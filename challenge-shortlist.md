# Valmet challenge notes

Updated 6 November 2026 from the supplied full challenge brief and synthetic builder workbook. Valmet is our selected challenge. These notes replace the earlier pre-brief shortlist assumptions. Live team work is tracked in [PLAN.md](PLAN.md).

## Full challenge

**Industrial Metaverse: Semantic 3D Scene Understanding & Autonomous Field-Service Copilot** — Valmet Automation.

Turn the supplied Industrial Boiler Room Gaussian-splat scene into an environment where a simulated service worker or robot can understand surrounding equipment, follow a realistic route to a faulty device, and receive evidence-grounded service guidance.

## Required end-to-end behaviour

1. Process the supplied PLY to extract many distinct objects and enclose them in 3D boxes/frames.
2. Map the supplied workbook's metadata, statuses and telemetry to those objects. Procedural/random mapping is explicitly allowed; retain the supplied values and disclose the association.
3. Automatically calculate and travel a logical walkable route to a predetermined faulty target, avoiding walls, equipment and obstacles.
4. Dynamically highlight nearby assets and show their mapped information along the route.
5. On arrival, explain the target condition and recommend inspection/service steps grounded in the workbook's evidence and documentation.

## Published Valmet scoring

| Criterion | Weight |
| --- | --- |
| Semantic extraction density and 3D asset framing | 30% |
| Realistic obstacle-aware navigation and proximity display | 25% |
| AI diagnostics, grounding and explainability | 20% |
| Backend architecture and implementation | 15% |
| Demo clarity and innovation | 10% |

The brief explicitly prefers strong backend/spatial processing with lightweight visualization over a polished mobile app with weak spatial processing. Extract distinct, meaningful assets; do not inflate counts by duplicating or arbitrarily fragmenting equipment.

## Our product direction

**Select faulty equipment → navigate through the actual scan → see nearby equipment and status → arrive and understand what to inspect next.**

Keep the Flutter/iOS viewer already in the repository. **Phone movement drives the virtual camera; clean rendered boiler-room frames feed a vision model running on the iPhone; detections are associated with 3D objects and displayed as stable overlays.** The model does not analyze the real room camera feed. Add automatic avatar/camera playback alongside physical movement to fulfil the requested journey and make the demonstration repeatable.

The virtual camera's pose is known in simulation. Overlays in the supplied scene do not establish localization in a real industrial plant. Manual ARKit alignment is not visual recognition of the physical equipment.

## Role of local models and fine-tuning

- The challenge permits multiple approaches: geometry/clustering, point-cloud processing, multi-view vision models lifted into 3D, pathfinding, and evidence-grounded AI.
- Fine-tuning is not required and has no separate scoring category. First build a baseline that extracts persistent 3D assets and completes the service journey.
- Live vision inference on iPhone hardware is a team requirement. Start with a compact pretrained model whose export works on the actual phone; then fine-tune if rendered-scene evaluation reveals a useful adaptation target. Two-dimensional detections must be associated with the scene using matching frame-time pose and geometry/depth, and combined across views.
- No labelled image-training dataset is included in the inspected package. Rendered training images need trustworthy labels and evaluation on distinct viewpoints, not near-duplicates.
- Geometry-based scene rendering is not trained model inference. Disclose procedural labels, synthetic mapping and pretrained components.
- A local diagnostic model should retrieve supplied evidence rather than invent device facts or unsupported interventions. Separate observations, hypotheses, confidence and next verification steps.
- Scene preprocessing and training may run on a computer, but deployed vision inference must run on the phone. Sample clean renderer frames before overlays without encoding video; decouple inference from display rendering. Confirm performance with splat rendering and motion tracking running together. Record diagnostic execution location separately and verify offline claims with connectivity disabled.

## Supplied materials and constraints

| Material | What it provides / what to check |
| --- | --- |
| Industrial Boiler Room PLY | Gaussian splats, not an automatic collision mesh. Validate retained geometry, coordinate system, scale and walkable areas. |
| Synthetic builder workbook | 30 assets in five classes; current states; 4,320 included telemetry samples; 1,000 events; 300 maintenance-history records; 50 historical service cases; eight knowledge-context documents. |
| Scene_Anchors sheet | Placeholder coordinates; not equipment positions in the supplied boiler room. |
| RAG_Corpus_Index | 38 index entries, including asset cards; not 38 separately supplied document files. |
| Full telemetry CSV | Referenced by the workbook but absent from the supplied ZIP. |
| Reference videos | Provided as semantic-extraction examples. They were not watched for this assessment. |

The workbook is synthetic; that does not establish permission to redistribute the separate scan. Keep source and derived scene files local unless authorized. Field guidance must preserve the source's verification, approved-procedure and qualified-personnel boundaries.

## Deliverables

The company brief asks for a working demonstrator using the PLY and workbook, source code with setup instructions, **5–8 slides**, a demo video **at most five minutes**, and a short technical note naming models, libraries and components.

The event submission is in sinceai.app by **Sunday 8 November, 10:00 Finnish time**. The saved event guide also requires a repository link, source ZIP up to 100 MB and a public/unlisted YouTube video, ideally around two minutes. A two-minute video fits the company's maximum. Check the final submission form and include the company-requested slides; see [event guide](sinceai-guide.md).

## Evidence to collect

- Count and inspect distinct extracted assets and their 3D boxes.
- Show routes avoiding represented obstacles and handling unreachable targets.
- Show proximity highlights changing during movement.
- Trace displayed statuses to workbook records; diagnostics to telemetry, event and document references.
- Record actual loading time, frame rate and inference latency on the demonstration hardware.
- If fine-tuning is used, report the original-versus-adapted result on separate evaluation examples.

## Source basis

The authoritative partner materials are the locally supplied `Valmet_x_SinceAI_2026_Challenge_Brief_FINAL_updated (1).docx` and `Valmet_SinceAI_2026_Synthetic_Industrial_Metaverse_Builder_Pack (1) (2) (1).xlsx`. They are not uploaded with these notes. The challenge brief supplies the scoring and deliverables; the workbook supplies the data inventory and mapping/evidence conventions. Our iOS design and work allocation are team decisions.
