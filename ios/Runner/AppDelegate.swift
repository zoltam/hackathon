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
      guard ["openAR", "openWorld"].contains(call.method) else { return result(FlutterMethodNotImplemented) }
      guard ARWorldTrackingConfiguration.isSupported else {
        return result(FlutterError(code: "unsupported", message: "AR needs a compatible physical iPhone.", details: nil))
      }
      guard let host = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow })?.rootViewController,
        host.presentedViewController == nil else {
        return result(FlutterError(code: "unavailable", message: "Could not open the AR camera.", details: nil))
      }
      let camera: UIViewController
      if call.method == "openWorld" {
        guard let payload = call.arguments as? String,
              let model = try? JSONDecoder().decode(WalkSite.self, from: Data(payload.utf8)) else {
          return result(FlutterError(code: "invalid_model", message: "Could not open this 3D model.", details: nil))
        }
        let key = registrar.lookupKey(forAsset: "assets/valmet/boiler-room.bin")
        guard let path = Bundle.main.path(forResource: key, ofType: nil),
              let points = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              !points.isEmpty, points.count.isMultiple(of: 28) else {
          return result(FlutterError(code: "missing_scan", message: "The boiler room scan is missing.", details: nil))
        }
        camera = WorldWalk(model: model, points: points)
      } else {
        camera = RouteCamera()
      }
      camera.modalPresentationStyle = .fullScreen
      host.present(camera, animated: true) { result(nil) }
    }
  }
}
