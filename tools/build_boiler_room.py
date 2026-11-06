#!/usr/bin/env python3
"""Prepare the Valmet EGS boiler-room scan for the iOS demo (requires numpy)."""

from collections import Counter, deque
from pathlib import Path
import argparse
import json

import numpy as np


def prepare(source, destination):
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
    # The supplied EGS scan uses y down, with the main floor near y=1.07.
    crop = np.array([[-5.0, -1.55, -4.0], [4.0, 1.24, -.7]])
    values = values[((values[:, :3] >= crop[0]) & (values[:, :3] <= crop[1])).all(axis=1)]
    values = values[values[:, 10] >= -2.2]
    x, y, z = values[:, :3].T
    xyz = np.stack((x + 5, 1.07 - y, -.7 - z), axis=1)
    cell = .25
    width, depth = 36, 14
    grid = np.floor(xyz[:, [0, 2]] / cell).astype(int)
    grid = np.clip(grid, [0, 0], [width - 1, depth - 1])

    def counts(mask):
        return Counter(map(tuple, grid[mask].tolist()))

    occupied = {p for p, n in counts((xyz[:, 1] >= .17) & (xyz[:, 1] <= 1.8)).items() if n >= 20}
    # Add a small horizontal margin around dense obstacle points.
    close = {p for p, n in counts((xyz[:, 1] >= .17) & (xyz[:, 1] <= 1.8)).items() if n >= 55}
    candidates = {p for p, n in counts(np.abs(xyz[:, 1]) <= .12).items() if n >= 14}
    walkable = candidates - occupied
    nearby = set()
    for x, z in close:
        nearby.update(((x-1,z),(x+1,z),(x,z-1),(x,z+1)))
    buffered = walkable - nearby

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

    unseen = set(buffered)
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
        'name': 'Industrial Boiler Room',
        'width': width, 'depth': depth, 'cellSize': cell,
        'start': start, 'floor': sorted(best),
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
    print(f'{len(points):,} Gaussian splats, {len(best)} walkable cells, {dist[service]} route steps')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, default=Path('assets/valmet'))
    args = parser.parse_args()
    prepare(args.source, args.output)
