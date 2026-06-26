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

## Next stage
- [ ] **Merge with `.lst` reader** - integrate listing-file parsing (budget /
  mass-balance / convergence) alongside the heads visualizer. New session.
