# Known issues / backlog

Working state confirmed: MF6 (DIS/DISV/DISU), MF-USG, and MODFLOW-2005 models
load and render; georeferencing, basemap auto-toggle, sentinels, async ZIP
processing all verified. The items below are minor follow-ups, deferred to avoid
destabilising the working build.

## Bugs
- [ ] **Layer not reset on new model load.** If a layer > 1 is selected and the
  newly loaded model has fewer layers, slicing errors. Reset `select_layer` to 1
  when a new model is loaded (the max is updated, but the current value isn't
  clamped).
- [ ] **Focus-on-Model only works once.** `rdeck_proxy(initial_bounds=...)`
  re-fits on the first click but not subsequent clicks (deck.gl treats it as the
  initial view). Needs a mechanism that forces a re-fit each click (e.g. nudge
  the view_state or toggle a value).
- [ ] **Row/Col shown for non-structured grids.** The map tooltip shows row/col
  whenever those columns exist; USG `qtgrid` carries base-grid row/col, so they
  appear there too. Restrict row/col to structured (DIS / MF2005) models.

## UX / docs
- [ ] **USG "?" help is wrong.** It describes a `usgs.model.reference` sidecar,
  but the USG workflow is gpkg-based: CRS comes from the gpkg's own embedded CRS,
  geometry + global node numbers + layer field from the gpkg. A reference file
  does not help USG. Update the help text for model type = usg.
- [ ] **No help for manual parquet upload.** Add instructions describing the
  expected files/schema: `Grid.parquet` (sf polygons with `nodenumber`,
  `nodenumberL1`, optional `layer`), `Heads.parquet` (`SP`, `layer`,
  `nodenumberL1`, `h`), `Times.csv` (`time`, `SP`, ...).
- [ ] **Clarify manual parquet scope.** Manual parquet upload is NOT USG-only -
  it works for any model type, since it loads already-processed parquet/csv
  outputs (grid-type agnostic). Docs/labels currently imply USG.

## Enhancements
- [ ] **Baseline (drawdown) should accept `.hds`.** Currently the baseline
  upload accepts `.parquet` only; allow an `.hds` (run it through the parser to
  produce a heads parquet) so drawdown works directly from model output.

## Next stage
- [ ] **Merge with `.lst` reader** - integrate listing-file parsing (budget /
  mass-balance / convergence) alongside the heads visualizer. New session.
