"""Local equipment-detector data, training and candidate-export commands (Python 3.11)."""

import argparse
from collections import Counter
from dataclasses import replace
import hashlib
import json
import math
import os
from pathlib import Path
import tempfile
from unittest.mock import patch


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def class_names(path):
    names = read(path)
    if not isinstance(names, list) or not names or not all(isinstance(n, str) and n for n in names) or len(names) != len(set(names)):
        raise ValueError('Class names must be a nonempty ordered list of unique strings')
    return names


def new_output(path):
    if path.exists():
        raise ValueError(f'Candidate output already exists: {path}')
    path.parent.mkdir(parents=True, exist_ok=True)


def convert(args):
    from PIL import Image

    names = class_names(args.classes)
    ids = {name: i for i, name in enumerate(names, 1)}
    poses = {}
    for path in args.poses:
        for row in read(path):
            name, cell = row['name'], tuple(row['cell'])
            if name in poses and poses[name] != cell:
                raise ValueError(f'Conflicting camera metadata: {name}')
            poses[name] = cell
    if args.expected_scan_sha256 and digest(args.scan) != args.expected_scan_sha256:
        raise ValueError('Corrected scan digest does not match')
    new_output(args.output)
    audit = {'scan_sha256': digest(args.scan), 'splits': {}}
    seen_hashes, seen_cells = set(), set()
    with tempfile.TemporaryDirectory(prefix='.detector-', dir=args.output.parent) as temporary:
        target = Path(temporary) / 'dataset'
        target.mkdir()
        for source_split, split in [('train', 'train'), ('validation', 'valid'), ('test', 'test')]:
            folder = args.dataset / source_split
            index = folder / 'annotations.json'
            rows = read(index)
            destination = target / split
            destination.mkdir()
            images, annotations = [], []
            hashes, cells, stems, support = set(), set(), set(), Counter()
            clipped = negatives = 0
            for image_id, row in enumerate(rows, 1):
                name = row['imagefilename']
                if Path(name).name != name or Path(name).stem in stems:
                    raise ValueError(f'Unsafe or duplicate image filename: {name}')
                stems.add(Path(name).stem)
                source = (folder / name).resolve(strict=True)
                image_hash = digest(source)
                cell = poses[name.removeprefix('portrait-')]
                if image_hash in hashes | seen_hashes or cell in seen_cells:
                    raise ValueError(f'Image or camera-cell split leakage: {name}')
                hashes.add(image_hash)
                cells.add(cell)
                with Image.open(source) as image:
                    width, height = image.size
                    image.verify()
                images.append(dict(id=image_id, file_name=name, width=width, height=height))
                present = set()
                for box in row['annotation']:
                    label, c = box['label'], box['coordinates']
                    if label not in ids or label in present:
                        raise ValueError(f'Unknown or duplicate instance label: {name} / {label}')
                    present.add(label)
                    x, y, w, h = (float(c[k]) for k in ('x', 'y', 'width', 'height'))
                    if not all(math.isfinite(v) for v in (x, y, w, h)) or min(w, h) <= 0:
                        raise ValueError(f'Invalid box: {name} / {label}')
                    left, top, right, bottom = x-w/2, y-h/2, x+w/2, y+h/2
                    overflow = max(-left, -top, right-width, bottom-height, 0)
                    # Visible masks count inclusive pixels and can extend 0.5 px at the image edge.
                    if overflow > .5:
                        raise ValueError(f'Box exceeds the viewport by more than 0.5 px: {name}')
                    clipped += overflow > 0
                    left, top, right, bottom = max(0, left), max(0, top), min(width, right), min(height, bottom)
                    if not left < right or not top < bottom:
                        raise ValueError(f'Empty clipped box: {name}')
                    w, h = right-left, bottom-top
                    annotations.append(dict(id=len(annotations)+1, image_id=image_id, category_id=ids[label],
                                            bbox=[left, top, w, h], area=w*h, iscrowd=0))
                    support[label] += 1
                negatives += not present
                (destination / name).symlink_to(source)
            if set(support) != set(names):
                raise ValueError(f'{source_split} does not cover every class')
            write(destination / '_annotations.coco.json', dict(
                info={'description': 'Local equipment mask labels'}, licenses=[],
                categories=[dict(id=ids[n], name=n, supercategory='equipment') for n in names],
                images=images, annotations=annotations,
            ))
            seen_hashes |= hashes
            seen_cells |= cells
            audit['splits'][split] = dict(images=len(images), boxes=len(annotations), negatives=negatives,
                                          clipped_half_pixel=clipped, camera_cells=len(cells), support=dict(support),
                                          source_annotations_sha256=digest(index))
        write(target / 'audit.json', audit)
        write(target / 'classes.json', names)
        target.replace(args.output)
    print(json.dumps(audit, indent=2))


def training_plan(args):
    checkpoint = (args.resume or args.weights).resolve(strict=True)
    categories = None
    hashes = {}
    for split in ('train', 'valid'):
        path = args.dataset / split / '_annotations.coco.json'
        data = read(path)
        current = data['categories']
        if [c['id'] for c in current] != list(range(1, len(current)+1)) or not current:
            raise ValueError('Expected COCO category IDs 1..N in stable order')
        if categories is not None and current != categories:
            raise ValueError('Training and validation class order differ')
        categories = current
        hashes[split] = digest(path)
    if args.epochs < 1 or args.batch < 1 or args.accumulate < 1:
        raise ValueError('Epoch, batch and accumulation counts must be positive')
    if args.output.exists():
        raise ValueError('Use a new candidate output directory')
    return dict(checkpoint=str(checkpoint), checkpoint_sha256=digest(checkpoint),
                dataset=str(args.dataset.resolve()), annotation_sha256=hashes,
                classes=[c['name'] for c in categories], epochs=args.epochs, device=args.device)


def validate_resume(checkpoint, names, epochs):
    saved = checkpoint.get('args', {})
    if not isinstance(saved, dict) or saved.get('class_names') != names:
        raise ValueError('Resume checkpoint class order must exactly match the dataset')
    if not checkpoint.get('optimizer_states') or not checkpoint.get('lr_schedulers'):
        raise ValueError('Resume requires a full training checkpoint, not an EMA/inference snapshot')
    epoch = checkpoint.get('epoch')
    if not isinstance(epoch, int) or epochs <= epoch+1:
        raise ValueError('Total epoch endpoint must exceed the completed checkpoint epoch')


def train(args):
    plan = training_plan(args)
    print(json.dumps(plan, indent=2))
    if args.dry_run:
        return
    from importlib.metadata import version
    if version('rfdetr') != '1.12.0':
        raise ValueError('Revalidate this tooling before changing RF-DETR version')
    os.environ['WANDB_MODE'] = 'disabled'
    from rfdetr import RFDETRNano

    if args.resume:
        import torch
        checkpoint = torch.load(plan['checkpoint'], map_location='cpu', weights_only=True, mmap=True)
        validate_resume(checkpoint, plan['classes'], args.epochs)
        del checkpoint
    model = RFDETRNano.from_checkpoint(plan['checkpoint'], device=args.device)
    if args.resume and model.class_names != plan['classes']:
        raise ValueError('Loaded checkpoint class order differs from the dataset')
    new_output(args.output)
    args.output.mkdir()
    write(args.output / 'provenance.json', plan)
    model.train(
        dataset_dir=str(args.dataset.resolve()), output_dir=str(args.output.resolve()),
        resume=str(args.resume.resolve()) if args.resume else None,
        device=args.device, epochs=args.epochs, batch_size=args.batch, grad_accum_steps=args.accumulate,
        num_workers=0, multi_scale='off', amp_dtype=None, checkpoint_interval=1, seed=33,
        tensorboard=False, wandb=False, mlflow=False, clearml=False, run_test=False,
    )


def export_contract(args):
    contract = read(args.contract)
    names = contract['classes']
    if not isinstance(names, list) or not names or not all(isinstance(n, str) and n for n in names) or len(set(names)) != len(names):
        raise ValueError('Invalid ordered class list')
    if contract['checkpoint_sha256'] != digest(args.checkpoint):
        raise ValueError('Contract belongs to a different checkpoint')
    thresholds = contract['thresholds']
    if len(thresholds) != len(names) or not all(isinstance(t, (int, float)) and 0 <= t <= 1 for t in thresholds):
        raise ValueError('One finite threshold in [0,1] is required per class')
    if not 0 <= args.legacy_count <= len(names):
        raise ValueError('Invalid legacy class count')
    legacy = set(names[:args.legacy_count])
    approved = contract['approvedObjectIDs']
    if not isinstance(approved, list) or not all(isinstance(n, str) for n in approved) or len(approved) != len(set(approved)) or not set(approved) <= set(names):
        raise ValueError('Approved IDs must be unique model classes')
    replacements = contract.get('replacesPrimaryObjectIDs', [])
    if (not isinstance(replacements, list) or not all(isinstance(n, str) for n in replacements)
            or len(replacements) != len(set(replacements))
            or not set(replacements) <= {'boiler-room:middle-blue-actuator'}
            or set(approved) & legacy != set(replacements)):
        raise ValueError('Only a declared middle-blue-actuator may replace a primary ID')
    image_only = contract.get('imageOnlyGateObjectIDs', [])
    if len(image_only) != len(set(image_only)) or not set(image_only) <= set(names[args.legacy_count:]):
        raise ValueError('Image-only qualified IDs must also be unique novel IDs')
    if not contract.get('approvalScope') or contract.get('topK') != 300:
        raise ValueError('Approval scope and evaluated topK=300 must be explicit')
    if contract.get('inputShape') != [1, 3, 384, 384]:
        raise ValueError('This tested Nano export requires inputShape [1,3,384,384]')
    if args.output.exists():
        raise ValueError('Use a new candidate output directory')
    contract.update(input='image', inputColor='RGB', inputScale=1/255,
                    mean=[.485, .456, .406], std=[.229, .224, .225],
                    outputBoxes='boxes', outputLogits='logits', minimumTarget='iOS15', precision='float16')
    return contract


def export(args):
    contract = export_contract(args)
    print(json.dumps(contract, indent=2))
    if args.dry_run:
        return
    from importlib.metadata import version
    if version('rfdetr') != '1.12.0' or version('coremltools') != '9.0':
        raise ValueError('Revalidate private exporter hooks before changing dependency versions')
    import coremltools as ct
    import numpy as np
    import torch
    from rfdetr import RFDETRNano
    from rfdetr.export._coreml.exporter import CoreMLExporter

    class RGBInput(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model
            self.register_buffer('mean', torch.tensor([.485, .456, .406]).reshape(1, 3, 1, 1))
            self.register_buffer('std', torch.tensor([.229, .224, .225]).reshape(1, 3, 1, 1))

        def forward(self, image):
            return self.model((image-self.mean)/self.std)

    torch.set_num_threads(2)
    model = RFDETRNano.from_checkpoint(args.checkpoint.resolve(), device='cpu')
    if model.class_names != contract['classes']:
        raise ValueError('Checkpoint class mapping does not match the contract')
    new_output(args.output)
    original_program, original_convert = CoreMLExporter._export_program, ct.convert

    def image_graph(exporter, graph):
        if exporter.config.neural_engine:
            raise ValueError('This tested export uses the standard RF-DETR graph')
        return original_program(exporter, replace(graph, model=RGBInput(graph.model).eval()))

    def image_convert(program, *values, **options):
        image = ct.ImageType(name=program.graph_signature.user_inputs[0], shape=(1, 3, 384, 384),
                             color_layout=ct.colorlayout.RGB, channel_first=True, scale=1/255)
        outputs = [ct.TensorType(name=n, dtype=np.float32) for n in ('boxes', 'logits')]
        result = original_convert(program, *values, inputs=[image], outputs=outputs,
                                  compute_units=ct.ComputeUnit.CPU_ONLY, **options)
        result.user_defined_metadata['valmet_rf_detr_contract'] = json.dumps(contract, separators=(',', ':'))
        return result

    # Private exporter hooks are pinned by requirements-detector-export.txt and tested with this source version.
    with patch.object(CoreMLExporter, '_export_program', image_graph), patch.object(ct, 'convert', image_convert):
        artifact = model.export(format='coreml', output_dir=str(args.output), output_name='equipment-candidate',
                                shape=(384, 384), batch_size=1, coreml_precision='float16')
    artifact.with_name(artifact.name+'.rfdetr.json').rename(args.output / 'exporter-provenance.json')
    spec = ct.models.MLModel(str(artifact), skip_model_load=True).get_spec()
    if spec.description.input[0].type.WhichOneof('Type') != 'imageType':
        raise ValueError('Exporter did not produce a typed image')
    expected = [('boxes', [1, 300, 4]), ('logits', [1, 300, len(contract['classes'])+1])]
    if [(f.name, list(f.type.multiArrayType.shape)) for f in spec.description.output] != expected:
        raise ValueError('Exported output schema differs from the decoder contract')
    write(args.output / 'contract.json', contract)
    write(args.output / 'provenance.json', dict(checkpoint_sha256=digest(args.checkpoint),
          contract_sha256=digest(args.contract), rfdetr=version('rfdetr'), coremltools=version('coremltools'),
          torch=version('torch'), torchvision=version('torchvision')))
    print(artifact)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    coco = commands.add_parser('coco')
    coco.add_argument('--dataset', type=Path, required=True)
    coco.add_argument('--classes', type=Path, required=True)
    coco.add_argument('--poses', type=Path, nargs='+', required=True)
    coco.add_argument('--scan', type=Path, required=True)
    coco.add_argument('--expected-scan-sha256')
    coco.add_argument('--output', type=Path, required=True)
    coco.set_defaults(action=convert)
    training = commands.add_parser('train')
    training.add_argument('--dataset', type=Path, required=True)
    sources = training.add_mutually_exclusive_group(required=True)
    sources.add_argument('--weights', type=Path)
    sources.add_argument('--resume', type=Path)
    training.add_argument('--output', type=Path, required=True)
    training.add_argument('--epochs', type=int, required=True, help='Total epoch endpoint, including resumed epochs')
    training.add_argument('--batch', type=int, default=4)
    training.add_argument('--accumulate', type=int, default=2)
    training.add_argument('--device', choices=['mps', 'cpu'], default='mps')
    training.add_argument('--dry-run', action='store_true')
    training.set_defaults(action=train)
    exporting = commands.add_parser('export')
    exporting.add_argument('--checkpoint', type=Path, required=True)
    exporting.add_argument('--contract', type=Path, required=True)
    exporting.add_argument('--output', type=Path, required=True)
    exporting.add_argument('--legacy-count', type=int, default=11)
    exporting.add_argument('--dry-run', action='store_true')
    exporting.set_defaults(action=export)
    args = parser.parse_args()
    try:
        args.action(args)
    except (ValueError, KeyError, FileNotFoundError) as error:
        parser.exit(2, f'{error}\n')


if __name__ == '__main__':
    main()
