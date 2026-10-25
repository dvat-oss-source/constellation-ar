#!/usr/bin/env python3
"""Cross-check the in-app plate solver (and Core Motion) against astrometry.net on a recorded session.

    .venv/bin/python tools/astrometry/crosscheck.py SESSION [SESSION ...] [--astrometry] [--solutions DIR] [--flip-y auto|yes|no]

For every full-resolution frame (frames/f<seq>.png) that astrometry.net solved (.wcs next to it, or in --solutions) and
the app solved too (platesolves.jsonl, outcome "fix"), the camera←reference rotation from each is compared:
  pointing   angle between the two optical axes,
  roll       twist about the optical axis,
  total      angle of the full rotation difference.
The Core Motion attitude at the frame's capture time (with the recorded lens boresight) is compared the same way, so
the gyro/compass error is visible beside the solver's. Prints per-frame lines and the RMS; --astrometry first runs
tools/astrometry/solve.sh on frames that have no .wcs yet.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from analyze_session import load_session  # noqa: E402
from calibrate_lens import (DEVICE_TO_CAMERA, kabsch, load_wcs, quaternion_matrix, rotation_vector_matrix,  # noqa: E402
                            sky_to_reference, slerp_matrix, solve_with_astrometry)


def camera_from_reference(device_from_reference: np.ndarray, boresight: np.ndarray | None = None) -> np.ndarray:
    c = DEVICE_TO_CAMERA @ device_from_reference
    return rotation_vector_matrix(boresight) @ c if boresight is not None else c


def camera_from_pixels(intrinsics, pixels: np.ndarray, directions: np.ndarray) -> np.ndarray:
    """camera←reference rotation that best maps reference directions onto the rays through the given buffer pixels."""
    fx, fy, cx, cy = intrinsics
    rays = np.stack([(pixels[:, 0] - cx) / fx, (pixels[:, 1] - cy) / fy, np.ones(len(pixels))], axis=1)
    rays /= np.linalg.norm(rays, axis=1, keepdims=True)
    return kabsch(directions, rays)


def compare(ours: np.ndarray, theirs: np.ndarray) -> dict[str, float]:
    """Degrees of disagreement between two camera←reference rotations: optical-axis separation, roll about it, total."""
    pointing = np.degrees(np.arccos(np.clip(ours[2] @ theirs[2], -1, 1)))
    delta = theirs @ ours.T
    roll = np.degrees(np.arctan2(delta[1, 0] - delta[0, 1], delta[0, 0] + delta[1, 1]))
    total = np.degrees(np.arccos(np.clip((np.trace(delta) - 1) / 2, -1, 1)))
    return {"pointing": float(pointing), "roll": float(roll), "total": float(total)}


def rms(values: list[float]) -> float:
    return float(np.sqrt(np.mean(np.square(values)))) if values else float("nan")


def load_platesolves(folder: Path) -> dict[int, dict]:
    path = folder / "platesolves.jsonl"
    if not path.exists():
        return {}
    fixes = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        if item.get("outcome") == "fix" and "quaternion" in item:
            fixes[int(item["seq"])] = item
    return fixes


def crosscheck_session(folder: Path, solutions: Path | None, flip: str, verbose: bool) -> list[dict]:
    meta, cols, frames = load_session(folder)
    site = meta.get("observer")
    if site is None:
        print(f"{folder.name}: no observer location in meta.json", file=sys.stderr)
        return []
    quats = np.stack([cols["qx"], cols["qy"], cols["qz"], cols["qw"]], axis=1)
    times = cols["t"]
    reference = float(meta.get("captureTimeReference", 0.5))
    calibration = meta.get("calibration") or {}
    offset = float((calibration.get("timing") or {}).get("offsetSeconds", 0.0))
    boresight = np.asarray(calibration["lens"]["boresight"], float) if calibration.get("lens") else None
    inverse = meta.get("attitudeQuaternionIs", "deviceFromReference") == "referenceFromDevice"
    started = datetime.fromisoformat(meta["startedWallClock"].replace("Z", "+00:00")).astimezone(timezone.utc)
    start_host = float(meta["startedHostTime"])
    fixes = load_platesolves(folder)
    search = solutions or folder / "frames"
    rows = []
    for frame in frames:
        if not frame.get("png") or "K" not in frame:
            continue
        seq = int(frame["seq"])
        wcs = search / f"f{seq:06d}.wcs"
        fix = fixes.get(seq)
        if not wcs.exists() or fix is None:
            continue
        width, height = frame["size"]
        capture = frame["t"] + reference * frame.get("exposure", 0.0)
        when = datetime.fromtimestamp(started.timestamp() + capture - start_host, tz=timezone.utc)
        app = camera_from_reference(quaternion_matrix(fix["quaternion"]))
        motion_matrix = slerp_matrix(times, quats, capture + offset)
        motion = camera_from_reference(motion_matrix.T if inverse else motion_matrix, boresight)
        best = None
        for choice in (["yes", "no"] if flip == "auto" else [flip]):
            pixels, ra, dec = load_wcs(wcs, width, height, choice == "yes")
            directions = sky_to_reference(ra, dec, when, site["latitude"], site["longitude"], site["altitude"])
            theirs = camera_from_pixels(frame["K"], pixels, directions)
            result = compare(app, theirs)
            if best is None or result["total"] < best[0]["total"]:
                best = (result, compare(motion, theirs), choice)
        row = {"seq": seq, "stars": fix.get("starCount"), "sigma": fix.get("sigmaDegrees"), "flipY": best[2],
               "app": best[0], "motion": best[1]}
        rows.append(row)
        if verbose:
            print(format_row(row))
    return rows


def format_row(row: dict) -> str:
    a, m = row["app"], row["motion"]
    return (f"f{row['seq']:06d}  app solve: pointing {a['pointing']:.3f}° roll {a['roll']:+.3f}° total {a['total']:.3f}°"
            f" ({row['stars']} stars, σ {row['sigma']:.3f}°)   motion: pointing {m['pointing']:.2f}° roll {m['roll']:+.2f}°"
            f" total {m['total']:.2f}°")


def summary(rows: list[dict]) -> dict:
    return {
        "frames": len(rows),
        "appRmsTotalDegrees": rms([r["app"]["total"] for r in rows]),
        "appRmsPointingDegrees": rms([r["app"]["pointing"] for r in rows]),
        "motionRmsTotalDegrees": rms([r["motion"]["total"] for r in rows]),
        "motionRmsPointingDegrees": rms([r["motion"]["pointing"] for r in rows]),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sessions", nargs="+", type=Path)
    parser.add_argument("--astrometry", action="store_true", help="run the local astrometry.net on unsolved frames/f*.png first")
    parser.add_argument("--solutions", type=Path, default=None, help="directory of .wcs files (default: the session's frames/)")
    parser.add_argument("--flip-y", choices=["auto", "yes", "no"], default="auto")
    parser.add_argument("--json", action="store_true", help="print the per-frame rows and summary as JSON")
    args = parser.parse_args(argv)
    rows = []
    for folder in args.sessions:
        if args.astrometry:
            results = solve_with_astrometry(folder, load_session(folder)[2], verbose=True)
            print(f"{folder.name}: astrometry.net solved {sum(r != 'FAILED' for r in results.values())}/{len(results)} full frames",
                  file=sys.stderr)
        rows += crosscheck_session(folder, args.solutions, args.flip_y, verbose=not args.json)
    if not rows:
        print("no frame was solved by both astrometry.net and the app (needs full frames + night auto-alignment while recording)",
              file=sys.stderr)
        return 1
    s = summary(rows)
    if args.json:
        print(json.dumps({"frames": rows, "summary": s}, indent=2))
    else:
        print(f"{s['frames']} frames: app solve RMS total {s['appRmsTotalDegrees']:.3f}° (pointing {s['appRmsPointingDegrees']:.3f}°),"
              f" motion RMS total {s['motionRmsTotalDegrees']:.2f}° (pointing {s['motionRmsPointingDegrees']:.2f}°)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
