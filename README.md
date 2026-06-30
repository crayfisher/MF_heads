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

## Run with Docker

```bash
docker build -t rgw_heads_app .
docker run -d --restart unless-stopped --name rgw_heads -p 3839:3838 rgw_heads_app
```

The app listens on `3838` inside the container. See `DEPLOYMENT.md` for the full
deploy/redeploy reference (covers both this app and the companion
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
