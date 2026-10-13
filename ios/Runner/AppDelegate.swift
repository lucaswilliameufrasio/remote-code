import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
#if DEBUG
    let localPreviewChannel = FlutterMethodChannel(
      name: "remote_dev/local_preview",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    localPreviewChannel.setMethodCallHandler { call, result in
      guard call.method == "localSimulatorPassword" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(ProcessInfo.processInfo.environment["REMOTE_OPENCODE_SERVER_PASSWORD"])
    }
#endif
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
