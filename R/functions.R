# functions.R
# Shared helpers for analysis scripts and the report. Load with:
#   source(here::here("R", "functions.R"))

library(sf)
library(terra)
library(yaml)
library(here)

cfg <- yaml::read_yaml(here("config.yml"))

# Study area polygon (buffered transect) in the project CRS.
load_aoi <- function() {
  st_read(here(cfg$paths$derived, "aoi.gpkg"), layer = "aoi", quiet = TRUE)
}

# Transect line in the project CRS.
load_transect <- function() {
  st_read(here(cfg$paths$derived, "aoi.gpkg"), layer = "transect_line", quiet = TRUE)
}

# 12in orthoimagery mosaic (virtual, built by R/03_build_vrt.R).
#   aoi:  TRUE to crop to the study-area extent, FALSE for the full mosaic,
#         or an sf/SpatVector polygon to crop to instead.
#   mask: also set pixels outside the polygon to NA. This writes a full-size
#         temporary raster, so prefer masking per analysis (e.g. extract()) when possible.
# The VRT has no nodata value: areas outside the tiles read as 0 in all three bands.
# All such areas lie outside the AOI, so any analysis limited to the AOI polygon is unaffected.
load_ortho <- function(aoi = TRUE, mask = FALSE) {
  r <- rast(here(cfg$paths$derived, "ortho_12in.vrt"))
  names(r) <- c("red", "green", "blue")
  if (isFALSE(aoi)) return(r)
  poly <- if (isTRUE(aoi)) load_aoi() else aoi
  poly <- project(vect(poly), crs(r))
  # window() limits reading to the extent without copying; crop() would write
  # the whole area (~11 GB for the AOI) to a temporary file.
  window(r) <- align(ext(poly), r, snap = "out")
  if (mask) r <- terra::mask(r, poly)
  r
}
