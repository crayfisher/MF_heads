# GWheads — MODFLOW heads visualiser

> **Beta.** This app is under active development; expect rough edges and please
> report bugs (see below).

Interactive, web-native Shiny app for 2D visualisation of MODFLOW hydraulic
heads, drawdown distributions, and hydrographs. Supports **MF6**, **MODFLOW-USG**,
and **MODFLOW-2005**.

Part of the [Crayfisher](https://crayfisher.com) suite of web-based groundwater
modelling tools. Live: **https://heads.crayfisher.com**

## Features

- GPU-accelerated map (deck.gl / `rdeck`) — renders millions of cells instantly
- Upload a model **ZIP**, or already-processed **parquet/CSV** outputs (grid-type
  agnostic), or load a bundled **demo** model that opens instantly
- Heads and **drawdown** (vs. a baseline run), per stress period and layer
- Temporal **hydrograph** extraction at any node
- Colour flooding / contours, custom colour limits, satellite basemap
- Optional CRS via a `usgs.model.reference` sidecar + EPSG input

## Run locally

R with the packages in `environment.yml` (bslib, rdeck, plotly, arrow, reticulate,
flopy via the `flopy_env` conda env for model processing):

```r
shiny::runApp("app.R")
```

## Review bundles (local use)

A **review bundle** is one folder of plain tables exported from one model run,
for reviewing it interactively: grid, heads, an optional baseline run, and
optionally targets, CLN nodes, pumping and parameter fields. A model project
writes it with its own exporter; the app only reads it, in place.

```bash
./run_app.sh --bundles <folder>     # or: CF_BUNDLE_ROOT=<folder> ./run_app.sh
```

"1. Data Uploads" then lists every bundle (a folder with `manifest.json`) under
`<folder>`. The picker exists only when the folder is configured, so a hosted
copy never exposes the server's disk.

| File | Columns |
|---|---|
| `manifest.json` | `title`, `model_type`, `crs` (`EPSG:nnnn`), `start_date`, `time_units`, `n_layers`, `nodes_per_layer`, `n_periods`, `segments` |
| `Grid.parquet` | GeoParquet cell polygons: `nodenumber`, `layer`, `nodenumberL1` (+ `top`, `bot`, `area`, `zone`) |
| `Times.csv` | `SP`, `time` (days to the period's end) + optional `date_end`, `date_start`, `segment`, `kper` |
| `Heads.parquet` | `SP`, `layer`, `nodenumberL1`, `h` (dry / inactive = NA) |
| `Heads_baseline.parquet` | optional, same columns: enables Drawdown (baseline − run) and Difference (run − baseline) |
| `Sites.parquet` | optional GeoParquet points: `site`, `group`, `layer`, `node`, `cln_node` |
| `Targets.parquet` | optional: `obsname`, `site`, `group`, `role`, `date`, `SP`, `observed`, `simulated`, `simulated_baseline`, `weight` |
| `Observations.parquet` | optional: `site`, `datetime`, `value` (m), `source` (e.g. `manual`, `logger`, `survey`), `role` (the target role whose panel they belong in) |
| `CLN_nodes.parquet` | optional GeoParquet lines and/or points: `cln_node`, `kind`, `name`, `layer`, `gw_node`, `top`, and the bed level as `bed` or per segment `bed_p1`, `bed_p2`, … |
| `CLN_heads.parquet` | optional: `SP`, `cln_node`, `h`, `active` |
| `Fields.parquet` | optional: `field` (any name: `kx`, `kz`, `sy`, …), `layer`, `nodenumberL1`, `value`, `run` (`prior`, `run`, `ratio` = run / prior) |
| `Pumping.parquet` | optional: `SP`, `well`, `kind`, `cln_node`, `requested`, `delivered` (m³/d, out of the aquifer positive) |

With sites and targets, "6. Review Layers" shows the sites on the map (filter by
group); clicking one plots its observed values against the simulated (and
baseline) series under the hydrograph. Observations with weight 0 are drawn
hollow. With observations (the raw measurements behind the targets, which are
often resampled to stress periods or turned into differences), the site's
chart also draws them by source, faintly, with the site's simulated (and
baseline) head in every period, read from its node or CLN node.

With CLN nodes (connected linear network: drains, trenches, bores), the same
panel draws them coloured by head, or by head − bed, in the selected stress
period (grey = switched off). Clicking one plots its head against its bed and,
if it pumps, requested vs delivered pumping. `bed_p<k>` applies to the periods
of segment `k` in `Times.csv`; a well that moves between CLN nodes keeps one
`well` name and shows at each node for the periods it pumped there.

With parameter fields, "5. Visual Settings" adds a **Field** display: any field
on the selected layer, as the run's values, the prior's, or their ratio. Fields
named `k…` (conductivities) and ratios default to a log colour scale.

Node numbers are 1-based as MODFLOW writes them. `nodenumberL1` is a node's
position **within its layer**, so layers may have different cells (MODFLOW-USG):
each layer is drawn from its own polygons, and hydrographs join on
(`layer`, `nodenumberL1`). `SP` is one global period number, also when the run
was made in several chained segments.

`scripts/make_test_bundle.py <out_dir>` writes a small synthetic bundle (two
layers with different cells, two segments) to try this out; the tests in
`tests/` use it.

## Run with Docker

```bash
docker build -t rgw_heads_app .
docker run -d --restart unless-stopped --name rgw_heads -p 127.0.0.1:3839:3838 rgw_heads_app
```

The app listens on `3838` inside the container, bound to `127.0.0.1` on the
host so it's only reachable through the reverse proxy, not directly. See
`DEPLOYMENT.md` for the full deploy/redeploy reference (covers both this app and the companion
[GWchart / MF_lst](https://github.com/crayfisher/MF_lst) listing-file viewer).

> Demo data lives in `demo/` and is **gitignored** (it can be large); it is copied
> into the image via the Docker build context. Copy it to the server before
> building — see `DEPLOYMENT.md`.

## Demo model attribution

The bundled **HPM** demo is the Heretaunga Plains groundwater model, developed by
**Hawkes Bay Regional Council, NZ**, documented in:

> Rakowski P., Knowling M. (2018) *4997 Heretaunga Aquifer Groundwater Model
> Development Report.* Hawkes Bay Regional Council.
> [Executive summary](https://www.hbrc.govt.nz/assets/Document-Library/Publications-Database/4999-Executive-summary-of-Heretaunga-Aquifer-Groundwater-Model-Development-Report1.pdf)
> · [Full report](https://www.hbrc.govt.nz/assets/Document-Library/Publications-Database/4997-Heretaunga-Model-Groundwater-Development-Report.pdf)

## Acknowledgements

This app is **powered by [FloPy](https://github.com/modflowpy/flopy)** — the Python
package for creating, running, and post-processing MODFLOW models — which it uses
to read and process model grids and head outputs. If you use this tool in your
work, please also cite FloPy:

> Bakker, M., Post, V., Langevin, C.D., Hughes, J.D., White, J.T., Starn, J.J.,
> and Fienen, M.N. (2016). Scripting MODFLOW Model Development Using Python and
> FloPy. *Groundwater*, 54(5), 733–739. https://doi.org/10.1111/gwat.12413

## Reporting bugs

Please open an issue: https://github.com/crayfisher/MF_heads/issues
