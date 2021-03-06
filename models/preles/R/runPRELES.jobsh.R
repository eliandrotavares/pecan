#-------------------------------------------------------------------------------
# Copyright (c) 2012 University of Illinois, NCSA.
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the 
# University of Illinois/NCSA Open Source License
# which accompanies this distribution, and is available at
# http://opensource.ncsa.illinois.edu/license.html
#-------------------------------------------------------------------------------

#--------------------------------------------------------------------------------------------------#
##' @title Function to process ncdf file, run PRELES model, and convert output .nc file in CF standard
##' @param in.path location on disk where inputs are stored
##' @param in.prefix prefix of input and output files
##' @param outdir Location of PRELES model output
##' @param start_date Start time of the simulation
##' @param end_date End time of the simulation
##' @export 
##' @author Tony Gardella, Michael Dietze
##' @importFrom ncdf4 ncvar_get ncvar_def
runPRELES.jobsh <- function(met.file, outdir, parameters, sitelat, sitelon, start.date, end.date) {
  
  library(PEcAn.data.atmosphere)
  library(PEcAn.utils)
  library(Rpreles)
  
  # Process start and end dates
  start_date <- as.POSIXlt(start.date, tz = "UTC")
  end_date <- as.POSIXlt(end.date, tz = "UTC")
  
  start_year <- lubridate::year(start_date)
  end_year <- lubridate::year(end_date)
  
  timestep.s <- 86400  # Number of seconds in a day
  
  ## Build met
  met <- NULL
  for (year in start_year:end_year) {
    
    met.file.y <- paste(met.file, year, "nc", sep = ".")
    
    if (file.exists(met.file.y)) {
      
      ## Open netcdf file
      nc <- ncdf4::nc_open(met.file.y)
      
      ## convert time to seconds
      sec <- nc$dim$time$vals
      sec <- udunits2::ud.convert(sec, unlist(strsplit(nc$dim$time$units, " "))[1], "seconds")
      
      ## build day and year
      
      dt <- ifelse(lubridate::leap_year(year) == TRUE, 
                   366 * 24 * 60 * 60 / length(sec), # leap year
                   365 * 24 * 60 * 60 / length(sec)) # non-leap year
      tstep <- round(timestep.s / dt)  #time steps per day
      
      doy <- rep(1:365, each = tstep)[1:length(sec)]
      if (year %% 4 == 0) {
        ## is leap
        doy <- rep(1:366, each = tstep)[1:length(sec)]
      }
      
      ## Get variables from netcdf file
      SW     <- ncvar_get(nc, "surface_downwelling_shortwave_flux_in_air")  # SW in W/m2
      Tair   <- ncvar_get(nc, "air_temperature")  # air temperature in K
      Precip <- ncvar_get(nc, "precipitation_flux")  # precipitation in kg/m2s1
      CO2    <- try(ncvar_get(nc, "mole_fraction_of_carbon_dioxide_in_air"))  # mol/mol
      SH     <- ncvar_get(nc, "specific_humidity")
      lat    <- ncvar_get(nc, "latitude")
      lon    <- ncvar_get(nc, "longitude")
      
      ncdf4::nc_close(nc)
      
      ## Check for CO2 and PAR
      if (!is.numeric(CO2)) {
        logger.warn("CO2 not found. Setting to default: 4.0e+8 mol/mol")  # using rough estimate of atmospheric CO2 levels
        CO2 <- rep(4e+08, length(Precip))
      }
      
      ## GET VPD from Saturated humidity and Air Temperature
      RH <- qair2rh(SH, Tair)
      VPD <- get.vpd(RH, Tair)
      
      VPD <- VPD * 0.01  # convert to Pascal
      
      ## Get PPFD from SW
      PPFD <- sw2ppfd(SW)  # PPFD in umol/m2/s
      PPFD <- PPFD * 1e-06  # convert umol to mol
      
      ## Format/convert inputs
      ppfd   <- tapply(PPFD, doy, mean, na.rm = TRUE)  # Find the mean for the day
      tair   <- udunits2::ud.convert(tapply(Tair, doy, mean, na.rm = TRUE), "kelvin", "celsius")  # Convert Kelvin to Celcius
      vpd    <- udunits2::ud.convert(tapply(VPD, doy, mean, na.rm = TRUE), "Pa", "kPa")  # pascal to kila pascal
      precip <- tapply(Precip, doy, sum, na.rm = TRUE)  # Sum to daily precipitation
      co2    <- tapply(CO2, doy, mean)  # need daily average, so sum up day
      co2    <- co2 / 1e+06  # convert to ppm
      doy    <- tapply(doy, doy, mean)  # day of year
      fapar  <- rep(0.6, length = length(doy))  # For now set to 0.6. Needs to be between 0-1
      
      ## Bind inputs
      tmp <- cbind(ppfd, tair, vpd, precip, co2, fapar)
      tmp[is.na(tmp)] <- 0
      met <- rbind(met, tmp)
    }  ## end file exists
  }  ## end met process
  
  param.def <- rep(NA, 30)
  
  #PARAMETER DEFAULT LIST
  ##GPP_MODEL_PARAMETERS  
  #1.soildepth 413.0    |2.ThetaFC 0.450      | 3.ThetaPWP 0.118        |4.tauDrainage 3 
  #5.betaGPP 0.748018   |6.tauGPP 13.23383    |7.S0GPP -3.9657867       |8.SmaxGPP 18.76696
  #9.kappaGPP -0.130473 |10.gammaGPP 0.034459 |11.soilthresGPP 0.450828 |12.cmCO2 2000 
  #13.ckappaCO2 0.4      
  ##EVAPOTRANSPIRATION_PARAMETERS               
  #14.betaET  0.324463  |15.kappaET 0.874151  |16.chiET 0.075601        |17.soilthresE 0.541605   
  #18.nu ET 0.273584
  ##SNOW_RAIN_PARAMETERS
  #19.Meltcoef 1.2      |20.I_0 0.33          |21.CWmax 4.970496        |22.SnowThreshold 0     
  #23.T_0 0           
  ##START INITIALISATION PARAMETERS                
  #24.SWinit 200        |25.CWinit 0          |26.SOGinit 0             |27.Sinit 20
  #28.t0 fPheno_start_date_Tsum_accumulation; conif -999, for birch 57
  #29.tcrit -999 fPheno_start_date_Tsum_Tthreshold, 1.5 birch
  #30.tsumcrit -999 fPheno_budburst_Tsum, 134 birch
  
  ## Replace default with sampled parameters
  load(parameters)
  params <- data.frame(trait.values)
  colnames <- c(names(trait.values[[1]]))
  colnames(params) <- colnames
  
  param.def[5] <- as.numeric(params["bGPP"])
  param.def[9] <- as.numeric(params["kGPP"])
  
  ## Run PRELES
  PRELES.output <- as.data.frame(PRELES(PAR = tmp[, "ppfd"], 
                                        TAir = tmp[, "tair"], 
                                        VPD = tmp[, "vpd"], 
                                        Precip = tmp[, "precip"], 
                                        CO2 = tmp[, "co2"], 
                                        fAPAR = tmp[, "fapar"],
                                        p = param.def))
  PRELES.output.dims <- dim(PRELES.output)
  
  days <- as.Date(start_date):as.Date(end_date)
  year <- strftime(as.Date(days, origin = "1970-01-01"), "%Y")
  years <- unique(year)
  num.years <- length(years)
  
  for (y in years) {
    if (file.exists(file.path(outdir, paste(y)))) 
      next
    print(paste("----Processing year: ", y))
    
    sub.PRELES.output <- subset(PRELES.output, years == y)
    sub.PRELES.output.dims <- dim(sub.PRELES.output)
    
    output <- list()
    output[[1]] <- (sub.PRELES.output[, 1] * 0.001)/timestep.s  #GPP - gC/m2day to kgC/m2s1
    output[[2]] <- (sub.PRELES.output[, 2])/timestep.s  #Evapotranspiration - mm =kg/m2
    output[[3]] <- (sub.PRELES.output[, 3])/timestep.s  #Soilmoisture - mm = kg/m2
    output[[4]] <- (sub.PRELES.output[, 4])/timestep.s  #fWE modifier - just a modifier
    output[[5]] <- (sub.PRELES.output[, 5])/timestep.s  #fW modifier - just a modifier
    output[[6]] <- (sub.PRELES.output[, 6])/timestep.s  #Evaporation - mm = kg/m2 
    output[[7]] <- (sub.PRELES.output[, 7])/timestep.s  #transpiration - mm = kg/m2
    
    t <- ncdf4::ncdim_def(name = "time",
                   units = paste0("days since", y, "-01-01 00:00:00"), 
                   vals = 1:nrow(sub.PRELES.output), 
                   calendar = "standard", 
                   unlim = TRUE)
    
    lat <- ncdf4::ncdim_def("lat", "degrees_east", vals = as.numeric(sitelat), longname = "station_longitude")
    lon <- ncdf4::ncdim_def("lat", "degrees_north", vals = as.numeric(sitelon), longname = "station_longitude")
    
    for (i in seq_along(output)) {
      if (length(output[[i]]) == 0) 
        output[[i]] <- rep(-999, length(t$vals))
    }
    
    var      <- list()
    var[[1]] <- mstmipvar("GPP", lat, lon, t, NA)
    var[[2]] <- ncvar_def("Evapotranspiration", "kg/m2s1", list(lon, lat, t), -999)
    var[[3]] <- ncvar_def("SoilMoist", "kg/m2s1", list(lat, lon, t), NA)
    var[[4]] <- ncvar_def("fWE", "NA", list(lon, lat, t), -999)
    var[[5]] <- ncvar_def("fW", "NA", list(lon, lat, t), -999)
    var[[6]] <- ncvar_def("Evap", "kg/m2/s", list(lon, lat, t), -999)
    var[[7]] <- ncvar_def("TVeg", "kg/m2/s", list(lat, lon, t), NA)
    
    nc <- ncdf4::nc_create(file.path(outdir, paste(y, "nc", sep = ".")), var)
    varfile <- file(file.path(outdir, paste(y, "nc", "var", sep = ".")), "w")
    for (i in seq_along(var)) {
      ncdf4::ncvar_put(nc, var[[i]], output[[i]])
      cat(paste(var[[i]]$name, var[[i]]$longname), file = varfile, sep = "\n")
    }
    close(varfile)
    ncdf4::nc_close(nc)
  }
} # runPRELES.jobsh
