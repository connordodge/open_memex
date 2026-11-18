// WI #81 (Spec #61 F5; Reqs 11, 14-17; TD5): the Edit ▸ Find items in
// `MainMenu.xib`.
//
// Flutter's hidden `FlutterTextInputPlugin` is an `NSTextView`: while a
// Flutter text field has focus it is first in the responder chain and would
// catch (and grey out) a first-responder `performFindPanelAction:`, the same
// trap as `checkSpelling:` (SpellingMenuController.swift). So the five Find
// items carry identifiers instead, and MainFlutterWindow.swift finds them by
// identifier and targets itself. XCTest isn't gated, so these tests read the
// xib as text; real menu behaviour is the PR's MANUAL rows.
//
// `flutter test` runs with `app/` as the working directory, so the path is
// relative to the app package root.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _xibPath = 'macos/Runner/Base.lproj/MainMenu.xib';

/// The xib id of the Edit ▸ Find submenu.
const _findMenuId = '1b7-l0-nxx';

String _xib() {
  final f = File(_xibPath);
  expect(f.existsSync(), isTrue, reason: '$_xibPath exists under app/');
  return f.readAsStringSync();
}

Map<String, String> _attrs(String tagAttrs) => {
  for (final m in RegExp(r'([\w:]+)="([^"]*)"').allMatches(tagAttrs))
    m.group(1)!: m.group(2)!,
};

/// One `<menuItem>` of the Find submenu: its attributes and inner XML.
class _Wi81FindItem {
  _Wi81FindItem(this.attrs, this.inner);
  final Map<String, String> attrs;
  final String inner;

  String? get title => attrs['title'];
  String? get identifier => attrs['identifier'];

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

/// The inner XML of the Edit ▸ Find submenu (it has no nested menus).
String _findMenu(String xib) {
  final start = RegExp(
    '<menu\\b[^>]*\\bid="$_findMenuId"[^>]*>',
  ).firstMatch(xib);
  expect(start, isNotNull, reason: 'the Find submenu ($_findMenuId) exists');
  expect(start!.group(0), contains('key="submenu"'));
  expect(start.group(0), contains('title="Find"'));
  final end = xib.indexOf('</menu>', start.end);
  expect(end, greaterThan(start.end), reason: 'the Find submenu is closed');
  final inner = xib.substring(start.end, end);
  expect(inner, isNot(contains('<menu ')), reason: 'no nested menu');
  return inner;
}

List<_Wi81FindItem> _items(String menuXml) => [
  for (final m in RegExp(
    r'<menuItem\b([^>]*?)(?:/>|>([\s\S]*?)</menuItem>)',
  ).allMatches(menuXml))
    _Wi81FindItem(_attrs(m.group(1)!), m.group(2) ?? ''),
];

_Wi81FindItem _byIdentifier(List<_Wi81FindItem> items, String identifier) {
  final found = items.where((i) => i.identifier == identifier).toList();
  expect(
    found,
    hasLength(1),
    reason: 'the Find submenu has one item with identifier "$identifier"',
  );
  return found.single;
}

/// The five Find items: identifier, title, key equivalent and whether the
/// mask adds option and shift (command is always set: the default mask for
/// an item with no `<modifierMask>` is ⌘).
const _findItems = <(String, String, String, bool, bool)>[
  ('find-show', 'Find…', 'f', false, false),
  ('find-replace', 'Find and Replace…', 'f', true, false),
  ('find-next', 'Find Next', 'g', false, false),
  // An upper-case "G" is ⇧⌘G: AppKit adds shift for a capital letter.
  ('find-previous', 'Find Previous', 'G', false, false),
  ('find-use-selection', 'Use Selection for Find', 'e', false, false),
];

void main() {
  test(
    'MainMenu.xib holds the five Find items with their identifiers titles and key equivalents',
    () {
      final xib = _xib();
      final items = _items(_findMenu(xib));
      for (final (id, title, key, option, shift) in _findItems) {
        final item = _byIdentifier(items, id);
        expect(item.title, title, reason: '$id keeps its title');
        expect(
          item.attrs['keyEquivalent'],
          key,
          reason: '$id keeps its key equivalent',
        );
        final mask = item.modifierMask;
        if (option || shift) {
          expect(mask, isNotNull, reason: '$id sets its modifier mask');
          expect(mask!['command'], 'YES', reason: '$id keeps ⌘');
          expect(mask['option'], option ? 'YES' : isNot('YES'));
          expect(mask['shift'], shift ? 'YES' : isNot('YES'));
          expect(mask['control'], isNot('YES'));
        } else {
          expect(
            mask,
            isNull,
            reason: '$id keeps the default ⌘ mask (no explicit mask)',
          );
        }
        expect(
          RegExp('identifier="$id"').allMatches(xib),
          hasLength(1),
          reason: 'identifier $id appears once in the whole menu bar',
        );
        expect(
          RegExp('title="$title"').allMatches(xib),
          hasLength(1),
          reason: '"$title" appears once in the whole menu bar',
        );
      }
      // Titles use an ellipsis (U+2026), not three dots.
      expect(items.where((i) => i.title == 'Find...'), isEmpty);
      expect(items.where((i) => i.title == 'Find and Replace...'), isEmpty);
    },
  );

  test(
    'the Find submenu keeps Jump to Selection with its first-responder action after the five Find items',
    () {
      final items = _items(_findMenu(_xib()));
      expect(items.map((i) => i.title), [
        'Find…',
        'Find and Replace…',
        'Find Next',
        'Find Previous',
        'Use Selection for Find',
        'Jump to Selection',
      ]);
      final jump = items.last;
      expect(jump.attrs['keyEquivalent'], 'j');
      expect(jump.identifier, isNull);
      expect(jump.actions, [
        {
          'selector': 'centerSelectionInVisibleArea:',
          'target': '-1',
          'id': 'IOG-6D-g5B',
        },
      ]);
    },
  );

  test(
    'no Find item keeps a performFindPanelAction action and the xib has none left',
    () {
      final xib = _xib();
      final items = _items(_findMenu(xib));
      for (final (id, _, _, _, _) in _findItems) {
        final item = _byIdentifier(items, id);
        expect(
          item.actions.where((a) => a['selector'] == 'performFindPanelAction:'),
          isEmpty,
          reason:
              '$id has no performFindPanelAction: (the hidden '
              'FlutterTextInputPlugin text view would catch it)',
        );
        expect(
          item.actions.where((a) => a['target'] == '-1'),
          isEmpty,
          reason: '$id has no first-responder action at all',
        );
      }
      expect(
        xib,
        isNot(contains('performFindPanelAction:')),
        reason: 'no other item in the menu bar keeps the action either',
      );
    },
  );

  test('the Find items keep the xib well formed with unique ids', () {
    final xib = _xib();
    final ids = RegExp(
      r'\sid="([^"]+)"',
    ).allMatches(xib).map((m) => m.group(1)!).toList();
    final seen = <String>{};
    final dupes = [
      for (final id in ids)
        if (!seen.add(id)) id,
    ];
    expect(dupes, isEmpty, reason: 'every xib id is unique');
    // Every element is closed in order.
    final stack = <String>[];
    for (final m in RegExp(
      r'<(/?)([A-Za-z][\w.:-]*)\b[^>]*?(/?)>',
    ).allMatches(xib)) {
      if (m.group(3) == '/') continue;
      if (m.group(1) == '/') {
        expect(stack, isNotEmpty, reason: 'unexpected </${m.group(2)}>');
        expect(stack.removeLast(), m.group(2));
      } else {
        stack.add(m.group(2)!);
      }
    }
    expect(stack, isEmpty);
  });
}
