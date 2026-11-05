# Local deployment

This directory is a small local interface around the repository's existing
library-testing tools. It does not replace their logic: setup calls
`.CI/installLibraries.mos`, and runs call the current `test.py` and `report.py`
with a temporary filtered copy of `configs/conf.json`.

## Fresh-machine setup

Install Python 3 with `venv`, Git, a C/C++ toolchain, `make`, `tar`, `xz`,
`timeout`, `diff`, `ps`, and `flock`, then run:

```sh
deployment/setup.sh
```

By default, setup automatically detects the sibling build at
`../OpenModelica/build_cmake/install_cmake/bin/omc`, which resolves in
this checkout to:

```text
/home/linus/Projects/OpenModelica/build_cmake/install_cmake/bin/omc
```

An explicit executable, `bin` directory, or installation prefix can be used:

```sh
deployment/setup.sh --omc /path/to/install/bin/omc
deployment/setup.sh --omc /path/to/install/bin
deployment/setup.sh --omc /path/to/install
```

Setup records the resolved executable and `run.sh` reuses it. Pass
`--omc PATH` to `run.sh` only to override that recorded compiler for a run.

Setup is idempotent: it reuses the deployment virtual environment and Git
checkouts, updates public references, and reruns the upstream library installer.
It also installs Jinja2, which the Buildings Spawn/EnergyPlus preparation
script needs but the repository's main `requirements.txt` does not declare. It
never clones this `OpenModelicaLibraryTesting` checkout.

## Runs

The default is two parallel tests, suitable for a laptop:

```sh
# Standard nightly configuration, all libraries
deployment/run.sh master

# All four predefined configurations, followed by a report
deployment/run.sh all --jobs 4

# One library, or one precise configured version
deployment/run.sh master --library Buildings --version master --jobs 2 --require-references
deployment/run.sh master --library Modelica --version 4.1.0

# Force execution even when the database/config hash says it is unchanged
deployment/run.sh master --library BoundaryInitBlocks --force
```

Add `--require-references` to a reference-backed run to stop during preflight
instead of spending time testing without a usable selected reference set.

After an interrupted named run, repeat the same command with `--resume`. It
validates that the effective configuration is unchanged, preserves finalized
model files in the scratch directory, executes only unfinished models, and then
publishes the complete result. Use `--force` when a complete rerun is intended;
it clears the scratch files and executes every selected model.

The predefined jobs are `master`, `gbode`, `cvode`, and `ida`. Their compiler
and runtime settings match the jobs in `.CI/Jenkinsfile`. `all` runs those four
in sequence. Use `--name NAME` for a separate result/database branch; for
`all`, it becomes the prefix (`NAME-master`, `NAME-gbode`, and so on).

Extra flags are appended to the preset, without replacing it:

```sh
deployment/run.sh gbode --library Buildings --version maint.12.x \
  --compiler-flags "--newBackend" \
  --runtime-flags "-lv=LOG_STATS" \
  --jobs 2 --name buildings-gbode --force
```

`--library NAME` may be repeated. `--version VERSION` filters the selected
library entries, and `default` selects a config entry without an explicit
`libraryVersion`. The wrapper rejects unknown libraries, versions, options,
and invalid job counts before starting `test.py`. Run `deployment/run.sh
--help` for the full interface.

## Reports and outputs

Create an overview from the latest standard job tables, or from a named run:

```sh
deployment/run.sh report
deployment/run.sh report --name buildings-gbode --library Buildings \
  --version maint.12.x
```

`report` does not execute models. It calls the existing `report.py` on results
already stored by `test.py` and writes `deployment/results/overview.html`.
The overview compares selected jobs and links to their standard per-library
HTML; it includes model/phase counts, timings, OpenModelica versions, run
dates, and verification differences.

Common report workflows:

```sh
# Run one standard job, then report only Buildings from it
deployment/run.sh master --library Buildings --version master
deployment/run.sh report --library Buildings --version master

# Give a run its own database/result name, then report that exact name
deployment/run.sh gbode --name buildings-gbode \
  --library Buildings --version maint.12.x
deployment/run.sh report --name buildings-gbode \
  --library Buildings --version maint.12.x

# Run all four presets; this automatically creates the overview afterward
deployment/run.sh all --jobs 2
```

All generated data stays below this directory:

| Location | Contents |
|---|---|
| `deployment/state/home/.openmodelica/libraries/` | Installed Modelica libraries |
| `deployment/state/venv/` | Python environment and requirements |
| `deployment/state/references/` | Downloaded/generated reference results |
| `deployment/state/reference-inventory.md` | Available/unavailable reference inventory with source and reason |
| `deployment/state/database/sqlite3.db` | Shared test/report database |
| `deployment/state/logs/` | Timestamped setup, test, and report logs |
| `deployment/state/runs/NAME/` | Effective config and exact invocation for a run |
| `deployment/state/work/` | Isolated working directory used by upstream scripts |
| `deployment/state/tmp/` | Temporary configs and runtime files |
| `deployment/results/NAME/` | Per-library HTML, error files, plots, and other test results |
| `deployment/results/overview.html` | Latest generated overview report |
| `deployment/results/effective-report-config.json` | Config used for that overview |

## Reference results, including Buildings

Setup discovers reference declarations from all current `configs/*.json`. It
downloads the public Git repositories, extracts the Modelica Standard Library
sets, copies Modelica_Synchronous data from the sibling OpenModelica checkout
(or downloads that subdirectory), and prepares the other environment-variable
sets used by the configs.

The Buildings config currently names Jenkins-machine paths below
`/mnt/ReferenceFiles/Buildings/csv/`. Those paths are never used locally.
Installed Buildings packages contain public Dymola reference results and the
project's `buildingspy_to_csv.py`; setup uses that converter and writes its
data in the comma-separated format understood by OpenModelica to create the
version-specific CSV sets under:

```text
deployment/state/references/Buildings/csv/maint_11.x/
deployment/state/references/Buildings/csv/maint_12.x/
deployment/state/references/Buildings/csv/master/
```

Setup validates every generated Buildings CSV before making the set available.
`run.sh` validates it again before forwarding the temporary config to `test.py`.
Malformed or unavailable references are omitted, which leaves verification
empty while compilation and simulation still run. After `test.py` finishes,
the wrapper rejects any impossible green result that compared zero variables;
the standard HTML remains available for diagnosis, but the command returns an
error instead of silently presenting it as valid verification.

Every run rewrites only the temporary config to those absolute local paths;
the upstream configs remain unchanged. If an installed Buildings package does
not provide the data/converter, setup records the failure and expected source
in `deployment/state/reference-inventory.md`. A prebuilt set can instead be
provided with `BUILDINGS_REFERENCE_SOURCE=/path/containing/the/three/sets`.

Reference downloads that fail do not hide the problem: setup keeps usable
cached data when possible and records unavailable sets, the reason, expected
source, and local destination in the inventory. Tests can still run without a
reference set, but affected models will not be reference-verified. `run.sh`
omits unusable references only from its temporary config, allowing the existing
`test.py` to finish and create its standard HTML with verification left empty.

## Compare two compiler revisions

`compare.py` builds two committed OpenModelica revisions and runs the existing
library tester with the same libraries, references and settings on both. The
default matrix is **Modelica 4.1.0 and Buildings master (`Buildings_latest`)**,
using **CVODE and GBODE Radau IIA3**, first on the baseline and then the candidate.

From this repository's `deployment` branch, in a terminal or byobu session:

```sh
deployment/compare.py \
  --repo ../OpenModelica \
  --baseline origin/master \
  --candidate fix/spatialdistribution/stages \
  --name spatial \
  --build-jobs 8 --jobs 8
```

The source checkout must contain both commits, and they must be different. Add `--fetch` to update `origin`
before starting, or fetch a PR explicitly and pass its ref/commit as the
candidate. Uncommitted source changes are not included. The runner creates
independent clones; it does not switch branches or create Git worktrees in the
source checkout. Both use `build_cmake`, the `install` target, Release mode,
and disabled GUI clients, OMSimulator and C++ runtime. Build commands run
sequentially with at most eight jobs. `--build-root /srv/om-builds` chooses where
those compiler clones and builds live; `--cmake-arg=-DOPTION=VALUE` adds a CMake
option equally to both builds. Build dependencies must already be installed.

The first invocation calls `setup.sh` once if deployment has not been set up.
Otherwise it reuses the installed libraries and reference sets. Do not update
libraries or run setup during the comparison. Modelica sources, package
metadata, selected reference files, compiler installations, harness code and
settings are fingerprinted. Resume rejects changed inputs; moving branch names
continue to use the original pinned commits.

Useful variations:

```sh
# CVODE alone, or all four solvers
deployment/compare.py --repo ../OpenModelica --candidate my-branch \
  --name cvode-check --solvers cvode
deployment/compare.py --repo ../OpenModelica --candidate my-branch \
  --name all-solvers --solvers dassl,ida,cvode,gbode-radauIIA3

# Explicit libraries/versions; --library is repeatable
deployment/compare.py --repo ../OpenModelica --candidate my-branch \
  --name buildings-only --library Buildings:master

# Use two existing installations, without building either
deployment/compare.py --name installed-check \
  --baseline-omc /srv/master/build_cmake/install_cmake \
  --candidate-omc /srv/pr/build_cmake/install_cmake

# Resume with the original arguments and name, or regenerate only the tables
deployment/compare.py --repo ../OpenModelica --candidate my-branch \
  --name spatial --build-jobs 8 --jobs 8 --resume
deployment/compare.py --name spatial --report-only
```

Every compiler/solver combination has separate scratch files and a result name
such as `spatial-baseline-cvode` or `spatial-candidate-gbode-radauIIA3`. Completed
combinations are skipped on resume; the interrupted one uses `run.sh --resume`.
An existing comparison name is never silently overwritten. Defaults allow two
parallel model tests; `--jobs` accepts 1–8. Per-model compilation remains one
job, matching the library tester's default. Model translation and simulation
timeouts come from the selected library config. `--build-timeout` (default two
hours per command) and `--run-timeout` (default 24 hours per combination) bound
the orchestration; interrupted commands and their descendants are terminated, including model
workers that start separate process sessions.

Use `--compiler-flags='...'` and `--runtime-flags='...'` to configure both
compilers equally. The default compiler flag is `--simCodeTarget=C`; each solver
uses the neutral `master` preset with an explicit runtime selection, avoiding
other nightly solver presets. The Radau flags are
`-s=gbode -gbm=radauIIA3 -gbnls=internal`. Add custom configurations with, for
example, `--solver 'gbode-esdirk4=-s=gbode -gbm=esdirk4 -gbnls=internal'`.
`--solvers ''` suppresses the built-in configurations when using only custom
ones. `--config PATH` selects another library configuration file.

Outputs for `--name spatial`:

| Location | Contents |
|---|---|
| `deployment/results/comparisons/spatial/summary.md` | Counts, common-model speedup and paired per-model results |
| `deployment/results/comparisons/spatial/models.csv` | Paired status, simulation/build/total times, reasons and failing variables |
| `deployment/results/comparisons/spatial/manifest.json` | Exact commits, flags, compiler versions, fingerprints and completed combinations |
| `deployment/results/spatial-overview.html` | Existing HTML overview for all selected combinations |
| `deployment/results/spatial-{baseline,candidate}-SOLVER/` | Existing detailed library reports and diagnostics |
| `deployment/state/comparisons/spatial/` | Build/test logs, pinned config, resumable scratch files and default compiler builds |

Commands and log locations are printed as they start. Follow the indicated log
with `tail -f` in another byobu window for detailed compiler/model progress.

"Simulates" means the simulation completed; "verifies" additionally requires
a successful reference comparison with at least one compared variable. Missing
per-model references are shown as **no reference**, not verification passes.
Both runs use the existing native library references and comparison tolerances;
no references or tolerances are changed. The configured experiment models and
exclusions are the same as the nightly tests. A model/reference failure does not
stop the matrix; an infrastructure error does, preserving partial reports and
allowing resume. Speedup compares simulation time on the common completed
models only. Total execution time also includes failed attempts and timeouts.
Each model is translated by OMC and compiled by the C compiler **once per
compiler revision**, then its executable is reused for every solver configuration.
The cache lives in `deployment/state/comparisons/NAME/model-cache/{baseline,candidate}/`.
The original build directory is retained and never used for simulation, so
initialization failures and runtime
timeouts do not lose the executable. Completed translation/compilation failures
are also reused. Interrupted builds without a completed cache record are retried.
Each solver gets a fresh copy of the build artifacts in its own working directory;
result files and reference comparisons are never reused. Later solver runs report
zero compilation time and `build_reused=True` in the CSV. The original build
cost remains in the first solver's results and the cached build record. The same
rules apply when resuming an interrupted comparison. These caches belong to the
pinned comparison and cannot be shared with different inputs or compilers.

The existing tester records the selected reference filename and writes explicit
timeout diagnostics; configured timeout
limits printed in ordinary logs are not treated as failures.

The deployment wrapper also accepts `--config PATH`, `--work-dir PATH`, and
`report --branches 'NAME1 NAME2 ...'` independently of the comparison runner.

Run the small offline orchestration tests with:

```sh
python3 deployment/test_compare.py
```
