import ARKit
import AVFoundation
import UIKit
import simd

let assumedPhoneHeight: Float = 1.75

struct WalkSite: Decodable {
  struct Block: Decodable {
    let name: String
    let x, z, width, depth: Int
    let height: CGFloat
    let cells: [[Int]]?
  }

  let name: String
  let width, depth: Int
  let cellSize: Float
  let start: [Int]
  let route: [[Int]]
  let floor: [[Int]]?
  let target: Int?
  let objects: [Block]
  let arrivalRadiusMetres: Float?
  let inspectionReport: String?

  var routeLength: Float { Float(max(0, route.count - 1)) * cellSize }

  func playbackPose(distance: Float) -> simd_float4x4? {
    guard route.count > 1 else { return nil }
    let step = min(max(0, distance), routeLength) / cellSize
    let index = min(Int(step), route.count - 2)
    let a = center(route[index], height: assumedPhoneHeight)
    let b = center(route[index + 1], height: assumedPhoneHeight)
    let position = a + (b - a) * min(1, step - Float(index))
    let forward = simd_normalize(b - a)
    let yaw = atan2(-forward.x, -forward.z)
    var pose = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
    pose.columns.3 = SIMD4(position.x, position.y, position.z, 1)
    return pose
  }

  func center(_ cell: [Int], height: Float = 0) -> SIMD3<Float> {
    SIMD3((Float(cell[0]) + 0.5) * cellSize, height, (Float(cell[1]) + 0.5) * cellSize)
  }
}

struct WorldAlignment {
  let worldFromTracking: simd_float4x4

  init(physicalCamera: SIMD3<Float>, physicalFloor: Float,
       physicalForward: SIMD3<Float>, modelStart: SIMD3<Float>, modelForward: SIMD3<Float>) {
    func yaw(_ direction: SIMD3<Float>) -> Float { atan2(-direction.x, -direction.z) }
    let turn = simd_quatf(angle: yaw(modelForward) - yaw(physicalForward), axis: SIMD3(0, 1, 0))
    let physicalStart = SIMD3(physicalCamera.x, physicalFloor, physicalCamera.z)
    var transform = simd_float4x4(turn)
    let translation = modelStart - turn.act(physicalStart)
    transform.columns.3 = SIMD4(translation.x, translation.y, translation.z, 1)
    worldFromTracking = transform
  }

  func modelPose(_ trackingPose: simd_float4x4) -> simd_float4x4 {
    worldFromTracking * trackingPose
  }
}

final class WorldWalk: UIViewController, ARSessionDelegate {
  private let model: WalkSite
  private let renderer: SplatRenderer
  private let reality = ARSCNView()
  private var virtual: UIView { renderer.view }
  private let routeLayer = CAShapeLayer()
  private let targetLayer = CAShapeLayer()
  private let message = UILabel()
  private let align = UIButton(type: .system)
  private let toggle = UIButton(type: .system)
  private let playback = UIButton(type: .system)
  private let inspect = UIButton(type: .system)
  private var previewMode = false
  private var playbackRunning = false
  private var playbackDistance: Float = 0
  private var previousFrameTime: TimeInterval?
  private var arrived = false
  private var alignment: WorldAlignment?
  private var showModel = false
  private var requestedCamera = false
  private var ready = false
  private var lastMessage: String?
  private var floorCells: Set<SIMD2<Int>>?

  init(model: WalkSite, renderer: SplatRenderer) {
    self.model = model
    self.renderer = renderer
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    for preview in [reality, virtual] {
      preview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(preview)
      NSLayoutConstraint.activate([
        preview.topAnchor.constraint(equalTo: view.topAnchor),
        preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      ])
    }
    reality.session.delegate = self
    reality.session.delegateQueue = .main
    floorCells = model.floor.map { Set($0.map { SIMD2($0[0], $0[1]) }) }
    for (layer, color, width) in [
      (routeLayer, UIColor.systemMint, CGFloat(4)),
      (targetLayer, UIColor.systemYellow, CGFloat(3)),
    ] {
      layer.strokeColor = color.cgColor
      layer.fillColor = UIColor.clear.cgColor
      layer.lineWidth = width
      layer.lineJoin = .round
      layer.lineCap = .round
      virtual.layer.addSublayer(layer)
    }

    message.font = .preferredFont(forTextStyle: .callout)
    message.textColor = .white
    message.numberOfLines = 0
    align.configuration = .filled()
    align.setTitle("Set start and direction", for: .normal)
    align.addTarget(self, action: #selector(calibrate), for: .touchUpInside)
    toggle.configuration = .tinted()
    toggle.setTitle("Show camera", for: .normal)
    toggle.addTarget(self, action: #selector(toggleView), for: .touchUpInside)
    let close = UIButton(type: .system)
    close.configuration = .tinted()
    close.setTitle("Close", for: .normal)
    close.addTarget(self, action: #selector(closeWalk), for: .touchUpInside)

    playback.configuration = .filled()
    playback.setTitle("Play route preview", for: .normal)
    playback.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
    inspect.configuration = .tinted()
    inspect.setTitle("Inspection evidence", for: .normal)
    inspect.addTarget(self, action: #selector(showInspection), for: .touchUpInside)
    let row = UIStackView(arrangedSubviews: [toggle, close])
    row.distribution = .fillEqually
    row.spacing = 8
    let panel = UIStackView(arrangedSubviews: [message, align, playback, inspect, row])
    panel.axis = .vertical
    panel.spacing = 8
    panel.isLayoutMarginsRelativeArrangement = true
    panel.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    panel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
    panel.layer.cornerRadius = 12
    panel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(panel)
    NSLayoutConstraint.activate([
      panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
    ])
    updateDisplay("Hold the phone steady while tracking starts.")
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !requestedCamera else { return }
    requestedCamera = true
    AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
      DispatchQueue.main.async {
        guard let self, self.view.window != nil else { return }
        if allowed {
          let configuration = ARWorldTrackingConfiguration()
          configuration.worldAlignment = .gravity
          self.reality.session.run(configuration)
        } else {
          self.updateDisplay("Allow camera access in Settings to track your walk.")
        }
      }
    }
  }

  private func drawGuide(_ transform: simd_float4x4) {
    let bounds = virtual.bounds
    func project(_ point: SIMD3<Float>) -> CGPoint? {
      let clip = transform * SIMD4(point.x, point.y, point.z, 1)
      guard clip.w > 0.04 else { return nil }
      return CGPoint(x: (CGFloat(clip.x / clip.w) + 1) * bounds.width / 2,
                     y: (1 - CGFloat(clip.y / clip.w)) * bounds.height / 2)
    }

    let path = UIBezierPath()
    var previous: CGPoint?
    for cell in model.route {
      guard let point = project(model.center(cell, height: 0.07)) else {
        previous = nil
        continue
      }
      if previous == nil { path.move(to: point) } else { path.addLine(to: point) }
      previous = point
    }

    let ring = UIBezierPath()
    if let index = model.target, model.objects.indices.contains(index) {
      let target = model.objects[index]
      let position = SIMD3(
        (Float(target.x) + Float(target.width) / 2) * model.cellSize,
        Float(target.height),
        (Float(target.z) + Float(target.depth) / 2) * model.cellSize
      )
      if let point = project(position) {
        ring.addArc(withCenter: point, radius: 17, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
      }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    routeLayer.frame = bounds
    routeLayer.path = path.cgPath
    targetLayer.frame = bounds
    targetLayer.path = ring.cgPath
    CATransaction.commit()
  }

  @objc private func calibrate() {
    if alignment != nil {
      previewMode = false
      playbackRunning = false
      playbackDistance = 0
      previousFrameTime = nil
      arrived = false
      alignment = nil
      showModel = false
      updateDisplay("Stand at your start, hold the phone upright and face the first direction of the route.")
      return
    }
    guard ready, let frame = reality.session.currentFrame,
          case .normal = frame.camera.trackingState else { return }
    let position = frame.camera.transform.columns.3
    let back = frame.camera.transform.columns.2
    let horizontal = SIMD3(-back.x, 0, -back.z)
    guard simd_length(horizontal) > 0.25 else {
      updateDisplay("Hold the phone upright and point it forward to set the route direction.")
      return
    }
    let start = model.center(model.start)
    let forward = model.route.dropFirst().first.map { model.center($0) - start } ?? SIMD3(0, 0, -1)
    alignment = WorldAlignment(
      physicalCamera: SIMD3(position.x, position.y, position.z),
      physicalFloor: position.y - assumedPhoneHeight,
      physicalForward: horizontal,
      modelStart: start,
      modelForward: forward
    )
    showModel = true
    updatePose(frame)
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard case .normal = frame.camera.trackingState else {
      previousFrameTime = nil
      if ready {
        ready = false
        updateDisplay("Tracking paused. Hold still and point at recognizable features.")
      }
      return
    }
    let resumed = !ready
    ready = true
    if alignment != nil {
      updatePose(frame)
    } else if resumed {
      updateDisplay("Stand at your start, hold the phone upright and face the first direction of the route.")
    }
  }

  private func updatePose(_ frame: ARFrame) {
    guard let alignment else { return }
    let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
    if previewMode && playbackRunning {
      if let last = previousFrameTime {
        playbackDistance = min(model.routeLength,
          playbackDistance + Float(max(0, min(frame.timestamp - last, 0.1))) * 0.7)
      }
      if playbackDistance >= model.routeLength { playbackRunning = false }
    }
    previousFrameTime = frame.timestamp
    let physicalPose = alignment.modelPose(frame.camera.viewMatrix(for: orientation).inverse)
    let pose = previewMode ? (model.playbackPose(distance: playbackDistance) ?? physicalPose) : physicalPose
    let size = virtual.bounds.size
    if showModel, size.width > 0, size.height > 0 {
      virtual.isHidden = false
      let projection = frame.camera.projectionMatrix(for: orientation, viewportSize: size, zNear: 0.04, zFar: 40)
      renderer.render(pose: pose, projection: projection)
      drawGuide(projection * pose.inverse)
    }
    let position = pose.columns.3
    let cell = SIMD2(Int(floor(position.x / model.cellSize)), Int(floor(position.z / model.cellSize)))
    let outOfBounds = cell.x < 0 || cell.y < 0 || cell.x >= model.width || cell.y >= model.depth
    arrived = false
    if outOfBounds || floorCells?.contains(cell) == false {
      updateDisplay("Outside the model’s walkable area. Return to the route or show the camera.")
    } else if let end = model.route.last,
              simd_distance(SIMD2(position.x, position.z),
                SIMD2(model.center(end).x, model.center(end).z)) <= (model.arrivalRadiusMetres ?? model.cellSize / 2),
              let index = model.target, model.objects.indices.contains(index) {
      arrived = true
      updateDisplay((previewMode ? "Preview at service position · " : "At service position · ") +
        model.objects[index].name + "\nTarget recognition is checked separately.")
    } else {
      updateDisplay(model.name + (previewMode ? " · Automatic route preview" :
        (model.route.isEmpty ? " · Explore the model" : " · Follow the green route")))
    }
  }

  @objc private func togglePlayback() {
    guard alignment != nil, ready, model.route.count > 1 else { return }
    if !previewMode || playbackDistance >= model.routeLength {
      previewMode = true
      playbackDistance = 0
    }
    playbackRunning.toggle()
    previousFrameTime = nil
    showModel = true
    updateDisplay(model.name + " · Automatic route preview")
  }

  @objc private func showInspection() {
    guard arrived else { return }
    let report = UIViewController()
    report.title = "Inspection evidence"
    report.view.backgroundColor = .systemBackground
    let text = UITextView()
    text.isEditable = false
    text.font = .preferredFont(forTextStyle: .body)
    text.text = model.inspectionReport ?? "No workbook evidence is available for this target."
    text.translatesAutoresizingMaskIntoConstraints = false
    report.view.addSubview(text)
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: report.view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      text.trailingAnchor.constraint(equalTo: report.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      text.topAnchor.constraint(equalTo: report.view.safeAreaLayoutGuide.topAnchor, constant: 16),
      text.bottomAnchor.constraint(equalTo: report.view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])
    present(report, animated: true)
  }

  func sessionWasInterrupted(_ session: ARSession) {
    previousFrameTime = nil
    ready = false
    updateDisplay("Tracking interrupted. Return to the original area.")
  }

  func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

  func session(_ session: ARSession, didFailWithError error: Error) {
    alignment = nil
    ready = false
    updateDisplay("Tracking stopped. Close the walkthrough and try again.")
  }

  private func updateDisplay(_ text: String) {
    let visible = ready && showModel && alignment != nil
    virtual.isHidden = !visible
    playback.isEnabled = ready && alignment != nil && model.route.count > 1
    playback.setTitle(playbackRunning ? "Pause route preview" :
      (playbackDistance >= model.routeLength ? "Replay route preview" : "Play route preview"), for: .normal)
    inspect.isEnabled = arrived
    align.isEnabled = ready || alignment != nil
    toggle.isEnabled = alignment != nil && ready
    align.setTitle(alignment == nil ? "Set start and direction" : "Reset alignment", for: .normal)
    toggle.setTitle(visible ? "Show camera" : "Show 3D model", for: .normal)
    if lastMessage != text {
      message.text = text
      lastMessage = text
    }
  }

  @objc private func toggleView() {
    showModel.toggle()
    if !showModel { playbackRunning = false; previousFrameTime = nil }
    updateDisplay(lastMessage ?? model.name)
  }

  @objc private func closeWalk() {
    reality.session.pause()
    dismiss(animated: true)
  }
}
