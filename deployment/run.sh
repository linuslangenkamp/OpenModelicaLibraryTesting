#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOYMENT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$DEPLOYMENT/.." && pwd -P)"
SIBLING_OMC="$ROOT/../OpenModelica/build_cmake/install_cmake/bin/omc"
if [[ -x "$SIBLING_OMC" ]]; then
  SIBLING_OMC="$(cd -- "$(dirname -- "$SIBLING_OMC")" && pwd -P)/omc"
fi
STATE="$DEPLOYMENT/state"
RESULTS="$DEPLOYMENT/results"
VENV="$STATE/venv"
HOME_DIR="$STATE/home"
LIBRARIES="$HOME_DIR/.openmodelica/libraries"
REFS="$STATE/references"
WORK="$STATE/work"
DATABASE="$STATE/database/sqlite3.db"
SOURCE_CONFIG="$ROOT/configs/conf.json"

usage() {
  cat <<'EOF'
Usage: deployment/run.sh JOB [OPTIONS]

Run the repository's existing test.py/report.py using configs/conf.json.
Without --omc, run.sh reuses the executable recorded by setup.sh; otherwise
the existing sibling compiler is preferred:
  ../OpenModelica/build_cmake/install_cmake/bin/omc
No OpenModelica checkout, build, or compiler branch is changed by a job.

Jobs:
  master   Regular nightly test settings; uses the current existing omc
  gbode    Nightly GBODE settings
  cvode    Nightly CVODE settings
  ida      Nightly IDA settings
  all      Run master, gbode, cvode, and ida, then create an overview
  report   Create deployment/results/overview.html from existing results

Nightly presets:
  master   compiler: none; runtime: none
  cvode    compiler: -d=newInst,-frontEndUnitCheck; runtime: -s cvode
  ida      compiler: -d=newInst,-frontEndUnitCheck; runtime: -s ida
  gbode    compiler: -d=newInst,-frontEndUnitCheck
           runtime: -s gbode -gbnls=internal -gberr=embedded -gbm=esdirk4

Options:
  --library NAME          Test only NAME (repeatable; default: all libraries)
  --version VERSION       Select this version of --library (use default for an
                          entry with no explicit libraryVersion)
  --jobs N                Parallel model tests (default: 2, laptop-safe)
  --compiler-flags FLAGS  Append raw OMC flags to the selected preset
  --runtime-flags FLAGS   Append simulation executable flags to the preset
  --name NAME             Result/database name; with all, NAME is a prefix
  --omc PATH              Existing omc executable, bin directory, or install
                          prefix containing bin/omc; overrides setup's path
  --require-references    Stop before testing if a selected reference set is
                          unavailable or invalid
  --force                 Forward --execAllTests to test.py
  -h, --help              Show this help

Reference behavior:
  Available references are passed as absolute deployment/state paths. Missing
  references are omitted from the temporary config, so test.py still simulates
  and creates its standard HTML with verification left empty.
  Buildings CSV sets are validated before the run. A completed run is rejected
  if any model is marked verified after comparing zero variables.

Buildings versions in configs/conf.json:
  maint.11.x, maint.12.x, master

Outputs:
  deployment/results/NAME/LIBRARY/LIBRARY.html  Standard library HTML
  deployment/results/overview.html              Standard overview (report job)
  deployment/state/database/sqlite3.db          Existing test.py database
  deployment/state/logs/run-*.log               Complete run logs

Examples:
  deployment/run.sh master
  deployment/run.sh master --library Modelica --version 4.1.0 --jobs 2
  deployment/run.sh gbode --library Buildings --version maint.12.x --force
  deployment/run.sh master --library Buildings --version master --jobs 2 --require-references
  deployment/run.sh master --omc /opt/openmodelica --library Buildings
  deployment/run.sh ida --compiler-flags "--newBackend" --runtime-flags "-nls=kinsol"
  deployment/run.sh all --jobs 4
  deployment/run.sh report
  deployment/run.sh report --library Buildings --version master
  deployment/run.sh report --name my-buildings --library Buildings --version master
EOF
  if [[ -x "$SIBLING_OMC" ]]; then
    printf '\nDetected existing omc: %s\n' "$SIBLING_OMC"
  fi
}

resolve_omc() {
  local requested=$1 candidate=''
  if [[ -d "$requested" && -x "$requested/omc" ]]; then
    candidate="$requested/omc"
  elif [[ -d "$requested" && -x "$requested/bin/omc" ]]; then
    candidate="$requested/bin/omc"
  elif [[ -f "$requested" && -x "$requested" ]]; then
    candidate="$requested"
  else
    printf 'error: --omc does not resolve to an executable omc: %s\n' "$requested" >&2
    return 1
  fi
  printf '%s/%s\n' "$(cd -- "$(dirname -- "$candidate")" && pwd -P)" "$(basename -- "$candidate")"
}

case "${1:-}" in
  -h|--help|'') usage; [[ -n "${1:-}" ]] && exit 0 || exit 2 ;;
esac
JOB=$1
shift
case "$JOB" in
  master|gbode|cvode|ida|all|report) ;;
  *) printf 'error: unknown job: %s\n' "$JOB" >&2; usage >&2; exit 2 ;;
esac

JOBS=2
VERSION=''
VERSION_SET=0
NAME=''
NAME_SET=0
COMPILER_FLAGS=''
RUNTIME_FLAGS=''
FORCE=0
REQUIRE_REFERENCES=0
OMC_REQUEST=''
LIBRARY_FILTERS=()

need_value() {
  (($# >= 2)) || {
    printf 'error: %s requires a value\n' "$1" >&2
    exit 2
  }
}

while (($#)); do
  case "$1" in
    --library)
      need_value "$@"
      LIBRARY_FILTERS+=("$2")
      shift 2
      ;;
    --version)
      need_value "$@"
      VERSION=$2
      VERSION_SET=1
      shift 2
      ;;
    --jobs)
      need_value "$@"
      JOBS=$2
      shift 2
      ;;
    --compiler-flags)
      need_value "$@"
      COMPILER_FLAGS=$2
      shift 2
      ;;
    --runtime-flags)
      need_value "$@"
      RUNTIME_FLAGS=$2
      shift 2
      ;;
    --name)
      need_value "$@"
      NAME=$2
      NAME_SET=1
      shift 2
      ;;
    --omc)
      need_value "$@"
      OMC_REQUEST=$2
      shift 2
      ;;
    --omc=*)
      OMC_REQUEST=${1#*=}
      [[ -n "$OMC_REQUEST" ]] || { printf 'error: --omc requires a path\n' >&2; exit 2; }
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --require-references)
      REQUIRE_REFERENCES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || {
  printf 'error: --jobs must be a positive integer\n' >&2
  exit 2
}
if ((VERSION_SET)) && ((${#LIBRARY_FILTERS[@]} == 0)); then
  printf 'error: --version requires --library\n' >&2
  exit 2
fi
if ((NAME_SET)) && [[ ! "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  printf 'error: --name may contain only letters, numbers, dot, underscore, and hyphen\n' >&2
  exit 2
fi
if [[ "$COMPILER_FLAGS" == *$'\n'* || "$RUNTIME_FLAGS" == *$'\n'* ]]; then
  printf 'error: compiler/runtime flags may not contain newlines\n' >&2
  exit 2
fi
if [[ "$JOB" == report && ( -n "$COMPILER_FLAGS" || -n "$RUNTIME_FLAGS" ) ]]; then
  printf 'error: compiler/runtime flags do not apply to the report job\n' >&2
  exit 2
fi

[[ -f "$STATE/setup.complete" ]] || {
  printf 'error: deployment is not set up; run %s/setup.sh first\n' "$DEPLOYMENT" >&2
  exit 1
}
if [[ -n "$OMC_REQUEST" ]]; then
  OMC_BIN="$(resolve_omc "$OMC_REQUEST")"
else
  OMC_BIN="$(sed -n 's/^omc_executable=//p' "$STATE/setup.complete" | tail -n 1)"
  if [[ -n "$OMC_BIN" ]]; then
    OMC_BIN="$(resolve_omc "$OMC_BIN")" || {
      printf 'error: the omc recorded by setup is unavailable; rerun setup.sh --omc PATH\n' >&2
      exit 1
    }
  elif [[ -x "$SIBLING_OMC" ]]; then
    OMC_BIN=$SIBLING_OMC
  elif command -v omc >/dev/null 2>&1; then
    OMC_BIN="$(resolve_omc "$(command -v omc)")"
  else
    OMC_BIN=''
  fi
fi
if [[ -n "$OMC_BIN" ]]; then
  export PATH="$(dirname -- "$OMC_BIN"):$PATH"
  export OPENMODELICAHOME="$(cd -- "$(dirname -- "$OMC_BIN")/.." && pwd -P)"
fi
[[ -x "$VENV/bin/python" ]] || {
  printf 'error: deployment Python is missing; rerun %s/setup.sh\n' "$DEPLOYMENT" >&2
  exit 1
}
command -v omc >/dev/null 2>&1 || {
  printf 'error: omc is unavailable; rerun setup or place omc in PATH\n' >&2
  exit 1
}
command -v flock >/dev/null 2>&1 || {
  printf 'error: flock is required (normally provided by util-linux)\n' >&2
  exit 1
}

mkdir -p "$RESULTS" "$WORK" "$STATE/database" "$STATE/logs" "$STATE/runs" \
  "$STATE/tmp/configs" "$STATE/tmp/runtime" "$REFS/config/ReferenceFiles"
touch "$DATABASE"

export HOME="$HOME_DIR"
export XDG_CACHE_HOME="$STATE/cache/xdg"
export XDG_CONFIG_HOME="$STATE/config"
export XDG_DATA_HOME="$STATE/data"
export PIP_CACHE_DIR="$STATE/cache/pip"
export TMPDIR="$STATE/tmp/runtime"
export PATH="$VENV/bin:$PATH"
export MSLREFERENCE="$REFS/msl"
export REFERENCEFILES="$REFS/openmodelica/ReferenceFiles"
export PNLIBREFS="$REFS/PNlib/ReferenceFiles"
export THERMOFLUIDSTREAMREFS="$REFS/ThermoFluidStream-main-regression/ReferenceData"
export THERMOFLUIDSTREAMREFSOM="$REFS/ThermoFluidStream-OM-regression/ReferenceData"
export MY_SANITY_CHECK_DIRECTORY="$REFS/sanityCheck"
export GC_MARKERS=1

if [[ "$JOB" != report ]]; then
  needs_buildings=0
  if ((${#LIBRARY_FILTERS[@]} == 0)); then
    needs_buildings=1
  else
    for library in "${LIBRARY_FILTERS[@]}"; do
      [[ "$library" != Buildings ]] || needs_buildings=1
    done
  fi
  if ((needs_buildings)) && ! "$VENV/bin/python" -c 'import jinja2' >/dev/null 2>&1; then
    printf 'error: Buildings requires Jinja2 in the deployment Python. Install it with:\n  %s/bin/python -m pip install '\''Jinja2>=3.1,<4'\''\nor rerun setup.sh.\n' "$VENV" >&2
    exit 1
  fi
fi

exec 9>"$STATE/run.lock"
flock -n 9 || {
  printf 'error: another deployment run is active\n' >&2
  exit 1
}

link_path() {
  local source=$1 target=$2
  if [[ -L "$target" ]]; then
    ln -sfn -- "$source" "$target"
  elif [[ -e "$target" ]]; then
    printf 'error: unmanaged path exists in deployment work directory: %s\n' "$target" >&2
    exit 1
  else
    ln -s -- "$source" "$target"
  fi
}

for file in Architecture.mo FMI.mos HelloWorld.mo HelloWorld.mos \
  library.html.tpl overview.html.tpl omcommon.py report.py shared.py \
  test.py testmodel.py; do
  [[ -e "$ROOT/$file" ]] || {
    printf 'error: required repository file is missing: %s\n' "$ROOT/$file" >&2
    exit 1
  }
  link_path "$ROOT/$file" "$WORK/$file"
done
link_path "$DATABASE" "$WORK/sqlite3.db"

TEMP_CONFIGS=()
CONFIG_RESULT=''
cleanup() {
  ((${#TEMP_CONFIGS[@]} == 0)) || rm -f -- "${TEMP_CONFIGS[@]}"
}
trap cleanup EXIT

make_config() {
  local output
  output="$(mktemp "$STATE/tmp/configs/effective.XXXXXX")"
  TEMP_CONFIGS+=("$output")
  if ! "$VENV/bin/python" - "$SOURCE_CONFIG" "$output" "$REFS" \
    "$VERSION_SET" "$VERSION" "$REQUIRE_REFERENCES" "${LIBRARY_FILTERS[@]}" <<'PY'
import copy, csv, json, os, sys
source, output, references_root, version_set, version, require_references, *libraries = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    entries = json.load(handle)

def effective_version(entry):
    return str(entry.get("libraryVersion") or "default")

selected = entries
if libraries:
    wanted = set(libraries)
    present = {entry.get("library") for entry in entries}
    missing = sorted(wanted - present)
    if missing:
        raise SystemExit("unknown library: " + ", ".join(missing))
    selected = [entry for entry in selected if entry.get("library") in wanted]
if version_set == "1":
    selected = [entry for entry in selected if effective_version(entry) == version]
    matched = {entry.get("library") for entry in selected}
    missing = sorted(set(libraries) - matched)
    if missing:
        available = []
        for library in missing:
            versions = sorted({effective_version(entry) for entry in entries if entry.get("library") == library})
            available.append(f"{library}: {', '.join(versions)}")
        raise SystemExit(
            f"version {version!r} is not configured for: {', '.join(missing)}; "
            + "available versions: " + "; ".join(available)
        )
if not selected:
    raise SystemExit("filters selected no config entries")

def local_reference(reference):
    if isinstance(reference, dict):
        path = os.path.join(references_root, "config", reference["destination"])
        if reference.get("git-directory"):
            path = os.path.join(path, reference["git-directory"])
        return path
    replacements = (
        ("$MSLREFERENCE", os.path.join(references_root, "msl")),
        ("$REFERENCEFILES", os.path.join(references_root, "openmodelica", "ReferenceFiles")),
        ("$PNLIBREFS", os.path.join(references_root, "PNlib", "ReferenceFiles")),
        ("$THERMOFLUIDSTREAMREFS", os.path.join(references_root, "ThermoFluidStream-main-regression", "ReferenceData")),
        ("$MY_SANITY_CHECK_DIRECTORY", os.path.join(references_root, "sanityCheck")),
        ("/mnt/ReferenceFiles/Buildings/csv", os.path.join(references_root, "Buildings", "csv")),
    )
    for prefix, replacement in replacements:
        if reference == prefix or reference.startswith(prefix + "/"):
            return replacement + reference[len(prefix):]
    return None

def validate_buildings_csv_set(path):
    files = []
    for directory, subdirectories, filenames in os.walk(path):
        subdirectories[:] = [name for name in subdirectories if name != ".git"]
        files.extend(
            os.path.join(directory, name)
            for name in filenames
            if name.lower().endswith(".csv")
        )
    if not files:
        return False, "no CSV reference files were found"
    for filename in sorted(files):
        try:
            with open(filename, newline="", encoding="utf-8") as handle:
                reader = csv.reader(handle, strict=True)
                header = next(reader)
                if len(header) < 2 or header[0].strip() != "time":
                    return False, f"{filename} is not a comma-separated time/result CSV"
                if any(not name.strip() for name in header):
                    return False, f"{filename} contains an empty variable name"
                if len(set(header)) != len(header):
                    return False, f"{filename} contains duplicate variable names"
                rows = 0
                for row_number, row in enumerate(reader, 2):
                    if len(row) != len(header):
                        return False, (
                            f"{filename} row {row_number} has {len(row)} columns; "
                            f"expected {len(header)}"
                        )
                    try:
                        for value in row:
                            float(value)
                    except ValueError:
                        return False, f"{filename} row {row_number} contains a non-numeric value"
                    rows += 1
                if rows == 0:
                    return False, f"{filename} has no data rows"
        except (OSError, UnicodeError, csv.Error, StopIteration) as error:
            return False, f"cannot parse {filename}: {error}"
    return True, f"validated {len(files)} Buildings CSV reference files"

def reference_status(path, extension):
    if not path or not os.path.isdir(path):
        return False, f"local directory is missing: {path or '<unresolved>'}"
    suffix = "." + extension.lower().lstrip(".")
    buildings_root = os.path.abspath(os.path.join(references_root, "Buildings", "csv"))
    candidate = os.path.abspath(path)
    if suffix == ".csv" and (
        candidate == buildings_root or candidate.startswith(buildings_root + os.sep)
    ):
        return validate_buildings_csv_set(path)
    for directory, subdirectories, filenames in os.walk(path):
        subdirectories[:] = [name for name in subdirectories if name != ".git"]
        for name in filenames:
            if not name.lower().endswith(suffix):
                continue
            if suffix != ".csv":
                return True, f"found {suffix} reference files"
            try:
                with open(os.path.join(directory, name), newline="", encoding="utf-8") as handle:
                    if len(next(csv.reader(handle))) >= 2:
                        return True, "found readable CSV reference files"
            except (OSError, StopIteration, UnicodeError):
                pass
    return False, f"no readable {suffix} reference files were found in {path}"

selected = copy.deepcopy(selected)
without_references = 0
for entry in selected:
    reference = entry.get("referenceFiles")
    if reference is None:
        continue
    path = local_reference(reference)
    extension = str(entry.get("referenceFileExtension") or "mat")
    available, detail = reference_status(path, extension)
    label = f"{entry.get('library')} {effective_version(entry)}"
    if available:
        entry["referenceFiles"] = os.path.abspath(path)
        print(f"Reference verification enabled for {label}: {detail} ({path})", file=sys.stderr)
    else:
        entry.pop("referenceFiles", None)
        entry.pop("allReferenceFilesExist", None)
        without_references += 1
        print(f"Reference verification disabled for {label}: {detail}", file=sys.stderr)
if require_references == "1" and without_references:
    raise SystemExit(
        f"{without_references} selected reference set(s) are unavailable or invalid; "
        "setup or repair them before running with --require-references"
    )
with open(output, "w", encoding="utf-8") as handle:
    json.dump(selected, handle, indent=2)
    handle.write("\n")
print(
    f"Using {len(selected)} entry/entries from {source}; "
    f"{without_references} will run without reference verification",
    file=sys.stderr,
)
PY
  then
    rm -f -- "$output"
    return 1
  fi
  CONFIG_RESULT=$output
}

join_flags() {
  local preset=$1 extra=$2
  if [[ -n "$preset" && -n "$extra" ]]; then
    printf '%s %s' "$preset" "$extra"
  else
    printf '%s%s' "$preset" "$extra"
  fi
}

omc_expression() {
  local flags=$1
  flags=${flags//\\/\\\\}
  flags=${flags//\"/\\\"}
  printf 'setCommandLineOptions("%s")' "$flags"
}

audit_verification_results() {
  local branch=$1 config=$2
  "$VENV/bin/python" - "$RESULTS/$branch" "$config" <<'PY'
import glob, json, os, sys

result_root, config_file = sys.argv[1:]
with open(config_file, encoding="utf-8") as handle:
    entries = json.load(handle)

def result_name(entry):
    library = entry["library"]
    if "libraryVersionNameForTests" in entry:
        suffix = entry["libraryVersionNameForTests"]
        return f"{library}_{suffix}" if suffix else library
    version = entry.get("libraryVersion", "default")
    name = library if version == "default" else f"{library}_{version}"
    if "configExtraName" in entry:
        name += "_" + entry["configExtraName"]
    return name

zero_variable = []
compared_models = 0
compared_variables = 0
status_files = 0
for entry in entries:
    directory = os.path.join(result_root, result_name(entry), "files")
    for filename in glob.glob(os.path.join(directory, "*.stat.json")):
        status_files += 1
        try:
            with open(filename, encoding="utf-8") as handle:
                status = json.load(handle)
        except (OSError, ValueError):
            continue
        diff = status.get("diff") or {}
        compared = int(diff.get("numCompared") or 0)
        if int(status.get("phase") or 0) >= 7:
            if compared <= 0:
                zero_variable.append(filename)
            else:
                compared_models += 1
                compared_variables += compared

if zero_variable:
    print(
        "error: invalid verification result: "
        f"{len(zero_variable)} model(s) reached verification after comparing zero variables.",
        file=sys.stderr,
    )
    for filename in zero_variable[:5]:
        print(f"  {filename}", file=sys.stderr)
    if len(zero_variable) > 5:
        print(f"  ... and {len(zero_variable) - 5} more", file=sys.stderr)
    print(
        "The HTML and simulation results were preserved, but the verification column must not be trusted.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"Reference-result audit: {status_files} model status files; "
    f"{compared_models} model(s) genuinely compared {compared_variables} variable series"
)
PY
}

run_one() {
  local preset=$1 branch=$2 preset_compiler='' preset_runtime=''
  local compiler runtime config run_dir log timestamp status
  local -a command

  case "$preset" in
    master) ;;
    cvode)
      preset_compiler='-d=newInst,-frontEndUnitCheck'
      preset_runtime='-s cvode'
      ;;
    gbode)
      preset_compiler='-d=newInst,-frontEndUnitCheck'
      preset_runtime='-s gbode -gbnls=internal -gberr=embedded -gbm=esdirk4'
      ;;
    ida)
      preset_compiler='-d=newInst,-frontEndUnitCheck'
      preset_runtime='-s ida'
      ;;
  esac

  compiler="$(join_flags "$preset_compiler" "$COMPILER_FLAGS")"
  runtime="$(join_flags "$preset_runtime" "$RUNTIME_FLAGS")"
  if ! make_config; then
    printf 'error: configuration preflight failed; no tests were started\n' >&2
    return 1
  fi
  config=$CONFIG_RESULT
  run_dir="$STATE/runs/$branch"
  mkdir -p "$run_dir"
  cp -- "$config" "$run_dir/effective-config.json"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  log="$STATE/logs/run-$timestamp-$branch.log"

  command=(
    "$VENV/bin/python" "$WORK/test.py"
    --noSync
    "--branch=$branch"
    "--output=$RESULTS"
    "--libraries=$LIBRARIES"
    "--jobs=$JOBS"
  )
  [[ -z "$compiler" ]] || command+=("--extraflags=$(omc_expression "$compiler")")
  [[ -z "$runtime" ]] || command+=("--extrasimflags=$runtime")
  ((FORCE == 0)) || command+=(--execAllTests)
  command+=("$config")

  {
    printf 'preset=%s\nbranch=%s\njobs=%s\ncompiler_flags=%s\nruntime_flags=%s\n' \
      "$preset" "$branch" "$JOBS" "$compiler" "$runtime"
    printf 'command='
    printf '%q ' "${command[@]}"
    printf '\n'
  } > "$run_dir/invocation.txt"

  printf '\n==> %s (name: %s, jobs: %s)\n' "$preset" "$branch" "$JOBS"
  printf 'Log: %s\nResults: %s/%s\n' "$log" "$RESULTS" "$branch"
  set +e
  (cd "$WORK" && "${command[@]}") 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  set -e
  ((status == 0)) || {
    printf 'error: test.py failed for %s with status %s; see %s\n' "$branch" "$status" "$log" >&2
    return "$status"
  }
  audit_verification_results "$branch" "$config"
}

available_report_branches() {
  "$VENV/bin/python" - "$DATABASE" "$@" <<'PY'
import sqlite3, sys
database, *requested = sys.argv[1:]
with sqlite3.connect(database) as connection:
    present = {row[0] for row in connection.execute("select name from sqlite_master where type='table'")}
present -= {"libversion", "omcversion"}
if requested:
    missing = [name for name in requested if name not in present]
    if missing:
        raise SystemExit("missing database branch table(s): " + ", ".join(missing))
    result = requested
else:
    preferred = [name for name in ("master", "gbode", "cvode", "ida") if name in present]
    result = preferred or sorted(present)
if not result:
    raise SystemExit("database contains no test runs")
print(" ".join(result))
PY
}

make_report() {
  local branches=$1 config log timestamp
  if ! make_config; then
    printf 'error: report configuration preflight failed\n' >&2
    return 1
  fi
  config=$CONFIG_RESULT
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  log="$STATE/logs/report-$timestamp.log"
  rm -f -- "$WORK/overview.html"
  printf '\n==> report for: %s\n' "$branches"
  (cd "$WORK" && "$VENV/bin/python" "$WORK/report.py" "--branches=$branches" "$config") 2>&1 | tee "$log"
  [[ -s "$WORK/overview.html" ]] || {
    printf 'error: report.py did not create overview.html; see %s\n' "$log" >&2
    return 1
  }
  mv -- "$WORK/overview.html" "$RESULTS/overview.html"
  cp -- "$config" "$RESULTS/effective-report-config.json"
  printf 'Overview: %s/overview.html\n' "$RESULTS"
}

if [[ "$JOB" == report ]]; then
  if ((NAME_SET)); then
    branches="$(available_report_branches "$NAME")"
  else
    branches="$(available_report_branches)"
  fi
  make_report "$branches"
elif [[ "$JOB" == all ]]; then
  all_branches=()
  for preset in master gbode cvode ida; do
    if ((NAME_SET)); then
      branch="$NAME-$preset"
    else
      branch="$preset"
    fi
    all_branches+=("$branch")
    run_one "$preset" "$branch"
  done
  make_report "${all_branches[*]}"
else
  branch="$JOB"
  ((NAME_SET == 0)) || branch="$NAME"
  run_one "$JOB" "$branch"
fi
