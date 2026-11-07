# Optional RF-DETR tooling

Python 3.11. Optional training dependencies are pinned in requirements-detector.txt. Export adds requirements-detector-export.txt. Existing source-mask renderers and the production Create ML model provide the data and regression baseline. Images, source scans and mask annotations stay on local storage.

The coco command converts a Create ML dataset with train/validation/test/annotations.json. Supply ordered class JSON, camera-pose JSON files, the corrected scan file and its expected digest. It symlinks RGB files, uses category IDs 1..N, rejects image-hash or camera-cell split overlap, and clips only the renderer's inclusive half-pixel edge overflow. It builds a fresh dataset through a temporary directory and records split support and source digests.

    python tools/equipment_detector.py coco --dataset "$MASK_DATASET" --classes "$CLASSES_JSON" --poses "$POSES_JSON" --scan "$CORRECTED_SCAN" --expected-scan-sha256 "$SCAN_SHA256" --output "$COCO_CANDIDATE"
    python tools/equipment_detector.py train --dataset "$COCO_CANDIDATE" --weights "$LOCAL_NANO_WEIGHTS" --epochs 3 --output "$TRAIN_CANDIDATE" --dry-run
    python tools/equipment_detector.py train --dataset "$COCO_CANDIDATE" --resume "$LOCAL_TRAINING_CHECKPOINT" --epochs 6 --output "$RESUMED_CANDIDATE" --dry-run
    python tools/equipment_detector.py export --checkpoint "$FROZEN_EMA_CHECKPOINT" --contract "$VALIDATED_CONTRACT" --output "$EXPORT_CANDIDATE" --dry-run

Remove --dry-run only for the intended local operation. Training requires an existing local checkpoint or starter-weight file. Dry-run validates the data/paths but does not inspect checkpoint tensors. Actual resume rejects EMA/inference snapshots without optimizer/scheduler state and requires exact checkpoint class order. Resume uses the total epoch endpoint and preserves optimizer state through RF-DETR's training-checkpoint API. It disables remote loggers and automatic test evaluation. Each operation requires a fresh candidate output path.

The export contract has checkpoint_sha256, ordered classes, ordered thresholds, topK 300, inputShape [1,3,384,384], explicit approvalScope, and approvedObjectIDs. Optional imageOnlyGateObjectIDs records the separate image-only policy. Approved IDs must exclude the first 11 legacy IDs by default. --legacy-count supports a different explicitly chosen baseline. Generate policy and confidence values from validation evidence before passing the contract. The export command verifies provenance and schema. Statistical validity of approval comes from the supplied evaluation evidence.

Export uses typed RGB input with exact in-graph normalization, FP16 computation, and named FP32 boxes/logits outputs. The private RF-DETR exporter hooks are pinned to locally verified versions. Core ML Tools 9 warns that Torch 2.15 is newer than its tested range, so dependency changes require renewed numerical and Vision parity checks. Preserve exported metadata/provenance, class counts, frozen thresholds, mask sources and held-out evaluations with each candidate. Phone accuracy and throughput remain adoption gates.

Run python -m unittest discover -s tools -p test_equipment_detector.py. Synthetic checks cover mapping, clipping, rejection of split leakage and invalid boxes, local resume planning, and approval/checkpoint validation. They do not load weights or execute a model.
