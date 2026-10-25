import json
import math
import random
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_catalog as bc  # noqa: E402

DATA = bc.DATA


def load(name):
    return json.loads((DATA / name).read_text(encoding="utf-8"))


class StarsBinTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.stars = bc.read_stars_bin(DATA / "stars.bin")
        cls.by_hip = {r[0]: r for r in cls.stars["records"]}

    def test_round_trip(self):
        recs = [(1, 1.0, 0.0, 0.0, -1.5, 0.0, 379.2), (7, 0.0, 0.0, 1.0, 2.0, math.nan, math.nan)]
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "s.bin"
            bc.write_stars_bin(p, recs)
            raw = p.read_bytes()
            self.assertEqual(len(raw), 24 + 2 * 28)
            self.assertEqual(raw[:4], b"SKYS")
            back = bc.read_stars_bin(p)
        self.assertEqual(back["pmEpoch"], bc.PM_EPOCH)
        self.assertEqual(back["records"][0][0], 1)
        self.assertAlmostEqual(back["records"][0][6], 379.2, places=4)
        self.assertTrue(math.isnan(back["records"][1][5]) and math.isnan(back["records"][1][6]))

    def test_header_and_layout(self):
        s = self.stars
        self.assertEqual((s["version"], s["recordSize"]), (1, 28))
        self.assertAlmostEqual(s["pmEpoch"], 2026.5)
        self.assertEqual((DATA / "stars.bin").stat().st_size, 24 + 28 * s["count"])

    def test_count_plausible(self):
        self.assertTrue(8500 <= self.stars["count"] <= 9500, self.stars["count"])

    def test_sorted_and_unit_vectors(self):
        mags = [r[4] for r in self.stars["records"]]
        self.assertEqual(mags, sorted(mags))
        for r in self.stars["records"]:
            self.assertAlmostEqual(r[1] ** 2 + r[2] ** 2 + r[3] ** 2, 1.0, places=5)
            self.assertFalse(r[6] <= 0)

    def test_betelgeuse(self):
        r = self.by_hip[27989]
        self.assertAlmostEqual(r[4], 0.45, places=2)
        ra = math.degrees(math.atan2(r[2], r[1])) % 360
        dec = math.degrees(math.asin(r[3]))
        self.assertAlmostEqual(ra, 88.7929, delta=0.01)
        self.assertAlmostEqual(dec, 7.4071, delta=0.01)

    def test_polaris_direction(self):
        self.assertGreater(self.by_hip[11767][3], 0.9998)


class ConstellationFileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lines = load("lines.json")
        cls.cons = load("constellations.json")
        cls.roman = load("roman1875.json")
        cls.star_hips = {r[0] for r in bc.read_stars_bin(DATA / "stars.bin")["records"]}

    def test_88_ids_everywhere(self):
        ids = {c["id"] for c in self.cons}
        self.assertEqual(len(self.cons), 88)
        self.assertEqual(len(ids), 88)
        self.assertEqual({c["id"] for c in self.lines["constellations"]}, ids)
        self.assertEqual(len(self.lines["constellations"]), 88)
        self.assertEqual({r[3] for r in self.roman["rows"]}, ids)
        for i in ("And", "Ori", "UMa", "CVn", "Ser", "CrA", "TrA", "PsA"):
            self.assertIn(i, ids)

    def test_roman_row_count(self):
        self.assertEqual(len(self.roman["rows"]), 357)
        self.assertEqual(self.roman["equinox"], "B1875")
        self.assertEqual(self.roman["rows"][0], [0.0, 24.0, 88.0, "UMi"])
        self.assertEqual(self.roman["rows"][-1], [0.0, 24.0, -90.0, "Oct"])

    def test_orion_contains_betelgeuse(self):
        ori = next(c for c in self.lines["constellations"] if c["id"] == "Ori")
        self.assertEqual(ori["name"], "Orion")
        self.assertIn(27989, {h for s in ori["segments"] for h in s})

    def test_line_hips_in_stars_bin(self):
        for c in self.lines["constellations"]:
            self.assertTrue(c["segments"], c["id"])
            seen = set()
            for a, b in c["segments"]:
                self.assertIn(a, self.star_hips)
                self.assertIn(b, self.star_hips)
                self.assertNotEqual(a, b)
                key = (min(a, b), max(a, b))
                self.assertNotIn(key, seen)
                seen.add(key)

    def test_genitives(self):
        g = {c["id"]: c["genitive"] for c in self.cons}
        self.assertEqual(g["Ori"], "Orionis")
        self.assertEqual(g["CVn"], "Canum Venaticorum")
        self.assertEqual(g["Ser"], "Serpentis")

    def test_names(self):
        names = load("names.json")["stars"]
        by = {n["hip"]: n for n in names}
        self.assertEqual(by[27989]["name"], "Betelgeuse")
        self.assertTrue(by[27989]["label"])
        self.assertEqual(by[72105]["name"], "Izar")
        self.assertEqual(sum(n["label"] for n in names), bc.LABEL_COUNT)
        self.assertTrue(all(n["hip"] in self.star_hips for n in names))


class LookupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = load("roman1875.json")["rows"]
        cls.bounds = load("test/vi49_bounds.json")

    def test_roman_readme_examples(self):
        # VI/42 ReadMe examples are equinox 1950.0.
        cases = [(9.0, 65.0, "UMa"), (23.5, -20.0, "Aqr"), (5.12, 9.12, "Ori"), (9.4555, -19.9, "Hya"),
                 (12.8888, 22.0, "Com"), (15.6687, -12.1234, "Lib"), (19.0, -40.0, "CrA"), (6.2222, -81.1234, "Men")]
        import astropy.units as u
        from astropy.coordinates import FK5, SkyCoord
        from astropy.time import Time
        for ra, dec, want in cases:
            c = SkyCoord(ra=ra * u.hourangle, dec=dec * u.deg, frame=FK5(equinox=Time("B1950")))
            p = c.transform_to(FK5(equinox=Time("B1875")))
            self.assertEqual(bc.roman_lookup(self.rows, p.ra.hour, p.dec.deg), want, (ra, dec))

    def test_roman_matches_astropy_for_bright_stars(self):
        from astropy.coordinates import SkyCoord, get_constellation
        stars = [r for r in bc.read_stars_bin(DATA / "stars.bin")["records"] if r[4] < 4.0]
        xyz = np.array([r[1:4] for r in stars], dtype=float)
        ra = np.degrees(np.arctan2(xyz[:, 1], xyz[:, 0])) % 360
        dec = np.degrees(np.arcsin(np.clip(xyz[:, 2], -1, 1)))
        theirs = get_constellation(SkyCoord(ra, dec, unit="deg", frame="icrs"), short_name=True)
        ra75, dec75 = bc.to_b1875(ra, dec)
        ours = [bc.roman_lookup(self.rows, a, d) for a, d in zip(ra75, dec75)]
        mismatches = [(s[0], o, t) for s, o, t in zip(stars, ours, theirs) if o != t]
        self.assertLessEqual(len(mismatches), 2, mismatches)

    def test_vi49_structure(self):
        b = self.bounds
        self.assertEqual(b["equinox"], "B1875")
        self.assertEqual(len(b["constellations"]), 88)
        ser = next(c for c in b["constellations"] if c["id"] == "Ser")
        self.assertEqual(len(ser["polygons"]), 2)
        poles = {c["id"]: p["enclosesPole"] for c in b["constellations"] for p in c["polygons"] if p["enclosesPole"]}
        self.assertEqual(poles, {"UMi": "N", "Oct": "S"})
        for c in b["constellations"]:
            for p in c["polygons"]:
                self.assertEqual(p["vertices"][0], p["vertices"][-1])

    def test_vi49_polygons_agree_with_roman(self):
        rng = random.Random(1875)
        polys = [(c["id"], p) for c in self.bounds["constellations"] for p in c["polygons"]]
        disagreements = 0
        n = 3000
        for _ in range(n):
            ra = rng.uniform(0, 24)
            dec = math.degrees(math.asin(rng.uniform(-1, 1)))
            hits = [cid for cid, p in polys if bc.bounds_contains(p, ra, dec)]
            if hits != [bc.roman_lookup(self.rows, ra, dec)]:
                disagreements += 1
        self.assertEqual(disagreements, 0)


class ExtrasTests(unittest.TestCase):
    def setUp(self):
        if not (DATA / "dso.json").exists():
            self.skipTest("extras not built")
        self.star_hips = {r[0] for r in bc.read_stars_bin(DATA / "stars.bin")["records"]}

    def test_asterisms(self):
        a = load("asterisms.json")["asterisms"]
        dipper = next(x for x in a if x["id"] == "BigDipper")
        for line in dipper["lines"]:
            for ra, dec in line:
                self.assertTrue(0 <= ra < 360)
                self.assertTrue(40 < dec < 65)

    def test_milky_way(self):
        mw = load("milkyway.json")
        self.assertEqual([lv["level"] for lv in mw["levels"]], [1, 2, 3, 4, 5])
        for lv in mw["levels"]:
            for ring in lv["polygons"]:
                self.assertGreaterEqual(len(ring), 4)
                self.assertTrue(all(0 <= ra < 360 and -90 <= dec <= 90 for ra, dec in ring))

        def levels(ra, dec):
            return [lv["level"] for lv in mw["levels"] if bc.milkyway_contains(lv, ra, dec)]

        self.assertEqual(levels(271.0003, -29.0003), [1, 2, 3, 4, 5])  # Sagittarius star cloud
        self.assertIn(1, levels(309.0003, 41.0003))  # Cygnus
        for ra, dec in ((37.9543, 89.2641), (192.8595, 27.1283), (80.8937, -69.7561), (279.2347, 38.7837)):
            self.assertEqual(levels(ra, dec), [], (ra, dec))  # Polaris, NGP, LMC, Vega

    def test_dso(self):
        d = load("dso.json")
        objs = d["objects"]
        messier = {o["messier"] for o in objs if o["messier"]}
        self.assertEqual(set(range(1, 111)) - messier, {102})
        m42 = next(o for o in objs if o["messier"] == 42)
        self.assertEqual(m42["id"], "NGC 1976")
        self.assertAlmostEqual(m42["raDeg"], 83.8187, delta=0.01)
        for o in objs:
            self.assertTrue(o["messier"] or (o["mag"] is not None and o["mag"] <= d["magLimit"]))

    def test_artwork(self):
        art = load("artwork.json")
        self.assertEqual(len(art), 85)
        for a in art:
            path = DATA / a["file"]
            self.assertTrue(path.exists(), a["file"])
            self.assertEqual(list(bc._png_size(path)), a["size"])
            self.assertLessEqual(max(a["size"]), bc.ART_MAX_PX)
            self.assertEqual(len(a["anchors"]), 3)
            for an in a["anchors"]:
                self.assertIn(an["hip"], self.star_hips)
                self.assertTrue(0 <= an["pos"][0] <= a["size"][0] and 0 <= an["pos"][1] <= a["size"][1])


if __name__ == "__main__":
    unittest.main()
