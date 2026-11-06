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
}
