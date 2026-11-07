# ServicePath

Extracts equipment from a 3D scan, guides technicians to faulty machines, and shows what to check next.

Built by **Just Vibes** for the Valmet challenge at Since AI Hackathon 2026. The simulator combines Valmet’s boiler-room scan with its synthetic maintenance workbook. Follow a planned route to a faulty pump, see nearby equipment and its recorded status, then open a report with the evidence for the next inspection.

![Walkable floor grid over the Equipment Room scan](docs/images/equipment-room-walking-paths.png)

- **3D extraction.** RF-DETR detections from multiple rendered views and the scan geometry localized 33 known equipment assets. A separate voxel search found one reviewed display stand.
- **Navigation.** A 10 cm floor grid and clearance checks guide automatic walkthroughs and manual exploration. Floor arrows and a minimap show the route. Orange arrows guide the technician back after a deviation.
- **Diagnostics.** Stable equipment IDs connect 3D frames to synthetic workbook records. The offline P-005 report shows the motor-current trend and cites the workbook for its recommended hydraulic-path inspection.

The route audit covered **12,636 shortest paths** in the mapped room. All six simulator service routes opened the matching report. In the same-room 3D comparison, **32 of 33** fitted boxes reached an IoU of at least 0.50 against reviewed bounds. Live recognition was evaluated separately.

## Run locally

Obtain approved local copies of the complete `Equipment Room.ply` replacement scan and Valmet’s synthetic builder workbook. From the repository root, with Python and Flutter installed:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r tools/requirements-spatial.txt
flutter pub get

python tools/build_boiler_room.py "/path/to/Equipment Room.ply" --output build/spatial-input
cp assets/valmet/reviewed-asset-tags.json build/spatial-input/
python tools/spatial_backend.py \
  --assets build/spatial-input \
  --scan "/path/to/Equipment Room.ply" \
  --workbook "/path/to/Valmet builder workbook.xlsx"
```

The command prepares the scene and workbook exports. To run the app, follow [Run on iOS](DEVELOPMENT.md#run-on-ios) for asset setup and Xcode signing.

[Technical note](docs/TECHNICAL-NOTE.md) · [3D fitting and validation](docs/AI_DEVELOPMENT_REPORT.md) · [Full development and reproduction guide](DEVELOPMENT.md)
