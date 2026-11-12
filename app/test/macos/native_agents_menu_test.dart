// WI #409 (Spec #394 requirements 4, 5, 7, 31; rulings D17, D18): source
// contract for the native half of Window ▸ Agents… and the concealed copy.
//
// XCTest isn't gated and the AC map takes no Swift path, so these tests read
// `MainMenu.xib` and `MainFlutterWindow.swift` as text and pin the wiring the
// Spec promises: the menu item, its key equivalent and explicit target, the
// window-channel `openAgents` / `setAgentsMenuEnabled` pair, `validateMenuItem`
// deferring to `super`, and the files-channel `copySensitive` with its
// ConcealedType marker. They are text pins, not behaviour: real behaviour is
// the PR's MANUAL rows and `## Hand mutants`.
//
// `flutter test` runs with `app/` as the working directory, so the paths are
// relative to the app package root (as in test/release/).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _xibPath = 'macos/Runner/Base.lproj/MainMenu.xib';
const _swiftPath = 'macos/Runner/MainFlutterWindow.swift';

/// The xib id of the `Window` submenu.
const _windowMenuId = 'Td7-aD-5lo';

String _read(String relative) {
  final f = File(relative);
  expect(f.existsSync(), isTrue, reason: '$relative exists under app/');
  return f.readAsStringSync();
}

String _xib() => _read(_xibPath);
String _swift() => _read(_swiftPath);

// ---------------------------------------------------------------- xib -----

Map<String, String> _attrs(String tagAttrs) => {
  for (final m in RegExp(r'([\w:]+)="([^"]*)"').allMatches(tagAttrs))
    m.group(1)!: m.group(2)!,
};

/// One `<menuItem>` of a menu: its attributes and inner XML.
class _MenuItem {
  _MenuItem(this.attrs, this.inner);
  final Map<String, String> attrs;
  final String inner;

  String? get title => attrs['title'];

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

/// The inner XML of the `Window` submenu (it has no nested menus).
String _windowMenu(String xib) {
  final start = RegExp(
    '<menu key="submenu" title="Window"[^>]*id="$_windowMenuId"[^>]*>',
  ).firstMatch(xib);
  expect(
    start,
    isNotNull,
    reason: 'the Window submenu ($_windowMenuId) exists',
  );
  final end = xib.indexOf('</menu>', start!.end);
  expect(end, greaterThan(start.end), reason: 'the Window submenu is closed');
  return xib.substring(start.end, end);
}

List<_MenuItem> _items(String menuXml) => [
  for (final m in RegExp(
    r'<menuItem\b([^>]*?)(?:/>|>([\s\S]*?)</menuItem>)',
  ).allMatches(menuXml))
    _MenuItem(_attrs(m.group(1)!), m.group(2) ?? ''),
];

_MenuItem _item(List<_MenuItem> items, String title) {
  final found = items.where((i) => i.title == title).toList();
  expect(found, hasLength(1), reason: 'the Window menu has one "$title" item');
  return found.single;
}

// -------------------------------------------------------------- Swift -----

/// The text from [from] up to [to] (exclusive), both of which must exist.
String _between(String src, String from, String to) {
  final a = src.indexOf(from);
  expect(a, isNonNegative, reason: '"$from" appears in $_swiftPath');
  final b = src.indexOf(to, a);
  expect(b, greaterThan(a), reason: '"$to" follows "$from" in $_swiftPath');
  return src.substring(a, b);
}

/// The `open_memex/window` channel's method-call handler.
String _windowHandler(String src) =>
    _between(src, 'name: "open_memex/window"', 'windowChannel = channel');

/// The `open_memex/files` channel's method-call handler.
String _filesHandler(String src) =>
    _between(src, 'name: "open_memex/files"', 'filesChannel = files');

/// The body of `case "<method>":` in [handler], up to the next case/default.
String _case(String handler, String method) {
  final start = handler.indexOf('case "$method":');
  expect(start, isNonNegative, reason: 'the handler has case "$method"');
  final next = RegExp(
    r'\n\s*(?:case "|default:)',
  ).allMatches(handler).map((m) => m.start).where((i) => i > start).toList();
  return handler.substring(start, next.isEmpty ? handler.length : next.first);
}

/// The text inside the braces that open at [open] (an index of `{`).
/// String literals are skipped so braces inside them don't count.
String _braceBody(String src, int open) {
  expect(src[open], '{');
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
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  fail('unbalanced braces from offset $open in $_swiftPath');
}

/// The body of the function whose declaration matches [decl].
String _funcBody(String src, RegExp decl) {
  final m = decl.firstMatch(src);
  expect(m, isNotNull, reason: '$_swiftPath declares ${decl.pattern}');
  return _braceBody(src, src.indexOf('{', m!.end));
}

/// A `guard let <v> = call.arguments as? <type> else { … }` in [block]:
/// the bound name, the else body and the text after the guard.
({String name, String elseBody, String rest}) _argGuard(
  String block,
  String type,
) {
  final m = RegExp(
    r'guard\s+let\s+(\w+)\s*=\s*call\.arguments\s+as\?\s+' +
        type +
        r'\s+else\s*\{',
  ).firstMatch(block);
  expect(
    m,
    isNotNull,
    reason: 'the case guards `call.arguments as? $type`:\n$block',
  );
  final elseBody = _braceBody(block, m!.end - 1);
  return (
    name: m.group(1)!,
    elseBody: elseBody,
    rest: block.substring(m.end + elseBody.length + 1),
  );
}

/// Expects [elseBody] to reply a `bad_arguments` FlutterError and return.
void _expectBadArguments(String elseBody, String method) {
  expect(
    elseBody,
    matches(
      RegExp(
        r'result\(\s*FlutterError\(\s*code:\s*"bad_arguments"',
        dotAll: true,
      ),
    ),
    reason: '$method replies bad_arguments to a wrong argument type',
  );
  expect(
    elseBody,
    contains('return'),
    reason: '$method returns after bad_arguments',
  );
  expect(
    elseBody,
    isNot(contains('result(nil)')),
    reason: '$method never also replies nil to a bad argument',
  );
}

/// The `///` doc comment above `class MainFlutterWindow`, as bullets: each
/// `- …` line joined with its indented continuation lines.
({List<String> window, List<String> files}) _docBullets(String src) {
  final classAt = src.indexOf('class MainFlutterWindow');
  expect(classAt, isNonNegative);
  final doc = src
      .substring(0, classAt)
      .split('\n')
      .where((l) => l.trimLeft().startsWith('///'))
      .map((l) => l.trimLeft().substring(3))
      .toList();
  final windowAt = doc.indexWhere(
    (l) => l.contains('Window channel `open_memex/window`'),
  );
  final filesAt = doc.indexWhere(
    (l) => l.contains('Files channel `open_memex/files`'),
  );
  expect(windowAt, isNonNegative, reason: 'the doc has a window-channel part');
  expect(filesAt, greaterThan(windowAt), reason: 'then a files-channel part');
  List<String> bullets(Iterable<String> lines) {
    final out = <String>[];
    for (final l in lines) {
      if (l.trimLeft().startsWith('- ')) {
        out.add(l.trim());
      } else if (out.isNotEmpty && l.startsWith('   ')) {
        out[out.length - 1] = '${out.last} ${l.trim()}';
      }
    }
    return out;
  }

  return (
    window: bullets(doc.sublist(windowAt + 1, filesAt)),
    files: bullets(doc.sublist(filesAt + 1)),
  );
}

void _expectBullet(List<String> bullets, List<String> parts, String why) {
  expect(
    bullets.where((b) => parts.every(b.contains)),
    isNotEmpty,
    reason:
        '$why: a doc bullet containing ${parts.join(' + ')}\n'
        '${bullets.join('\n')}',
  );
}

/// The identifier bound to `NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")`.
String _concealedTypeName(String src) {
  final m = RegExp(
    r'let\s+(\w+)(?:\s*:\s*NSPasteboard\.PasteboardType)?\s*=\s*'
    r'NSPasteboard\.PasteboardType\(\s*"org\.nspasteboard\.ConcealedType"\s*\)',
  ).firstMatch(src);
  expect(
    m,
    isNotNull,
    reason:
        'the file binds NSPasteboard.PasteboardType('
        '"org.nspasteboard.ConcealedType") to a name',
  );
  return m!.group(1)!;
}

/// [src] without `//` comments, trimmed.
String _code(String src) => src.replaceAll(RegExp(r'//[^\n]*'), '').trim();

/// How many times [pattern] occurs in [src].
int _count(String src, Pattern pattern) => pattern.allMatches(src).length;

/// A reference to [name], bare or through `self.`, `Self.` or the class.
String _ref(String name) =>
    r'(?:(?:self|Self|MainFlutterWindow)\.)?' + RegExp.escape(name) + r'\b';

void main() {
  group('MainMenu.xib Window menu', () {
    test('Window menu has one Agents… item with ⇧⌘A', () {
      final xib = _xib();
      final items = _items(_windowMenu(xib));
      expect(
        items.where((i) => i.title == 'Agents...'),
        isEmpty,
        reason: 'the title uses an ellipsis (U+2026), not three dots',
      );
      final agents = _item(items, 'Agents…');
      expect(
        RegExp('title="Agents…"').allMatches(xib),
        hasLength(1),
        reason: 'Agents… appears once in the whole menu bar',
      );
      expect(agents.attrs['isSeparatorItem'], isNull);
      expect(
        agents.attrs['keyEquivalent'],
        'a',
        reason: 'lower-case "a" plus the shift mask is ⇧⌘A',
      );
      final mask = agents.modifierMask;
      expect(mask, isNotNull, reason: 'Agents… sets its modifier mask');
      expect(mask!['shift'], 'YES');
      expect(mask['command'], 'YES');
      expect(mask['option'], isNot('YES'));
      expect(mask['control'], isNot('YES'));
    });

    test('Agents… targets MainFlutterWindow openAgents: explicitly', () {
      final xib = _xib();
      final window = RegExp(
        r'<window\b[^>]*\bid="([^"]+)"[^>]*customClass="MainFlutterWindow"',
      ).firstMatch(xib);
      expect(window, isNotNull, reason: 'the xib has the MainFlutterWindow');
      final windowId = window!.group(1)!;
      expect(windowId, 'QvC-M9-y7g');

      final agents = _item(_items(_windowMenu(xib)), 'Agents…');
      expect(agents.actions, hasLength(1), reason: 'one action connection');
      final action = agents.actions.single;
      expect(action['selector'], 'openAgents:');
      expect(
        action['target'],
        windowId,
        reason: 'an explicit target (the window), not the first responder -1',
      );

      final ids = RegExp(
        r'\bid="([^"]+)"',
      ).allMatches(xib).map((m) => m.group(1)!).toList();
      for (final id in [agents.attrs['id'], action['id']]) {
        expect(id, isNotNull);
        expect(
          ids.where((i) => i == id),
          hasLength(1),
          reason: 'xib id $id is unique',
        );
      }
    });

    test(
      'Minimize, Zoom and Bring All to Front keep their first-responder actions',
      () {
        final items = _items(_windowMenu(_xib()));
        final minimize = _item(items, 'Minimize');
        expect(minimize.attrs['keyEquivalent'], 'm');
        expect(minimize.actions, [
          {
            'selector': 'performMiniaturize:',
            'target': '-1',
            'id': 'VwT-WD-YPe',
          },
        ]);
        expect(_item(items, 'Zoom').actions, [
          {'selector': 'performZoom:', 'target': '-1', 'id': 'DIl-cC-cCs'},
        ]);
        expect(_item(items, 'Bring All to Front').actions, [
          {'selector': 'arrangeInFront:', 'target': '-1', 'id': 'DRN-fu-gQh'},
        ]);
      },
    );
  });

  group('MainFlutterWindow.swift', () {
    test(
      'channel doc comment lists openAgents, setAgentsMenuEnabled(Bool) and copySensitive(String)',
      () {
        final doc = _docBullets(_swift());
        _expectBullet(doc.window, [
          'native → Dart',
          '`openAgents`',
        ], 'openAgents');
        _expectBullet(doc.window, [
          'Dart → native',
          '`setAgentsMenuEnabled(Bool)`',
        ], 'setAgentsMenuEnabled');
        _expectBullet(doc.files, [
          'Dart → native',
          '`copySensitive(String)`',
          '`copy_failed`',
          '`bad_arguments`',
        ], 'copySensitive and its replies');
        // The methods that were already there stay listed.
        _expectBullet(doc.window, [
          'native → Dart',
          '`windowShouldClose`',
        ], 'windowShouldClose');
        _expectBullet(doc.window, [
          'Dart → native',
          '`setTitle(String)`',
        ], 'setTitle');
        _expectBullet(doc.files, [
          'Dart → native',
          '`trashItem(String)`',
        ], 'trashItem');
      },
    );

    test(
      'openAgents action sends openAgents with no arguments on the window channel',
      () {
        final src = _swift();
        final body = _funcBody(
          src,
          RegExp(
            r'@IBAction\s+func\s+openAgents\(\s*_\s+sender\s*:\s*Any\?\s*\)',
          ),
        );
        expect(
          body,
          matches(
            RegExp(
              r'windowChannel\?\.invokeMethod\(\s*"openAgents"\s*,\s*arguments:\s*nil\s*\)',
            ),
          ),
        );
        expect(
          body.trim().split('\n'),
          hasLength(1),
          reason:
              'a thin pass-through: the mapping lives in Dart (lesson #347)',
        );
      },
    );

    test(
      'Agents menu flag starts false so the item is greyed out until a vault opens',
      () {
        expect(
          _swift(),
          matches(
            RegExp(
              r'private\s+var\s+agentsMenuEnabled(?:\s*:\s*Bool)?\s*=\s*false\b',
            ),
          ),
        );
      },
    );

    test(
      'setAgentsMenuEnabled takes a Bool, sets the flag and replies nil',
      () {
        final block = _case(_windowHandler(_swift()), 'setAgentsMenuEnabled');
        final g = _argGuard(block, 'Bool');
        expect(
          _code(g.rest),
          matches(
            RegExp(
              r'^(?:self\??\.)?agentsMenuEnabled\s*=\s*' +
                  g.name +
                  r'\s*\n\s*result\(nil\)$',
            ),
          ),
          reason:
              'after the guard the flag is set to the bound Bool as it is '
              '(not negated, not `|| true`, not nested in an `if`), then '
              'the reply is nil, with nothing else:\n${g.rest}',
        );
        expect(
          _count(block, 'result(nil)'),
          1,
          reason: 'one nil reply, the last statement of the case',
        );
        expect(
          _count(_swift(), RegExp(r'agentsMenuEnabled\s*=(?!=)')),
          2,
          reason:
              'the flag is written only by its false initializer and by '
              'setAgentsMenuEnabled',
        );
      },
    );

    test('setAgentsMenuEnabled replies bad_arguments to a non-Bool', () {
      final block = _case(_windowHandler(_swift()), 'setAgentsMenuEnabled');
      final g = _argGuard(block, 'Bool');
      _expectBadArguments(g.elseBody, 'setAgentsMenuEnabled');
      expect(
        g.elseBody,
        isNot(contains('agentsMenuEnabled')),
        reason: 'a bad argument leaves the flag alone',
      );
      expect(
        _count(block, RegExp(r'agentsMenuEnabled\s*=(?!=)')),
        1,
        reason:
            'the flag is assigned once in the whole case, after the guard, '
            'so a bad argument never reaches it',
      );
      expect(
        _count(block, 'result('),
        3,
        reason:
            'only the CFBoolean refusal, the Bool refusal and the nil '
            'reply answer, so nothing replies before bad_arguments',
      );
      expect(
        _count(block, 'return'),
        2,
        reason: 'the two refusals return; nothing else exits early',
      );
    });

    test(
      'setAgentsMenuEnabled refuses a number that is not a CFBoolean before the Bool guard',
      () {
        // Swift's `as? Bool` bridges an NSNumber 0 or 1 (a Dart int or
        // double), so a CFBoolean check has to come first.
        final src = _swift();
        final block = _case(_windowHandler(src), 'setAgentsMenuEnabled');
        final cf = RegExp(
          r'\bif\s+let\s+(\w+)\s*=\s*call\.arguments\s+as\?\s+NSNumber\s*,\s*'
          r'CFGetTypeID\(\s*\1\s*\)\s*!=\s*CFBooleanGetTypeID\(\)\s*\{',
        ).firstMatch(block);
        expect(
          cf,
          isNotNull,
          reason: 'a non-CFBoolean NSNumber is refused:\n$block',
        );
        final refuse = _braceBody(block, cf!.end - 1);
        _expectBadArguments(refuse, 'setAgentsMenuEnabled (number)');
        expect(
          refuse,
          isNot(contains('agentsMenuEnabled')),
          reason: 'a refused number leaves the flag alone',
        );
        expect(
          block.indexOf('guard let'),
          greaterThan(cf.end + refuse.length),
          reason: 'the CFBoolean check runs before the Bool guard',
        );
        final guardAt = block.indexOf('guard let');
        expect(
          _code(block.substring(cf.end + refuse.length + 1, guardAt)),
          isEmpty,
          reason: 'nothing runs between the CFBoolean check and the Bool guard',
        );
        expect(
          block
              .substring(0, cf.start)
              .replaceFirst('case "setAgentsMenuEnabled":', '')
              .replaceAll(RegExp(r'//[^\n]*'), '')
              .trim(),
          isEmpty,
          reason: 'nothing runs before the check',
        );
        final doc = _docBullets(src);
        _expectBullet(doc.window, [
          '`setAgentsMenuEnabled(Bool)`',
          'int',
          '`bad_arguments`',
        ], 'the doc says a Dart int is refused');
      },
    );

    test(
      'validateMenuItem returns the flag for openAgents: and super for every other item',
      () {
        final body = _funcBody(
          _swift(),
          RegExp(
            r'override\s+func\s+validateMenuItem\(\s*_\s+menuItem\s*:\s*NSMenuItem\s*\)\s*->\s*Bool',
          ),
        );
        expect(
          body,
          matches(
            RegExp(
              r'menuItem\.action\s*==\s*#selector\(\s*openAgents\(_:\)\s*\)',
            ),
          ),
          reason: 'the Agents item is recognised by its action',
        );
        // Tie each return to its branch: the `if` body is exactly the flag,
        // the fall-through is exactly super, and nothing else is in the body.
        final ifMatch = RegExp(r'\bif\s+([^{]*?)\s*\{').firstMatch(body);
        expect(ifMatch, isNotNull, reason: 'one `if` recognises the item');
        expect(
          body.substring(0, ifMatch!.start).trim(),
          isEmpty,
          reason: 'the `if` is the first statement',
        );
        expect(
          ifMatch.group(1),
          'menuItem.action == #selector(openAgents(_:))',
          reason: 'the branch is taken for openAgents: only (no `!`, no `!=`)',
        );
        final ifBody = _braceBody(body, ifMatch.end - 1);
        expect(
          ifBody.trim(),
          matches(RegExp(r'^return\s+(?:self\.)?agentsMenuEnabled$')),
          reason: 'openAgents: is enabled exactly when the flag is set',
        );
        final fallThrough = body.substring(ifMatch.end + ifBody.length + 1);
        expect(
          fallThrough.trim(),
          'return super.validateMenuItem(menuItem)',
          reason:
              'every other item (Minimize, Zoom) asks super, with no '
              'else, no other return',
        );
      },
    );

    test('copySensitive replies bad_arguments to a non-String', () {
      final block = _case(_filesHandler(_swift()), 'copySensitive');
      final g = _argGuard(block, 'String');
      _expectBadArguments(g.elseBody, 'copySensitive');
      expect(g.elseBody, isNot(contains('NSPasteboard')));
      expect(
        _code(block.substring(0, block.indexOf('guard let'))),
        'case "copySensitive":',
        reason: 'nothing runs before the String guard',
      );
    });

    test(
      'copySensitive clears the pasteboard and declares the string and ConcealedType',
      () {
        final src = _swift();
        final concealed = _concealedTypeName(src);
        final block = _case(_filesHandler(src), 'copySensitive');
        final g = _argGuard(block, 'String');
        final body = g.rest;
        expect(body, contains('NSPasteboard.general'));
        final clear = body.indexOf('.clearContents()');
        expect(clear, isNonNegative, reason: 'the pasteboard is cleared first');
        final declare = RegExp(
          r'\.declareTypes\(\s*\[([^\]]*)\]\s*,\s*owner:\s*nil\s*\)',
        ).firstMatch(body);
        expect(declare, isNotNull, reason: 'the types are declared:\n$body');
        expect(declare!.start, greaterThan(clear), reason: 'after clearing');
        final types = declare
            .group(1)!
            .split(',')
            .map((t) => t.trim())
            .toList();
        expect(types, hasLength(2));
        expect(
          types,
          contains(
            matches(RegExp(r'^(?:NSPasteboard\.PasteboardType)?\.string$')),
          ),
          reason: 'public.utf8-plain-text is declared',
        );
        expect(
          types,
          contains(matches(RegExp('^${_ref(concealed)}\$'))),
          reason: 'org.nspasteboard.ConcealedType is declared',
        );
      },
    );

    test(
      'copySensitive writes the text as a string and an empty ConcealedType marker',
      () {
        final src = _swift();
        final concealed = _concealedTypeName(src);
        final block = _case(_filesHandler(src), 'copySensitive');
        final g = _argGuard(block, 'String');
        final body = g.rest;
        final declare = body.indexOf('.declareTypes(');
        expect(declare, isNonNegative);
        final text = RegExp(
          r'\.setString\(\s*' +
              g.name +
              r'\s*,\s*forType:\s*(?:NSPasteboard\.PasteboardType)?\.string\s*\)',
        ).firstMatch(body);
        expect(
          text,
          isNotNull,
          reason: 'the real text goes on as .string:\n$body',
        );
        expect(text!.start, greaterThan(declare), reason: 'after declaring');
        final marker = RegExp(
          r'\.setString\(\s*""\s*,\s*forType:\s*' + _ref(concealed) + r'\s*\)',
        ).firstMatch(body);
        expect(
          marker,
          isNotNull,
          reason: 'the concealed marker is set:\n$body',
        );
        expect(marker!.start, greaterThan(declare));
        expect(
          RegExp(
            r'\.setString\(\s*' +
                g.name +
                r'\s*,\s*forType:\s*' +
                _ref(concealed),
          ).hasMatch(body),
          isFalse,
          reason: 'the token itself is never written under the marker type',
        );
        expect(body, contains('result(nil)'), reason: 'success replies nil');
      },
    );

    test(
      'copySensitive replies copy_failed with domain and code when a write fails',
      () {
        final src = _swift();
        final concealed = _concealedTypeName(src);
        final block = _case(_filesHandler(src), 'copySensitive');
        final g = _argGuard(block, 'String');
        final body = g.rest;
        expect(
          RegExp(r'\.setString\(').allMatches(body),
          hasLength(2),
          reason: 'exactly two writes (text, marker), both inside the guard',
        );
        final wr = RegExp(r'\bguard\s+([^{]*?)\s+else\s*\{').firstMatch(body);
        expect(wr, isNotNull, reason: 'the writes are guarded:\n$body');
        final cond = wr!.group(1)!;
        expect(cond, isNot(contains('||')));
        expect(cond, isNot(contains('!')));
        expect(cond, isNot(contains('_ =')), reason: 'no result is discarded');
        // Split the guard conditions on top-level commas or `&&`.
        final clauses = <String>[];
        var depth = 0;
        var start = 0;
        for (var i = 0; i < cond.length; i++) {
          final c = cond[i];
          if (c == '(' || c == '[') depth++;
          if (c == ')' || c == ']') depth--;
          if (depth == 0 && c == ',') {
            clauses.add(cond.substring(start, i).trim());
            start = i + 1;
          } else if (depth == 0 && cond.startsWith('&&', i)) {
            clauses.add(cond.substring(start, i).trim());
            start = i + 2;
            i++;
          }
        }
        clauses.add(cond.substring(start).trim());
        expect(
          clauses,
          hasLength(2),
          reason: 'both writes are guard clauses:\n$cond',
        );
        expect(
          clauses,
          contains(
            matches(
              RegExp(
                r'^\w+\.setString\(\s*' +
                    g.name +
                    r'\s*,\s*forType:\s*(?:NSPasteboard\.PasteboardType)?\.string\s*\)$',
              ),
            ),
          ),
          reason: 'a failed text write is copy_failed',
        );
        expect(
          clauses,
          contains(
            matches(
              RegExp(
                r'^\w+\.setString\(\s*""\s*,\s*forType:\s*' +
                    _ref(concealed) +
                    r'\s*\)$',
              ),
            ),
          ),
          reason: 'a failed marker write is copy_failed',
        );
        final elseBody = _braceBody(body, wr.end - 1);
        final err = RegExp(
          r'result\(\s*FlutterError\(\s*code:\s*"copy_failed"[\s\S]*?details:\s*\[([^\]]*)\]\s*\)\s*\)',
        ).firstMatch(elseBody);
        expect(
          err,
          isNotNull,
          reason: 'a failed write replies copy_failed:\n$elseBody',
        );
        final details = err!.group(1)!;
        expect(details, matches(RegExp(r'"domain"\s*:\s*"NSPasteboard"')));
        expect(details, matches(RegExp(r'"code"\s*:\s*0\b')));
        expect(
          elseBody.substring(err.end).trim(),
          'return',
          reason: 'copy_failed returns at once',
        );
        expect(
          elseBody,
          isNot(contains('result(nil)')),
          reason: 'a failed copy never also replies nil (no double reply)',
        );
        expect(
          body.substring(wr.end + elseBody.length + 1).trim(),
          'result(nil)',
          reason: 'the success reply is the last statement, after the guard',
        );
        expect(
          body.substring(0, wr.start),
          isNot(contains('result(')),
          reason:
              'nothing replies before the writes: an early reply would '
              'answer success and drop the later copy_failed',
        );
        expect(
          _count(block, 'result(nil)'),
          1,
          reason: 'one nil reply in the whole case, after the writes',
        );
        expect(
          _count(block, 'result('),
          3,
          reason: 'bad_arguments, copy_failed and the nil reply, no more',
        );
        expect(
          _count(block, 'return'),
          2,
          reason: 'only the two failure paths return early',
        );
      },
    );

    test('copySensitive never logs or echoes the copied text', () {
      final block = _case(_filesHandler(_swift()), 'copySensitive');
      final g = _argGuard(block, 'String');
      for (final log in [
        'print(',
        'debugPrint(',
        'NSLog(',
        'os_log(',
        'Logger(',
        'dump(',
      ]) {
        expect(
          block,
          isNot(contains(log)),
          reason: 'copySensitive never logs ($log)',
        );
      }
      expect(
        block,
        isNot(contains('\\(${g.name}')),
        reason: 'the text is never interpolated into a string',
      );
      final errors = RegExp(
        r'FlutterError\(([\s\S]*?)\)\s*\)',
      ).allMatches(block);
      expect(errors, isNotEmpty);
      for (final e in errors) {
        expect(
          RegExp(r'\b' + g.name + r'\b').hasMatch(e.group(1)!),
          isFalse,
          reason: 'no error reply carries the text: ${e.group(0)}',
        );
      }
    });

    test('window and files channels keep their existing methods', () {
      final src = _swift();
      final window = _windowHandler(src);
      final files = _filesHandler(src);
      expect(window, contains('case "setTitle":'));
      expect(window, contains('result(FlutterMethodNotImplemented)'));
      expect(files, contains('case "trashItem":'));
      expect(files, contains('result(FlutterMethodNotImplemented)'));
      expect(src, contains('self.delegate = self'));
      final shouldClose = _funcBody(
        src,
        RegExp(
          r'func\s+windowShouldClose\(\s*_\s+sender\s*:\s*NSWindow\s*\)\s*->\s*Bool',
        ),
      );
      expect(
        shouldClose,
        contains('channel.invokeMethod("windowShouldClose", arguments: nil)'),
      );
      expect(shouldClose, contains('return false'));
    });
  });
}
