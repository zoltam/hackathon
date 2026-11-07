import ARKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ValmetField") else { return }
    let channel = FlutterMethodChannel(name: "valmet/field", binaryMessenger: registrar.messenger())
    let open: (String, WorldWalk.VisionMode, [WorldWalk.VerificationPose]?, @escaping FlutterResult) -> Void = {
      payload, visionMode, verificationPoses, result in
      guard let host = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow })?.rootViewController,
        host.presentedViewController == nil else {
        return result(FlutterError(code: "unavailable", message: "Could not open the AR camera.", details: nil))
      }
      guard let model = try? JSONDecoder().decode(WalkSite.self, from: Data(payload.utf8)) else {
        return result(FlutterError(code: "invalid_model", message: "Could not open this 3D model.", details: nil))
      }
      if visionMode == .preview {
        guard let target = model.target, model.objects.indices.contains(target),
              let service = model.objects[target].service,
              let floor = model.walkableFloor, model.route.first == model.start,
              WalkSite.isClearanceSafeRoute(model.route, to: service, walkableFloor: floor) else {
          return result(FlutterError(code: "invalid_route", message: "No safe route to this device.", details: nil))
        }
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
                                         cellSize: model.cellSize, obstacleEnabled: visionMode == .obstacle || model.obstacleDemo == true,
                                         framesPerSecond: model.renderFramesPerSecond) else {
        return result(FlutterError(code: "metal", message: "Could not start the 3D renderer.", details: nil))
      }
      let detectorKey = registrar.lookupKey(forAsset: "assets/valmet/equipment-detector.mlmodel")
      let detectorURL = Bundle.main.url(forResource: detectorKey, withExtension: nil)
      let mapKey = registrar.lookupKey(forAsset: "assets/valmet/equipment-room-map.png")
      let mapImage = Bundle.main.path(forResource: mapKey, ofType: nil).flatMap { UIImage(contentsOfFile: $0) }
      let camera = WorldWalk(model: model, renderer: renderer, detectorURL: detectorURL,
                             visionMode: visionMode, mapImage: mapImage, verificationPoses: verificationPoses)
      camera.replanRoute = { request, completion in
        channel.invokeMethod("replanServiceRoute", arguments: request, result: completion)
      }
      camera.modalPresentationStyle = .fullScreen
      host.present(camera, animated: visionMode == .normal || visionMode == .preview) { result(nil) }
    }
    channel.setMethodCallHandler { call, result in
      guard call.method == "openWorld" || call.method == "openServiceSimulation" else {
        return result(FlutterMethodNotImplemented)
      }
      guard let payload = call.arguments as? String else {
        return result(FlutterError(code: "invalid_model", message: "Missing 3D model.", details: nil))
      }
      open(payload, call.method == "openWorld" ? .normal : .preview, nil, result)
    }
    let arguments = ProcessInfo.processInfo.arguments
    #if targetEnvironment(simulator)
    let personArgument = arguments.firstIndex(of: "--verify-person-service")
    #else
    let personArgument: Int? = nil
    #endif
    let obstacleArgument = arguments.firstIndex(of: "--verify-obstacle-reroute")
    let journeyArgument = obstacleArgument ?? arguments.firstIndex(of: "--verify-service-journey")
    let verifyArgument = arguments.firstIndex(of: "--verify-rendered-vision")
    let visionMode: WorldWalk.VisionMode = personArgument != nil ? .preview :
      obstacleArgument != nil ? .obstacle : journeyArgument != nil ? .journey :
      arguments.contains("--benchmark-rendered-vision") ? .benchmark :
      verifyArgument != nil ? .verify : .normal
    let verificationPoses: [WorldWalk.VerificationPose]?
    if visionMode == .verify, let verifyArgument, arguments.indices.contains(verifyArgument + 1),
       !arguments[verifyArgument + 1].hasPrefix("-") {
      guard let poses = try? JSONDecoder().decode([WorldWalk.VerificationPose].self,
          from: Data(arguments[verifyArgument + 1].utf8)),
          (1...64).contains(poses.count), poses.allSatisfy(\.isValid),
          Set(poses.map(\.id)).count == poses.count else {
        print("VALMET_VISION result=failed error=invalid_pose_fixture")
        fflush(stdout)
        return
      }
      verificationPoses = poses
    } else {
      verificationPoses = nil
    }
    if visionMode != .normal {
      let logPrefix = personArgument != nil ? "VALMET_PERSON" :
        visionMode == .obstacle ? "VALMET_OBSTACLE" : visionMode == .journey ? "VALMET_JOURNEY" :
        visionMode == .benchmark ? "VALMET_BENCH" : "VALMET_VISION"
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let key = registrar.lookupKey(forAsset: personArgument == nil ? "assets/valmet/site.json" : "assets/valmet/person-site.json")
        guard let url = Bundle.main.url(forResource: key, withExtension: nil),
              let data = try? Data(contentsOf: url),
              var site = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let start = site["start"] as? [Int], start.count == 2 else {
          print(verificationPoses != nil ? "VALMET_VISION result=failed error=missing_scene" :
                visionMode == .verify ? "VALMET_VISION missing scene" : "\(logPrefix) error=missing_scene")
          fflush(stdout)
          return
        }
        site["keyControls"] = false
        func present(_ scene: [String: Any]) {
          guard let data = try? JSONSerialization.data(withJSONObject: scene) else { return }
          open(String(decoding: data, as: UTF8.self), visionMode, verificationPoses) { error in
            if let error = error as? FlutterError {
              print(verificationPoses != nil ? "VALMET_VISION result=failed error=\(error.code)" :
                    visionMode == .verify ? "VALMET_VISION opening error: \(error.code)" : "\(logPrefix) error=\(error.code)")
              fflush(stdout)
            }
          }
        }
        func presentWithEvidence(_ scene: [String: Any], targetID: String) {
          channel.invokeMethod("serviceJourneyEvidence", arguments: [
            "targetID": targetID, "personNavigation": personArgument != nil
          ]) { result in
            var scene = scene
            if let evidence = result as? [String: Any], var objects = scene["objects"] as? [[String: Any]] {
              let conditions = evidence["conditions"] as? [String: Any] ?? [:]
              let tags = evidence["tags"] as? [String: Any] ?? [:]
              for index in objects.indices {
                if let id = objects[index]["objectId"] as? String {
                  objects[index]["syntheticCondition"] = conditions[id] as? String
                  objects[index]["workbookTag"] = tags[id] as? String
                }
              }
              scene["objects"] = objects
              scene["hasWorkbook"] = evidence["hasWorkbook"] as? Bool
              scene["inspectionReport"] = evidence["inspectionReport"] as? String
              scene["inspectionSummary"] = evidence["inspectionSummary"] as? String
            }
            present(scene)
          }
        }
        if let personArgument {
          guard arguments.indices.contains(personArgument + 1),
                let profile = site["navigationProfile"] as? [String: Any],
                let clearance = profile["radiusMetres"] as? Double,
                let eye = profile["eyeHeightMetres"] as? Double,
                let speed = profile["speedMetresPerSecond"] as? Double,
                let cellSize = site["cellSize"] as? Double,
                let objects = site["objects"] as? [[String: Any]],
                let target = objects.firstIndex(where: { $0["objectId"] as? String == arguments[personArgument + 1] }),
                let service = objects[target]["service"] as? [Int] else {
            print("\(logPrefix) error=invalid_target_or_profile")
            fflush(stdout)
            return
          }
          channel.invokeMethod("replanServiceRoute", arguments: [
            "from": start, "to": service, "blocked": [] as [[Int]], "clearanceMetres": clearance,
            "personNavigation": true
          ]) { result in
            guard let planner = result as? [String: Any], let floor = planner["walkableFloor"] as? [[Int]],
                  let route = planner["route"] as? [[Int]], !route.isEmpty else {
              print("\(logPrefix) error=no_route")
              fflush(stdout)
              return
            }
            var scene = site
            scene["target"] = target
            scene["route"] = route
            scene["walkableFloor"] = floor
            scene["clearanceMetres"] = clearance
            scene["eyeHeightMetres"] = eye
            scene["walkingSpeedMetresPerSecond"] = speed
            scene["arrivalRadiusMetres"] = cellSize / 2
            presentWithEvidence(scene, targetID: arguments[personArgument + 1])
          }
        } else if let journeyArgument {
          guard arguments.indices.contains(journeyArgument + 1),
                let journey = (try? JSONSerialization.jsonObject(
                  with: Data(arguments[journeyArgument + 1].utf8))) as? [String: Any],
                let route = journey["route"] as? [[Int]], let routeStart = route.first,
                routeStart.count == 2,
                let id = journey["targetID"] as? String,
                let objects = site["objects"] as? [[String: Any]],
                let target = objects.firstIndex(where: { $0["objectId"] as? String == id }),
                let service = objects[target]["service"] as? [Int], service.count == 2, route.last == service else {
            print("\(logPrefix) error=invalid_route")
            fflush(stdout)
            return
          }
          let clearance = 0.10
          channel.invokeMethod("replanServiceRoute", arguments: [
            "from": routeStart, "to": service, "blocked": [] as [[Int]], "clearanceMetres": clearance
          ]) { result in
            guard let planner = result as? [String: Any], let walkableFloor = planner["walkableFloor"] as? [[Int]] else {
              print("\(logPrefix) error=planner_unavailable")
              fflush(stdout)
              return
            }
            guard WalkSite.isClearanceSafeRoute(route, to: service, walkableFloor: walkableFloor) else {
              print("\(logPrefix) error=invalid_route")
              fflush(stdout)
              return
            }
            var scene = site
            scene["start"] = routeStart
            scene["target"] = target
            scene["route"] = route
            scene["walkableFloor"] = walkableFloor
            scene["clearanceMetres"] = clearance
            if visionMode == .journey {
              presentWithEvidence(scene, targetID: id)
            } else {
              present(scene)
            }
          }
        } else {
          site["target"] = 0
          site["route"] = [start, [start[0], start[1] + 1]]
          if verificationPoses != nil, let objects = site["objects"] as? [[String: Any]],
             let targetID = objects.first?["objectId"] as? String {
            presentWithEvidence(site, targetID: targetID)
          } else {
            present(site)
          }
        }
      }
    }
  }
}
