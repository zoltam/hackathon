import ARKit
import AVFoundation
import UIKit
import simd

let assumedPhoneHeight: Float = 1.50

struct WalkSite: Decodable {
  struct Block: Decodable {
    let name: String
    let objectId: String?
    let x, z, width, depth: Int
    let height: CGFloat
    let cells: [[Int]]?
    let bounds: [[Float]]?
  }

  let name: String
  let keyControls: Bool
  let width, depth: Int
  let cellSize: Float
  let start: [Int]
  let route: [[Int]]
  let floor: [[Int]]?
  let target: Int?
  let objects: [Block]

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
  private let visionStatus = UILabel()
  private let verifyVision: Bool
  private var verificationFrames = 0
  private var lastTargetMatch: CFTimeInterval?
  private var targetBounds: PumpBounds?
  private var targetName: String?
  private var targetID: String?
  private let align = UIButton(type: .system)
  private let toggle = UIButton(type: .system)
  private var alignment: WorldAlignment?
  private var showModel = false
  private var requestedCamera = false
  private var ready = false
  private var lastMessage: String?
  private var floorCells: Set<SIMD2<Int>>?
  private enum Motion: Hashable { case forward, backward }
  private var keys: [UIKeyboardHIDUsage: Motion] = [:]
  private var buttons = Set<Motion>()
  private var movementControls: UIView?
  private var manualPosition = SIMD3<Float>.zero
  private var lastFrame: CFTimeInterval?

  override var canBecomeFirstResponder: Bool { model.keyControls }

  init(model: WalkSite, renderer: SplatRenderer, verifyVision: Bool = false) {
    self.model = model
    self.renderer = renderer
    self.verifyVision = verifyVision
    if let index = model.target, model.objects.indices.contains(index) {
      let target = model.objects[index]
      targetBounds = target.bounds.flatMap(PumpBounds.init)
      targetName = target.name
      targetID = target.objectId
    }
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
    visionStatus.font = .preferredFont(forTextStyle: .caption1)
    visionStatus.textColor = .white
    visionStatus.numberOfLines = 2
    visionStatus.isHidden = true
    renderer.vision.onPrediction = { [weak self] prediction in
      guard let self, self.view.window != nil, !self.virtual.isHidden else { return }
      self.lastTargetMatch = prediction.matched ? prediction.frame.timestamp : nil
      if self.verifyVision {
        print("VALMET_VISION sample=\(self.verificationFrames) object=\(prediction.matched ? self.targetID ?? "none" : "none") ts=\(prediction.frame.timestamp) x=\(prediction.frame.pose.columns.3.x) matched=\(prediction.matched) distance=\(prediction.distance) red=\(prediction.redFraction) ms=\(prediction.inferenceMilliseconds)")
        fflush(stdout)
        self.verificationFrames += 1
      }
      guard CACurrentMediaTime() - prediction.frame.timestamp < 2 else { return }
      self.visionStatus.text = prediction.matched ? "Vision matched · \(self.targetName ?? "Target")" : "Vision · Searching for the target"
      self.visionStatus.isHidden = false
    }
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

    let row = UIStackView(arrangedSubviews: [toggle, close])
    row.distribution = .fillEqually
    row.spacing = 8
    movementControls = model.keyControls ? makeControls() : nil
    let panel = UIStackView(arrangedSubviews: [message, visionStatus, movementControls, align, row].compactMap { $0 })
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
    if verifyVision {
      verifyRenderedFrame(index: 0)
      return
    }
    if model.keyControls { becomeFirstResponder() }
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

  // Repeatable device smoke check. Uses the normal renderer and model,
  // with synthetic camera poses instead of requiring a person to walk.
  private func verifyRenderedFrame(index: Int) {
    guard view.window != nil, verificationFrames < 7, index < 12 else { return }
    virtual.isHidden = false
    let size = virtual.bounds.size
    if size.width > 0, size.height > 0 {
      let eye = index == 5 ? SIMD3<Float>(4.625, 1.50, 1.625) :
        SIMD3<Float>(5.385 - Float(index % 3) * 0.08, 1.50, 1.88 + Float(index % 2) * 0.06)
      let look: SIMD3<Float> = index == 2 ? SIMD3(6.90, 1.15, 2.43) :
        index == 3 ? SIMD3(3.0, 1.15, 1.875) : SIMD3(5.943, 1.164, 2.447)
      let back = simd_normalize(eye - look)
      let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), back))
      let up = simd_cross(back, right)
      func vector(_ p: SIMD3<Float>, _ w: Float) -> SIMD4<Float> { SIMD4(p.x, p.y, p.z, w) }
      let pose = simd_float4x4(columns: (vector(right, 0), vector(up, 0), vector(back, 0), vector(eye, 1)))
      let n: Float = 0.04, f: Float = 40, zoom: Float = 1.4
      let projection = simd_float4x4(columns: (
        SIMD4(zoom / Float(size.width / size.height), 0, 0, 0), SIMD4(0, zoom, 0, 0),
        SIMD4(0, 0, f / (n - f), -1), SIMD4(0, 0, n * f / (n - f), 0)
      ))
      renderer.render(pose: pose, projection: projection)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { [weak self] in
      self?.verifyRenderedFrame(index: index + 1)
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    lastFrame = nil
    keys.removeAll()
    buttons.removeAll()
  }

  private var initialForward: SIMD3<Float> {
    model.route.dropFirst().first.map { model.center($0) - model.center(model.start) } ?? SIMD3(0, 0, -1)
  }

  private func makeControls() -> UIView {
    let row = UIStackView()
    row.spacing = 8
    row.distribution = .fillEqually
    let controls: [(Motion, String, String)] = [
      (.forward, "arrow.up", "Move forward"), (.backward, "arrow.down", "Move backward"),
    ]
    for (motion, symbol, title) in controls {
      let button = UIButton(type: .system)
      var configuration = UIButton.Configuration.tinted()
      configuration.image = UIImage(systemName: symbol)
      button.configuration = configuration
      button.accessibilityLabel = title
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      button.addAction(UIAction { [weak self] _ in self?.buttons.insert(motion) }, for: .touchDown)
      button.addAction(UIAction { [weak self] _ in self?.buttons.remove(motion) },
                       for: [.touchUpInside, .touchUpOutside, .touchCancel])
      button.addAction(UIAction { [weak self] _ in
        if UIAccessibility.isVoiceOverRunning, let self, self.ready, self.showModel,
           let frame = self.reality.session.currentFrame, let alignment = self.alignment {
          self.move(motions: [motion], seconds: 0.12, pose: alignment.modelPose(frame.camera.transform))
        }
      }, for: .primaryActionTriggered)
      row.addArrangedSubview(button)
    }
    return row
  }

  private func motion(for usage: UIKeyboardHIDUsage) -> Motion? {
    switch usage {
    case .keyboardUpArrow: return .forward
    case .keyboardDownArrow: return .backward
    default: return nil
    }
  }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    var unhandled = presses
    if model.keyControls {
      for press in presses {
        if let code = press.key?.keyCode, let motion = motion(for: code) {
          keys[code] = motion
          unhandled.remove(press)
        }
      }
    }
    if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
  }

  private func releaseKeys(_ presses: Set<UIPress>) -> Set<UIPress> {
    var unhandled = presses
    for press in presses {
      if let code = press.key?.keyCode, keys.removeValue(forKey: code) != nil {
        unhandled.remove(press)
      }
    }
    return unhandled
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    let unhandled = releaseKeys(presses)
    if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
  }

  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    let unhandled = releaseKeys(presses)
    if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
  }

  private func move(motions: Set<Motion>, seconds: Float, pose: simd_float4x4) {
    let direction: Float = (motions.contains(.forward) ? 1 : 0) -
      (motions.contains(.backward) ? 1 : 0)
    guard direction != 0 else { return }
    let back = pose.columns.2
    let heading = SIMD2(-back.x, -back.z)
    guard simd_length(heading) > 0.1 else { return }
    let offset = simd_normalize(heading) * (direction * seconds * 1.2)
    let x = manualPosition.x + offset.x
    let z = manualPosition.z + offset.y
    if isWalkable(cellAt(x: x, z: manualPosition.z)) { manualPosition.x = x }
    if isWalkable(cellAt(x: manualPosition.x, z: z)) { manualPosition.z = z }
  }

  private func cellAt(x: Float, z: Float) -> SIMD2<Int> {
    SIMD2(Int(floor(x / model.cellSize)), Int(floor(z / model.cellSize)))
  }

  private func isWalkable(_ cell: SIMD2<Int>) -> Bool {
    cell.x >= 0 && cell.y >= 0 && cell.x < model.width && cell.y < model.depth &&
      floorCells?.contains(cell) != false
  }

  private func arrivalText(at cell: SIMD2<Int>) -> String? {
    guard let end = model.route.last, cell == SIMD2(end[0], end[1]),
          let index = model.target, model.objects.indices.contains(index) else { return nil }
    return "At service position · \(model.objects[index].name)"
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
    if let match = lastTargetMatch, CACurrentMediaTime() - match < 1.2,
       let region = targetBounds?.region(transform: transform) {
      ring.append(UIBezierPath(roundedRect: CGRect(
        x: region.minX * bounds.width, y: (1 - region.maxY) * bounds.height,
        width: region.width * bounds.width, height: region.height * bounds.height
      ), cornerRadius: 6))
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
      alignment = nil
      showModel = false
      lastFrame = nil
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
    let forward = initialForward
    alignment = WorldAlignment(
      physicalCamera: SIMD3(position.x, position.y, position.z),
      physicalFloor: position.y - assumedPhoneHeight,
      physicalForward: horizontal,
      modelStart: start,
      modelForward: forward
    )
    manualPosition = model.center(model.start, height: assumedPhoneHeight)
    lastFrame = nil
    showModel = true
    updatePose(frame)
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard case .normal = frame.camera.trackingState else {
      if ready {
        ready = false
        lastFrame = nil
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
    var pose = alignment.modelPose(frame.camera.viewMatrix(for: orientation).inverse)
    if model.keyControls {
      let seconds = Float(min(0.05, max(0, frame.timestamp - (lastFrame ?? frame.timestamp))))
      lastFrame = frame.timestamp
      if showModel { move(motions: buttons.union(keys.values), seconds: seconds, pose: pose) }
      pose.columns.3 = SIMD4(manualPosition.x, manualPosition.y, manualPosition.z, 1)
    }
    let size = virtual.bounds.size
    if showModel, size.width > 0, size.height > 0 {
      virtual.isHidden = false
      let projection = frame.camera.projectionMatrix(for: orientation, viewportSize: size, zNear: 0.04, zFar: 40)
      renderer.render(pose: pose, projection: projection)
      drawGuide(projection * pose.inverse)
    }
    let position = pose.columns.3
    let cell = cellAt(x: position.x, z: position.z)
    if !isWalkable(cell) {
      updateDisplay("Outside the model’s walkable area. Return to the route or show the camera.")
    } else if let arrival = arrivalText(at: cell) {
      updateDisplay(arrival)
    } else {
      updateDisplay(model.name + (model.route.isEmpty ? " · Explore the model" : " · Follow the green route"))
    }
  }

  func sessionWasInterrupted(_ session: ARSession) {
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
    movementControls?.isHidden = !visible
    if !visible {
      buttons.removeAll()
      visionStatus.isHidden = true
      lastTargetMatch = nil
    }
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
    updateDisplay(lastMessage ?? model.name)
  }

  @objc private func closeWalk() {
    reality.session.pause()
    dismiss(animated: true)
  }
}
