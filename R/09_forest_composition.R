# 09_forest_composition.R
# Split NLCD forest (classes 41-43) into evergreen and deciduous shares using the leaf-off imagery.
#
# In February-March imagery, evergreen foliage (pine, cedar, holly, laurel) is green and has high
# brightness-adjusted NDVI (ndvi_adj, R/05b_ndvi_calibration.R); bare hardwood canopy is near 0.
# A per-pixel threshold gives a biased share, because the two distributions overlap (deciduous
# ~N(0, 0.7), evergreen ~N(1.5, 0.6) in ndvi_adj units): a threshold low enough to catch most
# evergreen also passes many deciduous pixels, and the bias depends on the true mix.
# Instead, a two-component Gaussian mixture is fitted to ndvi_adj of random forest points (3 x 3
# px means, the smoothing used for crowns), pooled over the whole study area. Holding the two
# components fixed, the evergreen mixing weight is then estimated separately for each NLCD class
# and each 1 km window (EM on one parameter). That weight is the estimated share of forest area
# whose visible winter foliage is evergreen.
#
# Check: NLCD defines 41 as < 25% evergreen, 42 as > 75%, and 43 in between, so the class
# estimates should fall in those ranges.
# Uncertainty: bootstrap, resampling points within each window (and end caps) and refitting the
# mixture each time, so it includes the uncertainty in the components.
#
# Leaf-off caveat: evergreen understory (holly, cedar, laurel) seen through bare hardwood canopy
# counts as evergreen, so this is "evergreen foliage visible from above in winter", which can be
# higher than the leaf-on evergreen share of the canopy.
#
# Inputs:  data/derived/ortho_12in.vrt (4-band), data/derived/aoi.gpkg, transect_windows.gpkg,
#          NLCD LndCov, data/derived/ndvi_shadow_curve.csv, nlcd_windows.csv
# Outputs: data/derived/forest_points.csv       - sample: window, u_km, nlcd, brightness, ndvi_adj
#          data/derived/forest_mixture.csv      - mixture components (mean, sd, weight), bootstrap
#          data/derived/forest_composition.csv  - evergreen share by group (class, window, all)

library(sf)
library(terra)
library(mclust)
library(here)

source(here("R", "functions.R"))

fc <- cfg$forest_composition
set.seed(fc$seed)
forest <- c(41, 42, 43)
derived <- here(cfg$paths$derived)

# Sample forest points ---------------------------------------------------------------
lc <- rast(here(cfg$nlcd$dir, sprintf("LndCov_%d.tif", cfg$nlcd$year)))
pts <- st_sample(load_aoi(), fc$candidate_points)
nlcd <- extract(lc, vect(st_transform(pts, crs(lc))))[, 2]
pts <- st_sf(nlcd = nlcd, geometry = pts)[nlcd %in% forest, ]
pos <- transect_position(x = pts)
pts$u_km <- pos$u_km
pts$window <- pos$window
pts$stratum <- ifelse(is.na(pts$window), 0L, pts$window)          # 0 = end caps

# Same sampling density everywhere: keep a fixed fraction of the forest candidates, set so the
# window with the most forest gets about points_per_window points
n_avail <- table(pts$window)
frac <- min(1, fc$points_per_window / max(n_avail))
keep <- which(runif(nrow(pts)) < frac)
pts <- pts[keep, ]
message(sprintf("%d forest points (%.0f%% of forest candidates)", nrow(pts), 100 * frac))

win <- load_windows()
ortho <- load_ortho(aoi = FALSE)
if (!"nir" %in% names(ortho)) stop("Needs the 4-band imagery.")
adj <- adjacent(ortho, cellFromXY(ortho, st_coordinates(pts)), directions = "queen",
                include = TRUE)
vals <- ortho[as.vector(adj)]
vals$brightness <- (vals$red + vals$green + vals$blue) / 3
smooth3 <- function(x) rowMeans(matrix(x, nrow(adj)))
pts$brightness <- smooth3(vals$brightness)
pts$ndvi_adj <- smooth3(unname(veg_index(vals, "ndvi_adj")))
pts <- pts[is.finite(pts$ndvi_adj), ]
d <- st_drop_geometry(pts)
write.csv(d[, c("stratum", "window", "u_km", "nlcd", "brightness", "ndvi_adj")],
          file.path(derived, "forest_points.csv"), row.names = FALSE)

# Mixture -------------------------------------------------------------------------------
fit_mix <- function(x) {
  m <- Mclust(x, G = fc$components, modelNames = "V", verbose = FALSE)
  o <- order(m$parameters$mean)
  list(mean = m$parameters$mean[o], sd = sqrt(m$parameters$variance$sigmasq)[o],
       pro = m$parameters$pro[o])
}
# Evergreen weight with components fixed (EM on the weight only); evergreen = highest mean
evg_weight <- function(x, comp) {
  k <- length(comp$mean)
  dens <- sapply(seq_len(k), function(j) dnorm(x, comp$mean[j], comp$sd[j]))
  p <- comp$pro
  for (i in 1:500) {
    r <- sweep(dens, 2, p, "*")
    r <- r / rowSums(r)
    p_new <- colMeans(r)
    if (max(abs(p_new - p)) < 1e-6) break
    p <- p_new
  }
  p[k]
}

estimate <- function(d, comp) {
  sapply(groups_of(d), function(g) if (sum(g) >= 30) evg_weight(d$ndvi_adj[g], comp) else NA)
}
groups_of <- function(d) {
  c(list(all = rep(TRUE, nrow(d))),
    setNames(lapply(forest, function(k) d$nlcd == k), paste0("nlcd_", forest)),
    setNames(lapply(seq_len(nrow(win)), function(w) d$window %in% w),
             paste0("window_", seq_len(nrow(win)))))
}

x_ok <- function(x) x > -5 & x < 8                                   # drop rare extreme values
comp <- fit_mix(d$ndvi_adj[x_ok(d$ndvi_adj)])
est <- estimate(d, comp)

boot <- replicate(fc$n_boot, {
  b <- d[unlist(lapply(split(seq_len(nrow(d)), d$stratum),
                       function(i) i[sample.int(length(i), length(i), replace = TRUE)])), ]
  cb <- fit_mix(b$ndvi_adj[x_ok(b$ndvi_adj)])
  c(estimate(b, cb), mu_dec = unname(cb$mean[1]), mu_evg = unname(cb$mean[fc$components]))
})

nm <- names(est)
out <- data.frame(group = nm, n = sapply(groups_of(d), sum), evg_share = est,
                  lo = apply(boot[nm, ], 1, quantile, 0.025, na.rm = TRUE),
                  hi = apply(boot[nm, ], 1, quantile, 0.975, na.rm = TRUE),
                  share_gt_crown = sapply(groups_of(d), function(g)
                    mean(d$ndvi_adj[g] > cfg$holly$thresholds$ndvi_adj$crown)),
                  row.names = NULL)
out$window <- suppressWarnings(as.integer(sub("^window_", "", out$group)))
out$u_mid_km <- win$u_mid_km[match(out$window, win$window)]

# Forest area per window (NLCD) split into evergreen and deciduous
nw <- read.csv(file.path(derived, "nlcd_windows.csv"))
out$forest_km2 <- with(nw, area_km2 * forest_pct / 100)[match(out$window, nw$window)]
out$evg_km2 <- out$forest_km2 * out$evg_share
out$dec_km2 <- out$forest_km2 - out$evg_km2
# Study-wide total over the windows, area-weighted (end caps excluded)
w <- !is.na(out$window) & out$n >= 30
tot <- data.frame(group = "windows_total", n = sum(out$n[w]),
                  evg_share = sum(out$evg_km2[w]) / sum(out$forest_km2[w]),
                  lo = NA, hi = NA, share_gt_crown = NA, window = NA, u_mid_km = NA,
                  forest_km2 = sum(out$forest_km2[w]), evg_km2 = sum(out$evg_km2[w]),
                  dec_km2 = sum(out$dec_km2[w]))
wb <- boot[paste0("window_", out$window[w]), ]
tot_b <- colSums(wb * out$forest_km2[w]) / tot$forest_km2
tot$lo <- quantile(tot_b, 0.025); tot$hi <- quantile(tot_b, 0.975)
out <- rbind(out, tot)
write.csv(out, file.path(derived, "forest_composition.csv"), row.names = FALSE)

write.csv(data.frame(component = c("deciduous", rep("other", fc$components - 2), "evergreen"),
                     mean = comp$mean, sd = comp$sd, weight = comp$pro,
                     mean_lo = c(quantile(boot["mu_dec", ], 0.025), rep(NA, fc$components - 2),
                                 quantile(boot["mu_evg", ], 0.025)),
                     mean_hi = c(quantile(boot["mu_dec", ], 0.975), rep(NA, fc$components - 2),
                                 quantile(boot["mu_evg", ], 0.975))),
          file.path(derived, "forest_mixture.csv"), row.names = FALSE)

print(data.frame(comp))
print(transform(out[, c("group", "n", "evg_share", "lo", "hi", "share_gt_crown", "forest_km2")],
                evg_share = round(evg_share, 3), lo = round(lo, 3), hi = round(hi, 3),
                share_gt_crown = round(share_gt_crown, 3), forest_km2 = round(forest_km2, 2)))
