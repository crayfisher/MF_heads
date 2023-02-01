library(raster)
library(interp)
library(tmap)
library(sf)
#crs
#crs1 <- 28351

#read in grid from shapefile generted with gridgen
#grid_shp_poly <- "D:/Pawel/R/RGWheads/data/qtgrid.shp"

#grid_shp_point <- "D:/Pawel/R/RGWheads/data/qtgrid_pt.shp"
read_ugrid <-function(fn,crs1){
  grid_sf_poly <- st_read(fn) %>% 
    mutate(layer = layer +1) %>% 
    st_set_crs(crs1)
  
  grid_sf_pt <- grid_sf_poly %>% st_centroid()
  
  nodes_per_layer <- grid_sf_pt %>% 
    as_tibble() %>% 
    count(layer) %>% 
    rename(nodes_per_layer = n) %>% 
    mutate(nodes_per_layer_cum = cumsum(nodes_per_layer)-nodes_per_layer )  
  
  grid_sf_pt_grid <- grid_sf_pt %>% 
    left_join(nodes_per_layer) %>% 
    mutate(nodenumberL1 = nodenumber - nodes_per_layer_cum ) %>% 
    mutate(layerId = nodenumber)#%>% 
    #dplyr::select(-nodes_per_layer_cum,-nodes_per_layer, -row,-col,-child_loca,-delr, -delc )
  
  grid_sf_poly_grid <- grid_sf_poly %>% 
    left_join(nodes_per_layer) %>% 
    mutate(nodenumberL1 = nodenumber - nodes_per_layer_cum ) %>% 
    mutate(layerId = nodenumber) #%>% 
    #dplyr::select(-nodes_per_layer_cum,-nodes_per_layer, -row,-col,-child_loca,-delr, -delc )
  
  return(list(grid_sf_pt_grid,grid_sf_poly_grid))
}

#grid_sf_pt_grid <- read_ugrid(grid_shp_poly,crs1)[[1]]

#read in drawdown binary file
# fn <-    "D:/Pawel/R/RGWheads/data/mf.ddn"
# i <- 1
# h_matr <- get_drd(fn[i])


# #filter array
# SP <- 30
# L <- 1
# res_x <- 10 #desired resolution of raster


get_head_poly <- function(grid_obj,head_obj,SP,L,crs1){
  
  #if (typeof(head_obj) == "double"){
    #drd_SP_L <- head_obj[SP,L,]
 # } else if (typeof(head_obj) == "list"){
  #  drd_SP_L <- unlist(head_obj[SP,L])
  drd_SP_L <- head_obj[SP,L][[1]]
    
 # }
  
  
  grid_sf_pt_grid_h <- grid_obj[[1]] %>% 
    dplyr::filter(layer == L) %>% 
    mutate(h = drd_SP_L)
  #grd_test <- grid_obj[[2]]
  grid_sf_poly_grid_h <- grid_obj[[2]] %>% 
    dplyr::filter(layer == L) %>% 
    mutate(h = drd_SP_L)
  
  return(list(grid_sf_pt_grid_h,grid_sf_poly_grid_h))
  
}

get_head_raster2 <- function(grid_sf_pt_grid_h,
                             Rnrow = 500,
                             Rncol = 500,
                             crs1){
  res_y <- res_x
  
  
  ext1 <- extent(grid_sf_pt_grid_h)
  
  ugri_pt_sp <- grid_sf_pt_grid_h %>% 
    dplyr::select(h)
  
  ugri_pt_sp <- as(ugri_pt_sp,"Spatial")
  #plot(ugri_pt_sp)
  
  #get raster dimenstions form extent
  ras_x <- ext1[2] - ext1[1]
  ras_y <- ext1[4] - ext1[3]
  
  #calc no or rows and columsn
  #there is an issue with intertp packge for some resolutions, seems to be random, but gereraly higher resoltions
  #Rnrow <- ceiling(ras_y/res_y)
  #Rncol <- ceiling(ras_x/res_x)

  #interpolate values
  tring <- interp::interp(x = ugri_pt_sp,y = NULL,z = "h",ny = Rnrow,nx = Rncol)
  
  #convert interpolated values to raSTER
  trig_ras <- raster(tring)
  
  #asingn crs
  css1_str <- st_crs(crs1)$proj4string
  crs(trig_ras) <- css1_str

  
  return(trig_ras)
  }


get_head_raster <- function(grid_obj,head_obj,SP,L,res_x,crs1){
  res_y <- res_x
  
 if (typeof(head_obj) == "double"){
   drd_SP_L <- head_obj[SP,L,]
 } else if (typeof(head_obj) == "list"){
   drd_SP_L <- head_obj[SP,L]
 }
  
  
  grid_sf_pt_grid_h <- grid_obj %>% 
    dplyr::filter(layer == L) %>% 
    mutate(h = drd_SP_L)
  
  ext1 <- extent(grid_sf_pt_grid_h)
  
  ugri_pt_sp <- grid_sf_pt_grid_h %>% 
    dplyr::select(h)
  
  ugri_pt_sp <- as(ugri_pt_sp,"Spatial")
  #plot(ugri_pt_sp)
  
  #get raster dimenstions form extent
  ras_x <- ext1[2] - ext1[1]
  ras_y <- ext1[4] - ext1[3]
  
  #calc no or rows and columsn
  Rnrow <- ceiling(ras_y/res_y)
  Rncol <- ceiling(ras_x/res_x)
  
  #interpolate values
  tring <- interp::interp(x = ugri_pt_sp,y = NULL,z = "h",ny = Rnrow,nx = Rncol)
  
  #convert interpolated values to raSTER
  trig_ras <- raster(tring)
  
  #asingn crs
  css1_str <- st_crs(crs1)$proj4string
  crs(trig_ras) <- css1_str
  return(trig_ras)
}
# trig_ras <- get_head_raster(grid_sf_pt_grid,SP,L,res_x,crs1)
# 
 #plot(trig_ras)


get_hydrograph <- function(node_sel_sf,
                           grid_sf_poly_grid,
                           bore_id_col,
                           h_matr,L,time_list){
  #node_sel_sf <- st_read(node_sel_fn)
  
  node_sel_sf_grid <- node_sel_sf %>%
    st_join(grid_sf_poly_grid) %>%
    dplyr::filter(layer == L)
  
  node_sel_no <- node_sel_sf_grid %>% 
    pull(nodenumber)
  
  bores_nm <- node_sel_sf_grid %>% 
    pull(!!bore_id_col)
  
  drd_node <- h_matr[,L,node_sel_no]
  
  
  
  df0 <- as_tibble(drd_node) %>% 
    rename_all(~ bores_nm) %>% 
    mutate(time = time_list[[1]],
           sp = time_list[[2]],
           ts = time_list[[3]]) %>% 
    pivot_longer(cols = -c(time,sp,ts),names_to = "bore",values_to = "head") 
  return(df0)
}

get_times <- function(fn){
  t_ts_sp <- get_drd_times(fn)
  times <- t_ts_sp[,1]
  sp <- t_ts_sp[,3]+1
  ts <- t_ts_sp[,2]+1
  times2 <- parse_date_time("1/6/2019","dmy")+days(times)
  time_list <- list(times2,sp,ts)
  return(time_list)
}


#function to flatten head matrix for octree grid
#this is needed to get hydrographs by node number
flatten_head_octree <- function(head_obj){
  dim_list <- dim(head_obj)
  nSP <- dim_list[1]
  nL <- dim_list[2]
  
  
  for (spi in 1:nSP){
    head_comb <- NULL
    for (Li in 1:nL){
      head_i <- head_obj[spi,Li][[1]]
      head_comb <- c(head_comb,head_i)
    }
    if(spi == 1){
      nnodes <- length(head_comb)
      head_comb0 <- array(dim = c(nSP,nnodes))
    }
    head_comb0[spi,] <- head_comb
  }
  return(head_comb0)
}

#head_comb0 <- flatten_head_octree(head_obj)

#funtion to extract a hydrograph for octree grid, from flattened head matrix
get_hydr_octree <- function(head_comb0,node_list,ID_list,time_df){
  df_hydr <- head_comb0[,node_list] %>% 
    as_tibble()
  
  colnames(df_hydr) <- ID_list 
  
  df_hydr <- df_hydr %>% 
   
    bind_cols(time_df) %>% 
    pivot_longer(cols = -c(time,    SP,    TS,     n)) 
    

  return(df_hydr)
  
}
#df_hydr <- get_hydr_octree(head_comb0,node_list,ID_list)

#convert df results for L, SP to raster
#res1 resolution for raster
#number of cell in each dimention for contouring
get_ras_f <- function(df,res,res1,crs_1){
  
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
  crs_1_str <- st_crs(crs_1)$proj4string
  crs(trig_ras) <- crs_1_str
  #plot(trig_ras)
  return(trig_ras) 
}



#convert to contours
con_f <- function(raster_1,levels_1,crs_1
                  #,domain,file_name = "contour.shp"
                  ){
  con1 <- rasterToContour(raster_1,levels = levels_1)
  con1_sf <- st_as_sf(con1) %>% st_set_crs(crs_1) %>% 
    st_transform(4326)#%>% 
    #st_intersection(domain)
  #st_write(con1_sf,file_name,delete_dsn=TRUE )
  return(con1_sf)
}
