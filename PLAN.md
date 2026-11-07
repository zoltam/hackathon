# Valmet two-person delivery plan

Updated 7 November 2026. Baseline `5dfed35`. Previous experiments and detailed measurements are in the Git history of this file. Read the [challenge notes](challenge-shortlist.md) and [setup](README.md) before changing code.

Current `zoltam` scope is product behavior, Linux validation and the Mac integration handoff. Demo, slide and video assembly is deferred.

## What the demo must prove

Use the complete Equipment Room replacement scan to extract and frame equipment, calculate and automatically travel a collision-free route to a preselected faulty device, show nearby assets and their synthetic Excel metadata, and open grounded inspection guidance at arrival. Keep the iOS viewer focused on that workflow. The brief weights extraction and framing 30%, navigation and proximity 25%, diagnostics 20%, backend 15%, and demo 10%.

P-005 is the primary demo. Demonstrate the five other service targets in verification. The top release priorities are accurate in-app recognition of all 33 catalog objects and working in-app routes to all six service targets from every supported start. Offline detector and planner results support this gate. Verify the integrated app with rendered-frame recognition and actual route playback in the simulator. Keep the existing tagged crate demo separate. New unexpected-obstacle avoidance is deferred.

## Scene and equipment handoff

- The complete replacement scan has 1,676,481 splats and 33 reviewed seed volumes. The current app enables 30 identities. The rear red vessel and two orange actuators remain below the release gate. The latest independent rear-vessel QA found one usable pair, below the required eight. The orange-actuator search found no qualifying new independent validation views on the sampled grid. Seek new, permitted same-scene views or a genuinely independent split before tuning again.
- The catalog uses stable `objectId` values and registered 3D bounds. The 10 cm grid uses the same frame as rendering. Route distances assume model units are metres. Preserve origin, scale and IDs unless both workers agree on a versioned migration.
- At the 0.10 m default virtual-camera clearance, 2,106 cells connect to all six service approaches. The other 24 walkable cells are disconnected. Planner tests cover shortest routes, alternate starts, larger radii and unreachable cases.
- RF-DETR simulator journeys passed at least once for each service target. CV-003 and P-003 passed previously missed approaches on retry. P-004's 2.3 m approach confirmed once on retry despite 37 projected detections. History expired by age 32 times and by pose four times. Separating overlay expiry from capture pairing increased confirmed frames from 1 to 32 for P-004 in the simulator. P-003 (6.0 m), CV-003 (3.0 m) and P-005 (2.0 m) also passed on the same build. These are individual simulator runs. R3 fails to create an inference context on the tested iOS 26.5 simulator. RF-DETR journey mode provides separate simulator evidence. Preserve normal iPhone compatibility.
- On app revision `87cbaa2`, a single iOS 26.5 simulator run confirmed all 20 enabled RF-DETR IDs at their assigned fixed views, with 8–12 fresh samples per view. The entrance negative stayed empty over nine fresh samples. This confirms those runtime examples. The R3 gate failed separately and these views do not estimate precision or recall. The P-005 simulator capture and matching log are ready for private handoff.
- Excel import preserves workbook SHA and worksheet rows. Six service targets have compatible synthetic records. CV-001 and CV-002 are additional nearby parent-valve mappings. The app retrieves supplied evidence and shows row citations beside the next check. The explanation is deterministic. The workbook's full 14-day CSV is unavailable, so use its included 4,320 telemetry rows.

| Tag | Scene object | Passing simulator start | Distance |
| --- | --- | --- | ---: |
| P-001 | Far circulation pump | `[69,65]` | 3.4 m |
| P-002 | Black circulation pump | `[69,65]` | 2.9 m |
| P-003 | Wall circulation pump | `[94,66]` | 0.8 m |
| P-004 | Middle circulation pump | `[87,44]` | 4.8 m |
| P-005 | Red circulation pump | `[69,65]` | 2.0 m |
| CV-003 | Blue inline valve | `[88,67]` | 0.9 m |

## Ownership

Each worker has three implementation or delivery packages. Mac owns everything that requires Xcode and iOS verification. Linux owns the cross-platform backend and submission assembly. One writer per file. Review the other worker's handoff without editing their files.

| Owner | Package | Owns | Deliverable |
| --- | --- | --- | --- |
| Mac | Vision and model | Detector datasets and training, `tools/*detector*`, render and detection-view preparation, Core ML exports | Per-ID RGB and runtime evaluation, locked model contract, protected existing detections, verified candidates for remaining IDs |
| Mac | iOS viewer and reliability | `ios/`, `lib/main.dart`, `test/widget_test.dart`, `pubspec.yaml`, generated map image | Clean-frame capture, stable two-frame boxes, route and proximity overlays, report access, generic iOS build |
| Mac | Simulator integration | Native tests, simulator scripts and logs, final integration and `PLAN.md` | Repeatable six-target runs, known hard approaches, recorded P-005 walkthrough and logs for Linux |
| Linux | Scene and navigation | Scene builder, PLY import, geometry and generated `site.json`, `lib/site.dart`, `lib/navigation.dart`, Dart route tool, corresponding tests | Reproducible catalog and floor geometry, shortest-route matrix for six targets, safe blocked and unreachable behavior |
| Linux | Workbook and diagnostics | Workbook importer, `lib/asset_data.dart`, corresponding tests and diagnostic tooling | Correct Excel names, mappings and row citations, case retrieval and safe, evidence-backed guidance. Evaluate optional local RAG with deterministic fallback |
| Linux | Delivery assembly | `README.md`, `DEMO.md`, `docs/TECHNICAL-NOTE.md`, submission package | Reproducible setup, source package, 5–8 slides and video of at most five minutes using Mac capture. Reconcile stale counts and label simulator evidence accurately |

### Shared interface

Linux hands Mac the source revision, local asset-generation commands, scan and workbook hashes, changed IDs or bounds, expected service cells, route fixtures and evidence rows. Mac owns the Flutter-to-native payload and adapts it after agreeing to an interface change. Linux keeps the generated catalog and metadata reproducible. Mac owns model packages and provides contract and metrics. Linux uses those results in the technical note.

Agree before changing catalog IDs, bounds, coordinate transforms, workbook schema, model labels or route payload. Keep scan, workbook, footage and generated private data out of the public repo unless redistribution is authorized. Each worker uses their own approved source copies. Mac works directly on `main`. Linux uses one existing or agreed branch for its handoff. Review both contributions, test the combined revision and fast-forward `main`. Keep release notes tied to the tested commit.

## Order and acceptance

1. **Parallel start.** Mac reproduces P-003, P-004 and CV-003 confirmation failures and fixes any proven history or timing issue without weakening the two-consecutive-frame rule. In parallel, Linux verifies geometry and workbook output on Linux, checks names and citations for each service target, and prepares the route matrix and submission outline.
2. **Model and backend gate.** Use clean RGB renders from this scan and freeze disjoint train, validation and test views before scoring. Target per-ID precision ≥95% and recall ≥70% at IoU ≥0.50 with sufficient positive support. Report RGB-only and pose-associated scores separately, including false positives and misses. Require evidence from near, far and oblique views, hard negatives and consecutive walking frames. Preserve the old classes and P-005. Linux checks shortest paths, observed floor, continuous clearance, blocked starts, alternate starts, correct asset tags and source-grounded reports. Keep LLM output constrained to cited evidence if enabled and preserve the offline fallback.
3. **Combined release.** Run Flutter and Python suites on source changes. Mac runs native tests, a generic iOS release build, and repeated simulator journeys on the combined revision. Include the table starts and difficult starts P-003 `[66,92]`, P-004 `[67,65]`, CV-003 `[69,65]`. Require recognition, arrival, matching workbook report and nearby mapped assets in each tested journey. Check an empty vision view and P-005 report dismissal. Record simulator runtime and backend. Use `--verify-service-journey` with `--simulator-rf16-journey` and optimized Swift Debug if needed. All new device tests use the simulator only.
4. **Submit.** Mac supplies the tested revision, P-005 capture and measured limitations. Linux assembles the video, 5–8 slides, technical note and source package, verifies the current submission form and coordinates delivery. Both confirm the claims match the evidence before submission. The previous event schedule listed Sunday 8 November at 10:00 Finnish time. Confirm in the organizer portal.

The release checkpoint is a verified stable build. Full completion also requires reliable recognition for all 33, all supported service routes and the grounded end-to-end workflow. Keep any unmet gate explicit in the handoff.

## Goal prompts

### Mac goal

> Read PLAN.md and the Valmet brief. Own the Mac packages only. Improve clean rendered-RGB recognition for all 33 catalog IDs with independent per-ID evidence and protect the existing detector and P-005. Fix measured iOS confirmation and viewer problems. Verify all six service targets and the difficult approaches on the iOS simulator, including recognition, arrival, workbook evidence and nearby overlays. Preserve normal iPhone compatibility with a generic release build. Use no physical phone tests and add no new unexpected-obstacle avoidance. Work directly on main, coordinate contract changes with Linux, and push each verified milestone safely. Deliver a recorded P-005 journey and exact revision, test results and remaining gaps to Linux.

### Linux goal

> Read PLAN.md and the Valmet brief. Own the Linux packages only. Prioritize what the integrated app needs to recognize all 33 objects and route reliably to all six service targets. Validate and improve the registered scene catalog, observed walkable floor, collision-free shortest routes for all six targets and blocked/unreachable behavior. Verify synthetic Excel mappings, exact names and evidence-backed arrival guidance, including safe retrieval and an offline fallback. Run Python and Flutter/Dart tests on Linux. Supply Mac with reproducible assets, fixtures, expected results and a revision for iOS simulator integration. Keep iOS and Core ML files with Mac. Assemble the setup, technical note, slides and video from verified evidence and Mac capture. Use one branch, coordinate schema changes and hand off for safe main integration. Add no new unexpected-obstacle avoidance.
