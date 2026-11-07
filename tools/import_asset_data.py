#!/usr/bin/env python3
"""Export the supplied workbook and synthetic scene mapping for Flutter.

Requires openpyxl. Source workbook and generated output must remain local.
"""
import argparse
from collections import defaultdict, deque
from datetime import date, datetime
import hashlib
import json
from pathlib import Path

from openpyxl import load_workbook

SHEETS = (
    'Asset_Master', 'Current_State', 'Telemetry_Sample_3d', 'Alarms_Events',
    'Maintenance_History', 'Historical_Service_Cases', 'Knowledge_Docs',
    'Data_Quality',
)
ASSET_CLASS_BY_EQUIPMENT_TYPE = {
    'pump': 'PROCESS_PUMP',
    'valve': 'CONTROL_VALVE',
    'valve_actuator': 'CONTROL_VALVE',
}
REVIEWED_ASSET_CLASS_BY_EQUIPMENT_TYPE = {
    **ASSET_CLASS_BY_EQUIPMENT_TYPE,
    'inline_valve': 'CONTROL_VALVE',
    'motor': 'ELECTRIC_MOTOR',
    'pressure_transmitter': 'PRESSURE_TRANSMITTER',
    'vibration_sensor': 'VIBRATION_SENSOR',
}


def object_id(obj):
    return obj.get('objectId') or obj.get('object_id') or 'grid:{x}:{z}:{width}:{depth}'.format(**obj)


def read_reviewed_tags(path):
    tags = json.loads(path.read_text())
    if not isinstance(tags, dict) or any(not isinstance(tag, str) or not tag for tag in tags.values()):
        raise ValueError('Reviewed tags must map scene object IDs to workbook tags')
    return tags


def export(workbook, site, mappings=None, *, include_nearby=False, reviewed_tags=None):
    book = load_workbook(workbook, read_only=True, data_only=True)
    tables = {}
    try:
        for name in SHEETS:
            rows = iter(book[name].values)
            headers = next(rows)
            records = []
            for row_number, values in enumerate(rows, 2):
                if not any(v is not None for v in values):
                    continue
                record = dict(zip(headers, values))
                for key, value in record.items():
                    if isinstance(value, (date, datetime)):
                        record[key] = value.isoformat()
                record['_source'] = f'{name}!{row_number}'
                records.append(record)
            tables[name] = records
    finally:
        book.close()

    assets = {r['asset_id']: r for r in tables['Asset_Master']}
    if len(assets) != len(tables['Asset_Master']):
        raise ValueError('Duplicate workbook asset IDs')
    if reviewed_tags is not None:
        if mappings is not None:
            raise ValueError('Supply workbook asset IDs or reviewed tags, not both')
        by_tag = defaultdict(list)
        for asset_id, asset in assets.items():
            by_tag[asset.get('tag')].append(asset_id)
        mappings = {}
        for scene_id, tag in reviewed_tags.items():
            matches = by_tag[tag]
            if len(matches) != 1:
                raise ValueError(f'Expected one workbook asset with tag {tag}')
            mappings[scene_id] = matches[0]
    states = {r['asset_id']: r for r in tables['Current_State']}
    if len(states) != len(tables['Current_State']):
        raise ValueError('Duplicate current states')
    for name in ('Current_State', 'Telemetry_Sample_3d', 'Alarms_Events',
                 'Maintenance_History', 'Data_Quality'):
        for row in tables[name]:
            if row['asset_id'] not in assets:
                raise ValueError(f"Unknown asset at {row['_source']}")

    primary_service_id = site.get('primaryServiceObjectId')
    equipment = [o for o in site['objects'] if not o.get('geometryOnly')]
    objects = sorted((o for o in equipment if o.get('service') is not None),
                     key=lambda o: (object_id(o) != primary_service_id, object_id(o)))
    if include_nearby:
        # Keep the service target and existing detector catalog assignments stable.
        nearby = (o for o in equipment if o.get('service') is None)
        objects += sorted(nearby, key=lambda o: (o.get('detectorEnabled') is False, object_id(o)))
    ids = [object_id(o) for o in objects]
    if len(set(ids)) != len(ids):
        raise ValueError('Mapped scene objects need unique object_id values')
    mapping_method = 'synthetic_class_ranked' if mappings is None else 'synthetic_explicit'
    if mappings is None:
        # Prioritize service targets and rank only within compatible workbook classes.
        by_class = defaultdict(deque)
        ranked = sorted(states, key=lambda a: (
            states[a].get('health_score', 101), a))
        for asset_id in ranked:
            by_class[assets[asset_id].get('asset_class')].append(asset_id)
        mappings = {}
        for obj in objects:
            asset_class = ASSET_CLASS_BY_EQUIPMENT_TYPE.get(obj.get('equipmentType'))
            if not asset_class or not by_class[asset_class]:
                continue
            available = by_class[asset_class]
            if obj.get('service') is not None:
                asset_id = available.popleft()
            else:
                # Nearby synthetic records illustrate normal operation first.
                asset_id = max(available, key=lambda a: states[a].get('health_score', 101))
                available.remove(asset_id)
            mappings[object_id(obj)] = asset_id
    if set(mappings) - set(ids):
        raise ValueError('Mapping contains scene objects outside the selected mapping scope')
    if set(mappings.values()) - assets.keys():
        raise ValueError('Mapping contains unknown workbook assets')
    if len(set(mappings.values())) != len(mappings):
        raise ValueError('Mapping must be one-to-one')
    for obj, scene_id in zip(objects, ids):
        if scene_id not in mappings:
            continue
        asset_id = mappings[scene_id]
        asset_class = REVIEWED_ASSET_CLASS_BY_EQUIPMENT_TYPE.get(obj.get('equipmentType'))
        if not asset_class or assets[asset_id].get('asset_class') != asset_class:
            raise ValueError(f'Incompatible workbook asset {asset_id} for scene object {scene_id}')
    return {
        'schemaVersion': 1,
        'sourceFile': Path(workbook).name,
        'sourceSha256': hashlib.sha256(Path(workbook).read_bytes()).hexdigest(),
        'synthetic': True,
        'mappingMethod': mapping_method,
        'mappingNotice': 'Synthetic scene association; asset identity is not physically verified.',
        'mappings': mappings,
        'tables': tables,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workbook', type=Path)
    parser.add_argument('--site', type=Path, required=True)
    mapping = parser.add_mutually_exclusive_group()
    mapping.add_argument('--mapping', type=Path,
                         help='JSON object: scene object_id -> workbook asset_id')
    mapping.add_argument('--reviewed-tags', type=Path,
                         help='JSON object: scene object_id -> reviewed workbook tag')
    parser.add_argument('--include-nearby', action='store_true',
                        help='Also map equipment without a service route')
    parser.add_argument('--output', type=Path,
                        default=Path('assets/valmet/asset-data.json'))
    args = parser.parse_args()
    mappings = json.loads(args.mapping.read_text()) if args.mapping else None
    result = export(args.workbook, json.loads(args.site.read_text()), mappings,
                    include_nearby=args.include_nearby,
                    reviewed_tags=read_reviewed_tags(args.reviewed_tags) if args.reviewed_tags else None)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, allow_nan=False) + '\n')
    print(f"Mapped {len(result['mappings'])} scene objects; "
          f"imported {len(result['tables']['Asset_Master'])} assets")


if __name__ == '__main__':
    main()
