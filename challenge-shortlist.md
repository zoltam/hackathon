# Challenge shortlist — local models and fine-tuning

Decision notes · 5 November 2026

## What we are choosing for

We want to adapt an existing model to a specific task and run the resulting model locally. Models can handle images, radio signals, time series or text; this is not limited to LLMs. We are building with AI assistance. Our degree subjects receive little weight in this assessment.

**None of the current descriptions promises suitable training data, labels, permission to train on partner data, local deployment support, compute, or a suitable pretrained model. None explicitly requests fine-tuning.** The descriptions identify business problems, not guaranteed technical implementations. General permission to use AI is not a guarantee that a particular dataset may be used for training.

Local inference and fine-tuning are separate choices. A model can run locally without adaptation; adapting a model does not establish that the resulting product benefits from local deployment. Here, “local” means inference on our own or company-controlled hardware; it does not assume training must also happen on a laptop.

## Recommendation before selection

Our earlier exploratory order was **Valmet → Traficom → Elisa**. On a stricter reading of what is actually disclosed, the more conservative order is **Valmet → Elisa → Turku Energia**, with **Traficom as the higher-uncertainty signal-model choice**.

- **Choose Valmet** for the best combination of an industrial perception opportunity and a directly relevant 2025 precedent. Vision data is still an assumption for 2026.
- **Choose Elisa** for the clearest current language-model task: extracting operational knowledge from discussions. Whether fine-tuning improves over prompting and retrieval remains unproven.
- **Choose Turku Energia** for the clearest explicitly predictive task and an opportunity to adapt a forecasting model. Local deployment has a weaker stated motivation.
- **Choose Traficom instead of one of those** if we specifically want to explore RF models and accept that the actual challenge may be about planning records rather than recorded signals. It is a credible opportunity, not a promised RF-training task.

This ranking concerns our preferred technical approach, not overall challenge quality or predicted chances of winning. There is no opportunity to resolve these uncertainties before choosing, so they are selection risks rather than a request to wait for more information.

## What last year's projects actually establish

| 2025 example | Published evidence | What it supports for our decision |
| --- | --- | --- |
| Valmet: industrial field-device detection | The organiser describes vision / 3D recognition under changing lighting, angles and occlusion. | A concrete precedent for specialist perception models at Valmet. It does not establish the 2026 input format or available labels. |
| Kongsberg: maritime sound detection | The organiser describes CNN audio classification. SoundWatch's team member reports a challenge win, AudioResNet-18, synthetic acoustic scenes and edge inference in Docker. | A specialist model with locally running inference can make a strong project, even when a team must generate data. Acoustic scenes are not evidence of Traficom RF recordings. |
| Sandvik: spare-part discovery | The organiser describes agents and retrieval-augmented generation for catalog search. | Useful industrial AI can be primarily retrieval and workflow integration; fine-tuning is not automatically the main contribution. |

Sources: [official 2025 project themes](https://sinceai.ai/projects), [SoundWatch participant account](https://www.linkedin.com/posts/tabw_colregs-whistle-intelligence-activity-7398817596583845888-swLi), checked 5 November 2026. The organiser publishes summaries rather than complete solutions. The SoundWatch account does **not** establish whether its backbone was pretrained or fine-tuned; do not present it as a verified fine-tuning precedent. Synthetic-data performance also does not establish real-world performance.

## Detailed assessment of the strongest candidates

### Valmet — Best overall candidate; vision is plausible, not promised.

**Current description, verbatim from [challenges.md](challenges.md):**

> Explore how AI can connect the physical and digital worlds in complex industrial sites. Build ideas that help people and intelligent systems understand equipment, navigate environments and support field-service decisions.

- **Actually stated:** equipment understanding, navigation and field-service decisions in industrial sites.
- **Plausible adaptation:** fine-tune a vision model for equipment recognition or identifying relevant components. A multimodal approach is another option, not a stated requirement.
- **Plausible local benefit:** use at the point of service with limited connectivity or without sending site imagery to a cloud service. Neither constraint is stated in the summary.
- **Not promised:** photos, video, 3D scans, bounding boxes, object labels, camera access or edge hardware.
- **Failure of our assumption:** the task could instead center on site information, navigation data or a document assistant. We should not choose expecting a repeat of the 2025 object-detection challenge.
- **Verdict:** strongest combined current-theme / historical fit, but only medium confidence in the exact model task.

#### Demo idea — equipment recognition on an iPhone in airplane mode

**Turn on airplane mode, point the camera at equipment, and get accurate results immediately.** This makes offline operation and local inference visible to the audience.

Our proposed implementation is an iPhone app running an equipment-recognition model on the device, potentially fine-tuned for the selected equipment. Demonstrate with Wi-Fi and cellular connectivity disabled. Accuracy and response time are goals to measure on the actual phone, not established results. This is our product idea, not a capability or dataset promised by Valmet's current challenge description.

### Elisa — Strongest explicit text-input clue.

**Current description, verbatim from [challenges.md](challenges.md):**

> Essential know-how in network operations often lives in everyday discussions rather than formal systems. Explore how AI could capture and connect that knowledge to support more autonomous operations.

- **Actually stated:** operational knowledge lives in everyday discussions and should be captured and connected.
- **Plausible adaptation:** teach a small model to extract incident, equipment, symptom, action and resolution records from discussions in a consistent format.
- **Plausible local benefit:** keep operational discussions within a company-controlled environment. The summary does not require this.
- **Not promised:** chat exports, transcripts, labelled examples, expected output schemas or training rights. “Discussions” does not imply audio recordings.
- **Failure of our assumption:** the main problem may be retrieving and linking knowledge, for which a local untuned model and retrieval could suffice.
- **Verdict:** a credible local LLM route with fewer input-modality assumptions than Traficom; the benefit of fine-tuning still needs demonstration.

### Turku Energia — Clearest stated predictive-model objective.

**Current description, verbatim from [challenges.md](challenges.md):**

> Energy markets change rapidly as electricity production and demand shift. Explore how AI could improve short-term forecasts and help experts make informed decisions under uncertainty.

- **Actually stated:** improve short-term forecasts amid changing electricity production and demand, supporting decisions under uncertainty.
- **Plausible adaptation:** adapt a pretrained time-series model to an energy forecasting target and evaluate on later, held-out periods.
- **Plausible local benefit:** internal operation and predictable inference latency / costs. These are proposed benefits, not published constraints.
- **Not promised:** target variable, historical series, sampling frequency, external covariates, forecast horizon or evaluation metric.
- **Failure of our assumption:** data volume may not support adaptation, or a simple statistical / tabular baseline may outperform a fine-tuned foundation model.
- **Verdict:** high confidence that forecasting fits; lower confidence that fine-tuning and local deployment are both valuable.

### Traficom — High technical potential; substantial input-data uncertainty.

**Current description, verbatim from [challenges.md](challenges.md):**

> Satellite and terrestrial radio systems share limited radio-frequency spectrum. Explore how AI could help specialists identify potential interference risks and support more efficient spectrum planning.

- **Actually stated:** satellite and terrestrial systems share spectrum; identify potential interference risks and support spectrum planning.
- **Plausible adaptation if recordings exist:** adapt an RF model using I/Q samples or a vision model using spectrum spectrograms to detect relevant activity / interference patterns.
- **Alternative consistent with the description:** use frequency assignments, transmitter locations, antenna parameters and propagation calculations to assess planned interference. No recorded-signal classifier is necessarily involved.
- **Plausible local benefit:** receiver-side inference if measurements are part of the task. The summary does not establish a receiver, live data or an edge requirement.
- **Not promised:** I/Q recordings, audio, spectrograms, signal labels, SDR access, interference examples or a compatible pretrained model.
- **Failure of our assumption:** signal classification can be technically impressive while failing to answer the actual spectrum-planning problem. Identifying a signal type does not by itself quantify interference risk.
- **Verdict:** genuinely worth shortlisting for specialist models, but not the safest fine-tuning choice on the wording alone. Our earlier suggestion of an audio model was speculative; radio signals are not ordinary sound recordings.

### Bayer — Plausible text classification; input format unconfirmed.

**Current description, verbatim from [challenges.md](challenges.md):**

> Turn industrial health, safety and environment observations into insights people can act on. Explore how AI could make complex safety information clearer and more useful for decision-making.

- **Actually stated:** make industrial health, safety and environment observations actionable and easier to understand.
- **Plausible adaptation:** classify observations and extract hazards, events and actions into consistent records.
- **Plausible local benefit:** internal processing of sensitive observations, if the supplied data is sensitive.
- **Not promised:** free-text reports rather than structured tables, labels, incident examples or a training objective.
- **Failure of our assumption:** analytics, visualization and retrieval may deliver the core value without fine-tuning.
- **Verdict:** a reasonable backup for local text models, with less explicit text-input evidence than Elisa.

### Business Turku — Local deployment fits the setting; fine-tuning remains speculative.

**Current description, verbatim from [challenges.md](challenges.md):**

> Existing industrial machinery holds untapped potential for smarter operations. Explore how AI could add intelligence to established equipment and help people recognise maintenance and performance opportunities.

- **Actually stated:** add intelligence to existing machinery to identify maintenance and performance opportunities.
- **Plausible adaptation:** adapt a time-series, vibration or vision model to a specific machine task.
- **Plausible local benefit:** processing near existing equipment. The description does not require edge hardware or offline operation.
- **Not promised:** sensors, vibration / sound recordings, images, failure labels, machine access or historical telemetry.
- **Failure of our assumption:** the available task may concern existing records or service workflows. An anomaly model trained from scratch is not necessarily fine-tuning.
- **Verdict:** credible industrial ML potential, but too little information to place above the main shortlist.

## Remaining challenges

These are interpretations of the supplied current descriptions in [challenges.md](challenges.md), not confirmed implementations.

| Challenge | Fine-tuning opportunity | Why it is outside our main shortlist |
| --- | --- | --- |
| Europress | Adapt a model to equipment signals for operational prediction or anomaly detection. | Operational signals are explicit, but their form, historical coverage and target labels are not. Strong backup if we prefer industrial telemetry; local processing is inferred. |
| Fonecta | Adapt an extractor / matcher to normalize and reconcile business information. | Plausible bounded text task, but source access and correct target records are unconfirmed; local deployment has no clear stated advantage. |
| Takomo Golf | Adapt a recommendation or regression model using player characteristics and performance signals. | A specific prediction task is plausible, but examples of successful fittings are unconfirmed. Could be tabular ML rather than pretrained-model adaptation. Supplied terms transfer event work and restrict later reuse without consent. |
| Meyer Turku | Adapt a requirement extractor or clause classifier. | Rules comprehension does not itself require fine-tuning; retrieval with source citations may be the stronger core. No document corpus or labelled compliance examples promised. |
| TrustED | Adapt a sensitive-information detector or a model using a privacy-enhancing training method. | Privacy is explicit, but neither the task nor data modality is. Local inference alone is not a privacy-enhancing technology or evidence of privacy protection. |
| DNA | Adapt a model to recognize digital-safety scenarios and provide consistent guidance. | Reliable advice may depend more on curated knowledge and evaluation than training. No labelled cases promised; supplied terms transfer event work to DNA. |
| Apetit | Adapt a forecasting or document model for sustainability-related decisions. | Too broad to infer a trainable target, input type or local deployment need. |
| Lindström | Adapt an extractor to textile sustainability documents or data. | The stated objective is credible customer insights; calculations, retrieval and communication may dominate. No clear adaptation target promised. |
| FORCIT Group | Potential specialist industrial model, depending on confidential task. | Neither modality nor trainable target is disclosed. NDA and industrial context do not imply local inference, available labels or permission to fine-tune. Larger prize does not reduce technical uncertainty. |

## What a convincing local fine-tuning project would demonstrate

These are our proposed success criteria, not event requirements:

1. A specific task that directly answers the selected business problem.
2. A compatible pretrained model, with permission to adapt and deploy it.
3. A training set and a genuinely separate evaluation set; no testing on near-duplicates of training examples.
4. Improvement over the original model and a practical baseline, using task-relevant measures.
5. Inference on identified local hardware, with measured latency and resource use.
6. A concrete reason local inference helps the user: connectivity, latency, data handling or cost, supported by the chosen scenario.

AI coding assistance can accelerate implementation. It cannot substitute for appropriate examples, reliable evaluation or correct signal / domain assumptions. Public or synthetic data can support a prototype, but claims must distinguish performance on that data from performance in the partner's real environment.

**Decision:** Valmet is our best informed first choice. Elisa is the more conservative second choice for a small language model; Traficom is the more adventurous second choice for a specialist signal model. No published summary guarantees that fine-tuning will be necessary, feasible or superior.
