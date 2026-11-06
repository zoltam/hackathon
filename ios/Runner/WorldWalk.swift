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
  private let align = UIButton(type: .system)
  private let toggle = UIButton(type: .system)
  private var alignment: WorldAlignment?
  private var showModel = false
  private var requestedCamera = false
  private var ready = false
  private var lastMessage: String?
  private var floorCells: Set<SIMD2<Int>>?
  private enum Motion: Hashable { case forward, backward, left, right }
  private var keys: [UIKeyboardHIDUsage: Motion] = [:]
  private var buttons = Set<Motion>()
  private var manualPosition = SIMD3<Float>.zero
  private var manualYaw: Float = 0
  private var displayLink: CADisplayLink?
  private var lastFrame: CFTimeInterval?

  override var canBecomeFirstResponder: Bool { model.keyControls }

  init(model: WalkSite, renderer: SplatRenderer) {
    self.model = model
    self.renderer = renderer
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    let previews: [UIView] = model.keyControls ? [virtual] : [reality, virtual]
    for preview in previews {
      preview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(preview)
      NSLayoutConstraint.activate([
        preview.topAnchor.constraint(equalTo: view.topAnchor),
        preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      ])
    }
    if !model.keyControls {
      reality.session.delegate = self
      reality.session.delegateQueue = .main
    }
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

    let row = UIStackView(arrangedSubviews: [toggle, close])
    row.distribution = .fillEqually
    row.spacing = 8
    let panel = UIStackView(arrangedSubviews: model.keyControls
      ? [message, makeControls(), close] : [message, align, row])
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
    if model.keyControls {
      manualPosition = model.center(model.start, height: assumedPhoneHeight)
      let forward = initialForward
      manualYaw = atan2(-forward.x, -forward.z)
      updateDisplay("WASD or arrows · Move and turn")
    } else {
      updateDisplay("Hold the phone steady while tracking starts.")
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if model.keyControls {
      becomeFirstResponder()
      let link = CADisplayLink(target: self, selector: #selector(stepManual))
      link.preferredFramesPerSecond = 30
      link.add(to: .main, forMode: .common)
      displayLink = link
      return
    }
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

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    displayLink?.invalidate()
    displayLink = nil
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
      (.left, "arrow.left", "Turn left"), (.forward, "arrow.up", "Move forward"),
      (.backward, "arrow.down", "Move backward"), (.right, "arrow.right", "Turn right"),
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
        if UIAccessibility.isVoiceOverRunning { self?.move(motions: [motion], seconds: 0.2) }
      }, for: .primaryActionTriggered)
      row.addArrangedSubview(button)
    }
    return row
  }

  private func motion(for usage: UIKeyboardHIDUsage) -> Motion? {
    switch usage {
    case .keyboardW, .keyboardUpArrow: return .forward
    case .keyboardS, .keyboardDownArrow: return .backward
    case .keyboardA, .keyboardLeftArrow: return .left
    case .keyboardD, .keyboardRightArrow: return .right
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

  private func move(motions: Set<Motion>, seconds: Float) {
    func axis(_ positive: Motion, _ negative: Motion) -> Float {
      (motions.contains(positive) ? 1 : 0) - (motions.contains(negative) ? 1 : 0)
    }
    manualYaw += axis(.left, .right) * seconds * 1.65
    let step = axis(.forward, .backward) * seconds * 1.2
    let x = manualPosition.x - sin(manualYaw) * step
    let z = manualPosition.z - cos(manualYaw) * step
    if isWalkable(cellAt(x: x, z: manualPosition.z)) { manualPosition.x = x }
    if isWalkable(cellAt(x: manualPosition.x, z: z)) { manualPosition.z = z }
  }

  @objc private func stepManual(_ link: CADisplayLink) {
    let seconds = Float(min(0.05, max(0, link.timestamp - (lastFrame ?? link.timestamp))))
    lastFrame = link.timestamp
    move(motions: buttons.union(keys.values), seconds: seconds)

    let size = virtual.bounds.size
    guard size.width > 0, size.height > 0 else { return }
    let yaw = simd_quatf(angle: manualYaw, axis: SIMD3(0, 1, 0))
    let pitch = simd_quatf(angle: -0.16, axis: SIMD3(1, 0, 0))
    var pose = simd_float4x4(yaw * pitch)
    pose.columns.3 = SIMD4(manualPosition.x, manualPosition.y, manualPosition.z, 1)
    let zoom: Float = 1.35, near: Float = 0.04, far: Float = 40
    let projection = simd_float4x4(columns: (
      SIMD4(zoom / Float(size.width / size.height), 0, 0, 0), SIMD4(0, zoom, 0, 0),
      SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)
    ))
    renderer.render(pose: pose, projection: projection)
    drawGuide(projection * pose.inverse)
    let cell = cellAt(x: manualPosition.x, z: manualPosition.z)
    updateDisplay(arrivalText(at: cell) ?? "WASD or arrows · Move and turn")
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
    let forward = initialForward
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
    let pose = alignment.modelPose(frame.camera.viewMatrix(for: orientation).inverse)
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
    let visible = model.keyControls || (ready && showModel && alignment != nil)
    virtual.isHidden = !visible
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
    if !model.keyControls { reality.session.pause() }
    dismiss(animated: true)
  }
}
