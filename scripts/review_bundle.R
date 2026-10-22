# Review bundles: one folder of plain tables describing one model run.
#
# A bundle is written by a model project's own exporter (never by this app)
# and opened here read-only, for LOCAL review: the folder picker only appears
# when the CF_BUNDLE_ROOT environment variable names a folder on this machine,
# and only folders inside it can be opened. The hosted app never sets it.
#
# Layout (all tables long format, one value per row; only the first three are
# required):
#   manifest.json           title, model_type, crs, start_date, time_units, ...
#   Grid.parquet            GeoParquet cell polygons: nodenumber, layer,
#                           nodenumberL1 (+ top, bot, area, zone)
#   Times.csv               SP, time (+ date_start, date_end, segment, kper)
#   Heads.parquet           SP, layer, nodenumberL1, h   (dry / inactive = NA)
#   Heads_baseline.parquet  optional, same columns -> drawdown / difference maps
#   (more tables are read by the observed-vs-simulated, CLN and field views)
#
# Conventions: node numbers are 1-based as MODFLOW writes them; nodenumberL1 is
# the position of a node WITHIN its layer, so layers may have different cells
# and (layer, nodenumberL1) is the key that joins Grid, Heads and Fields. SP is
# one global period number even when the run was made in several segments.
#
# Test data: scripts/make_test_bundle.py writes a small synthetic bundle.

rb_required <- c("manifest.json", "Grid.parquet", "Heads.parquet", "Times.csv")

# TRUE if `dir` holds a bundle (manifest + the three required tables).
rb_is_bundle <- function(dir) {
  isTRUE(dir.exists(dir)) && all(file.exists(file.path(dir, rb_required)))
}

# The configured bundle root, or "" when bundle opening is disabled.
rb_root <- function() {
  root <- Sys.getenv("CF_BUNDLE_ROOT")
  if (!nzchar(root) || !dir.exists(root)) return("")
  normalizePath(root, mustWork = TRUE)
}

# Bundles under `root` (the root itself counts), searched `max_depth` levels
# down. Returns paths relative to root ("." for the root), newest first.
rb_list <- function(root, max_depth = 3) {
  if (!nzchar(root)) return(character(0))
  found <- character(0)
  level <- root
  for (d in 0:max_depth) {
    found <- c(found, level[vapply(level, rb_is_bundle, logical(1))])
    level <- unlist(lapply(level, list.dirs, recursive = FALSE, full.names = TRUE))
    if (length(level) == 0) break
  }
  if (length(found) == 0) return(character(0))
  found <- found[order(file.mtime(file.path(found, "manifest.json")), decreasing = TRUE)]
  rel <- substring(found, nchar(root) + 2)
  rel[!nzchar(rel)] <- "."
  rel
}

# Resolve a relative bundle path chosen in the UI to an absolute folder,
# refusing anything outside `root` (a crafted input value such as "../.." must
# not open arbitrary folders) or anything that is not a bundle.
rb_resolve <- function(root, rel) {
  if (!nzchar(root) || is.null(rel) || !nzchar(rel)) stop("No bundle root configured.")
  dir <- normalizePath(file.path(root, rel), mustWork = FALSE)
  inside <- identical(dir, root) || startsWith(dir, paste0(root, .Platform$file.sep))
  if (!inside) stop("That folder is outside the bundle root.")
  if (!rb_is_bundle(dir)) stop("Not a review bundle (needs ", paste(rb_required, collapse = ", "), ").")
  dir
}

# manifest.json as a list. Missing fields come back NULL.
rb_manifest <- function(dir) {
  jsonlite::fromJSON(file.path(dir, "manifest.json"), simplifyVector = TRUE)
}

# EPSG code (character, e.g. "32633") from a "EPSG:32633"-style string, or
# "NONE" when there is none.
rb_epsg <- function(crs) {
  code <- sub("^EPSG:", "", toupper(crs %||% ""))
  if (grepl("^[0-9]+$", code)) code else "NONE"
}

# The CRS recorded in a GeoParquet file's "geo" metadata, as an sf crs (or NA).
# sfarrow reads WKT CRSs but returns NA for the PROJJSON that GeoParquet 1.0
# writers (geopandas, GDAL) store, so read the authority code directly.
rb_geoparquet_crs <- function(path) {
  tbl <- arrow::read_parquet(path, as_data_frame = FALSE)
  geo <- tbl$metadata$geo
  if (is.null(geo)) return(sf::NA_crs_)
  meta <- tryCatch(jsonlite::fromJSON(geo, simplifyVector = FALSE), error = function(e) NULL)
  col <- meta$columns[[meta$primary_column %||% "geometry"]]
  id <- col$crs$id
  if (is.null(id$authority) || is.null(id$code)) return(sf::NA_crs_)
  sf::st_crs(paste0(id$authority, ":", id$code))
}

# Read a GeoParquet file as sf with its geometry column named "geometry" and a
# CRS set: from the file, else from its PROJJSON id, else `fallback_epsg`.
rb_read_sf <- function(path, fallback_epsg = "NONE") {
  g <- sfarrow::st_read_parquet(path)
  if (!identical(attr(g, "sf_column"), "geometry")) {
    g <- sf::st_sf(sf::st_drop_geometry(g), geometry = sf::st_geometry(g))
  }
  if (is.na(sf::st_crs(g))) {
    crs <- rb_geoparquet_crs(path)
    if (is.na(crs) && fallback_epsg != "NONE") crs <- sf::st_crs(as.integer(fallback_epsg))
    if (!is.na(crs)) sf::st_crs(g) <- crs
  }
  g
}

# Times.csv with a `date` column (POSIXct) when the file carries calendar
# dates: the period's end (`date_end`), else NULL so the app falls back to
# start date + time.
rb_times_dates <- function(times) {
  if ("date_end" %in% names(times)) as.POSIXct(as.character(times$date_end), tz = "UTC") else NULL
}

# Run minus baseline, as a map/hydrograph variable.
#   "Drawdown"   = baseline - run   (positive where the run is lower)
#   "Difference" = run - baseline   (positive where the run is higher)
# NA (dry / inactive) in either run gives NA.
rb_compare <- function(h, h_base, mode = c("Drawdown", "Difference")) {
  mode <- match.arg(mode)
  if (mode == "Drawdown") h_base - h else h - h_base
}

# One-line summary of a bundle for the status panel.
rb_summary <- function(m, dir) {
  segs <- m$segments
  n_seg <- if (is.data.frame(segs)) nrow(segs) else length(segs)
  paste0(
    m$title %||% basename(dir),
    " — ", m$model_type %||% "model", ", ",
    m$n_layers %||% "?", " layers, ",
    m$n_periods %||% "?", " periods",
    if (n_seg > 1) paste0(" in ", n_seg, " segments") else ""
  )
}

# TRUE if the open bundle `dir` has the optional table `file`.
rb_has <- function(dir, file) {
  !is.null(dir) && nzchar(dir) && file.exists(file.path(dir, file))
}

# --- Observed vs simulated ---------------------------------------------------
# Sites.parquet   GeoParquet points: site, group, layer, node, cln_node
# Targets.parquet obsname, site, group, role, date, SP, observed, simulated,
#                 simulated_baseline (optional), weight
# Observations.parquet (optional) site, datetime, value, source (e.g. manual,
#                 logger, survey), role (optional: the target role whose panel
#                 the values belong in). The raw measurements behind the
#                 targets, which are often resampled or differenced.
# Simulated values in a bundle come from the bundle's own heads, so they match
# the maps.

# Targets of one site, sorted by date, with `date` as Date and the residual
# (observed - simulated, m).
rb_site_targets <- function(targets, site) {
  tg <- targets[targets$site == site, , drop = FALSE]
  if (nrow(tg) == 0) return(tg)
  tg$date <- as.Date(substr(as.character(tg$date), 1, 10))
  tg$residual <- tg$observed - tg$simulated
  if (!"simulated_baseline" %in% names(tg)) tg$simulated_baseline <- NA_real_
  if (!"weight" %in% names(tg)) tg$weight <- NA_real_
  if (!"role" %in% names(tg)) tg$role <- "target"
  tg[order(tg$role, tg$date), , drop = FALSE]
}

# Measurements of one site, sorted by time, with `datetime` as POSIXct (UTC,
# i.e. the clock time as written) and `role` filled ("measured" when absent).
rb_site_observations <- function(obs, site) {
  if (is.null(obs)) return(NULL)
  o <- as.data.frame(obs[obs$site == site, , drop = FALSE])
  if (nrow(o) == 0) return(NULL)
  # Arrow reads a time without a time zone as that clock time in UTC; keep it
  # in UTC so it prints as written (not shifted to this computer's zone).
  o$datetime <- as.POSIXct(format(o$datetime, "%Y-%m-%d %H:%M:%S", tz = "UTC"), tz = "UTC")
  if (!"source" %in% names(o)) o$source <- "measured"
  if (!"role" %in% names(o)) o$role <- "measured"
  o$role[is.na(o$role)] <- "measured"
  o[order(o$datetime), , drop = FALSE]
}

# Simulated head at one site in every period: data.frame(SP, h, h_base). A
# site with a CLN node reads CLN_heads (h, h_baseline); otherwise its GW node
# (global `node`, looked up in `grid` = data.frame(nodenumber, layer,
# nodenumberL1)) reads Heads / Heads_baseline. NULL when neither applies.
rb_site_series <- function(dir, site_row, grid) {
  cn <- site_row$cln_node %||% NA
  nd <- site_row$node %||% NA
  if (!is.na(cn) && rb_has(dir, "CLN_heads.parquet")) {
    ch <- arrow::open_dataset(file.path(dir, "CLN_heads.parquet")) %>%
      dplyr::filter(cln_node == !!as.integer(cn)) %>% dplyr::collect()
    if (nrow(ch) == 0) return(NULL)
    return(data.frame(SP = ch$SP, h = ch$h,
                      h_base = if ("h_baseline" %in% names(ch)) ch$h_baseline else NA_real_))
  }
  if (is.na(nd)) return(NULL)
  g <- grid[grid$nodenumber == nd, , drop = FALSE]
  if (nrow(g) == 0) return(NULL)
  pick <- function(file) {
    if (!rb_has(dir, file)) return(NULL)
    arrow::open_dataset(file.path(dir, file)) %>%
      dplyr::filter(layer == !!as.integer(g$layer[1]),
                    nodenumberL1 == !!as.integer(g$nodenumberL1[1])) %>%
      dplyr::select(SP, h) %>% dplyr::collect()
  }
  h <- pick("Heads.parquet")
  if (is.null(h) || nrow(h) == 0) return(NULL)
  b <- pick("Heads_baseline.parquet")
  out <- data.frame(SP = h$SP, h = h$h)
  out$h_base <- if (is.null(b)) NA_real_ else b$h[match(out$SP, b$SP)]
  out
}

# Observed (points) vs simulated (line) vs baseline (dashed) for one site's
# targets (output of rb_site_targets). Observations with weight 0 are drawn
# hollow: they are shown but did not count in the calibration. A site with
# several roles (e.g. heads and drawdowns) gets one panel per role.
#
# With `obs` (rb_site_observations) the measurements are drawn faintly in the
# panel of their role (a "measured" panel of their own when no target has that
# role), and that panel's simulated / baseline lines come from `sim`
# (data.frame(x, h, h_base): every period) instead of the target dates only.
rb_targets_plot <- function(tg, title = "", obs = NULL, sim = NULL) {
  roles <- unique(tg$role)
  obs_roles <- if (is.null(obs)) character(0) else unique(obs$role)
  roles <- c(roles, setdiff(obs_roles, roles))
  src_cols <- c("#8ac6ff", "#c792ea", "#ff9f43", "#7ee787", "#f78fb3")
  one_role <- function(r, show_legend) {
    d <- tg[tg$role == r, , drop = FALSE]
    o <- if (r %in% obs_roles) obs[obs$role == r, , drop = FALSE] else NULL
    if (!is.null(o)) {
      return(rb_measured_panel(d, o, sim, src_cols, show_legend,
                               y_title = if (length(roles) > 1) paste(r, "(m)") else "Head (m)"))
    }
    hover <- sprintf("%s<br>%s<br>observed %.3f<br>simulated %.3f<br>residual %.3f<br>weight %s",
                     d$obsname, format(d$date), d$observed, d$simulated, d$residual,
                     format(d$weight))
    p <- plotly::plot_ly(d, x = ~date)
    if (any(!is.na(d$simulated_baseline))) {
      p <- plotly::add_lines(p, y = ~simulated_baseline, name = "Baseline",
                             legendgroup = "base", showlegend = show_legend,
                             line = list(color = CF_PLOT_MUTED, dash = "dash", width = 1.5))
    }
    p <- plotly::add_lines(p, y = ~simulated, name = "Simulated",
                           legendgroup = "sim", showlegend = show_legend,
                           line = list(color = "#00bc8c", width = 2))
    w0 <- !is.na(d$weight) & d$weight == 0
    p <- plotly::add_markers(p, data = d[!w0, , drop = FALSE], y = ~observed,
                             name = "Observed", legendgroup = "obs", showlegend = show_legend,
                             text = hover[!w0], hoverinfo = "text",
                             marker = list(color = "#ffd166", size = 7))
    if (any(w0)) {
      p <- plotly::add_markers(p, data = d[w0, , drop = FALSE], y = ~observed,
                               name = "Observed (weight 0)", legendgroup = "obs0",
                               showlegend = show_legend, text = hover[w0], hoverinfo = "text",
                               marker = list(color = "rgba(0,0,0,0)", size = 7,
                                             line = list(color = "#ffd166", width = 1.5)))
    }
    cf_plotly_style(p, y_title = if (length(roles) > 1) paste(r, "(m)") else "Head (m)")
  }
  plots <- lapply(seq_along(roles), function(i) one_role(roles[i], i == 1))
  p <- if (length(plots) == 1) plots[[1]] else
    plotly::subplot(plots, nrows = length(plots), shareX = TRUE, titleY = TRUE)
  plotly::layout(p, title = list(text = title, font = list(size = 13), x = 0.02),
                 margin = list(t = 35))
}

# One colour per group (site groups on the map): the series colours, or a ramp
# through them when there are more groups than colours.
rb_group_colours <- function(groups) {
  n <- length(groups)
  if (n <= length(CF_SERIES_COLOURS)) return(CF_SERIES_COLOURS[seq_len(n)])
  grDevices::colorRampPalette(CF_SERIES_COLOURS)(n)
}

# One panel of rb_targets_plot with measurements: measured values by source
# (small, faint), simulated and baseline in every period when `sim` is given
# (else at the target dates), and the targets' observed values on top.
# Its legend entries always show (their names differ from the other panels').
rb_measured_panel <- function(d, o, sim, src_cols, show_legend, y_title) {
  p <- plotly::plot_ly()
  srcs <- unique(o$source)
  for (i in seq_along(srcs)) {
    os <- o[o$source == srcs[i], , drop = FALSE]
    col <- src_cols[(i - 1) %% length(src_cols) + 1]
    hover <- sprintf("%s<br>%s %.3f", srcs[i], format(os$datetime, "%Y-%m-%d %H:%M", tz = "UTC"), os$value)
    # A dense record (a logger) reads better as a line; sparse ones as points.
    gaps <- as.numeric(diff(os$datetime), units = "days")
    dense <- nrow(os) > 50 && stats::median(gaps) <= 2
    p <- plotly::add_trace(p, data = os, x = ~datetime, y = ~value, type = "scatter",
                           mode = if (dense) "lines" else "markers",
                           name = paste("Measured:", srcs[i]), legendgroup = paste0("m_", srcs[i]),
                           text = hover, hoverinfo = "text",
                           line = list(color = col, width = 1.2),
                           marker = list(color = col, size = 6, symbol = "diamond"))
  }
  if (!is.null(sim) && nrow(sim) > 0) {
    if (any(!is.na(sim$h_base))) {
      p <- plotly::add_lines(p, data = sim, x = ~x, y = ~h_base, name = "Baseline (every period)",
                             legendgroup = "base_all",
                             line = list(color = CF_PLOT_MUTED, dash = "dash", width = 1.5))
    }
    p <- plotly::add_lines(p, data = sim, x = ~x, y = ~h, name = "Simulated (every period)",
                           legendgroup = "sim_all",
                           line = list(color = "#00bc8c", width = 2))
  } else if (nrow(d) > 0) {
    p <- plotly::add_lines(p, data = d, x = ~date, y = ~simulated, name = "Simulated",
                           legendgroup = "sim", showlegend = show_legend,
                           line = list(color = "#00bc8c", width = 2))
  }
  if (nrow(d) > 0) {
    w0 <- !is.na(d$weight) & d$weight == 0
    hover <- sprintf("%s<br>%s<br>observed %.3f<br>simulated %.3f<br>residual %.3f<br>weight %s",
                     d$obsname, format(d$date), d$observed, d$simulated, d$residual, format(d$weight))
    p <- plotly::add_markers(p, data = d, x = ~date, y = ~observed, name = "Target (observed)",
                             legendgroup = "target", text = hover, hoverinfo = "text",
                             marker = list(color = ifelse(w0, "rgba(0,0,0,0)", "#ffd166"), size = 5,
                                           line = list(color = "#ffd166", width = 1)))
  }
  cf_plotly_style(p, y_title = y_title)
}

# Weight summary for a chart title, e.g. "weight 1" or "weights 0-2".
rb_weight_label <- function(w) {
  w <- w[!is.na(w)]
  if (length(w) == 0) return("")
  r <- range(w)
  r <- signif(r, 3)
  if (r[1] == r[2]) paste("weight", format(r[1])) else paste0("weights ", format(r[1]), "–", format(r[2]))
}

# --- CLN nodes (connected linear network: trenches, drains, bores) ----------
# CLN_nodes.parquet  GeoParquet lines and/or points: cln_node, kind, name,
#                    layer, gw_node, top, and the bed level either as one `bed`
#                    column or per segment as bed_p1, bed_p2, ... (bed_p<k> is
#                    used for the periods of segment k in Times.csv)
# CLN_heads.parquet  SP, cln_node, h, active (switched on that period)
# Pumping.parquet    SP, well, kind, cln_node, requested, delivered (m3/d, out
#                    of the aquifer positive). A well that moves between CLN
#                    nodes keeps one `well` name.

# x axis for period series: the period's end date when Times.csv has one,
# otherwise model time. Returns data.frame(SP, x) and the axis title.
rb_period_axis <- function(times) {
  d <- rb_times_dates(times)
  if (!is.null(d)) list(df = data.frame(SP = times$SP, x = as.Date(d)), title = "")
  else list(df = data.frame(SP = times$SP, x = times$time), title = "Time (days)")
}

# Bed level of every CLN node in every period, long: SP, cln_node, bed (m).
# One `bed` column applies to all periods; bed_p<k> columns apply to the
# periods of segment k (segment 1 when Times.csv has no `segment`). Nodes
# without a bed get NA.
rb_cln_bed <- function(cln, times) {
  nodes <- as.data.frame(cln)[, "cln_node", drop = TRUE]
  seg <- if ("segment" %in% names(times)) times$segment else rep(1L, nrow(times))
  out <- expand.grid(cln_node = nodes, i = seq_len(nrow(times)))   # i = row of times
  out$SP <- times$SP[out$i]
  out$segment <- seg[out$i]
  attrs <- sf::st_drop_geometry(cln)
  pos <- match(out$cln_node, attrs$cln_node)
  out$bed <- NA_real_
  if ("bed" %in% names(attrs)) {
    out$bed <- attrs$bed[pos]
  } else {
    for (k in unique(out$segment)) {
      col <- paste0("bed_p", k)
      if (col %in% names(attrs)) out$bed[out$segment == k] <- attrs[[col]][pos[out$segment == k]]
    }
  }
  out[order(out$cln_node, out$SP), c("SP", "cln_node", "bed")]
}

# Map values for one period: data.frame(cln_node, h, bed, active, value).
# value = h ("Head") or h - bed ("Head - bed", m above the bed; negative means
# the head is below the bed). Nodes switched off that period get NA.
rb_cln_period_values <- function(cln_heads, beds, sp, mode = c("Head", "Head - bed")) {
  mode <- match.arg(mode)
  h <- cln_heads[cln_heads$SP == sp, , drop = FALSE]
  if (!"active" %in% names(h)) h$active <- TRUE
  b <- beds[beds$SP == sp, c("cln_node", "bed")]
  v <- merge(h[, c("cln_node", "h", "active")], b, by = "cln_node", all.x = TRUE)
  v$active <- !is.na(v$active) & as.logical(v$active)
  v$value <- if (mode == "Head") v$h else v$h - v$bed
  v$value[!v$active] <- NA_real_
  v
}

# One CLN node through time: SP, x, h (NA when off), bed, active.
rb_cln_series <- function(cln_heads, beds, times, node) {
  ax <- rb_period_axis(times)$df
  h <- cln_heads[cln_heads$cln_node == node, , drop = FALSE]
  if (!"active" %in% names(h)) h$active <- TRUE
  s <- merge(ax, h[, c("SP", "h", "active")], by = "SP", all.x = TRUE)
  s <- merge(s, beds[beds$cln_node == node, c("SP", "bed")], by = "SP", all.x = TRUE)
  s$active <- !is.na(s$active) & as.logical(s$active)
  s$h[!s$active] <- NA_real_
  s[order(s$SP), ]
}

# Pumping at one CLN node: SP, x, well, requested, delivered (m3/d). Rows of a
# moving well appear only for the periods it pumped from this node.
rb_cln_pumping <- function(pumping, times, node) {
  if (is.null(pumping)) return(NULL)
  p <- pumping[!is.na(pumping$cln_node) & pumping$cln_node == node, , drop = FALSE]
  if (nrow(p) == 0) return(NULL)
  p <- merge(rb_period_axis(times)$df, p, by = "SP")
  p[order(p$well, p$SP), ]
}

# Head and bed (top panel) and requested / delivered pumping (bottom panel,
# when the node pumps) for one CLN node.
rb_cln_plot <- function(series, pump = NULL, title = "", x_title = "") {
  top <- plotly::plot_ly(series, x = ~x) %>%
    plotly::add_lines(y = ~bed, name = "Bed", line = list(color = CF_PLOT_MUTED, dash = "dot", width = 1.5,
                                                          shape = "hv")) %>%
    plotly::add_lines(y = ~h, name = "CLN head", line = list(color = "#00bc8c", width = 2),
                      connectgaps = FALSE)
  top <- cf_plotly_style(top, x_title = x_title, y_title = "Level (m)")
  if (is.null(pump) || nrow(pump) == 0) {
    return(plotly::layout(top, title = list(text = title, font = list(size = 13), x = 0.02),
                          margin = list(t = 35)))
  }
  bottom <- plotly::plot_ly()
  wells <- unique(pump$well)
  for (i in seq_along(wells)) {
    d <- pump[pump$well == wells[i], , drop = FALSE]
    col <- CF_SERIES_COLOURS[(i %% length(CF_SERIES_COLOURS)) + 1]
    bottom <- bottom %>%
      plotly::add_lines(data = d, x = ~x, y = ~requested, name = paste(wells[i], "requested"),
                        line = list(color = col, dash = "dash", width = 1.5, shape = "hv")) %>%
      plotly::add_lines(data = d, x = ~x, y = ~delivered, name = paste(wells[i], "delivered"),
                        line = list(color = col, width = 2, shape = "hv"))
  }
  bottom <- cf_plotly_style(bottom, x_title = x_title, y_title = "Pumping (m³/d)")
  plotly::subplot(top, bottom, nrows = 2, shareX = TRUE, titleY = TRUE, heights = c(0.6, 0.4)) %>%
    plotly::layout(title = list(text = title, font = list(size = 13), x = 0.02), margin = list(t = 35))
}

# --- Parameter fields ---------------------------------------------------------
# Fields.parquet  field (any name: kx, kz, sy, ...), layer, nodenumberL1,
#                 value, run ("prior", "run", "ratio" = run / prior, or any
#                 other label). Joined to the grid on (layer, nodenumberL1).

# Distinct (field, run) pairs in a bundle's Fields.parquet, or NULL.
rb_field_index <- function(dir) {
  if (!rb_has(dir, "Fields.parquet")) return(NULL)
  arrow::open_dataset(file.path(dir, "Fields.parquet")) %>%
    dplyr::distinct(field, run) %>% dplyr::collect() %>%
    dplyr::arrange(field, run)
}

# One field, run and layer: data.frame(layer, nodenumberL1, value).
rb_field_slice <- function(dir, field_name, run_name, layer_no) {
  arrow::open_dataset(file.path(dir, "Fields.parquet")) %>%
    dplyr::filter(field == field_name, run == run_name, layer == layer_no) %>%
    dplyr::select(layer, nodenumberL1, value) %>%
    dplyr::collect()
}

# Hydraulic conductivities span orders of magnitude: default to a log colour
# scale for fields named k* (kx, ky, kz, k33, ...) and for run / prior ratios.
rb_field_default_log <- function(field_name, run_name = "") {
  grepl("^k", field_name, ignore.case = TRUE) || identical(run_name, "ratio")
}

# Colour-bin breaks for a log scale: 1-2-5 steps per decade inside `domain`
# (both ends > 0); decades when that gives too many, geometric steps when
# it gives too few.
rb_log_breaks <- function(domain, max_n = 12) {
  lo <- floor(log10(domain[1])); hi <- ceiling(log10(domain[2]))
  b <- as.vector(outer(c(1, 2, 5), 10^(lo:hi)))
  b <- sort(b[b >= domain[1] & b <= domain[2]])
  if (length(b) > max_n) b <- 10^(lo:hi)[10^(lo:hi) >= domain[1] & 10^(lo:hi) <= domain[2]]
  # Less than a decade or so: too few round steps to see anything, so use
  # 8 geometric steps instead (rounded to 2 significant figures).
  if (length(b) < 5) b <- unique(signif(exp(seq(log(domain[1]), log(domain[2]), length.out = 8)), 2))
  b
}
