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
HOME_DIR="$STATE/home"
LIBRARIES="$HOME_DIR/.openmodelica/libraries"
REFS="$STATE/references"
VENV="$STATE/venv"
INVENTORY="$STATE/reference-inventory.md"

usage() {
  cat <<'EOF'
Usage: deployment/setup.sh

Create or update the local deployment. Rerunning this command reuses the
virtual environment and existing Git clones, updates them, and reruns the
repository's .CI/installLibraries.mos library installer.

This command has no positional arguments. It does not build or install
OpenModelica. Without --omc, it prefers the existing sibling compiler:
  ../OpenModelica/build_cmake/install_cmake/bin/omc

Options:
  --omc PATH                   Existing omc executable, bin directory, or
                               installation prefix containing bin/omc.
  -h, --help                   Show this help.

It creates/updates:
  deployment/state/venv/                         Python requirements
  deployment/state/home/.openmodelica/libraries/ Modelica libraries
  deployment/state/references/                   Public reference results
  deployment/state/reference-inventory.md        Availability and sources
  deployment/state/logs/setup-*.log              Complete setup logs

Buildings:
  The installed maint.11.x, maint.12.x, and master packages contain public
  Dymola references. Setup converts and validates them with Buildings' own
  converter into deployment/state/references/Buildings/csv/VERSION/.

Optional environment variables:
  OPENMODELICA_SOURCE          Existing OpenModelica checkout used instead of
                               cloning its Modelica_Synchronous references.
  BUILDINGS_REFERENCE_SOURCE  Directory containing Buildings CSV directories
                               maint_11.x, maint_12.x, and master.

Examples:
  deployment/setup.sh
  deployment/setup.sh --omc /opt/openmodelica/bin/omc
  deployment/setup.sh --omc /opt/openmodelica/bin
  deployment/setup.sh --omc /opt/openmodelica
  OPENMODELICA_SOURCE=/path/to/OpenModelica deployment/setup.sh
  BUILDINGS_REFERENCE_SOURCE=/path/to/Buildings/csv deployment/setup.sh
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

OMC_REQUEST=''
while (($#)); do
  case "$1" in
    --omc)
      (($# >= 2)) || { printf 'error: --omc requires a path\n' >&2; exit 2; }
      OMC_REQUEST=$2
      shift 2
      ;;
    --omc=*)
      OMC_REQUEST=${1#*=}
      [[ -n "$OMC_REQUEST" ]] || { printf 'error: --omc requires a path\n' >&2; exit 2; }
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

if [[ -n "$OMC_REQUEST" ]]; then
  OMC_BIN="$(resolve_omc "$OMC_REQUEST")"
elif [[ -x "$SIBLING_OMC" ]]; then
  OMC_BIN=$SIBLING_OMC
elif command -v omc >/dev/null 2>&1; then
  OMC_BIN="$(resolve_omc "$(command -v omc)")"
else
  OMC_BIN=''
fi
if [[ -n "$OMC_BIN" ]]; then
  export PATH="$(dirname -- "$OMC_BIN"):$PATH"
  export OPENMODELICAHOME="$(cd -- "$(dirname -- "$OMC_BIN")/.." && pwd -P)"
fi

missing=()
for tool in python3 git omc make cc c++ tar xz find flock tee timeout diff; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if ((${#missing[@]})); then
  printf 'error: missing required commands: %s\n' "${missing[*]}" >&2
  cat >&2 <<'EOF'
Install OpenModelica, Python with venv support, Git, a C/C++ toolchain, tar,
xz-utils, coreutils, diffutils, and util-linux. On Debian/Ubuntu, the
non-OpenModelica packages are:
  sudo apt install python3-venv git build-essential tar xz-utils coreutils diffutils util-linux
OpenModelica installation: https://openmodelica.org/download/
EOF
  exit 1
fi

mkdir -p "$RESULTS" "$HOME_DIR" "$LIBRARIES" "$REFS/config/ReferenceFiles" \
  "$STATE/cache/pip" "$STATE/cache/xdg" "$STATE/config" "$STATE/data" \
  "$STATE/database" "$STATE/logs" "$STATE/runs" "$STATE/tmp/configs" \
  "$STATE/tmp/runtime" "$STATE/work"

export HOME="$HOME_DIR"
export XDG_CACHE_HOME="$STATE/cache/xdg"
export XDG_CONFIG_HOME="$STATE/config"
export XDG_DATA_HOME="$STATE/data"
export PIP_CACHE_DIR="$STATE/cache/pip"
export TMPDIR="$STATE/tmp/runtime"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log="$STATE/logs/setup-$stamp.log"
exec > >(tee -a "$log") 2>&1

printf 'Deployment state: %s\n' "$STATE"
printf 'Final results:   %s\n' "$RESULTS"
printf 'Setup log:       %s\n\n' "$log"

printf '==> Python requirements\n'
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV" || {
    printf 'error: could not create a virtual environment; install python3-venv\n' >&2
    exit 1
  }
fi
# Buildings' Spawn/EnergyPlus resource installer imports Jinja2 at runtime,
# although it is not listed in this repository's Python requirements.
"$VENV/bin/python" -m pip install --disable-pip-version-check \
  -r "$ROOT/requirements.txt" 'Jinja2>=3.1,<4'
"$VENV/bin/python" -m pip check
"$VENV/bin/python" -m pip freeze > "$STATE/python-requirements-resolved.txt"

printf '\n==> Modelica libraries (using the repository installer)\n'
printf 'Using existing omc: %s\n' "$(command -v omc)"
omc --version
omc "$ROOT/.CI/installLibraries.mos"
if ! find "$LIBRARIES" -mindepth 2 -maxdepth 2 -name package.mo -print -quit | grep -q .; then
  printf 'error: no installed Modelica packages found under %s\n' "$LIBRARIES" >&2
  exit 1
fi

inventory_tmp="$INVENTORY.tmp"
cat > "$inventory_tmp" <<EOF
# Local reference-result inventory

Generated by deployment/setup.sh at $stamp from the current configs.

| Status | Set | Expected source | Local path | Note |
|---|---|---|---|---|
EOF
missing_refs=0

inventory_add() {
  local status=${1//|/\\|}
  local name=${2//|/\\|}
  local source=${3//|/\\|}
  local path=${4//|/\\|}
  local note=${5//|/\\|}
  printf '| %s | %s | %s | %s | %s |\n' "$status" "$name" "$source" "$path" "$note" >> "$inventory_tmp"
}

has_files() {
  [[ -d "$1" ]] && [[ -n "$(find "$1" -name .git -type d -prune -o -type f -print -quit 2>/dev/null || true)" ]]
}

unpack_mat_files() {
  [[ -d "$1" ]] || return 0
  find "$1" -type f -name '*.mat.xz' -exec xz --decompress --keep --force '{}' +
}

sync_repo() {
  local url=$1 destination=$2 branch=$3 sparse=${4:-} revision
  mkdir -p "$(dirname -- "$destination")"
  if [[ -e "$destination" && ! -d "$destination/.git" ]]; then
    printf 'error: reference destination is not a Git checkout: %s\n' "$destination" >&2
    return 1
  fi
  if [[ ! -d "$destination/.git" ]]; then
    git clone --filter=blob:none --no-checkout -- "$url" "$destination" || return 1
  else
    git -C "$destination" remote set-url origin "$url"
  fi
  if [[ -n "$sparse" ]]; then
    git -C "$destination" sparse-checkout init --cone || return 1
    git -C "$destination" sparse-checkout set -- "$sparse" || return 1
  elif [[ -f "$destination/.git/info/sparse-checkout" ]]; then
    git -C "$destination" sparse-checkout disable || return 1
  fi
  git -C "$destination" fetch --prune origin || return 1
  if [[ "$branch" == HEAD ]]; then
    revision=origin/HEAD
  elif [[ "$branch" == origin/* ]]; then
    revision=$branch
  else
    revision="origin/$branch"
  fi
  git -C "$destination" rev-parse --verify "$revision^{commit}" >/dev/null || return 1
  git -C "$destination" checkout --force --detach "$revision" || return 1
  git -C "$destination" clean -fdx -e '*.hash' || return 1
  unpack_mat_files "$destination"
}

record_repo() {
  local name=$1 url=$2 destination=$3 branch=$4 sparse=${5:-}
  local data_path="$destination" branch_label=$branch
  [[ -z "$sparse" ]] || data_path="$destination/$sparse"
  if [[ "$branch" == HEAD ]]; then
    branch_label="$(git -C "$destination" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || printf 'remote default')"
    branch_label=${branch_label#origin/}
  else
    branch_label=${branch_label#origin/}
  fi
  if sync_repo "$url" "$destination" "$branch" "$sparse"; then
    if [[ "$branch" == HEAD ]]; then
      branch_label="$(git -C "$destination" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || printf 'remote default')"
      branch_label=${branch_label#origin/}
    fi
    inventory_add available "$name" "$url (branch $branch_label)" "$data_path" "commit $(git -C "$destination" rev-parse --short HEAD)"
  elif has_files "$data_path"; then
    inventory_add 'available (cached)' "$name" "$url (branch $branch_label)" "$data_path" 'update failed; cached files retained'
  else
    inventory_add unavailable "$name" "$url (branch $branch_label)" "$data_path" "clone/update failed; see $log"
    missing_refs=$((missing_refs + 1))
  fi
}

printf '\n==> Public reference results declared directly as Git repositories\n'
while IFS='|' read -r url destination branch sparse; do
  record_repo "$destination" "$url" "$REFS/config/$destination" "$branch" "$sparse"
done < <("$VENV/bin/python" - "$ROOT/configs" <<'PY'
import glob, json, os, sys
records = {}
for filename in glob.glob(os.path.join(sys.argv[1], "*.json")):
    with open(filename, encoding="utf-8") as handle:
        for item in json.load(handle):
            ref = item.get("referenceFiles")
            if not isinstance(ref, dict):
                continue
            row = (ref["giturl"], ref["destination"], ref.get("git-ref", "HEAD"), ref.get("git-directory", ""))
            old = records.setdefault(ref["destination"], row)
            if old != row:
                raise SystemExit(f"conflicting reference destination {ref['destination']}: {old} != {row}")
for row in sorted(records.values(), key=lambda value: value[1]):
    if any("|" in value or "\n" in value for value in row):
        raise SystemExit(f"unsupported character in reference declaration: {row}")
    print("|".join(row))
PY
)

copy_tree() {
  local source=$1 destination=$2 temporary
  [[ -d "$source" ]] || return 1
  temporary="$(mktemp -d "$STATE/tmp/reference.XXXXXX")"
  cp -a -- "$source/." "$temporary/"
  rm -rf -- "$destination"
  mkdir -p "$(dirname -- "$destination")"
  mv -- "$temporary" "$destination"
  unpack_mat_files "$destination"
}

sync_modelica_synchronous() {
  local source_checkout="${OPENMODELICA_SOURCE:-$ROOT/../OpenModelica}"
  local source_dir
  if [[ -d "$source_checkout/testsuite/ReferenceFiles/Modelica_Synchronous" ]]; then
    source_dir="$source_checkout/testsuite/ReferenceFiles/Modelica_Synchronous"
  else
    source_checkout="$REFS/sources/OpenModelica"
    sync_repo 'https://github.com/OpenModelica/OpenModelica.git' "$source_checkout" master \
      'testsuite/ReferenceFiles/Modelica_Synchronous' || return 1
    source_dir="$source_checkout/testsuite/ReferenceFiles/Modelica_Synchronous"
  fi
  copy_tree "$source_dir" "$REFS/openmodelica/ReferenceFiles/Modelica_Synchronous"
}

sync_msl_reference() {
  local version=$1
  local mirror="$REFS/sources/MAP-LIB_ReferenceResults.git"
  local destination="$REFS/msl/MAP-LIB_ReferenceResults/$version"
  local temporary revision
  mkdir -p "$(dirname -- "$mirror")"
  if [[ ! -d "$mirror" ]]; then
    git clone --mirror -- 'https://github.com/modelica/MAP-LIB_ReferenceResults.git' "$mirror" || return 1
  fi
  git --git-dir="$mirror" remote update --prune || true
  revision="$(git --git-dir="$mirror" rev-parse --verify "$version^{commit}" 2>/dev/null)" || return 1
  temporary="$(mktemp -d "$STATE/tmp/msl.XXXXXX")"
  if ! git --git-dir="$mirror" archive "$revision" | tar -xf - -C "$temporary"; then
    rm -rf -- "$temporary"
    return 1
  fi
  printf '%s\n' "$revision" > "$temporary/commit"
  rm -rf -- "$destination"
  mkdir -p "$(dirname -- "$destination")"
  mv -- "$temporary" "$destination"
}

build_buildings_csv() {
  local branch=$1 destination=$2
  local package_branch=${branch//_/.}
  local package_dir source_dir converter temporary source_sha source_key

  validate_buildings_csv_set() {
    "$VENV/bin/python" - "$1" <<'PY'
import csv, glob, os, sys

root = sys.argv[1]
files = sorted(glob.glob(os.path.join(root, "*.csv")))
if not files:
    raise SystemExit(f"no Buildings CSV reference files found in {root}")

total_variables = 0
for filename in files:
    try:
        with open(filename, newline="", encoding="utf-8") as handle:
            reader = csv.reader(handle, strict=True)
            header = next(reader)
            if len(header) < 2 or header[0].strip() != "time":
                raise ValueError("expected a comma-separated header beginning with time and at least one result variable")
            if any(not name.strip() for name in header):
                raise ValueError("header contains an empty variable name")
            if len(set(header)) != len(header):
                raise ValueError("header contains duplicate variable names")
            rows = 0
            for row_number, row in enumerate(reader, 2):
                if len(row) != len(header):
                    raise ValueError(
                        f"row {row_number} has {len(row)} columns; expected {len(header)}"
                    )
                try:
                    for value in row:
                        float(value)
                except ValueError as error:
                    raise ValueError(f"row {row_number} contains a non-numeric value") from error
                rows += 1
            if rows == 0:
                raise ValueError("file has no data rows")
            total_variables += len(header) - 1
    except (OSError, UnicodeError, csv.Error, StopIteration, ValueError) as error:
        raise SystemExit(f"invalid Buildings reference CSV {filename}: {error}")

print(f"Validated {len(files)} Buildings CSV files containing {total_variables} result-variable columns")
PY
  }

  if [[ -n "${BUILDINGS_REFERENCE_SOURCE:-}" ]]; then
    [[ -d "$BUILDINGS_REFERENCE_SOURCE/$branch" ]] || {
      printf 'Buildings reference source directory does not exist: %s\n' "$BUILDINGS_REFERENCE_SOURCE/$branch" >&2
      return 1
    }
    temporary="$(mktemp -d "$STATE/tmp/buildings-csv.XXXXXX")"
    cp -a -- "$BUILDINGS_REFERENCE_SOURCE/$branch/." "$temporary/"
    if ! validate_buildings_csv_set "$temporary"; then
      rm -rf -- "$temporary"
      return 1
    fi
    rm -rf -- "$destination"
    mkdir -p "$(dirname -- "$destination")"
    mv -- "$temporary" "$destination"
    BUILDINGS_NOTE="copied from BUILDINGS_REFERENCE_SOURCE/$branch"
    return
  fi

  package_dir="$(find "$LIBRARIES" -mindepth 1 -maxdepth 1 -type d \
    \( -name "Buildings $package_branch" -o -name "Buildings *-$package_branch" \) \
    -print | sort | tail -n 1)"
  [[ -n "$package_dir" ]] || {
    printf 'no installed Buildings package found for branch %s under %s\n' "$branch" "$LIBRARIES" >&2
    return 1
  }
  source_dir="$package_dir/Resources/ReferenceResults/Dymola"
  converter="$package_dir/Resources/Scripts/JModelica/buildingspy_to_csv.py"
  [[ -d "$source_dir" && -f "$converter" ]] || {
    printf 'Buildings %s lacks its public reference files or CSV converter\n' "$branch" >&2
    return 1
  }

  source_sha="$("$VENV/bin/python" - "$package_dir/openmodelica.metadata.json" <<'PY'
import hashlib, sys
try:
    with open(sys.argv[1], "rb") as handle:
        print(hashlib.sha256(handle.read()).hexdigest())
except OSError:
    print("unknown")
PY
)"
  # Bump this key whenever the generated CSV representation changes.
  source_key="$source_sha:openmodelica-csv-v2"
  if [[ -f "$destination/.source-sha" ]] \
      && [[ "$(cat "$destination/.source-sha")" == "$source_key" ]] \
      && find "$destination" -maxdepth 1 -name '*.csv' -print -quit | grep -q .; then
    if validate_buildings_csv_set "$destination"; then
      BUILDINGS_NOTE="generated from installed $branch package; unchanged source $source_sha"
      return
    fi
    printf 'Existing Buildings %s reference set is invalid; regenerating it.\n' "$branch" >&2
  fi

  temporary="$(mktemp -d "$STATE/tmp/buildings-csv.XXXXXX")"
  if ! "$VENV/bin/python" - "$converter" "$source_dir" "$temporary" <<'PY'
import csv, glob, importlib.util, os, sys
converter, source, destination = sys.argv[1:]
spec = importlib.util.spec_from_file_location("buildings_reference_converter", converter)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
created = 0
for filename in glob.glob(os.path.join(source, "*.txt")):
    output = os.path.join(destination, os.path.splitext(os.path.basename(filename))[0] + ".csv")
    intermediate = output + ".semicolon"
    module._write_csv(intermediate, module._read_reference_result(filename))
    if not os.path.isfile(intermediate):
        continue
    with open(intermediate, newline="", encoding="utf-8") as source_csv:
        rows = list(csv.reader(source_csv, delimiter=";", skipinitialspace=True))
    os.unlink(intermediate)
    if not rows or len(rows[0]) < 2 or rows[0][0].strip() != "time":
        continue
    with open(output, "w", newline="", encoding="utf-8") as output_csv:
        csv.writer(output_csv, lineterminator="\n").writerows(rows)
    created += 1
print(f"Converted {created} Buildings reference files from {source}")
raise SystemExit(0 if created else 1)
PY
  then
    rm -rf -- "$temporary"
    return 1
  fi
  if ! validate_buildings_csv_set "$temporary"; then
    rm -rf -- "$temporary"
    return 1
  fi
  printf '%s\n' "$source_key" > "$temporary/.source-sha"
  rm -rf -- "$destination"
  mkdir -p "$(dirname -- "$destination")"
  mv -- "$temporary" "$destination"
  BUILDINGS_NOTE="generated with the Buildings package's buildingspy_to_csv.py; source $source_sha"
}

printf '\n==> Environment/path-based reference results used by configs\n'
while IFS= read -r reference; do
  case "$reference" in
    '$MSLREFERENCE/MAP-LIB_ReferenceResults/'*)
      version="$(basename -- "$reference")"
      destination="$REFS/msl/MAP-LIB_ReferenceResults/$version"
      if sync_msl_reference "$version"; then
        inventory_add available "MSL $version" 'https://github.com/modelica/MAP-LIB_ReferenceResults.git' "$destination" 'branch/tag extracted locally'
      elif has_files "$destination"; then
        inventory_add 'available (cached)' "MSL $version" 'https://github.com/modelica/MAP-LIB_ReferenceResults.git' "$destination" 'update failed; cached files retained'
      else
        inventory_add unavailable "MSL $version" 'https://github.com/modelica/MAP-LIB_ReferenceResults.git' "$destination" "fetch/extraction failed; see $log"
        missing_refs=$((missing_refs + 1))
      fi
      ;;
    '$REFERENCEFILES/Modelica_Synchronous')
      destination="$REFS/openmodelica/ReferenceFiles/Modelica_Synchronous"
      if sync_modelica_synchronous; then
        inventory_add available Modelica_Synchronous 'existing ../OpenModelica, or https://github.com/OpenModelica/OpenModelica.git' "$destination" 'copied into deployment state'
      elif has_files "$destination"; then
        inventory_add 'available (cached)' Modelica_Synchronous 'https://github.com/OpenModelica/OpenModelica.git' "$destination" 'update failed; cached files retained'
      else
        inventory_add unavailable Modelica_Synchronous 'https://github.com/OpenModelica/OpenModelica.git' "$destination" "source copy/checkout failed; see $log"
        missing_refs=$((missing_refs + 1))
      fi
      ;;
    '$PNLIBREFS')
      record_repo PNlib 'https://github.com/AMIT-HSBI/PNlib.git' "$REFS/PNlib" master
      ;;
    '$THERMOFLUIDSTREAMREFS')
      record_repo ThermofluidStream 'https://github.com/DLR-SR/ThermoFluidStream-Regression.git' "$REFS/ThermoFluidStream-main-regression" main
      ;;
    '$MY_SANITY_CHECK_DIRECTORY/ReferenceFiles')
      destination="$REFS/sanityCheck/ReferenceFiles"
      if copy_tree "$ROOT/sanityCheck/ReferenceFiles" "$destination"; then
        inventory_add available sanityCheck "$ROOT/sanityCheck/ReferenceFiles" "$destination" 'copied from this checkout'
      else
        inventory_add unavailable sanityCheck "$ROOT/sanityCheck/ReferenceFiles" "$destination" 'source files are missing'
        missing_refs=$((missing_refs + 1))
      fi
      ;;
    /mnt/ReferenceFiles/Buildings/csv/*)
      version="$(basename -- "$reference")"
      destination="$REFS/Buildings/csv/$version"
      if build_buildings_csv "$version" "$destination"; then
        inventory_add available "Buildings $version" 'public reference data shipped in the installed Buildings package' "$destination" "$BUILDINGS_NOTE"
      else
        inventory_add unavailable "Buildings $version" 'installed Buildings package Resources/ReferenceResults/Dymola' "$destination" "automatic conversion failed; see $log or set BUILDINGS_REFERENCE_SOURCE"
        missing_refs=$((missing_refs + 1))
      fi
      ;;
    *)
      inventory_add unavailable "$reference" "$reference" "$REFS/unresolved" 'no automatic source is declared by the config'
      missing_refs=$((missing_refs + 1))
      ;;
  esac
done < <("$VENV/bin/python" - "$ROOT/configs" <<'PY'
import glob, json, os, sys
values = set()
for filename in glob.glob(os.path.join(sys.argv[1], "*.json")):
    with open(filename, encoding="utf-8") as handle:
        for item in json.load(handle):
            ref = item.get("referenceFiles")
            if isinstance(ref, str):
                values.add(ref)
for value in sorted(values):
    print(value)
PY
)

cat >> "$inventory_tmp" <<'EOF'

THERMOFLUIDSTREAMREFSOM is exported by the run wrapper for compatibility, but
no current configs entry uses it, so setup does not download it.
EOF
mv -- "$inventory_tmp" "$INVENTORY"

cat > "$STATE/setup.complete" <<EOF
completed=$stamp
repository=$ROOT
commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf unknown)
omc=$(omc --version | head -n 1)
omc_executable=$(command -v omc)
libraries=$LIBRARIES
inventory=$INVENTORY
missing_references=$missing_refs
log=$log
EOF

printf '\nSetup complete.\n'
printf 'Reference inventory: %s\n' "$INVENTORY"
printf 'Try: %s/run.sh master --library Modelica --version 4.1.0\n' "$DEPLOYMENT"
if ((missing_refs)); then
  printf 'warning: %d reference set(s) are unavailable; see the inventory. Tests still run, but affected models are not reference-verified.\n' "$missing_refs"
fi
