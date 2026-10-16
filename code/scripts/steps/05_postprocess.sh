#!/usr/bin/env bash
# Post-process SET tractograms: VTK→TCK, flip axes, concatenate 8 runs.
# Runs inside docker://gamorosino/ensemble_tracking:latest (mrtrix3 + python).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utils/qc_json.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Post-process SET tractograms for one subject.

Required:
  --subject <sub>    Full subject string (e.g., sub-100206)
  --set-dir <dir>    SET output directory containing *_filtered.fib files

Optional:
  --flip-axes <str>  Axes to flip [x,y]
  --qc-json <path>   Append a "postprocess" stage to this QC json (see
                      code/scripts/utils/qc_json.sh). Skipped if omitted.
  -h, --help         Show this help and exit

Output:
  <set-dir>/all_sets_flipXY_concatenated.tck
EOF
}

# --- Defaults ----------------------------------------------------------------
subject=""
set_dir=""
flip_axes="x,y"
qc_json=""

# ET_IMAGE_DOCKER env var (set by main_local.sh) switches to Docker mode.
ET_IMAGE="${ET_IMAGE_DOCKER:-docker://gamorosino/ensemble_tracking:latest}"
_USE_DOCKER=false
[[ -n "${ET_IMAGE_DOCKER:-}" ]] && _USE_DOCKER=true

# --- Parse -------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --subject)    subject="$2";    shift 2 ;;
        --set-dir)    set_dir="$2";    shift 2 ;;
        --flip-axes)  flip_axes="$2";  shift 2 ;;
        --qc-json)    qc_json="$2";    shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

[[ -z "$subject" ]] && { echo "ERROR: --subject is required"; exit 1; }
[[ -z "$set_dir" ]] && { echo "ERROR: --set-dir is required"; exit 1; }
[[ ! -d "$set_dir" ]] && { echo "ERROR: set-dir not found: $set_dir"; exit 1; }

# ---------------------------------------------------------------------------
_utils_dir="$(cd "${SCRIPT_DIR}/../utils" && pwd)"
et_exec() {
    if [[ "$_USE_DOCKER" == true ]]; then
        docker run --rm \
            --user "$(id -u):$(id -g)" \
            -v "${set_dir}:${set_dir}" \
            -v "${_utils_dir}:${_utils_dir}" \
            -v /tmp:/tmp \
            -w "${set_dir}" \
            -e HOME=/tmp \
            "$ET_IMAGE" "$@"
    else
        ( cd /tmp && singularity exec --cleanenv \
            -B "${set_dir}:${set_dir}" \
            -B "${_utils_dir}:${_utils_dir}" \
            "$ET_IMAGE" "$@" )
    fi
}

final="${set_dir}/all_sets_flipXY_concatenated.tck"

cd "$set_dir"
echo "Post-processing tractograms for ${subject}"
_ts_pp_start=$(qc_timestamp); _t0_pp=$(qc_epoch)

# 1. Rename .fib → .vtk
for f in "${subject}__set_"*"_filtered.fib"; do
    cp "$f" "${f%.fib}.vtk"
done

# 2. Convert VTK → TCK (parallel)
_pp_pids=()
for f in "${subject}__set_"*"_filtered.vtk"; do
    base="${f%.vtk}"
    et_exec tckconvert "${set_dir}/${f}" "${set_dir}/${base}.tck" -force \
        >>"${set_dir}/pp_convert_${base}.log" 2>&1 &
    _pp_pids+=("tckconvert_${base}:$!")
done
for spec in "${_pp_pids[@]}"; do
    label="${spec%%:*}"; pid="${spec#*:}"
    wait "$pid" || { echo "ERROR: ${label} failed" >&2; exit 1; }
done

# 3. Flip axes (parallel — all TCK files ready now)
flip_script="$(realpath "${SCRIPT_DIR}/../utils/flip_tractogram.py")"
_pp_pids=()
for f in "${subject}__set_"*"_filtered.tck"; do
    et_exec python3 "$flip_script" "${set_dir}/${f}" "${set_dir}/${f%.tck}_flipXY.tck" --axes "$flip_axes" \
        >>"${set_dir}/pp_flip_${f%.tck}.log" 2>&1 &
    _pp_pids+=("flip_${f%.tck}:$!")
done
for spec in "${_pp_pids[@]}"; do
    label="${spec%%:*}"; pid="${spec#*:}"
    wait "$pid" || { echo "ERROR: ${label} failed" >&2; exit 1; }
done

# 4. Concatenate all runs into one tractogram
shopt -s nullglob
flipped=("${subject}__set_"*"_filtered_flipXY.tck")
shopt -u nullglob
et_exec tckedit "${flipped[@]/#/${set_dir}/}" "$final" -force
_ts_pp_end=$(qc_timestamp); _t1_pp=$(qc_epoch)

echo "Post-processing complete for ${subject}: ${final}"

if [[ -n "$qc_json" ]]; then
    qc_pp_status="failed"
    streamline_count="null"
    if [[ -f "$final" ]]; then
        qc_pp_status="success"
        # Read the count MRtrix already recorded in the header when tckedit
        # wrote this file — avoids `tckinfo -count`'s slow full-file recount.
        streamline_count=$(et_exec tckinfo "$final" 2>/dev/null | awk '/^ *count:/ {print $2; exit}')
        [[ -z "$streamline_count" ]] && streamline_count="null"
    fi
    postprocess_fragment=$(cat <<EOF
"postprocess": {"status": "${qc_pp_status}", "final_tractogram": "${final}", "streamline_count": ${streamline_count}, "start": "${_ts_pp_start}", "end": "${_ts_pp_end}", "duration_s": $((_t1_pp - _t0_pp))}
EOF
)
    qc_write "$qc_json" "$postprocess_fragment"
fi
