#!/usr/bin/env python3
"""Export the supplied workbook and explicit synthetic scene mapping for Flutter.

Requires openpyxl. Source workbook and generated output must remain local.
"""
import argparse
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


def object_id(obj):
    return obj.get('objectId') or obj.get('object_id') or 'grid:{x}:{z}:{width}:{depth}'.format(**obj)


def export(workbook, site, mappings=None):
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
    states = {r['asset_id']: r for r in tables['Current_State']}
    if len(states) != len(tables['Current_State']):
        raise ValueError('Duplicate current states')
    for name in ('Current_State', 'Telemetry_Sample_3d', 'Alarms_Events',
                 'Maintenance_History', 'Data_Quality'):
        for row in tables[name]:
            if row['asset_id'] not in assets:
                raise ValueError(f"Unknown asset at {row['_source']}")

    objects = [o for o in site['objects'] if o.get('service') is not None]
    ids = [object_id(o) for o in objects]
    if len(set(ids)) != len(ids):
        raise ValueError('Service objects need unique object_id values')
    mapping_method = 'synthetic_ranked' if mappings is None else 'synthetic_explicit'
    if mappings is None:
        # Reproducible association allowed by the brief. No semantic identity claim.
        ranked = sorted(states, key=lambda a: (
            states[a].get('health_score', 101), a))
        if len(ids) > len(ranked):
            raise ValueError('More service objects than workbook assets')
        mappings = dict(zip(sorted(ids), ranked))
    if set(mappings) - set(ids):
        raise ValueError('Mapping contains unknown/non-service scene objects')
    if set(mappings.values()) - assets.keys():
        raise ValueError('Mapping contains unknown workbook assets')
    if len(set(mappings.values())) != len(mappings):
        raise ValueError('Mapping must be one-to-one')
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
    parser.add_argument('--mapping', type=Path,
                        help='JSON object: scene object_id -> workbook asset_id')
    parser.add_argument('--output', type=Path,
                        default=Path('assets/valmet/asset-data.json'))
    args = parser.parse_args()
    mappings = json.loads(args.mapping.read_text()) if args.mapping else None
    result = export(args.workbook, json.loads(args.site.read_text()), mappings)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, allow_nan=False) + '\n')
    print(f"Mapped {len(result['mappings'])} scene objects; "
          f"imported {len(result['tables']['Asset_Master'])} assets")


if __name__ == '__main__':
    main()
