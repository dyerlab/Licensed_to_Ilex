# 04_transect_windows.R
# Divide the study area into non-overlapping windows along the transect. Each window is a
# rectangle spanning the full buffer width, cfg$windows$length_km long. The last window is
# shorter if the transect length is not a whole multiple of the window length. The round end
# caps beyond the transect endpoints are not part of any window.
#
# Input:  data/derived/aoi.gpkg (transect_line)
# Output: data/derived/transect_windows.gpkg with one polygon per window and fields
#   window (id, 1 at Richmond), u_start_km, u_end_km, u_mid_km, length_km, area_km2

library(sf)
library(units)
library(here)

source(here("R", "functions.R"))

ends <- st_coordinates(load_transect())[, 1:2]
d <- ends[2, ] - ends[1, ]
len <- sqrt(sum(d^2))
d <- d / len
n <- c(-d[2], d[1])                           # left-hand normal
half_w <- km_to_crs(cfg$buffer$half_width_km)

len_km <- crs_to_km(len)
breaks_km <- unique(c(seq(0, len_km, by = cfg$windows$length_km), len_km))
u0 <- head(breaks_km, -1)
u1 <- tail(breaks_km, -1)
# Drop a sliver window if the transect length is within 1 m of a whole number of windows
keep <- (u1 - u0) > 0.001
u0 <- u0[keep]; u1[sum(keep)] <- len_km; u1 <- u1[keep]

rect <- function(a, b) {
  pa <- ends[1, ] + km_to_crs(a) * d
  pb <- ends[1, ] + km_to_crs(b) * d
  st_polygon(list(rbind(pa + half_w * n, pb + half_w * n,
                        pb - half_w * n, pa - half_w * n, pa + half_w * n)))
}

windows <- st_sf(
  window = seq_along(u0),
  u_start_km = u0,
  u_end_km = u1,
  u_mid_km = (u0 + u1) / 2,
  length_km = u1 - u0,
  geometry = st_sfc(mapply(rect, u0, u1, SIMPLIFY = FALSE), crs = cfg$crs)
)
windows$area_km2 <- as.numeric(set_units(st_area(windows), "km^2"))

out <- here(cfg$paths$derived, "transect_windows.gpkg")
st_write(windows, out, delete_dsn = TRUE, quiet = TRUE)

message(sprintf("%d windows of %g km (last %.2f km), %.1f km2 total -> %s",
                nrow(windows), cfg$windows$length_km, tail(windows$length_km, 1),
                sum(windows$area_km2), out))
