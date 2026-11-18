// WI #81 (Spec #61 F5; Reqs 11, 14-17; TD5; D9): source contract for the
// native half of Edit ▸ Find in `MainFlutterWindow.swift`.
//
// XCTest isn't gated and the gate cannot mutate Swift, so these tests read
// the Swift source as text and pin the thin pass-through the Spec promises
// (adapter lesson #347), each one killing a `## Hand mutants` row:
// - the identifier lookup: the four items `find-show`, `find-next`,
//   `find-previous` and `find-use-selection` map to the action strings
//   `show`, `next`, `previous` and `useSelection`, and nothing maps
//   `find-replace`;
// - one `@objc` action, targeted at the window by identifier once the main
//   menu is installed, that sends native → Dart `find` with the action string
//   and never reads a reply;
// - the enabled flag: `setFindMenuEnabled(Bool)` starts false (fail closed),
//   is set only by that method and is what `validateMenuItem` answers for
//   the four items;
// - Find and Replace… is always disabled (Req 16);
// - the `bad_arguments` branch: a non-`Bool` argument, a Dart int 0 or 1
//   included, leaves the flag alone.
// They are text pins, not behaviour: the real menu is the PR's MANUAL rows.
//
// `flutter test` runs with `app/` as the working directory, so the path is
// relative to the app package root.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _swiftPath = 'macos/Runner/MainFlutterWindow.swift';

/// Identifier → the action string native sends to Dart.
const _actions = <String, String>{
  'find-show': 'show',
  'find-next': 'next',
  'find-previous': 'previous',
  'find-use-selection': 'useSelection',
};

String _raw() {
  final f = File(_swiftPath);
  expect(f.existsSync(), isTrue, reason: '$_swiftPath exists under app/');
  return f.readAsStringSync();
}

/// [src] with every `//` comment removed (string literals are kept), so a
/// doc comment never satisfies (or trips) a pin.
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

String _swift() => _stripComments(_raw());

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

/// The body of `case "<method>":` in [handler], up to the next case/default.
String _case(String handler, String method) {
  final start = handler.indexOf('case "$method":');
  expect(start, isNonNegative, reason: 'the handler has case "$method"');
  final next = RegExp(
    r'\n\s*(?:case "|default:)',
  ).allMatches(handler).map((m) => m.start).where((i) => i > start).toList();
  return handler.substring(start, next.isEmpty ? handler.length : next.first);
}

/// The text inside the bracket pair that opens at [open] (`{` or `[`).
/// String literals are skipped so brackets inside them don't count.
String _bracketBody(String src, int open) {
  final o = src[open];
  expect(o, anyOf('{', '['));
  final c = o == '{' ? '}' : ']';
  var depth = 0;
  var inString = false;
  for (var i = open; i < src.length; i++) {
    final ch = src[i];
    if (inString) {
      if (ch == r'\') {
        i++;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == o) {
      depth++;
    } else if (ch == c) {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  fail('unbalanced $o from offset $open in $_swiftPath');
}

/// The body of the function whose declaration matches [decl].
String _funcBody(String src, RegExp decl) {
  final m = decl.firstMatch(src);
  expect(m, isNotNull, reason: '$_swiftPath declares ${decl.pattern}');
  return _bracketBody(src, src.indexOf('{', m!.end));
}

/// How many times [pattern] occurs in [src].
int _count(String src, Pattern pattern) => pattern.allMatches(src).length;

/// The dictionary literal that maps the Find identifiers: its name and its
/// `"key": "value"` entries in source order.
({String name, List<(String, String)> entries}) _findMap(String src) {
  for (final m in RegExp(
    r'\b(?:let|var)\s+(\w+)\s*(?::\s*\[\s*String\s*:\s*String\s*\])?\s*=\s*\[',
  ).allMatches(src)) {
    final body = _bracketBody(src, m.end - 1);
    if (!body.contains('"find-show"')) continue;
    return (
      name: m.group(1)!,
      entries: [
        for (final e in RegExp(r'"([^"]*)"\s*:\s*"([^"]*)"').allMatches(body))
          (e.group(1)!, e.group(2)!),
      ],
    );
  }
  fail(
    '$_swiftPath has no [String: String] literal holding "find-show": the '
    'identifier → action string lookup',
  );
}

/// The one `@objc` function that sends `find`: its name and body.
({String name, String body}) _findAction(String src) {
  final found = <({String name, String body})>[];
  for (final m in RegExp(
    r'@(?:objc|IBAction)\s+(?:@objc\s+)?(?:private\s+)?func\s+(\w+)\(\s*_\s+\w+\s*:\s*(?:NSMenuItem|Any\?|NSMenuItem\?)\s*\)\s*\{',
  ).allMatches(src)) {
    final body = _bracketBody(src, m.end - 1);
    if (body.contains('invokeMethod("find"')) {
      found.add((name: m.group(1)!, body: body));
    }
  }
  expect(
    found,
    hasLength(1),
    reason: 'one @objc action sends find (TD5: one action for the four items)',
  );
  return found.single;
}

/// The `///` doc comment above `class MainFlutterWindow`, window-channel
/// part, as bullets: each `- …` line joined with its continuation lines.
List<String> _windowDocBullets(String raw) {
  final classAt = raw.indexOf('class MainFlutterWindow');
  expect(classAt, isNonNegative);
  final doc = raw
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
  expect(windowAt, isNonNegative);
  expect(filesAt, greaterThan(windowAt));
  final out = <String>[];
  for (final l in doc.sublist(windowAt + 1, filesAt)) {
    if (l.trimLeft().startsWith('- ')) {
      out.add(l.trim());
    } else if (out.isNotEmpty && l.startsWith('   ')) {
      out[out.length - 1] = '${out.last} ${l.trim()}';
    }
  }
  return out;
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

/// Expects [elseBody] to reply a `bad_arguments` FlutterError and return.
void _expectBadArguments(String elseBody, String why) {
  expect(
    elseBody,
    matches(
      RegExp(
        r'result\(\s*FlutterError\(\s*code:\s*"bad_arguments"',
        dotAll: true,
      ),
    ),
    reason: '$why replies bad_arguments',
  );
  expect(elseBody, contains('return'), reason: '$why returns at once');
  expect(
    elseBody,
    isNot(contains('result(nil)')),
    reason: '$why never also replies nil',
  );
  expect(
    elseBody,
    isNot(contains('findMenuEnabled')),
    reason: '$why leaves the flag alone',
  );
}

/// The top-level `if <cond> { <body> }` statements of [body], in order.
List<({String cond, String body, int start})> _ifs(String body) {
  final out = <({String cond, String body, int start})>[];
  var from = 0;
  while (true) {
    final m = RegExp(r'\bif\s+([^{]*?)\s*\{').firstMatch(body.substring(from));
    if (m == null) return out;
    final open = from + m.end - 1;
    final inner = _bracketBody(body, open);
    out.add((cond: m.group(1)!.trim(), body: inner, start: from + m.start));
    from = open + inner.length + 2;
  }
}

void main() {
  test(
    'channel doc comment lists native to Dart find with its four action strings and setFindMenuEnabled Bool with bad_arguments',
    () {
      final bullets = _windowDocBullets(_raw());
      _expectBullet(bullets, [
        'native → Dart',
        '`find`',
        '`show`',
        '`next`',
        '`previous`',
        '`useSelection`',
      ], 'find');
      _expectBullet(bullets, [
        'Dart → native',
        '`setFindMenuEnabled(Bool)`',
        'int',
        '`bad_arguments`',
      ], 'setFindMenuEnabled');
      // The methods that were already there stay listed.
      _expectBullet(bullets, ['native → Dart', '`openAgents`'], 'openAgents');
      _expectBullet(bullets, [
        'Dart → native',
        '`setAgentsMenuEnabled(Bool)`',
      ], 'setAgentsMenuEnabled');
      _expectBullet(bullets, [
        'native → Dart',
        '`windowShouldClose`',
      ], 'windowShouldClose');
    },
  );

  test(
    'the identifier lookup maps exactly the four Find items to show next previous and useSelection',
    () {
      final src = _swift();
      final map = _findMap(src);
      expect(
        {for (final (k, v) in map.entries) k: v},
        _actions,
        reason: 'each identifier sends its own action string',
      );
      expect(
        map.entries,
        hasLength(4),
        reason: 'no identifier is listed twice:\n${map.entries}',
      );
      expect(
        src,
        isNot(matches(RegExp(r'"find-replace"\s*:'))),
        reason: 'Find and Replace… is never mapped to an action (Req 16)',
      );
      for (final id in _actions.keys) {
        expect(
          _count(src, '"$id"'),
          1,
          reason: '$id is named once, in the lookup',
        );
      }
    },
  );

  test(
    'the find action looks its item up by identifier and sends find with the action string and no reply handler',
    () {
      final src = _swift();
      final map = _findMap(src);
      final action = _findAction(src);
      final call = RegExp(
        r'windowChannel\?\.invokeMethod\(\s*"find"\s*,\s*arguments:\s*(\w+)\s*\)',
      ).firstMatch(action.body);
      expect(
        call,
        isNotNull,
        reason:
            'sends find on the window channel with one argument and no '
            'result closure (native never reads the reply):\n${action.body}',
      );
      final arg = call!.group(1)!;
      expect(arg, isNot('nil'), reason: 'the action string is the argument');
      expect(
        action.body,
        matches(
          RegExp(
            r'\blet\s+' +
                arg +
                r'\s*=\s*(?:Self\.|MainFlutterWindow\.|self\.)?' +
                map.name +
                r'\[',
          ),
        ),
        reason: 'the argument is the lookup of the item in ${map.name}',
      );
      expect(
        action.body,
        contains('.identifier'),
        reason: 'the item is looked up by its identifier',
      );
      expect(
        _count(src, 'invokeMethod("find"'),
        1,
        reason: 'only this action sends find',
      );
      expect(
        action.body,
        isNot(matches(RegExp(r'\b(?:switch|if)\b'))),
        reason: 'a thin pass-through: no branching beyond the guard (#347)',
      );
      final statements = action.body
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      expect(
        statements.length,
        lessThanOrEqualTo(5),
        reason: 'a guard on the lookup, then the send:\n${action.body}',
      );
    },
  );

  test(
    'the four Find items are targeted at the window with the find action once the main menu is installed',
    () {
      final src = _swift();
      final map = _findMap(src);
      final action = _findAction(src);
      final selector = RegExp(
        r'#selector\(\s*(?:self\.)?' + action.name + r'\(_:\)\s*\)',
      );
      // The attach code: the function (or closure) that walks the main menu
      // and points the items at the window.
      final menuAt = src.indexOf('NSApp.mainMenu');
      expect(
        menuAt,
        isNonNegative,
        reason: 'the items are found in the installed main menu',
      );
      expect(
        src,
        matches(RegExp(r'\.target\s*=\s*self\b')),
        reason: 'each item targets the window (not the first responder)',
      );
      expect(
        _count(src, selector),
        greaterThanOrEqualTo(2),
        reason:
            'the find action is set on the items and recognised in '
            'validateMenuItem',
      );
      expect(
        src,
        matches(
          RegExp(
            r'(?:Self\.|MainFlutterWindow\.|self\.)?' +
                map.name +
                r'(?:\[|\.keys|\.index)',
          ),
        ),
        reason: 'the attach looks items up in the same identifier lookup',
      );
      final awake = _funcBody(
        src,
        RegExp(r'override\s+func\s+awakeFromNib\(\s*\)'),
      );
      expect(
        awake,
        contains('DispatchQueue.main.async'),
        reason:
            'awakeFromNib runs while MainMenu.xib is still loading, so the '
            'items are attached on the next main-queue turn',
      );
      expect(
        awake.indexOf('DispatchQueue.main.async'),
        lessThan(awake.indexOf('super.awakeFromNib()')),
      );
    },
  );

  test(
    'the Find menu flag starts false so the four items are greyed out until Dart enables them',
    () {
      final src = _swift();
      expect(
        src,
        matches(
          RegExp(
            r'private\s+var\s+findMenuEnabled(?:\s*:\s*Bool)?\s*=\s*false\b',
          ),
        ),
      );
      expect(
        _count(src, RegExp(r'findMenuEnabled\s*=(?!=)')),
        2,
        reason:
            'the flag is written only by its false initializer and by '
            'setFindMenuEnabled',
      );
    },
  );

  test('setFindMenuEnabled takes a Bool sets the flag and replies nil', () {
    final block = _case(_windowHandler(_swift()), 'setFindMenuEnabled');
    final g = RegExp(
      r'guard\s+let\s+(\w+)\s*=\s*call\.arguments\s+as\?\s+Bool\s+else\s*\{',
    ).firstMatch(block);
    expect(g, isNotNull, reason: 'the case guards `as? Bool`:\n$block');
    final elseBody = _bracketBody(block, g!.end - 1);
    _expectBadArguments(elseBody, 'setFindMenuEnabled (not a Bool)');
    final rest = block.substring(g.end + elseBody.length + 1).trim();
    expect(
      rest,
      matches(
        RegExp(
          r'^(?:self\??\.)?findMenuEnabled\s*=\s*' +
              g.group(1)! +
              r'\s*\n\s*result\(nil\)$',
        ),
      ),
      reason:
          'after the guard the flag is set to the bound Bool as it is, then '
          'the reply is nil, with nothing else:\n$rest',
    );
    expect(_count(block, 'result(nil)'), 1);
    expect(
      _count(block, 'result('),
      3,
      reason: 'the CFBoolean refusal, the Bool refusal and the nil reply',
    );
    expect(
      _count(block, 'return'),
      2,
      reason: 'the two refusals return; nothing else exits early',
    );
  });

  test(
    'setFindMenuEnabled refuses a number that is not a CFBoolean before the Bool guard',
    () {
      // Swift's `as? Bool` bridges an NSNumber 0 or 1 (a Dart int or double),
      // so the CFBoolean check has to come first.
      final block = _case(_windowHandler(_swift()), 'setFindMenuEnabled');
      final cf = RegExp(
        r'\bif\s+let\s+(\w+)\s*=\s*call\.arguments\s+as\?\s+NSNumber\s*,\s*'
        r'CFGetTypeID\(\s*\1\s*\)\s*!=\s*CFBooleanGetTypeID\(\)\s*\{',
      ).firstMatch(block);
      expect(cf, isNotNull, reason: 'a non-CFBoolean is refused:\n$block');
      final refuse = _bracketBody(block, cf!.end - 1);
      _expectBadArguments(refuse, 'setFindMenuEnabled (a number)');
      final guardAt = block.indexOf('guard let');
      expect(guardAt, greaterThan(cf.end + refuse.length));
      expect(
        block
            .substring(0, cf.start)
            .replaceFirst('case "setFindMenuEnabled":', '')
            .trim(),
        isEmpty,
        reason: 'nothing runs before the check',
      );
      expect(
        block.substring(cf.end + refuse.length + 1, guardAt).trim(),
        isEmpty,
        reason: 'nothing runs between the check and the guard',
      );
    },
  );

  test(
    'validateMenuItem answers false for Find and Replace and the flag for the find action',
    () {
      final src = _swift();
      final action = _findAction(src);
      final body = _funcBody(
        src,
        RegExp(
          r'override\s+func\s+validateMenuItem\(\s*_\s+menuItem\s*:\s*NSMenuItem\s*\)\s*->\s*Bool',
        ),
      );
      final ifs = _ifs(body);
      final replace = ifs
          .where((i) => i.cond.contains('"find-replace"'))
          .toList();
      expect(
        replace,
        hasLength(1),
        reason: 'one branch recognises Find and Replace…:\n$body',
      );
      expect(
        replace.single.cond,
        matches(RegExp(r'^menuItem\.identifier\b.*==.*"find-replace"\)?$')),
        reason: 'by its identifier, with ==:\n${replace.single.cond}',
      );
      expect(replace.single.cond, isNot(contains('!=')));
      expect(
        replace.single.body.trim(),
        'return false',
        reason: 'Find and Replace… is always disabled (Req 16)',
      );
      final flag = ifs
          .where((i) => i.cond.contains('#selector('))
          .where((i) => i.cond.contains('${action.name}(_:)'))
          .toList();
      expect(flag, hasLength(1), reason: 'one branch for the find action');
      expect(
        flag.single.cond,
        matches(
          RegExp(
            r'^menuItem\.action\s*==\s*#selector\(\s*(?:self\.)?' +
                action.name +
                r'\(_:\)\s*\)$',
          ),
        ),
      );
      expect(
        flag.single.body.trim(),
        matches(RegExp(r'^return\s+(?:self\.)?findMenuEnabled$')),
        reason: 'the four items are enabled exactly when the flag is set',
      );
      expect(
        replace.single.start,
        lessThan(flag.single.start),
        reason: 'Find and Replace… is answered before the flag branch',
      );
      expect(
        body.trim().split('\n').last.trim(),
        'return super.validateMenuItem(menuItem)',
      );
      expect(body, isNot(matches(RegExp(r'return\s+true\b'))));
      expect(body, isNot(contains('!findMenuEnabled')));
    },
  );
}
