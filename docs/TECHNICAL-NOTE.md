# Valmet Field Service Copilot — Technical note

## From scan to equipment

Python and NumPy validate and register the supplied Equipment Room scan, which contains 1,676,481 Gaussians. RF-DETR Nano detects known equipment in clean renders from multiple viewpoints. The offline fitter triangulates detections using camera poses, then projects candidate Gaussians back into the supporting views to estimate 3D bounds. Stable equipment IDs link those bounds to the route planner and workbook. The iOS viewer applies reviewed locations only when the source scan hash matches.

The pipeline localized 33 known equipment assets. A separate voxel search found one reviewed display stand. For 32 of the 33 assets, the fitted box reached at least 0.50 3D IoU against previously reviewed bounds from the same room.

## Navigation and rendering

Flutter and Dart plan shortest paths on a four-neighbour floor grid. Floor support, obstacle occupancy and clearance checks determine where the simulated technician can move. The 10 cm grid supports six reviewed service approaches. Swift and Metal render the scan, nearby equipment frames and route arrows at a 30 FPS target. ARKit drives manual exploration on iPhone. If a technician stays at least 1.5 m off-route for one second, orange arrows retrace their path toward the marked route.

The route audit verified 12,636 shortest paths across 2,106 connected starts and six targets, plus 144 unreachable start–target pairs. All six simulated service routes opened the matching report. These checks cover navigation in the scanned room.

## Workbook and diagnostics

Python and openpyxl import eight workbook sheets into local JSON with row references and the workbook hash. The app links five pumps and one inline valve to synthetic service records. Reports retrieve telemetry, alarms, maintenance history and relevant cases on-device. The P-005 report maps to ASSET-017, shows the motor-current trend and cites Current_State!18 for the recommended hydraulic-path inspection. It distinguishes the observed evidence from the suspected cause.

## Model and verification scope

Offline 3D localization and live recognition were evaluated separately. The iOS recognition code uses Vision and Core ML with the Create ML R3 detector and an RF-DETR Nano FP16 supplement. These models process rendered scan frames. Two optional RF-DETR simulator runs reached P-005 and opened its report, but inference arrived too late for target confirmation. The six-route navigation check ran with live vision disabled.

[Setup and reproduction](../README.md) · [3D fitting and validation results](AI_DEVELOPMENT_REPORT.md)
