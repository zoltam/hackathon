"""Regressions for measured floor mapping in the registered equipment frame."""
import unittest

import numpy as np

from build_boiler_room import observed_floor, clearance_floor


class FloorMappingTests(unittest.TestCase):
    def test_faint_floor_connects_corridor_without_filling_unknown_space(self):
        xyz, logits, grid = [], [], []
        for x in (0, 1, 2):
            xyz.extend([[x * .25 + .125, 0, .125]] * 20)
            logits.extend([-3.5 if x == 1 else 2] * 20)
            grid.extend([(x, 0)] * 20)
        floor, _ = observed_floor(np.array(xyz), np.array(logits), np.array(grid))
        self.assertEqual(floor, {(0, 0), (1, 0), (2, 0)})
        self.assertNotIn((3, 0), floor)

    def test_obstacles_stay_blocked_and_no_extra_margin_is_added(self):
        xyz, logits, grid = [], [], []
        for x in range(5):
            xyz.extend([[x * .25 + .125, 0, .125]] * 20)
            logits.extend([2] * 20)
            grid.extend([(x, 0)] * 20)
        xyz.extend([[.625, .5, .125]] * 60)
        logits.extend([2] * 60)
        grid.extend([(2, 0)] * 60)
        # Overhead geometry does not erase observed floor beneath it.
        xyz.extend([[.875, 2.2, .125]] * 60)
        logits.extend([2] * 60)
        grid.extend([(3, 0)] * 60)
        floor, blocked = observed_floor(np.array(xyz), np.array(logits), np.array(grid))
        self.assertEqual(blocked, {(2, 0)})
        self.assertEqual(floor, {(0, 0), (1, 0), (3, 0), (4, 0)})

    def test_disconnected_floor_retained_and_very_faint_noise_excluded(self):
        xyz = np.array([[.125, 0, .125]] * 20 + [[2.125, 0, .125]] * 20 +
                       [[3.125, 0, .125]] * 20)
        grid = np.array([(0, 0)] * 20 + [(8, 0)] * 20 + [(12, 0)] * 20)
        logits = np.array([2] * 40 + [-8] * 20)
        floor, _ = observed_floor(xyz, logits, grid)
        self.assertEqual(floor, {(0, 0), (8, 0)})

    def test_sparse_floor_requires_direct_and_neighbourhood_evidence(self):
        cells = [(0, 0)] * 12 + [(1, 0)] * 2 + [(2, 0)] + [(9, 9)] * 2
        xyz = np.array([[x * .1 + .05, 0, z * .1 + .05] for x, z in cells])
        floor, _ = observed_floor(xyz, np.full(len(cells), 2), np.array(cells))
        self.assertEqual(floor, {(0, 0), (1, 0)})

    def test_camera_passes_below_overhead_pipe_but_not_low_obstacle(self):
        xyz = np.array([[.05, 0, .05]] * 3 + [[.15, 0, .05]] * 3 +
                       [[.05, 1.77, .05]] * 40 + [[.15, .3, .05]] * 4)
        grid = np.array([(0, 0)] * 3 + [(1, 0)] * 3 + [(0, 0)] * 40 + [(1, 0)] * 4)
        floor, blocked = observed_floor(xyz, np.full(len(xyz), 2), grid)
        self.assertEqual(floor, {(0, 0)})
        self.assertEqual(blocked, {(1, 0)})

    def test_radius_excludes_unknown_holes_and_narrow_connections(self):
        floor = {(x, z) for x in range(7) for z in range(7)}
        floor.remove((3, 3))
        safe = clearance_floor(floor, .1, .1)
        self.assertIn((1, 1), safe)
        self.assertNotIn((2, 2), safe)
        self.assertNotIn((0, 1), safe)
        self.assertNotIn((3, 3), safe)

    def test_gaussian_floor_footprints_recover_only_bounded_supported_surface(self):
        xyz = np.array([[.095, 0, .15]] * 14 + [[.35, 2.2, .35]])
        grid = np.floor(xyz[:, [0, 2]] / .1).astype(int)
        covariance = np.tile(np.diag([.01, .0001, .000025]), (len(xyz), 1, 1))
        floor, _ = observed_floor(xyz, np.full(len(xyz), 2), grid, covariance)
        self.assertIn((1, 1), floor)  # Measured ellipse reaches the neighbouring centre.
        self.assertNotIn((2, 1), floor)  # Even a wide ellipse cannot extend beyond 12 cm.
        self.assertNotIn((1, 2), floor)  # Preserve anisotropic footprint shape.

        sparse = np.array([0, 1, 14])
        floor, _ = observed_floor(xyz[sparse], np.full(3, 2), grid[sparse], covariance[sparse])
        self.assertNotIn((1, 1), floor)  # Two isolated splats lack nearby floor evidence.

    def test_gaussian_floor_footprints_do_not_override_physical_obstacles(self):
        xyz = np.array([[.095, 0, .15]] * 14 + [[.15, .3, .15]] * 4)
        grid = np.floor(xyz[:, [0, 2]] / .1).astype(int)
        covariance = np.tile(np.diag([.01, .0001, .000025]), (len(xyz), 1, 1))
        floor, blocked = observed_floor(xyz, np.full(len(xyz), 2), grid, covariance)
        self.assertIn((1, 1), blocked)
        self.assertNotIn((1, 1), floor)


if __name__ == '__main__':
    unittest.main()
