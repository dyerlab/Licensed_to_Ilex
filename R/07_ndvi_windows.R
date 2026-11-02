# 07_ndvi_windows.R
# NDVI along the transect from the 4-band (RGB + NIR) imagery.
#
# The imagery was flown leaf-off (February to March 2025), so high NDVI marks evergreen
# foliage (pine, cedar, holly, magnolia, evergreen shrubs) and green winter lawns; leaf-off
# hardwood canopy has moderate values. The NIR band is not radiometrically calibrated, so
# absolute NDVI values are not comparable with other sensors; comparisons along the transect
# are what matter.
#
# Per tile, NDVI is computed at full 1 ft resolution and summarised into 10 ft cells
# (mean NDVI and share of 1 ft pixels above the holly context threshold, i.e. "evergreen").
# Run R/05b_ndvi_calibration.R first.
# The 10 ft summaries are then mosaicked and summarised per 1 km window, for all land and for
# NLCD forest only (classes 41-43).
#
# "Evergreen" uses the configured index (brightness-adjusted NDVI by default, so shadows are
# not counted) and its context threshold; the mean is plain NDVI.
#
# Inputs:  data/derived/tiles_needed.csv, 4-band tiles (ortho_tile_paths()),
#          data/derived/transect_windows.gpkg, data/raw/nlcd/LndCov_<year>.tif
# Outputs: data/derived/ndvi/tiles/<tile>.tif - per-tile 10 ft summaries (cache; delete to redo)
#          data/derived/ndvi_10ft.tif          - mosaic: ndvi_mean, evg_frac (10 ft cells)
#          data/derived/ndvi_windows.csv       - per-window summaries

library(sf)
library(terra)
library(parallel)
library(exactextractr)
library(here)

source(here("R", "functions.R"))

cell_px <- 10                                   # 10 x 10 px = 10 ft cells

forest  <- c(41, 42, 43)

tiles <- read.csv(here(cfg$paths$derived, "tiles_needed.csv"))
tiles$tif_path <- ortho_tile_paths(tiles$tile_name)
probe <- rast(here(tiles$tif_path[1]))
if (nlyr(probe) < 4) stop("NDVI needs the 4-band imagery (imagery_source: \"4band\").")
names(probe) <- band_names(probe)
evg_index <- veg_index_name(probe)
evg_thr <- cfg$holly$thresholds[[evg_index]]$context    # "evergreen" pixel threshold
message("Evergreen pixels: ", evg_index, " > ", evg_thr)

# Per-tile 10 ft summaries ----------------------------------------------------------
tile_dir <- here(cfg$paths$derived, "ndvi", "tiles")
dir.create(tile_dir, recursive = TRUE, showWarnings = FALSE)

ndvi_tile <- function(tile_name, tif_path) {
  out <- file.path(tile_dir, paste0(tile_name, ".tif"))
  if (file.exists(out)) return(out)
  tmp <- file.path(tempdir(), tile_name)
  dir.create(tmp, showWarnings = FALSE)
  terraOptions(tempdir = tmp, memfrac = 0.15, progress = 0)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

  r <- rast(here(tif_path))
  names(r) <- band_names(r)
  nd <- veg_index(r, "ndvi")
  s <- c(aggregate(nd, cell_px, "mean", na.rm = TRUE),
         aggregate(veg_index(r, evg_index) > evg_thr, cell_px, "mean", na.rm = TRUE))
  names(s) <- c("ndvi_mean", "evg_frac")
  part <- sub("\\.tif$", ".part.tif", out)
  writeRaster(s, part, overwrite = TRUE, datatype = "FLT4S", gdal = "COMPRESS=DEFLATE")
  file.rename(part, out)
  out
}

todo <- tiles[!file.exists(file.path(tile_dir, paste0(tiles$tile_name, ".tif"))), ]
message(sprintf("%d of %d tiles to process", nrow(todo), nrow(tiles)))
res <- mclapply(seq_len(nrow(todo)), function(i) {
  tryCatch(ndvi_tile(todo$tile_name[i], todo$tif_path[i]),
           error = function(e) paste("ERROR", todo$tile_name[i], conditionMessage(e)))
}, mc.cores = cfg$holly$workers, mc.preschedule = FALSE)
errs <- grep("^ERROR", unlist(res), value = TRUE)
if (length(errs)) stop(paste(errs, collapse = "\n"))

# Mosaic (tiles do not overlap; edges fall on 10 ft multiples)
mos <- merge(sprc(file.path(tile_dir, paste0(tiles$tile_name, ".tif"))))
names(mos) <- c("ndvi_mean", "evg_frac")
mos <- mask(mos, vect(load_aoi()))
writeRaster(mos, here(cfg$paths$derived, "ndvi_10ft.tif"), overwrite = TRUE,
            gdal = c("COMPRESS=DEFLATE", "TILED=YES"))

# NLCD land cover on the 10 ft grid (nearest neighbour; used only as a class mask)
lc <- rast(here(cfg$nlcd$dir, sprintf("LndCov_%d.tif", cfg$nlcd$year)))
lc10 <- project(lc, mos, method = "near")
land   <- lc10 != 11
forest_mask <- lc10 %in% forest

# Per-window summaries (area-weighted means over 10 ft cells)
win <- load_windows()
stack <- c(mos, mask(mos, land, maskvalues = FALSE), mask(mos, forest_mask, maskvalues = FALSE))
names(stack) <- c("ndvi_all", "evg_all", "ndvi_land", "evg_land", "ndvi_forest", "evg_forest")
m <- exact_extract(stack, win, "mean", progress = FALSE)
names(m) <- sub("^mean\\.", "", names(m))
q <- exact_extract(stack[["ndvi_land"]], win, "quantile", quantiles = c(0.1, 0.5, 0.9),
                   progress = FALSE)
names(q) <- c("ndvi_q10", "ndvi_q50", "ndvi_q90")

out <- cbind(st_drop_geometry(win)[, c("window", "u_mid_km")],
             ndvi_mean = m$ndvi_land, evg_pct = 100 * m$evg_land,
             ndvi_forest = m$ndvi_forest, evg_forest_pct = 100 * m$evg_forest,
             q)
write.csv(out, here(cfg$paths$derived, "ndvi_windows.csv"), row.names = FALSE)
message("Per-window NDVI -> ndvi_windows.csv; 10 ft mosaic -> ndvi_10ft.tif")
print(round(out, 3))
