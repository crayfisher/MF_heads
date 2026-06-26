# Docker Deployment Guide: RGWheads

This guide covers the architecture, build instructions, and deployment strategies for containerizing the `RGWheads` Shiny Application.

## 1. Architecture

The Docker container is built on top of **`mambaorg/micromamba`** rather than the standard `rocker/shiny` image. 
*   **Why?** Geospatial R packages (`sf`, `stars`, `arrow`) require massive system-level libraries (GDAL, GEOS, PROJ, C++ compilers) that take hours to compile from source in standard Linux environments. 
*   **The Fix:** By using Conda/Micromamba, we instantly download the pre-compiled binary versions of these libraries, reducing build times from hours to minutes.

## 1b. Scaling strategy (multiple apps / a model platform)

This image currently bundles *everything*: the heavy conda env (R geo stack +
rdeck + python + flopy) **and** the app code + demo data. That is fine for one
app, but the roadmap (per-client apps, a properties/BC viewer, hosted-model
automation, an AI run-assistant) is better served by separating concerns:

1.  **Base runtime image (build rarely).** A `Dockerfile.base` that stops after
    the `micromamba install` + `rdeck` build → tag `rgw-base:latest`. This is the
    slow, ~GB layer (GDAL/PROJ/flopy/rdeck). It almost never changes.

2.  **Per-app images (build often, cheap).** Each app's `Dockerfile` is
    `FROM rgw-base:latest` + `COPY` of just that app's code and its `demo/` /
    client config. Rebuilds are seconds, and every client app is guaranteed an
    identical runtime. The app reads its config from env vars (`APP_PASSWORD`,
    `RGW_CONDA_ENV`, and e.g. a future `RGW_APP_TITLE` / `RGW_DEMO_DIR`).

3.  **Separate the "runner" from the "viewer" (longer term).** For hosted models
    with weekly WEL/recharge updates, run a **processing service** (flopy +
    MODFLOW executables, on a cron/queue) that writes parquet outputs to a shared
    volume or object store. The Shiny viewers (this heads app, the `.lst`
    budget/convergence reader, future BC viewer) stay lean and just *read* those
    parquet outputs. The AI "run assistant" becomes another client of the same
    runner API. This keeps the GPU/parsing-heavy work off the interactive apps
    and lets each app scale independently.

**For today/tomorrow:** deploy this single self-contained image as-is (it now does
full ZIP/HDS processing). Adopt the base-image split (#1/#2) when you stand up the
second client app; defer the runner/viewer split (#3) until automation starts.
Merging the `.lst` reader is cleanest as **another page in this same app**
(`page_navbar` with a "Heads" page and a "Listing" page) sharing one image/env —
not a second container.

## 2. Environment Management (`environment.yml`)

The application's dependencies are tracked strictly in `environment.yml`. 
To keep the Docker image small and secure, this file was manually pruned to *only* include production libraries. It excludes local data science utilities (like Jupyter) that were present in the development environment.

**Important Packages included:**
*   `r-base`, `r-shiny`, `r-bslib`, `r-shinymanager`
*   `r-sf`, `r-stars`, `r-arrow`, `r-dplyr`
*   `c-compiler`, `cxx-compiler` (Needed to compile packages from GitHub)

**Special Case: `rdeck`**
The `rdeck` package is **not** available on CRAN or conda-forge. It is a GitHub-only package. 
If you look at the `Dockerfile`, there is a dedicated line using `remotes::install_github('qfes/rdeck')` to compile it from source. This is why the C++ compilers were added to the `environment.yml`.

## 3. Security (shinymanager)

The application is protected behind a login screen using `shinymanager`. 
*   **Username:** `viewer`
*   **Password:** The password is **never** hardcoded into `app.R` or the Docker image. 
*   It securely reads from an environment variable (`APP_PASSWORD`) that you inject at runtime. If you run the app locally in RStudio without Docker, it will default to `rgw_secret` so your local development is not interrupted.

## 3b. Bundled Demo / Test Data

For demonstrations the app ships a **pre-processed sample model** under `demo/`.
Each demo is a folder (e.g. `demo/hpm/`) holding the already-processed outputs the
app loads directly:

```
demo/hpm/
  Grid.parquet            # sf polygons (nodenumber, nodenumberL1, row/col)
  Heads.parquet           # SP, layer, nodenumberL1, h        (scenario)
  Heads_baseline.parquet  # same schema (optional null run)   -> enables Drawdown
  Times.csv               # time, kstp, kper, SP
  crs_used.txt  sentinels.txt  time_units.txt  start_date.txt  model_type.txt
```

In the UI a **"Demo / Test Data"** selector + **Load** button (under *1. Data
Uploads*) loads any folder found in `demo/` instantly — **no upload, no flopy, no
model processing at runtime**. The app auto-discovers any subfolder of `demo/`
that contains a `Grid.parquet`, so adding more demos is just dropping in another
folder. If a demo also contains `Heads_baseline.parquet` (e.g. a no-pumping
"null" run), **Drawdown** is wired up automatically on load.

### git vs. Docker (demo is NOT committed)

`demo/` is **gitignored** — demo data can be large and does not belong in the
repo. It is still shipped to the server *inside the image*, because the Docker
**build context is the working directory, not git**:

*   `.dockerignore` has `!demo/` / `!demo/**` exceptions, so `COPY . /app` copies
    `demo/` into the image as long as the folder exists locally when you build.
*   **Therefore: generate `demo/` (below) on the build machine before
    `docker build`.** A bare `git clone` will not contain it.

The image already excludes `scripts/`, `data/` and the raw model files to stay
lean and avoid running flopy at runtime — the demo only needs the small
parquet/csv outputs, so it behaves identically in the container and locally.

### Size / time resolution

Full transient models are large (HPM = **420 monthly stress periods ≈ 35 years**,
~485 MB of heads per run). You control the trade-off with `--frames`:

*   `--frames all` keeps every stress period (full seasonality). With a scenario
    **and** a baseline this can be several hundred MB — fine if you are happy with
    the server/image size.
*   `--frames 60` keeps the first 60 *consecutive* months (5 years), renumbered
    `1..60`, preserving monthly seasonal behaviour at a fraction of the size.

The real model `time` (days) is always preserved for the calendar axis.

### Regenerating / adding a demo

Needs `flopy_env` (flopy + a MODFLOW exe); run locally, not in the container.
Geometry/metadata come from a light `--grid` source; the heavy heads come from
explicit `--heads` (scenario) and optional `--baseline` (null) `.hds` files:

```bash
# Optional: build a no-pumping "null" run to use as the drawdown baseline.
conda run -n flopy_env python scripts/make_null_run.py data/HPM HPM_M3.nam HPM_null --remove WEL

# Assemble the demo. The shipped demo/hpm uses --frames 60 (5 years monthly,
# ~191 MB: Grid 8 + Heads 96 + Baseline 96). Use --frames all for the full
# 35-year run (~977 MB) or --frames 36 (3 years, ~175 MB).
conda run -n flopy_env python scripts/make_demo.py --out demo/hpm \
    --grid data/HPM.zip --model-type mf2005 \
    --heads data/HPM/HPM_M3.hds --baseline data/HPM/HPM_null.hds --frames 60
```

> **Full processing in the container:** ZIP upload and scenario/baseline `.hds`
> loading run flopy via `scripts/`, which **are** included in the image (flopy is
> in `environment.yml`, and the Dockerfile sets `RGW_CONDA_ENV=base` /
> `RGW_CONDA_RUN=""` so the app calls `python`/`Rscript` directly in the active
> env — there is no `conda` binary in the micromamba image). *Running* models
> (null runs, weekly automation) additionally needs MODFLOW executables, e.g.
> `micromamba run -n base get-modflow :flopy` at build time.

## 4. Building the Image

To build the Docker image, run the following command in the project root (where the `Dockerfile` is located). 
This will read the `.dockerignore` file, ensuring large `data/` files and `.Rhistory` caches are not copied into the image.

```bash
docker build -t rgw_heads_app .
```

## 5. Running the Container

Once built, launch the container using `docker run`. You must explicitly map port `3838` (the Shiny default) and inject your secure password:

**Foreground Mode (For testing and seeing error logs):**
```bash
docker run -p 3838:3838 -e APP_PASSWORD="MySuperSecurePassword123" rgw_heads_app
```

**Detached/Daemon Mode (For production deployment):**
```bash
docker run -d --restart unless-stopped --name rgw_heads \
  -p 3838:3838 -e APP_PASSWORD="MySuperSecurePassword123" rgw_heads_app
```

Once running, the application will be accessible at: `http://<your-server-ip>:3838` or `http://localhost:3838`.

## 6. Running alongside another app (e.g. RGWchart)

`3838` is the port *inside* the container; `-p HOST:CONTAINER` maps it to a host
port. Two containers cannot share the same **host** port, but each keeps its own
internal `3838`, so just map them to different host ports — **no need to stop the
other app**:

```bash
# RGWchart already running on host port 3838
docker run -d --restart unless-stopped --name rgw_heads \
  -p 3839:3838 -e APP_PASSWORD="..." rgw_heads_app
```

RGWheads is then at `http://<server>:3839`, RGWchart stays at `:3838`.

**Cleaner URLs (recommended next):** put a reverse proxy on 443 in front of both
and route by subdomain (add DNS A-records → server). [Caddy](https://caddyserver.com)
gives automatic HTTPS and handles Shiny's websockets out of the box:

```
# /etc/caddy/Caddyfile
lst.apps.crayfisher.com { reverse_proxy localhost:3838 }
heads.apps.crayfisher.com { reverse_proxy localhost:3839 }
```

Then both are reachable as clean `https://lst.apps.crayfisher.com` /
`https://heads.apps.crayfisher.com` with no port numbers. See §1b for when to graduate
to a shared base image or ShinyProxy (per-user isolation/scaling) — both can wait
until you have multiple concurrent users.

## 7. Local test deploy (verifying this build)

Before deploying to the server, smoke-test locally:

```bash
docker build -t rgw_heads_app .
docker run -d --rm --name rgw_heads_test -p 3839:3838 -e APP_PASSWORD=test rgw_heads_app
# open http://localhost:3839 ; load the HPM demo; toggle Heads/Drawdown
docker logs -f rgw_heads_test     # watch for processing/runtime errors
docker stop rgw_heads_test
```
