"""Read the registered app geometry without altering its coordinates or source."""
import hashlib
import json
from pathlib import Path

import numpy as np


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def load_geometry(assets):
    assets = Path(assets)
    path = assets / 'boiler-room-sh.splats'
    if not path.stat().st_size or path.stat().st_size % 160:
        raise ValueError('Expected the registered 160-byte Gaussian asset')
    packed = np.memmap(path, dtype=np.uint8, mode='r').reshape(-1, 160)
    fields = np.ascontiguousarray(packed[:, :64]).view('<f4').reshape(-1, 16)
    if not np.isfinite(fields).all():
        raise ValueError('Registered geometry contains nonfinite fields')
    covariance = np.empty((len(fields), 3, 3), dtype=np.float32)
    covariance[:, 0, 0] = fields[:, 8]
    covariance[:, 0, 1] = covariance[:, 1, 0] = fields[:, 9]
    covariance[:, 0, 2] = covariance[:, 2, 0] = fields[:, 10]
    covariance[:, 1, 1] = fields[:, 11]
    covariance[:, 1, 2] = covariance[:, 2, 1] = fields[:, 12]
    covariance[:, 2, 2] = fields[:, 13]
    site = json.loads((assets / 'site.json').read_text(encoding='utf-8'))
    return {
        'centers': fields[:, :3],
        'opacities': np.clip(fields[:, 3], 0, 1),
        'rgbs': np.clip(fields[:, 4:7], 0, 1),
        'covariances': covariance,
        'sourceSha256': site.get('sourceSha256'),
    }


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False,
                                    indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)
