import Cocoa
import FlutterMacOS

/// The native half of spelling (Spec #392 requirements 5, 19, 20, 22): the
/// Edit ▸ Spelling and Grammar items and the `open_memex/spelling` channel
/// over `NSSpellChecker` (Dart side: `app/lib/src/state/spelling_service.dart`).
///
/// The kept menu items have no first-responder action in `MainMenu.xib`:
/// Flutter's hidden `FlutterTextInputPlugin` text view would catch
/// `checkSpelling:` and friends. This controller finds them by identifier and
/// targets itself instead.
///
/// Dart → native (a thin pass-through; all mapping is in Dart, lesson #347):
/// - `check{requestId, text, documentTag, spelling, grammar}`: checks off the
///   main thread and replies on it with
///   `{requestId, results: [{kind, start, length, description?, corrections?}]}`;
/// - `guesses{text, start, length, documentTag}` → `[String]`;
/// - `learn{word}`, `unlearn{word}`, `ignore{word, documentTag}` → nil;
/// - `documentTag{noteId}` → Int, one tag per note id;
/// - `closeDocumentTags` → nil, closes every tag;
/// - `setMenuState{checkSpelling, checkGrammar}` → nil.
/// Malformed arguments get a `bad_arguments` error; unknown methods are not
/// implemented.
///
/// Native → Dart: `menuToggle{item: checkSpelling|checkGrammar}` and
/// `checkDocumentNow`.
///
/// Offsets are UTF-16 code units: only `NSString` lengths and `NSRange`s.
class SpellingMenuController: NSObject, NSMenuItemValidation {
  private let channel: FlutterMethodChannel
  private let checker = NSSpellChecker.shared

  /// Note id → its spell document tag, until `closeDocumentTags`.
  private var documentTags: [String: Int] = [:]

  /// The settings Dart last sent with `setMenuState` (both on by default,
  /// Spec #392 requirement 19).
  private var checkSpelling = true
  private var checkGrammar = true

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "open_memex/spelling", binaryMessenger: binaryMessenger)
    super.init()
    checker.automaticallyIdentifiesLanguages = true
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    // MainFlutterWindow.awakeFromNib runs while MainMenu.xib is still
    // loading, so the main menu may not be installed yet.
    DispatchQueue.main.async { [weak self] in
      self?.attachMenuItems()
    }
  }

  // MARK: Dart → native

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "check":
      guard let requestId = args["requestId"] as? Int,
        let text = args["text"] as? String,
        let tag = args["documentTag"] as? Int,
        let spelling = args["spelling"] as? Bool,
        let grammar = args["grammar"] as? Bool
      else {
        result(badArguments("check expects {requestId, text, documentTag, spelling, grammar}"))
        return
      }
      check(
        requestId: requestId, text: text as NSString, tag: tag, spelling: spelling,
        grammar: grammar, result: result)
    case "guesses":
      guard let text = args["text"] as? String,
        let start = args["start"] as? Int,
        let length = args["length"] as? Int,
        let tag = args["documentTag"] as? Int
      else {
        result(badArguments("guesses expects {text, start, length, documentTag}"))
        return
      }
      let ns = text as NSString
      guard start >= 0, length >= 0, start <= ns.length, length <= ns.length,
        start + length <= ns.length
      else {
        result(badArguments("guesses range is outside the text"))
        return
      }
      let guesses =
        checker.guesses(
          forWordRange: NSRange(location: start, length: length), in: text, language: nil,
          inSpellDocumentWithTag: tag) ?? []
      result(guesses)
    case "learn":
      guard let word = args["word"] as? String else {
        result(badArguments("learn expects {word}"))
        return
      }
      checker.learnWord(word)
      result(nil)
    case "unlearn":
      guard let word = args["word"] as? String else {
        result(badArguments("unlearn expects {word}"))
        return
      }
      checker.unlearnWord(word)
      result(nil)
    case "ignore":
      guard let word = args["word"] as? String,
        let tag = args["documentTag"] as? Int
      else {
        result(badArguments("ignore expects {word, documentTag}"))
        return
      }
      checker.ignoreWord(word, inSpellDocumentWithTag: tag)
      result(nil)
    case "documentTag":
      guard let noteId = args["noteId"] as? String else {
        result(badArguments("documentTag expects {noteId}"))
        return
      }
      if let tag = documentTags[noteId] {
        result(tag)
        return
      }
      let tag = NSSpellChecker.uniqueSpellDocumentTag()
      documentTags[noteId] = tag
      result(tag)
    case "closeDocumentTags":
      for tag in documentTags.values {
        checker.closeSpellDocument(withTag: tag)
      }
      documentTags.removeAll()
      result(nil)
    case "setMenuState":
      guard let spelling = args["checkSpelling"] as? Bool,
        let grammar = args["checkGrammar"] as? Bool
      else {
        result(badArguments("setMenuState expects {checkSpelling, checkGrammar}"))
        return
      }
      checkSpelling = spelling
      checkGrammar = grammar
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Checks the whole [text] off the main thread and replies on it.
  private func check(
    requestId: Int, text: NSString, tag: Int, spelling: Bool, grammar: Bool,
    result: @escaping FlutterResult
  ) {
    var types: NSTextCheckingTypes = 0
    if spelling { types |= NSTextCheckingResult.CheckingType.spelling.rawValue }
    if grammar { types |= NSTextCheckingResult.CheckingType.grammar.rawValue }
    let whole = NSRange(location: 0, length: text.length)
    if types == 0 || whole.length == 0 {
      result(["requestId": requestId, "results": [[String: Any]]()])
      return
    }
    _ = checker.requestChecking(
      of: text as String, range: whole, types: types, options: nil,
      inSpellDocumentWithTag: tag,
      completionHandler: { _, checked, _, _ in
        var issues: [[String: Any]] = []
        for found in checked {
          if found.resultType == .spelling {
            issues.append([
              "kind": "spelling", "start": found.range.location, "length": found.range.length,
            ])
          } else if found.resultType == .grammar {
            for detail in found.grammarDetails ?? [] {
              guard let value = detail[NSGrammarRange] as? NSValue else { continue }
              let range = value.rangeValue
              var issue: [String: Any] = [
                "kind": "grammar", "start": found.range.location + range.location,
                "length": range.length,
              ]
              if let description = detail[NSGrammarUserDescription] as? String {
                issue["description"] = description
              }
              issue["corrections"] = detail[NSGrammarCorrections] as? [String] ?? []
              issues.append(issue)
            }
          }
        }
        DispatchQueue.main.async {
          result(["requestId": requestId, "results": issues])
        }
      })
  }

  private func badArguments(_ message: String) -> FlutterError {
    FlutterError(code: "bad_arguments", message: message, details: nil)
  }

  // MARK: Menu

  /// Points the three Spelling items, found by identifier, at this
  /// controller.
  private func attachMenuItems() {
    guard let menu = NSApp.mainMenu else { return }
    let actions: [String: Selector] = [
      "spelling-check-document": #selector(checkDocumentNow(_:)),
      "spelling-toggle-spelling": #selector(toggleSpelling(_:)),
      "spelling-toggle-grammar": #selector(toggleGrammar(_:)),
    ]
    attach(actions, in: menu)
  }

  private func attach(_ actions: [String: Selector], in menu: NSMenu) {
    for item in menu.items {
      if let id = item.identifier?.rawValue, let action = actions[id] {
        item.target = self
        item.action = action
      }
      if let submenu = item.submenu {
        attach(actions, in: submenu)
      }
    }
  }

  /// Edit ▸ Spelling and Grammar ▸ Check Document Now (⌘;).
  @objc func checkDocumentNow(_ sender: Any?) {
    channel.invokeMethod("checkDocumentNow", arguments: nil)
  }

  /// Check Spelling While Typing: Dart flips the setting and sends
  /// `setMenuState` back.
  @objc func toggleSpelling(_ sender: Any?) {
    channel.invokeMethod("menuToggle", arguments: ["item": "checkSpelling"])
  }

  /// Check Grammar With Spelling: as above, for grammar.
  @objc func toggleGrammar(_ sender: Any?) {
    channel.invokeMethod("menuToggle", arguments: ["item": "checkGrammar"])
  }

  /// Checkmarks follow the last `setMenuState`. The grammar item keeps its
  /// stored checkmark but is greyed out while spelling is off.
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(toggleSpelling(_:)) {
      menuItem.state = checkSpelling ? .on : .off
      return true
    }
    if menuItem.action == #selector(toggleGrammar(_:)) {
      menuItem.state = checkGrammar ? .on : .off
      return checkSpelling
    }
    return true
  }
}
