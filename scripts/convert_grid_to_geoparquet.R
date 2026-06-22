library(sf)
library(dplyr)
library(sfarrow)

# Read command line arguments
args = commandArgs(trailingOnly=TRUE)
if (length(args) < 1) {
  stop("Usage: Rscript convert_grid_to_geoparquet.R <input.gpkg> [output.parquet]")
}

in_file <- args[1]
if (length(args) >= 2) {
  out_file <- args[2]
} else {
  out_file <- sub("\\.[^.]+$", ".parquet", in_file)
}

cat("Reading", in_file, "...\n")
grid_sf_poly <- st_read(in_file) %>% 
  mutate(layer = layer + 1)

cat("Calculating node indices...\n")
nodes_per_layer <- grid_sf_poly %>% 
  as_tibble() %>% 
  count(layer) %>% 
  rename(nodes_per_layer = n) %>% 
  mutate(nodes_per_layer_cum = cumsum(nodes_per_layer) - nodes_per_layer)  

grid_sf_poly_grid <- grid_sf_poly %>% 
  left_join(nodes_per_layer, by = "layer") %>% 
  mutate(nodenumberL1 = nodenumber - nodes_per_layer_cum ) %>% 
  mutate(layerId = nodenumber) %>%
  dplyr::select(-nodes_per_layer_cum, -nodes_per_layer)

cat("Writing to GeoParquet format:", out_file, "...\n")
st_write_parquet(grid_sf_poly_grid, out_file)

cat("Done!\n")
