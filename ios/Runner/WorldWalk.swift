import ARKit
import AVFoundation
import UIKit
import simd

struct VisionConfirmedIDs {
  var primary = Set<String>()
  var supplemental = Set<String>()
  var visible: [String] { primary.union(supplemental).sorted() }
}

let assumedPhoneHeight: Float = 1.50

struct WalkSite: Decodable {
  struct ExtractionBounds: Decodable {
    let value: [[Float]]?

    init(from decoder: Decoder) {
      value = try? decoder.singleValueContainer().decode([[Float]].self)
    }
  }

  struct Block: Decodable {
    let name: String
    let objectId: String?
    let x, z, width, depth: Int
    let height: CGFloat
    let cells: [[Int]]?
    let bounds: [[Float]]?
    private let extractionBounds: ExtractionBounds?
    let workbookTag: String?
    let equipmentType: String?
    let syntheticCondition: String?
    let service: [Int]?

    private func frameBounds(_ candidate: [[Float]]?) -> [[Float]]? {
      guard let candidate, candidate.count == 2,
            candidate.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
            zip(candidate[0], candidate[1]).allSatisfy({ $0.0 < $0.1 }) else { return nil }
      return candidate
    }

    var nearbyFrameBounds: [[Float]]? { frameBounds(extractionBounds?.value) ?? markerBounds }
    var markerBounds: [[Float]]? { frameBounds(bounds) }

    var displayName: String {
      if equipmentType == "valve_actuator", let workbookTag {
        return "\(name) · synthetic parent \(workbookTag)"
      }
      return workbookTag.map { "\($0) · \(name)" } ?? name
    }

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
  let hasWorkbook: Bool?
  let sourceSha256: String?
  let framesPerSecond: Int?

  var renderFramesPerSecond: Int {
    let fps = framesPerSecond ?? 30
    return [15, 30, 60].contains(fps) ? fps : 30
  }
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
  let eyeHeightMetres: Float?
  let walkingSpeedMetresPerSecond: Float?
  let inspectionReport: String?
  let inspectionSummary: String?

  func center(_ cell: [Int], height: Float = 0) -> SIMD3<Float> {
    SIMD3((Float(cell[0]) + 0.5) * cellSize, height, (Float(cell[1]) + 0.5) * cellSize)
  }

  func cellAt(x: Float, z: Float) -> SIMD2<Int> {
    SIMD2(Int((x / cellSize).rounded(.down)), Int((z / cellSize).rounded(.down)))
  }

  var occupiedFloor: Set<SIMD2<Int>> {
    Set(objects.flatMap { object -> [SIMD2<Int>] in
      if let cells = object.cells {
        return cells.compactMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
      }
      guard object.width > 0, object.depth > 0 else { return [] }
      return (object.x..<(object.x + object.width)).flatMap { x in
        (object.z..<(object.z + object.depth)).map { SIMD2(x, $0) }
      }
    })
  }

  func isClearanceSafePosition(_ position: SIMD2<Float>,
                               observedFloor: Set<SIMD2<Int>>?,
                               occupied: Set<SIMD2<Int>>,
                               additionalBlocked: Set<[Int]> = []) -> Bool {
    let radius = clearanceMetres ?? 0
    let extent = SIMD2(Float(width), Float(depth)) * cellSize
    guard cellSize.isFinite, cellSize > 0, radius.isFinite, radius >= 0,
          position.x >= 0, position.y >= 0,
          position.x < extent.x, position.y < extent.y else { return false }
    func pointWalkable(_ cell: SIMD2<Int>) -> Bool {
      cell.x >= 0 && cell.x < width && cell.y >= 0 && cell.y < depth &&
        observedFloor?.contains(cell) != false && !occupied.contains(cell) && !additionalBlocked.contains([cell.x, cell.y])
    }
    guard pointWalkable(cellAt(x: position.x, z: position.y)) else { return false }
    // Allow tangency despite Float rounding in the renderer's metre coordinates.
    let distance = max(0, radius - 0.000001)
    guard position.x >= distance, position.y >= distance,
          extent.x - position.x >= distance, extent.y - position.y >= distance else { return false }
    if distance == 0 { return true }
    let lower = cellAt(x: position.x - distance, z: position.y - distance)
    let upper = cellAt(x: position.x + distance, z: position.y + distance)
    for x in max(0, lower.x)...min(width - 1, upper.x) {
      for z in max(0, lower.y)...min(depth - 1, upper.y) {
        if pointWalkable(SIMD2(x, z)) { continue }
        let minimum = SIMD2(Float(x), Float(z)) * cellSize
        let nearest = simd_clamp(position, minimum, minimum + cellSize)
        if simd_distance_squared(position, nearest) < distance * distance { return false }
      }
    }
    return true
  }

  static func isClearanceSafeRoute(_ route: [[Int]], to service: [Int], walkableFloor: [[Int]]) -> Bool {
    let walkable = Set(walkableFloor)
    return route.last == service &&
      route.allSatisfy { $0.count == 2 && walkable.contains($0) } &&
      zip(route, route.dropFirst()).allSatisfy { a, b in
        abs(a[0] - b[0]) + abs(a[1] - b[1]) == 1
      }
  }

  func isAtServicePosition(_ position: SIMD2<Float>, on route: [[Int]]) -> Bool {
    guard let end = route.last, cellSize > 0 else { return false }
    let radius = arrivalRadiusMetres ?? max(0.30, cellSize / 2)
    let destination = center(end)
    guard simd_distance(position, SIMD2(destination.x, destination.z)) <= radius else { return false }
    let cell = cellAt(x: position.x, z: position.y)
    return route.suffix(Int(ceil(radius / cellSize)) + 1).contains([cell.x, cell.y])
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

final class RouteMapView: UIControl {
  let model: WalkSite
  let mapImage: UIImage?
  private let expanded: Bool
  private(set) var route: [[Int]]
  // Same orthographic crop/aspect correction as the reviewed 2400 × 2000 room PNG.
  static let imageWorldBounds = CGRect(x: 1.7163, y: 1.5921166667, width: 9.5708, height: 7.9756666667)
  static let imageSourceSha256 = "83d8c7d99316c08c9719cfc2c5a6b9d1903b89847780e2458adc662c79f32955"
  private(set) var pose: simd_float4x4?
  private var baseImage: UIImage?

  init(model: WalkSite, image: UIImage? = nil, expanded: Bool = false) {
    self.model = model
    self.expanded = expanded
    route = model.route
    mapImage = model.sourceSha256 == Self.imageSourceSha256 ? image : nil
    super.init(frame: .zero)
    backgroundColor = UIColor.black.withAlphaComponent(0.85)
    layer.cornerRadius = expanded ? 0 : 6
    clipsToBounds = true
    isAccessibilityElement = true
    accessibilityLabel = "Route map"
    accessibilityIdentifier = "route-map"
    accessibilityTraits = .button
    accessibilityHint = "Opens a larger map"
    setPose(nil)
  }

  required init?(coder: NSCoder) { nil }

  func setRoute(_ route: [[Int]]) {
    self.route = route
    baseImage = nil
    setNeedsDisplay()
  }

  func setPose(_ pose: simd_float4x4?) {
    self.pose = pose
    accessibilityValue = pose.map {
      String(format: "Position %.1f, %.1f metres", $0.columns.3.x, $0.columns.3.z)
    } ?? "Location unavailable"
    setNeedsDisplay()
  }

  func mapPoint(x: Float, z: Float) -> CGPoint {
    let region = worldBounds
    let header: CGFloat = expanded ? 0 : 22
    let footer: CGFloat = 22
    let sideInset: CGFloat = expanded ? 0 : 2
    let contentHeight = bounds.height - header - footer
    let scale = max(0, min((bounds.width - 2 * sideInset) / region.width, contentHeight / region.height))
    return CGPoint(x: (bounds.width - region.width * scale) / 2 + (CGFloat(x) - region.minX) * scale,
                   y: header + (contentHeight - region.height * scale) / 2 + (CGFloat(z) - region.minY) * scale)
  }

  private var worldBounds: CGRect {
    mapImage == nil ? CGRect(x: 0, y: 0, width: CGFloat(model.width) * CGFloat(model.cellSize),
                            height: CGFloat(model.depth) * CGFloat(model.cellSize)) : Self.imageWorldBounds
  }

  private var imageRect: CGRect {
    let region = worldBounds
    let a = mapPoint(x: Float(region.minX), z: Float(region.minY))
    let b = mapPoint(x: Float(region.maxX), z: Float(region.maxY))
    return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    baseImage = nil
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    guard bounds.width > 24, bounds.height > 60 else { return }
    if baseImage == nil {
      baseImage = UIGraphicsImageRenderer(size: bounds.size).image { context in
        context.cgContext.clip(to: imageRect)
        func cells(_ cells: [[Int]], color: UIColor) {
          let path = UIBezierPath()
          for cell in cells {
            let a = mapPoint(x: Float(cell[0]) * model.cellSize, z: Float(cell[1]) * model.cellSize)
            let b = mapPoint(x: Float(cell[0] + 1) * model.cellSize, z: Float(cell[1] + 1) * model.cellSize)
            path.append(UIBezierPath(rect: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)))
          }
          color.setFill()
          path.fill()
        }
        if let mapImage {
          mapImage.draw(in: imageRect)
        } else {
          cells(model.floor ?? model.walkableFloor ?? [], color: UIColor(white: 0.28, alpha: 1))
          cells(model.walkableFloor ?? [], color: UIColor(white: 0.48, alpha: 1))
          for object in model.objects {
            let footprint = object.cells ?? (object.x..<(object.x + object.width)).flatMap { x in
              (object.z..<(object.z + object.depth)).map { [x, $0] }
            }
            cells(footprint, color: .darkGray)
          }
        }
        let routePath = UIBezierPath()
        for (index, cell) in route.enumerated() {
          let center = model.center(cell)
          let point = mapPoint(x: center.x, z: center.z)
          if index == 0 { routePath.move(to: point) } else { routePath.addLine(to: point) }
        }
        UIColor.systemMint.setStroke()
        routePath.lineWidth = 3
        routePath.lineCapStyle = .round
        routePath.lineJoinStyle = .round
        routePath.stroke()
        let start = model.center(model.start)
        let startPoint = mapPoint(x: start.x, z: start.z)
        UIColor.systemBlue.setStroke()
        let ring = UIBezierPath(ovalIn: CGRect(x: startPoint.x - 4, y: startPoint.y - 4, width: 8, height: 8))
        ring.lineWidth = 2
        ring.stroke()
        let destination: SIMD3<Float>?
        if let last = route.last {
          destination = model.center(last)
        } else if let target = model.target, model.objects.indices.contains(target) {
          let object = model.objects[target]
          if let service = object.service, service.count == 2 {
            destination = model.center(service)
          } else {
            destination = SIMD3((Float(object.x) + Float(object.width) / 2) * model.cellSize,
                                0, (Float(object.z) + Float(object.depth) / 2) * model.cellSize)
          }
        } else {
          destination = nil
        }
        if let end = destination {
          let point = mapPoint(x: end.x, z: end.z)
          UIColor.systemYellow.setFill()
          UIBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)).fill()
        }
      }
    }
    baseImage?.draw(in: bounds)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.preferredFont(forTextStyle: .caption1), .foregroundColor: UIColor.white,
    ]
    UIColor.black.setStroke()
    let border = UIBezierPath(rect: imageRect.insetBy(dx: 0.25, dy: 0.25))
    border.lineWidth = 0.5
    border.stroke()
    if !expanded {
      ("Map ↗" as NSString).draw(at: CGPoint(x: 6, y: 3), withAttributes: attributes)
    }
    let outside = pose.map { !worldBounds.contains(CGPoint(x: CGFloat($0.columns.3.x), y: CGFloat($0.columns.3.z))) } ?? false
    let status = pose == nil ? "Location unavailable" : outside ? "Outside map" : route.isEmpty ? "No route" : "You · Route · Target"
    (status as NSString).draw(at: CGPoint(x: 6, y: bounds.height - 19), withAttributes: attributes)
    guard let pose, !outside, let context = UIGraphicsGetCurrentContext() else { return }
    let point = mapPoint(x: pose.columns.3.x, z: pose.columns.3.z)
    context.saveGState()
    context.translateBy(x: point.x, y: point.y)
    context.rotate(by: CGFloat(atan2(-pose.columns.2.x, pose.columns.2.z)))
    let arrow = UIBezierPath()
    arrow.move(to: CGPoint(x: 0, y: -10))
    arrow.addLine(to: CGPoint(x: 7, y: 7))
    arrow.addLine(to: CGPoint(x: 0, y: 4))
    arrow.addLine(to: CGPoint(x: -7, y: 7))
    arrow.close()
    UIColor.systemBlue.setFill()
    UIColor.white.setStroke()
    arrow.lineWidth = 2
    arrow.fill()
    arrow.stroke()
    context.restoreGState()
  }
}

final class WorldWalk: UIViewController, ARSessionDelegate {
  enum VisionMode {
    case normal, preview, verify, benchmark, journey, obstacle

    var isLiveWalk: Bool { self == .normal || self == .preview }

    func acceptsDetection(_ objectID: String, selectedID: String?) -> Bool {
      !isLiveWalk || objectID == selectedID
    }
  }

  struct VerificationPose: Decodable {
    let id: String
    let eye, look: SIMD3<Float>
    let expectedIDs, absentIDs: [String]?

    var isValid: Bool {
      let delta = look - eye
      let horizontal = simd_length_squared(SIMD2(delta.x, delta.z))
      return !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || "-_".contains($0) } &&
        [eye.x, eye.y, eye.z, look.x, look.y, look.z].allSatisfy(\.isFinite) &&
        simd_length_squared(delta).isFinite && horizontal > 0.000001
    }
  }

  private struct VerificationSamples {
    let started = CACurrentMediaTime()
    var count = 0
    var raw = Set<String>()
    var projected = Set<String>()
    var confirmed = Set<String>()
    var supplementalSamples = 0
    var supplementalStale = 0
    var supplementalConfirmed = Set<String>()
    var supplementalSourceSizes = Set<String>()
  }

  private let model: WalkSite
  private let renderer: SplatRenderer
  private let reality = ARSCNView()
  private var virtual: UIView { renderer.view }
  private let detectionLayer = CAShapeLayer()
  private let supplementalLayer = CAShapeLayer()
  private let nearbyFrameLayer = CAShapeLayer()
  private let targetFrameLayer = CAShapeLayer()
  private let serviceMarker = UILabel()
  private var nearbyLabels: [Int: UILabel] = [:]
  private var nearbyLabelSizes: [Int: CGSize] = [:]
  private var nearbyLabelWidth: CGFloat = 0
  private weak var controlPanel: UIStackView?
  private let message = UILabel()
  private let visionStatus = UILabel()
  private let nearbyStatus = UILabel()
  private let visionMode: VisionMode
  private let detectorURL: URL?
  private let mapImage: UIImage?
  private lazy var routeMap = RouteMapView(model: model, image: mapImage)
  private weak var expandedMap: RouteMapView?
  private var panelTrailing: NSLayoutConstraint?
  private let verificationPoses: [VerificationPose]?
  private var verificationSamples: VerificationSamples?
  private var verificationFailures = 0
  private var verificationFrames = 0
  private var journeyStart: CFTimeInterval?
  private var journeyConfirmedTarget = false
  #if targetEnvironment(simulator)
  private var journeyVision = (fresh: 0, stale: 0, qualified: 0, associated: 0, confirmed: 0)
  private var journeyVisionExpiry = (hidden: 0, poseReset: 0)
  private var usesSimulatorJourneyDetector: Bool {
    visionMode == .journey && ProcessInfo.processInfo.arguments.contains("--simulator-rf16-journey")
  }
  #endif
  private var journeyNearbyMax = (frames: 0, mapped: 0)
  var replanRoute: (([String: Any], @escaping (Any?) -> Void) -> Void)?
  private lazy var activeRoute = model.route {
    didSet {
      routeMap.setRoute(activeRoute)
      expandedMap?.setRoute(activeRoute)
    }
  }
  private var obstacleStart: CFTimeInterval?
  private var obstaclePlacedAt: CFTimeInterval?
  private var previousObstacleCenter: SIMD2<Float>?
  private var plannedObstacleCenter: SIMD2<Float>?
  private var obstacleStage = 0
  private var firstObstacleTestCenter: SIMD2<Float>?
  private var obstacleTestCenter: SIMD2<Float>?
  private var confirmedBlockedCells = Set<[Int]>()
  private var obstacleConfirmed = false
  private var replanPending = false
  private var replanAfterRetreat = false
  private let moveCrate = UIButton(type: .system)
  private lazy var benchmarkDuration: CFTimeInterval = {
    let prefix = "--benchmark-seconds="
    let argument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
    let seconds = argument.flatMap { Int($0.dropFirst(prefix.count)) } ?? 15
    return CFTimeInterval(min(180, max(15, seconds)))
  }()
  private var benchmarkStart: CFTimeInterval?
  private var benchmarkWarmupStart: CFTimeInterval?
  private var supplementalWarmupFrames = 0
  private var nextBenchmarkCheckpoint: CFTimeInterval = 15
  private var verificationIdleTimerWasDisabled: Bool?
  private var benchmarkLink: CADisplayLink?
  private var benchmarkLatencies: [Int] = []
  private var supplementalBenchmarkLatencies: [Int] = []
  private var supplementalBenchmarkAges: [Int] = []
  private var supplementalBenchmarkStale = 0
  private var benchmarkOverlayAges: [Int] = []
  private var benchmarkConfirmedFrames = 0
  private var lastDetection: RenderedVision.Frame?
  private var lastSupplementalDetection: RenderedVision.Frame?
  private static let detectionMaxAge: CFTimeInterval = 0.40
  private var supplementalReplacement: (ids: Set<String>, timestamp: CFTimeInterval)?
  private var confirmedVisionIDs = VisionConfirmedIDs()
  private var previousDetectionBoxes: [String: CGRect] = [:]
  private var previousSupplementalBoxes: [String: CGRect] = [:]
  private let supplementalEnabled = !ProcessInfo.processInfo.arguments.contains("--disable-rfdetr-supplemental")
  private var visionIdleText = "Vision · Loading detector"
  private var currentPose: simd_float4x4?
  private let align = UIButton(type: .system)
  private let toggle = UIButton(type: .system)
  private let inspect = UIButton(type: .system)
  private var arrived = false
  private var alignment: WorldAlignment?
  private var showModel = false
  private var started = false
  private var closed = false
  private var ready = false
  private var lastMessage: String?
  private var floorCells: Set<SIMD2<Int>>?
  private lazy var observedFloor = model.floor.map { Set($0.map { SIMD2($0[0], $0[1]) }) }
  private lazy var occupiedFloor = model.occupiedFloor
  private enum Motion: Hashable { case forward, backward }
  private var keys: [UIKeyboardHIDUsage: Motion] = [:]
  private var buttons = Set<Motion>()
  private var movementControls: UIView?
  private var manualPosition = SIMD3<Float>.zero
  private var lastFrame: CFTimeInterval?

  override var canBecomeFirstResponder: Bool { model.keyControls }

  init(model: WalkSite, renderer: SplatRenderer, detectorURL: URL?, visionMode: VisionMode = .normal,
       mapImage: UIImage? = nil, verificationPoses: [VerificationPose]? = nil) {
    self.model = model
    self.renderer = renderer
    self.detectorURL = detectorURL
    self.mapImage = mapImage
    self.visionMode = visionMode
    self.verificationPoses = verificationPoses
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
    nearbyFrameLayer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.58).cgColor
    nearbyFrameLayer.fillColor = UIColor.clear.cgColor
    nearbyFrameLayer.lineWidth = 1.25
    nearbyFrameLayer.lineJoin = .round
    virtual.layer.addSublayer(nearbyFrameLayer)
    targetFrameLayer.strokeColor = UIColor.systemTeal.cgColor
    targetFrameLayer.fillColor = UIColor.clear.cgColor
    targetFrameLayer.lineWidth = 1.75
    targetFrameLayer.lineJoin = .round
    virtual.layer.addSublayer(targetFrameLayer)
    detectionLayer.strokeColor = UIColor.systemYellow.cgColor
    detectionLayer.fillColor = UIColor.clear.cgColor
    detectionLayer.lineWidth = 2
    detectionLayer.lineJoin = .round
    supplementalLayer.strokeColor = detectionLayer.strokeColor
    supplementalLayer.fillColor = detectionLayer.fillColor
    supplementalLayer.lineWidth = detectionLayer.lineWidth
    supplementalLayer.lineJoin = detectionLayer.lineJoin
    virtual.layer.addSublayer(supplementalLayer)
    virtual.layer.addSublayer(detectionLayer)
    serviceMarker.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
    serviceMarker.text = "!"
    serviceMarker.textColor = .systemYellow
    serviceMarker.font = .systemFont(ofSize: 34, weight: .heavy)
    serviceMarker.textAlignment = .center
    serviceMarker.backgroundColor = .black.withAlphaComponent(0.85)
    serviceMarker.layer.cornerRadius = 22
    serviceMarker.layer.masksToBounds = true
    serviceMarker.layer.zPosition = 1
    serviceMarker.accessibilityLabel = "Service target"
    serviceMarker.isHidden = true
    virtual.addSubview(serviceMarker)

    message.font = .preferredFont(forTextStyle: .subheadline)
    message.textColor = .white
    message.numberOfLines = visionMode.isLiveWalk ? 5 : 0
    visionStatus.font = .preferredFont(forTextStyle: .caption1)
    visionStatus.textColor = .white
    visionStatus.numberOfLines = 2
    visionStatus.isHidden = true
    renderer.onFrameReady = { [weak self] pose, projection, size in
      guard let self, self.view.window != nil, !self.virtual.isHidden,
            self.virtual.bounds.size == size else { return }
      self.updateDetectionPose(pose)
      if self.visionMode != .normal { self.updateMap(pose) }
      self.updateNearbyEquipment(at: pose.columns.3, viewProjection: projection * pose.inverse)
    }
    nearbyStatus.font = .preferredFont(forTextStyle: .caption2)
    nearbyStatus.textColor = .white
    nearbyStatus.numberOfLines = 4
    nearbyStatus.isHidden = true
    renderer.vision.onPrediction = { [weak self] prediction in
      guard let self, !self.closed else { return }
      if self.visionMode == .benchmark, self.inBenchmarkWindow(CACurrentMediaTime()) {
        self.benchmarkLatencies.append(prediction.inferenceMilliseconds)
      }
      guard self.view.window != nil, !self.virtual.isHidden, let pose = self.currentPose else { return }
      if self.verificationPoses != nil {
        guard let samples = self.verificationSamples,
              prediction.frame.timestamp >= samples.started else { return }
      }
      self.observeObstacle(in: prediction)
      guard self.isCurrent(prediction.frame, comparedWith: pose) else {
        self.clearDetections()
        return
      }
      // A stalled supplemental stream returns its replacement to R3.
      if let replacement = self.supplementalReplacement,
         CACurrentMediaTime() - replacement.timestamp >= Self.detectionMaxAge {
        self.supplementalReplacement = nil
        self.clearSupplementalDetections()
      }
      let replaced = self.supplementalReplacement?.ids ?? []
      let viewProjection = prediction.frame.projection * prediction.frame.pose.inverse
      var projectedIDs = Set<String>()
      let selectedID = self.serviceTarget?.objectId
      let detections = prediction.detections.filter { detection in
        guard self.visionMode.acceptsDetection(detection.objectID, selectedID: selectedID),
              !replaced.contains(detection.objectID),
              let object = self.model.objects.first(where: { $0.objectId == detection.objectID }) else { return false }
        if let bounds = object.bounds {
          guard RenderedVision.matches(detection, to: bounds, viewProjection: viewProjection) else { return false }
          if self.verificationPoses != nil { projectedIDs.insert(detection.objectID) }
        }
        return true
      }
      let confirmedIDs = self.drawDetections(detections, frame: prediction.frame)
      if self.visionMode == .benchmark, self.inBenchmarkWindow(CACurrentMediaTime()) {
        self.benchmarkOverlayAges.append(Int((CACurrentMediaTime() - prediction.frame.timestamp) * 1000))
        if !confirmedIDs.isEmpty { self.benchmarkConfirmedFrames += 1 }
      }
      self.confirmJourneyTarget(confirmedIDs)
      if self.verificationPoses != nil {
        self.verificationSamples?.count += 1
        self.verificationSamples?.raw.formUnion(prediction.detections.map(\.objectID))
        self.verificationSamples?.projected.formUnion(projectedIDs)
        self.verificationSamples?.confirmed.formUnion(confirmedIDs)
      } else if self.visionMode == .verify {
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
    }
    renderer.vision.onSupplementalStopped = { [weak self] in
      guard let self else { return }
      self.supplementalReplacement = nil
      self.clearSupplementalDetections()
      #if targetEnvironment(simulator)
      if self.usesSimulatorJourneyDetector { self.stopJourney(error: "simulator_rf16_stopped") }
      #endif
      if self.benchmarkWarmupStart != nil { self.abortBenchmark(reason: "supplemental_stopped_during_warmup") }
    }
    renderer.vision.onSupplementalPrediction = { [weak self] prediction, replacements in
      guard let self, !self.closed else { return }
      let benchmarking = self.visionMode == .benchmark && self.inBenchmarkWindow(CACurrentMediaTime())
      if benchmarking {
        self.supplementalBenchmarkLatencies.append(prediction.inferenceMilliseconds)
      }
      guard self.view.window != nil, !self.virtual.isHidden, let pose = self.currentPose else { return }
      if self.verificationPoses != nil {
        guard let samples = self.verificationSamples, prediction.frame.timestamp >= samples.started else { return }
      }
      guard self.isCurrent(prediction.frame, comparedWith: pose) else {
        if benchmarking { self.supplementalBenchmarkStale += 1 }
        #if targetEnvironment(simulator)
        if self.usesSimulatorJourneyDetector, self.journeyStart != nil {
          self.journeyVision.stale += 1
        }
        #endif
        self.verificationSamples?.supplementalStale += 1
        self.clearSupplementalDetections()
        return
      }
      if !replacements.isEmpty {
        self.supplementalReplacement = (replacements, prediction.frame.timestamp)
      }
      if self.benchmarkWarmupStart != nil { self.supplementalWarmupFrames += 1 }
      if benchmarking {
        self.supplementalBenchmarkAges.append(Int((CACurrentMediaTime() - prediction.frame.timestamp) * 1000))
      }
      let viewProjection = prediction.frame.projection * prediction.frame.pose.inverse
      let selectedID = self.serviceTarget?.objectId
      let detections = prediction.detections.filter { detection in
        guard self.visionMode.acceptsDetection(detection.objectID, selectedID: selectedID),
              let object = self.model.objects.first(where: { $0.objectId == detection.objectID }),
              let bounds = object.bounds else { return false }
        return RenderedVision.matches(detection, to: bounds, viewProjection: viewProjection)
      }
      let confirmed = self.drawDetections(detections, frame: prediction.frame, supplemental: true)
      if self.journeyStart != nil, let target = self.serviceTarget?.objectId,
         replacements.contains(target) {
        self.confirmJourneyTarget(confirmed)
      }
      #if targetEnvironment(simulator)
      if self.usesSimulatorJourneyDetector, self.journeyStart != nil {
        // This test stream contains only the selected service target.
        self.journeyVision.fresh += 1
        if !prediction.detections.isEmpty { self.journeyVision.qualified += 1 }
        if !detections.isEmpty { self.journeyVision.associated += 1 }
        if !confirmed.isEmpty { self.journeyVision.confirmed += 1 }
        self.confirmJourneyTarget(confirmed)
      }
      #endif
      self.verificationSamples?.supplementalSamples += 1
      if self.verificationSamples != nil {
        let size = prediction.frame.sourceSize
        self.verificationSamples?.supplementalSourceSizes.insert("\(size.x)x\(size.y)")
      }
      self.verificationSamples?.supplementalConfirmed.formUnion(confirmed)
      if self.verificationPoses != nil, !replacements.isEmpty {
        self.verificationSamples?.raw.formUnion(prediction.detections.map(\.objectID).filter(replacements.contains))
        self.verificationSamples?.projected.formUnion(detections.map(\.objectID).filter(replacements.contains))
        self.verificationSamples?.confirmed.formUnion(confirmed.filter(replacements.contains))
      }
      if self.visionMode == .verify, !confirmed.isEmpty {
        print("VALMET_SUPPLEMENTAL confirmed=\(confirmed.sorted().joined(separator: ","))")
        fflush(stdout)
      }
    }
    align.configuration = .filled()
    align.setTitle("Set start and direction", for: .normal)
    align.addTarget(self, action: #selector(calibrate), for: .touchUpInside)
    align.isHidden = visionMode == .preview
    toggle.configuration = .tinted()
    toggle.setTitle("Show camera", for: .normal)
    toggle.addTarget(self, action: #selector(toggleView), for: .touchUpInside)
    toggle.isHidden = visionMode == .preview
    let close = UIButton(type: .system)
    close.configuration = .tinted()
    close.setTitle("Close", for: .normal)
    close.addTarget(self, action: #selector(closeWalk), for: .touchUpInside)

    var inspectionButton = UIButton.Configuration.filled()
    inspectionButton.title = "Open maintenance report"
    inspectionButton.image = UIImage(systemName: "doc.text")
    inspectionButton.imagePadding = 8
    inspectionButton.buttonSize = .medium
    inspect.configuration = inspectionButton
    inspect.addTarget(self, action: #selector(showInspection), for: .touchUpInside)
    moveCrate.configuration = .tinted()
    moveCrate.setTitle("Place demo crate", for: .normal)
    moveCrate.addTarget(self, action: #selector(placeDemoCrate), for: .touchUpInside)
    let row = UIStackView(arrangedSubviews: [toggle, close])
    row.distribution = .fillEqually
    row.spacing = 6
    movementControls = model.keyControls ? makeControls() : nil
    let panel = UIStackView(arrangedSubviews: [message, inspect, visionStatus, nearbyStatus, movementControls, align, moveCrate, row].compactMap { $0 })
    panel.axis = .vertical
    panel.spacing = 5
    panel.isLayoutMarginsRelativeArrangement = true
    panel.layoutMargins = UIEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
    panel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
    panel.layer.cornerRadius = 12
    panel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(panel)
    controlPanel = panel
    let trailing = panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12)
    panelTrailing = trailing
    NSLayoutConstraint.activate([
      panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      trailing,
      panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])
    routeMap.translatesAutoresizingMaskIntoConstraints = false
    routeMap.addTarget(self, action: #selector(showMap), for: .touchUpInside)
    view.addSubview(routeMap)
    NSLayoutConstraint.activate([
      routeMap.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      routeMap.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      routeMap.widthAnchor.constraint(equalToConstant: 160),
      routeMap.heightAnchor.constraint(equalTo: routeMap.widthAnchor),
    ])
    updateDisplay("Hold the phone steady while tracking starts.")
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    panelTrailing?.constant = view.bounds.width > view.bounds.height ? -184 : -12
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    if model.keyControls { becomeFirstResponder() }
    #if targetEnvironment(simulator)
    if usesSimulatorJourneyDetector {
      startSimulatorJourneyDetector()
      return
    }
    #endif
    if visionMode == .preview { startJourney() }
    renderer.vision.detectsObstacleTag = visionMode == .obstacle || model.obstacleDemo == true
    if visionMode == .normal { startTracking() }
    guard !visionMode.isLiveWalk || serviceTarget?.objectId != nil else { return }
    renderer.vision.loadModel(at: detectorURL) { [weak self] loaded in
      guard let self, !self.closed, self.view.window != nil else { return }
      self.visionIdleText = loaded ? "Vision · No equipment detected" : "Vision · Detector unavailable"
      self.clearDetections()
      if loaded, self.supplementalEnabled {
        if let url = Bundle.main.url(forResource: "RFDETRSupplemental", withExtension: "mlmodelc") {
          let selectedID = self.visionMode.isLiveWalk ? self.serviceTarget?.objectId : nil
          self.renderer.vision.loadSupplementalModel(at: url, limitingTo: selectedID)
        } else {
          NSLog("Supplemental detector resource unavailable")
        }
      }
      guard !self.visionMode.isLiveWalk else { return }
      if !loaded {
        self.visionStatus.isHidden = false
        let log = self.visionMode == .obstacle ? "VALMET_OBSTACLE error=detector_unavailable" :
          self.visionMode == .journey ? "VALMET_JOURNEY error=detector_unavailable" :
          self.visionMode == .benchmark ? "VALMET_BENCH error=detector_unavailable" :
          self.verificationPoses == nil ? "VALMET_VISION detector unavailable" : "VALMET_VISION result=failed error=detector_unavailable"
        print(log)
        fflush(stdout)
      } else if self.visionMode == .verify {
        if self.verificationPoses == nil {
          self.verifyRenderedFrame(index: 0)
        } else {
          self.keepVerificationScreenAwake()
          self.verifyCatalogPose(index: 0)
        }
      } else if self.visionMode == .benchmark {
        self.startBenchmark()
      } else if self.visionMode == .obstacle {
        self.startObstacleCheck()
      } else {
        self.startJourney()
      }
    }
  }

  private func startTracking() {
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
    guard view.window != nil, verificationFrames < 7 else { return }
    guard index < 12 else {
      print("VALMET_VISION error=insufficient_samples samples=\(verificationFrames) expected=7")
      fflush(stdout)
      return
    }
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

  private func verifyCatalogPose(index: Int) {
    guard let poses = verificationPoses, view.window != nil else { return }
    guard view.window?.windowScene?.activationState == .foregroundActive else {
      verificationSamples = nil
      restoreVerificationIdleTimer()
      print("VALMET_VISION result=failed error=inactive")
      fflush(stdout)
      return
    }
    guard poses.indices.contains(index) else {
      restoreVerificationIdleTimer()
      print("VALMET_VISION result=\(verificationFailures == 0 ? "passed" : "failed") poses=\(poses.count) failures=\(verificationFailures)")
      fflush(stdout)
      return
    }
    let pose = poses[index]
    if let samples = verificationSamples {
      let elapsed = CACurrentMediaTime() - samples.started
      if elapsed >= 3 || (elapsed >= 1 && samples.count >= 2) {
        let missing = Set(pose.expectedIDs ?? []).subtracting(samples.confirmed)
        let unexpected = Set(pose.absentIDs ?? []).intersection(samples.confirmed)
        let passed = samples.count >= 2 && missing.isEmpty && unexpected.isEmpty
        if !passed { verificationFailures += 1 }
        func list(_ ids: Set<String>) -> String { ids.isEmpty ? "none" : ids.sorted().joined(separator: ",") }
        let tags = model.objects.compactMap { object -> String? in
          guard let id = object.objectId, samples.confirmed.contains(id), let tag = object.workbookTag else { return nil }
          return "\(id)@\(tag)"
        }
        print("VALMET_VISION pose=\(pose.id) samples=\(samples.count) raw=\(list(samples.raw)) projected=\(list(samples.projected)) confirmed=\(list(samples.confirmed)) workbook=\(model.hasWorkbook == true) tags=\(list(Set(tags))) missing=\(list(missing)) unexpected=\(list(unexpected)) status=\(passed ? "passed" : "failed")")
        print("VALMET_SUPPLEMENTAL pose=\(pose.id) samples=\(samples.supplementalSamples) stale=\(samples.supplementalStale) confirmed=\(list(samples.supplementalConfirmed)) source=\(list(samples.supplementalSourceSizes))")
        fflush(stdout)
        verificationSamples = nil
        verifyCatalogPose(index: index + 1)
        return
      }
    } else {
      clearDetections()
      clearSupplementalDetections()
      verificationSamples = VerificationSamples()
      virtual.isHidden = false
      visionStatus.isHidden = false
    }
    renderScriptedView(eye: pose.eye, look: pose.look)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) { [weak self] in
      self?.verifyCatalogPose(index: index)
    }
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
    firstObstacleTestCenter = obstacleTestCenter
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
    let eye = obstacleStage == 2
      ? SIMD3(center.x - 0.12, assumedPhoneHeight, center.y)
      : model.center(model.start, height: assumedPhoneHeight)
    updateWalkStatus(at: SIMD4(eye.x, eye.y, eye.z, 1))
    renderScriptedView(eye: eye, look: SIMD3(center.x, ObstacleTag.height, center.y))
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) { [weak self] in
      self?.obstacleFrame()
    }
  }

  @objc private func placeDemoCrate() {
    guard let pose = currentPose, !replanPending else { return }
    let eye = SIMD2(pose.columns.3.x, pose.columns.3.z)
    let start = model.center(model.start)
    let center = model.route.dropFirst().dropLast()
      .map { model.center($0) }
      .map { SIMD2($0.x, $0.z) }
      .filter { point in
        let distance = simd_distance(eye, point)
        return distance >= 0.85 && distance <= 2.0 &&
          simd_distance(SIMD2(start.x, start.z), point) >= 0.85 &&
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
    replanAfterRetreat = false
    moveCrate.setTitle("Move demo crate", for: .normal)
  }

  private func observeObstacle(in prediction: RenderedVision.Prediction) {
    guard (obstacleStart != nil || model.obstacleDemo == true), !replanPending,
          let placed = obstaclePlacedAt, prediction.frame.timestamp >= placed else { return }
    guard let measured = prediction.obstacleCenter else {
      previousObstacleCenter = nil
      return
    }
    defer { previousObstacleCenter = measured }
    guard let previous = previousObstacleCenter, simd_distance(previous, measured) < 0.08 else { return }
    let center = (previous + measured) / 2
    if let plannedObstacleCenter, simd_distance(plannedObstacleCenter, center) < 0.14 { return }
    guard let pose = currentPose else { return }
    let from = cellAt(x: pose.columns.3.x, z: pose.columns.3.z)
    replanAroundCrate(at: center, from: from, placed: placed)
  }

  private func replanAroundCrate(at center: SIMD2<Float>, from: SIMD2<Int>, placed: CFTimeInterval) {
    guard let replanRoute, let end = serviceTarget?.service ?? model.route.last else { return }
    plannedObstacleCenter = center
    let halfSide = ObstacleTag.side / 2 + 0.02
    let minCell = cellAt(x: center.x - halfSide, z: center.y - halfSide)
    let maxCell = cellAt(x: center.x + halfSide, z: center.y + halfSide)
    let blocked = (minCell.x...maxCell.x).flatMap { x in (minCell.y...maxCell.y).map { [x, $0] } }
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
      let sameFootprint = self.confirmedBlockedCells == Set(blocked)
      self.confirmedBlockedCells = Set(blocked)
      self.floorCells = Set(floor.map { SIMD2($0[0], $0[1]) })
      self.replanAfterRetreat = !self.isWalkable(from)
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
      if self.obstacleStage == 2 {
        guard error < 0.12, self.replanAfterRetreat, self.activeRoute.isEmpty, route.isEmpty else {
          self.finishObstacleCheck(error: "expected_blocked_camera")
          return
        }
        self.obstacleStage = 3
        return
      }
      let expectedChange = self.obstacleStage == 3
        ? sameFootprint && [from.x, from.y] == self.model.start
        : previousRouteBlocked
      guard error < 0.12, expectedChange, !route.isEmpty,
            self.obstacleStage != 1 || reopened > 0,
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
      } else if self.obstacleStage == 1 {
        self.obstacleStage = 2
        self.obstacleTestCenter = self.firstObstacleTestCenter
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
      print("VALMET_OBSTACLE result=passed observations=3 recovered=true")
    }
    fflush(stdout)
  }

  #if targetEnvironment(simulator)
  private func startSimulatorJourneyDetector() {
    print("VALMET_JOURNEY vision_source=simulator-rf16")
    fflush(stdout)
    guard supplementalEnabled, let target = serviceTarget?.objectId,
          let url = Bundle.main.url(forResource: "RFDETRSupplemental", withExtension: "mlmodelc") else {
      print("VALMET_JOURNEY result=failed error=simulator_rf16_unavailable")
      fflush(stdout)
      return
    }
    renderer.vision.simulatorJourneyTarget = target
    renderer.vision.loadSupplementalModel(at: url) { [weak self] loaded in
      guard let self, !self.closed, self.view.window != nil else { return }
      guard loaded else {
        print("VALMET_JOURNEY result=failed error=simulator_rf16_unavailable")
        fflush(stdout)
        return
      }
      self.visionIdleText = "Vision · No equipment detected"
      self.clearDetections()
      self.startJourney()
    }
  }
  #endif

  private func confirmJourneyTarget(_ confirmedIDs: [String]) {
    guard journeyStart != nil, !journeyConfirmedTarget,
          let id = serviceTarget?.objectId, confirmedIDs.contains(id) else { return }
    journeyConfirmedTarget = true
    print("VALMET_JOURNEY phase=target_confirmed id=\(id)")
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
    keepVerificationScreenAwake()
    let distance = Float(model.route.count - 1) * model.cellSize
    print("VALMET_JOURNEY phase=start id=\(id) cells=\(model.route.count) distance_m=\(distance)")
    fflush(stdout)
    journeyFrame()
  }

  private var hasJourneyWorkbookEvidence: Bool {
    model.inspectionSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }

  private func journeyFrame() {
    guard let start = journeyStart, let target = serviceTarget else { return }
    guard view.window?.windowScene?.activationState == .foregroundActive else {
      stopJourney(error: "scene_inactive")
      return
    }
    let end = Float(model.route.count - 1)
    let speed: Float = visionMode == .preview ? model.walkingSpeedMetresPerSecond ?? 0.45 : 0.15
    let eyeHeight = model.eyeHeightMetres ?? assumedPhoneHeight
    let elapsed = Float(CACurrentMediaTime() - start)
    let elapsedWalking = end * model.cellSize / speed
    let step = min(end, elapsed * speed / model.cellSize)
    func point(at step: Float) -> SIMD3<Float> {
      let index = Int(step)
      let a = model.center(model.route[index], height: eyeHeight)
      let b = model.center(model.route[min(index + 1, model.route.count - 1)], height: eyeHeight)
      return a + (b - a) * (step - Float(index))
    }
    let eye = point(at: step)
    if model.walkingSpeedMetresPerSecond != nil, !isWalkablePosition(x: eye.x, z: eye.z) {
      updateWalkStatus(at: SIMD4(eye.x, eye.y, eye.z, 1))
      stopJourney(error: "unsafe_position")
      return
    }
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
      print("VALMET_JOURNEY evidence=\(hasJourneyWorkbookEvidence ? "workbook" : "unavailable") tag=\(target.workbookTag ?? "unavailable")")
      fflush(stdout)
    }
    if elapsed >= elapsedWalking + 4 {
      if visionMode == .preview {
        stopJourney(error: nil)
        return
      }
      let error: String?
      if !arrived || !journeyConfirmedTarget {
        error = "missing_arrival_or_target"
      } else if !hasJourneyWorkbookEvidence {
        error = "missing_workbook_evidence"
      } else if journeyNearbyMax.mapped == 0 {
        error = "missing_mapped_nearby_frames"
      } else {
        error = nil
      }
      stopJourney(error: error)
    } else {
      let fps = visionMode == .preview ? model.renderFramesPerSecond : 30
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / Double(fps)) { [weak self] in
        self?.journeyFrame()
      }
    }
  }

  private func stopJourney(error: String?) {
    guard let start = journeyStart else { return }
    journeyStart = nil
    restoreVerificationIdleTimer()
    if visionMode == .preview {
      #if targetEnvironment(simulator)
      if ProcessInfo.processInfo.arguments.contains("--verify-person-service") {
        let hasReport = model.inspectionReport?.isEmpty == false && hasJourneyWorkbookEvidence
        let tag = serviceTarget?.workbookTag ?? "unavailable"
        if error == nil && arrived && hasReport { showInspection() }
        let reportOpened = (presentedViewController as? UINavigationController)?.topViewController?.title == "Inspection evidence"
        let result = error == nil && arrived && hasReport && reportOpened ? "passed" : "failed"
        print("VALMET_PERSON result=\(result) arrived=\(arrived) report=\(hasReport) opened=\(reportOpened) tag=\(tag) error=\(error ?? "none")")
        fflush(stdout)
      }
      #endif
      return
    }
    let elapsed = CACurrentMediaTime() - start
    #if targetEnvironment(simulator)
    if usesSimulatorJourneyDetector {
      print("VALMET_JOURNEY rf16_frames fresh=\(journeyVision.fresh) stale=\(journeyVision.stale) " +
            "qualified=\(journeyVision.qualified) associated=\(journeyVision.associated) confirmed=\(journeyVision.confirmed) " +
            "overlay_hides_age=\(journeyVisionExpiry.hidden) history_clears_pose=\(journeyVisionExpiry.poseReset)")
    }
    #endif
    print("VALMET_JOURNEY nearby_frames_max=\(journeyNearbyMax.frames) mapped_nearby_frames_max=\(journeyNearbyMax.mapped)")
    let arrivalWorkbook = arrived && hasJourneyWorkbookEvidence
    let tag = arrivalWorkbook ? (serviceTarget?.workbookTag ?? "unavailable") : "unavailable"
    print("VALMET_JOURNEY checks arrived=\(arrived) vision_confirmed=\(journeyConfirmedTarget) " +
          "arrival_workbook=\(arrivalWorkbook) workbook_tag=\(tag) mapped_nearby=\(journeyNearbyMax.mapped > 0)")
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
    keepVerificationScreenAwake()
    if supplementalEnabled {
      benchmarkWarmupStart = start
      supplementalWarmupFrames = 0
      print("VALMET_SUPPLEMENTAL_BENCH phase=warmup timeout_s=30")
      fflush(stdout)
    } else {
      beginBenchmarkWindow(at: start)
    }
    let link = CADisplayLink(target: self, selector: #selector(benchmarkFrame(_:)))
    benchmarkLink = link
    NotificationCenter.default.addObserver(self, selector: #selector(benchmarkSceneDeactivated(_:)),
                                           name: UIScene.willDeactivateNotification, object: scene)
    link.add(to: .main, forMode: .common)
  }

  private func beginBenchmarkWindow(at start: CFTimeInterval) {
    benchmarkWarmupStart = nil
    benchmarkStart = start
    renderer.frameCounter = SplatRenderer.FrameCounter(window: start..<(start + benchmarkDuration))
  }

  @objc private func benchmarkSceneDeactivated(_ notification: Notification) {
    abortBenchmark(reason: "scene_inactive")
  }

  private func inBenchmarkWindow(_ time: CFTimeInterval) -> Bool {
    guard let benchmarkStart else { return false }
    return time >= benchmarkStart && time - benchmarkStart < benchmarkDuration
  }

  @objc private func benchmarkFrame(_ link: CADisplayLink) {
    if let warmup = benchmarkWarmupStart {
      let elapsed = CACurrentMediaTime() - warmup
      guard elapsed < 30 else {
        abortBenchmark(reason: "supplemental_warmup_timeout")
        return
      }
      if supplementalWarmupFrames >= 3, elapsed >= 2 {
        print("VALMET_SUPPLEMENTAL_BENCH phase=ready warmup_s=\(elapsed) current_frames=\(supplementalWarmupFrames)")
        fflush(stdout)
        beginBenchmarkWindow(at: CACurrentMediaTime())
      } else {
        renderVerificationPose(index: Int(elapsed / 0.72) % 12)
        return
      }
    }
    guard let benchmarkStart else { return }
    let elapsed = CACurrentMediaTime() - benchmarkStart
    if elapsed < benchmarkDuration {
      if elapsed >= nextBenchmarkCheckpoint {
        reportBenchmark(frames: renderer.frameCounter?.count ?? 0, elapsed: elapsed, checkpoint: true)
        nextBenchmarkCheckpoint += 15
      }
      renderVerificationPose(index: Int(elapsed / 0.72) % 12)
      return
    }
    self.benchmarkStart = nil
    reportBenchmark(frames: stopBenchmarkRendering(), elapsed: benchmarkDuration)
  }

  @discardableResult private func stopBenchmarkRendering() -> Int {
    NotificationCenter.default.removeObserver(self, name: UIScene.willDeactivateNotification, object: nil)
    benchmarkLink?.invalidate()
    benchmarkLink = nil
    restoreVerificationIdleTimer()
    let frames = renderer.frameCounter?.count ?? 0
    renderer.frameCounter = nil
    return frames
  }

  private func keepVerificationScreenAwake() {
    verificationIdleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
  }

  private func restoreVerificationIdleTimer() {
    guard let previous = verificationIdleTimerWasDisabled else { return }
    UIApplication.shared.isIdleTimerDisabled = previous
    verificationIdleTimerWasDisabled = nil
  }

  private func reportBenchmark(frames: Int, elapsed: CFTimeInterval, checkpoint: Bool = false) {
    let samples = benchmarkLatencies.sorted()
    func percentile(_ samples: [Int], _ fraction: Double) -> String {
      guard !samples.isEmpty else { return "na" }
      return String(samples[Int(ceil(Double(samples.count) * fraction)) - 1])
    }
    let overlayAges = benchmarkOverlayAges.sorted()
    let seconds = String(format: "%.3f", elapsed)
    let fps = String(format: "%.2f", Double(frames) / elapsed)
    let thermal = ProcessInfo.processInfo.thermalState.rawValue
    let timeField = checkpoint ? "checkpoint_s" : "elapsed_s"
    print("VALMET_BENCH \(timeField)=\(seconds) gpu_frames=\(frames) fps=\(fps) inference_samples=\(samples.count) p50_ms=\(percentile(samples, 0.50)) p95_ms=\(percentile(samples, 0.95)) overlay_updates=\(overlayAges.count) confirmed_frames=\(benchmarkConfirmedFrames) overlay_p95_ms=\(percentile(overlayAges, 0.95)) thermal_state=\(thermal)")
    if supplementalEnabled {
      let supplemental = supplementalBenchmarkLatencies.sorted()
      let ages = supplementalBenchmarkAges.sorted()
      let hz = String(format: "%.2f", Double(supplemental.count) / elapsed)
      print("VALMET_SUPPLEMENTAL_BENCH \(timeField)=\(seconds) target_hz=8 inference_samples=\(supplemental.count) inference_hz=\(hz) p50_ms=\(percentile(supplemental, 0.50)) p95_ms=\(percentile(supplemental, 0.95)) current_frames=\(ages.count) stale_frames=\(supplementalBenchmarkStale) frame_age_p95_ms=\(percentile(ages, 0.95))")
    }
    fflush(stdout)
  }

  private func abortBenchmark(reason: String) {
    guard benchmarkStart != nil || benchmarkWarmupStart != nil else { return }
    benchmarkStart = nil
    benchmarkWarmupStart = nil
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
          isWalkablePosition(x: manualPosition.x, z: manualPosition.z) else { return }
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
      if isWalkablePosition(x: x, z: manualPosition.z) { manualPosition.x = x }
      if isWalkablePosition(x: manualPosition.x, z: z) { manualPosition.z = z }
    }
  }

  private func cellAt(x: Float, z: Float) -> SIMD2<Int> {
    model.cellAt(x: x, z: z)
  }

  private func isWalkable(_ cell: SIMD2<Int>) -> Bool {
    cell.x >= 0 && cell.y >= 0 && cell.x < model.width && cell.y < model.depth &&
      floorCells?.contains(cell) != false
  }

  private func isWalkablePosition(x: Float, z: Float) -> Bool {
    model.isClearanceSafePosition(SIMD2(x, z), observedFloor: observedFloor,
                                  occupied: occupiedFloor, additionalBlocked: confirmedBlockedCells) &&
      isWalkable(cellAt(x: x, z: z))
  }

  private func updateNearbyEquipment(at position: SIMD4<Float>, viewProjection: simd_float4x4) {
    let point = SIMD2(position.x, position.z)
    let radius: Float = 2.5
    let nearby = model.objects.indices.compactMap { index -> (index: Int, distance: Float)? in
      let bounds = model.objects[index].floorBounds(cellSize: model.cellSize)
      let distance = simd_distance_squared(point, simd_clamp(point, bounds.min, bounds.max))
      return distance <= radius * radius ? (index, distance) : nil
    }.sorted { $0.distance == $1.distance ? $0.index < $1.index : $0.distance < $1.distance }
    let lines = nearby.prefix(3).map { entry in
      let object = model.objects[entry.index]
      return "\(object.displayName) · \(conditionText(for: object))"
    }
    let text = lines.isEmpty ? nil : (["Nearby equipment"] + lines).joined(separator: "\n")
    if nearbyStatus.text != text { nearbyStatus.text = text }
    nearbyStatus.isHidden = text == nil

    let viewport = virtual.bounds
    var labelArea = viewport.insetBy(dx: 6, dy: 6)
    if let panel = controlPanel {
      labelArea.size.height = max(0, min(labelArea.maxY, virtual.convert(panel.bounds, from: panel).minY - 6) - labelArea.minY)
    }
    let frames = UIBezierPath()
    let targetFrame = UIBezierPath()
    let labelWidth = labelArea.width * 0.65
    if nearbyLabelWidth != labelWidth {
      nearbyLabelWidth = labelWidth
      nearbyLabelSizes.removeAll(keepingCapacity: true)
    }
    var placedLabels: [CGRect] = []
    var visibleLabels = Set<Int>()
    var markerPosition: CGPoint?
    var frameCount = 0
    var mappedFrameCount = 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for entry in nearby {
      let object = model.objects[entry.index]
      if entry.index == model.target, let marker = object.markerBounds {
        let top = viewProjection * SIMD4((marker[0][0] + marker[1][0]) / 2, marker[1][1],
                                         (marker[0][2] + marker[1][2]) / 2, 1)
        markerPosition = Self.serviceMarkerPosition(top, viewport: viewport, availableArea: labelArea)
      }
      guard let bounds = object.nearbyFrameBounds else { continue }
      let corners = (0..<8).map { index in
        viewProjection * SIMD4(bounds[index & 1][0], bounds[(index >> 1) & 1][1],
                               bounds[(index >> 2) & 1][2], 1)
      }
      let frame = UIBezierPath()
      for corner in corners.indices {
        for axis in [1, 2, 4] where corner & axis == 0 {
          if let (a, b) = Self.clipEdge(corners[corner], corners[corner | axis], to: viewport) {
            frame.move(to: a)
            frame.addLine(to: b)
          }
        }
      }
      guard !frame.isEmpty else { continue }
      let path = entry.index == model.target ? targetFrame : frames
      path.append(frame)
      frameCount += 1
      if object.syntheticCondition != nil { mappedFrameCount += 1 }
      let label = nearbyLabel(at: entry.index, text: object.displayName + "\n" + conditionText(for: object))
      let projected = frame.bounds
      let size = nearbyLabelSizes[entry.index] ??
        label.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude))
      nearbyLabelSizes[entry.index] = size
      let width = min(labelArea.width, ceil(size.width) + 12)
      let height = ceil(size.height) + 6
      guard width > 0, labelArea.height >= height else { continue }
      let x = min(max(projected.minX, labelArea.minX), labelArea.maxX - width)
      let base = min(max(projected.minY - height - 4, labelArea.minY), labelArea.maxY - height)
      for offset in [0, 1, -1, 2, -2, 3, -3] {
        let y = base + CGFloat(offset) * (height + 3)
        let candidate = CGRect(x: x, y: y, width: width, height: height)
        guard labelArea.contains(candidate),
              !placedLabels.contains(where: { $0.insetBy(dx: -3, dy: -2).intersects(candidate) })
        else { continue }
        label.frame = candidate
        label.isHidden = false
        placedLabels.append(candidate)
        visibleLabels.insert(entry.index)
        let anchor = CGPoint(x: projected.minX, y: projected.minY)
        path.move(to: anchor)
        path.addLine(to: CGPoint(x: min(max(anchor.x, candidate.minX), candidate.maxX),
                                   y: min(max(anchor.y, candidate.minY), candidate.maxY)))
        break
      }
    }
    for (index, label) in nearbyLabels where !visibleLabels.contains(index) { label.isHidden = true }
    nearbyFrameLayer.frame = viewport
    nearbyFrameLayer.path = frames.cgPath
    targetFrameLayer.frame = viewport
    targetFrameLayer.path = targetFrame.cgPath
    CATransaction.commit()
    updateServiceMarker(at: markerPosition)
    if journeyStart != nil {
      journeyNearbyMax.frames = max(journeyNearbyMax.frames, frameCount)
      journeyNearbyMax.mapped = max(journeyNearbyMax.mapped, mappedFrameCount)
    }
  }

  private func updateServiceMarker(at position: CGPoint?) {
    serviceMarker.isHidden = position == nil
    if let position { serviceMarker.center = position }
    let key = "service-bob"
    guard position != nil, !UIAccessibility.isReduceMotionEnabled else {
      serviceMarker.layer.removeAnimation(forKey: key)
      return
    }
    guard serviceMarker.layer.animation(forKey: key) == nil else { return }
    let bob = CABasicAnimation(keyPath: "transform.translation.y")
    bob.toValue = -6
    bob.duration = 0.6
    bob.autoreverses = true
    bob.repeatCount = .infinity
    bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    serviceMarker.layer.add(bob, forKey: key)
  }

  static func serviceMarkerPosition(_ top: SIMD4<Float>, viewport: CGRect, availableArea: CGRect) -> CGPoint? {
    guard top.w > 0, top.z >= 0, top.z <= top.w, abs(top.x) <= top.w, abs(top.y) <= top.w,
          availableArea.width >= 44, availableArea.height >= 56 else { return nil }
    let x = viewport.midX + CGFloat(top.x / top.w) * viewport.width / 2
    let y = viewport.midY - CGFloat(top.y / top.w) * viewport.height / 2 - 25
    return CGPoint(x: min(max(x, availableArea.minX + 22), availableArea.maxX - 22),
                   y: min(max(y, availableArea.minY + 28), availableArea.maxY - 28))
  }

  private func conditionText(for object: WalkSite.Block) -> String {
    object.syntheticCondition.map { "Synthetic: \($0)" } ?? "Condition unavailable"
  }

  private func nearbyLabel(at index: Int, text: String) -> UILabel {
    if let label = nearbyLabels[index] { return label }
    let label = UILabel()
    let font = UIFont.preferredFont(forTextStyle: .caption2)
    let isTarget = index == model.target
    label.font = isTarget ? font : font.withSize(font.pointSize * 0.9)
    label.textColor = .white
    label.textAlignment = .center
    label.numberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    if isTarget {
      label.backgroundColor = UIColor.black.withAlphaComponent(0.85)
      label.layer.borderColor = targetFrameLayer.strokeColor
      label.layer.borderWidth = 1
      label.layer.cornerRadius = 4
      label.layer.masksToBounds = true
      label.text = text
    } else {
      label.attributedText = NSAttributedString(string: text, attributes: [
        .font: label.font!,
        .foregroundColor: UIColor.white,
        .strokeColor: UIColor.black,
        .strokeWidth: -4,
      ])
    }
    label.isHidden = true
    virtual.addSubview(label)
    nearbyLabels[index] = label
    return label
  }

  private static func clipEdge(_ a: SIMD4<Float>, _ b: SIMD4<Float>, to viewport: CGRect) -> (CGPoint, CGPoint)? {
    // Clip in homogeneous coordinates before dividing by w. Metal's depth is 0...w.
    let aPlanes = [a.w + a.x, a.w - a.x, a.w + a.y, a.w - a.y, a.z, a.w - a.z]
    let bPlanes = [b.w + b.x, b.w - b.x, b.w + b.y, b.w - b.y, b.z, b.w - b.z]
    var first: Float = 0
    var last: Float = 1
    for (from, to) in zip(aPlanes, bPlanes) {
      guard from.isFinite, to.isFinite, from >= 0 || to >= 0 else { return nil }
      if from < 0 { first = max(first, from / (from - to)) }
      if to < 0 { last = min(last, from / (from - to)) }
    }
    guard first < last else { return nil }
    let start = a + (b - a) * first
    let end = a + (b - a) * last
    guard start.w > 0, end.w > 0 else { return nil }
    func project(_ point: SIMD4<Float>) -> CGPoint {
      let x = CGFloat(point.x / point.w + 1) / 2
      let y = CGFloat(1 - point.y / point.w) / 2
      return CGPoint(x: viewport.minX + x * viewport.width, y: viewport.minY + y * viewport.height)
    }
    return (project(start), project(end))
  }

  private func arrivalText(at position: SIMD4<Float>) -> String? {
    guard model.isAtServicePosition(SIMD2(position.x, position.z), on: activeRoute),
          let target = serviceTarget else { return nil }
    return "At service position · \(target.displayName)"
  }

  private func isCurrent(_ frame: RenderedVision.Frame, comparedWith pose: simd_float4x4) -> Bool {
    // Avoid drawing boxes from an older view after the camera moves.
    CACurrentMediaTime() - frame.timestamp < Self.detectionMaxAge && frame.matchesPose(pose)
  }

  @discardableResult private func drawDetections(_ detections: [RenderedVision.Detection],
                                                  frame: RenderedVision.Frame? = nil,
                                                  supplemental: Bool = false) -> [String] {
    let bounds = virtual.bounds
    let path = UIBezierPath()
    let current = RenderedVision.strongestDetections(detections, supplemental: supplemental)
      .mapValues(\.bounds)
    let previousFrame = supplemental ? lastSupplementalDetection : lastDetection
    let previousBoxes: [String: CGRect]
    if let frame, let previousFrame, frame.follows(previousFrame, within: Self.detectionMaxAge) {
      previousBoxes = supplemental ? previousSupplementalBoxes : previousDetectionBoxes
    } else {
      previousBoxes = [:]
    }
    var confirmedIDs: [String] = []
    for (id, rawBox) in current {
      // Retain RF history while the last R3 box is still visible.
      if supplemental, confirmedVisionIDs.primary.contains(id) { continue }
      guard let previous = previousBoxes[id] else { continue }
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
    if supplemental {
      previousSupplementalBoxes = current
      lastSupplementalDetection = current.isEmpty ? nil : frame
    } else {
      previousDetectionBoxes = current
      lastDetection = current.isEmpty ? nil : frame
    }
    setDetectionOverlay(path: path.isEmpty ? nil : path.cgPath,
                        confirmed: Set(confirmedIDs), supplemental: supplemental)
    return confirmedIDs
  }

  private func setDetectionOverlay(path: CGPath?, confirmed: Set<String>, supplemental: Bool) {
    let layer = supplemental ? supplementalLayer : detectionLayer
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.frame = virtual.bounds
    layer.path = path
    CATransaction.commit()
    if supplemental {
      confirmedVisionIDs.supplemental = confirmed
    } else {
      confirmedVisionIDs.primary = confirmed
    }
    updateVisionStatus()
  }

  private func updateVisionStatus() {
    let names = confirmedVisionIDs.visible.map { id in
      model.objects.first { $0.objectId == id }?.displayName ?? id
    }
    visionStatus.text = names.isEmpty ? visionIdleText : "Vision · " + names.joined(separator: ", ")
  }

  private func clearDetections() {
    drawDetections([])
  }

  private func clearSupplementalDetections() {
    drawDetections([], supplemental: true)
  }

  private func updateDetectionPose(_ pose: simd_float4x4) {
    currentPose = pose
    if let lastDetection {
      if !lastDetection.matchesPose(pose) {
        clearDetections()
      } else if detectionLayer.path != nil, !isCurrent(lastDetection, comparedWith: pose) {
        // Hide aged boxes while keeping the prior raw sample for the next capture.
        setDetectionOverlay(path: nil, confirmed: [], supplemental: false)
      }
    }
    if let lastSupplementalDetection {
      if !lastSupplementalDetection.matchesPose(pose) {
        #if targetEnvironment(simulator)
        if usesSimulatorJourneyDetector, journeyStart != nil { journeyVisionExpiry.poseReset += 1 }
        #endif
        clearSupplementalDetections()
      } else if supplementalLayer.path != nil, !isCurrent(lastSupplementalDetection, comparedWith: pose) {
        #if targetEnvironment(simulator)
        if usesSimulatorJourneyDetector, journeyStart != nil { journeyVisionExpiry.hidden += 1 }
        #endif
        setDetectionOverlay(path: nil, confirmed: [], supplemental: true)
      }
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
    updateMap(pose)
    updateWalkStatus(at: pose.columns.3)
  }

  private func updateWalkStatus(at position: SIMD4<Float>) {
    let cell = cellAt(x: position.x, z: position.z)
    let walkable = isWalkablePosition(x: position.x, z: position.z)
    if replanAfterRetreat, !replanPending, walkable,
       let center = plannedObstacleCenter, let placed = obstaclePlacedAt {
      replanAfterRetreat = false
      replanAroundCrate(at: center, from: cell, placed: placed)
    }
    arrived = false
    if !walkable {
      if model.keyControls && cell == SIMD2(model.start[0], model.start[1]) {
        updateDisplay("Start position lacks the selected clearance. Close and reduce the camera radius.")
      } else if model.keyControls && replanAfterRetreat {
        updateDisplay("The crate blocks this position. Reset alignment to resume from the start.")
      } else {
        updateDisplay("Outside the model’s walkable area. Return to the route or show the camera.")
      }
    } else if let arrival = arrivalText(at: position) {
      arrived = true
      let summary = model.inspectionSummary.map { "\n\($0)" } ?? ""
      updateDisplay(arrival + summary)
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
    report.navigationItem.rightBarButtonItem = UIBarButtonItem(
      systemItem: .close, primaryAction: UIAction { [weak report] _ in
        report?.navigationController?.dismiss(animated: true)
      })
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
    present(UINavigationController(rootViewController: report), animated: true)
  }

  private func updateMap(_ pose: simd_float4x4?) {
    routeMap.setPose(pose)
    expandedMap?.setPose(pose)
  }

  @objc private func showMap() {
    guard presentedViewController == nil else { return }
    let page = UIViewController()
    page.title = model.name
    page.view.backgroundColor = .black
    let map = RouteMapView(model: model, image: mapImage, expanded: true)
    map.accessibilityTraits = .image
    map.accessibilityHint = nil
    map.setRoute(activeRoute)
    map.setPose(routeMap.pose)
    expandedMap = map
    map.translatesAutoresizingMaskIntoConstraints = false
    page.view.addSubview(map)
    NSLayoutConstraint.activate([
      map.leadingAnchor.constraint(equalTo: page.view.leadingAnchor),
      map.trailingAnchor.constraint(equalTo: page.view.trailingAnchor),
      map.topAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.topAnchor),
      map.bottomAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.bottomAnchor),
    ])
    page.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done,
      primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    let navigation = UINavigationController(rootViewController: page)
    navigation.modalPresentationStyle = .overFullScreen
    present(navigation, animated: true)
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
    if visionMode == .normal && (!ready || alignment == nil) { updateMap(nil) }
    let visible = showModel && (visionMode == .journey || visionMode == .preview ||
                               visionMode == .obstacle || (ready && alignment != nil))
    virtual.isHidden = !visible
    movementControls?.isHidden = !visible
    inspect.isHidden = !visible || !arrived
    visionStatus.isHidden = !visible || visionMode.isLiveWalk
    nearbyStatus.isHidden = !visible || nearbyStatus.text == nil
    moveCrate.isHidden = !visible || model.obstacleDemo != true
    moveCrate.isEnabled = !replanPending

    if !visible {
      buttons.removeAll()
      updateServiceMarker(at: nil)
      clearDetections()
      clearSupplementalDetections()
      if nearbyFrameLayer.path != nil {
        nearbyFrameLayer.path = nil
        targetFrameLayer.path = nil
        nearbyLabels.values.forEach { $0.isHidden = true }
        nearbyStatus.text = nil
      }
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
    closed = true
    renderer.vision.stopSupplementalModel()
    clearDetections()
    clearSupplementalDetections()
    if verificationPoses != nil { restoreVerificationIdleTimer() }
    reality.session.pause()
    dismiss(animated: true)
  }
}
