"""Synthetic CLI checks. No model import, network access, training or inference."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from PIL import Image
from equipment_detector import validate_resume

TOOL = Path(__file__).with_name('equipment_detector.py')


class DetectorToolsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        self.names = ['legacy:pump', 'novel:cart']
        self.classes = self.root / 'classes.json'
        self.classes.write_text(json.dumps(self.names))
        self.scan = self.root / 'corrected.splats'
        self.scan.write_bytes(b'local corrected scan fixture')
        poses = []
        for i, split in enumerate(['train', 'validation', 'test']):
            folder = self.source / split
            folder.mkdir(parents=True)
            name = f'{split}.png'
            Image.new('RGB', (20, 10), (30*i, 60*i, 90*i)).save(folder / name)
            rows = [dict(imagefilename=name, annotation=[
                dict(label=self.names[0], coordinates=dict(x=2, y=2, width=5, height=5)),
                dict(label=self.names[1], coordinates=dict(x=12, y=5, width=4, height=4)),
            ])]
            (folder / 'annotations.json').write_text(json.dumps(rows))
            poses.append(dict(name=name, cell=[i, i]))
        self.poses = self.root / 'poses.json'
        self.poses.write_text(json.dumps(poses))
        self.dataset = self.root / 'coco'
        self.weights = self.root / 'weights.pth'
        self.weights.write_bytes(b'local checkpoint fixture')

    def cli(self, *arguments, succeeds=True):
        result = subprocess.run([sys.executable, str(TOOL), *map(str, arguments)], text=True, capture_output=True)
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def convert(self, succeeds=True):
        return self.cli('coco', '--dataset', self.source, '--classes', self.classes,
                        '--poses', self.poses, '--scan', self.scan, '--output', self.dataset,
                        succeeds=succeeds)

    def test_conversion_clipping_mapping_and_offline_cli_plans(self):
        self.convert()
        data = json.loads((self.dataset / 'train/_annotations.coco.json').read_text())
        self.assertEqual([r['id'] for r in data['categories']], [1, 2])
        self.assertEqual(data['annotations'][0]['bbox'], [0, 0, 4.5, 4.5])
        self.assertTrue((self.dataset / 'train/train.png').is_symlink())
        train_output = self.root / 'candidate-training'
        self.cli('train', '--dataset', self.dataset, '--resume', self.weights, '--epochs', 6,
                 '--output', train_output, '--dry-run')
        self.assertFalse(train_output.exists())
        contract = dict(checkpoint_sha256=hashlib.sha256(self.weights.read_bytes()).hexdigest(),
                        classes=self.names, thresholds=[.25, .6], approvedObjectIDs=[self.names[1]],
                        approvalScope='synthetic validation only', topK=300, inputShape=[1, 3, 384, 384])
        policy = self.root / 'contract.json'
        policy.write_text(json.dumps(contract))
        export_output = self.root / 'candidate-export'
        arguments = ['export', '--checkpoint', self.weights, '--contract', policy,
                     '--legacy-count', 1, '--output', export_output, '--dry-run']
        self.cli(*arguments)
        self.assertFalse(export_output.exists())
        contract['approvedObjectIDs'] = [self.names[0]]
        policy.write_text(json.dumps(contract))
        self.cli(*arguments, succeeds=False)
        contract['approvedObjectIDs'] = [self.names[1]]
        contract['checkpoint_sha256'] = 'wrong'
        policy.write_text(json.dumps(contract))
        self.cli(*arguments, succeeds=False)

    def test_resume_rejects_ema_reordered_classes_and_completed_endpoint(self):
        checkpoint = dict(args=dict(class_names=self.names), epoch=15,
                          optimizer_states=[{'state': {}}], lr_schedulers=[{}])
        validate_resume(checkpoint, self.names, 18)
        for replacement in [dict(optimizer_states=[]), dict(epoch=17),
                            dict(args=dict(class_names=list(reversed(self.names))))]:
            with self.assertRaises(ValueError):
                validate_resume(checkpoint | replacement, self.names, 18)

    def test_split_camera_leak_rejects_without_partial_dataset(self):
        poses = json.loads(self.poses.read_text())
        poses[-1]['cell'] = poses[0]['cell']
        self.poses.write_text(json.dumps(poses))
        self.convert(succeeds=False)
        self.assertFalse(self.dataset.exists())

    def test_duplicate_image_hash_and_invalid_box_are_rejected(self):
        train = self.source / 'train/train.png'
        (self.source / 'test/test.png').write_bytes(train.read_bytes())
        self.convert(succeeds=False)
        self.assertFalse(self.dataset.exists())
        Image.new('RGB', (20, 10), 'red').save(self.source / 'test/test.png')
        path = self.source / 'train/annotations.json'
        rows = json.loads(path.read_text())
        rows[0]['annotation'][0]['coordinates']['width'] = 99
        path.write_text(json.dumps(rows))
        self.convert(succeeds=False)
        self.assertFalse(self.dataset.exists())


if __name__ == '__main__':
    unittest.main()
