# Local deployment

This directory is a small local interface around the repository's existing
library-testing tools. It does not replace their logic: setup calls
`.CI/installLibraries.mos`, and runs call the current `test.py` and `report.py`
with a temporary filtered copy of `configs/conf.json`.

## Fresh-machine setup

Install Python 3 with `venv`, Git, a C/C++ toolchain, `make`, `tar`, `xz`,
`timeout`, `diff`, and `flock`, then run:

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
