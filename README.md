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

On an ARKit-capable iPhone, select a service target and tap **Walk inside the 3D model**. Stand at the physical spot that should correspond to the virtual start, hold the phone upright and face the direction of the first route segment. The app assumes an initial phone height of 1.75 metres and uses the phone’s angle for the view. Tap **Set start and direction**. ARKit drives the virtual camera with the phone's rotation and translation, with one physical metre equal to one model metre. **Show camera** switches back to the live view while tracking continues. Use **Reset alignment** to choose a new physical start.

The iPhone demo loads the organizer-provided Industrial Boiler Room scan. From the repository root, install NumPy and prepare the local assets before building:

```sh
python3 tools/build_boiler_room.py "/path/to/Industrial Boiler Room.ply"
```

The importer filters invalid EGS vertices and renders the remaining anisotropic Gaussians with Metal. It estimates the walkable floor and chooses a demo inspection target from observed geometry. The scan's scale is assumed to be metres. Keep the original and generated assets local unless public redistribution is authorized. A manually aligned model does not detect differences between virtual and physical obstacles.

## Navigation and inspection evidence (member 2)

The Flutter screen plans four-neighbour routes over the observed floor. The
**Virtual avatar radius** selector checks clearance against obstacles, unknown
floor and map boundaries. No route disables walkthrough/playback. The prepared
boiler-room grid currently supports the **0.10 m virtual camera** preview, but
not the default 0.20 m avatar along the complete journey. This is a simulation
radius, not evidence of clearance for a person. Validate the scan floor and scale
before making larger-avatar claims.

**Play route preview** animates the map marker at 0.7 m/s, with pause and reset.
On the iPhone, align first, then use **Play route preview** in the 3D viewer for
an automatic camera journey. Pause holds the virtual pose. **Show camera** pauses
playback; **Reset alignment** leaves preview mode and lets you align physical
movement again. Arrival uses horizontal distance to the service point, separately
from target recognition. The yellow mapped marker is not a vision detection.

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
`object_id` to workbook `asset_id`. Explicit `object_id` values are preferred;
older objects use `grid:x:z:width:depth`. Regenerate/review the mapping when
fallback geometry IDs change. Unknown or duplicate IDs are rejected.

The arrival panel and iPhone **Inspection evidence** button show supplied current
state, latest included telemetry, recent events/work orders, context documents,
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

The iOS playback/evidence integration needs a Mac/Xcode build and physical iPhone
check. On Linux the Dart planner, playback, evidence retrieval, importer and
Flutter controls can be tested independently. No new Flutter packages are needed.
