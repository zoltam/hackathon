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
}
