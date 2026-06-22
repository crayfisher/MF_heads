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
# Limit upload file size to 1000MB
options(shiny.maxRequestSize = 1000 * 1024^2)

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
        fileInput("upload_files", "Drop all files here (Grid .parquet, Heads .parquet, Times .csv)", 
                  accept = c(".parquet", ".csv"), multiple = TRUE, buttonLabel = "Browse...")
      ),
      accordion_panel(
        "2. File Status",
        icon = icon("check-circle"),
        div(style="font-size: 0.85em; line-height: 1.8;",
          uiOutput("status_grd"),
          uiOutput("status_hds"),
          uiOutput("status_time")
        )
      ),
      accordion_panel(
        "3. Projection & Timeline",
        icon = icon("calendar-alt"),
        dateInput("start_date", "Model Start Date:", value = "2019-06-01", weekstart = 1)
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
        radioButtons("render_style", "Map Style:", choices = c("Color Flood", "Contours", "Both"), selected = "Color Flood", inline = TRUE),
        checkboxInput("exclude_999", "Exclude Inactive Cells (h=999)", value = TRUE),
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
        tooltip(
          icon("info-circle"),
          "GPU-accelerated map. Displays millions of cells instantly."
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
  
  # Status indicators
  output$status_grd <- renderUI({
    if (is.null(grid_path())) span(icon("times-circle"), " Grid missing", style="color:#ef4444")
    else span(icon("check-circle"), " Grid loaded", style="color:#10b981")
  })
  output$status_hds <- renderUI({
    if (is.null(hds_path())) span(icon("times-circle"), " Heads missing", style="color:#ef4444")
    else span(icon("check-circle"), " Heads loaded", style="color:#10b981")
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

  # Determine which file is which
  grid_path <- reactive({
    req(nrow(uploaded_files()) > 0)
    files <- uploaded_files()
    idx <- grep("grid|qtgrid", files$name, ignore.case = TRUE)
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
  
  time_path <- reactive({
    req(nrow(uploaded_files()) > 0)
    files <- uploaded_files()
    idx <- grep("\\.csv$", files$name, ignore.case = TRUE)
    if(length(idx) == 0) return(NULL)
    files$datapath[idx[1]]
  })

  # Grid GeoParquet Loading
  grid_sf <- reactive({
    req(grid_path())
    st_read_parquet(grid_path())
  })
  
  # Outline for initial bounds
  grid_outline <- reactive({
    req(grid_sf())
    grid_sf() %>% 
      filter(layer == 1) %>% 
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
    df <- df %>% mutate(date = ymd(input$start_date) + days(time))
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
    req(grid_sf())
    updateNumericInput(session, "select_layer", max = max(grid_sf()$layer, na.rm = TRUE))
  })
  
  # Slicing the Heads for the Map
  head_slice <- reactive({
    req(head_ds(), input$select_time, input$select_layer)
    sp_target <- as.integer(input$select_time)
    lay_target <- as.integer(input$select_layer)
    
    # Push query down to Arrow / DuckDB
    head_ds() %>%
      filter(SP == sp_target, layer == lay_target) %>%
      collect()
  })
  
  # Join Slice with Geometry
  map_data <- reactive({
    req(grid_sf())
    lay_target <- as.integer(input$select_layer)
    
    # Filter grid to correct layer
    df <- grid_sf() %>% filter(layer == lay_target)
    
    # Try joining heads if available
    try_heads <- tryCatch({
      h_df <- head_slice()
      if(nrow(h_df) > 0) h_df else NULL
    }, error = function(e) NULL)
    
    if (!is.null(try_heads)) {
      df <- df %>% inner_join(try_heads, by = c("layer", "nodenumberL1"))
    }
    
    df <- df %>% st_transform(4326)
    
    if (!"h" %in% colnames(df)) {
      df <- df %>% mutate(h = NA_real_, h_color = NA_real_)
    } else {
      # Exclude 999 if checked
      if(isTRUE(input$exclude_999)) {
        df <- df %>% mutate(h_color = ifelse(h == 999, NA, h))
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
    if(isTRUE(input$exclude_999)) {
      vals <- vals[vals != 999]
    }
    
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
    
    tooltip_vars <- if (has_heads) rlang::expr(c(nodenumber, h)) else rlang::expr(c(nodenumber))
    
    proxy <- rdeck_proxy("my_rdeck") %>%
      add_tile_layer(
        id = "google_sat",
        data = "https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}",
        pickable = FALSE
      )
      
    if (input$render_style %in% c("Color Flood", "Both") || !has_heads) {
      proxy <- proxy %>% add_polygon_layer(
        id = "head_layer",
        data = map_data(),
        get_polygon = geom,
        get_fill_color = !!fill_color_arg,
        get_line_color = if(has_heads && input$render_style == "Color Flood") "#00000000" else "#ffffff80",
        opacity = input$opacity,
        pickable = TRUE,
        auto_highlight = TRUE,
        highlight_color = "#ffffff80",
        tooltip = !!tooltip_vars
      )
    } else {
      proxy <- proxy %>% add_polygon_layer(id = "head_layer", data = map_data() %>% slice(0), get_polygon = geom)
    }
    
    if (input$render_style %in% c("Contours", "Both") && has_heads) {
      cl_data <- contour_data()
      cl <- cl_data$lines
      cl_pts <- cl_data$labels
      
      if (!is.null(cl) && nrow(cl) > 0) {
        proxy <- proxy %>% add_path_layer(
          id = "contour_layer",
          data = cl,
          get_path = geometry,
          get_color = "#ffffff",
          width_min_pixels = 2,
          pickable = TRUE,
          tooltip = c(h_color)
        ) %>% add_text_layer(
          id = "contour_labels",
          data = cl_pts,
          get_position = geometry,
          get_text = label,
          get_color = "#ffffff",
          get_size = 14,
          pickable = FALSE
        )
      } else {
        proxy <- proxy %>% 
          add_path_layer(id = "contour_layer", data = st_sf(geometry=st_sfc(), h_color=numeric()), get_path=geometry) %>%
          add_text_layer(id = "contour_labels", data = st_sf(geometry=st_sfc(), label=character()), get_position=geometry, get_text=label)
      }
    } else {
      proxy <- proxy %>% 
        add_path_layer(id = "contour_layer", data = st_sf(geometry=st_sfc(), h_color=numeric()), get_path=geometry) %>%
        add_text_layer(id = "contour_labels", data = st_sf(geometry=st_sfc(), label=character()), get_position=geometry, get_text=label)
    }
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
      # Fast fallback if grid is loaded
      grid_sf() %>% filter(layer == 1) %>% nrow()
    } else {
      # Compute mathematically from parquet metadata
      head_ds() %>% summarize(n = max(nodenumberL1)) %>% collect() %>% pull(n)
    }
  })
  
  # Hydrograph Data
  node_hydr <- reactive({
    req(head_ds(), input$nodenumber, time_df())
    node_id <- as.integer(input$nodenumber)
    n_layer <- nodes_per_layer()
    
    lay_target <- (node_id - 1) %/% n_layer + 1
    nl1_target <- (node_id - 1) %% n_layer + 1
    
    # Query arrow dataset for this specific node across all time
    h_time <- head_ds() %>%
      filter(layer == lay_target, nodenumberL1 == nl1_target) %>%
      collect()
      
    # Join with time dataframe
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
        title = paste("Hydrograph for Node #", input$nodenumber),
        x = lbls[time_col],
        y = "Head / Drawdown"
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
