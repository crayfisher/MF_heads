#function for diff
diff_f <- function(sim,df_i_null,df_i){
  df_i_diff <-  df_i_null$WL - df_i$WL
  df_i_diff1 <- df_i %>% 
    dplyr::select(node) %>% 
    mutate(diff= df_i_diff,
           sim = as.factor(sim))
  return(df_i_diff1)
}

#function for contour


drd_r <- function(sim,f_base,f_base_null,ugri_poly,L,SP,res){
  
  df_base <- read_mf_real_ug_select(f_base,SP)
  df_base_null <- read_mf_real_ug_select(f_base_null,SP)
  df_i_null <- df_base_null
  df_i <- df_base
  
  df_base_diff <- diff_f(sim,df_i_null,df_i)
  df <- df_base_diff
  df <- df %>% 
    mutate(KPER = SP,
           WL=diff)
  r_diff <- get_contours(df,L,SP,res)
  return(r_diff)
}




drd_con <- function(raster_1,levels_1,file_name,crs_1){
  con1 <- rasterToContour(raster_1,levels = levels_1)
  con1_sf <- st_as_sf(con1) %>% st_set_crs(crs_1)
  st_write(con1_sf,file_name,delete_dsn=TRUE )
}

drd_area <- function(raster_1){
  pol1 <- rasterToPolygons(raster_1,
                           fun = function(x){x>=0.5}) %>% 
    st_as_sf() %>% 
    group_by() %>% 
    summarise(WL = max(WL)) %>% 
    st_area() 
  pol1 <- as.numeric(pol1)
  pol1
}
