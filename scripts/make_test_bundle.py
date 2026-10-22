"""Write a small SYNTHETIC review bundle, for tests and for trying the app.

A review bundle is one folder of plain tables describing one model run
(grid, heads, CLN heads, pumping, targets, parameter fields). Real bundles are
written by a model project's own exporter; this script writes a tiny made-up
one with the same layout and columns, so the app can be tested without any
real model data.

The synthetic model is deliberately awkward in the ways real unstructured
(MODFLOW-USG) models are:

* two layers with DIFFERENT cells: layer 1 is a 6 x 6 grid of 100 m cells
  (36 nodes), layer 2 a 3 x 3 grid of 200 m cells (9 nodes), so
  ``nodenumberL1 = i`` in layer 2 is NOT under ``nodenumberL1 = i`` in layer 1;
* two chained segments (6 + 4 = 10 periods of 30 days) on one global timeline;
* one dry cell (head NA from period 6) and one inactive cell (NA throughout);
* four CLN nodes: three trench sections (lines) and one bore (point), one
  section switched off in segment 1, and a pumped well that moves between sections;
* three target sites in two groups, observed on some periods only, and raw
  measurements behind them (a daily logger and monthly dips at S1, a survey
  at S3, none at S2).

Usage (flopy_py_env):
    python scripts/make_test_bundle.py <out_dir>

Output: <out_dir>/manifest.json, Grid.parquet, Times.csv, Heads.parquet,
Heads_baseline.parquet, CLN_nodes.parquet, CLN_heads.parquet, Pumping.parquet,
Sites.parquet, Targets.parquet, Observations.parquet, Fields.parquet.
Units: m, m/d, m3/d, days.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd
from shapely.geometry import LineString, Point, box

# A neutral projected CRS (UTM zone 33N) and an arbitrary origin; nothing here
# refers to a real place or model.
CRS = "EPSG:32633"
X0, Y0 = 500_000.0, 6_000_000.0  # lower-left corner of the model, m
START_DATE = "2020-01-01"
PERIOD_DAYS = 30
SEGMENTS = [(1, 6), (2, 4)]  # (segment number, periods in that segment)
LAYERS = [(1, 6, 100.0), (2, 3, 200.0)]  # (layer, cells per side, cell size m)
DRY_FROM_SP = 6  # layer 1, nodenumberL1 1 goes dry from this period on
INACTIVE_L2 = 9  # layer 2, nodenumberL1 9 is inactive throughout


def make_grid() -> gpd.GeoDataFrame:
    """Cell polygons for both layers.

    Returns one row per node: nodenumber (1-based over all layers),
    layer (1-based), nodenumberL1 (1-based within its layer), top, bot (m),
    area (m2), zone, geometry. Rows run north to south, then west to east, as
    MODFLOW numbers them.
    """
    rows = []
    nodenumber = 0
    for layer, n_side, size in LAYERS:
        nl1 = 0
        for i in range(n_side):  # i = 0 is the NORTH row (0-based Python index)
            for j in range(n_side):
                nodenumber += 1
                nl1 += 1
                ymax = Y0 + 600.0 - i * size
                xmin = X0 + j * size
                rows.append(
                    {
                        "nodenumber": nodenumber,
                        "layer": layer,
                        "nodenumberL1": nl1,
                        "top": 100.0 if layer == 1 else 60.0,
                        "bot": 60.0 if layer == 1 else 0.0,
                        "area": size * size,
                        "zone": 1 + (j * size >= 300.0),
                        "geometry": box(xmin, ymax - size, xmin + size, ymax),
                    }
                )
    return gpd.GeoDataFrame(rows, geometry="geometry", crs=CRS)


def make_times() -> pd.DataFrame:
    """One row per global stress period.

    Returns SP (1-based, global), time (days from START_DATE to the period's
    end), date_start, date_end (ISO dates), segment, kper (1-based period
    within its segment).
    """
    start = pd.Timestamp(START_DATE)
    rows = []
    sp = 0
    for segment, nper in SEGMENTS:
        for kper in range(1, nper + 1):
            sp += 1
            t_end = sp * PERIOD_DAYS
            rows.append(
                {
                    "SP": sp,
                    "time": float(t_end),
                    "date_start": (start + pd.Timedelta(days=t_end - PERIOD_DAYS))
                    .date()
                    .isoformat(),
                    "date_end": (start + pd.Timedelta(days=t_end)).date().isoformat(),
                    "segment": segment,
                    "kper": kper,
                }
            )
    return pd.DataFrame(rows)


def head_at(x: float, y: float, layer: int, sp: int) -> float:
    """Synthetic head (m): a west-to-east gradient, a seasonal swing and a
    slow decline. x, y are cell-centre coordinates (m)."""
    return (
        100.0
        - 0.02 * (x - X0)
        - 0.3 * layer
        + 0.5 * np.sin(sp)
        - 0.1 * sp
        + 0.001 * (y - Y0)
    )


def make_heads(
    grid: gpd.GeoDataFrame, times: pd.DataFrame, baseline: bool = False
) -> pd.DataFrame:
    """Long table SP, layer, nodenumberL1, h (m). Dry/inactive cells are NA.

    The baseline run is higher by 0.2 m plus a small eastward rise, so
    run - baseline varies across the model.
    """
    centres = grid.geometry.centroid
    rows = []
    for sp in times["SP"]:
        for k, cell in enumerate(grid.itertuples()):
            x, y = centres.iloc[k].x, centres.iloc[k].y  # iloc: 0-based position
            h = head_at(x, y, cell.layer, sp)
            if baseline:
                h += 0.2 + 0.001 * (x - X0)
            dry = (
                cell.layer == 1
                and cell.nodenumberL1 == 1
                and sp >= DRY_FROM_SP
                and not baseline
            )
            inactive = cell.layer == 2 and cell.nodenumberL1 == INACTIVE_L2
            rows.append(
                {
                    "SP": int(sp),
                    "layer": int(cell.layer),
                    "nodenumberL1": int(cell.nodenumberL1),
                    "h": np.nan if (dry or inactive) else h,
                }
            )
    df = pd.DataFrame(rows)
    df["h"] = df["h"].astype("float32")
    return df


def make_cln_nodes(grid: gpd.GeoDataFrame) -> gpd.GeoDataFrame:
    """Three trench sections (lines along layer-1 row 3) and one bore (point).

    bed_p1 / bed_p2 are the bed level (m) in segments 1 and 2; for the bore it
    is the CLN bottom. gw_node is the 1-based global node the CLN connects to.
    """
    y = Y0 + 600.0 - 250.0  # centre line of layer-1 row 3
    sections = [
        (1, LineString([(X0 + 50, y), (X0 + 250, y)]), 13),
        (2, LineString([(X0 + 250, y), (X0 + 450, y)]), 15),
        (3, LineString([(X0 + 450, y), (X0 + 550, y)]), 17),
    ]
    rows = [
        {
            "cln_node": n,
            "kind": "trench",
            "name": f"Trench A s{n}",
            "reach_id": float(n),
            "section": n,
            "group": "A",
            "trench": "Trench A",
            "bed_p1": 96.0 - 0.5 * n,
            "bed_p2": 95.5 - 0.5 * n,
            "top": 100.0,
            "layer": 1,
            "gw_node": gw,
            "geometry": geom,
        }
        for n, geom, gw in sections
    ]
    bore_node = grid.loc[(grid["layer"] == 2) & (grid["nodenumberL1"] == 5)].iloc[0]
    rows.append(
        {
            "cln_node": 4,
            "kind": "bore",
            "name": "Bore 1",
            "reach_id": np.nan,
            "section": np.nan,
            "group": "B",
            "trench": None,
            "bed_p1": 20.0,
            "bed_p2": 20.0,
            "top": 100.0,
            "layer": 2,
            "gw_node": int(bore_node["nodenumber"]),
            "geometry": bore_node.geometry.centroid,
        }
    )
    return gpd.GeoDataFrame(rows, geometry="geometry", crs=CRS)


def make_cln_heads(cln: gpd.GeoDataFrame, times: pd.DataFrame) -> pd.DataFrame:
    """Long table SP, cln_node, h (m), active. Section 3 is off in segment 1
    (inactive periods carry NA heads)."""
    rows = []
    for sp, segment in zip(times["SP"], times["segment"]):
        for node in cln.itertuples():
            bed = node.bed_p1 if segment == 1 else node.bed_p2
            active = not (node.cln_node == 3 and segment == 1)
            h = bed + 1.0 + 0.3 * np.sin(sp + node.cln_node) if active else np.nan
            rows.append(
                {
                    "SP": int(sp),
                    "cln_node": int(node.cln_node),
                    "h": h,
                    "active": active,
                }
            )
    return pd.DataFrame(rows)


def make_pumping(times: pd.DataFrame) -> pd.DataFrame:
    """Long table SP, well, kind, cln_node, requested, delivered (m3/d,
    positive = out of the aquifer). "Well A" moves from CLN node 2 to 3 when
    segment 2 starts and cannot deliver its full rate there."""
    rows = []
    for sp, segment in zip(times["SP"], times["segment"]):
        well_node = 2 if segment == 1 else 3
        rows.append(
            {
                "SP": int(sp),
                "well": "Well A",
                "kind": "moving",
                "cln_node": well_node,
                "requested": 100.0,
                "delivered": 100.0 if segment == 1 else 60.0,
            }
        )
        rows.append(
            {
                "SP": int(sp),
                "well": "Bore 1",
                "kind": "bore",
                "cln_node": 4,
                "requested": 50.0,
                "delivered": 50.0,
            }
        )
    return pd.DataFrame(rows)


def make_sites(grid: gpd.GeoDataFrame, cln: gpd.GeoDataFrame) -> gpd.GeoDataFrame:
    """Three target sites: two aquifer bores (layers 1 and 2) in group "obs_a"
    and one at the CLN bore in group "obs_b". node is the 1-based global node."""

    def centre(layer: int, nl1: int) -> tuple[int, Point]:
        cell = grid.loc[(grid["layer"] == layer) & (grid["nodenumberL1"] == nl1)].iloc[
            0
        ]
        return int(cell["nodenumber"]), cell.geometry.centroid

    n1, p1 = centre(1, 8)
    n2, p2 = centre(2, 3)
    bore = cln.loc[cln["cln_node"] == 4].iloc[0]
    rows = [
        {
            "site": "S1",
            "group": "obs_a",
            "layer": 1,
            "node": n1,
            "cln_node": pd.NA,
            "geometry": p1,
        },
        {
            "site": "S2",
            "group": "obs_a",
            "layer": 2,
            "node": n2,
            "cln_node": pd.NA,
            "geometry": p2,
        },
        {
            "site": "S3",
            "group": "obs_b",
            "layer": int(bore["layer"]),
            "node": int(bore["gw_node"]),
            "cln_node": 4,
            "geometry": bore.geometry,
        },
    ]
    sites = gpd.GeoDataFrame(rows, geometry="geometry", crs=CRS)
    sites["cln_node"] = sites["cln_node"].astype("Int64")  # nullable integer
    return sites


def make_targets(
    sites: gpd.GeoDataFrame,
    grid: gpd.GeoDataFrame,
    times: pd.DataFrame,
    heads: pd.DataFrame,
    heads_base: pd.DataFrame,
    cln_heads: pd.DataFrame,
) -> pd.DataFrame:
    """Observed and simulated values per target (m).

    simulated / simulated_baseline are read from the bundle's own heads (the
    site's node, or its CLN node), so they match the maps. observed is the
    simulated value plus a fixed offset and noise; S1 is observed every second
    period only.
    """
    rng = np.random.default_rng(42)
    node_key = grid.set_index("nodenumber")[["layer", "nodenumberL1"]]
    h_run = heads.set_index(["SP", "layer", "nodenumberL1"])["h"]
    h_base = heads_base.set_index(["SP", "layer", "nodenumberL1"])["h"]
    h_cln = cln_heads.set_index(["SP", "cln_node"])["h"]
    weights = {"S1": 1.0, "S2": 0.5, "S3": 2.0}
    rows = []
    for site in sites.itertuples():
        layer, nl1 = node_key.loc[site.node]
        for sp, date_end in zip(times["SP"], times["date_end"]):
            if site.site == "S1" and sp % 2 == 1:
                continue
            if pd.notna(site.cln_node):
                sim = h_cln.loc[(sp, site.cln_node)]
                sim_base = np.nan
            else:
                sim = h_run.loc[(sp, layer, nl1)]
                sim_base = h_base.loc[(sp, layer, nl1)]
            rows.append(
                {
                    "obsname": f"{site.site.lower()}_{sp:03d}",
                    "site": site.site,
                    "group": site.group,
                    "role": "head",
                    "date": date_end,
                    "SP": int(sp),
                    "observed": float(sim) + 0.3 + rng.normal(0, 0.1),
                    "simulated": float(sim),
                    "simulated_baseline": float(sim_base),
                    "weight": weights[site.site],
                }
            )
    return pd.DataFrame(rows)


def make_observations(targets: pd.DataFrame) -> pd.DataFrame:
    """Raw measurements behind the targets: site, datetime, value (m), source,
    role.

    S1: a daily logger over the whole run (its target values interpolated
    to each day, plus noise) and a manual dip on the 15th of every month; S3:
    one survey. S2 has none, so the app must cope with sites without any.
    """
    rng = np.random.default_rng(7)
    s1 = targets[targets.site == "S1"].sort_values("date")
    t_obs = pd.to_datetime(s1["date"]).to_numpy()
    days = pd.date_range(START_DATE, periods=300, freq="D")
    # np.interp works on numbers: datetimes as int64 nanoseconds.
    level = np.interp(
        days.asi8, t_obs.astype("datetime64[ns]").astype("int64"), s1["observed"]
    )
    logger = pd.DataFrame(
        {
            "site": "S1",
            "datetime": days,
            "value": level + rng.normal(0, 0.02, len(days)),
            "source": "logger",
        }
    )
    dips = logger[logger.datetime.dt.day == 15].copy()
    dips["datetime"] = dips["datetime"] + pd.Timedelta(hours=10)
    dips["source"] = "manual"
    s3 = targets[targets.site == "S3"].iloc[0]
    survey = pd.DataFrame(
        {
            "site": ["S3"],
            "datetime": [pd.Timestamp(s3["date"])],
            "value": [s3["observed"]],
            "source": ["survey"],
        }
    )
    obs = pd.concat([logger, dips, survey], ignore_index=True)
    obs["role"] = "head"
    return obs


def make_fields(grid: gpd.GeoDataFrame) -> pd.DataFrame:
    """Long table field, layer, nodenumberL1, value, run.

    Fields kx, kz (m/d) and sy (-); run is "prior", "run" or "ratio"
    (= run / prior). The run's kx rises eastward by up to x8.
    """
    rows = []
    centres_x = grid.geometry.centroid.x
    for k, cell in enumerate(grid.itertuples()):
        prior = {
            "kx": 10.0 if cell.layer == 1 else 1.0,
            "sy": 0.1 if cell.layer == 1 else 0.05,
        }
        prior["kz"] = prior["kx"] / 10.0
        mult = 2.0 ** (3.0 * (centres_x.iloc[k] - X0) / 600.0)  # 1 .. 8 west to east
        run = {"kx": prior["kx"] * mult, "kz": prior["kz"] * mult, "sy": prior["sy"]}
        for field in ("kx", "kz", "sy"):
            for run_name, value in (
                ("prior", prior[field]),
                ("run", run[field]),
                ("ratio", run[field] / prior[field]),
            ):
                rows.append(
                    {
                        "field": field,
                        "layer": int(cell.layer),
                        "nodenumberL1": int(cell.nodenumberL1),
                        "value": float(value),
                        "run": run_name,
                    }
                )
    return pd.DataFrame(rows)


def make_manifest(grid: gpd.GeoDataFrame, times: pd.DataFrame) -> dict:
    """The bundle's manifest.json content."""
    segments = []
    for segment, seg_times in times.groupby("segment"):
        segments.append(
            {
                "segment": int(segment),
                "first_period": int(seg_times["SP"].min()),
                "nper": len(seg_times),
                "from": seg_times["date_start"].iloc[0],
                "to": seg_times["date_end"].iloc[-1],
            }
        )
    return {
        "tag": "synthetic_test",
        "title": "Synthetic test bundle (2 layers, 2 segments)",
        "source_run": None,
        "baseline_run": None,
        "snapshot": None,
        "parameter_file": None,
        "model_type": "mfusg",
        "crs": CRS,
        "start_date": START_DATE,
        "time_units": "days",
        "n_layers": len(LAYERS),
        "nodes_per_layer": [int(n) for n in grid.groupby("layer").size()],
        "n_periods": len(times),
        "segments": segments,
        "confidential": False,
        "created": pd.Timestamp.now(tz="UTC").isoformat(timespec="seconds"),
        "exporter_commit": None,
    }


def write_bundle(out_dir: Path) -> Path:
    """Write the full synthetic bundle into out_dir (created if needed).
    Returns out_dir."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    grid = make_grid()
    times = make_times()
    heads = make_heads(grid, times)
    heads_base = make_heads(grid, times, baseline=True)
    cln = make_cln_nodes(grid)
    cln_heads = make_cln_heads(cln, times)
    sites = make_sites(grid, cln)
    targets = make_targets(sites, grid, times, heads, heads_base, cln_heads)

    (out_dir / "manifest.json").write_text(
        json.dumps(make_manifest(grid, times), indent=2)
    )
    grid.to_parquet(out_dir / "Grid.parquet")
    times.to_csv(out_dir / "Times.csv", index=False)
    heads.to_parquet(out_dir / "Heads.parquet", index=False)
    heads_base.to_parquet(out_dir / "Heads_baseline.parquet", index=False)
    cln.to_parquet(out_dir / "CLN_nodes.parquet")
    cln_heads.to_parquet(out_dir / "CLN_heads.parquet", index=False)
    make_pumping(times).to_parquet(out_dir / "Pumping.parquet", index=False)
    sites.to_parquet(out_dir / "Sites.parquet")
    targets.to_parquet(out_dir / "Targets.parquet", index=False)
    make_observations(targets).to_parquet(out_dir / "Observations.parquet", index=False)
    make_fields(grid).to_parquet(out_dir / "Fields.parquet", index=False)
    return out_dir


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    out = write_bundle(Path(argv[1]))
    print(f"Synthetic review bundle written to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
