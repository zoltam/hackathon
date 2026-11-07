import unittest

import numpy as np

from spatial_vision_fusion import apply_approved, camera, proposals


class VisionFusionTest(unittest.TestCase):
    def test_fits_observed_geometry_and_requires_distinct_camera_positions(self):
        points = np.array(np.meshgrid(
            np.linspace(2.9, 3.1, 9), np.linspace(.85, 1.15, 9), np.linspace(3.8, 4.2, 9)
        )).reshape(3, -1).T
        decoy = points + [0, 0, 1.8]
        cloud = np.concatenate([points, decoy])
        geometry = {'centers': cloud, 'opacities': np.ones(len(cloud))}
        focal = np.array([1.2, 1.35])
        shots, predictions = [], []
        for i, eye in enumerate(([1, 1.5, 2], [4, 1.5, 2], [5, 1.5, 4], [3, 1.5, 6])):
            shot = dict(output=f'{i}.png', eye=eye, lookAt=[3, 1, 4])
            origin, basis = camera(shot)
            q = (points - origin) @ basis.T
            projected = .5 + .5 * q[:, :2] * focal / q[:, 2:3]
            low, high = projected.min(axis=0), projected.max(axis=0)
            box = ' '.join(map(str, np.r_[low - .005, high - low + .01]))
            shots.append(shot)
            predictions.append(f'BOX {i}.png equipment .9 {box}')
        result = proposals(shots, predictions, {}, geometry, focal)['equipment']
        self.assertEqual(result['inliers'], 4)
        np.testing.assert_allclose(result['bounds'], [points.min(axis=0), points.max(axis=0)], atol=.03)
        repeated = [dict(shots[0], output=f'{i}.png') for i in range(4)]
        repeated_boxes = [predictions[0].replace('0.png', f'{i}.png') for i in range(4)]
        self.assertEqual(proposals(repeated, repeated_boxes, {}, geometry, focal), {})

    def test_approval_updates_display_bounds_without_changing_operational_bounds(self):
        obj = dict(objectId='equipment', bounds=[[0, 0, 0], [2, 2, 2]], service=[2, 3])
        site = dict(sourceSha256='scan', objects=[obj])
        fit = dict(bounds=[[.1, .1, .1], [1, 1, 1]], supportingSplats=50,
                   inliers=3, strongInliers=3, confidenceTier='strict')
        proposal_set = dict(sourceSha256='scan', method='fusion', candidates={'equipment': fit})
        members = {'equipment': np.arange(50)}
        result = apply_approved(site, proposal_set, {'equipment'}, members, 50)['objects'][0]
        self.assertEqual(result['bounds'], obj['bounds'])
        self.assertEqual(result['service'], obj['service'])
        self.assertEqual(result['extractionBounds'], fit['bounds'])
        self.assertNotIn('extractionBounds', obj)
        with self.assertRaisesRegex(ValueError, 'Invalid approved'):
            apply_approved(site, proposal_set, {'equipment'}, members, 49)


if __name__ == '__main__':
    unittest.main()
