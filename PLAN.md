# Valmet development plan

Updated 6 November 2026. Starting point: source review of commit `c103c63`; iPhone build and runtime behaviour have not been verified in this review.

## Goal and demo

Build a simulated field-service journey in the supplied boiler room: **select a faulty device → automatically navigate around obstacles → highlight nearby equipment and its condition → explain the target fault with evidence and the next inspection step.**

Keep the existing Flutter/iOS app as the presentation foundation. Motion-controlled exploration is part of our vision; add automatic inspection playback for the requested avatar/robot journey and a repeatable demo. Scene understanding, navigation, workbook integration and diagnostics take priority over UI polish. Fine-tuning is an optional improvement, not a prerequisite or a deliverable by itself.

Full requirements and scoring: [challenge notes](challenge-shortlist.md). Source setup: [README](README.md).

## Four-person ownership

Names are not assigned in this document. Agree on the people before starting parallel work.

| Member | Owns | Main output |
| --- | --- | --- |
| 1 — Scene understanding | Load and validate the scene; identify distinct equipment; persistent 3D boxes and labels | Extracted objects and scene geometry for navigation and overlays |
| 2 — Navigation and AI | Walkable routes, automatic movement, workbook mapping and grounded fault explanations | A route to the faulty target and evidence-backed diagnosis |
| 3 — UI | Target selection, walkthrough, guidance and proximity overlays; iPhone integration | A clear, usable complete journey |
| 4 — Demo and coordination | Demo story, Valmet feedback, shared plan, slides, video, rehearsal and submission | A convincing and submission-ready demonstration |

Members 1–3 supply results, screenshots and limitations to member 4 throughout development. Member 4's feedback shapes the build. Select one integration owner from the team; that person coordinates PR review and merging, with AI assistance.

Connection: **member 1 finds the objects → member 2 connects data and plans the journey → member 3 presents it → member 4 explains its value and evidence.**

## Current starting point

| Area | What exists in the reviewed code | What remains |
| --- | --- | --- |
| Scene | PLY preparation, filtering and native Gaussian-splat rendering | Verify retained geometry, scale, floor and device performance |
| Navigation | Observed-floor grid and shortest grid route | Validate obstacle clearance and add automatic avatar/camera movement |
| Viewer | Flutter target selection and ARKit motion-controlled virtual walkthrough | Multiple assets, proximity boxes/status and diagnostic display |
| Assets | Main builder creates one generic inspection target | Extract many distinct assets with stable IDs and 3D bounds |
| Data and AI | No workbook importer or diagnostic pipeline found | Map supplied records, retrieve evidence and produce grounded guidance |
| Fine-tuning | No training pipeline or trained detector found | Only attempt after a baseline and evaluation are available |

These are code observations, not completed acceptance checks. Generated assets stay local and are not included in Git.

## Next milestone

Get **one complete inspection journey through the actual scene** working before expanding asset coverage or model complexity. One target is the integration milestone; the final submission still needs broad asset extraction and nearby-object display.

Statuses: **Ready → In progress → In review → Done**. The coordinator updates this table. Done means merged and checked in the combined application. Branch names below are suggested, not already created.

| Task | Owner | Status | Suggested branch | Done when |
| --- | --- | --- | --- | --- |
| Validate scene preparation and coordinate system | 1 + 3 | Ready | `scene/validate-room` | Actual scan renders; axes, scale, floor, filtering and device behaviour are recorded |
| Agree shared object/data interface | 1 + 2 + 3 | Ready | `integration/asset-contract` | Sample object, bounds, asset mapping and viewer result are understood by all three |
| Extract multiple 3D assets | 1 | Ready | `scene/extract-equipment` | Distinct persistent boxes are inspected; duplicates, labels and uncertainty are recorded |
| Import workbook and map a faulty target | 2 | Ready | `ai/asset-data` | Target and surrounding assets show reproducibly mapped supplied records, clearly labelled synthetic |
| Validate routes and add automatic inspection playback | 2 + 3 | Ready | `navigation/inspection-route` | Start-to-target movement follows the walkability model; unreachable cases are handled |
| Show nearby assets and their condition | 3 | Ready | `ui/proximity-overlays` | Boxes and information change with simulated position without showing every asset at once |
| Add grounded arrival diagnostics | 2 + 3 | Ready | `ai/asset-diagnostics` | Arrival shows observations, hypotheses, evidence references and a supported next check |
| Write demo story and collect company feedback | 4 | Ready | `demo/story-and-plan` | One user, problem, journey and value are clear; feedback is recorded |
| Improve extraction/model quality | 1 | Ready | `scene/model-improvement` | Improvement over the baseline is evaluated on separate examples; no unsupported fine-tuning claim |
| Record video, prepare slides and submission | 4, with all members | Ready | `demo/submission` | Video, 5–8 slides, technical note, README, source ZIP and submission fields are checked |

## How to work in parallel

- Member 1 works on actual scene extraction while member 2 uses sample objects and imports workbook data; member 3 uses the same sample objects/results to build the UI. Member 4 writes the story and tests the flow as pieces arrive.
- Agree edits to shared files before starting. Members 1 and 2 share Python preparation concerns; members 2 and 3 share route playback concerns. Split those changes explicitly rather than editing the same functions concurrently.
- Use one branch per small milestone, push progress, open a PR, and merge working improvements frequently. Bring updated main into ongoing work when shared interfaces change.
- Separate AI coding sessions on one machine need separate worktrees, or carefully separated file ownership in a shared workspace. One coordinator handles Git operations for agents sharing a workspace.
- Mac build/device checks are required for iOS changes. Other members can contribute from Linux. Keep a stable demo version before attempting risky model or rendering improvements.

## Shared agreements before integration

| Topic | Agreement needed |
| --- | --- |
| Coordinates | Same origin, axes, scale and floor in scene, routing and viewer; validate the current metre assumption |
| Object identity | Stable scene `object_id`, separate mapped workbook `asset_id`, label, 3D bounds and confidence |
| Synthetic mapping | A reproducible mapping; never imply a visually detected device ID is physically verified |
| Navigation | Start pose, route points, reachable result, approach point and avatar clearance |
| Proximity | One agreed distance rule for showing nearby objects |
| Diagnostics | Condition, observations, hypotheses, source IDs, uncertainty and next check |
| Local operation | Record which processing runs on a computer and which runs on the phone; do not claim phone-only inference unless demonstrated |

## Known gaps and decisions

- The full brief favours lightweight UI and backend intelligence. Native iOS is our presentation choice, not a judging requirement.
- The main scene builder currently selects a generic geometric inspection target; this is not semantic recognition or fine-tuning.
- The source PLY produced suspicious values in a basic binary inspection. Current code filters invalid records; validate retained scene coverage rather than treating filtering as proof that the source issue is resolved.
- Workbook scene coordinates are placeholders. Remap them to extracted objects; the brief explicitly allows procedural/random metadata association.
- The local workbook contains 4,320 telemetry samples. Its referenced `telemetry_full_14d_30min.csv` is not in the supplied ZIP. Use the included sample unless more data is provided.
- Knowledge_Docs contains eight context documents; the 38-entry RAG index also references asset cards. Do not assume 38 separate document files are supplied.
- Original scans, workbook, videos and generated scene assets remain local unless redistribution is authorized. The ignored local source folder is `sources/valmet/` on the machine where it was set up; teammates need their own approved copy.
- The brief asks for a video of at most five minutes; the saved event guide recommends roughly two minutes. Aim for a clear two-minute submission video and 5–8 slides. Confirm final form requirements before submitting.

## Demo and delivery checkpoints

1. Agree the story now and use it to prioritize implementation.
2. Complete the first end-to-end journey before optional fine-tuning or further UI polish.
3. Show an early working version to Valmet during available mentoring, and record feedback.
4. Prepare a first complete recording Saturday evening; measure claims and disclose synthetic data, procedural mapping and limitations.
5. Submit in sinceai.app before Sunday 8 November at 10:00 Finnish time. Check links, files and terms early; member 4 coordinates and another member verifies.
6. If selected for the finals, prepare the four-minute live presentation and jury questions. Keep automatic playback available as a reliable demonstration path.
