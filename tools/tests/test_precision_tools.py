"""Synthetic checks for tools/analyze_session.py and tools/calibrate_lens.py.

    .venv/bin/python -m unittest tools/tests/test_precision_tools.py -v
"""
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import analyze_session as analyze  # noqa: E402
import calibrate_lens as lens  # noqa: E402


# MARK: Timing / rolling shutter

SMALL = (160, 120)
FULL = (640, 480)
FOCAL = 500.0


class Texture:
    """A band-limited random scene evaluated analytically, so sub-pixel shifts are exact."""

    def __init__(self, rng, count=70):
        self.k = rng.uniform(-0.09, 0.09, size=(count, 2))
        self.phase = rng.uniform(0, 2 * np.pi, count)
        self.amp = 1.0 / (1.0 + 8.0 * np.linalg.norm(self.k, axis=1))
        self.amp *= 34.0 / np.sqrt(np.sum(self.amp ** 2) / 2)

    def sample(self, x, y):
        total = np.zeros_like(x, dtype=float)
        for k, p, a in zip(self.k, self.phase, self.amp):
            total += a * np.cos(2 * np.pi * (k[0] * x + k[1] * y) + p)
        return 128 + total


def make_timing_session(folder: Path, tau: float, readout: float, seed: int = 3, seconds: float = 6.0, fps: float = 30.0):
    rng = np.random.default_rng(seed)
    texture = Texture(rng)
    (folder / "frames").mkdir(parents=True)
    base = 1000.0
    a1, w1, p1 = 0.55, 2 * np.pi * 1.1, 0.3
    a2, w2, p2 = 0.65, 2 * np.pi * 0.8, 1.1
    a3, w3, p3 = 0.2, 2 * np.pi * 0.37, 0.0

    def cumulative(t):
        s = t - base
        return np.array([-a1 / w1 * (np.cos(w1 * s + p1) - np.cos(p1)), -a2 / w2 * (np.cos(w2 * s + p2) - np.cos(p2)),
                         -a3 / w3 * (np.cos(w3 * s + p3) - np.cos(p3))])

    t = base + np.arange(0, seconds, 0.005)
    rates = np.stack([a1 * np.sin(w1 * (t - base) + p1), a2 * np.sin(w2 * (t - base) + p2), a3 * np.sin(w3 * (t - base) + p3)], axis=1)
    motion = np.zeros((len(t), 8))
    motion[:, 0] = t
    motion[:, 4] = 1.0
    motion[:, 5:8] = rates
    motion.astype("<f8").tofile(folder / "motion.f64")

    exposure = 0.01
    f_small = FOCAL * SMALL[0] / FULL[0]
    rows = np.arange(SMALL[1])
    r = (rows + 0.5) / SMALL[1] - 0.5
    xs, ys = np.meshgrid(np.arange(SMALL[0], dtype=float), rows.astype(float))
    frames = []
    for i in range(int(seconds * fps) - 6):
        ft = base + 0.2 + i / fps
        sx = np.empty(SMALL[1])
        sy = np.empty(SMALL[1])
        for row in range(SMALL[1]):
            theta = cumulative(ft + 0.5 * exposure + tau + r[row] * readout)
            sx[row], sy[row] = f_small * theta[0], -f_small * theta[1]
        image = texture.sample(xs - sx[:, None], ys - sy[:, None]) + rng.normal(0, 1.0, size=xs.shape)
        name = f"frames/s{i:06d}.y8"
        np.clip(np.round(image), 0, 255).astype(np.uint8).tofile(folder / name)
        frames.append({"seq": i, "t": ft, "size": list(FULL), "exposure": exposure, "K": [FOCAL, FOCAL, FULL[0] / 2, FULL[1] / 2],
                       "small": name, "smallSize": list(SMALL)})
    (folder / "frames.jsonl").write_text("\n".join(json.dumps(f) for f in frames) + "\n")
    (folder / "meta.json").write_text(json.dumps({
        "motionColumns": ["t", "qx", "qy", "qz", "qw", "rotX", "rotY", "rotZ"], "captureTimeReference": 0.5}))


class TimingTests(unittest.TestCase):
    def run_case(self, tau, readout):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d) / "session"
            make_timing_session(folder, tau, readout)
            return analyze.analyze(folder)

    def test_recovers_offset_and_readout(self):
        result = self.run_case(0.014, 0.026)
        self.assertLess(abs(result["offsetSeconds"] - 0.014), 0.002, result)
        self.assertLess(abs(result["readoutSeconds"] - 0.026), 0.006, result)
        self.assertAlmostEqual(result["diagnostics"]["gain"], 1.0, delta=0.1)
        self.assertNotIn("warning", result["diagnostics"])

    def test_negative_offset(self):
        result = self.run_case(-0.021, 0.0)
        self.assertLess(abs(result["offsetSeconds"] + 0.021), 0.002, result)
        self.assertLess(abs(result["readoutSeconds"]), 0.006, result)

    def test_merge_keeps_other_sections(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "calibration.json"
            path.write_text(json.dumps({"lens": {"focalScaleX": 1.01}}))
            analyze.merge_into(path, {"offsetSeconds": 0.01, "readoutSeconds": 0.02, "diagnostics": {"pairs": 5}})
            merged = json.loads(path.read_text())
            self.assertEqual(merged["lens"]["focalScaleX"], 1.01)
            self.assertEqual(merged["timing"], {"offsetSeconds": 0.01, "readoutSeconds": 0.02})


# MARK: Lens / boresight

SIZE = (4032, 3024)
K = (3000.0, 3000.0, 2016.0, 1512.0)
TRUTH = np.array([0.004, -0.003, 0.002, -0.0015, -0.008, 0.004, np.radians(0.35), np.radians(-0.25), np.radians(0.2)])
TRUTH_YAW = np.radians(7.0)


def attitude(azimuth, altitude, roll):
    """Device-from-reference attitude of a phone looking toward (azimuth, altitude)."""
    f = np.array([np.cos(altitude) * np.cos(azimuth), np.cos(altitude) * np.sin(azimuth), np.sin(altitude)])
    down = -(np.array([0, 0, 1.0]) - f[2] * f)
    down /= np.linalg.norm(down)
    x = np.cross(down, f)
    cos, sin = np.cos(roll), np.sin(roll)
    x, down = cos * x + sin * down, cos * down - sin * x
    return lens.DEVICE_TO_CAMERA.T @ np.stack([x, down, f])


def synthesize(rng, values, yaw, frames, per_frame=40, noise=0.3):
    out = []
    for i in range(frames):
        r = attitude(rng.uniform(0, 2 * np.pi), np.radians(rng.uniform(20, 75)), np.radians(rng.uniform(-40, 40)))
        forward = (r.T @ lens.DEVICE_TO_CAMERA.T @ np.array([0, 0, 1.0]))
        forward = lens.rz(-yaw) @ forward  # the star-side direction the true camera sees at its centre
        vectors = forward + rng.normal(0, 0.45, size=(per_frame * 3, 3))
        vectors /= np.linalg.norm(vectors, axis=1, keepdims=True)
        draft = lens.Observation(0, i, r, K, SIZE, np.zeros((len(vectors), 2)), vectors)
        pixels = lens.project(values, np.array([yaw]), [draft])
        inside = (pixels[:, 0] > 0) & (pixels[:, 0] < SIZE[0]) & (pixels[:, 1] > 0) & (pixels[:, 1] < SIZE[1]) & (vectors[:, 2] > 0.2)
        pixels, vectors = pixels[inside][:per_frame], vectors[inside][:per_frame]
        out.append(lens.Observation(0, i, r, K, SIZE, pixels + rng.normal(0, noise, pixels.shape), vectors))
    return out


class LensTests(unittest.TestCase):
    def test_forward_axis_projects_to_principal_point(self):
        r = attitude(0.7, 0.9, 0.2)
        forward = r.T @ lens.DEVICE_TO_CAMERA.T @ np.array([0, 0, 1.0])
        obs = lens.Observation(0, 0, r, K, SIZE, np.zeros((1, 2)), forward[None, :])
        pixel = lens.project(np.zeros(9), np.zeros(1), [obs])[0]
        np.testing.assert_allclose(pixel, [K[2], K[3]], atol=1e-6)

    def test_recovers_injected_lens_and_boresight(self):
        rng = np.random.default_rng(11)
        obs = synthesize(rng, TRUTH, TRUTH_YAW, frames=14)
        values, yaws, info = lens.fit(obs, 1, list(lens.PARAMETERS))
        self.assertLess(info["rmsPixels"], 0.6, info)
        self.assertAlmostEqual(np.degrees(yaws[0]), 7.0, delta=0.05)
        np.testing.assert_allclose(np.degrees(values[6:9]), np.degrees(TRUTH[6:9]), atol=0.03)
        self.assertAlmostEqual(values[0], TRUTH[0], delta=0.0015)
        self.assertAlmostEqual(values[1], TRUTH[1], delta=0.0015)
        self.assertAlmostEqual(values[4], TRUTH[4], delta=0.004)

    def test_rejects_wrong_matches(self):
        rng = np.random.default_rng(5)
        obs = synthesize(rng, TRUTH, TRUTH_YAW, frames=12)
        for o in obs[:4]:
            o.pixels[:3] += rng.uniform(40, 120, size=(3, 2))  # a few bad star matches
        values, _, info = lens.fit(obs, 1, list(lens.PARAMETERS))
        self.assertGreaterEqual(info["rejected"], 10)
        self.assertLess(info["rmsPixels"], 0.7, info)
        np.testing.assert_allclose(np.degrees(values[6:9]), np.degrees(TRUTH[6:9]), atol=0.04)

    def test_boresight_only_fit_with_two_sessions(self):
        rng = np.random.default_rng(2)
        truth = np.zeros(9)
        truth[6:9] = np.radians([0.3, 0.2, -0.4])
        first = synthesize(rng, truth, np.radians(-12), frames=6)
        second = synthesize(rng, truth, np.radians(25), frames=6)
        for o in second:
            o.session = 1
        values, yaws, info = lens.fit(first + second, 2, ["boresightX", "boresightY", "boresightZ"])
        np.testing.assert_allclose(np.degrees(values[6:9]), [0.3, 0.2, -0.4], atol=0.03)
        np.testing.assert_allclose(np.degrees(yaws), [-12, 25], atol=0.05)

    def test_lens_json_matches_swift_codable(self):
        payload = lens.lens_json(TRUTH)
        self.assertEqual(set(payload), {"focalScaleX", "focalScaleY", "principalShiftX", "principalShiftY", "distortion", "boresight"})
        self.assertEqual(len(payload["boresight"]), 3)
        self.assertEqual(set(payload["distortion"]), {"k1", "k2"})
        json.dumps(payload)


class LoaderTests(unittest.TestCase):
    def test_wcs_grid_centre(self):
        from astropy.io import fits
        from astropy.wcs import WCS

        w, h = 400, 300
        wcs = WCS(naxis=2)
        wcs.wcs.ctype = ["RA---TAN", "DEC--TAN"]
        wcs.wcs.crval = [150.0, 30.0]
        wcs.wcs.crpix = [w / 2 + 0.5, h / 2 + 0.5]
        wcs.wcs.cd = [[-1e-3, 0], [0, 1e-3]]
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "f000001.wcs"
            fits.PrimaryHDU(header=wcs.to_header()).writeto(path)
            pixels, ra, dec = lens.load_wcs(path, w, h, flip=False)
        middle = int(np.argmin(np.linalg.norm(pixels - [w / 2, h / 2], axis=1)))
        self.assertAlmostEqual(ra[middle], 150.0, places=6)
        self.assertAlmostEqual(dec[middle], 30.0, places=6)
        # a pixel one step right of the centre is lower RA with this CD matrix
        step = int(np.argmin(np.linalg.norm(pixels - [w / 2 + w / 9, h / 2], axis=1)))
        self.assertLess(ra[step], 150.0)

    def test_corr_flip_convention(self):
        from astropy.io import fits

        h = 3024
        pixels = np.array([[10.0, 20.0], [4000.5, 3000.25]])
        for flip in (True, False):
            fx = lens.corner_to_fits(pixels, h, flip)
            columns = [fits.Column(name="field_x", format="D", array=fx[:, 0]), fits.Column(name="field_y", format="D", array=fx[:, 1]),
                       fits.Column(name="index_ra", format="D", array=[1.0, 2.0]), fits.Column(name="index_dec", format="D", array=[3.0, 4.0])]
            with tempfile.TemporaryDirectory() as d:
                path = Path(d) / "f.corr"
                fits.HDUList([fits.PrimaryHDU(), fits.BinTableHDU.from_columns(columns)]).writeto(path)
                got, ra, dec = lens.load_corr(path, h, flip)
            np.testing.assert_allclose(got, pixels, atol=1e-9)
            np.testing.assert_allclose([ra, dec], [[1.0, 2.0], [3.0, 4.0]])

    def test_zenith_star_is_up(self):
        from astropy.coordinates import AltAz, EarthLocation, SkyCoord
        from astropy.time import Time
        import astropy.units as u

        when = datetime(2026, 1, 15, 5, 0, tzinfo=timezone.utc)
        location = EarthLocation(lat=40 * u.deg, lon=-100 * u.deg, height=300 * u.m)
        frame = AltAz(obstime=Time(when), location=location, pressure=1013.25 * u.hPa, temperature=10 * u.deg_C,
                      relative_humidity=0.5, obswl=0.55 * u.micron)
        # An ICRS position that is at the zenith of the same refracted frame comes back as straight up (+Z).
        zenith = SkyCoord(az=0 * u.deg, alt=90 * u.deg, frame=frame).icrs
        direction = lens.sky_to_reference(zenith.ra.deg, zenith.dec.deg, when, 40.0, -100.0, 300.0)[0]
        self.assertGreater(direction[2], np.cos(np.radians(0.01)))
        # The celestial pole: due north (+X), at an elevation equal to the latitude (refraction adds a few arcminutes).
        pole = lens.sky_to_reference(0.0, 89.9999, when, 40.0, -100.0, 300.0)[0]
        self.assertGreater(pole[0], 0.0)
        self.assertAlmostEqual(np.degrees(np.arcsin(pole[2])), 40.0, delta=0.5)
        self.assertAlmostEqual(pole[1], 0.0, delta=0.01)


# MARK: End to end through the file formats


def matrix_quaternion(m):
    """x, y, z, w of a rotation matrix."""
    t = np.trace(m)
    if t > 0:
        s = np.sqrt(t + 1) * 2
        return np.array([(m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, s / 4])
    i = int(np.argmax(np.diag(m)))
    j, k = (i + 1) % 3, (i + 2) % 3
    s = np.sqrt(1 + m[i, i] - m[j, j] - m[k, k]) * 2
    q = np.zeros(4)
    q[i] = s / 4
    q[j] = (m[j, i] + m[i, j]) / s
    q[k] = (m[k, i] + m[i, k]) / s
    q[3] = (m[k, j] - m[j, k]) / s
    return q


def write_session(folder: Path, attitudes: list[np.ndarray], inverse: bool = False):
    (folder / "frames").mkdir(parents=True)
    started = datetime(2026, 1, 15, 5, 0, 0, tzinfo=timezone.utc)
    rows, frames = [], []
    for i, r in enumerate(attitudes):
        t = 5001.0 + 10 * i
        q = matrix_quaternion(r.T if inverse else r)
        for dt in (-0.05, 0.05):
            rows.append([t + dt, *q])
        frames.append({"seq": i, "t": t, "size": list(SIZE), "exposure": 0.01, "K": list(K)})
    np.array(rows, dtype="<f8").tofile(folder / "motion.f64")
    (folder / "frames.jsonl").write_text("\n".join(json.dumps(f) for f in frames) + "\n")
    (folder / "meta.json").write_text(json.dumps({
        "motionColumns": ["t", "qx", "qy", "qz", "qw"], "captureTimeReference": 0.5,
        "attitudeQuaternionIs": "referenceFromDevice" if inverse else "deviceFromReference",
        "observer": {"latitude": 40.0, "longitude": -100.0, "altitude": 300.0},
        "startedWallClock": "2026-01-15T05:00:00.000Z", "startedHostTime": 5000.0}))
    return frames


class EndToEndTests(unittest.TestCase):
    def test_corr_files_with_flipped_y(self):
        from astropy.coordinates import AltAz, EarthLocation, SkyCoord
        from astropy.io import fits
        from astropy.time import Time
        import astropy.units as u

        rng = np.random.default_rng(8)
        truth = np.zeros(9)
        truth[0], truth[1] = 0.003, 0.003
        truth[6:9] = np.radians([-0.3, 0.25, 0.15])
        truth_yaw = np.radians(-9.0)
        obs = synthesize(rng, truth, truth_yaw, frames=7, per_frame=30, noise=0.25)
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d) / "session"
            frames = write_session(folder, [o.device_from_reference for o in obs])
            location = EarthLocation(lat=40 * u.deg, lon=-100 * u.deg, height=300 * u.m)
            for o, frame in zip(obs, frames):
                when = datetime.fromtimestamp(datetime(2026, 1, 15, 5, tzinfo=timezone.utc).timestamp() + frame["t"] + 0.005 - 5000.0,
                                              tz=timezone.utc)
                north, west, up = o.directions.T
                altaz = AltAz(az=np.arctan2(-west, north) * u.rad, alt=np.arcsin(up) * u.rad, obstime=Time(when), location=location,
                              pressure=1013.25 * u.hPa, temperature=10 * u.deg_C, relative_humidity=0.5, obswl=0.55 * u.micron)
                icrs = SkyCoord(altaz).icrs
                fx = lens.corner_to_fits(o.pixels, SIZE[1], flip=True)
                columns = [fits.Column(name=n, format="D", array=a) for n, a in
                           [("field_x", fx[:, 0]), ("field_y", fx[:, 1]), ("index_ra", icrs.ra.deg), ("index_dec", icrs.dec.deg)]]
                fits.HDUList([fits.PrimaryHDU(), fits.BinTableHDU.from_columns(columns)]).writeto(folder / "frames" / f"f{frame['seq']:06d}.corr")
            values, yaws, info = lens.calibrate([folder], None, "auto", ["focalX", "focalY", "boresightX", "boresightY", "boresightZ"])
        self.assertTrue(info["flipY"], info)
        self.assertLess(info["rmsPixels"], 0.8, info)
        self.assertAlmostEqual(np.degrees(yaws[0]), -9.0, delta=0.05)
        np.testing.assert_allclose(np.degrees(values[6:9]), np.degrees(truth[6:9]), atol=0.04)

    def test_starfix_attitudes_give_boresight_and_yaw(self):
        rng = np.random.default_rng(4)
        boresight = np.radians([0.3, -0.2, 0.25])
        truth_yaw = np.radians(14.0)
        attitudes = [attitude(rng.uniform(0, 6.28), np.radians(rng.uniform(25, 70)), np.radians(rng.uniform(-30, 30))) for _ in range(6)]
        with tempfile.TemporaryDirectory() as d:
            for inverse in (False, True):
                folder = Path(d) / f"session{inverse}"
                frames = write_session(folder, attitudes, inverse=inverse)
                b_device = lens.DEVICE_TO_CAMERA.T @ lens.rotation_vector_matrix(boresight) @ lens.DEVICE_TO_CAMERA
                fixes = []
                for r, frame in zip(attitudes, frames):
                    a_fix = b_device @ r @ lens.rz(truth_yaw)  # what an attitude-only solver reports for the real camera
                    fixes.append({"seq": frame["seq"], "hostTime": frame["t"], "deviceFromReference": list(matrix_quaternion(a_fix))})
                solutions = folder / "solutions.json"
                solutions.write_text(json.dumps(fixes))
                values, yaws, info = lens.calibrate([folder], solutions, "auto")
                np.testing.assert_allclose(values[6:9], boresight, atol=np.radians(0.01))
                self.assertAlmostEqual(np.degrees(yaws[0]), 14.0, delta=0.02)
                np.testing.assert_allclose(values[:6], 0, atol=1e-9)  # attitude-only input cannot move the intrinsics


if __name__ == "__main__":
    unittest.main()
