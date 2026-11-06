# Valmet Field App

Flutter starter for the Valmet hackathon challenge. See [challenge details](challenges.md).

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

The importer filters invalid EGS vertices and uses the remaining centers and colors for a point cloud preview. It estimates the walkable floor and chooses a demo inspection target from observed geometry. The scan's scale is assumed to be metres. Keep the original and generated assets local unless public redistribution is authorized. A manually aligned model does not detect differences between virtual and physical obstacles.
