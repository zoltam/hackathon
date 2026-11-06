"""Reviewed seed volumes for the readable Valmet boiler-room scan."""

import numpy as np


# Bounds are model metres. Seeds were aligned to rendered views of the actual scan.
# Workbook identity and coordinates are deliberately separate from these objects.
SEEDS = [
    ("red-circulation-pump", "Red circulation pump", "pump", (5.77, 1.045, 2.27), (6.10, 1.32, 2.63)),
    ("middle-circulation-pump", "Middle circulation pump", "pump", (6.70, 1.04, 2.27), (7.03, 1.33, 2.57)),
    ("wall-circulation-pump", "Wall circulation pump", "pump", (7.32, 1.04, 2.34), (7.58, 1.28, 2.61)),
    ("far-circulation-pump", "Far circulation pump", "pump", (8.39, 1.04, 1.93), (8.75, 1.30, 2.15)),
    ("black-circulation-pump", "Black circulation pump", "pump", (8.32, 1.07, 1.03), (8.56, 1.30, 1.27)),
    ("blue-inline-valve", "Blue inline valve", "valve", (8.53, .83, 1.29), (8.76, 1.06, 1.56)),
    ("left-control-cabinet", "Left control cabinet", "control_cabinet", (8.50, .53, .14), (8.92, 1.79, .78)),
    ("right-control-cabinet", "Right control cabinet", "control_cabinet", (7.69, .79, 2.41), (8.42, 1.70, 2.76)),
    ("left-blue-actuator", "Left blue actuator", "actuator", (8.31, .59, .97), (8.53, .79, 1.15)),
    ("middle-blue-actuator", "Middle blue actuator", "actuator", (8.39, .60, 1.93), (8.63, .80, 2.14)),
    ("right-blue-actuator", "Right blue actuator", "actuator", (7.32, .58, 2.25), (7.53, .80, 2.54)),
]

# Registered viewpoints reviewed with the shipped detector.
REVIEWED_APPROACHES = {
    'boiler-room:far-circulation-pump': (7.85, .80),
    'boiler-room:black-circulation-pump': (7.35, .80),
}


def extract_equipment(xyz, opacity, cell, approach, origin):
    objects = []
    for index, (slug, label, equipment_type, minimum, maximum) in enumerate(SEEDS):
        lo, hi = np.array(minimum) + origin, np.array(maximum) + origin
        inside = ((xyz >= lo) & (xyz <= hi)).all(axis=1) & (opacity >= .12)
        points = xyz[inside]
        if len(points) < 50:
            raise ValueError(f'Mapped object {slug} has insufficient scan evidence: {len(points)} points')
        # Keep the primary pump's reviewed bounds identical to the volume used
        # for its reference images. Refine the other seeds with observed geometry.
        if index:
            qlo, qhi = np.quantile(points, [.015, .985], axis=0)
            lo, hi = np.maximum(lo, qlo - .025), np.minimum(hi, qhi + .025)
        lo, hi = np.round(lo, 4), np.round(hi, 4)
        x, z = np.floor(lo[[0, 2]] / cell).astype(int).tolist()
        end_x, end_z = np.ceil(hi[[0, 2]] / cell).astype(int).tolist()
        obj = {
            'objectId': f'boiler-room:{slug}',
            'name': label,
            'equipmentType': equipment_type,
            'bounds': [lo.tolist(), hi.tolist()],
            'supportingSplats': len(points),
            'x': x,
            'z': z,
            'width': end_x - x,
            'depth': end_z - z,
            'height': float(hi[1]),
        }
        if index == 0:
            obj['service'] = approach
        else:
            # Catalog bounds alone must not widen navigation obstacles.
            obj['cells'] = []
        objects.append(obj)
    return objects


def service_approach(bounds, reachable, scan_points, cell, camera_height, preferred=None):
    """Use a reviewed viewpoint if reachable, otherwise find the closest clear view."""
    lo, hi = np.array(bounds)
    target = (lo + hi) / 2
    target[1] = hi[1] * .9  # Same aim point as the scripted iOS journey.
    max_standoff, sight_radius = 2.0, .055
    margin = max_standoff + sight_radius
    local = scan_points[((scan_points >= lo - margin) & (scan_points <= hi + margin)).all(axis=1)]
    blockers = local[~((local >= lo) & (local <= hi)).all(axis=1)]
    candidates = []
    for p, steps in reachable.items():
        eye = np.array([(p[0] + .5) * cell, camera_height, (p[1] + .5) * cell])
        gap = np.maximum(np.maximum(lo - eye, eye - hi), 0)[[0, 2]]
        distance_squared = gap @ gap
        if 0 < distance_squared <= max_standoff ** 2:
            candidates.append((p != preferred, distance_squared, steps, p, eye))
    # ponytail: screen dense clusters of splat centres; use rendered depth for precise occlusion.
    for _, _, _, p, eye in sorted(candidates):
        ray = target - eye
        relative = blockers - eye
        along = np.einsum('ij,j->i', relative, ray) / (ray @ ray)
        offset = relative - along[:, None] * ray
        hits = along[(along > 0) & (along < 1) & ((offset * offset).sum(axis=1) < sight_radius ** 2)]
        bins = (hits * np.linalg.norm(ray) / cell).astype(int)
        if np.bincount(bins).max(initial=0) < 4:
            return p
    return None
