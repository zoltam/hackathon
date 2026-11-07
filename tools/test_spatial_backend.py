"""Independent end-to-end checks against private registered scan and workbook."""
import json
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import numpy as np

from spatial_backend import SpatialApplication, SpatialViewer, box_edges, nearby_objects
from spatial_navigation import Journey, verify_route


ROOT = Path(__file__).resolve().parents[1]


class ViewerLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.viewer = SpatialViewer.__new__(SpatialViewer)
        self.viewer._state_lock = threading.RLock()
        self.viewer.generation = 0
        self.viewer.selected_id = 'target'
        self.viewer.asset_names = {'Fixture': 'target', 'Other': 'other'}
        self.viewer.asset = SimpleNamespace(value='Other')

    def test_unreachable_journey_keeps_loop_alive_without_position(self):
        viewer = self.viewer
        viewer.journey = Journey([], .1)
        viewer.person = SimpleNamespace(visible=True)
        viewer.body = SimpleNamespace(visible=True)
        viewer.nearby = SimpleNamespace(content='Old nearby objects')
        with patch('spatial_backend.time.sleep', side_effect=StopIteration):
            with self.assertRaises(StopIteration):
                viewer.run()
        self.assertFalse(viewer.person.visible)
        self.assertFalse(viewer.body.visible)
        self.assertIn('No reachable', viewer.nearby.content)

    def test_failed_replan_removes_previous_route(self):
        viewer = self.viewer
        viewer.target_ids = {'Fixture': 'target'}
        viewer.target = SimpleNamespace(value='Fixture')
        viewer.start_x = SimpleNamespace(value=1)
        viewer.start_z = SimpleNamespace(value=1)
        old_route = Mock()
        viewer.route_handle = old_route
        viewer.app = SimpleNamespace(route=Mock(side_effect=RuntimeError('Fixture failure')))
        viewer.person = SimpleNamespace(visible=True)
        viewer.body = SimpleNamespace(visible=True)
        viewer.status = SimpleNamespace(content='Old route')
        viewer.plan()
        old_route.remove.assert_called_once()
        self.assertIsNone(viewer.route_handle)
        self.assertIsNone(viewer.journey)
        self.assertFalse(viewer.person.visible)
        self.assertIn('unavailable', viewer.status.content)

    def test_replan_stops_old_journey_before_waiting_and_syncs_inspected_asset(self):
        viewer = self.viewer
        viewer.target_ids = {'Fixture': 'target'}
        viewer.target = SimpleNamespace(value='Fixture')
        viewer.start_x = SimpleNamespace(value=1)
        viewer.start_z = SimpleNamespace(value=1)
        viewer.route_handle = None
        viewer.journey = Journey([[1, 1], [2, 1]], .1)
        viewer.journey.play()
        viewer.person = SimpleNamespace(visible=True)
        viewer.body = SimpleNamespace(visible=True)
        viewer.status = SimpleNamespace(content='Old route')
        viewer.show_report = Mock()

        def delayed_route(*args):
            self.assertIsNone(viewer.journey)
            return {'route': [[1, 1]], 'status': 'arrived', 'distanceMetres': 0}

        viewer.app = SimpleNamespace(route=delayed_route, site={'cellSize': .1})
        viewer.plan()
        self.assertEqual(viewer.asset.value, 'Fixture')
        viewer.show_report.assert_called_once_with('target')
        self.assertEqual(viewer.journey.status, 'arrived')

    def test_reset_and_replay_cannot_open_previous_arrival_explanation(self):
        viewer = self.viewer
        viewer.journey = Journey([[1, 1], [2, 1]], .1)
        viewer.journey.play()
        viewer.journey.advance(1)
        journey = viewer.journey
        viewer.show_report = Mock()
        viewer.open_report = Mock()

        def answer_after_reset(*args):
            viewer.reset()
            journey.play()
            journey.advance(1)

        viewer.app = SimpleNamespace(explain=answer_after_reset)
        viewer.arrival_report(journey, 'target', viewer.generation)
        self.assertEqual(journey.status, 'arrived')
        self.assertGreater(viewer.generation, 0)
        viewer.show_report.assert_not_called()
        viewer.open_report.assert_not_called()

    def test_catalog_refresh_cannot_be_overwritten_by_pending_model_output(self):
        app = SpatialApplication.__new__(SpatialApplication)
        original, refreshed = {'summary': 'Old association'}, {'summary': 'New association'}
        app.reports = {'target': original}
        app.lock = threading.RLock()
        app.save_reports = Mock()

        def model_returns_after_refresh(report):
            self.assertIs(report, original)
            app.reports['target'] = refreshed
            return {'summary': 'Model output for old association'}

        with patch('spatial_backend.explain_report', side_effect=model_returns_after_refresh):
            app.explain('target')
        self.assertIs(app.reports['target'], refreshed)
        app.save_reports.assert_not_called()


class ActualSpatialBackendTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.assets = ROOT / 'assets/valmet'
        cls.scan = ROOT / 'sources/valmet/Equipment Room.ply'
        cls.workbook = ROOT / 'sources/valmet/Valmet_SinceAI_2026_Synthetic_Industrial_Metaverse_Builder_Pack (1) (2) (1).xlsx'
        if not all(path.exists() for path in [cls.scan, cls.workbook,
                                               cls.assets / 'boiler-room-sh.splats']):
            raise unittest.SkipTest('Approved private scan, packed geometry or workbook unavailable')
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.output = Path(cls.directory.name) / 'spatial'
        cls.app = SpatialApplication(cls.assets, cls.scan, cls.workbook, cls.output)

    def test_scan_hash_guard_rejects_other_geometry(self):
        wrong_scan = Path(self.directory.name) / 'wrong.ply'
        wrong_scan.write_bytes(b'not the approved source scan')
        with self.assertRaisesRegex(ValueError, 'Scan hash differs'):
            SpatialApplication(self.assets, wrong_scan, self.workbook,
                               Path(self.directory.name) / 'rejected')

    def test_exports_preserve_registered_assets_and_cover_every_approved_object(self):
        app = self.app
        baseline = {o['objectId']: o for o in app.baseline['objects']}
        objects = {o['objectId']: o for o in app.site['objects']}
        self.assertLessEqual(baseline.keys(), objects.keys())
        for object_id, original in baseline.items():
            self.assertEqual(objects[object_id]['bounds'], original['bounds'])
            self.assertEqual(objects[object_id]['name'], original['name'])
        site = json.loads((self.output / 'site.json').read_text())
        self.assertEqual(site['sourceSha256'], app.baseline['sourceSha256'])
        self.assertEqual(site['originShift'], app.baseline['originShift'])
        self.assertEqual(site['shRotation'], app.baseline['shRotation'])
        self.assertTrue(set(map(tuple, site['floor'])) <= set(map(tuple, app.baseline['floor'])))
        associations = json.loads((self.output / 'associations.json').read_text())
        records = {a['sceneObjectId']: a for a in associations['associations']}
        self.assertEqual(records.keys(), objects.keys())
        self.assertEqual(associations['sourceSha256'], app.bundle['sourceSha256'])
        self.assertEqual(associations['sceneSourceSha256'], app.baseline['sourceSha256'])
        self.assertTrue(associations['synthetic'])
        for object_id, asset_id in app.bundle['mappings'].items():
            self.assertEqual(records[object_id]['workbookAssetId'], asset_id)
        reports = json.loads((self.output / 'diagnostics.json').read_text())
        self.assertEqual(reports['reports'].keys(), objects.keys())
        allowed_refs = {row['_source'] for rows in app.bundle['tables'].values()
                        if isinstance(rows, list) for row in rows if row.get('_source')}
        for object_id, report in reports['reports'].items():
            with self.subTest(object_id=object_id):
                self.assertEqual(report['schemaVersion'], 1)
                self.assertEqual(report['sceneObjectId'], object_id)
                self.assertEqual(report['workbookAssetId'], records[object_id]['workbookAssetId'])
                self.assertEqual(report['sourceSha256'], app.bundle['sourceSha256'])
                self.assertTrue(report['synthetic'])
                self.assertTrue(report['mappingNotice'])
                self.assertTrue(report['reportText'])
                self.assertEqual(report['engine'], 'deterministic')
                refs = {c['reference'] for c in report['citations']}
                self.assertTrue(refs)
                self.assertLessEqual(refs, allowed_refs)
                for field in ('observations', 'hypotheses', 'qualityIssues',
                              'missingEvidence', 'contradictions'):
                    for statement in report[field]:
                        self.assertLessEqual(set(statement['references']), refs)

    def test_six_actual_routes_playback_and_proximity(self):
        app = self.app
        targets = [o for o in app.site['objects'] if o.get('service') is not None]
        self.assertEqual(len(targets), 6)
        for target in targets:
            with self.subTest(target=target['objectId']):
                route = app.route(target['objectId'])
                self.assertEqual(route['status'], 'ready')
                self.assertTrue(verify_route(app.site, route)['reachable'])
                journey = Journey(route['route'], app.site['cellSize'])
                journey.play()
                journey.advance(journey.length_metres / journey.speed + 1)
                self.assertEqual(journey.status, 'arrived')
                np.testing.assert_allclose(journey.position,
                    [(target['service'][0] + .5) * app.site['cellSize'], 0,
                     (target['service'][1] + .5) * app.site['cellSize']])
                near = nearby_objects(app.site['objects'], journey.position)
                self.assertIn(target['objectId'], {o['objectId'] for o in near})
                for obj in near:
                    self.assertIn(obj['objectId'], app.reports)
                    self.assertEqual(box_edges(obj['bounds']).shape, (12, 2, 3))
                    self.assertTrue(app.reports[obj['objectId']]['synthetic'])

    def test_actual_blocked_and_disconnected_starts(self):
        target = next(o['objectId'] for o in self.app.site['objects'] if 'service' in o)
        for start, expected in [([58, 65], 'blocked_start'),
                                ([-1, -1], 'blocked_start'),
                                ([32, 49], 'unreachable')]:
            with self.subTest(start=start):
                result = self.app.route(target, start)
                self.assertEqual(result['status'], expected)
                self.assertEqual(result['route'], [])
                self.assertEqual(Journey(result['route'], self.app.site['cellSize']).position, None)


if __name__ == '__main__':
    unittest.main()
