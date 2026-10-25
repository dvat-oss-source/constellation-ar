#!/usr/bin/env python3
"""Camera-vs-gyro timing offset and rolling-shutter readout time from a recorded quick pan.

    .venv/bin/python tools/analyze_session.py Sessions/session-YYYYMMDD-HHMMSS [--out Data/calibration.json]

The session must hold downsampled frames (the debug panel's "Small frames every 1" is best) recorded while panning
the phone quickly across a textured scene in good light, ideally with a few direction changes. For each pair of
consecutive stored frames the image shift is measured by phase correlation, globally and in horizontal strips,
and compared with the shift the gyro predicts (shift = focal length × rotation angle between the two exposure
times). The offset tau that best aligns them is the camera-vs-gyro time offset; the strip-to-strip differences of the
shift fix the readout time (rows are exposed one after another). Output: the "timing" section of calibration.json.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

MOTION_COLUMNS = ["t", "qx", "qy", "qz", "qw", "rotX", "rotY", "rotZ"]
STRIPS = 6


def load_session(folder: Path):
    meta = json.loads((folder / "meta.json").read_text())
    columns = meta["motionColumns"]
    raw = np.fromfile(folder / "motion.f64", dtype="<f8")
    motion = raw.reshape(-1, len(columns))
    cols = {name: motion[:, i] for i, name in enumerate(columns)}
    frames = [json.loads(line) for line in (folder / "frames.jsonl").read_text().splitlines() if line.strip()]
    return meta, cols, frames


def read_small(folder: Path, frame: dict) -> np.ndarray | None:
    name = frame.get("small")
    if not name:
        return None
    w, h = frame["smallSize"]
    data = np.fromfile(folder / name, dtype=np.uint8)
    if data.size != w * h:
        return None
    return data.reshape(h, w).astype(np.float64)


def phase_shift(a: np.ndarray, b: np.ndarray, max_shift: float, whitening: float = 0.5) -> tuple[float, float, float] | None:
    """(dx, dy, peak): the content of `a` moved by (dx, dy) pixels to give `b` (b(x) = a(x − d)).

    Cross-power-spectrum correlation with partial whitening (0 = plain cross-correlation, 1 = pure phase correlation),
    refined to about 0.01 px by evaluating the spectrum at fractional shifts (parabola fits on the peak are biased
    toward whole pixels, which would show up as a gain error). `peak` is the share of the spectrum that agrees, 0…1."""
    a = a - a.mean()
    b = b - b.mean()
    if a.std() < 1.0 or b.std() < 1.0:
        return None
    h, w = a.shape
    window = np.hanning(h)[:, None] * np.hanning(w)[None, :]
    cross = np.fft.fft2(b * window) * np.conj(np.fft.fft2(a * window))
    weighted = cross / (np.abs(cross) ** whitening + 1e-9)
    total = float(np.sum(np.abs(weighted)))
    if total <= 0:
        return None
    corr = np.fft.ifft2(weighted).real
    my, mx = int(min(max_shift, h // 2 - 2)), int(min(max_shift, w // 2 - 2))
    padded = np.zeros((2 * my + 1, 2 * mx + 1))
    for iy, dy in enumerate(range(-my, my + 1)):
        for ix, dx in enumerate(range(-mx, mx + 1)):
            padded[iy, ix] = corr[dy % h, dx % w]
    iy, ix = np.unravel_index(np.argmax(padded), padded.shape)
    peak = float(padded[iy, ix] * h * w / total)
    if peak < 0.05 or iy in (0, 2 * my) or ix in (0, 2 * mx):
        return None

    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[:, None]
    dy, dx = float(iy - my), float(ix - mx)
    for span, step in ((1.0, 0.1), (0.1, 0.01)):
        ys = dy + np.arange(-span, span + step / 2, step)
        xs = dx + np.arange(-span, span + step / 2, step)
        ey = np.exp(2j * np.pi * fy * ys[None, :])  # h × n
        ex = np.exp(2j * np.pi * fx * xs[None, :])  # w × n
        values = (ey.T @ weighted @ ex).real
        best = np.unravel_index(np.argmax(values), values.shape)
        dy, dx = float(ys[best[0]]), float(xs[best[1]])
    return dx, dy, peak


class Gyro:
    """Cumulative gyro angle in the device frame, interpolated at any host time."""

    def __init__(self, t: np.ndarray, rate: np.ndarray):
        dt = np.diff(t, prepend=t[0])
        dt[dt > 0.1] = 0.0
        self.t = t
        mid = 0.5 * (rate + np.vstack([rate[:1], rate[:-1]]))  # trapezoid: no half-sample bias in the offset
        self.cum = np.cumsum(mid * dt[:, None], axis=0)

    def angle(self, when: np.ndarray) -> np.ndarray:
        return np.stack([np.interp(when, self.t, self.cum[:, k]) for k in range(3)], axis=-1)


def predicted_shift(gyro: Gyro, focal: np.ndarray, t0: np.ndarray, t1: np.ndarray, gain: float = 1.0) -> np.ndarray:
    """Buffer-pixel shift between exposures at t0 and t1: f·(Δθx, −Δθy) of the device-frame rotation (device → camera
    axes are x↔−y; see CameraPose.deviceToCamera)."""
    d = gyro.angle(t1) - gyro.angle(t0)
    return gain * np.stack([focal * d[:, 0], -focal * d[:, 1]], axis=-1)


def measure_pairs(folder: Path, meta: dict, frames: list[dict], max_gap: float = 0.05):
    """Per stored-frame pair: nominal times, global shift and per-strip shifts in full-resolution buffer pixels."""
    ref = float(meta.get("captureTimeReference", 0.5))
    stored = [f for f in frames if f.get("small")]
    pairs = []
    previous = None
    for frame in stored:
        image = read_small(folder, frame)
        if image is None:
            continue
        nominal = frame["t"] + ref * frame.get("exposure", 0.0)
        record = (frame, image, nominal)
        if previous is not None:
            f0, i0, t0 = previous
            f1, i1, t1 = record
            if 0 < t1 - t0 <= max_gap and f1["seq"] - f0["seq"] <= 3 and i0.shape == i1.shape:
                scale = f0["size"][0] / i0.shape[1]
                rows = i0.shape[0]
                global_shift = phase_shift(i0, i1, 12)
                strips = []
                for k in range(STRIPS):
                    r0, r1 = k * rows // STRIPS, (k + 1) * rows // STRIPS
                    s = phase_shift(i0[r0:r1], i1[r0:r1], 12)
                    strips.append(None if s is None else (s[0] * scale, s[1] * scale, s[2]))
                if global_shift is not None and all(s is not None for s in strips):
                    pairs.append({
                        "t0": t0, "t1": t1,
                        "focal": f0["K"][0] if "K" in f0 else None,
                        "height": f0["size"][1],
                        "shift": np.array([global_shift[0] * scale, global_shift[1] * scale]),
                        "strips": np.array([[s[0], s[1]] for s in strips]),
                        "strip_rows": np.array([((k + 0.5) / STRIPS - 0.5) for k in range(STRIPS)]),
                    })
        previous = record
    return pairs


def fit_offset(gyro: Gyro, pairs: list[dict], search: float = 0.15, step: float = 0.0005):
    t0 = np.array([p["t0"] for p in pairs])
    t1 = np.array([p["t1"] for p in pairs])
    focal = np.array([p["focal"] for p in pairs])
    measured = np.array([p["shift"] for p in pairs])
    taus = np.arange(-search, search + step / 2, step)
    scores = []
    for tau in taus:
        pred = predicted_shift(gyro, focal, t0 + tau, t1 + tau)
        scores.append(float(np.sum(measured * pred) / (np.linalg.norm(measured) * np.linalg.norm(pred) + 1e-12)))
    scores = np.array(scores)
    best = int(np.argmax(scores))
    tau = taus[best]
    if 0 < best < len(taus) - 1:
        a, b, c = scores[best - 1], scores[best], scores[best + 1]
        denom = a - 2 * b + c
        if abs(denom) > 1e-12:
            tau += 0.5 * (a - c) / denom * step
    pred = predicted_shift(gyro, focal, t0 + tau, t1 + tau)
    gain = float(np.sum(measured * pred) / (np.sum(pred * pred) + 1e-12))
    residual = measured - gain * pred
    return tau, gain, float(np.sqrt(np.mean(residual ** 2))), float(scores[best])


def fit_readout(gyro: Gyro, pairs: list[dict], tau: float, gain: float, span: float = 0.08, step: float = 0.0005) -> tuple[float, float]:
    """Readout time T (top row to bottom row, signed) from the strip shifts: strip k's rows are exposed r_k·T later than
    the frame's centre row."""
    t0 = np.array([p["t0"] for p in pairs])
    t1 = np.array([p["t1"] for p in pairs])
    focal = np.array([p["focal"] for p in pairs])
    strips = np.array([p["strips"] for p in pairs])
    rows = pairs[0]["strip_rows"]

    def cost(T: float) -> float:
        total = 0.0
        for k, r in enumerate(rows):
            pred = predicted_shift(gyro, focal, t0 + tau + r * T, t1 + tau + r * T, gain)
            total += float(np.sum((strips[:, k, :] - pred) ** 2))
        return total

    candidates = np.arange(-span, span + step / 2, step)
    costs = np.array([cost(T) for T in candidates])
    best = int(np.argmin(costs))
    T = candidates[best]
    if 0 < best < len(candidates) - 1:
        a, b, c = costs[best - 1], costs[best], costs[best + 1]
        denom = a - 2 * b + c
        if abs(denom) > 1e-18:
            T += 0.5 * (a - c) / denom * step
    # One standard error from the curvature of the cost around the minimum.
    n = strips.size
    sigma2 = costs[best] / max(n - 2, 1)
    curvature = (costs[min(best + 4, len(costs) - 1)] - 2 * costs[best] + costs[max(best - 4, 0)]) / (4 * step) ** 2
    error = float(np.sqrt(2 * sigma2 / curvature)) if curvature > 0 else float("inf")
    return float(T), error


def analyze(folder: Path) -> dict:
    meta, cols, frames = load_session(folder)
    gyro = Gyro(cols["t"], np.stack([cols["rotX"], cols["rotY"], cols["rotZ"]], axis=1))
    pairs = measure_pairs(folder, meta, frames)
    if len(pairs) < 20:
        raise SystemExit(f"only {len(pairs)} usable frame pairs; record a pan with small frames every 1 in a textured, well-lit scene")
    tau, gain, residual, score = fit_offset(gyro, pairs)
    T, T_error = fit_readout(gyro, pairs, tau, gain)
    result = {
        "offsetSeconds": round(tau, 5),
        "readoutSeconds": round(T, 5),
        "diagnostics": {
            "pairs": len(pairs),
            "gain": round(gain, 3),
            "correlation": round(score, 3),
            "residualPixels": round(residual, 3),
            "readoutStandardError": round(T_error, 5) if np.isfinite(T_error) else None,
            "note": "gain should be close to +1; -1 means the gyro axes are flipped; a large readoutStandardError "
                    "means the pan had too little acceleration to see the rolling shutter",
        },
    }
    if abs(gain - 1) > 0.25 or score < 0.5:
        result["diagnostics"]["warning"] = "weak or inconsistent correlation: do not trust this calibration"
    return result


def merge_into(path: Path, result: dict) -> None:
    current = json.loads(path.read_text()) if path.exists() else {}
    current["timing"] = {"offsetSeconds": result["offsetSeconds"], "readoutSeconds": result["readoutSeconds"]}
    current["timingFit"] = result["diagnostics"]
    path.write_text(json.dumps(current, indent=2) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("session", type=Path)
    parser.add_argument("--out", type=Path, default=None, help="calibration.json to update (default: print only)")
    args = parser.parse_args(argv)
    result = analyze(args.session)
    print(json.dumps(result, indent=2))
    if args.out:
        merge_into(args.out, result)
        print(f"updated {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
