suppressPackageStartupMessages({library(terra); library(sf)})
source(here::here("R","functions.R"))
line <- load_transect()
ends <- st_coordinates(line)[, 1:2]
d <- (ends[2, ] - ends[1, ]) / sqrt(sum((ends[2, ] - ends[1, ])^2))
p <- ends[1, ] + km_to_crs(22.5) * d
w <- 2400; h <- 1350   # ft at 1 ft/px -> 2400 x 1350 px (16:9)
e <- ext(p[1] - w/2, p[1] + w/2, p[2] - h/2, p[2] + h/2)
tifs <- list.files(here::here("data/raw/tiles_tif"), "\\.tif$", full.names = TRUE); v <- vrt(tifs, file.path(Sys.getenv("S"), "o.vrt"), overwrite = TRUE); chip <- crop(v, e)
names(chip) <- band_names(chip)
cat(dim(chip), "\n"); print(names(chip))
rgb <- chip[[c("red","green","blue")]]
png(file.path(Sys.getenv("S"), "hdr_wide.png"), width = ncol(rgb), height = nrow(rgb))
par(mar = c(0,0,0,0)); plotRGB(rgb, stretch = "lin", maxcell = Inf, mar = c(0,0,0,0), axes = FALSE)
dev.off()
