import ARKit
import AVFoundation
import SceneKit
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
  private let points: Data
  private let reality = ARSCNView()
  private let virtual = SCNView()
  private let eye = SCNNode()
  private let message = UILabel()
  private let align = UIButton(type: .system)
  private let toggle = UIButton(type: .system)
  private var alignment: WorldAlignment?
  private var showModel = false
  private var requestedCamera = false
  private var ready = false
  private var lastMessage: String?
  private var floorCells: Set<SIMD2<Int>>?

  init(model: WalkSite, points: Data) {
    self.model = model
    self.points = points
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

  private func buildScene() -> SCNScene {
    let scene = SCNScene()
    scene.background.contents = UIColor(red: 0.15, green: 0.19, blue: 0.20, alpha: 1)
    let root = scene.rootNode
    let size = CGFloat(model.cellSize)

    let stride = 7 * MemoryLayout<Float>.stride
    let count = points.count / stride
    let positions = SCNGeometrySource(data: points, semantic: .vertex, vectorCount: count,
                                      usesFloatComponents: true, componentsPerVector: 3,
                                      bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
    let colors = SCNGeometrySource(data: points, semantic: .color, vectorCount: count,
                                   usesFloatComponents: true, componentsPerVector: 4,
                                   bytesPerComponent: 4, dataOffset: 12, dataStride: stride)
    let indices = (0..<count).map(UInt32.init)
    let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
    let element = SCNGeometryElement(data: indexData, primitiveType: .point,
                                     primitiveCount: count, bytesPerIndex: 4)
    element.pointSize = 0.025
    element.minimumPointScreenSpaceRadius = 1
    element.maximumPointScreenSpaceRadius = 9
    let cloud = SCNGeometry(sources: [positions, colors], elements: [element])
    cloud.firstMaterial?.lightingModel = .constant
    root.addChildNode(SCNNode(geometry: cloud))
    floorCells = model.floor.map { Set($0.map { SIMD2($0[0], $0[1]) }) }

    for (index, object) in model.objects.enumerated() {
      let selected = model.target == index
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
      let a = model.center(from, height: 0.065), b = model.center(to, height: 0.065)
      let segment = SCNBox(width: 0.085, height: 0.018, length: size, chamferRadius: 0.005)
      segment.firstMaterial?.diffuse.contents = UIColor.systemMint
      segment.firstMaterial?.lightingModel = .constant
      let strip = SCNNode(geometry: segment)
      strip.simdPosition = (a + b) / 2
      strip.eulerAngles.y = atan2(b.x - a.x, b.z - a.z)
      root.addChildNode(strip)
    }
    if let last = model.route.last {
      let marker = SCNCylinder(radius: 0.11, height: 0.04)
      marker.firstMaterial?.diffuse.contents = UIColor.systemMint
      marker.firstMaterial?.lightingModel = .constant
      let endpoint = SCNNode(geometry: marker)
      endpoint.simdPosition = model.center(last, height: 0.045)
      root.addChildNode(endpoint)
    }

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
    eye.simdTransform = pose
    let position = pose.columns.3
    let cell = SIMD2(Int(floor(position.x / model.cellSize)), Int(floor(position.z / model.cellSize)))
    let outOfBounds = cell.x < 0 || cell.y < 0 || cell.x >= model.width || cell.y >= model.depth
    if outOfBounds || floorCells?.contains(cell) == false {
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
