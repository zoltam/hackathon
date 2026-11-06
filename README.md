# Valmet Field App

Flutter starter for the Valmet hackathon challenge. See [challenge details](challenges.md).

Team coordination: [development plan](PLAN.md) · [full challenge notes and scoring](challenge-shortlist.md).

## Run on iOS

Use macOS with Flutter and Xcode installed. From the repository root:

```sh
flutter pub get
open -a Simulator
flutter run
```

For a physical iPhone, open `ios/Runner.xcworkspace` in Xcode and select your team under Runner → Signing & Capabilities. Use a unique bundle identifier for device signing.

## Walk inside the 3D model

Enable **Forward and backward controls** under **Settings** to move with the two on-screen buttons or ↑/↓. Turn by rotating the phone. This mode still uses ARKit to track orientation.

On an ARKit-capable iPhone, select a service target and tap **Walk inside the 3D model**. Stand at the physical spot that should correspond to the virtual start, hold the phone upright and face the direction of the first route segment. The app assumes an initial phone height of 1.50 metres and uses the phone’s angle for the view. Tap **Set start and direction**. ARKit drives the virtual camera with the phone's rotation and translation, with one physical metre equal to one model metre. **Show camera** switches back to the live view while tracking continues. Use **Reset alignment** to choose a new physical start.

The iPhone demo loads the organizer-provided Industrial Boiler Room scan. From the repository root, install NumPy and prepare the local assets before building:

```sh
python3 tools/build_boiler_room.py "/path/to/Equipment Room.ply"
swiftc -O tools/build_pump_references.swift -o /tmp/valmet-pump-references
/tmp/valmet-pump-references
```

The importer requires the complete Equipment Room scan. It registers the scan against the reviewed equipment frame and renders all 1,676,481 splats with their anisotropic covariance, opacity, and degree-3 view-dependent color. The navigation grid comes from observed floor and obstacle geometry. A neutral backing surface fills missing floor pixels and leaves walkability unchanged. Distances assume the reviewed scene uses metres. Keep the organizer's scan and derived assets local unless public redistribution is authorized.

The iPhone detector samples the full rendered image locally at up to 10 frames per second. It skips frames while inference is busy. It returns image-space boxes for the catalog objects, without reading coordinates or camera images as recognition input. Routing and arrival use the separately mapped walkable approach.

To prepare and train the detector on macOS with Xcode and Pillow installed:

```sh
swiftc -O tools/build_pump_references.swift -o /tmp/valmet-pump-references
/tmp/valmet-pump-references --detection-dataset-hq
python3 tools/prepare_detection_views.py build/valmet-detection-hq
swiftc -O tools/train_equipment_detector.swift -o /tmp/valmet-train-equipment-monitored
/tmp/valmet-train-equipment-monitored 600 > /tmp/valmet-detector-hq-training.log 2>&1
```

In another terminal, monitor without altering the worker:

```sh
python3 tools/monitor_equipment_training.py --watch --log /tmp/valmet-detector-hq-training.log --trainer /tmp/valmet-train-equipment-monitored
```

Train and select on validation, then evaluate the chosen export with `--evaluate-only --split=test`. For intermediate checkpoints, copy the training session directory before using `--checkpoint-dir=<copy> --checkpoint-iteration=<step> --model=<separate-output>` on validation. The monitor can verify the evaluated export with `--expected-sha256 <digest>`. The generated Core ML model is `assets/valmet/equipment-detector.mlmodel`. Build the iPhone app after it exists. Scan data, renders, checkpoints and trained weights stay local.

The generated scene JSON also contains reviewed equipment volumes and stable `objectId` values for the workbook and proximity features. See [the scene handoff](PLAN.md#scene-and-equipment-handoff) for coverage and coordinate assumptions.

For an installed development build on a connected and unlocked iPhone, repeat the renderer-to-model checks:

```sh
xcrun devicectl device process launch --device <device> --terminate-existing --console <bundle-id> -- --verify-rendered-vision
xcrun devicectl device process launch --device <device> --terminate-existing --console <bundle-id> -- --benchmark-rendered-vision
```

The verification prints image-space boxes for several rendered views. The benchmark prints the number of GPU-completed frames, frame rate, inference latency, and frame-to-overlay latency for a 15-second scripted view sequence. The benchmark is invalidated if the app loses foreground focus.

## Navigation and inspection evidence (member 2)

The Flutter screen plans four-neighbour routes over the observed floor. The
**Virtual avatar radius** selector checks clearance against obstacles, unknown
floor and map boundaries. The walkthrough requires a route. The Equipment Room
grid opens with a 0.10 m virtual camera radius and supports a 2.75 m route to the
pump. The route becomes unavailable at 0.20 m. This radius describes the
simulation. Clearance for a person requires a calibrated floor and scale.

On the iPhone, set the start and direction, then follow the green route in the
3D viewer. Walk with the phone or enable **Forward and backward controls** to
move with arrows and turn by rotating the phone. **Show camera** switches to
the camera feed, and **Reset alignment** lets you align again. Arrival uses
horizontal distance to the service point, separately from target recognition.
At the service point, open **Inspection evidence** for the selected target.

Import the supplied workbook after generating `assets/valmet/site.json`:

```sh
python3 -m pip install -r tools/requirements-data.txt
python3 tools/import_asset_data.py "/path/to/supplied-workbook.xlsx" \
  --site assets/valmet/site.json
```

The importer writes ignored `assets/valmet/asset-data.json`, retaining original
values, worksheet row references and a workbook SHA-256. It imports the included
3-day telemetry sample, not the unavailable full telemetry CSV. Original inputs
can be kept in ignored `sources/valmet/`. Keep source and generated data local.

By default it sorts service-object IDs and associates them with workbook assets
by increasing health score, breaking ties by asset ID. This is a **synthetic
association**, not semantic recognition or verified physical identity. Override
it with `--mapping /path/to/mapping.json`, whose JSON object maps scene
`object_id` to workbook `asset_id`. Explicit `objectId` or `object_id` values are preferred;
older objects use `grid:x:z:width:depth`. Regenerate/review the mapping when
fallback geometry IDs change. Unknown or duplicate IDs are rejected.

The iPhone **Inspection evidence** panel shows supplied current state, latest included telemetry, recent events/work orders, context documents,
matching historical hypotheses and data-quality flags, all with source references.
The snapshot date and supplied model confidence stay visible. This is a local,
deterministic evidence-retrieval baseline; it does not call a generative AI model
or establish a confirmed cause. Missing records remain explicit. Vision model
integration belongs to members 1 and 3; changed-obstacle rerouting remains phase 2.

Checks:

```sh
flutter analyze
flutter test
python3 -m unittest discover -s tools -p 'test_*.py'
```
