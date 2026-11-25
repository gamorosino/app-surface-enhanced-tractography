# SET++ — Surface-Enhanced Tractography Plus

<!-- brainlife-app:begin (generated from the App manifest; edit the manifest, not this block) -->

> **Generates a whole-brain tractogram with Surface-Enhanced Tractography (SET), seeding probabilistic tracking from FreeSurfer white matter surfaces, after registering the T1w to DWI with ANTs and computing FODFs with scilpy.**

Registers the T1w to DWI space with ANTs (SyN, or affine only with linear_transformation), computes an order-8 FODF with scilpy unless one is supplied, and runs the SET engine (freesurfer_a2009s_proper profile only) for several random-seed chains, then concatenates them into one tractogram. Use it for surface-informed whole-brain tractography with better cortical terminations. Needs preprocessed DWI, FA, an ACPC-aligned T1w, a FreeSurfer directory and a 5TT mask (vol2 used as WM include, vol3 as CSF exclude).

| | |
|---|---|
| 📥 **Inputs** | `neuro/dwi` · `neuro/freesurfer` · `neuro/tensor` · `neuro/anat/t1w` · `neuro/mask` · `neuro/csd` (optional) · `neuro/transform/nifti` (optional) |
| 📤 **Outputs** | `neuro/track/tck` · `neuro/csd` · `neuro/transform/nifti` |
| 🐳 **Container** | `gamorosino/ensemble_tracking:latest` |
| ⚙️ **Resources** | 8 CPUs · 16 GB memory · 15 h walltime |
| 🔗 **Run it** | [doi.org/10.25663/brainlife.app.951](https://doi.org/10.25663/brainlife.app.951) |

#### 📥 Inputs

| Input | Datatype | Required | Description |
|---|---|---|---|
| `dwi` | `neuro/dwi` | yes | Preprocessed DWI with bvecs and bvals. |
| `freesurfer` | `neuro/freesurfer` | yes | FreeSurfer subject directory whose white matter surfaces seed tracking. |
| `tensor` | `neuro/tensor` | yes | Tensor dataset; only the FA map is used. |
| `t1` | `neuro/anat/t1w` | yes | ACPC-aligned T1-weighted image registered to DWI space. |
| `mask_5tt` | `neuro/mask` (5tt) | yes | 4D five-tissue-type mask. Brainlife 5tt ordering: volume 2 is white matter (include), volume 3 is CSF (exclude). |
| `fodf` | `neuro/csd` | no | Optional precomputed FODF (SH order 8, descoteaux07 basis); skips FODF computation. |
| `t1_transform` | `neuro/transform/nifti` | no | Optional precomputed T1-to-DWI ANTs transform; skips registration. Warp, inverse warp and affine must all be given together. |

#### 📤 Outputs

| Output | Datatype | Description |
|---|---|---|
| `tractogram` | `neuro/track/tck` | Final concatenated whole-brain tractogram from Surface-Enhanced Tractography (all 8 random-seed chains concatenated). |
| `fodf` | `neuro/csd` | FODF (SH order 8, descoteaux07 basis) -- only produced when the fodf input wasn't already given. |
| `t1_transform` | `neuro/transform/nifti` | T1-to-DWI ANTs registration transform -- only produced when the t1_transform input wasn't already given. |

<details>
<summary><b>⚙️ Parameters</b> (6)</summary>

| Parameter | Type | Default | Description |
|---|---|---|---|
| `random_seeds` | string | `1,2,3,4,5,6,7,8` | Comma-separated random seeds for SET tracking chains. |
| `nb_iter` | number | `1` | Dynamic seeding iterations per random seed. |
| `nb_seeds` | number | `500000` | Seeds per iteration. |
| `max_parallel_seeds` | number | `4` | Concurrent random-seed tracking chains. |
| `linear_transformation` | boolean | `false` | Register T1 to DWI with an affine transform only (no SyN) and pass --transf-linear to SET. |
| `ants_verbose` | boolean | `false` | Enable ANTs registration verbose output (produces very large logs; useful for debugging only). |

</details>

📚 **References used by this App:**
- St-Onge E, Daducci A, Girard G, Descoteaux M. Surface-enhanced tractography (SET). NeuroImage 169:524-539 (2018). [doi:10.1016/j.neuroimage.2017.12.036](https://doi.org/10.1016/j.neuroimage.2017.12.036)

<!-- brainlife-app:end -->

Registers a subject's T1w to DWI space, computes (or reuses) a fiber
orientation distribution function (FODF), and runs surface-guided
probabilistic tractography seeded from FreeSurfer white matter surfaces,
producing one whole-brain tractogram.

SET++ is a reimplementation and acceleration of the original SET Nextflow
pipeline ([StongeEtienne/set-nf](https://github.com/StongeEtienne/set-nf)),
ported to brainlife.io and restructured for high-throughput local execution
without Nextflow or Singularity on systems where only Docker is available.

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

## Citation

If you use this app, please cite the original SET method:

> St-Onge, Etienne, et al. "Surface-enhanced tractography (SET)." *NeuroImage* 169 (2018): 524-539.

Original SET implementation: https://github.com/StongeEtienne/set-nf

## Parameter configurations

Example configurations for different use cases (whole-brain connectivity,
HCP data, short association fibers / visual cortex) with source references
are documented in [`params.md`](params.md).

## Authors

- Gabriele Amorosino

## Contributors

- Sydney Fulton
  
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

## Inputs

- `dwi` (`neuro/dwi`) — preprocessed DWI: `dwi.nii.gz`/`.bvecs`/`.bvals`
- `freesurfer` (`neuro/freesurfer`) — FreeSurfer `output/` directory
- `tensor` (`neuro/tensor`) — only the `fa` (fractional anisotropy) file is used
- `t1` (`neuro/anat/t1w`) — T1w, ACPC-aligned
- `mask_5tt` (`neuro/mask`, tag `5tt`) — 4D five-tissue-type mask

Optional (skip the corresponding computation when given):

- `fodf` (`neuro/csd`, `lmax8` file — SH order 8, `descoteaux07` basis) —
  precomputed FODF
- `t1_transform` (`neuro/transform/nifti`) — precomputed T1→DWI ANTs
  registration (`warp`/`inverse-warp`/`affine`, all three required together)

## Outputs

- `tractogram` (`neuro/track/tck`) — the final concatenated whole-brain
  tractogram (`all_sets_flipXY_concatenated.tck` in the original pipeline)
- `fodf` (`neuro/csd`) — only produced if `fodf` wasn't given as input
- `t1_transform` (`neuro/transform/nifti`) — only produced if `t1_transform`
  wasn't given as input

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

## Usage

Brainlife.io: run via `braise-app-run`/`braise-app-pipeline` once registered
with `braise-app-create`, or the web UI.

Locally with Singularity: copy `config.json.example` to `config.json`, fill
in real file paths, then run `./main` from this directory. Singularity pulls
and caches the images automatically.

Locally with Docker (no Singularity or root required): use `./main_local.sh`
instead. Both scripts read the same `config.json` keys, including
`max_parallel_seeds` and `tracking_processes`.


## License

MIT, see `LICENSE`.
