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

On an ARKit-capable iPhone, select a service target and tap **Walk inside the 3D model**. Stand at the physical spot that should correspond to the virtual start, face the direction of the first route segment, and aim at the floor a short distance ahead. Tap **Set start and direction**. ARKit drives the virtual camera with the phone's rotation and translation, with one physical metre equal to one model metre. **Show camera** switches back to the live view while tracking continues. Use **Reset alignment** to choose a new physical start.

The bundled boiler room is a demonstration model. To use a PLY scan, generate and review a replacement model with `python3 tools/import_ply.py --help`, then rebuild with the resulting `assets/site.json`. This renders the extracted floor and obstacle geometry. A manually aligned model does not detect differences between virtual walls and physical obstacles.
