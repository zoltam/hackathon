import ARKit
import AVFoundation
import ReplayKit
import UIKit

private struct RecordedRoute: Codable {
  var steps: [SIMD3<Float>]
  var target: SIMD3<Float>
  var facing: SIMD3<Float>
  var map: Data
}

final class RouteCamera: UIViewController, ARSessionDelegate, RPPreviewViewControllerDelegate {
  private enum Mode { case idle, recording, marking, saving, replay }
  private let scene = ARSCNView()
  private let status = UILabel()
  private let aim = UILabel()
  private let record = UIButton(type: .system)
  private let replay = UIButton(type: .system)
  private let video = UIButton(type: .system)
  private let done = UIButton(type: .system)
  private let recorder = RPScreenRecorder.shared()
  private var mode = Mode.idle
  private var steps: [SIMD3<Float>] = []
  private var floor: Float = 0
  private var guidance: SCNNode?
  private var saved: RecordedRoute?
  private var activeStep = -1
  private var renderedStep = -2
  private var stableFrames = 0
  private var missedTracking = false
  private var videoBusy = false
  private var requestedCamera = false
  private var message: String?
  private var store: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("valmet-ar-route.json")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    scene.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scene)
    scene.session.delegate = self
    scene.session.delegateQueue = .main

    status.numberOfLines = 0
    status.textColor = .white
    status.font = .preferredFont(forTextStyle: .callout)
    aim.text = "⊕"
    aim.textColor = .white
    aim.font = .systemFont(ofSize: 32, weight: .medium)
    aim.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(aim)

    record.addTarget(self, action: #selector(recordAction), for: .touchUpInside)
    replay.addTarget(self, action: #selector(replayAction), for: .touchUpInside)
    video.addTarget(self, action: #selector(videoAction), for: .touchUpInside)
    done.addTarget(self, action: #selector(closeCamera), for: .touchUpInside)
    let row = UIStackView(arrangedSubviews: [video, done])
    row.distribution = .fillEqually
    row.spacing = 8
    let controls = UIStackView(arrangedSubviews: [status, record, replay, row])
    controls.axis = .vertical
    controls.spacing = 8
    controls.backgroundColor = UIColor.black.withAlphaComponent(0.8)
    controls.layer.cornerRadius = 14
    controls.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    controls.isLayoutMarginsRelativeArrangement = true
    controls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controls)
    NSLayoutConstraint.activate([
      scene.topAnchor.constraint(equalTo: view.topAnchor),
      scene.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      scene.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scene.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      aim.centerXAnchor.constraint(equalTo: scene.centerXAnchor),
      aim.centerYAnchor.constraint(equalTo: scene.centerYAnchor),
      controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
    ])
    done.configuration = .borderedTinted()
    done.setTitle("Close", for: .normal)
    if let data = try? Data(contentsOf: store) {
      saved = try? JSONDecoder().decode(RecordedRoute.self, from: data)
    }
    updateControls()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !requestedCamera else { return }
    requestedCamera = true
    AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
      DispatchQueue.main.async {
        guard let self, self.view.window != nil else { return }
        if allowed {
          self.runSession()
        } else {
          self.message = "Allow camera access in Settings to use AR."
          self.updateControls()
        }
      }
    }
  }

  private func runSession(map: ARWorldMap? = nil) {
    let config = ARWorldTrackingConfiguration()
    config.planeDetection = [.horizontal, .vertical]
    config.initialWorldMap = map
    stableFrames = 0
    scene.session.run(config, options: [.resetTracking, .removeExistingAnchors])
  }

  private func updateControls() {
    let canTrack = stableFrames >= 5
    let recordTitle: String
    let hint: String
    switch mode {
    case .idle:
      recordTitle = "Start at floor marker"
      hint = canTrack ? "Aim at the floor by your feet and start the walk." : "Scan the room slowly to establish tracking."
    case .recording:
      recordTitle = "Mark service target"
      hint = canTrack ? "Walk around obstacles. \(steps.count) route points." : "Tracking lost. Stop walking and scan the surroundings."
    case .marking:
      recordTitle = "Save route and target"
      hint = "Stand where you will service the device. Aim at its surface."
    case .saving:
      recordTitle = "Saving…"
      hint = "Saving route and room map on this phone."
    case .replay:
      recordTitle = "Record a new route"
      hint = !canTrack ? "Return to the original room and scan familiar features."
        : activeStep < 0 ? "Walk to the first blue marker."
        : activeStep >= (saved?.steps.count ?? 0) - 1 ? "At service position. The orange ring marks the target."
        : "Follow the blue markers in order."
    }
    status.text = message ?? hint
    aim.isHidden = mode == .replay || mode == .saving
    setButton(record, title: recordTitle, prominent: true)
    setButton(replay, title: mode == .replay ? "Restart replay" : "Replay saved route")
    setButton(video, title: recorder.isRecording ? "Stop video" : "Start video")
    record.isEnabled = mode == .replay || (canTrack && mode != .saving)
    replay.isEnabled = saved != nil && mode != .saving && mode != .recording && mode != .marking
    video.isEnabled = !videoBusy && (recorder.isRecording || (canTrack && recorder.isAvailable))
    done.isEnabled = !videoBusy && !recorder.isRecording && mode != .saving
  }

  private func setButton(_ button: UIButton, title: String, prominent: Bool = false) {
    if button.configuration?.title == title { return }
    var config: UIButton.Configuration = prominent ? .filled() : .tinted()
    config.title = title
    button.configuration = config
  }

  private func hit(_ alignment: ARRaycastQuery.TargetAlignment) -> SIMD3<Float>? {
    let center = CGPoint(x: scene.bounds.midX, y: scene.bounds.midY)
    for target: ARRaycastQuery.Target in [.existingPlaneGeometry, .estimatedPlane] {
      if let query = scene.raycastQuery(from: center, allowing: target, alignment: alignment),
         let result = scene.session.raycast(query).first {
        return position(result.worldTransform)
      }
    }
    return nil
  }

  private func position(_ transform: simd_float4x4) -> SIMD3<Float> {
    SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
  }

  @objc private func recordAction() {
    message = nil
    defer { updateControls() }
    if mode == .replay {
      resetWalk()
      runSession()
      return
    }
    guard let frame = scene.session.currentFrame, case .normal = frame.camera.trackingState else { return }
    let camera = position(frame.camera.transform)
    switch mode {
    case .idle:
      guard let ground = hit(.horizontal), (0.5...2.5).contains(camera.y - ground.y) else {
        message = "Floor not found. Move the camera slowly and aim down near your feet."
        return
      }
      floor = ground.y + 0.06
      steps = [SIMD3(camera.x, floor, camera.z)]
      mode = .recording
    case .recording:
      guard steps.count >= 2 else {
        message = "Walk a little farther before marking the target."
        return
      }
      mode = .marking
    case .marking:
      guard frame.worldMappingStatus == .mapped || frame.worldMappingStatus == .extending else {
        message = "Scan nearby walls and equipment to improve the room map."
        return
      }
      guard let target = hit(.any), (0.25...5).contains(simd_distance(camera, target)) else {
        message = "No surface found near the aim point. Move closer and scan the device."
        return
      }
      let end = SIMD3(camera.x, floor, camera.z)
      guard let last = steps.last, simd_distance(last, end) <= 0.5 else {
        message = "Return to where you stopped the walk to save the service position."
        return
      }
      let path = simd_distance(last, end) > 0.05 ? steps + [end] : steps
      save(path, target: target, facing: simd_normalize(camera - target))
    case .saving, .replay:
      break
    }
  }

  private func save(_ path: [SIMD3<Float>], target: SIMD3<Float>, facing: SIMD3<Float>) {
    mode = .saving
    let destination = store
    scene.session.getCurrentWorldMap { [weak self] map, error in
      DispatchQueue.global(qos: .userInitiated).async {
        let result = Result {
          guard let map else { throw error ?? CocoaError(.fileWriteUnknown) }
          let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
          let route = RecordedRoute(steps: path, target: target, facing: facing, map: data)
          try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
          try JSONEncoder().encode(route).write(to: destination, options: .atomic)
          return route
        }
        DispatchQueue.main.async {
          guard let self else { return }
          switch result {
          case .success(let route):
            self.saved = route
            self.resetWalk()
            self.message = "Route saved. Return to the start and tap Replay saved route."
          case .failure:
            self.mode = .marking
            self.message = "Could not save the room map. Scan the surroundings and retry."
          }
          self.updateControls()
        }
      }
    }
  }

  @objc private func replayAction() {
    guard let saved,
          let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: saved.map) else {
      message = "Could not read the saved room map."
      updateControls()
      return
    }
    resetWalk()
    mode = .replay
    runSession(map: map)
    updateControls()
  }

  private func resetWalk() {
    mode = .idle
    steps.removeAll()
    guidance?.removeFromParentNode()
    guidance = nil
    activeStep = -1
    renderedStep = -2
    missedTracking = false
    message = nil
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard case .normal = frame.camera.trackingState else {
      if mode == .recording || mode == .marking { missedTracking = true }
      if stableFrames != 0 {
        stableFrames = 0
        guidance?.isHidden = true
        updateControls()
      }
      return
    }
    if stableFrames < 5 {
      stableFrames += 1
      guard stableFrames == 5 else { return }
      updateControls()
    }
    let camera = position(frame.camera.transform)
    if mode == .recording, let last = steps.last {
      let ground = SIMD3(camera.x, floor, camera.z)
      let distance = simd_distance(last, ground)
      if (missedTracking && distance > 0.4) || distance > 1.0 || steps.count >= 8000 {
        resetWalk()
        message = "Walk lost tracking or exceeded its limit. Start a new walk."
        updateControls()
      } else {
        missedTracking = false
        if distance >= 0.20 {
          steps.append(ground)
          message = nil
          updateControls()
        }
      }
    } else if mode == .replay, let saved, !saved.steps.isEmpty {
      let next = activeStep + 1
      if saved.steps.indices.contains(next) {
        let waypoint = saved.steps[next]
        let distance = simd_distance(SIMD2(camera.x, camera.z), SIMD2(waypoint.x, waypoint.z))
        if distance < (next == 0 ? 0.55 : 0.36) {
          activeStep = next
          updateControls()
        }
      }
      if renderedStep != activeStep {
        draw(saved)
        renderedStep = activeStep
      }
      guidance?.isHidden = false
    }
  }

  func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

  func session(_ session: ARSession, didFailWithError error: Error) {
    resetWalk()
    stableFrames = 0
    message = "AR session stopped: \(error.localizedDescription)"
    updateControls()
  }

  private func draw(_ route: RecordedRoute) {
    guidance?.removeFromParentNode()
    let group = SCNNode()
    let start = activeStep < 0 ? 0 : activeStep + 1
    let end = min(route.steps.count, start + (activeStep < 0 ? 1 : 8))
    for index in start..<end {
      let marker = SCNSphere(radius: index == start ? 0.085 : 0.038)
      marker.firstMaterial?.lightingModel = .constant
      marker.firstMaterial?.diffuse.contents = UIColor.systemCyan
      let node = SCNNode(geometry: marker)
      node.simdPosition = route.steps[index]
      group.addChildNode(node)
    }
    if activeStep >= route.steps.count - 2, activeStep >= 0 {
      let ring = SCNTorus(ringRadius: 0.19, pipeRadius: 0.013)
      ring.firstMaterial?.lightingModel = .constant
      ring.firstMaterial?.diffuse.contents = UIColor.systemOrange
      let node = SCNNode(geometry: ring)
      node.simdPosition = route.target + route.facing * 0.035
      node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: route.facing)
      group.addChildNode(node)
    }
    scene.scene.rootNode.addChildNode(group)
    guidance = group
  }

  @objc private func videoAction() {
    videoBusy = true
    message = nil
    updateControls()
    if recorder.isRecording {
      recorder.stopRecording { [weak self] preview, error in
        DispatchQueue.main.async {
          guard let self else { return }
          self.videoBusy = false
          if let preview {
            preview.previewControllerDelegate = self
            self.present(preview, animated: true)
          } else if let error {
            self.message = error.localizedDescription
          }
          self.updateControls()
        }
      }
    } else {
      recorder.isMicrophoneEnabled = false
      recorder.startRecording { [weak self] error in
        DispatchQueue.main.async {
          self?.videoBusy = false
          self?.message = error?.localizedDescription
          self?.updateControls()
        }
      }
    }
  }

  func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
    previewController.dismiss(animated: true)
  }

  @objc private func closeCamera() {
    scene.session.pause()
    dismiss(animated: true)
  }
}
