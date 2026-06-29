# Docker Deployment Guide: RGWheads (+ RGWchart)

This guide covers the architecture, build instructions, and deployment strategies
for the `RGWheads` Shiny application. **§8 is the exact deploy/redeploy command
reference for both `RGWheads` and `RGWchart`** (the two apps are separate repos,
images, and containers).

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
    identical runtime. The app reads its config from env vars (`RGW_CONDA_ENV`,
    and e.g. a future `RGW_APP_TITLE` / `RGW_DEMO_DIR`).

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

## 3. Security (public access + Cloudflare)

**Login is currently disabled.** The app is public (linked from the Crayfisher
website), so the `shinymanager` gate is commented out in both the UI
(`secure_app`) and server (`secure_server`) — re-enable by uncommenting both
blocks in `app.R`. The `APP_PASSWORD` env var is no longer needed.

Because there is no in-app auth, two layers protect the app:
*   **Cloudflare** edge (Bot Fight Mode + optional rate limiting) — see §6.
*   **Server-side upload validation** in `app.R` (`validate_upload()`): every
    upload is checked by extension, and ZIP/Parquet are verified by magic bytes,
    before anything reaches the flopy/MODFLOW pipeline.
Do **not** expose the container publicly until Cloudflare is in front of it.

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

The image excludes `data/` and the raw model files (31 GB) to stay lean, but
**does** include `scripts/` + flopy so ZIP/`.hds` processing works in-container
(see the processing note below). The demo itself only needs the small parquet/csv
outputs, so it behaves identically in the container and locally.

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

### Transferring the demo to a remote server

`demo/` is gitignored, so `git clone`/`pull` will **not** bring it to the server.
Copy it separately into the **same project folder** (so it lands at `<repo>/demo/`)
**before** `docker build` — the build context, not git, carries it. You only
re-transfer when the demo changes, not on every deploy.

```bash
# Option A - rsync (resumable, no zip step). Run from the project root locally:
rsync -avz --progress demo/ user@server:~/apps/RGWheads_oct-quad/demo/

# Option B - tar + scp:
tar czf demo.tar.gz demo/
scp demo.tar.gz user@server:~/apps/RGWheads_oct-quad/
ssh user@server 'cd ~/apps/RGWheads_oct-quad && tar xzf demo.tar.gz && rm demo.tar.gz'
```

The parquet is already zstd-compressed, so gzip/zip barely shrinks it (~191 MB
either way). Full server flow:

```bash
git pull                                          # code (no demo)
rsync -avz demo/ server:~/apps/RGWheads_oct-quad/demo/   # one-time / on demo change
docker build -t rgw_heads_app .                   # build context includes demo/
docker run -d --restart unless-stopped --name rgw_heads -p 3839:3838 rgw_heads_app
```
(See **§8** for the full deploy/redeploy reference for both apps.)

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

Once built, launch the container with `docker run`. The app listens on `3838`
*inside* the container; map it to a host port with `-p HOST:3838`. RGWheads uses
host port **3839** (RGWchart takes 3838 — see §6). No password is needed (login
is disabled, §3).

**Foreground mode (testing — see logs live):**
```bash
docker run --rm -p 3839:3838 rgw_heads_app
```

**Detached/daemon mode (production):**
```bash
docker run -d --restart unless-stopped --name rgw_heads -p 3839:3838 rgw_heads_app
```

Then it's reachable at `http://<server-ip>:3839` (or `http://localhost:3839`).

> The exact, copy-paste commands for a **first deploy** and a **redeploy** of
> **both** apps are in **§8** — that is the authoritative command reference.

## 6. Running alongside another app (e.g. RGWchart)

`3838` is the port *inside* the container; `-p HOST:CONTAINER` maps it to a host
port. Two containers cannot share the same **host** port, but each keeps its own
internal `3838`, so just map them to different host ports — **no need to stop the
other app**:

```bash
# RGWchart already running on host port 3838
docker run -d --restart unless-stopped --name rgw_heads -p 3839:3838 rgw_heads_app
```

RGWheads is then at `http://<server>:3839`, RGWchart stays at `:3838`.

**Cleaner URLs (recommended next):** put a reverse proxy on 443 in front of both
and route by subdomain (add DNS A-records → server). [Caddy](https://caddyserver.com)
gives automatic HTTPS and handles Shiny's websockets out of the box:

```
# /etc/caddy/Caddyfile
lst.crayfisher.com   { reverse_proxy localhost:3838 }
heads.crayfisher.com { reverse_proxy localhost:3839 }
```

Then both are reachable as clean `https://lst.crayfisher.com` /
`https://heads.crayfisher.com` with no port numbers. See §1b for when to graduate
to a shared base image or ShinyProxy (per-user isolation/scaling) — both can wait
until you have multiple concurrent users.

> **Subdomain note (single-level on purpose).** Use `heads.crayfisher.com` /
> `lst.crayfisher.com`, NOT nested `*.apps.crayfisher.com`. Cloudflare's free
> Universal SSL only covers the apex + one wildcard level (`*.crayfisher.com`),
> so a third-level host like `heads.apps.crayfisher.com` would fail TLS through
> the Cloudflare proxy (would need paid Advanced Certificate Manager).

**Cloudflare (edge bot/abuse protection).** Login is disabled on both apps, so
they sit behind Cloudflare's free tier instead of an in-app gate:
1. Add `crayfisher.com` to Cloudflare; switch nameservers at the registrar.
2. DNS: add **proxied (orange-cloud)** A records `heads` and `lst` → server IP.
3. SSL/TLS mode = **Full (strict)** (Caddy holds valid origin certs).
4. Security → Bots → enable **Bot Fight Mode**; optionally add a WAF rate-limit
   rule. Leave Turnstile off unless real abuse appears.
5. Keep **WebSockets** enabled (Network tab) — Shiny needs them.
Optionally trust Cloudflare's forwarded IPs in Caddy so logs/rate-limits see the
real client IP (`trusted_proxies`/`X-Forwarded-For`).

## 7. Local test deploy (verifying this build)

Before deploying to the server, smoke-test locally:

```bash
docker build -t rgw_heads_app .
docker run -d --rm --name rgw_heads_test -p 3839:3838 rgw_heads_app
# open http://localhost:3839 ; load the HPM demo; toggle Heads/Drawdown
docker logs -f rgw_heads_test     # watch for processing/runtime errors
docker stop rgw_heads_test
```

## 8. Deploy & redeploy — exact commands (both apps)

This is the authoritative command reference. The two apps are **separate repos /
images / containers**:

| App      | Repo dir (server)            | Image           | Container   | Host→ctr port | App file in image            |
|----------|------------------------------|-----------------|-------------|---------------|------------------------------|
| RGWheads | `~/apps/RGWheads_oct-quad`   | `rgw_heads_app` | `rgw_heads` | `3839→3838`   | `/app/app.R`                 |
| RGWchart | `~/apps/RGWchart`            | `rgw_chart_app` | `rgw_chart` | `3838→3838`   | `/srv/shiny-server/app.R`    |

> Names above are the convention used here. If your existing containers/images
> use different names, run `docker ps` / `docker images` and substitute them
> (or adopt these names — the redeploy below removes the old container anyway).

### The one rule that bites everyone

`docker build` makes a **new image**. A **running container keeps running the old
image** until you remove and recreate it. So a rebuild alone changes nothing on
the live site — you must `docker rm -f <name>` then `docker run …` again. (Code
is **copied in at build time**; there is no live mount.) The website is separate
— GitHub Pages serves `docs/` on push, no Docker.

### A. RGWheads — first deploy

```bash
cd ~/apps/RGWheads_oct-quad
git pull
# demo/ is gitignored — copy it in BEFORE building (build context, not git,
# carries it). One-time / only when the demo changes. Run from your LOCAL repo:
#   rsync -avz demo/ user@server:~/apps/RGWheads_oct-quad/demo/
docker build -t rgw_heads_app .
docker run -d --restart unless-stopped --name rgw_heads -p 3839:3838 rgw_heads_app
docker logs -f rgw_heads          # Ctrl-C once you see it listening / no errors
```

### B. RGWchart — first deploy

```bash
cd ~/apps/RGWchart
git pull
docker build -t rgw_chart_app .   # build context is small (copies app.R + scripts/)
docker run -d --restart unless-stopped --name rgw_chart -p 3838:3838 rgw_chart_app
docker logs -f rgw_chart
```

### C. Redeploy either app after a code change

Same three steps; the `docker rm -f` is the part that's easy to forget:

```bash
# --- RGWheads ---
cd ~/apps/RGWheads_oct-quad && git pull
docker build -t rgw_heads_app .
docker rm -f rgw_heads
docker run -d --restart unless-stopped --name rgw_heads -p 3839:3838 rgw_heads_app

# --- RGWchart ---
cd ~/apps/RGWchart && git pull
docker build -t rgw_chart_app .
docker rm -f rgw_chart
docker run -d --restart unless-stopped --name rgw_chart -p 3838:3838 rgw_chart_app

docker image prune -f             # optional: reclaim the now-dangling old images
```

### D. Verify the new code is actually live (when it "still looks old")

```bash
# 1) Is the running container newer than your rebuild?
docker ps                         # check the CONTAINER's CREATED column
docker images | grep rgw          # check the IMAGE's CREATED column
#    Container older than the image  ->  you skipped `docker rm -f` + run (step C).

# 2) Is the new code inside the running container? (look for a known-new string)
docker exec rgw_heads grep -c app-back-btn /app/app.R              # expect >= 1
docker exec rgw_chart grep -c app-back-btn /srv/shiny-server/app.R # expect >= 1
#    0  ->  the build missed your changes: confirm `git pull` ran in the dir you
#           built from (`git log --oneline -1`), and you rebuilt that image.

# 3) Still old in the browser but correct in the container  ->  it's a cache:
#    - hard refresh (Ctrl/Cmd+Shift+R) or an incognito window (Shiny caches JS/CSS)
#    - if the subdomain is proxied by Cloudflare, purge cache (or enable
#      Development Mode briefly)
```

### Notes

*   `APP_PASSWORD` / `RGWCHART_PASSWORD` are no longer required (login disabled).
*   Host ports must stay distinct (heads **3839**, chart **3838**); both map to
    `3838` inside their containers, so don't change the right-hand `:3838`.
*   Smoke-test after redeploy: load the page (hard refresh), check the dark theme
    + dark top bar + `← crayfisher.com` button; for RGWheads also load the HPM
    demo and toggle Heads/Drawdown.
