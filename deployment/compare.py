#!/usr/bin/env python3
"""Build two OMC revisions and compare existing library-testing runs."""

import argparse
import csv
from contextlib import suppress
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

DEPLOYMENT = Path(__file__).resolve().parent
ROOT = DEPLOYMENT.parent
STATE = DEPLOYMENT / "state"
RESULTS = DEPLOYMENT / "results"
SOLVERS = {
    "cvode": "-s=cvode",
    "gbode-radauIIA3": "-s=gbode -gbm=radauIIA3 -gbnls=internal",
    "dassl": "-s=dassl",
    "ida": "-s=ida",
}
CMAKE = ["-DCMAKE_BUILD_TYPE=Release", "-DOM_ENABLE_GUI_CLIENTS=OFF",
         "-DOM_ENABLE_OMSIMULATOR=OFF", "-DOM_OMC_ENABLE_CPP_RUNTIME=OFF"]


def save(path, data):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def digest(paths):
    result = hashlib.sha256()
    for name, path in sorted(paths):
        result.update(name.encode() + b"\0")
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                result.update(block)
    return result.hexdigest()


def run(command, log, timeout, cwd=None):
    command = [str(arg) for arg in command]
    print("+ " + shlex.join(command) + f"\nLog: {log}", flush=True)
    with log.open("ab", buffering=0) as output:
        output.write(("\n+ " + shlex.join(command) + "\n").encode())
        process = subprocess.Popen(command, cwd=cwd, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            # Model workers start separate sessions, so the outer process group is insufficient.
            parents = [tuple(map(int, line.split())) for line in
                       subprocess.check_output(["ps", "-eo", "pid=,ppid="], text=True, timeout=10).splitlines()]
            descendants = {process.pid}
            while True:
                children = {pid for pid, parent in parents if parent in descendants} - descendants
                if not children:
                    break
                descendants.update(children)
            for pid in descendants:
                with suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGTERM)
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
            for pid in descendants:
                with suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGKILL)
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
    if code:
        raise RuntimeError(f"command exited {code}; see {log}")


def output(command):
    return subprocess.check_output([str(x) for x in command], timeout=60, text=True).strip()


def identifier(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value):
        raise argparse.ArgumentTypeError("use letters, numbers, dot, underscore or hyphen")
    return value


def jobs(value):
    number = int(value)
    if not 1 <= number <= 8:
        raise argparse.ArgumentTypeError("use 1 to 8 jobs")
    return number


def select_config(args):
    entries = json.loads(args.config.read_text())
    selected = []
    for request in args.library or ["Modelica:4.1.0", "Buildings:master"]:
        library, separator, version = request.partition(":")
        found = [entry for entry in entries if entry["library"] == library and
                 (not separator or str(entry.get("libraryVersion") or "default") == version)]
        if not found:
            raise ValueError(f"no configuration matches {request}")
        for entry in found:
            if entry not in selected:
                selected.append(entry)
    return selected


def reference_paths(entries):
    references = STATE / "references"
    prefixes = {
        "/mnt/ReferenceFiles/Buildings/csv": references / "Buildings/csv",
        "$MSLREFERENCE": references / "msl",
        "$REFERENCEFILES": references / "openmodelica/ReferenceFiles",
        "$PNLIBREFS": references / "PNlib/ReferenceFiles",
        "$THERMOFLUIDSTREAMREFS": references / "ThermoFluidStream-main-regression/ReferenceData",
        "$MY_SANITY_CHECK_DIRECTORY": references / "sanityCheck",
    }
    for entry in entries:
        reference = entry.get("referenceFiles")
        if isinstance(reference, dict):
            yield references / "config" / reference["destination"] / reference.get("git-directory", "")
        elif reference:
            for prefix, destination in prefixes.items():
                if reference == prefix or reference.startswith(prefix + "/"):
                    yield destination / reference[len(prefix):].lstrip("/")
                    break
            else:
                yield Path(os.path.expandvars(reference))


def inputs(entries):
    libraries = STATE / "home/.openmodelica/libraries"
    paths = [("libraries/" + str(path.relative_to(libraries)), path)
             for path in libraries.rglob("*") if path.is_file() and
             (path.suffix == ".mo" or path.name == "openmodelica.metadata.json")]
    if not paths:
        raise ValueError("no installed Modelica sources; run deployment/setup.sh first")
    for index, directory in enumerate(reference_paths(entries)):
        if not directory.is_dir():
            raise ValueError(f"reference directory is missing: {directory}; rerun setup.sh")
        paths.extend((f"reference/{index}/" + str(path.relative_to(directory)), path)
                     for path in directory.rglob("*") if path.is_file() and
                     ".git" not in path.relative_to(directory).parts and not path.name.endswith(".hash"))
    return digest(paths)


def compiler(path):
    path = path.resolve()
    if path.is_dir():
        path = path / ("omc" if (path / "omc").is_file() else "bin/omc")
    prefix = path.parent.parent
    files = [("bin/omc", path)]
    for relative in ("lib/omc", "include/omc", "share/omc"):
        files.extend((str(item.relative_to(prefix)), item) for item in (prefix / relative).rglob("*")
                     if item.is_file() and item.suffix != ".pyc")
    return {"path": str(path), "version": output([path, "--version"]), "sha256": digest(files)}


def build(args, revision, directory, log):
    source = directory / "source"
    if not source.exists():
        run(["git", "clone", "--no-hardlinks", "--no-checkout", args.repo, source],
            log, args.build_timeout)
    run(["git", "-C", source, "checkout", "--detach", revision], log, args.build_timeout)
    run(["git", "-C", source, "submodule", "update", "--init", "--recursive",
         f"--jobs={args.build_jobs}"], log, args.build_timeout)
    build_dir = source / "build_cmake"
    run(["cmake", "-S", source, "-B", build_dir, *CMAKE, *args.cmake_arg], log, args.build_timeout)
    run(["cmake", "--build", build_dir, "--target", "install", "--parallel", args.build_jobs],
        log, args.build_timeout)
    return compiler(build_dir / "install_cmake/bin/omc")


def model_results(name):
    result = {}
    for status_file in (RESULTS / name).glob("*/files/*.stat.json"):
        library = status_file.parent.parent.name
        prefix = status_file.name.removesuffix(".stat.json")
        model = prefix.removeprefix(library + "_")
        stat = json.loads(status_file.read_text())
        phase = int(stat.get("phase") or 0)
        diff = stat.get("diff")
        compared = int((diff or {}).get("numCompared") or 0)
        verifies = ("yes" if phase >= 7 and compared > 0 else
                    "invalid (zero variables)" if phase >= 7 else
                    "no" if phase >= 6 and diff is not None else
                    "not completed" if phase >= 6 and stat.get("referenceFile") else
                    "no reference" if phase >= 6 else "not run")
        diagnostics = "\n".join(path.read_text(errors="replace") for extension in (".err", ".sim")
                                if (path := status_file.with_name(prefix + extension)).is_file())
        timed_out = phase < 6 and bool(re.search(r"timed out|timeout error|alarm clock|SIGALRM", diagnostics, re.I))
        reason = "timeout" if timed_out else "reference mismatch" if verifies == "no" else ""
        if phase < 6 and not reason:
            lines = [line.strip() for line in diagnostics.splitlines() if line.strip()]
            reason = " | ".join(lines[-3:])[-500:] or "failed before simulation completed"
        result[library, model] = {
            "simulates": "yes" if phase >= 6 else "no", "verifies": verifies,
            "simulation_s": stat.get("sim"),
            "translation_build_s": sum(stat.get(key) or 0 for key in
                                       ("parsing", "frontend", "backend", "simcode", "templates", "build")),
            "total_s": stat.get("exectime"), "reason": reason,
            "failing_variables": ", ".join((diff or {}).get("vars") or []),
        }
    return result


def report(manifest, destination):
    rows = []
    summary = ["# Compiler comparison", "", "Exact inputs and commands: `manifest.json`.", "",
               "Times are seconds. Speedup uses only models simulated by both versions; "
               "timeout costs remain in total execution time.", "",
               "| Solver | Models before/after | Simulate before/after | Verify before/after | "
               "Common completions | Simulation speedup | Total execution before/after (s) |",
               "|---|---:|---:|---:|---:|---:|---:|"]
    for solver in manifest["settings"]["solvers"]:
        before = model_results(f"{manifest['name']}-baseline-{solver}")
        after = model_results(f"{manifest['name']}-candidate-{solver}")
        common = [key for key in before.keys() & after.keys()
                  if before[key]["simulates"] == after[key]["simulates"] == "yes"]
        before_time = sum(before[key]["simulation_s"] or 0 for key in common)
        after_time = sum(after[key]["simulation_s"] or 0 for key in common)
        speedup = f"{before_time / after_time:.3f}x" if after_time else "—"
        counts = [f"{sum(value[field] == 'yes' for value in data.values())}"
                  for field in ("simulates", "verifies") for data in (before, after)]
        costs = [sum(value["total_s"] or 0 for value in data.values()) for data in (before, after)]
        summary.append(f"| {solver} | {len(before)}/{len(after)} | {counts[0]}/{counts[1]} | "
                       f"{counts[2]}/{counts[3]} | {len(common)} | {speedup} | {costs[0]:.2f}/{costs[1]:.2f} |")
        for library, model in sorted(before.keys() | after.keys()):
            row = {"library": library, "model": model, "solver": solver}
            for label, data in (("before", before), ("after", after)):
                row.update({label + "_" + key: value for key, value in data.get((library, model), {
                    "simulates": "missing", "verifies": "missing", "reason": "no result"}).items()})
            rows.append(row)
    if rows:
        with (destination / "models.csv").open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(dict.fromkeys(key for row in rows for key in row)))
            writer.writeheader()
            writer.writerows(rows)
    summary += ["", "## Per-model results", "",
                "| Library / Model | Solver | Simulates before → after | Verifies before → after | Simulation seconds before → after | Detail |",
                "|---|---|---|---|---|---|"]
    for row in rows:
        times = [f"{row[label + '_simulation_s']:.3f}" if isinstance(row.get(label + "_simulation_s"), (int, float))
                 else "—" for label in ("before", "after")]
        detail = "; ".join(f"{label}: {row[label + '_reason']}" for label in ("before", "after") if row.get(label + "_reason"))
        summary.append(f"| {row['library']} / {row['model']} | {row['solver']} | "
                       f"{row['before_simulates']} → {row['after_simulates']} | "
                       f"{row['before_verifies']} → {row['after_verifies']} | {' → '.join(times)} | "
                       + detail.replace("|", "\\|").replace("\n", " ") + " |")
    (destination / "summary.md").write_text("\n".join(summary) + "\n")
    save(destination / "manifest.json", manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, help="local OpenModelica Git checkout; committed revisions only")
    parser.add_argument("--baseline", default="origin/master")
    parser.add_argument("--candidate", help="branch, commit, or fetched PR ref")
    parser.add_argument("--baseline-omc", type=Path, help="use an existing install instead of building")
    parser.add_argument("--candidate-omc", type=Path)
    parser.add_argument("--fetch", action="store_true", help="fetch origin before resolving revisions")
    parser.add_argument("--build-root", type=Path, help="compiler clones/builds (default: comparison state directory)")
    parser.add_argument("--library", action="append", metavar="NAME:VERSION",
                        help="repeatable; default: Modelica:4.1.0 and Buildings:master")
    parser.add_argument("--config", type=Path, default=ROOT / "configs/conf.json")
    parser.add_argument("--solvers", default="cvode,gbode-radauIIA3", help="comma-separated preset names")
    parser.add_argument("--solver", action="append", default=[], metavar="NAME=FLAGS", help="add a custom solver configuration")
    parser.add_argument("--compiler-flags", default="--simCodeTarget=C")
    parser.add_argument("--runtime-flags", default="", help="append to every solver configuration")
    parser.add_argument("--cmake-arg", action="append", default=[], help="extra CMake argument; use --cmake-arg=-D...")
    parser.add_argument("--jobs", type=jobs, default=2, help="parallel model tests (1–8)")
    parser.add_argument("--build-jobs", type=jobs, default=8)
    parser.add_argument("--build-timeout", type=float, default=7200, help="seconds per build/setup command")
    parser.add_argument("--run-timeout", type=float, default=86400, help="seconds per library-test job")
    parser.add_argument("--name", type=identifier, help="result prefix; required for resume/report-only")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--report-only", action="store_true")
    args = parser.parse_args()
    if (args.resume or args.report_only) and not args.name:
        parser.error("--resume/--report-only requires --name")
    if min(args.build_timeout, args.run_timeout) <= 0:
        parser.error("timeouts must be positive")
    args.name = args.name or time.strftime("compare-%Y%m%dT%H%M%SZ", time.gmtime())
    destination = RESULTS / "comparisons" / args.name
    directory = STATE / "comparisons" / args.name
    directory.mkdir(parents=True, exist_ok=True)
    destination.mkdir(parents=True, exist_ok=True)
    manifest_path = directory / "manifest.json"
    if args.report_only:
        report(json.loads(manifest_path.read_text()), destination)
        print(destination / "summary.md")
        return
    if bool(args.baseline_omc) != bool(args.candidate_omc):
        parser.error("provide both --baseline-omc and --candidate-omc")
    if args.baseline_omc and (args.repo or args.candidate or args.fetch):
        parser.error("installed-compiler mode cannot be combined with source revisions/--fetch")
    if not args.baseline_omc and (not args.repo or not args.candidate):
        parser.error("provide --repo and --candidate, or both installed compilers")
    lock = (STATE / "compare.lock").open("a")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.environ.update(OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1", CARGO_BUILD_JOBS=str(args.build_jobs))
    unknown = set(args.solvers.split(",")) - SOLVERS.keys() - {""}
    if unknown:
        parser.error("unknown solver(s): " + ", ".join(sorted(unknown)))
    solvers = {identifier(name): SOLVERS[name] for name in args.solvers.split(",") if name}
    for value in args.solver:
        name, separator, flags = value.partition("=")
        if not separator or not flags.strip():
            parser.error("--solver requires NAME=FLAGS")
        solvers[identifier(name)] = flags
    if not solvers:
        parser.error("select at least one solver")
    entries = select_config(args)
    build_root = (args.build_root.resolve() / args.name if args.build_root else directory / "builds").resolve()
    revisions = {}
    requested = {"repo": str(args.repo.resolve()) if args.repo else None,
                 "baseline": args.baseline, "candidate": args.candidate}
    saved = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
    if args.repo:
        args.repo = args.repo.resolve()
        if args.fetch and not args.resume:
            run(["git", "-C", args.repo, "fetch", "origin"], directory / "fetch.log", args.build_timeout)
        revisions = saved["settings"]["revisions"] if args.resume and saved else {label: output(["git", "-C", args.repo, "rev-parse", "--verify", ref + "^{commit}"])
                     for label, ref in (("baseline", args.baseline), ("candidate", args.candidate))}
    if revisions and len(set(revisions.values())) == 1:
        raise ValueError("baseline and candidate resolve to the same commit; commit the candidate changes first")
    settings = {"requested": requested, "revisions": revisions, "libraries": entries, "solvers": solvers,
                "compiler_flags": args.compiler_flags, "runtime_flags": args.runtime_flags,
                "cmake": CMAKE + args.cmake_arg, "build_root": str(build_root), "jobs": args.jobs,
                "harness": digest((path, ROOT / path) for path in
                                  ("deployment/run.sh", "deployment/setup.sh", "deployment/compare.py",
                                   "test.py", "testmodel.py", "shared.py", "omcommon.py", "report.py",
                                   "library.html.tpl", "overview.html.tpl"))}
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text())
        if not args.resume:
            raise ValueError(f"comparison {args.name} exists; use --resume or a new --name")
        if manifest["settings"] != settings:
            raise ValueError("comparison inputs/settings changed; use a new --name")
    else:
        if any((RESULTS / f"{args.name}-{label}-{solver}").exists()
               for label in ("baseline", "candidate") for solver in solvers):
            raise ValueError("result names already exist; choose a new --name")
        manifest = {"name": args.name, "settings": settings, "compilers": {}, "completed": []}
        save(manifest_path, manifest)
    config = directory / "libraries.json"
    save(config, entries)
    for label in ("baseline", "candidate"):
        existing = getattr(args, label + "_omc")
        previous = manifest["compilers"].get(label)
        current = compiler(existing) if existing else compiler(Path(previous["path"])) if previous else None
        if previous and previous != current:
            raise ValueError(f"{label} compiler changed; use a new --name")
        if current is None:
            build_dir = build_root / label
            build_dir.mkdir(parents=True, exist_ok=True)
            current = build(args, revisions[label], build_dir, directory / (label + "-build.log"))
        manifest["compilers"][label] = current
        save(manifest_path, manifest)
    if not (STATE / "setup.complete").is_file():
        run([DEPLOYMENT / "setup.sh", "--omc", manifest["compilers"]["baseline"]["path"]],
            directory / "setup.log", args.build_timeout)
    snapshot = inputs(entries)
    if "inputs_sha256" in manifest and manifest["inputs_sha256"] != snapshot:
        raise ValueError("installed library sources or references changed; use a new --name")
    manifest["inputs_sha256"] = snapshot
    save(manifest_path, manifest)
    try:
        for label in ("baseline", "candidate"):
            for solver, flags in solvers.items():
                name = f"{args.name}-{label}-{solver}"
                if name in manifest["completed"]:
                    if not model_results(name):
                        raise ValueError(f"completed results are missing: {RESULTS / name}")
                    continue
                if inputs(entries) != snapshot:
                    raise ValueError("library/reference inputs changed during comparison")
                if compiler(Path(manifest["compilers"][label]["path"])) != manifest["compilers"][label]:
                    raise ValueError(f"{label} compiler installation changed")
                work = directory / "work" / name
                command = [DEPLOYMENT / "run.sh", "master", "--name", name,
                           "--omc", manifest["compilers"][label]["path"],
                           "--config", config, "--work-dir", work, "--jobs", args.jobs,
                           "--compiler-flags", args.compiler_flags,
                           "--runtime-flags", flags + " " + args.runtime_flags, "--require-references",
                           "--resume" if args.resume and (work / "files").is_dir() else "--force"]
                run(command, directory / (name + ".log"), args.run_timeout)
                if inputs(entries) != snapshot:
                    raise ValueError("library/reference inputs changed during comparison")
                if not model_results(name):
                    raise RuntimeError(f"no model results were produced for {name}")
                manifest["completed"].append(name)
                save(manifest_path, manifest)
                report(manifest, destination)
        run([DEPLOYMENT / "run.sh", "report", "--config", config,
             "--omc", manifest["compilers"]["baseline"]["path"],
             "--work-dir", directory / "report", "--branches", " ".join(manifest["completed"])],
            directory / "report.log", args.run_timeout)
        shutil.copy2(RESULTS / "overview.html", RESULTS / (args.name + "-overview.html"))
    finally:
        report(manifest, destination)
    print(f"\nComparison: {destination / 'summary.md'}\nPer-model CSV: {destination / 'models.csv'}\n"
          f"HTML: {RESULTS / (args.name + '-overview.html')}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f"error: {error}")
