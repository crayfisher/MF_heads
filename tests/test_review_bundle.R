# Tests for scripts/review_bundle.R against the SYNTHETIC bundle written by
# scripts/make_test_bundle.py.
#
#   cd apps/mf_heads && Rscript -e 'testthat::test_dir("tests")'      (flopy_env)
#
# The generator needs Python with geopandas: CF_TEST_PYTHON names the
# interpreter (default: python3 on PATH); the tests skip if it cannot run.
# CF_TEST_BUNDLE=<folder> additionally runs the reader checks on a real bundle
# kept outside the repo (never commit one).
library(testthat)
suppressMessages({ library(sf); library(dplyr); library(arrow) })
app <- if (file.exists("../scripts/review_bundle.R")) ".." else "."
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
source(file.path(app, "lib", "cf_charts.R"))
source(file.path(app, "scripts", "review_bundle.R"))

make_synthetic <- function() {
  py <- Sys.getenv("CF_TEST_PYTHON", "python3")
  root <- tempfile("bundles_")
  out <- file.path(root, "runs", "synthetic")
  status <- suppressWarnings(system2(py, c(shQuote(file.path(app, "scripts", "make_test_bundle.py")),
                                           shQuote(out)), stdout = FALSE, stderr = FALSE))
  if (!identical(status, 0L) || !rb_is_bundle(out)) return(NULL)
  list(root = normalizePath(root), dir = normalizePath(out))
}
syn <- make_synthetic()
need_syn <- function() if (is.null(syn)) skip("synthetic bundle generator could not run (set CF_TEST_PYTHON)")

test_that("bundles are found under the root and resolved inside it only", {
  need_syn()
  expect_equal(rb_list(syn$root), "runs/synthetic")
  expect_equal(rb_resolve(syn$root, "runs/synthetic"), syn$dir)
  expect_error(rb_resolve(syn$root, "../.."), "outside")
  expect_error(rb_resolve(syn$root, "runs"), "Not a review bundle")
  expect_equal(rb_list(""), character(0))
})

test_that("the root itself may be a bundle", {
  need_syn()
  expect_equal(rb_list(syn$dir), ".")
  expect_equal(rb_resolve(syn$dir, "."), syn$dir)
})

test_that("CF_BUNDLE_ROOT unset disables bundle opening", {
  withr::local_envvar(CF_BUNDLE_ROOT = "")
  expect_equal(rb_root(), "")
  withr::local_envvar(CF_BUNDLE_ROOT = "/no/such/folder")
  expect_equal(rb_root(), "")
})

test_that("manifest and CRS are read", {
  need_syn()
  m <- rb_manifest(syn$dir)
  expect_equal(m$nodes_per_layer, c(36L, 9L))
  expect_equal(rb_epsg(m$crs), "32633")
  expect_equal(rb_epsg(NULL), "NONE")
  g <- rb_read_sf(file.path(syn$dir, "Grid.parquet"))
  expect_equal(st_crs(g)$epsg, 32633L)          # recovered from GeoParquet PROJJSON
  expect_identical(attr(g, "sf_column"), "geometry")
  expect_match(rb_summary(m, syn$dir), "2 layers, 10 periods in 2 segments")
})

test_that("layers keep their own cells; heads join on (layer, nodenumberL1)", {
  need_syn()
  g <- rb_read_sf(file.path(syn$dir, "Grid.parquet"))
  expect_equal(as.vector(table(g$layer)), c(36L, 9L))
  heads <- read_parquet(file.path(syn$dir, "Heads.parquet"))
  # Layer 2 drawn from its own 9 polygons: every one gets exactly one head.
  l2 <- g %>% filter(layer == 2) %>%
    inner_join(heads %>% filter(SP == 1, layer == 2), by = c("layer", "nodenumberL1"))
  expect_equal(nrow(l2), 9L)
  # Global node 41 is layer 2, cell 5 -- not layer 1, cell 41 (which does not exist).
  hit <- st_drop_geometry(g)[g$nodenumber == 41, ]
  expect_equal(c(hit$layer, hit$nodenumberL1), c(2L, 5L))
  # Dry and inactive cells are NA, not sentinels.
  expect_true(all(is.na(heads$h[heads$layer == 2 & heads$nodenumberL1 == 9])))
})

test_that("calendar dates come from Times.csv date_end", {
  need_syn()
  times <- readr::read_csv(file.path(syn$dir, "Times.csv"), show_col_types = FALSE)
  d <- rb_times_dates(times)
  expect_equal(format(d[1], "%Y-%m-%d"), "2020-01-31")
  expect_null(rb_times_dates(data.frame(SP = 1, time = 1)))
})

test_that("drawdown and difference have opposite signs; NA stays NA", {
  expect_equal(rb_compare(9, 10, "Drawdown"), 1)
  expect_equal(rb_compare(9, 10, "Difference"), -1)
  expect_true(is.na(rb_compare(NA_real_, 10, "Difference")))
})

test_that("a site's targets: observed, simulated, baseline, weight", {
  need_syn()
  targets <- read_parquet(file.path(syn$dir, "Targets.parquet"))
  tg <- rb_site_targets(targets, "S1")
  expect_equal(nrow(tg), 5L)                      # observed every second period
  expect_s3_class(tg$date, "Date")
  expect_false(is.unsorted(tg$date))
  expect_equal(tg$residual, tg$observed - tg$simulated)
  expect_equal(nrow(rb_site_targets(targets, "nope")), 0L)
  p <- plotly::plotly_build(rb_targets_plot(tg, "S1"))
  names <- vapply(p$x$data, function(t) t$name %||% "", character(1))
  expect_true(all(c("Simulated", "Baseline", "Observed") %in% names))
  # A weight-0 observation gets its own hollow series.
  tg$weight[1] <- 0
  p0 <- plotly::plotly_build(rb_targets_plot(tg))
  expect_true("Observed (weight 0)" %in% vapply(p0$x$data, function(t) t$name %||% "", character(1)))
  expect_equal(rb_weight_label(c(1, 1)), "weight 1")
  expect_equal(rb_weight_label(c(0, 2)), "weights 0–2")
  expect_equal(rb_weight_label(c(8.9513, 41.9137)), "weights 8.95–41.9")
})

test_that("measurements behind the targets, with the site's head in every period", {
  need_syn()
  obs <- read_parquet(file.path(syn$dir, "Observations.parquet"))
  o <- rb_site_observations(obs, "S1")
  expect_s3_class(o$datetime, "POSIXct")
  expect_equal(format(o$datetime[1], "%Y-%m-%d %H:%M"), "2020-01-01 00:00")  # clock time kept
  expect_setequal(unique(o$source), c("logger", "manual"))
  expect_null(rb_site_observations(obs, "S2"))      # a site without measurements
  expect_null(rb_site_observations(NULL, "S1"))

  sites <- st_drop_geometry(rb_read_sf(file.path(syn$dir, "Sites.parquet")))
  grid <- st_drop_geometry(rb_read_sf(file.path(syn$dir, "Grid.parquet")))[, c("nodenumber", "layer", "nodenumberL1")]
  targets <- read_parquet(file.path(syn$dir, "Targets.parquet"))
  # S1 (GW node): every period, matching the targets where they exist.
  s1 <- rb_site_series(syn$dir, sites[sites$site == "S1", ], grid)
  expect_equal(nrow(s1), 10L)
  t1 <- targets[targets$site == "S1", ]
  expect_equal(s1$h[match(t1$SP, s1$SP)], t1$simulated, tolerance = 1e-5)
  expect_equal(s1$h_base[match(t1$SP, s1$SP)], t1$simulated_baseline, tolerance = 1e-5)
  # S3 (CLN node): from CLN_heads.
  s3 <- rb_site_series(syn$dir, sites[sites$site == "S3", ], grid)
  t3 <- targets[targets$site == "S3", ]
  expect_equal(s3$h[match(t3$SP, s3$SP)], t3$simulated, tolerance = 1e-5)

  sim <- merge(rb_period_axis(read.csv(file.path(syn$dir, "Times.csv")))$df, s1, by = "SP")
  p <- plotly::plotly_build(rb_targets_plot(rb_site_targets(targets, "S1"), "S1", obs = o, sim = sim))
  nm <- vapply(p$x$data, function(t) t$name %||% "", character(1))
  expect_true(all(c("Measured: logger", "Measured: manual", "Simulated (every period)",
                    "Baseline (every period)", "Target (observed)") %in% nm))
  expect_equal(length(p$x$data[[which(nm == "Simulated (every period)")]]$x), 10L)
  # Measurements whose role no target has get a panel of their own.
  o$role <- "elsewhere"
  p2 <- plotly::plotly_build(rb_targets_plot(rb_site_targets(targets, "S1"), obs = o, sim = sim))
  y_titles <- unlist(lapply(p2$x$layout[grepl("^yaxis", names(p2$x$layout))], function(a) if (is.list(a$title)) a$title$text else a$title))
  expect_true(any(grepl("elsewhere", y_titles)))
})

test_that("every site group gets a valid colour, also past the palette size", {
  expect_equal(rb_group_colours(c("a", "b")), CF_SERIES_COLOURS[1:2])
  many <- rb_group_colours(paste0("g", 1:12))
  expect_length(many, 12)
  expect_false(anyNA(many))
  expect_length(unique(many), 12)
})

test_that("site groups split the synthetic sites", {
  need_syn()
  s <- rb_read_sf(file.path(syn$dir, "Sites.parquet"))
  expect_equal(sort(unique(s$group)), c("obs_a", "obs_b"))
  expect_equal(st_crs(s)$epsg, 32633L)
})

test_that("CLN bed follows the segment; head - bed and switched-off nodes", {
  need_syn()
  cln <- rb_read_sf(file.path(syn$dir, "CLN_nodes.parquet"))
  times <- readr::read_csv(file.path(syn$dir, "Times.csv"), show_col_types = FALSE)
  beds <- rb_cln_bed(cln, times)
  expect_equal(nrow(beds), 4L * 10L)
  # Node 1: bed_p1 = 95.5 in segment 1 (SP 1-6), bed_p2 = 95.0 in segment 2.
  expect_equal(beds$bed[beds$cln_node == 1 & beds$SP == 6], 95.5)
  expect_equal(beds$bed[beds$cln_node == 1 & beds$SP == 7], 95.0)
  # A single `bed` column applies to every period.
  one <- cln; one$bed <- 50
  expect_true(all(rb_cln_bed(one, times)$bed == 50))

  ch <- read_parquet(file.path(syn$dir, "CLN_heads.parquet"))
  v1 <- rb_cln_period_values(ch, beds, 1, "Head - bed")
  expect_true(is.na(v1$value[v1$cln_node == 3]))        # node 3 is off in segment 1
  n1 <- v1[v1$cln_node == 1, ]
  expect_equal(n1$value, n1$h - n1$bed)
  v7 <- rb_cln_period_values(ch, beds, 7, "Head")
  expect_false(is.na(v7$value[v7$cln_node == 3]))

  s3 <- rb_cln_series(ch, beds, times, 3)
  expect_equal(nrow(s3), 10L)
  expect_true(all(is.na(s3$h[s3$SP <= 6])))
  expect_s3_class(s3$x, "Date")
})

test_that("pumping at a CLN node follows a moving well", {
  need_syn()
  times <- readr::read_csv(file.path(syn$dir, "Times.csv"), show_col_types = FALSE)
  pumping <- read_parquet(file.path(syn$dir, "Pumping.parquet"))
  p2 <- rb_cln_pumping(pumping, times, 2)
  p3 <- rb_cln_pumping(pumping, times, 3)
  expect_equal(p2$SP, 1:6)                               # the well was at node 2 ...
  expect_equal(p3$SP, 7:10)                              # ... then moved to node 3
  expect_true(all(p3$delivered < p3$requested))
  expect_null(rb_cln_pumping(pumping, times, 1))
  ch <- read_parquet(file.path(syn$dir, "CLN_heads.parquet"))
  cln <- rb_read_sf(file.path(syn$dir, "CLN_nodes.parquet"))
  s <- rb_cln_series(ch, rb_cln_bed(cln, times), times, 3)
  built <- plotly::plotly_build(rb_cln_plot(s, p3, "node 3"))
  nm <- vapply(built$x$data, function(t) t$name %||% "", character(1))
  expect_true(all(c("CLN head", "Bed", "Well A requested", "Well A delivered") %in% nm))
})

test_that("parameter fields: index, per-layer slice, log defaults", {
  need_syn()
  fi <- rb_field_index(syn$dir)
  expect_setequal(unique(fi$field), c("kx", "kz", "sy"))
  expect_setequal(unique(fi$run), c("prior", "run", "ratio"))
  l2 <- rb_field_slice(syn$dir, "kx", "ratio", 2)
  expect_equal(nrow(l2), 9L)                              # layer 2's own cells
  expect_equal(sort(l2$nodenumberL1), 1:9)
  prior <- rb_field_slice(syn$dir, "kx", "prior", 1)
  run <- rb_field_slice(syn$dir, "kx", "run", 1)
  ratio <- rb_field_slice(syn$dir, "kx", "ratio", 1)
  j <- merge(merge(prior, run, by = c("layer", "nodenumberL1")), ratio, by = c("layer", "nodenumberL1"))
  expect_equal(j$value, j$value.y / j$value.x)
  expect_true(rb_field_default_log("kx"))
  expect_true(rb_field_default_log("K33"))
  expect_false(rb_field_default_log("sy"))
  expect_true(rb_field_default_log("sy", "ratio"))
  expect_null(rb_field_index(NULL))
})

test_that("log breaks step 1-2-5 inside the domain", {
  expect_equal(rb_log_breaks(c(1, 80)), c(1, 2, 5, 10, 20, 50))
  expect_equal(rb_log_breaks(c(1e-6, 1e3)), 10^(-6:3))  # too many 1-2-5 steps -> decades
  expect_length(rb_log_breaks(c(3, 4)), 8L)              # narrow: geometric steps
  expect_length(rb_log_breaks(c(11, 67)), 8L)
})

real <- Sys.getenv("CF_TEST_BUNDLE")
test_that("a real bundle given at run time reads (CF_TEST_BUNDLE)", {
  if (!nzchar(real)) skip("CF_TEST_BUNDLE not set")
  expect_true(rb_is_bundle(real))
  m <- rb_manifest(real)
  g <- rb_read_sf(file.path(real, "Grid.parquet"), rb_epsg(m$crs))
  expect_false(is.na(st_crs(g)))
  expect_true(all(c("layer", "nodenumber", "nodenumberL1") %in% names(g)))
  n <- as.vector(table(g$layer))
  if (!is.null(m$nodes_per_layer)) expect_equal(n, as.integer(m$nodes_per_layer))
  heads <- open_dataset(file.path(real, "Heads.parquet"))
  expect_true(all(c("SP", "layer", "nodenumberL1", "h") %in% names(heads)))
})
