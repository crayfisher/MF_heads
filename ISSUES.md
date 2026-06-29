# Known issues / backlog

Working state confirmed: MF6 (DIS/DISV/DISU), MF-USG, and MODFLOW-2005 models
load and render; georeferencing, basemap auto-toggle, sentinels, async ZIP
processing all verified. The items below are minor follow-ups, deferred to avoid
destabilising the working build.

## Bugs
- [x] **Layer not reset on new model load.** Fixed: the layer-max `observe`
  now clamps `select_layer` back to 1 when the newly loaded model has fewer
  layers than the current selection (prevents the slicing error).
- [x] **Focus-on-Model only works once.** Fixed: each click alternates a
  sub-metre nudge on the `initial_bounds` so deck.gl always sees a changed
  value and re-fits every click instead of only the first.
- [x] **Row/Col shown for non-structured grids.** Fixed: row/col are now shown
  only when the loaded model type is not USG (and the columns exist). The
  loaded type is tracked in `loaded_model_type` (ZIP load / manual upload);
  DISV/DISU never carry the columns, USG quadtree's base-grid row/col are
  suppressed.

## UX / docs
- [x] **USG "?" help is wrong.** Fixed: `georef_help` now has a USG-specific
  branch explaining the CRS is read from the gpkg's own embedded projection;
  no `usgs.model.reference` sidecar is involved. MF6 keeps the sidecar note.
- [x] **No help for manual parquet upload.** Fixed: added a `manual_help`
  tooltip next to the manual upload input documenting `Grid.parquet`,
  `Heads.parquet` and `Times.csv` and their schemas.
- [x] **Clarify manual parquet scope.** Fixed: added an inline note that the
  manual upload works for any model type (grid-type agnostic, not USG-only).

## Enhancements
- [x] **Baseline (drawdown) should accept `.hds`.** Done: the baseline input
  now accepts `.parquet` or `.hds`. A `.hds` is run through the parser's new
  `heads`/`heads_usg` mode (background worker) to produce a heads parquet, so
  drawdown works directly from model output. (Standard HeadFile + USG HeadUFile;
  DISU flat output is not layer-split.)

## Delivered 2026-06-26 (session 2)
- [x] **Bundled demo / test data.** `demo/<name>/` holds pre-processed outputs;
  a UI selector auto-discovers any folder with `Grid.parquet` and loads it
  instantly. A bundled `Heads_baseline.parquet` auto-enables Drawdown. `demo/`
  is gitignored but copied into the Docker image. Generators:
  `scripts/make_demo.py` (--grid/--heads/--baseline/--frames all|N) and
  `scripts/make_null_run.py`. Shipped `demo/hpm` = HPM mf2005, **5 years (60
  monthly frames)**, scenario + no-pumping null baseline (~191 MB).
- [x] **Load different scenarios after the base model.** New "Swap Scenario"
  uploader (.hds/.parquet) overrides heads while keeping the loaded grid;
  baseline `.hds` works the same way. Status indicator shows when an override is
  active. Loading a new base model clears overrides.
- [x] **Docker runs full model processing.** flopy + python added to
  `environment.yml`, `scripts/` un-excluded, `RGW_CONDA_ENV`/`RGW_CONDA_RUN`
  make the processing command env-aware (image runs `python`/`Rscript` directly
  in the active `base` env). ZIP + scenario/baseline `.hds` now work in-container.
- [x] **Fix: demo drawdown was 0 everywhere.** `hds_path` was picking the
  bundled baseline parquet as the scenario (scenario == baseline). Now excludes
  `grid|qtgrid|baseline` and prefers the exact `Heads.parquet`.

## Post-deploy feedback 2026-06-26 (reported after local test)
- [x] **Start-date/time offset persists across model loads.** Fixed:
  `apply_processed_model` now resets `start_date` to the app default
  (2019-06-01) when the newly loaded model carries no reference date, instead of
  silently keeping the previous model's date.
- [x] **Drawdown hydrograph y-axis should be reversed.** Fixed: the plotly chart
  now applies `yaxis = list(autorange = "reversed")` when
  `data_display == "Drawdown"`.
- [x] **Color scale direction inconsistent between models.** Pinned the default:
  `rev_colors` now defaults to FALSE. The fill mapping is deterministic —
  `domain_pal()` always returns `c(min, max)` ascending and `turbo` runs
  blue→red — so the default is now low=blue / high=red for every model. NOTE:
  the cross-model *inconsistency* (USG-T appearing opposite to the demo with the
  same toggle state) could not be reproduced from the code, which is
  deterministic; if it persists after this change, capture the USG-T dataset so
  the mapping can be inspected with real values.
- [x] **Clearer labels.** "Polygon Opacity" → "Cell Fill Opacity"; the map card
  header is now dynamic ("Groundwater Head Distribution Map" /
  "Drawdown Distribution Map"); hydrograph y-axis "Head" → "Head (m)".

## Styling & access 2026-06-29
- [x] **Crayfisher website styling.** Both apps now use the SAME vivid theme as
  the website (Quarto `theme: vapor`): bootswatch `"vapor"` deep-purple base +
  shared palette (`CF_*` constants: primary `#00bc8c`, accent `#32fbe2`, bg
  `#1a0933`, panel `#241046`, fg `#ece7f7`) + a byte-identical `custom_css` block
  (purple radial-gradient body, glowing navbar/cards, pill buttons with neon
  glow, neon accordion accents). All hardcoded slate colors (`#0f172a/#1e293b/
  #334155`) and plot backgrounds (ggplot + plotly) were migrated to the purple
  palette so charts sit seamlessly in the cards. The shared block is duplicated
  in both `app.R` files with a "keep in sync" header — edit both together.
- [x] **Styling refinements (both apps).** Top bar made solid dark `#150726`
  (was semi-transparent, leaked the body gradient as a pink tint); outline/danger
  button text given explicit readable colors (`btn-outline-danger` was invisible
  until hover); added a `← crayfisher.com` back button pinned to the right of the
  top bar linking to `https://crayfisher.com`.
- [x] **CSS wasn't loading in RGWheads (root cause of recurring nav-bar bugs).**
  `page_sidebar()` has no `header` argument, so `header = tags$head(tags$style(...))`
  rendered a `<head>` inside `<body>` which the browser discards — none of the
  custom CSS applied; the app showed raw vapor defaults (pink top bar included).
  Fix: compile the CSS into the theme with `bs_add_rules(app_theme, custom_css)`
  in BOTH apps (removed the broken `header=`/`tags$head` injection). Verified
  live with Playwright: navbar computes to `#150726` (dark navy), title text
  `#00bc8c` (teal).
- [x] **Top bar pink + dark text (both apps).** bslib's page-sidebar title bar
  pulls bg/text from `--bslib-page-sidebar-title-bg/-color` (vapor sets them
  pink/dark-contrast). Pinned both vars to the dark palette in the shared CSS.
- [x] **RGWchart empty-plot was white.** `plotly_empty()` defaults to white
  paper; wrapped both placeholders in an `empty_plot()` helper that sets
  `plot_bgcolor`/`paper_bgcolor` = `#241046` and lavender text.
- [x] **Light/dark toggle — decided AGAINST.** `vapor` is dark-only (hardcoded
  SCSS), so a real light mode would mean dropping vapor for a custom theme pair +
  mode-aware plots. Chose to stay dark-only to keep the exact website match.
  Revisit only if a light mode becomes a hard requirement.
- [x] **Login disabled (both apps).** The shinymanager gate is commented out in
  the UI (`secure_app`) and server (`secure_server`) in THIS app and in
  `../RGWchart` (both linked publicly from the site). Re-enable by uncommenting
  both blocks.
- [x] **Server-side upload type checks.** `accept=` is client-only, so both apps
  now validate uploads server-side before processing:
  - RGWheads: `validate_upload()` checks extension for every upload and verifies
    magic bytes for ZIP (PK..) and Parquet (PAR1 head+tail); `.hds`/`.csv` are
    extension + non-empty (no portable signature). Wired into `upload_zip`,
    `upload_files`, `upload_scenario`, `upload_baseline`.
  - RGWchart: `input$files` rejects anything outside `.lst/.list/.txt/.out` and
    empty files before parsing.
- [x] **Bot protection = Cloudflare (chosen).** Proxy both subdomains through
  Cloudflare's free tier (bot-fight mode + rate limiting; Turnstile only when
  suspicious). User to complete DNS/proxy setup — steps provided in chat
  2026-06-29. No in-app CAPTCHA (keeps the app accessible).

## Content / onboarding
- [ ] **Landing page.** Add an intro page (general concepts + instructions) shown
  before/alongside the map — candidate first tab of a future `page_navbar`.
- [ ] **HPM model reference.** Add attribution for the HPM demo model (author +
  link) in the UI (e.g. on the landing page or an About/info popover).

## Known limitations / follow-ups
- [ ] **HPM null run convergence.** Removing WEL left 46/420 stress periods not
  fully GMG-converged. Fine for a demo baseline; regenerate from a properly
  re-calibrated no-pumping run if a production baseline is needed.
- [ ] **DISU baseline/scenario `.hds`.** `heads` mode does not layer-split flat
  DISU output; baseline/scenario swap for DISU is unsupported.

## Next stage
- [ ] **Merge with `.lst` reader** - integrate listing-file parsing (budget /
  mass-balance / convergence) alongside the heads visualizer. Recommended as a
  `page_navbar` page in THIS app (one image/env), not a separate container.
  Existing `.lst` app is `../RGWchart` (rocker/shiny-verse + reticulate).
