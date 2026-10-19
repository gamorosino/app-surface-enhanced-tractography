#!/bin/bash
# main_local.sh — Docker-based local runner for Surface-Enhanced Tractography.
#
# Drop-in replacement for `main` that uses Docker instead of Singularity.
# Key differences from the brainlife main:
#   - All container calls use `docker run` (user is in the docker group).
#   - DWI is not required: FA map is used as the T1 registration reference
#     (both are in diffusion space; avoids downloading the full HCP DWI volume).
#   - fodf_lmax8 is always expected (precomputed CSD); 03_compute_fodf.sh is skipped.
#   - max_parallel_seeds defaults to 8 (run all seed chains simultaneously).
#   - 05_postprocess.sh is called with Docker via ET_IMAGE_DOCKER env var.

set -euo pipefail
trap 'echo "ERROR: command failed at line $LINENO (exit $?) -- cmd: $BASH_COMMAND" >&2' ERR

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="${REPO_DIR}/code/scripts/steps"
source "${REPO_DIR}/code/scripts/utils/qc_json.sh"

TASK_DIR="$(pwd)"
ET_IMAGE="gamorosino/ensemble_tracking:latest"
SET_IMAGE="gamorosino/set_1v1:latest"

CONFIG="${CONFIG:-config.json}"
[[ -f "$CONFIG" ]] || { echo "ERROR: config not found: $CONFIG"; exit 1; }

freesurfer_dir=$(jq -r '.freesurfer' "$CONFIG")
fa_in=$(jq -r '.fa' "$CONFIG")
t1=$(jq -r '.t1' "$CONFIG")
mask_5tt=$(jq -r '.mask_5tt' "$CONFIG")
fodf_lmax8=$(jq -r '.fodf_lmax8 // empty' "$CONFIG")
fodf_response=$(jq -r '.fodf_response // empty' "$CONFIG")
t1_warp=$(jq -r '.t1_warp // empty' "$CONFIG")
t1_inv_warp=$(jq -r '.t1_inv_warp // empty' "$CONFIG")
t1_affine=$(jq -r '.t1_affine // empty' "$CONFIG")
random_seeds=$(jq -r '.random_seeds // "1,2,3,4,5,6,7,8"' "$CONFIG")
nb_iter=$(jq -r '.nb_iter // 1' "$CONFIG")
nb_seeds=$(jq -r '.nb_seeds // 500000' "$CONFIG")
max_parallel_seeds=$(jq -r '.max_parallel_seeds // 8' "$CONFIG")
tracking_processes=$(jq -r '.tracking_processes // 1' "$CONFIG")
linear_transformation=$(jq -r '.linear_transformation // false' "$CONFIG")
ants_verbose=$(jq -r '.ants_verbose // false' "$CONFIG")
min_length=$(jq -r '.min_length // empty' "$CONFIG")
max_length=$(jq -r '.max_length // empty' "$CONFIG")
theta=$(jq -r '.theta // empty' "$CONFIG")
step=$(jq -r '.step // empty' "$CONFIG")
sfthres=$(jq -r '.sfthres // empty' "$CONFIG")
algo=$(jq -r '.algo // empty' "$CONFIG")

[[ -n "$fodf_lmax8" && -f "$fodf_lmax8" ]] || { echo "ERROR: fodf_lmax8 required and not found: $fodf_lmax8"; exit 1; }
[[ -d "$freesurfer_dir" ]] || { echo "ERROR: freesurfer dir not found: $freesurfer_dir"; exit 1; }
[[ -f "$fa_in"    ]] || { echo "ERROR: fa not found: $fa_in"; exit 1; }
[[ -f "$t1"       ]] || { echo "ERROR: t1 not found: $t1"; exit 1; }
[[ -f "$mask_5tt" ]] || { echo "ERROR: mask_5tt not found: $mask_5tt"; exit 1; }

n_reg=0
[[ -n "$t1_warp"     ]] && (( n_reg++ )) || true
[[ -n "$t1_inv_warp" ]] && (( n_reg++ )) || true
[[ -n "$t1_affine"   ]] && (( n_reg++ )) || true
if [[ "$n_reg" -gt 0 && "$n_reg" -lt 3 ]]; then
    echo "ERROR: t1_warp, t1_inv_warp, and t1_affine must all be given together"; exit 1
fi

# ---------------------------------------------------------------------------
# Docker helper — mounts every directory that holds an input path.
# Uses the parent of the mount point (Docker EEXIST workaround for FUSE mounts).
# ---------------------------------------------------------------------------
_DOCKER_VOLS=()
declare -A _VOL_SEEN=()
add_vol_for() {
    local target="$1"
    [[ -n "${target}" ]] || return 0
    local resolved mount_point
    resolved="$(readlink -f "${target}" 2>/dev/null || echo "${target}")"
    mount_point="$(df --output=target -- "${resolved}" 2>/dev/null | tail -n1 | xargs || true)"
    # Skip root filesystem (covered by explicit /tmp mount) and empty results
    [[ -z "${mount_point}" || "${mount_point}" == "/" ]] && return 0
    # For FUSE mounts, bind-mount the parent directory to avoid EEXIST errors
    local bind_src; bind_src="$(dirname "${mount_point}")"
    [[ "${bind_src}" == "/" ]] && bind_src="${mount_point}"
    if [[ -z "${_VOL_SEEN[${bind_src}]:-}" ]]; then
        _VOL_SEEN["${bind_src}"]=1
        _DOCKER_VOLS+=(-v "${bind_src}:${bind_src}")
    fi
}
for _p in "$TASK_DIR" "$freesurfer_dir" "$fa_in" "$t1" "$mask_5tt" "$fodf_lmax8" \
           "$t1_warp" "$t1_inv_warp" "$t1_affine"; do
    add_vol_for "$_p"
done

# Always mount /tmp and the local task directory (which may be on the root
# filesystem and therefore skipped by add_vol_for's mount-point deduplication).
_DOCKER_VOLS+=(-v /tmp:/tmp)
_DOCKER_VOLS+=(-v "$TASK_DIR:$TASK_DIR")

et_exec() {
    docker run --rm -i \
        --user "$(id -u):$(id -g)" \
        "${_DOCKER_VOLS[@]}" \
        -w "$(pwd)" \
        -e HOME=/tmp \
        "$ET_IMAGE" "$@"
}

imm_squeeze() {
    et_exec python3 - "$1" "$2" <<'PYEOF'
import nibabel as nib, numpy as np, sys
img = nib.load(sys.argv[1])
nib.save(nib.Nifti1Image(np.squeeze(img.get_fdata()), img.affine, img.header), sys.argv[2])
PYEOF
}

binarize_nii() {
    local in="$1" out="$2" thr="${3:-0}"
    et_exec python3 - "$in" "$out" "$thr" <<'PYEOF'
import sys, numpy as np, nibabel as nib
img = nib.load(sys.argv[1])
d = np.nan_to_num(img.get_fdata())
mask = (d > float(sys.argv[3])).any(axis=-1).astype(np.uint8) if d.ndim == 4 \
       else (d > float(sys.argv[3])).astype(np.uint8)
out = nib.Nifti1Image(mask, img.affine, img.header); out.set_data_dtype(np.uint8)
nib.save(out, sys.argv[2])
PYEOF
}

extract_5tt_vol() {
    local mask="$1" vol="$2" out="$3"
    et_exec python3 - "$mask" "$vol" "$out" <<'PYEOF'
import sys, numpy as np, nibabel as nib
img = nib.load(sys.argv[1]); v = int(sys.argv[2])
d = np.squeeze(img.get_fdata()[..., v]).astype(np.float32)
nib.save(nib.Nifti1Image(d, img.affine, img.header), sys.argv[3])
PYEOF
}

# ---------------------------------------------------------------------------
# Working directories
# ---------------------------------------------------------------------------
sub="sub-100206"
output_dir="${TASK_DIR}/out_dir"
staging_dir="${output_dir}/.set_inputs"
stage="${staging_dir}/${sub}"
mkdir -p "$output_dir" "$staging_dir" \
         "${stage}/Register_T1" "${stage}/DTI_Metrics" "${stage}/FODF_Metrics" \
         "${stage}/PFT_Maps" "${stage}/freesurfer/${sub}"

qc_json="${output_dir}/${sub}_qc.json"
qc_init "$qc_json"
_pipeline_start=$(qc_timestamp)
_pipeline_t0=$(qc_epoch)
qc_write "$qc_json" "\"pipeline\": {\"name\": \"surface_enhanced_tractography\", \"version\": \"v1.0\", \"subject\": \"${sub}\", \"start\": \"${_pipeline_start}\"}"
trap 'qc_finalize "$qc_json"' EXIT

echo "=== Staging SET inputs (Docker: ${ET_IMAGE}) ==="

# ---------------------------------------------------------------------------
# 1. PFT maps from 5TT (vol2=WM/include, vol3=CSF/exclude)
# ---------------------------------------------------------------------------
inc="${stage}/PFT_Maps/${sub}__map_include.nii.gz"
exc="${stage}/PFT_Maps/${sub}__map_exclude.nii.gz"
echo "--- Extracting PFT maps from 5TT mask ---"
_t0_pft=$(qc_epoch); qc_pft_start=$(qc_timestamp)
extract_5tt_vol "$mask_5tt" 2 "$inc"
extract_5tt_vol "$mask_5tt" 3 "$exc"
imm_squeeze "$inc" "$inc"
imm_squeeze "$exc" "$exc"
qc_pft_timestamp=$(qc_timestamp); _t1_pft=$(qc_epoch)

# ---------------------------------------------------------------------------
# 2. DTI metrics (FA)
# ---------------------------------------------------------------------------
fa_staged="${stage}/DTI_Metrics/${sub}__fa.nii.gz"
echo "--- Copying FA map ---"
_t0_fa=$(qc_epoch); qc_fa_start=$(qc_timestamp)
cp "$fa_in" "$fa_staged"
qc_fa_timestamp=$(qc_timestamp); _t1_fa=$(qc_epoch)

# ---------------------------------------------------------------------------
# 3. FODF (precomputed — always required for local runs)
# ---------------------------------------------------------------------------
staged_fodf="${stage}/FODF_Metrics/fodf.nii.gz"
echo "--- Using precomputed FODF (lmax8, descoteaux07 basis) ---"
_t0_fodf=$(qc_epoch); qc_fodf_start=$(qc_timestamp)
cp "$fodf_lmax8" "$staged_fodf"
qc_fodf_status="precomputed"
qc_fodf_timestamp=$(qc_timestamp); _t1_fodf=$(qc_epoch)

# ---------------------------------------------------------------------------
# 4. T1 registration
#    If all three transforms are precomputed, use them directly.
#    Otherwise run ANTs with FA as the diffusion-space reference (no DWI needed).
# ---------------------------------------------------------------------------
reg_prefix="${stage}/Register_T1/${sub}"
_t0_reg=$(qc_epoch); qc_reg_start=$(qc_timestamp)

if [[ "$n_reg" -eq 3 ]]; then
    echo "--- Using precomputed T1 registration ---"
    qc_reg_status="precomputed"
    [[ "$(realpath "$t1_warp")"     != "$(realpath "${reg_prefix}__output1Warp.nii.gz")"        ]] && cp "$t1_warp"     "${reg_prefix}__output1Warp.nii.gz"     || true
    [[ "$(realpath "$t1_inv_warp")" != "$(realpath "${reg_prefix}__output1InverseWarp.nii.gz")" ]] && cp "$t1_inv_warp" "${reg_prefix}__output1InverseWarp.nii.gz" || true
    # Stage the affine: try converting .txt → .mat (some ANTs builds don't support
    # writing .mat); fall back to using the .txt directly. If .mat already exists
    # from a prior run, keep it — antsApplyTransforms reads both formats.
    _staged_affine="${reg_prefix}__output0GenericAffine.mat"
    if [[ ! -f "$_staged_affine" ]]; then
        et_exec ConvertTransformFile 3 "$t1_affine" "$_staged_affine" 2>/dev/null || {
            cp "$t1_affine" "${reg_prefix}__output0GenericAffine.txt"
            _staged_affine="${reg_prefix}__output0GenericAffine.txt"
        }
    fi

    et_exec antsApplyTransforms -d 3 -i "$t1" \
        -r "$fa_staged" \
        -o "${reg_prefix}__t1_warped.nii.gz" \
        -t "${reg_prefix}__output1Warp.nii.gz" \
           "$_staged_affine"

    t1_mask_tmp="${stage}/Register_T1/t1_mask_tmp.nii.gz"
    binarize_nii "$t1" "$t1_mask_tmp"
    et_exec antsApplyTransforms -d 3 -i "$t1_mask_tmp" \
        -r "${reg_prefix}__t1_warped.nii.gz" \
        -o "${reg_prefix}__t1_mask_warped.nii.gz" \
        -n NearestNeighbor \
        -t "${reg_prefix}__output1Warp.nii.gz" \
           "$_staged_affine"
    et_exec python3 - "${reg_prefix}__t1_mask_warped.nii.gz" <<'PYEOF'
import sys, numpy as np, nibabel as nib
p = sys.argv[1]; img = nib.load(p)
out = nib.Nifti1Image(img.get_fdata().astype(np.uint8), img.affine, img.header)
out.set_data_dtype(np.uint8); nib.save(out, p)
PYEOF
    rm -f "$t1_mask_tmp"
else
    echo "--- Registering T1 to diffusion space using FA as reference (ANTs) ---"
    qc_reg_status="computed"
    cpus="${SLURM_CPUS_PER_TASK:-$(nproc)}"

    t1_mask_tmp="${stage}/Register_T1/t1_mask_tmp.nii.gz"
    binarize_nii "$mask_5tt" "$t1_mask_tmp"

    syn_args=()
    if [[ "$linear_transformation" == false ]]; then
        syn_args=(
            --transform SyN[0.1,3,0]
                --metric MI["$fa_staged","$t1",1,32]
                --metric CC["$fa_staged","$t1",1,4]
                --convergence [50x25x10,1e-6,10] --shrink-factors 4x2x1
                --smoothing-sigmas 3x2x1
        )
    fi
    ants_verbose_flag=()
    [[ "$ants_verbose" == true ]] && ants_verbose_flag=(--verbose)

    (
        [[ "$ants_verbose" != true ]] && exec > /dev/null
        docker run --rm \
            --user "$(id -u):$(id -g)" \
            "${_DOCKER_VOLS[@]}" \
            -w "$(pwd)" \
            -e HOME=/tmp \
            -e ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$cpus" \
            -e OMP_NUM_THREADS=1 \
            -e OPENBLAS_NUM_THREADS=1 \
            -e ANTS_RANDOM_SEED=1234 \
            "$ET_IMAGE" \
            antsRegistration --dimensionality 3 --float 0 \
                --output ["${stage}/Register_T1/"output,"${stage}/Register_T1/"outputWarped.nii.gz,"${stage}/Register_T1/"outputInverseWarped.nii.gz] \
                --interpolation Linear --use-histogram-matching 0 \
                --winsorize-image-intensities [0.005,0.995] \
                --initial-moving-transform ["$fa_staged","$t1",1] \
                --transform Rigid['0.2'] \
                    --metric MI["$fa_staged","$t1",1,32,Regular,0.25] \
                    --convergence [500x250x125x50,1e-6,10] --shrink-factors 8x4x2x1 \
                    --smoothing-sigmas 3x2x1x0 \
                --transform Affine['0.2'] \
                    --metric MI["$fa_staged","$t1",1,32,Regular,0.25] \
                    --convergence [500x250x125x50,1e-6,10] --shrink-factors 8x4x2x1 \
                    --smoothing-sigmas 3x2x1x0 \
                "${syn_args[@]}" "${ants_verbose_flag[@]}"

        mv "${stage}/Register_T1/"outputWarped.nii.gz            "${reg_prefix}__t1_warped.nii.gz"
        mv "${stage}/Register_T1/"output0GenericAffine.mat       "${reg_prefix}__output0GenericAffine.mat"
        [[ -f "${stage}/Register_T1/"output1InverseWarp.nii.gz ]] && \
            mv "${stage}/Register_T1/"output1InverseWarp.nii.gz  "${reg_prefix}__output1InverseWarp.nii.gz"
        [[ -f "${stage}/Register_T1/"output1Warp.nii.gz ]] && \
            mv "${stage}/Register_T1/"output1Warp.nii.gz         "${reg_prefix}__output1Warp.nii.gz"
    )

    reg_apply_transforms=("${reg_prefix}__output0GenericAffine.mat")
    [[ "$linear_transformation" == false ]] && \
        reg_apply_transforms=("${reg_prefix}__output1Warp.nii.gz" "${reg_apply_transforms[@]}")

    et_exec antsApplyTransforms -d 3 -i "$t1_mask_tmp" \
        -r "${reg_prefix}__t1_warped.nii.gz" \
        -o "${reg_prefix}__t1_mask_warped.nii.gz" \
        -n NearestNeighbor \
        -t "${reg_apply_transforms[@]}"
    et_exec python3 - "${reg_prefix}__t1_mask_warped.nii.gz" <<'PYEOF'
import sys, numpy as np, nibabel as nib
p = sys.argv[1]; img = nib.load(p)
out = nib.Nifti1Image(img.get_fdata().astype(np.uint8), img.affine, img.header)
out.set_data_dtype(np.uint8); nib.save(out, p)
PYEOF
    rm -f "$t1_mask_tmp"
fi
qc_reg_timestamp=$(qc_timestamp); _t1_reg=$(qc_epoch)

# ---------------------------------------------------------------------------
# 5. FreeSurfer
# ---------------------------------------------------------------------------
echo "--- Copying FreeSurfer outputs ---"
_t0_fs=$(qc_epoch); qc_fs_start=$(qc_timestamp)
cp -r "${freesurfer_dir}/." "${stage}/freesurfer/${sub}/"
qc_fs_timestamp=$(qc_timestamp); _t1_fs=$(qc_epoch)

staging_fragment=$(cat <<EOF
"staging": {
    "pft_maps":        {"start": "${qc_pft_start}",  "end": "${qc_pft_timestamp}",  "duration_s": $((_t1_pft  - _t0_pft))},
    "fa_map":          {"start": "${qc_fa_start}",   "end": "${qc_fa_timestamp}",   "duration_s": $((_t1_fa   - _t0_fa))},
    "fodf":            {"status": "${qc_fodf_status}", "start": "${qc_fodf_start}", "end": "${qc_fodf_timestamp}", "duration_s": $((_t1_fodf - _t0_fodf))},
    "t1_registration": {"status": "${qc_reg_status}", "linear_transformation": ${linear_transformation}, "start": "${qc_reg_start}", "end": "${qc_reg_timestamp}", "duration_s": $((_t1_reg  - _t0_reg))},
    "freesurfer":      {"start": "${qc_fs_start}",   "end": "${qc_fs_timestamp}",   "duration_s": $((_t1_fs   - _t0_fs))}
}
EOF
)
qc_write "$qc_json" "$staging_fragment"

# ---------------------------------------------------------------------------
# 6. Run SET (Docker, all 8 chains in parallel)
# ---------------------------------------------------------------------------
echo "=== Running SET (Docker: ${SET_IMAGE}, max_parallel_seeds=${max_parallel_seeds}) ==="
set_extra_args=()
[[ "$linear_transformation" == true ]] && set_extra_args+=(--transf-linear)
[[ -n "$min_length" ]] && set_extra_args+=(--min-length "$min_length")
[[ -n "$max_length" ]] && set_extra_args+=(--max-length "$max_length")
[[ -n "$theta"      ]] && set_extra_args+=(--theta      "$theta")
[[ -n "$step"       ]] && set_extra_args+=(--step       "$step")
[[ -n "$sfthres"    ]] && set_extra_args+=(--sfthres    "$sfthres")
[[ -n "$algo"       ]] && set_extra_args+=(--algo       "$algo")

bash "${STEPS_DIR}/04_run_set_direct.sh" \
    --subject              "$sub" \
    --staging-dir          "$staging_dir" \
    --output-dir           "$output_dir" \
    --docker               "$SET_IMAGE" \
    --random-seeds         "$random_seeds" \
    --nb-iter              "$nb_iter" \
    --nb-seeds             "$nb_seeds" \
    --max-parallel-seeds   "$max_parallel_seeds" \
    --tracking-processes   "$tracking_processes" \
    --quiet \
    --qc-json              "$qc_json" \
    "${set_extra_args[@]}"

# ---------------------------------------------------------------------------
# 7. Post-process (Docker)
# ---------------------------------------------------------------------------
echo "=== Post-processing tractograms ==="
tract_dir="${output_dir}/${sub}/F__Surface_Enhanced_Tractography"
ET_IMAGE_DOCKER="$ET_IMAGE" \
bash "${STEPS_DIR}/05_postprocess.sh" \
    --subject  "$sub" \
    --set-dir  "$tract_dir" \
    --qc-json  "$qc_json"

final="${tract_dir}/all_sets_flipXY_concatenated.tck"
[[ -f "$final" ]] || { echo "ERROR: no final tractogram produced"; exit 1; }

mkdir -p tractogram fodf t1_transform
cp "$final" tractogram/track.tck

cp "$fodf_lmax8" fodf/lmax8.nii.gz
[[ -n "$fodf_response" && -f "$fodf_response" ]] && cp "$fodf_response" fodf/response.txt || true

if [[ "$n_reg" -ne 3 && -f "${reg_prefix}__output1Warp.nii.gz" ]]; then
    cp "${reg_prefix}__output1Warp.nii.gz"        t1_transform/warp.nii.gz
    cp "${reg_prefix}__output1InverseWarp.nii.gz" t1_transform/inverse-warp.nii.gz
fi
et_exec ConvertTransformFile 3 "${reg_prefix}__output0GenericAffine.mat" t1_transform/affine.txt

qc_write "$qc_json" "\"pipeline_summary\": {\"end\": \"$(qc_timestamp)\", \"duration_s\": $(($(qc_epoch) - _pipeline_t0)), \"status\": \"success\"}"

echo "=== Done: tractogram/track.tck ==="
