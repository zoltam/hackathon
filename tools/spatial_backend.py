#!/usr/bin/env python3
"""Local, scan-backed extraction review and field-service simulation.

Run with the approved complete scan and workbook; all generated data stays local.
"""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import threading
import time

import numpy as np

from import_asset_data import export as import_workbook
from import_asset_data import read_reviewed_tags
from spatial_catalog import CatalogReview
from spatial_diagnostics import build_associations, evidence_report, explain_report
from spatial_navigation import Journey, plan_route, prepare_person_site
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


class SpatialViewer:
    def __init__(self, app, port=8080):
        import viser
        self.app = app
        self._state_lock = threading.RLock()
        self.generation = 0
        self.server = viser.ViserServer(host='127.0.0.1', port=port,
                                       label='Valmet · Spatial service backend')
        self.server.scene.set_up_direction('+y')
        self.server.on_client_connect(self.connected)
        self.selected_id = next(o['objectId'] for o in app.site['objects'] if 'service' in o)
        self.journey = None
        self.arrival_opened = False
        self.boxes = {}
        self.draw_scene()
        self.draw_catalog()
        with self.server.gui.add_folder('Scene view', expand_by_default=False):
            self.upper = self.server.gui.add_checkbox('Show ceiling and upper structure', False)
            self.upper.on_update(lambda _: self.draw_scan(self.upper.value))
        with self.server.gui.add_folder('Service journey'):
            targets = {o['name']: o['objectId'] for o in app.site['objects'] if 'service' in o}
            self.target_ids = targets
            self.target = self.server.gui.add_dropdown('Target', list(targets))
            self.start_x = self.server.gui.add_number('Start cell X', app.site['start'][0], step=1)
            self.start_z = self.server.gui.add_number('Start cell Z', app.site['start'][1], step=1)
            self.server.gui.add_button('Plan route').on_click(lambda _: self.plan())
            self.server.gui.add_button('Play').on_click(lambda _: self.playback('play'))
            self.server.gui.add_button('Pause').on_click(lambda _: self.playback('pause'))
            self.server.gui.add_button('Reset').on_click(lambda _: self.reset())
            self.follow = self.server.gui.add_checkbox('Follow person', False)
            self.status = self.server.gui.add_markdown('Preparing route…')
            self.nearby = self.server.gui.add_markdown('Nearby equipment')
        with self.server.gui.add_folder('Equipment and evidence'):
            self.asset_names = self.report_options()
            self.asset = self.server.gui.add_dropdown('Inspect asset', list(self.asset_names))
            self.asset.on_update(lambda _: self.show_report(self.asset_names[self.asset.value]))
            self.server.gui.add_button('Open inspection report').on_click(
                lambda _: self.open_report(self.asset_names[self.asset.value]))
            self.ai = self.server.gui.add_button('Explain with local AI')
            self.ai.on_click(self.explain)
            self.report = self.server.gui.add_markdown('Select an asset to inspect supplied evidence.')
        with self.server.gui.add_folder('Extraction review', expand_by_default=False):
            self.review_ids = self.server.gui.add_text('Candidate IDs (comma separated)', '')
            self.proposal = self.server.gui.add_dropdown('Candidate', list(app.catalog.candidates) or ['none'])
            self.proposal.on_update(lambda event: self.show_candidate(event.client))
            self.review_name = self.server.gui.add_text('Object name', '')
            self.review_type = self.server.gui.add_text('Object type', 'context')
            self.review_min = [self.server.gui.add_number(f'Min {axis.upper()}', 0.0, step=.01)
                               for axis in ('x', 'y', 'z')]
            self.review_max = [self.server.gui.add_number(f'Max {axis.upper()}', 1.0, step=.01)
                               for axis in ('x', 'y', 'z')]
            self.server.gui.add_button('Refine candidate bounds').on_click(lambda _: self.review_action('refine'))
            self.server.gui.add_button('Record this view').on_click(self.record_view)
            self.server.gui.add_button('Accept reviewed object').on_click(lambda _: self.review_action('accept'))
            self.server.gui.add_button('Reject candidate').on_click(lambda _: self.review_action('reject'))
            self.server.gui.add_button('Rename object').on_click(lambda _: self.review_action('rename'))
            self.server.gui.add_button('Merge selected IDs').on_click(lambda _: self.review_action('merge'))
            self.axis = self.server.gui.add_dropdown('Split axis', ['x', 'y', 'z'])
            self.split_at = self.server.gui.add_number('Split coordinate (metres)', 0.0, step=.01)
            self.server.gui.add_button('Split candidate').on_click(lambda _: self.review_action('split'))
            self.review_status = self.server.gui.add_markdown('Proposals are unclassified until reviewed from at least two directions.')
        self.plan()

    def draw_scene(self):
        self.draw_scan(False)
        self.person = self.server.scene.add_icosphere('/person/head', radius=.12,
                                                     color=(240, 180, 60))
        self.body = self.server.scene.add_icosphere('/person/body', radius=.30,
            scale=(1, 3, 1), color=(240, 180, 60), opacity=.65)
        self.route_handle = None

    def draw_scan(self, upper):
        g = self.app.geometry
        # Cutaway affects display only; all source geometry remains in analysis.
        mask = np.ones(len(g['centers']), dtype=bool) if upper else g['centers'][:, 1] <= 2.2
        self.server.scene.add_gaussian_splats('/scan', g['centers'][mask], g['covariances'][mask],
                                              g['rgbs'][mask], g['opacities'][mask, None])

    def draw_catalog(self):
        for handle in self.boxes.values():
            handle.remove()
        self.boxes = {}
        for obj in self.app.site['objects']:
            self.boxes[obj['objectId']] = self.server.scene.add_line_segments(
                '/assets/' + obj['objectId'].replace(':', '/'),
                box_edges(obj.get('extractionBounds', obj['bounds'])),
                (60, 210, 180), thickness=.008)

    def connected(self, client):
        client.camera.position = (6.3, 5.8, 10.3)
        client.camera.look_at = (7.3, .6, 6.5)
        client.camera.up_direction = (0, 1, 0)

    def plan(self):
        with self._state_lock:
            self.generation += 1
            generation = self.generation
            target = self.target_ids[self.target.value]
            self.selected_id = target
            self.journey = None
            self.person.visible = self.body.visible = False
            if self.route_handle:
                self.route_handle.remove()
                self.route_handle = None
            coordinates = [self.start_x.value, self.start_z.value]
        try:
            if any(not float(value).is_integer() for value in coordinates):
                raise ValueError('Start cells must be whole numbers')
            result = self.app.route(target, list(map(int, coordinates)))
            with self._state_lock:
                if generation != self.generation:
                    return
                self.journey = Journey(result['route'], self.app.site['cellSize'])
                self.arrival_opened = False
                route = result['route']
                if len(route) > 1:
                    p = np.array([[(x + .5) * self.app.site['cellSize'], .04,
                                   (z + .5) * self.app.site['cellSize']] for x, z in route])
                    self.route_handle = self.server.scene.add_line_segments(
                        '/service-route', np.stack([p[:-1], p[1:]], axis=1),
                        (245, 190, 60), thickness=.025)
                self.status.content = (f"**{result['status']}** · {result['distanceMetres']:.2f} m\n\n"
                                       'Person: 0.60 m wide × 1.80 m tall, 0.05 m overhead margin.')
                self.asset.value = next(name for name, value in self.asset_names.items() if value == target)
                self.show_report(target)
        except (ValueError, RuntimeError, OSError) as error:
            with self._state_lock:
                if generation == self.generation:
                    self.status.content = f'Route unavailable: {error}'

    def playback(self, action):
        with self._state_lock:
            if self.journey:
                getattr(self.journey, action)()

    def reset(self):
        with self._state_lock:
            self.generation += 1
            if self.journey:
                self.journey.reset()
            self.arrival_opened = False

    def show_report(self, object_id):
        report = self.app.reports.get(object_id)
        if report is None:
            self.report.content = 'No workbook association.'
            return
        text = report.get('llmSummary') or report['summary']
        self.report.content = (f"**{report['tag']} · {report['condition']}**\n\n"
            f"{report['mappingNotice']}\n\n{text}\n\nEngine: {report['engine']}")

    def report_options(self):
        return {o['name'] + ' · ' + o['objectId']: o['objectId']
                for o in self.app.site['objects'] if o['objectId'] in self.app.reports}

    def open_report(self, object_id):
        report = self.app.reports[object_id]
        with self.server.gui.add_modal('Inspection evidence') as modal:
            if report.get('llmSummary'):
                self.server.gui.add_markdown('**Local AI explanation**\n\n' + report['llmSummary'])
            self.server.gui.add_markdown(report['reportText'])
            self.server.gui.add_markdown(f"Engine: {report['engine']} · {report.get('modelStatus', 'not requested')}")
            self.server.gui.add_button('Close report').on_click(lambda _: modal.close())

    def explain(self, _):
        self.ai.disabled = True
        object_id = self.asset_names[self.asset.value]
        self.report.content = 'Generating a local explanation from cited workbook evidence…'
        try:
            self.app.explain(object_id)
            if self.asset_names[self.asset.value] == object_id:
                self.show_report(object_id)
        finally:
            self.ai.disabled = False

    def arrival_report(self, journey, object_id, generation):
        self.app.explain(object_id)
        with self._state_lock:
            if (self.generation == generation and self.journey is journey
                    and journey.status == 'arrived'):
                if self.asset_names[self.asset.value] == object_id:
                    self.show_report(object_id)
                self.open_report(object_id)
                self.status.content = '**Arrived** · Inspection report ready.'

    def show_candidate(self, client=None):
        candidate = self.app.catalog.candidates.get(self.proposal.value)
        if candidate is None:
            return
        self.review_ids.value = self.proposal.value
        decision = self.app.catalog.decisions.get(self.proposal.value, {})
        self.review_name.value = decision.get('name', candidate.get('name', ''))
        self.review_type.value = decision.get('equipmentType', 'context')
        lo, hi = np.asarray(candidate['bounds'])
        for handle, value in zip(self.review_min + self.review_max, list(lo) + list(hi)):
            handle.value = float(value)
        center = (lo + hi) / 2
        self.split_at.value = float(center[['x', 'y', 'z'].index(self.axis.value)])
        self.server.scene.add_line_segments('/review/box', box_edges(candidate['bounds']),
                                            (255, 130, 70), thickness=.015)
        members = self.app.catalog.memberships[self.proposal.value]
        self.server.scene.add_point_cloud('/review/members', self.app.geometry['centers'][members],
                                          (255, 150, 60), point_size=.012)
        self.review_status.content = json.dumps({**candidate, 'review': decision}, indent=2)
        if client:
            client.camera.look_at = tuple(center)

    def record_view(self, event):
        try:
            if event.client is None:
                raise ValueError('Open the viewer to record a review camera')
            self.app.catalog.record_view(self.proposal.value, list(event.client.camera.position))
            self.show_candidate()
        except ValueError as error:
            self.review_status.content = str(error)

    def review_action(self, action):
        try:
            catalog, candidate = self.app.catalog, self.proposal.value
            if action == 'accept':
                catalog.accept(candidate, self.review_name.value, self.review_type.value)
            elif action == 'reject':
                catalog.reject(candidate)
            elif action == 'rename':
                catalog.rename(candidate, self.review_name.value)
            elif action == 'merge':
                ids = [s.strip() for s in self.review_ids.value.split(',') if s.strip()]
                candidate = catalog.merge(ids, self.review_name.value)
            elif action == 'split':
                candidate = catalog.split(candidate, ['x', 'y', 'z'].index(self.axis.value), self.split_at.value)[0]
            elif action == 'refine':
                candidate = catalog.refine_bounds(candidate,
                    [h.value for h in self.review_min], [h.value for h in self.review_max])
            self.app.refresh_exports()
            self.draw_catalog()
            self.proposal.options = list(catalog.candidates)
            self.proposal.value = candidate
            self.asset_names = self.report_options()
            self.asset.options = list(self.asset_names)
            self.review_status.content = f'Saved. {len(catalog.accepted_objects)} reviewed assets.'
        except (ValueError, KeyError) as error:
            self.review_status.content = str(error)

    def run(self):
        previous = time.monotonic()
        while True:
            now = time.monotonic()
            with self._state_lock:
                if self.journey:
                    self.journey.advance(min(now - previous, .1))
                    position = self.journey.position
                    self.person.visible = self.body.visible = position is not None
                    if position is None:
                        self.nearby.content = 'No reachable walking route from this start.'
                        previous = now
                        time.sleep(.05)
                        continue
                    self.person.position = (position[0], 1.65, position[2])
                    self.body.position = (position[0], .9, position[2])
                    nearby = nearby_objects(self.app.site['objects'], position)
                    visible = {o['objectId'] for o in nearby}
                    for object_id, box in self.boxes.items():
                        box.visible = object_id in visible
                    lines = []
                    for obj in nearby:
                        report = self.app.reports.get(obj['objectId'])
                        detail = (f"{report['tag']} · {report['condition']} (synthetic)"
                                  if report else 'No workbook association')
                        lines.append(f"{obj['name']} · {detail}")
                    self.nearby.content = '**Nearby within 2.5 m**\n\n' + '\n\n'.join(lines)
                    if self.journey.status != 'arrived':
                        remaining = max(0, self.journey.length_metres - self.journey.travelled)
                        self.status.content = f'**{self.journey.status}** · {remaining:.2f} m remaining'
                    if self.follow.value:
                        for client in self.server.get_clients().values():
                            if self.journey.status == 'arrived':
                                target = next(o for o in self.app.site['objects'] if o['objectId'] == self.selected_id)
                                client.camera.position = (position[0], 1.65, position[2])
                                client.camera.look_at = tuple(target['serviceViewpoint']['lookAt'])
                            else:
                                client.camera.position = (position[0] - 1, 2.3, position[2] + 1.7)
                                client.camera.look_at = (position[0], 1, position[2])
                    if self.journey.status == 'arrived' and not self.arrival_opened:
                        self.arrival_opened = True
                        self.status.content = '**Arrived** · Preparing the cited inspection report locally…'
                        threading.Thread(target=self.arrival_report,
                            args=(self.journey, self.selected_id, self.generation), daemon=True).start()
            previous = now
            time.sleep(.05)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, default=Path('assets/valmet'))
    parser.add_argument('--scan', type=Path, default=Path('sources/valmet/Equipment Room.ply'))
    parser.add_argument('--workbook', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('build/spatial'))
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--port', type=int, default=8080)
    args = parser.parse_args()
    app = SpatialApplication(args.assets, args.scan, args.workbook, args.output)
    pending = sum(app.catalog.decisions.get(key, {}).get('status', 'pending') == 'pending'
                  for key in app.catalog.candidates)
    print(f'Prepared {len(app.site["objects"])} approved assets and {pending} pending proposals', flush=True)
    if not args.prepare_only:
        viewer = SpatialViewer(app, args.port)
        print(f'Open http://127.0.0.1:{args.port}', flush=True)
        try:
            viewer.run()
        except KeyboardInterrupt:
            pass
        finally:
            viewer.server.stop()


if __name__ == '__main__':
    main()
