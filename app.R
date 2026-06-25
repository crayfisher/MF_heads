library(shiny)
library(plotly)
library(DT)
library(tidyverse)
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
# Limit upload file size to 1000MB
options(shiny.maxRequestSize = 1000 * 1024^2)

# Resolve app directory at load time (before Shiny changes cwd)
APP_DIR <- normalizePath(dirname(sys.frame(1)$ofile %||% "."), mustWork = FALSE)
if (!file.exists(file.path(APP_DIR, "scripts", "process_model.R"))) {
  # Fallback: use getwd() which is set to app dir by runApp()
  APP_DIR <- getwd()
}
message("[Startup] APP_DIR = ", APP_DIR)

# Define custom premium theme using bslib
app_theme <- bs_theme(
  bootswatch = "darkly",
  primary = "#10b981", # Emerald
  secondary = "#475569", # Slate
  success = "#10b981",
  info = "#0ea5e9", # Sky blue
  base_font = font_google("Inter"),
  heading_font = font_google("Outfit"),
  bg = "#0f172a", # Dark slate background
  fg = "#f8fafc" # Light grey text
)

# Custom CSS for modern design accents
custom_css <- "
  .navbar { border-bottom: 1px solid #1e293b !important; }
  .card {
    border: 1px solid #1e293b !important;
    background-color: #1e293b !important;
    border-radius: 12px !important;
    box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1) !important;
  }
  .card-header { border-bottom: 1px solid #334155 !important; font-weight: 600 !important; }
  .sidebar { background-color: #0f172a !important; border-right: 1px solid #1e293b !important; }
  .accordion-button { background-color: #1e293b !important; color: #f8fafc !important; }
  .accordion-button:not(.collapsed) { background-color: #334155 !important; color: #10b981 !important; }
  .value-box { border-radius: 12px !important; border: 1px solid #1e293b !important; }
"

# Secure credentials using environment variables
# Pass the password at runtime via: docker run -e APP_PASSWORD="your_password" ...
app_pass <- Sys.getenv("APP_PASSWORD")
if (app_pass == "") {
  app_pass <- "rgw_secret" # Fallback for local testing
}

credentials <- data.frame(
  user = c("viewer"),
  password = c(app_pass),
  admin = c(FALSE),
  stringsAsFactors = FALSE
)

ui <- page_sidebar(
  title = "RGW Heads Visualizer (WebGL)",
  theme = app_theme,
  header = tags$head(
    tags$style(HTML(custom_css))
  ),
  sidebar = sidebar(
    title = "Controls & Parameters",
    bg = "#0f172a",
    width = 350,
    div(
      style = "font-size: 0.85rem; background-color: #1e293b; padding: 10px; border-radius: 5px; margin-bottom: 15px; border: 1px solid #334155; line-height: 1.5;",
      div(strong(icon("layer-group"), " Slice: "), textOutput("slice_text", inline = TRUE)),
      div(strong(icon("map-pin"), " Node: "), textOutput("node_text", inline = TRUE))
    ),
    accordion(
      open = c("1. Data Uploads", "3. Slicing & Extraction"),
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
        hr(style = "border-top: 1px solid #334155; margin: 10px 0;"),
        fileInput("upload_files", "Or Manual Parquet Upload (Grid, Heads, Times)",
                  accept = c(".parquet", ".csv"), multiple = TRUE, buttonLabel = "Browse..."),
        fileInput("upload_baseline", "Optional: Upload Baseline Heads (.parquet) for Drawdown", accept = c(".parquet"), multiple = FALSE, buttonLabel = "Browse...")
      ),
      accordion_panel(
        "2. File Status",
        icon = icon("check-circle"),
        div(style="font-size: 0.85em; line-height: 1.8;",
          uiOutput("status_grd"),
          uiOutput("status_hds"),
          uiOutput("status_baseline"),
          uiOutput("status_time")
        )
      ),
      accordion_panel(
        "3. Projection & Timeline",
        icon = icon("calendar-alt"),
        uiOutput("crs_status"),
        dateInput("start_date", "Model Start Date:", value = "2019-06-01", weekstart = 1),
        div(style = "font-size: 0.78rem; color: #94a3b8; margin-top: 4px;",
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
        checkboxInput("rev_colors", "Reverse Color Ramp", value = TRUE),
        radioButtons("color_mode", "Color Scale Type:", choices = c("Discrete Bins", "Continuous"), selected = "Discrete Bins"),
        checkboxInput("lim_val", "Apply Custom Color Limits (Hide OOB)", value = FALSE),
        numericInput("min_val", "Color Min Value:", value = NA),
        numericInput("max_val", "Color Max Value:", value = NA),
        sliderInput("opacity", "Polygon Opacity:", min = 0, max = 1, value = 0.8, step = 0.1)
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
        "WebGL Head Distribution Map",
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

server <- function(input, output, session) {

  # res_auth <- secure_server(
  #   check_credentials = check_credentials(credentials)
  # )

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

  # Georeferencing instructions + example sidecar, shown under the ZIP input.
  output$georef_help <- renderUI({
    if ((input$model_type %||% "mf6") == "mf2005") {
      div(style = "font-size: 0.78rem; color: #94a3b8; background:#0f172a; padding:8px; border-radius:6px; border:1px solid #334155;",
          strong("Georeferencing: "), "read automatically from the flopy nam-file header ",
          tags$code("#xll:..; yll:..; rotation:..; proj4_str:epsg:XXXX; start_datetime:.."),
          ". No CRS → unreferenced view (no basemap).")
    } else {
      div(style = "font-size: 0.78rem; color: #94a3b8; background:#0f172a; padding:8px; border-radius:6px; border:1px solid #334155;",
          strong("Georeferencing (optional): "),
          "include a ", tags$code("usgs.model.reference"), " file in the ZIP to place the model on the map. Example:",
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
      div(style = "font-size: 0.82rem; color:#10b981; margin-bottom:6px;",
          icon("location-dot"), sprintf(" Georeferenced: EPSG:%s.", cu))
    }
  })

  # Status indicators
  output$status_grd <- renderUI({
    if (is.null(grid_path())) span(icon("times-circle"), " Grid missing", style="color:#ef4444")
    else span(icon("check-circle"), " Grid loaded", style="color:#10b981")
  })
  output$status_hds <- renderUI({
    if (is.null(hds_path())) span(icon("times-circle"), " Heads missing", style="color:#ef4444")
    else span(icon("check-circle"), " Heads loaded", style="color:#10b981")
  })
  output$status_baseline <- renderUI({
    if (is.null(hds2_path())) span(icon("info-circle"), " No Baseline (Drawdown disabled)", style="color:#94a3b8")
    else span(icon("check-circle"), " Baseline loaded", style="color:#10b981")
  })
  output$status_time <- renderUI({
    if (is.null(time_path())) span(icon("times-circle"), " Times missing", style="color:#ef4444")
    else span(icon("check-circle"), " Times loaded", style="color:#10b981")
  })
  
  # Accumulate uploaded files so sequential drag-and-drops don't overwrite each other
  uploaded_files <- reactiveVal(data.frame(name = character(), datapath = character(), stringsAsFactors = FALSE))
  
  observeEvent(input$upload_files, {
    new_files <- input$upload_files
    current_files <- uploaded_files()
    
    # Remove older files with the same name if re-uploaded
    current_files <- current_files[!(current_files$name %in% new_files$name), ]
    updated_files <- rbind(current_files, new_files[, c("name", "datapath")])
    
    uploaded_files(updated_files)
  })
  
  observeEvent(input$upload_zip, {
    req(input$upload_zip)
    
    showModal(modalDialog(
      title = "Processing Archive...",
      "Extracting and compiling model files. This may take a minute...",
      footer = NULL
    ))
    
    zip_path <- input$upload_zip$datapath
    temp_dir <- tempfile(pattern = "model_extract_")
    out_dir <- tempfile(pattern = "model_out_")
    
    dir.create(temp_dir)
    unzip(zip_path, exdir = temp_dir)
    
    mtype <- input$model_type
    
    # Use absolute path so it works regardless of working directory
    process_script <- file.path(APP_DIR, "scripts", "process_model.R")
    cmd <- sprintf("conda run -n flopy_env Rscript %s %s %s %s",
                   shQuote(process_script), mtype, shQuote(temp_dir), shQuote(out_dir))
    message("[ZIP Upload] Running: ", cmd)
    res <- system(cmd, intern = FALSE, ignore.stdout = FALSE, ignore.stderr = FALSE)
    message("[ZIP Upload] Exit code: ", res)
    
    # Gather output files and REPLACE all previously uploaded files
    out_files <- list.files(out_dir, full.names = TRUE)
    if(res == 0 && length(out_files) > 0) {
      new_files <- data.frame(
        name = basename(out_files),
        datapath = out_files,
        stringsAsFactors = FALSE
      )
      
      # Clear all previous files - new ZIP is a fresh model
      uploaded_files(new_files)

      # Read reference metadata the parser/R wrote out.
      read_meta <- function(fname) {
        f <- file.path(out_dir, fname)
        if (file.exists(f)) trimws(readLines(f, warn = FALSE)[1]) else ""
      }

      # CRS: default the basemap toggle from whether a CRS was resolved. A model
      # with no known CRS lands at a fabricated location, so hide the basemap.
      cu <- read_meta("crs_used.txt")
      known <- nzchar(cu) && toupper(cu) != "NONE"
      model_crs(if (known) cu else "NONE")
      updateCheckboxInput(session, "show_basemap", value = known)

      # Model-specific inactive/dry head sentinels (HNOFLO/HDRY).
      sent <- read_meta("sentinels.txt")
      sv <- suppressWarnings(as.numeric(strsplit(sent, ",")[[1]]))
      sv <- sv[is.finite(sv)]
      model_sentinels(unique(c(999, sv)))

      # Time units (for the calendar axis) + start date from the model.
      tu <- read_meta("time_units.txt")
      model_time_units(if (nzchar(tu)) tu else "unknown")
      sd <- read_meta("start_date.txt")
      sd_date <- suppressWarnings(as.Date(substr(sd, 1, 10)))
      if (nzchar(sd) && toupper(sd) != "NONE" && !is.na(sd_date)) {
        updateDateInput(session, "start_date", value = sd_date)
      }

      crs_msg <- if (known) sprintf(" CRS EPSG:%s.", cu) else " No CRS - basemap hidden."
      removeModal()
      showNotification(paste0("Model successfully extracted and processed!", crs_msg), type = "message")
    } else {
      removeModal()
      showNotification("Failed to extract any useful data from ZIP.", type = "error")
    }
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
  
  hds_path <- reactive({
    req(nrow(uploaded_files()) > 0)
    files <- uploaded_files()
    idx_p <- grep("\\.parquet$", files$name, ignore.case = TRUE)
    idx_g <- grep("grid|qtgrid", files$name, ignore.case = TRUE)
    idx <- setdiff(idx_p, idx_g)
    if(length(idx) == 0) return(NULL)
    files$datapath[idx[1]]
  })
  
  hds2_path <- reactive({
    req(input$upload_baseline)
    input$upload_baseline$datapath
  })
  
  time_path <- reactive({
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
  
  # Outline for initial bounds
  grid_outline <- reactive({
    req(grid_sf())
    df <- grid_sf()
    if ("layer" %in% names(df)) {
      df <- df %>% filter(layer == 1)
    }
    df %>% 
      st_union() %>%
      st_transform(4326)
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
    # for the calendar axis (ddays accepts fractional days).
    df <- df %>% mutate(date = as.POSIXct(input$start_date) +
                          lubridate::ddays(time_to_days(time, model_time_units())))
    df
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
    
    has_heads <- !is.null(hds_path()) && "h" %in% colnames(map_data()) && !all(is.na(map_data()$h))
    
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
    
    # Show row/col when the grid carries them (structured models), else node id.
    tt <- if (all(c("row", "col") %in% names(map_data()))) c("row", "col", "nodenumber") else "nodenumber"
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
        data = map_data(),
        get_polygon = geometry,
        get_fill_color = !!fill_color_arg,
        get_line_color = if(has_heads && input$render_style == "Color Flood") "#00000000" else "#ffffff80",
        opacity = input$opacity,
        pickable = TRUE,
        auto_highlight = TRUE,
        highlight_color = "#ffffff80",
        tooltip = !!tooltip_vars
      )
    } else {
      proxy <- proxy %>% add_polygon_layer(id = "head_layer", data = map_data() %>% slice(0), get_polygon = geometry)
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
  observeEvent(input$focus_model, {
    req(grid_outline())
    bbox <- st_bbox(grid_outline())
    if ((bbox["xmax"] - bbox["xmin"]) < 1e-4) {
      bbox["xmax"] <- bbox["xmax"] + 1e-4; bbox["xmin"] <- bbox["xmin"] - 1e-4
    }
    if ((bbox["ymax"] - bbox["ymin"]) < 1e-4) {
      bbox["ymax"] <- bbox["ymax"] + 1e-4; bbox["ymin"] <- bbox["ymin"] - 1e-4
    }
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
    g <- tryCatch(grid_sf(), error = function(e) NULL)
    if (!is.null(g)) {
      gdf <- sf::st_drop_geometry(g)
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
  
  # Plotly Chart
  output$chart <- renderPlotly({
    req(node_hydr())
    
    time_col <- input$radio_time_unit
    lbls <- c("time" = "Time (Days)", "SP" = "Stress Period", "date" = "Calendar Date")
    
    p <- ggplot(node_hydr(), aes(x = .data[[time_col]], y = h)) +
      geom_line(linewidth = 1, color = "#10b981") +
      geom_point(size = 2, color = "#10b981", alpha = 0.7) +
      labs(
        title = paste(if(input$data_display == "Drawdown") "Drawdown Hydrograph for Node #" else "Hydrograph for Node #", input$nodenumber),
        x = lbls[time_col],
        y = if(input$data_display == "Drawdown") "Drawdown (m)" else "Head"
      ) +
      theme_minimal(base_family = "Inter") +
      theme(
        plot.title = element_text(face = "bold", color = "white"),
        axis.title = element_text(face = "bold", color = "white"),
        axis.text = element_text(color = "gray"),
        panel.grid.major = element_line(color = "#334155"),
        panel.grid.minor = element_blank(),
        plot.background = element_rect(fill = "#1e293b", color = NA),
        panel.background = element_rect(fill = "#1e293b", color = NA)
      )
      
    ggplotly(p, dynamicTicks = TRUE) %>%
      layout(
        plot_bgcolor = "#1e293b",
        paper_bgcolor = "#1e293b",
        font = list(color = "white")
      )
  })
}

shinyApp(ui = ui, server = server)
