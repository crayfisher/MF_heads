#source python
library(reticulate)
library(tidyverse)
library(lubridate)
source_python("scripts/flopy_r.py")

get_lst <- function(file)  {
  df <- as_tibble(get_lst_py(file)) %>% 
    mutate(kstp = kstp + 1,
           kper = kper +1,
           time = parse_date_time(time,"ymd HMS"),
           time_kstp =ifelse(row_number()==1,totim,  totim - lag(totim))) %>% 
    select(kper,kstp,totim,time_kstp,time,everything()) 

  return(df)}


#fn <- "D:/Pawel/modelling/RES2021/LY_RES2021_v2/mf/run/mf_cal.hds"
#test5 <- get_times_u_df(fn)
