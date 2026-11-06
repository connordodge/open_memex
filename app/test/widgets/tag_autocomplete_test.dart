// WI #246 (A2, Spec #234 R22-R25, L14, L17; lead rulings in the context pack):
// the `#` type-ahead over existing tags, in the same host as `[[`
// (TextSegmentField), so in live preview rows and the Source field.
//
// D41 (Connor): Enter on a tag typed in full makes a new line, and only typing
// opens the popover.
//
// Keys the tests read: `tag-autocomplete` (the box), `tag-autocomplete-item-<tag>`
// (a tag row), `tag-autocomplete-create` (the create row).
//
// Every test that asserts the popover stays closed first opens it on a known
// text (`_expectOpens`), so it cannot pass against a popover that never opens.
import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/tags_reads.dart';
import 'package:open_memex_app/src/editor/tag_grammar.dart';
import 'package:open_memex_app/src/state/tags_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';
import 'package:open_memex_app/src/widgets/tag_autocomplete.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/editor_scope.dart';
import '../support/font_fetch_hold.dart';
import '../support/tags_seed.dart';

const _itemPrefix = 'tag-autocomplete-item-';

final Finder _popover = find.byKey(const Key('tag-autocomplete'));
final Finder _createRow = find.byKey(const Key('tag-autocomplete-create'));
final Finder _wikilinkPopover = find.byKey(const Key('wikilink-popover'));

Finder _row(String tag) => find.byKey(Key('$_itemPrefix$tag'));

Finder _wikilinkItem(String title) =>
    find.byKey(Key('wikilink-popover-item-$title'));

TagRow _tag(String name, int count) =>
    TagRow(tag: name, noteCount: count, system: isSystemTag(name));

/// A vault's tags, in the order the provider returns them: alphabetical, so
/// a count sort is visible.
final List<TagRow> _sample = [
  _tag('health', 2),
  _tag('memex', 12),
  _tag('pricing', 3),
  _tag('reading', 5),
  _tag('work', 7),
];

Override _tagsLoad(List<TagRow> tags) => tagsAsyncProvider.overrideWith(
  (ref) async => VaultScoped(ref.watch(currentVaultProvider), tags),
);

/// Lets a provider's future and the frames after it land, without wall time.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump();
  }
}

/// A focused [TextSegmentField] whose tags load [tags] (or [overrides]).
Future<TextEditingController> _pumpField(
  WidgetTester tester, {
  List<TagRow>? tags,
  TextEditingController? controller,
  KindChipHost? chips,
  List<Override>? overrides,
  List<NoteTitle> titles = const [],
  ValueChanged<String>? onChanged,
  FocusNode? Function()? onMoveDown,
}) async {
  final field = controller ?? TextEditingController();
  addTearDown(field.dispose);
  final host = chips ?? KindChipHost();
  if (chips == null) addTearDown(host.dispose);
  await pumpEditorScoped(
    tester,
    MaterialApp(
      home: Scaffold(
        body: TextSegmentField(
          controller: field,
          kindChips: host,
          onChanged: onChanged,
          onMoveDown: onMoveDown,
        ),
      ),
    ),
    titles: titles,
    overrides: overrides ?? [_tagsLoad(tags ?? _sample)],
  );
  await _flush(tester);
  await tester.showKeyboard(find.byType(TextField));
  await tester.pump();
  return field;
}

/// Sets the field's text as typing does, with the caret at [caret] (default:
/// the end).
Future<void> _type(
  WidgetTester tester,
  TextEditingController field,
  String text, {
  int? caret,
}) async {
  field.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret ?? text.length),
  );
  await tester.pump();
}

/// The positive control: a mid-line bare `#` opens the popover here.
Future<void> _expectOpens(
  WidgetTester tester,
  TextEditingController field,
) async {
  await _type(tester, field, 'x #');
  expect(_popover, findsOneWidget, reason: 'control: x # opens the popover');
}

/// The tag rows on screen, top to bottom.
List<String> _rowNames() {
  final rows = find
      .byWidgetPredicate((w) {
        final key = w.key;
        return key is ValueKey<String> && key.value.startsWith(_itemPrefix);
      })
      .evaluate()
      .toList();
  double top(Element e) =>
      (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy;
  rows.sort((a, b) => top(a).compareTo(top(b)));
  return [
    for (final e in rows)
      ((e.widget.key! as ValueKey<String>).value).substring(_itemPrefix.length),
  ];
}

bool _isSelected(Finder row) => find
    .descendant(
      of: row,
      matching: find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == OmColors.surface4,
      ),
    )
    .evaluate()
    .isNotEmpty;

/// The tag rows and the create row that show as selected.
List<String> _selectedRows() => [
  for (final name in _rowNames())
    if (_isSelected(_row(name))) name,
  if (_createRow.evaluate().isNotEmpty && _isSelected(_createRow)) 'create',
];

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(TextSegmentField)));

Text _textIn(WidgetTester tester, Finder row, String data) =>
    tester.widget(find.descendant(of: row, matching: find.text(data)));

Icon _iconIn(WidgetTester tester, Finder row) =>
    tester.widget(find.descendant(of: row, matching: find.byType(Icon)));

KeyDownEvent _down(LogicalKeyboardKey key) => KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.keyA,
  logicalKey: key,
  timeStamp: Duration.zero,
);

KeyRepeatEvent _repeat(LogicalKeyboardKey key) => KeyRepeatEvent(
  physicalKey: PhysicalKeyboardKey.keyA,
  logicalKey: key,
  timeStamp: Duration.zero,
);

KeyUpEvent _up(LogicalKeyboardKey key) => KeyUpEvent(
  physicalKey: PhysicalKeyboardKey.keyA,
  logicalKey: key,
  timeStamp: Duration.zero,
);

/// A bare [TagAutocomplete] with a caret at [caret], for placement and the key
/// contract the host relies on.
Future<({TextEditingController field, GlobalKey<TagAutocompleteState> key})>
_pumpBare(
  WidgetTester tester, {
  Offset caret = const Offset(20, 20),
  List<TagRow>? tags,
}) async {
  final field = TextEditingController();
  addTearDown(field.dispose);
  final key = GlobalKey<TagAutocompleteState>();
  await pumpEditorScoped(
    tester,
    MaterialApp(
      home: Scaffold(
        body: TagAutocomplete(
          key: key,
          controller: field,
          caretLocator: () => caret,
        ),
      ),
    ),
    overrides: [_tagsLoad(tags ?? _sample)],
  );
  await _flush(tester);
  return (field: field, key: key);
}

void main() {
  holdFontFetches();

  group('opening rule at line start', () {
    testWidgets(
      'at line start a bare hash shows no popover and hash p opens it',
      (tester) async {
        final field = await _pumpField(tester);

        await _type(tester, field, '#');
        expect(_popover, findsNothing);

        await _type(tester, field, '#p');
        expect(_popover, findsOneWidget);
        expect(_rowNames(), ['pricing']);
      },
    );

    testWidgets(
      'line start means column 0 of any line of the field, not only the first',
      (tester) async {
        final field = await _pumpField(tester);

        await _expectOpens(tester, field);
        await _type(tester, field, 'first\n#');
        expect(_popover, findsNothing);

        await _type(tester, field, 'first\n#p');
        expect(_popover, findsOneWidget);
      },
    );

    testWidgets(
      'the caret right after a line start hash is still a bare hash',
      (tester) async {
        final field = await _pumpField(tester);

        await _expectOpens(tester, field);
        await _type(tester, field, '#pricing', caret: 1);
        expect(_popover, findsNothing);
      },
    );

    testWidgets(
      'hash space closes the popover and leaves a heading and deeper markers never open it',
      (tester) async {
        final field = await _pumpField(tester);

        await _type(tester, field, '#p');
        expect(_popover, findsOneWidget);

        await _type(tester, field, '# ');
        expect(_popover, findsNothing);
        expect(field.text, '# ');

        for (final text in ['##', '## x', '## ', '##p']) {
          await _type(tester, field, text);
          expect(_popover, findsNothing, reason: text);
        }
      },
    );

    testWidgets(
      'heading markers of depth two to six never open at line start',
      (tester) async {
        final field = await _pumpField(tester);

        await _expectOpens(tester, field);
        for (final marker in ['##', '###', '####', '#####', '######']) {
          await _type(tester, field, marker);
          expect(_popover, findsNothing, reason: marker);
          await _type(tester, field, '$marker ');
          expect(_popover, findsNothing, reason: '$marker then a space');
          await _type(tester, field, '$marker x');
          expect(_popover, findsNothing, reason: '$marker then text');
        }
        await _type(tester, field, 'first\n###');
        expect(_popover, findsNothing, reason: 'a marker on a later line');
      },
    );

    testWidgets('an indented hash is mid-line so a bare hash opens', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      for (final text in ['  #', '\t#', 'first\n  #', '- #', '> #']) {
        await _type(tester, field, 'plain');
        expect(_popover, findsNothing);
        await _type(tester, field, text);
        expect(_popover, findsOneWidget, reason: text);
      }
    });

    testWidgets(
      'a bare hash in a live preview item row opens because its marker is outside the field',
      (tester) async {
        final item = LivePreviewController()..itemText = true;
        final field = await _pumpField(tester, controller: item);

        await _type(tester, field, '#');
        expect(_popover, findsOneWidget);
      },
    );

    testWidgets(
      'a bare hash at column 0 of a live preview prose row stays closed',
      (tester) async {
        final prose = LivePreviewController();
        final field = await _pumpField(tester, controller: prose);

        await _expectOpens(tester, field);
        await _type(tester, field, '#');
        expect(_popover, findsNothing);
      },
    );

    testWidgets('a hash on a heading text line opens like any mid-line hash', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      for (final text in ['# #', '## x #', '# #p']) {
        await _type(tester, field, 'plain');
        expect(_popover, findsNothing);
        await _type(tester, field, text);
        expect(_popover, findsOneWidget, reason: text);
      }
    });
  });

  group('opening rule mid-line', () {
    testWidgets(
      'mid-line a bare hash opens listing most-used tags first and a hash after a letter does not',
      (tester) async {
        final field = await _pumpField(tester);

        await _type(tester, field, '- call with Sam #');
        expect(_popover, findsOneWidget);
        expect(_rowNames(), ['memex', 'work', 'reading', 'pricing', 'health']);
        expect(_selectedRows(), ['memex'], reason: 'the first row is selected');
        expect(
          _createRow,
          findsNothing,
          reason: 'nothing typed, no create row',
        );

        await _type(tester, field, 'a#');
        expect(_popover, findsNothing);
        await _type(tester, field, 'a#p');
        expect(_popover, findsNothing);
      },
    );

    testWidgets('a bare hash sorts equal counts alphabetically', (
      tester,
    ) async {
      final field = await _pumpField(
        tester,
        tags: [
          _tag('zebra', 4),
          _tag('apple', 4),
          _tag('most', 9),
          _tag('mango', 4),
        ],
      );

      await _type(tester, field, 'x #');
      expect(_rowNames(), ['most', 'apple', 'mango', 'zebra']);
    });

    testWidgets('a bare hash leaves the provider list in its own order', (
      tester,
    ) async {
      final tags = [_tag('apple', 1), _tag('mango', 5), _tag('zebra', 3)];
      final field = await _pumpField(tester, tags: tags);

      await _type(tester, field, 'x #');
      expect(_rowNames(), ['mango', 'zebra', 'apple']);
      expect(tags.map((t) => t.tag), ['apple', 'mango', 'zebra']);
    });

    testWidgets('the last hash before the caret holds the query', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #one #pr');
      expect(_rowNames(), ['pricing']);

      await _press(tester, LogicalKeyboardKey.enter);
      expect(field.text, 'x #one #pricing ');

      await _type(tester, field, 'x #one #');
      expect(_rowNames().first, 'memex', reason: 'a second hash is bare');
    });

    testWidgets('a hash opens after each opener of the tag grammar', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      for (final before in [
        'x ',
        '(',
        '[',
        '{',
        '"',
        "'",
        'x\u00A0',
        'x\u3000',
        'x\t',
      ]) {
        await _type(tester, field, 'plain');
        expect(_popover, findsNothing);
        await _type(tester, field, '$before#');
        expect(_popover, findsOneWidget, reason: 'after <$before>');
      }
    });

    testWidgets('a hash does not open after a character the grammar rejects', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _expectOpens(tester, field);
      for (final text in ['a#', '1#', '.#', '-#', ')#', 'x ##', 'x #a#']) {
        await _type(tester, field, text);
        expect(_popover, findsNothing, reason: text);
      }
    });

    testWidgets('the query must be a tag name prefix or the popover closes', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _expectOpens(tester, field);
      for (final text in [
        '# ',
        '#1',
        '#a b',
        'x #1',
        'x # ',
        'x #a b',
        'x #-a',
        'x #_a',
        'x #a.b',
        'x #a!',
        'x #\u{1F600}',
      ]) {
        await _type(tester, field, text);
        expect(_popover, findsNothing, reason: text);
      }
    });

    testWidgets(
      'a query of letters, marks, digits, dash and underscore keeps it open',
      (tester) async {
        final field = await _pumpField(tester);

        for (final text in [
          '#q3',
          '#q3-',
          '#q3_',
          '#a-b_c9',
          '#café',
          '#café',
          '#пр',
          '#\u{1D49C}b',
        ]) {
          await _type(tester, field, 'plain');
          expect(_popover, findsNothing);
          await _type(tester, field, text);
          expect(_popover, findsOneWidget, reason: text);
        }
      },
    );

    testWidgets('a newline closes it and only the caret line is scanned', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _expectOpens(tester, field);
      await _type(tester, field, 'x #\n');
      expect(_popover, findsNothing);
      await _type(tester, field, 'x #\nplain');
      expect(_popover, findsNothing);
      await _type(tester, field, 'x #\ny #');
      expect(_popover, findsOneWidget);
      await _type(tester, field, 'x #\ny');
      expect(_popover, findsNothing);
    });

    testWidgets(
      'a long line opens it from any distance, with no fixed scan window',
      (tester) async {
        final field = await _pumpField(tester);
        final long = 'word ' * 40;

        await _type(tester, field, 'plain');
        expect(_popover, findsNothing);
        await _type(tester, field, '$long#');
        expect(_popover, findsOneWidget);
        final longQuery = 'q' * 80;
        await _type(tester, field, 'x #$longQuery');
        expect(_popover, findsOneWidget);
        expect(_createRow, findsOneWidget);
      },
    );

    testWidgets(
      'moving the caret off the hash or clearing it closes the popover',
      (tester) async {
        final field = await _pumpField(tester);

        await _expectOpens(tester, field);
        await _type(tester, field, 'x #', caret: 1);
        expect(_popover, findsNothing);

        // Retyped: a caret move back would not reopen it (D41).
        await _type(tester, field, 'x ');
        await _expectOpens(tester, field);
        await _type(tester, field, 'x #', caret: 0);
        expect(_popover, findsNothing);
      },
    );

    testWidgets('a cleared selection closes the popover', (tester) async {
      final bare = await _pumpBare(tester);
      bare.field.value = const TextEditingValue(
        text: 'x #',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();
      expect(bare.key.currentState!.isOpen, isTrue);

      bare.field.selection = const TextSelection.collapsed(offset: -1);
      await tester.pump();
      expect(bare.key.currentState!.isOpen, isFalse);
      expect(_popover, findsNothing);
    });

    testWidgets('the query ends at the caret when text follows it', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #pr tail', caret: 5);
      expect(_popover, findsOneWidget);
      expect(_rowNames(), ['pricing']);

      await _type(tester, field, 'x #pricing', caret: 3);
      expect(_createRow, findsNothing);
      expect(_rowNames().first, 'memex', reason: 'bare, so most-used first');
    });
  });

  group('ranking and rows', () {
    testWidgets(
      'hash prc lists pricing first and a prefix beats a substring beats in-order letters',
      (tester) async {
        final field = await _pumpField(
          tester,
          tags: [
            _tag('core', 90),
            _tag('memex', 12),
            _tag('pricing', 3),
            _tag('reading', 1),
            _tag('rome', 90),
            _tag('work', 7),
          ],
        );

        await _type(tester, field, 'x #prc');
        expect(_rowNames(), ['pricing']);
        expect(_selectedRows(), ['pricing']);

        await _type(tester, field, 'x #re');
        expect(_rowNames(), [
          'reading',
          'core',
          'rome',
        ], reason: 'match kind decides, whatever the count');
        expect(_selectedRows(), ['reading']);
      },
    );

    testWidgets('matching ignores the case of the query', (tester) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #PRC');
      expect(_rowNames(), ['pricing']);
    });

    testWidgets('equal scores keep the provider order, stably, past 32 tags', (
      tester,
    ) async {
      String name(int i) => 't${i.toString().padLeft(2, '0')}';
      final field = await _pumpField(
        tester,
        tags: [for (var i = 0; i < 40; i++) _tag(name(i), 40 - i)],
      );

      await _type(tester, field, 'x #t');
      expect(_rowNames(), [for (var i = 0; i < 8; i++) name(i)]);
    });

    testWidgets('a row shows the tag and its count and at most 8 rows show', (
      tester,
    ) async {
      final field = await _pumpField(
        tester,
        tags: [for (var i = 1; i <= 9; i++) _tag('tag$i', i * 10)],
      );

      await _type(tester, field, 'x #');
      expect(_rowNames(), [
        for (var i = 9; i >= 2; i--) 'tag$i',
      ], reason: 'the 8 most used of 9');
      expect(_row('tag1'), findsNothing);

      final top = _row('tag9');
      expect(
        find.descendant(of: top, matching: find.text('tag9')),
        findsOneWidget,
        reason: 'the bare name, no #',
      );
      expect(
        find.descendant(of: top, matching: find.text('90')),
        findsOneWidget,
      );
    });

    testWidgets('exactly 8 tags all show', (tester) async {
      final field = await _pumpField(
        tester,
        tags: [for (var i = 1; i <= 8; i++) _tag('tag$i', i)],
      );

      await _type(tester, field, 'x #');
      expect(_rowNames(), hasLength(8));
      expect(_row('tag1'), findsOneWidget);
    });

    testWidgets(
      'a typed query shows at most 8 tag rows and then the create row',
      (tester) async {
        final field = await _pumpField(
          tester,
          tags: [for (var i = 1; i <= 9; i++) _tag('tag$i', i)],
        );

        await _type(tester, field, 'x #ta');
        expect(_rowNames(), hasLength(8));
        expect(_createRow, findsOneWidget);
        expect(
          tester.getTopLeft(_createRow).dy,
          greaterThan(tester.getTopLeft(_row(_rowNames().last)).dy),
          reason: 'the create row is always last',
        );
      },
    );

    testWidgets('system tags never appear', (tester) async {
      final field = await _pumpField(
        tester,
        tags: [
          _tag('agent-authored', 90),
          _tag('inbox', 80),
          _tag('pricing', 3),
        ],
      );

      await _type(tester, field, 'x #');
      expect(_rowNames(), ['pricing']);

      await _type(tester, field, 'x #inb');
      expect(_rowNames(), isEmpty);
      await _type(tester, field, 'x #agent');
      expect(_rowNames(), isEmpty);
    });

    testWidgets(
      'a vault with only system tags and an empty query shows nothing',
      (tester) async {
        final field = await _pumpField(tester, tags: [_tag('inbox', 3)]);

        await _type(tester, field, 'x #inbo');
        expect(_createRow, findsOneWidget);
        await _type(tester, field, 'x #');
        expect(_popover, findsNothing);
      },
    );

    testWidgets('a tag row follows the design pack values', (tester) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #pr');

      expect(tester.getSize(_popover).width, 320);
      final row = _row('pricing');
      expect(tester.getSize(row).height, moreOrLessEquals(34, epsilon: 0.01));
      expect(tester.getSize(row).width, 320);
      expect(
        tester.getTopLeft(row).dy - tester.getTopLeft(_popover).dy,
        moreOrLessEquals(4, epsilon: 0.01),
        reason: 'vertical list padding',
      );

      final icon = _iconIn(tester, row);
      expect(icon.icon, LucideIcons.hash);
      expect(icon.size, 12);
      expect(icon.color, OmColors.fg2);

      final name = _textIn(tester, row, 'pricing');
      expect(name.style!.fontSize, 13);
      expect(name.style!.height! * 13, moreOrLessEquals(18, epsilon: 0.01));
      expect(name.style!.color, OmColors.fg0);
      expect(name.style!.fontFamily, contains('InterTight'));
      expect(name.overflow, TextOverflow.ellipsis);
      expect(name.maxLines, 1);

      final count = _textIn(tester, row, '3');
      expect(count.style!.fontSize, 11);
      expect(count.style!.height! * 11, moreOrLessEquals(18, epsilon: 0.01));
      expect(count.style!.color, OmColors.fg2);
      expect(count.style!.fontFamily, contains('JetBrainsMono'));
      final countRight = tester
          .getTopRight(find.descendant(of: row, matching: find.text('3')))
          .dx;
      expect(
        tester.getTopRight(row).dx - countRight,
        moreOrLessEquals(12, epsilon: 0.01),
        reason: 'the count is right-aligned inside 12 px padding',
      );
      expect(
        tester
            .getTopLeft(
              find.descendant(of: row, matching: find.text('pricing')),
            )
            .dx,
        lessThan(countRight),
      );

      expect(_isSelected(row), isTrue);
      expect(_isSelected(_createRow), isFalse);
    });

    testWidgets('the box and the create row follow the design pack values', (
      tester,
    ) async {
      final field = await _pumpField(
        tester,
        tags: [for (var i = 1; i <= 9; i++) _tag('tag$i', i)],
      );

      await _type(tester, field, 'x #ta');
      final material = tester.widget<Material>(
        find.ancestor(of: _popover, matching: find.byType(Material)).first,
      );
      expect(material.color, OmColors.surface3);
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(6));
      expect(shape.side.color, OmColors.line3);
      expect(
        tester.getSize(_popover).height,
        lessThanOrEqualTo(280),
        reason: '8 rows and the create row scroll inside the 280 max',
      );

      final icon = _iconIn(tester, _createRow);
      expect(icon.icon, LucideIcons.plus);
      expect(icon.size, 12);
      expect(icon.color, OmColors.accent);
      final label = _textIn(tester, _createRow, 'Create new tag #ta');
      expect(label.style!.fontSize, 13);
      expect(label.style!.height! * 13, moreOrLessEquals(18, epsilon: 0.01));
      expect(label.style!.color, OmColors.accent);
    });
  });

  group('create row', () {
    testWidgets(
      'a query with no match shows the create row only and it is selected',
      (tester) async {
        final field = await _pumpField(tester);

        await _type(tester, field, 'x #roadmap');
        expect(_popover, findsOneWidget);
        expect(_rowNames(), isEmpty);
        expect(_createRow, findsOneWidget);
        expect(
          find.descendant(
            of: _createRow,
            matching: find.text('Create new tag #roadmap'),
          ),
          findsOneWidget,
        );
        expect(_selectedRows(), ['create']);
      },
    );

    testWidgets('a matching query shows the tag rows and the create row last', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #pr');
      expect(_rowNames(), ['pricing']);
      expect(_createRow, findsOneWidget);
      expect(
        tester.getTopLeft(_createRow).dy,
        greaterThan(tester.getTopLeft(_row('pricing')).dy),
      );
      expect(_selectedRows(), ['pricing']);
    });

    testWidgets(
      'the create row hides when a listed row equals the query in any case',
      (tester) async {
        final field = await _pumpField(tester);

        await _type(tester, field, 'x #pricin');
        expect(_createRow, findsOneWidget);
        for (final text in ['x #pricing', 'x #Pricing', 'x #PRICING']) {
          await _type(tester, field, text);
          expect(_rowNames(), ['pricing'], reason: text);
          expect(_createRow, findsNothing, reason: text);
        }
      },
    );

    testWidgets(
      'accepting the create row keeps the case as typed in label and text',
      (tester) async {
        final field = await _pumpField(tester);

        await _type(tester, field, 'x #RoadMap');
        expect(find.text('Create new tag #RoadMap'), findsOneWidget);

        await _press(tester, LogicalKeyboardKey.enter);
        expect(field.text, 'x #RoadMap ');
        expect(field.selection, const TextSelection.collapsed(offset: 11));
        expect(_popover, findsNothing);
      },
    );

    testWidgets('accepting an existing row writes its stored lowercase name', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #PRIC');
      await _press(tester, LogicalKeyboardKey.enter);
      expect(field.text, 'x #pricing ');
    });

    testWidgets(
      'accepting the create row trims a trailing dash or underscore',
      (tester) async {
        final field = await _pumpField(tester);

        await _type(tester, field, 'x #q3-');
        expect(_popover, findsOneWidget);
        expect(find.text('Create new tag #q3-'), findsOneWidget);
        await _press(tester, LogicalKeyboardKey.enter);
        expect(field.text, 'x #q3 ');

        await _type(tester, field, 'y #a-b_-_');
        await _press(tester, LogicalKeyboardKey.tab);
        expect(field.text, 'y #a-b ');
        expect(field.selection, const TextSelection.collapsed(offset: 7));
      },
    );

    testWidgets(
      'accepting the create row writes text only and bumps no revision',
      (tester) async {
        final chips = KindChipHost();
        addTearDown(chips.dispose);
        final field = await _pumpField(tester, chips: chips);
        final container = _container(tester);
        final before = container.read(vaultRevisionProvider);

        await _type(tester, field, 'x #roadmap');
        await tester.tap(_createRow);
        await tester.pump();

        expect(field.text, 'x #roadmap ');
        expect(container.read(vaultRevisionProvider), before);
        expect(chips.target, isNull, reason: 'a tag has no kind chip');
      },
    );
  });

  group('keys and accept', () {
    testWidgets(
      'Enter and Tab accept the selected row and replace the query with the name and a space',
      (tester) async {
        final field = await _pumpField(tester);

        await _type(tester, field, 'x #pr');
        await _press(tester, LogicalKeyboardKey.enter);
        expect(field.text, 'x #pricing ');
        expect(field.selection, const TextSelection.collapsed(offset: 11));
        expect(_popover, findsNothing);

        await _type(tester, field, 'y #wo');
        await _press(tester, LogicalKeyboardKey.tab);
        expect(field.text, 'y #work ');
        expect(field.selection, const TextSelection.collapsed(offset: 8));
        expect(_popover, findsNothing);
      },
    );

    testWidgets('numpad Enter accepts the selected row too', (tester) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #wo');
      await _press(tester, LogicalKeyboardKey.numpadEnter);
      expect(field.text, 'x #work ');
    });

    testWidgets('Escape closes it and leaves the text', (tester) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #pr');
      expect(_popover, findsOneWidget);
      await _press(tester, LogicalKeyboardKey.escape);
      expect(_popover, findsNothing);
      expect(field.text, 'x #pr');
      expect(field.selection, const TextSelection.collapsed(offset: 5));
    });

    testWidgets('after Escape another letter opens it again', (tester) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #pr');
      await _press(tester, LogicalKeyboardKey.escape);
      expect(_popover, findsNothing);

      await _type(tester, field, 'x #pri');
      expect(_popover, findsOneWidget);
    });

    testWidgets(
      'after Escape a controller notification with the same value leaves it closed',
      (tester) async {
        final live = LivePreviewController();
        final field = await _pumpField(tester, controller: live);

        await _type(tester, field, 'x #pr');
        expect(_popover, findsOneWidget);
        await _press(tester, LogicalKeyboardKey.escape);
        expect(_popover, findsNothing);

        // A live preview row notifies for non-text changes (hover, row kind).
        live.cmdHover = const TextRange(start: 0, end: 1);
        await tester.pump();
        expect(_popover, findsNothing);
        expect(field.text, 'x #pr');
      },
    );

    testWidgets('arrow keys move the selection and wrap in both directions', (
      tester,
    ) async {
      final field = await _pumpField(
        tester,
        tags: [_tag('aa', 3), _tag('bb', 2), _tag('cc', 1)],
      );

      await _type(tester, field, 'x #');
      expect(_selectedRows(), ['aa']);

      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_selectedRows(), ['bb']);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_selectedRows(), ['cc']);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_selectedRows(), ['aa'], reason: 'down wraps to the first row');

      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_selectedRows(), ['cc'], reason: 'up wraps to the last row');
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_selectedRows(), ['bb']);

      await _press(tester, LogicalKeyboardKey.enter);
      expect(field.text, 'x #bb ');
    });

    testWidgets('arrows reach the create row and wrap past it', (tester) async {
      final field = await _pumpField(
        tester,
        tags: [_tag('pa', 2), _tag('pb', 1)],
      );

      await _type(tester, field, 'x #p');
      await _press(tester, LogicalKeyboardKey.arrowDown);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_selectedRows(), ['create']);

      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_selectedRows(), ['pa']);

      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_selectedRows(), ['create']);

      await _press(tester, LogicalKeyboardKey.enter);
      expect(field.text, 'x #p ');
    });

    testWidgets('a create row on its own stays selected through the arrows', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #roadmap');
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_selectedRows(), ['create']);
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_selectedRows(), ['create']);
    });

    testWidgets('typing resets the selection to the first row', (tester) async {
      final field = await _pumpField(
        tester,
        tags: [_tag('pa', 2), _tag('pb', 1)],
      );

      await _type(tester, field, 'x #p');
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_selectedRows(), ['pb']);

      await _type(tester, field, 'x #pb');
      expect(_selectedRows(), ['pb']);
      await _type(tester, field, 'x #p');
      expect(_selectedRows(), ['pa']);
    });

    testWidgets(
      'accepting replaces only the query and keeps the following lines',
      (tester) async {
        final field = await _pumpField(tester);

        await _type(tester, field, 'first\nx #pr\nlast', caret: 11);
        await _press(tester, LogicalKeyboardKey.enter);
        expect(field.text, 'first\nx #pricing \nlast');
        expect(field.selection, const TextSelection.collapsed(offset: 17));
      },
    );

    testWidgets('accepting keeps the text after the caret on its line', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #pr tail', caret: 5);
      await _press(tester, LogicalKeyboardKey.enter);
      expect(field.text, 'x #pricing  tail');
      expect(field.selection, const TextSelection.collapsed(offset: 11));
    });

    testWidgets('accepting a query outside the BMP counts UTF-16 units', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #\u{1D49C}b');
      await _press(tester, LogicalKeyboardKey.enter);
      expect(field.text, 'x #\u{1D49C}b ');
      expect(field.selection, const TextSelection.collapsed(offset: 7));
    });

    testWidgets('accepting a bare hash writes the selected tag', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #');
      await _press(tester, LogicalKeyboardKey.tab);
      expect(field.text, 'x #memex ');
    });

    testWidgets('clicking a row accepts it', (tester) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #');
      await tester.tap(_row('work'));
      await tester.pump();
      expect(field.text, 'x #work ');
      expect(field.selection, const TextSelection.collapsed(offset: 8));
      expect(_popover, findsNothing);
    });

    testWidgets('clicking outside closes it and leaves the text', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #pr');
      expect(_popover, findsOneWidget);
      await tester.tapAt(const Offset(790, 590));
      await tester.pump();
      expect(_popover, findsNothing);
      expect(field.text, 'x #pr');
    });

    testWidgets('the field keeps focus while it opens and through an accept', (
      tester,
    ) async {
      final field = await _pumpField(tester);
      final focused = FocusManager.instance.primaryFocus;

      await _type(tester, field, 'x #pr');
      expect(_popover, findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(focused));

      await _press(tester, LogicalKeyboardKey.tab);
      expect(field.text, 'x #pricing ');
      expect(FocusManager.instance.primaryFocus, same(focused));
    });

    testWidgets('an accept is reported through the field onChanged', (
      tester,
    ) async {
      final seen = <String>[];
      final field = await _pumpField(tester, onChanged: seen.add);

      await _type(tester, field, 'x #pr');
      await _press(tester, LogicalKeyboardKey.enter);
      expect(seen.last, 'x #pricing ');
      expect(field.text, seen.last);
    });

    testWidgets(
      'arrow down with it open moves the selection and not the focus',
      (tester) async {
        var moved = 0;
        final next = FocusNode();
        addTearDown(next.dispose);
        final field = await _pumpField(
          tester,
          onMoveDown: () {
            moved++;
            return next;
          },
        );

        await _type(tester, field, 'x #');
        await _press(tester, LogicalKeyboardKey.arrowDown);
        expect(moved, 0);
        expect(_selectedRows(), ['work']);

        await _press(tester, LogicalKeyboardKey.escape);
        await _press(tester, LogicalKeyboardKey.arrowDown);
        expect(moved, 1, reason: 'closed, the key reaches the field as before');
      },
    );

    testWidgets('handleKeyEvent ignores every key while closed', (
      tester,
    ) async {
      final bare = await _pumpBare(tester);
      final state = bare.key.currentState!;

      bare.field.value = const TextEditingValue(
        text: 'x #',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();
      expect(state.isOpen, isTrue, reason: 'control');
      expect(
        state.handleKeyEvent(_down(LogicalKeyboardKey.escape)),
        KeyEventResult.handled,
      );
      await tester.pump();
      expect(state.isOpen, isFalse);

      for (final key in [
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.keyA,
      ]) {
        expect(
          state.handleKeyEvent(_down(key)),
          KeyEventResult.ignored,
          reason: '$key',
        );
        expect(
          state.handleKeyEvent(_up(key)),
          KeyEventResult.ignored,
          reason: '$key up',
        );
      }
    });

    testWidgets(
      'handleKeyEvent consumes the popover keys and passes the rest while open',
      (tester) async {
        final bare = await _pumpBare(
          tester,
          tags: [_tag('aa', 3), _tag('bb', 2), _tag('cc', 1)],
        );
        final state = bare.key.currentState!;
        bare.field.value = const TextEditingValue(
          text: 'x #',
          selection: TextSelection.collapsed(offset: 3),
        );
        await tester.pump();
        expect(state.isOpen, isTrue);

        // Typing and caret keys go on to the field.
        for (final key in [
          LogicalKeyboardKey.keyA,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.backspace,
        ]) {
          expect(
            state.handleKeyEvent(_down(key)),
            KeyEventResult.ignored,
            reason: '$key',
          );
        }

        // The key-up paired with a handled key-down is swallowed.
        expect(
          state.handleKeyEvent(_up(LogicalKeyboardKey.enter)),
          KeyEventResult.handled,
        );
        expect(state.isOpen, isTrue);

        // Arrows are handled, and a held arrow repeats.
        expect(
          state.handleKeyEvent(_down(LogicalKeyboardKey.arrowDown)),
          KeyEventResult.handled,
        );
        await tester.pump();
        expect(_selectedRows(), ['bb']);
        expect(
          state.handleKeyEvent(_repeat(LogicalKeyboardKey.arrowDown)),
          KeyEventResult.handled,
        );
        await tester.pump();
        expect(_selectedRows(), ['cc']);
        expect(
          state.handleKeyEvent(_repeat(LogicalKeyboardKey.arrowUp)),
          KeyEventResult.handled,
        );
        await tester.pump();
        expect(_selectedRows(), ['bb']);

        // Accepting is consumed, Enter included: no newline reaches the field.
        bare.field.value = const TextEditingValue(
          text: 'plain',
          selection: TextSelection.collapsed(offset: 5),
        );
        await tester.pump();
        expect(state.isOpen, isFalse);
        for (final (key, text) in [
          (LogicalKeyboardKey.enter, 'x #aa '),
          (LogicalKeyboardKey.numpadEnter, 'x #aa '),
          (LogicalKeyboardKey.tab, 'x #aa '),
        ]) {
          bare.field.value = const TextEditingValue(
            text: 'x #',
            selection: TextSelection.collapsed(offset: 3),
          );
          await tester.pump();
          expect(state.isOpen, isTrue);
          expect(
            state.handleKeyEvent(_down(key)),
            KeyEventResult.handled,
            reason: '$key',
          );
          await tester.pump();
          expect(bare.field.text, text, reason: '$key');
          expect(state.isOpen, isFalse);
        }

        // Enter on the create row is consumed like any accept.
        bare.field.value = const TextEditingValue(
          text: 'x #new',
          selection: TextSelection.collapsed(offset: 6),
        );
        await tester.pump();
        expect(
          state.handleKeyEvent(_down(LogicalKeyboardKey.enter)),
          KeyEventResult.handled,
        );
        expect(bare.field.text, 'x #new ');

        // Escape is handled while open.
        bare.field.value = const TextEditingValue(
          text: 'x #',
          selection: TextSelection.collapsed(offset: 3),
        );
        await tester.pump();
        expect(
          state.handleKeyEvent(_down(LogicalKeyboardKey.escape)),
          KeyEventResult.handled,
        );
      },
    );

    testWidgets('the popover goes away with its widget', (tester) async {
      final bare = await _pumpBare(tester);
      bare.field.value = const TextEditingValue(
        text: 'x #',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();
      expect(_popover, findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(_popover, findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('placement', () {
    Future<Offset> topLeftWith(WidgetTester tester, Offset caret) async {
      final bare = await _pumpBare(tester, caret: caret);
      bare.field.value = const TextEditingValue(
        text: 'x #',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();
      return tester.getTopLeft(_popover);
    }

    // The default test window is 800 x 600.
    testWidgets('it sits 6 px below the caret', (tester) async {
      expect(
        await topLeftWith(tester, const Offset(100, 100)),
        const Offset(100, 106),
      );
    });

    testWidgets('it stays below when it just fits above the 24 px bottom gap', (
      tester,
    ) async {
      expect(
        await topLeftWith(tester, const Offset(100, 290)),
        const Offset(100, 296),
      );
    });

    testWidgets('it flips above the caret near the window bottom', (
      tester,
    ) async {
      expect(
        await topLeftWith(tester, const Offset(100, 400)),
        const Offset(100, 96),
      );
    });

    testWidgets('a flip never goes above 8 px', (tester) async {
      expect(
        await topLeftWith(tester, const Offset(100, 291)),
        const Offset(100, 8),
      );
    });

    testWidgets('it stays 12 px inside the window right edge', (tester) async {
      expect(
        await topLeftWith(tester, const Offset(700, 100)),
        const Offset(468, 106),
      );
    });

    testWidgets('it stays 8 px inside the window left edge', (tester) async {
      expect(
        await topLeftWith(tester, const Offset(2, 100)),
        const Offset(8, 106),
      );
    });

    testWidgets('in a field it anchors below the real caret line', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      // Like the wikilink popover it reads the layout of the frame before the
      // hash, so the second line is laid out first and x may be one glyph off.
      await _type(tester, field, 'first\nx ');
      await _type(tester, field, 'first\nx #');

      final editable = findRenderEditable(
        tester.renderObject(find.byType(TextField)),
      )!;
      Offset anchor(int offset) => editable.localToGlobal(
        RenderEditableLineBoxes(editable).caretRect(offset).bottomLeft,
      );
      final top = tester.getTopLeft(_popover);
      expect(top.dy, moreOrLessEquals(anchor(9).dy + 6, epsilon: 0.5));
      expect(top.dx, greaterThanOrEqualTo(anchor(8).dx - 0.5));
      expect(top.dx, lessThanOrEqualTo(anchor(9).dx + 0.5));
    });
  });

  group('where a hash cannot start a tag', () {
    testWidgets(
      'inside a code span, a fence, a wikilink or a URL a hash does not open it',
      (tester) async {
        final field = await _pumpField(tester);

        await _expectOpens(tester, field);
        for (final (text, caret) in [
          ('`#p`', 3),
          ('```\n#p', null),
          ('[[a #p]]', 6),
          ('https://x.y/#p', null),
        ]) {
          await _type(tester, field, text, caret: caret);
          expect(_popover, findsNothing, reason: text);
        }
      },
    );

    testWidgets('a code span hides a hash that the whole line closes', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _expectOpens(tester, field);
      for (final (text, caret) in [
        ('x `a #p` y', 7),
        ('x `a #` y', 6),
        ('``a #p``', 6),
        ('`a` `b #p`', 9),
      ]) {
        await _type(tester, field, text, caret: caret);
        expect(_popover, findsNothing, reason: text);
      }
    });

    testWidgets('a fence hides every line up to its close', (tester) async {
      final field = await _pumpField(tester);

      await _expectOpens(tester, field);
      await _type(tester, field, '```\nx #p\n```', caret: 7);
      expect(_popover, findsNothing, reason: 'a closed fence around the caret');
      for (final text in [
        '```\nx #',
        '```dart\nx #p',
        '~~~\nx #',
        '   ```\nx #',
        'text\n```\nx #p',
        '```\n\n\nx #',
        '``` #p',
        '```dart #',
        '```\n~~~\nx #',
        '````\n```\nx #',
        '```\nx\n``` y\nz #',
        '```\nx\n``` #p',
        '```\na\n```\n~~~\nb #',
      ]) {
        await _type(tester, field, text);
        expect(_popover, findsNothing, reason: text);
      }
    });

    testWidgets(
      'a wikilink or a markdown link hides a hash the caret is inside',
      (tester) async {
        final field = await _pumpField(tester);

        await _expectOpens(tester, field);
        for (final (text, caret) in [
          ('[[a #p]]', 6),
          ('![[a #p]]', 7),
          ('[a #p](http://x.y)', 5),
          ('[a](#p)', 6),
          ('[a](x #p)', 8),
        ]) {
          await _type(tester, field, text, caret: caret);
          expect(_popover, findsNothing, reason: text);
        }
      },
    );

    testWidgets('a URL hides a hash that an opener precedes', (tester) async {
      final field = await _pumpField(tester);

      await _expectOpens(tester, field);
      for (final text in [
        'https://x.y/#p',
        'https://x.y/(#p',
        "see https://x.y/a'#",
        'mailto://x.y/[#',
      ]) {
        await _type(tester, field, text);
        expect(_popover, findsNothing, reason: text);
      }
    });

    testWidgets('it opens beside closed spans, links and fences', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      for (final (text, caret) in [
        ('`a` #p', null),
        ('`a` #', null),
        ('[[a]] #p', null),
        ('[[a]] #', null),
        ('[a](http://x.y) #p', null),
        ('https://x.y #p', null),
        ('![[a]] #', null),
        ('```\nx\n```\ny #', null),
        ('~~~\nx\n~~~~\ny #', null),
        ('```\nx\n```  \ny #', null),
        ('x #\n```', 3),
        ('[[a\nx #p', null),
      ]) {
        await _type(tester, field, 'plain');
        expect(_popover, findsNothing);
        await _type(tester, field, text, caret: caret);
        expect(_popover, findsOneWidget, reason: text);
      }
    });

    testWidgets('an unclosed backtick is plain text, per the grammar', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      for (final text in ['` #p', 'x ` #', '``a` #p', '``` a`b\nx #']) {
        await _type(tester, field, 'plain');
        expect(_popover, findsNothing);
        await _type(tester, field, text);
        expect(_popover, findsOneWidget, reason: text);
      }
    });
  });

  group('beside the wikilink popover', () {
    testWidgets(
      'wikilink popover opens and accepts as before in the same field',
      (tester) async {
        final chips = KindChipHost();
        addTearDown(chips.dispose);
        final field = await _pumpField(
          tester,
          chips: chips,
          titles: [NoteTitle(id: 'n1', title: 'Pricing', updatedAt: 0)],
        );

        await _type(tester, field, 'read [[pri');
        expect(_wikilinkPopover, findsOneWidget);
        expect(_popover, findsNothing);
        final item = _wikilinkItem('Pricing');
        expect(item, findsOneWidget);
        expect(_iconIn(tester, item).icon, LucideIcons.fileText);
        expect(
          find.descendant(of: item, matching: find.byType(Text)),
          findsOneWidget,
          reason: 'no trailing count on a note row',
        );
        expect(
          tester.getSize(item).height,
          moreOrLessEquals(36, epsilon: 0.01),
          reason: 'the row is unchanged',
        );
        expect(tester.getSize(_wikilinkPopover).width, 320);
        final create = find.byKey(const Key('wikilink-popover-create'));
        expect(
          find.descendant(
            of: create,
            matching: find.text('Create new note titled "pri"'),
          ),
          findsOneWidget,
        );

        await _press(tester, LogicalKeyboardKey.enter);
        expect(field.text, 'read [[Pricing]]');
        expect(field.selection, const TextSelection.collapsed(offset: 16));
        expect(_wikilinkPopover, findsNothing);
        expect(chips.target, same(field), reason: 'the kind chip still shows');
      },
    );

    testWidgets('wikilink popover keeps its placeholder with no titles', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, '[[');
      expect(_wikilinkPopover, findsOneWidget);
      expect(find.text('type to search…'), findsOneWidget);
      expect(_popover, findsNothing);
    });

    testWidgets(
      'a hash inside an unclosed wikilink leaves only the wikilink popover',
      (tester) async {
        final field = await _pumpField(
          tester,
          titles: [NoteTitle(id: 'n1', title: 'a #b note', updatedAt: 0)],
        );

        await _expectOpens(tester, field);
        await _type(tester, field, '[[a #b');
        expect(_wikilinkPopover, findsOneWidget);
        expect(_popover, findsNothing);

        await _press(tester, LogicalKeyboardKey.arrowDown);
        await _press(tester, LogicalKeyboardKey.arrowUp);
        await _press(tester, LogicalKeyboardKey.enter);
        expect(field.text, '[[a #b note]]');
      },
    );

    testWidgets(
      'a wikilink opened after a tag query closes the tag popover and takes the keys',
      (tester) async {
        final field = await _pumpField(
          tester,
          titles: [NoteTitle(id: 'n1', title: 'Pricing', updatedAt: 0)],
        );

        await _type(tester, field, 'x #pr');
        expect(_popover, findsOneWidget);

        await _type(tester, field, 'x #pr [[Pri');
        expect(_popover, findsNothing);
        expect(_wikilinkPopover, findsOneWidget);

        await _press(tester, LogicalKeyboardKey.enter);
        expect(field.text, 'x #pr [[Pricing]]');
      },
    );

    testWidgets(
      'an unclosed wikilink past the wikilink popover window still keeps the tag popover closed',
      (tester) async {
        final field = await _pumpField(tester);

        await _expectOpens(tester, field);
        await _type(tester, field, '[[${'a' * 70} #p');
        expect(_wikilinkPopover, findsNothing);
        expect(_popover, findsNothing);
      },
    );

    testWidgets(
      'a second unclosed wikilink on the line keeps the tag popover closed',
      (tester) async {
        final field = await _pumpField(tester);

        await _expectOpens(tester, field);
        await _type(tester, field, '[[a]] [[b #p');
        expect(_popover, findsNothing);
      },
    );

    testWidgets('the tag popover takes the keys while it is the one open', (
      tester,
    ) async {
      final field = await _pumpField(
        tester,
        titles: [NoteTitle(id: 'n1', title: 'Pricing', updatedAt: 0)],
      );

      await _type(tester, field, '[[Pricing]] #pr');
      expect(_popover, findsOneWidget);
      expect(_wikilinkPopover, findsNothing);

      await _press(tester, LogicalKeyboardKey.enter);
      expect(field.text, '[[Pricing]] #pricing ');
    });

    testWidgets('escaping a wikilink popover does not open the tag popover', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _expectOpens(tester, field);
      await _type(tester, field, '[[a #b');
      expect(_wikilinkPopover, findsOneWidget);
      await _press(tester, LogicalKeyboardKey.escape);
      expect(_wikilinkPopover, findsNothing);
      expect(_popover, findsNothing);
    });
  });

  group('tags that load late', () {
    testWidgets(
      'tags that load after the popover opens appear without reopening it',
      (tester) async {
        final load = Completer<VaultScoped<List<TagRow>>>();
        final field = await _pumpField(
          tester,
          overrides: [tagsAsyncProvider.overrideWith((ref) => load.future)],
        );

        await _type(tester, field, 'x #pr');
        expect(_popover, findsOneWidget);
        expect(_rowNames(), isEmpty);
        expect(_createRow, findsOneWidget);

        load.complete(VaultScoped(null, _sample));
        await _flush(tester);

        expect(_popover, findsOneWidget);
        expect(_rowNames(), ['pricing']);
        expect(_selectedRows(), ['pricing']);
        expect(field.text, 'x #pr');
      },
    );

    testWidgets('a bare hash with no tags yet shows nothing until they load', (
      tester,
    ) async {
      final load = Completer<VaultScoped<List<TagRow>>>();
      final field = await _pumpField(
        tester,
        overrides: [tagsAsyncProvider.overrideWith((ref) => load.future)],
      );

      await _type(tester, field, 'x #');
      expect(_popover, findsNothing);
      expect(find.text('type to search…'), findsNothing);

      load.complete(VaultScoped(null, _sample));
      await _flush(tester);

      expect(_popover, findsOneWidget);
      expect(_rowNames().first, 'memex');
      expect(_selectedRows(), ['memex']);
    });

    testWidgets('a load does not open it where the text does not', (
      tester,
    ) async {
      final load = Completer<VaultScoped<List<TagRow>>>();
      final field = await _pumpField(
        tester,
        overrides: [tagsAsyncProvider.overrideWith((ref) => load.future)],
      );

      await _type(tester, field, '#');
      load.complete(VaultScoped(null, _sample));
      await _flush(tester);
      expect(_popover, findsNothing, reason: 'a bare hash at line start');

      await _expectOpens(tester, field);
      await _type(tester, field, 'plain');
      expect(_popover, findsNothing);
    });

    testWidgets('a load after Escape leaves it closed', (tester) async {
      final load = Completer<VaultScoped<List<TagRow>>>();
      final field = await _pumpField(
        tester,
        overrides: [tagsAsyncProvider.overrideWith((ref) => load.future)],
      );

      await _type(tester, field, 'x #pr');
      expect(_popover, findsOneWidget);
      await _press(tester, LogicalKeyboardKey.escape);
      expect(_popover, findsNothing);

      load.complete(VaultScoped(null, _sample));
      await _flush(tester);
      expect(_popover, findsNothing);
      expect(field.text, 'x #pr');
    });

    testWidgets(
      'a revision re-read refreshes an open list and empties it when the tags go',
      (tester) async {
        var tags = <TagRow>[_tag('first', 1)];
        final field = await _pumpField(
          tester,
          overrides: [
            tagsAsyncProvider.overrideWith((ref) async {
              ref.watch(vaultRevisionProvider);
              return VaultScoped(ref.watch(currentVaultProvider), tags);
            }),
          ],
        );
        final container = _container(tester);

        await _type(tester, field, 'x #');
        expect(_rowNames(), ['first']);

        tags = [_tag('first', 1), _tag('second', 5)];
        container.read(vaultRevisionProvider.notifier).state++;
        await _flush(tester);
        expect(_rowNames(), ['second', 'first']);

        tags = const [];
        container.read(vaultRevisionProvider.notifier).state++;
        await _flush(tester);
        expect(_popover, findsNothing, reason: 'no rows and an empty query');
        expect(find.text('type to search…'), findsNothing);
      },
    );

    testWidgets('tags of another vault and a failed read list nothing', (
      tester,
    ) async {
      final field = await _pumpField(
        tester,
        overrides: [
          tagsAsyncProvider.overrideWith(
            (ref) async => VaultScoped(const LocalVaultRef('/other'), _sample),
          ),
        ],
      );

      await _type(tester, field, 'x #pr');
      expect(_createRow, findsOneWidget);
      expect(_rowNames(), isEmpty);

      await _type(tester, field, 'x #');
      expect(_popover, findsNothing);
    });

    testWidgets('a failed tags read leaves only the create row', (
      tester,
    ) async {
      final field = await _pumpField(
        tester,
        overrides: [
          tagsAsyncProvider.overrideWith(
            (ref) async => throw Exception('read failed'),
          ),
        ],
      );

      await _type(tester, field, 'x #pr');
      expect(_createRow, findsOneWidget);
      expect(_rowNames(), isEmpty);
      await _type(tester, field, 'x #');
      expect(_popover, findsNothing);
    });
  });

  group('in the editor hosts', () {
    /// A vault whose tags come through the real provider, on the V6 fake.
    Future<SegmentedEditorRobot> launchTagged(WidgetTester tester) async {
      final vault = seedSegmentedVault();
      vault.db
        ..seedTag(fixtureZetaId, 'pricing')
        ..seedTag(fixtureAlphaId, 'pricing')
        ..seedTag(fixtureZetaId, 'work')
        ..seedTag(fixtureZetaId, 'inbox');
      return launchSegmented(tester, vault: vault);
    }

    Finder sourceField(SegmentedEditorRobot r) =>
        find.descendant(of: r.sourceBody, matching: find.byType(TextField));

    testWidgets(
      'the popover opens and accepts in a live preview text segment',
      (tester) async {
        final r = await launchTagged(tester);
        await r.open(fixtureTopicId);

        await r.typeInSegment(2, 'Outro #pr');
        await pumpFrames(tester);
        expect(_popover, findsOneWidget);
        expect(_rowNames(), ['pricing']);
        expect(
          find.descendant(of: _row('pricing'), matching: find.text('2')),
          findsOneWidget,
          reason: 'the count comes from the vault',
        );

        await r.pressKey(LogicalKeyboardKey.enter);
        expect(r.segmentText(2), 'Outro #pricing ');
        expect(
          r.segmentSelection(2),
          const TextSelection.collapsed(offset: 15),
        );
        expect(_popover, findsNothing);
      },
    );

    testWidgets('the popover opens and accepts in a live preview item row', (
      tester,
    ) async {
      final r = await launchTagged(tester);
      await r.open(fixtureTopicId);

      await r.typeInSegment(2, '- #');
      await pumpFrames(tester);
      expect(_popover, findsOneWidget, reason: 'a bare hash after a marker');
      expect(_rowNames(), ['pricing', 'work']);
      expect(_row('inbox'), findsNothing);

      await r.pressKey(LogicalKeyboardKey.arrowDown);
      await r.pressKey(LogicalKeyboardKey.enter);
      expect(r.segmentText(2), '- #work ');
    });

    testWidgets(
      'the popover respects line start and fences in live preview rows',
      (tester) async {
        final r = await launchTagged(tester);
        await r.open(fixtureTopicId);

        await r.typeInSegment(2, '#');
        await pumpFrames(tester);
        expect(_popover, findsNothing, reason: 'a bare hash at line start');

        await r.typeInSegment(2, '#p');
        await pumpFrames(tester);
        expect(_popover, findsOneWidget);

        await r.typeInSegment(2, '# ');
        await pumpFrames(tester);
        expect(_popover, findsNothing, reason: 'a heading');

        await r.typeInSegment(2, 'prose\n#');
        await pumpFrames(tester);
        expect(_popover, findsNothing, reason: 'column 0 of a prose row line');

        await r.typeInSegment(2, '```\nx #p');
        await pumpFrames(tester);
        expect(_popover, findsNothing, reason: 'a code row');
      },
    );

    testWidgets(
      'the popover opens and accepts in a daily note person section',
      (tester) async {
        final r = await launchTagged(tester);
        await r.open(fixtureDailyId);

        await r.typeInSegment(0, 'Slept #wo');
        await pumpFrames(tester);
        expect(_popover, findsOneWidget);

        await r.pressKey(LogicalKeyboardKey.tab);
        expect(r.segmentText(0), 'Slept #work ');
      },
    );

    testWidgets('the popover opens and accepts in the Source mode field', (
      tester,
    ) async {
      final r = await launchTagged(tester);
      await r.open(fixtureTopicId);
      await r.toggleSource();

      await tester.showKeyboard(sourceField(r));
      await tester.enterText(sourceField(r), '- call #pr');
      await pumpFrames(tester);
      expect(_popover, findsOneWidget);
      expect(_rowNames(), ['pricing']);

      await r.pressKey(LogicalKeyboardKey.enter);
      expect(r.sourceText, '- call #pricing ', reason: 'no list continuation');
      expect(_popover, findsNothing);

      await tester.enterText(sourceField(r), '- call #wo');
      await pumpFrames(tester);
      await r.pressKey(LogicalKeyboardKey.tab);
      expect(r.sourceText, '- call #work ', reason: 'no list indent');
    });

    testWidgets(
      'the Source mode field applies the opening rule to its whole text',
      (tester) async {
        final r = await launchTagged(tester);
        await r.open(fixtureTopicId);
        await r.toggleSource();

        await tester.showKeyboard(sourceField(r));
        await tester.enterText(sourceField(r), '- #');
        await pumpFrames(tester);
        expect(_popover, findsOneWidget, reason: 'mid-line in the source text');

        await tester.enterText(sourceField(r), 'intro\n#');
        await pumpFrames(tester);
        expect(_popover, findsNothing);

        await tester.enterText(sourceField(r), '```\nx #p');
        await pumpFrames(tester);
        expect(_popover, findsNothing);
      },
    );

    testWidgets(
      'a hash opens in the row after a tilde fence that an item row splits',
      (tester) async {
        final r = await launchTagged(tester);
        await r.open(fixtureTopicId);

        // The last row holds `~~~\n#y`: alone its first line reads as an
        // opener, but on the server it closes the fence.
        await r.typeInSegment(2, '~~~\n- #\n~~~\n');
        await pumpFrames(tester);
        await r.focusSegment(2);
        await r.typeChars('#y');
        await pumpFrames(tester);
        expect(r.segmentText(2), '~~~\n- #\n~~~\n#y');
        expect(_popover, findsOneWidget);
      },
    );

    testWidgets(
      'a hash in an item row inside a tilde fence does not open and one outside does',
      (tester) async {
        final r = await launchTagged(tester);
        await r.open(fixtureTopicId);

        await r.typeInSegment(2, 'a\n- ');
        await pumpFrames(tester);
        await r.focusSegment(2);
        await r.typeChars('#');
        await pumpFrames(tester);
        expect(r.segmentText(2), 'a\n- #');
        expect(_popover, findsOneWidget, reason: 'control: no fence');

        // The item row holds only `#`: the fence is in the rows around it.
        await r.typeInSegment(2, '~~~\n- \n~~~');
        await pumpFrames(tester);
        expect(_popover, findsNothing);
        await r.focusSegment(2, offset: 6);
        await r.typeChars('#');
        await pumpFrames(tester);
        expect(r.segmentText(2), '~~~\n- #\n~~~');
        expect(_popover, findsNothing, reason: 'a bare hash in the fence');

        await r.typeChars('x');
        await pumpFrames(tester);
        expect(r.segmentText(2), '~~~\n- #x\n~~~');
        expect(_popover, findsNothing, reason: 'a query in the fence');
      },
    );

    testWidgets('a plain hash inside a tilde fence in one row does not open', (
      tester,
    ) async {
      final r = await launchTagged(tester);
      await r.open(fixtureTopicId);

      await r.typeInSegment(2, '~~~\nb\n~~~\nc');
      await pumpFrames(tester);
      await r.focusSegment(2);
      await r.typeChars(' #');
      await pumpFrames(tester);
      expect(r.segmentText(2), '~~~\nb\n~~~\nc #');
      expect(_popover, findsOneWidget, reason: 'control: past the close');

      await r.typeInSegment(2, '~~~\nb\n~~~');
      await pumpFrames(tester);
      expect(_popover, findsNothing);
      await r.focusSegment(2, offset: 5);
      await r.typeChars(' #');
      await pumpFrames(tester);
      expect(r.segmentText(2), '~~~\nb #\n~~~');
      expect(_popover, findsNothing);
    });

    testWidgets(
      'Enter on an exact match makes a new line in a live preview prose row',
      (tester) async {
        final r = await launchTagged(tester);
        await r.open(fixtureTopicId);

        await r.typeInSegment(2, 'Outro #work');
        await pumpFrames(tester);
        expect(_popover, findsOneWidget);

        expect(await r.pressEnter(), isFalse, reason: 'left to the platform');
        await pumpFrames(tester);
        expect(r.segmentText(2), 'Outro #work\n');
        expect(
          r.segmentSelection(2),
          const TextSelection.collapsed(offset: 12),
        );
        expect(_popover, findsNothing);
      },
    );

    testWidgets(
      'Enter on an exact match continues the list in a live preview item row',
      (tester) async {
        final r = await launchTagged(tester);
        await r.open(fixtureTopicId);

        await r.typeInSegment(2, '- #work');
        await pumpFrames(tester);
        expect(_popover, findsOneWidget);

        await r.pressEnter();
        await pumpFrames(tester);
        expect(r.segmentText(2), '- #work\n- ');
        expect(_popover, findsNothing);
      },
    );

    testWidgets('Enter on an exact match continues the list in Source mode', (
      tester,
    ) async {
      final r = await launchTagged(tester);
      await r.open(fixtureTopicId);
      await r.toggleSource();

      await tester.showKeyboard(sourceField(r));
      await tester.enterText(sourceField(r), '- call #work');
      await pumpFrames(tester);
      expect(_popover, findsOneWidget);

      await r.pressEnter();
      await pumpFrames(tester);
      expect(r.sourceText, '- call #work\n- ');
      expect(_popover, findsNothing);
    });

    testWidgets(
      'a caret move to a tag in a live preview row does not open it',
      (tester) async {
        final r = await launchTagged(tester);
        await r.open(fixtureTopicId);

        await r.typeInSegment(2, 'Outro #pricing and more');
        await pumpFrames(tester);
        expect(_popover, findsNothing);

        await r.focusSegment(2, offset: 14);
        await pumpFrames(tester);
        expect(
          r.segmentSelection(2),
          const TextSelection.collapsed(offset: 14),
        );
        expect(_popover, findsNothing);

        await r.typeChars('s');
        await pumpFrames(tester);
        expect(_popover, findsOneWidget, reason: 'control: typing opens it');
      },
    );

    testWidgets(
      'the Source mode field judges a tilde fence from its own text',
      (tester) async {
        final r = await launchTagged(tester);
        await r.open(fixtureTopicId);
        await r.toggleSource();

        await tester.showKeyboard(sourceField(r));
        await tester.enterText(sourceField(r), '~~~\n- #');
        await pumpFrames(tester);
        expect(_popover, findsNothing);

        await tester.enterText(sourceField(r), '~~~\n- #\n~~~\n#y');
        await pumpFrames(tester);
        expect(_popover, findsOneWidget);
      },
    );
  });

  group('Enter on a tag typed in full (D41)', () {
    testWidgets(
      'Enter on an exact match closes the popover and leaves the key to the field',
      (tester) async {
        final field = await _pumpField(tester);

        await _type(tester, field, 'x #work');
        expect(_selectedRows(), ['work']);

        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(handled, isFalse);
        expect(_popover, findsNothing);
        expect(field.text, 'x #work', reason: 'the platform adds the newline');
        expect(field.selection, const TextSelection.collapsed(offset: 7));
      },
    );

    testWidgets('numpad Enter on an exact match leaves the key to the field', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #work');
      final handled = await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await tester.pump();
      expect(handled, isFalse);
      expect(_popover, findsNothing);
      expect(field.text, 'x #work');
    });

    testWidgets('Enter on an exact match mid-line leaves the text after it', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #work tail', caret: 7);
      expect(_popover, findsOneWidget);
      final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(handled, isFalse);
      expect(_popover, findsNothing);
      expect(field.text, 'x #work tail');
    });

    testWidgets('Enter on a partial match still completes the tag', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #wor');
      final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(handled, isTrue);
      expect(field.text, 'x #work ');
      expect(_popover, findsNothing);
    });

    testWidgets('Tab on an exact match accepts and adds the space', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #work');
      final handled = await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(handled, isTrue);
      expect(field.text, 'x #work ');
      expect(field.selection, const TextSelection.collapsed(offset: 8));
      expect(_popover, findsNothing);
    });

    testWidgets(
      'Enter on a row arrowed to from an exact match accepts that row',
      (tester) async {
        final field = await _pumpField(
          tester,
          tags: [_tag('work', 2), _tag('workshop', 1)],
        );

        await _type(tester, field, 'x #work');
        expect(_rowNames(), ['work', 'workshop']);
        await _press(tester, LogicalKeyboardKey.arrowDown);
        expect(_selectedRows(), ['workshop']);

        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(handled, isTrue);
        expect(field.text, 'x #workshop ');
      },
    );

    testWidgets(
      'Enter on the exact row arrowed back to leaves the key to the field',
      (tester) async {
        final field = await _pumpField(
          tester,
          tags: [_tag('work', 2), _tag('workshop', 1)],
        );

        await _type(tester, field, 'x #work');
        await _press(tester, LogicalKeyboardKey.arrowDown);
        await _press(tester, LogicalKeyboardKey.arrowUp);
        expect(_selectedRows(), ['work']);

        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(handled, isFalse);
        expect(field.text, 'x #work');
        expect(_popover, findsNothing);
      },
    );

    testWidgets('Enter on a tag typed in another case completes to its name', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #Work');
      expect(_createRow, findsNothing);
      final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(handled, isTrue);
      expect(field.text, 'x #work ');
    });

    testWidgets(
      'a tags re-read after an exact Enter leaves the popover closed',
      (tester) async {
        final field = await _pumpField(
          tester,
          overrides: [
            tagsAsyncProvider.overrideWith((ref) async {
              ref.watch(vaultRevisionProvider);
              return VaultScoped(ref.watch(currentVaultProvider), _sample);
            }),
          ],
        );
        final container = _container(tester);

        await _type(tester, field, 'x #work');
        await _press(tester, LogicalKeyboardKey.enter);
        expect(_popover, findsNothing);

        container.read(vaultRevisionProvider.notifier).state++;
        await _flush(tester);
        expect(_popover, findsNothing);
      },
    );
  });

  group('the popover opens only while typing (D41)', () {
    testWidgets('a caret move onto a hash or a tag never opens the popover', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #pricing y #');
      expect(_popover, findsOneWidget, reason: 'control: typing opens it');
      await _type(tester, field, 'x #pricing y z');
      expect(_popover, findsNothing);

      for (final caret in [10, 3, 5, 10]) {
        await _type(tester, field, 'x #pricing y z', caret: caret);
        expect(_popover, findsNothing, reason: 'caret at $caret');
      }
    });

    testWidgets('a click at the end of a tag does not open the popover', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #pricing y');
      expect(_popover, findsNothing);

      final editable = findRenderEditable(
        tester.renderObject(find.byType(TextField)),
      )!;
      final caret = RenderEditableLineBoxes(editable).caretRect(10);
      await tester.tapAt(editable.localToGlobal(caret.centerLeft));
      await tester.pump();
      expect(field.selection, const TextSelection.collapsed(offset: 10));
      expect(_popover, findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('typing after a caret move opens the popover', (tester) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #pricing y');
      await _type(tester, field, 'x #pricing y', caret: 10);
      expect(_popover, findsNothing);

      await _type(tester, field, 'x #pricings y', caret: 11);
      expect(_popover, findsOneWidget);
    });

    testWidgets('an open popover follows a caret move inside its query', (
      tester,
    ) async {
      final field = await _pumpField(
        tester,
        tags: [_tag('pa', 2), _tag('pb', 1), _tag('qq', 5)],
      );

      await _type(tester, field, 'x #pa');
      expect(_rowNames(), ['pa']);

      await _type(tester, field, 'x #pa', caret: 4);
      expect(_popover, findsOneWidget);
      expect(_rowNames(), ['pa', 'pb']);

      await _type(tester, field, 'x #pa', caret: 3);
      expect(_popover, findsOneWidget);
      expect(_rowNames(), ['qq', 'pa', 'pb'], reason: 'bare, most-used first');

      await _type(tester, field, 'x #pa', caret: 1);
      expect(_popover, findsNothing);

      await _type(tester, field, 'x #pa', caret: 4);
      expect(_popover, findsNothing, reason: 'a caret move does not reopen it');
    });

    testWidgets('a tags load after a caret move does not open the popover', (
      tester,
    ) async {
      final load = Completer<VaultScoped<List<TagRow>>>();
      final field = await _pumpField(
        tester,
        overrides: [tagsAsyncProvider.overrideWith((ref) => load.future)],
      );

      await _type(tester, field, 'x #');
      expect(_popover, findsNothing, reason: 'no rows yet');
      await _type(tester, field, 'x #', caret: 1);
      await _type(tester, field, 'x #', caret: 3);

      load.complete(VaultScoped(null, _sample));
      await _flush(tester);
      expect(_popover, findsNothing);

      await _type(tester, field, 'x #m');
      expect(_popover, findsOneWidget, reason: 'control: typing opens it');
    });

    testWidgets('after Escape a caret move leaves it closed through a load', (
      tester,
    ) async {
      final load = Completer<VaultScoped<List<TagRow>>>();
      final field = await _pumpField(
        tester,
        overrides: [tagsAsyncProvider.overrideWith((ref) => load.future)],
      );

      await _type(tester, field, 'x #pr');
      await _press(tester, LogicalKeyboardKey.escape);
      expect(_popover, findsNothing);

      await _type(tester, field, 'x #pr', caret: 4);
      expect(_popover, findsNothing);

      load.complete(VaultScoped(null, _sample));
      await _flush(tester);
      expect(_popover, findsNothing);
    });
  });

  group('the popover opens only in a focused field', () {
    const fieldA = Key('field-a');
    const fieldB = Key('field-b');

    /// Two fields of one page, neither focused, whose tags load [overrides].
    Future<(TextEditingController, TextEditingController)> pumpTwo(
      WidgetTester tester, {
      required List<Override> overrides,
    }) async {
      final a = TextEditingController();
      final b = TextEditingController();
      final host = KindChipHost();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      addTearDown(host.dispose);
      await pumpEditorScoped(
        tester,
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextSegmentField(key: fieldA, controller: a, kindChips: host),
                TextSegmentField(key: fieldB, controller: b, kindChips: host),
              ],
            ),
          ),
        ),
        overrides: overrides,
      );
      await _flush(tester);
      return (a, b);
    }

    Future<void> focus(WidgetTester tester, Key key) async {
      await tester.showKeyboard(find.byKey(key));
      await tester.pump();
    }

    testWidgets('a tags load does not open the popover in an unfocused field', (
      tester,
    ) async {
      final load = Completer<VaultScoped<List<TagRow>>>();
      final (a, b) = await pumpTwo(
        tester,
        overrides: [tagsAsyncProvider.overrideWith((ref) => load.future)],
      );

      await focus(tester, fieldA);
      await _type(tester, a, 'x #');
      expect(_popover, findsNothing, reason: 'no rows yet');

      await focus(tester, fieldB);
      await _type(tester, b, '#first');
      await _press(tester, LogicalKeyboardKey.escape);
      expect(_popover, findsNothing);

      load.complete(VaultScoped(null, _sample));
      await _flush(tester);
      expect(_popover, findsNothing);
      expect(a.text, 'x #');
    });

    testWidgets('a tags load opens the popover in the focused field only', (
      tester,
    ) async {
      final load = Completer<VaultScoped<List<TagRow>>>();
      final (a, b) = await pumpTwo(
        tester,
        overrides: [tagsAsyncProvider.overrideWith((ref) => load.future)],
      );

      await focus(tester, fieldA);
      await _type(tester, a, 'x #');
      await focus(tester, fieldB);
      await _type(tester, b, 'y #');
      expect(_popover, findsNothing, reason: 'no rows yet');

      load.complete(VaultScoped(null, _sample));
      await _flush(tester);
      expect(_popover, findsOneWidget);

      await _press(tester, LogicalKeyboardKey.tab);
      expect(b.text, 'y #memex ', reason: 'the focused field holds it');
      expect(a.text, 'x #');
      expect(_popover, findsNothing);
    });

    testWidgets(
      'text written to an unfocused field does not open the popover',
      (tester) async {
        final (a, _) = await pumpTwo(tester, overrides: [_tagsLoad(_sample)]);

        await focus(tester, fieldB);
        await _type(tester, a, 'x #pr');
        expect(_popover, findsNothing);

        await focus(tester, fieldA);
        await _type(tester, a, 'x #pri');
        expect(_popover, findsOneWidget, reason: 'control: focused, it opens');
      },
    );
  });

  group('contracts pinned in verify', () {
    testWidgets('a range selection closes the popover', (tester) async {
      final field = await _pumpField(tester);

      await _expectOpens(tester, field);
      field.value = const TextEditingValue(
        text: 'x #pr',
        selection: TextSelection(baseOffset: 5, extentOffset: 4),
      );
      await tester.pump();
      expect(_popover, findsNothing, reason: 'a range selection is no query');

      field.value = const TextEditingValue(
        text: 'x #pr',
        selection: TextSelection.collapsed(offset: 5),
      );
      await tester.pump();
      expect(_popover, findsNothing, reason: 'collapsing it is no typing');

      await _type(tester, field, 'x #pri');
      expect(_popover, findsOneWidget, reason: 'control: typing opens it');
    });

    testWidgets('a tags re-read keeps the selected tag selected', (
      tester,
    ) async {
      var tags = <TagRow>[_tag('aa', 3), _tag('bb', 2), _tag('cc', 1)];
      final field = await _pumpField(
        tester,
        overrides: [
          tagsAsyncProvider.overrideWith((ref) async {
            ref.watch(vaultRevisionProvider);
            return VaultScoped(ref.watch(currentVaultProvider), tags);
          }),
        ],
      );
      final container = _container(tester);

      await _type(tester, field, 'x #');
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_selectedRows(), ['bb']);

      // bb is now the most used: it moves to the first position.
      tags = [_tag('aa', 3), _tag('bb', 9), _tag('cc', 1)];
      container.read(vaultRevisionProvider.notifier).state++;
      await _flush(tester);
      expect(_rowNames(), ['bb', 'aa', 'cc']);
      expect(_selectedRows(), ['bb'], reason: 'the tag, not the position');

      // The selected tag is gone: the first row is selected.
      tags = [_tag('aa', 3), _tag('cc', 1)];
      container.read(vaultRevisionProvider.notifier).state++;
      await _flush(tester);
      expect(_rowNames(), ['aa', 'cc']);
      expect(_selectedRows(), ['aa']);

      await _press(tester, LogicalKeyboardKey.enter);
      expect(field.text, 'x #aa ');
    });

    testWidgets('a tags re-read moves a selected create row to the first row', (
      tester,
    ) async {
      var tags = <TagRow>[_tag('pa', 2), _tag('pb', 1)];
      final field = await _pumpField(
        tester,
        overrides: [
          tagsAsyncProvider.overrideWith((ref) async {
            ref.watch(vaultRevisionProvider);
            return VaultScoped(ref.watch(currentVaultProvider), tags);
          }),
        ],
      );
      final container = _container(tester);

      await _type(tester, field, 'x #p');
      await _press(tester, LogicalKeyboardKey.arrowDown);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_selectedRows(), ['create']);

      tags = [_tag('pa', 2), _tag('pb', 1), _tag('pc', 1)];
      container.read(vaultRevisionProvider.notifier).state++;
      await _flush(tester);
      expect(_rowNames(), ['pa', 'pb', 'pc']);
      expect(_selectedRows(), ['pa']);
    });

    testWidgets('a notification with the same value keeps the selection', (
      tester,
    ) async {
      final live = LivePreviewController();
      final field = await _pumpField(
        tester,
        controller: live,
        tags: [_tag('aa', 3), _tag('bb', 2)],
      );

      await _type(tester, field, 'x #');
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_selectedRows(), ['bb']);

      live.cmdHover = const TextRange(start: 0, end: 1);
      await tester.pump();
      expect(_popover, findsOneWidget);
      expect(_selectedRows(), ['bb'], reason: 'hover is not a text change');
    });

    testWidgets('clicking outside also keeps it closed when tags then load', (
      tester,
    ) async {
      final load = Completer<VaultScoped<List<TagRow>>>();
      final field = await _pumpField(
        tester,
        overrides: [tagsAsyncProvider.overrideWith((ref) => load.future)],
      );

      await _type(tester, field, 'x #pr');
      expect(_popover, findsOneWidget);
      await tester.tapAt(const Offset(790, 590));
      await tester.pump();
      expect(_popover, findsNothing);

      load.complete(VaultScoped(null, _sample));
      await _flush(tester);
      expect(_popover, findsNothing);
      expect(field.text, 'x #pr');

      await _type(tester, field, 'x #pri');
      expect(_popover, findsOneWidget, reason: 'typing opens it again');
    });

    testWidgets('on desktop a click on a row keeps the field focused', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final field = await _pumpField(tester);
        final focus = tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode;
        focus.requestFocus();
        await tester.pump();
        expect(focus.hasPrimaryFocus, isTrue, reason: 'control: focused');

        await _type(tester, field, 'x #');
        await tester.tap(_row('work'));
        await tester.pump();
        expect(field.text, 'x #work ');
        expect(focus.hasPrimaryFocus, isTrue, reason: 'the field keeps focus');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the create row accepts on a click and keeps the case', (
      tester,
    ) async {
      final field = await _pumpField(tester);

      await _type(tester, field, 'x #Road-');
      await tester.tap(_createRow);
      await tester.pump();
      expect(field.text, 'x #Road ');
      expect(field.selection, const TextSelection.collapsed(offset: 8));
      expect(_popover, findsNothing);
    });
  });
}
