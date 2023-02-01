library(reticulate)
library(shiny)
library(plotly)
library(DT)
library(tidyverse)
library(lubridate)
library(leaflet)

source("scripts/flopy_r.R")
source("scripts/head_functions2.R")
# Define UI for application 
#file size up to 1000MB
options(shiny.maxRequestSize = 1000*1024^2)

ui <- fluidPage(
  uiOutput('page_content')
)

server <- function(input, output, session) {
  output$page_content <- renderUI({
    tagList(
      titlePanel("RGW heads"),
      sidebarLayout(
        sidebarPanel(
          # radioButtons("radio", label = "Input type",
          #              choices = list("Single file" = 1,
          #                             "Up to 3 files" = 2,
          #                             "Upload file with addressess" = 3), 
          #              selected = 1),
          radioButtons("radio_time_unit", label = "time units",
                       choiceNames = c("time","SP","date"),
                       choiceValues	= c("time","SP","date"),
                       selected = "time"),
          # sliderInput("select_time", label = h3("Select time"), 
          #             min = 1, 
          #             max = 1, 
          #             value = 1,
          #             animate = T,
          #             step =1),
          numericInput("select_time", label = h3("Select time"), 
                      min = 1, 
                      max = 1, 
                      value = 1,
                                            step =1),
          # sliderInput("select_layer", label = h3("Select layer"), 
          #             min = 1, 
          #             max = 7, 
          #             value = 1),
          numericInput("select_layer", label = h3("Select layer"), 
                      min = 1, 
                      max = 7, 
                      value = 1),
          checkboxInput("contour_if", label = "Contours?", value = F),
          checkboxInput("lim_val", label = "limit values", value = F),
          numericInput("max_val",
                       label = "max_val:",
                       value = 502),
          numericInput("min_val",
                       label = "min_val:",
                       value = 489),
          numericInput("int_val",
                       label = "cont. interv.:",
                       value = 0.5),
          dateInput(inputId = "start_date",
                    label = "start time",
                    value = "2019-06-01",
                    weekstart = 1),
          fileInput("file1_ddn",
                    label = "Head, dradown or concentration file"),
          # fileInput("file2_shp",
          #           label = "obs shp file"),
          fileInput("file3_grd",
                    label = "gridgen grid file(.gpkg)"),
          numericInput("crs",
                       label = "EPSG:",
                       value = 28351),
          numericInput("nodenumber",
                       label = "node number:",
                       value = 1)
        ),
        mainPanel(
          #tableOutput("table2"),
          #downloadButton("download_data", label = "Download Data")
          leafletOutput("my_leaflet2"),
          # absolutePanel(bottom = 10, left = 10,
          #               verbatimTextOutput("clickInfo")),
          plotlyOutput('chart'),
          #dataTableOutput("table")
 
        )
      )  
    )})
  
  #data inputs
  
  #grid
  grid_shp_poly <- reactive({input$file3_grd$datapath}) 
  #crs
  crs1 <- reactive({as.numeric(input$crs)})
  
  #drd finename
  fn <- reactive({input$file1_ddn$datapath}) 
  L <- reactive({as.numeric(input$select_layer)}) 
  i <- 1
  
  #data for contours
  #stress period
  SP <- reactive({as.numeric(input$select_time)})
  
  #model layer

  #desired resolution of raster
  res_x <- 50 
  
  #data for hydrographs
  node_sel_fn <- reactive({input$file2_shp$datapath}) 
  bore_id_col <- "bore_id"
  
  #read in grid from shapefile generted with gridgen
  grid_sf_grid <- reactive({
    req(grid_shp_poly())
    read_ugrid(grid_shp_poly(),crs1())
    })
  
  grid_sf_grid_outline <- reactive({
    grid_sf_grid()[[2]] %>% 
      group_by() %>% 
      summarise(nodenumber = max(nodenumber)) %>% 
      st_transform(4326)
      })

  #read in drawdown binary file
  time_df <- reactive({
    get_times_u_df_date(fn()[i],
                        date_start = input$start_date)
      })
  
  n_times <- reactive({
    max(time_df()$n)})
  
  n_lay <- reactive({max(grid_sf_grid()[[1]]$layer)})
  
  #extract head from file
  h_matr <- reactive({
    req(fn()[i])
    get_con_u(fn()[i])})
  
  #check for file type - quadtree or octree
  
  h_type <- reactive({
    req(fn()[i])
    if (typeof(h_matr()) == "double"){
     "quadtree"
     } else if (typeof(h_matr()) == "list"){
       "octree"
      }
    
    
  })

   #trig_ras <- reactive({get_head_raster(grid_sf_pt_grid(),h_matr(),SP(),L,res_x,crs1())})
  poly_map <- reactive({get_head_poly(grid_sf_grid(),
                                      h_matr(),
                                      SP(),
                                      L(),
                                      crs1())})
  
  
  
  head_map_poly <- reactive({poly_map()[[2]]  %>% 
      st_transform(4326)})
  
  head_map_pt <- reactive({poly_map()[[1]]})
  
  head_ras <-  reactive({get_ras_f(head_map_pt(),100,500,crs1())
    })

   
  head_con <- reactive({
    
    req(input$contour_if == T,
        head_ras(),
        input$min_val,
        input$max_val,
        input$int_val,
        input$min_val <= input$max_val,
        input$int_val <= input$max_val - input$min_val,
        input$int_val > 0,
        cancelOutput = T
    )
    
    
    from1 <- as.numeric(input$min_val)
    to1 <- as.numeric(input$max_val)
    by1 <- as.numeric(input$int_val)
    
    con_f(head_ras(), 
          as.vector(seq(from = from1, 
                        to = to1,
                        by = by1)),  
          28351)
  })  
  

  
  lf_map2 <- reactive({
    
    leaflet() %>% 
      addTiles((urlTemplate = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}') ) %>%
      addMapPane(name = "outline", zIndex = 420) %>% 
      addMapPane(name = "contours", zIndex = 420) %>% 
      addMapPane(name = "grid_head_pane", zIndex = 420) %>% 
      addPolygons(group = "outline",
                  data=grid_sf_grid_outline(),
                  opacity = 1,
                  fillOpacity = 0,
                  stroke = T,
                  color = "red",
                  options = leafletOptions(pane = "outline")) 

  })
 
  domain_pal <- reactive({
    if(input$lim_val == F){
      head_map_poly()$h
    }else{ c(input$min_val,input$max_val)}
    
  })
  
  
  colorpal <- reactive({colorNumeric(
    palette = "Spectral",
    domain = domain_pal())})
  
 # update a map 
#contour map
  observe({
    req(head_con(),
        cancelOutput = T
        )
    
    

    
    proxy <- leafletProxy("my_leaflet2")
    proxy %>%
      clearGroup(group = "contours") %>%
      addPolylines(group = "contours",
                   data = head_con(),
                   opacity = 0.5,
                   fillOpacity = 0.5,
                   stroke = T,
                   options = leafletOptions(pane = "contours"))
    
    
    
    
       })
  #poly map
  observe({
    req(input$file1_ddn,
        input$file3_grd)
    pal <- colorpal()
      proxy <- leafletProxy("my_leaflet2")
      proxy %>%
        clearGroup(group = "grid_head") %>%
        addPolygons(group = "grid_head",
                    data=head_map_poly(),
                    opacity = 1,
                    fillOpacity = 0.5,
                    fillColor = ~pal(h),
                    stroke = F,
                    options = leafletOptions(pane = "grid_head_pane"),
                    layerId = ~nodenumber,
                    label = ~round(h,2))# %>%
      #addLegend(layerId = "legend2",
      #          title = "head/drawdown",
      #          pal = pal,
      #          values= vals )
  })
  
  # observe({
  #   req(input$file1_ddn)
  #   pal <- colorpal()
  #     proxy <- leafletProxy("my_leaflet2")
  #     proxy %>%
  #       clearGroup(group = "grid_head") %>%
  #       clearGroup(group = "contours") %>%
  #       addPolylines(group = "contours",
  #                    data = head_con(),
  #                    opacity = 0.5,
  #                    fillOpacity = 0.5,
  #                    stroke = T,
  #                    options = leafletOptions(pane = "contours")) %>%
  #       addPolygons(group = "grid_head",
  #                   data=head_map_poly(),
  #                   opacity = 1,
  #                   fillOpacity = 0.5,
  #                   fillColor = ~pal(h),
  #                   stroke = F,
  #                   options = leafletOptions(pane = "grid_head_pane"),
  #                   layerId = ~nodenumber,
  #                   label = ~round(h,2))# %>%
  #     #addLegend(layerId = "legend2",
  #     #          title = "head/drawdown",
  #     #          pal = pal,
  #     #          values= vals )
  # })
  
     output$my_leaflet2 <- renderLeaflet(lf_map2())

  observe({
    #if(input$pump_in_type == "single point"){
      
      click <- input$my_leaflet2_shape_click
      req(click)
      node_num <- as.numeric(str_extract(click$id,"[0-9]+"))
      output$clickInfo <- renderPrint(click)
   updateNumericInput(session,
                      inputId = "nodenumber",
                      label = "Easting:",
                      value = node_num
   )
  })
  
  
  observe( {
    if(is.null(fn())){
      return()
      }else{
        max = n_times()
        updateSliderInput(session, "select_time", max=max)
      }
    
  })
  
  
  observe( {
    if(is.null(node_sel_fn())){
      return()
    }else{
      layer = n_lay()
      updateSliderInput(session, "select_layer", max=layer)
    }
    
  })
  
  
  
  #node_sel_sf <- reactive({st_read(node_sel_fn())})
  node <- reactive({
    as.numeric(input$nodenumber)
    # click1 <- input$my_leaflet2_shape_click
    # input$my_leaflet_shape_click
    # if(is.null(click1))
    # return()
    # as.numeric(str_extract(click1$id,"[0-9]+"))
    })

  #n_nodes <- 127587
  head_flat <- reactive({
    req(fn()[i])
    if (h_type() == "quadtree"){
      flatten_head_quadtree(h_matr())
    } else if (h_type() == "octree"){
      flatten_head_octree(h_matr())
    }
    })


  df_sel_hydr <-  reactive({get_hydr(head_flat(),node(),node(),time_df())})
  
  #output$table <- renderDataTable(df_sel_hydr())
  #output$table2 <- renderTable(df_sel_hydr)
  
  
  char_head <- reactive({df_sel_hydr() %>% ggplot( aes(.data[[input$radio_time_unit]], value,col = name))+
     geom_line()})#+
  #expand_limits(y =0)+
  #facet_grid( sim ~ bore )
  #char_head
  output$chart <- renderPlotly({ggplotly(char_head(),dynamicTicks =T)})
  
}

shinyApp(ui = ui, server = server)
