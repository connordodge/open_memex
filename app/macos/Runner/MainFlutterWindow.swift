import Cocoa
import FlutterMacOS

/// The app window. It is its own delegate so the red close button asks Dart
/// first (#103): `AppDelegate` terminates after the last window closes, and
/// Dart's `AppLifecycleListener.onExitRequested` only fires once the window
/// is already gone, so closing has to be held here.
///
/// Window channel `open_memex/window` (Dart side: `app/lib/src/state/app_exit.dart`):
/// - native → Dart `windowShouldClose`: Dart replies a bool, true to close.
/// - Dart → native `setTitle(String)`: sets the window title.
class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var windowChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "open_memex/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setTitle":
        guard let title = call.arguments as? String else {
          result(
            FlutterError(
              code: "bad_arguments", message: "setTitle expects a String", details: nil))
          return
        }
        self?.title = title
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    windowChannel = channel
    self.delegate = self

    super.awakeFromNib()
  }

  /// Never closes at once: asks Dart and closes only when Dart allows it.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let channel = windowChannel else { return true }
    channel.invokeMethod("windowShouldClose", arguments: nil) { [weak self] reply in
      guard let self = self, MainFlutterWindow.closeAllowed(by: reply) else { return }
      // `close()` skips `windowShouldClose`, so this does not ask again.
      self.close()
    }
    return false
  }

  /// Dart's reply to `windowShouldClose`, fail-safe:
  /// - a bool: Dart's decision;
  /// - not implemented (no Dart handler attached, so nothing is guarding):
  ///   close, or the window could never close;
  /// - an error or any other reply: keep the window open.
  private static func closeAllowed(by reply: Any?) -> Bool {
    if let allowed = reply as? Bool { return allowed }
    if let sentinel = reply as? NSObject, sentinel === FlutterMethodNotImplemented {
      return true
    }
    return false
  }
}
