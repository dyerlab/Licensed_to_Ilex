# 08_focal_trees.R
# Choose focal holly trees for field work, balanced across an urbanization gradient.
#
# 1. Pool: crowns that pass the size and isolation parts of the candidate rule, anywhere on
#    land (developed land included, so the urban end can be sampled), not cut by a tile edge.
# 2. Landscape context: on the native 30 m NLCD grid, metrics within a circular neighbourhood
#    (cfg$focal$buffer_m) of every cell:
#      imperv_mean, imperv_sd   fractional impervious surface: mean and heterogeneity
#      forest_pct, developed_pct share of forest (41-43) and developed (21-24) cover
#      shdi, shei               Shannon diversity and evenness of grouped land cover
#      edge_density             m of edge between grouped cover types per ha
#    Neighbourhoods are truncated at the edge of the NLCD extract (AOI bounding box + margin);
#    metrics use only the cells present.
# 3. Indices: urbanization index = imperv_mean (%); heterogeneity index = PC1 of the
#    standardized heterogeneity metrics (cfg$focal$heterogeneity_metrics) over AOI cells.
# 4. Selection: the urbanization index range of the pool (1st-99th percentile) is cut into
#    cfg$focal$n_bins equal-width bins (on the arcsine-square-root scale of the impervious
#    fraction, cfg$focal$urban_transform), and each bin gets the same number of trees. Within a bin,
#    trees are picked one at a time by greedy maximin on (heterogeneity index, distance along
#    transect), so they
#    spread across heterogeneity and space, and every tree must be at least
#    cfg$focal$min_spacing_m from every tree already picked (all bins). Bins with the fewest
#    eligible crowns are filled first. Alternates are picked the same way after the primaries,
#    so the whole list (primaries + alternates) respects the spacing.
#
# Inputs:  data/derived/holly_objects.gpkg, NLCD LndCov and FctImp
# Outputs: data/derived/landscape_30m.tif   - metric rasters + PC1/PC2 (30 m, EPSG:5070)
#          data/derived/landscape_pca.csv   - heterogeneity PCA loadings, variance explained
#          data/derived/focal_bins.csv      - bin edges (impervious %) and pool size per bin
#          data/derived/focal_trees.{gpkg,csv,gpx} - primaries and alternates with metrics

library(sf)
library(terra)
library(here)

source(here("R", "functions.R"))

fc <- cfg$focal
set.seed(fc$seed)
derived <- here(cfg$paths$derived)

# Landscape metrics on the 30 m grid -----------------------------------------------
lc  <- rast(here(cfg$nlcd$dir, sprintf("LndCov_%d.tif", cfg$nlcd$year)))
imp <- rast(here(cfg$nlcd$dir, sprintf("FctImp_%d.tif", cfg$nlcd$year)))
groups <- list(water = 11:12, developed_open = 21, developed = 22:24, barren = 31,
               forest = 41:43, shrub_grass = c(52, 71), agriculture = 81:82,
               wetland = c(90, 95))
rcl <- do.call(rbind, lapply(seq_along(groups), function(i) cbind(groups[[i]], i)))
g <- classify(lc, rcl, others = NA)

w <- focalMat(lc, fc$buffer_m, "circle")
w[w > 0] <- 1
nmean <- function(x) {          # neighbourhood mean using only cells with data
  focal(x, w, "sum", na.rm = TRUE) / focal(!is.na(x), w, "sum", na.rm = TRUE)
}

p <- rast(lapply(seq_along(groups), function(i) nmean(g == i)))
names(p) <- names(groups)
shdi <- app(p, function(x) { x <- x[!is.na(x) & x > 0]; -sum(x * log(x)) })
nk   <- app(p > 0, sum, na.rm = TRUE)
shei <- ifel(nk > 1, shdi / log(nk), 0)

# Edges between grouped classes: count of the 4 neighbours in a different group; each shared
# edge (30 m) is split between its two cells
cell_m <- res(lc)[1]
nb <- function(pos) { m <- matrix(0, 3, 3); m[pos] <- 1; focal(g, m, "sum") }
diff4 <- Reduce(`+`, lapply(c(2, 4, 6, 8), function(pos) {
  d <- nb(pos) != g
  ifel(is.na(d), 0, d)
}))
edge_m <- diff4 * cell_m / 2
cell_ha <- cell_m^2 / 1e4

imp_mean <- nmean(imp)
imp_var <- nmean(imp^2) - imp_mean^2
land <- list(
  imperv_mean   = imp_mean,
  imperv_sd     = sqrt(ifel(imp_var < 0, 0, imp_var)),
  forest_pct    = 100 * p[["forest"]],
  developed_pct = 100 * (p[["developed"]] + p[["developed_open"]]),
  shdi          = shdi,
  shei          = shei,
  edge_density  = nmean(edge_m) / cell_ha
)
land <- setNames(rast(land), names(land))

# Indices --------------------------------------------------------------------------
# Urbanization index: mean impervious surface (%) in the neighbourhood. A PCA of all metrics was
# tried first, but its PC1 saturates at the urban end (forest and developed shares reach 0% and
# 100% well before the urban core), so it could not tell suburbs from downtown.
# Heterogeneity index: PC1 of the heterogeneity metrics over AOI cells, + = more heterogeneous.
het_vars <- cfg$focal$heterogeneity_metrics
aoi_lc <- vect(st_transform(load_aoi(), crs(lc)))
v <- na.omit(as.data.frame(mask(land[[het_vars]], aoi_lc), na.rm = FALSE))
pca <- prcomp(v, center = TRUE, scale. = TRUE)
rot <- pca$rotation[, 1, drop = FALSE] * sign(pca$rotation["shdi", 1])
het <- app(land[[het_vars]], function(x) {
  scale(as.matrix(x), center = pca$center, scale = pca$scale) %*% rot
})
pcs <- c(land[["imperv_mean"]], het)
names(pcs) <- c("urban_index", "heterogeneity_index")
writeRaster(c(land, pcs), file.path(derived, "landscape_30m.tif"), overwrite = TRUE,
            gdal = c("COMPRESS=DEFLATE", "TILED=YES"))
ve <- pca$sdev^2 / sum(pca$sdev^2)
write.csv(data.frame(metric = rownames(rot), loading = rot[, 1], var_explained = ve[1]),
          file.path(derived, "landscape_pca.csv"), row.names = FALSE)

# Pool of crowns -----------------------------------------------------------------
h <- cfg$holly
h$exclude_nlcd <- fc$exclude_nlcd           # developed land allowed for focal trees
obj <- holly_candidates(load_holly_objects(), h)
pool <- obj[obj$candidate & !obj$tile_edge, ]
cent <- st_centroid(st_geometry(pool))
vals <- extract(c(land, pcs), vect(st_transform(cent, crs(lc))))[, -1]
pool <- cbind(pool, vals)
pool <- pool[complete.cases(st_drop_geometry(pool)[, names(vals)]), ]
xy <- st_coordinates(st_centroid(st_geometry(pool)))

# Bins are equal-width on the arcsine-square-root of the impervious fraction, which gives the
# forest end (0-10% impervious) and the urban core (50-75%) similar resolution; equal-width bins
# on the raw percentage put the whole forest end into one bin.
to_bin_scale <- function(x) switch(fc$urban_transform,
  asinsqrt = asin(sqrt(pmin(pmax(x / 100, 0), 1))),
  none = x,
  stop("Unknown urban_transform: ", fc$urban_transform))
ub <- to_bin_scale(pool$urban_index)
lim <- quantile(ub, c(0.01, 0.99))
breaks <- seq(lim[1], lim[2], length.out = fc$n_bins + 1)
pool$bin <- findInterval(ub, breaks, all.inside = TRUE)
pool$bin[ub < lim[1] | ub > lim[2]] <- NA
bin_edges <- if (fc$urban_transform == "asinsqrt") 100 * sin(breaks)^2 else breaks
write.csv(data.frame(bin = seq_len(fc$n_bins), imperv_from = head(bin_edges, -1),
                     imperv_to = bin_edges[-1], pool_crowns = tabulate(pool$bin, fc$n_bins)),
          file.path(derived, "focal_bins.csv"), row.names = FALSE)

# Greedy selection -----------------------------------------------------------------
min_sep <- km_to_crs(fc$min_spacing_m / 1000)
per_bin <- fc$n_trees / fc$n_bins
n_take  <- per_bin + fc$alternates_per_bin
feat <- scale(cbind(pool$heterogeneity_index, pool$u_km))   # spread within a bin
chosen <- integer(0)
role <- character(0)
bin_order <- order(tabulate(pool$bin, fc$n_bins))            # scarcest bins first

for (b in bin_order) {
  idx <- which(pool$bin == b)
  picked <- integer(0)
  while (length(picked) < n_take) {
    ok <- idx[!idx %in% chosen]
    if (length(chosen)) {
      dmin <- apply(as.matrix(dist(rbind(xy[chosen, , drop = FALSE], xy[ok, , drop = FALSE])))[
        seq_along(chosen), length(chosen) + seq_along(ok), drop = FALSE], 2, min)
      ok <- ok[dmin >= min_sep]
    }
    if (!length(ok)) break
    nxt <- if (!length(picked)) {
      ok[sample.int(length(ok), 1)]
    } else {
      fd <- sapply(ok, function(i) min(colSums((t(feat[picked, , drop = FALSE]) - feat[i, ])^2)))
      ok[which.max(fd)]
    }
    picked <- c(picked, nxt)
    chosen <- c(chosen, nxt)
    role <- c(role, if (length(picked) <= per_bin) "primary" else "alternate")
  }
  if (length(picked) < per_bin) {
    warning(sprintf("Bin %d: only %d eligible trees (wanted %d)", b, length(picked), per_bin))
  }
}

sel <- pool[chosen, ]
sel$role <- role
sel <- sel[order(sel$role != "primary", sel$bin, sel$u_km), ]
sel$focal_id <- sprintf("F%03d", seq_len(nrow(sel)))
rownames(sel) <- NULL

keep <- c("focal_id", "role", "bin", "urban_index", "heterogeneity_index", "obj_id",
          "lat", "lon", "u_km", "v_km", "window", "nlcd", "diam_ft", "context", "vi_mean",
          names(land))
sel <- sel[, keep]
st_write(sel, file.path(derived, "focal_trees.gpkg"), delete_dsn = TRUE, quiet = TRUE)
write.csv(st_drop_geometry(sel), file.path(derived, "focal_trees.csv"), row.names = FALSE)
gpx <- st_as_sf(data.frame(name = sel$focal_id,
                           desc = sprintf("%s, bin %d, %.0f ft crown, %.1f km", sel$role, sel$bin,
                                          sel$diam_ft, sel$u_km),
                           lon = sel$lon, lat = sel$lat),
                coords = c("lon", "lat"), crs = 4326)
gpx_path <- file.path(derived, "focal_trees.gpx")
if (file.exists(gpx_path)) file.remove(gpx_path)
st_write(gpx, gpx_path, driver = "GPX", layer = "waypoints", quiet = TRUE)

# Check spacing
d <- as.matrix(dist(st_coordinates(st_centroid(st_geometry(sel)))))
diag(d) <- Inf
message(sprintf("Pool %s crowns; selected %d primaries + %d alternates; min spacing %.0f m",
                format(nrow(pool), big.mark = ","), sum(sel$role == "primary"),
                sum(sel$role == "alternate"), min(d) * crs_to_km(1) * 1000))
print(table(bin = sel$bin, role = sel$role))
print(round(rot, 2)); print(round(ve, 3))
