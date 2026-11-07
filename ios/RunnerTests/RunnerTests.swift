import Flutter
import CoreML
import UIKit
import XCTest
import simd
@testable import Runner

class RunnerTests: XCTestCase {
  func testLiveVisionAcceptsOnlySelectedEquipment() {
    for mode in [WorldWalk.VisionMode.normal, .preview] {
      XCTAssertTrue(mode.acceptsDetection("pump", selectedID: "pump"))
      XCTAssertFalse(mode.acceptsDetection("valve", selectedID: "pump"))
      XCTAssertFalse(mode.acceptsDetection("pump", selectedID: nil))
    }
    for mode in [WorldWalk.VisionMode.verify, .benchmark, .journey, .obstacle] {
      XCTAssertTrue(mode.acceptsDetection("valve", selectedID: "pump"))
      XCTAssertTrue(mode.acceptsDetection("pump", selectedID: nil))
    }
  }

  func testNearbyFramesUseValidExtractionBoundsIndependentlyOfOperationalBounds() throws {
    let prefix = #"{"name":"Pump","x":0,"z":0,"width":1,"depth":1,"height":1,"bounds":[[1,2,3],[2,3,4]]"#
    func block(_ extraction: String? = nil) throws -> WalkSite.Block {
      let field = extraction.map { #", "extractionBounds": "# + $0 } ?? ""
      return try JSONDecoder().decode(WalkSite.Block.self, from: Data((prefix + field + "}").utf8))
    }
    let operational: [[Float]] = [[1, 2, 3], [2, 3, 4]]
    let valid = try block("[[5,6,7],[8,9,10]]")
    XCTAssertEqual(valid.nearbyFrameBounds, [[5, 6, 7], [8, 9, 10]])
    XCTAssertEqual(valid.bounds, operational)
    XCTAssertEqual(valid.markerBounds, operational)
    XCTAssertEqual(valid.floorBounds(cellSize: 1).min, SIMD2<Float>(1, 3))
    XCTAssertEqual(try block().nearbyFrameBounds, operational)
    for malformed in ["[[1,2],[3,4]]", "[[2,2,3],[1,3,4]]", "[[1,2,3],[1,3,4]]", "[[1,2,3],[1e40,3,4]]", #""bad""#] {
      XCTAssertEqual(try block(malformed).nearbyFrameBounds, operational)
    }
  }

  func testServiceMarkerStaysVisibleAboveControlsAndAtScreenEdge() throws {
    let viewport = CGRect(x: 0, y: 0, width: 400, height: 700)
    let area = CGRect(x: 6, y: 6, width: 388, height: 340)
    let top = try XCTUnwrap(WorldWalk.serviceMarkerPosition(SIMD4(0.99, -0.5, 0.5, 1),
                                                           viewport: viewport, availableArea: area))
    XCTAssertEqual(top, CGPoint(x: 372, y: 318))
    XCTAssertNil(WorldWalk.serviceMarkerPosition(SIMD4(0, 0, 0, -1), viewport: viewport, availableArea: area))
    XCTAssertNil(WorldWalk.serviceMarkerPosition(SIMD4(2, 0, 0.5, 1), viewport: viewport, availableArea: area))
  }

  func testValveActuatorShowsSyntheticParentTagSeparately() throws {
    let json = """
      {"name":"Orange actuator A","equipmentType":"valve_actuator",
       "x":0,"z":0,"width":1,"depth":1,"height":1,"workbookTag":"CV-001"}
      """
    let block = try JSONDecoder().decode(WalkSite.Block.self, from: Data(json.utf8))
    XCTAssertEqual(block.displayName, "Orange actuator A · synthetic parent CV-001")
  }

  func testSupplementalDecoderRanksBackgroundBeforeDroppingItAndClipsBoxes() throws {
    let boxes = try MLMultiArray(shape: [1, 2, 4], dataType: .float32)
    let logits = try MLMultiArray(shape: [1, 2, 3], dataType: .float32)
    for (index, value) in [0.1, 0.1, 0.4, 0.4, 0.75, 0.5, 0.2, 0.2].enumerated() {
      boxes[index] = NSNumber(value: value)
    }
    for (index, value) in [3.0, -10, 10, -10, 4, -10].enumerated() {
      logits[index] = NSNumber(value: value)
    }
    let topTwo = try RFDETRDecoder.decode(
      boxes: boxes, logits: logits, classes: ["first", "second"], thresholds: [0.5, 0.5], topK: 2)
    XCTAssertEqual(topTwo.map(\.objectID), ["second"])
    let topThree = try RFDETRDecoder.decode(
      boxes: boxes, logits: logits, classes: ["first", "second"], thresholds: [0.5, 0.5], topK: 3)
    let clipped = try XCTUnwrap(topThree.first { $0.objectID == "first" })
    XCTAssertEqual(clipped.bounds.minX, 0, accuracy: 0.00001)
    XCTAssertEqual(clipped.bounds.minY, 0.7, accuracy: 0.00001)
    XCTAssertEqual(clipped.bounds.width, 0.3, accuracy: 0.00001)
    XCTAssertEqual(clipped.bounds.height, 0.3, accuracy: 0.00001)
    boxes[4] = NSNumber(value: Float.nan)
    let finite = try RFDETRDecoder.decode(
      boxes: boxes, logits: logits, classes: ["first", "second"], thresholds: [0.5, 0.5], topK: 3)
    XCTAssertEqual(finite.map(\.objectID), ["first"])
  }

  func testSupplementalDecoderRejectsIncompatibleShapesAndThresholds() throws {
    let boxes = try MLMultiArray(shape: [1, 2, 4], dataType: .float32)
    let logits = try MLMultiArray(shape: [1, 2, 2], dataType: .float32)
    XCTAssertThrowsError(try RFDETRDecoder.decode(
      boxes: boxes, logits: logits, classes: ["first", "second"], thresholds: [0.5, 0.5], topK: 3))
    XCTAssertThrowsError(try RFDETRDecoder.decode(
      boxes: boxes, logits: logits, classes: ["first"], thresholds: [Float.nan], topK: 3))
  }

  private func routeSite() throws -> WalkSite {
    let json = #"{"name":"Test","keyControls":false,"width":3,"depth":3,"cellSize":1,"start":[0,0],"route":[[0,0],[1,0],[1,1]],"objects":[]}"#
    return try JSONDecoder().decode(WalkSite.self, from: Data(json.utf8))
  }

  func testRouteCellsMapToModelPositions() throws {
    let site = try routeSite()
    XCTAssertEqual(site.route.map { site.center($0) }, [
      SIMD3<Float>(0.5, 0, 0.5),
      SIMD3<Float>(1.5, 0, 0.5),
      SIMD3<Float>(1.5, 0, 1.5),
    ])
  }

  func testScriptedRouteUsesClearanceMaskFromMultipleStarts() {
    let approach = [2, 0]
    let detour = [[0, 0], [0, 1], [1, 1], [2, 1], approach]
    XCTAssertTrue(WalkSite.isClearanceSafeRoute(detour, to: approach, walkableFloor: detour))
    XCTAssertTrue(WalkSite.isClearanceSafeRoute(Array(detour.dropFirst()), to: approach, walkableFloor: detour))
    XCTAssertTrue(WalkSite.isClearanceSafeRoute([approach], to: approach, walkableFloor: detour))
    XCTAssertFalse(WalkSite.isClearanceSafeRoute([[0, 0], [1, 0], approach], to: approach, walkableFloor: detour))
  }

  func testScriptedRouteRejectsMalformedPaths() {
    let floor = [[0, 0], [0, 1], [1, 1]]
    let approach = [1, 1]
    for route in [[], [[0], approach], [[0, 0], approach], [[0, 0], [0, 1]]] {
      XCTAssertFalse(WalkSite.isClearanceSafeRoute(route, to: approach, walkableFloor: floor))
    }
  }

  func testMinimapDropsThePreviousRouteWhenReplanned() throws {
    let map = RouteMapView(model: try routeSite())
    map.frame = CGRect(x: 0, y: 0, width: 160, height: 160)
    map.layoutIfNeeded()
    func snapshot() -> Data? {
      map.layer.displayIfNeeded()
      return UIGraphicsImageRenderer(size: map.bounds.size).image {
        map.layer.render(in: $0.cgContext)
      }.pngData()
    }
    let original = try XCTUnwrap(snapshot())
    map.setRoute([])
    XCTAssertTrue(map.route.isEmpty)
    XCTAssertNotEqual(try XCTUnwrap(snapshot()), original)
    map.setRoute([[0, 0], [0, 1], [1, 1]])
    XCTAssertEqual(map.route, [[0, 0], [0, 1], [1, 1]])
    XCTAssertNotEqual(try XCTUnwrap(snapshot()), original)
  }

  private func clearanceSite(_ radius: String) throws -> WalkSite {
    let json = """
      {"name":"Clearance","keyControls":true,"width":126,"depth":129,"cellSize":0.1,
       "start":[67,63],"route":[],"clearanceMetres":\(radius),
       "objects":[{"name":"Obstacle","x":65,"z":61,"width":1,"depth":1,"height":1}]}
      """
    return try JSONDecoder().decode(WalkSite.self, from: Data(json.utf8))
  }

  func testContinuousClearanceRejectsOffCentrePositionsInSafeCells() throws {
    let cases: [(String, SIMD2<Float>, SIMD2<Float>)] = [
      ("0.2", SIMD2(6.75, 6.35), SIMD2(6.75, 6.301)),
      ("0.3", SIMD2(6.85, 6.45), SIMD2(6.801, 6.401)),
    ]
    for (radius, center, nearCorner) in cases {
      let site = try clearanceSite(radius)
      XCTAssertEqual(site.cellAt(x: center.x, z: center.y), site.cellAt(x: nearCorner.x, z: nearCorner.y))
      XCTAssertTrue(site.isClearanceSafePosition(center, observedFloor: nil, occupied: site.occupiedFloor))
      XCTAssertFalse(site.isClearanceSafePosition(nearCorner, observedFloor: nil, occupied: site.occupiedFloor))
      XCTAssertFalse(site.isClearanceSafePosition(nearCorner, observedFloor: nil,
                                                  occupied: [], additionalBlocked: [[65, 61]]))
      let observed = Set((62...72).flatMap { x in (58...69).map { SIMD2(x, $0) } }).subtracting([SIMD2(65, 61)])
      XCTAssertFalse(site.isClearanceSafePosition(nearCorner, observedFloor: observed, occupied: []))
    }
  }

  func testContinuousClearanceAllowsTangencyAndLegacyPointRouting() throws {
    let site = try clearanceSite("0.2")
    XCTAssertTrue(site.isClearanceSafePosition(SIMD2(0.2, 1), observedFloor: nil, occupied: []))
    XCTAssertFalse(site.isClearanceSafePosition(SIMD2(0.1999, 1), observedFloor: nil, occupied: []))
    XCTAssertTrue(site.isClearanceSafePosition(SIMD2(6.8, 6.15), observedFloor: nil, occupied: site.occupiedFloor))
    XCTAssertFalse(site.isClearanceSafePosition(SIMD2(6.7999, 6.15), observedFloor: nil, occupied: site.occupiedFloor))
    let old = try clearanceSite("null")
    XCTAssertTrue(old.isClearanceSafePosition(SIMD2(0.01, 1), observedFloor: nil, occupied: []))
    XCTAssertFalse(old.isClearanceSafePosition(SIMD2(0.01, 1), observedFloor: [], occupied: []))
  }

  func testArrivalAcceptsTheApproachButNotOtherNearbyCells() throws {
    let json = #"{"name":"Test","keyControls":false,"width":4,"depth":6,"cellSize":0.1,"start":[1,0],"route":[[1,0],[1,1],[1,2],[1,3],[1,4]],"objects":[]}"#
    let site = try JSONDecoder().decode(WalkSite.self, from: Data(json.utf8))
    XCTAssertTrue(site.isAtServicePosition(SIMD2(0.15, 0.25), on: site.route))
    XCTAssertFalse(site.isAtServicePosition(SIMD2(0.25, 0.45), on: site.route))
    XCTAssertFalse(site.isAtServicePosition(SIMD2(0.15, 0.05), on: site.route))
    XCTAssertFalse(site.isAtServicePosition(SIMD2(0.15, 0.45), on: []))
  }

  func testDetectionPairUsesCaptureGapAndMatchingPose() {
    func frame(_ timestamp: CFTimeInterval, x: Float = 0) -> RenderedVision.Frame {
      var pose = matrix_identity_float4x4
      pose.columns.3.x = x
      return .init(pose: pose, projection: matrix_identity_float4x4, timestamp: timestamp)
    }
    let previous = frame(10)
    XCTAssertTrue(frame(10.25).follows(previous, within: 0.4))
    XCTAssertFalse(frame(10.45).follows(previous, within: 0.4))
    XCTAssertFalse(frame(10).follows(previous, within: 0.4))
    XCTAssertFalse(frame(9.9).follows(previous, within: 0.4))
    XCTAssertFalse(frame(10.25, x: 0.17).follows(previous, within: 0.4))
  }

  func testSupplementalChairVetoUsesStrongestOverlappingHandTruck() {
    // Recorded projected detections in release-right-control-cabinet-03.png.
    let chair = RenderedVision.Detection(
      objectID: "boiler-room:rolling-chair", confidence: 0.5795194,
      bounds: CGRect(x: 0, y: 0, width: 0.1529541015625, height: 0.347412109375))
    let truck = RenderedVision.Detection(
      objectID: "boiler-room:red-wheel-hand-truck", confidence: 0.8729984,
      bounds: CGRect(x: 0.00189208984375, y: 0.039306640625,
                     width: 0.1756591796875, height: 0.32080078125))
    let blocked = RenderedVision.strongestDetections([chair, truck], supplemental: true)
    XCTAssertNil(blocked[chair.objectID])
    XCTAssertEqual(blocked[truck.objectID]?.bounds, truck.bounds)

    let weak = RenderedVision.Detection(objectID: truck.objectID,
                                         confidence: chair.confidence + 0.19, bounds: truck.bounds)
    let distant = RenderedVision.Detection(objectID: truck.objectID, confidence: 0.95,
                                            bounds: truck.bounds.offsetBy(dx: 0.12, dy: 0))
    for observations in [[chair, weak], [chair, truck, distant]] {
      XCTAssertEqual(RenderedVision.strongestDetections(observations, supplemental: true)[chair.objectID]?.bounds,
                     chair.bounds)
    }
    XCTAssertNotNil(RenderedVision.strongestDetections([chair, truck], supplemental: false)[chair.objectID])
  }

  func testDetectionMatchesTheMappedAssetAtCapturePose() {
    let bounds: [[Float]] = [[-0.4, 0.2, 0.2], [0.0, 0.6, 0.5]]
    let fragment = RenderedVision.Detection(
      objectID: "pump", confidence: 0.8,
      bounds: CGRect(x: 0.37, y: 0.66, width: 0.07, height: 0.07))
    XCTAssertTrue(RenderedVision.matches(fragment, to: bounds, viewProjection: matrix_identity_float4x4))

    var movedView = matrix_identity_float4x4
    movedView.columns.3.x = 1
    XCTAssertFalse(RenderedVision.matches(fragment, to: bounds, viewProjection: movedView))
    XCTAssertFalse(RenderedVision.matches(
      fragment, to: [[-0.4, 0.2, -0.5], [0.0, 0.6, -0.2]],
      viewProjection: matrix_identity_float4x4))
  }

  func testObstacleTagLocalizesPerspectiveCornersOnTheCratePlane() throws {
    let center = SIMD2<Float>(6.95, 6.55)
    let eye = SIMD3<Float>(5.85, 1.50, 6.45)
    let look = SIMD3(center.x, ObstacleTag.height, center.y)
    let back = simd_normalize(eye - look)
    let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), back))
    let up = simd_cross(back, right)
    func vector(_ point: SIMD3<Float>, _ w: Float) -> SIMD4<Float> {
      SIMD4(point.x, point.y, point.z, w)
    }
    let pose = simd_float4x4(columns: (vector(right, 0), vector(up, 0), vector(back, 0), vector(eye, 1)))
    let projection = simd_float4x4(columns: (
      SIMD4(2.8, 0, 0, 0), SIMD4(0, 1.4, 0, 0),
      SIMD4(0, 0, -1.001, -1), SIMD4(0, 0, -0.04004, 0)
    ))
    let frame = RenderedVision.Frame(pose: pose, projection: projection, timestamp: 1)
    let transform = projection * pose.inverse
    func corners(halfSide: Float) -> [CGPoint] {
      [SIMD2<Float>(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)].map { corner in
        let point = center + corner * halfSide
        let clip = transform * SIMD4(point.x, ObstacleTag.height, point.y, 1)
        return CGPoint(x: CGFloat((clip.x / clip.w + 1) / 2), y: CGFloat((clip.y / clip.w + 1) / 2))
      }
    }

    let observed = try XCTUnwrap(ObstacleTag.center(corners: corners(halfSide: 0.19), frame: frame))
    XCTAssertEqual(observed.x, center.x, accuracy: 0.001)
    XCTAssertEqual(observed.y, center.y, accuracy: 0.001)
    XCTAssertNil(ObstacleTag.center(corners: corners(halfSide: 0.05), frame: frame))
  }

  private func roomSite() throws -> WalkSite {
    let json = """
      {"name":"Equipment Room","sourceSha256":"\(RouteMapView.imageSourceSha256)",
       "keyControls":false,"width":126,"depth":129,"cellSize":0.1,
       "start":[58,65],"route":[[58,65],[73,65],[73,81]],"objects":[]}
      """
    return try JSONDecoder().decode(WalkSite.self, from: Data(json.utf8))
  }

  func testPNGMapKeepsReviewedStartAndServiceAlignedAtBothSizes() throws {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 200)).image { _ in
      UIColor.brown.setFill()
      UIBezierPath(rect: CGRect(x: 0, y: 0, width: 240, height: 200)).fill()
    }
    let map = RouteMapView(model: try roomSite(), image: image)
    XCTAssertNotNil(map.mapImage)
    for size in [CGSize(width: 160, height: 160), CGSize(width: 360, height: 600)] {
      map.frame = CGRect(origin: .zero, size: size)
      let region = RouteMapView.imageWorldBounds
      let a = map.mapPoint(x: Float(region.minX), z: Float(region.minY))
      let b = map.mapPoint(x: Float(region.maxX), z: Float(region.maxY))
      let start = map.mapPoint(x: 5.85, z: 6.55)
      let service = map.mapPoint(x: 7.35, z: 8.15)
      XCTAssertEqual((b.x - a.x) / (b.y - a.y), 1.2, accuracy: 0.0001)
      // Reviewed landmarks in the 2400 × 2000 PNG, independent of view size.
      XCTAssertEqual((start.x - a.x) / (b.x - a.x) * 2400, 1036.578, accuracy: 0.1)
      XCTAssertEqual((start.y - a.y) / (b.y - a.y) * 2000, 1243.252, accuracy: 0.1)
      XCTAssertEqual((service.x - a.x) / (b.x - a.x) * 2400, 1412.722, accuracy: 0.1)
      XCTAssertEqual((service.y - a.y) / (b.y - a.y) * 2000, 1644.473, accuracy: 0.1)
    }
    XCTAssertNil(RouteMapView(model: try routeSite(), image: image).mapImage)
  }

  func testFrameRateDefaultsAndRejectsUnsupportedValues() throws {
    XCTAssertEqual(try routeSite().renderFramesPerSecond, 30)
    for (value, expected) in [(15, 15), (60, 60), (0, 30), (1000, 30)] {
      let json = "{\"name\":\"Test\",\"keyControls\":false,\"framesPerSecond\":\(value),\"width\":3,\"depth\":3,\"cellSize\":1,\"start\":[0,0],\"route\":[],\"objects\":[]}"
      let site = try JSONDecoder().decode(WalkSite.self, from: Data(json.utf8))
      XCTAssertEqual(site.renderFramesPerSecond, expected)
    }
  }

  func testMapPreservesModelAxesAndScaleWhenExpanded() throws {
    let map = RouteMapView(model: try routeSite())
    for size in [CGSize(width: 160, height: 160), CGSize(width: 360, height: 700)] {
      map.frame = CGRect(origin: .zero, size: size)
      let origin = map.mapPoint(x: 0, z: 0)
      let east = map.mapPoint(x: 1, z: 0)
      let south = map.mapPoint(x: 0, z: 1)
      XCTAssertGreaterThan(east.x, origin.x)
      XCTAssertGreaterThan(south.y, origin.y)
      XCTAssertEqual(east.x - origin.x, south.y - origin.y, accuracy: 0.001)
      XCTAssertTrue(map.bounds.contains(map.mapPoint(x: 3, z: 3)))
    }
  }

  func testMapDoesNotClaimLocationBeforeAlignmentOrAfterTrackingLoss() throws {
    let map = RouteMapView(model: try routeSite())
    XCTAssertNil(map.pose)
    XCTAssertEqual(map.accessibilityValue, "Location unavailable")
    var pose = matrix_identity_float4x4
    pose.columns.3 = SIMD4(1.5, 1.5, 2.5, 1)
    map.setPose(pose)
    XCTAssertEqual(map.pose?.columns.3, pose.columns.3)
    XCTAssertNotEqual(map.accessibilityValue, "Location unavailable")
    map.setPose(nil)
    XCTAssertNil(map.pose)
    XCTAssertEqual(map.accessibilityValue, "Location unavailable")
  }

  func testMapRendersAtCornerAndExpandedSizes() throws {
    let imageURL = Bundle.main.bundleURL.appendingPathComponent(
      "Frameworks/App.framework/flutter_assets/assets/valmet/equipment-room-map.png")
    let image = UIImage(contentsOfFile: imageURL.path)
    let map = RouteMapView(model: try image == nil ? routeSite() : roomSite(), image: image)
    var pose = matrix_identity_float4x4
    pose.columns.3 = image == nil ? SIMD4(0.5, 1.5, 0.5, 1) : SIMD4(5.85, 1.5, 6.55, 1)
    map.setPose(pose)
    for size in [CGSize(width: 160, height: 160), CGSize(width: 360, height: 600)] {
      map.frame = CGRect(origin: .zero, size: size)
      map.layoutIfNeeded()
      map.layer.displayIfNeeded()
      let image = UIGraphicsImageRenderer(size: size).image { map.layer.render(in: $0.cgContext) }
      let attachment = XCTAttachment(image: image)
      attachment.name = "Route map \(Int(size.width))"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  func testMapTapOpensLargerMapAndKeepsLocationLive() throws {
    let site = try routeSite()
    let renderer = try XCTUnwrap(SplatRenderer(data: Data(count: 160), roomSize: SIMD2(3, 3),
                                              sourceRotation: matrix_identity_float3x3,
                                              route: site.route.map { site.center($0) }, cellSize: site.cellSize))
    let controller = WorldWalk(model: site, renderer: renderer, detectorURL: nil, visionMode: .verify)
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let corner = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? RouteMapView }.first)
    renderer.view.isHidden = false
    var pose = matrix_identity_float4x4
    pose.columns.3 = SIMD4(0.5, 1.5, 0.5, 1)
    renderer.onFrameReady?(pose, matrix_identity_float4x4, renderer.view.bounds.size)
    corner.sendActions(for: .touchUpInside)
    let navigation = try XCTUnwrap(controller.presentedViewController as? UINavigationController)
    let page = try XCTUnwrap(navigation.topViewController)
    let expanded = try XCTUnwrap(page.view.subviews.compactMap { $0 as? RouteMapView }.first)
    navigation.view.layoutIfNeeded()
    page.view.layoutIfNeeded()
    XCTAssertGreaterThan(expanded.bounds.width, corner.bounds.width)
    XCTAssertEqual(expanded.pose?.columns.3, pose.columns.3)
    pose.columns.3 = SIMD4(1.5, 1.5, 1.5, 1)
    renderer.onFrameReady?(pose, matrix_identity_float4x4, renderer.view.bounds.size)
    XCTAssertEqual(expanded.pose?.columns.3, pose.columns.3)
    XCTAssertNotNil(page.navigationItem.rightBarButtonItem)
  }
}
