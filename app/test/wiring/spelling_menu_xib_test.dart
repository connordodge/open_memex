// WI #433 (Spec #392 requirements 5, 19, 20, 22; rulings D17, D18): source
// contract for the native half of spelling: the Edit ▸ Spelling and Grammar
// submenu, `SpellingMenuController.swift` and its `open_memex/spelling`
// channel.
//
// XCTest isn't gated (lead ruling, 2026-11-11), so these tests read
// `MainMenu.xib`, `project.pbxproj` and the Swift sources as text and pin the
// wiring the Spec promises: the four kept menu items, their identifiers, no
// first-responder spelling actions, the controller compiled into Runner, every
// Dart→native method of requirement 22 with the argument keys of the Dart
// side (`app/lib/src/state/spelling_service.dart`), the native→Dart calls,
// UTF-16 NSRange offsets and the main-thread reply. They are text pins, not
// behaviour: real behaviour is the PR's MANUAL rows and `## Hand mutants`.
//
// Swift is read with `//` comments removed, so a doc comment never satisfies
// (or trips) a pin.
//
// `flutter test` runs with `app/` as the working directory, so the paths are
// relative to the app package root.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _xibPath = 'macos/Runner/Base.lproj/MainMenu.xib';
const _pbxprojPath = 'macos/Runner.xcodeproj/project.pbxproj';
const _controllerPath = 'macos/Runner/SpellingMenuController.swift';
const _windowPath = 'macos/Runner/MainFlutterWindow.swift';

/// The xib id of the `Spelling` submenu (under Edit ▸ Spelling and Grammar).
const _spellingMenuId = '3IN-sU-3Bg';

/// Requirement 22's Dart→native methods and the argument keys the Dart side
/// (`MethodChannelSpellingService`) sends for each.
const _dartToNative = <String, List<String>>{
  'check': ['requestId', 'text', 'documentTag', 'spelling', 'grammar'],
  'guesses': ['text', 'start', 'length', 'documentTag'],
  'learn': ['word'],
  'unlearn': ['word'],
  'ignore': ['word', 'documentTag'],
  'documentTag': ['noteId'],
  'closeDocumentTags': [],
  'setMenuState': ['checkSpelling', 'checkGrammar'],
};

String _read(String relative) {
  final f = File(relative);
  expect(f.existsSync(), isTrue, reason: '$relative exists under app/');
  return f.readAsStringSync();
}

/// [src] with every `//` comment removed (string literals are kept).
String _stripComments(String src) {
  final out = StringBuffer();
  var inString = false;
  for (var i = 0; i < src.length; i++) {
    final c = src[i];
    if (inString) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[++i]);
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      final nl = src.indexOf('\n', i);
      if (nl < 0) break;
      i = nl - 1;
      continue;
    }
    if (c == '"') inString = true;
    out.write(c);
  }
  return out.toString();
}

String _xib() => _read(_xibPath);
String _pbxproj() => _read(_pbxprojPath);
String _controller() => _stripComments(_read(_controllerPath));
String _window() => _stripComments(_read(_windowPath));

// ---------------------------------------------------------------- xib -----

Map<String, String> _attrs(String tagAttrs) => {
  for (final m in RegExp(r'([\w:]+)="([^"]*)"').allMatches(tagAttrs))
    m.group(1)!: m.group(2)!,
};

/// One `<menuItem>` of a menu: its attributes and inner XML.
class _SpellingMenuItem433 {
  _SpellingMenuItem433(this.attrs, this.inner);
  final Map<String, String> attrs;
  final String inner;

  String? get title => attrs['title'];
  bool get isSeparator => attrs['isSeparatorItem'] == 'YES';

  /// The attributes of the `keyEquivalentModifierMask` element, or null.
  Map<String, String>? get modifierMask {
    final m = RegExp(
      r'<modifierMask\b([^>]*key="keyEquivalentModifierMask"[^>]*)/?>',
    ).firstMatch(inner);
    return m == null ? null : _attrs(m.group(1)!);
  }

  /// The attributes of every `<action …/>` connection.
  List<Map<String, String>> get actions => [
    for (final m in RegExp(r'<action\b([^>]*)/>').allMatches(inner))
      _attrs(m.group(1)!),
  ];
}

/// The inner XML of the `Spelling` submenu (it has no nested menus).
String _spellingMenu(String xib) {
  final start = RegExp(
    '<menu\\b[^>]*\\bid="$_spellingMenuId"[^>]*>',
  ).firstMatch(xib);
  expect(
    start,
    isNotNull,
    reason: 'the Spelling submenu ($_spellingMenuId) exists',
  );
  expect(start!.group(0), contains('key="submenu"'));
  expect(start.group(0), contains('title="Spelling"'));
  final end = xib.indexOf('</menu>', start.end);
  expect(end, greaterThan(start.end), reason: 'the Spelling submenu is closed');
  final inner = xib.substring(start.end, end);
  expect(
    inner,
    isNot(contains('<menu ')),
    reason: 'the Spelling submenu has no nested menu',
  );
  return inner;
}

List<_SpellingMenuItem433> _items(String menuXml) => [
  for (final m in RegExp(
    r'<menuItem\b([^>]*?)(?:/>|>([\s\S]*?)</menuItem>)',
  ).allMatches(menuXml))
    _SpellingMenuItem433(_attrs(m.group(1)!), m.group(2) ?? ''),
];

/// Every element in [xml] is closed in order (a cheap well-formedness check,
/// since the app has no XML parser dependency).
void _expectBalanced(String xml) {
  final stack = <String>[];
  for (final m in RegExp(
    r'<(/?)([A-Za-z][\w.:-]*)\b[^>]*?(/?)>',
  ).allMatches(xml)) {
    final closing = m.group(1) == '/';
    final name = m.group(2)!;
    final selfClosing = m.group(3) == '/';
    if (selfClosing) continue;
    if (closing) {
      expect(
        stack,
        isNotEmpty,
        reason: 'unexpected </$name> at offset ${m.start} of $_xibPath',
      );
      expect(
        stack.removeLast(),
        name,
        reason: '</$name> at offset ${m.start} closes the open element',
      );
    } else {
      stack.add(name);
    }
  }
  expect(stack, isEmpty, reason: 'every element of $_xibPath is closed');
}

List<String> _xibIds(String xib) =>
    RegExp(r'\sid="([^"]+)"').allMatches(xib).map((m) => m.group(1)!).toList();

// ------------------------------------------------------------ pbxproj -----

final _pbxId = RegExp(r'^[0-9A-F]{24}$');

/// The `files = ( … );` or `children = ( … );` entries of the object whose
/// list contains [member]: each entry's id and comment.
List<({String id, String comment})> _listContaining(
  String pbx,
  String listKey,
  String member,
) {
  for (final m in RegExp('$listKey = \\(([\\s\\S]*?)\\);').allMatches(pbx)) {
    final body = m.group(1)!;
    if (!body.contains(member)) continue;
    return [
      for (final e in RegExp(
        r'([0-9A-Fa-f]{24}) /\* ([^*]+?) \*/,',
      ).allMatches(body))
        (id: e.group(1)!, comment: e.group(2)!),
    ];
  }
  fail('no "$listKey" list in $_pbxprojPath contains "$member"');
}

/// The id of the one PBXFileReference for [path].
String _fileRefId(String pbx, String path) {
  final refs = RegExp(
    r'([0-9A-Fa-f]{24}) /\* ' +
        RegExp.escape(path) +
        r' \*/ = \{isa = PBXFileReference;([^}]*)\};',
  ).allMatches(pbx).toList();
  expect(refs, hasLength(1), reason: 'one PBXFileReference for $path');
  return refs.single.group(1)!;
}

// -------------------------------------------------------------- Swift -----

/// The text inside the bracket pair that opens at [open] (`{` or `(`).
/// String literals are skipped so their brackets don't count.
String _bracketBody(String src, int open, String path) {
  expect(open, isNonNegative, reason: 'a bracket opens in $path');
  final o = src[open];
  expect(o, anyOf('{', '('));
  final cl = o == '{' ? '}' : ')';
  var depth = 0;
  var inString = false;
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    if (inString) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == o) {
      depth++;
    } else if (c == cl) {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  fail('unbalanced "$o" from offset $open in $path');
}

String _braceBody(String src, int open, String path) =>
    _bracketBody(src, open, path);

/// The body of the function whose declaration matches [decl].
String _funcBody(String src, RegExp decl, String path) {
  final m = decl.firstMatch(src);
  expect(m, isNotNull, reason: '$path declares ${decl.pattern}');
  return _braceBody(src, src.indexOf('{', m!.end), path);
}

/// [code] plus the bodies of the functions it calls that [src] declares,
/// followed up to three calls deep. A case may hand its work to a helper
/// (`case "check": check(call, result)`), so pins read the whole path.
String _reachable(String src, String code) {
  final seen = <String>{};
  final out = StringBuffer(code);
  var frontier = [code];
  for (var depth = 0; depth < 3 && frontier.isNotEmpty; depth++) {
    final next = <String>[];
    for (final text in frontier) {
      for (final m in RegExp(r'\b(\w+)\s*\(').allMatches(text)) {
        final name = m.group(1)!;
        if (!seen.add(name)) continue;
        final decl = RegExp(r'\bfunc\s+' + name + r'\s*[(<]');
        if (!decl.hasMatch(src)) continue;
        final body = _funcBody(src, decl, _controllerPath);
        out.write('\n$body');
        next.add(body);
      }
    }
    frontier = next;
  }
  return out.toString();
}

/// The controller's `switch call.method { … }` and the helpers it calls.
String _handler(String src) {
  final switches = RegExp(r'switch\s+\w+\.method\s*\{').allMatches(src);
  expect(
    switches,
    hasLength(1),
    reason: '$_controllerPath dispatches on the call method once',
  );
  final s = switches.single;
  return _reachable(src, _braceBody(src, s.end - 1, _controllerPath));
}

/// The body of `case "<method>":` in [handler], up to the next `case` or
/// `default:` of the same switch (nested braces are skipped).
String _case(String handler, String method) {
  final label = 'case "$method":';
  final start = handler.indexOf(label);
  expect(
    start,
    isNonNegative,
    reason: 'the spelling handler has case "$method":\n$handler',
  );
  final boundary = RegExp(r'\n\s*(?:case\s|default\s*:|@unknown\s)');
  var depth = 0;
  var inString = false;
  for (var i = start + label.length; i < handler.length; i++) {
    final c = handler[i];
    if (inString) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      if (depth == 0) return handler.substring(start, i);
      depth--;
    } else if (c == '\n' && depth == 0) {
      if (boundary.matchAsPrefix(handler, i) != null) {
        return handler.substring(start, i);
      }
    }
  }
  return handler.substring(start);
}

/// The code a Dart→native [method] runs: its case plus its helpers.
String _methodCode(String src, String method) =>
    _reachable(src, _case(_handler(src), method));

/// The stored `Bool` properties of the controller with an initial value.
List<String> _boolProps(String src) => [
  for (final m in RegExp(
    r'\bvar\s+(\w+)\s*(?::\s*Bool\s*)?=\s*(?:true|false)\b',
  ).allMatches(src))
    m.group(1)!,
];

/// The stored `Bool` properties that `setMenuState` assigns.
List<String> _menuStateProps(String src) {
  final code = _methodCode(src, 'setMenuState');
  return [
    for (final p in _boolProps(src))
      if (RegExp(r'\b' + p + r'\s*=[^=]').hasMatch(code)) p,
  ];
}

String _validateMenuItemBody(String src) => _funcBody(
  src,
  RegExp(
    r'func\s+validateMenuItem\(\s*_\s+\w+\s*:\s*NSMenuItem\s*\)\s*->\s*Bool',
  ),
  _controllerPath,
);

/// The `[String: Int]` dictionary property that caches document tags.
String _tagCacheName(String src) {
  final m = RegExp(
    r'\bvar\s+(\w+)\s*(?::\s*\[\s*String\s*:\s*Int\s*\]\s*=\s*\[\s*:\s*\]|=\s*\[\s*String\s*:\s*Int\s*\]\(\s*\))',
  ).firstMatch(src);
  expect(
    m,
    isNotNull,
    reason: '$_controllerPath keeps a [String: Int] note id → tag cache',
  );
  return m!.group(1)!;
}

void main() {
  group('MainMenu.xib Spelling submenu', () {
    test(
      'Spelling submenu holds Check Document Now (⌘;), a separator, Check Spelling While Typing and Check Grammar With Spelling, in order',
      () {
        final xib = _xib();
        _expectBalanced(xib);
        final parent = RegExp(
          r'<menuItem\b[^>]*title="Spelling and Grammar"[^>]*>\s*'
          r'(?:<modifierMask[^>]*/>\s*)?'
          '<menu\\b[^>]*id="$_spellingMenuId"',
        );
        expect(
          parent.hasMatch(xib),
          isTrue,
          reason:
              'Edit ▸ Spelling and Grammar still opens the Spelling submenu',
        );
        final items = _items(_spellingMenu(xib));
        expect(items.map((i) => i.isSeparator ? '---' : i.title).toList(), [
          'Check Document Now',
          '---',
          'Check Spelling While Typing',
          'Check Grammar With Spelling',
        ]);

        // Check Document Now keeps the Cocoa template's ⌘; [L4]. No mask
        // element means ⌘ alone.
        final check = items.first;
        expect(check.attrs['keyEquivalent'], ';');
        final mask = check.modifierMask;
        if (mask != null) {
          expect(mask['command'], 'YES');
          expect(mask['shift'], isNot('YES'));
          expect(mask['option'], isNot('YES'));
          expect(mask['control'], isNot('YES'));
        }
        // The two toggles have no key equivalent.
        for (final item in items.skip(2)) {
          expect(
            item.attrs['keyEquivalent'] ?? '',
            isEmpty,
            reason: '${item.title} has no key equivalent',
          );
        }
      },
    );

    test('each kept Spelling item carries its spelling-* identifier', () {
      final xib = _xib();
      final items = _items(_spellingMenu(xib));
      final byTitle = {for (final i in items) i.title: i.attrs['identifier']};
      expect(byTitle['Check Document Now'], 'spelling-check-document');
      expect(
        byTitle['Check Spelling While Typing'],
        'spelling-toggle-spelling',
      );
      expect(byTitle['Check Grammar With Spelling'], 'spelling-toggle-grammar');
      for (final id in [
        'spelling-check-document',
        'spelling-toggle-spelling',
        'spelling-toggle-grammar',
      ]) {
        expect(
          RegExp('identifier="$id"').allMatches(xib),
          hasLength(1),
          reason: 'identifier $id is used once in the whole menu bar',
        );
      }
      final ids = _xibIds(xib);
      expect(
        ids.toSet(),
        hasLength(ids.length),
        reason: 'every xib object id stays unique',
      );
    });

    test(
      'Show Spelling and Grammar and Correct Spelling Automatically are gone',
      () {
        final xib = _xib();
        for (final title in [
          'Show Spelling and Grammar',
          'Correct Spelling Automatically',
        ]) {
          expect(xib, isNot(contains('title="$title"')));
        }
        for (final selector in [
          'showGuessPanel:',
          'toggleAutomaticSpellingCorrection:',
        ]) {
          expect(xib, isNot(contains('selector="$selector"')));
        }
        // The template's item and action ids go with them.
        final ids = _xibIds(xib);
        for (final id in [
          'HFo-cy-zxI',
          'vFj-Ks-hy3',
          '78Y-hA-62v',
          '2lM-Qi-WAP',
        ]) {
          expect(
            ids,
            isNot(contains(id)),
            reason: 'template id $id is removed',
          );
        }
      },
    );

    test(
      'no Spelling submenu item uses a first-responder target="-1" spelling action',
      () {
        final xib = _xib();
        final menu = _spellingMenu(xib);
        expect(
          menu,
          isNot(contains('target="-1"')),
          reason:
              "Flutter's hidden FlutterTextInputPlugin view would catch a "
              'nil-targeted action',
        );
        for (final item in _items(menu)) {
          expect(
            item.actions.where((a) => a['target'] == '-1'),
            isEmpty,
            reason: '${item.title} has no first-responder action',
          );
        }
        for (final selector in [
          'checkSpelling:',
          'toggleContinuousSpellChecking:',
          'toggleGrammarChecking:',
          'showGuessPanel:',
          'toggleAutomaticSpellingCorrection:',
        ]) {
          expect(
            xib,
            isNot(contains('selector="$selector"')),
            reason:
                'no menu item anywhere sends $selector to the first responder',
          );
        }
      },
    );
  });

  group('project.pbxproj', () {
    test(
      'project.pbxproj declares SpellingMenuController.swift as a Swift source file',
      () {
        final pbx = _pbxproj();
        final ref = RegExp(
          r'([0-9A-Fa-f]{24}) /\* SpellingMenuController\.swift \*/ = '
          r'\{isa = PBXFileReference;([^}]*)\};',
        ).firstMatch(pbx);
        expect(
          ref,
          isNotNull,
          reason: 'a PBXFileReference for SpellingMenuController.swift',
        );
        expect(ref!.group(1), matches(_pbxId));
        final attrs = ref.group(2)!;
        expect(attrs, contains('lastKnownFileType = sourcecode.swift;'));
        expect(attrs, contains('path = SpellingMenuController.swift;'));
        expect(attrs, contains('sourceTree = "<group>";'));
      },
    );

    test(
      'project.pbxproj lists SpellingMenuController.swift in the Runner group',
      () {
        final pbx = _pbxproj();
        final refId = _fileRefId(pbx, 'SpellingMenuController.swift');
        final group = _listContaining(
          pbx,
          'children',
          '/* MainFlutterWindow.swift */',
        );
        expect(
          group.where((e) => e.comment == 'SpellingMenuController.swift'),
          [(id: refId, comment: 'SpellingMenuController.swift')],
          reason:
              'the Runner group (beside MainFlutterWindow.swift) has it once',
        );
        expect(
          RegExp(r'\b' + refId + r'\b').allMatches(pbx),
          hasLength(3),
          reason:
              'the file reference id is used by its definition, the Runner '
              'group and its build file, nothing else',
        );
      },
    );

    test(
      'project.pbxproj compiles SpellingMenuController.swift in the Runner Sources build phase',
      () {
        final pbx = _pbxproj();
        final refId = _fileRefId(pbx, 'SpellingMenuController.swift');
        final builds = RegExp(
          r'([0-9A-Fa-f]{24}) /\* SpellingMenuController\.swift in Sources \*/ = '
          r'\{isa = PBXBuildFile; fileRef = ([0-9A-Fa-f]{24}) /\* SpellingMenuController\.swift \*/; \};',
        ).allMatches(pbx).toList();
        expect(builds, hasLength(1), reason: 'one PBXBuildFile for it');
        final buildId = builds.single.group(1)!;
        expect(buildId, matches(_pbxId));
        expect(builds.single.group(2), refId, reason: 'it builds that file');
        expect(buildId, isNot(refId));

        // Runner's Sources phase is the one that compiles MainFlutterWindow.
        final runnerSources = _listContaining(
          pbx,
          'files',
          '/* MainFlutterWindow.swift in Sources */',
        );
        expect(
          runnerSources.where(
            (e) => e.comment == 'SpellingMenuController.swift in Sources',
          ),
          [(id: buildId, comment: 'SpellingMenuController.swift in Sources')],
        );
        // Not the RunnerTests target.
        final testSources = _listContaining(
          pbx,
          'files',
          '/* RunnerTests.swift in Sources */',
        );
        expect(
          testSources.map((e) => e.comment),
          isNot(contains('SpellingMenuController.swift in Sources')),
        );
        expect(
          RegExp(r'\b' + buildId + r'\b').allMatches(pbx),
          hasLength(2),
          reason: 'the build file id is used by its definition and the phase',
        );
      },
    );
  });

  group('SpellingMenuController.swift', () {
    test('SpellingMenuController is an NSObject that validates menu items', () {
      final src = _controller();
      expect(src, contains('import Cocoa'));
      expect(src, contains('import FlutterMacOS'));
      final decl = RegExp(
        r'\bclass\s+SpellingMenuController\s*:\s*NSObject\s*,([^{]*)\{',
      ).firstMatch(src);
      expect(
        decl,
        isNotNull,
        reason: 'class SpellingMenuController: NSObject, NSMenuItemValidation',
      );
      expect(
        decl!.group(1)!.split(',').map((s) => s.trim()),
        contains('NSMenuItemValidation'),
      );
      _validateMenuItemBody(src);
    });

    test(
      'SpellingMenuController registers the open_memex/spelling method channel',
      () {
        final src = _controller();
        expect(
          src,
          matches(
            RegExp(
              r'FlutterMethodChannel\(\s*name:\s*"open_memex/spelling"\s*,\s*binaryMessenger:',
            ),
          ),
        );
        expect(
          RegExp('"open_memex/spelling"').allMatches(src),
          hasLength(1),
          reason: 'one channel',
        );
        expect(src, contains('setMethodCallHandler'));
      },
    );

    for (final (name, method) in [
      (
        'check reads requestId, text, documentTag, spelling and grammar',
        'check',
      ),
      ('guesses reads text, start, length and documentTag', 'guesses'),
      ('learn reads word', 'learn'),
      ('unlearn reads word', 'unlearn'),
      ('ignore reads word and documentTag', 'ignore'),
      ('documentTag reads noteId', 'documentTag'),
      ('closeDocumentTags takes no arguments and replies', 'closeDocumentTags'),
      ('setMenuState reads checkSpelling and checkGrammar', 'setMenuState'),
    ]) {
      test(name, () {
        final src = _controller();
        final code = _methodCode(src, method);
        final keys = _dartToNative[method]!;
        for (final key in keys) {
          expect(
            code,
            matches(RegExp(r'\[\s*"' + key + r'"\s*\]')),
            reason: '$method reads the "$key" argument E1 sends:\n$code',
          );
          expect(
            code,
            isNot(matches(RegExp(r'\[\s*"' + key + r'"\s*\]\s*as!'))),
            reason: '$method never force-casts "$key" (a crash, not an error)',
          );
        }
        expect(
          code,
          contains('result('),
          reason: '$method always replies to Dart:\n$code',
        );
        if (keys.isNotEmpty) {
          expect(
            code,
            contains('FlutterError('),
            reason: '$method answers malformed arguments with a FlutterError',
          );
          expect(code, isNot(matches(RegExp(r'\barguments\s+as!'))));
        }
      });
    }

    test(
      'unknown methods reply FlutterMethodNotImplemented and errors carry code and message only',
      () {
        final src = _controller();
        expect(
          _handler(src),
          matches(
            RegExp(
              r'default\s*:\s*result\(\s*FlutterMethodNotImplemented\s*\)',
            ),
          ),
        );
        final errors = RegExp(r'FlutterError\(').allMatches(src).toList();
        expect(errors, isNotEmpty);
        for (final e in errors) {
          final args = _bracketBody(src, e.end - 1, _controllerPath);
          expect(
            args,
            matches(
              RegExp(
                r'^\s*code:\s*"[a-z_]+"\s*,\s*message:[\s\S]*,\s*details:\s*nil\s*$',
              ),
            ),
            reason:
                'FlutterError(code:message:details: nil); mapping is in Dart '
                '(lesson #347): FlutterError($args)',
          );
        }
      },
    );

    test(
      'check runs requestChecking off the main thread in the note document',
      () {
        final code = _methodCode(_controller(), 'check');
        final call = RegExp(
          r'requestChecking\(\s*of:[\s\S]*?range:[\s\S]*?types:[\s\S]*?options:'
          r'[\s\S]*?inSpellDocumentWithTag:'
          r'(?:[\s\S]*?completionHandler:|[^)]*\)\s*\{)',
        );
        expect(
          call.hasMatch(code),
          isTrue,
          reason:
              'NSSpellChecker.requestChecking(of:range:types:options:'
              'inSpellDocumentWithTag:completionHandler:):\n$code',
        );
        // Checking types follow the spelling and grammar flags.
        expect(
          code,
          matches(RegExp(r'CheckingType\.spelling|\.spelling\.rawValue')),
        );
        expect(
          code,
          matches(RegExp(r'CheckingType\.grammar|\.grammar\.rawValue')),
        );
        expect(
          code,
          isNot(matches(RegExp(r'\.check(?:String|Spelling|Grammar)\('))),
          reason: 'never a synchronous main-thread check',
        );
      },
    );

    test('check replies on the main thread with requestId and results', () {
      final code = _methodCode(_controller(), 'check');
      final main = code.indexOf('DispatchQueue.main.async');
      expect(
        main,
        isNonNegative,
        reason: 'the completion handler hops back to the main thread:\n$code',
      );
      final mainBody = _braceBody(
        code,
        code.indexOf('{', main),
        _controllerPath,
      );
      expect(
        mainBody,
        contains('result('),
        reason: 'the reply is sent inside DispatchQueue.main.async',
      );
      expect(code, matches(RegExp(r'"requestId"\s*:')));
      expect(code, matches(RegExp(r'"results"\s*:')));
    });

    test(
      'check maps spelling and grammar results to kind, start, length, description and corrections',
      () {
        final code = _methodCode(_controller(), 'check');
        for (final key in [
          'kind',
          'start',
          'length',
          'description',
          'corrections',
        ]) {
          expect(
            code,
            // A dictionary literal key or a subscript store.
            matches(RegExp('"$key"\\s*(?::|\\]\\s*=[^=])')),
            reason: 'a result entry has "$key"',
          );
        }
        // The kind values, apart from the "spelling"/"grammar" argument reads.
        final kinds = code.replaceAll(
          RegExp(r'\[\s*"(?:spelling|grammar)"\s*\]'),
          '',
        );
        expect(kinds, contains('"spelling"'));
        expect(kinds, contains('"grammar"'));
        // One grammar result per grammarDetails entry, offset by the result's
        // own range, with its description and corrections.
        expect(code, contains('grammarDetails'));
        expect(code, contains('NSGrammarRange'));
        expect(code, contains('NSGrammarUserDescription'));
        expect(code, contains('NSGrammarCorrections'));
        expect(
          code,
          matches(RegExp(r'\.location\s*\+|\+\s*[\w.?!]*\.location\b')),
          reason: 'a grammar detail range is offset by the result range',
        );
      },
    );

    test(
      'offsets stay UTF-16: NSString and NSRange only, never String.Index or Character',
      () {
        final src = _controller();
        expect(src, contains('NSString'));
        expect(src, matches(RegExp(r'NSRange\b|NSMakeRange\(')));
        expect(
          _methodCode(src, 'check'),
          contains('.length'),
          reason: 'the whole-text range is the NSString length',
        );
        for (final banned in [
          'String.Index',
          'Character',
          'startIndex',
          'endIndex',
          '.index(',
          'distance(from:',
          '.utf8',
          'unicodeScalars',
          'Range<',
          'NSRange(range',
        ]) {
          expect(
            src,
            isNot(contains(banned)),
            reason: 'offsets are UTF-16 code units: no $banned (req 22)',
          );
        }
        expect(
          src,
          isNot(matches(RegExp(r'\b(?:text|word|string|str)\.count\b'))),
          reason: "a Swift String's count is in Characters, not UTF-16 units",
        );
      },
    );

    test('NSSpellChecker identifies languages automatically', () {
      expect(
        _controller(),
        matches(RegExp(r'\.automaticallyIdentifiesLanguages\s*=\s*true\b')),
      );
    });

    test(
      'guesses asks NSSpellChecker for the UTF-16 word range in the note document',
      () {
        final code = _methodCode(_controller(), 'guesses');
        expect(
          code,
          matches(
            RegExp(
              r'guesses\(\s*forWordRange:[\s\S]*?in:[\s\S]*?language:'
              r'[\s\S]*?inSpellDocumentWithTag:',
            ),
          ),
        );
        expect(code, matches(RegExp(r'NSRange\(\s*location:|NSMakeRange\(')));
      },
    );

    test('learn and unlearn teach and forget the word in NSSpellChecker', () {
      final src = _controller();
      expect(_methodCode(src, 'learn'), matches(RegExp(r'\.learnWord\(')));
      expect(_methodCode(src, 'unlearn'), matches(RegExp(r'\.unlearnWord\(')));
    });

    test('ignore ignores the word in the note document tag', () {
      expect(
        _methodCode(_controller(), 'ignore'),
        matches(RegExp(r'\.ignoreWord\([\s\S]*?inSpellDocumentWithTag:')),
      );
    });

    test(
      'documentTag opens one uniqueSpellDocumentTag per note id and reuses it',
      () {
        final src = _controller();
        final cache = _tagCacheName(src);
        final code = _methodCode(src, 'documentTag');
        final unique = code.indexOf('uniqueSpellDocumentTag()');
        expect(
          unique,
          isNonNegative,
          reason: 'a new tag comes from NSSpellChecker',
        );
        final lookup = RegExp(r'\b' + cache + r'\s*\[').firstMatch(code);
        expect(lookup, isNotNull, reason: 'the cache is read');
        expect(
          lookup!.start,
          lessThan(unique),
          reason: 'the cache is consulted before opening a new tag',
        );
        expect(
          code,
          matches(RegExp(r'\b' + cache + r'\s*\[[^\]]+\]\s*=[^=]')),
          reason: 'a new tag is stored for the note id',
        );
      },
    );

    test('closeDocumentTags closes every tag and clears the cache', () {
      final src = _controller();
      final cache = _tagCacheName(src);
      final code = _methodCode(src, 'closeDocumentTags');
      final close = code.indexOf('closeSpellDocument(withTag:');
      expect(close, isNonNegative);
      expect(
        code,
        matches(
          RegExp(
            r'\bfor\s[^{]*\bin\s+(?:self\??\.)?' +
                cache +
                r'\b|\b' +
                cache +
                r'(?:\.values|\.keys)?\.forEach\b',
          ),
        ),
        reason: 'every cached tag is closed',
      );
      final clear = RegExp(
        r'\b' + cache + r'(?:\.removeAll\(|\s*=\s*\[\s*:\s*\])',
      ).firstMatch(code);
      expect(clear, isNotNull, reason: 'the cache is cleared');
      expect(
        clear!.start,
        greaterThan(close),
        reason: 'after closing the tags',
      );
      expect(code, contains('result(nil)'));
    });

    test(
      'setMenuState stores checkSpelling and checkGrammar for validateMenuItem',
      () {
        final src = _controller();
        final props = _menuStateProps(src);
        expect(
          props,
          hasLength(2),
          reason:
              'setMenuState sets two stored Bool properties: ${_boolProps(src)}',
        );
        final validate = _validateMenuItemBody(src);
        for (final p in props) {
          expect(
            validate,
            matches(RegExp(r'\b' + p + r'\b')),
            reason: 'validateMenuItem reads $p',
          );
        }
        expect(_methodCode(src, 'setMenuState'), contains('result(nil)'));
      },
    );

    test(
      'validateMenuItem sets checkmarks and greys out grammar while spelling is off',
      () {
        final src = _controller();
        final validate = _validateMenuItemBody(src);
        expect(validate, contains('.state'), reason: 'it sets checkmarks');
        expect(validate, contains('.on'));
        expect(validate, contains('.off'));
        final spelling = _menuStateProps(
          src,
        ).where((p) => p.toLowerCase().contains('spelling'));
        expect(
          spelling,
          hasLength(1),
          reason: 'one stored flag names the spelling setting',
        );
        final returns = RegExp(
          r'\breturn\b([^\n;}]*)',
        ).allMatches(validate).map((m) => m.group(1)!.trim()).toList();
        expect(
          returns.where(
            (r) => RegExp(r'\b' + spelling.single + r'\b').hasMatch(r),
          ),
          isNotEmpty,
          reason:
              'the grammar item is enabled only while spelling is on:\n$validate',
        );
      },
    );

    test('the menu items send checkDocumentNow and menuToggle to Dart', () {
      final src = _controller();
      final objc = [
        for (final m in RegExp(
          r'@objc\b[^{]*?\bfunc\s+\w+\s*\([^)]*\)',
        ).allMatches(src))
          _braceBody(src, src.indexOf('{', m.end), _controllerPath),
      ];
      expect(objc, hasLength(greaterThanOrEqualTo(3)));
      for (final send in [
        RegExp(
          r'invokeMethod\(\s*"checkDocumentNow"\s*,\s*arguments:\s*nil\s*\)',
        ),
        RegExp(
          r'invokeMethod\(\s*"menuToggle"\s*,\s*arguments:\s*\[\s*"item"\s*:\s*"checkSpelling"\s*\]\s*\)',
        ),
        RegExp(
          r'invokeMethod\(\s*"menuToggle"\s*,\s*arguments:\s*\[\s*"item"\s*:\s*"checkGrammar"\s*\]\s*\)',
        ),
      ]) {
        expect(
          objc.where(send.hasMatch),
          hasLength(1),
          reason: 'one @objc menu action sends ${send.pattern}',
        );
      }
    });

    test(
      'the controller finds the three items by identifier and targets itself',
      () {
        final src = _controller();
        for (final id in [
          'spelling-check-document',
          'spelling-toggle-spelling',
          'spelling-toggle-grammar',
        ]) {
          expect(src, contains('"$id"'), reason: 'it looks up $id');
        }
        expect(src, contains('mainMenu'), reason: 'it searches the main menu');
        expect(src, matches(RegExp(r'\.target\s*=\s*self\b')));
        expect(src, matches(RegExp(r'\.action\s*=')));
        expect(
          RegExp(r'#selector\(').allMatches(src).length,
          greaterThanOrEqualTo(3),
          reason: "each item gets one of the controller's own actions",
        );
      },
    );
  });

  // Contracts the controller's doc comments promise that the AC-level pins
  // above leave open (verify mode): the defaults, the guesses range guard,
  // which setting feeds which checkmark, the cache-hit reply and the menu
  // attach timing.
  group('SpellingMenuController.swift documented contracts', () {
    /// The @objc menu actions: function name → body.
    Map<String, String> objcActions(String src) => {
      for (final m in RegExp(
        r'@objc\b[^{]*?\bfunc\s+(\w+)\s*\([^)]*\)',
      ).allMatches(src))
        m.group(1)!: _braceBody(src, src.indexOf('{', m.end), _controllerPath),
    };

    test(
      'checkSpelling and checkGrammar are both on until setMenuState says otherwise',
      () {
        final src = _controller();
        final props = _menuStateProps(src);
        expect(props, hasLength(2));
        for (final p in props) {
          expect(
            src,
            matches(RegExp(r'\bvar\s+' + p + r'\s*(?::\s*Bool\s*)?=\s*true\b')),
            reason: '$p starts true (Spec #392 requirement 19)',
          );
        }
      },
    );

    test(
      'only setMenuState changes the stored spelling and grammar settings',
      () {
        final src = _controller();
        for (final p in _menuStateProps(src)) {
          // The initializer and the one assignment in setMenuState.
          expect(
            RegExp(r'\b' + p + r'\s*=[^=]').allMatches(src),
            hasLength(2),
            reason: '$p is only ever set by its initializer and setMenuState',
          );
          expect(
            _methodCode(src, 'setMenuState'),
            matches(RegExp(r'\b' + p + r'\s*=[^=]')),
          );
        }
      },
    );

    test(
      'validateMenuItem ties each checkmark to its own setting and greys out only the grammar item',
      () {
        final src = _controller();
        final validate = _validateMenuItemBody(src);
        final props = _menuStateProps(src);
        final spelling = props.singleWhere(
          (p) => p.toLowerCase().contains('spelling'),
        );
        final grammar = props.singleWhere(
          (p) => p.toLowerCase().contains('grammar'),
        );
        final actions = objcActions(src);
        String actionSending(String item) => actions.entries
            .singleWhere(
              (e) => RegExp(
                r'\[\s*"item"\s*:\s*"' + item + r'"\s*\]',
              ).hasMatch(e.value),
            )
            .key;
        final spellingAction = actionSending('checkSpelling');
        final grammarAction = actionSending('checkGrammar');
        final branches = {
          for (final m in RegExp(
            r'\bif\s+\w+\.action\s*==\s*#selector\(\s*(\w+)\s*\(',
          ).allMatches(validate))
            m.group(1)!: _braceBody(
              validate,
              validate.indexOf('{', m.end),
              _controllerPath,
            ),
        };
        expect(
          branches.keys,
          unorderedEquals([spellingAction, grammarAction]),
          reason: 'validateMenuItem handles exactly the two toggle actions',
        );

        final spellingBranch = branches[spellingAction]!;
        expect(
          spellingBranch,
          matches(
            RegExp(r'\.state\s*=\s*' + spelling + r'\s*\?\s*\.on\s*:\s*\.off'),
          ),
          reason: 'the spelling checkmark follows the spelling setting',
        );
        expect(
          spellingBranch,
          matches(RegExp(r'\breturn\s+true\b')),
          reason: 'Check Spelling While Typing is always enabled',
        );

        final grammarBranch = branches[grammarAction]!;
        expect(
          grammarBranch,
          matches(
            RegExp(r'\.state\s*=\s*' + grammar + r'\s*\?\s*\.on\s*:\s*\.off'),
          ),
          reason: 'the grammar checkmark follows the grammar setting',
        );
        expect(
          grammarBranch,
          matches(RegExp(r'\breturn\s+' + spelling + r'\b(?!\s*[&|?])')),
          reason:
              'Check Grammar With Spelling is enabled only while spelling is on',
        );
        expect(grammarBranch, isNot(matches(RegExp(r'\breturn\s+true\b'))));

        expect(
          validate.trimRight(),
          endsWith('return true'),
          reason: 'any other item stays enabled',
        );
      },
    );

    test(
      'guesses rejects a range outside the text with an error before asking NSSpellChecker',
      () {
        final code = _methodCode(_controller(), 'guesses');
        final call = code.indexOf('.guesses(');
        expect(call, isNonNegative);
        final before = code.substring(0, call);
        expect(
          before,
          matches(RegExp(r'\bstart\s*>=\s*0')),
          reason: 'a negative start is refused',
        );
        expect(
          before,
          matches(RegExp(r'\blength\s*>=\s*0')),
          reason: 'a negative length is refused',
        );
        expect(
          before,
          matches(RegExp(r'\bstart\s*\+\s*length\s*<=\s*\w+\.length')),
          reason: 'the range must fit the NSString length (UTF-16 units)',
        );
        // One guard for the arguments, one for the range, each replying with
        // an error and returning.
        expect(RegExp(r'\bguard\b').allMatches(before), hasLength(2));
        expect(RegExp(r'badArguments\(').allMatches(before), hasLength(2));
        expect(RegExp(r'\breturn\b').allMatches(before), hasLength(2));
      },
    );

    test('documentTag replies from the cache without opening a new tag', () {
      final src = _controller();
      final cache = _tagCacheName(src);
      final code = _methodCode(src, 'documentTag');
      final lookup = RegExp(r'\b' + cache + r'\s*\[').firstMatch(code)!;
      final unique = code.indexOf('uniqueSpellDocumentTag()');
      final hit = code.substring(lookup.start, unique);
      expect(hit, contains('result('), reason: 'a cache hit replies');
      expect(
        hit,
        matches(RegExp(r'\breturn\b')),
        reason: 'and returns before a second tag is opened',
      );
    });

    test(
      'check replies at once with no results when nothing is to be checked',
      () {
        final code = _methodCode(_controller(), 'check');
        final call = code.indexOf('requestChecking(');
        expect(call, isNonNegative);
        final early = code.substring(0, call);
        expect(early, matches(RegExp(r'\btypes\s*==\s*0')));
        expect(early, matches(RegExp(r'\.length\s*==\s*0')));
        expect(
          early,
          matches(
            RegExp(r'result\(\s*\[\s*"requestId"\s*:[\s\S]*?"results"\s*:'),
          ),
        );
      },
    );

    test(
      'check asks for spelling results only while spelling is requested and grammar only while grammar is',
      () {
        final code = _methodCode(_controller(), 'check');
        expect(
          code,
          matches(RegExp(r'\bif\s+spelling\s*\{[^}]*\.spelling\b[^}]*\}')),
        );
        expect(
          code,
          matches(RegExp(r'\bif\s+grammar\s*\{[^}]*\.grammar\b[^}]*\}')),
        );
      },
    );

    test(
      'the menu items are attached from the next main-queue turn, through every submenu',
      () {
        final src = _controller();
        final init = _funcBody(
          src,
          RegExp(r'\binit\([^)]*\)'),
          _controllerPath,
        );
        expect(
          RegExp(r'attachMenuItems\(').allMatches(init),
          hasLength(1),
          reason: 'init attaches once',
        );
        final main = init.indexOf('DispatchQueue.main.async');
        expect(
          main,
          isNonNegative,
          reason: 'NSApp.mainMenu may not be set while awakeFromNib runs',
        );
        expect(
          _braceBody(init, init.indexOf('{', main), _controllerPath),
          contains('attachMenuItems('),
          reason: 'attaching happens inside the deferred block',
        );

        final attachers =
            <String, String>{
              for (final m in RegExp(r'\bfunc\s+(\w+)\s*\(').allMatches(src))
                m.group(1)!: _funcBody(
                  src,
                  RegExp(r'\bfunc\s+' + m.group(1)! + r'\s*\('),
                  _controllerPath,
                ),
            }..removeWhere(
              (_, body) => !RegExp(r'\.target\s*=\s*self\b').hasMatch(body),
            );
        expect(
          attachers,
          hasLength(1),
          reason: 'one function targets the items at the controller',
        );
        final walker = attachers.entries.single;
        expect(walker.value, contains('.items'));
        expect(
          walker.value,
          contains('.submenu'),
          reason: 'the items live under Edit, so it walks submenus',
        );
        expect(
          walker.value,
          matches(RegExp(r'\b' + walker.key + r'\(')),
          reason: 'and recurses into them',
        );
      },
    );
  });

  // Review r1 (verify mode): bind each value to its own branch or key, so a
  // swapped setting, selector, kind or range expression cannot pass with every
  // text pin green.
  group('SpellingMenuController.swift value bindings', () {
    /// [s] with every run of whitespace collapsed to one space.
    String squash(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

    /// The @objc menu actions: function name → body.
    Map<String, String> objcActions(String src) => {
      for (final m in RegExp(
        r'@objc\b[^{]*?\bfunc\s+(\w+)\s*\([^)]*\)',
      ).allMatches(src))
        m.group(1)!: _braceBody(src, src.indexOf('{', m.end), _controllerPath),
    };

    /// The body of the `{` that ends the first match of [head] in [code].
    String branch(String code, RegExp head) {
      final m = head.firstMatch(code);
      expect(m, isNotNull, reason: 'the code has ${head.pattern}:\n$code');
      return _braceBody(code, m!.end - 1, _controllerPath);
    }

    test(
      'check maps each result kind to its own start and length expressions',
      () {
        final code = _methodCode(_controller(), 'check');
        final spelling = squash(
          branch(
            code,
            RegExp(r'\bif\s+\w+\.resultType\s*==\s*\.spelling\s*\{'),
          ),
        );
        final grammar = squash(
          branch(
            code,
            RegExp(r'\belse\s+if\s+\w+\.resultType\s*==\s*\.grammar\s*\{'),
          ),
        );

        // A spelling result: its own range, as is.
        expect(spelling, contains('"kind": "spelling"'));
        expect(spelling, isNot(contains('grammar')));
        expect(
          spelling,
          matches(RegExp(r'"start":\s*found\.range\.location\s*,')),
          reason: 'a spelling squiggle starts at the result range start',
        );
        expect(
          spelling,
          matches(RegExp(r'"length":\s*found\.range\.length\s*,')),
          reason: 'a spelling squiggle spans the result range',
        );

        // A grammar result: one per detail, offset by the sentence start,
        // sized by the detail range alone.
        expect(grammar, contains('"kind": "grammar"'));
        expect(grammar, isNot(contains('"spelling"')));
        final range = RegExp(
          r'let\s+(\w+)\s*=\s*\w+\.rangeValue\b',
        ).firstMatch(grammar);
        expect(
          range,
          isNotNull,
          reason: 'the detail range is read from its NSValue',
        );
        final r = range!.group(1)!;
        expect(
          grammar,
          matches(
            RegExp(
              r'"start":\s*found\.range\.location\s*\+\s*' +
                  r +
                  r'\.location\s*,',
            ),
          ),
          reason: 'detail offsets are relative to the result range',
        );
        expect(
          grammar,
          matches(RegExp(r'"length":\s*' + r + r'\.length\s*,')),
          reason: 'a grammar squiggle spans the detail range, not the sentence',
        );
        expect(
          grammar,
          matches(
            RegExp(
              r'if let (\w+) = detail\[NSGrammarUserDescription\] as\? String '
              r'\{ issue\["description"\] = \1 \}',
            ),
          ),
          reason: 'the description is the NSGrammarUserDescription string',
        );
        expect(
          grammar,
          matches(
            RegExp(
              r'issue\["corrections"\] = detail\[NSGrammarCorrections\] as\? '
              r'\[String\] \?\? \[\]',
            ),
          ),
          reason: 'the corrections are NSGrammarCorrections, empty if absent',
        );
      },
    );

    test(
      'setMenuState feeds checkSpelling to the spelling flag and checkGrammar to the grammar flag',
      () {
        final src = _controller();
        final code = squash(_case(_handler(src), 'setMenuState'));
        final props = _menuStateProps(src);
        final spellingProp = props.singleWhere(
          (p) => p.toLowerCase().contains('spelling'),
        );
        final grammarProp = props.singleWhere(
          (p) => p.toLowerCase().contains('grammar'),
        );
        String local(String key) {
          final m = RegExp(
            r'let (\w+) = args\["' + key + r'"\] as\? Bool',
          ).firstMatch(code);
          expect(
            m,
            isNotNull,
            reason: 'setMenuState reads args["$key"]:\n$code',
          );
          return m!.group(1)!;
        }

        expect(
          code,
          matches(
            RegExp(
              r'\b' + spellingProp + r' = ' + local('checkSpelling') + r'\b',
            ),
          ),
          reason: 'args["checkSpelling"] is stored as $spellingProp',
        );
        expect(
          code,
          matches(
            RegExp(
              r'\b' + grammarProp + r' = ' + local('checkGrammar') + r'\b',
            ),
          ),
          reason: 'args["checkGrammar"] is stored as $grammarProp',
        );
      },
    );

    test(
      'check hands args["spelling"] to the spelling flag and args["grammar"] to the grammar flag',
      () {
        final code = squash(_case(_handler(_controller()), 'check'));
        String local(String key) {
          final m = RegExp(
            r'let (\w+) = args\["' + key + r'"\] as\? Bool',
          ).firstMatch(code);
          expect(m, isNotNull, reason: 'check reads args["$key"]:\n$code');
          return m!.group(1)!;
        }

        final call = RegExp(r'\bcheck\(([^)]*)\)').firstMatch(code);
        expect(call, isNotNull, reason: 'the case calls check(…):\n$code');
        expect(
          call!.group(1)!,
          matches(RegExp(r'\bspelling:\s*' + local('spelling') + r'\b')),
          reason: 'args["spelling"] decides whether spelling is checked',
        );
        expect(
          call.group(1)!,
          matches(RegExp(r'\bgrammar:\s*' + local('grammar') + r'\b')),
          reason: 'args["grammar"] decides whether grammar is checked',
        );
      },
    );

    test(
      'each spelling-* identifier is wired to the action that sends its own message to Dart',
      () {
        final src = _controller();
        final actions = objcActions(src);
        String actionSending(Pattern message) =>
            actions.entries.singleWhere((e) => e.value.contains(message)).key;
        final expected = {
          'spelling-check-document': actionSending('"checkDocumentNow"'),
          'spelling-toggle-spelling': actionSending(
            RegExp(r'\[\s*"item"\s*:\s*"checkSpelling"\s*\]'),
          ),
          'spelling-toggle-grammar': actionSending(
            RegExp(r'\[\s*"item"\s*:\s*"checkGrammar"\s*\]'),
          ),
        };
        expect(
          expected.values.toSet(),
          hasLength(3),
          reason: 'three distinct actions: $expected',
        );
        final body = _funcBody(
          src,
          RegExp(r'func\s+attachMenuItems\(\s*\)'),
          _controllerPath,
        );
        final wired = {
          for (final m in RegExp(
            r'"([\w-]+)"\s*:\s*#selector\(\s*(\w+)\s*\(',
          ).allMatches(body))
            m.group(1)!: m.group(2)!,
        };
        expect(wired, expected);
      },
    );

    test(
      'check returns right after the empty reply, before requestChecking',
      () {
        final src = _controller();
        final helper = _funcBody(
          src,
          RegExp(r'func\s+check\(\s*requestId\b'),
          _controllerPath,
        );
        final empty = squash(
          branch(
            helper,
            RegExp(r'\bif\s+types\s*==\s*0\s*\|\|[^{]*\.length\s*==\s*0\s*\{'),
          ),
        );
        expect(
          empty.trim(),
          matches(
            RegExp(
              r'^result\(\["requestId": requestId, "results": '
              r'\[\[String: Any\]\]\(\)\]\) return$',
            ),
          ),
          reason: 'one empty reply, then return (never a second reply)',
        );
      },
    );

    test(
      'guesses bounds start and length by the text length before adding them',
      () {
        final code = squash(_methodCode(_controller(), 'guesses'));
        expect(
          code,
          matches(
            RegExp(
              r'start <= (\w+)\.length, length <= \1\.length, '
              r'start \+ length <= \1\.length',
            ),
          ),
          reason: 'a huge start or length must not overflow the Int sum',
        );
      },
    );
  });

  group('MainFlutterWindow.swift', () {
    test(
      'MainFlutterWindow creates the SpellingMenuController right after filesChannel and keeps it',
      () {
        final src = _window();
        final prop = RegExp(
          r'\b(?:private\s+)?var\s+(\w+)\s*:\s*SpellingMenuController\??',
        ).firstMatch(src);
        expect(
          prop,
          isNotNull,
          reason: 'a stored property keeps the controller alive',
        );
        final name = prop!.group(1)!;
        final body = _funcBody(
          src,
          RegExp(r'override\s+func\s+awakeFromNib\(\s*\)'),
          _windowPath,
        );
        final files = body.indexOf('filesChannel = files');
        final create = RegExp(
          r'\b(?:self\.)?' + name + r'\s*=\s*SpellingMenuController\(',
        ).firstMatch(body);
        final superAwake = body.indexOf('super.awakeFromNib()');
        expect(files, isNonNegative);
        expect(create, isNotNull, reason: 'awakeFromNib creates it:\n$body');
        expect(
          create!.start,
          greaterThan(files),
          reason: 'after filesChannel (D17)',
        );
        expect(
          create.start,
          lessThan(superAwake),
          reason: 'before super.awakeFromNib()',
        );
        expect(
          _bracketBody(body, create.end - 1, _windowPath),
          contains('flutterViewController.engine.binaryMessenger'),
          reason: "it is given the engine's binary messenger",
        );
        expect(
          RegExp(r'SpellingMenuController\(').allMatches(src),
          hasLength(1),
          reason: 'one controller',
        );
      },
    );
  });
}
