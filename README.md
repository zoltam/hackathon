# Valmet Field App

Flutter starter for the Valmet hackathon challenge. See [challenge details](challenges.md).

Team coordination: [development plan](PLAN.md) · [full challenge notes and scoring](challenge-shortlist.md).

## Run on iOS

Use macOS with Xcode, Python 3 and Flutter with Dart 3.12.2 or later
(tested with Flutter 3.44.3). For the full demo, use an ARKit-capable iPhone
and obtain approved copies of the replacement `Equipment Room.ply` and the
Valmet synthetic builder workbook (`.xlsx`). The replacement scan has
1,676,481 vertices. The earlier `Industrial Boiler Room (1).ply` uses a
different scene registration.

From the repository root, prepare the local assets before building:

```sh
python3 -m venv sources/valmet/.venv
source sources/valmet/.venv/bin/activate
python3 -m pip install numpy -r tools/requirements-data.txt
python3 tools/build_boiler_room.py "/path/to/Equipment Room.ply"
python3 tools/import_asset_data.py "/path/to/Valmet_SinceAI_2026_Synthetic_Industrial_Metaverse_Builder_Pack (1) (2) (1).xlsx" \
  --site assets/valmet/site.json --include-nearby
flutter pub get
```

Connect the iPhone, open `ios/Runner.xcworkspace` in Xcode, and select
your team and a unique bundle identifier under Runner → Signing & Capabilities.
Select the connected iPhone as the run destination and run the Runner scheme.
The simulator can preview the Flutter settings. The AR walkthrough requires
the physical iPhone. The repository already includes the Core ML detector.

## Walk inside the 3D model

The main screen shows the planned route distance for the selected target and
camera clearance. Open the maintenance report after reaching the target in
the 3D viewer.

Enable **Forward and backward controls** under **Settings** to move with the two on-screen buttons or ↑/↓. Turn by rotating the phone. This mode still uses ARKit to track orientation.

Choose **3D frame rate** under **Settings** before opening the viewer: 15, 30
(default), or 60 FPS. This is a target; the device may render more slowly.

The 3D viewer's top-right map shows the room PNG, your blue position/heading,
the active mint route, and the gold destination. Tap it to enlarge; **Done**
returns to the viewer. Both map sizes follow obstacle-driven replanning.
Position appears after alignment and disappears if tracking is unavailable.
The bundled PNG is calibrated to the reviewed Equipment Room scan; a vector
map is used if the scan differs or the image cannot be loaded.

On an ARKit-capable iPhone, select a service target and tap **Walk inside the 3D model**. Stand at the physical spot that should correspond to the virtual start, hold the phone upright and face the direction of the first route segment. The app assumes an initial phone height of 1.50 metres and uses the phone’s angle for the view. Tap **Set start and direction**. ARKit drives the virtual camera with the phone's rotation and translation, with one physical metre equal to one model metre. **Show camera** switches back to the live view while tracking continues. Use **Reset alignment** to choose a new physical start.

The importer requires the complete Equipment Room scan. It registers the scan against the reviewed equipment frame and renders all 1,676,481 splats with their anisotropic covariance, opacity, and degree-3 view-dependent color. The navigation grid comes from observed floor and obstacle geometry. A neutral backing surface fills missing floor pixels and leaves walkability unchanged. Distances assume the reviewed scene uses metres. Keep the organizer's scan and derived assets local unless public redistribution is authorized.

The iPhone detector samples the full rendered image locally at up to 8 frames per second. It skips frames while inference is busy. It returns image-space boxes for the catalog objects, without reading coordinates or camera images as recognition input. Routing and arrival use the separately mapped walkable approach.

### Additional-object detector

The app includes an RF-DETR Nano FP16 Core ML supplement at
`ios/Runner/RFDETRSupplemental.mlpackage`, with its Apache 2.0 notice at
`ios/Runner/RFDETR-LICENSE.txt`. Xcode compiles the source package when building.
Normal launches run it alongside the existing R3 detector. Use the launch
argument `--disable-rfdetr-supplemental` for a baseline-only check.
The supplement has an independent
bounded inference queue and two-frame confirmation history. Its approved IDs
exclude all 11 R3 IDs. Capture-time 3D association follows image inference.

The frozen epoch-16 export qualified 14 additional instances on both validation
and test at per-instance precision ≥95% and recall ≥70%, after pose association
and deduplication. The separate image-only policy qualified ten additional
instances. These are different evaluated policies. Across all 33 candidates,
the pose-associated test produced 2,243 true positives, 81 false positives and
392 misses. Three difficult instances still have low recall, particularly the
two orange actuators and the rear red vessel. The enabled catalog contains 25 IDs,
comprising 11 R3 IDs and 14 additional IDs.

The iPhone check found all 14 additional IDs in their respective fixed views
and showed no supplemental overlay in the negative view. Both baseline and
combined runs missed the same wall-pump approach view. All six service journeys
passed recognition, arrival and workbook-evidence checks with the supplement.
A separate 2.0 m alternate P-005 journey also passed.

After a 12.49 s cold-model warmup, the 90-second combined benchmark produced
719 supplemental samples at 7.99 Hz, with p95 inference of 27 ms and one stale
sample. Rendering averaged 27.21 FPS versus 28.88 for R3 alone. R3 p95 inference
was 28 versus 6 ms, and overlay p95 age was 129 versus 110 ms. Both runs were
thermally constrained. This records the shared-resource cost on the tested
iPhone 15, iOS 26.5. The extra IDs become available after background model load.

Optional local data conversion, training/resume and typed Core ML export are
documented in [the detector tooling guide](tools/README-detector.md).

To retrain the detector, use the prepared scan and Python environment from
the setup above:

```sh
python3 -m pip install Pillow
swiftc -O tools/build_pump_references.swift -o /tmp/valmet-pump-references
/tmp/valmet-pump-references --detection-dataset-hq
python3 tools/prepare_detection_views.py build/valmet-detection-hq
swiftc -O tools/train_equipment_detector.swift -o /tmp/valmet-train-equipment-monitored
/tmp/valmet-train-equipment-monitored 600 --model="$PWD/build/valmet-detection-hq/candidate.mlmodel" > /tmp/valmet-detector-hq-training.log 2>&1
```

In another terminal, monitor without altering the worker:

```sh
python3 tools/monitor_equipment_training.py --watch --log /tmp/valmet-detector-hq-training.log \
  --model build/valmet-detection-hq/candidate.mlmodel --trainer /tmp/valmet-train-equipment-monitored
```

Train and select on validation, then evaluate the chosen export with `--evaluate-only --split=test --model=<candidate>`. Append the test output to the run log so the monitor can show the completed result. Each `VALMET_EVAL` row reports counts for one instance. Training and checkpoint export default to `candidate.mlmodel` inside the dataset; evaluation alone defaults to the bundled detector. For intermediate checkpoints, copy the training session directory before using `--checkpoint-dir=<copy> --checkpoint-iteration=<step> --model=<separate-output>` on validation. The monitor can verify the evaluated export with `--expected-sha256 <digest>`. The repository includes the evaluated Core ML detector at `assets/valmet/equipment-detector.mlmodel`, which the iPhone app bundles automatically. The scan, renders and training checkpoints stay local.

The generated scene JSON also contains reviewed equipment volumes and stable `objectId` values for the workbook and proximity features. See [the scene handoff](PLAN.md#scene-and-equipment-handoff) for coverage and coordinate assumptions.

For an installed development build on a connected and unlocked iPhone, repeat the renderer-to-model checks:

```sh
xcrun devicectl device process launch --device <device> --terminate-existing --console <bundle-id> -- --verify-rendered-vision
xcrun devicectl device process launch --device <device> --terminate-existing --console <bundle-id> -- --benchmark-rendered-vision
```

The verification prints image-space boxes for several rendered views. To check
specific views with the workbook loaded, pass a JSON array after
`--verify-rendered-vision`. Each entry has an `id`, an `eye` and `look` point in
registered scene metres, and optional `expectedIDs` and `absentIDs` lists of
scene object IDs. Each pose logs raw, 3D-matched and confirmed IDs separately.
The expected and absent lists are checked against confirmed overlays.

The 15-second benchmark reports GPU frames, frame rate, inference latency and
frame-to-overlay latency. `inference_samples` counts completed predictions,
`overlay_updates` counts predictions accepted by the frame freshness check,
and `confirmed_frames` counts accepted predictions that show a box. Report
all three counts and the iPhone/iOS versions when investigating missing
boxes. The run is invalidated if the app loses foreground focus.
Append `--benchmark-seconds=90` after `--benchmark-rendered-vision` for a
sustained check with cumulative counters every 15 seconds. Compare adjacent
checkpoints to see whether inference, accepted predictions or visible boxes
stop increasing. The duration is bounded to 15–180 seconds.

To check target confirmation and arrival on the route from the Dart planner, run
the scripted service journey on the connected phone:

```sh
xcrun devicectl device process launch --device <device> --terminate-existing --console <bundle-id> -- \
  --verify-service-journey "$(dart tools/verify_service_route.dart)"
```

Pass a scene object ID to `dart tools/verify_service_route.dart` to test
another service target. Append two floor-cell coordinates, `start-x start-z`,
after the ID to test an alternate start. The app's **Service target** selector offers the five
pumps and inline valve. Their routes are available at the default 0.10 m
virtual-camera radius.

The log records distance, target confirmation, arrival, workbook evidence and
visible mapped frames. The journey passes only when all are present. The
script moves the virtual camera. Verify physical AR walking separately.

To rehearse the route and workbook UI on a booted simulator, launch the
installed build with the same arguments:

```sh
xcrun simctl launch --terminate-running-process booted <bundle-id> \
  --verify-service-journey "$(dart tools/verify_service_route.dart)"
```

The simulator can render the journey without AR tracking. Use the physical
iPhone to verify the Core ML detector and the full journey gate.

## Navigation and inspection evidence (member 2)

The Flutter screen plans four-neighbour routes over measured floor support on
10 cm cells. Floor observations retain opacity down to 1%. Each floor cell needs
three observations, or two direct observations plus at least 14 across its 3×3
neighbourhood. A sparse cell can also use two measured Gaussian 2σ floor
footprints covering its centre, with the same nearby evidence requirement and a
12 cm maximum reach. This uses the actual scan surface rather than filling
unknown gaps. Strong obstacle observations between
0.17 and 1.55 m block movement, matching the virtual camera's 1.50 m height plus
5 cm margin; this is not standing-person clearance. Real low obstacles stay blocked.
Radius clearance runs in the planner and the native viewer uses the same mask.
Manual movement checks substeps no longer than half a cell to prevent skipping
obstacles. The registered renderer/detector frame and 11 equipment bounds remain
unchanged; the reviewed pump approach moves only 3.5 cm to a finer cell centre.

The repository includes the generated navigation map at `assets/valmet/site.json`
and its PNG illustration at `docs/images/equipment-room-walking-paths.png`.
Regenerating the scan assets also refreshes the navigation JSON.

The current Equipment Room build contains 3,213 observed floor cells. With the
default 0.10 m radius, 2,130 cells pass clearance and 2,106 connect to the pump:
21.06 m², compared with 11.19 m² previously. Seven reviewed room regions,
including the upper-middle aisle, are reachable. The remaining 24 clearance-valid
cells form small separate patches; they are not shown as connected walking paths.
The upper aisle was checked in actual Gaussian renders from both directions.
Run `flutter test test/scan_navigation_test.dart` after generating local assets to
check these connections, low obstacles, equipment bounds and preview arrival.

![Equipment Room walking connections](docs/images/equipment-room-walking-paths.png)

Teal lines show the connected 0.10 m virtual-camera walking network; orange shows
the 3.10 m pump route. The picture uses the same registered coordinates,
equipment catalogue and full-scan asset as the app. The overhead illustration
cuts geometry above 1.35 m to reveal the floor.

The **Virtual camera radius** selector checks obstacles, unknown floor and map
boundaries. If a target has no route, free exploration remains available.
A blocked starting point is reported explicitly.
Physical AR movement cannot be constrained; leaving the mask displays a warning.

On the iPhone, set the start and direction, then follow the mint floor arrows along the curved line to the
gold service marker in the 3D viewer. Walk with the phone or enable **Forward and backward controls** to
move with arrows and turn by rotating the phone. **Show camera** switches to
the camera feed, and **Reset alignment** lets you align again. Arrival uses
horizontal distance to the service point, separately from target recognition.
The viewer frames nearby catalog objects within 2.5 m and labels visible frames
with their synthetic condition. The panel lists the three closest objects.
The scene includes 17 reviewed frames and the bundled detector has 11 classes.
When the workbook is loaded, yellow boxes are limited to scene objects with a
compatible workbook tag. The supplied data maps five pumps and one inline valve.
A box requires two consecutive detections that agree with the mapped 3D bounds.
At the service point, tap **Open maintenance report** below the arrival message.

To demonstrate a moving obstacle, enable **Movable demo crate** before opening
the viewer. Align, tap **Place demo crate**, and aim down at its tag. After the
tag is seen in two frames, the planner applies the observed footprint to the
walkable map and redraws a blocked route. **Move demo crate** repeats the check.
If the new footprint covers your position, step back onto a walkable cell to
recalculate the route. With button controls, use **Reset alignment** to return
to the start and replan.
The demo uses a tagged simulated crate with a known size and height.

To verify placement and mask replacement on iPhone:

```sh
xcrun devicectl device process launch --device <device> --terminate-existing --console <bundle-id> -- \
  --verify-obstacle-reroute "$(dart tools/verify_service_route.dart)"
```


The importer writes ignored `assets/valmet/asset-data.json`, retaining original
values, worksheet row references and a workbook SHA-256. It imports the included
3-day telemetry sample, not the unavailable full telemetry CSV. Original inputs
can be kept in ignored `sources/valmet/`. Keep source and generated data local.

By default it sorts service-object IDs and associates them with compatible
workbook classes by increasing health score, breaking ties by asset ID. The
nearby option considers the remaining scene objects without changing service
targets. Pumps map to `PROCESS_PUMP`. The inline valve uses `CONTROL_VALVE` as
its synthetic valve-family mapping. The app shows the exact workbook tag
alongside the scene name. These workbook identities are synthetic. Override
it with `--mapping /path/to/mapping.json`, whose JSON object maps scene
`object_id` to workbook `asset_id`. Explicit `objectId` or `object_id` values are preferred;
older objects use `grid:x:z:width:depth`. Regenerate/review the mapping when
fallback geometry IDs change. Unknown or duplicate IDs are rejected.
Explicit overrides must match the same equipment classes as automatic mappings.

The iPhone **Inspection evidence** panel shows supplied current state, the
latest telemetry and the two ends of the included sample period, recent events
and work orders, context documents, matching historical hypotheses and their
evidence workflow, and data-quality flags. Workbook evidence keeps its row references.
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


## Desktop render checks

For optional desktop inspection with OpenGL/EGL:

```sh
python3 -m pip install -r tools/requirements-render.txt
python3 tools/render_scene.py --top-down --cut-height 1.35 \
  --plan-bounds 1.7163 1.6062 11.2871 9.5537 \
  --width 2400 --height 2000 --output /path/to/equipment-room-plan.png
```

The helper reads the current `boiler-room-sh.splats` format, including degree-3
view-dependent colour, covariance and opacity. It renders depth-sorted Gaussian
ellipses rather than plotting point centres. Use `--camera X Y Z --target X Y Z`
for perspective inspection. Bounds only crop the illustration; they do not alter
the scan or navigation map. Desktop captures do not replace iPhone checks.
