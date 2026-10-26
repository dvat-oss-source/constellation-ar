#!/usr/bin/env bash
# Thin wrapper around a local astrometry.net (brew install astrometry-net).
# Mac-only calibration/cross-check tool; never shipped in the iOS app.
#
# Usage: tools/astrometry/solve.sh <image> [outdir] [extra solve-field args...]
#   image   FITS/PNG/JPEG. outdir defaults to build/astrometry-solve.
#   Env:    SCALE_LOW / SCALE_HIGH  field width bounds in degrees (default 10 / 90,
#           covering a phone main camera and ~15 deg crops). CPULIMIT seconds (default 60).
# Output:  <outdir>/<basename>.wcs (WCS header), .corr (matched stars), .solved; prints
#          "SOLVED <ra> <dec> <width_deg> <height_deg> <rot_deg>" or "FAILED" and exits 1.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
IMG="${1:?image path required}"; shift || true
OUT="${1:-$REPO/build/astrometry-solve}"; [ $# -gt 0 ] && shift
mkdir -p "$OUT"
BASE="$(basename "${IMG%.*}")"

# Resolve the index directory without publishing a developer's absolute home path.
SOLVER_CONFIG="$(mktemp)"
trap 'rm -f "$SOLVER_CONFIG"' EXIT
while IFS= read -r line || [ -n "$line" ]; do
  if [ "$line" = 'add_path tools/.cache/astrometry' ]; then
    printf 'add_path %s/tools/.cache/astrometry\n' "$REPO"
  else
    printf '%s\n' "$line"
  fi
done < "$HERE/astrometry.cfg" > "$SOLVER_CONFIG"

solve-field --config "$SOLVER_CONFIG" \
  --scale-units degwidth --scale-low "${SCALE_LOW:-10}" --scale-high "${SCALE_HIGH:-90}" \
  --cpulimit "${CPULIMIT:-60}" --no-plots --overwrite --dir "$OUT" \
  --new-fits none --index-xyls none --rdls none --match none \
  "$@" "$IMG" > "$OUT/$BASE.log" 2>&1 || true

if [ ! -f "$OUT/$BASE.solved" ]; then echo FAILED; exit 1; fi
wcsinfo "$OUT/$BASE.wcs" | awk '
  /^ra_center /{ra=$2} /^dec_center /{dec=$2} /^fieldw /{w=$2} /^fieldh /{h=$2} /^orientation /{rot=$2}
  END{printf "SOLVED %s %s %s %s %s\n", ra, dec, w, h, rot}'
