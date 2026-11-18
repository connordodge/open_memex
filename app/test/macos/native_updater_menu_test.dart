// WI #39 (A5, Spec #31 req 13, TD4; D5): source contract for the native half
// of Open Memex ▸ Check for Updates….
//
// XCTest isn't gated and the AC map takes no Swift path, so these tests read
// `MainMenu.xib` and `MainFlutterWindow.swift` as text (the pattern of
// native_agents_menu_test.dart, which this WI never edits) and pin the
// wiring: the menu item between About and the separator above Preferences…,
// its explicit target and action, the `open_memex/updater` channel made in
// `awakeFromNib` before `super`, the one-line `checkForUpdates(_:)`
// pass-through (lesson #347), no Dart → native handler, `validateMenuItem`
// untouched and a doc-comment section after the Files section. They are
// text pins, not behaviour: the real menu is the PR's MANUAL row.
//
// `flutter test` runs with `app/` as the working directory.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/updater_menu_host.dart';

const _xibPath = 'macos/Runner/Base.lproj/MainMenu.xib';
const _swiftPath = 'macos/Runner/MainFlutterWindow.swift';

/// The xib id of the app (`APP_NAME`) submenu.
const _appMenuId = 'uQy-DD-JDr';

/// The MainFlutterWindow's xib id.
const _windowId = 'QvC-M9-y7g';

const _title = 'Check for Updates…';

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

class _Wi39MenuItem {
  _Wi39MenuItem(this.attrs, this.inner);
  final Map<String, String> attrs;
  final String inner;

  String? get title => attrs['title'];
  String? get id => attrs['id'];
  bool get isSeparator => attrs['isSeparatorItem'] == 'YES';

  List<Map<String, String>> get actions => [
    for (final m in RegExp(r'<action\b([^>]*)/>').allMatches(inner))
      _attrs(m.group(1)!),
  ];
}

/// The app submenu's `<items>` XML (its Services submenu is self-closing).
String _appMenu(String xib) {
  final start = RegExp(
    '<menu key="submenu"[^>]*id="$_appMenuId"[^>]*>',
  ).firstMatch(xib);
  expect(start, isNotNull, reason: 'the app submenu ($_appMenuId) exists');
  final end = xib.indexOf('</items>', start!.end);
  expect(end, greaterThan(start.end));
  return xib.substring(start.end, end);
}

List<_Wi39MenuItem> _items(String menuXml) => [
  for (final m in RegExp(
    r'<menuItem\b([^>]*?)(?:/>|>([\s\S]*?)</menuItem>)',
  ).allMatches(menuXml))
    _Wi39MenuItem(_attrs(m.group(1)!), m.group(2) ?? ''),
];

// -------------------------------------------------------------- Swift -----

/// The text inside the braces that open at [open], skipping string
/// literals.
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

String _funcBody(String src, RegExp decl) {
  final m = decl.firstMatch(src);
  expect(m, isNotNull, reason: '$_swiftPath declares ${decl.pattern}');
  return _braceBody(src, src.indexOf('{', m!.end));
}

String _awakeFromNib(String src) =>
    _funcBody(src, RegExp(r'override\s+func\s+awakeFromNib\(\s*\)'));

/// The doc comment above `class MainFlutterWindow`, `///` stripped.
List<String> _docLines(String src) {
  final classAt = src.indexOf('class MainFlutterWindow');
  expect(classAt, isNonNegative);
  return src
      .substring(0, classAt)
      .split('\n')
      .where((l) => l.trimLeft().startsWith('///'))
      .map((l) => l.trimLeft().substring(3))
      .toList();
}

/// Bullets (`- …` joined with their indented continuations) of [lines].
List<String> _bullets(Iterable<String> lines) {
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

void main() {
  group('MainMenu.xib', () {
    test(
      'the app menu has Check for Updates directly after About and before the separator above Preferences',
      () {
        final items = _items(_appMenu(_xib()));
        final ids = [for (final i in items) i.id];
        final about = ids.indexOf('5kV-Vb-QxS');
        expect(about, isNonNegative, reason: 'About APP_NAME is there');
        expect(
          items.where((i) => i.title == _title),
          hasLength(1),
          reason: 'one "$_title" item in the app menu',
        );
        expect(items[about + 1].title, _title, reason: 'directly under About');
        expect(items[about + 2].id, 'VOq-y0-SEH');
        expect(items[about + 2].isSeparator, isTrue);
        expect(items[about + 3].title, 'Preferences…');
        expect(items[about + 3].id, 'BOF-NM-1cW');
      },
    );

    test(
      'Check for Updates targets MainFlutterWindow checkForUpdates explicitly',
      () {
        final xib = _xib();
        final window = RegExp(
          r'<window\b[^>]*\bid="([^"]+)"[^>]*customClass="MainFlutterWindow"',
        ).firstMatch(xib);
        expect(window, isNotNull);
        expect(window!.group(1), _windowId);

        final matching = _items(
          _appMenu(xib),
        ).where((i) => i.title == _title).toList();
        expect(matching, hasLength(1), reason: 'one "$_title" item');
        final item = matching.single;
        expect(item.actions, hasLength(1), reason: 'one action connection');
        final action = item.actions.single;
        expect(action['selector'], 'checkForUpdates:');
        expect(
          action['target'],
          _windowId,
          reason: 'an explicit target (the window), not the first responder -1',
        );
        expect(
          item.attrs['keyEquivalent'] ?? '',
          isEmpty,
          reason: 'no shortcut',
        );

        final allIds = RegExp(
          r'\bid="([^"]+)"',
        ).allMatches(xib).map((m) => m.group(1)!).toList();
        for (final id in [item.id, action['id']]) {
          expect(id, isNotNull);
          expect(
            allIds.where((i) => i == id),
            hasLength(1),
            reason: 'xib id $id is unique',
          );
        }
      },
    );

    test('About keeps its standard about panel action', () {
      final about = _items(
        _appMenu(_xib()),
      ).singleWhere((i) => i.id == '5kV-Vb-QxS');
      expect(about.actions, [
        {
          'selector': 'orderFrontStandardAboutPanel:',
          'target': '-1',
          'id': 'Exp-CZ-Vem',
        },
      ]);
    });
  });

  group('MainFlutterWindow.swift', () {
    test('awakeFromNib creates the open_memex/updater channel before super', () {
      final src = _swift();
      expect(
        src,
        matches(
          RegExp(
            r'private\s+var\s+updaterChannel\s*:\s*FlutterMethodChannel\?',
          ),
        ),
        reason: 'the window holds the channel in updaterChannel',
      );
      final body = _awakeFromNib(src);
      final made = RegExp(
        r'(?:(?:let|var)\s+(\w+)|(updaterChannel))\s*=\s*FlutterMethodChannel\(\s*'
        r'name:\s*"open_memex/updater"\s*,\s*'
        r'binaryMessenger:\s*flutterViewController\.engine\.binaryMessenger\s*\)',
      ).firstMatch(body);
      expect(
        made,
        isNotNull,
        reason: 'awakeFromNib makes the open_memex/updater channel',
      );
      final superAt = body.indexOf('super.awakeFromNib()');
      expect(superAt, isNonNegative);
      expect(made!.start, lessThan(superAt), reason: 'before super');
      final local = made.group(1);
      if (local != null) {
        final assigned = RegExp(
          r'updaterChannel\s*=\s*' + local + r'\b',
        ).firstMatch(body);
        expect(assigned, isNotNull, reason: 'updaterChannel = $local');
        expect(assigned!.start, lessThan(superAt));
        expect(
          src,
          isNot(contains('$local.setMethodCallHandler')),
          reason: 'TD4: no Dart → native methods',
        );
      }
      expect(
        src,
        isNot(matches(RegExp(r'updaterChannel\??\.setMethodCallHandler'))),
        reason: 'TD4: no Dart → native methods',
      );
      expect(
        RegExp('"open_memex/updater"').allMatches(src),
        hasLength(1),
        reason: 'one updater channel',
      );
    });

    test(
      'checkForUpdates action only sends checkForUpdatesFromMenu with no arguments',
      () {
        final body = _funcBody(
          _swift(),
          RegExp(
            r'@IBAction\s+func\s+checkForUpdates\(\s*_\s+sender\s*:\s*Any\?\s*\)',
          ),
        );
        expect(
          body.trim(),
          matches(
            RegExp(
              r'^updaterChannel\?\.invokeMethod\(\s*"checkForUpdatesFromMenu"\s*,\s*arguments:\s*nil\s*\)$',
            ),
          ),
          reason: 'a one-line pass-through (lesson #347)',
        );
      },
    );

    test(
      'the doc comment has an updater channel section after the files section',
      () {
        final doc = _docLines(_swift());
        final filesAt = doc.indexWhere(
          (l) => l.contains('Files channel `open_memex/files`'),
        );
        final updaterAt = doc.indexWhere(
          (l) => l.contains('Updater channel `open_memex/updater`'),
        );
        expect(filesAt, isNonNegative);
        expect(updaterAt, greaterThan(filesAt), reason: 'after Files');
        final bullets = _bullets(doc.sublist(updaterAt + 1));
        expect(
          bullets.where(
            (b) =>
                b.contains('native → Dart') &&
                b.contains('`checkForUpdatesFromMenu`'),
          ),
          isNotEmpty,
          reason: 'it lists native → Dart checkForUpdatesFromMenu:\n$bullets',
        );
        expect(
          bullets.where((b) => b.contains('Dart → native')),
          isEmpty,
          reason: 'TD4: the updater channel has no Dart → native method',
        );
      },
    );

    test(
      'validateMenuItem stays as it was and never mentions checkForUpdates',
      () {
        final body = _funcBody(
          _swift(),
          RegExp(
            r'override\s+func\s+validateMenuItem\(\s*_\s+menuItem\s*:\s*NSMenuItem\s*\)\s*->\s*Bool',
          ),
        );
        expect(body.trim().split('\n').map((l) => l.trim()).toList(), [
          'if menuItem.action == #selector(openAgents(_:)) {',
          'return agentsMenuEnabled',
          '}',
          'return super.validateMenuItem(menuItem)',
        ]);
      },
    );

    test('no new Swift file is added to the Runner', () {
      final swift = [
        for (final f in Directory('macos/Runner').listSync())
          if (f is File && f.path.endsWith('.swift')) f.uri.pathSegments.last,
      ]..sort();
      expect(swift, [
        'AppDelegate.swift',
        'MainFlutterWindow.swift',
        'SpellingMenuController.swift',
      ]);
    });
  });

  test('the Dart updater channel name matches the native one', () {
    expect(updaterChannel.name, 'open_memex/updater');
  });
}
