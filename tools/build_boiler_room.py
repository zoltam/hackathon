#!/usr/bin/env python3
"""Prepare the Valmet EGS boiler-room scan for the iOS demo (requires numpy)."""

from collections import Counter, deque
from pathlib import Path
import argparse
import json
import hashlib
import sys

import numpy as np

from scene_equipment import REVIEWED_APPROACHES, extract_equipment, service_approach


# Similarity registration from the reviewed scan into Equipment Room.ply.
SOURCE_ROTATION = np.array([
    [.9998943, -.0008709, -.0145134],
    [.0009207, .9999937, .0034282],
    [.0145103, -.0034413, .9998888],
])
SOURCE_SCALE = 1.0362638
SOURCE_TRANSLATION = np.array([.170918, .066481, -.148239])
WORLD_AXES = np.array([1, -1, -1])


CELL_SIZE = .10
CAMERA_HEIGHT = 1.50
OBSTACLE_TOP = CAMERA_HEIGHT + .05

# Bounds reviewed against multiple renders in the registered frame before originShift.
# These objects provide scene context and have no classes in the released detector.
SURROUNDING_SEEDS = [
    ('floor-fan', 'Portable floor fan', 'fan', (8.37, .015, .27), (8.66, .46, .73)),
    ('floor-carton', 'Floor carton', 'carton', (7.96, .005, .86), (8.50, .355, 1.35)),
    ('blue-platform-trolley', 'Blue platform trolley', 'trolley', (7.77, .005, -.40), (8.45, .24, .37)),
    ('rolling-chair', 'Rolling chair', 'chair', (5.70, .005, .62), (6.58, .90, 1.36)),
    ('white-jerrycan', 'White jerrycan', 'container', (5.71, .005, 1.47), (5.97, .29, 1.71)),
    ('black-storage-bin', 'Black storage bin', 'bin', (7.75, .005, -1.78), (8.32, .54, -1.15)),
    ('rear-leaning-ladder', 'Rear leaning ladder', 'ladder', (7.865, 0.085, -2.465), (8.812, 1.506, -1.928)),
    ('short-step-ladder', 'Short step ladder', 'ladder', (7.753, 0.058, -1.892), (8.932, 1.254, -1.481)),
    ('tall-step-ladder', 'Tall step ladder', 'ladder', (7.793, 0.101, -1.381), (8.903, 1.475, -0.955)),
    ('front-leaning-ladder', 'Front leaning ladder', 'ladder', (8.056, 0.073, -0.893), (8.935, 1.309, -0.477)),
    ('black-shelf-cart', 'Black shelf cart', 'trolley', (7.635, 0.026, -0.972), (8.051, 1.046, -0.436)),
    ('silver-platform-cart', 'Silver platform cart', 'trolley', (7.013, 0.002, 1.022), (8.15, 0.872, 1.851)),
    ('yellow-wheel-hand-truck', 'Yellow-wheel hand truck', 'hand_truck', (6.349, 0.0, 1.073), (6.84, 1.085, 1.376)),
    ('red-wheel-hand-truck', 'Red-wheel hand truck', 'hand_truck', (5.899, 0.0, 1.272), (6.241, 0.982, 1.498)),
    ('black-hand-truck', 'Black hand truck', 'hand_truck', (5.865, 0.0, 2.01), (6.491, 1.103, 2.725)),
    ('green-chair', 'Green swivel chair', 'chair', (5.477, 0.0, -2.289), (6.105, 0.704, -1.57)),
    ('gray-cleaning-cart', 'Gray wheeled cleaning cart', 'cleaning_cart', (5.739, 0.0, -1.256), (6.501, 0.879, -0.904)),
    ('rear-red-vessel', 'Rear red pressure vessel', 'vessel', (5.545, 0.371, -3.152), (6.433, 1.445, -2.359)),
    ('doorway-blue-valve', 'Doorway blue inline valve', 'inline_valve', (5.515, 0.824, 2.385), (5.848, 1.033, 2.735)),
    ('front-red-vessel', 'Front red vessel', 'vessel', (4.779, 0.0, -3.087), (5.453, 1.407, -2.363)),
    ('orange-actuator-a', 'Orange actuator A', 'actuator', (4.399, 1.065, -2.418), (4.497, 1.230, -2.169)),
    ('orange-actuator-b', 'Orange actuator B', 'actuator', (4.544, 1.084, -2.383), (4.644, 1.249, -2.171)),
]


def extract_surroundings(xyz, opacity, cell, origin):
    objects = []
    for slug, name, kind, minimum, maximum in SURROUNDING_SEEDS:
        lo, hi = np.round(np.array([minimum, maximum]) + origin, 4)
        support = int(np.count_nonzero(
            ((xyz >= lo) & (xyz <= hi)).all(axis=1) & (opacity >= .12)))
        if support < 50:
            raise ValueError(f'Mapped object {slug} has insufficient scan evidence: {support} points')
        x, z = np.floor(lo[[0, 2]] / cell).astype(int).tolist()
        end_x, end_z = np.ceil(hi[[0, 2]] / cell).astype(int).tolist()
        objects.append({
            'objectId': f'boiler-room:{slug}',
            'name': name,
            'equipmentType': kind,
            'bounds': [lo.tolist(), hi.tolist()],
            'supportingSplats': support,
            'x': x,
            'z': z,
            'width': end_x - x,
            'depth': end_z - z,
            'height': float(hi[1]),
            'cells': [],
            'detectorEnabled': False,
        })
    return objects


def observed_floor(xyz, opacity_logits, grid, covariance=None):
    """Keep measured floor support; let the runtime planner apply radius clearance."""
    body = (xyz[:, 1] >= .17) & (xyz[:, 1] <= OBSTACLE_TOP) & (opacity_logits >= -2.2)
    floor = (np.abs(xyz[:, 1]) <= .12) & (opacity_logits >= np.log(.01 / .99))
    occupied = {p for p, n in Counter(map(tuple, grid[body].tolist())).items() if n >= 4}
    support = Counter(map(tuple, grid[floor].tolist()))
    # Sparse scan patches still need direct observations and nearby floor evidence.
    candidates = {p for p, n in support.items() if n >= 3 or (n >= 2 and
                  sum(support[(p[0] + dx, p[1] + dz)]
                      for dx in (-1, 0, 1) for dz in (-1, 0, 1)) >= 14)}
    if covariance is not None and floor.any():
        centres = xyz[floor][:, [0, 2]]
        cov = covariance[floor]
        xx, xz, zz = cov[:, 0, 0], cov[:, 0, 2], cov[:, 2, 2]
        determinant = xx * zz - xz * xz
        valid = determinant > 1e-12
        centres, xx, xz, zz, determinant = (
            values[valid] for values in (centres, xx, xz, zz, determinant))
        origins = np.floor(centres / CELL_SIZE).astype(int)
        shape = grid.max(axis=0) + 1
        footprints = np.zeros(tuple(shape), dtype=int)
        for dx in (-1, 0, 1):
            for dz in (-1, 0, 1):
                cells = origins + [dx, dz]
                delta = (cells + .5) * CELL_SIZE - centres
                distance = (zz * delta[:, 0] ** 2 - 2 * xz * delta[:, 0] * delta[:, 1] +
                            xx * delta[:, 1] ** 2) / determinant
                # Measured Gaussian footprints cover sparse gaps; never extrapolate beyond 12 cm.
                inside = (distance <= 4) & ((delta * delta).sum(axis=1) <= .12 ** 2)
                inside &= (cells >= 0).all(axis=1) & (cells < shape).all(axis=1)
                cells = cells[inside]
                np.add.at(footprints, (cells[:, 0], cells[:, 1]), 1)
        for p in map(tuple, np.argwhere(footprints >= 2).tolist()):
            if sum(support[(p[0] + dx, p[1] + dz)]
                   for dx in (-1, 0, 1) for dz in (-1, 0, 1)) >= 14:
                candidates.add(p)
    return candidates - occupied, occupied


def clearance_floor(floor, cell_size, radius):
    """Same circle-to-square clearance as Site._walkable, including unknown floor."""
    reach = int(np.ceil(radius / cell_size + .5))
    offsets = [(x, z) for x in range(-reach, reach + 1)
               for z in range(-reach, reach + 1)
               if (max(0, abs(x) - .5) * cell_size) ** 2 +
                  (max(0, abs(z) - .5) * cell_size) ** 2 < radius ** 2]
    return {p for p in floor if all((p[0] + x, p[1] + z) in floor for x, z in offsets)}


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
    # Keep the reviewed renderer/detector frame anchored to its original grid.
    coarse = np.floor(xyz[:, [0, 2]] / .25).astype(int)
    shift = -coarse.min(axis=0)
    origin = np.array([shift[0] * .25, 0, shift[1] * .25])
    xyz += origin
    cell = CELL_SIZE
    grid = np.floor(xyz[:, [0, 2]] / cell).astype(int)
    width, depth = (grid.max(axis=0) + 1).tolist()

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

    walkable, _ = observed_floor(xyz, values[:, 10], grid, covariance)

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
    service = tuple(np.floor((origin[[0, 2]] + [5.375, 1.875]) / cell).astype(int).tolist())
    if service not in walkable:
        raise ValueError('The mapped pump approach is not on the observed walkable floor')
    dist = distances(service, walkable)
    if len(dist) < 8:
        raise ValueError('No sufficiently large walkable floor at the pump approach')
    entrance = (origin[[0, 2]] + [3.875, .125]) / cell - .5
    safe = clearance_floor(walkable, cell, .10)
    safe_dist = distances(service, safe) if service in safe else {}
    if not safe_dist:
        raise ValueError("The pump approach lacks virtual-camera clearance")
    start = min(safe_dist, key=lambda p: ((p[0] - entrance[0]) ** 2 + (p[1] - entrance[1]) ** 2, p))
    opacity = 1 / (1 + np.exp(-values[:, 10]))
    equipment = extract_equipment(xyz, opacity, cell, service, origin)
    primary = equipment[0]
    # The runtime also blocks the reviewed primary pump's catalog footprint.
    primary_cells = {
        (x, z)
        for x in range(primary['x'], primary['x'] + primary['width'])
        for z in range(primary['z'], primary['z'] + primary['depth'])
    }
    route_floor = clearance_floor(walkable - primary_cells, cell, .10)
    if start not in route_floor:
        raise ValueError('The start lacks virtual-camera clearance')
    reachable = distances(start, route_floor)
    if service not in reachable:
        raise ValueError('The reviewed pump approach is unreachable')
    scan_points = xyz[opacity >= .12]
    for obj in equipment[1:]:
        if obj['equipmentType'] not in ('pump', 'valve'):
            continue
        reviewed = REVIEWED_APPROACHES.get(obj['objectId'])
        preferred = (tuple(np.floor((origin[[0, 2]] + reviewed) / cell).astype(int).tolist())
                     if reviewed is not None else None)
        approach = service_approach(obj['bounds'], reachable, scan_points, cell, CAMERA_HEIGHT, preferred)
        if approach is not None:
            obj['service'] = approach
        else:
            print(f'No reachable inspection viewpoint for {obj["name"]}', file=sys.stderr)
    model = {
        'name': 'Equipment Room',
        'sourceFile': source.name,
        'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'width': width, 'depth': depth, 'cellSize': cell,
        'start': start, 'floor': sorted(walkable),
        'floorMapping': {
            'method': 'observed_floor_without_body_height_obstacle_points',
            'floorBandMetres': .12, 'obstacleHeightMetres': [.17, OBSTACLE_TOP],
            'cameraHeightMetres': CAMERA_HEIGHT,
            'minimumFloorPoints': 2, 'denseFloorPoints': 3,
            'sparseFloorNeighbourhoodPoints': 14, 'minimumObstaclePoints': 4,
            'minimumFloorGaussianFootprints': 2, 'floorGaussianSigma': 2,
            'maximumFloorFootprintReachMetres': .12,
            'minimumFloorOpacity': .01,
            'allValidSplatsRetained': True,
            'minimumObstacleOpacity': float(1 / (1 + np.exp(2.2))),
            'importerMarginMetres': 0,
            'connectedCellsFromStart': len(dist),
            'disconnectedFloorCells': len(walkable - dist.keys()),
            'cameraRadiusMetres': .10,
            'clearanceCells': len(safe),
            'connectedClearanceCells': len(safe_dist),
        },
        'originShift': origin.tolist(), 'shRotation': SOURCE_ROTATION.tolist(),
        'primaryServiceObjectId': primary['objectId'],
        'objects': equipment + extract_surroundings(xyz, opacity, cell, origin),
    }

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
    print(f'{len(model["objects"])} mapped assets, {len(points):,} Gaussian splats, {len(walkable)} mapped floor cells ({len(dist)} connected), {dist[start]} route steps')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, default=Path('assets/valmet'))
    args = parser.parse_args()
    try:
        prepare(args.source, args.output)
    except ValueError as error:
        parser.exit(1, f'{error}\n')
