# 05_nlcd.R
# Download Annual NLCD land cover and fractional impervious surface for the study area and
# summarize them for each transect window.
#
# NLCD stays on its native 30 m grid (EPSG:5070); the windows are projected to it and
# summarized with exactextractr, which weights each cell by the fraction inside the window.
#
# Inputs:  data/derived/aoi.gpkg, data/derived/transect_windows.gpkg (R/04_transect_windows.R)
# Outputs: data/raw/nlcd/<product>_<year>.tif     - NLCD clipped to the AOI bounding box
#          data/derived/nlcd_window_classes.csv   - fraction of each land cover class per window
#          data/derived/nlcd_windows.csv          - one row per window: impervious and grouped cover

library(sf)
library(terra)
library(exactextractr)
library(here)

source(here("R", "functions.R"))

nl <- cfg$nlcd
nlcd_dir <- here(nl$dir)
dir.create(nlcd_dir, recursive = TRUE, showWarnings = FALSE)

# Download ----------------------------------------------------------------
# Request the AOI bounding box (plus a margin) snapped outward to the native 30 m grid.
bb <- st_bbox(st_transform(load_aoi(), nl$crs))
bb <- c(floor((bb[c("xmin", "ymin")] - nl$margin_m) / nl$res_m) * nl$res_m,
        ceiling((bb[c("xmax", "ymax")] + nl$margin_m) / nl$res_m) * nl$res_m)

nlcd_path <- function(prod) file.path(nlcd_dir, sprintf("%s_%d.tif", prod, nl$year))

get_nlcd <- function(prod) {
  out <- nlcd_path(prod)
  if (file.exists(out)) return(out)
  cov <- nl$products[[prod]]
  ws <- paste0("mrlc_", cov)
  url <- httr::modify_url(
    paste(nl$wcs_url, ws, "wcs", sep = "/"),
    query = list(service = "WCS", version = "1.0.0", request = "GetCoverage",
                 coverage = paste0(ws, ":", cov), CRS = paste0("EPSG:", nl$crs),
                 BBOX = paste(bb[c("xmin", "ymin", "xmax", "ymax")], collapse = ","),
                 time = sprintf("%d-01-01T00:00:00.000Z", nl$year),
                 format = "image/geotiff", resx = nl$res_m, resy = nl$res_m)
  )
  tmp <- tempfile(fileext = ".tif")
  resp <- httr::GET(url, httr::write_disk(tmp, overwrite = TRUE), httr::timeout(300))
  if (httr::http_error(resp) || !grepl("tiff", httr::headers(resp)[["content-type"]])) {
    stop("NLCD download failed for ", prod, " ", nl$year, ": ", readLines(tmp, warn = FALSE)[1])
  }
  # The service adds tiny floating-point jitter to the geotransform; snap to the native grid.
  r <- rast(tmp)
  ext(r) <- ext(bb[c("xmin", "xmax", "ymin", "ymax")])
  writeRaster(r, out, datatype = "INT1U", gdal = "COMPRESS=LZW")
  message("Downloaded ", basename(out))
  out
}

lc  <- rast(get_nlcd("LndCov"))
imp <- rast(get_nlcd("FctImp"))
imp[imp > 100] <- NA    # 0-100 %; anything above is a fill value

# Summarize per window ----------------------------------------------------
windows <- st_transform(load_windows(), nl$crs)

# Class fractions (share of window area in each NLCD class)
frac <- exact_extract(lc, windows, "frac", progress = FALSE)
classes <- as.integer(sub("^frac_", "", names(frac)))
class_tab <- data.frame(
  window = rep(windows$window, times = length(classes)),
  class  = rep(classes, each = nrow(windows)),
  frac   = unlist(frac, use.names = FALSE)
)
class_tab <- class_tab[order(class_tab$window, class_tab$class), ]

# Grouped cover (Anderson level I, with developed split by intensity)
groups <- list(
  water         = 11:12,
  developed_open = 21,
  developed     = 22:24,      # low, medium, high intensity
  barren        = 31,
  forest        = 41:43,
  shrub_grass   = c(52, 71),
  agriculture   = 81:82,
  wetland       = c(90, 95)
)
grouped <- sapply(groups, function(k) {
  tapply(class_tab$frac * (class_tab$class %in% k), class_tab$window, sum)
})

summary_tab <- data.frame(
  st_drop_geometry(windows)[, c("window", "u_start_km", "u_end_km", "u_mid_km", "area_km2")],
  imperv_mean = exact_extract(imp, windows, "mean", progress = FALSE),
  imperv_sd   = exact_extract(imp, windows, "stdev", progress = FALSE),
  100 * grouped[as.character(windows$window), , drop = FALSE],
  row.names = NULL
)
names(summary_tab)[-(1:7)] <- paste0(names(summary_tab)[-(1:7)], "_pct")
summary_tab$nlcd_year <- nl$year

write.csv(class_tab, here(cfg$paths$derived, "nlcd_window_classes.csv"), row.names = FALSE)
write.csv(summary_tab, here(cfg$paths$derived, "nlcd_windows.csv"), row.names = FALSE)

message(sprintf("Summarized NLCD %d for %d windows -> data/derived/nlcd_windows.csv",
                nl$year, nrow(summary_tab)))
