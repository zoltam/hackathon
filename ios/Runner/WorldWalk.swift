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
    let syntheticCondition: String?
    let service: [Int]?

    func floorBounds(cellSize: Float) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
      if let bounds, bounds.count == 2, bounds.allSatisfy({ $0.count == 3 }),
         bounds[0][0] <= bounds[1][0], bounds[0][2] <= bounds[1][2] {
        return (SIMD2(bounds[0][0], bounds[0][2]), SIMD2(bounds[1][0], bounds[1][2]))
      }
      let min = SIMD2(Float(x), Float(z)) * cellSize
      let max = SIMD2(Float(x) + Float(width), Float(z) + Float(depth)) * cellSize
      return (min, max)
    }
  }

  let name: String
  let keyControls: Bool
  let obstacleDemo: Bool?
  let moved: Bool?
  let width, depth: Int
  let cellSize: Float
  let originShift: SIMD3<Float>?
  let shRotation: [SIMD3<Float>]?

  var sourceRotation: simd_float3x3 {
    guard let rows = shRotation, rows.count == 3 else { return matrix_identity_float3x3 }
    return simd_float3x3(rows: rows)
  }
  let start: [Int]
  let route: [[Int]]
  let floor: [[Int]]?
  let walkableFloor: [[Int]]?
  let target: Int?
  let objects: [Block]
  let arrivalRadiusMetres: Float?
  let clearanceMetres: Float?
  let inspectionReport: String?

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
  enum VisionMode { case normal, verify, benchmark, journey, obstacle }

  private let model: WalkSite
  private let renderer: SplatRenderer
  private let reality = ARSCNView()
  private var virtual: UIView { renderer.view }
  private let detectionLayer = CAShapeLayer()
  private let message = UILabel()
  private let visionStatus = UILabel()
  private let nearbyStatus = UILabel()
  private let visionMode: VisionMode
  private let detectorURL: URL?
  private var verificationFrames = 0
  private var journeyStart: CFTimeInterval?
  private var journeyConfirmedTarget = false
  var replanRoute: (([String: Any], @escaping (Any?) -> Void) -> Void)?
  private lazy var activeRoute = model.route
  private var obstacleStart: CFTimeInterval?
  private var obstaclePlacedAt: CFTimeInterval?
  private var previousObstacleCenter: SIMD2<Float>?
  private var plannedObstacleCenter: SIMD2<Float>?
  private var obstacleStage = 0
  private var obstacleTestCenter: SIMD2<Float>?
  private var confirmedBlockedCells = Set<[Int]>()
  private var obstacleConfirmed = false
  private var replanPending = false
  private let moveCrate = UIButton(type: .system)
  private static let benchmarkDuration: CFTimeInterval = 15
  private var benchmarkStart: CFTimeInterval?
  private var benchmarkLink: CADisplayLink?
  private var benchmarkLatencies: [Int] = []
  private var benchmarkOverlayAges: [Int] = []
  private var lastDetection: RenderedVision.Frame?
  private var previousDetectionBoxes: [String: CGRect] = [:]
  private var visionIdleText = "Vision · Loading detector"
  private var currentPose: simd_float4x4?
  private let align = UIButton(type: .system)
  private let toggle = UIButton(type: .system)
  private let inspect = UIButton(type: .system)
  private var arrived = false
  private var alignment: WorldAlignment?
  private var showModel = false
  private var started = false
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

  init(model: WalkSite, renderer: SplatRenderer, detectorURL: URL?, visionMode: VisionMode = .normal) {
    self.model = model
    self.renderer = renderer
    self.detectorURL = detectorURL
    self.visionMode = visionMode
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
    floorCells = (model.walkableFloor ?? model.floor).map { Set($0.map { SIMD2($0[0], $0[1]) }) }
    detectionLayer.strokeColor = UIColor.systemYellow.cgColor
    detectionLayer.fillColor = UIColor.clear.cgColor
    detectionLayer.lineWidth = 3
    detectionLayer.lineJoin = .round
    virtual.layer.addSublayer(detectionLayer)

    message.font = .preferredFont(forTextStyle: .callout)
    message.textColor = .white
    message.numberOfLines = 0
    visionStatus.font = .preferredFont(forTextStyle: .caption1)
    visionStatus.textColor = .white
    visionStatus.numberOfLines = 2
    visionStatus.isHidden = true
    renderer.onFrameReady = { [weak self] pose in
      guard let self, self.view.window != nil, !self.virtual.isHidden else { return }
      self.updateDetectionPose(pose)
    }
    nearbyStatus.font = .preferredFont(forTextStyle: .caption1)
    nearbyStatus.textColor = .white
    nearbyStatus.numberOfLines = 4
    nearbyStatus.isHidden = true
    renderer.vision.onPrediction = { [weak self] prediction in
      guard let self else { return }
      if self.visionMode == .benchmark, self.inBenchmarkWindow(CACurrentMediaTime()) {
        self.benchmarkLatencies.append(prediction.inferenceMilliseconds)
      }
      guard self.view.window != nil, !self.virtual.isHidden, let pose = self.currentPose else { return }
      self.observeObstacle(in: prediction)
      guard self.isCurrent(prediction.frame, comparedWith: pose) else {
        self.clearDetections()
        return
      }
      let viewProjection = prediction.frame.projection * prediction.frame.pose.inverse
      let detections = prediction.detections.filter { detection in
        guard let object = self.model.objects.first(where: { $0.objectId == detection.objectID }) else { return false }
        guard let bounds = object.bounds else { return true }
        return RenderedVision.matches(detection, to: bounds, viewProjection: viewProjection)
      }
      self.lastDetection = detections.isEmpty ? nil : prediction.frame
      let confirmedIDs = self.drawDetections(detections)
      if self.visionMode == .benchmark, self.inBenchmarkWindow(CACurrentMediaTime()) {
        self.benchmarkOverlayAges.append(Int((CACurrentMediaTime() - prediction.frame.timestamp) * 1000))
      }
      if self.journeyStart != nil, !self.journeyConfirmedTarget,
         let id = self.serviceTarget?.objectId, confirmedIDs.contains(id) {
        self.journeyConfirmedTarget = true
        print("VALMET_JOURNEY phase=target_confirmed id=\(id)")
        fflush(stdout)
      }
      if self.visionMode == .verify {
        let labels = detections.map { detection in
          let box = detection.bounds
          let details = String(format: "%.3f[%.3f,%.3f,%.3f,%.3f]", detection.confidence,
                               box.minX, box.minY, box.width, box.height)
          return "\(detection.objectID)@\(details)"
        }
        print("VALMET_VISION sample=\(self.verificationFrames) detections=\(labels.isEmpty ? "none" : labels.joined(separator: ",")) ms=\(prediction.inferenceMilliseconds)")
        fflush(stdout)
        self.verificationFrames += 1
      }
      let names = confirmedIDs.sorted().map { id in
        self.model.objects.first { $0.objectId == id }?.name ?? id
      }
      self.visionStatus.text = names.isEmpty ? self.visionIdleText : "Vision · " + names.joined(separator: ", ")
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

    inspect.configuration = .tinted()
    inspect.setTitle("Inspection evidence", for: .normal)
    inspect.addTarget(self, action: #selector(showInspection), for: .touchUpInside)
    moveCrate.configuration = .tinted()
    moveCrate.setTitle("Place demo crate", for: .normal)
    moveCrate.addTarget(self, action: #selector(placeDemoCrate), for: .touchUpInside)
    let row = UIStackView(arrangedSubviews: [toggle, close])
    row.distribution = .fillEqually
    row.spacing = 8
    movementControls = model.keyControls ? makeControls() : nil
    let panel = UIStackView(arrangedSubviews: [message, visionStatus, nearbyStatus, movementControls, align, inspect, moveCrate, row].compactMap { $0 })
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
    guard !started else { return }
    started = true
    if model.keyControls { becomeFirstResponder() }
    renderer.vision.detectsObstacleTag = visionMode == .obstacle || model.obstacleDemo == true
    renderer.vision.loadModel(at: detectorURL) { [weak self] loaded in
      guard let self, self.view.window != nil else { return }
      self.visionIdleText = loaded ? "Vision · No equipment detected" : "Vision · Detector unavailable"
      self.visionStatus.text = self.visionIdleText
      guard self.visionMode != .normal else { return }
      if !loaded {
        self.visionStatus.isHidden = false
        let log = self.visionMode == .obstacle ? "VALMET_OBSTACLE error=detector_unavailable" :
          self.visionMode == .journey ? "VALMET_JOURNEY error=detector_unavailable" :
          self.visionMode == .benchmark ? "VALMET_BENCH error=detector_unavailable" : "VALMET_VISION detector unavailable"
        print(log)
        fflush(stdout)
      } else if self.visionMode == .verify {
        self.verifyRenderedFrame(index: 0)
      } else if self.visionMode == .benchmark {
        self.startBenchmark()
      } else if self.visionMode == .obstacle {
        self.startObstacleCheck()
      } else {
        self.startJourney()
      }
    }
    if visionMode != .normal { return }
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
    visionStatus.isHidden = false
    renderVerificationPose(index: index)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { [weak self] in
      self?.verifyRenderedFrame(index: index + 1)
    }
  }

  private func renderVerificationPose(index: Int) {
    let origin = model.originShift ?? .zero
    let eye = origin + (index == 5 ? SIMD3<Float>(4.625, 1.50, 1.625) :
      SIMD3<Float>(5.385 - Float(index % 3) * 0.08, 1.50, 1.88 + Float(index % 2) * 0.06))
    let look = origin + (index == 2 ? SIMD3<Float>(6.90, 1.15, 2.43) :
      index == 3 ? SIMD3(3.0, 1.15, 1.875) : SIMD3(5.943, 1.164, 2.447))
    renderScriptedView(eye: eye, look: look)
  }

  private func renderScriptedView(eye: SIMD3<Float>, look: SIMD3<Float>) {
    let size = virtual.bounds.size
    guard size.width > 0, size.height > 0 else { return }
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

  private var serviceTarget: WalkSite.Block? {
    guard let target = model.target, model.objects.indices.contains(target) else { return nil }
    return model.objects[target]
  }

  private func startObstacleCheck() {
    guard model.route.count >= 6, model.cellSize > 0, replanRoute != nil else {
      print("VALMET_OBSTACLE result=failed error=missing_route")
      fflush(stdout)
      return
    }
    showModel = true
    let index = min(Int((1.10 / model.cellSize).rounded()), model.route.count - 2)
    let center = model.center(model.route[index])
    obstacleTestCenter = SIMD2(center.x, center.z)
    obstacleStart = CACurrentMediaTime()
    print("VALMET_OBSTACLE phase=initial_route cells=\(model.route.count)")
    fflush(stdout)
    obstacleFrame()
  }

  private func obstacleFrame() {
    guard let start = obstacleStart, let center = obstacleTestCenter else { return }
    let now = CACurrentMediaTime()
    if now - start > 25 || view.window?.windowScene?.activationState != .foregroundActive {
      finishObstacleCheck(error: "timeout_or_inactive")
      return
    }
    if now - start >= 2, renderer.obstacleCenter != center {
      renderer.obstacleCenter = center
      obstaclePlacedAt = now
      previousObstacleCenter = nil
      print("VALMET_OBSTACLE phase=placed stage=\(obstacleStage + 1)")
      fflush(stdout)
    }
    let eye = model.center(model.start, height: assumedPhoneHeight)
    updateWalkStatus(at: SIMD4(eye.x, eye.y, eye.z, 1))
    renderScriptedView(eye: eye, look: SIMD3(center.x, ObstacleTag.height, center.y))
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) { [weak self] in
      self?.obstacleFrame()
    }
  }

  @objc private func placeDemoCrate() {
    guard let pose = currentPose, !replanPending else { return }
    let eye = SIMD2(pose.columns.3.x, pose.columns.3.z)
    let center = model.route.dropFirst().dropLast()
      .map { model.center($0) }
      .map { SIMD2($0.x, $0.z) }
      .filter { point in
        let distance = simd_distance(eye, point)
        return distance >= 0.85 && distance <= 2.0 &&
          (renderer.obstacleCenter.map { simd_distance($0, point) >= 0.35 } ?? true)
      }.min { abs(simd_distance(eye, $0) - 1.10) < abs(simd_distance(eye, $1) - 1.10) }
    guard let center else {
      updateDisplay("Move to a clear view of the planned route before placing the demo crate.")
      return
    }
    renderer.obstacleCenter = center
    obstaclePlacedAt = CACurrentMediaTime()
    previousObstacleCenter = nil
    obstacleConfirmed = false
    moveCrate.setTitle("Move demo crate", for: .normal)
  }

  private func observeObstacle(in prediction: RenderedVision.Prediction) {
    guard (obstacleStart != nil || model.obstacleDemo == true), let replanRoute, !replanPending,
          let placed = obstaclePlacedAt, prediction.frame.timestamp >= placed else { return }
    guard let measured = prediction.obstacleCenter else {
      previousObstacleCenter = nil
      return
    }
    defer { previousObstacleCenter = measured }
    guard let previous = previousObstacleCenter, simd_distance(previous, measured) < 0.08 else { return }
    let center = (previous + measured) / 2
    if let plannedObstacleCenter, simd_distance(plannedObstacleCenter, center) < 0.14 { return }
    plannedObstacleCenter = center
    let halfSide = ObstacleTag.side / 2 + 0.02
    let minCell = cellAt(x: center.x - halfSide, z: center.y - halfSide)
    let maxCell = cellAt(x: center.x + halfSide, z: center.y + halfSide)
    let blocked = (minCell.x...maxCell.x).flatMap { x in (minCell.y...maxCell.y).map { [x, $0] } }
    guard let end = serviceTarget?.service ?? model.route.last, let pose = currentPose else { return }
    let from = cellAt(x: pose.columns.3.x, z: pose.columns.3.z)
    print("VALMET_OBSTACLE phase=confirmed x=\(center.x) z=\(center.y) cells=\(blocked.count)")
    fflush(stdout)
    replanPending = true
    replanRoute(["from": [from.x, from.y], "to": end, "blocked": blocked,
                 "clearanceMetres": model.clearanceMetres ?? 0.1,
                 "moved": model.moved == true]) { [weak self] response in
      guard let self else { return }
      self.replanPending = false
      guard self.view.window != nil, self.obstaclePlacedAt == placed else { return }
      guard let result = response as? [String: Any], let route = result["route"] as? [[Int]],
            let floor = result["walkableFloor"] as? [[Int]] else {
        self.plannedObstacleCenter = nil
        if self.obstacleStart != nil { self.finishObstacleCheck(error: "planner_unavailable") }
        return
      }
      let walkable = Set(floor)
      let previousRouteBlocked = self.activeRoute.contains { !walkable.contains($0) }
      let originalRouteBlocked = self.model.route.contains { !walkable.contains($0) }
      let reopened = self.confirmedBlockedCells.intersection(walkable).count
      self.confirmedBlockedCells = Set(blocked)
      self.floorCells = Set(floor.map { SIMD2($0[0], $0[1]) })
      let remaining = self.activeRoute.dropFirst(self.activeRoute.firstIndex(of: [from.x, from.y]) ?? 0)
      if self.obstacleStart != nil || !remaining.contains([from.x, from.y]) ||
         remaining.contains(where: { !walkable.contains($0) }) {
        self.activeRoute = route
        self.renderer.setRoute(route.map { self.model.center($0) })
      }
      self.obstacleConfirmed = true
      guard self.obstacleStart != nil, let expected = self.obstacleTestCenter else { return }
      let error = simd_distance(center, expected)
      print("VALMET_OBSTACLE phase=replanned cells=\(route.count) previous_route_blocked=\(previousRouteBlocked) original_route_blocked=\(originalRouteBlocked) reopened=\(reopened) error_m=\(error)")
      fflush(stdout)
      guard error < 0.12, previousRouteBlocked, !route.isEmpty,
            self.obstacleStage == 0 || reopened > 0,
            route.first == [from.x, from.y], route.last == end,
            route.allSatisfy(walkable.contains), blocked.allSatisfy({ !walkable.contains($0) }) else {
        self.finishObstacleCheck(error: "unexpected_replan")
        return
      }
      if self.obstacleStage == 0 {
        self.obstacleStage = 1
        let index = min(Int((1.50 / self.model.cellSize).rounded()), route.count - 2)
        let next = self.model.center(route[index])
        self.obstacleTestCenter = SIMD2(next.x, next.z)
      } else {
        self.finishObstacleCheck(error: nil)
      }
    }
  }

  private func finishObstacleCheck(error: String?) {
    obstacleStart = nil
    if let error {
      print("VALMET_OBSTACLE result=failed error=\(error)")
    } else {
      print("VALMET_OBSTACLE result=passed observations=2")
    }
    fflush(stdout)
  }

  private func startJourney() {
    guard let id = serviceTarget?.objectId, model.cellSize > 0, !model.route.isEmpty else {
      print("VALMET_JOURNEY error=invalid_route")
      fflush(stdout)
      return
    }
    showModel = true
    journeyStart = CACurrentMediaTime()
    let distance = Float(model.route.count - 1) * model.cellSize
    print("VALMET_JOURNEY phase=start id=\(id) cells=\(model.route.count) distance_m=\(distance)")
    fflush(stdout)
    journeyFrame()
  }

  private func journeyFrame() {
    guard let start = journeyStart, let target = serviceTarget else { return }
    guard view.window?.windowScene?.activationState == .foregroundActive else {
      stopJourney(error: "scene_inactive")
      return
    }
    let end = Float(model.route.count - 1)
    let speed: Float = 0.15
    let elapsed = Float(CACurrentMediaTime() - start)
    let elapsedWalking = end * model.cellSize / speed
    let step = min(end, elapsed * speed / model.cellSize)
    func point(at step: Float) -> SIMD3<Float> {
      let index = Int(step)
      let a = model.center(model.route[index], height: assumedPhoneHeight)
      let b = model.center(model.route[min(index + 1, model.route.count - 1)], height: assumedPhoneHeight)
      return a + (b - a) * (step - Float(index))
    }
    let eye = point(at: step)
    let bounds = target.floorBounds(cellSize: model.cellSize)
    let targetCenter = (bounds.min + bounds.max) / 2
    let lookAtTarget = SIMD3(targetCenter.x, Float(target.height) * 0.9, targetCenter.y)
    let lookAhead = point(at: min(end, step + 4)) - SIMD3(0, 0.20, 0)
    let remaining = (end - step) * model.cellSize
    let aim = min(1, max(0, (0.9 - remaining) / 0.5))
    let look = lookAhead + (lookAtTarget - lookAhead) * aim

    let hadArrived = arrived
    updateWalkStatus(at: SIMD4(eye.x, eye.y, eye.z, 1))
    renderScriptedView(eye: eye, look: look)
    if arrived && !hadArrived {
      print("VALMET_JOURNEY phase=arrival elapsed_s=\(elapsed)")
      fflush(stdout)
    }
    if elapsed >= elapsedWalking + 4 {
      stopJourney(error: arrived && journeyConfirmedTarget ? nil : "missing_arrival_or_target")
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) { [weak self] in
        self?.journeyFrame()
      }
    }
  }

  private func stopJourney(error: String?) {
    guard let start = journeyStart else { return }
    journeyStart = nil
    let elapsed = CACurrentMediaTime() - start
    if let error {
      print("VALMET_JOURNEY result=failed error=\(error) confirmed=\(journeyConfirmedTarget) arrived=\(arrived) elapsed_s=\(elapsed)")
    } else {
      print("VALMET_JOURNEY result=passed confirmed=true arrived=true elapsed_s=\(elapsed)")
    }
    fflush(stdout)
  }

  private func startBenchmark() {
    guard let scene = view.window?.windowScene, scene.activationState == .foregroundActive else {
      print("VALMET_BENCH error=scene_inactive")
      fflush(stdout)
      return
    }
    virtual.isHidden = false
    visionStatus.isHidden = false
    let start = CACurrentMediaTime()
    benchmarkStart = start
    renderer.frameCounter = SplatRenderer.FrameCounter(window: start..<(start + Self.benchmarkDuration))
    let link = CADisplayLink(target: self, selector: #selector(benchmarkFrame(_:)))
    benchmarkLink = link
    NotificationCenter.default.addObserver(self, selector: #selector(benchmarkSceneDeactivated(_:)),
                                           name: UIScene.willDeactivateNotification, object: scene)
    link.add(to: .main, forMode: .common)
  }

  @objc private func benchmarkSceneDeactivated(_ notification: Notification) {
    abortBenchmark(reason: "scene_inactive")
  }

  private func inBenchmarkWindow(_ time: CFTimeInterval) -> Bool {
    guard let benchmarkStart else { return false }
    return time >= benchmarkStart && time - benchmarkStart < Self.benchmarkDuration
  }

  @objc private func benchmarkFrame(_ link: CADisplayLink) {
    guard let benchmarkStart else { return }
    let elapsed = CACurrentMediaTime() - benchmarkStart
    if elapsed < Self.benchmarkDuration {
      renderVerificationPose(index: Int(elapsed / 0.72) % 12)
      return
    }
    reportBenchmark(frames: stopBenchmarkRendering())
  }

  @discardableResult private func stopBenchmarkRendering() -> Int {
    NotificationCenter.default.removeObserver(self, name: UIScene.willDeactivateNotification, object: nil)
    benchmarkLink?.invalidate()
    benchmarkLink = nil
    let frames = renderer.frameCounter?.count ?? 0
    renderer.frameCounter = nil
    return frames
  }

  private func reportBenchmark(frames: Int) {
    guard benchmarkStart != nil else { return }
    benchmarkStart = nil
    let samples = benchmarkLatencies.sorted()
    func percentile(_ samples: [Int], _ fraction: Double) -> String {
      guard !samples.isEmpty else { return "na" }
      return String(samples[Int(ceil(Double(samples.count) * fraction)) - 1])
    }
    let overlayAges = benchmarkOverlayAges.sorted()
    let elapsed = String(format: "%.3f", Self.benchmarkDuration)
    let fps = String(format: "%.2f", Double(frames) / Self.benchmarkDuration)
    let thermal = ProcessInfo.processInfo.thermalState.rawValue
    print("VALMET_BENCH elapsed_s=\(elapsed) gpu_frames=\(frames) fps=\(fps) inference_samples=\(samples.count) p50_ms=\(percentile(samples, 0.50)) p95_ms=\(percentile(samples, 0.95)) overlay_updates=\(overlayAges.count) overlay_p95_ms=\(percentile(overlayAges, 0.95)) thermal_state=\(thermal)")
    fflush(stdout)
  }

  private func abortBenchmark(reason: String) {
    guard benchmarkStart != nil else { return }
    benchmarkStart = nil
    stopBenchmarkRendering()
    print("VALMET_BENCH error=interrupted reason=\(reason)")
    fflush(stdout)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    abortBenchmark(reason: "view_disappeared")
    stopJourney(error: "view_disappeared")
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
    guard direction != 0,
          isWalkable(cellAt(x: manualPosition.x, z: manualPosition.z)) else { return }
    let back = pose.columns.2
    let heading = SIMD2(-back.x, -back.z)
    guard simd_length(heading) > 0.1 else { return }
    let offset = simd_normalize(heading) * (direction * seconds * 1.2)
    // Check short steps so a tap cannot skip a blocked cell in a fine grid.
    let steps = max(1, Int(ceil(simd_length(offset) / (model.cellSize / 2))))
    let step = offset / Float(steps)
    for _ in 0..<steps {
      let x = manualPosition.x + step.x
      let z = manualPosition.z + step.y
      if isWalkable(cellAt(x: x, z: manualPosition.z)) { manualPosition.x = x }
      if isWalkable(cellAt(x: manualPosition.x, z: z)) { manualPosition.z = z }
    }
  }

  private func cellAt(x: Float, z: Float) -> SIMD2<Int> {
    SIMD2(Int(floor(x / model.cellSize)), Int(floor(z / model.cellSize)))
  }

  private func isWalkable(_ cell: SIMD2<Int>) -> Bool {
    cell.x >= 0 && cell.y >= 0 && cell.x < model.width && cell.y < model.depth &&
      floorCells?.contains(cell) != false
  }

  private func updateNearbyEquipment(at position: SIMD4<Float>) {
    let point = SIMD2(position.x, position.z)
    let radius: Float = 2.5
    let nearby = model.objects.compactMap { object -> (WalkSite.Block, Float)? in
      let bounds = object.floorBounds(cellSize: model.cellSize)
      let nearest = simd_clamp(point, bounds.min, bounds.max)
      let distance = simd_distance_squared(point, nearest)
      return distance <= radius * radius ? (object, distance) : nil
    }.sorted {
      $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1
    }.prefix(3)
    let lines = nearby.map { object, _ in
      let condition = object.syntheticCondition.map { "Synthetic condition: \($0)" } ?? "Condition unavailable"
      return "\(object.name) · \(condition)"
    }
    let text = lines.isEmpty ? nil : (["Nearby equipment"] + lines).joined(separator: "\n")
    if nearbyStatus.text != text { nearbyStatus.text = text }
  }

  private func arrivalText(at position: SIMD4<Float>) -> String? {
    guard let end = activeRoute.last,
          simd_distance(SIMD2(position.x, position.z), SIMD2(model.center(end).x, model.center(end).z))
            <= (model.arrivalRadiusMetres ?? model.cellSize / 2),
          let target = serviceTarget else { return nil }
    return "At service position · \(target.name)"
  }

  private func isCurrent(_ frame: RenderedVision.Frame, comparedWith pose: simd_float4x4) -> Bool {
    // Avoid drawing boxes from an older view after the camera moves.
    CACurrentMediaTime() - frame.timestamp < 0.40 &&
      simd_distance(frame.pose.columns.3, pose.columns.3) <= 0.16 &&
      simd_dot(frame.pose.columns.2, pose.columns.2) >= 0.99 &&
      simd_dot(frame.pose.columns.0, pose.columns.0) >= 0.99
  }

  @discardableResult private func drawDetections(_ detections: [RenderedVision.Detection]) -> [String] {
    let bounds = virtual.bounds
    let path = UIBezierPath()
    // Each catalog ID names one physical object. Keep its strongest observation.
    let current = Dictionary(detections.map { ($0.objectID, $0) }, uniquingKeysWith: {
      $0.confidence >= $1.confidence ? $0 : $1
    }).mapValues { $0.bounds }
    var confirmedIDs: [String] = []
    for (id, rawBox) in current {
      guard let previous = previousDetectionBoxes[id] else { continue }
      let box = CGRect(x: (previous.minX + rawBox.minX) / 2,
                       y: (previous.minY + rawBox.minY) / 2,
                       width: (previous.width + rawBox.width) / 2,
                       height: (previous.height + rawBox.height) / 2)
      confirmedIDs.append(id)
      path.append(UIBezierPath(roundedRect: CGRect(
        x: box.minX * bounds.width, y: (1 - box.maxY) * bounds.height,
        width: box.width * bounds.width, height: box.height * bounds.height
      ), cornerRadius: 6))
    }
    // Average adjacent raw observations, without feeding the result back.
    previousDetectionBoxes = current
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    detectionLayer.frame = bounds
    detectionLayer.path = path.cgPath
    CATransaction.commit()
    return confirmedIDs
  }

  private func clearDetections() {
    if lastDetection != nil { drawDetections([]) }
    lastDetection = nil
    visionStatus.text = visionIdleText
  }

  private func updateDetectionPose(_ pose: simd_float4x4) {
    currentPose = pose
    if let lastDetection, !isCurrent(lastDetection, comparedWith: pose) {
      clearDetections()
    }
  }

  @objc private func calibrate() {
    if alignment != nil {
      arrived = false
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
    }
    updateWalkStatus(at: pose.columns.3)
  }

  private func updateWalkStatus(at position: SIMD4<Float>) {
    if showModel { updateNearbyEquipment(at: position) }
    let cell = cellAt(x: position.x, z: position.z)
    arrived = false
    if !isWalkable(cell) {
      if model.keyControls && cell == SIMD2(model.start[0], model.start[1]) {
        updateDisplay("Start position lacks the selected clearance. Close and reduce the camera radius.")
      } else {
        updateDisplay("Outside the model’s walkable area. Return to the route or show the camera.")
      }
    } else if let arrival = arrivalText(at: position) {
      arrived = true
      updateDisplay(arrival)
    } else {
      let guidance = activeRoute.isEmpty ? "No route to target" : "Follow the green route"
      let obstacleStatus = model.obstacleDemo == true && renderer.obstacleCenter != nil
        ? (obstacleConfirmed ? " · Crate detected" : " · Aim at the tag on the crate")
        : ""
      updateDisplay(model.name + " · " + guidance + obstacleStatus)
    }
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
    let visible = showModel && (visionMode == .journey || visionMode == .obstacle || (ready && alignment != nil))
    virtual.isHidden = !visible
    movementControls?.isHidden = !visible
    inspect.isHidden = !visible || !arrived
    visionStatus.isHidden = !visible
    nearbyStatus.isHidden = !visible || nearbyStatus.text == nil
    moveCrate.isHidden = !visible || model.obstacleDemo != true
    moveCrate.isEnabled = !replanPending

    if !visible {
      buttons.removeAll()
      clearDetections()
      currentPose = nil
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
