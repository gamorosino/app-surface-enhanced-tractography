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

ET_IMAGE="docker://gamorosino/ensemble_tracking:latest"

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
et_exec() {
    ( cd /tmp && singularity exec --cleanenv -B "${set_dir}:${set_dir}" "$ET_IMAGE" "$@" )
}

final="${set_dir}/all_sets_flipXY_concatenated.tck"

cd "$set_dir"
echo "Post-processing tractograms for ${subject}"

# 1. Rename .fib → .vtk
for f in "${subject}__set_"*"_filtered.fib"; do
    cp "$f" "${f%.fib}.vtk"
done

# 2. Convert VTK → TCK
for f in "${subject}__set_"*"_filtered.vtk"; do
    base="${f%.vtk}"
    et_exec tckconvert "${set_dir}/${f}" "${set_dir}/${base}.tck" -force
done

# 3. Flip axes
flip_script="${SCRIPT_DIR}/../utils/flip_tractogram.py"
for f in "${subject}__set_"*"_filtered.tck"; do
    et_exec python3 "$flip_script" "${set_dir}/${f}" "${set_dir}/${f%.tck}_flipXY.tck" --axes "$flip_axes"
done

# 4. Concatenate all runs into one tractogram
shopt -s nullglob
flipped=("${subject}__set_"*"_filtered_flipXY.tck")
shopt -u nullglob
et_exec tckedit "${flipped[@]/#/${set_dir}/}" "$final" -force

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
"postprocess": {"status": "${qc_pp_status}", "final_tractogram": "${final}", "streamline_count": ${streamline_count}, "timestamp": "$(qc_timestamp)"}
EOF
)
    qc_write "$qc_json" "$postprocess_fragment"
fi
