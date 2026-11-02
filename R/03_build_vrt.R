# 03_build_vrt.R
# Build a virtual mosaic (VRT) of the 4-band (red, green, blue, nir) GeoTIFF tiles and a
# low-resolution preview for the report.
#
# Inputs:  data/derived/tiles_needed.csv, <cfg$paths$geotiff>/*.tif (VGIN 4-band GeoTIFFs)
# Outputs: data/derived/ortho_12in.vrt        - mosaic of all tiles (references the .tif files)
#          data/derived/ortho_12in_preview.tif - downsampled copy for quick plotting

library(terra)
library(xml2)
library(yaml)
library(here)

cfg <- yaml::read_yaml(here("config.yml"))

# Path of `to` relative to directory `from` (both absolute), e.g. "../raw/tiles_tif".
relative_path <- function(to, from) {
  a <- strsplit(normalizePath(to, mustWork = FALSE), "/")[[1]]
  b <- strsplit(normalizePath(from, mustWork = FALSE), "/")[[1]]
  n <- 0
  while (n < min(length(a), length(b)) && a[n + 1] == b[n + 1]) n <- n + 1
  do.call(file.path, as.list(c(rep("..", length(b) - n), a[-seq_len(n)])))
}
derived <- here(cfg$paths$derived)
vrt_path <- file.path(derived, "ortho_12in.vrt")
preview_path <- file.path(derived, "ortho_12in_preview.tif")
preview_res_ft <- 25   # preview pixel size in CRS units (US survey feet)

# Check that every required tile has been converted ------------------------
tiles <- read.csv(file.path(derived, "tiles_needed.csv"))
missing <- tiles$tile_name[!file.exists(here(tiles$tif_path))]
if (length(missing) > 0) {
  stop(length(missing), " tile(s) not found in ", cfg$paths$geotiff, ", e.g. ", missing[1],
       ". Download the 4-band GeoTIFFs first (see analyses/01_study_area.qmd).")
}

# Build the VRT ------------------------------------------------------------
# Relative source paths keep the VRT valid if the project folder is moved.
v <- vrt(here(tiles$tif_path), filename = vrt_path, overwrite = TRUE,
         options = c("-srcnodata", "None", "-vrtnodata", "None"))

# Set band descriptions so GDAL-based tools (terra, QGIS) see red/green/blue/nir,
# and make source paths relative to the VRT.
doc <- read_xml(vrt_path)
bands <- xml_find_all(doc, "//VRTRasterBand")
for (i in seq_along(bands)) {
  xml_add_child(bands[[i]], "Description", c("red", "green", "blue", "nir")[i], .where = 0)
}
for (sf_node in xml_find_all(doc, "//SourceFilename")) {
  rel <- file.path(relative_path(here(cfg$paths$geotiff), derived), basename(xml_text(sf_node)))
  xml_text(sf_node) <- rel
  xml_set_attr(sf_node, "relativeToVRT", "1")
}
write_xml(doc, vrt_path)

ortho <- rast(vrt_path)
stopifnot(nlyr(ortho) == 4, same.crs(ortho, paste0("EPSG:", cfg$crs)))

# Preview -----------------------------------------------------------------
# The VRT is the bounding rectangle of the tiles; areas with no tile read as 0 in
# all bands (no nodata value is set, so real dark pixels are never lost). Real
# pixels are never 0 in all four bands, so that pattern marks uncovered areas.
# Every pixel inside the AOI is covered by a tile (checked in 02_select_tiles.R).
# Tile edges fall on multiples of the preview pixel size, so averaging never mixes
# covered and uncovered areas.
tmp <- tempfile(fileext = ".tif")
sf::gdal_utils(
  "translate", vrt_path, tmp,
  options = c("-tr", preview_res_ft, preview_res_ft, "-r", "average")
)
preview <- rast(tmp)
uncovered <- app(preview, function(x) all(x == 0))
preview <- mask(preview, uncovered, maskvalues = 1)
names(preview) <- c("red", "green", "blue", "nir")
writeRaster(preview, preview_path, overwrite = TRUE, datatype = "INT2U", NAflag = 65535,
            gdal = c("COMPRESS=DEFLATE", "TILED=YES"))
unlink(tmp)

message(sprintf(
  "VRT written to %s\n  %d tiles, %d x %d px, %g ft pixels, bands: %s\n  preview: %s (%g ft pixels)",
  vrt_path, nrow(tiles), ncol(ortho), nrow(ortho), res(ortho)[1],
  paste(names(ortho), collapse = ", "), preview_path, preview_res_ft
))
