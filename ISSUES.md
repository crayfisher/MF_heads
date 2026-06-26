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

## Post-deploy feedback 2026-06-26 (reported after local test, to fix next)
- [ ] **Start-date/time offset persists across model loads.** After loading a
  demo then a new model (USG), the time offset from the first model is preserved.
  Reset `start_date` (and any time baseline) when a new base model loads, the
  same way layers/scenario/baseline are now reset in `apply_processed_model`.
- [ ] **Drawdown hydrograph y-axis should be reversed.** When `data_display ==
  "Drawdown"`, invert the chart y-axis (drawdown increases downward).
- [ ] **Color scale direction inconsistent between models.** The test/demo model
  renders low=red / high=blue, opposite to the USG-T model, even though the
  "Reverse Color Ramp" box is ticked in both (unticking flips it). The default
  ramp direction should be consistent regardless of model — pin the palette to
  data semantics (e.g. low=blue/high=red for heads) rather than relying on the
  toggle landing differently per dataset.
- [ ] **Clearer labels.** Use domain terms instead of generic ones, e.g. "Heads"
  rather than "polygons" in the layer/legend/labels.

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
