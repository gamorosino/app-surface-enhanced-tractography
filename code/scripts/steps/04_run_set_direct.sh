#!/usr/bin/env bash
# Run the SET pipeline directly via Singularity or Docker — no Nextflow required.
# Replicates the freesurfer_a2009s_proper profile (main.nf A→H processes).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utils/qc_json.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run the SET pipeline for one subject without Nextflow.
Equivalent to: nextflow run main.nf -profile freesurfer_a2009s_proper

Required:
  --subject <id>        Subject ID string (e.g., sub-102614)
  --staging-dir <dir>   SET staging root — must contain sub-XXXXX/{freesurfer,
                        Register_T1,DTI_Metrics,FODF_Metrics,PFT_Maps}
  --output-dir <dir>    Directory where results will be written

Container (one required):
  --set-img <file>      Path to set_1v1.img Singularity image
  --docker [image]      Use Docker instead of Singularity.
                        Default image: gamorosino/set_1v1:latest

Optional:
  --random-seeds <str>  Comma-separated random seeds [1,2,3,4,5,6,7,8]
  --nb-iter <n>         Dynamic seeding iterations per seed [1]
  --nb-seeds <n>        Seeds per iteration [500000]
  --max-parallel-seeds <n>
                        Run this many random-seed chains concurrently [4]
                        Each chain's iterations still run sequentially.
  --force-tracking      Redo every seed/iteration even if its done-marker
                        (from a prior run) says it already finished.
  --qc-json <path>      Append a "tracking" stage to this QC json (see
                        code/scripts/utils/qc_json.sh). Skipped if omitted.
  -h, --help
EOF
}

# ---------------------------------------------------------------------------
# Defaults (freesurfer_a2009s_proper profile values)
# ---------------------------------------------------------------------------
subject=""
staging_dir=""
output_dir=""
set_img=""
use_docker=false
docker_image="gamorosino/set_1v1:latest"
random_seeds="1,2,3,4,5,6,7,8"
nb_iter=1
nb_seeds=500000
max_parallel_seeds=4
force_tracking=false
qc_json=""

flip_to_lps="-x -y"
flow_masked_indices="-1 0 6 7 8 9 10 35 42 67"
seed_masked_indices="-1 0"
intersections_masked_indices="-1 0"
rois_indices=("10" "11" "12" "13" "16" "17" "18" "49" "50" "51" "52" "53" "54")
unused_labels="-1 0"

surf_smooth_nb_step=2
surf_smooth_step_size=2.0
surf_flow_nb_step=100
surf_flow_step_size=1.0
subsample_flow=1
gaussian_threshold=0.2
angle_threshold=2

tractography_algo="prob"
tractography_step=0.2
tractography_theta=20.0
tractography_sfthres=0.1
pft_particles=15
pft_back=2
pft_front=1
compression_rate=0.2
min_length=10
max_length=300

rois_opening=2
rois_closing=2
rois_smoothing=2

# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --subject)      subject="$2";      shift 2 ;;
        --staging-dir)  staging_dir="$2";  shift 2 ;;
        --output-dir)   output_dir="$2";   shift 2 ;;
        --set-img)      set_img="$2";      shift 2 ;;
        --docker)
            use_docker=true
            # optional custom image name after the flag
            if [[ $# -gt 1 && "${2:-}" != --* ]]; then
                docker_image="$2"; shift
            fi
            shift ;;
        --random-seeds) random_seeds="$2"; shift 2 ;;
        --nb-iter)      nb_iter="$2";      shift 2 ;;
        --nb-seeds)     nb_seeds="$2";     shift 2 ;;
        --max-parallel-seeds) max_parallel_seeds="$2"; shift 2 ;;
        --force-tracking) force_tracking=true; shift ;;
        --qc-json) qc_json="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

[[ -z "$subject"     ]] && { echo "ERROR: --subject is required";     exit 1; }
[[ -z "$staging_dir" ]] && { echo "ERROR: --staging-dir is required"; exit 1; }
[[ -z "$output_dir"  ]] && { echo "ERROR: --output-dir is required";  exit 1; }
if [[ "$use_docker" == false && -z "$set_img" ]]; then
    echo "ERROR: provide --set-img <singularity.img> or --docker [image]"; exit 1
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
input_root="${staging_dir}/${subject}"
fs_dir="${input_root}/freesurfer/${subject}"
work="${output_dir}/${subject}/set_work"
results="${output_dir}/${subject}/F__Surface_Enhanced_Tractography"
mkdir -p "$work" "$results"

fodf="${input_root}/FODF_Metrics/fodf.nii.gz"
map_include="${input_root}/PFT_Maps/${subject}__map_include.nii.gz"
map_exclude="${input_root}/PFT_Maps/${subject}__map_exclude.nii.gz"
fa="${input_root}/DTI_Metrics/${subject}__fa.nii.gz"
affine="${input_root}/Register_T1/${subject}__output0GenericAffine.mat"
inv_warp="${input_root}/Register_T1/${subject}__output1InverseWarp.nii.gz"

wmparc="${fs_dir}/mri/wmparc.mgz"
lh_pial="${fs_dir}/surf/lh.pial"
rh_pial="${fs_dir}/surf/rh.pial"
lh_white="${fs_dir}/surf/lh.white"
rh_white="${fs_dir}/surf/rh.white"
lh_annot="${fs_dir}/label/lh.aparc.a2009s.annot"
rh_annot="${fs_dir}/label/rh.aparc.a2009s.annot"

# Container runner — Singularity or Docker
if [[ "$use_docker" == true ]]; then
    echo "Using Docker image: ${docker_image}"
    # Mount the parent of each mount point (e.g. /mnt) — Docker daemon has a
    # bug where it fails with EEXIST when the bind-mount source IS a mount point.
    # Mounting the plain parent directory works around this.
    _staging_mnt=$(dirname "$(stat --format="%m" "${staging_dir}")")
    _output_mnt=$(dirname "$(stat --format="%m" "${output_dir}")")
    # Deduplicate in case both resolve to the same parent
    if [[ "$_staging_mnt" == "$_output_mnt" ]]; then
        _vol_flags="-v ${_staging_mnt}:${_staging_mnt}"
    else
        _vol_flags="-v ${_staging_mnt}:${_staging_mnt} -v ${_output_mnt}:${_output_mnt}"
    fi
    # The Singularity image sets PATH via %environment; Docker import doesn't carry that.
    _SET_PATH="/usr/share/fsl/5.0/bin:/usr/lib/fsl/5.0:/mrtrix3/bin:/opt/minc/1.9.16/bin:/opt/minc/1.9.16/pipeline:/scilpy/dev_scripts:/scilpy/surgery_scripts:/scilpy/scripts:/freesurfer/freesurfer/mni/bin:/freesurfer/freesurfer/bin:/freesurfer/freesurfer/fsfast/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/ants_build/bin"
    set_run() {
        docker run --rm \
            --user "$(id -u):$(id -g)" \
            $_vol_flags \
            -e PATH="${_SET_PATH}" \
            -e PYTHONPATH=/scilpy \
            -e LD_LIBRARY_PATH=/usr/local/lib/python2.7/dist-packages/vtk \
            -e HOME=/tmp \
            "$docker_image" "$@"
    }
else
    echo "Using Singularity image: ${set_img}"
    BINDS="-B ${staging_dir}:${staging_dir} -B ${output_dir}:${output_dir}"
    set_run() {
        ( cd /tmp && singularity exec --cleanenv $BINDS "$set_img" "$@" )
    }
fi

# ---------------------------------------------------------------------------
echo "=== SET direct pipeline: ${subject} ==="

# ---------------------------------------------------------------------------
# A: Convert FreeSurfer surfaces (.pial/.white → .vtk)
# ---------------------------------------------------------------------------
echo "--- A: Convert FreeSurfer surfaces ---"
set_run mris_convert --to-scanner "$lh_pial"  "${work}/${subject}__lh_pial.vtk"
set_run mris_convert --to-scanner "$rh_pial"  "${work}/${subject}__rh_pial.vtk"
set_run mris_convert --to-scanner "$lh_white" "${work}/${subject}__lh_white.vtk"
set_run mris_convert --to-scanner "$rh_white" "${work}/${subject}__rh_white.vtk"

# A: Convert label volume (wmparc.mgz → .nii.gz)
echo "--- A: Convert label volume ---"
set_run mri_convert "$wmparc" "${work}/${subject}__labels.nii.gz"

# A: Convert ANTs affine transform → VTK format
echo "--- A: Convert ANTs transform ---"
set_run ConvertTransformFile 3 "$affine" "${work}/${subject}__vtk_transfo.txt" --hm

# A: Flip surfaces to LPS
echo "--- A: Flip surfaces to LPS ---"
for surf in lh_pial rh_pial lh_white rh_white; do
    set_run scil_flip_surface.py \
        "${work}/${subject}__${surf}.vtk" \
        "${work}/${subject}__${surf}_lps.vtk" \
        $flip_to_lps -f
done

# ---------------------------------------------------------------------------
# B: Surface masks (flow / seed / intersections)
# ---------------------------------------------------------------------------
echo "--- B: Surface masks ---"
for hemi in lh rh; do
    annot_var="${hemi}_annot"
    surf_vtk="${work}/${subject}__${hemi}_white.vtk"
    annot="${!annot_var}"

    set_run scil_surface.py "$surf_vtk" --annot "$annot" \
        -i $flow_masked_indices --inverse_mask \
        --save_vts_mask "${work}/${subject}__${hemi}_flow_mask.npy" -f

    set_run scil_surface.py "$surf_vtk" --annot "$annot" \
        -i $seed_masked_indices --inverse_mask \
        --save_vts_mask "${work}/${subject}__${hemi}_seed_mask.npy" -f

    set_run scil_surface.py "$surf_vtk" --annot "$annot" \
        -i $intersections_masked_indices --inverse_mask \
        --save_vts_mask "${work}/${subject}__${hemi}_intersections_mask.npy" -f

    set_run scil_surface.py "$surf_vtk" --vts_val 0.0 \
        --save_vts_mask "${work}/${subject}__${hemi}_zero_mask.npy" -f
done

# B: Surface labels
echo "--- B: Surface labels ---"
for hemi in lh rh; do
    annot_var="${hemi}_annot"
    surf_vtk="${work}/${subject}__${hemi}_white.vtk"
    annot="${!annot_var}"
    set_run scil_surface.py "$surf_vtk" --annot "$annot" \
        --save_vts_label "${work}/${subject}__${hemi}_labels.npy" -f
done

# B: Generate ROI surfaces from label volume
echo "--- B: Generate ROIs ---"
roi_vtks=()
for i in "${!rois_indices[@]}"; do
    idx_str=$(printf "%04d" "$i")
    roi_vtk="${work}/${subject}__roi${idx_str}.vtk"
    set_run scil_surface_from_volume.py "${work}/${subject}__labels.nii.gz" \
        "$roi_vtk" \
        --index ${rois_indices[$i]} \
        --closing "$rois_closing" \
        --opening "$rois_opening" \
        --smooth  "$rois_smoothing" \
        --vox2vtk --fill --max_label -f
    roi_vtks+=("$roi_vtk")
done

# B: ROI masks
echo "--- B: ROI masks ---"
for roi_vtk in "${roi_vtks[@]}"; do
    base="${roi_vtk%.vtk}"
    set_run scil_surface.py "$roi_vtk" --vts_val 0.0 \
        --save_vts_mask "${base}_flow_mask.npy" -f
    set_run scil_surface.py "$roi_vtk" --vts_val 1.0 \
        --save_vts_mask "${base}_intersections_mask.npy" -f
    set_run scil_surface_map_from_volume.py "$roi_vtk" "$fa" \
        "${base}_seed_mask.npy" --binarize --binarize_value 0.5 -f
done

# B: Concatenate surfaces
echo "--- B: Concatenate surfaces ---"
roi_vtk_list="${roi_vtks[*]}"
set_run scil_concatenate_surfaces.py \
    "${work}/${subject}__lh_white_lps.vtk" \
    "${work}/${subject}__rh_white_lps.vtk" \
    --outer_surfaces \
        "${work}/${subject}__lh_pial_lps.vtk" \
        "${work}/${subject}__rh_pial_lps.vtk" \
    --inner_surfaces $roi_vtk_list \
    --out_surface_id    "${work}/${subject}__surfaces_id.npy" \
    --out_surface_type_map "${work}/${subject}__surfaces_type.npy" \
    --out_concatenated_surface "${work}/${subject}__surfaces.vtk" -f

# B: Concatenate masks
echo "--- B: Concatenate masks ---"
roi_flow_masks=()
roi_seed_masks=()
roi_inter_masks=()
for roi_vtk in "${roi_vtks[@]}"; do
    base="${roi_vtk%.vtk}"
    roi_flow_masks+=("${base}_flow_mask.npy")
    roi_seed_masks+=("${base}_seed_mask.npy")
    roi_inter_masks+=("${base}_intersections_mask.npy")
done

set_run scil_concatenate_surfaces_map.py \
    "${work}/${subject}__lh_flow_mask.npy" \
    "${work}/${subject}__rh_flow_mask.npy" \
    --outer_surfaces_map \
        "${work}/${subject}__lh_zero_mask.npy" \
        "${work}/${subject}__rh_zero_mask.npy" \
    --inner_surfaces_map ${roi_flow_masks[*]} \
    --out_map "${work}/${subject}__flow_mask.npy" -f

set_run scil_concatenate_surfaces_map.py \
    "${work}/${subject}__lh_seed_mask.npy" \
    "${work}/${subject}__rh_seed_mask.npy" \
    --outer_surfaces_map \
        "${work}/${subject}__lh_zero_mask.npy" \
        "${work}/${subject}__rh_zero_mask.npy" \
    --inner_surfaces_map ${roi_seed_masks[*]} \
    --out_map "${work}/${subject}__seed_mask.npy" -f

set_run scil_concatenate_surfaces_map.py \
    "${work}/${subject}__lh_intersections_mask.npy" \
    "${work}/${subject}__rh_intersections_mask.npy" \
    --outer_surfaces_map \
        "${work}/${subject}__lh_intersections_mask.npy" \
        "${work}/${subject}__rh_intersections_mask.npy" \
    --inner_surfaces_map ${roi_inter_masks[*]} \
    --out_map "${work}/${subject}__intersections_mask.npy" -f

# B: Concatenate labels
echo "--- B: Concatenate labels ---"
set_run scil_concatenate_surfaces_map.py \
    "${work}/${subject}__lh_labels.npy" \
    "${work}/${subject}__rh_labels.npy" \
    --outer_surfaces_map \
        "${work}/${subject}__lh_zero_mask.npy" \
        "${work}/${subject}__rh_zero_mask.npy" \
    --inner_surfaces_map ${roi_inter_masks[*]} \
    --out_map "${work}/${subject}__unique_id.npy" \
    --unique_id \
    --out_id_map "${work}/${subject}__unique_id.txt" \
    --indices_to_remove $unused_labels -f

# ---------------------------------------------------------------------------
# C: Register surface (T1 → DWI space via ANTs warp)
# ---------------------------------------------------------------------------
echo "--- C: Register surface ---"
set_run scil_transform_surface.py \
    "${work}/${subject}__surfaces.vtk" \
    "${work}/${subject}__vtk_transfo.txt" \
    "${work}/${subject}__surfaces_b0.vtk" \
    --ants_warp "$inv_warp" -f

# ---------------------------------------------------------------------------
# D: Surface flow (smooth + flow)
# ---------------------------------------------------------------------------
echo "--- D: Surface flow ---"
flow_vtk="${work}/${subject}__flow_${surf_flow_nb_step}_${surf_flow_step_size}.vtk"
flow_hdf5="${work}/${subject}__flow_${surf_flow_nb_step}_${surf_flow_step_size}.hdf5"

set_run scil_smooth_surface.py \
    "${work}/${subject}__surfaces_b0.vtk" \
    "${work}/${subject}__smoothed.vtk" \
    --vts_mask "${work}/${subject}__flow_mask.npy" \
    --nb_steps "$surf_smooth_nb_step" \
    --step_size "$surf_smooth_step_size" -f

if [[ "$surf_flow_nb_step" -gt 1 ]]; then
    set_run scil_surface_flow.py \
        "${work}/${subject}__smoothed.vtk" \
        "$flow_vtk" \
        --vts_mask "${work}/${subject}__flow_mask.npy" \
        --nb_step "$surf_flow_nb_step" \
        --step_size "$surf_flow_step_size" \
        --subsample_flow "$subsample_flow" \
        --gaussian_threshold "$gaussian_threshold" \
        --angle_threshold "$angle_threshold" \
        --out_flow "$flow_hdf5" -f
else
    cp "${work}/${subject}__smoothed.vtk" "$flow_vtk"
    touch "$flow_hdf5"
fi

# ---------------------------------------------------------------------------
# E: Initial seeding map
# ---------------------------------------------------------------------------
echo "--- E: Initial seeding map ---"
set_run scil_surface_seed_map.py \
    "$flow_vtk" \
    "${work}/${subject}__seeding_map_0.npy" \
    --vts_mask "${work}/${subject}__seed_mask.npy" \
    --triangle_area_weighting -f

set_run scil_surface_seed_map.py \
    "$flow_vtk" \
    "${work}/${subject}__zeros_tri_map.npy" \
    --zeros_map -f

# ---------------------------------------------------------------------------
# F: SET tracking (each random seed's iteration chain is independent of the
#    other seeds — only iterations *within* one seed are sequential — so
#    chains run as background jobs, up to $max_parallel_seeds at a time.
# ---------------------------------------------------------------------------
echo "--- F: SET tracking ---"
IFS=',' read -ra rand_seeds <<< "$random_seeds"

run_seed_chain() {
    local rand_id="$1"
    local rand_id_pad iter iter_pad tag done_marker filtered_npz
    local seed_map sum_density prev_iter prev_pad flow_fib
    rand_id_pad=$(printf "%04d" "$rand_id")

    for (( iter=0; iter<nb_iter; iter++ )); do
        iter_pad=$(printf "%04d" "$iter")
        tag="${rand_id_pad}_i${iter_pad}"
        done_marker="${results}/${subject}__.done_${tag}"
        filtered_npz="${results}/${subject}__intersections_${tag}_filtered.npz"

        if [[ -f "$done_marker" ]] && [[ "$force_tracking" == false ]]; then
            echo "  Run ${tag}: already complete, skipping"
            continue
        fi

        echo "  Run ${tag}..."

        # Seeding map for this iteration
        if [[ "$iter" -eq 0 ]]; then
            seed_map="${work}/${subject}__seeding_map_0.npy"
            sum_density="${work}/${subject}__zeros_tri_map.npy"
        else
            prev_iter=$(( iter - 1 ))
            prev_pad=$(printf "%04d" "$prev_iter")
            seed_map="${results}/${subject}__seeding_map_${rand_id_pad}_i${prev_pad}.npy"
            sum_density="${results}/${subject}__sum_density_${rand_id_pad}_i${prev_pad}.npy"
        fi

        # Generate seeds
        set_run scil_surface_seed_map.py "$flow_vtk" \
            "${results}/${subject}__seeding_map_${tag}.npy" \
            --triangle_weight "$seed_map" \
            --previous_density "$sum_density" -f

        set_run scil_surface_seeds_from_map.py "$flow_vtk" \
            "${results}/${subject}__seeding_map_${tag}.npy" \
            "$nb_seeds" \
            "${results}/${subject}__seeds_${tag}.npz" \
            --random_number_generator "$rand_id" -f

        # PFT tractography
        set_run scil_surface_pft_dipy.py \
            "$fodf" "$map_include" "$map_exclude" "$flow_vtk" \
            "${results}/${subject}__seeds_${tag}.npz" \
            "${results}/${subject}__set_${tag}.trk" \
            --algo "$tractography_algo" \
            --step "$tractography_step" \
            --theta "$tractography_theta" \
            --sfthres "$tractography_sfthres" \
            --max_length "$max_length" \
            --random_seed "$iter" \
            --compress "$compression_rate" \
            --particles "$pft_particles" \
            --back "$pft_back" \
            --forward "$pft_front" -f

        # Convert .trk → .fib
        set_run scil_convert_tractogram.py \
            "${results}/${subject}__set_${tag}.trk" \
            "${results}/${subject}__set_${tag}.fib" -f

        # Surface intersections
        set_run scil_surface_tractogram_intersections.py "$flow_vtk" \
            "${results}/${subject}__set_${tag}.fib" \
            "${work}/${subject}__surfaces_type.npy" \
            "${work}/${subject}__intersections_mask.npy" \
            --output_intersections "${results}/${subject}__intersections_${tag}.npz" \
            --output_tractogram    "${results}/${subject}__cut_${tag}.fib" -f

        # Surface flow combine
        if [[ "$surf_flow_nb_step" -gt 1 ]]; then
            set_run scil_surface_combine_flow.py "$flow_vtk" "$flow_hdf5" \
                "${results}/${subject}__intersections_${tag}.npz" \
                "${results}/${subject}__cut_${tag}.fib" \
                "${results}/${subject}__set_${tag}_flow.fib" \
                --compression_rate "$compression_rate"
            flow_fib="${results}/${subject}__set_${tag}_flow.fib"
        else
            flow_fib="${results}/${subject}__cut_${tag}.fib"
        fi

        # Filter tractogram
        set_run scil_surface_filtering.py "$flow_vtk" \
            "${results}/${subject}__intersections_${tag}.npz" \
            "$flow_fib" \
            "${results}/${subject}__set_${tag}_filtered.fib" \
            --out_intersections "$filtered_npz" \
            --min_length "$min_length" \
            --max_length "$max_length" -f

        # Density for next iteration
        set_run scil_surface_intersections_density.py "$flow_vtk" \
            "$filtered_npz" \
            "${results}/${subject}__set_density_${tag}.npy"

        set_run scil_surface_seed_map.py "$flow_vtk" \
            "${results}/${subject}__sum_density_${tag}.npy" \
            --sum_maps "$sum_density" \
            "${results}/${subject}__set_density_${tag}.npy" -f

        touch "$done_marker"
    done
}

# Launch seed chains in batches of $max_parallel_seeds. A batch is fully
# joined (all jobs' exit statuses collected) before the next batch starts —
# simpler and safer than a sliding window, since a background job's exit
# status can only be read once via `wait <pid>`.
seed_fail=0
idx=0
# Per-seed QC results are accumulated in memory (this loop is the only
# writer — the background jobs themselves never touch $qc_json) and
# written as a single qc_write call once every batch has joined, so there's
# no concurrent-append race on the shared QC file.
qc_seeds_json=""
while [[ "$idx" -lt "${#rand_seeds[@]}" ]]; do
    batch_pids=()
    batch_ids=()
    batch_logs=()
    batch_count=0
    while [[ "$batch_count" -lt "$max_parallel_seeds" && "$idx" -lt "${#rand_seeds[@]}" ]]; do
        rid="${rand_seeds[$idx]}"
        rid_pad=$(printf "%04d" "$rid")
        seed_log="${work}/${subject}__seed_${rid_pad}.log"
        echo "  Launching seed ${rid} chain (log: ${seed_log})"
        run_seed_chain "$rid" > "$seed_log" 2>&1 &
        batch_pids+=("$!")
        batch_ids+=("$rid")
        batch_logs+=("$seed_log")
        idx=$(( idx + 1 ))
        batch_count=$(( batch_count + 1 ))
    done

    for b in "${!batch_pids[@]}"; do
        rid_pad=$(printf "%04d" "${batch_ids[$b]}")
        if wait "${batch_pids[$b]}"; then
            seed_status="success"
        else
            echo "ERROR: seed ${batch_ids[$b]} chain failed — see ${batch_logs[$b]}" >&2
            seed_status="failed"
            seed_fail=1
        fi
        qc_seeds_json="${qc_seeds_json}\"seed_${rid_pad}\": {\"status\": \"${seed_status}\", \"iterations\": ${nb_iter}, \"log\": \"${batch_logs[$b]}\", \"timestamp\": \"$(qc_timestamp)\"}, "
    done
done

if [[ -n "$qc_json" ]]; then
    tracking_fragment=$(cat <<EOF
"tracking": {
    "params": {"random_seeds": "${random_seeds}", "nb_iter": ${nb_iter}, "nb_seeds": ${nb_seeds}, "max_parallel_seeds": ${max_parallel_seeds}, "algo": "${tractography_algo}", "step": ${tractography_step}, "theta": ${tractography_theta}, "sfthres": ${tractography_sfthres}},
    "seeds": {${qc_seeds_json%, }}
}
EOF
)
    qc_write "$qc_json" "$tracking_fragment"
fi

[[ "$seed_fail" -ne 0 ]] && exit 1

# Reconstruct the ordered list of filtered intersections (deterministic
# path names — no cross-process communication needed).
all_inter_npz=()
for rand_id in "${rand_seeds[@]}"; do
    rand_id_pad=$(printf "%04d" "$rand_id")
    for (( iter=0; iter<nb_iter; iter++ )); do
        iter_pad=$(printf "%04d" "$iter")
        tag="${rand_id_pad}_i${iter_pad}"
        filtered_npz="${results}/${subject}__intersections_${tag}_filtered.npz"
        if [[ ! -f "$filtered_npz" ]]; then
            echo "ERROR: expected output missing: $filtered_npz" >&2
            exit 1
        fi
        all_inter_npz+=("$filtered_npz")
    done
done

# ---------------------------------------------------------------------------
# G: Concatenate intersections
# ---------------------------------------------------------------------------
echo "--- G: Concatenate intersections ---"
set_run scil_concatenate_surfaces_intersections.py \
    "${all_inter_npz[@]}" \
    --output_intersections "${results}/${subject}__set_c_filtered.npz" -f

# ---------------------------------------------------------------------------
# H: Connectivity matrix + surface density
# ---------------------------------------------------------------------------
echo "--- H: Connectivity matrix ---"
set_run scil_surface_intersections_to_connectivity.py \
    "$flow_vtk" \
    "${results}/${subject}__set_c_filtered.npz" \
    "${work}/${subject}__unique_id.npy" \
    "${results}/${subject}__set_connectivity.npy"

echo "--- H: Surface density ---"
set_run scil_surface_intersections_density.py \
    "$flow_vtk" \
    "${results}/${subject}__set_c_filtered.npz" \
    "${results}/${subject}__set_density.npy" \
    --normalize_l1_to 1

echo "=== SET direct pipeline complete: ${subject} ==="
