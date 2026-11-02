# 05b_ndvi_calibration.R
# Calibrate the vegetation indices used to find evergreen crowns (run before 06).
#
# In this leaf-off imagery NDVI depends strongly on brightness: in shadow the red band falls
# nearly to zero while the NIR band stays high (light scattered by surrounding vegetation), so
# shadowed bare hardwood reaches NDVI ~0.6, like evergreen foliage. The brightness-adjusted
# index removes this:
#
#   ndvi_adj = (NDVI - mean(b)) / sd(b)
#
# where b = brightness = (red + green + blue) / 3, and mean(b) and sd(b) are the mean and spread
# of NDVI among pixels in NLCD deciduous forest (class 41) at that brightness (loess fits).
# ndvi_adj is in units of deciduous-forest standard deviations: ~0 for bare hardwood at any
# brightness, positive for foliage greener than leaf-off forest. Standardizing matters because
# NDVI also gets noisier in shadow (red near zero), so a fixed offset would still pass many
# dark pixels.
#
# Sample: random points in the AOI, each with its 3 x 3 px neighbourhood (the smoothing used
# in crown extraction), NLCD class, brightness, and GLI, NDVI, ndvi_adj (3 x 3 means).
#
# Inputs:  data/derived/ortho_12in.vrt (4-band), data/derived/aoi.gpkg, NLCD LndCov
# Outputs: data/derived/ndvi_shadow_curve.csv - brightness (0-255) -> deciduous NDVI mean, sd
#          data/derived/ndvi_calibration.csv  - calibration sample
# The thresholds in config.yml (holly$thresholds$ndvi_adj) are set from the quantiles printed
# at the end.

library(sf)
library(terra)
library(here)

source(here("R", "functions.R"))

n_cal <- 60000
set.seed(1)
pts <- st_sample(load_aoi(), n_cal)
ortho <- load_ortho(aoi = FALSE)
if (!"nir" %in% names(ortho)) stop("Calibration needs the 4-band imagery.")
adj <- adjacent(ortho, cellFromXY(ortho, st_coordinates(pts)), directions = "queen",
                include = TRUE)                    # n x 9: each point's 3 x 3 px neighbourhood
vals <- ortho[as.vector(adj)]
vals$brightness <- (vals$red + vals$green + vals$blue) / 3
vals$ndvi <- unname(veg_index(vals, "ndvi"))
lc <- rast(here(cfg$nlcd$dir, sprintf("LndCov_%d.tif", cfg$nlcd$year)))
nlcd <- extract(lc, vect(st_transform(pts, crs(lc))))[, 2]

# Shadow curve: pixel-level NDVI of deciduous forest against brightness
dec_px <- vals[rep(nlcd, 9) %in% 41 & is.finite(vals$ndvi), ]
fit <- loess(ndvi ~ brightness, dec_px, span = 0.3, degree = 1,
             control = loess.control(surface = "direct"))
rng <- quantile(dec_px$brightness, c(0.001, 0.999))
curve <- data.frame(brightness = 0:255)
# Fitted inside the data range, held constant beyond it
b_clamped <- data.frame(brightness = pmin(pmax(curve$brightness, rng[1]), rng[2]))
curve$ndvi <- predict(fit, b_clamped)
# Spread: loess of absolute residuals; E|e| = sd * sqrt(2 / pi) for normal errors
dec_px$abs_res <- abs(residuals(fit))
fit_sd <- loess(abs_res ~ brightness, dec_px, span = 0.3, degree = 1,
                control = loess.control(surface = "direct"))
curve$sd <- predict(fit_sd, b_clamped) * sqrt(pi / 2)
write.csv(curve, here(cfg$paths$derived, "ndvi_shadow_curve.csv"), row.names = FALSE)

# Calibration sample: 3 x 3 means of each index
vals$ndvi_adj <- unname(veg_index(vals, "ndvi_adj"))
smooth3 <- function(x) rowMeans(matrix(x, nrow(adj)))
cal <- data.frame(nlcd = nlcd,
                  brightness = smooth3(vals$brightness),
                  gli = smooth3(unname(veg_index(vals, "gli"))),
                  ndvi = smooth3(vals$ndvi),
                  ndvi_adj = smooth3(vals$ndvi_adj))
write.csv(cal, here(cfg$paths$derived, "ndvi_calibration.csv"), row.names = FALSE)

# Threshold guide: deciduous-forest quantiles (false-positive rates) and evergreen exceedance
dec <- cal[cal$nlcd %in% 41, ]
evg <- cal[cal$nlcd %in% 42, ]
for (ix in c("gli", "ndvi", "ndvi_adj")) {
  q <- quantile(dec[[ix]], c(0.90, 0.975), na.rm = TRUE)
  message(sprintf("%-8s deciduous 90%% %.3f (evergreen above %.0f%%), 97.5%% %.3f (evergreen above %.0f%%)",
                  ix, q[1], 100 * mean(evg[[ix]] > q[1], na.rm = TRUE),
                  q[2], 100 * mean(evg[[ix]] > q[2], na.rm = TRUE)))
}
