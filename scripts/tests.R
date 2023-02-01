fn <- "D:/Pawel/modelling/RES2021/LY_RES2021_v4/mf/run_0.5_rch_sp1_20yr/mf_out/mf_cal.hds"

time_df <- get_times_u_df(fn)

hd_obj <- get_con_u(fn)

hd_obj2 <- flatten_head_octree(hd_obj)

hd_obj3 <- get_hydr_octree(hd_obj2,1000,1000,time_df)

hd_obj4 <- bind_cols(hd_obj3,time_df) %>% 
 dplyr:: select(-n)
