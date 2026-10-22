#!/usr/bin/env python
"""Build a bundled demo / test dataset the app can load instantly.

The Docker image ships without flopy / the parser scripts, so demo data must be
pre-processed into the parquet/csv outputs the app loads directly:

    demo/<name>/
      Grid.parquet            sf polygons (nodenumber, nodenumberL1, row/col)
      Heads.parquet           SP, layer, nodenumberL1, h        (scenario)
      Heads_baseline.parquet  same schema                       (optional null)
      Times.csv               time, kstp, kper, SP
      crs_used.txt  sentinels.txt  time_units.txt  start_date.txt  model_type.txt

Geometry + metadata come from a lightweight `--grid` source (a model ZIP or
workspace, processed once via process_model.R). The actual head time-series come
from explicit `--heads` (scenario) and optional `--baseline` (e.g. a no-pumping
"null" run) .hds files, so you can pair a full transient run with its baseline
for drawdown without re-deriving geometry.

`--frames all` keeps every stress period (preserves full seasonality - fine if
you are happy with the size). An integer keeps the first N *consecutive* stress
periods (e.g. 60 = first 5 years of a monthly model), renumbered 1..N.

Usage:
    python scripts/make_demo.py --out demo/hpm --grid data/HPM.zip \
        --model-type mf2005 --heads data/HPM/HPM_M3.hds \
        --baseline data/HPM/HPM_null.hds --frames all
"""
import argparse
import os
import shutil
import subprocess
import tempfile
import zipfile

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
META_FILES = ("crs_used.txt", "sentinels.txt", "time_units.txt", "start_date.txt")


def process_grid_source(grid_src, model_type):
    """Run the normal pipeline on a small grid source to get Grid.parquet + meta.
    Returns the temp dir holding the outputs (caller cleans up)."""
    proc = tempfile.mkdtemp(prefix="demo_grid_")
    src = grid_src
    if grid_src.lower().endswith(".zip"):
        work = tempfile.mkdtemp(prefix="demo_unzip_")
        with zipfile.ZipFile(grid_src) as z:
            z.extractall(work)
        src = work
    cmd = ["conda", "run", "-n", "flopy_env", "Rscript",
           os.path.join(HERE, "process_model.R"), model_type, src, proc]
    print("Grid/meta:", " ".join(cmd))
    subprocess.run(cmd, check=True)
    return proc


def extract_heads(hds_file, usg=False):
    """Read a .hds into (heads_df[SP,layer,nodenumberL1,h], times_df)."""
    import flopy.utils.binaryfile as bf
    recs = []
    if usg:
        hd = bf.HeadUFile(hds_file)
        kp, times, nlay = hd.get_kstpkper(), hd.get_times(), hd.nlay
        for idx, (kstp, kper) in enumerate(kp):
            for lay in range(nlay):
                a = hd.get_data(kstpkper=(kstp, kper), mflay=lay).flatten()
                recs.append(pd.DataFrame({'SP': idx + 1, 'layer': lay + 1,
                                          'nodenumberL1': np.arange(1, len(a) + 1), 'h': a}))
    else:
        hd = bf.HeadFile(hds_file)
        kp, times = hd.get_kstpkper(), hd.get_times()
        for idx, (kstp, kper) in enumerate(kp):
            heads = hd.get_data(kstpkper=(kstp, kper))
            for li in range(heads.shape[0]):
                a = heads[li].flatten()
                recs.append(pd.DataFrame({'SP': idx + 1, 'layer': li + 1,
                                          'nodenumberL1': np.arange(1, len(a) + 1), 'h': a}))
    heads_df = pd.concat(recs, ignore_index=True)
    kp = np.array(kp)
    times_df = pd.DataFrame({'time': np.array(times), 'kstp': kp[:, 0],
                             'kper': kp[:, 1], 'SP': np.arange(1, len(times) + 1)})
    return heads_df, times_df


def keep_set(all_sp, frames):
    if frames == "all" or int(frames) >= len(all_sp):
        return all_sp
    return all_sp[:int(frames)]  # first N consecutive periods (seasonality preserved)


def _is_sentinel(v):
    """Inactive/dry markers: the model's own (e.g. 99999), plus the usual extremes."""
    import math
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return True
    return abs(v) >= 1e29 or abs(v) >= 9e4 or v == 999


def cast_heads(df):
    df = df.copy()
    df['SP'] = df['SP'].astype(np.uint16)
    df['layer'] = df['layer'].astype(np.uint8)
    df['nodenumberL1'] = df['nodenumberL1'].astype(np.uint32)
    df['h'] = df['h'].astype(np.float32)
    return df


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="demo output dir, e.g. demo/hpm")
    ap.add_argument("--grid", required=True, help="grid/meta source: model .zip or workspace dir")
    ap.add_argument("--model-type", required=True, choices=["mf6", "mf2005", "usg"])
    ap.add_argument("--heads", help="scenario .hds (overrides heads from --grid)")
    ap.add_argument("--baseline", help="optional baseline/null .hds for drawdown")
    ap.add_argument("--frames", default="all", help="'all' or first-N stress periods")
    ap.add_argument("--drop-inactive", action="store_true",
                    help="omit rows whose head is a sentinel (inactive/dry cells). "
                         "The app inner-joins heads to the grid and filters these out "
                         "anyway, so dropping them at build time changes nothing on "
                         "screen but cuts the head files by ~60%%. Off by default so "
                         "existing demo bundles keep their exact schema.")
    args = ap.parse_args()
    usg = args.model_type == "usg"

    proc = process_grid_source(args.grid, args.model_type)

    # Scenario heads + times: from --heads if given, else what the grid source produced.
    if args.heads:
        heads_df, times_df = extract_heads(args.heads, usg=usg)
    else:
        heads_df = pd.read_parquet(os.path.join(proc, "Heads.parquet"))
        times_df = pd.read_csv(os.path.join(proc, "Times.csv"))

    all_sp = times_df["SP"].to_numpy()
    keep = keep_set(all_sp, args.frames)
    remap = {int(o): i + 1 for i, o in enumerate(sorted(keep))}
    print(f"Keeping {len(keep)}/{len(all_sp)} stress periods (frames={args.frames}).")

    def subset(df):
        d = df[df["SP"].isin(keep)].copy()
        d["SP"] = d["SP"].map(remap)
        return d

    heads_df = subset(heads_df).sort_values(["SP", "layer", "nodenumberL1"])
    times_df = subset(times_df).sort_values("SP")

    os.makedirs(args.out, exist_ok=True)
    shutil.copy(os.path.join(proc, "Grid.parquet"), os.path.join(args.out, "Grid.parquet"))
    def _maybe_drop(df):
        if not args.drop_inactive:
            return df
        before = len(df)
        keep = df[~df["h"].apply(_is_sentinel)]
        print(f"  dropped {before - len(keep):,} inactive rows "
              f"({100 * len(keep) / max(1, before):.0f}% kept)")
        return keep

    cast_heads(_maybe_drop(heads_df)).to_parquet(
        os.path.join(args.out, "Heads.parquet"),
        compression="zstd", compression_level=9)
    times_df.to_csv(os.path.join(args.out, "Times.csv"), index=False)
    for m in META_FILES:
        s = os.path.join(proc, m)
        if os.path.exists(s):
            shutil.copy(s, os.path.join(args.out, m))
    with open(os.path.join(args.out, "model_type.txt"), "w") as f:
        f.write(args.model_type)

    if args.baseline:
        bh, _ = extract_heads(args.baseline, usg=usg)
        bh = bh[bh["SP"].isin(keep)].copy()
        bh["SP"] = bh["SP"].map(remap)
        bh = bh.sort_values(["SP", "layer", "nodenumberL1"])
        cast_heads(_maybe_drop(bh)).to_parquet(os.path.join(args.out, "Heads_baseline.parquet"),
                                  compression="zstd", compression_level=9)
        print(f"Baseline written ({len(bh)} rows).")

    def mb(p):
        fp = os.path.join(args.out, p)
        return f"{os.path.getsize(fp) / 1e6:.1f} MB" if os.path.exists(fp) else "-"
    print(f"Demo -> {args.out}/  Grid {mb('Grid.parquet')}, "
          f"Heads {mb('Heads.parquet')}, Baseline {mb('Heads_baseline.parquet')}")

    shutil.rmtree(proc, ignore_errors=True)


if __name__ == "__main__":
    main()
