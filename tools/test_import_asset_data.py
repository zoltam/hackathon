"""Importer contract tests using synthetic in-memory rows, no source data."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from import_asset_data import SHEETS, export


class Sheet:
    def __init__(self, rows):
        self.values = rows


class Book(dict):
    def close(self):
        pass


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.book = Book({name: Sheet([('asset_id',)]) for name in SHEETS})
        self.book['Asset_Master'] = Sheet([
            ('asset_id', 'tag'), ('A', 'TEST-A'), ('B', 'TEST-B')])
        self.book['Current_State'] = Sheet([
            ('asset_id', 'health_score'), ('A', 80), ('B', 40)])
        self.site = {'objects': [dict(name='Test', x=1, z=2, width=1,
                                     depth=1, service=[0, 2])]}

    def run_export(self, mapping=None):
        with tempfile.TemporaryDirectory() as temp:
            workbook = Path(temp) / 'synthetic.xlsx'
            workbook.write_bytes(b'synthetic test source')
            with patch('import_asset_data.load_workbook', return_value=self.book):
                return export(workbook, self.site, mapping)

    def test_reproducible_mapping_and_source_provenance(self):
        result = self.run_export()
        self.assertEqual(result, self.run_export())
        self.assertEqual(result['mappings'], {'grid:1:2:1:1': 'B'})
        self.assertEqual(result['mappingMethod'], 'synthetic_ranked')
        self.assertEqual(result['tables']['Current_State'][0]['_source'], 'Current_State!2')
        self.assertTrue(result['synthetic'])

    def test_explicit_mapping_and_invalid_ids(self):
        result = self.run_export({'grid:1:2:1:1': 'A'})
        self.assertEqual(result['mappingMethod'], 'synthetic_explicit')
        with self.assertRaises(ValueError):
            self.run_export({'grid:1:2:1:1': 'UNKNOWN'})
        with self.assertRaises(ValueError):
            self.run_export({'unknown-object': 'A'})

    def test_duplicate_scene_or_asset_ids_rejected(self):
        self.site['objects'] *= 2
        with self.assertRaises(ValueError):
            self.run_export()
        self.site['objects'] = []
        self.book['Asset_Master'] = Sheet([('asset_id',), ('A',), ('A',)])
        with self.assertRaises(ValueError):
            self.run_export()


if __name__ == '__main__':
    unittest.main()
