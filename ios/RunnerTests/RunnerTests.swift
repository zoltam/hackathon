import Flutter
import UIKit
import XCTest
import simd
@testable import Runner

class RunnerTests: XCTestCase {
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

  func testArrivalAcceptsTheApproachButNotOtherNearbyCells() throws {
    let json = #"{"name":"Test","keyControls":false,"width":4,"depth":6,"cellSize":0.1,"start":[1,0],"route":[[1,0],[1,1],[1,2],[1,3],[1,4]],"objects":[]}"#
    let site = try JSONDecoder().decode(WalkSite.self, from: Data(json.utf8))
    XCTAssertTrue(site.isAtServicePosition(SIMD2(0.15, 0.25), on: site.route))
    XCTAssertFalse(site.isAtServicePosition(SIMD2(0.25, 0.45), on: site.route))
    XCTAssertFalse(site.isAtServicePosition(SIMD2(0.15, 0.05), on: site.route))
    XCTAssertFalse(site.isAtServicePosition(SIMD2(0.15, 0.45), on: []))
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
}
