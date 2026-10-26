"""Checks session segmentation and timing interpretation without camera hardware."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("inspect_camera_quality", Path(__file__).resolve().parents[1] / "inspect_camera_quality.py")
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


class CameraQualityReportTests(unittest.TestCase):
    def testRevisitingLensDoesNotTurnTheInterveningRunIntoAFrameGap(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            frames = []
            for seq, (device, time) in enumerate([("wide", 0), ("wide", 1 / 60),
                                                 ("tele", 10), ("tele", 10 + 1 / 30),
                                                 ("wide", 20), ("wide", 20 + 1 / 60)]):
                frames.append({"seq": seq, "t": time, "pts": time, "deliveredAt": time + .01,
                               "size": [1920, 1080], "captureStateAtDelivery": {
                                   "deviceID": device, "zoomFactor": 1, "upscaleThreshold": 2,
                                   "formatSize": [1920, 1080]}})
            (folder / "frames.jsonl").write_text("\n".join(json.dumps(f) for f in frames))
            (folder / "renders.jsonl").write_text("\n".join(json.dumps({
                "seq": seq, "frameHostTime": 0, "targetDisplayTime": t, "pixelsPerSensorPixel": 1.5
            }) for seq, t in [(0, .01), (0, .02), (1, .03)]))
            report = quality.inspect(folder, settle_seconds=0)
            self.assertEqual(len(report["segments"]), 3)
            for segment, expected in zip(report["segments"], [60, 30, 60]):
                self.assertAlmostEqual(segment["deliveredFPS"], expected)
                self.assertFalse(segment["digitalUpscaling"])
                self.assertFalse(segment["captureSizeDiffersFromFormat"])
                self.assertIsNone(segment["sampleExposureSeconds"])
            self.assertEqual(report["segments"][0]["renderSubmissions"], 3)
            self.assertEqual(report["segments"][0]["distinctFramesSubmitted"], 2)

    def testLegacySessionsAndSettlingWindowDoNotInventMetadata(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "frames.jsonl").write_text(json.dumps({"seq": 1, "t": 3, "pts": 3, "size": [1280, 720]}))
            short = quality.inspect(folder)
            self.assertIn("error", short["segments"][0])
            legacy = quality.inspect(folder, settle_seconds=0)["segments"][0]
            self.assertIsNone(legacy["digitalUpscaling"])
            self.assertIsNone(legacy["deliveredFPS"])
            self.assertIsNone(legacy["deliveryLatencySeconds"])

    def testBackgroundTimestampGapIsSeparatedFromSteadyCaptureFPS(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            frames = [{"seq": i, "t": t, "pts": t, "size": [1920, 1080],
                       "captureStateAtDelivery": {"maxFrameDuration": 1 / 60}}
                      for i, t in enumerate([0, 1 / 60, 5, 5 + 1 / 60])]
            (folder / "frames.jsonl").write_text("\n".join(json.dumps(f) for f in frames))
            report = quality.inspect(folder, settle_seconds=0)
            self.assertEqual(len(report["segments"]), 2)
            self.assertEqual(len(report["timestampDiscontinuities"]), 1)
            for segment in report["segments"]:
                self.assertAlmostEqual(segment["deliveredFPS"], 60)


if __name__ == "__main__":
    unittest.main()
