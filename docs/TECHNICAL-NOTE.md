# Valmet Field App · Technical note

Revision basis: source baseline `2014f82`, with Linux `zoltam` work under review. Linux backend verification passed on this baseline plus the working changes below; combined iOS runtime verification remains pending. The shared [plan](../PLAN.md) is the source for previously recorded device results, not a record of Linux-reproduced iOS tests.

## Scene and semantic catalog

Python/NumPy validates and registers the complete replacement Equipment Room scan containing 1,676,481 Gaussian records. Swift/Metal renders anisotropic splats with opacity and degree-three view-dependent colour. Registered distances assume one unit equals one metre.

The builder starts from 33 reviewed seed volumes, selects supporting Gaussians and refines bounds where applicable. Stable object IDs connect catalog volumes, workbook associations and service approaches. This is seeded, scene-specific extraction. It does not discover arbitrary equipment in an unseen plant. The baseline catalog flags 11 R3 detector IDs. The RF-DETR contract adds supplemental support so the integrated app enables 30 distinct IDs. The rear red vessel and two orange actuators remain below the release gate. All-33 recognition is incomplete.

## Recognition and runtime boundaries

Mac tooling uses Swift/Metal, Pillow and Apple Create ML to prepare labeled same-scene renders and train the R3 ObjectPrint transfer-learning detector. The RF-DETR Nano FP16 Core ML supplement carries its class ordering, frozen thresholds and approved IDs, with the Apache 2.0 notice included. Training/render provenance and model-selection evidence are Mac-owned.

Vision/Core ML samples clean rendered frames at up to 8 Hz and skips inference while busy. Pixels provide recognition input. Capture-time pose and projection associate image boxes with registered volumes after inference. The viewer deduplicates per ID and requires two consecutive observations. R3 and supplemental inference use independent bounded queues and histories. Middle-actuator handoff falls back to R3 when supplemental results stop or become stale. Teal proximity frames within 2.5 m use catalog geometry and are separate from yellow recognition boxes.

Previously recorded simulator runs used RF-DETR journey mode because R3 could not create its inference context on the tested iOS 26.5 simulator. The shared plan records at least one passing run per service target, with retries and confirmation expiry on difficult approaches. Those results do not establish repeatable reliability on the combined revision. New verification is simulator-only and belongs to Mac. Historical iPhone measurements must retain their hardware, revision, test policy and caveats if cited.

## Observed floor and shortest routes

Dart uses four-neighbour breadth-first search on a 10 cm grid. Floor support comes from measured scan observations and bounded Gaussian floor footprints. Unknown space stays unavailable. Obstacles between 0.17 and 1.55 m and radius clearance constrain the virtual camera. The ceiling models its 1.50 m height plus margin and does not establish full-body clearance.

The checked-in scene describes 3,213 observed floor cells. At the default 0.10 m radius, 2,130 cells pass clearance and 2,106 form the connected service network. The remaining 24 form separate patches. All six reviewed service approaches lie on that network. Route length depends on target and start. A historical 3.10 m P-005 route is not a universal route length. Larger radii can make targets unreachable. Safe behavior includes explicit blocked starts, absent paths and continuous motion checks that prevent skipping obstacles.

The pre-existing opt-in tagged crate experiment replaces a known simulated footprint after visual tag confirmation. It is separate from the static-route release gate. This work adds no unexpected-obstacle avoidance.

## Workbook mapping and grounded guidance

Python/openpyxl imports eight evidence sheets and retains workbook SHA-256 and original worksheet row references. Compatible synthetic assignments map five scene pumps and one inline valve to distinct records. The inline valve uses the disclosed `CONTROL_VALVE` family mapping. Nearby orange actuators use parent-valve records under their own scene names. These associations do not establish the identities of physical plant equipment.

At arrival, Dart retrieves current state, newest telemetry, endpoints of the included sample, matching open events, recent maintenance, referenced context documents, matching historical cases and quality issues. Historical retrieval matches both asset class and issue code. Field-safety context and safe evidence workflows preserve qualified-personnel and approved-procedure boundaries. The importer accepts explicit reviewed overrides and rejects incompatible mappings.

The report distinguishes workbook observations, supplied confidence, unconfirmed hypotheses and next verification. P-005's default synthetic assignment is ASSET-017, with current-state evidence at `Current_State!18`. The included telemetry has 4,320 samples over three days. The separate fourteen-day CSV is unavailable. Missing context or telemetry must remain visible.

The working offline fallback is deterministic local retrieval, requiring no network or generative model. No optional LLM/RAG service is deployed by this revision. A local diagnostic model must not be claimed merely because retrieved case text appears in the report.

## Product evidence status

Linux validates Python and Flutter/Dart behavior and supplies reproducible asset-generation commands and fixtures. Backend tests establish only their tested invariants. Mac must verify native compatibility, repeat all six simulator journeys including difficult approaches, record recognition/arrival/report/proximity evidence, test negative views and report dismissal, and supply the tested combined revision with matching logs.

On app revision `87cbaa2`, the Mac summary in `PLAN.md` records one iOS 26.5 simulator run confirming all 20 enabled supplemental IDs at assigned fixed views, with 8–12 fresh samples per view. The entrance negative stayed empty over nine fresh samples. These runtime examples do not measure precision or recall, and the R3 gate failed separately. A capture and matching log are available for private handoff according to that summary, but raw files are not present in the Linux checkout.

## Reproducible Linux asset handoff

The approved source copies regenerate `site.json` and the full splat asset byte
for byte. Preserve their IDs, registration and model-unit scale for Mac runtime
checks. SHA-256 values:

| Input or generated asset | SHA-256 |
| --- | --- |
| Equipment Room PLY | `83d8c7d99316c08c9719cfc2c5a6b9d1903b89847780e2458adc662c79f32955` |
| Synthetic workbook | `a0bcb5385fcd5bf4a1f3cf7f79ff3a2fbcb1070e0dec41d716da49357cd4f4da` |
| Generated `site.json` | `adcc75106e21d0b5f2f71bd88028ebd6ba6c83445080109347065e7cf0c3aad8` |
| Generated `boiler-room-sh.splats` | `9abfa18d198a50dfa4d25c79f30513a5131aabdac517196da124a652ba5d1210` |

Use the setup and audit commands in [README](../README.md). The default route
audit covers 2,106 connected supported starts against six targets and checks the
24 disconnected starts against all six as unreachable. Private source files,
generated scene/workbook assets and detailed expected-result fixtures stay local.

### Verified backend checkpoint

On source baseline `2014f82` plus the current Linux changes, all 20 Python tests
and all 29 Flutter tests passed. Full Flutter analysis was clean. The exhaustive route
audit verified 12,636 shortest routes (2,106 connected starts × six targets),
144 unreachable pairs (24 disconnected starts × six targets), 12 blocked-endpoint
cases and 3,888 cardinal edges with exact swept-clearance checks. These checks
exercise the represented grid and camera radius, not physical industrial safety.
Record `git rev-parse HEAD` when reproducing this checkpoint; private audit output stays in ignored `build/`.
Combined iOS simulator runtime verification remains pending with Mac.
