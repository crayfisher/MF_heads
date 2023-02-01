Lay <- 1
get_contours <- function(df,Lay,SP,res){
  
  
  df1 <- df %>% 
    filter( KPER == SP) %>% 
    dplyr::select(node,WL) %>% 
    filter(WL != 999) 
  # mutate(WL = ifelse(WL == 999,0,WL) )
  
  ugri_pt <- ugri_poly %>% 
    filter(layer == Lay) %>% 
    st_centroid() %>% 
    left_join(df1,by = c("nodenumber" = "node")) %>% 
    filter(is.na(WL) == F) 
  
  #crs1 <- st_crs(ugri_pt)$proj4string
  ext1 <- extent(ugri_pt)
  
  ras1 <- raster(ext1,resolution = 10)
  #crs(ras1) <- crs1
  ras1_pt <- rasterToPoints(ras1,spatial=T)
  
  
  ugri_pt_sp <- ugri_pt %>% 
    dplyr::select(WL)
  
  ugri_pt_sp <- as(ugri_pt_sp,"Spatial")
  #plot(ugri_pt_sp)
  
  tring <- interp(x = ugri_pt_sp,y = NULL,z = "WL",ny = res,nx = res)
  
  trig_ras <- raster(tring)
  plot(trig_ras)
  # con1 <- rasterToContour(trig_ras,levels = c(0.5,1,2,3,4,5,6,7,8,9,10))
  # 
  # plot(con1)
  # 
  # con1_sf <- st_as_sf(con1)
  # 
  
  return(trig_ras) 
}