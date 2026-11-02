# Licensed to *Ilex*

> Because we can, we will, and we won't stop....

Analyses of 2025 Virginia Base Mapping Program (VBMP) 12-inch orthoimagery along a 25 km
transect from industrial Richmond, Virginia (37.584817° N, 77.472433° W) to Pocahontas State
Park (37.373768° N, 77.570813° W), buffered by 2 km on each side.

## Rendered analyses

Site home: <https://dyerlab.github.io/Licensed_to_Ilex/>

1. [Study area and orthoimagery](https://dyerlab.github.io/Licensed_to_Ilex/analyses/01_study_area.html) (source: [`analyses/01_study_area.qmd`](analyses/01_study_area.qmd))
   - [Purpose and workflow](https://dyerlab.github.io/Licensed_to_Ilex/analyses/01_study_area.html#purpose)
   - [Study area and interactive map](https://dyerlab.github.io/Licensed_to_Ilex/analyses/01_study_area.html#study-area)
   - [Orthoimagery tiles](https://dyerlab.github.io/Licensed_to_Ilex/analyses/01_study_area.html#orthoimagery-tiles)
   - [Tiles required to reproduce](https://dyerlab.github.io/Licensed_to_Ilex/analyses/01_study_area.html#tiles-required-to-reproduce)
   - [Mosaic preview](https://dyerlab.github.io/Licensed_to_Ilex/analyses/01_study_area.html#mosaic)
   - [Notes](https://dyerlab.github.io/Licensed_to_Ilex/analyses/01_study_area.html#notes)
2. [Urban to forest gradient](https://dyerlab.github.io/Licensed_to_Ilex/analyses/02_gradient.html) (source: [`analyses/02_gradient.qmd`](analyses/02_gradient.qmd))
   - [Purpose](https://dyerlab.github.io/Licensed_to_Ilex/analyses/02_gradient.html#purpose)
   - [Windows and interactive map](https://dyerlab.github.io/Licensed_to_Ilex/analyses/02_gradient.html#windows)
   - [Land cover](https://dyerlab.github.io/Licensed_to_Ilex/analyses/02_gradient.html#land-cover)
   - [Gradient](https://dyerlab.github.io/Licensed_to_Ilex/analyses/02_gradient.html#gradient)
   - [Window table](https://dyerlab.github.io/Licensed_to_Ilex/analyses/02_gradient.html#window-table)
   - [Notes](https://dyerlab.github.io/Licensed_to_Ilex/analyses/02_gradient.html#notes)
3. [Holly candidates](https://dyerlab.github.io/Licensed_to_Ilex/analyses/03_holly_classification.html) (source: [`analyses/03_holly_classification.qmd`](analyses/03_holly_classification.qmd))
   - [Purpose](https://dyerlab.github.io/Licensed_to_Ilex/analyses/03_holly_classification.html#purpose)
   - [Why NDVI and measuring the gain from NIR](https://dyerlab.github.io/Licensed_to_Ilex/analyses/03_holly_classification.html#why-ndvi)
   - [Approach and example](https://dyerlab.github.io/Licensed_to_Ilex/analyses/03_holly_classification.html#approach)
   - [Candidates, map, and density along the transect](https://dyerlab.github.io/Licensed_to_Ilex/analyses/03_holly_classification.html#candidates)
   - [Ground truth](https://dyerlab.github.io/Licensed_to_Ilex/analyses/03_holly_classification.html#ground-truth)
   - [Next steps](https://dyerlab.github.io/Licensed_to_Ilex/analyses/03_holly_classification.html#next-steps)
   - [Notes](https://dyerlab.github.io/Licensed_to_Ilex/analyses/03_holly_classification.html#notes)

<!-- When adding an analysis: add analyses/NN_name.qmd, list it in _quarto.yml and index.qmd,
     then add an entry here (section anchors are the lowercased, hyphenated headings). -->

## Repository layout

```
config.yml          transect endpoints, buffer, CRS, and paths
R/                  analysis scripts (run in order) and shared helpers (functions.R)
python/             MrSID to GeoTIFF conversion (earlier RGB imagery only; no longer needed)
analyses/           Quarto documents describing and visualizing each step
index.qmd           website home page
docs/               rendered website (served by GitHub Pages)
data/               local only, not tracked by git (see below)
```

## Data

No imagery is stored in this repository. To reproduce, download the following from the
[VGIN VBMP](https://vgin.vdem.virginia.gov/) 2025 orthoimagery release into `data/raw/`:

| Folder | Contents |
|---|---|
| `data/raw/tile_index/` | VBMP 2025 tile index shapefiles (`2025_VGIN_12in_{South,North}_Tiles.*`) |
| `data/raw/tiles_tif/` | 12-inch 4-band GeoTIFF tiles (`.tif` + `.tfw`, red/green/blue/NIR) listed on the [study area page](https://dyerlab.github.io/Licensed_to_Ilex/analyses/01_study_area.html), from the VGIN Box share under `2025_TIF/south/200/` |
| `data/raw/metadata/` | VBMP 2025 metadata XML (optional, for reference) |

`R/02_select_tiles.R` reports which tiles are needed and which are missing, so you can also
run steps 1–2 with only the tile index and download tiles afterwards.

## Workflow

Requirements: R (sf, terra, units, dplyr, tidyr, ggplot2, leaflet, exactextractr, httr, yaml, here, xml2) and Quarto.

```sh
Rscript R/01_build_aoi.R       # transect line and 2 km buffer       -> data/derived/aoi.gpkg
Rscript R/02_select_tiles.R    # tiles intersecting the buffer       -> data/derived/tiles_needed.csv
# Download the listed 4-band GeoTIFFs (.tif + .tfw)              -> data/raw/tiles_tif/
Rscript R/03_build_vrt.R       # virtual mosaic + preview            -> data/derived/ortho_12in.vrt
Rscript R/04_transect_windows.R  # 1 km windows along the transect  -> data/derived/transect_windows.gpkg
Rscript R/05_nlcd.R            # Annual NLCD download + summaries    -> data/derived/nlcd_windows.csv
Rscript R/06_holly_objects.R   # evergreen crowns + holly candidates -> data/derived/holly_candidates.csv
quarto render                  # rebuild the website                 -> docs/
```

In analysis code, load the imagery with:

```r
source(here::here("R", "functions.R"))
ortho <- load_ortho()          # mosaic limited to the study area, read lazily
```

All coordinates are NAD83(HARN) / Virginia South (ftUS), EPSG:2925, the native CRS of the
imagery; nothing is resampled.
