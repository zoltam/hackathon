#!/usr/bin/env python3
"""Prepare the Valmet EGS boiler-room scan for the iOS demo (requires numpy)."""

from collections import Counter, deque
from pathlib import Path
import argparse
import json
import hashlib

import numpy as np


def prepare(source, destination, *, full_scene=False, floor_y=1.07, name=None):
    with source.open('rb') as stream:
        header = []
        for line in stream:
            if line.strip() == b'end_header':
                break
            header.append(line.decode('ascii').strip())
        else:
            raise ValueError('Missing PLY header terminator')
        offset = stream.tell()
    if 'format binary_little_endian 1.0' not in header:
        raise ValueError('Expected a little-endian EGS PLY')
    count = int(next(line.split()[-1] for line in header if line.startswith('element vertex ')))
    columns = [line.split()[-1] for line in header if line.startswith('property float ')]
    raw = np.memmap(source, dtype='<f4', mode='r', offset=offset, shape=(count, len(columns)))
    keys = ('x', 'y', 'z', 'rot_0', 'rot_1', 'rot_2', 'rot_3', 'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity', 'scale_0', 'scale_1', 'scale_2')
    values = raw[:, [columns.index(key) for key in keys]]
    valid = np.isfinite(values).all(axis=1) & (np.abs(values) < 40).all(axis=1)
    values = values[valid]
    values = values[np.abs(np.linalg.norm(values[:, 3:7], axis=1) - 1) < .01]
    if not len(values):
        raise ValueError('No valid EGS vertices')
    # The original scan uses a reviewed crop. Updated scans can fit their own
    # navigation extent while keeping the full visible scene for rendering.
    cell = .25
    if not full_scene:
        crop = np.array([[-5.0, -1.55, -4.0], [4.0, 1.24, -.7]])
        values = values[((values[:, :3] >= crop[0]) & (values[:, :3] <= crop[1])).all(axis=1)]
    # Floor surfaces can have faint Gaussians even where the rendered passage
    # is continuous. Keep those observations for support, not as new free space.
    floor_points = values[(np.abs(floor_y - values[:, 1]) <= .12) &
                          (values[:, 10] >= np.log(.01 / .99)), :3]
    values = values[values[:, 10] >= -2.2]
    if not len(values):
        raise ValueError('No visible vertices in the selected scene extent')
    if full_scene:
        low, high = np.quantile(values[:, [0, 2]], [.005, .995], axis=0)
        origin_x = float(np.floor(low[0] / cell) * cell)
        origin_z = float(np.ceil(high[1] / cell) * cell)
        width = int(np.ceil((high[0] - origin_x) / cell))
        depth = int(np.ceil((origin_z - low[1]) / cell))
    else:
        origin_x, origin_z = -5.0, -.7
        width, depth = 36, 14
    if width * depth > 60000:
        raise ValueError('Navigation grid too large; review scene scale')
    x, y, z = values[:, :3].T
    xyz = np.stack((x - origin_x, floor_y - y, origin_z - z), axis=1)
    grid = np.floor(xyz[:, [0, 2]] / cell).astype(int)
    inside_grid = ((grid >= [0, 0]) & (grid < [width, depth])).all(axis=1)

    def counts(mask):
        return Counter(map(tuple, grid[mask & inside_grid].tolist()))

    occupied = {p for p, n in counts((xyz[:, 1] >= .17) & (xyz[:, 1] <= 1.8)).items() if n >= 20}
    floor_grid = np.floor(np.column_stack((floor_points[:, 0] - origin_x,
                                          origin_z - floor_points[:, 2])) / cell).astype(int)
    floor_inside = ((floor_grid >= [0, 0]) &
                    (floor_grid < [width, depth])).all(axis=1)
    floor_counts = Counter(map(tuple, floor_grid[floor_inside].tolist()))
    candidates = {p for p, n in floor_counts.items() if n >= 14}
    # Radius clearance belongs to the planner. Dilation here would apply it twice.
    walkable = candidates - occupied

    def adjacent(p):
        x, z = p
        return ((x-1,z),(x+1,z),(x,z-1),(x,z+1))

    def distances(start, allowed):
        queue = deque([start])
        distance = {start: 0}
        while queue:
            p = queue.popleft()
            for q in adjacent(p):
                if q in allowed and q not in distance:
                    distance[q] = distance[p] + 1
                    queue.append(q)
        return distance

    unseen = set(walkable)
    best = set()
    while unseen:
        region = set(distances(min(unseen), unseen))
        if len(region) > len(best):
            best = region
        unseen -= region
    if len(best) < 8:
        raise ValueError('No sufficiently large walkable floor in this scan')
    start = min(best, key=lambda p: (p[1], abs(p[0] - 12), p[0]))
    dist = distances(start, best)
    # Place the demo target at an observed structure near the route end.
    service, target = max(
        ((p, q) for p in best for q in occupied
         if abs(p[0]-q[0]) + abs(p[1]-q[1]) == 2),
        key=lambda pair: (dist[pair[0]], pair),
    )
    model = {
        'name': name or ('Industrial Boiler Room' if not full_scene else source.stem),
        'sourceFile': source.name,
        'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'sourceOrigin': [origin_x, floor_y, origin_z],
        'width': width, 'depth': depth, 'cellSize': cell,
        'start': start, 'floor': sorted(walkable),
        'floorMapping': {
            'method': 'observed_floor_without_body_height_obstacle_points',
            'floorBandMetres': .12, 'obstacleHeightMetres': [.17, 1.8],
            'minimumFloorPoints': 14, 'minimumObstaclePoints': 20,
            'minimumFloorOpacity': .01,
            'minimumRenderedOpacity': float(1 / (1 + np.exp(2.2))),
            'importerMarginMetres': 0,
            'connectedCellsFromStart': len(best),
            'disconnectedFloorCells': len(walkable - best),
        },
        'objects': [{
            'name': 'Inspection target', 'x': target[0], 'z': target[1],
            'width': 1, 'depth': 1, 'height': 1.2, 'service': service,
        }],
    }

    # Keep anisotropic Gaussian shape, opacity, and DC color for Metal.
    # Convert the quaternion's coordinate frame by rotating 180° around x.
    q = values[:, 3:7] * [1, 1, -1, -1]
    w, qx, qy, qz = q.T
    rotation = np.column_stack((
        1 - 2*(qy*qy + qz*qz), 2*(qx*qy - qz*w), 2*(qx*qz + qy*w),
        2*(qx*qy + qz*w), 1 - 2*(qx*qx + qz*qz), 2*(qy*qz - qx*w),
        2*(qx*qz - qy*w), 2*(qy*qz + qx*w), 1 - 2*(qx*qx + qy*qy),
    )).reshape(-1, 3, 3)
    axes = rotation * np.exp(np.clip(values[:, 11:14], -11, -1))[..., None, :]
    covariance = axes @ np.swapaxes(axes, 1, 2)
    rgb = np.clip(.5 + .28209479 * values[:, 7:10], 0, 1)
    opacity = 1 / (1 + np.exp(-values[:, 10]))
    zero = np.zeros(len(values))
    points = np.column_stack((
        xyz, opacity, rgb, zero,
        covariance[:, 0, 0], covariance[:, 0, 1], covariance[:, 0, 2], covariance[:, 1, 1],
        covariance[:, 1, 2], covariance[:, 2, 2], zero, zero,
    )).astype('<f4')
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'site.json').write_text(json.dumps(model) + '\n', encoding='utf-8')
    points.tofile(destination / 'boiler-room.splats')
    print(f'{len(points):,} Gaussian splats, {len(walkable)} mapped floor cells '
          f'({len(best)} connected), {dist[service]} route steps')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, default=Path('assets/valmet'))
    parser.add_argument('--full-scene', action='store_true',
                        help='Fit navigation bounds to this scan; do not use the old crop')
    parser.add_argument('--floor-y', type=float, default=1.07,
                        help='Source y-down floor elevation; review for each new scan')
    parser.add_argument('--name', help='Display name for the scene')
    args = parser.parse_args()
    if not np.isfinite(args.floor_y):
        parser.error('--floor-y must be finite')
    prepare(args.source, args.output, full_scene=args.full_scene,
            floor_y=args.floor_y, name=args.name)
