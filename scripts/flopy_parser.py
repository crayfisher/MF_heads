import sys
import os
import glob
import pandas as pd
import numpy as np
import flopy
import flopy.utils.binaryfile as bf


def detect_and_write_crs(grid, sim_ws, out_dir):
    """Determine the grid's EPSG and record it for the R side.

    MF6 files do not store a CRS, but flopy honors a `usgs.model.reference`
    sidecar (keys `epsg`/`proj4`) if we read it explicitly; mf2005 recovers it
    from the nam header. Writes detected_crs.txt = <epsg> or NONE.
    """
    epsg = None
    ref = os.path.join(sim_ws, "usgs.model.reference")
    if os.path.exists(ref):
        try:
            grid.read_usgs_model_reference_file(ref)
            print(f"Read CRS sidecar: {ref}")
        except Exception as e:
            print(f"Could not read usgs.model.reference: {e}")
    try:
        if grid.crs is not None:
            epsg = grid.crs.to_epsg()
    except Exception:
        epsg = None
    # Depending on the flopy/pyproj build, the sidecar/nam may populate `epsg`
    # without building a full `crs` object - fall back to it.
    if epsg is None:
        epsg = getattr(grid, "epsg", None)
    with open(os.path.join(out_dir, "detected_crs.txt"), "w") as f:
        f.write(str(epsg) if epsg else "NONE")
    print(f"Detected CRS EPSG: {epsg}")
    return epsg


def write_model_meta(out_dir, start_datetime, time_units):
    """Record start date + time units so the app can set the timeline."""
    with open(os.path.join(out_dir, "start_date.txt"), "w") as f:
        f.write(str(start_datetime) if start_datetime else "NONE")
    with open(os.path.join(out_dir, "time_units.txt"), "w") as f:
        f.write(str(time_units) if time_units else "unknown")
    print(f"Model meta: start={start_datetime}, time_units={time_units}")


ITMUNI_MAP = {0: "unknown", 1: "seconds", 2: "minutes", 3: "hours", 4: "days", 5: "years"}


def model_start_and_units(modeltime):
    start = time_units = None
    try:
        start = modeltime.start_datetime
    except Exception:
        start = None
    try:
        time_units = modeltime.time_units
    except Exception:
        time_units = None
    return start, time_units


def write_sentinels(out_dir, values):
    """Record model-specific inactive/dry head sentinels (HNOFLO/HDRY) so the
    app can exclude them - these vary by model (e.g. 999, 99999, +/-1e30)."""
    clean = sorted({float(v) for v in values if v is not None})
    with open(os.path.join(out_dir, "sentinels.txt"), "w") as f:
        f.write(",".join(repr(v) for v in clean))
    print(f"Head sentinels: {clean}")


def mf2005_load_only(nam_path):
    """Packages we care about (geometry + sentinels) that are actually listed in
    the nam file - flopy errors if load_only names a missing package."""
    present = set()
    try:
        with open(nam_path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    present.add(line.split()[0].lower())
    except Exception:
        pass
    lo = [p for p in ('dis', 'bas6', 'lpf', 'upw', 'bcf6') if p in present]
    if 'dis' not in lo:
        lo = ['dis'] + lo
    return lo


def collect_mf_sentinels(m):
    """HNOFLO (BAS) and HDRY (flow package) for a MODFLOW-2005 model."""
    vals = []
    try:
        if getattr(m, "bas6", None) is not None:
            vals.append(float(m.bas6.hnoflo))
    except Exception:
        pass
    for pkgname in ("lpf", "upw", "bcf6"):
        pkg = getattr(m, pkgname, None)
        if pkg is not None and hasattr(pkg, "hdry"):
            try:
                vals.append(float(pkg.hdry))
            except Exception:
                pass
    return vals


def start_datetime_from_nam(nam_path):
    """Read start_datetime from the flopy nam-header comment. flopy's own header
    parser splits on ':' and truncates the time, so we read it ourselves."""
    try:
        with open(nam_path) as f:
            for line in f:
                if line.lstrip().startswith("#") and "start_datetime" in line:
                    return line.split("start_datetime:", 1)[1].strip().rstrip(";").strip()
    except Exception:
        pass
    return None


def _ring_wkt(pts):
    """Build a closed POLYGON WKT string from a list of (x, y) vertices.
    No shapely needed - this is just string formatting, and lets R rebuild
    geometry via a fast vectorized st_as_sfc() instead of a slow group_by."""
    pts = list(pts)
    if pts[0] != pts[-1]:
        pts = pts + [pts[0]]
    coords = ", ".join(f"{float(x)} {float(y)}" for x, y in pts)
    return f"POLYGON (({coords}))"


def build_grid_records(grid):
    """One record per cell with a WKT polygon. DISU rows also carry layer +
    per-layer node so the join stays layer-aware. Works for structured (DIS),
    vertex (DISV) and unstructured (DISU) grids.

    Returns (records, disu_layer, disu_nl1).
    """
    disu_layer = disu_nl1 = None
    if grid.grid_type == 'unstructured':
        ncpl = np.atleast_1d(np.asarray(grid.ncpl)).astype(int)
        nnodes = int(grid.nnodes)
        disu_layer = np.zeros(nnodes, dtype=int)
        disu_nl1 = np.zeros(nnodes, dtype=int)
        start = 0
        for li, count in enumerate(ncpl):
            disu_layer[start:start + count] = li + 1
            disu_nl1[start:start + count] = np.arange(1, count + 1)
            start += count

    records = []
    if grid.grid_type == 'structured':
        # Single layer of polygons (no 'layer' column) - reused for every head
        # layer via nodenumberL1, so the same geometry serves all layers.
        # row/col (1-based) are carried for the tooltip on structured models.
        node = 1
        for r in range(grid.nrow):
            for c in range(grid.ncol):
                records.append({'node': node, 'nodenumberL1': node,
                                'row': r + 1, 'col': c + 1,
                                'wkt': _ring_wkt(grid.get_cell_vertices(r, c))})
                node += 1
    elif grid.grid_type == 'vertex':
        # DISV grid - one layer of polygons (ncpl cells), reused per head layer.
        for i in range(grid.ncpl):
            records.append({'node': i + 1, 'nodenumberL1': i + 1,
                            'wkt': _ring_wkt(grid.get_cell_vertices(i))})
    elif grid.grid_type == 'unstructured':
        # DISU grid - one polygon per global node, tagged with layer + per-layer node.
        for gn in range(int(grid.nnodes)):
            records.append({'node': gn + 1, 'layer': int(disu_layer[gn]),
                            'nodenumberL1': int(disu_nl1[gn]),
                            'wkt': _ring_wkt(grid.get_cell_vertices(gn))})
    else:
        print(f"Unhandled grid type '{grid.grid_type}'. Geometry not extracted.")
    return records, disu_layer, disu_nl1


def write_grid_csv(records, out_dir):
    if records:
        grid_csv = os.path.join(out_dir, "grid_polys.csv")
        pd.DataFrame(records).to_csv(grid_csv, index=False)
        print(f"Saved {grid_csv}")


def write_heads_and_times(hds_file, grid, out_dir, disu_layer=None, disu_nl1=None):
    """Extract per-(SP, layer, node) heads + the times table. Shared by MF6 and
    MODFLOW-2005 (both use the standard HeadFile binary)."""
    print(f"Extracting heads from {hds_file}...")
    hdobj = bf.HeadFile(hds_file)
    kstpkper = hdobj.get_kstpkper()
    times = hdobj.get_times()

    h_records = []
    for idx, (kstp, kper) in enumerate(kstpkper):
        sp = idx + 1
        heads = hdobj.get_data(kstpkper=(kstp, kper))
        if grid.grid_type == 'unstructured':
            # DISU heads come back as a flat vector of all global nodes; split
            # into layers to match the layer-aware geometry.
            flat = np.asarray(heads).flatten()
            for lay in np.unique(disu_layer):
                sel = disu_layer == lay
                h_records.append(pd.DataFrame({
                    'SP': sp, 'layer': int(lay),
                    'nodenumberL1': disu_nl1[sel], 'h': flat[sel]}))
        else:
            n_lay = heads.shape[0]
            for lay_idx in range(n_lay):
                lay_heads = heads[lay_idx].flatten()
                h_records.append(pd.DataFrame({
                    'SP': sp, 'layer': lay_idx + 1,
                    'nodenumberL1': np.arange(1, len(lay_heads) + 1), 'h': lay_heads}))

    heads_df = pd.concat(h_records, ignore_index=True)
    heads_df['SP'] = heads_df['SP'].astype(np.uint16)
    heads_df['layer'] = heads_df['layer'].astype(np.uint8)
    heads_df['nodenumberL1'] = heads_df['nodenumberL1'].astype(np.uint32)
    heads_df['h'] = heads_df['h'].astype(np.float32)
    heads_df.to_parquet(os.path.join(out_dir, "Heads.parquet"), compression='snappy')
    print(f"Saved Heads.parquet ({len(heads_df)} rows)")

    kp = np.array(kstpkper)
    pd.DataFrame({'time': np.array(times), 'kstp': kp[:, 0], 'kper': kp[:, 1],
                  'SP': np.arange(1, len(times) + 1)}).to_csv(
        os.path.join(out_dir, "Times.csv"), index=False)
    print("Saved Times.csv")


def parse_mf6(sim_ws, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    print(f"Loading MF6 from {sim_ws}...")
    sim = flopy.mf6.MFSimulation.load(sim_ws=sim_ws, load_only=['dis', 'disv', 'disu'])
    model_names = list(sim.model_names)
    if not model_names:
        raise ValueError("No MF6 model found in simulation.")
    gwf = sim.get_model(model_names[0])
    grid = gwf.modelgrid
    print(f"Grid type detected: {grid.grid_type}")
    detect_and_write_crs(grid, sim_ws, out_dir)
    try:
        start, tu = model_start_and_units(gwf.modeltime)
    except Exception as e:
        print(f"Could not read model time: {e}")
        start, tu = None, None
    write_model_meta(out_dir, start, tu)

    records, disu_layer, disu_nl1 = build_grid_records(grid)
    write_grid_csv(records, out_dir)

    hds_files = glob.glob(os.path.join(sim_ws, "*.hds"))
    if hds_files:
        write_heads_and_times(hds_files[0], grid, out_dir, disu_layer, disu_nl1)


def parse_mf2005(in_path, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    # in_path may be a directory or the .nam file itself.
    if os.path.isdir(in_path):
        nams = glob.glob(os.path.join(in_path, "*.nam"))
        if not nams:
            raise ValueError("No .nam file found for MODFLOW-2005 model.")
        nam_path = nams[0]
    else:
        nam_path = in_path
    ws, nam = os.path.dirname(nam_path), os.path.basename(nam_path)
    print(f"Loading MODFLOW-2005 {nam} from {ws}...")
    # Load DIS for geometry plus BAS/flow packages for the HNOFLO/HDRY sentinels
    # (skip the big stress packages for speed). Only request packages present.
    lo = mf2005_load_only(nam_path)
    try:
        m = flopy.modflow.Modflow.load(nam, model_ws=ws, load_only=lo,
                                       check=False, verbose=False, forgive=True)
    except Exception as e:
        print(f"Load with {lo} failed ({e}); retrying DIS only")
        m = flopy.modflow.Modflow.load(nam, model_ws=ws, load_only=['dis'],
                                       check=False, verbose=False, forgive=True)
    grid = m.modelgrid
    print(f"Grid type detected: {grid.grid_type}")
    detect_and_write_crs(grid, ws, out_dir)
    write_sentinels(out_dir, collect_mf_sentinels(m))
    # Avoid m.modeltime (it can choke parsing the nam-header start_datetime).
    # Time units come from DIS itmuni; start date from the nam header directly.
    try:
        itmuni = int(m.dis.itmuni)
    except Exception:
        itmuni = 0
    write_model_meta(out_dir, start_datetime_from_nam(nam_path),
                     ITMUNI_MAP.get(itmuni, "unknown"))

    records, disu_layer, disu_nl1 = build_grid_records(grid)
    write_grid_csv(records, out_dir)

    hds_files = glob.glob(os.path.join(ws, "*.hds"))
    if hds_files:
        write_heads_and_times(hds_files[0], grid, out_dir, disu_layer, disu_nl1)


def parse_usg(hds_file, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    # USG geometry/CRS come from the gpkg/shp (handled in R), not from here.
    with open(os.path.join(out_dir, "detected_crs.txt"), "w") as f:
        f.write("NONE")
    write_model_meta(out_dir, None, None)
    print(f"Extracting USG heads from {hds_file}...")
    hdobj = bf.HeadUFile(hds_file)
    kstpkper = hdobj.get_kstpkper()
    times = hdobj.get_times()

    nlay = hdobj.nlay
    h_records = []
    for idx, (kstp, kper) in enumerate(kstpkper):
        sp = idx + 1
        heads_list = [hdobj.get_data(kstpkper=(kstp, kper), mflay=lay) for lay in range(nlay)]
        for lay_idx in range(nlay):
            lay_heads = heads_list[lay_idx].flatten()
            h_records.append(pd.DataFrame({
                'SP': sp, 'layer': lay_idx + 1,
                'nodenumberL1': np.arange(1, len(lay_heads) + 1), 'h': lay_heads}))

    heads_df = pd.concat(h_records, ignore_index=True)
    heads_df['SP'] = heads_df['SP'].astype(np.uint16)
    heads_df['layer'] = heads_df['layer'].astype(np.uint8)
    heads_df['nodenumberL1'] = heads_df['nodenumberL1'].astype(np.uint32)
    heads_df['h'] = heads_df['h'].astype(np.float32)
    heads_df.to_parquet(os.path.join(out_dir, "Heads.parquet"), compression='snappy')
    print(f"Saved Heads.parquet ({len(heads_df)} rows)")

    kp = np.array(kstpkper)
    pd.DataFrame({'time': np.array(times), 'kstp': kp[:, 0], 'kper': kp[:, 1],
                  'SP': np.arange(1, len(times) + 1)}).to_csv(
        os.path.join(out_dir, "Times.csv"), index=False)
    print("Saved Times.csv")


if __name__ == '__main__':
    if len(sys.argv) < 4:
        print("Usage: python flopy_parser.py <model_type: mf6|mf2005|usg> <input_path> <out_dir>")
        sys.exit(1)

    mtype = sys.argv[1].lower()
    in_path = sys.argv[2]
    out_dir = sys.argv[3]

    if mtype == 'mf6':
        parse_mf6(in_path, out_dir)
    elif mtype == 'mf2005':
        parse_mf2005(in_path, out_dir)
    elif mtype == 'usg':
        parse_usg(in_path, out_dir)
    else:
        print(f"Unknown model type: {mtype}")
