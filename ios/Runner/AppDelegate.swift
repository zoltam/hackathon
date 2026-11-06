import ARKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ValmetField") else { return }
    let channel = FlutterMethodChannel(name: "valmet/field", binaryMessenger: registrar.messenger())
    let open: (String, Bool, @escaping FlutterResult) -> Void = { payload, verify, result in
      guard let host = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow })?.rootViewController,
        host.presentedViewController == nil else {
        return result(FlutterError(code: "unavailable", message: "Could not open the AR camera.", details: nil))
      }
      guard let model = try? JSONDecoder().decode(WalkSite.self, from: Data(payload.utf8)) else {
        return result(FlutterError(code: "invalid_model", message: "Could not open this 3D model.", details: nil))
      }
      guard ARWorldTrackingConfiguration.isSupported else {
        return result(FlutterError(code: "unsupported", message: "AR needs a compatible physical iPhone.", details: nil))
      }
      let key = registrar.lookupKey(forAsset: "assets/valmet/boiler-room-sh.splats")
      guard let path = Bundle.main.path(forResource: key, ofType: nil),
            let points = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
            !points.isEmpty, points.count.isMultiple(of: SplatRenderer.bytesPerSplat) else {
        return result(FlutterError(code: "missing_scan", message: "The boiler room scan is missing.", details: nil))
      }
      guard let renderer = SplatRenderer(data: points, roomSize: SIMD2(Float(model.width), Float(model.depth)) * model.cellSize) else {
        return result(FlutterError(code: "metal", message: "Could not start the 3D renderer.", details: nil))
      }
      renderer.vision.referenceURLs = ["a", "b", "e"].compactMap {
        let key = registrar.lookupKey(forAsset: "assets/valmet/pump-reference-\($0).png")
        return Bundle.main.url(forResource: key, withExtension: nil)
      }
      if let index = model.target, model.objects.indices.contains(index) {
        renderer.vision.bounds = model.objects[index].bounds.flatMap(PumpBounds.init)
      }
      let camera = WorldWalk(model: model, renderer: renderer, verifyVision: verify)
      camera.modalPresentationStyle = .fullScreen
      host.present(camera, animated: !verify) { result(nil) }
    }
    channel.setMethodCallHandler { call, result in
      guard call.method == "openWorld" else { return result(FlutterMethodNotImplemented) }
      guard let payload = call.arguments as? String else {
        return result(FlutterError(code: "invalid_model", message: "Missing 3D model.", details: nil))
      }
      open(payload, false, result)
    }
    if ProcessInfo.processInfo.arguments.contains("--verify-rendered-vision") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let key = registrar.lookupKey(forAsset: "assets/valmet/site.json")
        guard let url = Bundle.main.url(forResource: key, withExtension: nil),
              let data = try? Data(contentsOf: url),
              var site = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let start = site["start"] as? [Int], start.count == 2 else {
          print("VALMET_VISION missing scene")
          fflush(stdout)
          return
        }
        site["keyControls"] = false
        site["target"] = 0
        site["route"] = [start, [start[0], start[1] + 1]]
        guard let data = try? JSONSerialization.data(withJSONObject: site) else { return }
        open(String(decoding: data, as: UTF8.self), true) { error in
          if let error = error as? FlutterError {
            print("VALMET_VISION opening error: \(error.code)")
            fflush(stdout)
          }
        }
      }
    }
  }
}
