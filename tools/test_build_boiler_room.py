"""Regressions for measured floor mapping in the registered equipment frame."""
import unittest

import numpy as np

from build_boiler_room import observed_floor


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


if __name__ == '__main__':
    unittest.main()
