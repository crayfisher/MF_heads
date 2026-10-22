# =============================================================================
# cf_credits.R — shared attributions for every Crayfisher app
# =============================================================================
# The credits and source links themselves live in lib/cf_credits.json (also
# read by the mf_ai_hbrc assistant). This file only renders them, so every app
# credits the same things in the same words.
#
#   source("lib/cf_credits.R")
#   cf_credits_ui(c("hpm", "flopy", "mf6", "osm"))   # About panel block
#   cf_map_attribution(c("osm"))                     # overlay for a map card
#
# Keys: hpm, flopy, mf6, freyberg, pestpp, pyemu, linz_gazetteer, linz_addresses, osm, linz_topo,
# linz_aerial, esri_imagery, esri_streets.
# An app lists only what it actually uses. PUBLIC module (tools/assemble.sh
# SHARED_LIB) — nothing app-private belongs here.
# =============================================================================

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

CF_CREDITS <- local({
  p <- file.path("lib", "cf_credits.json")
  if (file.exists(p)) jsonlite::fromJSON(p, simplifyDataFrame = FALSE) else list()
})

.cf_credit_link <- function(l) {
  tags$a(l$label, href = l$url, target = "_blank", rel = "noopener",
         style = "color: #32fbe2;")
}

#' About-panel block crediting the listed sources, in a fixed order.
cf_credits_ui <- function(keys, show_use = TRUE) {
  items <- lapply(keys, function(k) {
    cr <- CF_CREDITS[[k]]
    if (is.null(cr)) return(NULL)
    links <- if (length(cr$links))
      tagList(" ", lapply(seq_along(cr$links), function(i)
        tagList(if (i > 1) " · ", .cf_credit_link(cr$links[[i]]))))
    div(style = "margin-bottom: 5px;",
      tags$strong(cr$title, style = "color: #ece7f7;"), " — ", cr$text,
      if (show_use && !is.null(cr$use)) tagList(" ", tags$em(cr$use)),
      links)
  })
  div(style = paste("font-size: 0.72rem; color: #a99fce; line-height: 1.4;",
                    "border-top: 1px solid rgba(169,159,206,0.25);",
                    "padding-top: 6px; margin-top: 8px;"),
      tags$div(style = "font-size: 0.62rem; letter-spacing: 1px; text-transform: uppercase; margin-bottom: 4px;",
               "Credits & sources"),
      items)
}

#' Small attribution overlay for the corner of a map (OSM requires it to be
#' visible on the map itself). Place inside a position:relative container.
cf_map_attribution <- function(keys) {
  txt <- unlist(lapply(keys, function(k) CF_CREDITS[[k]]$map))
  if (!length(txt)) return(NULL)
  url <- CF_CREDITS[[keys[[1]]]]$links[[1]]$url
  div(style = paste("position: absolute; right: 6px; bottom: 4px; z-index: 5;",
                    "font-size: 0.62rem; background: rgba(21,7,38,0.72);",
                    "padding: 1px 6px; border-radius: 4px; pointer-events: auto;"),
      if (!is.null(url)) tags$a(paste(txt, collapse = " · "), href = url,
                                target = "_blank", rel = "noopener",
                                style = "color: #ece7f7; text-decoration: none;")
      else span(paste(txt, collapse = " · "), style = "color: #ece7f7;"))
}

#' Tile URL template for a base map key ("osm", "linz_aerial", ...), from
#' cf_credits.json — so the source and its attribution cannot drift apart.
#' A provider that needs a key names its env var in `key_env`; the key is
#' substituted for {key}. Returns NULL when that key is not set, so an app can
#' simply leave the option out. (A map key is visible to the browser in the
#' tile URLs — normal for map keys; it is kept out of git, not secret.)
cf_basemap_url <- function(key) {
  cr <- CF_CREDITS[[key]]
  if (is.null(cr$tiles)) return(NULL)
  if (is.null(cr$key_env)) return(cr$tiles)
  k <- Sys.getenv(cr$key_env)
  if (!nzchar(k)) return(NULL)
  sub("{key}", utils::URLencode(k, reserved = TRUE), cr$tiles, fixed = TRUE)
}

#' Tile size in px for a base map (512 for some providers; default 256).
cf_basemap_tile_size <- function(key) CF_CREDITS[[key]]$tile_size %||% 256

#' The subset of base-map keys that can actually be shown. For a keyed
#' provider that means the key is set AND one probe tile (cf_credits.json
#' `probe`) loads — so an expired, mistyped or unprivileged key hides the
#' option at start-up instead of giving a blank map. One tiny request per keyed
#' base map per app start; the outcome is logged.
cf_available_basemaps <- function(choices, probe = TRUE) {
  ok <- vapply(choices, function(k) {
    url <- cf_basemap_url(k)
    if (is.null(url)) return(FALSE)
    cr <- CF_CREDITS[[k]]
    if (!probe || is.null(cr$key_env) || (is.null(cr$probe) && is.null(cr$probe_url)))
      return(TRUE)
    # `probe_url` (a key-validating endpoint) wins over a probe tile: some tile
    # endpoints answer 200 whatever the key, which would prove nothing.
    t <- if (!is.null(cr$probe_url)) {
      sub("{key}", utils::URLencode(Sys.getenv(cr$key_env), reserved = TRUE),
          cr$probe_url, fixed = TRUE)
    } else {
      sub("{z}", cr$probe$z, sub("{x}", cr$probe$x, sub("{y}", cr$probe$y, url,
          fixed = TRUE), fixed = TRUE), fixed = TRUE)
    }
    # A key with referrer restrictions only works for requests that say where
    # they come from; browsers do, a server-side probe does not. CF_MAP_REFERER
    # (e.g. http://localhost/ locally, https://mf-heads.crayfisher.com/ on the
    # server) makes the probe present itself like the app's own pages.
    status <- .cf_probe_status(t, Sys.getenv("CF_MAP_REFERER"))
    good <- isTRUE(status == 200L)
    message(sprintf("[cf_credits] base map %-13s %s", k,
                    if (good) "available" else sprintf("HIDDEN (probe tile: %s — check %s)",
                                                       status, cr$key_env)))
    good
  }, logical(1))
  choices[ok]
}

# libcurl reports e.g. "... HTTP status was '401 Unauthorized'". Read the code
# from that phrase only: the message also contains the URL, full of digits.
.cf_http_status <- function(msg) {
  m <- regmatches(msg, regexpr("status was '[0-9]{3}", msg))
  if (length(m)) as.integer(sub("status was '", "", m)) else NA_integer_
}

.cf_probe_status <- function(url, referer = "") {
  if (!nzchar(referer)) {
    return(tryCatch(attr(curlGetHeaders(url, timeout = 8), "status"),
                    error = function(e) NA_integer_))
  }
  # curlGetHeaders cannot set headers; download.file (libcurl) can. It errors
  # on an HTTP error status, so a clean return means 200.
  f <- tempfile(); on.exit(unlink(f))
  old <- options(timeout = 8); on.exit(options(old), add = TRUE)
  tryCatch({
    utils::download.file(url, f, method = "libcurl", quiet = TRUE,
                         headers = c(Referer = referer))
    200L
  }, error = function(e) .cf_http_status(conditionMessage(e)),
     warning = function(w) .cf_http_status(conditionMessage(w)))
}

#' Base-map choices with a keyless fallback: `preferred` (keyed, probed)
#' first; if none of the `street` ones survives, `fallback` (e.g. OSM) is
#' added so the map always has a street option.
cf_basemap_choices <- function(preferred, street, fallback) {
  got <- cf_available_basemaps(preferred)
  if (!any(street %in% got)) got <- c(got, fallback)
  got
}
