"""
Convert the MrSID tiles listed in data/derived/tiles_needed.csv to GeoTIFF.

Run from the QGIS Python console (the MrSID driver only loads inside QGIS):
    exec(open("/path/to/Licensed_to_Ilex/python/convert_mrsid.py").read())

Set PROJECT_DIR below to your copy of the repository first.

The file list is produced by R/02_select_tiles.R. Only rows with status == "local"
are converted; tiles already converted are skipped, so it is safe to re-run.
"""
import csv
import os
from datetime import datetime
from osgeo import gdal

# Project root: the only path to edit if the project folder moves
PROJECT_DIR = os.path.expanduser("~/Projects/Licensed_to_Ilex")
FILE_LIST = os.path.join(PROJECT_DIR, "data", "derived", "tiles_needed.csv")
LOG_FILE = os.path.join(PROJECT_DIR, "data", "derived", "conversion_log.csv")
OUTPUT_SRS = "EPSG:2925"  # NAD83(HARN) / Virginia South (ftUS)

gdal.AllRegister()
gdal.UseExceptions()
if gdal.GetDriverByName("MrSID") is None:
    raise RuntimeError("MrSID driver not registered. Run this from the QGIS Python console.")

with open(FILE_LIST, newline="") as f:
    rows = [r for r in csv.DictReader(f) if r["status"] == "local"]

new_log = not os.path.exists(LOG_FILE)
log = open(LOG_FILE, "a", newline="")
logw = csv.writer(log)
if new_log:
    logw.writerow(["timestamp", "tile_name", "result", "message"])

options = gdal.TranslateOptions(
    format="GTiff",
    outputSRS=OUTPUT_SRS,
    creationOptions=["COMPRESS=LZW", "TILED=YES", "BIGTIFF=IF_SAFER"],
)

n_done = n_skip = n_err = 0
for i, r in enumerate(rows, start=1):
    # Paths in the file list are relative to the project root
    name = r["tile_name"]
    src = os.path.join(PROJECT_DIR, r["sid_path"])
    dst = os.path.join(PROJECT_DIR, r["tif_path"])
    if os.path.exists(dst):
        n_skip += 1
        continue
    print(f"[{i}/{len(rows)}] {name}")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = dst + ".part"  # write to a temp name so a crash never leaves a partial .tif
    try:
        gdal.Translate(tmp, src, options=options)
        os.replace(tmp, dst)
        logw.writerow([datetime.now().isoformat(timespec="seconds"), name, "ok", ""])
        n_done += 1
    except Exception as e:
        if os.path.exists(tmp):
            os.remove(tmp)
        print(f"  [ERROR] {e}")
        logw.writerow([datetime.now().isoformat(timespec="seconds"), name, "error", str(e)])
        n_err += 1
    log.flush()

log.close()
print(f"Done: {n_done} converted, {n_skip} already present, {n_err} errors (of {len(rows)} local tiles).")
