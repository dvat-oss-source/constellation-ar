#!/usr/bin/env python3
"""Lens and camera-angle calibration from plate-solved star photos.

    .venv/bin/python tools/calibrate_lens.py SESSION [SESSION ...] [--solutions PATH] [--out Data/calibration.json]

Solves, by Levenberg–Marquardt least squares on pixel residuals, for
  - focal-length scale (fx, fy), principal-point shift, and the radial distortion Apple's buffers still have (k1, k2),
  - the camera's fixed boresight misalignment to the device (a rotation vector in the camera frame),
  - one heading (yaw) offset of Core Motion per session.
The model per star is  pixel = K'(distort(B · D · R_device←reference(t) · Rz(yaw) · s)), the chain the app draws with.

Plate solutions are pluggable. For each stored full-resolution frame f<seq> the tool looks in the session's frames/
folder (or --solutions) for, in this order:
  f<seq>.corr   astrometry.net matched stars (FIELD_X/Y, INDEX_RA/DEC): the best input, it constrains intrinsics too
  f<seq>.wcs    astrometry.net WCS: sampled on a pixel grid
  a StarFix-like JSON (--solutions file.json or session/solutions.json), a list or JSON-lines of objects with
  "deviceFromReference": [x, y, z, w] and either "seq" or "hostTime": sampled on a pixel grid with Apple's intrinsics,
  so it constrains only the boresight and yaw.
astrometry.net writes pixel coordinates with the FITS (bottom-left) origin; --flip-y auto tries both and keeps the
one that fits.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from analyze_session import load_session  # noqa: E402

# Device (X right, Y top, Z out of screen) → camera (x right, y down, z forward) of the rear camera; CameraPose.deviceToCamera.
DEVICE_TO_CAMERA = np.array([[0.0, -1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, -1.0]])
PARAMETERS = ["focalX", "focalY", "centreX", "centreY", "k1", "k2", "boresightX", "boresightY", "boresightZ"]


def rotation_vector_matrix(v) -> np.ndarray:
    v = np.asarray(v, dtype=float)
    angle = np.linalg.norm(v)
    if angle < 1e-15:
        return np.eye(3)
    k = v / angle
    kx = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + np.sin(angle) * kx + (1 - np.cos(angle)) * kx @ kx


def quaternion_matrix(q) -> np.ndarray:
    x, y, z, w = np.asarray(q, dtype=float) / np.linalg.norm(q)
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def rz(angle: float) -> np.ndarray:
    """Active rotation about +Z (north toward west)."""
    c, s = np.cos(angle), np.sin(angle)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def slerp_matrix(times: np.ndarray, quats: np.ndarray, when: float) -> np.ndarray:
    i = int(np.clip(np.searchsorted(times, when) - 1, 0, len(times) - 2))
    q0, q1 = quats[i], quats[i + 1]
    span = times[i + 1] - times[i]
    t = 0.0 if span <= 0 else float(np.clip((when - times[i]) / span, 0, 1))
    if np.dot(q0, q1) < 0:
        q1 = -q1
    dot = min(1.0, float(np.dot(q0, q1)))
    theta = np.arccos(dot)
    q = q0 if theta < 1e-8 else (np.sin((1 - t) * theta) * q0 + np.sin(t * theta) * q1) / np.sin(theta)
    return quaternion_matrix(q)


def sky_to_reference(ra_deg, dec_deg, when: datetime, lat: float, lon: float, alt: float) -> np.ndarray:
    """Apparent (aberrated, refracted) directions of ICRS stars in the Core Motion reference frame (X north, Y west, Z up)."""
    import astropy.units as u
    from astropy.coordinates import AltAz, EarthLocation, SkyCoord
    from astropy.time import Time

    location = EarthLocation(lat=lat * u.deg, lon=lon * u.deg, height=alt * u.m)
    frame = AltAz(obstime=Time(when), location=location, pressure=1013.25 * u.hPa, temperature=10 * u.deg_C,
                  relative_humidity=0.5, obswl=0.55 * u.micron)
    horizontal = SkyCoord(ra=np.atleast_1d(ra_deg) * u.deg, dec=np.atleast_1d(dec_deg) * u.deg, frame="icrs").transform_to(frame)
    az, el = horizontal.az.rad, horizontal.alt.rad
    east, north, up = np.sin(az) * np.cos(el), np.cos(az) * np.cos(el), np.sin(el)
    return np.stack([north, -east, up], axis=-1)


@dataclass
class Observation:
    """Stars seen in one frame: buffer pixels (corner origin) and the matching reference-frame directions."""
    session: int
    seq: int
    device_from_reference: np.ndarray
    intrinsics: tuple[float, float, float, float]
    size: tuple[int, int]
    pixels: np.ndarray
    directions: np.ndarray
    source: str = ""


@dataclass
class Model:
    """The calibration parameters plus one yaw per session."""
    values: np.ndarray = field(default_factory=lambda: np.zeros(len(PARAMETERS)))
    yaws: np.ndarray = field(default_factory=lambda: np.zeros(1))


def project(model_values: np.ndarray, yaws: np.ndarray, obs: list[Observation]) -> np.ndarray:
    fx_s, fy_s, cx_s, cy_s, k1, k2, bx, by, bz = model_values
    boresight = rotation_vector_matrix([bx, by, bz])
    out = []
    for o in obs:
        fx, fy, cx, cy = o.intrinsics
        w, h = o.size
        c = (boresight @ DEVICE_TO_CAMERA @ o.device_from_reference @ rz(yaws[o.session]) @ o.directions.T).T
        n = c[:, :2] / c[:, 2:3]
        r2 = np.sum(n * n, axis=1, keepdims=True)
        n = n * (1 + r2 * (k1 + k2 * r2))
        out.append(np.stack([fx * (1 + fx_s) * n[:, 0] + cx + cx_s * w, fy * (1 + fy_s) * n[:, 1] + cy + cy_s * h], axis=1))
    return np.concatenate(out)


def circular_mean(angles: np.ndarray) -> float:
    return float(np.arctan2(np.mean(np.sin(angles)), np.mean(np.cos(angles))))


def kabsch(source: np.ndarray, target: np.ndarray) -> np.ndarray:
    u, _, vt = np.linalg.svd(target.T @ source)
    d = np.diag([1, 1, np.sign(np.linalg.det(u @ vt))])
    return u @ d @ vt


def initial_yaws(obs: list[Observation], sessions: int) -> np.ndarray:
    """Heading offsets from the nominal camera: each frame's solved attitude against Core Motion's, twist about +Z."""
    yaws = np.zeros(sessions)
    for s in range(sessions):
        samples = []
        for o in obs:
            if o.session != s:
                continue
            fx, fy, cx, cy = o.intrinsics
            rays = np.stack([(o.pixels[:, 0] - cx) / fx, (o.pixels[:, 1] - cy) / fy, np.ones(len(o.pixels))], axis=1)
            rays /= np.linalg.norm(rays, axis=1, keepdims=True)
            q = kabsch(o.directions, rays)  # reference → camera
            c = o.device_from_reference.T @ DEVICE_TO_CAMERA.T @ q  # reference → reference: the heading correction
            samples.append(np.arctan2(c[1, 0] - c[0, 1], c[0, 0] + c[1, 1]))
        if samples:
            yaws[s] = circular_mean(np.array(samples))
    return yaws


def fit(obs: list[Observation], sessions: int, free: list[str], iterations: int = 60, reject: float = 4.0, verbose: bool = False):
    """Levenberg–Marquardt with a finite-difference Jacobian; returns (values, yaws, info)."""
    values = np.zeros(len(PARAMETERS))
    yaws = initial_yaws(obs, sessions)
    index = [PARAMETERS.index(p) for p in free]
    observed = np.concatenate([o.pixels for o in obs])
    keep = np.ones(len(observed), dtype=bool)
    steps = {"focalX": 1e-6, "focalY": 1e-6, "centreX": 1e-6, "centreY": 1e-6, "k1": 1e-6, "k2": 1e-6,
             "boresightX": 1e-7, "boresightY": 1e-7, "boresightZ": 1e-7}

    def pack(v, y):
        return np.concatenate([v[index], y])

    def unpack(p):
        v = values.copy()
        v[index] = p[: len(index)]
        return v, p[len(index):]

    def residual(p):
        v, y = unpack(p)
        return (project(v, y, obs) - observed)

    p = pack(values, yaws)
    names = free + [f"yaw[{s}]" for s in range(sessions)]
    step_sizes = np.array([steps[n] for n in free] + [1e-7] * sessions)
    lam = 1e-3
    for outer in range(3):
        for _ in range(iterations):
            r = residual(p)
            rk = r[keep].ravel()
            cost = float(rk @ rk)
            jac = np.zeros((rk.size, len(p)))
            for j, h in enumerate(step_sizes):
                dp = np.zeros_like(p)
                dp[j] = h
                jac[:, j] = ((residual(p + dp) - r)[keep].ravel()) / h
            jtj = jac.T @ jac
            gradient = jac.T @ rk
            improved = False
            for _ in range(12):
                try:
                    delta = np.linalg.solve(jtj + lam * np.diag(np.diag(jtj) + 1e-12), -gradient)
                except np.linalg.LinAlgError:
                    lam *= 10
                    continue
                trial = residual(p + delta)[keep].ravel()
                if trial @ trial < cost:
                    p = p + delta
                    lam = max(lam / 5, 1e-12)
                    improved = True
                    break
                lam *= 5
            if not improved or np.max(np.abs(delta) / (step_sizes * 1e3 + 1e-12)) < 1e-3 and cost - float(trial @ trial) < 1e-12:
                break
        # Drop gross mismatches (wrong star matches) and refit.
        r = residual(p)
        norms = np.linalg.norm(r, axis=1)
        scale = max(1.4826 * np.median(norms[keep]), 0.2)
        keep = norms < max(reject * scale, 2.0)
        if verbose:
            print(f"pass {outer}: rms {np.sqrt(np.mean(norms[keep] ** 2)):.3f} px, kept {int(keep.sum())}/{len(keep)}", file=sys.stderr)

    r = residual(p)
    rk = r[keep].ravel()
    jac = np.zeros((rk.size, len(p)))
    for j, h in enumerate(step_sizes):
        dp = np.zeros_like(p)
        dp[j] = h
        jac[:, j] = ((residual(p + dp) - r)[keep].ravel()) / h
    dof = max(rk.size - len(p), 1)
    sigma2 = float(rk @ rk) / dof
    covariance = np.linalg.pinv(jac.T @ jac) * sigma2
    singular = np.linalg.svd(jac / np.maximum(np.linalg.norm(jac, axis=0), 1e-12), compute_uv=False)
    v, y = unpack(p)
    info = {
        "rmsPixels": float(np.sqrt(np.mean(np.sum(r[keep] ** 2, axis=1)))),
        "stars": int(keep.sum()) // 1,
        "rejected": int((~keep).sum()),
        "standardError": {n: float(np.sqrt(max(covariance[i, i], 0))) for i, n in enumerate(names)},
        "conditionNumber": float(singular[0] / max(singular[-1], 1e-12)),
        "yawDegrees": [float(np.degrees(a)) for a in y],
    }
    return v, y, info


def lens_json(values: np.ndarray) -> dict:
    return {
        "focalScaleX": 1 + values[0], "focalScaleY": 1 + values[1],
        "principalShiftX": values[2], "principalShiftY": values[3],
        "distortion": {"k1": values[4], "k2": values[5]},
        "boresight": [values[6], values[7], values[8]],
    }


# MARK: Plate-solution loaders


def frame_index(frames: list[dict]) -> dict[int, dict]:
    return {int(f["seq"]): f for f in frames}


def grid_pixels(width: int, height: int, nx: int = 9, ny: int = 5) -> np.ndarray:
    xs = (np.arange(nx) + 0.5) / nx * width
    ys = (np.arange(ny) + 0.5) / ny * height
    return np.array([(x, y) for y in ys for x in xs])


def fits_to_corner(x, y, height: int, flip: bool):
    """FITS pixel coordinates (1-based, centre of the first pixel = 1) to the app's corner-origin buffer pixels."""
    x = np.asarray(x, dtype=float) - 0.5
    y = (height - (np.asarray(y, dtype=float) - 0.5)) if flip else (np.asarray(y, dtype=float) - 0.5)
    return np.stack([x, y], axis=-1)


def corner_to_fits(p: np.ndarray, height: int, flip: bool) -> np.ndarray:
    return np.stack([p[:, 0] + 0.5, (height - p[:, 1]) + 0.5 if flip else p[:, 1] + 0.5], axis=-1)


def load_corr(path: Path, height: int, flip: bool):
    from astropy.io import fits

    with fits.open(path) as hdus:
        table = hdus[1].data
        names = {n.lower(): n for n in table.names}
        x, y = table[names["field_x"]], table[names["field_y"]]
        ra, dec = table[names["index_ra"]], table[names["index_dec"]]
    return fits_to_corner(x, y, height, flip), np.asarray(ra, float), np.asarray(dec, float)


def load_wcs(path: Path, width: int, height: int, flip: bool):
    from astropy.io import fits
    from astropy.wcs import WCS

    wcs = WCS(fits.getheader(path))
    pixels = grid_pixels(width, height)
    fx = corner_to_fits(pixels, height, flip)
    ra, dec = wcs.all_pix2world(fx[:, 0] - 1, fx[:, 1] - 1, 0)
    return pixels, np.asarray(ra, float), np.asarray(dec, float)


def load_starfixes(path: Path) -> list[dict]:
    text = path.read_text().strip()
    if not text:
        return []
    items = json.loads(text) if text[0] == "[" else [json.loads(line) for line in text.splitlines() if line.strip()]
    out = []
    for item in items:
        q = item.get("deviceFromReference", item.get("quaternion"))
        if isinstance(q, dict):
            q = [q["x"], q["y"], q["z"], q["w"]]
        if q is None:
            continue
        out.append({"seq": item.get("seq"), "hostTime": item.get("hostTime"), "quaternion": np.asarray(q, float)})
    return out


def collect(sessions: list[Path], solutions: Path | None, flip: str, timing_offset: float | None, verbose: bool) -> tuple[list[Observation], int]:
    """Builds the observations for one flip hypothesis."""
    obs: list[Observation] = []
    for s, folder in enumerate(sessions):
        meta, cols, frames = load_session(folder)
        quats = np.stack([cols["qx"], cols["qy"], cols["qz"], cols["qw"]], axis=1)
        times = cols["t"]
        reference = float(meta.get("captureTimeReference", 0.5))
        offset = timing_offset if timing_offset is not None else float(((meta.get("calibration") or {}).get("timing") or {}).get("offsetSeconds", 0.0))
        inverse = meta.get("attitudeQuaternionIs", "deviceFromReference") == "referenceFromDevice"
        site = meta.get("observer")
        started = datetime.fromisoformat(meta["startedWallClock"].replace("Z", "+00:00")).astimezone(timezone.utc)
        start_host = float(meta["startedHostTime"])
        index = frame_index(frames)
        fix_file = solutions if solutions and solutions.is_file() else folder / "solutions.json"
        fixes = load_starfixes(fix_file) if fix_file.exists() else []
        search = solutions if solutions and solutions.is_dir() else folder / "frames"

        def attitude(frame: dict) -> np.ndarray:
            capture = frame["t"] + reference * frame.get("exposure", 0.0) + offset
            r = slerp_matrix(times, quats, capture)
            return r.T if inverse else r

        def wall(frame: dict) -> datetime:
            capture = frame["t"] + reference * frame.get("exposure", 0.0)
            return datetime.fromtimestamp(started.timestamp() + capture - start_host, tz=timezone.utc)

        for frame in frames:
            seq = int(frame["seq"])
            if "K" not in frame:
                continue
            width, height = frame["size"]
            name = f"f{seq:06d}"
            for kind in ("corr", "wcs"):
                path = search / f"{name}.{kind}"
                if not path.exists():
                    continue
                flip_choice = flip == "yes"
                if kind == "corr":
                    pixels, ra, dec = load_corr(path, height, flip_choice)
                else:
                    pixels, ra, dec = load_wcs(path, width, height, flip_choice)
                if site is None or len(pixels) < 4:
                    break
                directions = sky_to_reference(ra, dec, wall(frame), site["latitude"], site["longitude"], site["altitude"])
                above = directions[:, 2] > np.sin(np.radians(10))
                obs.append(Observation(s, seq, attitude(frame), tuple(frame["K"]), (width, height), pixels[above], directions[above],
                                       source=kind))
                break
        for fix in fixes:
            frame = index.get(int(fix["seq"])) if fix.get("seq") is not None else None
            if frame is None and fix.get("hostTime") is not None:
                candidates = [f for f in frames if "K" in f]
                frame = min(candidates, key=lambda f: abs(f["t"] + reference * f.get("exposure", 0.0) + offset - fix["hostTime"]), default=None)
            if frame is None or "K" not in frame:
                continue
            width, height = frame["size"]
            fx, fy, cx, cy = frame["K"]
            pixels = grid_pixels(width, height)
            rays = np.stack([(pixels[:, 0] - cx) / fx, (pixels[:, 1] - cy) / fy, np.ones(len(pixels))], axis=1)
            a_fix = quaternion_matrix(fix["quaternion"])
            directions = (a_fix.T @ DEVICE_TO_CAMERA.T @ rays.T).T
            directions /= np.linalg.norm(directions, axis=1, keepdims=True)
            obs.append(Observation(s, int(frame["seq"]), attitude(frame), tuple(frame["K"]), (width, height), pixels, directions, source="starfix"))
    if verbose:
        print(f"{len(obs)} solved frames, {sum(len(o.pixels) for o in obs)} star positions", file=sys.stderr)
    return obs, len(sessions)


def calibrate(sessions: list[Path], solutions: Path | None, flip: str = "auto", free: list[str] | None = None,
              timing_offset: float | None = None, verbose: bool = False):
    free = free or list(PARAMETERS)
    hypotheses = ["yes", "no"] if flip == "auto" else [flip]
    best = None
    for choice in hypotheses:
        obs, n = collect(sessions, solutions, choice, timing_offset, verbose)
        if not obs:
            continue
        usable = free
        if all(o.source == "starfix" for o in obs):  # attitude-only input says nothing about focal length or distortion
            usable = [p for p in free if p.startswith("boresight")]
        values, yaws, info = fit(obs, n, usable, verbose=verbose)
        info["fitted"] = usable
        info["flipY"] = choice == "yes"
        if best is None or info["rmsPixels"] < best[2]["rmsPixels"]:
            best = (values, yaws, info)
        if not any(o.source in ("corr", "wcs") for o in obs):
            break
    if best is None:
        raise SystemExit("no solved frames found: run astrometry.net on frames/f*.png or pass --solutions")
    return best


def merge_into(path: Path, values: np.ndarray, info: dict) -> None:
    current = json.loads(path.read_text()) if path.exists() else {}
    current["lens"] = lens_json(values)
    current["lensFit"] = info
    path.write_text(json.dumps(current, indent=2) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sessions", nargs="+", type=Path)
    parser.add_argument("--solutions", type=Path, default=None, help="directory of .wcs/.corr files, or a StarFix JSON file")
    parser.add_argument("--flip-y", choices=["auto", "yes", "no"], default="auto")
    parser.add_argument("--fit", default=",".join(PARAMETERS), help="comma-separated subset of: " + ", ".join(PARAMETERS))
    parser.add_argument("--timing-offset", type=float, default=None, help="camera-vs-gyro offset in seconds (default: from the recording)")
    parser.add_argument("--out", type=Path, default=None, help="calibration.json to update (default: print only)")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    free = [p for p in args.fit.split(",") if p]
    unknown = set(free) - set(PARAMETERS)
    if unknown:
        parser.error(f"unknown parameters: {sorted(unknown)}")
    values, _, info = calibrate(args.sessions, args.solutions, args.flip_y, free, args.timing_offset, args.verbose)
    print(json.dumps({"lens": lens_json(values), "fit": info}, indent=2))
    degrees = np.degrees(values[6:9])
    print(f"boresight {degrees[0]:+.3f}° {degrees[1]:+.3f}° {degrees[2]:+.3f}°, rms {info['rmsPixels']:.2f} px", file=sys.stderr)
    if info["conditionNumber"] > 1e4:
        print("warning: poorly conditioned; photograph at more varied pointing directions", file=sys.stderr)
    if args.out:
        merge_into(args.out, values, info)
        print(f"updated {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
