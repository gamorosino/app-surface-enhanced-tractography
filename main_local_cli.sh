#!/usr/bin/env bash
set -euo pipefail

# Build config.json from --<key> <value> flags, then run ./main_local.sh.
#
# Mirrors main_cli.sh but targets the local (non-Singularity) runner.
# Every "--foo bar" pair is written into config.json as "foo": bar, with the
# value type auto-detected (true/false -> boolean, numeric -> number, else string).
#
# Example:
#   ./main_local_cli.sh \
#     --freesurfer /mnt/s3/archive/.../output \
#     --fa /mnt/s3/archive/.../fa.nii.gz \
#     --t1 /mnt/s3/archive/.../t1.nii.gz \
#     --mask_5tt /mnt/s3/archive/.../mask.nii.gz \
#     --fodf_lmax8 /mnt/s3/archive/.../lmax8.nii.gz \
#     --fodf_response /mnt/s3/archive/.../response.txt \
#     --random_seeds "1,2,...,32" \
#     --max_parallel_seeds 32 \
#     --output_dir run_100206_32seeds
#
# Pass --dry-run to only generate and print config.json without executing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_OUT="config.json"
CONFIG_OUT_SET=0
OUTDIR=""
DRY_RUN=0
declare -a JSON_FRAGMENTS=()

usage() {
  cat <<'EOF'
Usage: ./main_local_cli.sh --<key> <value> [--<key> <value> ...] [--config PATH] [--dry-run]

Any --<key> <value> pair becomes a "<key>": <value> entry in config.json.

Required keys:
  --freesurfer --fa --t1 --mask_5tt

Optional keys (skip the corresponding computation when given):
  --fodf_lmax8 --fodf_response
  --t1_warp --t1_inv_warp --t1_affine   (all three required together)

Tunable:
  --random_seeds        comma-separated seed list, e.g. "1,2,3,...,32"
  --nb_iter             number of SET iterations (default 1)
  --nb_seeds            seeds per iteration (default 500000)
  --max_parallel_seeds  concurrent tracking containers (default = # seeds)
  --tracking_processes  parallel sub-processes inside each container (default 1)
                        composes with max_parallel_seeds:
                          8 seeds × 4 processes = 32 CPUs total
  --linear_transformation  true/false — skip nonlinear SyN stage

Options:
  --config PATH     write generated config to PATH (default: <OUTDIR>/config.json
                    when --output_dir is set, else ./config.json)
  --output_dir DIR  run main_local.sh from inside DIR so outputs land there
  --dry-run         only generate and print config.json; do not execute
  -h, --help        show this help
EOF
}

to_json_fragment() {
  local key="$1" value="$2"
  if [[ -e "$value" ]]; then
    value="$(realpath "$value")"
  fi
  jq -n --arg k "$key" --arg v "$value" '
    if ($v == "true") then {($k): true}
    elif ($v == "false") then {($k): false}
    elif ($v | test("^-?[0-9]+$")) then {($k): ($v | tonumber)}
    elif ($v | test("^-?[0-9]*\\.[0-9]+$")) then {($k): ($v | tonumber)}
    else {($k): $v}
    end
  '
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --config)
      [[ $# -ge 2 ]] || { echo "ERROR: missing value for --config" >&2; exit 1; }
      CONFIG_OUT="$2"
      CONFIG_OUT_SET=1
      shift 2
      ;;
    --output_dir)
      [[ $# -ge 2 ]] || { echo "ERROR: missing value for --output_dir" >&2; exit 1; }
      OUTDIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --*=*)
      key="${1#--}"
      value="${key#*=}"
      key="${key%%=*}"
      JSON_FRAGMENTS+=("$(to_json_fragment "$key" "$value")")
      shift
      ;;
    --*)
      key="${1#--}"
      if [[ $# -ge 2 && "$2" != --* ]]; then
        value="$2"
        shift 2
      else
        value="true"
        shift
      fi
      JSON_FRAGMENTS+=("$(to_json_fragment "$key" "$value")")
      ;;
    *)
      echo "ERROR: unrecognized argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ${#JSON_FRAGMENTS[@]} -eq 0 ]]; then
  echo "ERROR: no --<key> <value> config options provided" >&2
  usage
  exit 1
fi

if [[ -n "${OUTDIR}" ]]; then
  mkdir -p "${OUTDIR}"
  OUTDIR="$(cd "${OUTDIR}" && pwd)"
  if [[ "${CONFIG_OUT_SET}" -eq 0 ]]; then
    CONFIG_OUT="${OUTDIR}/config.json"
  fi
fi

printf '%s\n' "${JSON_FRAGMENTS[@]}" | jq -s 'add' > "${CONFIG_OUT}"
CONFIG_OUT="$(realpath "${CONFIG_OUT}")"

echo "Wrote ${CONFIG_OUT}:"
cat "${CONFIG_OUT}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo
  echo "Dry run: not executing ./main_local.sh."
  exit 0
fi

if [[ -n "${OUTDIR}" ]]; then
  echo
  echo "Running ./main_local.sh in ${OUTDIR} ..."
  ( cd "${OUTDIR}" && CONFIG="${CONFIG_OUT}" bash "${SCRIPT_DIR}/main_local.sh" )
else
  echo
  echo "Running ./main_local.sh with CONFIG=${CONFIG_OUT} ..."
  CONFIG="${CONFIG_OUT}" bash "${SCRIPT_DIR}/main_local.sh"
fi
