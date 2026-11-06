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

The iPhone demo now loads the updated **Equipment Room** scan. From the repository root, install NumPy and prepare the local assets before building:

```sh
python3 tools/build_boiler_room.py "sources/valmet/Equipment Room.ply" \
  --full-scene --floor-y 1.17 --name "Equipment Room"
```

The updated scan uses a source floor estimate of y=1.17 (y down). `--full-scene` fits the navigation extent to this scan instead of reusing the old room crop. Recheck the floor and scale on the device. Regenerate workbook mapping after each scene replacement using the command below.

The importer filters invalid EGS vertices and renders the remaining anisotropic Gaussians with Metal. It estimates the walkable floor and chooses a demo inspection target from observed geometry. The scan's scale is assumed to be metres. Keep the original and generated assets local unless public redistribution is authorized. A manually aligned model does not detect differences between virtual and physical obstacles.

## Navigation and inspection evidence (member 2)

The Flutter screen plans four-neighbour routes over the observed floor. The
importer now retains all observed obstacle-free floor patches: **400 cells**, of
which **390 connect to the starting region**. The earlier extra 0.25 m importer
margin reduced this to 164 cells. Clearance now runs once, in the route planner;
unknown gaps remain excluded and disconnected patches remain visible. Floor
support uses measured Gaussians down to 1% opacity, while rendered/body-obstacle
evidence retains the existing approximately 10% threshold. This recovers faint
floor in the narrow strip behind the red vessels without filling unknown holes
or removing the obstacle checks.

**Virtual avatar radius** selector checks clearance against obstacles, unknown
floor and map boundaries. No route disables walkthrough/playback. The updated
Equipment Room grid currently supports the **0.10 m virtual camera** preview, but
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


## Render inspection pictures on desktop

Optional inspection tool (requires desktop OpenGL/EGL, not used by the iPhone):

```sh
python3 -m pip install -r tools/requirements-render.txt
python3 tools/render_scene.py --top-down --cut-height 1.35 \
  --width 2400 --height 2000 --output /path/to/floor-cutaway.png
python3 tools/render_scene.py --camera 6.125 1.5 4.15 \
  --target 6.125 0.05 5.125 --output /path/to/floor-check.png
```

This rasterizes Gaussian ellipses with covariance, alpha and depth sorting. It
uses the source DC colour stored in the app assets, not a point-density scatter
plot. The overhead illustration cuts geometry above 1.35 m to reveal the floor;
perspective checks retain overhead geometry. Desktop pictures do not replace
an iPhone runtime check. Scanned geometry is not a complete collision model.
