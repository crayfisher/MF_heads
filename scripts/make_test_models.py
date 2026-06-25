"""
Generate small MF6 test models covering all basic grid types for the
RGW Heads Visualizer pipeline.

Models produced (under data/test_models/<name>/):
  - mf6_dis_ml   : MF6 structured DIS, 3 layers, transient, with INACTIVE cells
                   (idomain=0 -> heads written as 1e30) to exercise sentinel logic.
  - mf6_disv_ml  : MF6 DISV via gridgen quadtree refinement, 2 layers, transient.
  - mf6_disu     : MF6 DISU via gridgen, 2 layers (unstructured), steady.

Each model is run with mf6 so a .hds exists. Gridgen also exports the cell
polygon shapefile (needed for the DISU geometry, which flopy cannot rebuild
from the binary grid alone).
"""
import os
import shutil
import numpy as np
import flopy
from flopy.discretization import StructuredGrid
from flopy.utils.gridgen import Gridgen

BASE = os.path.join("data", "test_models")
MF6 = "mf6"
GRIDGEN = "gridgen"


def _fresh(ws):
    if os.path.isdir(ws):
        shutil.rmtree(ws)
    os.makedirs(ws, exist_ok=True)
    return ws


# ---------------------------------------------------------------------------
def build_mf6_dis_ml():
    name = "mf6_dis_ml"
    ws = _fresh(os.path.join(BASE, name))
    nlay, nrow, ncol = 3, 6, 6

    sim = flopy.mf6.MFSimulation(sim_name=name, sim_ws=ws, exe_name=MF6)
    flopy.mf6.ModflowTdis(
        sim, time_units="DAYS", nper=3,
        perioddata=[(1.0, 1, 1.0), (10.0, 5, 1.2), (10.0, 5, 1.2)],
    )
    flopy.mf6.ModflowIms(sim, complexity="SIMPLE", print_option="SUMMARY")
    gwf = flopy.mf6.ModflowGwf(sim, modelname=name, save_flows=True)

    # Inactive block in the middle through all layers -> heads = 1e30 there.
    idomain = np.ones((nlay, nrow, ncol), dtype=int)
    idomain[:, 2:4, 2:4] = 0

    flopy.mf6.ModflowGwfdis(
        gwf, nlay=nlay, nrow=nrow, ncol=ncol,
        delr=100.0, delc=100.0, top=30.0, botm=[20.0, 10.0, 0.0],
        idomain=idomain,
    )
    flopy.mf6.ModflowGwfic(gwf, strt=25.0)
    flopy.mf6.ModflowGwfnpf(gwf, k=10.0, save_specific_discharge=True)
    flopy.mf6.ModflowGwfsto(
        gwf, ss=1e-5, sy=0.1, steady_state={0: True}, transient={1: True, 2: True}
    )

    chd = []
    for k in range(nlay):
        for r in range(nrow):
            chd.append([(k, r, 0), 25.0])
            chd.append([(k, r, ncol - 1), 15.0])
    flopy.mf6.ModflowGwfchd(gwf, stress_period_data={0: chd})

    flopy.mf6.ModflowGwfoc(
        gwf, head_filerecord=f"{name}.hds", budget_filerecord=f"{name}.cbc",
        saverecord=[("HEAD", "ALL"), ("BUDGET", "ALL")],
    )
    sim.write_simulation()
    ok, _ = sim.run_simulation(silent=True)
    print(f"[{name}] run success: {ok}")
    return ws


# ---------------------------------------------------------------------------
def _gridgen_base(nlay, top, botm):
    nrow = ncol = 10
    delr = delc = 100.0
    sg = StructuredGrid(
        delc=delc * np.ones(nrow, dtype=float),
        delr=delr * np.ones(ncol, dtype=float),
        top=top * np.ones((nrow, ncol), dtype=float),
        botm=np.array([np.full((nrow, ncol), b, dtype=float) for b in botm]),
        nlay=nlay,
    )
    return sg, nrow, ncol


def build_mf6_disv_ml():
    name = "mf6_disv_ml"
    ws = _fresh(os.path.join(BASE, name))
    gg_ws = _fresh(os.path.join(ws, "gridgen"))
    nlay = 2
    top, botm = 30.0, [15.0, 0.0]

    sg, nrow, ncol = _gridgen_base(nlay, top, botm)
    g = Gridgen(sg, model_ws=gg_ws, exe_name=GRIDGEN)
    # Refine around the centre point, level 2, all layers.
    g.add_refinement_features([[(500.0, 500.0)]], "point", 2, range(nlay))
    g.build(verbose=False)
    gp = g.get_gridprops_disv()

    sim = flopy.mf6.MFSimulation(sim_name=name, sim_ws=ws, exe_name=MF6)
    flopy.mf6.ModflowTdis(
        sim, time_units="DAYS", nper=2,
        perioddata=[(1.0, 1, 1.0), (10.0, 5, 1.2)],
    )
    flopy.mf6.ModflowIms(sim, complexity="SIMPLE")
    gwf = flopy.mf6.ModflowGwf(sim, modelname=name, save_flows=True)
    flopy.mf6.ModflowGwfdisv(gwf, **gp)
    flopy.mf6.ModflowGwfic(gwf, strt=25.0)
    flopy.mf6.ModflowGwfnpf(gwf, k=10.0, save_specific_discharge=True)
    flopy.mf6.ModflowGwfsto(gwf, ss=1e-5, sy=0.1,
                            steady_state={0: True}, transient={1: True})

    # CHD on extreme-left and -right cells (layer 0) by x-coordinate.
    xc = sg.xcellcenters  # not used directly; use gridgen cell centers
    chd = []
    cell_xy = np.array([(c[1], c[2]) for c in gp["cell2d"]])
    ncpl = gp["ncpl"]
    for icpl in range(ncpl):
        x = cell_xy[icpl, 0]
        if x < 100.0:
            chd.append([(0, icpl), 25.0])
        elif x > 900.0:
            chd.append([(0, icpl), 15.0])
    flopy.mf6.ModflowGwfchd(gwf, stress_period_data={0: chd})

    flopy.mf6.ModflowGwfoc(
        gwf, head_filerecord=f"{name}.hds", budget_filerecord=f"{name}.cbc",
        saverecord=[("HEAD", "ALL"), ("BUDGET", "ALL")],
    )
    sim.write_simulation()
    ok, _ = sim.run_simulation(silent=True)
    print(f"[{name}] run success: {ok}")
    return ws, g


# ---------------------------------------------------------------------------
def build_mf6_disu():
    name = "mf6_disu"
    ws = _fresh(os.path.join(BASE, name))
    gg_ws = _fresh(os.path.join(ws, "gridgen"))
    nlay = 2
    top, botm = 30.0, [15.0, 0.0]

    sg, nrow, ncol = _gridgen_base(nlay, top, botm)
    g = Gridgen(sg, model_ws=gg_ws, exe_name=GRIDGEN)
    g.add_refinement_features([[(500.0, 500.0)]], "point", 2, range(nlay))
    g.build(verbose=False)
    gp = g.get_gridprops_disu6()

    sim = flopy.mf6.MFSimulation(sim_name=name, sim_ws=ws, exe_name=MF6)
    flopy.mf6.ModflowTdis(sim, time_units="DAYS", nper=1,
                          perioddata=[(1.0, 1, 1.0)])
    flopy.mf6.ModflowIms(sim, complexity="SIMPLE")
    gwf = flopy.mf6.ModflowGwf(sim, modelname=name, save_flows=True)
    flopy.mf6.ModflowGwfdisu(gwf, **gp)
    flopy.mf6.ModflowGwfic(gwf, strt=25.0)
    flopy.mf6.ModflowGwfnpf(gwf, k=10.0, save_specific_discharge=True)

    # CHD by cell-center x using the disu grid.
    disu_grid = gwf.modelgrid
    xc = disu_grid.xcellcenters
    chd = []
    for n in range(len(xc)):
        if xc[n] < 100.0:
            chd.append([(n,), 25.0])
        elif xc[n] > 900.0:
            chd.append([(n,), 15.0])
    flopy.mf6.ModflowGwfchd(gwf, stress_period_data={0: chd})

    flopy.mf6.ModflowGwfoc(
        gwf, head_filerecord=f"{name}.hds", budget_filerecord=f"{name}.cbc",
        saverecord=[("HEAD", "ALL"), ("BUDGET", "ALL")],
    )
    sim.write_simulation()
    ok, _ = sim.run_simulation(silent=True)
    print(f"[{name}] run success: {ok}")
    return ws, g


# ---------------------------------------------------------------------------
# CRS demo coords: place models in New Zealand Transverse Mercator (EPSG:2193),
# reusing the xll/yll from the user's mf2005 model. Built in LOCAL coords; the
# usgs.model.reference sidecar supplies offset + CRS, which the parser applies.
NZ_XLL, NZ_YLL, NZ_EPSG = 1891460.0, 5594400.0, 2193


def _write_model_reference(ws, xll, yll, epsg):
    with open(os.path.join(ws, "usgs.model.reference"), "w") as f:
        f.write(f"xll {xll}\nyll {yll}\nrotation 0.0\n"
                f"epsg {epsg}\nstart_date 1980-07-01\n")
    print(f"  wrote usgs.model.reference (epsg {epsg})")


def _chd_by_x_disv(gp, lo=25.0, hi=15.0, margin=0.1):
    """CHD on the left/right edge cells (layer 0), keyed on cell-centre x."""
    xs = np.array([c[1] for c in gp["cell2d"]])
    xmin, xmax = xs.min(), xs.max()
    span = xmax - xmin
    chd = []
    for icpl in range(gp["ncpl"]):
        if xs[icpl] <= xmin + margin * span:
            chd.append([(0, icpl), lo])
        elif xs[icpl] >= xmax - margin * span:
            chd.append([(0, icpl), hi])
    return chd


def build_mf6_quadtree_crs():
    name = "mf6_quadtree"
    ws = _fresh(os.path.join(BASE, name))
    gg_ws = _fresh(os.path.join(ws, "gridgen"))
    nlay, top, botm = 1, 30.0, [0.0]
    nrow = ncol = 20
    sg, _, _ = _gridgen_base(nlay, top, botm)  # 10x10 base, local coords
    g = Gridgen(sg, model_ws=gg_ws, exe_name=GRIDGEN)
    # Nested refinement around the centre (levels 1-3) -> a real quadtree.
    g.add_refinement_features([[(500.0, 500.0)]], "point", 3, range(nlay))
    g.add_refinement_features([[[(200.0, 200.0), (800.0, 200.0),
                                 (800.0, 800.0), (200.0, 800.0),
                                 (200.0, 200.0)]]], "polygon", 1, range(nlay))
    g.build(verbose=False)
    gp = g.get_gridprops_disv()

    sim = flopy.mf6.MFSimulation(sim_name=name, sim_ws=ws, exe_name=MF6)
    flopy.mf6.ModflowTdis(sim, time_units="DAYS", nper=1, perioddata=[(1.0, 1, 1.0)])
    flopy.mf6.ModflowIms(sim, complexity="SIMPLE")
    gwf = flopy.mf6.ModflowGwf(sim, modelname=name, save_flows=True)
    flopy.mf6.ModflowGwfdisv(gwf, **gp)
    flopy.mf6.ModflowGwfic(gwf, strt=25.0)
    flopy.mf6.ModflowGwfnpf(gwf, k=10.0)
    flopy.mf6.ModflowGwfchd(gwf, stress_period_data={0: _chd_by_x_disv(gp)})
    flopy.mf6.ModflowGwfoc(gwf, head_filerecord=f"{name}.hds",
                           saverecord=[("HEAD", "ALL")])
    sim.write_simulation()
    ok, _ = sim.run_simulation(silent=True)
    print(f"[{name}] run success: {ok} (ncpl={gp['ncpl']})")
    _write_model_reference(ws, NZ_XLL, NZ_YLL, NZ_EPSG)
    return ws


def build_mf6_voronoi_crs():
    from flopy.utils.triangle import Triangle
    from flopy.utils.voronoi import VoronoiGrid
    name = "mf6_voronoi"
    ws = _fresh(os.path.join(BASE, name))
    tri_ws = _fresh(os.path.join(ws, "triangle"))

    domain = [(0.0, 0.0), (1000.0, 0.0), (1000.0, 1000.0), (0.0, 1000.0)]
    tri = Triangle(maximum_area=3000.0, angle=30, model_ws=tri_ws, exe_name="triangle")
    tri.add_polygon(domain)
    tri.build(verbose=False)
    vor = VoronoiGrid(tri)
    gp = vor.get_disv_gridprops()  # ncpl, nvert, vertices, cell2d
    gp.update(nlay=1, top=30.0, botm=[0.0])

    sim = flopy.mf6.MFSimulation(sim_name=name, sim_ws=ws, exe_name=MF6)
    flopy.mf6.ModflowTdis(sim, time_units="DAYS", nper=1, perioddata=[(1.0, 1, 1.0)])
    flopy.mf6.ModflowIms(sim, complexity="SIMPLE")
    gwf = flopy.mf6.ModflowGwf(sim, modelname=name, save_flows=True)
    flopy.mf6.ModflowGwfdisv(gwf, **gp)
    flopy.mf6.ModflowGwfic(gwf, strt=25.0)
    flopy.mf6.ModflowGwfnpf(gwf, k=10.0)
    flopy.mf6.ModflowGwfchd(gwf, stress_period_data={0: _chd_by_x_disv(gp)})
    flopy.mf6.ModflowGwfoc(gwf, head_filerecord=f"{name}.hds",
                           saverecord=[("HEAD", "ALL")])
    sim.write_simulation()
    ok, _ = sim.run_simulation(silent=True)
    print(f"[{name}] run success: {ok} (ncpl={gp['ncpl']})")
    _write_model_reference(ws, NZ_XLL, NZ_YLL, NZ_EPSG)
    return ws


def build_mf2005_min():
    """Minimal MODFLOW-2005 model: structured, 2 layers, transient, georeferenced
    AND rotated (15 deg) via the flopy nam-file header - doubles as the rotation
    test. CRS + rotation + start date all auto-detect from the nam header."""
    name = "mf2005_min"
    ws = _fresh(os.path.join(BASE, name))
    nlay, nrow, ncol = 2, 8, 10
    m = flopy.modflow.Modflow(name, model_ws=ws, exe_name="mf2005")
    flopy.modflow.ModflowDis(
        m, nlay=nlay, nrow=nrow, ncol=ncol, delr=100.0, delc=100.0,
        top=30.0, botm=[15.0, 0.0], nper=2, perlen=[1.0, 10.0], nstp=[1, 5],
        steady=[True, False], itmuni=4, lenuni=2,
        xul=NZ_XLL, yul=NZ_YLL + nrow * 100.0, rotation=15.0,
        crs="epsg:2193", start_datetime="1980-07-01",
    )
    flopy.modflow.ModflowBas(m, ibound=1, strt=25.0)
    flopy.modflow.ModflowLpf(m, hk=10.0, ss=1e-5, sy=0.1)
    chd = []
    for k in range(nlay):
        for r in range(nrow):
            chd.append([k, r, 0, 25.0, 25.0])
            chd.append([k, r, ncol - 1, 15.0, 15.0])
    flopy.modflow.ModflowChd(m, stress_period_data={0: chd})
    flopy.modflow.ModflowOc(m, stress_period_data={(0, 0): ["save head"],
                                                    (1, 4): ["save head"]})
    flopy.modflow.ModflowPcg(m)
    m.write_input()
    ok, _ = m.run_model(silent=True)
    print(f"[{name}] run success: {ok}")
    return ws


if __name__ == "__main__":
    os.makedirs(BASE, exist_ok=True)
    build_mf6_dis_ml()
    _, gdisv = build_mf6_disv_ml()
    _, gdisu = build_mf6_disu()
    build_mf6_quadtree_crs()
    build_mf6_voronoi_crs()
    build_mf2005_min()
    # Inspect what gridgen exported (for geometry shapefiles).
    for label, g in [("disv", gdisv), ("disu", gdisu)]:
        ews = g.model_ws
        print(f"\n[{label}] gridgen workspace files:")
        for f in sorted(os.listdir(ews)):
            print("   ", f)
