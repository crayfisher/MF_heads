# =============================================================================
# Crayfisher shared: plotly chart styling + time series
# =============================================================================
# PUBLIC MODULE — ships to the public mirrors via tools/assemble.sh
# (SHARED_LIB). No model-specific, proprietary or LLM content.
#
# Plotly rather than ggplot because it is the one plotting library ALL four
# apps already load (mf_heads and mf_lst additionally use ggplot for their
# existing static charts; those are deliberately left alone — rewriting a live
# public app's charts is not a side effect of adding a shared module).
#
# The styling here is the plotly counterpart of the vapor palette in
# cf_theme.R, which was previously copy-pasted inline in each app.
# =============================================================================

CF_PLOT_BG    <- "#241046"
CF_PLOT_FG    <- "#ece7f7"
CF_PLOT_MUTED <- "#a99fce"
CF_PLOT_GRID  <- "rgba(255,255,255,0.06)"

# Series palette: readable on the dark panel, and distinguishable to the most
# common forms of colour-vision deficiency (no red/green-only pairings).
CF_SERIES_COLOURS <- c(
  "#32fbe2", "#ffd166", "#ff5d73", "#8ac6ff", "#c792ea",
  "#00e6a8", "#ff9f43", "#f78fb3", "#7ee787", "#f6c744"
)

#' Apply the Crayfisher dark styling to a plotly object.
#'
#' `legend` may be "h" (below the plot, good under a map), "v", or NA to hide.
cf_plotly_style <- function(p, x_title = "", y_title = "", legend = "h") {
  lay <- list(
    xaxis = list(title = x_title, gridcolor = CF_PLOT_GRID,
                 zerolinecolor = "rgba(255,255,255,0.15)"),
    yaxis = list(title = y_title, gridcolor = CF_PLOT_GRID,
                 zerolinecolor = "rgba(255,255,255,0.15)"),
    paper_bgcolor = "rgba(0,0,0,0)",
    plot_bgcolor  = "rgba(0,0,0,0)",
    font = list(color = CF_PLOT_FG, size = 11),
    margin = list(l = 55, r = 10, t = 10, b = 40)
  )
  if (is.na(legend)) {
    lay$showlegend <- FALSE
  } else {
    lay$legend <- list(orientation = legend, y = if (identical(legend, "h")) -0.18 else 1)
  }
  do.call(plotly::layout, c(list(p), lay))
}

#' Styled multi-series time series.
#'
#' @param df    long/tidy data: one row per (series, time) point.
#' @param x,y,series  column names (strings).
#' @param x_labels optional character labels for the x positions (e.g. month
#'   names) — when given, `x` is treated as an index and ticks are relabelled.
#' @param unit_label appended to hover text and used as the y title.
cf_timeseries_plot <- function(df, x = "x", y = "y", series = "series",
                               x_title = "", y_title = "", unit_label = "",
                               x_labels = NULL, legend = "h",
                               reverse_y = FALSE, colour_by = NULL, dash_by = NULL) {
  # reverse_y: larger values plot LOWER — e.g. drawdown, so a deeper cone
  #   reads as a falling water level.
  # colour_by / dash_by: optional columns. Lines sharing a `colour_by` value
  #   share a colour; the first `dash_by` value is solid, others dashed — e.g.
  #   one colour per well, scenario solid, baseline dashed. Default: one
  #   colour per series (unchanged behaviour).
  if (is.null(df) || nrow(df) == 0) return(NULL)

  keys <- unique(df[[series]])
  ckey <- if (!is.null(colour_by)) unique(df[[colour_by]]) else keys
  pal <- stats::setNames(rep(CF_SERIES_COLOURS, length.out = length(ckey)), ckey)
  dkey <- if (!is.null(dash_by)) unique(df[[dash_by]]) else NULL

  p <- plotly::plot_ly()
  for (i in seq_along(keys)) {
    d <- df[df[[series]] == keys[i], , drop = FALSE]
    col <- pal[[as.character(if (!is.null(colour_by)) d[[colour_by]][1] else keys[i])]]
    dash <- if (!is.null(dash_by) && d[[dash_by]][1] != dkey[1]) "dash" else "solid"
    p <- plotly::add_trace(
      p, x = d[[x]], y = d[[y]], name = as.character(keys[i]),
      type = "scatter", mode = "lines+markers",
      line = list(color = col, width = 2, dash = dash),
      marker = list(color = col, size = 5),
      hovertemplate = paste0(keys[i], ": %{y:.3f} ", unit_label, "<extra></extra>")
    )
  }

  p <- cf_plotly_style(p, x_title = x_title,
                       y_title = if (nzchar(y_title)) y_title else unit_label,
                       legend = legend)
  if (!is.null(x_labels)) {
    p <- plotly::layout(p, xaxis = list(
      title = x_title, gridcolor = CF_PLOT_GRID,
      tickmode = "array", tickvals = seq_along(x_labels), ticktext = x_labels))
  }
  if (isTRUE(reverse_y)) p <- plotly::layout(p, yaxis = list(autorange = "reversed"))
  p
}

#' Styled horizontal bar chart — one bar per category, biggest at the top.
#'
#' For "which of these contributes most" questions, where a time series would
#' make the reader compare line heights by eye. Horizontal because the
#' categories are names (zones, rivers, wells) that do not fit under a tick.
#'
#' @param df    one row per category.
#' @param x,y   column names (strings): `x` is the value, `y` the category.
#' @param unit_label appended to hover text and used as the x title.
#' @param highlight optional category name drawn in the accent colour, the rest
#'   muted — e.g. the zone the user has selected.
#' @param max_bars keep only the largest N (the rest are usually noise).
cf_bar_plot <- function(df, x = "x", y = "y", x_title = "", unit_label = "",
                        highlight = NULL, max_bars = 12) {
  if (is.null(df) || nrow(df) == 0) return(NULL)

  df <- df[order(df[[x]], decreasing = TRUE), , drop = FALSE]
  if (nrow(df) > max_bars) df <- df[seq_len(max_bars), , drop = FALSE]
  # plotly draws the first category at the BOTTOM, so reverse for biggest-first.
  df <- df[rev(seq_len(nrow(df))), , drop = FALSE]

  cols <- if (is.null(highlight)) {
    rep(CF_SERIES_COLOURS[1], nrow(df))
  } else {
    ifelse(as.character(df[[y]]) == highlight, CF_SERIES_COLOURS[1], CF_PLOT_MUTED)
  }

  p <- plotly::plot_ly(
    x = df[[x]], y = factor(df[[y]], levels = df[[y]]),
    type = "bar", orientation = "h",
    marker = list(color = cols),
    hovertemplate = paste0("%{y}: %{x:.3f} ", unit_label, "<extra></extra>")
  )
  p <- cf_plotly_style(p, x_title = if (nzchar(x_title)) x_title else unit_label,
                       y_title = "", legend = NA)
  # Category names need the room a time axis does not.
  plotly::layout(p, margin = list(l = 130, r = 10, t = 10, b = 40),
                 yaxis = list(gridcolor = "rgba(0,0,0,0)"))
}
