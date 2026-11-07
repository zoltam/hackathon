#!/usr/bin/env python3
"""Reconcile a reviewed workbook import and render private room map artifacts."""
import argparse
import base64
from html import escape
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from import_asset_data import REVIEWED_ASSET_CLASS_BY_EQUIPMENT_TYPE, object_id
from merge_reviewed_scene import valid_bounds

# Same registered crop used by the iOS map.
ROOM = (1.7163, 1.5921166667, 9.5708, 7.9756666667)
SCAN_SHA256 = '83d8c7d99316c08c9719cfc2c5a6b9d1903b89847780e2458adc662c79f32955'


def reconcile(site, bundle):
    scene = {object_id(o): o for o in site['objects']}
    if len(scene) != len(site['objects']):
        raise ValueError('Duplicate scene object ID')
    markers = {key: n for n, key in enumerate(scene, 1)}
    bounds = {}
    for key, obj in scene.items():
        box = obj.get('extractionBounds') or obj.get('bounds')
        if not valid_bounds(box):
            raise ValueError(f'Invalid scene bounds for {key}')
        bounds[key] = box
    assets = bundle['tables']['Asset_Master']
    if len({a['asset_id'] for a in assets}) != len(assets):
        raise ValueError('Duplicate workbook asset ID')
    mapped = {asset: key for key, asset in bundle['mappings'].items()}
    if len(mapped) != len(bundle['mappings']) or set(mapped) - {a['asset_id'] for a in assets}:
        raise ValueError('Unknown or duplicate mapped workbook asset')
    rows = []
    for a in assets:
        key = mapped.get(a['asset_id'])
        obj = scene.get(key)
        if key is not None and (obj is None or
                REVIEWED_ASSET_CLASS_BY_EQUIPMENT_TYPE.get(obj.get('equipmentType')) != a['asset_class']):
            raise ValueError(f'Invalid scene association: {key}')
        anchor = a.get('scene_anchor_id')
        anchor_evidence = f' Workbook anchor {anchor} has no scan registration.' if anchor else ''
        rows.append({
            'asset_id': a['asset_id'], 'tag': a['tag'], 'class': a['asset_class'],
            'scene_object_id': key, 'location': bounds.get(key), 'marker': markers.get(key),
            'status': 'proposed synthetic' if obj else 'unlocated',
            'evidence': f"{a['_source']}. " + (
                f"{obj['name']} is cataloged as {obj['equipmentType']}. "
                'Existing class-compatible synthetic assignment. Physical identity unverified.'
                if obj else 'No reviewed synthetic assignment or verified scan identity.'
            ) + anchor_evidence,
        })
    return scene, rows


def draw_map(source, scene, rows, output, font_path):
    with Image.open(source) as room:
        room = room.convert('RGB')
    w, h = room.size
    width = w + 900
    unlocated = [r for r in rows if r['status'] == 'unlocated']
    columns = max(1, (w - 68) // 284)
    height = max(h + 218 + 42 * math.ceil(len(unlocated) / columns), 182 + 42 * len(scene))
    canvas = Image.new('RGB', (width, height), '#101b24')
    canvas.paste(room, (0, 100))
    draw = ImageDraw.Draw(canvas)
    encoded = base64.b64encode(source.read_bytes()).decode()
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
           f'viewBox="0 0 {width} {height}" role="img">',
           '<title>Equipment Room workbook reconciliation</title>',
           '<desc>Registered scan with numbered scene markers, synthetic workbook links and an unlocated asset list.</desc>',
           f'<rect width="{width}" height="{height}" fill="#101b24"/>',
           f'<image x="0" y="100" width="{w}" height="{h}" href="data:image/png;base64,{encoded}"/>']
    fonts = {size: ImageFont.truetype(font_path, size) for size in (24, 28, 34, 52)}

    def text(x, y, value, size=28, color='#f3f7fa'):
        draw.text((x, y), value, font=fonts[size], fill=color, anchor='ls')
        svg.append(f'<text x="{x}" y="{y}" fill="{color}" font-family="Arial,sans-serif" font-size="{size}">{escape(value)}</text>')

    linked = {r['scene_object_id']: r for r in rows if r['scene_object_id']}
    text(34, 68, 'Equipment Room · workbook reconciliation', 52)
    text(w + 32, 66, f'{len(scene)} scene markers', 34)
    text(w + 32, 105, 'Amber = proposed synthetic · teal = scene only', 28)
    text(w + 32, 140, 'Violet = geometry only', 28)
    left, back, span_x, span_z = ROOM
    placed = []
    for n, (key, obj) in enumerate(scene.items(), 1):
        lo, hi = obj.get('extractionBounds') or obj['bounds']
        x = round(((lo[0] + hi[0]) / 2 - left) / span_x * w)
        y = 100 + round(((lo[2] + hi[2]) / 2 - back) / span_z * h)
        if not (0 <= x <= w and 100 <= y <= h + 100):
            raise ValueError(f'Scene center falls outside registered image for {key}')
        candidates = [(0, 0)] + [(round(radius * math.cos(a * math.pi / 8)),
                      round(radius * math.sin(a * math.pi / 8)))
                     for radius in (45, 82, 120) for a in range(16)]
        px, py = next(((x + dx, y + dy) for dx, dy in candidates
                       if 20 <= x + dx <= w - 20 and 120 <= y + dy <= h + 80
                       and all(math.dist((x + dx, y + dy), p) >= 40 for p in placed)), (x, y))
        placed.append((px, py))
        row = linked.get(key)
        color = '#ffd16b' if row else '#c9b5ff' if obj.get('geometryOnly') else '#7fe5da'
        draw.line((x, y, px, py), fill=color, width=3)
        svg.append(f'<path d="M{x} {y}L{px} {py}" stroke="{color}" stroke-width="3"/>')
        draw.ellipse((px-18, py-18, px+18, py+18), fill='#101b24', outline=color, width=3)
        svg.append(f'<circle cx="{px}" cy="{py}" r="18" fill="#101b24" stroke="{color}" stroke-width="3"/>')
        digits = str(n)
        text(px - round(fonts[24].getlength(digits) / 2), py + 8, digits, 24, color)
        label = f"{n:02}  {obj['name']}"
        if row:
            label += f" · {row['tag']} / {row['asset_id']}"
        text(w + 32, 182 + 42 * (n - 1), label, 24, color)
    y = h + 188
    text(34, h + 132, 'Registered scan view · workbook assignments are synthetic.', 28)
    text(34, y, f'Unlocated workbook assets ({len(unlocated)})', 34)
    for i, row in enumerate(unlocated):
        text(34 + (i % columns) * 284, y + 42 * (i // columns + 1),
             f"{row['tag']} / {row['asset_id']}", 24)
    canvas.save(output.with_suffix('.png'))
    output.with_suffix('.svg').write_text('\n'.join([*svg, '</svg>']) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--site', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--room-image', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    mac_font = Path('/System/Library/Fonts/Supplemental/Arial.ttf')
    parser.add_argument('--font', default=str(mac_font) if mac_font.is_file() else 'DejaVuSans.ttf')
    args = parser.parse_args()
    site = json.loads(args.site.read_text())
    if site.get('sourceSha256') != SCAN_SHA256:
        parser.error('the room image crop requires the registered Equipment Room scan')
    bundle = json.loads(args.bundle.read_text())
    scene, rows = reconcile(site, bundle)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    draw_map(args.room_image, scene, rows, args.output, args.font)
    proposed = sum(r['marker'] is not None for r in rows)
    table = [
        '# Workbook-to-room reconciliation', '',
        f'{len(rows)} workbook assets. {proposed} proposed synthetic assignments. '
        f'{len(rows) - proposed} unlocated. {len(scene)} room markers.', '',
        f"Workbook SHA-256 `{bundle['sourceSha256']}`. "
        f"Scene scan SHA-256 `{site['sourceSha256']}`.", '',
        'Map numbers follow the scene catalog order. Each marker points to the center of its '
        'scene bounds in the registered X/Z scan image. Table bounds are X/Y/Z in metres. '
        'Violet markers show geometry-only observations. Workbook tags and anchors carry synthetic identities.', '',
        '| Asset ID | Tag | Class | Marker | Scene object ID | Location (metres, 3D bounds) | Status | Evidence |',
        '| --- | --- | --- | --- | --- | --- | --- | --- |',
    ]
    for row in rows:
        location = '—' if not row['location'] else ' to '.join(
            '(' + ', '.join(f'{v:.2f}' for v in p) + ')' for p in row['location'])
        marker = f"{row['marker']:02}" if row['marker'] else '—'
        table.append(f"| {row['asset_id']} | {row['tag']} | {row['class']} | {marker} | "
                     f"{row['scene_object_id'] or '—'} | {location} | {row['status']} | {row['evidence']} |")
    table.extend(['', '## Geometry-only observations', '',
                  '| Marker | Scene object | Scene object ID | Scan evidence |',
                  '| --- | --- | --- | --- |'])
    for marker, (key, obj) in enumerate(scene.items(), 1):
        if obj.get('geometryOnly'):
            extraction = obj.get('extraction', {})
            evidence = extraction.get('evidence') or extraction.get('method', 'Scene catalog')
            views = ', '.join(view['view'] for view in extraction.get('viewObservations', []))
            evidence += f' Views {views}.' if views else ''
            table.append(f"| {marker:02} | {obj['name']} | {key} | {evidence} |")
    args.output.with_suffix('.md').write_text('\n'.join(table) + '\n')
    print(f"{len(rows)} workbook rows, {len(scene)} scene markers, "
          f"{proposed} synthetic links")


if __name__ == '__main__':
    main()
