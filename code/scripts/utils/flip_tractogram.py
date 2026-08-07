#!/usr/bin/env python3
import argparse, os
import numpy as np
import nibabel as nib
from nibabel.streamlines import load, save, Tractogram

AXIS = {"x": 0, "y": 1, "z": 2}

def parse_axes(s):
    parts = [p.strip().lower() for p in s.replace(" ", "").split(",") if p.strip()]
    if not parts:
        raise argparse.ArgumentTypeError("Provide at least one axis, e.g. 'x' or 'x,y'")
    for p in parts:
        if p not in AXIS:
            raise argparse.ArgumentTypeError(f"Invalid axis '{p}'. Use x,y,z.")
    # dedupe, keep order
    out, seen = [], set()
    for p in parts:
        if p not in seen:
            out.append(p); seen.add(p)
    return out

def main():
    ap = argparse.ArgumentParser(
        description="Flip selected axes of a .tck/.trk by multiplying coordinates by -1 (origin flip only)."
    )
    ap.add_argument("input", help="Input tractogram (.tck or .trk)")
    ap.add_argument("output", help="Output tractogram (.tck or .trk)")
    ap.add_argument("--axes", type=parse_axes, required=True,
                    help="Comma list of axes to flip, e.g. 'x', 'y,z', or 'x,y,z'")
    args = ap.parse_args()

    if not os.path.exists(args.input):
        ap.error(f"Input not found: {args.input}")

    obj = load(args.input)
    tr = obj.tractogram

    idxs = [AXIS[a] for a in args.axes]

    # flip coordinates only
    flipped_streams = []
    for s in tr.streamlines:
        a = np.asarray(s, dtype=np.float32).copy()
        for i in idxs:
            a[:, i] *= -1.0
        flipped_streams.append(a)

    flipped = Tractogram(
        flipped_streams,
        affine_to_rasmm=getattr(tr, "affine_to_rasmm", None),
        data_per_point=tr.data_per_point,
        data_per_streamline=tr.data_per_streamline,
    )

    save(flipped, args.output)
    print(f"wrote {args.output}")

if __name__ == "__main__":
    main()

