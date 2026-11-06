import ARKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ValmetField") else { return }
    let channel = FlutterMethodChannel(name: "valmet/field", binaryMessenger: registrar.messenger())
    let open: (String, WorldWalk.VisionMode, @escaping FlutterResult) -> Void = { payload, visionMode, result in
      guard let host = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow })?.rootViewController,
        host.presentedViewController == nil else {
        return result(FlutterError(code: "unavailable", message: "Could not open the AR camera.", details: nil))
      }
      guard let model = try? JSONDecoder().decode(WalkSite.self, from: Data(payload.utf8)) else {
        return result(FlutterError(code: "invalid_model", message: "Could not open this 3D model.", details: nil))
      }
      guard visionMode != .normal || ARWorldTrackingConfiguration.isSupported else {
        return result(FlutterError(code: "unsupported", message: "AR needs a compatible physical iPhone.", details: nil))
      }
      let key = registrar.lookupKey(forAsset: "assets/valmet/boiler-room-sh.splats")
      guard let path = Bundle.main.path(forResource: key, ofType: nil),
            let points = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
            !points.isEmpty, points.count.isMultiple(of: SplatRenderer.bytesPerSplat) else {
        return result(FlutterError(code: "missing_scan", message: "The boiler room scan is missing.", details: nil))
      }
      guard let renderer = SplatRenderer(data: points,
                                         roomSize: SIMD2(Float(model.width), Float(model.depth)) * model.cellSize,
                                         sourceRotation: model.sourceRotation,
                                         route: model.route.map { model.center($0) },
                                         cellSize: model.cellSize, obstacleEnabled: visionMode == .obstacle || model.obstacleDemo == true) else {
        return result(FlutterError(code: "metal", message: "Could not start the 3D renderer.", details: nil))
      }
      let detectorKey = registrar.lookupKey(forAsset: "assets/valmet/equipment-detector.mlmodel")
      let detectorURL = Bundle.main.url(forResource: detectorKey, withExtension: nil)
      let camera = WorldWalk(model: model, renderer: renderer, detectorURL: detectorURL, visionMode: visionMode)
      camera.replanRoute = { request, completion in
        channel.invokeMethod("replanServiceRoute", arguments: request, result: completion)
      }
      camera.modalPresentationStyle = .fullScreen
      host.present(camera, animated: visionMode == .normal) { result(nil) }
    }
    channel.setMethodCallHandler { call, result in
      guard call.method == "openWorld" else { return result(FlutterMethodNotImplemented) }
      guard let payload = call.arguments as? String else {
        return result(FlutterError(code: "invalid_model", message: "Missing 3D model.", details: nil))
      }
      open(payload, .normal, result)
    }
    let arguments = ProcessInfo.processInfo.arguments
    let obstacleArgument = arguments.firstIndex(of: "--verify-obstacle-reroute")
    let journeyArgument = obstacleArgument ?? arguments.firstIndex(of: "--verify-service-journey")
    let visionMode: WorldWalk.VisionMode = obstacleArgument != nil ? .obstacle : journeyArgument != nil ? .journey :
      arguments.contains("--benchmark-rendered-vision") ? .benchmark :
      arguments.contains("--verify-rendered-vision") ? .verify : .normal
    if visionMode != .normal {
      let logPrefix = visionMode == .obstacle ? "VALMET_OBSTACLE" : visionMode == .journey ? "VALMET_JOURNEY" :
        visionMode == .benchmark ? "VALMET_BENCH" : "VALMET_VISION"
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let key = registrar.lookupKey(forAsset: "assets/valmet/site.json")
        guard let url = Bundle.main.url(forResource: key, withExtension: nil),
              let data = try? Data(contentsOf: url),
              var site = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let start = site["start"] as? [Int], start.count == 2 else {
          print(visionMode == .verify ? "VALMET_VISION missing scene" : "\(logPrefix) error=missing_scene")
          fflush(stdout)
          return
        }
        site["keyControls"] = false
        if let journeyArgument {
          guard arguments.indices.contains(journeyArgument + 1),
                let journey = (try? JSONSerialization.jsonObject(
                  with: Data(arguments[journeyArgument + 1].utf8))) as? [String: Any],
                let route = journey["route"] as? [[Int]], route.first == start,
                let id = journey["targetID"] as? String,
                let objects = site["objects"] as? [[String: Any]],
                let target = objects.firstIndex(where: { $0["objectId"] as? String == id }),
                let service = objects[target]["service"] as? [Int], route.last == service,
                let floor = site["floor"] as? [[Int]] else {
            print("\(logPrefix) error=invalid_route")
            fflush(stdout)
            return
          }
          let floorCells = Set(floor)
          guard route.allSatisfy({ $0.count == 2 && floorCells.contains($0) }),
                zip(route, route.dropFirst()).allSatisfy({ a, b in
                  abs(a[0] - b[0]) + abs(a[1] - b[1]) == 1
                }) else {
            print("\(logPrefix) error=invalid_route")
            fflush(stdout)
            return
          }
          site["target"] = target
          site["route"] = route
        } else {
          site["target"] = 0
          site["route"] = [start, [start[0], start[1] + 1]]
        }
        func present(_ scene: [String: Any]) {
          guard let data = try? JSONSerialization.data(withJSONObject: scene) else { return }
          open(String(decoding: data, as: UTF8.self), visionMode) { error in
            if let error = error as? FlutterError {
              print(visionMode == .verify ? "VALMET_VISION opening error: \(error.code)" : "\(logPrefix) error=\(error.code)")
              fflush(stdout)
            }
          }
        }
        if visionMode == .journey, var objects = site["objects"] as? [[String: Any]],
           let target = site["target"] as? Int, let targetID = objects[target]["objectId"] as? String {
          channel.invokeMethod("serviceJourneyEvidence", arguments: [
            "targetID": targetID, "objectIDs": objects.compactMap { $0["objectId"] as? String }
          ]) { result in
            if let evidence = result as? [String: Any] {
              let conditions = evidence["conditions"] as? [String: Any] ?? [:]
              for index in objects.indices {
                if let id = objects[index]["objectId"] as? String {
                  objects[index]["syntheticCondition"] = conditions[id] as? String
                }
              }
              site["objects"] = objects
              site["inspectionReport"] = evidence["inspectionReport"] as? String
              site["inspectionSummary"] = evidence["inspectionSummary"] as? String
            }
            present(site)
          }
        } else {
          present(site)
        }
      }
    }
  }
}
