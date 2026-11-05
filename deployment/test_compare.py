#!/usr/bin/env python3
"""Local orchestration tests; no OMC build or network is needed."""

import csv
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("compare", HERE / "compare.py")
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)


class ComparisonTests(unittest.TestCase):
    def test_build_resume_and_reports(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            harness = root / "harness"
            deployment = harness / "deployment"
            deployment.mkdir(parents=True)
            shutil.copy2(HERE / "compare.py", deployment / "compare.py")
            for relative in ("deployment/setup.sh", "test.py", "testmodel.py", "shared.py",
                             "omcommon.py", "report.py", "library.html.tpl", "overview.html.tpl"):
                (harness / relative).write_text("fixture\n")
            (harness / "configs").mkdir()
            entries = [{"library": name, "libraryVersion": version} for name, version in
                       (("Modelica", "4.1.0"), ("Buildings", "master"))]
            (harness / "configs/conf.json").write_text(json.dumps(entries))
            state = deployment / "state"
            library = state / "home/.openmodelica/libraries/Test"
            library.mkdir(parents=True)
            (library / "package.mo").write_text("package Test end Test;\n")
            (state / "setup.complete").touch()
            runner = deployment / "run.sh"
            runner.write_text('''#!/usr/bin/env python3
import json,sys
from pathlib import Path
root=Path(__file__).resolve().parent
args=sys.argv[1:]
if args[0]=='report':
    (root/'results/overview.html').write_text('overview')
    sys.exit(0)
name=args[args.index('--name')+1]
work=Path(args[args.index('--work-dir')+1]); (work/'files').mkdir(parents=True,exist_ok=True)
with (root/'calls.jsonl').open('a') as f:f.write(json.dumps(args)+'\\n')
marker=root/'interrupted'
if name.endswith('candidate-cvode') and not marker.exists():
    marker.touch(); sys.exit(9)
for entry in json.loads(Path(args[args.index('--config')+1]).read_text()):
    lib=entry['library']+'_'+entry['libraryVersion']
    folder=root/'results'/name/lib/'files';folder.mkdir(parents=True,exist_ok=True)
    for model in ['Good','Repaired','Regressed','NoReference']:
        before='-baseline-' in name
        phase=5 if model=='Repaired' and before else 6 if model=='Regressed' and not before or model=='NoReference' else 7
        diff=None if phase==5 or model=='NoReference' else {'numCompared':1,'vars':['x'] if phase==6 else []}
        stat={'referenceFile':None if model=='NoReference' else 'reference.csv','phase':phase,'sim':2 if before else 1,'build':3,'exectime':5,'diff':diff}
        prefix=lib+'_'+entry['library']+'.'+model
        (folder/(prefix+'.stat.json')).write_text(json.dumps(stat))
        if phase==5:(folder/(prefix+'.err')).write_text('Simulation timed out')
''')
            runner.chmod(0o755)
            source = root / "compiler"
            source.mkdir()
            git = ["git", "-C", str(source)]
            subprocess.run(git + ["init", "-q", "-b", "master"], check=True)
            for name, value in (("user.name", "Test"), ("user.email", "test@example.invalid")):
                subprocess.run(git + ["config", name, value], check=True)
            (source / "omc").write_text("#!/bin/sh\necho Fake-OMC-1\n")
            (source / "omc").chmod(0o755)
            (source / "CMakeLists.txt").write_text('''cmake_minimum_required(VERSION 3.16)
project(FakeOMC NONE)
set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}/install_cmake" CACHE PATH "" FORCE)
install(PROGRAMS omc DESTINATION bin)
''')
            subprocess.run(git + ["add", "CMakeLists.txt", "omc"], check=True)
            subprocess.run(git + ["commit", "-qm", "baseline"], check=True)
            baseline = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
            subprocess.run(git + ["checkout", "-qb", "candidate"], check=True)
            (source / "omc").write_text("#!/bin/sh\necho Fake-OMC-2\n")
            subprocess.run(git + ["add", "omc"], check=True)
            subprocess.run(git + ["commit", "-qm", "candidate"], check=True)
            command = [sys.executable, str(deployment / "compare.py"), "--repo", str(source),
                       "--baseline", "master", "--candidate", "candidate", "--name", "test"]
            first = subprocess.run(command, capture_output=True, text=True, timeout=60)
            self.assertNotEqual(first.returncode, 0)
            self.assertIn("command exited 9", first.stderr)
            subprocess.run(git + ["branch", "--force", "master", "candidate"], check=True)
            resumed = subprocess.run(command + ["--resume"], capture_output=True, text=True, timeout=60)
            self.assertEqual(resumed.returncode, 0, resumed.stderr + resumed.stdout)
            destination = deployment / "results/comparisons/test"
            manifest = json.loads((destination / "manifest.json").read_text())
            self.assertEqual(manifest["settings"]["revisions"]["baseline"], baseline)
            self.assertEqual(len(manifest["completed"]), 4)
            calls = [json.loads(line) for line in (deployment / "calls.jsonl").read_text().splitlines()]
            self.assertIn("--resume", calls[3])
            self.assertEqual(len({call[call.index("--work-dir")+1] for call in calls}), 4)
            self.assertTrue(any("radauIIA3" in value for call in calls for value in call))
            with (destination / "models.csv").open() as handle:
                rows = list(csv.DictReader(handle))
            repaired = next(row for row in rows if row["model"] == "Modelica.Repaired")
            self.assertEqual((repaired["before_reason"], repaired["after_verifies"]), ("timeout", "yes"))
            regressed = next(row for row in rows if row["model"] == "Modelica.Regressed")
            self.assertEqual((regressed["before_verifies"], regressed["after_verifies"], regressed["after_failing_variables"]), ("yes", "no", "x"))
            self.assertTrue(all(row["after_verifies"] == "no reference" for row in rows if row["model"].endswith("NoReference")))
            (library / "package.mo").write_text("package Test Real changed; end Test;\n")
            refused = subprocess.run(command + ["--resume"], capture_output=True, text=True, timeout=60)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("sources or references changed", refused.stderr)
            self.assertEqual(subprocess.run([sys.executable, str(deployment / "compare.py"), "--name", "test", "--report-only"],
                                            capture_output=True, timeout=60).returncode, 0)

    def test_input_and_verification_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            original, original_state = compare.RESULTS, compare.STATE
            compare.RESULTS = Path(temporary)
            compare.STATE = Path(temporary) / "state"
            try:
                library = compare.STATE / "home/.openmodelica/libraries/Test"
                library.mkdir(parents=True)
                (library / "package.mo").write_text("package Test end Test;")
                references = compare.STATE / "references"
                references.mkdir()
                data = references / "Test.csv"
                data.write_text("time,x\n0,0\n")
                entries = [{"referenceFiles": str(references)}]
                fingerprint = compare.inputs(entries)
                (references / "Test.csv.hash").write_text("generated tester cache")
                self.assertEqual(fingerprint, compare.inputs(entries))
                data.write_text("time,x\n0,1\n")
                self.assertNotEqual(fingerprint, compare.inputs(entries))
                folder = compare.RESULTS / "run/Test/files"
                folder.mkdir(parents=True)
                (folder / "Test_Test.Empty.stat.json").write_text(json.dumps({"phase": 7, "diff": {"numCompared": 0}}))
                stat = compare.model_results("run")
                self.assertEqual(stat["Test", "Test.Empty"]["verifies"], "invalid (zero variables)")
                failure = folder / "Test_Test.Initialization.stat.json"
                failure.write_text(json.dumps({"phase": 5}))
                error = failure.with_name("Test_Test.Initialization.err")
                error.write_text("make [Timeout 30]\nInitialization failed")
                self.assertNotEqual(compare.model_results("run")["Test", "Test.Initialization"]["reason"], "timeout")
                error.write_text("Library test timed out after 30 seconds.")
                self.assertEqual(compare.model_results("run")["Test", "Test.Initialization"]["reason"], "timeout")
            finally:
                compare.RESULTS, compare.STATE = original, original_state

    def test_command_timeout(self):
        with tempfile.TemporaryDirectory() as temporary:
            start = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired):
                code = ("import pathlib,subprocess,sys,time; "
                        "p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],start_new_session=True); "
                        f"pathlib.Path({str(Path(temporary) / 'child.pid')!r}).write_text(str(p.pid)); time.sleep(60)")
                compare.run([sys.executable, "-c", code], Path(temporary) / "log", .5)
            self.assertLess(time.monotonic() - start, 5)
            child = (Path(temporary) / "child.pid").read_text()
            status = subprocess.run(["ps", "-o", "stat=", "-p", child], capture_output=True, text=True).stdout.strip()
            self.assertTrue(not status or status.startswith("Z"), status)


if __name__ == "__main__":
    unittest.main()
