.get.veg.module <- function(input_veg, 
                            outfolder,
                            start_date, end_date,
                            dbparms,
                            lat, lon, site_id, 
                            host, overwrite){

  #--------------------------------------------------------------------------------------------------#
  # Extract/load data : this step requires DB connections can't be handled by convert.inputs
  
  # which sources require load_data, temporary, need to extract from somewhereelse
  load_sources <- c("GapMacro", "NASA_FFT_Plot_Inventory", "NASA_TE_FIA")
  
  if(input_veg$source == "FIA"){
    
    veg_info <- extract_FIA(lon, lat, start_date, gridres = 0.075, dbparms)
    
  }else if(input_veg$source %in% load_sources){
    
    if(!is.null(input_veg$source.id)){
      source.id <- input_veg$source.id
    }else{
      logger.error("Must specify input source.id")
    }
    
    bety <- dplyr::src_postgres(dbname   = dbparms$bety$dbname, 
                                host     = dbparms$bety$host, 
                                user     = dbparms$bety$user, 
                                password = dbparms$bety$password)
    
    # query data.path from source id [input id in BETY]
    query      <- paste0("SELECT * FROM dbfiles where container_id = ", source.id)
    input_file <- db.query(query, con = bety$con)
    data_path  <- file.path(input_file[["file_path"]], input_file[["file_name"]])
    
    # query format info
    format <- query.format.vars(bety = bety, input.id = source.id)
    
    # a hack for now to have a similar structure as the FIA case
    veg_info      <- list() 
    veg_info[[1]] <- NULL   # the first sublist can be for the metadata maybe?
    veg_info[[2]] <- load_data(data.path = data_path, format)
                     
  }
  
  #--------------------------------------------------------------------------------------------------#
  # Match species : this step requires DB connections can't be handled by convert.inputs
  
  usda_sources <- c("GapMacro", "NASA_FFT_Plot_Inventory", "NASA_TE_FIA")
  
  # decide which code format to use while matching species
  # should we retrieve it from settings or assign a code format per source type?
  # or allow both?
  if(input_veg$source %in% usda_sources){
    format.name = 'usda'
  }else if(input_veg$source %in% c("FIA")){
    format.name = 'fia'      
  }else if(!is.null(input_veg$match.format)){
    format.name = input_veg$match.format
  }else{
    logger.error("Can't match code to species. No valid format found.")
  }
  
  # decide which column has the codes
  # this block may or may not be merged with the block above
  if(format.name == 'usda'){
    code.col = "species_USDA_symbol"
  }else if(format.name == 'fia'){
    code.col = "spcd"
  }else if(format.name == 'latin_name'){
    code.col = "latin_name"
  }
  
  obs <- veg_info[[2]]
  
  # match code to species ID
  spp.info <- match_species_id(input_codes = obs[[code.col]], format_name = format.name, bety = bety)
  
  # merge with data
  tmp <- spp.info[ , colnames(spp.info) != "input_code"]
  
  veg_info[[2]] <- cbind(obs, tmp)


  #--------------------------------------------------------------------------------------------------#
  # convert.inputs
  
  pkg <- "PEcAn.data.land"
  fcn <- "write_veg"
  con <- bety$con
  
  getveg.id <- convert.input(input.id = NA,
                          outfolder = outfolder, 
                          formatname = "spp.info", 
                          mimetype = "application/rds",
                          site.id = site_id, 
                          start_date = start_date, end_date = end_date, 
                          pkg = pkg, fcn = fcn, 
                          con = con, host = host, browndog = NULL, 
                          write = TRUE, 
                          overwrite = overwrite, 
                          # fcn specific args 
                          veg_info = veg_info)
  
  
  return(getveg.id)
  
}