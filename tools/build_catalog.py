#!/usr/bin/env python3
"""Builds the bundled sky catalogue files in Data/ from pinned upstream sources.

Usage (from the repo root):
    .venv/bin/python tools/build_catalog.py            # core + extras
    .venv/bin/python tools/build_catalog.py --core     # stars.bin, lines, names, roman1875, constellations, test bounds
    .venv/bin/python tools/build_catalog.py --extras   # asterisms, milkyway, dso, artwork
    .venv/bin/python tools/build_catalog.py --offline  # never touch the network; fail if a cached file is missing

Downloads go to tools/.cache/. tools/sources.json pins every source (URL, version) and records
its sha256 on first download; later runs refuse files whose hash differs.
"""

import argparse
import csv
import hashlib
import html
import json
import math
import re
import shutil
import struct
import subprocess
import sys
import time
import warnings
from pathlib import Path

import numpy as np
import requests

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
CACHE = TOOLS / ".cache"
DATA = ROOT / "Data"
MANIFEST = TOOLS / "sources.json"
USER_AGENT = "SkyAppDataBuild/1.0 (personal, non-commercial iPhone app data build)"

PM_EPOCH = 2026.5
HIP_EPOCH = 1991.25
STAR_MAG_LIMIT = 6.5
DSO_MAG_LIMIT = 11.0
ART_MAX_PX = 1024
LABEL_COUNT = 50

STARS_MAGIC = b"SKYS"
STARS_VERSION = 1
STARS_HEADER = struct.Struct("<4sIIId")
STARS_RECORD = struct.Struct("<Iffffff")

STELLARIUM_ART_BASE = "https://raw.githubusercontent.com/Stellarium/stellarium/v26.3/skycultures/modern/"


# ---------------------------------------------------------------------------
# Source manifest and downloads


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, dest, attempts=6):
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".part")
    for attempt in range(attempts):
        with requests.get(url, headers={"User-Agent": USER_AGENT}, stream=True, timeout=120) as r:
            if r.status_code in (429, 500, 502, 503, 504) and attempt < attempts - 1:
                retry_after = r.headers.get("Retry-After", "")
                time.sleep(float(retry_after) if retry_after.isdigit() else 2.0 * 2 ** attempt)
                continue
            r.raise_for_status()
            with open(tmp, "wb") as f:
                for chunk in r.iter_content(1 << 20):
                    f.write(chunk)
        break
    tmp.replace(dest)


class Sources:
    def __init__(self, offline=False, manifest=MANIFEST):
        self.offline = offline
        self.manifest_path = manifest
        self.manifest = json.loads(manifest.read_text()) if manifest.exists() else {}

    def get(self, key, url=None, version=None, path=None):
        entry = self.manifest.get(key)
        if entry is None:
            if url is None:
                raise SystemExit(f"unknown source {key!r}; add it to {MANIFEST}")
            entry = {"url": url, "version": version, "path": path, "sha256": None}
            self.manifest[key] = entry
        dest = CACHE / entry["path"]
        if not dest.exists():
            if self.offline:
                raise SystemExit(f"--offline but {dest} is not cached")
            print(f"downloading {key}: {entry['url']}")
            download(entry["url"], dest)
        digest = sha256_file(dest)
        if entry["sha256"] is None:
            entry["sha256"] = digest
            self.save()
            print(f"pinned {key} sha256={digest}")
        elif entry["sha256"] != digest:
            raise SystemExit(
                f"sha256 mismatch for {key} ({dest}):\n  expected {entry['sha256']}\n  got      {digest}\n"
                f"Delete the cached file to re-download, or update {self.manifest_path.name} if the pin changed on purpose."
            )
        return dest

    def entry(self, key):
        return self.manifest[key]

    def save(self):
        self.manifest_path.write_text(json.dumps(self.manifest, indent=2, ensure_ascii=False) + "\n")


# ---------------------------------------------------------------------------
# Parsers


def parse_constellation_table(path):
    """Wikipedia 'IAU designated constellations' wikitext -> [(id, name, genitive, articleTitle)]."""
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("| [["):
            continue
        cells = [c.strip() for c in line[1:].split("||")]
        if len(cells) < 4:
            continue
        m = re.match(r"\[\[([^|\]]+)(?:\|([^\]]+))?\]\]", cells[0])
        if not m:
            continue
        title = m.group(1)
        name = m.group(2) or title
        genitive = re.sub(r"\{\{br\}\}.*", "", cells[3])
        genitive = re.sub(r"<ref[^>]*/>|<ref[^>]*>.*?</ref>", "", genitive)
        genitive = re.sub(r"'''?|\[\[|\]\]", "", genitive).strip()
        out.append((cells[1], name, genitive, title))
    if len(out) != 88:
        raise SystemExit(f"expected 88 constellations in the Wikipedia table, got {len(out)}")
    return out


def _sexagesimal(text):
    parts = text.split()
    sign = -1.0 if parts[0].startswith("-") else 1.0
    a, b, c = abs(float(parts[0])), float(parts[1]), float(parts[2])
    return sign * (a + b / 60 + c / 3600)


def parse_hipparcos(path):
    """hip_main.dat (I/239 ReadMe byte columns) -> dict of numpy arrays."""

    def num(line, first, last):
        s = line[first - 1:last].strip()
        return float(s) if s else math.nan

    hip, ra, de, vmag, plx, e_plx, pmra, pmde, bv, fallback = [], [], [], [], [], [], [], [], [], []
    with open(path, encoding="ascii") as f:
        for line in f:
            hip.append(int(line[8:14]))
            r, d = num(line, 52, 63), num(line, 65, 76)
            if math.isnan(r):
                r = _sexagesimal(line[17:28]) * 15.0
                d = _sexagesimal(line[29:40])
                fallback.append(hip[-1])
            ra.append(r)
            de.append(d)
            vmag.append(num(line, 42, 46))
            plx.append(num(line, 80, 86))
            e_plx.append(num(line, 120, 125))
            pmra.append(num(line, 88, 95))
            pmde.append(num(line, 97, 104))
            bv.append(num(line, 246, 251))
    arr = lambda x, t=np.float64: np.array(x, dtype=t)
    return {
        "hip": arr(hip, np.int64), "ra": arr(ra), "de": arr(de), "vmag": arr(vmag), "plx": arr(plx), "e_plx": arr(e_plx),
        "pmra": arr(pmra), "pmde": arr(pmde), "bv": arr(bv), "hms_fallback": set(fallback),
    }


def parse_stellarium(path):
    d = json.loads(path.read_text(encoding="utf-8"))
    out = {}
    for c in d["constellations"]:
        cid = c["id"].split()[-1]
        segments, seen = [], set()
        for polyline in c["lines"]:
            for a, b in zip(polyline, polyline[1:]):
                if a == b:
                    continue
                key = (min(a, b), max(a, b))
                if key in seen:
                    continue
                seen.add(key)
                segments.append([a, b])
        out[cid] = {"segments": segments, "image": c.get("image"), "native": c["common_name"].get("native")}
    return out


def parse_wgsn(path):
    """WGSN CSN HTML table -> {hip: name}. Shared HIPs keep the primary (shortest Bayer/component id)."""
    text = path.read_text(encoding="utf-8")
    table = re.findall(r"<table.*?</table>", text, flags=re.S)[0]
    header = [re.sub(r"<[^>]+>", "", x).strip() for x in re.findall(r"<th.*?</th>", table, flags=re.S)]
    i_name, i_hip, i_bayer = header.index("proper names"), header.index("HIP"), header.index("Bayer ID")
    cands = {}
    for row in re.findall(r"<tr.*?</tr>", table, flags=re.S):
        cells = [html.unescape(re.sub(r"<[^>]+>", "", x)).strip() for x in re.findall(r"<td.*?</td>", row, flags=re.S)]
        if len(cells) <= i_hip or not cells[i_hip].isdigit():
            continue
        cands.setdefault(int(cells[i_hip]), []).append((len(cells[i_bayer]), cells[i_name]))
    return {hip: sorted(v)[0][1] for hip, v in cands.items()}, {hip: [n for _, n in v] for hip, v in cands.items() if len(v) > 1}


def parse_roman(path):
    rows = []
    for line in path.read_text(encoding="ascii").splitlines():
        if not line.strip():
            continue
        rows.append([float(line[1:8]), float(line[9:16]), float(line[17:25]), line[26:29].strip()])
    return rows


def roman_lookup(rows, ra_hours, dec_deg):
    for lo, hi, dlo, cid in rows:
        if dec_deg >= dlo and lo <= ra_hours < hi:
            return cid
    return None


def parse_bound18(path, ids):
    """bound_18.dat -> {id: [polygon, ...]}, polygon = {"enclosesPole": None|"N"|"S", "vertices": [[raH, decDeg], ...] closed}."""
    upper = {i.upper(): i for i in ids}
    upper["SER1"] = upper["SER2"] = "Ser"
    groups = []
    for line in path.read_text(encoding="ascii").splitlines():
        if not line.strip():
            continue
        ra, dec, cst = float(line[0:8]), float(line[9:18]), line[19:23].strip()
        if not groups or groups[-1][0] != cst:
            groups.append((cst, []))
        groups[-1][1].append((ra, dec))
    out = {}
    for cst, pts in groups:
        # Octans' -90 deg points are plotting aids that cross 0h to the pole and back (VI/49 constell.txt sec 2.1).
        pts = [(ra % 24.0, dec) for ra, dec in pts if dec > -90.0]
        dedup = [pts[0]]
        for p in pts[1:]:
            if p != dedup[-1]:
                dedup.append(p)
        if dedup[0] == dedup[-1]:
            dedup.pop()
        ring = dedup + [dedup[0]]
        winding = 0.0
        for (r1, d1), (r2, d2) in zip(ring, ring[1:]):
            if d1 == d2:
                dra = (r2 - r1 + 12.0) % 24.0 - 12.0
                if abs(abs(dra) - 12.0) < 1e-9:
                    raise SystemExit(f"{cst}: ambiguous 12h parallel edge")
                winding += dra
            elif abs((r1 - r2 + 12.0) % 24.0 - 12.0) > 1e-9:
                raise SystemExit(f"{cst}: edge {r1},{d1} -> {r2},{d2} is neither a parallel nor a meridian")
        pole = None
        if abs(abs(winding) - 24.0) < 1e-6:
            pole = "N" if sum(d for _, d in dedup) > 0 else "S"
        elif abs(winding) > 1e-6:
            raise SystemExit(f"{cst}: unexpected RA winding {winding}")
        out.setdefault(upper[cst], []).append(
            {"enclosesPole": pole, "vertices": [[round(r, 5), round(d, 5)] for r, d in ring]}
        )
    return out


def bounds_contains(polygon, ra_hours, dec_deg):
    """Point-in-polygon for a vi49_bounds.json polygon, per the algorithm documented in its 'format' field."""
    v = polygon["vertices"]
    crossings = 0
    for (r1, d1), (r2, d2) in zip(v, v[1:]):
        if d1 != d2 or d1 <= dec_deg:
            continue
        width = (r2 - r1) % 24.0
        start = r1
        if width > 12.0:
            width, start = 24.0 - width, r2
        if (ra_hours - start) % 24.0 < width:
            crossings += 1
    inside = crossings % 2 == 1
    return (not inside) if polygon["enclosesPole"] == "N" else inside


# ---------------------------------------------------------------------------
# Astrometry


def propagate_to_epoch(ra_deg, de_deg, pmra, pmde, plx):
    """Rigorous space motion J1991.25 -> PM_EPOCH via astropy SkyCoord.apply_space_motion (ERFA pmsafe), RV = 0."""
    import astropy.units as u
    from astropy.coordinates import Distance, SkyCoord
    from astropy.time import Time
    from erfa import ErfaWarning

    t0 = Time(HIP_EPOCH, format="jyear", scale="tt")
    t1 = Time(PM_EPOCH, format="jyear", scale="tt")
    pmra = np.nan_to_num(pmra)
    pmde = np.nan_to_num(pmde)
    has_plx = np.nan_to_num(plx) > 0
    out_ra = np.empty_like(ra_deg)
    out_de = np.empty_like(de_deg)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", ErfaWarning)
        for mask, with_distance in ((has_plx, True), (~has_plx, False)):
            if not mask.any():
                continue
            kw = dict(
                ra=ra_deg[mask] * u.deg, dec=de_deg[mask] * u.deg,
                pm_ra_cosdec=pmra[mask] * u.mas / u.yr, pm_dec=pmde[mask] * u.mas / u.yr,
                obstime=t0, frame="icrs",
            )
            if with_distance:
                kw["distance"] = Distance(parallax=plx[mask] * u.mas)
                kw["radial_velocity"] = np.zeros(mask.sum()) * u.km / u.s
            moved = SkyCoord(**kw).apply_space_motion(new_obstime=t1)
            out_ra[mask] = moved.ra.deg
            out_de[mask] = moved.dec.deg
    return out_ra, out_de


def unit_vectors(ra_deg, de_deg):
    ra, de = np.radians(ra_deg), np.radians(de_deg)
    return np.stack([np.cos(de) * np.cos(ra), np.cos(de) * np.sin(ra), np.sin(de)], axis=1)


def to_b1875(ra_deg, de_deg):
    """ICRS -> mean equator & equinox B1875 (FK5 precession), the frame of the Delporte/Roman boundaries."""
    import astropy.units as u
    from astropy.coordinates import FK5, SkyCoord
    from astropy.time import Time

    c = SkyCoord(ra=np.atleast_1d(ra_deg) * u.deg, dec=np.atleast_1d(de_deg) * u.deg, frame="icrs")
    p = c.transform_to(FK5(equinox=Time("B1875.0")))
    return p.ra.hour, p.dec.deg


# ---------------------------------------------------------------------------
# stars.bin I/O


def write_stars_bin(path, records):
    with open(path, "wb") as f:
        f.write(STARS_HEADER.pack(STARS_MAGIC, STARS_VERSION, len(records), STARS_RECORD.size, PM_EPOCH))
        for r in records:
            f.write(STARS_RECORD.pack(*r))


def read_stars_bin(path):
    raw = Path(path).read_bytes()
    magic, version, count, size, epoch = STARS_HEADER.unpack_from(raw, 0)
    if magic != STARS_MAGIC or version != STARS_VERSION or size != STARS_RECORD.size:
        raise ValueError("bad stars.bin header")
    if len(raw) != STARS_HEADER.size + count * size:
        raise ValueError("stars.bin length mismatch")
    recs = [STARS_RECORD.unpack_from(raw, STARS_HEADER.size + i * size) for i in range(count)]
    return {"version": version, "count": count, "recordSize": size, "pmEpoch": epoch, "records": recs}


def write_json(path, obj, compact=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    if compact:
        text = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    else:
        text = json.dumps(obj, ensure_ascii=False, indent=1)
    path.write_text(text + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# Core build


def build_core(src):
    report = {}
    table = parse_constellation_table(src.get("iau_constellations_wiki"))
    ids = [t[0] for t in table]
    names = {t[0]: t[1] for t in table}

    roman = parse_roman(src.get("vi42_data"))
    src.get("vi42_readme")
    roman_ids = {r[3] for r in roman}
    if roman_ids != set(ids):
        raise SystemExit(f"VI/42 ids differ from IAU list: {sorted(roman_ids ^ set(ids))}")
    report["romanRows"] = len(roman)

    stel = parse_stellarium(src.get("stellarium_index"))
    src.get("stellarium_description")
    if set(stel) != set(ids):
        raise SystemExit(f"Stellarium ids differ from IAU list: {sorted(set(stel) ^ set(ids))}")
    report["stellariumNameDiffs"] = {i: stel[i]["native"] for i in ids if stel[i]["native"] != names[i]}

    hip = parse_hipparcos(src.get("hip_main"))
    src.get("hip_readme")
    index = {h: i for i, h in enumerate(hip["hip"].tolist())}

    line_hips = {h for c in stel.values() for seg in c["segments"] for h in seg}
    anchor_hips = {a["hip"] for c in stel.values() if c["image"] for a in c["image"]["anchors"]}
    missing = sorted((line_hips | anchor_hips) - set(index))
    if missing:
        raise SystemExit(f"HIP ids referenced by Stellarium but absent from hip_main.dat: {missing}")

    bright = set(hip["hip"][hip["vmag"] <= STAR_MAG_LIMIT].tolist())
    chosen = sorted(bright | line_hips | anchor_hips)
    sel = np.array([index[h] for h in chosen])
    ra1, de1 = propagate_to_epoch(hip["ra"][sel], hip["de"][sel], hip["pmra"][sel], hip["pmde"][sel], hip["plx"][sel])
    xyz = unit_vectors(ra1, de1)

    records = []
    for k, i in enumerate(sel):
        plx = hip["plx"][i]
        records.append((
            int(hip["hip"][i]), float(xyz[k, 0]), float(xyz[k, 1]), float(xyz[k, 2]),
            float(hip["vmag"][i]), float(hip["bv"][i]), float(plx) if plx > 0 else math.nan,
        ))
    records.sort(key=lambda r: (math.isnan(r[4]), r[4], r[0]))
    DATA.mkdir(parents=True, exist_ok=True)
    write_stars_bin(DATA / "stars.bin", records)
    vmag_of = {r[0]: r[4] for r in records}
    faint = sorted(
        ((h, vmag_of[h], "line" if h in line_hips else "anchor") for h in (line_hips | anchor_hips) if not vmag_of[h] <= STAR_MAG_LIMIT),
        key=lambda t: t[1],
    )
    report.update({
        "starCount": len(records), "starsBrightCount": len(bright), "pmEpoch": PM_EPOCH,
        "fainterThanLimit": faint, "hmsFallback": sorted(hip["hms_fallback"] & set(chosen)),
    })

    write_json(DATA / "lines.json", {
        "version": 1,
        "source": src.entry("stellarium_index")["version"],
        "constellations": [{"id": i, "name": names[i], "segments": stel[i]["segments"]} for i in ids],
    }, compact=True)

    wgsn, shared = parse_wgsn(src.get("wgsn_csn"))
    named = sorted((vmag_of[h], h, n) for h, n in wgsn.items() if h in vmag_of)
    label = {h for _, h, _ in named[:LABEL_COUNT]}
    write_json(DATA / "names.json", {
        "version": 1,
        "source": src.entry("wgsn_csn")["version"],
        "stars": [{"hip": h, "name": n, "label": h in label} for _, h, n in named],
    }, compact=True)
    report.update({"wgsnWithHip": len(wgsn), "namesInCatalog": len(named), "wgsnSharedHip": shared})

    (DATA / "roman1875.json").write_text(
        '{"version":1,"equinox":"B1875","rows":[\n'
        + ",\n".join(json.dumps(r, separators=(",", ":")) for r in roman)
        + "\n]}\n",
        encoding="utf-8",
    )
    write_json(DATA / "constellations.json", [{"id": i, "name": n, "genitive": g} for i, n, g, _ in table])

    bounds = parse_bound18(src.get("vi49_bound18"), ids)
    src.get("vi49_readme")
    if set(bounds) != set(ids):
        raise SystemExit(f"VI/49 ids differ: {sorted(set(bounds) ^ set(ids))}")
    write_json(DATA / "test" / "vi49_bounds.json", {
        "version": 1,
        "source": src.entry("vi49_bound18")["version"],
        "equinox": "B1875",
        "format": (
            "constellations[]: {id (IAU abbreviation; both Serpens parts are 'Ser' with two polygons), polygons[]}. "
            "polygon: {enclosesPole: null|'N'|'S', vertices: [[raHours, decDeg], ...]} in VI/49 file order, closed "
            "(last vertex == first), raHours in [0,24). Every edge is either a meridian (equal RA) or a parallel "
            "(equal dec) of the B1875 equator; a parallel edge runs along the shorter RA arc between its endpoints "
            "(all are < 12h, so the 0h/24h crossing is unambiguous). Octans' three plotting-aid points at dec -90 "
            "were dropped, which makes Octans a ring around the south pole (enclosesPole 'S'); Ursa Minor encloses "
            "the north pole ('N'). Containment test for a B1875 point (ra, dec): count parallel edges with "
            "edgeDec > dec whose RA arc contains ra (half-open: start <= ra < start+width, measured mod 24h from "
            "the arc's western end); inside = odd count, inverted when enclosesPole == 'N'. Points exactly on a "
            "boundary are ambiguous. Known source quirk: Serpens Cauda/Ophiuchus share a border given as "
            "18h25.5m on one side and 18h25.3m on the other (dec +3 to +4.5, see VI/49 constbnd.txt)."
        ),
        "constellations": [{"id": i, "polygons": bounds[i]} for i in ids],
    })
    report["boundsPolygons"] = sum(len(v) for v in bounds.values())
    return report


# ---------------------------------------------------------------------------
# Extras


def lon_to_ra(lon):
    return round(lon % 360.0, 4)


def milkyway_contains(level, ra_deg, dec_deg):
    """Even-odd test documented in milkyway.json 'format': count ring edges crossed by the northward meridian ray."""
    crossings = 0
    for ring in level["polygons"]:
        for (r1, d1), (r2, d2) in zip(ring, ring[1:]):
            width = (r2 - r1) % 360.0
            if width == 0.0:
                continue
            if width > 180.0:
                (r1, d1), (r2, d2) = (r2, d2), (r1, d1)
                width = 360.0 - width
            t = (ra_deg - r1) % 360.0
            if t >= width:
                continue
            if d1 + (d2 - d1) * (t / width) > dec_deg:
                crossings += 1
    return crossings % 2 == 1


def build_extras(src, star_hips):
    report = {}

    ast = json.loads(src.get("d3_asterisms").read_text(encoding="utf-8"))
    asterisms = []
    for f in ast["features"]:
        p = f["properties"]
        loc = p.get("loc")
        label = None if not loc or loc == [0, 0] else [lon_to_ra(loc[0]), loc[1]]
        asterisms.append({
            "id": f["id"], "name": p["n"], "priority": p.get("p"), "label": label,
            "lines": [[[lon_to_ra(x), round(y, 4)] for x, y in line] for line in f["geometry"]["coordinates"]],
        })
    write_json(DATA / "asterisms.json", {
        "version": 1,
        "source": f"d3-celestial data/asterisms.json, {src.entry('d3_asterisms')['version']}",
        "format": "lines: polylines of [raDeg 0..360, decDeg] (ICRS/J2000). priority: d3-celestial 'p' (1 = most prominent; 6 = star-hopping pointer lines). label: [raDeg, decDeg] or null.",
        "asterisms": asterisms,
    }, compact=True)
    report["asterisms"] = len(asterisms)

    mw = json.loads(src.get("d3_mw").read_text(encoding="utf-8"))
    levels = []
    for f in mw["features"]:
        rings = [ring for poly in f["geometry"]["coordinates"] for ring in poly]
        levels.append({
            "level": int(f["id"].lstrip("ol")),
            "polygons": [[[lon_to_ra(x), round(y, 3)] for x, y in ring] for ring in rings],
        })
    levels.sort(key=lambda lv: lv["level"])
    write_json(DATA / "milkyway.json", {
        "version": 1,
        "source": f"d3-celestial data/mw.json, {src.entry('d3_mw')['version']} (from J. R. Vieira's Milky Way Outline Catalog)",
        "format": (
            "levels[]: level 1 = faintest/outermost outline .. 5 = brightest; d3-celestial draws each level as its own "
            "translucent layer on top of the previous ones. polygons: closed rings of [raDeg 0..360, decDeg] (J2000), "
            "consecutive points < 2 deg apart, edges taken along the shorter RA direction. Two level-1 rings wrap once "
            "around the sky in RA (the band's northern and southern edges); the other rings are small outlines or holes. "
            "Membership rule for every level: cast a ray from the point due north along its meridian to the pole and count "
            "crossings with all of that level's rings (edges interpolated linearly in RA/Dec); odd = inside. On screen this "
            "is an even-odd fill, provided the two wrap-around rings are clipped/closed consistently."
        ),
        "levels": levels,
    }, compact=True)
    report["milkyWayRings"] = {lv["level"]: len(lv["polygons"]) for lv in levels}

    report.update(build_dso(src))
    report.update(build_artwork(src, star_hips))
    return report


def _dso_id(name):
    m = re.match(r"^(NGC|IC)0*(\d+)(.*)$", name)
    if m:
        return f"{m.group(1)} {m.group(2)}{m.group(3).strip() and ' ' + m.group(3).strip()}"
    m = re.match(r"^(Mel|Cl|C|B|H|M)0*(\d+)$", name)
    if m:
        prefix = {"Mel": "Mel", "Cl": "Cr", "C": "C", "B": "B", "H": "Harvard", "M": "M"}[m.group(1)]
        return f"{prefix} {m.group(2)}"
    return name


def build_dso(src):
    def num(s):
        return float(s) if s.strip() else None

    def hms_deg(s, hours):
        sign = -1.0 if s.startswith("-") else 1.0
        a, b, c = (float(x) for x in s.lstrip("+-").split(":"))
        return sign * (a + b / 60 + c / 3600) * (15.0 if hours else 1.0)

    objects, skipped_messier = [], []
    for key in ("openngc_ngc", "openngc_addendum"):
        with open(src.get(key), encoding="utf-8") as f:
            for r in csv.DictReader(f, delimiter=";"):
                messier = int(r["M"]) if r["M"].strip() else None
                if r["Type"] in ("Dup", "NonEx"):
                    if messier and r["Name"].startswith("M"):
                        skipped_messier.append(f"{r['Name']} ({r['Type']} of M{messier})")
                    continue
                if not r["RA"] or not r["Dec"]:
                    continue
                mag = num(r["V-Mag"])
                if mag is None:
                    mag = num(r["B-Mag"])
                if messier is None and (mag is None or mag > DSO_MAG_LIMIT):
                    continue
                common = [n.strip() for n in r["Common names"].split(",") if n.strip()]
                objects.append({
                    "id": _dso_id(r["Name"]), "messier": messier, "name": common[0] if common else None,
                    "type": r["Type"], "raDeg": round(hms_deg(r["RA"], True), 5), "decDeg": round(hms_deg(r["Dec"], False), 5),
                    "mag": mag, "majAxArcmin": num(r["MajAx"]), "minAxArcmin": num(r["MinAx"]), "posAngle": num(r["PosAng"]),
                })
    objects.sort(key=lambda o: (o["mag"] if o["mag"] is not None else 99.0, o["id"]))
    messiers = sorted(o["messier"] for o in objects if o["messier"])
    write_json(DATA / "dso.json", {
        "version": 1,
        "source": f"{src.entry('openngc_ngc')['version']}, database_files/NGC.csv + addendum.csv",
        "magLimit": DSO_MAG_LIMIT,
        "format": "All Messier objects plus NGC/IC/addendum objects with mag <= magLimit. mag = V-Mag, else B-Mag. type = OpenNGC type code (see OpenNGC NGC_guide.txt). raDeg/decDeg J2000. Sorted by mag.",
        "objects": objects,
    }, compact=True)
    return {"dsoCount": len(objects), "dsoMessier": len(messiers), "dsoMessierMissing": sorted(set(range(1, 111)) - set(messiers)), "dsoSkippedMessier": skipped_messier}


def _png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path} is not a PNG")
    return struct.unpack(">II", head[16:24])


def build_artwork(src, star_hips):
    stel = json.loads(src.get("stellarium_index").read_text(encoding="utf-8"))
    out_dir = DATA / "artwork"
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)
    entries, missing_hips = [], []
    for c in stel["constellations"]:
        img = c.get("image")
        if not img:
            continue
        cid = c["id"].split()[-1]
        rel = img["file"]
        raw = src.get(f"stellarium_art:{rel}", url=STELLARIUM_ART_BASE + rel,
                      version="Stellarium v26.3 skycultures/modern", path=f"stellarium/{rel}")
        w, h = _png_size(raw)
        dest = out_dir / Path(rel).name
        if max(w, h) > ART_MAX_PX:
            subprocess.run(["sips", "-Z", str(ART_MAX_PX), str(raw), "--out", str(dest)], check=True, capture_output=True)
        else:
            shutil.copyfile(raw, dest)
        ow, oh = _png_size(dest)
        dw, dh = img["size"]
        sx, sy = ow / dw, oh / dh
        anchors = []
        for a in img["anchors"]:
            if a["hip"] not in star_hips:
                missing_hips.append(a["hip"])
            anchors.append({"pos": [round(a["pos"][0] * sx, 2), round(a["pos"][1] * sy, 2)], "hip": a["hip"]})
        entries.append({"id": cid, "file": f"artwork/{dest.name}", "size": [ow, oh], "anchors": anchors,
                        "_src": {"declared": [dw, dh], "pixels": [w, h]}})
    if missing_hips:
        raise SystemExit(f"artwork anchors not in stars.bin: {missing_hips}")
    scaled = [(e["id"], e["_src"]) for e in entries if e["_src"]["declared"] != e["size"]]
    for e in entries:
        del e["_src"]
    entries.sort(key=lambda e: e["id"])
    write_json(DATA / "artwork.json", entries, compact=True)
    total = sum(p.stat().st_size for p in out_dir.iterdir())
    return {"artworkCount": len(entries), "artworkBytes": total, "artworkRescaled": scaled}


# ---------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--core", action="store_true", help="build only the core (Phase 1) files")
    ap.add_argument("--extras", action="store_true", help="build only the extras (Phase 5) files; needs Data/stars.bin")
    ap.add_argument("--offline", action="store_true", help="use cached downloads only")
    args = ap.parse_args()
    both = not args.core and not args.extras
    src = Sources(offline=args.offline)
    report = {}
    try:
        if args.core or both:
            report.update(build_core(src))
        if args.extras or both:
            star_hips = {r[0] for r in read_stars_bin(DATA / "stars.bin")["records"]}
            report.update(build_extras(src, star_hips))
    finally:
        src.save()
    sizes = {str(p.relative_to(ROOT)): p.stat().st_size for p in sorted(DATA.rglob("*")) if p.is_file() and "artwork/" not in str(p.relative_to(DATA))}
    report["files"] = sizes
    report["dataBytesTotal"] = sum(p.stat().st_size for p in DATA.rglob("*") if p.is_file())
    print(json.dumps(report, indent=1, ensure_ascii=False, default=str))


if __name__ == "__main__":
    main()
