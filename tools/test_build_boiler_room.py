"""Synthetic PLY regression for replacing the original scene crop."""
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

from build_boiler_room import prepare


class SceneImportTests(unittest.TestCase):
    def test_full_scene_keeps_geometry_and_fits_new_navigation_origin(self):
        columns = ['x', 'y', 'z', 'rot_0', 'rot_1', 'rot_2', 'rot_3',
                   'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity',
                   'scale_0', 'scale_1', 'scale_2']
        rows = []

        def point(x, y, z):
            return [x, y, z, 1, 0, 0, 0, 0, 0, 0, 2, -5, -5, -5]

        # A room outside the original hardcoded crop, plus one obstacle.
        for x in range(6):
            for z in range(6):
                if (x, z) == (1, 1):
                    continue  # Unknown floor must not be filled automatically.
                floor_point = point(10.125 + x * .25, 1.17, 10.125 + z * .25)
                if (x, z) == (4, 0):
                    floor_point[10] = -3.5  # Faint floor, still measured geometry.
                rows.extend([floor_point] * 20)
        rows.extend([point(10.625, .67, 10.625)] * 60)
        rows.extend([point(14.125, 1.17, 14.125)] * 20)  # Disconnected floor.
        rows.extend([point(10.875, -1.03, 10.875)] * 60)  # Above body-height band.
        rows.append(point(2, 1.17, 2))  # Rendered, outside the navigation extent.
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'Updated.ply'
            destination = Path(temp) / 'assets'
            header = ['ply', 'format binary_little_endian 1.0',
                      f'element vertex {len(rows)}']
            header += [f'property float {c}' for c in columns]
            header.append('end_header')
            with source.open('wb') as stream:
                stream.write(('\n'.join(header) + '\n').encode())
                np.array(rows, dtype='<f4').tofile(stream)
            prepare(source, destination, full_scene=True,
                    floor_y=1.17, name='Equipment Room')
            model = json.loads((destination / 'site.json').read_text())
            splats = np.fromfile(destination / 'boiler-room.splats', '<f4').reshape(-1, 16)
            self.assertEqual(len(splats), len(rows) - 20)
            self.assertTrue(np.isfinite(splats).all())
            self.assertLess(splats[:, 0].min(), 0)
            self.assertEqual(model['name'], 'Equipment Room')
            self.assertEqual(model['sourceFile'], 'Updated.ply')
            self.assertEqual(len(model['floor']), 35)
            self.assertEqual(model['floorMapping']['connectedCellsFromStart'], 34)
            self.assertEqual(model['floorMapping']['disconnectedFloorCells'], 1)
            self.assertEqual(model['floorMapping']['importerMarginMetres'], 0)
            origin = model['sourceOrigin']
            def cell_at(x, z):
                return [int(np.floor((x-origin[0])/.25)),
                        int(np.floor((origin[2]-z)/.25))]
            self.assertNotIn(cell_at(10.375, 10.375), model['floor'])
            self.assertNotIn(cell_at(10.625, 10.625), model['floor'])
            self.assertIn(cell_at(10.875, 10.875), model['floor'])
            self.assertIn(cell_at(14.125, 14.125), model['floor'])
            self.assertIn(cell_at(11.125, 10.125), model['floor'])
            self.assertEqual(model['floorMapping']['minimumFloorOpacity'], .01)
            self.assertIn(model['start'], model['floor'])
            self.assertIn(model['objects'][0]['service'], model['floor'])
            self.assertGreater(model['sourceOrigin'][0], 5)


if __name__ == '__main__':
    unittest.main()
