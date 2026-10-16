#!/usr/bin/env python3
"""Flip tractogram streamline coordinates along specified axes."""
import argparse
import numpy as np
import nibabel as nib


def main():
    p = argparse.ArgumentParser(description='Flip tractogram axes')
    p.add_argument('input', help='Input tractogram (.tck or .trk)')
    p.add_argument('output', help='Output tractogram (.tck or .trk)')
    p.add_argument('--axes', default='x,y',
                   help='Comma-separated axes to negate: x, y, z [%(default)s]')
    args = p.parse_args()

    flip_axes = {a.strip().lower() for a in args.axes.split(',')}
    flip_vector = np.array([
        -1.0 if 'x' in flip_axes else 1.0,
        -1.0 if 'y' in flip_axes else 1.0,
        -1.0 if 'z' in flip_axes else 1.0,
    ])

    trk = nib.streamlines.load(args.input)
    flipped = [s * flip_vector for s in trk.streamlines]

    tractogram = nib.streamlines.Tractogram(
        flipped,
        affine_to_rasmm=trk.affine)
    # Preserve header by wrapping in the same file-type object
    out_file = trk.__class__(tractogram, header=trk.header)
    nib.streamlines.save(out_file, args.output)
    print('Flipped {} streamlines ({}) -> {}'.format(
        len(flipped), args.axes, args.output))


if __name__ == '__main__':
    main()
