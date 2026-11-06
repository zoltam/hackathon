import ARKit
import AVFoundation
import SceneKit
import UIKit
import simd

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
  private let reality = ARSCNView()
  private let virtual = SCNView()
  private let eye = SCNNode()
  private let message = UILabel()
  private let aim = UILabel()
  private let align = UIButton(type: .system)
  private let toggle = UIButton(type: .system)
  private var alignment: WorldAlignment?
  private var showModel = false
  private var requestedCamera = false
  private var ready = false
  private var lastMessage: String?
  private var solidCells = Set<SIMD2<Int>>()
  private var floorCells: Set<SIMD2<Int>>?

  init(model: WalkSite) {
    self.model = model
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
    virtual.scene = buildScene()
    virtual.pointOfView = eye
    virtual.antialiasingMode = .multisampling2X
    virtual.isPlaying = true

    aim.text = "+"
    aim.textColor = .white
    aim.font = .boldSystemFont(ofSize: 36)
    aim.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(aim)

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
    let panel = UIStackView(arrangedSubviews: [message, align, row])
    panel.axis = .vertical
    panel.spacing = 8
    panel.isLayoutMarginsRelativeArrangement = true
    panel.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    panel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
    panel.layer.cornerRadius = 12
    panel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(panel)
    NSLayoutConstraint.activate([
      aim.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      aim.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
    ])
    updateDisplay("Scan the floor from your starting position.")
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
          configuration.planeDetection = [.horizontal]
          self.reality.session.run(configuration)
        } else {
          self.updateDisplay("Allow camera access in Settings to track your walk.")
        }
      }
    }
  }

  private func buildScene() -> SCNScene {
    let scene = SCNScene()
    scene.background.contents = UIColor(red: 0.15, green: 0.19, blue: 0.20, alpha: 1)
    let root = scene.rootNode
    let size = CGFloat(model.cellSize)

    func box(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat,
             _ width: CGFloat, _ height: CGFloat, _ depth: CGFloat, _ color: UIColor) {
      let shape = SCNBox(width: width, height: height, length: depth, chamferRadius: 0)
      shape.firstMaterial?.diffuse.contents = color
      let node = SCNNode(geometry: shape)
      node.position = SCNVector3(x, y, z)
      root.addChildNode(node)
    }

    let ground = UIColor(red: 0.34, green: 0.39, blue: 0.40, alpha: 1)
    if let floor = model.floor {
      floorCells = Set(floor.map { SIMD2($0[0], $0[1]) })
      for cell in floor {
        let point = model.center(cell)
        box(CGFloat(point.x), -0.06, CGFloat(point.z), size, 0.12, size, ground)
      }
    } else {
      let width = CGFloat(model.width) * size, depth = CGFloat(model.depth) * size
      box(width / 2, -0.06, depth / 2, width, 0.12, depth, ground)
      let wall = UIColor(red: 0.43, green: 0.46, blue: 0.46, alpha: 1)
      for z in [-0.09, depth + 0.09] {
        box(width / 2, 1.45, z, width + 0.36, 2.9, 0.18, wall)
      }
      for x in [-0.09, width + 0.09] {
        box(x, 1.45, depth / 2, 0.18, 2.9, depth, wall)
      }
      let lineColor = UIColor(white: 0.44, alpha: 1)
      for x in 0...model.width {
        box(CGFloat(x) * size, 0.002, depth / 2, 0.012, 0.003, depth, lineColor)
      }
      for z in 0...model.depth {
        box(width / 2, 0.002, CGFloat(z) * size, width, 0.003, 0.012, lineColor)
      }
    }

    for (index, object) in model.objects.enumerated() {
      let selected = model.target == index
      let color = selected ? UIColor.systemOrange : UIColor(red: 0.29, green: 0.44, blue: 0.51, alpha: 1)
      if let cells = object.cells {
        for cell in cells {
          solidCells.insert(SIMD2(cell[0], cell[1]))
          let point = model.center(cell)
          box(CGFloat(point.x), object.height / 2, CGFloat(point.z), size, object.height, size, color)
        }
      } else {
        for x in object.x..<(object.x + object.width) {
          for z in object.z..<(object.z + object.depth) { solidCells.insert(SIMD2(x, z)) }
        }
        box((CGFloat(object.x) + CGFloat(object.width) / 2) * size, object.height / 2,
            (CGFloat(object.z) + CGFloat(object.depth) / 2) * size,
            CGFloat(object.width) * size, object.height, CGFloat(object.depth) * size, color)
      }
      if selected {
        let ring = SCNTorus(ringRadius: 0.24, pipeRadius: 0.022)
        ring.firstMaterial?.diffuse.contents = UIColor.systemYellow
        ring.firstMaterial?.lightingModel = .constant
        let beacon = SCNNode(geometry: ring)
        beacon.eulerAngles.x = .pi / 2
        let facingCamera = SCNNode()
        facingCamera.position = SCNVector3(
          (CGFloat(object.x) + CGFloat(object.width) / 2) * size, object.height + 0.32,
          (CGFloat(object.z) + CGFloat(object.depth) / 2) * size
        )
        facingCamera.constraints = [SCNBillboardConstraint()]
        facingCamera.addChildNode(beacon)
        root.addChildNode(facingCamera)
      }
    }

    for (from, to) in zip(model.route, model.route.dropFirst()) {
      let a = model.center(from, height: 0.022), b = model.center(to, height: 0.022)
      let segment = SCNBox(width: 0.085, height: 0.018, length: size, chamferRadius: 0.005)
      segment.firstMaterial?.diffuse.contents = UIColor.systemMint
      segment.firstMaterial?.lightingModel = .constant
      let strip = SCNNode(geometry: segment)
      strip.simdPosition = (a + b) / 2
      strip.eulerAngles.y = atan2(b.x - a.x, b.z - a.z)
      root.addChildNode(strip)
    }
    if let last = model.route.last {
      let endpoint = model.center(last, height: 0.026)
      box(CGFloat(endpoint.x), 0.026, CGFloat(endpoint.z), 0.22, 0.04, 0.22, .systemMint)
    }

    let ambient = SCNNode()
    ambient.light = SCNLight()
    ambient.light?.type = .ambient
    ambient.light?.intensity = 600
    root.addChildNode(ambient)
    let directional = SCNNode()
    directional.light = SCNLight()
    directional.light?.type = .directional
    directional.light?.intensity = 850
    directional.eulerAngles = SCNVector3(-0.85, 0.5, 0)
    root.addChildNode(directional)

    eye.camera = SCNCamera()
    eye.camera?.zNear = 0.04
    eye.camera?.zFar = 250
    root.addChildNode(eye)
    return scene
  }

  @objc private func calibrate() {
    if alignment != nil {
      alignment = nil
      showModel = false
      updateDisplay("Face the first direction of the model route. Aim at the real floor.")
      return
    }
    guard ready, let frame = reality.session.currentFrame,
          case .normal = frame.camera.trackingState else { return }
    let position = frame.camera.transform.columns.3
    let back = frame.camera.transform.columns.2
    let horizontal = SIMD3(-back.x, 0, -back.z)
    guard simd_length(horizontal) > 0.25 else {
      updateDisplay("Tilt the phone toward the floor without pointing straight down.")
      return
    }
    let center = CGPoint(x: reality.bounds.midX, y: reality.bounds.midY)
    let hit = [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane].lazy.compactMap { target in
      self.reality.raycastQuery(from: center, allowing: target, alignment: .horizontal)
        .flatMap { self.reality.session.raycast($0).first }
    }.first
    guard let height = hit?.worldTransform.columns.3.y, (0.5...2.4).contains(position.y - height) else {
      updateDisplay("Floor not found. Aim at the floor a short distance ahead.")
      return
    }
    let start = model.center(model.start)
    let forward = model.route.dropFirst().first.map { model.center($0) - start } ?? SIMD3(0, 0, -1)
    alignment = WorldAlignment(
      physicalCamera: SIMD3(position.x, position.y, position.z),
      physicalFloor: height,
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
      updateDisplay("Face the first direction of the model route. Aim at the real floor.")
    }
  }

  private func updatePose(_ frame: ARFrame) {
    guard let alignment else { return }
    let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
    let pose = alignment.modelPose(frame.camera.viewMatrix(for: orientation).inverse)
    eye.simdTransform = pose
    let position = pose.columns.3
    let cell = SIMD2(Int(floor(position.x / model.cellSize)), Int(floor(position.z / model.cellSize)))
    let outOfBounds = cell.x < 0 || cell.y < 0 || cell.x >= model.width || cell.y >= model.depth
    if outOfBounds || solidCells.contains(cell) || floorCells?.contains(cell) == false {
      updateDisplay("Outside the model’s walkable area. Return to the route or show the camera.")
    } else if let end = model.route.last, cell == SIMD2(end[0], end[1]),
              let index = model.target, model.objects.indices.contains(index) {
      updateDisplay("At service position · \(model.objects[index].name)")
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
    aim.isHidden = alignment != nil
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
    virtual.isPlaying = false
    dismiss(animated: true)
  }
}
