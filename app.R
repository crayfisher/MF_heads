library(shiny)
library(plotly)
library(DT)
# Use the specific tidyverse packages the app needs rather than the full
# meta-package - keeps the Docker image lean and avoids the flaky
# googledrive/gargle/billboarder downloads tidyverse pulls in.
library(dplyr)
library(readr)
library(ggplot2)
library(lubridate)
library(rdeck)
library(sf)
library(sfarrow)
library(arrow)
library(bslib)
library(stars)
library(interp)
library(isoband)
library(shinymanager)
library(future)
library(promises)
# Run model processing in a background worker so the Shiny session stays
# responsive (heavy USG/MF2005 extraction was blocking the event loop long
# enough for the browser websocket to time out and grey the app out).
future::plan(future::multisession, workers = 2)
# Limit upload file size to 1000MB
options(shiny.maxRequestSize = 1000 * 1024^2)

# Resolve app directory at load time (before Shiny changes cwd)
APP_DIR <- normalizePath(dirname(sys.frame(1)$ofile %||% "."), mustWork = FALSE)
if (!file.exists(file.path(APP_DIR, "scripts", "process_model.R"))) {
  # Fallback: use getwd() which is set to app dir by runApp()
  APP_DIR <- getwd()
}
message("[Startup] APP_DIR = ", APP_DIR)

# Command prefix used to run flopy tooling (ZIP extraction, .hds -> parquet).
# Locally we shell out via conda into the dev env. In the Docker image the env
# is already active (and there is no `conda` binary), so set RGW_CONDA_RUN=""
# to call python/Rscript directly. RGW_CONDA_ENV picks the env for the default.
CONDA_ENV <- Sys.getenv("RGW_CONDA_ENV", "flopy_env")
PROC_PREFIX <- Sys.getenv("RGW_CONDA_RUN", paste("conda run -n", CONDA_ENV))
message("[Startup] CONDA_ENV = ", CONDA_ENV, " | PROC_PREFIX = '", PROC_PREFIX, "'")

# --- Shared visual identity (keep in sync with ../RGWchart) ------------------
# Both RGW apps use the SAME vapor base + palette + CSS so they are (a) vivid,
# matching the Crayfisher website's "vapor" theme, and (b) identical to each
# other. The website is Quarto `theme: vapor` with these same teal/neon accents,
# so the apps now read as part of the same family.
CF_PRIMARY   <- "#00bc8c" # teal-green (site h1/h2 + buttons)
CF_ACCENT    <- "#32fbe2" # neon-teal (hover / highlight)
CF_SECONDARY <- "#6f42c1" # vapor purple
CF_BG        <- "#1a0933" # deep purple page background (vapor)
CF_PANEL     <- "#241046" # card / plot panel
CF_FG        <- "#ece7f7" # light lavender text
CF_MUTED     <- "#a99fce" # muted lavender (secondary text)
app_theme <- bs_theme(
  bootswatch = "vapor",
  primary = CF_PRIMARY,
  secondary = CF_SECONDARY,
  success = CF_PRIMARY,
  info = CF_ACCENT,
  base_font = font_google("Inter"),
  heading_font = font_google("Outfit"),
  bg = CF_BG,
  fg = CF_FG
)

# Custom CSS for the vivid, glowing look (matches the website's neon accents).
# Literal hex values here mirror the CF_* constants above; keep them aligned.
custom_css <- "
  body { background: radial-gradient(circle at 20% 0%, #2a0f52 0%, #1a0933 55%) !important; }
  /* bslib's page-sidebar title bar derives its background + text colour from
     these two CSS vars; vapor sets them to pink bg / dark text. Pin both to the
     dark palette so the top bar is dark navy with readable teal text. */
  :root { --bslib-page-sidebar-title-bg: #150726 !important; --bslib-page-sidebar-title-color: #00bc8c !important; }
  .navbar, .bslib-page-sidebar > .navbar { background-color: #150726 !important; background-image: none !important; color: #00bc8c !important; border-bottom: 1px solid rgba(50,251,226,0.18) !important; box-shadow: none !important; position: relative; }
  .navbar .bslib-page-title { color: #00bc8c !important; font-weight: 700; }
  .navbar-brand { color: #00bc8c !important; font-weight: 700 !important; letter-spacing: 0.3px; text-shadow: 0 0 12px rgba(0,188,140,0.45); }
  /* Keep the title text + BETA pill together at the left (the page-title flex
     container would otherwise push a loose badge to the far right). */
  .app-title-wrap { display: inline-flex; align-items: center; }
  /* Large BETA pill next to the app title (matches the website apps badge). */
  .app-beta-badge { display: inline-block; margin-left: 12px; padding: 3px 13px; font-size: 0.78rem; font-weight: 800; letter-spacing: 1.5px; color: #1a0933; background: #32fbe2; border-radius: 30px; vertical-align: middle; text-shadow: none; box-shadow: 0 0 14px rgba(50,251,226,0.6); }
  /* Header link buttons (GitHub / report bug / back-to-site) grouped at the right
     of the top bar; explicit bright colour so they read at rest (outline-info
     rendered too dark on the dark bar). */
  .app-header-links { position: absolute !important; right: 16px; top: 50%; transform: translateY(-50%); z-index: 5; display: flex; gap: 8px; align-items: center; }
  .app-header-links .btn { color: #32fbe2 !important; border-color: #32fbe2 !important; background: rgba(50,251,226,0.08) !important; }
  .app-header-links .btn:hover { background: #32fbe2 !important; color: #150726 !important; box-shadow: 0 0 14px rgba(50,251,226,0.5) !important; }
  h1, h2, h3, h4 { color: #00bc8c; }
  .card {
    background: #241046 !important;
    border: 1px solid rgba(255,255,255,0.08) !important;
    border-radius: 14px !important;
    box-shadow: 0 8px 26px rgba(0,0,0,0.4) !important;
    transition: border-color 0.3s ease, box-shadow 0.3s ease;
  }
  .card:hover { border-color: #32fbe2 !important; box-shadow: 0 14px 30px rgba(50,251,226,0.18) !important; }
  .card-header { background: rgba(0,0,0,0.25) !important; border-bottom: 1px solid rgba(255,255,255,0.08) !important; color: #00bc8c !important; font-weight: 600 !important; }
  .sidebar { background: #150726 !important; border-right: 1px solid rgba(50,251,226,0.12) !important; }
  .accordion-button { background: #241046 !important; color: #ece7f7 !important; }
  .accordion-button:not(.collapsed) { background: #2d1657 !important; color: #00bc8c !important; box-shadow: inset 3px 0 0 #00bc8c; }
  .value-box { border-radius: 14px !important; border: 1px solid rgba(255,255,255,0.08) !important; }
  /* Buttons: pill shape + neon hover glow, matching the website cards. */
  .btn { border-radius: 30px !important; font-weight: 600 !important; transition: all 0.2s ease; }
  .btn-primary, .btn-success { background: #00bc8c !important; border: 1px solid #00bc8c !important; color: #04130e !important; }
  .btn-primary:hover, .btn-success:hover, .btn-info:hover { box-shadow: 0 0 16px rgba(0,188,140,0.55) !important; transform: translateY(-1px); }
  .btn-info { color: #04130e !important; }
  .btn-secondary { color: #ece7f7 !important; }
  /* Outline-info buttons (About panel: Source code / Report a bug): bright teal
     so they're clearly readable on the dark panel, not just on hover. */
  .btn-outline-info { color: #32fbe2 !important; border-color: #32fbe2 !important; }
  .btn-outline-info:hover { background: #32fbe2 !important; color: #150726 !important; box-shadow: 0 0 14px rgba(50,251,226,0.5) !important; }
  /* Outline buttons (e.g. Remove): keep text visible on the dark bg, not only on hover. */
  .btn-danger { color: #fff !important; }
  .btn-outline-danger { color: #ff7088 !important; border-color: #ff7088 !important; }
  .btn-outline-danger:hover { background: #ff7088 !important; color: #1a0933 !important; }
  .form-control, .form-select, .selectize-input, .selectize-dropdown { background: rgba(0,0,0,0.25) !important; border-color: rgba(255,255,255,0.12) !important; color: #ece7f7 !important; }
  a { color: #00bc8c; }
  a:hover { color: #32fbe2; }
"

# Login is disabled (public app), so no credentials are configured here. To
# re-introduce a shinymanager gate, build a `credentials` data.frame from an
# env-var password (never hard-code one) and uncomment the secure_app/
# secure_server lines below.

# GitHub repository for this app (source + bug reports).
APP_REPO <- "https://github.com/crayfisher/MF_heads"

ui <- page_sidebar(
  title = tagList(
    div(class = "app-title-wrap",
      tags$span("MODFLOW heads visualiser", class = "app-title-text"),
      tags$span("BETA", class = "app-beta-badge")
    ),
    div(class = "app-header-links",
      tags$a(icon("github"), href = APP_REPO, target = "_blank", rel = "noopener",
             title = "Source code on GitHub", class = "btn btn-outline-info btn-sm"),
      tags$a(icon("bug"), href = paste0(APP_REPO, "/issues/new"), target = "_blank",
             rel = "noopener", title = "Report a bug", class = "btn btn-outline-info btn-sm"),
      tags$a("← crayfisher.com", href = "https://crayfisher.com",
             class = "btn btn-outline-info btn-sm app-back-btn")
    )
  ),
  # Compile the custom CSS into the theme so it reliably lands in <head>.
  # (page_sidebar has no `header` arg; passing tags$head via ... rendered a
  # <head> inside <body>, which browsers discard — so the CSS never loaded.)
  theme = bs_add_rules(app_theme, custom_css),
  sidebar = sidebar(
    title = "Controls & Parameters",
    bg = "#150726",
    width = 350,
    div(
      style = "font-size: 0.85rem; background-color: #241046; padding: 10px; border-radius: 5px; margin-bottom: 15px; border: 1px solid rgba(255,255,255,0.12); line-height: 1.5;",
      div(strong(icon("layer-group"), " Slice: "), textOutput("slice_text", inline = TRUE)),
      div(strong(icon("map-pin"), " Node: "), textOutput("node_text", inline = TRUE))
    ),
    accordion(
      open = c("0. About", "1. Data Uploads", "4. Slicing & Extraction"),
      accordion_panel(
        "0. About",
        icon = icon("circle-info"),
        div(style = "font-size: 0.85rem; line-height: 1.5;",
          div(style = "margin-bottom: 8px;",
            tags$span("Beta — under active testing", class = "app-beta-badge",
                      style = "margin-left: 0;")),
          tags$p(style = "margin-bottom: 6px;",
            tags$strong("GWheads", style = "color: #32fbe2;"),
            " — MODFLOW heads visualiser for mf6, usg, mf2005."),
          tags$p(style = "margin-bottom: 8px; color: #a99fce;",
            "Interactive, web-native Shiny-based 2D visualisation of hydraulic ",
            "heads, drawdown distributions, and hydrographs."),
          tags$p(style = "margin-bottom: 8px; color: #a99fce;",
            "Powered by ",
            tags$a("FloPy", href = "https://github.com/modflowpy/flopy",
                   target = "_blank", rel = "noopener"),
            " — Python scripting for MODFLOW."),
          div(style = "display: flex; flex-wrap: wrap; gap: 8px;",
            tags$a(icon("github"), " Source code", href = APP_REPO,
                   target = "_blank", rel = "noopener",
                   class = "btn btn-outline-info btn-sm"),
            tags$a(icon("bug"), " Report a bug", href = paste0(APP_REPO, "/issues/new"),
                   target = "_blank", rel = "noopener",
                   class = "btn btn-outline-info btn-sm")
          ),
          div(style = "font-size: 0.75rem; color: #a99fce; margin-top: 8px;",
            "Found a problem or have a request? Please open an issue on GitHub.")
        )
      ),
      accordion_panel(
        "1. Data Uploads",
        icon = icon("cloud-upload-alt"),
        selectInput("model_type", "Model Type:",
                    choices = c("MF-USG" = "usg", "MF6" = "mf6", "MODFLOW-2005" = "mf2005")),
        div(style = "display: flex; align-items: center; gap: 10px;",
            fileInput("upload_zip", "Upload Model ZIP", accept = ".zip"),
            tooltip(
              icon("question-circle"),
              uiOutput("zip_help")
            )
        ),
        uiOutput("georef_help"),
        hr(style = "border-top: 1px solid rgba(255,255,255,0.12); margin: 10px 0;"),
        div(style = "display: flex; align-items: center; gap: 10px;",
            fileInput("upload_files", "Or Manual Parquet Upload (Grid, Heads, Times)",
                      accept = c(".parquet", ".csv"), multiple = TRUE, buttonLabel = "Browse..."),
            tooltip(
              icon("question-circle"),
              uiOutput("manual_help")
            )
        ),
        div(style = "font-size: 0.78rem; color: #a99fce; margin: -8px 0 8px;",
            "Works for ", strong("any"), " model type — it loads already-processed ",
            "parquet/CSV outputs and is grid-type agnostic (not USG-only)."),
        hr(style = "border-top: 1px solid rgba(255,255,255,0.12); margin: 10px 0;"),
        div(strong(icon("retweet"), " Swap Scenario (keeps current grid)"),
            style = "font-size: 0.9rem; margin-bottom: 6px;"),
        div(style = "display: flex; align-items: center; gap: 10px;",
            fileInput("upload_scenario", "Load Scenario Heads (.hds / .parquet)",
                      accept = c(".hds", ".parquet"), multiple = FALSE, buttonLabel = "Browse..."),
            tooltip(
              icon("question-circle"),
              uiOutput("scenario_help")
            )
        ),
        fileInput("upload_baseline", "Optional: Baseline Heads (.parquet/.hds) for Drawdown",
                  accept = c(".parquet", ".hds"), multiple = FALSE, buttonLabel = "Browse..."),
        hr(style = "border-top: 1px solid rgba(255,255,255,0.12); margin: 10px 0;"),
        # Bundled demo / test data - loads instantly (pre-processed parquet), no
        # upload or model-processing needed. Handy for demonstrations.
        uiOutput("demo_ui")
      ),
      accordion_panel(
        "2. File Status",
        icon = icon("check-circle"),
        div(style="font-size: 0.85em; line-height: 1.8;",
          uiOutput("status_grd"),
          uiOutput("status_hds"),
          uiOutput("status_scenario"),
          uiOutput("status_baseline"),
          uiOutput("status_time")
        )
      ),
      accordion_panel(
        "3. Projection & Timeline",
        icon = icon("calendar-alt"),
        uiOutput("crs_status"),
        dateInput("start_date", "Model Start Date:", value = "2019-06-01", weekstart = 1),
        div(style = "font-size: 0.78rem; color: #a99fce; margin-top: 4px;",
            "Start date auto-fills from the model's reference info when available; adjust freely.")
      ),
      accordion_panel(
        "4. Slicing & Extraction",
        icon = icon("sliders-h"),
        div(style = "display: flex; gap: 5px; align-items: flex-end;",
            div(style = "flex-grow: 1;",
                sliderInput("select_time", "Stress Period:", min = 1, max = 1, value = 1, step = 1,
                            animate = animationOptions(interval = 1000, loop = FALSE))),
            actionButton("prev_sp", "", icon = icon("step-backward"), class = "btn-secondary btn-sm", style = "margin-bottom: 1rem;"),
            actionButton("next_sp", "", icon = icon("step-forward"), class = "btn-secondary btn-sm", style = "margin-bottom: 1rem;")
        ),
        numericInput("select_layer", "Select Layer:", value = 1, min = 1, step = 1),
        radioButtons("radio_time_unit", "Hydrograph Time Axis:",
                     choices = c("Time (Days)" = "time", "Stress Period" = "SP", "Calendar Date" = "date"),
                     selected = "time"),
        numericInput("nodenumber", "Extract Node ID:", value = 1, min = 1, step = 1)
      ),
      accordion_panel(
        "5. Visual Settings",
        icon = icon("palette"),
        radioButtons("data_display", "Display Variable:", choices = c("Heads", "Drawdown"), selected = "Heads", inline = TRUE),
        radioButtons("render_style", "Map Style:", choices = c("Color Flood", "Contours", "Both"), selected = "Color Flood", inline = TRUE),
        checkboxInput("show_basemap", "Show Satellite Basemap", value = TRUE),
        checkboxInput("exclude_999", "Exclude Inactive/Dry Cells (999 or 1e30)", value = TRUE),
        # Default OFF so the ramp is pinned to data semantics consistently for
        # every model: turbo runs blue->red and domain_pal() is always
        # (min, max) ascending, giving low=blue / high=red. Toggle to flip.
        checkboxInput("rev_colors", "Reverse Color Ramp", value = FALSE),
        radioButtons("color_mode", "Color Scale Type:", choices = c("Discrete Bins", "Continuous"), selected = "Discrete Bins"),
        checkboxInput("lim_val", "Apply Custom Color Limits (Hide OOB)", value = FALSE),
        numericInput("min_val", "Color Min Value:", value = NA),
        numericInput("max_val", "Color Max Value:", value = NA),
        sliderInput("opacity", "Cell Fill Opacity:", min = 0, max = 1, value = 0.8, step = 0.1)
      )
    )
  ),
  
  # Main page content
  layout_columns(
    col_widths = c(12),
    card(
      full_screen = TRUE,
      card_header(
        class = "d-flex justify-content-between align-items-center",
        textOutput("map_title", inline = TRUE),
        div(class = "d-flex align-items-center", style = "gap: 10px;",
          actionButton("focus_model", "Focus on Model", icon = icon("crosshairs"),
                       class = "btn-secondary btn-sm"),
          tooltip(
            icon("info-circle"),
            "GPU-accelerated map. Displays millions of cells instantly."
          )
        )
      ),
      rdeckOutput("my_rdeck", height = "65vh")
    ),
    accordion(
      open = "Temporal Hydrograph Plot",
      accordion_panel(
        "Temporal Hydrograph Plot",
        icon = icon("chart-line"),
        plotlyOutput("chart", height = "280px")
      )
    )
  )
)

# --- Login gate (disabled) --------------------------------------------------
# Login is intentionally disabled to make the app publicly accessible (linked
# from the Crayfisher website). To re-enable the shinymanager gate, uncomment
# the line below and the matching `secure_server(...)` block in `server`.
# ui <- secure_app(ui)

server <- function(input, output, session) {

  # res_auth <- secure_server(
  #   check_credentials = check_credentials(credentials)
  # )

  # --- Upload validation ----------------------------------------------------
  # The `accept=` on fileInput is a client-side hint only; a crafted request can
  # still POST any file. Since uploads feed a heavy flopy/MODFLOW pipeline (and
  # the app is now public), validate every upload server-side by extension AND,
  # where the format has a reliable signature, by magic bytes before processing.
  ext_of <- function(name) tolower(tools::file_ext(name))

  # ZIP local-file/central/empty/spanned headers all start with "PK" + one of
  # 0x03/0x05/0x07.
  is_zip_file <- function(path) {
    con <- file(path, "rb"); on.exit(close(con))
    sig <- readBin(con, "raw", n = 4)
    length(sig) == 4 && sig[1] == as.raw(0x50) && sig[2] == as.raw(0x4b) &&
      sig[3] %in% as.raw(c(0x03, 0x05, 0x07))
  }
  # Parquet files begin and end with the 4-byte magic "PAR1".
  is_parquet_file <- function(path) {
    sz <- file.info(path)$size
    if (is.na(sz) || sz < 8) return(FALSE)
    con <- file(path, "rb"); on.exit(close(con))
    head4 <- readBin(con, "raw", n = 4)
    seek(con, where = sz - 4, origin = "start")
    tail4 <- readBin(con, "raw", n = 4)
    identical(rawToChar(head4), "PAR1") && identical(rawToChar(tail4), "PAR1")
  }
  # .hds / .csv have no portable signature - extension + non-empty is the
  # practical guard; the parser/reader rejects malformed content downstream.
  validate_upload <- function(df, allowed,
                              magic = c("none", "zip", "parquet")) {
    magic <- match.arg(magic)
    if (is.null(df) || nrow(df) == 0) return(FALSE)
    bad_ext <- df$name[!(ext_of(df$name) %in% tolower(allowed))]
    if (length(bad_ext) > 0) {
      showNotification(
        sprintf("Rejected: %s. Allowed types: %s.",
                paste(bad_ext, collapse = ", "), paste(allowed, collapse = ", ")),
        type = "error")
      return(FALSE)
    }
    if (any(is.na(df$size) | df$size <= 0)) {
      showNotification("Rejected: empty file.", type = "error")
      return(FALSE)
    }
    checker <- switch(magic, zip = is_zip_file, parquet = is_parquet_file, NULL)
    if (!is.null(checker)) {
      ok <- vapply(df$datapath, checker, logical(1))
      if (!all(ok)) {
        showNotification(
          sprintf("Rejected: %s - content does not match a valid %s file.",
                  paste(df$name[!ok], collapse = ", "), magic),
          type = "error")
        return(FALSE)
      }
    }
    TRUE
  }

  # Inactive / dry / no-flow cells. Sentinels vary by model: USG often uses 999,
  # MF6 writes +/-1e30, and MODFLOW-2005 HNOFLO/HDRY can be anything (e.g. 99999).
  # The parser records the model's actual sentinels; we always also treat 999 and
  # extreme magnitudes (>=1e29) as inactive.
  model_sentinels <- reactiveVal(999)
  is_inactive <- function(x) {
    s <- model_sentinels()
    !is.na(x) & (x %in% s | abs(x) >= 1e29)
  }

  # Reference info resolved from the last processed model.
  model_crs <- reactiveVal("NONE")          # EPSG string or "NONE"
  model_time_units <- reactiveVal("unknown")  # days / seconds / ...
  # Model type of the currently loaded data ("usg"/"mf6"/"mf2005"/"manual").
  # Used to decide whether row/col are meaningful (only structured DIS/MF2005).
  loaded_model_type <- reactiveVal(NULL)

  # Convert model time (in its own units) to days for the calendar axis.
  time_to_days <- function(t, units) {
    switch(tolower(units %||% "unknown"),
           "seconds" = t / 86400,
           "minutes" = t / 1440,
           "hours"   = t / 24,
           "years"   = t * 365.25,
           t)  # days or unknown -> assume days
  }
  
  # Value Boxes
  output$status_text <- renderText({
    hds_loaded <- !is.null(hds_path())
    grd_loaded <- !is.null(grid_path())
    if (hds_loaded && grd_loaded) {
      "Active (Parquet)"
    } else if (hds_loaded) {
      "Heads Loaded, Waiting for Grid"
    } else if (grd_loaded) {
      "Grid Loaded, Waiting for Heads"
    } else {
      "Waiting for Uploads"
    }
  })
  
  output$slice_text <- renderText({
    paste("Layer ", input$select_layer, " / SP ", input$select_time, sep="")
  })
  
  output$node_text <- renderText({
    req(input$nodenumber)
    paste("Node #", input$nodenumber, sep="")
  })

  # ZIP tooltip: required contents per model type.
  output$zip_help <- renderUI({
    common <- "Heads (.hds) must be inside the ZIP."
    body <- switch(input$model_type %||% "mf6",
      "usg"    = "MF-USG: ZIP must contain the heads (.hds) plus a grid polygon file (.gpkg or .shp from gridgen). The .gpkg should carry global node numbers and a layer field.",
      "mf6"    = "MF6: ZIP must contain the full simulation (mfsim.nam + dis/disv/disu + .hds). Geometry is read directly from the model.",
      "mf2005" = "MODFLOW-2005: ZIP must contain the name file (.nam), DIS package + referenced arrays, and heads (.hds). CRS/start date are read from the nam header.",
      common)
    span(body)
  })

  # Manual upload tooltip: the expected files + schema. Grid-type agnostic - it
  # loads already-processed outputs, so it works for any model type, not just USG.
  output$manual_help <- renderUI({
    div(style = "text-align:left; min-width: 280px;",
      div(strong("Manual upload (any model type)"), " — drag the processed outputs:"),
      tags$ul(style = "margin:6px 0 0; padding-left: 18px;",
        tags$li(tags$code("Grid.parquet"), " — sf polygons with ",
                tags$code("nodenumber"), ", ", tags$code("nodenumberL1"),
                ", optional ", tags$code("layer"), "."),
        tags$li(tags$code("Heads.parquet"), " — columns ",
                tags$code("SP"), ", ", tags$code("layer"), ", ",
                tags$code("nodenumberL1"), ", ", tags$code("h"), "."),
        tags$li(tags$code("Times.csv"), " — columns ",
                tags$code("time"), ", ", tags$code("SP"), " (+ kstp/kper).")
      )
    )
  })

  # Scenario swap tooltip.
  output$scenario_help <- renderUI({
    div(style = "text-align:left; min-width: 280px;",
      div(strong("Swap scenario heads")),
      div(style = "margin-top:4px;",
          "After loading a model (ZIP / manual / demo), load a different run's ",
          "heads to compare scenarios — the ", strong("grid stays the same"), "."),
      tags$ul(style = "margin:6px 0 0; padding-left: 18px;",
        tags$li(tags$code(".hds"), " — extracted via flopy (same model type as ",
                "the loaded grid), brings its own stress-period timeline."),
        tags$li(tags$code(".parquet"), " — a pre-processed Heads.parquet (",
                tags$code("SP, layer, nodenumberL1, h"), "), used directly.")
      ),
      div(style = "margin-top:4px; color:#a99fce;",
          "Must share the loaded grid's node numbering. Load a new model to reset.")
    )
  })

  # Georeferencing instructions + example sidecar, shown under the ZIP input.
  output$georef_help <- renderUI({
    box_style <- "font-size: 0.78rem; color: #a99fce; background:#150726; padding:8px; border-radius:6px; border:1px solid rgba(255,255,255,0.12);"
    mt <- input$model_type %||% "mf6"
    if (mt == "mf2005") {
      div(style = box_style,
          strong("Georeferencing: "), "read automatically from the flopy nam-file header ",
          tags$code("#xll:..; yll:..; rotation:..; proj4_str:epsg:XXXX; start_datetime:.."),
          ". No CRS → unreferenced view (no basemap).")
    } else if (mt == "usg") {
      # USG geometry comes from the gpkg/shp, which already carries its own CRS.
      # A usgs.model.reference sidecar does NOT apply to this workflow.
      div(style = box_style,
          strong("Georeferencing: "),
          "the CRS is read directly from the grid file's own embedded projection ",
          "(the ", tags$code(".gpkg"), " from gridgen). Geometry, global node numbers ",
          "and the layer field all come from that file — no ",
          tags$code("usgs.model.reference"), " sidecar is needed. ",
          "If the gpkg has no CRS the model is shown unreferenced (no basemap).")
    } else {
      div(style = box_style,
          strong("Georeferencing (optional): "),
          "MF6 files store no CRS. Include a ", tags$code("usgs.model.reference"),
          " file in the ZIP to place the model on the map. Example:",
          tags$pre(style = "margin:6px 0 0; white-space:pre; color:#cbd5e1;",
                   "xll 1891460.0\nyll 5594400.0\nrotation 0.0\nepsg 2193\nstart_date 1980-07-01"),
          "Without it the model is shown unreferenced (no basemap).")
    }
  })

  # Resolved CRS line in the Projection panel.
  output$crs_status <- renderUI({
    cu <- model_crs()
    if (is.null(cu) || toupper(cu) == "NONE") {
      div(style = "font-size: 0.82rem; color:#f59e0b; margin-bottom:6px;",
          icon("triangle-exclamation"), " Unreferenced (no CRS) – basemap off.")
    } else {
      div(style = "font-size: 0.82rem; color:#00bc8c; margin-bottom:6px;",
          icon("location-dot"), sprintf(" Georeferenced: EPSG:%s.", cu))
    }
  })

  # Status indicators
  output$status_grd <- renderUI({
    if (is.null(grid_path())) span(icon("times-circle"), " Grid missing", style="color:#ef4444")
    else span(icon("check-circle"), " Grid loaded", style="color:#00bc8c")
  })
  output$status_hds <- renderUI({
    if (is.null(hds_path())) span(icon("times-circle"), " Heads missing", style="color:#ef4444")
    else span(icon("check-circle"), " Heads loaded", style="color:#00bc8c")
  })
  output$status_scenario <- renderUI({
    if (is.null(scenario_heads())) span(icon("circle"), " Base heads (no scenario override)", style="color:#a99fce")
    else span(icon("retweet"), " Scenario override active", style="color:#0ea5e9")
  })
  output$status_baseline <- renderUI({
    if (is.null(hds2_path())) span(icon("info-circle"), " No Baseline (Drawdown disabled)", style="color:#a99fce")
    else span(icon("check-circle"), " Baseline loaded", style="color:#00bc8c")
  })
  output$status_time <- renderUI({
    if (is.null(time_path())) span(icon("times-circle"), " Times missing", style="color:#ef4444")
    else span(icon("check-circle"), " Times loaded", style="color:#00bc8c")
  })
  
  # Accumulate uploaded files so sequential drag-and-drops don't overwrite each other
  uploaded_files <- reactiveVal(data.frame(name = character(), datapath = character(), stringsAsFactors = FALSE))
  
  observeEvent(input$upload_files, {
    new_files <- input$upload_files
    # Server-side type check (extension for all; parquet magic for parquet ones).
    if (!validate_upload(new_files, allowed = c("parquet", "csv"))) return()
    pq <- new_files[ext_of(new_files$name) == "parquet", , drop = FALSE]
    if (nrow(pq) > 0 && !validate_upload(pq, allowed = "parquet", magic = "parquet")) return()
    current_files <- uploaded_files()
    
    # Remove older files with the same name if re-uploaded
    current_files <- current_files[!(current_files$name %in% new_files$name), ]
    updated_files <- rbind(current_files, new_files[, c("name", "datapath")])

    uploaded_files(updated_files)
    # Manual parquet upload is grid-type agnostic; mark it so we don't assume
    # the model_type dropdown (which only governs ZIP uploads) applies here.
    loaded_model_type("manual")
    # A manual upload defines its own heads; drop any scenario override.
    scenario_heads(NULL)
    scenario_times(NULL)
  })
  
  # Apply the processed model's output dir + metadata to the session. Runs on the
  # main thread once the background job resolves.
  apply_processed_model <- function(out_dir, mtype = NULL) {
    loaded_model_type(mtype)
    # Clear any baseline + scenario override from a previously loaded model (the
    # demo loader re-sets the baseline afterwards if the demo bundles one); avoids
    # a stale drawdown reference or scenario heads carrying over to a new model.
    baseline_parquet(NULL)
    scenario_heads(NULL)
    scenario_times(NULL)
    out_files <- list.files(out_dir, full.names = TRUE)
    if (length(out_files) == 0) {
      removeModal()
      showNotification("Failed to extract any useful data from ZIP.", type = "error")
      return(invisible())
    }
    uploaded_files(data.frame(name = basename(out_files), datapath = out_files,
                              stringsAsFactors = FALSE))

    read_meta <- function(fname) {
      f <- file.path(out_dir, fname)
      if (file.exists(f)) trimws(readLines(f, warn = FALSE)[1]) else ""
    }
    cu <- read_meta("crs_used.txt")
    known <- nzchar(cu) && toupper(cu) != "NONE"
    model_crs(if (known) cu else "NONE")
    updateCheckboxInput(session, "show_basemap", value = known)

    sent <- read_meta("sentinels.txt")
    sv <- suppressWarnings(as.numeric(strsplit(sent, ",")[[1]]))
    model_sentinels(unique(c(999, sv[is.finite(sv)])))

    tu <- read_meta("time_units.txt")
    model_time_units(if (nzchar(tu)) tu else "unknown")
    sd <- read_meta("start_date.txt")
    # as.Date() errors (not warns) on non-dates like "NONE", so guard it.
    sd_date <- if (nzchar(sd) && toupper(sd) != "NONE")
      tryCatch(as.Date(substr(sd, 1, 10)), error = function(e) NA) else NA
    if (!is.na(sd_date)) {
      updateDateInput(session, "start_date", value = sd_date)
    } else {
      # No reference date in the new model: reset to the app default rather than
      # silently carrying over the previous model's start date (otherwise the
      # timeline of a model with no start_date is offset by the last one's).
      updateDateInput(session, "start_date", value = as.Date("2019-06-01"))
    }

    removeModal()
    showNotification(paste0("Model successfully extracted and processed!",
                            if (known) sprintf(" CRS EPSG:%s.", cu) else " No CRS - basemap hidden."),
                     type = "message")
  }

  # --- Bundled demo / test data -------------------------------------------
  # Each demo lives in demo/<name>/ as the already-processed outputs
  # (Grid.parquet, Heads.parquet, Times.csv + *.txt sidecars), so it loads
  # instantly with no flopy/parser dependency - ideal for the Docker image.
  demo_base <- file.path(APP_DIR, "demo")
  demo_dirs <- reactive({
    if (!dir.exists(demo_base)) return(character(0))
    subs <- list.dirs(demo_base, full.names = FALSE, recursive = FALSE)
    subs[file.exists(file.path(demo_base, subs, "Grid.parquet"))]
  })

  output$demo_ui <- renderUI({
    dirs <- demo_dirs()
    if (length(dirs) == 0) return(NULL)
    # Friendly labels (e.g. "hpm" -> "HPM").
    labels <- toupper(dirs)
    choices <- setNames(dirs, labels)
    tagList(
      div(strong(icon("flask"), " Demo / Test Data"),
          style = "font-size: 0.9rem; margin-bottom: 6px;"),
      div(style = "display: flex; gap: 8px; align-items: flex-end;",
        div(style = "flex-grow: 1;",
            selectInput("demo_choice", NULL, choices = choices, width = "100%")),
        actionButton("load_demo", "Load", icon = icon("play"),
                     class = "btn-info btn-sm", style = "margin-bottom: 0;")
      ),
      div(style = "font-size: 0.78rem; color: #a99fce;",
          "Pre-processed sample model for demonstration - loads instantly."),
      if (any(tolower(dirs) == "hpm")) {
        div(style = "font-size: 0.72rem; color: #a99fce; margin-top: 8px; line-height: 1.35; border-top: 1px solid rgba(169,159,206,0.25); padding-top: 8px;",
          tags$strong("HPM", style = "color: #32fbe2;"),
          " - Heretaunga Plains groundwater model, developed by Hawkes Bay ",
          "Regional Council, NZ. Documented in the Heretaunga Aquifer ",
          "Groundwater Model Development Report:",
          tags$br(),
          "Rakowski P., Knowling M. (2018) ",
          tags$em("4997 Heretaunga Aquifer Groundwater Model Development Report"),
          ". ",
          tags$a("Executive summary", target = "_blank", rel = "noopener",
                 style = "color: #32fbe2;",
                 href = "https://www.hbrc.govt.nz/assets/Document-Library/Publications-Database/4999-Executive-summary-of-Heretaunga-Aquifer-Groundwater-Model-Development-Report1.pdf"),
          " | ",
          tags$a("full report", target = "_blank", rel = "noopener",
                 style = "color: #32fbe2;",
                 href = "https://www.hbrc.govt.nz/assets/Document-Library/Publications-Database/4997-Heretaunga-Model-Groundwater-Development-Report.pdf"),
          "."
        )
      }
    )
  })

  observeEvent(input$load_demo, {
    req(input$demo_choice)
    ddir <- file.path(demo_base, input$demo_choice)
    req(dir.exists(ddir))
    mt <- {
      f <- file.path(ddir, "model_type.txt")
      if (file.exists(f)) trimws(readLines(f, warn = FALSE)[1]) else "manual"
    }
    apply_processed_model(ddir, mt)
    # If the demo bundles a baseline (e.g. a no-pumping "null" run), wire it up
    # so Drawdown works out of the box without a separate upload.
    bl <- file.path(ddir, "Heads_baseline.parquet")
    if (file.exists(bl)) {
      baseline_parquet(bl)
      showNotification("Demo baseline loaded - Drawdown available.", type = "message")
    } else {
      baseline_parquet(NULL)
    }
  })

  observeEvent(input$upload_zip, {
    req(input$upload_zip)
    if (!validate_upload(input$upload_zip, allowed = "zip", magic = "zip")) return()

    showModal(modalDialog(
      title = "Processing Archive...",
      "Extracting and compiling model files. Large models can take a minute or two - the app stays connected while this runs.",
      footer = NULL
    ))

    # Capture plain values for the background worker (no reactives inside future).
    zip_path <- input$upload_zip$datapath
    temp_dir <- tempfile(pattern = "model_extract_")
    out_dir <- tempfile(pattern = "model_out_")
    dir.create(temp_dir)
    mtype <- input$model_type
    process_script <- file.path(APP_DIR, "scripts", "process_model.R")

    # Heavy work (unzip + conda Rscript extraction) runs in a worker process so
    # the Shiny event loop keeps answering heartbeats and never disconnects.
    future_promise({
      unzip(zip_path, exdir = temp_dir)
      cmd <- sprintf("%s Rscript %s %s %s %s",
                     PROC_PREFIX, shQuote(process_script), mtype, shQuote(temp_dir), shQuote(out_dir))
      res <- system(cmd, intern = FALSE, ignore.stdout = TRUE, ignore.stderr = TRUE)
      list(res = res, out_dir = out_dir)
    }, seed = TRUE) %...>% (function(result) {
      if (result$res == 0) {
        apply_processed_model(result$out_dir, mtype)
      } else {
        removeModal()
        showNotification("Model processing failed (non-zero exit).", type = "error")
      }
    }) %...!% (function(err) {
      removeModal()
      showNotification(paste("Processing error:", conditionMessage(err)), type = "error")
    })
  })

  # Determine which file is which
  grid_path <- reactive({
    req(nrow(uploaded_files()) > 0)
    files <- uploaded_files()
    # Require a parquet/gpkg extension so the intermediate grid_polys.csv that
    # the parser leaves behind is never mistaken for the grid geometry.
    idx <- grep("(grid|qtgrid).*\\.(parquet|gpkg)$", files$name, ignore.case = TRUE)
    if(length(idx) == 0) return(NULL)
    files$datapath[idx[1]]
  })
  
  # Active scenario overrides. Once a base model is loaded (ZIP/manual/demo), a
  # different scenario's heads can be swapped in while reusing the same grid:
  # scenario_heads holds the active Heads.parquet, scenario_times its timeline.
  scenario_heads <- reactiveVal(NULL)
  scenario_times <- reactiveVal(NULL)

  hds_path <- reactive({
    if (!is.null(scenario_heads())) return(scenario_heads())
    req(nrow(uploaded_files()) > 0)
    files <- uploaded_files()
    idx_p <- grep("\\.parquet$", files$name, ignore.case = TRUE)
    # Exclude grid geometry AND any baseline heads (a demo bundles
    # Heads_baseline.parquet alongside Heads.parquet) - the baseline must never
    # be picked as the scenario, or drawdown = baseline - baseline = 0.
    idx_excl <- grep("grid|qtgrid|baseline", files$name, ignore.case = TRUE)
    idx <- setdiff(idx_p, idx_excl)
    if (length(idx) == 0) return(NULL)
    # Prefer an exact "Heads.parquet" when present (deterministic, not order-dependent).
    exact <- intersect(grep("(^|/)Heads\\.parquet$", files$name, ignore.case = TRUE), idx)
    if (length(exact) > 0) return(files$datapath[exact[1]])
    files$datapath[idx[1]]
  })

  # Shared helper: extract a .hds to a heads parquet (+Times.csv) in a background
  # worker, then hand the output dir to on_success. Used for both scenario and
  # baseline uploads. USG uses HeadUFile; everything else the standard HeadFile.
  process_hds_async <- function(hds_src, title, on_success, on_fail = NULL) {
    showModal(modalDialog(title = title,
                          "Extracting heads from the .hds file.", footer = NULL))
    out_dir <- tempfile(pattern = "hds_out_")
    dir.create(out_dir)
    mode <- if (identical(loaded_model_type(), "usg")) "heads_usg" else "heads"
    py_script <- file.path(APP_DIR, "scripts", "flopy_parser.py")
    future_promise({
      cmd <- sprintf("%s python %s %s %s %s",
                     PROC_PREFIX, shQuote(py_script), mode, shQuote(hds_src), shQuote(out_dir))
      res <- system(cmd, intern = FALSE, ignore.stdout = TRUE, ignore.stderr = TRUE)
      list(res = res, out_dir = out_dir)
    }, seed = TRUE) %...>% (function(result) {
      removeModal()
      heads <- file.path(result$out_dir, "Heads.parquet")
      if (result$res == 0 && file.exists(heads)) {
        on_success(result$out_dir)
      } else {
        showNotification("Failed to extract heads from .hds.", type = "error")
        if (!is.null(on_fail)) on_fail()
      }
    }) %...!% (function(err) {
      removeModal()
      showNotification(paste("Extraction error:", conditionMessage(err)), type = "error")
      if (!is.null(on_fail)) on_fail()
    })
  }

  # Load a different scenario's heads on top of the current grid (.hds extracted
  # via flopy; .parquet used directly). The grid/geometry stays from the base.
  observeEvent(input$upload_scenario, {
    req(input$upload_scenario)
    f <- input$upload_scenario
    if (!validate_upload(f, allowed = c("hds", "parquet"))) return()
    ext <- ext_of(f$name)
    if (ext == "parquet") {
      if (!validate_upload(f, allowed = "parquet", magic = "parquet")) return()
      scenario_heads(f$datapath)
      scenario_times(NULL)  # parquet scenario keeps the base timeline
      showNotification("Scenario heads loaded (parquet).", type = "message")
      return(invisible())
    }
    process_hds_async(f$datapath, "Processing Scenario...",
      on_success = function(out_dir) {
        scenario_heads(file.path(out_dir, "Heads.parquet"))
        tf <- file.path(out_dir, "Times.csv")
        scenario_times(if (file.exists(tf)) tf else NULL)
        showNotification("Scenario heads extracted from .hds.", type = "message")
      })
  })

  # Baseline heads for drawdown. A .parquet is used directly; a .hds is run
  # through the parser to produce a heads parquet so drawdown works from output.
  baseline_parquet <- reactiveVal(NULL)

  observeEvent(input$upload_baseline, {
    req(input$upload_baseline)
    f <- input$upload_baseline
    if (!validate_upload(f, allowed = c("parquet", "hds"))) return()
    ext <- ext_of(f$name)
    if (ext == "parquet") {
      if (!validate_upload(f, allowed = "parquet", magic = "parquet")) return()
      baseline_parquet(f$datapath)
      return(invisible())
    }
    process_hds_async(f$datapath, "Processing Baseline...",
      on_success = function(out_dir) {
        baseline_parquet(file.path(out_dir, "Heads.parquet"))
        showNotification("Baseline heads extracted from .hds.", type = "message")
      },
      on_fail = function() baseline_parquet(NULL))
  })

  hds2_path <- reactive({
    baseline_parquet()
  })

  time_path <- reactive({
    if (!is.null(scenario_times())) return(scenario_times())
    req(nrow(uploaded_files()) > 0)
    files <- uploaded_files()
    idx <- grep("Times\\.csv$", files$name, ignore.case = TRUE)
    if(length(idx) == 0) return(NULL)
    files$datapath[idx[1]]
  })

  # Grid GeoParquet Loading. Standardize the geometry column name to "geometry"
  # so rdeck's get_polygon = geometry works (older parquets use "geom").
  grid_sf <- reactive({
    req(grid_path())
    g <- st_read_parquet(grid_path())
    if (!identical(attr(g, "sf_column"), "geometry")) {
      g <- st_sf(st_drop_geometry(g), geometry = st_geometry(g))
    }
    g
  })
  
  # Cached attribute table (no geometry) for node lookups - avoids copying the
  # full grid geometry on every node change.
  grid_attrs <- reactive({
    req(grid_sf())
    sf::st_drop_geometry(grid_sf())
  })

  # Outline for initial bounds - just the bounding box (st_union over tens of
  # thousands of polygons is needlessly slow/heavy; we only need the extent).
  grid_outline <- reactive({
    req(grid_sf())
    df <- grid_sf()
    if ("layer" %in% names(df)) {
      df <- df %>% filter(layer == 1)
    }
    st_as_sfc(st_bbox(df)) %>% st_transform(4326)
  })
  
  # Head Dataset & Times
  head_ds <- reactive({
    req(hds_path())
    open_dataset(hds_path())
  })
  
  time_df <- reactive({
    req(time_path())
    df <- read_csv(time_path(), show_col_types = FALSE)
    # `time` is cumulative model time in the model's own units; convert to days
    # for the calendar axis (ddays accepts fractional days). Guard the start date
    # (input may be NULL/blank during init -> as.POSIXct would error).
    start <- tryCatch(as.POSIXct(as.character(input$start_date)), error = function(e) NA)
    if (length(start) == 0 || is.na(start)) start <- as.POSIXct("1970-01-01")
    df %>% mutate(date = start + lubridate::ddays(time_to_days(time, model_time_units())))
  })
  
  # Step controls
  observeEvent(input$prev_sp, {
    req(input$select_time > 1)
    updateSliderInput(session, "select_time", value = input$select_time - 1)
  })
  observeEvent(input$next_sp, {
    req(time_df(), input$select_time < max(time_df()$SP))
    updateSliderInput(session, "select_time", value = input$select_time + 1)
  })
  
  # Update UI Bounds dynamically
  observe({
    req(time_df())
    updateSliderInput(session, "select_time", max = max(time_df()$SP))
  })
  
  observe({
    req(head_ds())
    # Layer count comes from the heads (grid geometry may be a single reusable
    # layer for structured/DISV), so this works for every grid type.
    n_lay <- tryCatch(
      head_ds() %>% summarize(n = max(layer)) %>% collect() %>% pull(n),
      error = function(e) 1
    )
    updateNumericInput(session, "select_layer", max = n_lay)
    # Clamp the current selection: if the previous model had more layers and the
    # user was on layer > n_lay, slicing the new (thinner) model would error.
    cur <- isolate(input$select_layer)
    if (isTruthy(cur) && cur > n_lay) {
      updateNumericInput(session, "select_layer", value = 1)
    }
  })
  
  # Slicing the Heads for the Map
  head_slice <- reactive({
    req(head_ds(), input$select_time, input$select_layer)
    sp_target <- as.integer(input$select_time)
    lay_target <- as.integer(input$select_layer)
    
    # Push query down to Arrow / DuckDB
    h_df <- head_ds() %>%
      filter(SP == sp_target, layer == lay_target) %>%
      collect()
      
    if (input$data_display == "Drawdown" && !is.null(hds2_path())) {
      h2_df <- open_dataset(hds2_path()) %>%
        filter(SP == sp_target, layer == lay_target) %>%
        collect()
      if(nrow(h2_df) > 0) {
        h_df <- h_df %>% inner_join(h2_df %>% rename(h_base = h), by = c("layer", "nodenumberL1", "SP"))
        # Drawdown = Baseline - Scenario (keep inactive cells flagged as 999)
        h_df$h <- ifelse(is_inactive(h_df$h) | is_inactive(h_df$h_base), 999, h_df$h_base - h_df$h)
      }
    }
    
    h_df
  })
  
  # Join Slice with Geometry
  map_data <- reactive({
    req(grid_sf())
    lay_target <- as.integer(input$select_layer)
    
    # Filter grid to correct layer
    if ("layer" %in% names(grid_sf())) {
      df <- grid_sf() %>% filter(layer == lay_target) %>% select(-layer)
    } else {
      df <- grid_sf()
    }
    
    if (!"nodenumberL1" %in% names(df)) {
      if ("nodenumber" %in% names(df)) {
        df$nodenumberL1 <- df$nodenumber
      } else {
        df$nodenumberL1 <- 1:nrow(df)
      }
    }
    
    # Try joining heads if available
    try_heads <- tryCatch({
      h_df <- head_slice()
      if(nrow(h_df) > 0) h_df else NULL
    }, error = function(e) NULL)
    
    if (!is.null(try_heads)) {
      df <- df %>% inner_join(try_heads, by = "nodenumberL1")
    }
    
    df <- df %>% st_transform(4326)
    
    if (!"h" %in% colnames(df)) {
      df <- df %>% mutate(h = NA_real_, h_color = NA_real_)
    } else {
      # Exclude inactive/dry cells if checked
      if(isTRUE(input$exclude_999)) {
        df <- df %>% mutate(h_color = ifelse(is_inactive(h), NA, h))
      } else {
        df <- df %>% mutate(h_color = h)
      }
      
      # Exclude outside limits if checked
      if(isTRUE(input$lim_val)) {
        if(!is.na(input$min_val)) {
          df <- df %>% mutate(h_color = ifelse(!is.na(h_color) & h_color < input$min_val, NA, h_color))
        }
        if(!is.na(input$max_val)) {
          df <- df %>% mutate(h_color = ifelse(!is.na(h_color) & h_color > input$max_val, NA, h_color))
        }
      }
    }
    
    df
  })
  
  # Color scaling
  domain_pal <- reactive({
    req(head_slice())
    vals <- head_slice()$h
    # Inactive/dry sentinels (999, 99999, +/-1e30, ...) must never drive the
    # color scale, regardless of the "exclude" toggle (they are not real data).
    vals <- vals[!is_inactive(vals)]

    c_min <- min(vals, na.rm=TRUE)
    c_max <- max(vals, na.rm=TRUE)
    
    if (isTRUE(input$lim_val)) {
      if (!is.na(input$min_val)) c_min <- input$min_val
      if (!is.na(input$max_val)) c_max <- input$max_val
    }
    
    c(c_min, c_max)
  })
  
  # Dynamic Contours
  contour_data <- reactive({
    req(map_data(), domain_pal(), input$render_style %in% c("Contours", "Both"))
    df <- map_data() %>% filter(!is.na(h_color))
    req(nrow(df) > 0)

    # Cap the points fed to interp() so contours on huge grids (e.g. 49k cells)
    # can't hang the app - sample down for the interpolation only.
    if (nrow(df) > 40000) {
      df <- df %>% slice_sample(n = 40000)
    }

    my_breaks <- pretty(domain_pal(), n = 10)
    
    tryCatch({
      # Suppress sf warnings about centroids
      pts <- suppressWarnings(st_centroid(df))
      coords <- st_coordinates(pts)
      
      # Interpolate scattered centroids to grid
      nx <- 200; ny <- 200
      
      # create mask via stars
      mask_stars <- stars::st_rasterize(df %>% mutate(m = 1) %>% select(m), nx = nx, ny = ny)
      mask_mat <- mask_stars[[1]]
      
      # Extract grid coords correctly oriented
      dim_x <- stars::st_get_dimension_values(mask_stars, 1)
      dim_y <- stars::st_get_dimension_values(mask_stars, 2)
      xo <- sort(unique(dim_x))
      yo <- sort(unique(dim_y))
      
      grid <- interp::interp(coords[, 1], coords[, 2], df$h_color, xo = xo, yo = yo)
      
      # Apply boundary clip (mask_mat has descending y natively)
      mask_mat_flipped <- mask_mat[, ny:1]
      grid$z[is.na(mask_mat_flipped)] <- NA
      
      # Generate smooth isolines (transpose z to fix mirror issue)
      lines <- isoband::isolines(xo, yo, t(grid$z), levels = my_breaks)
      cl_geom <- isoband::iso_to_sfg(lines)
      
      # Convert to sf
      cl <- st_sf(h_color = as.numeric(names(cl_geom)), geometry = st_sfc(cl_geom, crs = 4326))
      
      # Extract midpoints for text labels
      cl_pts <- suppressWarnings(st_point_on_surface(cl))
      cl_pts$label <- as.character(cl_pts$h_color)
      
      list(lines = cl, labels = cl_pts)
    }, error = function(e) NULL)
  })
  
  # WebGL Map Base
  output$my_rdeck <- renderRdeck({
    req(grid_outline())
    bbox <- st_bbox(grid_outline())
    
    # Pad bbox if it's too small (prevents rdeck crash on tiny grids like 2-cell model)
    if ((bbox["xmax"] - bbox["xmin"]) < 1e-4) {
      bbox["xmax"] <- bbox["xmax"] + 1e-4
      bbox["xmin"] <- bbox["xmin"] - 1e-4
    }
    if ((bbox["ymax"] - bbox["ymin"]) < 1e-4) {
      bbox["ymax"] <- bbox["ymax"] + 1e-4
      bbox["ymin"] <- bbox["ymin"] - 1e-4
    }
    
    rdeck(
      map_style = NULL, # Mapbox needs a token, so we skip it
      initial_bounds = bbox,
      controller = TRUE
    )
  })
  
  # Dynamic Map Layer updates
  observe({
    req(map_data())

    md <- map_data()
    n_poly <- nrow(md)
    # Large grids (e.g. 49k+ cells/layer): drop the hover-highlight, which forces
    # deck.gl to re-render the whole picking layer on every pointer move and can
    # exhaust GPU memory / hang the browser. Also ship only the columns rdeck
    # needs to cut the per-update payload.
    big_grid <- n_poly > 20000
    render_df <- md %>% select(any_of(c("nodenumber", "nodenumberL1", "row", "col", "h", "h_color")))

    has_heads <- !is.null(hds_path()) && "h" %in% colnames(md) && !all(is.na(md$h))
    
    if (has_heads) {
      req(domain_pal())
      my_breaks <- pretty(domain_pal(), n = 10)
      my_palette <- if(isTRUE(input$rev_colors)) rev(viridisLite::turbo(length(my_breaks) + 1)) else viridisLite::turbo(length(my_breaks) + 1)
      
      fill_scale <- if (input$color_mode == "Discrete Bins") {
        scale_color_threshold(
          col = h_color,
          palette = my_palette,
          breaks = my_breaks,
          na_color = "#00000000"
        )
      } else {
        scale_color_linear(
          col = h_color,
          palette = my_palette,
          limits = domain_pal(),
          breaks = my_breaks,
          na_color = "#00000000"
        )
      }
      fill_color_arg <- fill_scale
    } else {
      fill_color_arg <- "#3b82f680" # default blue outline when no heads
    }
    
    # Show row/col only for structured grids (DIS / MODFLOW-2005). USG quadtree
    # grids carry meaningless base-grid row/col, so suppress them there even
    # though the columns exist; DISV/DISU grids simply don't have the columns.
    structured_ok <- !identical(loaded_model_type(), "usg")
    tt <- if (structured_ok && all(c("row", "col") %in% names(render_df))) {
      c("row", "col", "nodenumber")
    } else {
      "nodenumber"
    }
    if (has_heads) tt <- c(tt, "h")
    tooltip_vars <- rlang::expr(c(!!!rlang::syms(tt)))
    
    proxy <- rdeck_proxy("my_rdeck") %>%
      add_tile_layer(
        id = "google_sat",
        data = "https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}",
        visible = isTRUE(input$show_basemap),
        pickable = FALSE
      )
      
    if (input$render_style %in% c("Color Flood", "Both") || !has_heads) {
      proxy <- proxy %>% add_polygon_layer(
        id = "head_layer",
        data = render_df,
        get_polygon = geometry,
        get_fill_color = !!fill_color_arg,
        get_line_color = if(has_heads && input$render_style == "Color Flood") "#00000000" else "#ffffff80",
        opacity = input$opacity,
        pickable = TRUE,
        auto_highlight = !big_grid,
        highlight_color = "#ffffff80",
        tooltip = !!tooltip_vars
      )
    } else {
      proxy <- proxy %>% add_polygon_layer(id = "head_layer", data = render_df %>% slice(0), get_polygon = geometry)
    }
    
    if (input$render_style %in% c("Contours", "Both") && has_heads) {
      cl_data <- contour_data()
      
      if (!is.null(cl_data)) {
        cl <- cl_data$lines
        cl_pts <- cl_data$labels
        
        if (!is.null(cl) && nrow(cl) > 0) {
          proxy <- proxy %>% add_path_layer(
            id = "contour_lines",
            data = cl,
            get_path = geometry,
            get_color = "#ffffff",
            width_min_pixels = 2,
            opacity = 0.8
          )
          
          if (!is.null(cl_pts) && nrow(cl_pts) > 0) {
            proxy <- proxy %>% add_text_layer(
              id = "contour_labels",
              data = cl_pts,
              get_position = geometry,
              get_text = label,
              get_color = "#ffffff",
              size_units = "pixels",
              get_size = 14,
              get_alignment_baseline = "center",
              get_text_anchor = "middle",
              background = TRUE,
              get_background_color = "#000000aa"
            )
          }
        }
      } else {
        proxy <- proxy %>%
          add_path_layer(id = "contour_lines", data = st_sf(geometry = st_sfc(), h_color = numeric()), get_path = geometry) %>%
          add_text_layer(id = "contour_labels", data = st_sf(geometry = st_sfc(), label = character()), get_position = geometry, get_text = label)
      }
    } else {
      proxy <- proxy %>% 
        add_path_layer(id = "contour_lines", data = st_sf(geometry=st_sfc(), h_color=numeric()), get_path=geometry) %>%
        add_text_layer(id = "contour_labels", data = st_sf(geometry=st_sfc(), label=character()), get_position=geometry, get_text=label)
    }
  })
  
  # Recenter the camera on the model extent.
  focus_tick <- reactiveVal(0)
  observeEvent(input$focus_model, {
    req(grid_outline())
    bbox <- st_bbox(grid_outline())
    if ((bbox["xmax"] - bbox["xmin"]) < 1e-4) {
      bbox["xmax"] <- bbox["xmax"] + 1e-4; bbox["xmin"] <- bbox["xmin"] - 1e-4
    }
    if ((bbox["ymax"] - bbox["ymin"]) < 1e-4) {
      bbox["ymax"] <- bbox["ymax"] + 1e-4; bbox["ymin"] <- bbox["ymin"] - 1e-4
    }
    # deck.gl ignores an unchanged `initial_bounds`, so a second click never
    # re-fits. Alternate a sub-metre nudge (~0.1 m) each click so the value
    # always differs from the previous fit and the camera re-centres every time.
    tick <- focus_tick() + 1
    focus_tick(tick)
    nudge <- if (tick %% 2 == 0) 1e-6 else -1e-6
    bbox["xmax"] <- bbox["xmax"] + nudge
    bbox["ymax"] <- bbox["ymax"] + nudge
    rdeck_proxy("my_rdeck", initial_bounds = bbox)
  })

  # Handle map clicks
  observeEvent(input$my_rdeck_click, {
    info <- input$my_rdeck_click
    if (!is.null(info) && !is.null(info$object)) {
      updateNumericInput(session, "nodenumber", value = info$object$nodenumber)
    }
  })
  
  # Number of nodes per layer (cached)
  nodes_per_layer <- reactive({
    req(head_ds())
    if (!is.null(grid_path())) {
      df <- grid_sf()
      n_per_lay <- nrow(df)
      if ("layer" %in% names(df)) {
        n_per_lay <- df %>% filter(layer == 1) %>% nrow()
      }
      n_per_lay
    } else {
      # Compute mathematically from parquet metadata
      head_ds() %>% summarize(n = max(nodenumberL1)) %>% collect() %>% pull(n)
    }
  })
  
  # Hydrograph Data
  node_hydr <- reactive({
    req(head_ds(), input$nodenumber, time_df())
    node_id <- as.integer(input$nodenumber)

    # Resolve (layer, per-layer node) for this node id. Prefer the grid as the
    # source of truth: DISU/USG grids carry layer + nodenumberL1 per node, while
    # structured/DISV grids share one geometry across layers (use selected layer).
    lay_target <- as.integer(input$select_layer)
    nl1_target <- node_id
    gdf <- tryCatch(grid_attrs(), error = function(e) NULL)
    if (!is.null(gdf)) {
      hit <- if ("nodenumber" %in% names(gdf)) gdf[gdf$nodenumber == node_id, , drop = FALSE] else gdf[0, ]
      if (nrow(hit) >= 1) {
        if ("nodenumberL1" %in% names(hit)) nl1_target <- as.integer(hit$nodenumberL1[1])
        if ("layer" %in% names(hit)) lay_target <- as.integer(hit$layer[1])
      }
    } else {
      # Heads-only (no grid): fall back to uniform global-node decomposition.
      n_layer <- nodes_per_layer()
      lay_target <- (node_id - 1) %/% n_layer + 1
      nl1_target <- (node_id - 1) %% n_layer + 1
    }

    # Query arrow dataset for this specific node across all time
    h_time <- head_ds() %>%
      filter(layer == lay_target, nodenumberL1 == nl1_target) %>%
      collect()
      
    if (input$data_display == "Drawdown" && !is.null(hds2_path())) {
      h2_time <- open_dataset(hds2_path()) %>%
        filter(layer == lay_target, nodenumberL1 == nl1_target) %>%
        collect()
      if (nrow(h2_time) > 0) {
        h_time <- h_time %>% inner_join(h2_time %>% rename(h_base = h), by = c("layer", "nodenumberL1", "SP"))
        h_time$h <- ifelse(h_time$h == 999 | h_time$h_base == 999, 999, h_time$h_base - h_time$h)
      }
    }
      
    h_time %>%
      left_join(time_df(), by = "SP")
  })
  
  # Map card title reflects what is being shown (Heads vs Drawdown) using
  # domain terms rather than a generic "head distribution" label.
  output$map_title <- renderText({
    if (identical(input$data_display, "Drawdown")) {
      "Drawdown Distribution Map"
    } else {
      "Groundwater Head Distribution Map"
    }
  })

  # Plotly Chart
  output$chart <- renderPlotly({
    req(node_hydr())
    
    time_col <- input$radio_time_unit
    lbls <- c("time" = "Time (Days)", "SP" = "Stress Period", "date" = "Calendar Date")
    
    p <- ggplot(node_hydr(), aes(x = .data[[time_col]], y = h)) +
      geom_line(linewidth = 1, color = "#00bc8c") +
      geom_point(size = 2, color = "#00bc8c", alpha = 0.7) +
      labs(
        title = paste(if(input$data_display == "Drawdown") "Drawdown Hydrograph for Node #" else "Hydrograph for Node #", input$nodenumber),
        x = lbls[time_col],
        y = if(input$data_display == "Drawdown") "Drawdown (m)" else "Head (m)"
      ) +
      theme_minimal(base_family = "Inter") +
      theme(
        plot.title = element_text(face = "bold", color = "#ece7f7"),
        axis.title = element_text(face = "bold", color = "#ece7f7"),
        axis.text = element_text(color = "#a99fce"),
        panel.grid.major = element_line(color = "#3a2560"),
        panel.grid.minor = element_blank(),
        plot.background = element_rect(fill = "#241046", color = NA),
        panel.background = element_rect(fill = "#241046", color = NA)
      )

    gp <- ggplotly(p, dynamicTicks = TRUE) %>%
      layout(
        plot_bgcolor = "#241046",
        paper_bgcolor = "#241046",
        font = list(color = "#ece7f7")
      )
    # Drawdown increases downward, so invert the y-axis when displaying it.
    if (input$data_display == "Drawdown") {
      gp <- gp %>% layout(yaxis = list(autorange = "reversed"))
    }
    gp
  })
}

shinyApp(ui = ui, server = server)
