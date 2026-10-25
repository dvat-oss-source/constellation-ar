#!/usr/bin/env python3
"""Reference answers for the SkyCore Swift tests.

Writes Data/fixtures/*.json:
  stars_skyfield.json      apparent topocentric alt/az + RA/Dec of date for ~200 Hipparcos stars (Skyfield)
  earth_orientation.json   Skyfield nutation, GMST/GAST and the ICRS->true-of-date matrix
  horizons.json            JPL Horizons airless apparent topocentric RA/Dec of date for Sun, Moon, planets
  omm_snapshot.json        CelesTrak OMM JSON snapshot (ISS + a few bright satellites)
  satellite_passes.json    Skyfield passes and samples for the snapshot
  constellation_events.json  Skyfield rise/transit/set of 20 constellation reference points for 3 observers (focus)

Usage: .venv/bin/python tools/make_fixtures.py [stars|orientation|horizons|satellites|focus|all] [--refresh-omm]
Network: Horizons (ssd.jpl.nasa.gov), CelesTrak, and the first de421.bsp download.
"""
import argparse
import datetime as dt
import json
import math
import pathlib
import random
import sys

import numpy as np
import requests
import skyfield
from skyfield import nutationlib
from skyfield.framelib import ICRS_to_J2000
from skyfield import almanac
from skyfield.api import EarthSatellite, Loader, Star, wgs84

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = ROOT / "tools" / ".cache"
OUT = ROOT / "Data" / "fixtures"
EPHEMERIS = "de421.bsp"

load = Loader(str(CACHE), verbose=False)
ts = load.timescale(builtin=True)

STAR_TIMES = [
    "2026-03-20T04:00:00Z",
    "2026-11-15T12:30:00Z",
    "2027-07-04T20:15:00Z",
    "2028-12-31T23:59:30Z",
]
STAR_OBSERVERS = [
    {"name": "Longyearbyen", "lat": 78.2232, "lon": 15.6267, "height_m": 10.0},
    {"name": "Boulder", "lat": 40.0150, "lon": -105.2705, "height_m": 1655.0},
    {"name": "Quito", "lat": -0.1807, "lon": -78.4678, "height_m": 2850.0},
    {"name": "Sydney", "lat": -33.8688, "lon": 151.2093, "height_m": 30.0},
]
HORIZONS_TIMES = sorted(STAR_TIMES + ["2026-06-15T02:00:00Z", "2027-12-01T09:45:00Z"])
HORIZONS_BODIES = {
    "sun": "10", "moon": "301", "mercury": "199", "venus": "299", "mars": "499",
    "jupiter": "599", "saturn": "699", "uranus": "799", "neptune": "899",
}
SAT_OBSERVERS = [
    {"name": "Seattle", "lat": 47.6062, "lon": -122.3321, "height_m": 50.0},
    {"name": "Sydney", "lat": -33.8688, "lon": 151.2093, "height_m": 30.0},
    {"name": "Quito", "lat": -0.1807, "lon": -78.4678, "height_m": 2850.0},
]
SAT_CATNRS = [25544, 48274, 20580, 33591, 25338]
CATALOG_EPOCHS = [2025.0, 2026.0, 2026.5, 2027.0, 2028.0]
HIP_EPOCH = 1991.25
SPECIAL_HIPS = [27989, 11767, 104382, 104214, 108870, 57939, 69673, 32349, 30438, 24436]


def parse_utc(s):
    d = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    return ts.from_datetime(d)


def write(name, payload):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / name
    path.write_text(json.dumps(payload, separators=(",", ":")) + "\n")
    print(f"wrote {path.relative_to(ROOT)} ({path.stat().st_size} bytes)")


def jd_utc(t):
    """UTC Julian date as Skyfield feeds it to SGP4."""
    return float(t.whole) + float(t.tai_fraction) - float(t._leap_seconds()) / 86400


def time_record(t, s):
    return {
        "utc": s,
        "jd_utc": jd_utc(t),
        "jd_tt": float(t.tt),
        "dut1": float(t.dut1),
        "delta_t": float(t.delta_t),
    }


def read_hipparcos():
    path = CACHE / "hip_main.dat"
    stars = {}
    with open(path) as f:
        for line in f:
            p = line.split("|")
            try:
                hip = int(p[1]); vmag = float(p[5]); ra = float(p[8]); dec = float(p[9])
            except ValueError:
                continue
            plx = float(p[11]) if p[11].strip() else None
            pmra = float(p[12]) if p[12].strip() else 0.0
            pmde = float(p[13]) if p[13].strip() else 0.0
            stars[hip] = {"hip": hip, "vmag": vmag, "ra_deg": ra, "dec_deg": dec,
                          "plx_mas": plx, "pmra_mas": pmra, "pmde_mas": pmde}
    return stars


def linear_direction(s, epoch_year):
    """Barycentric ICRS unit vector at epoch_year with Skyfield's linear space motion (radial velocity 0)."""
    ra, dec = math.radians(s["ra_deg"]), math.radians(s["dec_deg"])
    p = np.array([math.cos(dec) * math.cos(ra), math.cos(dec) * math.sin(ra), math.sin(dec)])
    e = np.array([-math.sin(ra), math.cos(ra), 0.0])
    n = np.array([-math.sin(dec) * math.cos(ra), -math.sin(dec) * math.sin(ra), math.cos(dec)])
    mas = math.radians(1 / 3_600_000)
    v = (s["pmra_mas"] * e + s["pmde_mas"] * n) * mas
    d = p + v * (epoch_year - HIP_EPOCH)
    return d / np.linalg.norm(d)


def select_stars(cat, count=200, seed=1875):
    eligible = sorted((s for s in cat.values() if s["vmag"] <= 6.5), key=lambda s: s["vmag"])
    chosen = {s["hip"]: s for s in eligible[:100]}
    for h in SPECIAL_HIPS:
        if h in cat:
            chosen[h] = cat[h]
    rng = random.Random(seed)
    rest = [s for s in eligible[100:] if s["hip"] not in chosen]
    bands = [(-90, -60), (-60, -30), (-30, 0), (0, 30), (30, 60), (60, 90)]
    per_band = max(1, (count - len(chosen)) // len(bands) + 1)
    for lo, hi in bands:
        pool = [s for s in rest if lo <= s["dec_deg"] < hi]
        rng.shuffle(pool)
        for s in pool[:per_band]:
            if len(chosen) < count:
                chosen[s["hip"]] = s
    return sorted(chosen.values(), key=lambda s: s["hip"])


def make_stars(eph):
    cat = read_hipparcos()
    stars = select_stars(cat)
    plx = np.array([s["plx_mas"] if s["plx_mas"] and s["plx_mas"] > 0 else 0.0 for s in stars])
    sky = Star(
        ra_hours=np.array([s["ra_deg"] / 15 for s in stars]),
        dec_degrees=np.array([s["dec_deg"] for s in stars]),
        ra_mas_per_year=np.array([s["pmra_mas"] for s in stars]),
        dec_mas_per_year=np.array([s["pmde_mas"] for s in stars]),
        parallax_mas=plx,
        epoch=ts.J(HIP_EPOCH),
    )
    earth = eph["earth"]
    times = [parse_utc(s) for s in STAR_TIMES]
    astrometric = []
    for t in times:
        v = earth.at(t).observe(sky).position.au
        astrometric.append((v / np.linalg.norm(v, axis=0)).T)
    results = []
    for oi, o in enumerate(STAR_OBSERVERS):
        obs = earth + wgs84.latlon(o["lat"], o["lon"], elevation_m=o["height_m"])
        for ti, t in enumerate(times):
            app = obs.at(t).observe(sky).apparent()
            alt, az, _ = app.altaz()
            ra, dec, _ = app.radec("date")
            for si in range(len(stars)):
                results.append([si, ti, oi, round(float(alt.degrees[si]), 9), round(float(az.degrees[si]), 9),
                                round(float(ra.hours[si]), 10), round(float(dec.degrees[si]), 9)])
    out_stars = []
    for si, s in enumerate(stars):
        out_stars.append({
            "hip": s["hip"], "vmag": s["vmag"],
            "hip_ra_deg": s["ra_deg"], "hip_dec_deg": s["dec_deg"], "plx_mas": s["plx_mas"],
            "pmra_mas": s["pmra_mas"], "pmde_mas": s["pmde_mas"],
            "catalog_icrs": {f"{e}": [round(float(x), 12) for x in linear_direction(s, e)] for e in CATALOG_EPOCHS},
            "astrometric": [[round(float(x), 12) for x in astrometric[ti][si]] for ti in range(len(times))],
        })
    write("stars_skyfield.json", {
        "generator": "tools/make_fixtures.py", "skyfield": skyfield.__version__, "ephemeris": EPHEMERIS,
        "notes": "Hipparcos I/239 (epoch J1991.25, ICRS). alt/az: airless apparent topocentric (no refraction, "
                 "no polar motion). ra/dec: apparent topocentric, true equator & equinox of date. astrometric: "
                 "geocentric ICRS unit vectors incl. proper motion and parallax. catalog_icrs: barycentric unit "
                 "vectors at Julian epoch years with linear space motion (radial velocity 0).",
        "observers": STAR_OBSERVERS,
        "times": [time_record(t, s) for t, s in zip(times, STAR_TIMES)],
        "stars": out_stars,
        "columns": ["star", "time", "observer", "alt_deg", "az_deg", "ra_date_hours", "dec_date_deg"],
        "results": results,
    })


def make_orientation():
    rows = []
    for s in STAR_TIMES + ["2000-01-01T12:00:00Z", "2026-10-25T21:00:00Z", "2030-06-01T00:00:00Z"]:
        t = parse_utc(s)
        dpsi, deps = nutationlib.iau2000a_radians(t)
        rows.append({
            **time_record(t, s),
            "dpsi_arcsec": math.degrees(float(dpsi)) * 3600,
            "deps_arcsec": math.degrees(float(deps)) * 3600,
            "mean_obliquity_arcsec": float(nutationlib.mean_obliquity(t.tdb)),
            "gmst_hours": float(t.gmst),
            "gast_hours": float(t.gast),
            "icrs_to_true_of_date": [[float(x) for x in row] for row in t.M],
            "icrs_to_mean_of_date": [[float(x) for x in row] for row in (t.P @ ICRS_to_J2000)],
        })
    write("earth_orientation.json", {
        "generator": "tools/make_fixtures.py", "skyfield": skyfield.__version__,
        "notes": "Skyfield builtin timescale; nutation IAU 2000A; matrices act on column vectors (v_date = M v_icrs).",
        "rows": rows,
    })


def horizons_query(code, observer, jds):
    params = {
        "format": "json", "COMMAND": f"'{code}'", "OBJ_DATA": "NO", "MAKE_EPHEM": "YES",
        "EPHEM_TYPE": "OBSERVER", "CENTER": "'coord@399'", "COORD_TYPE": "GEODETIC",
        "SITE_COORD": f"'{observer['lon']},{observer['lat']},{observer['height_m'] / 1000}'",
        "TLIST": " ".join(f"'{jd:.9f}'" for jd in jds), "TLIST_TYPE": "JD", "TIME_TYPE": "UT",
        "QUANTITIES": "'2'", "ANG_FORMAT": "DEG", "EXTRA_PREC": "YES", "APPARENT": "AIRLESS",
        "CSV_FORMAT": "YES",
    }
    # Horizons returns TLIST rows sorted by time, so callers must pass jds in ascending order.
    assert list(jds) == sorted(jds)
    r = requests.get("https://ssd.jpl.nasa.gov/api/horizons.api", params=params, timeout=60)
    r.raise_for_status()
    text = r.json()["result"]
    if "$$SOE" not in text:
        raise RuntimeError(f"Horizons error for {code}: {text[:800]}")
    body = text.split("$$SOE")[1].split("$$EOE")[0]
    values = []
    for line in body.strip().splitlines():
        nums = []
        for field in line.split(","):
            try:
                nums.append(float(field))
            except ValueError:
                pass
        values.append((nums[-2], nums[-1]))
    if len(values) != len(jds):
        raise RuntimeError(f"Horizons returned {len(values)} rows for {len(jds)} times ({code})")
    return values


def make_horizons():
    times = [parse_utc(s) for s in HORIZONS_TIMES]
    jds = [jd_utc(t) for t in times]
    entries = []
    for oi, o in enumerate(STAR_OBSERVERS):
        for body, code in HORIZONS_BODIES.items():
            for ti, (ra, dec) in enumerate(horizons_query(code, o, jds)):
                entries.append({"body": body, "time": ti, "observer": oi, "ra_deg": ra, "dec_deg": dec})
            print(f"horizons {o['name']} {body}")
    write("horizons.json", {
        "generator": "tools/make_fixtures.py", "source": "JPL Horizons API (https://ssd.jpl.nasa.gov/api/horizons.api)",
        "retrieved_utc": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "notes": "QUANTITIES=2 (airless apparent topocentric RA/Dec, true equator & equinox of date), "
                 "TIME_TYPE=UT (UTC), geodetic observer sites.",
        "observers": STAR_OBSERVERS,
        "times": [time_record(t, s) for t, s in zip(times, HORIZONS_TIMES)],
        "entries": entries,
    })


def fetch_omm(refresh):
    path = OUT / "omm_snapshot.json"
    if path.exists() and not refresh:
        return json.loads(path.read_text())
    records = []
    for catnr in SAT_CATNRS:
        r = requests.get("https://celestrak.org/NORAD/elements/gp.php",
                         params={"CATNR": catnr, "FORMAT": "json"}, timeout=60)
        r.raise_for_status()
        records.extend(r.json())
    OUT.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(records, indent=1) + "\n")
    print(f"wrote {path.relative_to(ROOT)} ({len(records)} records)")
    return records


def make_satellites(eph, refresh):
    records = fetch_omm(refresh)
    sats = [EarthSatellite.from_omm(ts, rec) for rec in records]
    iss = next(s for s in sats if s.model.satnum == 25544)
    start_dt = iss.epoch.utc_datetime().replace(minute=0, second=0, microsecond=0) + dt.timedelta(hours=1)
    t0 = ts.from_datetime(start_dt)
    t1 = ts.from_datetime(start_dt + dt.timedelta(days=3))
    earth, sun = eph["earth"], eph["sun"]
    rng = random.Random(25544)
    passes, samples = [], []

    def sample(sat, topos, oi, t):
        alt, az, dist = (sat - topos).at(t).altaz()
        sun_alt = (earth + topos).at(t).observe(sun).apparent().altaz()[0].degrees
        samples.append({
            "norad": int(sat.model.satnum), "observer": oi, "jd_utc": jd_utc(t),
            "alt_deg": float(alt.degrees), "az_deg": float(az.degrees), "range_km": float(dist.km),
            "sunlit": bool(sat.at(t).is_sunlit(eph)), "sun_alt_deg": float(sun_alt),
        })

    for oi, o in enumerate(SAT_OBSERVERS):
        topos = wgs84.latlon(o["lat"], o["lon"], elevation_m=o["height_m"])
        for sat in sats:
            times, events = sat.find_events(topos, t0, t1, altitude_degrees=0.0)
            i = 0
            while i + 2 < len(events):
                if list(events[i:i + 3]) != [0, 1, 2]:
                    i += 1
                    continue
                tr, tc, tset = times[i], times[i + 1], times[i + 2]
                alt = (sat - topos).at(tc).altaz()[0].degrees
                sun_alt = (earth + topos).at(tc).observe(sun).apparent().altaz()[0].degrees
                passes.append({
                    "norad": int(sat.model.satnum), "name": sat.name, "observer": oi,
                    "rise_jd_utc": jd_utc(tr), "culmination_jd_utc": jd_utc(tc),
                    "set_jd_utc": jd_utc(tset), "max_alt_deg": float(alt),
                    "sunlit_at_culmination": bool(sat.at(tc).is_sunlit(eph)),
                    "sun_alt_at_culmination_deg": float(sun_alt),
                })
                span = float(tset.tt - tr.tt)
                for k in range(5):
                    sample(sat, topos, oi, ts.tt_jd(float(tr.tt) + span * (k + 0.5) / 5))
                i += 3
            for _ in range(15):
                sample(sat, topos, oi, ts.tt_jd(float(t0.tt) + rng.random() * float(t1.tt - t0.tt)))
        print(f"satellites {o['name']}: {sum(p['observer'] == oi for p in passes)} passes")
    write("satellite_passes.json", {
        "generator": "tools/make_fixtures.py", "skyfield": skyfield.__version__, "ephemeris": EPHEMERIS,
        "omm_file": "omm_snapshot.json",
        "start_utc": start_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "end_utc": (start_dt + dt.timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "horizon_deg": 0.0,
        "notes": "Skyfield EarthSatellite.from_omm + find_events(altitude_degrees=0) (geometric altitude). "
                 "sunlit = Skyfield is_sunlit (line to Sun vs Earth sphere R=6378136.6 m). sun_alt: apparent "
                 "airless Sun altitude at the observer.",
        "observers": SAT_OBSERVERS,
        "passes": passes,
        "samples": samples,
    })


FOCUS_CONSTELLATIONS = ["UMi", "UMa", "Cas", "Cep", "Dra", "Cyg", "Ori", "Tau", "Gem", "Leo",
                        "Vir", "Sco", "Sgr", "Cru", "Cen", "Car", "Oct", "Hyi", "Pav", "Lyr"]
FOCUS_OBSERVERS = [STAR_OBSERVERS[0], STAR_OBSERVERS[1], STAR_OBSERVERS[3]]
FOCUS_TIMES = ["2026-11-15T12:30:00Z", "2027-06-20T03:00:00Z"]
# Airless (geometric) altitude of the reference point at rise/set: 34' of standard refraction at the horizon, no
# semidiameter (it is a point), i.e. apparent altitude 0 under standard refraction.
FOCUS_HORIZON_DEG = -0.5667


def figure_reference_point(cid, lines, vectors):
    """Normalised mean of the unit vectors of the stick-figure stars (unique HIPs), ICRS at the stars.bin epoch.
    Must match ConstellationAtlas.referencePoint(of:) in SkyCore."""
    hips = sorted({h for seg in next(c for c in lines["constellations"] if c["id"] == cid)["segments"] for h in seg})
    v = np.sum([vectors[h] for h in hips], axis=0)
    return v / np.linalg.norm(v)


def make_focus(eph):
    sys.path.insert(0, str(ROOT / "tools"))
    import build_catalog as bc

    lines = json.loads((ROOT / "Data" / "lines.json").read_text())
    vectors = {r[0]: np.array(r[1:4], dtype=float) for r in bc.read_stars_bin(ROOT / "Data" / "stars.bin")["records"]}
    times = [parse_utc(s) for s in FOCUS_TIMES]
    cases = []
    for oi, o in enumerate(FOCUS_OBSERVERS):
        observer = eph["earth"] + wgs84.latlon(o["lat"], o["lon"], elevation_m=o["height_m"])
        for cid in FOCUS_CONSTELLATIONS:
            ref = figure_reference_point(cid, lines, vectors)
            ra = math.degrees(math.atan2(ref[1], ref[0])) % 360.0
            dec = math.degrees(math.asin(ref[2]))
            star = Star(ra_hours=ra / 15.0, dec_degrees=dec)
            for ti, t0 in enumerate(times):
                t1 = ts.tt_jd(float(t0.tt) + 1.0)
                events = {}
                for name, finder in (("rise", almanac.find_risings), ("set", almanac.find_settings), ("transit", almanac.find_transits)):
                    if name == "transit":
                        found = finder(observer, star, t0, t1)
                    else:
                        found = finder(observer, star, t0, t1, horizon_degrees=FOCUS_HORIZON_DEG)
                        found = found[0][found[1]]
                    events[name] = jd_utc(found[0]) if len(found) else None
                lat = math.radians(o["lat"])
                x = (math.sin(math.radians(FOCUS_HORIZON_DEG)) - math.sin(lat) * ref[2]) / (math.cos(lat) * math.sqrt(1 - ref[2] ** 2))
                status = "circumpolar" if x < -1 else ("neverRises" if x > 1 else "risesAndSets")
                if (status == "risesAndSets") != (events["rise"] is not None and events["set"] is not None):
                    raise SystemExit(f"{cid} {o['name']}: geometry says {status} but Skyfield found {events}")
                cases.append({"constellation": cid, "observer": oi, "time": ti, "ref": [float(v) for v in ref],
                              "status": status, **events})
    write("constellation_events.json", {
        "generator": "tools/make_fixtures.py focus", "skyfield": skyfield.__version__,
        "horizon_deg": FOCUS_HORIZON_DEG,
        "notes": "Reference point = normalised mean of the unit vectors of the stick-figure stars (lines.json, stars.bin "
                 "epoch). Skyfield find_risings/find_settings (airless altitude = horizon_deg) and find_transits (upper "
                 "culmination) for the Star at that RA/Dec; the first event within 24 h (TT) after the start time; "
                 "values are UTC Julian dates, null when the event does not happen.",
        "observers": FOCUS_OBSERVERS, "times": [time_record(t, s) for t, s in zip(times, FOCUS_TIMES)],
        "cases": cases,
    })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("what", nargs="?", default="all",
                    choices=["stars", "orientation", "horizons", "satellites", "focus", "all"])
    ap.add_argument("--refresh-omm", action="store_true", help="re-download the OMM snapshot")
    args = ap.parse_args()
    eph = load(EPHEMERIS) if args.what in ("stars", "satellites", "focus", "all") else None
    if args.what in ("stars", "all"):
        make_stars(eph)
    if args.what in ("orientation", "all"):
        make_orientation()
    if args.what in ("horizons", "all"):
        make_horizons()
    if args.what in ("satellites", "all"):
        make_satellites(eph, args.refresh_omm)
    if args.what in ("focus", "all"):
        make_focus(eph)
    return 0


if __name__ == "__main__":
    sys.exit(main())
