# SET — Surface-Enhanced Tractography

Registers a subject's T1w to DWI space, computes (or reuses) a fiber
orientation distribution function (FODF), and runs surface-guided
probabilistic tractography seeded from FreeSurfer white matter surfaces,
producing one whole-brain tractogram.

This is a brainlife.io app adaptation of the original SET method's reference
implementation ([StongeEtienne/set-nf](https://github.com/StongeEtienne/set-nf)).

## Citation

If you use this app, please cite the original SET method:

> St-Onge, Etienne, et al. "Surface-enhanced tractography (SET)." *NeuroImage* 169 (2018): 524-539.

Original SET implementation: https://github.com/StongeEtienne/set-nf

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

Locally: copy `config.json.example` to `config.json`, fill in real file
paths, then run `./main` from this directory. Needs Singularity, not Docker,
installed locally (`main` calls `singularity exec docker://...` — Singularity
pulls and caches the image itself).


## License

MIT, see `LICENSE`.
