#!/usr/bin/env python3
"""Append reviewed geometry-only observations to a registered local scene."""

import argparse
import json
import math
from pathlib import Path
from tempfile import NamedTemporaryFile


def valid_bounds(box):
    return (
        isinstance(box, list) and len(box) == 2
        and all(isinstance(p, list) and len(p) == 3 and all(
            type(v) in (int, float) and math.isfinite(v) for v in p
        ) for p in box)
        and all(lo < hi for lo, hi in zip(*box))
    )


def merge(site, observations):
    objects = site['objects']
    existing = {obj['objectId']: obj for obj in objects}
    if len(existing) != len(objects):
        raise ValueError('Duplicate registered scene object ID')
    additions = []
    seen = set()
    for obj in observations:
        key = obj.get('objectId')
        extraction = obj.get('extraction', {})
        if (
            not isinstance(key, str) or not key.strip() or key in seen
            or obj.get('geometryOnly') is not True or obj.get('detectorEnabled') is not False
            or obj.get('cells') != [] or obj.get('service') is not None
            or not valid_bounds(obj.get('bounds'))
            or ('extractionBounds' in obj and not valid_bounds(obj['extractionBounds']))
            or extraction.get('sourceSha256') != site['sourceSha256']
            or extraction.get('status') != 'reviewed'
        ):
            raise ValueError(f'Invalid reviewed observation {key!r}')
        seen.add(key)
        if key in existing:
            if existing[key] != obj:
                raise ValueError(f'Observation conflicts with registered object {key}')
        else:
            additions.append(obj)
    return dict(site, objects=[*objects, *additions])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--site', type=Path, required=True)
    parser.add_argument('--observations', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    site = json.loads(args.site.read_text())
    observations = json.loads(args.observations.read_text())
    merged = merge(site, observations)
    rendered = json.dumps(merged, ensure_ascii=False, allow_nan=False, indent=2) + '\n'
    with NamedTemporaryFile(mode='w', encoding='utf-8', dir=args.output.parent, delete=False) as tmp:
        tmp.write(rendered)
    Path(tmp.name).replace(args.output)
    print(f"Added {len(merged['objects']) - len(site['objects'])} observations. "
          f"{len(merged['objects'])} scene objects total.")


if __name__ == '__main__':
    main()
