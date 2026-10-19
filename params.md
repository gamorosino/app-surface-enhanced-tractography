# SET++ — Example Parameter Configurations

This document collects suggested parameter sets for different use cases,
derived from published literature. Each configuration includes the source
reference and a brief rationale.

> **Where to set these parameters**
>
> | Parameter | Location |
> |-----------|----------|
> | `nb_seeds`, `nb_iter`, `random_seeds`, `max_parallel_seeds` | `config.json` |
> | `min_length`, `max_length`, `tractography_theta`, `tractography_step`, `tractography_sfthres`, `tractography_algo` | hardcoded defaults in `code/scripts/steps/04_run_set_direct.sh` (lines 113–122) |

---

## 1. Original SET paper — St-Onge et al. (2018)

Whole-brain tractography using one seed per cortical mesh vertex (~250k seeds
total). The paper validates SET on a test-retest dataset (11 subjects, 3
acquisitions each) and focuses on endpoint reproducibility and cortical coverage.

```json
{
  "nb_seeds": 250000,
  "nb_iter": 1,
  "random_seeds": "1",
  "max_parallel_seeds": 1
}
```

`04_run_set_direct.sh` defaults (unchanged from original):

| Parameter | Value |
|-----------|-------|
| `tractography_algo` | `prob` |
| `tractography_step` | `0.2` mm |
| `tractography_theta` | `20.0`° |
| `tractography_sfthres` | `0.1` |
| `min_length` | `10` mm |
| `max_length` | `300` mm |

**Reference:** St-Onge E, Daducci A, Girard G, Descoteaux M.
*Surface-enhanced tractography (SET).* NeuroImage 169 (2018): 524–539.
DOI: [10.1016/j.neuroimage.2017.12.036](https://doi.org/10.1016/j.neuroimage.2017.12.036)

---

## 2. HCP whole-brain — Winter et al. (2020)

Whole-brain structural connectivity on HCP data (1.25 mm isotropic). Uses 3
million surface seeds and a surface-flow parameter `t=75`. The 3M seed count
was chosen based on reproducibility results from Cole et al.
At ~8% tracking acceptance, 3M seeds yield roughly 240k output streamlines.

```json
{
  "nb_seeds": 3000000,
  "nb_iter": 1,
  "random_seeds": "1",
  "max_parallel_seeds": 8
}
```

`04_run_set_direct.sh` settings:

| Parameter | Value | Note |
|-----------|-------|------|
| `tractography_algo` | `prob` | |
| `tractography_step` | `0.2` mm | not explicitly stated in paper |
| `tractography_theta` | `20.0`° | not explicitly stated in paper |
| `tractography_sfthres` | `0.1` | |
| `min_length` | `10` mm | |
| `max_length` | `300` mm | |
| `surf_flow_nb_step` | `75` | paper's flow parameter `t=75` |

**Reference:** Winter A, et al.
*Multi-scale graph principal component analysis for connectomics.*
arXiv 2010.02332 (2020).
URL: [arxiv.org/abs/2010.02332](https://arxiv.org/abs/2010.02332)

**See also:** Cole MW, et al. — reproducibility study that informed the 3M seed choice.

---

## 3. Short association fibers (SAF) — visual cortex

Optimised for capturing short-range U-fibers, particularly in the visual
cortex (V1–V2, V2–V3, V3–hV4). Based on two papers that directly study
visual SAF with sub-millimetre diffusion MRI:

- Movahedian Attar et al. (2024): mean V1–V2 SAF length 12 ± 7 mm (in vivo),
  10 ± 3 mm (post mortem). Minimum length set to 3 mm.
- Movahedian Attar et al. (2025): V2–V3 connections extend the retinotopic
  stream; specificity highest for V1–V2, lower for longer connections.
- Shastin et al. (2022): surface-seeded whole-brain SAF at ≤ 40 mm;
  reports ~26% yield with angle threshold 45°.

```json
{
  "nb_seeds": 2000000,
  "nb_iter": 1,
  "random_seeds": "1,2,3,4,5,6,7,8",
  "max_parallel_seeds": 8
}
```

`04_run_set_direct.sh` settings to change from defaults:

| Parameter | Value | Change from default | Rationale |
|-----------|-------|---------------------|-----------|
| `tractography_algo` | `prob` | — | |
| `tractography_step` | `0.2` mm | — | Confirmed by Movahedian Attar 2024/2025 |
| `tractography_theta` | `30.0`° | **↑ from 20°** | Tight U-fiber bends require higher curvature tolerance; 30° used in both Movahedian Attar papers |
| `tractography_sfthres` | `0.1` | — | |
| `min_length` | `3` mm | **↓ from 10 mm** | V1–V2 mean is 12 ± 7 mm — a 10 mm floor cuts the lower half of the distribution |
| `max_length` | `120` mm | **↓ from 300 mm** | SAF literature cap; reduces false positives from long-range contamination |

> **Important:** lowering `min_length` to 3 mm requires adding an intracortical
> filter (remove streamlines with > 80% of their length inside cortex) to avoid
> streamlines that barely dip into white matter. This filter is used by both
> Movahedian Attar papers but is not yet implemented in SET++.

**Expected yield:** at 3 mm / 30° / 2M seeds/chain (16M total), estimated
~20–30% overall acceptance → ~3.2–4.8M output streamlines.

**References:**

- Movahedian Attar F, et al.
  *Mapping short association fibre connectivity up to V3 in the human brain in vivo.*
  Cerebral Cortex 34 (2024). DOI: [10.1093/cercor/bhae279](https://doi.org/10.1093/cercor/bhae279).
  PMC: [PMC11267744](https://pmc.ncbi.nlm.nih.gov/articles/PMC11267744/)

- Movahedian Attar F, et al.
  *[V1–V2 short association fibers, in vivo and post mortem validation.]* (2025).
  PMC: [PMC12319882](https://pmc.ncbi.nlm.nih.gov/articles/PMC12319882/)

- Shastin D, et al.
  *Surface-based tracking for short association fibre tractography.*
  NeuroImage 260 (2022): 119423. DOI: [10.1016/j.neuroimage.2022.119423](https://doi.org/10.1016/j.neuroimage.2022.119423).
  PMC: [PMC10009610](https://pmc.ncbi.nlm.nih.gov/articles/PMC10009610/)

---

## 4. Our current run — sub-100206 (HCP, 2026-10-15)

Baseline run on HCP subject 100206 using default SET++ parameters.
Produced 323,032 output streamlines from 4M input seeds (~8% acceptance).
Runtime: ~2 h 48 min on 128-CPU EC2 (8 parallel chains).

Rejection analysis:
- Step 1 (seeds → cortical intersection): 20.2% acceptance — 79.8% of seeds
  track into WM but never return to a second cortical surface.
- Step 2 (intersection → length filter): 40.0% acceptance — 60% of surviving
  streamlines are shorter than the 10 mm floor (mostly tight gyral U-shapes).

Uploaded to brainlife.io — Visual White Matter Tracking project
(`5dceb267c4ae281d2c297b92`), dataset `6ad66d5984949766fe5d8eb9`.

```json
{
  "nb_seeds": 500000,
  "nb_iter": 1,
  "random_seeds": "1,2,3,4,5,6,7,8",
  "max_parallel_seeds": 8
}
```

`04_run_set_direct.sh` settings (all defaults):

| Parameter | Value |
|-----------|-------|
| `tractography_algo` | `prob` |
| `tractography_step` | `0.2` mm |
| `tractography_theta` | `20.0`° |
| `tractography_sfthres` | `0.1` |
| `min_length` | `10` mm |
| `max_length` | `300` mm |

---

## Quick comparison

| Config | Seeds (total) | `min_length` | `max_length` | `theta` | Est. output | Runtime (8 chains) |
|--------|--------------|-------------|-------------|---------|-------------|---------------------|
| St-Onge 2018 | 250k | 10 mm | 300 mm | 20° | ~20k | ~40 min |
| Our baseline | 4M | 10 mm | 300 mm | 20° | 323k | ~2 h 48 min |
| HCP / Winter 2020 | 3M | 10 mm | 300 mm | 20° | ~240k | ~2 h |
| SAF / visual cortex | 16M | **3 mm** | **120 mm** | **30°** | ~3–5M | ~12–16 h |
