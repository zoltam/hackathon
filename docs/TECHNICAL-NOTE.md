# Valmet Field App · Technical note

## Scan preparation and 3D assets

The original Industrial Boiler Room PLY passed structural checks for 502,482 of 1,506,136 records. The demo uses the complete Equipment Room replacement. The Python/NumPy pipeline validates and registers all 1,676,481 Gaussians to the reviewed scene frame. Swift/Metal renders anisotropic splats with opacity and degree-3 view-dependent color. Model distances assume one registered unit equals one metre.

Extraction starts from 17 reviewed 3D seed volumes. The builder selects supporting Gaussians and refines bounds from their coordinates where applicable. It stores a stable object ID, type, 3D bounds and support count for each frame. Eleven equipment instances form the detector catalog. Six surrounding objects are framed for proximity display. Coverage is limited to the seeded catalog.

## Recognition and 3D association

On macOS, Swift/Metal and Pillow prepare labeled renders and portrait crops. Scene masks produce 2D training boxes from the visible parts of registered volumes. Apple Create ML trains an ObjectPrint transfer-learning detector. The bundled R3 Core ML export used 720 training images from the same simulated room.

On iPhone, Vision/Core ML runs on clean Metal-rendered frames sampled at up to 8 Hz, skipping frames while inference is busy. ARKit tracks physical phone motion for the manual walkthrough. The detector receives only rendered pixels and returns catalog IDs, boxes and scores. Each frame carries its capture-time pose, projection and timestamp. For current results, the app projects the matching catalog volume into the captured frame and checks overlap. It keeps the strongest box per ID and requires two consecutive observations before showing a yellow box. Teal proximity frames and mapped status use the scene geometry within 2.5 m.

## Route and changing obstacles

Flutter/Dart uses four-neighbour breadth-first search on a 10 cm grid built from observed floor support and obstacle occupancy. The default 10 cm camera radius leaves 2,106 clearance-valid cells connected to the pump approach, covering 21.06 m². The first-person demo follows a computed 3.10 m route. Arrival is based on the separate service cell. The 1.55 m obstacle ceiling models virtual-camera clearance.

For the opt-in crate demo, Apple Vision reads a QR tag in the rendered view. Capture-time projection and the known tag height locate the crate from its corners. After two consistent observations, the planner replaces the blocked footprint and replans from the current position when needed. It reports an unreachable target if no route remains. The obstacle experiment covers one tagged simulated object.

## Workbook and service guidance

Python/openpyxl imports eight workbook sheets into local JSON, preserving worksheet row references and workbook SHA-256. The demo maps 17 scene IDs to distinct synthetic workbook IDs. The default mapping assigns the lowest health score to the first service target, then assigns remaining records to nearby objects. An explicit mapping is also supported.

At arrival, Dart retrieves current state, latest sampled telemetry, recent alarms and maintenance, matching historical cases, context documents and quality flags. The red pump maps to synthetic ASSET-017. The workbook describes an efficiency-loss or fouling-like signature and recommends inspecting the hydraulic path (Current_State!18). Guidance is deterministic workbook retrieval. The confidence shown comes from the workbook, and the cause remains unconfirmed. The import includes 4,320 telemetry rows from the supplied three-day sample. The referenced full 14-day CSV was unavailable.

## Recorded evidence and scope

- Held-out same-room renders at IoU ≥ 0.50 and score ≥ 0.25. R3 aggregate F1 was 91.54% on 88 original views and 81.43% on 69 walking views. Raw pump detections were 13/18 and 67/69, with two and three false pump detections respectively. Replaying the app's pose-based filter and per-ID deduplication on the walking views raised F1 to 85.21% and removed all three false pump detections. This replay measured independent frames.
- iPhone 15, iOS 26.5, 15-second scripted render benchmark. 29.67 GPU FPS, 29 predictions, 5 ms median and 7 ms p95 inference latency. The scripted journey confirmed the pump, displayed up to four mapped proximity frames and arrived after 20.34 s.
- The stationary-camera crate test localized two placements, blocked the original route and then the active detour, and reopened 27 cells after the move. A physical walkthrough with Wi-Fi and cellular disabled remains unverified.

Setup and repeatable checks are in the [README](../README.md). Model selection and device evidence are in the [development plan](../PLAN.md).
