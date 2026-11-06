"""Add lossless portrait crops to each existing, independently rendered split."""

import argparse
import json
from pathlib import Path

from PIL import Image


def prepare(root):
    for split in ('train', 'validation', 'test'):
        folder = root / split
        annotation = folder / 'annotations.json'
        originals = [
            row for row in json.loads(annotation.read_text())
            if not row['imagefilename'].startswith('portrait-')
        ]
        portraits = []
        for row in originals:
            image = Image.open(folder / row['imagefilename'])
            width, height = image.size
            crop_width = round(height * 9 / 16)
            if crop_width >= width:
                continue
            shift = (sum(row['imagefilename'].encode()) % 5 - 2) * width * 0.035
            left = min(width - crop_width, max(0, round((width - crop_width) / 2 + shift)))
            labels = []
            for item in row['annotation']:
                b = item['coordinates']
                x0 = max(0, b['x'] - b['width'] / 2 - left)
                x1 = min(crop_width, b['x'] + b['width'] / 2 - left)
                w = x1 - x0
                if w >= 12 and w >= b['width'] * 0.45:
                    labels.append({'label': item['label'], 'coordinates': {
                        **b, 'x': (x0 + x1) / 2, 'width': w
                    }})
            if not labels:
                continue
            name = 'portrait-' + Path(row['imagefilename']).stem + '.png'
            image.crop((left, 0, left + crop_width, height)).save(folder / name)
            portraits.append({'imagefilename': name, 'annotation': labels})
        temporary = annotation.with_suffix('.tmp')
        temporary.write_text(json.dumps(originals + portraits, indent=2) + '\n')
        temporary.replace(annotation)
        print(f'{split}: {len(originals)} landscape + {len(portraits)} portrait views')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dataset', type=Path)
    prepare(parser.parse_args().dataset)
