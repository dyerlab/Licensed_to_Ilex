# 01_build_aoi.R
# Build the transect line and its buffered area of interest (AOI).
#
# Output: data/derived/aoi.gpkg with layers
#   transect_points  - the two endpoints
#   transect_line    - straight line between them (in project CRS)
#   aoi              - buffered transect

library(sf)
library(units)
library(yaml)
library(here)

cfg <- yaml::read_yaml(here("config.yml"))
dir.create(here(cfg$paths$derived), recursive = TRUE, showWarnings = FALSE)
aoi_path <- here(cfg$paths$derived, "aoi.gpkg")

# Endpoints ---------------------------------------------------------------
pts <- st_as_sf(
  data.frame(
    name = c(cfg$transect$start$name, cfg$transect$end$name),
    lon  = c(cfg$transect$start$lon,  cfg$transect$end$lon),
    lat  = c(cfg$transect$start$lat,  cfg$transect$end$lat)
  ),
  coords = c("lon", "lat"),
  crs = cfg$transect$input_crs,
  remove = FALSE
) |>
  st_transform(cfg$crs)

# Transect line -----------------------------------------------------------
# Built from the projected points so the line is straight in the project CRS.
line <- st_sf(
  name = "transect",
  geometry = st_sfc(st_linestring(st_coordinates(pts)), crs = cfg$crs)
)
line$length_km <- set_units(st_length(line), "km")

# Buffer ------------------------------------------------------------------
# Convert the half-width into the CRS's linear unit (US survey feet for 2925).
crs_units <- st_crs(cfg$crs)$units_gdal
crs_units <- if (crs_units == "US survey foot") "US_survey_foot" else crs_units
half_width <- set_units(set_units(cfg$buffer$half_width_km, "km"), crs_units, mode = "standard")

aoi <- st_sf(
  name = "aoi",
  half_width_km = cfg$buffer$half_width_km,
  end_cap = cfg$buffer$end_cap,
  geometry = st_buffer(
    st_geometry(line),
    dist = drop_units(half_width),
    endCapStyle = cfg$buffer$end_cap,
    nQuadSegs = cfg$buffer$quad_segs
  )
)
aoi$area_km2 <- set_units(st_area(aoi), "km^2")

# Write -------------------------------------------------------------------
if (file.exists(aoi_path)) invisible(file.remove(aoi_path))
st_write(pts,  aoi_path, layer = "transect_points", quiet = TRUE)
st_write(line, aoi_path, layer = "transect_line",   quiet = TRUE)
st_write(aoi,  aoi_path, layer = "aoi",             quiet = TRUE)

message(sprintf(
  "AOI written to %s\n  transect length: %.2f km\n  buffer half-width: %s km (%.1f %s)\n  AOI area: %.2f km^2",
  aoi_path, drop_units(line$length_km), cfg$buffer$half_width_km,
  drop_units(half_width), crs_units, drop_units(aoi$area_km2)
))
