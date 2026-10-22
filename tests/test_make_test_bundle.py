"""Checks that the synthetic review bundle has the shape the app relies on.

Run from the repo root or the app dir (flopy_py_env):
    python -m pytest -q apps/mf_heads/tests
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import geopandas as gpd
import pandas as pd
import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "make_test_bundle.py"


def _load_generator():
    """Import scripts/make_test_bundle.py by path (scripts/ is not a package)."""
    spec = importlib.util.spec_from_file_location("make_test_bundle", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def bundle(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return _load_generator().write_bundle(tmp_path_factory.mktemp("bundle"))


def test_all_tables_written(bundle: Path) -> None:
    expected = {
        "manifest.json",
        "Grid.parquet",
        "Times.csv",
        "Heads.parquet",
        "Heads_baseline.parquet",
        "CLN_nodes.parquet",
        "CLN_heads.parquet",
        "Pumping.parquet",
        "Sites.parquet",
        "Targets.parquet",
        "Observations.parquet",
        "Fields.parquet",
    }
    assert expected <= {p.name for p in bundle.iterdir()}


def test_layers_have_different_cells(bundle: Path) -> None:
    grid = gpd.read_parquet(bundle / "Grid.parquet")
    counts = grid.groupby("layer").size().to_dict()
    assert counts == {1: 36, 2: 9}
    # nodenumber is global and 1-based; nodenumberL1 restarts at 1 in each layer.
    assert grid["nodenumber"].tolist() == list(range(1, 46))
    for layer, n in counts.items():
        assert sorted(grid.loc[grid["layer"] == layer, "nodenumberL1"]) == list(
            range(1, n + 1)
        )
    manifest = json.loads((bundle / "manifest.json").read_text())
    assert manifest["nodes_per_layer"] == [36, 9]


def test_heads_cover_every_cell_and_period(bundle: Path) -> None:
    heads = pd.read_parquet(bundle / "Heads.parquet")
    assert len(heads) == 45 * 10
    assert heads["h"].isna().sum() == 5 + 10  # dry cell SP 6-10 + inactive cell
    base = pd.read_parquet(bundle / "Heads_baseline.parquet")
    assert list(base.columns) == list(heads.columns)


def test_times_join_two_segments(bundle: Path) -> None:
    times = pd.read_csv(bundle / "Times.csv")
    assert times["SP"].tolist() == list(range(1, 11))
    assert times.groupby("segment")["kper"].max().to_dict() == {1: 6, 2: 4}
    assert times["date_end"].iloc[0] == "2020-01-31"


def test_targets_match_heads(bundle: Path) -> None:
    targets = pd.read_parquet(bundle / "Targets.parquet")
    heads = pd.read_parquet(bundle / "Heads.parquet")
    grid = gpd.read_parquet(bundle / "Grid.parquet")
    s2 = targets[targets["site"] == "S2"].iloc[0]
    sites = gpd.read_parquet(bundle / "Sites.parquet")
    node = int(sites.loc[sites["site"] == "S2", "node"].iloc[0])
    cell = grid.loc[grid["nodenumber"] == node].iloc[0]
    h = heads[
        (heads["SP"] == s2["SP"])
        & (heads["layer"] == cell["layer"])
        & (heads["nodenumberL1"] == cell["nodenumberL1"])
    ]["h"].iloc[0]
    assert s2["simulated"] == pytest.approx(float(h), abs=1e-4)


def test_cln_mixes_lines_and_points(bundle: Path) -> None:
    cln = gpd.read_parquet(bundle / "CLN_nodes.parquet")
    assert set(cln.geom_type) == {"LineString", "Point"}
    pumping = pd.read_parquet(bundle / "Pumping.parquet")
    moving = pumping[pumping["well"] == "Well A"]
    assert set(moving["cln_node"]) == {2, 3}  # the well moves between nodes


def test_observations_behind_targets(bundle: Path) -> None:
    obs = pd.read_parquet(bundle / "Observations.parquet")
    assert set(obs.site) == {"S1", "S3"}  # S2 has no measurements
    assert set(obs.source) == {"logger", "manual", "survey"}
    assert (obs.role == "head").all()
    s1 = obs[(obs.site == "S1") & (obs.source == "logger")]
    assert len(s1) == 300 and s1.value.notna().all()
