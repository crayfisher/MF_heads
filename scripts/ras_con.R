
df <- grid_sf_pt_grid_h
res1 <- 10
res <- 500

#convert df results for L, SP to raster
#res1 resolution for raster
#number of cell in each dimention for contouring
get_ras_f <- function(df,res,res1){
  
  ugri_pt <- df %>% 
    filter(h != 999) %>% 
    dplyr::select(h)
  #crs1 <- st_crs(ugri_pt)$proj4string
  ext1 <- extent(ugri_pt)
  
  ras1 <- raster(ext1,resolution = res1)
  #crs(ras1) <- crs1
  ras1_pt <- rasterToPoints(ras1,spatial=T)
  
  ugri_pt_sp <- ugri_pt #%>% 
  #  dplyr::select(WL)
  
  ugri_pt_sp <- as(ugri_pt_sp,"Spatial")
  #plot(ugri_pt_sp)
  
  tring <- interp(x = ugri_pt_sp,y = NULL,z = "h",ny = res,nx = res)
  
  trig_ras <- raster(tring)
  #plot(trig_ras)
  return(trig_ras) 
}
ras_tes <- get_ras_f(grid_sf_pt_grid_h,500,100,28351)
plot(ras_tes)

#convert to contours
con_f <- function(raster_1,levels_1,crs_1
                  ,file_name = "contour.shp"
){
  con1 <- rasterToContour(raster_1,levels = levels_1)
  con1_sf <- st_as_sf(con1) %>% st_set_crs(crs_1) #%>% 
  #st_intersection(domain)
  st_write(con1_sf,file_name,delete_dsn=TRUE )
  return(con1_sf)
}
test_con_sf <- con_f(ras_tes,seq(489,510,0.5),28351) %>% 
  st_transform(4326)
tmap_mode("view")
qtm(test_con_sf)


leaflet() %>% 
  addTiles((urlTemplate = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}') ) %>%
  addMapPane(name = "outline", zIndex = 420) %>% 
  #addMapPane(name = "grid_head_pane", zIndex = 420) %>% 
  addPolylines(group = "outline",
               data = test_con_sf,
               opacity = 0.5,
               fillOpacity = 0.5,
               stroke = T,
               options = leafletOptions(pane = "outline")) 




# domiain_sf <- st_read("D:/Pawel/modelling/RES2021/LY_RES2021_v2/IN/shp/domain/domain.shp")
# con_test <- con_f(ras_tes,seq(489,520,1),"cont.shp",28351,domiain_sf)
# plot(con_test)
