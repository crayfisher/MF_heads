#!/usr/bin/env python
"""Create and run a "null" variant of a MODFLOW-2005 model.

A null run drops one or more stress packages (typically WEL, i.e. no pumping) so
its heads can serve as a *baseline* for drawdown = baseline - scenario. It does
NOT touch the original inputs: it only writes a new name file in the same model
workspace with the chosen packages removed and the output files renamed, then
runs MODFLOW so the scenario outputs are never overwritten.

Usage:
    python scripts/make_null_run.py <model_ws> <nam_file> <out_base> \
        [--remove WEL[,DRN,...]] [--exe mf2005] [--no-run]

Example (HPM, no wells):
    python scripts/make_null_run.py data/HPM HPM_M3.nam HPM_null --remove WEL
"""
import argparse
import os
import subprocess
import sys


def build_null_nam(model_ws, nam_file, out_base, remove):
    remove = {r.upper() for r in remove}
    src = os.path.join(model_ws, nam_file)
    out_nam = os.path.join(model_ws, out_base + ".nam")
    new_lines = []
    dropped, renamed = [], []
    with open(src) as f:
        for line in f:
            raw = line.rstrip("\n")
            if not raw.strip() or raw.lstrip().startswith("#"):
                new_lines.append(raw)
                continue
            toks = raw.split()
            ftype = toks[0].upper()
            if ftype in remove:
                dropped.append(toks[0])
                continue
            # Redirect outputs: LIST + DATA(BINARY)/DATA listing/output files.
            if (ftype == "LIST" or ftype.startswith("DATA")) and len(toks) >= 3:
                ext = os.path.splitext(os.path.basename(toks[2]))[1]
                toks[2] = out_base + ext
                renamed.append(toks[2])
                raw = " ".join(toks)
            new_lines.append(raw)
    with open(out_nam, "w") as f:
        f.write("\n".join(new_lines) + "\n")
    print(f"Wrote {out_nam}\n  dropped packages: {dropped}\n  outputs: {renamed}")
    return out_nam


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model_ws")
    ap.add_argument("nam_file")
    ap.add_argument("out_base")
    ap.add_argument("--remove", default="WEL")
    ap.add_argument("--exe", default="mf2005")
    ap.add_argument("--no-run", action="store_true")
    args = ap.parse_args()

    remove = [r for r in args.remove.split(",") if r]
    out_nam = build_null_nam(args.model_ws, args.nam_file, args.out_base, remove)

    if args.no_run:
        return
    print(f"Running {args.exe} {os.path.basename(out_nam)} in {args.model_ws} ...")
    res = subprocess.run([args.exe, os.path.basename(out_nam)],
                         cwd=args.model_ws, capture_output=True, text=True)
    tail = "\n".join(res.stdout.strip().splitlines()[-8:])
    print(tail)
    hds = os.path.join(args.model_ws, args.out_base + ".hds")
    if "Normal termination" in res.stdout and os.path.exists(hds):
        print(f"SUCCESS -> {hds}")
    else:
        print(f"NON-NORMAL termination (rc={res.returncode}). stderr:\n{res.stderr[-500:]}")
        sys.exit(1)


if __name__ == "__main__":
    main()
