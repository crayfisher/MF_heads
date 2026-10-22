# =============================================================================
# Crayfisher shared: model grid abstraction
# =============================================================================
# PUBLIC MODULE — ships to the public mirrors via tools/assemble.sh
# (SHARED_LIB). No model-specific, proprietary or LLM content.
#
# WHY THIS EXISTS
# ---------------
# Crayfisher apps need two things from a grid: turn a map click into a cell,
# and turn per-cell values into something drawable. Doing that with arithmetic
# (floor((x - xll) / cell_size)) only ever works for a structured DIS grid —
# a DISV quadtree or a DISU mesh has no rows and columns to divide by.
#
# flopy's modelgrid already solves this for all three grid types, so this
# module wraps it rather than reimplementing it. `intersect()` returns
# (row, col) for structured, a cell2d for vertex, and a node for unstructured,
# from the same call.
#
# TIERING
# -------
# Addressing (click -> cell) needs no tiers — modelgrid handles every type.
# RENDERING does, and the tier is chosen by cell COUNT and whether per-cell
# interaction is needed, NOT by grid type:
#
#   polygons  O(N) to the GPU, exact, supports per-cell hover.  Any grid type.
#   contours  cheap at any N.  Structured natively; unstructured needs
#             interpolation from cell centroids.
#   raster    cheap at any N, any grid type.  No per-cell hover.
#
# The point of separating addressing from rendering: a layer no longer has to
# carry cell identity just so clicks work. That is what lets a 150k-cell model
# render as contours or a raster and still be clickable — picking goes through
# cf_grid_locate(), not through the drawn geometry.
#
# STATUS: the structured implementations are live and tested. Vertex and
# unstructured raise explicit errors rather than guessing — apps/mf_heads'
# scripts/make_test_models.py generates real DISV and DISU models, so those
# paths should be written against those, not written blind.
#
# KNOWN CONSTRAINT: for DISU, flopy cannot rebuild cell geometry from the
# binary grid alone (see that same script) — it needs the gridgen polygon
# shapefile. Any geometry function must therefore accept externally supplied
# polygons, not assume flopy can always produce them.
# =============================================================================

#' Open a model's grid, applying a georeference if the model lacks one.
#'
#' MODFLOW files often carry no real-world origin (xoff/yoff = 0). Passing
#' xoff/yoff here sets it on the modelgrid itself, so every downstream call —
#' including flopy's own intersect() — works in real coordinates. That is
#' strictly better than keeping the offset beside the model and doing the
#' maths separately, which cannot generalise beyond a structured grid.
cf_grid_open <- function(model_ws, xoff = NULL, yoff = NULL, crs = NULL,
                         agent_dir = NULL) {
  flopy <- reticulate::import("flopy")
  sim <- flopy$mf6$MFSimulation$load(sim_ws = model_ws, verbosity_level = 0L)
  gwf <- sim$get_model()
  mg <- gwf$modelgrid
  if (!is.null(xoff) && !is.null(yoff)) {
    mg$set_coord_info(xoff = xoff, yoff = yoff)
  }
  structure(list(mg = mg, gwf = gwf, crs = crs,
                 type = as.character(mg$grid_type)), class = "cf_grid")
}

cf_grid_type <- function(g) g$type

#' Real-world (x, y) in the grid's CRS -> cell identifier.
#'
#' Returns a list: `type`, `cellid` (0-based, as flopy reports it), and for a
#' structured grid the convenience fields `row`/`col` (1-based). NULL when the
#' point falls outside the grid — a normal outcome for a map click, so it is a
#' value rather than an error.
cf_grid_locate <- function(g, x, y) {
  res <- tryCatch(g$mg$intersect(as.numeric(x), as.numeric(y)),
                  error = function(e) NULL)
  if (is.null(res)) return(NULL)
  cellid <- as.integer(unlist(res))
  out <- list(type = g$type, cellid = cellid)
  if (identical(g$type, "structured") && length(cellid) >= 2) {
    out$row <- cellid[1] + 1L
    out$col <- cellid[2] + 1L
  }
  out
}

#' Cell identifier -> real-world centre coordinates.
cf_grid_cell_centre <- function(g, row = NULL, col = NULL, cellid = NULL) {
  if (identical(g$type, "structured")) {
    if (is.null(row) || is.null(col)) stop("structured grid needs row and col")
    xc <- g$mg$xcellcenters ; yc <- g$mg$ycellcenters
    return(list(x = xc[row, col], y = yc[row, col]))
  }
  .cf_grid_unsupported(g, "cf_grid_cell_centre")
}

#' Per-cell values -> contour lines as sf, in the grid's CRS.
#'
#' Structured only for now: contouring needs a regular matrix. For a vertex or
#' unstructured grid the values sit at irregular centroids and must be
#' interpolated onto a raster first — deliberately not guessed at here.
cf_grid_contours <- function(g, values, levels, cell_size = NULL) {
  if (!identical(g$type, "structured")) .cf_grid_unsupported(g, "cf_grid_contours")

  m <- as.matrix(values)
  ext <- as.numeric(unlist(g$mg$extent))   # xmin, xmax, ymin, ymax
  r <- terra::rast(nrows = nrow(m), ncols = ncol(m),
                   xmin = ext[1], xmax = ext[2], ymin = ext[3], ymax = ext[4],
                   crs = if (!is.null(g$crs)) paste0("EPSG:", g$crs) else "")
  terra::values(r) <- as.vector(t(m))

  finite <- m[is.finite(m)]
  if (length(finite) == 0) return(NULL)
  use <- levels[levels > min(finite) & levels < max(finite)]
  if (length(use) == 0) return(NULL)

  out <- sf::st_as_sf(terra::as.contour(r, levels = use))
  names(out)[names(out) != attr(out, "sf_column")][1] <- "level"
  out$level <- as.numeric(as.character(out$level))
  out
}

#' Cell polygons as sf — the rendering tier that works for ANY grid type.
#'
#' `cells` is a data.frame of row/col (structured). `geometry_file` is the
#' escape hatch for DISU, where flopy cannot rebuild geometry from the binary
#' grid and gridgen's polygon shapefile must be supplied instead.
cf_grid_polygons <- function(g, cells = NULL, geometry_file = NULL) {
  if (!is.null(geometry_file)) return(sf::st_read(geometry_file, quiet = TRUE))
  if (!identical(g$type, "structured")) .cf_grid_unsupported(g, "cf_grid_polygons")
  if (is.null(cells)) stop("cf_grid_polygons: give `cells` or a `geometry_file`")

  polys <- lapply(seq_len(nrow(cells)), function(i) {
    v <- g$mg$get_cell_vertices(as.integer(cells$row[i]) - 1L,
                                as.integer(cells$col[i]) - 1L)
    m <- do.call(rbind, lapply(v, as.numeric))
    sf::st_polygon(list(rbind(m, m[1, , drop = FALSE])))
  })
  sf::st_sf(cells, geometry = sf::st_sfc(polys,
            crs = if (!is.null(g$crs)) g$crs else NA))
}

#' Per-cell values -> a colour-flood image layer: list(image, bounds, width,
#' height), where `image` is a PNG data URI and `bounds` its lon/lat box
#' (xmin, ymin, xmax, ymax) — what a deck.gl BitmapLayer takes.
#'
#' `colour` maps a numeric vector to hex colours (NA = transparent); pass
#' cf_colour_scale(...)$colour from lib/cf_colour.R. Keeping value->colour
#' outside this function is what lets every grid type share it.
#'
#' Why re-project: a BitmapLayer is placed by an axis-aligned lon/lat box and
#' drawn linearly in Web Mercator, while the model grid is square in its own
#' CRS (NZTM here). Stretching the grid image into that box is off by up to a
#' kilometre at the edges of a 50 km model. So the VALUES are re-projected to
#' EPSG:3857 with nearest-neighbour — exact model numbers, no smoothing — and
#' coloured afterwards.
#'
#' Two methods — the hybrid planned for unstructured grids:
#'
#'   "raster"   (default) ONE image, instant at any cell count, no per-cell
#'              hover. Structured grids go straight to a raster; vertex and
#'              unstructured grids will first rasterise their cell polygons
#'              (cf_grid_polygons(), with gridgen's shapefile for DISU) at
#'              about the finest cell size — the fast overview.
#'   "polygons" the real cells as sf with a `fill` colour column, for a
#'              polygon layer with per-cell hover and exact edges — the
#'              detail view (zoomed-in areas, smaller models). Works for any
#'              grid that can supply polygons: pass them as `polygons`
#'              (with a `value` column, aligned to `values`) or let a
#'              structured grid build them from `cells`.
#'
#' The unstructured raster step is written against real DISV/DISU models
#' (apps/mf_heads/scripts/make_test_models.py), not guessed, so it errors
#' explicitly until then.
cf_grid_flood <- function(g, values, colour, max_px = 1200,
                          method = c("raster", "polygons"),
                          polygons = NULL, cells = NULL) {
  method <- match.arg(method)
  if (method == "polygons") {
    if (is.null(polygons)) polygons <- cf_grid_polygons(g, cells = cells)
    polygons$value <- as.numeric(values)
    polygons$fill <- colour(polygons$value)
    return(sf::st_transform(polygons[!is.na(polygons$fill), ], 4326))
  }
  if (!identical(g$type, "structured")) .cf_grid_unsupported(g, "cf_grid_flood (raster)")
  ang <- tryCatch(as.numeric(g$mg$angrot), error = function(e) 0)
  if (is.finite(ang) && abs(ang) > 1e-9) .cf_grid_unsupported(g, "cf_grid_flood (rotated grid)")
  if (is.null(g$crs)) stop("cf_grid_flood: the grid needs a CRS to be placed on a map")

  m <- as.matrix(values)
  ext <- as.numeric(unlist(g$mg$extent))   # xmin, xmax, ymin, ymax
  r <- terra::rast(nrows = nrow(m), ncols = ncol(m),
                   xmin = ext[1], xmax = ext[2], ymin = ext[3], ymax = ext[4],
                   crs = paste0("EPSG:", g$crs))
  v <- as.vector(t(m))
  v[!is.finite(v) | abs(v) >= 1e20] <- NA   # dry/inactive sentinels
  terra::values(r) <- v

  # Target pixel size ~ one model cell, capped so a huge model stays light.
  cell <- min(terra::res(r))
  span <- max(ext[2] - ext[1], ext[4] - ext[3])
  res_m <- max(cell, span / max_px)
  p <- terra::project(r, "EPSG:3857", method = "near", res = res_m)

  vals <- terra::values(p, mat = FALSE)
  hex <- colour(vals)
  rgba <- array(0, dim = c(terra::nrow(p), terra::ncol(p), 4))
  ok <- !is.na(hex)
  if (any(ok)) {
    rgb <- grDevices::col2rgb(hex[ok]) / 255
    # terra values are row-major (top row first); fill the image the same way.
    idx <- which(ok)
    rr <- (idx - 1) %/% terra::ncol(p) + 1
    cc <- (idx - 1) %% terra::ncol(p) + 1
    for (k in 1:3) rgba[cbind(rr, cc, k)] <- rgb[k, ]
    rgba[cbind(rr, cc, 4)] <- 1
  }
  png_raw <- png::writePNG(rgba)
  e <- terra::ext(p)
  corners <- sf::st_transform(sf::st_sfc(
    sf::st_point(c(e$xmin, e$ymin)), sf::st_point(c(e$xmax, e$ymax)), crs = 3857), 4326)
  cc4 <- sf::st_coordinates(corners)
  list(image = paste0("data:image/png;base64,", base64enc::base64encode(png_raw)),
       bounds = c(cc4[1, "X"], cc4[1, "Y"], cc4[2, "X"], cc4[2, "Y"]),
       width = terra::ncol(p), height = terra::nrow(p))
}

# Fail loudly and usefully rather than returning something plausible-but-wrong.
.cf_grid_unsupported <- function(g, fn) {
  stop(sprintf(
    "%s: not implemented for grid_type '%s'.\nAddressing (cf_grid_locate) already works for every grid type; this is a rendering gap. Build it against a real model — apps/mf_heads/scripts/make_test_models.py generates DISV and DISU test models. For DISU, geometry must come from gridgen's polygon shapefile (pass geometry_file=).",
    fn, g$type), call. = FALSE)
}
