# =============================================================================
# cf_colour.R — shared value -> colour mapping for Crayfisher maps
# =============================================================================
# One place decides how a field of numbers (heads, drawdown, ...) becomes
# colours, so every app's colour flood, legend and limits behave the same.
# Deliberately GRID-AGNOSTIC: it maps plain numeric vectors and never looks at
# a grid, so structured, DISV and DISU grids all use it unchanged. Turning the
# colours into a map layer is the grid module's job (lib/cf_grid.R,
# cf_grid_flood()).
#
#   dom <- cf_colour_domain(values, limits = c(NA, 5))   # data range, optional limits
#   sc  <- cf_colour_scale(dom, mode = "discrete", reverse = FALSE)
#   hex <- sc$colour(values)                             # NA for no data
#   cf_colour_legend(sc, title = "Drawdown", units = "m")
#
# PUBLIC module (tools/assemble.sh SHARED_LIB).
# =============================================================================

#' Values that are not data: NA/NaN/Inf and MODFLOW's dry/inactive sentinels
#' (1e30, -1e30, 99999, -999.99 ...). Everything magnitude >= 1e20 or exactly a
#' common sentinel is treated as no data.
cf_colour_is_nodata <- function(v) {
  !is.finite(v) | abs(v) >= 1e20 | v %in% c(99999, -99999, 999.99, -999.99, 1e30, -1e30)
}

#' Colour domain c(min, max) from the data, overridden by any non-NA limit.
cf_colour_domain <- function(values, limits = c(NA_real_, NA_real_)) {
  v <- values[!cf_colour_is_nodata(values)]
  dom <- if (length(v)) range(v) else c(0, 1)
  if (length(limits) == 2) {
    if (!is.na(limits[1])) dom[1] <- limits[1]
    if (!is.na(limits[2])) dom[2] <- limits[2]
  }
  if (dom[2] <= dom[1]) dom[2] <- dom[1] + max(abs(dom[1]) * 1e-6, 1e-6)
  dom
}

#' The colour ramp. Turbo, as in mf_heads: low = blue, high = red.
cf_colour_palette <- function(n, reverse = FALSE) {
  pal <- viridisLite::turbo(n)
  if (isTRUE(reverse)) rev(pal) else pal
}

#' A colour scale: list(domain, breaks, mode, reverse, colour = function(v)).
#' mode "discrete": ~n "pretty" bins inside the domain (or the given `breaks`,
#' e.g. drawdown's log-spaced contour levels); "continuous": a smooth ramp
#' (256 steps). Values outside the domain take the end colours, except below
#' `transparent_below`, which are left uncoloured — for drawdown, so the
#' model's large zero-effect area stays clear and only the cone is drawn.
cf_colour_scale <- function(domain, mode = c("discrete", "continuous"),
                            reverse = FALSE, n = 10, breaks = NULL,
                            transparent_below = NULL) {
  mode <- match.arg(mode)
  if (is.null(breaks)) breaks <- pretty(domain, n = n)
  breaks <- breaks[breaks >= domain[1] & breaks <= domain[2]]
  if (length(breaks) < 2) breaks <- domain
  if (mode == "discrete") {
    edges <- sort(unique(c(domain[1], breaks, domain[2])))
    pal <- cf_colour_palette(length(edges) - 1, reverse)
    colour <- function(v) {
      out <- rep(NA_character_, length(v))
      ok <- !cf_colour_is_nodata(v)
      idx <- findInterval(pmin(pmax(v[ok], domain[1]), domain[2]), edges,
                          rightmost.closed = TRUE, all.inside = TRUE)
      out[ok] <- pal[idx]
      out
    }
  } else {
    pal <- cf_colour_palette(256, reverse)
    colour <- function(v) {
      out <- rep(NA_character_, length(v))
      ok <- !cf_colour_is_nodata(v)
      f <- (pmin(pmax(v[ok], domain[1]), domain[2]) - domain[1]) / diff(domain)
      out[ok] <- pal[1 + floor(f * 255)]
      out
    }
    edges <- breaks
  }
  if (!is.null(transparent_below)) {
    base <- colour
    colour <- function(v) { out <- base(v); out[!is.na(v) & v < transparent_below] <- NA; out }
  }
  list(domain = domain, breaks = breaks, edges = edges, mode = mode,
       reverse = reverse, colour = colour)
}

#' A compact HTML legend for a scale: a colour bar with tick labels. Map
#' libraries only draw legends for their own scales; a flood drawn as an image
#' (cf_grid_flood) has none, so this one is shared.
cf_colour_legend <- function(sc, title = "", units = "") {
  fmt <- function(x) formatC(x, digits = 3, format = "g")
  if (sc$mode == "discrete") {
    e <- sc$edges
    mids <- (utils::head(e, -1) + utils::tail(e, -1)) / 2
    cols <- sc$colour(mids)
    bar <- htmltools::div(style = "display:flex; height:10px;",
      lapply(cols, function(cl) htmltools::div(style = sprintf("flex:1; background:%s;", cl))))
    ticks <- e
  } else {
    cols <- sc$colour(seq(sc$domain[1], sc$domain[2], length.out = 12))
    bar <- htmltools::div(style = sprintf("height:10px; background:linear-gradient(to right, %s);",
                                          paste(cols, collapse = ",")))
    ticks <- sc$breaks
  }
  pos <- (ticks - sc$domain[1]) / diff(sc$domain) * 100
  htmltools::div(style = paste("min-width: 200px; font-size: 0.62rem; color: #ece7f7;",
                               "background: rgba(21,7,38,0.82); padding: 5px 8px 14px;",
                               "border-radius: 6px;"),
    htmltools::div(style = "margin-bottom: 3px; font-weight: 600;",
                   paste0(title, if (nzchar(units)) paste0(" (", units, ")"))),
    bar,
    htmltools::div(style = "position: relative; height: 10px;",
      lapply(seq_along(ticks), function(i) htmltools::span(
        style = sprintf("position:absolute; left:%.1f%%; transform:translateX(-50%%); top:1px;", pos[i]),
        fmt(ticks[i]))))
  )
}
