#!/usr/bin/env python3
"""Extracts illustrative silhouettes from Data/artwork/*.png into Data/artwork_outlines.json.

Usage (from the repo root):
    .venv/bin/python tools/extract_outlines.py [--ids Ori,Ant] [--report]

The Stellarium art has no alpha channel (PNG colour types 0 and 2, black background, drawn additively by
Stellarium), so the effective alpha is the brightest colour channel. Pipeline per image:
  mask (alpha >= THRESHOLD, specks and ink-line holes removed) -> marching squares on the mask
  -> Douglas-Peucker -> Catmull-Rom smoothing -> closed pixel polylines.
Pixel coordinates are image pixels, origin top-left, +y down (the convention of Data/artwork.json anchors).
"""

import argparse
import json
import statistics
import struct
import sys
import zlib
from collections import deque
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_catalog as bc  # noqa: E402

OUTPUT = bc.DATA / "artwork_outlines.json"
ALPHA_THRESHOLD = 20
MIN_REGION_FRACTION = 0.002
SIMPLIFY_EPSILON_FRACTION = 0.0010
MIN_EPSILON = 0.5
SMOOTH_SUBDIVISIONS = 2
DECIMALS = 1
ENTRIES_WITHOUT_ART = ("Pup", "Vel", "Ser")


# ---------------------------------------------------------------------------
# PNG decoding (stdlib zlib; 8-bit, non-interlaced, colour types 0/2/4/6)


def _unfilter(data, width, height, bpp):
    stride = width * bpp
    out = np.zeros((height, stride), dtype=np.uint8)
    pos = 0
    prev = np.zeros(stride, dtype=np.int32)
    for y in range(height):
        ft = data[pos]
        line = np.frombuffer(data, dtype=np.uint8, count=stride, offset=pos + 1).astype(np.int32)
        pos += 1 + stride
        if ft == 0:
            cur = line
        elif ft == 1:
            cur = line.copy()
            for i in range(bpp, stride):
                cur[i] = (cur[i] + cur[i - bpp]) & 255
        elif ft == 2:
            cur = (line + prev) & 255
        elif ft == 3:
            cur = line.copy()
            for i in range(stride):
                left = cur[i - bpp] if i >= bpp else 0
                cur[i] = (cur[i] + ((left + prev[i]) >> 1)) & 255
        elif ft == 4:
            cur = line.copy()
            for i in range(stride):
                a = cur[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                cur[i] = (cur[i] + pred) & 255
        else:
            raise ValueError(f"bad PNG filter {ft}")
        out[y] = cur
        prev = cur
    return out


def read_png_alpha(path):
    """-> (width, height, alpha uint8 array [h, w]); alpha is the real alpha channel if present, else the max colour channel."""
    raw = Path(path).read_bytes()
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")
    pos, idat, header = 8, [], None
    while pos < len(raw):
        n, tag = struct.unpack(">I4s", raw[pos:pos + 8])
        body = raw[pos + 8:pos + 8 + n]
        if tag == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat.append(body)
        pos += 12 + n
    width, height, depth, ctype, _, _, interlace = header
    if depth != 8 or interlace or ctype not in (0, 2, 4, 6):
        raise ValueError(f"{path}: unsupported PNG (depth {depth}, type {ctype}, interlace {interlace})")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    px = _unfilter(zlib.decompress(b"".join(idat)), width, height, channels).reshape(height, width, channels)
    if ctype in (4, 6):
        return width, height, px[:, :, -1].copy()
    return width, height, px.max(axis=2)


# ---------------------------------------------------------------------------
# Mask clean-up


def _components(mask, connectivity8):
    """Label connected regions of True pixels. -> (labels int32 [h, w] with 0 = background, sizes list indexed by label)."""
    h, w = mask.shape
    labels = np.zeros((h, w), dtype=np.int32)
    sizes = [0]
    nbrs = [(-1, 0), (1, 0), (0, -1), (0, 1)] + ([(-1, -1), (-1, 1), (1, -1), (1, 1)] if connectivity8 else [])
    flat = mask.tolist()
    lab = [[0] * w for _ in range(h)]
    for y0 in range(h):
        for x0 in range(w):
            if not flat[y0][x0] or lab[y0][x0]:
                continue
            k = len(sizes)
            lab[y0][x0] = k
            queue, count = deque([(y0, x0)]), 0
            while queue:
                y, x = queue.popleft()
                count += 1
                for dy, dx in nbrs:
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < h and 0 <= xx < w and flat[yy][xx] and not lab[yy][xx]:
                        lab[yy][xx] = k
                        queue.append((yy, xx))
            sizes.append(count)
    labels[:] = np.array(lab, dtype=np.int32)
    return labels, sizes


def silhouette_mask(alpha, threshold=ALPHA_THRESHOLD, min_fraction=MIN_REGION_FRACTION):
    """alpha >= threshold with foreground specks and enclosed background regions smaller than
    min_fraction of the image area removed (ink lines inside the art are darker than the threshold)."""
    h, w = alpha.shape
    limit = max(4, int(h * w * min_fraction))
    mask = alpha >= threshold
    labels, sizes = _components(mask, True)
    keep = np.array([False] + [s >= limit for s in sizes[1:]])
    mask = keep[labels]
    padded = np.pad(~mask, 1, constant_values=True)
    labels, sizes = _components(padded, False)
    outside = labels[0, 0]
    fill = np.array([s < limit and i != outside for i, s in enumerate(sizes)])
    fill[0] = False
    holes = fill[labels][1:-1, 1:-1]
    return mask | holes


# ---------------------------------------------------------------------------
# Marching squares


def marching_squares(field, level=0.5):
    """Closed iso-contours of a 2-D field (values above `level` inside) as lists of (x, y) in field index space.
    The caller pads the field with zeros so every contour closes."""
    h, w = field.shape
    f = field
    segments = []  # (edgeA, edgeB, pointA, pointB)

    def interp(p, q, a, b):
        t = 0.5 if a == b else (level - a) / (b - a)
        return (p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1]))

    for y in range(h - 1):
        row, below = f[y], f[y + 1]
        for x in range(w - 1):
            a, b, c, d = row[x], row[x + 1], below[x + 1], below[x]  # tl, tr, br, bl
            code = (a > level) | ((b > level) << 1) | ((c > level) << 2) | ((d > level) << 3)
            if code == 0 or code == 15:
                continue
            tl, tr, br, bl = (x, y), (x + 1, y), (x + 1, y + 1), (x, y + 1)
            top = (("h", x, y), interp(tl, tr, a, b))
            right = (("v", x + 1, y), interp(tr, br, b, c))
            bottom = (("h", x, y + 1), interp(bl, br, d, c))
            left = (("v", x, y), interp(tl, bl, a, d))
            if code in (1, 14):
                pairs = [(left, top)]
            elif code in (2, 13):
                pairs = [(top, right)]
            elif code in (4, 11):
                pairs = [(right, bottom)]
            elif code in (8, 7):
                pairs = [(bottom, left)]
            elif code in (3, 12):
                pairs = [(left, right)]
            elif code in (6, 9):
                pairs = [(top, bottom)]
            else:  # saddles 5 and 10
                centre_in = (a + b + c + d) / 4 > level
                if (code == 5) == centre_in:
                    pairs = [(left, bottom), (top, right)]
                else:
                    pairs = [(left, top), (bottom, right)]
            for p, q in pairs:
                segments.append((p[0], q[0], p[1], q[1]))
    by_edge = {}
    for i, (ea, eb, _, _) in enumerate(segments):
        by_edge.setdefault(ea, []).append(i)
        by_edge.setdefault(eb, []).append(i)
    used = [False] * len(segments)
    loops = []
    for start in range(len(segments)):
        if used[start]:
            continue
        used[start] = True
        ea, eb, pa, pb = segments[start]
        pts, first, edge = [pa, pb], ea, eb
        while edge != first:
            nxt = [i for i in by_edge[edge] if not used[i]]
            if not nxt:
                break
            i = nxt[0]
            used[i] = True
            sa, sb, qa, qb = segments[i]
            if sa == edge:
                pts.append(qb)
                edge = sb
            else:
                pts.append(qa)
                edge = sa
        pts.pop()
        if len(pts) >= 3:
            loops.append(pts)
    return loops


# ---------------------------------------------------------------------------
# Simplification and smoothing


def _point_segment_distance(p, a, b):
    ax, ay = a
    dx, dy = b[0] - ax, b[1] - ay
    n = dx * dx + dy * dy
    t = 0.0 if n == 0 else max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - ay) * dy) / n))
    return ((p[0] - ax - t * dx) ** 2 + (p[1] - ay - t * dy) ** 2) ** 0.5


def douglas_peucker(points, epsilon):
    """Open polyline simplification (keeps both ends)."""
    if len(points) < 3:
        return list(points)
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        lo, hi = stack.pop()
        best, index = 0.0, None
        for i in range(lo + 1, hi):
            d = _point_segment_distance(points[i], points[lo], points[hi])
            if d > best:
                best, index = d, i
        if index is not None and best > epsilon:
            keep[index] = True
            stack += [(lo, index), (index, hi)]
    return [p for p, k in zip(points, keep) if k]


def simplify_closed(loop, epsilon):
    """Douglas-Peucker on a closed loop: split at the point farthest from the first one, simplify both halves."""
    n = len(loop)
    far = max(range(n), key=lambda i: (loop[i][0] - loop[0][0]) ** 2 + (loop[i][1] - loop[0][1]) ** 2)
    a = douglas_peucker(loop[:far + 1], epsilon)
    b = douglas_peucker(loop[far:] + [loop[0]], epsilon)
    return a[:-1] + b[:-1]


def catmull_rom_closed(points, subdivisions):
    """Uniform Catmull-Rom spline through the closed polygon's vertices, `subdivisions` samples per span."""
    n = len(points)
    if n < 4 or subdivisions < 2:
        return list(points)
    out = []
    for i in range(n):
        p0, p1, p2, p3 = points[(i - 1) % n], points[i], points[(i + 1) % n], points[(i + 2) % n]
        for s in range(subdivisions):
            t = s / subdivisions
            t2, t3 = t * t, t * t * t
            out.append(tuple(
                0.5 * (2 * p1[k] + (p2[k] - p0[k]) * t + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2
                       + (3 * p1[k] - p0[k] - 3 * p2[k] + p3[k]) * t3)
                for k in (0, 1)
            ))
    return out


# ---------------------------------------------------------------------------
# Rasterising (for the IoU check)


def rasterize(loops, width, height):
    """Even-odd fill of closed polylines, sampled at pixel centres. -> bool array [h, w]."""
    crossings = [[] for _ in range(height)]
    for loop in loops:
        pts = loop + [loop[0]] if loop[0] != loop[-1] else loop
        for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
            if y1 == y2:
                continue
            lo, hi = (y1, y2) if y1 < y2 else (y2, y1)
            first = max(0, int(np.ceil(lo - 0.5)))
            last = min(height - 1, int(np.ceil(hi - 0.5)) - 1)
            for j in range(first, last + 1):
                crossings[j].append(x1 + ((j + 0.5) - y1) * (x2 - x1) / (y2 - y1))
    out = np.zeros((height, width), dtype=bool)
    for j, xs in enumerate(crossings):
        xs.sort()
        for a, b in zip(xs[0::2], xs[1::2]):
            i0, i1 = max(0, int(np.ceil(a - 0.5))), min(width, int(np.ceil(b - 0.5)))
            if i1 > i0:
                out[j, i0:i1] = True
    return out


def iou(a, b):
    union = np.logical_or(a, b).sum()
    return 1.0 if union == 0 else float(np.logical_and(a, b).sum() / union)


# ---------------------------------------------------------------------------


def extract(alpha, threshold=ALPHA_THRESHOLD):
    """alpha [h, w] -> (silhouette mask, [closed polylines as lists of (x, y), first point repeated at the end])."""
    h, w = alpha.shape
    mask = silhouette_mask(alpha, threshold)
    raw = marching_squares(np.pad(mask.astype(np.float64), 2), 0.5)
    eps = max(MIN_EPSILON, SIMPLIFY_EPSILON_FRACTION * max(w, h))
    loops = []
    for loop in raw:
        pts = [(x - 2 + 0.5, y - 2 + 0.5) for x, y in loop]
        pts = simplify_closed(pts, eps)
        if len(pts) < 3:
            continue
        pts = catmull_rom_closed(pts, SMOOTH_SUBDIVISIONS)
        pts = [(min(w, max(0.0, x)), min(h, max(0.0, y))) for x, y in pts]
        loops.append(pts + [pts[0]])
    return mask, loops


def build(ids=None, report=False):
    infos = json.loads((bc.DATA / "artwork.json").read_text(encoding="utf-8"))
    outlines, stats = {}, {}
    for info in infos:
        if ids and info["id"] not in ids:
            continue
        w, h, alpha = read_png_alpha(bc.DATA / info["file"])
        if [w, h] != [int(v) for v in info["size"]]:
            raise SystemExit(f"{info['id']}: PNG is {w}x{h}, artwork.json says {info['size']}")
        mask, loops = extract(alpha)
        outlines[info["id"]] = {
            "size": [w, h],
            "paths": [[[round(x, DECIMALS), round(y, DECIMALS)] for x, y in loop] for loop in loops],
        }
        raster = rasterize([[(x, y) for x, y in p] for p in outlines[info["id"]]["paths"]], w, h)
        stats[info["id"]] = {
            "iouSilhouette": iou(raster, mask), "iouRawAlpha": iou(raster, alpha >= ALPHA_THRESHOLD),
            "paths": len(loops), "points": sum(len(p) for p in loops),
        }
    return outlines, stats


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ids", help="comma-separated artwork ids (default: all; writes only when all are built)")
    ap.add_argument("--report", action="store_true", help="print per-image IoU")
    args = ap.parse_args()
    ids = set(args.ids.split(",")) if args.ids else None
    outlines, stats = build(ids)
    if not ids:
        bc.write_json(OUTPUT, {
            "version": 1,
            "format": (
                "outlines: {artworkId: {size: [w, h], paths: [[[x, y], ...], ...]}}. Pixel coordinates of Data/artwork/*.png "
                "(origin top-left, +y down). Each path is a closed loop (first point repeated last); loops are outer "
                "silhouettes or holes, filled even-odd. Silhouette = brightest colour channel >= "
                f"{ALPHA_THRESHOLD} (the art has no alpha channel; Stellarium draws it additively) with regions smaller "
                f"than {MIN_REGION_FRACTION:.1%} of the image removed/filled. Constellations without art ({', '.join(ENTRIES_WITHOUT_ART)}) "
                "have no entry."
            ),
            "outlines": outlines,
        }, compact=True)
    ious = [s["iouSilhouette"] for s in stats.values()]
    raw = [s["iouRawAlpha"] for s in stats.values()]
    if args.report:
        for k, s in sorted(stats.items()):
            print(f"{k:4s} IoU {s['iouSilhouette']:.4f} (raw alpha {s['iouRawAlpha']:.4f}) paths {s['paths']} points {s['points']}")
    print(json.dumps({
        "artworks": len(outlines), "iouMin": round(min(ious), 4), "iouMedian": round(statistics.median(ious), 4),
        "iouRawMin": round(min(raw), 4), "iouRawMedian": round(statistics.median(raw), 4),
        "points": sum(s["points"] for s in stats.values()),
        "bytes": OUTPUT.stat().st_size if OUTPUT.exists() else None,
    }))


if __name__ == "__main__":
    main()
