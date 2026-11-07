# Valmet two-person delivery plan

Updated 7 November 2026. Baseline `5dfed35`. Previous experiments and detailed measurements are in the Git history of this file. Read the [challenge notes](challenge-shortlist.md) and [setup](README.md) before changing code.

## What the demo must prove

Use the complete Equipment Room replacement scan to extract and frame equipment, calculate and automatically travel a collision-free route to a preselected faulty device, show nearby assets and their synthetic Excel metadata, and open grounded inspection guidance at arrival. Keep the iOS viewer focused on that workflow. The brief weights extraction and framing 30%, navigation and proximity 25%, diagnostics 20%, backend 15%, and demo 10%.

P-005 is the primary demo. Demonstrate the five other service targets in verification. The top release priorities are accurate in-app recognition of all 33 catalog objects and working in-app routes to all six service targets from every supported start. Offline detector and planner results support this gate. Verify the integrated app with rendered-frame recognition and actual route playback in the simulator. Keep the existing tagged crate demo separate. New unexpected-obstacle avoidance is deferred.

## Scene and equipment handoff

- The complete replacement scan has 1,676,481 splats and 33 reviewed seed volumes. The current app enables 30 identities. The rear red vessel and two orange actuators remain below the release gate. The latest independent rear-vessel QA found one usable pair, below the required eight. The orange-actuator search found no qualifying new independent validation views on the sampled grid. Seek new, permitted same-scene views or a genuinely independent split before tuning again.
- The catalog uses stable `objectId` values and registered 3D bounds. The 10 cm grid uses the same frame as rendering. Route distances assume model units are metres. Preserve origin, scale and IDs unless both workers agree on a versioned migration.
- At the 0.10 m default virtual-camera clearance, 2,106 cells connect to all six service approaches. The other 24 walkable cells are disconnected. Planner tests cover shortest routes, alternate starts, larger radii and unreachable cases.
- RF-DETR simulator journeys passed at least once for each service target. CV-003 and P-003 passed previously missed approaches on retry. P-004's 2.3 m approach confirmed once on retry despite 37 projected detections. History expired by age 32 times and by pose four times. Separating overlay expiry from capture pairing increased confirmed frames from 1 to 32 for P-004 in the simulator. P-003 (6.0 m), CV-003 (3.0 m) and P-005 (2.0 m) also passed on the same build. These are individual simulator runs. R3 fails to create an inference context on the tested iOS 26.5 simulator. RF-DETR journey mode provides separate simulator evidence. Preserve normal iPhone compatibility.
- On app revision `87cbaa2`, a single iOS 26.5 simulator run confirmed all 20 enabled RF-DETR IDs at their assigned fixed views, with 8–12 fresh samples per view. The entrance negative stayed empty over nine fresh samples. This confirms those runtime examples. The R3 gate failed separately and these views do not estimate precision or recall. The P-005 simulator capture and matching log are ready for private handoff.
- The same app build passed P-001 (3.4 m) and P-002 (2.9 m) after the pairing fix, completing simulator runs for all six service targets on that build. On P-005, the simulator UI opened the report for ASSET-017, showed the next check at Current_State!18 and matching event at Alarms_Events!249, and returned to the same arrived route on Close.
- R3 isolation reproduced the feature mismatch with identical 299×299 BGRA input bytes. The two positive images produced 1 and 6 NMS rows on Mac and zero in the simulator. Feeding Mac features to the simulator head recovered both results. Feeding simulator features to the Mac head reproduced the misses. The discrepancy is isolated to the platform VisionFeaturePrint stage for these fixtures.
- Excel import preserves workbook SHA and worksheet rows. Six service targets have compatible synthetic records. CV-001 and CV-002 are additional nearby parent-valve mappings. The app retrieves supplied evidence and shows row citations beside the next check. The explanation is deterministic. The workbook's full 14-day CSV is unavailable, so use its included 4,320 telemetry rows.

| Tag | Scene object | Passing simulator start | Distance |
| --- | --- | --- | ---: |
| P-001 | Far circulation pump | `[69,65]` | 3.4 m |
| P-002 | Black circulation pump | `[69,65]` | 2.9 m |
| P-003 | Wall circulation pump | `[94,66]` | 0.8 m |
| P-004 | Middle circulation pump | `[87,44]` | 4.8 m |
| P-005 | Red circulation pump | `[69,65]` | 2.0 m |
| CV-003 | Blue inline valve | `[88,67]` | 0.9 m |

## Render quality

The app now starts with an 1,800 px long edge and steps down through 1,440,
1,200 and 900 when completed frames stay slow. Sustained fast frames recover
quality. The previous cap was 1,200 and could fall permanently to 900.
Detection captures the clean render before drawing route guidance. The model
keeps its existing 384 × 384 input contract.

On iOS 26.5 simulator, all 20 approved RF-DETR fixed views confirmed with
828 × 1,800 source frames and the negative view stayed empty. The 2.0 m
P-005 route passed with 54 confirmed samples and the correct report. A
15-second moving-view benchmark measured 27.60 GPU FPS and 4.00 Hz RF-DETR
with 53 current and seven stale results. R3 remained unavailable there.
The generic iOS release build passed. Visual improvement varies by the
detail and visibility captured in the source scan.
All six service targets passed on the same higher-resolution app build.
The additional runs covered P-001 (3.4 m), P-002 (2.9 m), P-003 (6.0 m),
P-004 (2.3 m) and CV-003 (3.0 m). Each confirmed the target, arrived
and displayed the matching workbook report and nearby mapped equipment.

A simulator-only evaluation of an independently scheduled RF-DETR capture
deadline raised sample rate from 3.93–4.00 Hz to 4.27–4.33 Hz across two
15-second runs per implementation. The current-result age p95 increased
from 230–243 ms to 271–281 ms. The experiment was reverted. The app retains
the original scheduler and higher render quality.

## Orange-actuator model comparison

The 259-view validation set contains 26 A and 25 B annotations. At the locked
RGB thresholds (0.79 A, 0.72 B), the current typed RF-DETR export scored
11/0/15 for A and 13/0/12 for B (TP/FP/FN). The official tensor export of the
same fine-tuned checkpoint scored 10/0/16 and 12/1/13. DINOv2 with a trained
linear head and frozen backbone, and pretrained DISK + LightGlue, re-ranked
the same 1,662 archived proposals. Neither produced a usable RGB threshold
at 95% precision. Three fixed epochs of DINOv2 last-block and head
fine-tuning also failed the precision gate. LightGlue supports fine-tuning
with correspondence supervision, which this box-labeled screen did not use.
The comparison includes the tested preprocessing and adaptation choices.

Keep the current app export. A validation-only follow-up with the same
detector and four fixed overlapping RGB crops improved to 13/0/13 and
16/0/9 at the locked thresholds. Both remain below 70% recall, and the
extra inference cost has not been verified in the app. No candidate was
promoted. Evaluate model fine-tuning only against frozen splits and require
new independent views before release.
A fresh three-cell RGB pilot bypassed the projected-box overlap filter.
None of the three views showed both actuator housings and their own
connectors clearly. The same four-crop replay for the rear vessel at the
locked 0.76 threshold retained 25 true positives and added one false
positive. It was rejected.

## Additional approaches and continuous clearance

The higher-resolution simulator build also passed six alternate journeys:
P-001 and P-002 from `[96,36]` (4.0 and 3.7 m), P-003 and P-004 from
`[42,83]` (7.5 and 3.6 m), P-005 from `[66,92]` (1.8 m), and CV-003 from
`[96,36]` (3.6 m). Each confirmed the target and correct workbook tag,
arrived, and displayed nearby mapped equipment.

A native audit derived the entrance component from the app's exact
`site.json` bytes. It checked all 3,860 unique cardinal edges in the
2,106-cell component against the modeled obstacle rectangles and map
boundary over the full length of each edge. All six service cells were
reachable. Minimum modeled clearance was 0.15 m at a required 0.10 m.
This covers the static camera grid, separate from the simulator vision
and arrival checks.

## Blue inline valve handoff candidate

At the validation-locked RF-DETR threshold 0.814663589, the projected and
deduplicated archival comparison improved room results from 61/2/1 to
62/0/0 (TP/FP/FN). The walking archive was unchanged at 7/0/0 and falls
one positive below the eight-positive release gate. A separately frozen
four-view walking-endpoint sample improved from 0/0/4 to 3/0/1, with no
detections in two target-absent controls. This is supplementary static
evidence. The app still uses R3 for this valve and for P-005. The right blue actuator was also checked at its
locked threshold. Its walking result improved from 19/1/10 to 23/0/6,
but the room archive gained one false positive in a target-absent view.
R3 remains assigned to that actuator.

## Ownership

Each worker has three implementation or delivery packages. Mac owns everything that requires Xcode and iOS verification. Windows owns the cross-platform backend and submission assembly. One writer per file. Review the other worker's handoff without editing their files.

| Owner | Package | Owns | Deliverable |
| --- | --- | --- | --- |
| Mac | Vision and model | Detector datasets and training, `tools/*detector*`, render and detection-view preparation, Core ML exports | Per-ID RGB and runtime evaluation, locked model contract, protected existing detections, verified candidates for remaining IDs |
| Mac | iOS viewer and reliability | `ios/`, `lib/main.dart`, `test/widget_test.dart`, `pubspec.yaml`, generated map image | Clean-frame capture, stable two-frame boxes, route and proximity overlays, report access, generic iOS build |
| Mac | Simulator integration | Native tests, simulator scripts and logs, final integration and `PLAN.md` | Repeatable six-target runs, known hard approaches, recorded P-005 walkthrough and logs for Windows |
| Windows | Scene and navigation | Scene builder, PLY import, geometry and generated `site.json`, `lib/site.dart`, `lib/navigation.dart`, Dart route tool, corresponding tests | Reproducible catalog and floor geometry, shortest-route matrix for six targets, safe blocked and unreachable behavior |
| Windows | Workbook and diagnostics | Workbook importer, `lib/asset_data.dart`, corresponding tests and diagnostic tooling | Correct Excel names, mappings and row citations, case retrieval and safe, evidence-backed guidance. Evaluate optional local RAG with deterministic fallback |
| Windows | Delivery assembly | `README.md`, `DEMO.md`, `docs/TECHNICAL-NOTE.md`, submission package | Reproducible setup, source package, 5–8 slides and video of at most five minutes using Mac capture. Reconcile stale counts and label simulator evidence accurately |

### Shared interface

Windows hands Mac the source revision, local asset-generation commands, scan and workbook hashes, changed IDs or bounds, expected service cells, route fixtures and evidence rows. Mac owns the Flutter-to-native payload and adapts it after agreeing to an interface change. Windows keeps the generated catalog and metadata reproducible. Mac owns model packages and provides contract and metrics. Windows uses those results in the technical note.

Agree before changing catalog IDs, bounds, coordinate transforms, workbook schema, model labels or route payload. Keep scan, workbook, footage and generated private data out of the public repo unless redistribution is authorized. Each worker uses their own approved source copies. Mac works directly on `main`. Windows uses one existing or agreed branch for its handoff. Review both contributions, test the combined revision and fast-forward `main`. Keep release notes tied to the tested commit.

## Order and acceptance

1. **Parallel start.** Mac reproduces P-003, P-004 and CV-003 confirmation failures and fixes any proven history or timing issue without weakening the two-consecutive-frame rule. In parallel, Windows verifies geometry and workbook output on Windows, checks names and citations for each service target, and prepares the route matrix and submission outline.
2. **Model and backend gate.** Use clean RGB renders from this scan and freeze disjoint train, validation and test views before scoring. Target per-ID precision ≥95% and recall ≥70% at IoU ≥0.50 with sufficient positive support. Report RGB-only and pose-associated scores separately, including false positives and misses. Require evidence from near, far and oblique views, hard negatives and consecutive walking frames. Preserve the old classes and P-005. Windows checks shortest paths, observed floor, continuous clearance, blocked starts, alternate starts, correct asset tags and source-grounded reports. Keep LLM output constrained to cited evidence if enabled and preserve the offline fallback.
3. **Combined release.** Run Flutter and Python suites on source changes. Mac runs native tests, a generic iOS release build, and repeated simulator journeys on the combined revision. Include the table starts and difficult starts P-003 `[66,92]`, P-004 `[67,65]`, CV-003 `[69,65]`. Require recognition, arrival, matching workbook report and nearby mapped assets in each tested journey. Check an empty vision view and P-005 report dismissal. Record simulator runtime and backend. Use `--verify-service-journey` with `--simulator-rf16-journey` and optimized Swift Debug if needed. All new device tests use the simulator only.
4. **Submit.** Mac supplies the tested revision, P-005 capture and measured limitations. Windows assembles the video, 5–8 slides, technical note and source package, verifies the current submission form and coordinates delivery. Both confirm the claims match the evidence before submission. The previous event schedule listed Sunday 8 November at 10:00 Finnish time. Confirm in the organizer portal.

The release checkpoint is a verified stable build. Full completion also requires reliable recognition for all 33, all supported service routes and the grounded end-to-end workflow. Keep any unmet gate explicit in the handoff.

## Repeat the simulator service check

From the repository root, with the optimized app installed on a booted
iOS simulator, run:

```sh
python3 tools/verify_simulator_service_routes.py <simulator-udid> <new-log-folder>
```

This checks the six named targets, including the three difficult starts,
and requires the matching workbook tag, nearby mapped equipment, target
confirmation and arrival. It uses the RF-DETR simulator journey backend.
The script defines the tested starts and saves each route result. The planner
suite covers grid reachability.

## Goal prompts

### Mac goal

> Read PLAN.md and the Valmet brief. Own the Mac packages only. Improve clean rendered-RGB recognition for all 33 catalog IDs with independent per-ID evidence and protect the existing detector and P-005. Fix measured iOS confirmation and viewer problems. Verify all six service targets and the difficult approaches on the iOS simulator, including recognition, arrival, workbook evidence and nearby overlays. Preserve normal iPhone compatibility with a generic release build. Use no physical phone tests and add no new unexpected-obstacle avoidance. Work directly on main, coordinate contract changes with Windows, and push each verified milestone safely. Deliver a recorded P-005 journey and exact revision, test results and remaining gaps to Windows.

### Windows goal

> Read PLAN.md and the Valmet brief. Own the Windows packages only. Prioritize what the integrated app needs to recognize all 33 objects and route reliably to all six service targets. Validate and improve the registered scene catalog, observed walkable floor, collision-free shortest routes for all six targets and blocked/unreachable behavior. Verify synthetic Excel mappings, exact names and evidence-backed arrival guidance, including safe retrieval and an offline fallback. Run Python and Flutter/Dart tests on Windows. Supply Mac with reproducible assets, fixtures, expected results and a revision for iOS simulator integration. Keep iOS and Core ML files with Mac. Assemble the setup, technical note, slides and video from verified evidence and Mac capture. Use one branch, coordinate schema changes and hand off for safe main integration. Add no new unexpected-obstacle avoidance.
