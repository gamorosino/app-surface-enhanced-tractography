<h1 align="center">Surface-Enhanced Tractography (SET)</h1>

<p align="center">
  Generates a whole-brain tractogram with Surface-Enhanced Tractography (SET), seeding probabilistic tracking from FreeSurfer white matter surfaces, after registering the T1w to DWI with ANTs and computing FODFs with scilpy.
</p>

<p align="center">
  <a href="https://github.com/brainlife/abcd-spec"><img src="https://img.shields.io/badge/ABCD_Spec-v1.1-green.svg" alt="ABCD Spec v1.1"></a>
  <a href="https://doi.org/10.25663/brainlife.app.951"><img src="https://img.shields.io/badge/Brainlife-brainlife.app.951-blue.svg" alt="Run on brainlife.io"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-see_LICENSE-lightgrey.svg" alt="License"></a>
</p>

## At a glance

<!-- brainlife-app:begin (generated from the App manifest; edit the manifest, not this block) -->

> **Generates a whole-brain tractogram with Surface-Enhanced Tractography (SET), seeding probabilistic tracking from FreeSurfer white matter surfaces, after registering the T1w to DWI with ANTs and computing FODFs with scilpy.**

Registers the T1w to DWI space with ANTs (SyN, or affine only with linear_transformation), computes an order-8 FODF with scilpy unless one is supplied, and runs the SET engine (freesurfer_a2009s_proper profile only) for several random-seed chains, then concatenates them into one tractogram. Use it for surface-informed whole-brain tractography with better cortical terminations. Needs preprocessed DWI, FA, an ACPC-aligned T1w, a FreeSurfer directory and a 5TT mask (vol2 used as WM include, vol3 as CSF exclude).

| | |
|---|---|
| **Inputs** | `neuro/dwi` · `neuro/freesurfer` · `neuro/tensor` · `neuro/anat/t1w` · `neuro/mask` · `neuro/csd` (optional) · `neuro/transform/nifti` (optional) |
| **Outputs** | `neuro/track/tck` · `neuro/csd` · `neuro/transform/nifti` |
| **Container** | `gamorosino/ensemble_tracking:latest` |
| **Resources** | 8 CPUs · 16 GB memory · 15 h walltime |
| **Run it** | [doi.org/10.25663/brainlife.app.951](https://doi.org/10.25663/brainlife.app.951) |

#### Inputs

| Input | Datatype | Required | Description |
|---|---|---|---|
| `dwi` | `neuro/dwi` | yes | Preprocessed DWI with bvecs and bvals. |
| `freesurfer` | `neuro/freesurfer` | yes | FreeSurfer subject directory whose white matter surfaces seed tracking. |
| `tensor` | `neuro/tensor` | yes | Tensor dataset; only the FA map is used. |
| `t1` | `neuro/anat/t1w` | yes | ACPC-aligned T1-weighted image registered to DWI space. |
| `mask_5tt` | `neuro/mask` (5tt) | yes | 4D five-tissue-type mask. Brainlife 5tt ordering: volume 2 is white matter (include), volume 3 is CSF (exclude). |
| `fodf` | `neuro/csd` | no | Optional precomputed FODF (SH order 8, descoteaux07 basis); skips FODF computation. |
| `t1_transform` | `neuro/transform/nifti` | no | Optional precomputed T1-to-DWI ANTs transform; skips registration. Warp, inverse warp and affine must all be given together. |

#### Outputs

| Output | Datatype | Description |
|---|---|---|
| `tractogram` | `neuro/track/tck` | Final concatenated whole-brain tractogram from Surface-Enhanced Tractography (all 8 random-seed chains concatenated). |
| `fodf` | `neuro/csd` | FODF (SH order 8, descoteaux07 basis) -- only produced when the fodf input wasn't already given. |
| `t1_transform` | `neuro/transform/nifti` | T1-to-DWI ANTs registration transform -- only produced when the t1_transform input wasn't already given. |

<details>
<summary><b>Parameters</b> (6)</summary>

| Parameter | Type | Default | Description |
|---|---|---|---|
| `random_seeds` | string | `1,2,3,4,5,6,7,8` | Comma-separated random seeds for SET tracking chains. |
| `nb_iter` | number | `1` | Dynamic seeding iterations per random seed. |
| `nb_seeds` | number | `500000` | Seeds per iteration. |
| `max_parallel_seeds` | number | `4` | Concurrent random-seed tracking chains. |
| `linear_transformation` | boolean | `false` | Register T1 to DWI with an affine transform only (no SyN) and pass --transf-linear to SET. |
| `ants_verbose` | boolean | `false` | Enable ANTs registration verbose output (produces very large logs; useful for debugging only). |

</details>

<!-- brainlife-app:end -->

## Running the App

### On brainlife.io

Open the App at [doi.org/10.25663/brainlife.app.951](https://doi.org/10.25663/brainlife.app.951), choose `neuro/dwi`, `neuro/freesurfer`, `neuro/tensor`, `neuro/anat/t1w`, `neuro/mask`, `neuro/csd`, `neuro/transform/nifti` from your project, set the parameters and press **Execute**. The results are saved to your project as `neuro/track/tck`, `neuro/csd`, `neuro/transform/nifti`.

### Locally

You need [Singularity/Apptainer](https://apptainer.org/) (the App runs in `gamorosino/ensemble_tracking:latest`), [`jq`](https://jqlang.github.io/jq/).

1. Clone this repository.
2. Create `config.json` with the paths to your inputs and the parameters:

   ```json
   {
       "dwi": "/path/to/dwi/dwi",
       "bvecs": "/path/to/dwi/bvecs",
       "bvals": "/path/to/dwi/bvals",
       "freesurfer": "/path/to/freesurfer/freesurfer",
       "fa": "/path/to/tensor/fa",
       "t1": "/path/to/t1/t1",
       "mask_5tt": "/path/to/mask_5tt/mask_5tt",
       "fodf_lmax8": "/path/to/fodf/fodf_lmax8",
       "fodf_response": "/path/to/fodf/fodf_response",
       "t1_warp": "/path/to/t1_transform/t1_warp",
       "t1_inv_warp": "/path/to/t1_transform/t1_inv_warp",
       "t1_affine": "/path/to/t1_transform/t1_affine",
       "random_seeds": "1,2,3,4,5,6,7,8",
       "nb_iter": 1,
       "nb_seeds": 500000,
       "max_parallel_seeds": 4,
       "linear_transformation": false,
       "ants_verbose": false
   }
   ```

3. Run `./main`.

## SET++ — Reimplementation & Acceleration

The original `set-nf` pipeline runs under Nextflow with Singularity and caps
every tracking process at a single CPU (`ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=1`,
`OMP_NUM_THREADS=1`, etc.), relying entirely on Nextflow's scheduler for
inter-task parallelism.

This reimplementation introduces two orthogonal parallelism axes:

| Parameter | What it controls | Original |
|---|---|---|
| `max_parallel_seeds` | Number of random-seed chains running simultaneously (one container each) | Nextflow scheduler only |
| `tracking_processes` | Sub-processes spawned *inside* each tracking container, splitting seed points | 1 (fixed) |

These compose multiplicatively: `max_parallel_seeds=32` × `tracking_processes=4`
fills all 128 cores of a 128-CPU machine simultaneously, reducing PFT tracking
time from ~91 min (single-process) to ~23 min, with a total pipeline wall time
of ~100 min for 32 seeds.

A `main_local.sh` entry point mirrors `main` but uses Docker instead of
Singularity, enabling local execution on machines without Singularity or root
access.

## Parameter configurations

Example configurations for different use cases (whole-brain connectivity,
HCP data, short association fibers / visual cortex) with source references
are documented in [`params.md`](params.md).

## Scope

- **Only the `freesurfer_a2009s_proper` profile is supported.** The original
  repo also offers a Nextflow pipeline with 7 other profiles
  (`freesurfer_basic`, `freesurfer_proper`, `freesurfer_a2009s_basic`,
  `civet2_dkt`, `civet2_aal`, `vtk`); this app always uses the direct/Docker
  execution path (`04_run_set_direct.sh`), which only replicates
  `freesurfer_a2009s_proper`.
- **5TT tissue ordering fixed vs. the original repo.** `run_tracking.sh`
  assumes `vol0=CSF/exclude, vol3=WM/include`; this is backwards from the
  official brainlife `neuro/mask` `5tt` tag convention
  (`0=cortical-GM, 1=subcortical-GM, 2=WM/brainstem, 3=CSF/ventricles`) —
  confirmed against two independent real 5tt datasets (voxelwise Dice >0.8
  between vol2 and a separately-provided `wm.nii.gz`, and between vol3 and
  `csf.nii.gz`). This app uses `vol2=WM/include, vol3=CSF/exclude` — the
  corrected indices, not the original script's.

## Containers

No Dockerfile lives in this repo — three already-built images are chained via
sequential `singularity exec` calls from `main`:

- `docker://gamorosino/ensemble_tracking:latest` — ANTs 2.2/2.3, mrtrix3
  3.0.3, python/nibabel/dipy. Built from the source repo's own
  `docker/ensemble_tracking/Dockerfile` (a conda-pack of the
  `ensemble_tracking` environment).
- `docker://scilus/scilus:1.6.0` — FODF computation and every scilpy
  surface/tractography call.
- `docker://gamorosino/set_1v1:latest` — the SET tracking engine itself.

## Citing

If you use this App, please cite it, the software it builds on and brainlife.io:

- Surface-Enhanced Tractography (SET). brainlife.io App. [doi:10.25663/brainlife.app.951](https://doi.org/10.25663/brainlife.app.951)
- St-Onge E, Daducci A, Girard G, Descoteaux M. Surface-enhanced tractography (SET). NeuroImage 169:524-539 (2018). [doi:10.1016/j.neuroimage.2017.12.036](https://doi.org/10.1016/j.neuroimage.2017.12.036)
- Fischl. FreeSurfer. *NeuroImage* 62:774-781 (2012). [doi:10.1016/j.neuroimage.2012.01.021](https://doi.org/10.1016/j.neuroimage.2012.01.021)
- Tournier et al. MRtrix3: A fast, flexible and open software framework for medical image processing and visualisation. *NeuroImage* 202:116137 (2019). [doi:10.1016/j.neuroimage.2019.116137](https://doi.org/10.1016/j.neuroimage.2019.116137)
- Avants et al. A reproducible evaluation of ANTs similarity metric performance in brain image registration. *NeuroImage* 54:2033-2044 (2011). [doi:10.1016/j.neuroimage.2010.09.025](https://doi.org/10.1016/j.neuroimage.2010.09.025)
- Hayashi S, Caron BA, Heinsfeld AS, et al. brainlife.io: a decentralized and open-source cloud platform to support neuroscience research. *Nature Methods* 21:809–813 (2024). [doi:10.1038/s41592-024-02237-2](https://doi.org/10.1038/s41592-024-02237-2)
- Avesani P, McPherson B, Hayashi S, et al. The open diffusion data derivatives, brain data upcycling via integrated publishing of derivatives and reproducible open cloud services. *Scientific Data* 6:69 (2019). [doi:10.1038/s41597-019-0073-y](https://doi.org/10.1038/s41597-019-0073-y)

## Authors

- Gabriele Amorosino

**Contributors**

- Sydney Fulton

## License

See [LICENSE](LICENSE).
