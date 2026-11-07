"""Person-sized navigation variant and playback; Dart remains the route authority."""
from collections import Counter, deque
from copy import deepcopy
import json
import math
from pathlib import Path
import shutil
import subprocess

import numpy as np

from build_boiler_room import clearance_floor
from scene_equipment import service_approach


def _components(cells):
    remaining = set(cells)
    groups = []
    while remaining:
        start = min(remaining)
        remaining.remove(start)
        queue, group = deque([start]), {start}
        while queue:
            x, z = queue.popleft()
            for p in ((x - 1, z), (x + 1, z), (x, z - 1), (x, z + 1)):
                if p in remaining:
                    remaining.remove(p)
                    group.add(p)
                    queue.append(p)
        groups.append(group)
    return sorted(groups, key=lambda group: (-len(group), min(group)))


def _distances(start, allowed):
    queue, result = deque([start]), {start: 0}
    while queue:
        x, z = queue.popleft()
        for p in ((x - 1, z), (x + 1, z), (x, z - 1), (x, z + 1)):
            if p in allowed and p not in result:
                result[p] = result[(x, z)] + 1
                queue.append(p)
    return result


def _footprint(obj):
    if 'cells' in obj and obj['cells'] is not None:
        return set(map(tuple, obj['cells']))
    return {(x, z) for x in range(obj['x'], obj['x'] + obj['width'])
            for z in range(obj['z'], obj['z'] + obj['depth'])}


def prepare_person_site(site, geometry):
    """Conservatively remove occupied floor; never fill or change legacy assets."""
    result = deepcopy(site)
    points = np.asarray(geometry['centers'])
    opacity = np.asarray(geometry['opacities']).reshape(-1)
    if points.ndim != 2 or points.shape[1] != 3 or len(points) != len(opacity):
        raise ValueError('Geometry centers/opacities have incompatible shapes')
    cell = float(site['cellSize'])
    if not math.isfinite(cell) or cell <= 0:
        raise ValueError('Invalid cell size')
    mask = ((points[:, 1] >= .12) & (points[:, 1] <= 1.85)
            & (opacity >= 1 / (1 + np.exp(2.2))))
    grid = np.floor(points[mask][:, [0, 2]] / cell).astype(int)
    occupied = {p for p, count in Counter(map(tuple, grid.tolist())).items()
                if count >= 4}
    floor = set(map(tuple, site['floor'])) - occupied
    catalog = set().union(*(_footprint(obj) for obj in site['objects']))
    safe = clearance_floor(floor - catalog, cell, .30)
    groups = _components(safe)
    if not groups:
        raise ValueError('No observed floor supports the person envelope')
    connected = groups[0]
    old_start = site['start']
    start = min(connected, key=lambda p: (
        sum((a - b) ** 2 for a, b in zip(p, old_start)), p))
    distances = _distances(start, connected)
    scan = points[opacity >= .12]
    for obj in result['objects']:
        if obj.get('service') is None:
            continue
        old_service = obj['service']
        approach = service_approach(obj['bounds'], distances, scan, cell, 1.65)
        if approach is None:
            obj.pop('service', None)
            obj['serviceViewpoint'] = {'status': 'unreachable', 'legacyService': old_service}
            continue
        lo, hi = np.asarray(obj['bounds'])
        eye = np.array([(approach[0] + .5) * cell, 1.65, (approach[1] + .5) * cell])
        gap = np.maximum(np.maximum(lo - eye, eye - hi), 0)[[0, 2]]
        look = (lo + hi) / 2
        look[1] = hi[1] * .9
        obj['service'] = list(approach)
        obj['serviceViewpoint'] = {
            'status': 'candidate', 'legacyService': old_service,
            'eye': eye.tolist(), 'lookAt': look.tolist(),
            'horizontalStandoffMetres': float(np.linalg.norm(gap)),
            'visibilityMethod': 'opaque_splat_centers_5.5cm_ray_10cm_bins_fewer_than_four_hits',
            'requiresRenderedReview': True,
        }
    result['start'] = list(start)
    result['floor'] = [list(p) for p in sorted(floor)]
    result['navigationProfile'] = {
        'name': 'walking-person', 'radiusMetres': .30,
        'bodyHeightMetres': 1.80, 'headMarginMetres': .05,
        'obstacleHeightMetres': [.12, 1.85], 'eyeHeightMetres': 1.65,
        'speedMetresPerSecond': .7, 'minimumObstacleSplats': 4,
        'minimumObstacleOpacity': float(1 / (1 + np.exp(2.2))),
        'observedFloorOnly': True, 'floorCells': len(floor),
        'safeCells': len(safe), 'componentSizes': [len(group) for group in groups],
        'legacyStart': list(old_start),
        'collisionModel': 'scan_center_occupancy_and_continuous_swept_circle_against_grid',
        'limitations': [
            'Model units are assumed metres; physical scale is not independently calibrated.',
            'Occupancy uses measured splat centers; Gaussian extent is not certified solid geometry.',
            'Floor uncertainty is inherited from the 12 cm floor band; foot-level hazards require review.',
            'Service visibility is a geometric proposal requiring rendered review.',
        ],
    }
    return result


def verify_swept_route(route, raw_floor, cell_size, radius):
    """Exact swept-circle test against non-floor grid squares for cardinal edges."""
    allowed = set(map(tuple, raw_floor))
    reach = math.ceil(radius / cell_size) + 1
    edges = (list(zip(route, route[1:])) or [(route[0], route[0])]) if route else []
    for a, b in edges:
        if abs(a[0] - b[0]) + abs(a[1] - b[1]) not in (0, 1):
            raise ValueError('Route contains a non-cardinal edge')
        lo_x, hi_x = (min(a[0], b[0]) + .5) * cell_size, (max(a[0], b[0]) + .5) * cell_size
        lo_z, hi_z = (min(a[1], b[1]) + .5) * cell_size, (max(a[1], b[1]) + .5) * cell_size
        for x in range(min(a[0], b[0]) - reach, max(a[0], b[0]) + reach + 1):
            for z in range(min(a[1], b[1]) - reach, max(a[1], b[1]) + reach + 1):
                if (x, z) in allowed:
                    continue
                dx = max(0, x * cell_size - hi_x, lo_x - (x + 1) * cell_size)
                dz = max(0, z * cell_size - hi_z, lo_z - (z + 1) * cell_size)
                if dx * dx + dz * dz < radius * radius - 1e-12:
                    raise ValueError(f'Swept route intersects blocked cell {(x, z)}')


def verify_route(site, result):
    """Check returned routes against the represented scene, not planner-provided masks."""
    radius = site.get('navigationProfile', {}).get('radiusMetres', .30)
    blocked = set().union(*(_footprint(obj) for obj in site['objects']))
    floor = set(map(tuple, site['floor'])) - blocked
    route = result['route']
    if not route:
        if result['status'] in ('ready', 'arrived'):
            raise ValueError('Planner reported success without a route')
        return {'verifiedEdges': 0, 'reachable': False}
    if result['status'] not in ('ready', 'arrived'):
        raise ValueError('Planner returned a route for a failed request')
    if route[-1] not in [obj.get('service') for obj in site['objects']]:
        raise ValueError('Route does not end at a service approach')
    if any(tuple(p) not in floor for p in route):
        raise ValueError('Route leaves observed free floor')
    verify_swept_route(route, floor, site['cellSize'], radius)
    distance = max(0, len(route) - 1) * site['cellSize']
    if not math.isclose(result['distanceMetres'], distance, abs_tol=1e-9):
        raise ValueError('Route distance is inconsistent with its cells')
    return {'verifiedEdges': max(0, len(route) - 1), 'reachable': True,
            'collisionModel': 'continuous_swept_circle_against_represented_grid',
            'radiusMetres': radius}


def plan_route(site_path, start, target_id, dart_path=None):
    root = Path(__file__).resolve().parents[1]
    dart = dart_path or shutil.which('dart')
    if dart is None:
        candidate = root.parent / 'work/flutter/bin/dart'
        if candidate.exists():
            dart = str(candidate)
    if dart is None:
        raise RuntimeError('Dart SDK unavailable; install Flutter or pass dart_path')
    site_path = Path(site_path).resolve()
    site = json.loads(site_path.read_text())
    radius = site.get('navigationProfile', {}).get('radiusMetres', .30)
    request = {'sitePath': str(site_path), 'start': start,
               'targetID': target_id, 'clearanceMetres': radius}
    process = subprocess.run([str(dart), 'run', 'tools/spatial_route.dart'],
                             cwd=root, input=json.dumps(request), text=True,
                             capture_output=True, timeout=60, check=True)
    try:
        result = json.loads(process.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError('Dart planner returned malformed JSON') from error
    verify_route(site, result)
    return result


class Journey:
    """Deterministic frame-independent playback of a verified cardinal route."""
    def __init__(self, route, cell_size, speed=.7):
        if not math.isfinite(cell_size) or cell_size <= 0 or not math.isfinite(speed) or speed <= 0:
            raise ValueError('Cell size and speed must be finite and positive')
        self.route = [tuple(p) for p in route]
        if any(abs(a[0] - b[0]) + abs(a[1] - b[1]) != 1
               for a, b in zip(self.route, self.route[1:])):
            raise ValueError('Journey route must have cardinal adjacent cells')
        self.cell_size, self.speed = cell_size, speed
        self.reset()

    @property
    def length_metres(self):
        return max(0, len(self.route) - 1) * self.cell_size

    @property
    def position(self):
        if not self.route:
            return None
        step = self.travelled / self.cell_size
        index = min(int(step), len(self.route) - 1)
        a, b = self.route[index], self.route[min(index + 1, len(self.route) - 1)]
        fraction = step - index
        return (((a[0] + .5) + (b[0] - a[0]) * fraction) * self.cell_size,
                0., ((a[1] + .5) + (b[1] - a[1]) * fraction) * self.cell_size)

    def reset(self):
        self.travelled = 0.
        self.status = 'unreachable' if not self.route else 'arrived' if len(self.route) == 1 else 'ready'

    def play(self):
        if self.status in ('ready', 'paused'):
            self.status = 'playing'

    def pause(self):
        if self.status == 'playing':
            self.status = 'paused'

    def advance(self, seconds):
        if not math.isfinite(seconds) or seconds < 0:
            raise ValueError('Elapsed seconds must be finite and nonnegative')
        if self.status != 'playing':
            return
        self.travelled = min(self.length_metres, self.travelled + seconds * self.speed)
        if self.travelled >= self.length_metres:
            self.status = 'arrived'
