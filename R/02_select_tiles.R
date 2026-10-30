# 02_select_tiles.R
# Find the orthophoto tiles whose footprints intersect the AOI, and check which
# of them are present locally. File paths in the outputs are relative to the
# project root so the lists work on any machine.
#
# Inputs:  data/derived/aoi.gpkg (from 01_build_aoi.R), VBMP tile index shapefiles
# Outputs: data/derived/tiles_needed.gpkg  - footprints of intersecting tiles + status
#          data/derived/tiles_needed.csv   - file list read by convert_mrsid.py
#          data/derived/tiles_local_unused.csv - local .sid files outside the AOI

library(sf)
library(dplyr)
library(yaml)
library(here)

cfg <- yaml::read_yaml(here("config.yml"))
derived <- here(cfg$paths$derived)
aoi <- st_read(file.path(derived, "aoi.gpkg"), layer = "aoi", quiet = TRUE)

# Intersect AOI with each tile index layer --------------------------------
# Each layer is searched in its own CRS; footprints are returned in the project CRS.
select_from_layer <- function(layer) {
  idx <- st_read(here(cfg$tile_index$dir, paste0(layer, ".shp")), quiet = TRUE)
  aoi_l <- st_transform(aoi, st_crs(idx))
  hit <- idx[lengths(st_intersects(idx, aoi_l)) > 0, ]
  if (nrow(hit) == 0) return(NULL)
  hit |>
    transmute(
      tile_name   = .data[[cfg$tile_index$name_field]],
      index_layer = layer,
      product     = Product,
      native_epsg = st_crs(idx)$epsg
    ) |>
    st_transform(cfg$crs)
}
needed <- bind_rows(lapply(cfg$tile_index$layers, select_from_layer))

# Locate local files ------------------------------------------------------
sid_files <- file.path(
  cfg$paths$tiles_dir,
  list.files(here(cfg$paths$tiles_dir), pattern = "\\.sid$", recursive = TRUE, ignore.case = TRUE)
)
local <- tibble(
  sid_path  = sid_files,
  tile_name = sub("\\.sid$", "", basename(sid_files), ignore.case = TRUE)
)

# macOS iCloud: "dataless" files are cloud-only placeholders that must download
# before QGIS can read them. Flag them so a large batch doesn't stall.
is_dataless <- function(paths) {
  out <- rep(FALSE, length(paths))
  paths <- ifelse(is.na(paths), NA, here(paths))
  ok <- !is.na(paths) & file.exists(paths)
  if (Sys.info()[["sysname"]] != "Darwin" || !any(ok)) return(out)
  flags <- system2("stat", c("-f", "%Sf", shQuote(paths[ok])), stdout = TRUE)
  out[ok] <- grepl("dataless", flags)
  out
}

needed <- needed |>
  left_join(local, by = "tile_name") |>
  mutate(
    sdw_path = ifelse(is.na(sid_path), NA, sub("\\.sid$", ".sdw", sid_path, ignore.case = TRUE)),
    tif_path = file.path(cfg$paths$geotiff, paste0(tile_name, ".tif")),
    status   = ifelse(is.na(sid_path), "missing", "local"),
    cloud_only = is_dataless(sid_path),
    converted  = file.exists(here(tif_path))
  ) |>
  arrange(tile_name)

# Coverage check: any part of the AOI not covered by tile footprints?
gap <- st_difference(st_geometry(aoi), st_union(needed))
gap_km2 <- if (length(gap) == 0) 0 else as.numeric(units::set_units(sum(st_area(gap)), "km^2"))

# Write -------------------------------------------------------------------
gpkg <- file.path(derived, "tiles_needed.gpkg")
if (file.exists(gpkg)) invisible(file.remove(gpkg))
st_write(needed, gpkg, layer = "tiles_needed", quiet = TRUE)

needed |>
  st_drop_geometry() |>
  select(tile_name, index_layer, native_epsg, status, cloud_only, converted,
         sid_path, sdw_path, tif_path) |>
  write.csv(file.path(derived, "tiles_needed.csv"), row.names = FALSE, na = "")

unused <- local |> filter(!tile_name %in% needed$tile_name)
write.csv(unused, file.path(derived, "tiles_local_unused.csv"), row.names = FALSE)

# Summary -----------------------------------------------------------------
message(sprintf("Tiles intersecting AOI: %d", nrow(needed)))
print(count(st_drop_geometry(needed), index_layer, status, cloud_only))
message(sprintf("Local .sid files not needed: %d", nrow(unused)))
message(sprintf("AOI area not covered by any tile footprint: %.4f km^2", gap_km2))
if (any(needed$native_epsg != cfg$crs)) {
  warning("Some selected tiles are not in EPSG:", cfg$crs, " and will need reprojection.")
}
