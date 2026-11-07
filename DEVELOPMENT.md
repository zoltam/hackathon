# Development and verification

## Run on iOS

Use macOS with Xcode, Python and Flutter. An ARKit-capable iPhone is required
for manual AR navigation. The iOS simulator supports automatic walkthroughs.

Run the offline export from the [README](README.md#run-locally) using approved
local copies of the replacement scan and synthetic workbook. Copy the
matching files from that export into the Flutter asset directory:

```sh
cp build/spatial-input/boiler-room-sh.splats assets/valmet/
cp build/spatial/site.json assets/valmet/person-site.json
cp build/spatial/{asset-data,associations,diagnostics}.json assets/valmet/
flutter pub get
```

Open `ios/Runner.xcworkspace` in Xcode, select a signing team and unique
bundle identifier, then run the Runner scheme. Use the service target picker
and select **Simulate service visit** for the automatic walkthrough. On iPhone,
turn off walking-person simulation to use the live AR walkthrough.

The project bundles the baseline Core ML model and a supplemental RF-DETR
model. See the [detector guide](tools/README-detector.md) for model export
and the [validation report](docs/AI_DEVELOPMENT_REPORT.md) for the evaluation
setup and results.

## Checks

From the repository root, in the Python environment used for the offline export:

```sh
python -m unittest discover -s tools -p 'test_*.py'
flutter analyze
flutter test
```

The private integration checks expect the approved source files under
`sources/valmet/` and the packed scan under `assets/valmet/`. Run the
Runner XCTest target in Xcode for native iOS checks.

To regenerate the route and workbook audits from the local exports:

```sh
dart run tools/audit_service_routes.dart > build/service-route-audit.json
dart run tools/verify_asset_data.dart > build/asset-data-audit.json
```

Keep the supplied scan, workbook, generated exports and detailed audit outputs
local. The app validates scan registration before applying reviewed equipment
locations and uses a legacy scene when the person-sized export is absent.
