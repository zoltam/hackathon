import Flutter
import UIKit
import XCTest
import simd
@testable import Runner

class RunnerTests: XCTestCase {
  private func routeSite() throws -> WalkSite {
    let json = #"{"name":"Test","width":3,"depth":3,"cellSize":1,"start":[0,0],"route":[[0,0],[1,0],[1,1]],"objects":[]}"#
    return try JSONDecoder().decode(WalkSite.self, from: Data(json.utf8))
  }

  func testPlaybackFollowsCornerAndClampsAtServicePosition() throws {
    let site = try routeSite()
    let halfway = try XCTUnwrap(site.playbackPose(distance: 0.5))
    XCTAssertEqual(halfway.columns.3.x, 1, accuracy: 0.0001)
    XCTAssertEqual(halfway.columns.3.z, 0.5, accuracy: 0.0001)
    let corner = try XCTUnwrap(site.playbackPose(distance: 1))
    XCTAssertEqual(corner.columns.3.x, 1.5, accuracy: 0.0001)
    XCTAssertEqual(corner.columns.3.z, 0.5, accuracy: 0.0001)
    let end = try XCTUnwrap(site.playbackPose(distance: 100))
    XCTAssertEqual(end.columns.3.x, 1.5, accuracy: 0.0001)
    XCTAssertEqual(end.columns.3.z, 1.5, accuracy: 0.0001)
    XCTAssertEqual(end.columns.3.y, assumedPhoneHeight, accuracy: 0.0001)
    XCTAssertEqual(site.routeLength, 2)
  }
}
