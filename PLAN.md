# Valmet development plan

Updated 6 November 2026. Starting point: source review of commit `c103c63`; iPhone build and runtime behaviour have not been verified in this review.

## Goal and demo

Build an iPhone simulation of being inside the supplied boiler room: **walk/turn with the phone → render the virtual room continuously → run a vision model on those rendered frames on the iPhone → associate detections with 3D equipment → show route guidance and nearby asset information → explain the target fault with supplied evidence.**

Keep the existing Flutter/iOS app as the foundation. Live vision inference on iPhone hardware is a core team requirement, not optional presentation polish. Start with a compact pretrained model and prove device integration before fine-tuning. Add automatic inspection playback alongside physical movement for the requested avatar/robot journey and a repeatable demo. Preserve the full brief’s scene-extraction, navigation, metadata and diagnostics requirements.

Full requirements and scoring: [challenge notes](challenge-shortlist.md). Source setup: [README](README.md).

## Core runtime loop

1. ARKit tracks phone movement in the user's real room. After alignment, movement drives the virtual camera in the supplied boiler-room scene.
2. The iPhone renders the virtual room. Capture clean rendered image frames before drawing boxes, labels, route arrows or other UI.
3. A compatible compact vision model runs on the iPhone, preferably through Core ML. Its recognition input is the rendered boiler room, **not the real camera feed**. ARKit may still use the real camera for tracking.
4. Pair each analyzed frame with its capture-time virtual camera pose, projection and timestamp. Use depth/scene geometry to associate detections with persistent 3D objects. Account for inference delay and do not attach results using a newer camera pose.
5. The scene map stores confirmed object locations; navigation uses that map for targets outside the current view. A detector cannot locate unseen equipment from a single frame. Render stable boxes/guidance and look up the object's synthetic workbook mapping.
6. On arrival, show evidence-grounded diagnostic guidance. Decide separately where diagnostic generation runs; on-phone vision does not automatically mean all AI runs on the phone.

Do not encode a video just to analyze it: pass sampled renderer frames directly to inference. Decouple render and inference rates, keep only the newest pending frame, and avoid blocking rendering. Start by experimenting with a few inference frames per second; this is a tuning proposal, not a measured performance claim.

Physical movement is handheld VR-style simulation, not recognition/localization in the real boiler room. Keep the real walking area clear, preserve the real-camera switch, and provide a recenter/reposition or virtual-movement option where physical space is insufficient. Virtual obstacles cannot protect the user from real furniture.

Offline scene preparation, model training and export may happen on Linux/Mac/GPU hardware. The deployed vision model must run on the actual iPhone without server inference. Confirm target iPhone model and iOS version before choosing the model; both are currently unspecified.

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

First prove **phone motion → rendered boiler-room frames → pretrained vision inference on iPhone → detection overlays** on the actual device. Measure rendering and inference together. The baseline may initially detect poorly; that reveals the recognition gap to address with labels/adaptation. Then complete one inspection journey with a confirmed target and mapped evidence. One target is the integration milestone; the final submission still needs broad asset extraction and nearby-object display.

Statuses: **Ready → In progress → In review → Done**. The coordinator updates this table. Done means merged and checked in the combined application. Branch names below are suggested, not already created.

| Task | Owner | Status | Suggested branch | Done when |
| --- | --- | --- | --- | --- |
| Validate scene preparation and coordinate system | 1 + 3 | Ready | `scene/validate-room` | Actual scan renders; axes, scale, floor, filtering and device behaviour are recorded |
| Agree shared object/data interface | 1 + 2 + 3 | Ready | `integration/asset-contract` | Sample object, bounds, asset mapping and viewer result are understood by all three |
| Confirm target phone and baseline model/export | 1 + 3 | Ready | `vision/iphone-baseline` | Model loads and predicts on the actual phone; input format, labels, size and latency are recorded |
| Capture clean rendered frames and run live inference | 3 + 1 | Ready | `vision/rendered-frame-loop` | Boiler-room frames, not real camera images, reach the local model; overlays are excluded; stale frames do not queue |
| Associate detections with multiple 3D assets | 1 + 2 + 3 | Ready | `scene/extract-equipment` | Capture-time pose/depth association produces inspected persistent boxes; duplicates, uncertain identities and unseen targets are handled |
| Import workbook and map a faulty target | 2 | Ready | `ai/asset-data` | Target and surrounding assets show reproducibly mapped supplied records, clearly labelled synthetic |
| Validate routes and add automatic inspection playback | 2 + 3 | Ready | `navigation/inspection-route` | Start-to-target movement follows the walkability model; unreachable cases are handled |
| Show nearby assets and their condition | 3 | Ready | `ui/proximity-overlays` | Boxes and information change with simulated position without showing every asset at once |
| Add grounded arrival diagnostics | 2 + 3 | Ready | `ai/asset-diagnostics` | Arrival shows observations, hypotheses, evidence references and a supported next check |
| Write demo story and collect company feedback | 4 | Ready | `demo/story-and-plan` | One user, problem, journey and value are clear; feedback is recorded |
| Label rendered data and improve/fine-tune model if needed | 1 | Ready | `vision/model-adaptation` | Train/evaluation viewpoints are separate; adapted export is compared with baseline on the phone; classes and limits are disclosed |
| Benchmark combined rendering and vision | 1 + 3 + 4 | Ready | `vision/device-evaluation` | Record actual phone/iOS, scene coverage, render FPS, inference latency/rate, sustained behaviour and recognition errors; verify inference without connectivity |
| Record video, prepare slides and submission | 4, with all members | Ready | `demo/submission` | Video, 5–8 slides, technical note, README, source ZIP and submission fields are checked |

## How to work in parallel

- Members 1 and 3 first agree on image size/orientation, model format, labels and result format. Member 1 prepares the model and rendered dataset; member 3 integrates clean frame capture and inference on the Mac/iPhone. Member 2 independently imports workbook data and builds routes using sample objects. Member 4 shapes the story and collects measurements as pieces arrive.
- Agree edits to shared files before starting. Members 1 and 2 share Python preparation concerns; members 2 and 3 share route playback concerns. Split those changes explicitly rather than editing the same functions concurrently.
- Use one branch per small milestone, push progress, open a PR, and merge working improvements frequently. Bring updated main into ongoing work when shared interfaces change.
- Separate AI coding sessions on one machine need separate worktrees, or carefully separated file ownership in a shared workspace. One coordinator handles Git operations for agents sharing a workspace.
- Mac build/device checks are required for iOS changes. Other members can contribute from Linux. Keep a stable demo version before attempting risky model or rendering improvements.

## Shared agreements before integration

| Topic | Agreement needed |
| --- | --- |
| Vision input | Clean simulated RGB frames, image size/orientation, pixel normalization, capture timestamp and matching virtual pose/projection |
| Model handoff | Compatible Core ML export, version, class labels, preprocessing, output box coordinates/confidence and evaluation examples |
| Frame scheduling | Independent render/inference rates, bounded in-flight work, result age and behaviour while detections are pending |
| Coordinates | Same origin, axes, scale and floor in scene, routing and viewer; validate the current metre assumption |
| Object identity | Stable scene `object_id`, separate mapped workbook `asset_id`, label, 3D bounds and confidence |
| Synthetic mapping | A reproducible mapping; never imply a visually detected device ID is physically verified |
| Navigation | Start pose, route points, reachable result, approach point and avatar clearance |
| Proximity | One agreed distance rule for showing nearby objects |
| Diagnostics | Condition, observations, hypotheses, source IDs, uncertainty and next check |
| Local operation | Vision inference must run on the phone; record location of scene preprocessing, training and diagnostics separately. Prove offline inference on device |

## Known gaps and decisions

- The full brief favours lightweight UI and backend intelligence. iOS with live on-phone recognition is our chosen product requirement; keep it focused so the scored spatial/data/diagnostic work is delivered.
- The main scene builder currently selects a generic geometric inspection target; this is not semantic recognition or fine-tuning.
- The source PLY produced suspicious values in a basic binary inspection. Current code filters invalid records; validate retained scene coverage rather than treating filtering as proof that the source issue is resolved.
- Workbook scene coordinates are placeholders. Remap them to extracted objects; the brief explicitly allows procedural/random metadata association.
- The local workbook contains 4,320 telemetry samples. Its referenced `telemetry_full_14d_30min.csv` is not in the supplied ZIP. Use the included sample unless more data is provided.
- Knowledge_Docs contains eight context documents; the 38-entry RAG index also references asset cards. Do not assume 38 separate document files are supplied.
- Original scans, workbook, videos and generated scene assets remain local unless redistribution is authorized. The ignored local source folder is `sources/valmet/` on the machine where it was set up; teammates need their own approved copy.
- The brief asks for a video of at most five minutes; the saved event guide recommends roughly two minutes. Aim for a clear two-minute submission video and 5–8 slides. Confirm final form requirements before submitting.

## Demo and delivery checkpoints

1. Agree the story now: simulated first-person room exploration with genuinely on-phone vision, connected to the scored service journey.
2. Prove the render-to-model loop on the phone before fine-tuning. Establish a working inspection journey and improve recognition against measured failures rather than training without a baseline.
3. Show an early working version to Valmet during available mentoring, and record feedback.
4. Prepare a first complete recording Saturday evening. Show motion controlling the virtual scene and recognition continuing without connectivity. Disclose synthetic mapping, supported equipment classes, missed detections and whether the model is pretrained or fine-tuned.
5. Submit in sinceai.app before Sunday 8 November at 10:00 Finnish time. Check links, files and terms early; member 4 coordinates and another member verifies.
6. If selected for the finals, prepare the four-minute live presentation and jury questions. Keep automatic playback available as a reliable demonstration path.
