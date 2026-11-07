"""Membership, review gates and reproducibility for geometric proposals."""
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

from spatial_catalog import CatalogReview


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        rng = np.random.default_rng(8)
        points = np.concatenate([rng.uniform([x, .3, .3], [x+.25, .55, .55], (200, 3))
                                 for x in (1., 2.)])
        self.geometry = {'centers': points, 'opacities': np.ones(len(points))}
        self.site = {'sourceSha256': 'fixture', 'cellSize': .1, 'width': 40,
                     'depth': 40, 'start': [0, 0], 'floor': [], 'name': 'test', 'objects': []}

    def review(self):
        return CatalogReview(self.site, self.geometry, self.path)

    def qualify(self, review, key):
        center = np.mean(review.candidates[key]['bounds'], axis=0)
        review.record_view(key, center + [1, 0, 0])
        review.record_view(key, center + [0, 0, 1])
        review.accept(key, 'Reviewed object')

    def test_proposals_are_deterministic_and_require_distinct_views(self):
        review = self.review()
        self.assertEqual(len(review.candidates), 2)
        self.assertEqual(review.accepted_objects, [])
        key = next(iter(review.candidates))
        with self.assertRaisesRegex(ValueError, 'two recorded'):
            review.accept(key, 'object')
        center = np.mean(review.candidates[key]['bounds'], axis=0)
        review.record_view(key, center + [1, 0, 0])
        review.record_view(key, center + [1, 0, .01])
        with self.assertRaisesRegex(ValueError, '30 degrees'):
            review.accept(key, 'object')
        self.qualify(review, key)
        rebuilt = self.review()
        self.assertEqual(list(review.candidates), list(rebuilt.candidates))
        self.assertEqual(review.accepted_objects, rebuilt.accepted_objects)
        membership = np.load(self.path / 'memberships.npz')
        np.testing.assert_array_equal(membership[key], review.memberships[key])

    def test_baseline_preserved_and_never_reproposed(self):
        obj = {'objectId': 'baseline', 'name': 'Original', 'bounds': [[1, .3, .3], [1.3, .6, .6]],
               'equipmentType': 'pump', 'x': 10, 'z': 3, 'width': 3, 'depth': 3, 'height': .6}
        self.site['objects'] = [obj]
        review = self.review()
        [extracted] = review.accepted_objects
        self.assertEqual(extracted['bounds'], obj['bounds'])
        self.assertEqual(extracted['extraction']['status'], 'fitted')
        self.assertEqual(extracted['extraction']['supportingSplats'], 200)
        expected = np.quantile(self.geometry['centers'][:200], [.01, .99], axis=0)
        np.testing.assert_allclose(extracted['extractionBounds'], expected + [[-.01], [.01]])
        self.assertNotIn('extractionBounds', obj)
        self.assertEqual(len(review.candidates), 1)
        for key in review.candidates:
            self.assertFalse(np.intersect1d(review.memberships[key], review.memberships['baseline']).size)

    def test_merge_split_replay_and_no_duplicate_acceptance(self):
        review = self.review()
        originals = sorted(review.candidates)
        merged = review.merge(originals, 'Merged')
        self.qualify(review, merged)
        with self.assertRaisesRegex(ValueError, 'shares splats'):
            self.qualify(review, originals[0])
        review.reject(merged)
        children = review.split(merged, 0, 1.5)
        for key in children:
            self.qualify(review, key)
        before = json.loads((self.path / 'review.json').read_text())
        rebuilt = self.review()
        self.assertEqual(review.accepted_objects, rebuilt.accepted_objects)
        self.assertEqual(before, json.loads((self.path / 'review.json').read_text()))

    def test_wrong_source_and_invalid_split_fail(self):
        review = self.review()
        key = next(iter(review.candidates))
        with self.assertRaisesRegex(ValueError, '50 supporting'):
            review.split(key, 0, -100)
        review.export()
        self.site['sourceSha256'] = 'other'
        with self.assertRaisesRegex(ValueError, 'different source'):
            self.review()

    def test_floor_exclusion_does_not_mutate_source_geometry(self):
        original = self.geometry['centers'].copy()
        self.geometry['centers'] = np.concatenate([original, original * [1, 0, 1]])
        self.geometry['opacities'] = np.ones(len(self.geometry['centers']))
        before = self.geometry['centers'].copy()
        review = self.review()
        self.assertEqual(len(review.candidates), 2)
        for indices in review.memberships.values():
            self.assertTrue((self.geometry['centers'][indices, 1] > .15).all())
        np.testing.assert_array_equal(before, self.geometry['centers'])

    def test_geometry_hash_must_match_catalog(self):
        self.geometry['sourceSha256'] = 'different'
        with self.assertRaisesRegex(ValueError, 'different source'):
            self.review()

    def test_reviewed_crop_resets_views_and_replays(self):
        review = self.review()
        key = next(iter(review.candidates))
        self.qualify(review, key)
        lo, hi = np.array(review.candidates[key]['bounds'])
        refined = review.refine_bounds(key, lo-[.01, .1, .01], hi+[.01, .01, .01], 'agent_fixture_review')
        self.assertGreaterEqual(len(review.memberships[refined]), len(review.memberships[key]))
        self.assertEqual(review.decisions[refined]['views'], [])
        self.assertEqual(review.decisions[refined]['status'], 'pending')
        self.assertEqual(self.review().candidates, review.candidates)
        self.assertEqual(refined, review.refine_bounds(refined, lo-[.01, .1, .01], hi+[.01, .01, .01]))
        for invalid_lo, invalid_hi in (([0, 0], [1, 1]), ([0, 0, 0], [float('nan'), 1, 1]), ([1, 1, 1], [0, 0, 0])):
            with self.assertRaisesRegex(ValueError, 'finite ordered'):
                review.refine_bounds(key, invalid_lo, invalid_hi)


if __name__ == '__main__':
    unittest.main()
