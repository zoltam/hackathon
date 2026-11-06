# Valmet challenge notes — local models and fine-tuning

Valmet is the assigned challenge; detailed instructions will follow.

## Valmet — vision is plausible, not promised.

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
