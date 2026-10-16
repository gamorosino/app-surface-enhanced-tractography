#!/usr/bin/env python
"""
Parallel seed-splitting wrapper for scil_surface_pft_dipy.py.

Takes the same positional and optional arguments, plus --processes N.
When N > 1: splits the surface_seeds .npz into N equal chunks, runs N
sub-processes of scil_surface_pft_dipy.py in parallel (one per chunk),
then merges the resulting .trk files into the final output.
When N == 1: transparently exec()s the original script (no overhead).
"""
from __future__ import print_function

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

import nibabel as nib
import numpy as np

ORIG_SCRIPT = '/scilpy/scripts/scil_surface_pft_dipy.py'
PYTHON = sys.executable


def build_parser():
    p = argparse.ArgumentParser(add_help=False)
    # Mirror the six positional args of scil_surface_pft_dipy.py so we can
    # extract surface_seeds and output_file without re-implementing the full parser.
    p.add_argument('sh_file')
    p.add_argument('map_include_file')
    p.add_argument('map_exclude_file')
    p.add_argument('surface')
    p.add_argument('surface_seeds')
    p.add_argument('output_file')
    p.add_argument('--processes', type=int, default=1,
                   help='Parallel sub-processes for internal seed splitting [%(default)s]')
    return p


def split_seeds_npz(npz_path, n_chunks, tmpdir):
    data = np.load(npz_path)
    tri_idx = data['tri_idx']
    tri_coord = data['tri_coord']
    n = len(tri_idx)
    n_chunks = min(n_chunks, n)
    idx_splits = np.array_split(np.arange(n), n_chunks)
    paths = []
    for i, idx in enumerate(idx_splits):
        chunk_path = os.path.join(tmpdir, 'seeds_chunk_{:04d}.npz'.format(i))
        np.savez(chunk_path,
                 tri_idx=tri_idx[idx],
                 tri_coord=tri_coord[idx])
        paths.append(chunk_path)
    return paths


def merge_trk(chunk_trk_paths, output_file):
    all_streamlines = []
    ref_trk = None
    for p in chunk_trk_paths:
        if not os.path.exists(p):
            print('WARNING: chunk output missing: {}'.format(p), file=sys.stderr)
            continue
        loaded = nib.streamlines.load(p)
        if ref_trk is None:
            ref_trk = loaded
        all_streamlines.extend(list(loaded.streamlines))
    if ref_trk is None:
        raise RuntimeError('No chunk .trk outputs found to merge')
    tractogram = nib.streamlines.Tractogram(
        all_streamlines,
        affine_to_rasmm=ref_trk.affine)
    # Preserve header by wrapping in the same file-type object
    out_file = ref_trk.__class__(tractogram, header=ref_trk.header)
    nib.streamlines.save(out_file, output_file)
    print('Merged {} streamlines from {} chunks -> {}'.format(
        len(all_streamlines), len(chunk_trk_paths), output_file))


def main():
    parser = build_parser()
    args, extra_flags = parser.parse_known_args()

    if args.processes <= 1:
        # Zero overhead pass-through
        cmd = ([PYTHON, ORIG_SCRIPT,
                args.sh_file, args.map_include_file, args.map_exclude_file,
                args.surface, args.surface_seeds, args.output_file]
               + extra_flags)
        os.execv(PYTHON, cmd)

    # Overwrite check (mirrors scil_surface_pft_dipy.py behaviour)
    if os.path.exists(args.output_file) and '-f' not in extra_flags:
        print('ERROR: output file exists, use -f to overwrite: {}'.format(
            args.output_file), file=sys.stderr)
        sys.exit(1)

    tmpdir = tempfile.mkdtemp(prefix='pft_par_')
    try:
        chunk_seeds_paths = split_seeds_npz(
            args.surface_seeds, args.processes, tmpdir)
        n_chunks = len(chunk_seeds_paths)
        chunk_trk_paths = [
            os.path.join(tmpdir, 'out_{:04d}.trk'.format(i))
            for i in range(n_chunks)
        ]

        print('scil_surface_pft_parallel: {} processes, {} seed chunks'.format(
            args.processes, n_chunks))

        procs = []
        for chunk_seeds, chunk_trk in zip(chunk_seeds_paths, chunk_trk_paths):
            cmd = ([PYTHON, ORIG_SCRIPT,
                    args.sh_file, args.map_include_file, args.map_exclude_file,
                    args.surface, chunk_seeds, chunk_trk]
                   + extra_flags)
            procs.append(subprocess.Popen(cmd))

        failed = []
        for i, proc in enumerate(procs):
            rc = proc.wait()
            if rc != 0:
                failed.append(i)

        if failed:
            print('ERROR: PFT chunks {} failed'.format(failed), file=sys.stderr)
            sys.exit(1)

        merge_trk(chunk_trk_paths, args.output_file)

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == '__main__':
    main()
