"""Synthetic checks for crosscheck.py:  .venv/bin/python -m unittest tools/astrometry/test_crosscheck.py"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import crosscheck  # noqa: E402
from calibrate_lens import DEVICE_TO_CAMERA, grid_pixels, rotation_vector_matrix  # noqa: E402

K = (1500.0, 1500.0, 960.0, 540.0)
SIZE = (1920, 1080)


def quaternion(matrix: np.ndarray) -> np.ndarray:
    """[x, y, z, w] of a rotation matrix."""
    m = matrix
    w = np.sqrt(max(0.0, 1 + np.trace(m))) / 2
    return np.array([(m[2, 1] - m[1, 2]) / (4 * w), (m[0, 2] - m[2, 0]) / (4 * w), (m[1, 0] - m[0, 1]) / (4 * w), w])


def directions_seen_by(camera_from_reference: np.ndarray, pixels: np.ndarray) -> np.ndarray:
    fx, fy, cx, cy = K
    rays = np.stack([(pixels[:, 0] - cx) / fx, (pixels[:, 1] - cy) / fy, np.ones(len(pixels))], axis=1)
    rays /= np.linalg.norm(rays, axis=1, keepdims=True)
    return (camera_from_reference.T @ rays.T).T


class CompareTests(unittest.TestCase):
    truth_device = rotation_vector_matrix(np.radians([40.0, -10.0, 25.0]))

    def test_identical_rotations_agree(self):
        ours = crosscheck.camera_from_reference(self.truth_device)
        result = crosscheck.compare(ours, ours)
        self.assertAlmostEqual(result["total"], 0.0, places=6)
        self.assertAlmostEqual(result["pointing"], 0.0, places=6)
        self.assertAlmostEqual(result["roll"], 0.0, places=6)

    def test_pure_roll_is_reported_as_roll_only(self):
        ours = crosscheck.camera_from_reference(self.truth_device)
        rolled = rotation_vector_matrix([0, 0, np.radians(1.5)]) @ ours
        result = crosscheck.compare(ours, rolled)
        self.assertAlmostEqual(result["roll"], 1.5, places=6)
        self.assertAlmostEqual(result["pointing"], 0.0, places=5)
        self.assertAlmostEqual(result["total"], 1.5, places=6)

    def test_pointing_offset_is_reported_as_pointing_only(self):
        ours = crosscheck.camera_from_reference(self.truth_device)
        tilted = rotation_vector_matrix([np.radians(0.7), 0, 0]) @ ours
        result = crosscheck.compare(ours, tilted)
        self.assertAlmostEqual(result["pointing"], 0.7, places=6)
        self.assertAlmostEqual(result["roll"], 0.0, places=5)
        self.assertAlmostEqual(result["total"], 0.7, places=6)

    def test_wcs_grid_recovers_the_camera_rotation(self):
        truth = crosscheck.camera_from_reference(self.truth_device)
        pixels = grid_pixels(*SIZE)
        theirs = crosscheck.camera_from_pixels(K, pixels, directions_seen_by(truth, pixels))
        self.assertLess(crosscheck.compare(truth, theirs)["total"], 1e-9)

    def test_app_fix_against_synthetic_astrometry(self):
        """A device quaternion that is 0.3° (yaw) off the truth shows up as 0.3° total, mostly pointing."""
        truth = crosscheck.camera_from_reference(self.truth_device)
        pixels = grid_pixels(*SIZE)
        theirs = crosscheck.camera_from_pixels(K, pixels, directions_seen_by(truth, pixels))
        wrong_device = self.truth_device @ rotation_vector_matrix([0, 0, np.radians(0.3)])
        ours = crosscheck.camera_from_reference(crosscheck.quaternion_matrix(quaternion(wrong_device)))
        result = crosscheck.compare(ours, theirs)
        self.assertAlmostEqual(result["total"], 0.3, places=6)
        self.assertGreater(result["pointing"], 0.1)

    def test_boresight_is_applied_in_the_camera_frame(self):
        boresight = np.radians([0.2, -0.1, 0.05])
        plain = crosscheck.camera_from_reference(self.truth_device)
        corrected = crosscheck.camera_from_reference(self.truth_device, boresight)
        np.testing.assert_allclose(corrected, rotation_vector_matrix(boresight) @ plain, atol=1e-12)
        self.assertTrue(np.allclose(DEVICE_TO_CAMERA @ DEVICE_TO_CAMERA.T, np.eye(3)))

    def test_summary_rms(self):
        rows = [{"app": {"total": 3.0, "pointing": 3.0}, "motion": {"total": 0.0, "pointing": 0.0}},
                {"app": {"total": 4.0, "pointing": 4.0}, "motion": {"total": 0.0, "pointing": 0.0}}]
        s = crosscheck.summary(rows)
        self.assertEqual(s["frames"], 2)
        self.assertAlmostEqual(s["appRmsTotalDegrees"], np.sqrt(12.5))
        self.assertAlmostEqual(s["motionRmsTotalDegrees"], 0.0)
        self.assertTrue(np.isnan(crosscheck.rms([])))


if __name__ == "__main__":
    unittest.main()
