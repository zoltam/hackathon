#!/usr/bin/env python3
"""Prepare the Valmet EGS boiler-room scan for the iOS demo (requires numpy)."""

from collections import Counter, deque
from pathlib import Path
import argparse
import json

import numpy as np

from scene_equipment import extract_equipment


# Similarity registration from the reviewed scan into Equipment Room.ply.
SOURCE_ROTATION = np.array([
    [.9998943, -.0008709, -.0145134],
    [.0009207, .9999937, .0034282],
    [.0145103, -.0034413, .9998888],
])
SOURCE_SCALE = 1.0362638
SOURCE_TRANSLATION = np.array([.170918, .066481, -.148239])
WORLD_AXES = np.array([1, -1, -1])



def prepare(source, destination, require_complete=False):
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
    keys = ('x', 'y', 'z', 'rot_0', 'rot_1', 'rot_2', 'rot_3', 'f_dc_0', 'f_dc_1', 'f_dc_2',
            'opacity', 'scale_0', 'scale_1', 'scale_2')
    if source.stat().st_size != offset + count * len(columns) * 4:
        raise ValueError('PLY payload size does not match the header')
    raw = np.memmap(source, dtype='<f4', mode='r', offset=offset, shape=(count, len(columns)))
    attributes = [columns.index(key) for key in keys]
    harmonics = [columns.index(f'f_rest_{i}') for i in range(45)]
    accepted = []
    for start in range(0, count, 32768):
        batch = raw[start:start + 32768]
        with np.errstate(invalid='ignore', over='ignore'):
            values = batch[:, attributes]
            valid = np.isfinite(batch).all(axis=1)
            valid &= (np.abs(values[:, :3]) < 1000).all(axis=1)
            valid &= (np.abs(np.linalg.norm(values[:, 3:7], axis=1) - 1) < .01)
            valid &= (np.abs(batch[:, harmonics]) < 10).all(axis=1)
            valid &= (np.abs(values[:, 7:]) < 40).all(axis=1)
        if valid.any():
            accepted.append(batch[valid][:, attributes + harmonics])
    if not accepted:
        raise ValueError('No valid EGS vertices')
    values = np.concatenate(accepted)
    rejected = count - len(values)
    print(f'{len(values):,}/{count:,} structurally valid vertices. Invalid: {rejected:,}.')
    if rejected:
        raise ValueError('Full scan requested, but some PLY records failed validation')

    registered = (values[:, :3] - SOURCE_TRANSLATION) @ SOURCE_ROTATION / SOURCE_SCALE
    xyz = registered * WORLD_AXES + [5, 1.07, -.7]
    navigation = values[:, 10] >= -2.2
    cell = .25
    grid = np.floor(xyz[:, [0, 2]] / cell).astype(int)
    shift = -grid.min(axis=0)
    grid += shift
    width, depth = (grid.max(axis=0) + 1).tolist()
    origin = np.array([shift[0] * cell, 0, shift[1] * cell])
    xyz += origin

    def counts(mask):
        return Counter(map(tuple, grid[mask & navigation].tolist()))

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

    # Preserve the reviewed approach and pick the nearest valid starting cell.
    service = tuple((shift + [21, 7]).tolist())
    if service not in buffered:
        raise ValueError('The mapped pump approach is not on the observed walkable floor')
    dist = distances(service, buffered)
    if len(dist) < 8:
        raise ValueError('No sufficiently large walkable floor at the pump approach')
    entrance = shift + [15, 0]
    start = min(dist, key=lambda p: ((p[0] - entrance[0]) ** 2 + (p[1] - entrance[1]) ** 2, p))
    opacity = 1 / (1 + np.exp(-values[:, 10]))
    model = {
        'name': 'Industrial Boiler Room',
        'width': width, 'depth': depth, 'cellSize': cell,
        'start': start, 'floor': sorted(dist),
        'originShift': origin.tolist(), 'shRotation': SOURCE_ROTATION.tolist(),
        'objects': extract_equipment(xyz, opacity, cell, service, origin),
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
    axes = rotation * np.exp(np.clip(values[:, 11:14], -16, 4))[..., None, :]
    source_to_world = SOURCE_ROTATION.T * WORLD_AXES[:, None] * WORLD_AXES / SOURCE_SCALE
    axes = source_to_world @ axes
    covariance = axes @ np.swapaxes(axes, 1, 2)
    rgb = .5 + .28209479 * values[:, 7:10]
    zero = np.zeros(len(values))
    fields = np.column_stack((
        xyz, opacity, rgb, zero,
        covariance[:, 0, 0], covariance[:, 0, 1], covariance[:, 0, 2], covariance[:, 1, 1],
        covariance[:, 1, 2], covariance[:, 2, 2], zero, zero,
    )).astype('<f4')
    # Four aligned float4 fields, followed by 45 channel-major SH
    # coefficients and 3 padding values stored as half floats.
    points = np.empty((len(values), 160), dtype=np.uint8)
    points[:, :64] = fields.view(np.uint8).reshape(len(values), 64)
    sh = np.zeros((len(values), 48), dtype='<f2')
    sh[:, :45] = values[:, 14:]
    points[:, 64:] = sh.view(np.uint8).reshape(len(values), 96)
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'site.json').write_text(json.dumps(model) + '\n', encoding='utf-8')
    points.tofile(destination / 'boiler-room-sh.splats')
    print(f'{len(model["objects"])} mapped assets, {len(points):,} Gaussian splats, {len(dist)} walkable cells, {dist[start]} route steps')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, default=Path('assets/valmet'))
    parser.add_argument('--require-complete', action='store_true',
                        help='Reject the source unless every declared vertex validates')
    args = parser.parse_args()
    try:
        prepare(args.source, args.output)
    except ValueError as error:
        parser.exit(1, f'{error}\n')
