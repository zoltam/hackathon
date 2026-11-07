"""Independent end-to-end checks against private registered scan and workbook."""
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

import numpy as np

from spatial_backend import SpatialApplication, box_edges, nearby_objects
from spatial_navigation import Journey, verify_route


ROOT = Path(__file__).resolve().parents[1]


class SpatialExportTest(unittest.TestCase):
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

    def test_exports_preserve_registered_assets_and_cover_workbook_objects(self):
        app = self.app
        baseline = {o['objectId']: o for o in app.baseline['objects']}
        objects = {o['objectId']: o for o in app.site['objects']}
        self.assertLessEqual(baseline.keys(), objects.keys())
        for object_id, original in baseline.items():
            self.assertEqual(objects[object_id]['bounds'], original['bounds'])
            self.assertEqual(objects[object_id]['name'], original['name'])
            self.assertEqual(objects[object_id]['extraction']['status'], 'fitted')
            self.assertNotEqual(objects[object_id]['extractionBounds'], original['bounds'])
        site = json.loads((self.output / 'site.json').read_text())
        self.assertEqual(site['sourceSha256'], app.baseline['sourceSha256'])
        self.assertEqual(site['originShift'], app.baseline['originShift'])
        self.assertEqual(site['shRotation'], app.baseline['shRotation'])
        self.assertTrue(set(map(tuple, site['floor'])) <= set(map(tuple, app.baseline['floor'])))
        associations = json.loads((self.output / 'associations.json').read_text())
        records = {a['sceneObjectId']: a for a in associations['associations']}
        workbook_objects = app.bundle['mappings'].keys()
        self.assertEqual(app.bundle['mappingMethod'], 'synthetic_explicit')
        self.assertLess(workbook_objects, objects.keys())
        self.assertEqual(records.keys(), workbook_objects)
        self.assertEqual(associations['sourceSha256'], app.bundle['sourceSha256'])
        self.assertEqual(associations['sceneSourceSha256'], app.baseline['sourceSha256'])
        self.assertTrue(associations['synthetic'])
        for object_id, asset_id in app.bundle['mappings'].items():
            self.assertEqual(records[object_id]['workbookAssetId'], asset_id)
        reports = json.loads((self.output / 'diagnostics.json').read_text())
        self.assertEqual(reports['reports'].keys(), workbook_objects)
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
                    self.assertEqual(box_edges(obj['extractionBounds']).shape, (12, 2, 3))
                    if obj['objectId'] in app.bundle['mappings']:
                        self.assertTrue(app.reports[obj['objectId']]['synthetic'])
                    else:
                        self.assertNotIn(obj['objectId'], app.reports)

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
