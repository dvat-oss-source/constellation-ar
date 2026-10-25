import math
import struct
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_solver_db as sdb  # noqa: E402

STARS = sdb.ROOT / "Data" / "stars.bin"


def random_rotation(rng):
    q = rng.normal(size=4)
    q /= np.linalg.norm(q)
    w, x, y, z = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


class HelperTests(unittest.TestCase):
    def test_primes(self):
        self.assertEqual(sdb.next_prime(10), 11)
        self.assertEqual(sdb.next_prime(13), 17)
        self.assertTrue(all(sdb.is_prime(p) for p in (2, 3, 5, 7, 11, 13)))
        self.assertFalse(sdb.is_prime(1) or sdb.is_prime(9) or sdb.is_prime(49))

    def test_breadth_first_order_matches_cedar_solve(self):
        got = list(sdb.breadth_first_combinations([0, 1, 2, 3, 4, 5], 4))
        self.assertEqual(got[:6], [(0, 1, 2, 3), (0, 1, 2, 4), (0, 1, 3, 4), (0, 2, 3, 4), (1, 2, 3, 4), (0, 1, 2, 5)])
        self.assertEqual(len(got), 15)

    def test_fibonacci_lattice_is_unit_and_covers_sphere(self):
        pts = sdb.fibonacci_sphere_lattice(500)
        self.assertEqual(len(pts), 1001)
        np.testing.assert_allclose(np.linalg.norm(pts, axis=1), 1, atol=1e-12)
        self.assertLess(np.abs(pts.mean(axis=0)).max(), 0.01)

    def test_edge_ratios_are_rotation_and_order_invariant(self):
        rng = np.random.default_rng(4)
        v = rng.normal(size=(8, 3))
        v /= np.linalg.norm(v, axis=1, keepdims=True) * 4
        v = v + np.array([1.0, 0, 0])
        v /= np.linalg.norm(v, axis=1, keepdims=True)
        pats = [(0, 1, 2, 3), (3, 1, 0, 2), (4, 5, 6, 7)]
        r1, l1 = sdb.edge_ratios(v, pats)
        np.testing.assert_allclose(r1[0], r1[1], atol=1e-12)
        r2, l2 = sdb.edge_ratios(v @ random_rotation(rng).T, pats)
        np.testing.assert_allclose(r1, r2, atol=1e-9)
        np.testing.assert_allclose(l1, l2, atol=1e-9)
        self.assertTrue(np.all(r1 < 1) and np.all(np.diff(r1, axis=1) >= 0))

    def test_hash_matches_documented_formula(self):
        bins = 50
        key = [3, 7, 11, 19, 42]
        self.assertEqual(int(sdb.pattern_key_hash(key, bins)), sum(k * bins ** i for i, k in enumerate(key)))
        self.assertEqual(int(sdb.hash_index(1234567, 1009)), (1234567 * 2654435761) % 1009)


@unittest.skipUnless(STARS.exists(), "Data/stars.bin missing")
class BuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        cls.path = Path(cls.dir.name) / "db.bin"
        cls.info = sdb.build(STARS, cls.path, min_fov_deg=40, max_fov_deg=80, mag_limit=4.0, oversampling=5,
                             per_field=10)
        cls.raw = cls.path.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def header(self):
        return struct.unpack_from("<4sIIIII", self.raw, 0)

    def test_header_and_size(self):
        magic, version, n_stars, n_patterns, length, bins = self.header()
        self.assertEqual((magic, version), (b"SOLV", 1))
        self.assertEqual((n_stars, n_patterns, length, bins), (self.info["stars"], self.info["patterns"], self.info["table"], 50))
        self.assertEqual(len(self.raw), sdb.HEADER_SIZE + n_stars * sdb.STAR_RECORD + length * (8 + 2 + 2))
        self.assertTrue(sdb.is_prime(length))

    def test_stars_are_unit_vectors_sorted_by_brightness(self):
        n = self.info["stars"]
        rec = np.frombuffer(self.raw, dtype=np.dtype([("hip", "<u4"), ("v", "<f4", 3), ("m", "<f4")]),
                            count=n, offset=sdb.HEADER_SIZE)
        np.testing.assert_allclose(np.linalg.norm(rec["v"], axis=1), 1, atol=1e-6)
        self.assertTrue(np.all(np.diff(rec["m"]) >= 0))
        self.assertLessEqual(rec["m"].max(), 4.0)

    def test_every_pattern_is_found_by_its_own_key(self):
        _, _, n_stars, n_patterns, length, bins = self.header()
        rec_off = sdb.HEADER_SIZE
        rec = np.frombuffer(self.raw, dtype=np.dtype([("hip", "<u4"), ("v", "<f4", 3), ("m", "<f4")]), count=n_stars, offset=rec_off)
        vectors = rec["v"].astype(np.float64)
        table_off = rec_off + n_stars * sdb.STAR_RECORD
        table = np.frombuffer(self.raw, dtype="<u2", count=length * 4, offset=table_off).reshape(length, 4)
        keys = np.frombuffer(self.raw, dtype="<u2", count=length, offset=table_off + length * 8)
        edges = np.frombuffer(self.raw, dtype="<u2", count=length, offset=table_off + length * 10).view(np.float16)
        occupied = np.nonzero(table.any(axis=1))[0]
        self.assertEqual(len(occupied), n_patterns)
        rng = np.random.default_rng(1)
        for slot in rng.choice(occupied, size=300, replace=False):
            pattern = table[slot]
            self.assertEqual(len(set(pattern.tolist())), 4)
            ratios, largest = sdb.edge_ratios(vectors, [pattern])
            hashed = int(sdb.pattern_key_hash((ratios[0] * bins).astype(np.int64), bins))
            self.assertEqual(int(keys[slot]), hashed & 0xFFFF)
            self.assertAlmostEqual(float(edges[slot]), largest[0] * 1000, delta=largest[0] * 1000 * 1e-3 + 1e-3)
            base = int(sdb.hash_index(hashed, length))
            c = 0
            while (base + c * c) % length != slot:
                self.assertTrue(table[(base + c * c) % length].any(), "probe reached an empty slot before the pattern")
                c += 1

    def test_pattern_stars_are_ordered_by_distance_from_centroid(self):
        _, _, n_stars, _, length, _ = self.header()
        vectors = np.frombuffer(self.raw, dtype=np.dtype([("hip", "<u4"), ("v", "<f4", 3), ("m", "<f4")]),
                                count=n_stars, offset=sdb.HEADER_SIZE)["v"].astype(np.float64)
        table = np.frombuffer(self.raw, dtype="<u2", count=length * 4,
                              offset=sdb.HEADER_SIZE + n_stars * sdb.STAR_RECORD).reshape(length, 4)
        for slot in np.nonzero(table.any(axis=1))[0][:200]:
            pv = vectors[table[slot]]
            d = np.sum((pv - pv.mean(axis=0)) ** 2, axis=1)
            self.assertTrue(np.all(np.diff(d) >= -1e-12))

    def test_build_is_deterministic(self):
        again = Path(self.dir.name) / "again.bin"
        sdb.build(STARS, again, min_fov_deg=40, max_fov_deg=80, mag_limit=4.0, oversampling=5, per_field=10)
        self.assertEqual(again.read_bytes(), self.raw)


if __name__ == "__main__":
    unittest.main()
