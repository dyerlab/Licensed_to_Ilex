# 06_holly_objects.R
# Find small evergreen crowns in the leaf-off orthoimagery: the raw material for holly
# candidates. Every crown within cfg$holly$extract_diam_ft is kept with its features, so the
# candidate rule (holly_candidates() in R/functions.R) can be tuned without re-running this.
#
# Per tile (full 1 ft resolution, no resampling of the imagery):
#   1. vegetation index (GLI from RGB, or NDVI once a nir band exists), smoothed
#   2. crown mask: index > crown threshold; crowns are 8-connected patches of the mask
#   3. context: share of evergreen pixels (index > context threshold) in a 70 ft neighbourhood
#      around each crown, from the mask aggregated to 10 ft cells (isolation measure)
#   4. features per crown: area, equivalent diameter, compactness, mean/max index, mean band
#      values, and the mean of both indices (GLI, and NDVI when a nir band exists), so visible-only
#      and visible + NIR classifiers can be compared on the same crowns
# Then all tiles are combined, limited to the AOI, and given NLCD class and transect position.
#
# Inputs:  data/derived/tiles_needed.csv, tiles from cfg$imagery_source (ortho_tile_paths()),
#          data/raw/nlcd/LndCov_<year>.tif
# Outputs: data/derived/holly/tiles/<tile>.gpkg   - per-tile crowns (cache; delete to redo)
#          data/derived/holly_objects.gpkg         - all crowns in the AOI with features
#          data/derived/holly_candidates.csv, .gpx - crowns passing the candidate rule, for the field

library(sf)
library(terra)
library(parallel)
library(here)

source(here("R", "functions.R"))

h <- cfg$holly
tile_dir <- here(h$dir, "tiles")
dir.create(tile_dir, recursive = TRUE, showWarnings = FALSE)
tiles <- read.csv(here(cfg$paths$derived, "tiles_needed.csv"))
tiles$tif_path <- ortho_tile_paths(tiles$tile_name)

# Per-tile crown extraction ---------------------------------------------------
crowns_in_tile <- function(tile_name, tif_path) {
  out <- file.path(tile_dir, paste0(tile_name, ".gpkg"))
  if (file.exists(out)) return(out)

  # Separate temp folder per worker, removed when the tile is done
  tmp <- file.path(tempdir(), tile_name)
  dir.create(tmp, showWarnings = FALSE)
  terraOptions(tempdir = tmp, memfrac = 0.15, progress = 0)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

  r <- rast(here(tif_path))
  names(r) <- band_names(r)
  index <- veg_index_name(r)
  thr <- h$thresholds[[index]]
  px_area <- prod(res(r))                      # ft^2 per pixel

  vi <- focal(veg_index(r, index), h$smooth_px, "mean", na.policy = "omit")
  crowns <- patches(ifel(vi > thr$crown, 1, NA), directions = 8)

  # Keep crowns in the extraction size range
  f <- freq(crowns)
  f$diam_ft <- 2 * sqrt(f$count * px_area / pi)
  keep <- f$value[f$diam_ft >= h$extract_diam_ft[1] & f$diam_ft <= h$extract_diam_ft[2]]
  if (length(keep) == 0) {
    st_write(st_sf(geometry = st_sfc(crs = cfg$crs)), out, delete_dsn = TRUE, quiet = TRUE)
    return(out)
  }
  crowns <- mask(crowns, crowns %in% keep, maskvalues = FALSE)

  # Features
  # Area from pixel counts (exact); perimeter from sf in CRS units (terra's expanse()/perim()
  # do not report US survey feet for this CRS)
  pol <- as.polygons(crowns)
  names(pol) <- "patch"
  pol$area_ft2 <- f$count[match(pol$patch, f$value)] * px_area
  pol$diam_ft <- 2 * sqrt(pol$area_ft2 / pi)
  perim_ft <- as.numeric(st_length(st_cast(st_set_crs(st_geometry(st_as_sf(pol)), cfg$crs), "MULTILINESTRING")))
  pol$compactness <- 4 * pi * pol$area_ft2 / perim_ft^2
  # Unsmoothed index means for both indices (GLI always; NDVI when a nir band exists)
  both <- veg_index(r, "gli")
  if ("nir" %in% names(r)) both <- c(both, veg_index(r, "ndvi"))
  zmean <- zonal(c(vi, both, r), crowns, "mean", na.rm = TRUE)
  zmax  <- zonal(vi, crowns, "max", na.rm = TRUE)
  names(zmean) <- c("patch", "vi_mean", paste0(names(both), "_mean"), names(r))
  names(zmax)  <- c("patch", "vi_max")
  pol <- merge(merge(pol, zmean, by = "patch"), zmax, by = "patch")
  pol$brightness <- (pol$red + pol$green + pol$blue) / 3

  # Isolation: evergreen share of the neighbourhood around each crown centre
  ctx <- focal(aggregate(vi > thr$context, h$context_cell_px, "mean", na.rm = TRUE),
               h$context_window, "mean", na.rm = TRUE, expand = TRUE)
  pol$context <- extract(ctx, centroids(pol))[, 2]

  # Crowns cut by the tile edge are partial; flag them
  e <- ext(r)
  b <- do.call(rbind, lapply(seq_len(nrow(pol)), function(i) as.vector(ext(pol[i]))))
  pol$tile_edge <- b[, "xmin"] <= e$xmin | b[, "xmax"] >= e$xmax |
                   b[, "ymin"] <= e$ymin | b[, "ymax"] >= e$ymax

  pol$tile <- tile_name
  pol$obj_id <- sprintf("%s_%d", sub("\\.2025$", "", tile_name), pol$patch)
  pol$vi_name <- index
  s <- st_as_sf(pol)
  st_crs(s) <- st_crs(cfg$crs)
  # Write to a temporary name and rename, so an interrupted run never leaves a partial file
  part <- sub("\\.gpkg$", ".part.gpkg", out)
  st_write(s, part, delete_dsn = TRUE, quiet = TRUE)
  file.rename(part, out)
  tmpFiles(remove = TRUE)
  out
}

todo <- tiles[!file.exists(file.path(tile_dir, paste0(tiles$tile_name, ".gpkg"))), ]
message(sprintf("%d of %d tiles to process with %d workers", nrow(todo), nrow(tiles), h$workers))
t0 <- Sys.time()
res <- mclapply(seq_len(nrow(todo)), function(i) {
  tryCatch(crowns_in_tile(todo$tile_name[i], todo$tif_path[i]),
           error = function(e) paste("ERROR", todo$tile_name[i], conditionMessage(e)))
}, mc.cores = h$workers, mc.preschedule = FALSE)
errs <- grep("^ERROR", unlist(res), value = TRUE)
if (length(errs)) stop(paste(errs, collapse = "\n"))
message(sprintf("Tiles done in %.1f min", as.numeric(difftime(Sys.time(), t0, units = "mins"))))

# Combine, limit to AOI, add NLCD class and transect position ------------------
obj <- do.call(rbind, lapply(file.path(tile_dir, paste0(tiles$tile_name, ".gpkg")),
                             st_read, quiet = TRUE))
cent <- st_centroid(st_geometry(obj))
in_aoi <- lengths(st_intersects(cent, load_aoi())) > 0
obj <- obj[in_aoi, ]
cent <- cent[in_aoi]

lc <- rast(here(cfg$nlcd$dir, sprintf("LndCov_%d.tif", cfg$nlcd$year)))
obj$nlcd <- extract(lc, vect(st_transform(cent, crs(lc))))[, 2]
obj <- cbind(obj, transect_position(x = cent))
ll <- st_coordinates(st_transform(cent, 4326))
obj$lon <- ll[, 1]
obj$lat <- ll[, 2]
obj$patch <- NULL

st_write(obj, here(cfg$paths$derived, "holly_objects.gpkg"), delete_dsn = TRUE, quiet = TRUE)

# Candidates for the field ----------------------------------------------------
cand <- holly_candidates(obj)
cand <- cand[cand$candidate & !cand$tile_edge, ]
field_cols <- c("obj_id", "lat", "lon", "u_km", "v_km", "window",
                "diam_ft", "context", "vi_mean", "gli_mean", "ndvi_mean", "nlcd")
field <- st_drop_geometry(cand)[, intersect(field_cols, names(cand))]
write.csv(field, here(cfg$paths$derived, "holly_candidates.csv"), row.names = FALSE)

gpx <- st_as_sf(data.frame(name = field$obj_id,
                           desc = sprintf("%.0f ft crown, window %d", field$diam_ft, field$window),
                           lon = field$lon, lat = field$lat),
                coords = c("lon", "lat"), crs = 4326)
gpx_path <- here(cfg$paths$derived, "holly_candidates.gpx")
if (file.exists(gpx_path)) file.remove(gpx_path)
st_write(gpx, gpx_path, driver = "GPX", layer = "waypoints", quiet = TRUE)

message(sprintf("%d crowns in AOI, %d candidates -> holly_objects.gpkg, holly_candidates.{csv,gpx}",
                nrow(obj), nrow(cand)))
