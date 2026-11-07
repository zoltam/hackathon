# Valmet development plan

Updated 7 November 2026. The starting-point review below describes commit `c103c63`. See [device evidence](#brief-coverage-and-device-evidence) for later builds and runtime checks.

## Goal and demo

Build an iPhone simulation of being inside the supplied boiler room: **walk/turn with the phone → render the virtual room continuously → run a vision model on those rendered frames on the iPhone → associate detections with 3D equipment → show route guidance and nearby asset information → explain the target fault with supplied evidence.**

Keep the existing Flutter/iOS app as the foundation. Live vision inference on iPhone hardware is a core team requirement, not optional presentation polish. Start with a compact pretrained model and prove device integration before fine-tuning. Add automatic inspection playback alongside physical movement for the requested avatar/robot journey and a repeatable demo. Preserve the full brief’s scene-extraction, navigation, metadata and diagnostics requirements.

Full requirements and scoring: [challenge notes](challenge-shortlist.md). Source setup: [README](README.md).

## Phase 1 — find one object

This is the first user-facing milestone. Support **one predetermined target object** in the supplied boiler-room scene.

1. The technician opens the app and aligns the simulated starting position and direction.
2. The app shows a calculated walkable route to the target's known, mapped 3D location, even when the object is not yet visible.
3. The technician follows the route by walking and turning in their own clear physical room. Phone movement controls the simulated boiler-room view.
4. The on-iPhone vision model analyzes clean rendered frames and recognizes the target when it enters view. Highlight the detected target and associate it with its mapped 3D location.
5. Confirm arrival when the simulated position reaches the target's approach point. Recognition confidence and arrival distance are separate conditions.

**Acceptance:** on the actual iPhone, the user can open, align, see the route, follow it, see the target recognized/highlighted, and reach its service position. Recognition runs locally. Do not present a highlight drawn solely from a stored coordinate as model detection.

For this phase the obstacle map is static. A mapped target position is required before routing; the model does not have to discover an unseen destination. Live target recognition and guidance are the immediate priority. Nearby-asset coverage and workbook-backed diagnostics follow for the full challenge submission.

## Phase 2 — detect changed obstacles and reroute

After phase 1 works, demonstrate an object moved or introduced into the route **inside the simulated boiler room**.

1. Change an obstacle's position in the rendered simulation. Keep the planner's initial map unchanged so the system must detect the discrepancy.
2. The on-phone vision pipeline observes the obstacle in rendered frames and estimates its 3D position and occupied area using matching camera pose and geometry/depth.
3. Confirm the observation before updating the navigation obstacle map. A screen-space box alone is insufficient for routing.
4. Check whether the updated occupancy blocks the remaining route, including avatar clearance.
5. If blocked, calculate a route from the current simulated position and update the guidance. If no route exists, stop guidance and report that the target is unreachable.

**Acceptance:** show the initial route, the changed obstacle, the detected/map update, and a valid alternative route or an explicit no-route result. Do not silently send the scripted obstacle position directly to the planner and claim it was vision-detected. Validate that collision/depth geometry follows the changed object too.

This is a later enhancement, not a blocker for phase 1. Real furniture in the user's physical room is outside the simulated obstacle pipeline. A target-object-only detector may need additional classes, segmentation or another obstacle-detection method for phase 2.

## Core runtime loop

1. ARKit tracks phone movement in the user's real room. After alignment, movement drives the virtual camera in the supplied boiler-room scene.
2. The iPhone renders the virtual room. Capture clean rendered image frames before drawing boxes, labels, route arrows or other UI.
3. A compatible compact vision model runs on the iPhone, preferably through Core ML. Its recognition input is the rendered boiler room, **not the real camera feed**. ARKit may still use the real camera for tracking.
4. Pair each analyzed frame with its capture-time virtual camera pose, projection and timestamp. Use depth/scene geometry to associate detections with persistent 3D objects. Account for inference delay and do not attach results using a newer camera pose.
5. The scene map stores confirmed object locations; navigation uses that map for targets outside the current view. A detector cannot locate unseen equipment from a single frame. Render stable boxes/guidance and look up the object's synthetic workbook mapping.
6. On arrival, show evidence-grounded diagnostic guidance. Decide separately where diagnostic generation runs; on-phone vision does not automatically mean all AI runs on the phone.

Do not encode a video just to analyze it: pass sampled renderer frames directly to inference. Decouple render and inference rates, keep only the newest pending frame, and avoid blocking rendering. Start by experimenting with a few inference frames per second; this is a tuning proposal, not a measured performance claim.

Physical movement is handheld VR-style simulation, not recognition/localization in the real boiler room. Keep the real walking area clear, preserve the real-camera switch, and provide a recenter/reposition or virtual-movement option where physical space is insufficient. Virtual obstacles cannot protect the user from real furniture.

Scene preparation and model training run on a Mac. The deployed model runs locally on iPhone. Scripted and physical offline checks used iPhone 15 with iOS 26.5. The user reported the app now works on iPhone 13.

## Four-person ownership

Names are not assigned in this document. Agree on the people before starting parallel work.

| Member | Owns | Main output |
| --- | --- | --- |
| 1 — Scene and vision model | Validate scene; choose/export a compact detector; label rendered examples and fine-tune if useful; associate detections with persistent 3D equipment | Model artifact, preprocessing/labels, evaluated detections and scene objects |
| 2 — Navigation and AI | Walkable routes, automatic movement, workbook mapping and grounded fault explanations | A route to the faulty target and evidence-backed diagnosis |
| 3 — UI and iPhone integration | Motion-driven simulated view; clean rendered-frame capture; native inference integration; overlays and controls | A responsive on-phone render → detect → overlay loop and complete journey |
| 4 — Demo and coordination | Demo story, Valmet feedback, shared plan, slides, video, rehearsal and submission | A convincing and submission-ready demonstration |

Members 1–3 supply results, screenshots and limitations to member 4 throughout development. Member 4's feedback shapes the build. Select one integration owner from the team; that person coordinates PR review and merging, with AI assistance.

Connection: **member 3 supplies clean rendered frames → member 1 supplies the on-phone model and 3D associations → member 2 connects mapped data and routes → member 3 displays results → member 4 explains the journey and measured evidence.** Members 1 and 3 jointly integrate the live vision loop.

## Current starting point

| Area | What exists in the reviewed code | What remains |
| --- | --- | --- |
| Scene | PLY preparation, filtering and native Gaussian-splat rendering | Verify retained geometry, scale, floor and device performance |
| Navigation | Observed-floor grid and shortest grid route | Validate obstacle clearance and add automatic avatar/camera movement |
| Viewer | Flutter target selection and ARKit motion-controlled virtual walkthrough | Multiple assets, proximity boxes/status and diagnostic display |
| Assets | Main builder creates one generic inspection target | Extract many distinct assets with stable IDs and 3D bounds |
| Data and AI | No workbook importer or diagnostic pipeline found | Map supplied records, retrieve evidence and produce grounded guidance |
| On-phone vision | No rendered-frame capture/inference loop or trained detector found in reviewed code | First prove a compatible baseline model on actual iPhone hardware; then evaluate adaptation |

These are code observations, not completed acceptance checks. Generated assets stay local and are not included in Git.

## Next milestone

Deliver phase 1: **open and align → see the route to one mapped target → follow it → recognize/highlight the target with on-phone vision → confirm arrival.** First prove rendering and baseline inference together on the actual phone, then improve target recognition if needed. Dynamic obstacle detection and rerouting belong to phase 2. Continue the full-brief asset coverage, workbook integration and diagnostics work alongside this milestone; one target alone is not the complete company submission.

Statuses: **Ready → In progress → In review → Done**. The coordinator updates this table. Done means merged and checked in the combined application. Branch names below are suggested, not already created.

| Task | Owner | Status | Suggested branch | Done when |
| --- | --- | --- | --- | --- |
| Validate scene preparation and coordinate system | 1 + 3 | In review | `scene/validate-room` | Actual scan renders; axes, scale, floor, filtering and device behaviour are recorded |
| Agree shared object/data interface | 1 + 2 + 3 | Ready | `integration/asset-contract` | Sample object, bounds, asset mapping and viewer result are understood by all three |
| Confirm target phone and baseline model/export | 1 + 3 | In review | `vision/iphone-baseline` | Model loads and predicts on the actual phone; input format, labels, size and latency are recorded |
| Capture clean rendered frames and run live inference | 3 + 1 | In review | `vision/rendered-frame-loop` | Boiler-room frames, not real camera images, reach the local model; overlays are excluded; stale frames do not queue |
| Recognize and highlight the single target | 1 + 3 | In review | `vision/single-target` | On-phone detection of the rendered target produces a stable highlight associated with its mapped 3D object |
| Complete phase 1 guided walk | 2 + 3 + 4 | iPhone 15 offline pass | `navigation/single-target-walk` | User aligns, sees and follows the route, recognizes the target and reaches its approach point on the actual phone |
| Expand extraction to multiple 3D assets | 1 + 2 + 3 | In review | `scene/extract-equipment` | After single-target integration, expand persistent boxes and labels for the scored extraction/proximity requirements |
| Import workbook and map a faulty target | 2 | In review (six compatible mappings) | `ai/asset-data` | Target and surrounding assets show reproducibly mapped supplied records, clearly labelled synthetic |
| Validate routes and add automatic inspection playback | 2 + 3 | In review (scripted inspection) | `navigation/inspection-route` | Start-to-target movement follows the walkability model; unreachable cases are handled |
| Show nearby assets and their condition | 3 | In review | `ui/proximity-overlays` | Boxes and information change with simulated position without showing every asset at once |
| Add grounded arrival diagnostics | 2 + 3 | In review | `ai/asset-diagnostics` | Arrival shows observations, hypotheses, evidence references and a supported next check |
| Write demo story and collect company feedback | 4 | Ready | `demo/story-and-plan` | One user, problem, journey and value are clear; feedback is recorded |
| Label rendered data and improve/fine-tune model if needed | 1 | In review | `vision/model-adaptation` | Train/evaluation viewpoints are separate; adapted export is compared with baseline on the phone; classes and limits are disclosed |
| Detect a moved simulated obstacle | 1 + 3 | In review (tagged demo) | `vision/changed-obstacles` | Changed scene object is detected from rendered frames and localized; planner is not fed scripted ground truth as detection |
| Update obstacle map and reroute | 2 + 3 | In review (tagged demo) | `navigation/dynamic-reroute` | Confirmed obstacle blocks the old route; guidance updates from current position or reports no route |
| Benchmark combined rendering and vision | 1 + 3 + 4 | In review | `vision/device-evaluation` | Record actual phone/iOS, scene coverage, render FPS, inference latency/rate, sustained behaviour and recognition errors; verify inference without connectivity |
| Record video, prepare slides and submission | 4, with all members | Ready | `demo/submission` | Video, 5–8 slides, technical note, README, source ZIP and submission fields are checked |

## How to work in parallel

- Members 1 and 3 first agree on image size/orientation, model format, labels and result format. Member 1 prepares the model and rendered dataset; member 3 integrates clean frame capture and inference on the Mac/iPhone. Member 2 independently imports workbook data and builds routes using sample objects. Member 4 shapes the story and collects measurements as pieces arrive.
- Agree edits to shared files before starting. Members 1 and 2 share Python preparation concerns; members 2 and 3 share route playback concerns. Split those changes explicitly rather than editing the same functions concurrently.
- Use one branch per small milestone, push progress, open a PR, and merge working improvements frequently. Bring updated main into ongoing work when shared interfaces change.
- Separate AI coding sessions on one machine need separate worktrees, or carefully separated file ownership in a shared workspace. One coordinator handles Git operations for agents sharing a workspace.
- Mac build/device checks are required for iOS changes. Other members can contribute from Linux. Keep a stable demo version before attempting risky model or rendering improvements.

## Rendered-frame inference device check

6 November 2026, iPhone 15 with iOS 26.5. The release build classified three distinct Metal-rendered views with Apple's local Vision image classifier in 107, 59, and 61 ms. These are one initial and two subsequent inference times, not an end-to-end FPS benchmark. Each readback carries the originating camera pose, projection, and timestamp. The render target excludes the UIKit guidance overlay, and readback is capped at two samples per second with at most one sample in flight. This was the generic scene-classifier baseline before the pump verifier. Verification used the currently readable scan and simulated camera poses rather than a physical walk.

The current detector has a separate device check described below. The match/no-match verifier was the earlier, pose-dependent experiment.

The first mapped asset is `boiler-room:red-circulation-pump`. Its manually registered 3D bounds are `[5.77, 1.045, 2.27]` to `[6.10, 1.32, 2.63]` in model metres. The observed-floor route to its separate service cell `[21, 7]` is 3.25 m. The iPhone projects the mapped volume with the sampled frame pose and compares its rendered pixels with three local reference crops via Apple Vision feature prints. This is a verifier for a known 3D location. It does not search the whole image for arbitrary equipment or infer identity from workbook data. On iPhone 15, five target views matched, including one partially occluded view. A view aimed at a different pump and a view aimed away produced no match. Feature distances for the five accepted views were 0.397–0.474, and inference took 12–88 ms including first-use setup. In a separate reproducible macOS evaluation, two held-out target crops scored 0.380 and 0.650 and three other equipment crops scored 0.950–1.075 (lower is closer; threshold 0.72). Run the reference tool with `--evaluate` to repeat. These small pose-driven tests do not establish generalization or physical walk acceptance. The scan and its derived reference images are local.

## Full-frame equipment detector

The on-device detector is an Apple Create ML ObjectPrint transfer-learning model. It receives only the pixels of a clean rendered Metal frame and returns 2D boxes, confidence scores and catalog IDs. It does not use scene coordinates, camera pose, AR camera images or the projected service target as detector input. Camera pose is carried with the sample so old boxes can be hidden after movement. Rendering and routing still use the 3D scene independently.

The following baseline and fine-tuning results used the earlier partial scan. The first trained export was 7.4 MiB. It found 342 of 379 objects on 44 held-out rendered views, with 41 false positives at IoU 0.50 and score 0.25. The route target was found in 7 of 11 labeled views. On iPhone 15 the model returned IDs and boxes from the app's rendered frames. The initial device call took 458 ms; the observed subsequent calls took 15–17 ms. This is inference time, not FPS. Some device views produced false duplicate target labels.

The higher-quality run uses 1440 × 960 lossless renders and native portrait crops derived within the same split. It has 396 training images, 88 validation images and a separate 88-image test split. Camera groups are distinct but represent the same boiler room. On the same higher-quality validation split, the baseline scored 391 TP, 166 FP, 178 FN, while checkpoint 150 scored 449 TP, 70 FP, 120 FN. Target recall rose from 10/16 to 13/16. Validation F1 was 69.45% for the baseline and 82.54%, 88.45%, 88.71%, and 89.09% at iterations 150, 300, 450, and 600 respectively. Checkpoint 600 was selected on validation.

On the same 88-image held-out test, the baseline produced 423 TP, 189 FP, 147 FN (F1 71.57%). Checkpoint 600 produced 522 TP, 65 FP, 48 FN (precision 88.93%, recall 91.58%, F1 90.23%). The red pump improved from 11/18 to 12/18. A true positive requires the correct object ID and IoU ≥ 0.50. The evaluator filters emitted predictions below 0.25; the exported NMS stage may already suppress low confidence boxes. These are rendered views of the same scene, including cropped views derived within each split, not 88 independent physical captures.

Model SHA-256: `43bd9f6551bfdb11ee2d9871c3de122e6ec099e4166525d3d5c6d80cc1ccbe91`. Model selection and benchmark commands are in [README](README.md). Synthetic results do not establish generalization to other boiler rooms.

## Equipment Room detector handoff

The complete scan supplies 396 training images, 88 validation images and 88 separate test images. Rendering uses 1440 × 960 lossless frames and derived portrait views within each split. Scene masks yield 2D reference boxes for visible splats within the 11 registered equipment volumes. The detector receives RGB pixels. Its output ID links to the stored 3D volume.

| Export | Validation F1 | Validation pump | Test F1 | Test pump |
| --- | ---: | ---: | ---: | ---: |
| First detector, unchanged | 50.08% | 8/16 | 53.18% | 9/18 |
| Step 150 | 82.17% | 13/16 | | |
| Step 300, selected | 89.25% | 15/16 | 90.67% | 11/18 |
| Step 450 | 89.19% | 14/16 | | |
| Step 600 | 88.91% | 14/16 | | |

At IoU ≥ 0.50 and score ≥ 0.25, test counts changed from 343 TP, 378 FP and 226 FN to 520 TP, 58 FP and 49 FN. The test views are from the same simulated room. The catalog covers 11 mapped equipment instances. Their stored positions are separate from synthetic workbook IDs and from recognition.

The selected local export is `build/valmet-equipment-room/candidate/equipment-detector.mlmodel` (SHA-256 `7e0d9d80c6948ec6f20a9ea0f3513e79cbe091adc0074bd8331ff3775fc4ad68`). The installed app bundles the same bytes. Source PLY SHA-256 is `83d8c7d99316c08c9719cfc2c5a6b9d1903b89847780e2458adc662c79f32955`. Use the local equipment-room dataset and the checkpoint session at `build/valmet-equipment-room/checkpoints-600` to reproduce model selection.

On iPhone 15 (iOS 26.5), the scripted 15-second complete-scan benchmark processed 449 GPU frames (29.93 FPS) and 29 predictions (5 ms median, 8 ms p95). The first detector on the same scan delivered 29.47 FPS and 6/7 ms median/p95. The selected model returned one red-pump box in each of six scripted samples that showed the pump and no detection in the remaining sample. This checks the renderer-to-model path; a person walking the full route is a separate acceptance check.

## Follow-up training on walkable viewpoints

`/tmp/valmet-pump-references --route-dataset` renders 720 × 1560 native portrait images at walkable cell centers. Each cell belongs to one split. The images vary pitch, yaw and phone height around the pump, with all visible catalog assets labeled from scene masks. We added 192 images to the previous 396 training images and 78 images to the previous 88 validation images by combining the image files and annotation indices within each split. The 69 new test images stayed separate. All views represent the same simulated room.

We trained a new ObjectPrint detector head for 400 steps. Step 200 was selected by target F1 on the new validation views, subject to the original validation guard of at most 3.5 percentage points of aggregate F1 loss and one fewer correct pump detection. Its new validation result was 76/78 pump detections and seven false pump detections.

| Test split | Previous aggregate F1 | New aggregate F1 | Previous pump | New pump |
| --- | ---: | ---: | ---: | ---: |
| New walkable viewpoints, 69 images | 36.92% | 77.02% | 14/69 | 66/69 |
| Original viewpoints, 88 images | 90.67% | 88.08% | 11/18 | 10/18 |

False pump detections rose from 8 to 10 on the new split and from 2 to 4 on the original split. The new model is optimized for walkable portrait viewpoints. On iPhone 15, it returned a single pump box in each of the six scripted pump views and no detections in the remaining view. The 15-second benchmark measured 29.87 FPS with 29 predictions, 6 ms median inference and 7 ms p95.

Local export `build/valmet-equipment-room-r2/candidate/equipment-detector.mlmodel` SHA-256 `3893f04a516ad88cbf24a309cfa6f7e9c5e4c896f8930faed43f26ce73b05194`. The installed app bundles the same bytes. The training log is `/tmp/valmet-equipment-room-r2-training.log`. Pass `--report-label=boiler-room:red-circulation-pump` to the evaluation tool to report pump false positives.

## Follow-up training for both viewpoint sets

`/tmp/valmet-pump-references --legacy-augmentation` adds 132 lossless 1440 × 960 training renders with shifted camera poses and clipped pump views. Append these images and annotations to the previous training split for 720 images total, including all 192 walking views. Validation and test splits stayed fixed. Training and each test split cover all 11 mapped devices.

The 600-step export had the best original-view validation F1 (90.31%). It detected the walking pump in 74/78 validation views with one false pump detection, compared with 76/78 and seven false detections for the previous model. We selected it using the pump F1 fallback within two correct validation detections. The separate release test required higher original-view F1 and no loss of correct pump detections or increase in false pump detections in either test split.

| Test split | Previous aggregate F1 | New aggregate F1 | Previous pump | New pump | False pump detections, previous and new |
| --- | ---: | ---: | ---: | ---: | ---: |
| Original viewpoints, 88 images | 88.08% | 91.54% | 10/18 | 13/18 | 4 and 2 |
| Walking viewpoints, 69 images | 77.02% | 81.43% | 66/69 | 67/69 | 10 and 3 |

Correct detections increased for eight of 11 devices in the original views and stayed equal for two. The wall pump fell from 45/51 to 43/51. Correct detections increased for nine of 11 devices in the walking views and stayed equal for two.

The local export is `build/valmet-equipment-room-r3/candidate/equipment-detector.mlmodel`, SHA-256 `7114588a3fcd9477ef93f72039db10cd89c14305140f3abb907abc2e25fdb239`. It matches the bytes in the iPhone build. On iPhone 15, all six scripted pump views returned the target, one with a duplicate box. The seventh view returned no detections. The 15-second benchmark measured 29.67 FPS, 5 ms median inference and 7 ms p95 (29 predictions, reported thermal state 3).

## Actuator follow-up training

R4 ran 600 steps on 792 images, including 72 additional actuator portraits. The best
middle-actuator checkpoint improved walking validation from 3/18 to 5/18. Left
actuator remained at 0/7. Pump false positives rose from one to four, above the
validation limit, so the published R3 detector remains active. R4 was evaluated
on validation; the held-out test sets were reserved.

R5 added 81 distant portrait views with the actuator and pump visible. Its
600-step checkpoint reached 83.15% walking validation F1, versus 78.70% for R3.
It detected the left actuator in 1/7 views and the pump in 77/78, with seven
false pump detections versus one for R3. The same release gate rejected R5.
In a separate comparison of the app's 3D filter and per-ID deduplication, R5
passed validation. On the walking test both models detected the pump in 67/69
images, but R5 introduced one false pump detection. Its F1 was 85.02% versus
85.21% for R3. The published model remains R3.


The iPhone scripted journey followed the actual 3.10 m Dart route, confirmed
the red pump against its projected 3D bounds, and arrived after 20.38 seconds.
The run finished after 24.70 seconds. A physical AR walk and offline check
remain separate acceptance steps.

Phase 2 supports an opt-in movable crate. The renderer places it in the scan
and the on-device Vision request reads its tag from the same clean frame used
for equipment recognition. The captured projection and known tag height
locate it in the scene. Two consistent observations replace the blocked
footprint, then the Dart planner checks clearance and updates the guide. The
crate's scripted position is used only by the renderer and smoke-test error
check.

## Scene and equipment handoff

The current builder validates and renders all 1,676,481 Gaussians in Equipment Room.ply. Similarity registration to the reviewed scene yielded a 2.32 cm median nearest-neighbor distance. The navigation grid now uses 126 × 129 cells at 0.10 m resolution in the unchanged registered frame. Measured floor centres and bounded Gaussian footprints provide 3,213 floor cells. At the default 0.10 m virtual-camera radius, 2,106 of 2,130 clearance-valid cells connect to the pump approach (21.06 m²). The 1.55 m obstacle ceiling matches the 1.50 m virtual camera plus margin, not standing-person clearance. The imported route from the entrance to the pump is 31 steps (3.10 m). Eleven rendered-region anchors, including the full reviewed upper aisle, remain connected; real low obstacles stay blocked. Distances assume one reviewed scene unit is one metre.

The generated `assets/valmet/site.json` has 33 reviewed objects. The shipped detector covers 11 IDs: five pumps, one inline valve, two control cabinets and three blue actuators. The other 22 objects have 3D proximity frames, including two red vessels, two orange actuators, a doorway valve, ladders, carts and chairs. New frames use silhouettes reviewed in multiple corrected-scan renders and supporting Gaussians lifted into 3D. Each record has a stable `objectId`, `equipmentType`, metric `bounds` and `supportingSplats`. The original six service viewpoints, navigation grid and packed splats are unchanged. Workbook tags are synthetic and stored separately from scene IDs.

On the 69 held-out walking views, replaying the current workbook filter,
capture-time geometry check and strongest box per ID gave 147 true positives,
7 false positives and 22 misses for the six mapped IDs (95.45% precision,
86.98% recall, 91.02% F1 at IoU ≥ 0.50). This is a Mac replay of independent
rendered frames, before the iPhone's two-frame confirmation.

| Synthetic workbook tag | Scene object | Found / labeled | False positives |
| --- | --- | ---: | ---: |
| P-001 | Far circulation pump | 13/14 | 0 |
| P-002 | Black circulation pump | 4/6 | 0 |
| P-003 | Wall circulation pump | 18/29 | 4 |
| P-004 | Middle circulation pump | 38/44 | 3 |
| P-005 | Red circulation pump | 67/69 | 0 |
| CV-003 | Blue inline valve | 7/7 | 0 |

For P-003, four false positives were boxes on the correct pump with IoU
0.318–0.496. Five fragments of at most 1,080 pixels had no usable box.
Confidence was already at least 0.994 for the four misplaced boxes.
R6 added 80 reviewed wall-pump training views from disjoint camera cells.
Step 450 improved wall-pump walking validation from 23 TP / 4 FP to
26 TP / 3 FP, but original-view P-005 went from 16 TP / 0 FP to 14 TP / 2 FP.
None of the four checkpoints cleared the regression checks. R3 remains deployed.

## Shared agreements before integration

| Topic | Agreement needed |
| --- | --- |
| Vision input | Clean simulated RGB frames, image size/orientation, pixel normalization, capture timestamp and matching virtual pose/projection |
| Model handoff | Compatible Core ML export, version, class labels, preprocessing, output box coordinates/confidence and evaluation examples |
| Frame scheduling | Independent render/inference rates, bounded in-flight work, result age and behaviour while detections are pending |
| Coordinates | Same origin, axes, scale and floor in scene, routing and viewer; validate the current metre assumption |
| Object identity | Stable scene `object_id`, separate mapped workbook `asset_id`, label, 3D bounds and confidence |
| Synthetic mapping | A reproducible mapping; never imply a visually detected device ID is physically verified |
| Navigation | Start pose, known mapped target, route points, approach point, arrival distance and avatar clearance; phase 2 adds confirmed obstacle updates and replanning from current pose |
| Proximity | One agreed distance rule for showing nearby objects |
| Diagnostics | Condition, observations, hypotheses, source IDs, uncertainty and next check |
| Local operation | Vision inference must run on the phone; record location of scene preprocessing, training and diagnostics separately. Prove offline inference on device |

## Brief coverage and device evidence

### All-object recognition milestone

The brief rewards the number of distinctly extracted and framed assets. Our
target is at least 30 visually verified scene instances in the complete scan.
Use independent views to check each object's identity and 3D frame. Train on
RGB renders and report image-only precision and recall per instance at IoU
0.50 on held-out camera positions, including distance, angle and occlusion.
Keep source positions disjoint before adding crops. Compare the existing 11
IDs against the shipping model on the original room and walking test sets.
Keep the candidate separate until the regression checks pass. Test the final
iPhone render-to-overlay path, alternate starts and replanning for the six
workbook-compatible service targets. Add workbook tags only for compatible
device classes.

The first six-class context candidate reached 93.2% precision and 50.1%
recall on 177 held-out renders after threshold selection on validation.
Its recall was too low to replace the bundled detector. A unified 30-ID
candidate found each of its classes at least once on 250 held-out renders,
but reached only 54.3% precision and 54.2% recall. On the corrected-scan 11-ID
sets its F1 fell to 33.3% on room views and 58.1% on walking views, compared
with 91.5% and 81.4% for the bundled detector. The candidate stays local.
The 33-ID follow-up preserved legacy training images and their existing boxes,
added missing labels and included more wide and edge-clipped views. It found
all 33 classes on 292 held-out renders at least once, at 54.0% precision and
55.6% recall. Legacy F1 was 80.5% on room views and 71.7% on walking views.
The candidate did not pass the release checks.

A later six-ID specialist reached 91.2% precision and 40.2% recall on the
same 177-image test used for the first context model. On a separate 292-view
set the existing projection and deduplication produced 80.8% precision and
63.3% recall at score 0.25. This measures in-scene association after RGB
inference. No new ID cleared both release criteria. A local 608 × 608
Darknet pilot exported to Vision but produced zero true positives at its
30-step checkpoint, after approximately five minutes on the Mac.

An RF-DETR Nano experiment used the same 33 scene IDs and existing data
splits. Its tenth epoch was selected on validation. The FP16 Core ML export
reached 96.1% precision and 71.2% recall on the 22 new IDs using RGB alone.
Seven new IDs cleared both per-instance gates on validation and test. With
capture-pose matching, deduplication and thresholds fitted on validation for
that pipeline, ten new IDs cleared both gates. On separate 8 Hz rendered
sequences, the two-frame overlay reached 97.2% precision and 71.4% recall.
All 33 IDs had at least one correct overlay, but the two orange actuators
were confirmed in only one and two of their seven eligible frame pairs.
None of the 16 negative frames showed an overlay. These sequence results
use simulated timing. The supplemental iOS build keeps R3 active and needs
an on-device performance and regression check before release.

The epoch-16 typed FP16 candidate improved the 22 novel IDs to 97.0% precision
and 76.7% recall on the held-out test under the image-only locked policy.
Ten novel IDs passed both per-instance gates using RGB alone. The separately
calibrated capture-pose pipeline qualified 14 novel IDs. Across all 33 IDs its
test counts were 2,243 true positives, 81 false positives and 392 misses.
The two orange actuators and rear red vessel remain recall gaps. On independent
8 Hz rendered sequences, the projected two-frame overlay reached 96.6%
precision and 78.0% recall, with no overlays in the 16 negative frames.
A predeclared visibility-reviewed subset contained nine usable new views of
five IDs, all nine correctly detected. That subset complements the original
test and leaves substantial class coverage gaps.

The first epoch-16 release bundled this candidate as a supplement, with 14
approved additional IDs and the existing R3 model handling its original 11.
The source Core ML package, upstream license and optional reproducible local
data/train/export tooling travel with the preview. Phone verification passed
five poses and the alternate 2.0 m P-005 route with arrival evidence. Initial
15-second A/B runs measured 30.00 versus 29.87 rendered FPS, 120 R3 samples in
both runs, and R3 p95 of 6 versus 23 ms. Supplemental p95 was 25 ms with no stale
frames, but only 22 samples were collected because model startup fell inside
the window. A warmed-up measurement and sustained check remain release gates.
The first test restored the published main app afterward.

A subsequent warmed-up 90-second phone run delivered 719 supplemental samples
at 7.99 Hz, with 27 ms p95 inference and one stale sample. Rendering averaged
27.21 FPS versus 28.88 for R3 alone. Primary R3 produced 719 versus 720 samples,
with 28 versus 6 ms p95 inference and 129 versus 110 ms p95 overlay age. Both
runs reported thermal state 2. All 14 additional IDs were confirmed in their
respective fixed views, and the negative view remained empty. The same wall
pump approach was missed in both baseline and combined checks. All six service
journeys passed with the supplement, including the wall pump during walking,
arrival and matching workbook evidence. The supplement is enabled by default
after these checks; `--disable-rfdetr-supplemental` selects R3-only operation.

A separate local experiment continued from the full epoch-16 training
checkpoint at 512 px with 0.3× learning rates for epochs 17–18. It adds 47
reviewed 864 × 1872 training views, for 1,829 images and 17,845 complete-label
boxes. Existing training examples are retained, and validation/test annotation
files are byte-identical. The new camera cells exclude protected static,
temporal, device and blind-view cells. Actual restored optimizer groups and
scheduler rates were checked before training.

A train-only audit found 18 disconnected splats mislabeled as part of the rear
red vessel. Removing their label membership kept the render pixels identical
and removed a 1,166-pixel island on a white panel in the verification image.
The original box was nearly twice the corrected area. A versioned dataset
reproduced all original rear-vessel boxes before correcting 45 training and
eight validation boxes. It preserved RGB files, other labels and the original
test set. The updated validation annotations were locked before model scoring.

Replaying epoch 18 from the same full epoch-17 checkpoint with the repaired
training labels improved aggregate projected validation counts. It gained one
true positive across the two orange actuators and rear vessel over the frozen
512 px baseline. The original epoch-18 checkpoint gained three on the same
revised validation set, meeting the predeclared selection gate. Resume can
change batch order and augmentation draws, which limits causal interpretation.

Typed FP16 Vision evaluation qualified 20 novel IDs on revised validation.
Only nine qualified on both revised validation and the unchanged held-out
test, using frozen thresholds and per-ID precision ≥95% and recall ≥70%.
The projected novel test produced 1,394 true positives, 73 false positives
and 266 misses. The two-frame temporal overlay reached 94.2% precision and
77.5% recall. Eight of the currently enabled 14 novel IDs missed a held-out
gate. The app continues to use the validated 384 px supplement.

Among 84 readable, separated orange-actuator training pairs, A appeared to the
left in 77. The seven genuine reversed pairs came from two camera cells with a
view of the backs of the actuators. A separate training experiment tests the effect
of removing default horizontal mirroring while retaining those real views.
In that replay, the A actuator reached 80.8% recall after association and 57.7%
with RGB alone. The front-leaning ladder fell below the protected recall gate
at 67.5%, so the replay stayed local.

### Threshold-only coverage extension

For eight previously disabled IDs, a 0.01–0.99 validation grid selected the
highest score threshold that retained at least 97% precision and 80% recall
after association. Five IDs qualified. All five passed the archived 292-view
test at precision ≥95% and recall ≥70%. The already enabled 14 IDs retained
their exact score thresholds, and the package uses the same learned weights.

A supplementary evaluation froze 48 new views after numerical and agent
visual review, covering 25 previously held-out camera cells. Its annotations
include 31 IDs. Thirteen IDs had an accepted primary view. The set has no
human signoff and shares coarse cells with earlier tests. Of the five threshold
nominees, floor carton, black shelf cart and yellow-wheel hand truck passed
with adequate support. Rolling chair recorded 15 true positives, one false
positive and six misses, below the 95% precision gate. Short step ladder had
zero positives in this supplementary set and qualified on 62 archived positives.

The four newly enabled thresholds are 0.85 for floor carton, 0.51 for short
step ladder, 0.55 for black shelf cart and 0.51 for yellow-wheel hand truck.
Together they recorded 277 true positives, seven false positives and 85 misses
on the archived test. The RGB-only policy also qualified floor carton and
short step ladder. All four passed their fixed iPhone poses with the normal
launch policy. The empty view and alternate 2.0 m P-005 journey passed, including
the exact workbook tag and arrival evidence. The app now enables 29 IDs.

The 48-view replay for these 29 IDs measured 290 true positives, 26 false
positives and 137 misses after association, giving 91.8% precision and 67.9%
recall. These results describe static views and expose substantial misses
outside the fixed demonstration poses.

### Middle blue actuator handoff

R3 accounted for 110 of the 137 misses in the 48-view replay. The middle blue
actuator was the only nominated replacement after the original room and
walking validation comparison required at least eight positives per split,
precision ≥97%, recall ≥80% and no loss in R3 true positives or increase in
false positives. The locked score is 0.78. It improved the original room test
from 59/2/9 to 66/0/2 and the walking test from 2/0/12 to 12/0/2
(true positives / false positives / misses). The previously examined 48-view
set improved from 2/5/21 to 20/0/3 for this ID. Across the enabled 29 IDs, this
changes that diagnostic replay to 308/21/119, with 93.6% precision and 72.1% recall.

The shipped Core ML contract declares the middle actuator as its sole primary
replacement. A fresh supplemental prediction starts the handoff. A stopped or
stalled supplemental stream restores R3 after clearing its replacement layer.
The contract protects all six workbook service IDs. The iPhone check confirmed
the four new threshold IDs, the middle actuator handoff, P-005, the empty
view, the alternate P-005 journey and R3-only fallback.

On iPhone 15, build `e8e2930` processed 720 supplemental frames in 90
seconds at 8.00 Hz. All 720 passed the freshness check. Rendering averaged
28.88 FPS, inference p95 was 23 ms, and capture-to-overlay p95 was 121 ms.
Alternate scripted routes from `[69,65]` confirmed P-005, P-001 and P-002
and reached their matching workbook reports. CV-003 and P-003 passed
5.6 m and 6.0 m routes from `[66,92]`. The rendered crate check
localized three placements, replanned twice, entered a blocked state, and
recovered the 32-cell route.

### Continuous clearance and parent-valve records

The viewer now measures clearance at the camera's actual position against
observed floor, equipment footprints, map edges and confirmed crate cells.
The previous center-cell check could accept a position too close to a
diagonal obstacle. The native geometry passed 75,944 sampled positions on
79 planned routes, including crate detours and the 0.20 m alternate P-005 route.

The two orange actuators have distinct valve bodies in the scan. The importer
associates them with healthy synthetic parent records CV-001 and CV-002 for
nearby display. Their scene identities and the six existing service assignments
are preserved. The displayed parent tag describes the demo association.

The 384 px replay trained on the repaired rear-vessel and chair annotations.
The chair cleanup narrowed 494 boxes and removed 49 false labels from the
1,829 training images. The native checkpoint replay regressed 11 of the 19
released RF-DETR outputs at locked thresholds against the shipped typed
export. The chair's associated validation result moved
from 75/3/9 to 71/3/13 (true positives / false positives / misses). The candidate
stayed local.

Subsequent device checks use the iOS simulator. The alternate 2.0 m P-005
and 6.0 m P-003 scripts reached their service cells and loaded the correct
reports on the iPhone 17 Pro simulator. R3 reported `Could not create
inference context`, leaving the recognition condition of both scripts
unverified in that runtime. All 18 native simulator tests passed. The
generic iOS release build compiled for later physical-device use.

- The supplied DOCX names the original Industrial Boiler Room PLY. In that
  archive 502,482 of 1,506,136 records pass the structural guard. The team uses
  the complete registered Equipment Room replacement. The scene scale remains
  a model-unit-to-metre assumption.
- The local Core ML detector recognizes the 11 trained catalog IDs. Its
  capture-time projection must agree with each mapped 3D frame. Teal frames
  and their synthetic workbook conditions come from proximity within 2.5 m.
  Yellow boxes require two consecutive image detections. Vision overlays show
  the detected catalog object's scene name. The six compatible mapped objects
  also show their exact Excel tags. A capture-pose replay across all 11
  detector IDs produced 193 true positives, 10 false positives and 57 missed
  annotations on 69 walking renders, before the two-frame display rule.
- With the class-checked workbook mapping, the iPhone scripted 3.10 m route
  confirmed the pump as `P-005 · Red circulation pump` and displayed the
  workbook-based next check at arrival in 20.36 seconds. Up to four nearby
  frames were visible, including two with compatible workbook mappings.
  The user confirmed that a physical offline walkthrough showed P-005 and
  the arrival guidance. The test exposed a tight 5 cm arrival tolerance and
  an inspection report without a visible close control. The revised UI accepts
  positions within 30 cm on the final route cells and adds a close button to
  the report. The iPhone scripted journey passed again with arrival at 18.69 s.
  The user confirmed that the X button closes the report and returns to the route.
  The arrival panel places the filled **Open maintenance report** button
  immediately below the arrival message.
- The 90-second scripted iPhone 15 benchmark completed 2,523 GPU frames
  (28.03 FPS), with 120 predictions per 15 seconds. All 720 predictions
  passed the freshness check and 593 showed at least one confirmed box.
  Final cumulative p95 was 9 ms for inference and 122 ms from capture to
  overlay. GPU throughput fell to 25.40 FPS in the last interval. The
  reported thermal state was 3 throughout. The user reported working
  operation on iPhone 13. No instrumented iPhone 13 timing was recorded.
- On the merged build, all six scripted iPhone 15 journeys reached their
  service cell, confirmed the expected visual target, and loaded the matching
  workbook report. Routes at the default 0.10 m radius were P-005 3.1 m,
  P-004 3.2 m, P-003 4.5 m, P-001 4.5 m, P-002 4.0 m, and CV-003 4.1 m.
  The scan start lacks clearance at 0.20 m and 0.30 m.
- The route regression suite covers all six service targets from twelve starts
  and six replans around a 0.50 m crate. It checks blocked starts and goals,
  disconnected corridors, route recovery and arrival in the planner.
  It also checks 48 wider-clearance combinations across all six targets, four
  starts and 0.20 m and 0.30 m radii. The 21-cell P-005 route from `[69,65]`
  remains walkable at 0.20 m. Radii that cannot fit within the map return an
  empty route before conversion to grid coordinates.
- Scripted inspection checks the supplied route against the same clearance
  mask as the live planner. The iOS simulator rejected a raw-floor route
  outside that mask. Two alternate runs reached P-004 and CV-003 with their
  workbook evidence; simulator Vision could not create an inference context.
  On iPhone 15, `1722341` rejected the unsafe route and completed a 2.1 m
  alternate P-004 run from `[66, 92]` with target recognition and the matching
  workbook report. Five fixed views passed, including cabinet and actuator
  overlays with the workbook loaded and an empty negative view.
- The iPhone 15 passed the P-005 route from cell `[69, 65]` (2.0 m), the
  P-003 route (4.5 m) and the crate-recovery check with the 33-object scene.
  A separate fixed-pose check
  confirmed five of six service targets and rejected the negative view.
  The wall pump was missed in all eight samples from one fixed approach angle.
- The iPhone crate test localized two positions from rendered QR corners. It
  blocked the original route, then blocked the active detour and reopened 27
  cells when moved. The test uses a tagged object and a stationary camera
  at the route start. The interactive crate demo supports movement and a
  no-route state, with planner tests for a fully blocked corridor. An extended
  iPhone test put the simulated camera in a newly blocked cell, confirmed an
  empty route and recovered a 32-cell route after returning to the start with
  the same vision-derived footprint.
- Arrival shows a deterministic summary and the workbook evidence report,
  including dated telemetry endpoints and the evidence workflow from a matching
  historical case when present. [Demo plan](DEMO.md) and [technical note](docs/TECHNICAL-NOTE.md)
  record what the submission can demonstrate and what remains unverified.

## Known gaps and decisions

- The full brief favours lightweight UI and backend intelligence. iOS with live on-phone recognition is our chosen product requirement; keep it focused so the scored spatial/data/diagnostic work is delivered.
- The scene builder uses 33 visually reviewed seed volumes. The enabled detectors cover 29 identities. Rolling chair, rear red vessel and both orange actuators remain below release criteria. Fixed views still expose a wall-pump miss, despite successful scripted service journeys.
- The replacement PLY passed structural validation. Recheck registered equipment bounds in the complete scene before publishing detection metrics.
- Workbook scene coordinates are placeholders. Remap them to extracted objects; the brief explicitly allows procedural/random metadata association.
- The local workbook contains 4,320 telemetry samples. Its referenced `telemetry_full_14d_30min.csv` is not in the supplied ZIP. Use the included sample unless more data is provided.
- Knowledge_Docs contains eight context documents; the 38-entry RAG index also references asset cards. Do not assume 38 separate document files are supplied.
- Original scans, workbook, videos and generated scene assets remain local unless redistribution is authorized. The ignored local source folder is `sources/valmet/` on the machine where it was set up; teammates need their own approved copy.
- The brief asks for a video of at most five minutes; the saved event guide recommends roughly two minutes. Aim for a clear two-minute submission video and 5–8 slides. Confirm final form requirements before submitting.

## Demo and delivery checkpoints

1. Agree the story now: simulated first-person room exploration with genuinely on-phone vision, connected to the scored service journey.
2. Complete the phase 1 single-target guided walk on the phone. Prove the render-to-model loop before fine-tuning and improve recognition against measured failures.
3. Attempt phase 2 changed-obstacle detection and rerouting only after phase 1 works; protect time for the company-required asset coverage, workbook data and diagnostics.
4. Show an early working version to Valmet during available mentoring, and record feedback.
5. Prepare a first complete recording Saturday evening. Show motion controlling the virtual scene and recognition continuing without connectivity. Disclose synthetic mapping, supported equipment classes, missed detections and whether the model is pretrained or fine-tuned.
6. Submit in sinceai.app before Sunday 8 November at 10:00 Finnish time. Check links, files and terms early; member 4 coordinates and another member verifies.
7. If selected for the finals, prepare the four-minute live presentation and jury questions. Keep automatic playback available as a reliable demonstration path.
