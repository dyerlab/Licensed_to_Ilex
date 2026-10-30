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

# Distance conversion between km and the project CRS's linear unit (US survey feet for 2925).
crs_unit <- function() {
  u <- st_crs(cfg$crs)$units_gdal
  if (u == "US survey foot") "US_survey_foot" else u
}
km_to_crs <- function(x) {
  as.numeric(units::set_units(units::set_units(x, "km"), crs_unit(), mode = "standard"))
}
crs_to_km <- function(x) {
  as.numeric(units::set_units(units::set_units(x, crs_unit(), mode = "standard"), "km"))
}

# Transect windows (built by R/04_transect_windows.R).
load_windows <- function() {
  st_read(here(cfg$paths$derived, "transect_windows.gpkg"), quiet = TRUE)
}

# Position of points relative to the transect.
#   lon, lat: WGS84 coordinates, or pass an sf object as `x` instead (any CRS).
# Returns a data frame with
#   u_km:   distance along the transect from the Richmond end (negative or beyond the
#           transect length for points in the round end caps)
#   v_km:   signed perpendicular offset; positive is left of the direction of travel
#           (east side), negative is right (west side)
#   window: id of the window containing the point, NA outside all windows
# The transect is a straight line in the project CRS, so u and v are plain projections.
transect_position <- function(lon, lat, x = NULL) {
  if (is.null(x)) {
    x <- st_as_sf(data.frame(lon = lon, lat = lat), coords = c("lon", "lat"),
                  crs = cfg$transect$input_crs)
  }
  xy <- st_coordinates(st_transform(st_geometry(x), cfg$crs))[, 1:2, drop = FALSE]
  ends <- st_coordinates(load_transect())[, 1:2]
  d <- ends[2, ] - ends[1, ]
  len <- sqrt(sum(d^2))
  d <- d / len
  n <- c(-d[2], d[1])                     # left-hand normal
  rel <- sweep(xy, 2, ends[1, ])
  u <- crs_to_km(rel %*% d)
  v <- crs_to_km(rel %*% n)
  win_len <- cfg$windows$length_km
  inside <- u >= 0 & u <= crs_to_km(len) & abs(v) <= cfg$buffer$half_width_km
  window <- ifelse(inside, pmin(floor(u / win_len), ceiling(crs_to_km(len) / win_len) - 1) + 1, NA)
  data.frame(u_km = u, v_km = v, window = as.integer(window))
}
