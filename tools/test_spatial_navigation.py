"""Playback, collision and real-scene contract tests for the spatial viewer."""
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

from spatial_navigation import Journey, plan_route, prepare_person_site, verify_swept_route


ROOT = Path(__file__).resolve().parents[1]


class PlaybackTest(unittest.TestCase):
    def test_frame_independence_pause_and_arrival(self):
        a = Journey([[0, 0], [1, 0], [1, 1]], .1)
        b = Journey(a.route, .1)
        a.play()
        b.play()
        a.advance(.2)
        for _ in range(20):
            b.advance(.01)
        np.testing.assert_allclose(a.position, b.position)
        a.pause()
        saved = a.position
        a.advance(50)
        self.assertEqual(a.position, saved)
        a.play()
        a.advance(50)
        self.assertEqual(a.status, 'arrived')
        np.testing.assert_allclose(a.position, [.15, 0, .15])
        a.reset()
        self.assertEqual(a.status, 'ready')
        self.assertEqual(Journey([], .1).status, 'unreachable')
        self.assertEqual(Journey([[0, 0]], .1).status, 'arrived')
        with self.assertRaises(ValueError):
            a.advance(float('nan'))
        with self.assertRaises(ValueError):
            Journey([[0, 0], [1, 1]], .1)

    def test_swept_body_rejects_collision_and_diagonal(self):
        floor = {(x, z) for x in range(10) for z in range(10)}
        verify_swept_route([[4, 4], [5, 4]], floor, .1, .3)
        floor.remove((4, 6))
        with self.assertRaisesRegex(ValueError, 'intersects'):
            verify_swept_route([[4, 4], [5, 4]], floor, .1, .3)
        with self.assertRaisesRegex(ValueError, 'non-cardinal'):
            verify_swept_route([[4, 4], [5, 5]], floor, .1, .3)


class PlannerAdapterTest(unittest.TestCase):
    def test_ready_arrived_blocked_disconnected_and_unknown(self):
        site = {'name': 'fixture', 'width': 20, 'depth': 10, 'cellSize': .1,
                'start': [3, 3],
                'floor': [[x, z] for x in range(20) for z in range(10) if x < 9 or x >= 12],
                'objects': [{'objectId': 'target', 'name': 'Fixture target',
                             'x': 16, 'z': 3, 'width': 1, 'depth': 1,
                             'height': 1, 'cells': [], 'service': [16, 3]}]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'site.json'
            path.write_text(json.dumps(site))
            ready = plan_route(path, [15, 3], 'target')
            self.assertEqual(ready['status'], 'ready')
            self.assertEqual(ready['distanceMetres'], .1)
            self.assertEqual(plan_route(path, [16, 3], 'target')['status'], 'arrived')
            self.assertEqual(plan_route(path, [10, 3], 'target')['status'], 'blocked_start')
            self.assertEqual(plan_route(path, [3, 3], 'target')['status'], 'unreachable')
            self.assertEqual(plan_route(path, [3, 3], 'missing')['status'], 'invalid_request')
            self.assertEqual(plan_route(path, [3.5, 3], 'target')['status'], 'invalid_request')
            site['floor'].remove([16, 3])
            path.write_text(json.dumps(site))
            self.assertEqual(plan_route(path, [15, 3], 'target')['status'], 'blocked_start')
            self.assertEqual(plan_route(path, [3, 3], 'target')['status'], 'blocked_target')


class ActualPersonSceneTest(unittest.TestCase):
    def test_all_six_targets_have_person_routes_without_floor_filling(self):
        packed = ROOT / 'assets/valmet/boiler-room-sh.splats'
        if not packed.exists():
            self.skipTest('Private generated Gaussian scan is unavailable')
        raw = np.memmap(packed, dtype='u1', mode='r')
        fields = np.ndarray((len(raw) // 160, 16), dtype='<f4', buffer=raw, strides=(160, 4))
        geometry = {'centers': fields[:, :3], 'opacities': fields[:, 3]}
        legacy = json.loads((ROOT / 'assets/valmet/site.json').read_text())
        before = json.dumps(legacy, sort_keys=True)
        person = prepare_person_site(legacy, geometry)
        self.assertEqual(json.dumps(legacy, sort_keys=True), before)
        self.assertEqual(person['start'], [58, 67])
        self.assertEqual(person['navigationProfile']['componentSizes'], [617, 8])
        self.assertEqual(person['navigationProfile']['safeCells'], 625)
        self.assertEqual(len(person['floor']), 2271)
        self.assertTrue(set(map(tuple, person['floor'])) <= set(map(tuple, legacy['floor'])))
        self.assertEqual([(o['objectId'], o['bounds']) for o in person['objects']],
                         [(o['objectId'], o['bounds']) for o in legacy['objects']])
        targets = [o for o in person['objects'] if o.get('service') is not None]
        self.assertEqual(len(targets), 6)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'person-site.json'
            path.write_text(json.dumps(person))
            for target in targets:
                with self.subTest(target=target['objectId']):
                    result = plan_route(path, person['start'], target['objectId'])
                    self.assertEqual(result['status'], 'ready')
                    self.assertEqual(result['route'][0], person['start'])
                    self.assertEqual(result['route'][-1], target['service'])
                    expected = {'boiler-room:red-circulation-pump': 2.9,
                                'boiler-room:middle-circulation-pump': 2.7}
                    self.assertAlmostEqual(result['distanceMetres'],
                                           expected.get(target['objectId'], 3.6))
                    self.assertEqual(len(result['walkableFloor']), 625)
                    self.assertTrue(target['serviceViewpoint']['requiresRenderedReview'])
                    self.assertLessEqual(target['serviceViewpoint']['horizontalStandoffMetres'], 2.)
            self.assertEqual(plan_route(path, legacy['start'], targets[0]['objectId'])['status'],
                             'blocked_start')


if __name__ == '__main__':
    unittest.main()
