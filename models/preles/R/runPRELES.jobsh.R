#-------------------------------------------------------------------------------
# Copyright (c) 2012 NCSA.
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

runPRELES.jobsh<- function(met.file,outdir,parameters,start.date,end.date){
  
  require("PEcAn.data.atmosphere")
  require("PEcAn.utils")
  require("ncdf4")
  if(!require("Rpreles")) print("install Rpreles")
  require("udunits2")

  ## Open netcdf file
  nc=nc_open(met.file)
  
  #Process start and end dates
  start_date<-as.POSIXlt(start.date,tz="GMT")
  end_date<-as.POSIXlt(end.date,tz="GMT")
  
  days=as.Date(start_date):as.Date(end_date)
  year = strftime(as.Date(days,origin="1970-01-01"),"%Y")
  years<-unique(year)
  num.years<- length(years)
  timestep.s<-86400
  
  ## convert time to seconds
  sec   <- nc$dim$time$vals  
  sec = udunits2::ud.convert(sec,unlist(strsplit(nc$dim$time$units," "))[1],"seconds")
  
  ##build day and  year
  ifelse(leap_year(as.numeric(year))==TRUE,
         dt <- (366*24*60*60)/length(sec), #leap year
         dt <- (365*24*60*60)/length(sec)) #non-leap year
  tstep = 86400/dt
  
  doy <- rep(1:365,each=86400/dt)
  if(as.numeric(year) %% 4 == 0){  ## is leap
    doy <- rep(1:366,each=86400/dt)
  }
  
  ## Get variables from netcdf file
  ## Get variables from netcdf file
  PAR <-ncvar_get(nc,"surface_downwelling_photosynthetic_photon_flux_in_air") #PAR in mol/m2s1
  Tair <-ncvar_get(nc,"air_temperature")#air temperature in K
  Precip <-ncvar_get(nc,"precipitation_flux")#precipitation in kg/m2s1
  CO2 <-ncvar_get(nc,"mole_fraction_of_carbon_dioxide_in_air") #mol/mol
  SH <- ncvar_get(nc,"specific_humidity")
  lat<-ncvar_get(nc,"latitude")
  lon<-ncvar_get(nc,"longitude")
  
  ## GET VPD from calculateing Relative Humidity
  RH = qair2rh(SH,Tair)
  VPD= get.vpd(RH,Tair)
  
  VPD = VPD * .01 # convert to Pascal
  
  ## Format/convert inputs 
  PAR= tapply(PAR, doy,mean,na.rm=TRUE) #Find the mean for the day
  TAir=ud.convert(tapply(Tair,doy,mean,na.rm=TRUE),"kelvin", "celsius")#Convert Kelvin to Celcius
  VPD= ud.convert(tapply(VPD,doy,mean,na.rm=TRUE), "Pa","kPa")#pascal to kila pascal
  Precip=tapply(Precip,doy,sum, na.rm=TRUE) #Sum to daily precipitation
  CO2= tapply(CO2,doy,mean) #need daily average, so sum up day
  CO2= CO2/1e6
  doy=tapply(doy,doy,mean) # day of year
  fAPAR =rep (0.6,length=length(doy)) #For now set to 0.6. Needs to be between 0-1
  
  ##Bind inputs 
  tmp<-cbind (PAR,TAir,VPD,Precip,CO2,fAPAR)
  param.table = c(413.0, ## 1 soildepth |
                  0.450, ## 2 ThetaFC
                  0.118, ## 3 ThetaPWP
                  3, ## 4 tauDrainage
                  ## GPP_MODEL_PARAMETERS
                  0.748018, ## 5 betaGPP
                  13.23383, ## 6 tauGPP
                  -3.9657867, ## 7 S0GPP
                  18.76696, ## 8 SmaxGPP
                  -0.130473, ## 9 kappaGPP
                  0.034459, ## 10 gammaGPP
                  0.450828, ## 11 soilthresGPP
                  2000, ## 12 cmCO2
                  0.4, ## 13 ckappaCO2
                  ## EVAPOTRANSPIRATION_PARAMETERS
                  0.324463, ## 14 betaET
                  0.874151, ## 15 kappaET
                  0.075601, ## 16 chiET
                  0.541605, ## 17 soilthresET
                  0.273584, ## 18 nu ET
                  ## SNOW_RAIN_PARAMETERS
                  1.2, ## 19 Meltcoef
                  0.33, ## 20 I_0
                  4.970496, ## 21 CWmax, i.e. max canopy water
                  0, ## 22 SnowThreshold, 
                  0, ## 23 T_0, 
                  200, ## 24 SWinit, ## START INITIALISATION PARAMETERS 
                  0, ## 25 CWinit, ## Canopy water
                  0, ## 26 SOGinit, ## Snow on Ground 
                  20, ## 27 Sinit ##CWmax
                  -999, ## t0 fPheno_start_date_Tsum_accumulation; conif -999, for birch 57
                  -999, ## tcrit, fPheno_start_date_Tsum_Tthreshold, 1.5 birch
                  -999 ##tsumcrit, fPheno_budburst_Tsum, 134 birch
  )
  
  ## Replace defualt with samples parameters
  load(parameters)
  params=data.frame(trait.values)
  colnames=c(names(trait.values[[1]]))
  colnames(params)<-colnames

  param.table[5]=as.numeric(params["bGPP"])
  param.table[9]=as.numeric(params["kGPP"])
  
  ##Run PRELES
  PRELES.output=as.data.frame(PRELES(PAR=tmp[,"PAR"],TAir=tmp[,"TAir"],VPD=tmp[,"VPD"], Precip=tmp[,"Precip"],CO2=tmp[,"CO2"],fAPAR=tmp[,"fAPAR"],params = param.table))
  PRELES.output.dims<-dim(PRELES.output)
  

  for (y in years){
    if(file.exists(file.path(outdir,paste(y))))
      next
    print(paste("----Processing year: ",y))
    
    sub.PRELES.output<- subset(PRELES.output, years == y)
    sub.PRELES.output.dims <- dim(sub.PRELES.output)
    
    output <- list()
    output[[1]] <- (sub.PRELES.output[,1]*0.001)/timestep.s #GPP - gC/m2day to kgC/m2s1
    output[[2]] <- (sub.PRELES.output[,2])/timestep.s #Evapotranspiration - mm =kg/m2
    output[[3]] <- (sub.PRELES.output[,3])/timestep.s #Soilmoisture - mm = kg/m2
    output[[4]] <- (sub.PRELES.output[,4])/timestep.s #fWE modifier - just a modifier
    output[[5]] <- (sub.PRELES.output[,5])/timestep.s #fW modifier - just a modifier
    output[[6]] <- (sub.PRELES.output[,6])/timestep.s #Evaporation - mm = kg/m2 
    output[[7]] <- (sub.PRELES.output[,7])/timestep.s #transpiration - mm = kg/m2
    
    t<- ncdim_def(name = "time",
                  units =paste0("days since",y,"-01-01 00:00:00"),
                  vals = 1:nrow(sub.PRELES.output),
                  calendar = "standard",unlim =TRUE)
    
    lat<- ncdim_def("lat", "degrees_east",
                    vals=as.numeric(lat),
                    longname = "station_longitude")
    
    lon<- ncdim_def("lat", "degrees_north",
                    vals=as.numeric(lon),
                    longname = "station_longitude")
    
    for(i in 1:length(output)){
      if(length(output[[i]])==0)output[[i]]<- rep(-999,length(t$vals))
    }
    
    var<-list()
    var[[1]]<- mstmipvar("GPP", lat, lon, t, NA)
    var[[2]]<- ncvar_def("Evapotranspiration", "kg/m2s1",list(lon,lat,t), -999)
    var[[3]]<- ncvar_def("SoilMoist","kg/m2s1", list(lat,lon,t),NA)
    var[[4]]<- ncvar_def("fWE","NA",list(lon,lat,t),-999)
    var[[5]]<- ncvar_def("fW","NA",list(lon,lat,t),-999)
    var[[6]]<- ncvar_def("Evap","kg/m2/s", list(lon,lat,t),-999)
    var[[7]]<- ncvar_def("TVeg","kg/m2/s",list(lat, lon, t), NA)
    
    nc <-nc_create(file.path(outdir,paste(y,"nc", sep=".")),var)
    varfile <- file(file.path(outdir,paste(y,"nc","var",sep=".")),"w")
    for(i in 1:length(var)){
      ncvar_put(nc,var[[i]],output[[i]])
      cat(paste(var[[i]]$name,var[[i]]$longname),file=varfile,sep="/n")
    }
    close(varfile)
    nc_close(nc)
  }
  
} ## end runPRELES.jobsh