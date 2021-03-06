##' Read BioCro config file
##'
##' @title Read BioCro Config 
##' @param config.file Path to XML file
##' @return list of run configuration parameters for PEcAn
##' @export
##' @author David LeBauer
read.biocro.config <- function(config.file = "config.xml") {
  config <- XML::xmlToList(XML::xmlTreeParse(file = config.file, 
                                   handlers = list(comment = function(x) { NULL }),
                                   asTree = TRUE))
  config$pft$canopyControl$mResp <- unlist(strsplit(config$pft$canopyControl$mResp, split = ","))
  return(config)
}  # read.biocro.config
