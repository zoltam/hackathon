"""Deterministic geometric proposals and explicit, persistent asset review.

Proposals are not semantic predictions. Plane removal affects proposals only;
the caller must retain the complete scan for collision and floor processing.
"""
from copy import deepcopy
import hashlib
import json
from pathlib import Path

import numpy as np


def _identity(indices):
    return 'proposal:' + hashlib.sha256(np.asarray(indices, dtype='<i8').tobytes()).hexdigest()[:16]


def _components(voxels):
    unseen = set(map(tuple, voxels.tolist()))
    offsets = [(x, y, z) for x in (-1, 0, 1) for y in (-1, 0, 1)
               for z in (-1, 0, 1) if (x, y, z) != (0, 0, 0)]
    for seed in sorted(unseen):
        if seed not in unseen:
            continue
        unseen.remove(seed)
        group, stack = [seed], [seed]
        while stack:
            point = stack.pop()
            for offset in offsets:
                neighbor = tuple(point[i] + offset[i] for i in range(3))
                if neighbor in unseen:
                    unseen.remove(neighbor)
                    group.append(neighbor)
                    stack.append(neighbor)
        yield group


def _wall_mask(points):
    """Conservative dominant axis-aligned wall slabs, not equipment planes."""
    mask = np.zeros(len(points), dtype=bool)
    if len(points) < 200:
        return mask
    for axis in (0, 2):
        bins = np.floor(points[:, axis] / .08).astype(np.int64)
        keys, counts = np.unique(bins, return_counts=True)
        threshold = max(200, int(np.median(counts) * 4))
        side = 2 if axis == 0 else 0
        low, high = np.quantile(points[:, axis], [.05, .95])
        for key in keys[counts >= threshold]:
            center = (key + .5) * .08
            if low < center < high:
                continue
            selected = bins == key
            extent = np.ptp(points[selected], axis=0)
            if extent[1] >= 1.5 and extent[side] >= 2:
                mask |= selected
    return mask


class CatalogReview:
    def __init__(self, site, geometry, output):
        self.site = deepcopy(site)
        self.geometry = geometry
        self.output = Path(output)
        self.points = np.asarray(geometry['centers'])
        self.opacity = np.asarray(geometry['opacities'])
        if geometry.get('sourceSha256', site.get('sourceSha256')) != site.get('sourceSha256'):
            raise ValueError('Geometry and catalog refer to different source scans')
        if self.points.ndim != 2 or self.points.shape[1] != 3 or self.opacity.shape != (len(self.points),):
            raise ValueError('Expected Nx3 centers and N opacities')
        self.candidates, self.memberships, self.decisions = {}, {}, {}
        self.operations = []
        self.baseline = {o['objectId']: deepcopy(o) for o in site['objects']}
        available = np.isfinite(self.points).all(axis=1) & np.isfinite(self.opacity) & (self.opacity >= .12)
        valid = available.copy()
        for object_id, obj in self.baseline.items():
            lo, hi = np.asarray(obj['bounds'])
            inside = valid & ((self.points >= lo) & (self.points <= hi)).all(axis=1)
            self.memberships[object_id] = np.flatnonzero(inside)
            available &= ~inside
        available &= self.points[:, 1] > .15
        indices = np.flatnonzero(available)
        available[indices[_wall_mask(self.points[indices])]] = False
        self.proposal_exclusions = {'floorHeightMetres': .15, 'minimumOpacity': .12,
                                   'wallMethod': 'outer_dominant_axis_aligned_8cm_slabs'}
        indices = np.flatnonzero(available)
        existing = []
        for resolution in (.04, .08):
            if not len(indices):
                break
            cells, inverse = np.unique(np.floor(self.points[indices] / resolution).astype(np.int64),
                                       axis=0, return_inverse=True)
            lookup = {tuple(cell): i for i, cell in enumerate(cells)}
            order = np.argsort(inverse, kind='stable')
            boundaries = np.r_[0, np.cumsum(np.bincount(inverse))]
            for component in _components(cells):
                members = np.sort(np.concatenate([indices[order[boundaries[lookup[c]]:boundaries[lookup[c]+1]]]
                                                   for c in component]))
                if len(members) < 50:
                    continue
                extent = np.ptp(self.points[members], axis=0)
                if extent.max() > 3 or np.count_nonzero(extent > .03) < 2:
                    continue
                if any(len(np.intersect1d(members, previous, assume_unique=True)) /
                       min(len(members), len(previous)) >= .8 for previous in existing):
                    continue
                self._add(members, f'{int(resolution*100)}cm_voxel_26_connected')
                existing.append(members)
        state = self.output / 'review.json'
        if state.exists():
            saved = json.loads(state.read_text())
            if saved.get('sourceSha256') != site.get('sourceSha256'):
                raise ValueError('Review belongs to a different source scan')
            self._replaying = True
            for operation in saved.get('operations', []):
                if operation['kind'] == 'merge':
                    self.merge(operation['ids'], operation['name'])
                elif operation['kind'] == 'refine':
                    self.refine_bounds(operation['id'], operation['lo'], operation['hi'],
                                       operation.get('reviewer', 'manual_review'))
                else:
                    self.split(operation['id'], operation['axis'], operation['position'])
            self.decisions = saved.get('decisions', {})
            self._replaying = False
            for object_id in self.decisions:
                if object_id not in self.candidates:
                    raise ValueError(f'Review refers to missing candidate {object_id}')

    def _add(self, indices, method):
        indices = np.unique(indices).astype(np.int64)
        object_id = _identity(indices)
        lo, hi = self.points[indices].min(axis=0), self.points[indices].max(axis=0)
        cell = self.site['cellSize']
        x, z = np.floor(lo[[0, 2]] / cell).astype(int)
        end_x, end_z = np.ceil(hi[[0, 2]] / cell).astype(int)
        self.memberships[object_id] = indices
        self.candidates[object_id] = {
            'objectId': object_id, 'name': 'Unclassified geometric proposal',
            'equipmentType': 'context', 'bounds': [lo.tolist(), hi.tolist()],
            'supportingSplats': len(indices), 'x': int(x), 'z': int(z),
            'width': max(1, int(end_x-x)), 'depth': max(1, int(end_z-z)),
            'height': float(hi[1]), 'cells': [], 'detectorEnabled': False,
            'extraction': {'method': method, 'sourceSha256': self.site.get('sourceSha256'),
                           'membership': f'memberships.npz:{object_id}'},
        }
        return object_id

    @property
    def accepted_objects(self):
        return list(deepcopy(self.baseline).values()) + [
            dict(deepcopy(self.candidates[k]), name=d['name'], equipmentType=d['equipmentType'])
            for k, d in sorted(self.decisions.items()) if d.get('status') == 'accepted']

    def record_view(self, object_id, camera_position):
        obj = self.candidates[object_id]
        camera = np.asarray(camera_position, dtype=float)
        center = np.mean(obj['bounds'], axis=0)
        if camera.shape != (3,) or not np.isfinite(camera).all() or np.linalg.norm(camera-center) < .01:
            raise ValueError('View camera must be finite and outside the asset center')
        decision = self.decisions.setdefault(object_id, {})
        views = decision.setdefault('views', [])
        if camera.tolist() not in views:
            views.append(camera.tolist())
        self.export()

    def accept(self, object_id, name, equipment_type='context'):
        obj = self.candidates[object_id]
        if not isinstance(name, str) or not name.strip() or not isinstance(equipment_type, str) or not equipment_type.strip():
            raise ValueError('Accepted asset needs a name and equipment type')
        members = self.memberships[object_id]
        if len(members) < 50:
            raise ValueError('Accepted asset needs at least 50 supporting splats')
        decision = self.decisions.setdefault(object_id, {})
        center = np.mean(obj['bounds'], axis=0)
        directions = np.asarray(decision.get('views', []), dtype=float).reshape(-1, 3)-center
        if len(directions) < 2:
            raise ValueError('Review needs two recorded camera directions')
        directions /= np.linalg.norm(directions, axis=1, keepdims=True)
        if np.min(directions @ directions.T) > np.cos(np.deg2rad(30)):
            raise ValueError('Review camera directions must differ by at least 30 degrees')
        approved = [k for k, d in self.decisions.items() if d.get('status') == 'accepted' and k != object_id]
        for other in list(self.baseline) + approved:
            if np.intersect1d(members, self.memberships[other], assume_unique=True).size:
                raise ValueError(f'Asset shares splats with accepted instance {other}')
        decision.update(status='accepted', name=name.strip(), equipmentType=equipment_type.strip())
        self.export()

    def reject(self, object_id):
        self.candidates[object_id]
        self.decisions.setdefault(object_id, {}).update(status='rejected')
        self.export()

    def rename(self, object_id, name):
        self.candidates[object_id]
        if not isinstance(name, str) or not name.strip():
            raise ValueError('Asset name must not be empty')
        self.decisions.setdefault(object_id, {})['name'] = name.strip()
        self.export()

    def merge(self, ids, name):
        ids = sorted(set(ids))
        if len(ids) < 2 or any(k not in self.candidates for k in ids):
            raise ValueError('Merge needs at least two proposal IDs')
        if not isinstance(name, str) or not name.strip():
            raise ValueError('Merged asset name must not be empty')
        new = self._add(np.concatenate([self.memberships[k] for k in ids]), 'reviewed_merge')
        if new in ids:
            raise ValueError('Merge does not add a distinct instance')
        for key in ids:
            self.decisions.setdefault(key, {}).update(status='superseded')
        self.decisions[new] = {'name': name, 'status': 'pending'}
        self.operations.append({'kind': 'merge', 'ids': ids, 'name': name})
        self.export()
        return new

    def split(self, object_id, axis, position):
        self.candidates[object_id]
        if axis not in (0, 1, 2) or not np.isfinite(position):
            raise ValueError('Split requires axis 0, 1 or 2 and finite position')
        indices = self.memberships[object_id]
        mask = self.points[indices, axis] < position
        if min(mask.sum(), (~mask).sum()) < 50:
            raise ValueError('Each split asset needs at least 50 supporting splats')
        ids = [self._add(group, 'reviewed_split') for group in (indices[mask], indices[~mask])]
        self.decisions.setdefault(object_id, {}).update(status='superseded')
        self.operations.append({'kind': 'split', 'id': object_id, 'axis': axis, 'position': float(position)})
        self.export()
        return ids

    def refine_bounds(self, object_id, lo, hi, reviewer='manual_review'):
        """Replace a proposal with an explicitly reviewed source-space crop.

        The crop can include floor pixels and is not an automatic semantic mask;
        inspect its source renders before accepting it as a complete instance.
        """
        previous = self.candidates[object_id]
        lo, hi = np.asarray(lo, dtype=float), np.asarray(hi, dtype=float)
        if lo.shape != (3,) or hi.shape != (3,) or not np.isfinite([lo, hi]).all() or not (hi > lo).all():
            raise ValueError('Refined bounds must be finite ordered XYZ corners')
        if not isinstance(reviewer, str) or not reviewer.strip():
            raise ValueError('Refinement needs a reviewer label')
        selected = (np.isfinite(self.points).all(axis=1) & np.isfinite(self.opacity) &
                    (self.opacity >= .12) & ((self.points >= lo) & (self.points <= hi)).all(axis=1))
        for key in self.baseline:
            selected[self.memberships[key]] = False
        members = np.flatnonzero(selected)
        if len(members) < 50:
            raise ValueError('Refined asset needs at least 50 supporting splats')
        new = self._add(members, 'reviewed_source_crop')
        self.candidates[new]['extraction'].update(
            reviewedBounds=[lo.tolist(), hi.tolist()], reviewer=reviewer.strip(),
            parentProposal=object_id)
        label = self.decisions.get(object_id, {}).get('name', previous['name'])
        if not isinstance(label, str) or not label.strip():
            raise ValueError('Refined asset needs a nonempty label')
        if new != object_id:
            self.decisions.setdefault(object_id, {}).update(status='superseded')
        self.decisions[new] = {'status': 'pending', 'name': label.strip(), 'views': []}
        self.operations.append({'kind': 'refine', 'id': object_id, 'lo': lo.tolist(),
                                'hi': hi.tolist(), 'reviewer': reviewer.strip()})
        self.export()
        return new

    def export(self):
        if getattr(self, '_replaying', False):
            return dict(self.site, objects=self.accepted_objects)
        self.output.mkdir(parents=True, exist_ok=True)
        payload = {'schemaVersion': 1, 'sourceSha256': self.site.get('sourceSha256'),
                   'proposalExclusions': self.proposal_exclusions, 'operations': self.operations,
                   'decisions': self.decisions, 'candidates': list(self.candidates.values())}
        (self.output / 'review.json').write_text(json.dumps(payload, indent=2, allow_nan=False)+'\n')
        np.savez_compressed(self.output / 'memberships.npz', **self.memberships)
        site = dict(self.site, objects=self.accepted_objects)
        (self.output / 'site.json').write_text(json.dumps(site, allow_nan=False)+'\n')
        return site
