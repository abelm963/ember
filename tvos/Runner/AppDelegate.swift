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
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EmberKeyboard") {
      let channel = FlutterMethodChannel(name: "ember/keyboard", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "edit", let args = call.arguments as? [String: Any] else {
          result(FlutterMethodNotImplemented)
          return
        }
        KeyboardEditor.present(args, result)
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EmberPlayer") {
      NativePlayer.shared.register(messenger: registrar.messenger())
    }
  }
}

/// Apple's own full-screen keyboard for one text box (`ember/keyboard` › `edit`), so dictation,
/// the iPhone's keyboard notification and password autofill all work. It runs on a native text
/// field and hands the text back, so focus never gets stuck in a Flutter text field.
final class KeyboardEditor: UIViewController, UITextFieldDelegate {
  private let field = UITextField()
  private var result: FlutterResult?
  private var submitted = false

  static func present(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let top = topViewController() else {
      result(nil)
      return
    }
    let vc = KeyboardEditor()
    vc.result = result
    vc.field.text = args["text"] as? String
    vc.field.placeholder = args["label"] as? String
    vc.field.isSecureTextEntry = args["obscure"] as? Bool ?? false
    vc.field.autocorrectionType = .no
    switch args["keyboard"] as? String {
    case "url":
      vc.field.keyboardType = .URL
      vc.field.autocapitalizationType = .none
    case "number":
      vc.field.keyboardType = .numberPad
    case "email":
      vc.field.keyboardType = .emailAddress
      vc.field.autocapitalizationType = .none
    default:
      vc.field.autocapitalizationType = .none
    }
    vc.modalPresentationStyle = .overFullScreen
    top.present(vc, animated: false)
  }

  private static func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }
      .first
    var top = window?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(white: 0, alpha: 0.85)
    field.delegate = self
    field.frame = CGRect(x: 160, y: 120, width: 1600, height: 80)
    field.borderStyle = .roundedRect
    view.addSubview(field)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if !field.becomeFirstResponder() { finish() }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    submitted = true
    textField.resignFirstResponder()
    return true
  }

  func textFieldDidEndEditing(_ textField: UITextField) { finish() }

  private func finish() {
    guard let result = result else { return }
    self.result = nil
    let text = field.text ?? ""
    let submitted = self.submitted
    dismiss(animated: false) { result(["text": text, "submitted": submitted]) }
  }
}
