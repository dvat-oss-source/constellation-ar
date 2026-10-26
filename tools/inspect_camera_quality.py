#!/usr/bin/env python3
"""Summarize pre-render capture and CPU render timing from one or more recorded sessions.

No image-quality score is inferred from unrelated scenes. Compare the saved full-size color PNGs
at native scale and with the recorded aspect-fill mapping; see docs/camera-quality.md.
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
from pathlib import Path


def rows(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def distribution(values):
    values = sorted(v for v in values if isinstance(v, (int, float)) and math.isfinite(v))
    if not values:
        return None
    return {"median": statistics.median(values), "p95": values[math.ceil(.95 * len(values)) - 1],
            "min": values[0], "max": values[-1]}


def identity(frame):
    state = frame.get("captureStateAtDelivery", {})
    return (state.get("deviceID"), state.get("deviceType"), state.get("zoomFactor"),
            tuple(state.get("formatSize", [])), tuple(frame.get("size", [])), state.get("exposureMode"),
            state.get("minFrameDuration"), state.get("maxFrameDuration"))


def inspect(folder, settle_seconds=2):
    frames = rows(folder / "frames.jsonl")
    renders = rows(folder / "renders.jsonl")
    drops = rows(folder / "drops.jsonl")
    segments = []
    gaps = []
    for frame in frames:
        discontinuity = False
        if segments:
            previous = segments[-1][-1]
            max_duration = previous.get("captureStateAtDelivery", {}).get("maxFrameDuration", 0)
            discontinuity = frame["t"] - previous["t"] > max(.5, 2.5 * max_duration)
            if discontinuity:
                gaps.append({"afterSequence": previous["seq"], "beforeSequence": frame["seq"],
                             "seconds": frame["t"] - previous["t"]})
        if not segments or discontinuity or identity(segments[-1][-1]) != identity(frame):
            segments.append([])
        segments[-1].append(frame)
    summaries = []
    for segment in segments:
        selected = [f for f in segment if f["t"] >= segment[0]["t"] + settle_seconds]
        if not selected:
            summaries.append({"identity": identity(segment[0]), "error": "segment shorter than settling window"})
            continue
        state = selected[-1].get("captureStateAtDelivery", {})
        times = [f["t"] for f in selected]
        periods = [b - a for a, b in zip(times, times[1:])]
        seqs = {f["seq"] for f in selected}
        drawn = [r for r in renders if r.get("seq") in seqs]
        target_times = [r["targetDisplayTime"] for r in drawn]
        fovs = [math.degrees(2 * math.atan(f["size"][0] / (2 * f["K"][0]))) for f in selected if f.get("K")]
        summary = {
            "identity": identity(selected[0]), "frames": len(selected), "settlingSecondsExcluded": settle_seconds,
            "captureStateAtDelivery": state,
            "deliveredFPS": (len(times) - 1) / (times[-1] - times[0]) if times[-1] > times[0] else None,
            "framePeriodSeconds": distribution(periods),
            "nonIncreasingTimestamps": sum(p <= 0 for p in periods),
            "deliveryLatencySeconds": distribution([f["deliveredAt"] - f["t"] for f in selected if "deliveredAt" in f]),
            "hostMinusPTSSeconds": distribution([f["t"] - f["pts"] for f in selected]),
            "sampleExposureSeconds": distribution([f.get("exposure") for f in selected]),
            "sampleISO": distribution([f.get("iso") for f in selected]),
            "measuredLongAxisFOVDegrees": distribution(fovs),
            "adjustingFocusFrames": sum(f.get("captureStateAtDelivery", {}).get("adjustingFocus", False) for f in selected),
            "fullColorFrames": [f["colorPNG"] for f in selected if "colorPNG" in f],
            "captureSizeDiffersFromFormat": list(selected[0]["size"]) != state.get("formatSize") if state else None,
            "digitalUpscaling": state["zoomFactor"] > state["upscaleThreshold"] if "upscaleThreshold" in state else None,
            "renderSubmissions": len(drawn), "distinctFramesSubmitted": len({r["seq"] for r in drawn}),
            "targetDisplayPeriodSeconds": distribution([b - a for a, b in zip(target_times, target_times[1:])]),
            "captureToTargetDisplaySeconds": distribution([r["targetDisplayTime"] - r["frameHostTime"] for r in drawn]),
            "pixelsPerSensorPixel": distribution([r.get("pixelsPerSensorPixel") for r in drawn]),
            "warpedSubmissions": sum(r.get("warping", False) for r in drawn),
        }
        summaries.append(summary)
    return {"session": str(folder), "timestampDiscontinuities": gaps, "droppedCallbacks": len(drops), "dropReasons": sorted({r.get("reason", "unknown") for r in drops}),
            "segments": summaries,
            "limits": "Delivery is after Apple's ISP, not sensor RAW. Render times are CPU/target times, not GPU/panel measurements. Recording adds overhead."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sessions", type=Path, nargs="+")
    parser.add_argument("--settle-seconds", type=float, default=2)
    args = parser.parse_args()
    if args.settle_seconds < 0:
        parser.error("--settle-seconds must be nonnegative")
    print(json.dumps([inspect(folder, args.settle_seconds) for folder in args.sessions], indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
