#!/usr/bin/env bash
# Compute FODF (fiber orientation distribution function) for preprocessed DWI.
# Runs inside the public docker://scilus/scilus:1.6.0 image.
set -e

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Compute FODF metrics from preprocessed DWI data.

Required:
  --workdir <dir>       Directory containing dwi.nii.gz / dwi.bvals / dwi.bvecs

Optional:
  --fa <float>          FA threshold for FRF estimation [0.7]
  --min-fa <float>      Minimum FA threshold [0.5]
  --min-nvox <int>      Minimum number of voxels for FRF [300]
  --roi-radius <int>    ROI radius for FRF [20]
  --manual-frf <str>    Manual FRF override, e.g. "15,4,4" [15,4,4]
  --sh-order <int>      SH order for FODF [8] -- must stay 8 to match this
                        app's neuro/csd output (lmax8.nii.gz)
  --sh-basis <str>      SH basis [descoteaux07]
  -h, --help            Show this help and exit
EOF
}

# --- Defaults ----------------------------------------------------------------
workdir=""
fa=0.7
min_fa=0.5
min_nvox=300
roi_radius=20
manual_frf="15,4,4"
sh_order=8
sh_basis="descoteaux07"

SCILUS_IMAGE="docker://scilus/scilus:1.6.0"
ET_IMAGE="docker://gamorosino/ensemble_tracking:latest"

# --- Parse -------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workdir)      workdir="$2";    shift 2 ;;
        --fa)           fa="$2";         shift 2 ;;
        --min-fa)       min_fa="$2";     shift 2 ;;
        --min-nvox)     min_nvox="$2";   shift 2 ;;
        --roi-radius)   roi_radius="$2"; shift 2 ;;
        --manual-frf)   manual_frf="$2"; shift 2 ;;
        --sh-order)     sh_order="$2";   shift 2 ;;
        --sh-basis)     sh_basis="$2";   shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

[[ -z "$workdir" ]] && { echo "ERROR: --workdir is required"; exit 1; }

# ---------------------------------------------------------------------------
current_dir="${PWD}"
cd "$workdir"

scilus() {
    # Run from /tmp so Singularity doesn't try to replicate an external-storage
    # CWD inside the container (causes "Permission denied" on some mounts).
    ( cd /tmp && singularity exec \
        --cleanenv \
        -B "${workdir}:/data" \
        "$SCILUS_IMAGE" "$@" )
}

make_mask() {
    ( cd /tmp && singularity exec --cleanenv -B "${workdir}:${workdir}" "$ET_IMAGE" \
        python3 - "$1" "$2" <<'PYEOF'
import sys, numpy as np, nibabel as nib
img = nib.load(sys.argv[1])
mask = (img.get_fdata() > 0).astype(np.uint8)
nib.save(nib.Nifti1Image(mask, img.affine, img.header), sys.argv[2])
PYEOF
    )
}

B0="b0_volume.nii.gz"
MASK="b0_mask_int.nii.gz"
fodf_dir="scilpy_fodf"
SID="fodf"

# Extract b0
[[ ! -f "$B0" ]] && \
    scilus scil_extract_b0.py /data/dwi.nii.gz /data/dwi.bvals /data/dwi.bvecs \
           /data/"$B0" --force_b0_threshold

# Create mask
tmp_mask="b0_mask.nii.gz"
[[ ! -f "$tmp_mask" ]] && make_mask "$workdir/$B0" "$workdir/$tmp_mask"
[[ ! -f "$MASK"     ]] && \
    scilus scil_image_math.py convert /data/"$tmp_mask" /data/"$MASK" --data_type uint8 -f

# FRF
[[ ! -f frf.txt ]] && \
    scilus scil_compute_ssst_frf.py \
        /data/dwi.nii.gz /data/dwi.bvals /data/dwi.bvecs /data/frf.txt \
        --mask /data/"$MASK" \
        --fa "$fa" --min_fa "$min_fa" --min_nvox "$min_nvox" \
        --roi_radii "$roi_radius" --force_b0_threshold -f

# Manual FRF override
[[ ! -f frf_used.txt ]] && \
    scilus scil_set_response_function.py /data/frf.txt "$manual_frf" /data/frf_used.txt -f

# FODF
[[ ! -f fodf.nii.gz ]] && \
    scilus scil_compute_ssst_fodf.py \
        /data/dwi.nii.gz /data/dwi.bvals /data/dwi.bvecs /data/frf_used.txt \
        /data/fodf.nii.gz \
        --mask /data/"$MASK" \
        --sh_order "$sh_order" --sh_basis "$sh_basis" -f

# FODF metrics
mkdir -p "$fodf_dir"
if [[ ! -f "${fodf_dir}/${SID}__peaks.nii.gz" ]]; then
    scilus scil_compute_fodf_metrics.py \
        /data/fodf.nii.gz \
        --sh_basis "$sh_basis" \
        --mask /data/"$MASK" \
        --afd_max      /data/"${fodf_dir}/${SID}__afd_max.nii.gz" \
        --afd_sum      /data/"${fodf_dir}/${SID}__afd_sum.nii.gz" \
        --afd_total    /data/"${fodf_dir}/${SID}__afd_total.nii.gz" \
        --nufo         /data/"${fodf_dir}/${SID}__nufo.nii.gz" \
        --peaks        /data/"${fodf_dir}/${SID}__peaks.nii.gz" \
        --peak_indices /data/"${fodf_dir}/${SID}__peak_indices.nii.gz" \
        -f
fi

cd "$current_dir"
echo "FODF computation complete: ${workdir}"
