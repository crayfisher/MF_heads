library(sf)
library(dplyr)
library(sfarrow)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3) {
  stop("Usage: Rscript process_model.R <model_type> <input_path> <out_dir> [crs]")
}

model_type <- args[1]
input_path <- args[2]
out_dir <- args[3]
# User-supplied CRS (EPSG) from the UI; "", "NA" mean "not provided".
user_crs <- if (length(args) >= 4 && nzchar(args[4]) && toupper(args[4]) != "NA") args[4] else NA

dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# 1. Run Python Parser - use absolute path based on this script's location.
# Resolve robustly whether sourced or run via Rscript (commandArgs has --file=).
get_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]), mustWork = FALSE)))
  }
  ofile <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
  if (!is.null(ofile)) {
    return(dirname(normalizePath(ofile, mustWork = FALSE)))
  }
  "scripts"
}
script_dir <- get_script_dir()
py_script <- file.path(script_dir, "flopy_parser.py")
if (!file.exists(py_script)) {
  py_script <- file.path("scripts", "flopy_parser.py")
}

# Determine the actual path if input_path is a directory
original_dir <- input_path  # keep reference to the zip extraction root
if (dir.exists(input_path)) {
  if (model_type == "usg") {
    hds_files <- list.files(input_path, pattern = "\\.hds$", full.names = TRUE, recursive = TRUE, ignore.case = TRUE)
    if (length(hds_files) > 0) {
      input_path <- hds_files[1]
    }
  } else if (model_type == "mf6") {
    nam_files <- list.files(input_path, pattern = "^mfsim\\.nam$", full.names = TRUE, recursive = TRUE, ignore.case = TRUE)
    if (length(nam_files) > 0) {
      input_path <- dirname(nam_files[1])
    }
  } else if (model_type == "mf2005") {
    # Any .nam that is not mfsim.nam is the MODFLOW-2005 name file.
    nam_files <- list.files(input_path, pattern = "\\.nam$", full.names = TRUE, recursive = TRUE, ignore.case = TRUE)
    nam_files <- nam_files[basename(nam_files) != "mfsim.nam"]
    if (length(nam_files) > 0) {
      input_path <- dirname(nam_files[1])
    }
  }
}

cmd <- sprintf("conda run -n flopy_env python %s %s %s %s", 
               shQuote(py_script), model_type, shQuote(input_path), shQuote(out_dir))
message("Running Python extraction: ", cmd)
res <- system(cmd)
message("Python exit code: ", res)

# Effective CRS: user-supplied EPSG wins; otherwise use what the parser detected
# (e.g. from a usgs.model.reference sidecar or an mf2005 nam header).
detected_crs <- NA
detected_file <- file.path(out_dir, "detected_crs.txt")
if (file.exists(detected_file)) {
  dc <- trimws(readLines(detected_file, warn = FALSE)[1])
  if (length(dc) && nzchar(dc) && toupper(dc) != "NONE") detected_crs <- dc
}
eff_crs <- if (!is.na(user_crs)) user_crs else detected_crs
crs_known <- !is.na(eff_crs)
message("Effective CRS: ", if (crs_known) eff_crs else "NONE (basemap will default off)")

# 2. Process MF6 grid if grid_polys.csv was generated
grid_csv <- file.path(out_dir, "grid_polys.csv")
if (file.exists(grid_csv)) {
  message("Converting grid_polys.csv to Grid.parquet...")
  polys_df <- read.csv(grid_csv)
  # The parser emits one WKT polygon per cell; rebuild geometry with a single
  # vectorized st_as_sfc() (fast even for 100k+ cells, unlike a per-cell group_by).
  geom <- st_as_sfc(polys_df$wkt)
  attr_df <- polys_df[, setdiff(names(polys_df), "wkt"), drop = FALSE]
  grid_sf <- st_sf(attr_df, geometry = geom) %>%
    rename(nodenumber = node)
  if (!"nodenumberL1" %in% names(grid_sf)) {
    grid_sf <- grid_sf %>% mutate(nodenumberL1 = nodenumber)
  }
    
  if (crs_known) {
    st_crs(grid_sf) <- as.integer(eff_crs)
  } else {
    # No CRS known: place in 3857 so it still renders (basemap will be off).
    st_crs(grid_sf) <- 3857
  }
  grid_sf <- st_transform(grid_sf, 4326)

  # Standardize geometry column name
  st_geometry(grid_sf) <- "geometry"

  st_write_parquet(grid_sf, file.path(out_dir, "Grid.parquet"))
} else if (model_type == "usg" || model_type == "mf6") {
  # 3. Process existing shapefile/gpkg if provided
  # Search both the original extraction dir and the resolved input dir
  search_dirs <- unique(c(original_dir, dirname(input_path)))
  geom_files <- character(0)
  for (d in search_dirs) {
    geom_files <- c(geom_files, list.files(d, pattern = "\\.(shp|gpkg)$", full.names = TRUE, recursive = TRUE, ignore.case = TRUE))
  }
  geom_files <- unique(geom_files)
  
  if (length(geom_files) > 0) {
    message(sprintf("Found geometry file: %s. Converting to Grid.parquet...", geom_files[1]))
    df <- st_read(geom_files[1])
    
    # Rename node column to nodenumber if needed
    if ("nodenumb" %in% names(df) && !"nodenumber" %in% names(df)) {
      df <- df %>% rename(nodenumber = nodenumb)
    }
    
    # For USG-T: the gpkg uses global node numbers (1..N_total).
    # Heads use per-layer node numbers (1..N_per_layer).
    # We need to create a per-layer nodenumberL1 so the join works.
    if (model_type == "usg" && "layer" %in% names(df) && "nodenumber" %in% names(df)) {
      # Sort by layer then global nodenumber within layer
      df <- df %>% 
        arrange(layer, nodenumber) %>%
        group_by(layer) %>%
        mutate(nodenumberL1 = row_number()) %>%
        ungroup()
      
      # Layer in gpkg starts at 0, heads start at 1
      df <- df %>% mutate(layer = layer + 1L)
    } else if ("nodenumber" %in% names(df)) {
      df <- df %>% mutate(nodenumberL1 = nodenumber)
    }
    
    if (!is.na(st_crs(df))) {
      # The gpkg/shp already carries a real CRS - that counts as known.
      crs_known <- TRUE
      df_epsg <- st_crs(df)$epsg
      if (!is.null(df_epsg) && !is.na(df_epsg)) eff_crs <- df_epsg
    } else if (crs_known) {
      st_crs(df) <- as.integer(eff_crs)
    } else {
      st_crs(df) <- 3857
    }
    df <- st_transform(df, 4326)

    # Standardize geometry column name
    st_geometry(df) <- "geometry"

    st_write_parquet(df, file.path(out_dir, "Grid.parquet"))
  }
}

# Record the effective CRS so the app can default the basemap toggle.
writeLines(if (crs_known) as.character(eff_crs) else "NONE",
           file.path(out_dir, "crs_used.txt"))
