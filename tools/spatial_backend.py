#!/usr/bin/env python3
"""Prepare offline scene, equipment catalog and service evidence exports.

Run with the approved complete scan and workbook; all generated data stays local.
"""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import threading

import numpy as np

from import_asset_data import export as import_workbook
from import_asset_data import read_reviewed_tags
from spatial_catalog import CatalogReview
from spatial_diagnostics import build_associations, evidence_report, explain_report
from spatial_navigation import plan_route, prepare_person_site
from spatial_scene import load_geometry, sha256, write_json


def box_edges(bounds):
    lo, hi = np.asarray(bounds, dtype=float)
    corners = np.array([[hi[a] if i & (1 << a) else lo[a] for a in range(3)]
                        for i in range(8)])
    return np.array([[corners[i], corners[i | axis]] for i in range(8)
                     for axis in (1, 2, 4) if not i & axis])


def nearby_objects(objects, position, radius=2.5):
    point = np.asarray(position)[[0, 2]]
    nearby = []
    for obj in objects:
        bounds = np.asarray(obj['bounds'])[:, [0, 2]]
        gap = np.maximum(np.maximum(bounds[0] - point, point - bounds[1]), 0)
        distance = float(np.linalg.norm(gap))
        if distance <= radius:
            nearby.append((distance, obj['objectId'], obj))
    return [obj for _, _, obj in sorted(nearby, key=lambda item: item[:2])]


class SpatialApplication:
    def __init__(self, assets, scan, workbook, output):
        self.assets, self.output = Path(assets), Path(output)
        self.output.mkdir(parents=True, exist_ok=True)
        self.baseline = json.loads((self.assets / 'site.json').read_text())
        if sha256(scan) != self.baseline['sourceSha256']:
            raise ValueError('Scan hash differs from the registered app geometry; rebuild its assets first')
        self.geometry = load_geometry(self.assets)
        manifest = self.assets / 'reviewed-asset-tags.json'
        reviewed_tags = read_reviewed_tags(manifest) if manifest.is_file() else None
        self.bundle = import_workbook(workbook, self.baseline, include_nearby=True,
                                      reviewed_tags=reviewed_tags)
        self.catalog = CatalogReview(self.baseline, self.geometry, self.output / 'catalog')
        self.person_base = prepare_person_site(self.baseline, self.geometry)
        self.reports = {}
        self.lock = threading.RLock()
        self.refresh_exports()

    def refresh_exports(self):
        with self.lock:
            self.catalog.export()
            self.site = deepcopy(self.person_base)
            approaches = {o['objectId']: o for o in self.person_base['objects'] if 'service' in o}
            self.site['objects'] = deepcopy(self.catalog.accepted_objects)
            for obj in self.site['objects']:
                if obj['objectId'] in approaches:
                    for field in ('service', 'serviceViewpoint'):
                        if field in approaches[obj['objectId']]:
                            obj[field] = deepcopy(approaches[obj['objectId']][field])
            self.associations = build_associations(self.site, self.bundle)
            self.associations['sceneSourceSha256'] = self.site['sourceSha256']
            self.reports = {key: evidence_report(key, self.site, self.bundle, self.associations)
                            for key in (a['sceneObjectId'] for a in self.associations['associations'])}
            write_json(self.output / 'site.json', self.site)
            write_json(self.output / 'asset-data.json', self.bundle)
            write_json(self.output / 'associations.json', self.associations)
            self.save_reports()

    def save_reports(self):
        write_json(self.output / 'diagnostics.json', {
            'schemaVersion': 1, 'sourceSha256': self.bundle['sourceSha256'],
            'sceneSourceSha256': self.site['sourceSha256'], 'reports': self.reports,
        })

    def route(self, target, start=None):
        return plan_route(self.output / 'site.json', start or self.site['start'], target)

    def explain(self, object_id):
        with self.lock:
            original = self.reports[object_id]
        report = explain_report(original)
        with self.lock:
            if self.reports.get(object_id) is not original:
                return self.reports.get(object_id)
            self.reports[object_id] = report
            self.save_reports()
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, default=Path('assets/valmet'))
    parser.add_argument('--scan', type=Path, default=Path('sources/valmet/Equipment Room.ply'))
    parser.add_argument('--workbook', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('build/spatial'))
    args = parser.parse_args()
    app = SpatialApplication(args.assets, args.scan, args.workbook, args.output)
    pending = sum(app.catalog.decisions.get(key, {}).get('status', 'pending') == 'pending'
                  for key in app.catalog.candidates)
    print(f'Prepared {len(app.site["objects"])} approved assets and {pending} pending proposals', flush=True)


if __name__ == '__main__':
    main()
