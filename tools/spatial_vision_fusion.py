"""Fit seed-independent 3D proposals from posed RGB detections and registered splats."""
import argparse
from itertools import combinations
import json
from pathlib import Path

import numpy as np

from spatial_catalog import _components
from spatial_scene import load_geometry, write_json


def unit(vector):
    return vector / np.linalg.norm(vector)


def camera(view):
    eye = np.asarray(view['eye'], dtype=float)
    forward = unit(np.asarray(view['lookAt']) - eye)
    right = unit(np.cross(forward, [0, 1, 0]))
    return eye, np.array([right, np.cross(right, forward), forward])


def fit(observations, cloud, focal, confidence_floor, minimum_anchors):
    if len(observations) < 3:
        return None
    eyes, bases, boxes, confidence = map(np.asarray, zip(*observations))
    directions = np.array([
        unit(np.r_[((2 * box[:2] + box[2:] - 1) / focal), 1] @ basis)
        for box, basis in zip(boxes, bases)
    ])
    best = None
    for i, j in combinations(range(len(eyes)), 2):
        if directions[i] @ directions[j] > .985:
            continue
        axes = np.array([directions[i], -directions[j]]).T
        distances = np.linalg.lstsq(axes, eyes[j] - eyes[i], rcond=None)[0]
        if not ((.35 <= distances) & (distances <= 9)).all():
            continue
        a, b = eyes[[i, j]] + distances[:, None] * directions[[i, j]]
        if np.linalg.norm(a - b) > .20:
            continue
        center = (a + b) / 2
        if not .16 < center[1] < 2.8:
            continue
        delta = center - eyes
        depth = np.einsum('ij,ij->i', delta, directions)
        residual = np.linalg.norm(delta - depth[:, None] * directions, axis=1)
        inliers = (depth > .35) & (residual < .19)
        if (inliers & (confidence >= confidence_floor)).sum() < minimum_anchors:
            continue
        score = (int(inliers.sum()), float((confidence[inliers] * (1 - residual[inliers] / .19)).sum()))
        if best is None or score > best[0]:
            best = score, center, inliers
    if best is None or best[0][0] < max(3, (len(eyes) + 1) // 2):
        return None

    _, center, inliers = best
    distances = np.linalg.norm(center - eyes[inliers], axis=1)
    radius = np.clip(np.median((boxes[inliers, 2:] / focal).max(axis=1) * distances * 1.25), .20, 1.10)
    nearby = np.flatnonzero((np.abs(cloud - center) < radius).all(axis=1))
    points = cloud[nearby]
    votes = np.zeros(len(points), dtype=int)
    for eye, basis, box in zip(eyes[inliers], bases[inliers], boxes[inliers]):
        q = (points - eye) @ basis.T
        screen = .5 + .5 * q[:, :2] * focal / np.maximum(.01, q[:, 2:3])
        inside = ((box[:2] <= screen) & (screen <= box[:2] + box[2:])).all(axis=1)
        votes += (q[:, 2] > .04) & inside
    members = votes >= max(3, int(np.ceil(inliers.sum() * .70)))
    support = points[members]
    if len(support) < 50:
        return None
    bounds = np.quantile(support, [.01, .99], axis=0)
    if np.ptp(bounds, axis=0).min() < .025:
        return None
    # Keep a small margin around splat centres for their rendered extent.
    bounds += np.array([[-.015], [.015]])
    return (dict(bounds=bounds.tolist(), observations=len(eyes),
                 inliers=int(inliers.sum()), supportingSplats=len(support),
                 strongInliers=int((inliers & (confidence >= confidence_floor)).sum())), nearby[members])


def proposals(views, predictions, thresholds, geometry, focal, memberships=None):
    cameras = {Path(view['output']).name: camera(view) for view in views}
    by_label = {}
    for line in predictions:
        marker, name, label, score, *box = line.split()
        if marker != 'BOX' or len(box) != 4:
            raise ValueError('Expected BOX frame objectId confidence x y width height')
        score = float(score)
        floor = thresholds.get(label, .25)
        if score < min(floor, max(.50, floor * .65)):
            continue
        eye, basis = cameras[name]
        # Several headings from one camera location are one spatial observation.
        positions = by_label.setdefault(label, {})
        key = tuple(eye)
        if key not in positions or score > positions[key][3]:
            positions[key] = (eye, basis, list(map(float, box)), score)
    centers = geometry['centers']
    # Keep low equipment while excluding the floor plane itself.
    source_indices = np.flatnonzero((geometry['opacities'] >= .12) & (centers[:, 1] > .035))
    cloud = centers[source_indices]
    result = {}
    for label, positions in sorted(by_label.items()):
        floor = thresholds.get(label, .25)
        observations = list(positions.values())
        strong = [obs for obs in observations if obs[3] >= floor]
        candidate = fit(strong, cloud, focal, floor, 3)
        tier = 'strict'
        if candidate is None and len(strong) >= 2 and len(observations) >= 5:
            candidate = fit(observations, cloud, focal, floor, 2)
            if candidate is not None and candidate[0]['inliers'] < 5:
                candidate = None
            tier = 'corroborated'
        if candidate is not None:
            result[label], indices = candidate
            result[label]['confidenceTier'] = tier
            if memberships is not None:
                memberships[label] = source_indices[indices]
    return result


def apply_approved(site, proposal_set, approved_ids, members, source_count):
    """Replace display geometry only. Keep routing and detector registration intact."""
    if site['sourceSha256'] != proposal_set['sourceSha256']:
        raise ValueError('Vision proposals belong to a different source scan')
    candidates = proposal_set['candidates']
    registered = {obj['objectId'] for obj in site['objects']}
    if not set(approved_ids) <= registered & candidates.keys() & members.keys():
        raise ValueError('Approved ID is missing from the catalog, fit or membership')
    objects = []
    for obj in site['objects']:
        label = obj['objectId']
        if label in approved_ids:
            candidate = candidates[label]
            points = members[label]
            bounds = np.asarray(candidate['bounds'])
            if (bounds.shape != (2, 3) or not np.isfinite(bounds).all()
                    or not (bounds[0] < bounds[1]).all()
                    or points.ndim != 1 or points.dtype.kind not in 'iu'
                    or len(points) < 50 or len(points) != candidate['supportingSplats']
                    or points.min() < 0 or points.max() >= source_count
                    or np.any(points[1:] <= points[:-1])):
                raise ValueError(f'Invalid approved vision fit for {label}')
            obj = dict(obj, extractionBounds=bounds.tolist(), extraction={
                'method': proposal_set['method'], 'sourceSha256': site['sourceSha256'],
                'membership': f'memberships.npz:{label}', 'status': 'fitted',
                **{key: candidate[key] for key in (
                    'supportingSplats', 'inliers', 'strongInliers', 'confidenceTier')},
            })
            if 'refinement' in candidate:
                obj['extraction']['refinement'] = candidate['refinement']
        objects.append(obj)
    return dict(site, objects=objects)


def expand_chromatic_support(candidate, members, geometry):
    """Recover contiguous coloured surfaces missed by partially occluded RGB boxes."""
    centers, rgb, opacity = (geometry[k] for k in ('centers', 'rgbs', 'opacities'))
    colors = rgb[members]
    saturated = colors[np.ptp(colors, axis=1) > .08]
    if len(saturated) < 50:
        return candidate, members
    channels = np.bincount(saturated.argmax(axis=1), minlength=3)
    channel = channels.argmax()
    if channels[channel] < .85 * len(saturated):
        return candidate, members
    lo, hi = np.asarray(candidate['bounds'])
    in_window = ((centers >= lo - .35) & (centers <= hi + .35)).all(axis=1)
    chosen = np.flatnonzero(in_window & (opacity >= .12) & (centers[:, 1] > .035))
    colors = rgb[chosen]
    dominant = colors[:, channel] - np.delete(colors, channel, axis=1).max(axis=1)
    chosen = chosen[dominant > .08]
    cells, inverse = np.unique(np.floor(centers[chosen] / .035).astype(int),
                               axis=0, return_inverse=True)
    lookup = {tuple(cell): i for i, cell in enumerate(cells)}
    best_support, best = 0, None
    for component in _components(cells):
        indices = chosen[np.isin(inverse, [lookup[cell] for cell in component])]
        support = np.intersect1d(indices, members, assume_unique=True).size
        if support > best_support:
            best_support, best = support, indices
    if best_support < .40 * len(members):
        return candidate, members
    expanded = np.union1d(members, best)
    if len(expanded) == len(members):
        return candidate, members
    bounds = np.quantile(centers[expanded], [.01, .99], axis=0) + np.array([[-.015], [.015]])
    return dict(candidate, bounds=bounds.tolist(), supportingSplats=len(expanded),
                refinement='connected_dominant_chromatic_splats'), expanded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, default=Path('assets/valmet'))
    parser.add_argument('--shots', type=Path, required=True)
    parser.add_argument('--predictions', type=Path, required=True)
    parser.add_argument('--thresholds', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--memberships', type=Path)
    parser.add_argument('--grow-color', action='append', default=[])
    parser.add_argument('--focal', type=float, nargs=2, default=[1.35 * 1080 / 1920, 1.35])
    args = parser.parse_args()
    if not all(np.isfinite(x) and x > 0 for x in args.focal):
        parser.error('Focal scales must be finite and positive')
    geometry = load_geometry(args.assets)
    memberships = {} if args.memberships is not None or args.grow_color else None
    with args.predictions.open() as predictions:
        result = proposals(json.loads(args.shots.read_text()), predictions,
                           json.loads(args.thresholds.read_text()), geometry, np.array(args.focal), memberships)
    for label in args.grow_color:
        if label not in result:
            parser.error(f'Cannot refine a missing proposal: {label}')
        result[label], memberships[label] = expand_chromatic_support(result[label], memberships[label], geometry)
    write_json(args.output, dict(sourceSha256=geometry['sourceSha256'],
                                method='rgb_ray_consensus_splat_vote', candidates=result))
    if args.memberships is not None:
        np.savez_compressed(args.memberships, **memberships)
    print(f'{len(result)} seed-independent 3D proposals')


if __name__ == '__main__':
    main()
