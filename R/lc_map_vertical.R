# lc_map_vertical.R
# Standalone land cover figure: the lc-map from analyses/02_gradient.qmd rotated so the
# transect runs straight down the page (Richmond at top), for use as a tall, narrow figure
# with text wrapped beside it. Not used by the report.
#
# NLCD is sampled by nearest neighbour onto a fine grid aligned with the transect, so class
# values are never blended and the 30 m cells keep their shape, turned with the map.
#
# Inputs:  data/derived/aoi.gpkg, transect_windows.gpkg, nlcd_window_classes.csv,
#          data/raw/nlcd/LndCov_<year>.tif
# Outputs: media/lc_map_vertical.png, media/lc_map_vertical.pdf

library(sf)
library(terra)
library(ragg)
library(here)

source(here("R", "functions.R"))

grid_km <- 0.005                      # output pixel size (5 m)
fig_width_in <- 1.4                   # height follows from this width and the map's true scale
left_in  <- 0.33                      # room for the distance labels
right_in <- 0.17                      # room for the legend
label_in <- 0.17                      # room for each place name
font_pt <- 7

# Legend groups, drawn as blocks of touching swatches in NLCD class order within each group
lc_groups <- list(
  Developed   = c(21, 22, 23, 24),
  Forest      = c(41, 42, 43),
  Agriculture = c(71, 81, 82),
  Water       = c(11, 90, 95),
  Other       = c(31, 52)
)

lc <- rast(here(cfg$nlcd$dir, sprintf("LndCov_%d.tif", cfg$nlcd$year)))
windows <- load_windows()
half_w <- cfg$buffer$half_width_km

# Transect axes in the project CRS: d points from Richmond to Pocahontas, n is its left-hand
# normal. On the page, down is d and right is n, which is a pure rotation (no mirroring).
ends <- st_coordinates(load_transect())[, 1:2]
d <- ends[2, ] - ends[1, ]
len <- sqrt(sum(d^2))
d <- d / len
n <- c(-d[2], d[1])
len_km <- crs_to_km(len)

# Sample NLCD ---------------------------------------------------------------
u <- seq(-half_w + grid_km / 2, len_km + half_w, by = grid_km)
v <- seq(-half_w + grid_km / 2, half_w, by = grid_km)
grid <- expand.grid(v = v, u = u)     # row order: v varies fastest, one image row per u

# Keep only the AOI: the strip between the endpoints plus the round end caps.
along <- pmax(-grid$u, grid$u - len_km, 0)
inside <- sqrt(along^2 + grid$v^2) <= half_w

xy <- cbind(ends[1, 1] + km_to_crs(grid$u) * d[1] + km_to_crs(grid$v) * n[1],
            ends[1, 2] + km_to_crs(grid$u) * d[2] + km_to_crs(grid$v) * n[2])
xy_lc <- sf_project(st_crs(cfg$crs), st_crs(crs(lc)), xy)
cls <- values(lc)[cellFromXY(lc, xy_lc), 1]
cls[!inside] <- NA
lc_groups <- lapply(lc_groups, intersect, unique(cls))
lc_groups <- lc_groups[lengths(lc_groups) > 0]

# Check against the window summaries from R/05_nlcd.R ------------------------
# Fractions for each window from this grid should match the exactextractr values.
stored <- read.csv(here(cfg$paths$derived, "nlcd_window_classes.csv"))
win_id <- findInterval(grid$u, c(windows$u_start_km, len_km), left.open = TRUE)
in_win <- grid$u >= 0 & grid$u <= len_km & abs(grid$v) <= half_w
tab <- as.data.frame(prop.table(table(window = win_id[in_win], class = cls[in_win]), 1),
                     responseName = "frac_grid", stringsAsFactors = FALSE)
tab[c("window", "class")] <- lapply(tab[c("window", "class")], as.integer)
chk <- merge(stored, tab, by = c("window", "class"), all = TRUE)
chk[is.na(chk)] <- 0
worst <- max(abs(chk$frac - chk$frac_grid))
message(sprintf("Largest class-share difference from nlcd_window_classes.csv: %.2f percentage points",
                100 * worst))
if (worst > 0.02) stop("Rotated grid does not match the window summaries")

# Colors from the NLCD color table in the raster
ct <- coltab(lc)[[1]]
ct_hex <- setNames(rgb(ct$red, ct$green, ct$blue, maxColorValue = 255), ct[[1]])
img <- matrix(ifelse(is.na(cls), "transparent", ct_hex[as.character(cls)]),
              nrow = length(u), ncol = length(v), byrow = TRUE)

# Figure --------------------------------------------------------------------
# Everything is drawn in km on one true-scale coordinate system: x = v, y = -u.
km_per_in <- 2 * half_w / (fig_width_in - left_in - right_in)
fig_height_in <- (len_km + 2 * half_w) / km_per_in + 2 * label_in

draw <- function() {
  x0 <- -half_w - left_in * km_per_in
  y1 <- half_w + label_in * km_per_in
  op <- par(mai = rep(0, 4), xaxs = "i", yaxs = "i", ps = font_pt, cex = 1, lend = "butt")
  on.exit(par(op))
  plot.new()
  plot.window(xlim = c(x0, x0 + fig_width_in * km_per_in),
              ylim = c(y1 - fig_height_in * km_per_in, y1))

  rasterImage(as.raster(img), -half_w, -len_km - half_w, half_w, half_w, interpolate = FALSE)
  rect(-half_w, -windows$u_end_km, half_w, -windows$u_start_km, border = "grey20", lwd = 0.35)
  segments(0, 0, 0, -len_km, col = "black", lty = 2, lwd = 0.7)

  # Distance along the transect; the 1 km windows also serve as the scale
  km <- seq(0, floor(len_km), by = 5)
  tick <- 0.3
  segments(-half_w - tick, -km, -half_w, -km, lwd = 0.5)
  text(-half_w - tick * 1.3, -km, labels = c("0 km", km[-1]), adj = c(1, 0.5))

  # Place names
  text(0, half_w + label_in * km_per_in / 2, "Richmond", font = 2)
  text(0, -len_km - half_w - label_in * km_per_in / 2, "Pocahontas State Park", font = 2)

  # North arrow, in the corner beside the Richmond end cap (north = (0, 1) in the project CRS)
  north <- c(n[2], -d[2])
  base <- c(-half_w - 0.45, half_w - 1.25)
  tip <- base + 1.1 * north
  arrows(base[1], base[2], tip[1], tip[2], length = 0.05, lwd = 0.8)
  text(tip[1] + 0.35 * north[1], tip[2] + 0.5 * north[2], "N", font = 2)

  # Legend in one column down the right edge of the map: each group name, turned -90 degrees
  # (reading downward), followed by its swatches
  sw <- 0.11 * km_per_in
  gap <- 0.1 * km_per_in
  pad <- 0.03 * km_per_in
  xl <- half_w + pad
  y <- 0
  for (g in names(lc_groups)) {
    cl <- lc_groups[[g]]
    label_len <- strwidth(g, units = "inches") * km_per_in
    text(xl + sw / 2, y - label_len / 2, g, srt = -90, adj = c(0.5, 0.5))
    y <- y - label_len - pad
    tops <- y - (seq_along(cl) - 1) * sw
    rect(xl, tops - sw, xl + sw, tops, col = ct_hex[as.character(cl)],
         border = "grey20", lwd = 0.35)
    y <- y - length(cl) * sw - gap
  }
}

out <- here("media", "lc_map_vertical")
agg_png(paste0(out, ".png"), width = fig_width_in, height = fig_height_in, units = "in",
        res = 600, background = "white")
draw()
invisible(dev.off())

pdf(paste0(out, ".pdf"), width = fig_width_in, height = fig_height_in, bg = "white",
    useDingbats = FALSE)
draw()
invisible(dev.off())

message(sprintf("Wrote %s.png and .pdf (%.2f x %.2f in)", out, fig_width_in, fig_height_in))
