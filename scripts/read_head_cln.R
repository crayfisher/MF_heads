#sub function for one TS and layer for cln
read_mf_real_ug_cln1 <- function(fn) {
  KSTP <- readBin(fn, "integer", size=4)
  KPER <- readBin(fn, "integer", size=4)
  PERTIM <- readBin(fn, "numeric", size=4)
  TOTIM <- readBin(fn, "numeric", size=4)
  TEXT <- readChar(fn, nchars=16, useBytes=TRUE)
  NSTRT <- readBin(fn, "integer", size=4)
  NNDLAY <- readBin(fn, "integer", size=4)
  ILAY <- readBin(fn, "integer", size=4)
  #n_nodes <- NNDLAY - NSTRT+1 
  n_nodes <- NSTRT - NNDLAY + 1 #for cln this has to reveresed due to error in cln binary file header
  # Data
  data <- matrix(
    readBin(fn, "numeric", n = n_nodes, size=4),
    nrow= n_nodes, ncol=1, byrow=TRUE)
  # Attach the attributes
  attr(data, "kstp") <- KSTP
  attr(data, "kper") <- KPER
  attr(data, "pertim") <- PERTIM
  attr(data, "totim") <- TOTIM
  attr(data, "text") <- gsub("^\\s+|\\s+$", "", TEXT, perl=TRUE)
  attr(data, "ilay") <- ILAY
  data1 <- list(data,KSTP,KPER,PERTIM,TOTIM,TEXT,NSTRT,NNDLAY,ILAY,n_nodes)  
  
}

read_mf_real_ug_cln1_content_all <- function(file2){
  counter_size <- 0
  i <- 0
  
  file3 <- file(file2, "rb")
  on.exit(close(file3))
  size_file = file.size(file2)
  while( counter_size < size_file){
    i <- i+1
    
    data1 <- read_mf_real_ug_cln1(file3)
    TOTIM <- data1[[5]]
    KSTP <- data1[[2]]
    KPER <- data1[[3]]
    nodesL <- data1[[10]]
    L <- data1[[9]]
    data_df <- tibble(TOTIM = TOTIM,
                      KPER = KPER,
                      KSTP = KSTP,
                      L=L,
                      nodesL = nodesL)
    if(i == 1){data_comb <- data_df}else{data_comb <- bind_rows(data_comb,data_df)}
    
    data_length <- 7*4 + 1*16 + length(data)*4
    counter_size <- counter_size + data_length
  }
  return(data_comb)
}


#function for all layers SP and TS
read_mf_real_ug_cln1_all <- function(file2){
  counter_size <- 0
  i <- 0
  
  
  
  
  file3 <- file(file2, "rb")
  on.exit(close(file3))
  size_file = file.size(file2)
  
  #if(i == 1){data_comb <- data_df}else{data_comb <- bind_rows(data_comb,data_df)}
  
  while( counter_size < size_file){
    i <- i+1
    
    data1 <- read_mf_real_ug_cln1(file3)
    data <- data1[[1]]
    TOTIM <- data1[[5]]
    KSTP <- data1[[2]]
    KPER <- data1[[3]]
    nodesL <- data1[[10]]
    L <- data1[[9]]
    data_df <- tibble(WL = data) %>% 
      mutate(TOTIM = TOTIM,
             KPER = KPER,
             KSTP = KSTP,
             L=L) %>% 
      mutate(node = row_number())
    #section below doesnt work as expected, only number corrctly L1 and 2, furthr layers are numbers as L2
    # max_node <- max(data_df %>% pull(node))
    # 
    # if ( L !=1){data_df <-  data_df %>% 
    #   mutate(node = max_node + node)}
    
    if(i == 1){data_comb <- data_df}else{data_comb <- bind_rows(data_comb,data_df)}
    
    data_length <- 7*4 + 1*16 + length(data)*4
    counter_size <- counter_size + data_length
    
    
    
    
  }
  #this is a fix to layer numbering
  
  nodes <- data_comb %>% 
    distinct(L,node) %>% 
    group_by(L) %>% 
    summarise(max_node = max(node)) %>% 
    mutate(cum_node = cumsum(max_node)) 
  
  
  data_comb <- data_comb %>% 
    left_join(nodes) %>% 
    mutate(node = node + cum_node - max_node) %>% 
    dplyr::select(-cum_node, - max_node)
  
  return(data_comb)
}
