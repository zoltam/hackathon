import ARKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ValmetField") else { return }
    let channel = FlutterMethodChannel(name: "valmet/field", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "openWorld" else { return result(FlutterMethodNotImplemented) }
      guard let host = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow })?.rootViewController,
        host.presentedViewController == nil else {
        return result(FlutterError(code: "unavailable", message: "Could not open the AR camera.", details: nil))
      }
      guard let payload = call.arguments as? String,
            let model = try? JSONDecoder().decode(WalkSite.self, from: Data(payload.utf8)) else {
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
      let camera = WorldWalk(model: model, renderer: renderer)
      camera.modalPresentationStyle = .fullScreen
      host.present(camera, animated: true) { result(nil) }
    }
  }
}
