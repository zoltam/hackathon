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


def extract_equipment(xyz, opacity, cell, approach):
    objects = []
    for index, (slug, label, equipment_type, minimum, maximum) in enumerate(SEEDS):
        lo, hi = np.array(minimum), np.array(maximum)
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
