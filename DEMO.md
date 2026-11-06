# Demo plan

## Opening — live action into the CGI environment

Start with live-action footage of a person holding the iPhone, then transition into the virtual boiler room as though we are entering the environment through the phone.

**Visual reference:** [the first few seconds of this video](https://www.youtube.com/watch?v=u-MjuMqKUpM). Use the live-action-to-CGI transition described in the reference as inspiration for the opening.

### Proposed sequence

| Timing | Picture / action |
| --- | --- |
| 0–3 seconds | Live-action shot: the person raises the iPhone, ready to explore. Move the camera toward the phone screen. |
| 3–5 seconds | Transition: match the phone's view and camera movement to the rendered boiler room, letting the virtual environment fill the frame. Aim for one continuous movement into the scene. |
| 5–10 seconds | Continue inside the CGI environment. A turn or step carries through from the live-action shot into the virtual camera movement, establishing that the phone controls the viewpoint. |

### Production notes

- Match the framing, direction of movement and virtual starting pose across the transition.
- Carry sound across the transition; introduce boiler-room ambience as the CGI environment fills the screen.
- Keep the opening brief so it leads directly into the app demonstration.
- Treat the transition as an edited introduction. Show the actual app interaction immediately afterward.

## Submission cut

Aim for two minutes. The brief allows five minutes.

| Timing | Show | Explain |
| --- | --- | --- |
| 0:00–0:15 | Scan and equipment frames | The complete replacement scan contains 1.68 million splats. The scene has 17 reviewed objects, including 11 trained detector IDs. |
| 0:15–0:35 | Floor map and pump approach | The planner finds a 3.10 m route over observed floor with clearance for the virtual camera. |
| 0:35–1:10 | Scripted first-person journey | Mint arrows guide the avatar. Teal frames show nearby mapped objects and their synthetic conditions. Yellow boxes show detections from clean rendered frames. |
| 1:10–1:35 | Arrival and inspection report | The red pump is mapped to synthetic asset ASSET-017. Show the source workbook row and the recommended next check in the app. |
| 1:35–2:00 | Validation and limits | On the held-out rendered walking views, the app's frame filter retained 67/69 pump detections with zero false pump detections. Clarify that the automated journey uses scripted camera movement. |

Use a physical opening only if recorded. Label simulator or offscreen footage where used. Keep the separate offline physical acceptance check pending until someone follows the route with Wi-Fi and cellular disabled.

## Rehearsal and handoff

1. Prepare local assets using [README](README.md). Use the signed iPhone build and the automatic journey command for a repeatable run.
2. Check that the pump is recognized, nearby frames have workbook conditions, and arrival opens the next check. Keep a local recording for the pitch.
3. Use the 5–8 slide deck, short demo video, repository and [technical note](docs/TECHNICAL-NOTE.md) for the handoff. Verify each opens before submission. Confirm organizer terms before sharing scan-derived media outside the team.
4. Record mentor feedback and submission confirmation here once received.
