// WI #399 (F3, Spec #393 requirements 15-18, 21): the Move to..., File in...
// and Remove dialogs of the `Filed from this day` section show the block they
// act on, and the Activity subtitle and each entry's day line move from fg3 to
// fg2.
//
// The dialogs are driven through the section's own buttons, so the three call
// sites are tested together with the dialog. A person has to hover a row before
// its fix buttons answer (WI #398), so every press here hovers the row first
// with a mouse of its own: the tests hold with or without that reveal.
//
// Numbers come from the design pack (design/393-filed-groups/packs/399.md): the
// line is sans 12, line height 1.5, fg2, 6 px under the title and 16 px above
// the first field. Lead rulings LR5 and LR8: the preview is the block's
// `markdownPreviewText`, cut to its first 48 grapheme clusters, trailing
// whitespace trimmed, then `…`, only when it is longer than 48; the Remove line
// uses the Spec's copy. Fonts are the flutter_test fallback (every glyph 1 em
// wide). Test names use no apostrophes or quotes.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/markdown_preview_text.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/activity/filed_section.dart';
import 'package:open_memex_app/src/widgets/panel_placeholder_tab.dart';

import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/filed_section_fakes.dart';
import '../support/font_fetch_hold.dart';

// ---------- copy ----------

String _moveLine(String preview, String topic) => '“$preview” from $topic';
String _fileLine(String preview) => '“$preview”';
String _removeLine(String preview, String topic) =>
    '“$preview” stays in the day; only this block is taken out of $topic.';

const _subtitle =
    'every read and write by every connected agent. attaches to the audit log when a vault is shared with claude desktop.';

/// A family emoji: one grapheme cluster of seven code points.
const _family = '👨‍👩‍👧‍👦';

/// `e` plus a combining acute accent: one cluster, two code points.
const _eAcute = 'é';

// ---------- pumping ----------

/// One section on its own, 340 px wide, with the app theme (the dialogs take
/// their title style and colours from it).
class _S399 {
  _S399(this.server, this.db, this.cli);
  final F260Server server;
  final FakeVaultDb db;
  final FakeMemexCli cli;
}

Future<_S399> _pump399(
  WidgetTester tester, {
  F260Server Function(FakeVaultDb db)? server,
  double scale = 1.0,
  Size size = const Size(800, 2400),
}) async {
  final db = f260Db();
  final srv = (server ?? f260DefaultServer)(db);
  final cli = f260Cli(db, srv);
  final note = db.getNote(f260DailyId)!;
  final dir = Directory.systemTemp.createTempSync('wi399');
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(FakeClock()),
      selectedNoteIdProvider.overrideWith((_) => f260DailyId),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildOmTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          backgroundColor: OmColors.surface1,
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 340,
              child: SingleChildScrollView(child: FiledSection(note: note)),
            ),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
  expect(find.byKey(f260Section), findsOneWidget);
  return _S399(srv, db, cli);
}

/// A day whose Player Loop group holds one block per entry of [texts] (ids
/// `c0`, `c1`, ...), Economy holds `b3`, and Not filed holds `n0`, `n1`, ...
/// (one per entry of [texts] too).
F260Server Function(FakeVaultDb) _dayOfTexts(List<String> texts) =>
    (db) => F260Server(
      db,
      topics: [
        F260Topic(f260Loop, 'Player Loop', [
          for (final (i, t) in texts.indexed) ('c$i', t),
        ]),
        F260Topic(f260Economy, 'Economy', [(f260B3, f260B3Text)]),
      ],
      notFiled: [for (final (i, t) in texts.indexed) ('n$i', t)],
    );

/// Hovers the row [row] with a mouse of its own, then taps [key] (a fix button
/// of that row), as a person reveals and presses it. The mouse stays over the
/// row for the tap, and is removed after.
Future<void> _press(WidgetTester tester, Key row, Key key) async {
  final rowFinder = find.byKey(row);
  expect(rowFinder, findsOneWidget, reason: '$row');
  final mouse = TestGesture(
    dispatcher: tester.sendEventToBinding,
    pointer: 0x7fff0399,
    device: 0x7fff0399,
    kind: PointerDeviceKind.mouse,
  );
  await mouse.addPointer(location: tester.getCenter(rowFinder));
  await tester.pump();
  final target = find.byKey(key);
  expect(target, findsOneWidget, reason: '$key');
  await tester.tap(target);
  await mouse.removePointer();
  await pumpFrames(tester);
}

Future<void> _openMove(
  WidgetTester tester, {
  String topic = f260Loop,
  String block = f260B1,
}) => _press(tester, f260Row(topic, block), f260Move(topic, block));

Future<void> _openRemove(
  WidgetTester tester, {
  String topic = f260Loop,
  String block = f260B1,
}) => _press(tester, f260Row(topic, block), f260Remove(topic, block));

Future<void> _openFileIn(WidgetTester tester, {String block = f260N1}) =>
    _press(tester, f260NotFiledRow(block), f260FileIn(block));

// ---------- reading ----------

Finder get _dialog => find.byType(AlertDialog);

Finder _inDialog(Finder what) => find.descendant(of: _dialog, matching: what);

Finder _lineText(String text) => _inDialog(find.text(text));

RenderParagraph _para(WidgetTester tester, Finder text) {
  expect(text, findsOneWidget);
  return tester.renderObject<RenderParagraph>(text);
}

TextStyle _style(WidgetTester tester, Finder text) =>
    _para(tester, text).text.style!;

Rect _rect(WidgetTester tester, Finder f) {
  expect(f, findsOneWidget);
  return tester.getRect(f);
}

Future<void> _cancel(WidgetTester tester) async {
  await tester.tap(find.byKey(f260Cancel));
  await pumpFrames(tester);
}

void main() {
  holdFontFetches();

  group('Move to line (AC1)', () {
    testWidgets(
      'Move to shows one line under its title with the quoted preview and the topic title',
      (tester) async {
        await _pump399(tester);
        await _openMove(tester);

        expect(_inDialog(find.text('Move to…')), findsOneWidget);
        expect(_lineText(_moveLine(f260B1Text, 'Player Loop')), findsOneWidget);
        expect(
          find.text('Remove from Player Loop'),
          findsNothing,
          reason: 'only the Remove dialog is retitled',
        );
        await _cancel(tester);
      },
    );

    testWidgets('Move to names the topic the block is filed in', (
      tester,
    ) async {
      await _pump399(tester);
      await _openMove(tester, topic: f260Economy, block: f260B3);

      expect(_lineText(_moveLine(f260B3Text, 'Economy')), findsOneWidget);
      expect(
        _lineText(_moveLine(f260B3Text, 'Player Loop')),
        findsNothing,
        reason: 'the line names Economy, the topic of this row',
      );
      await _cancel(tester);
    });

    testWidgets(
      'Move to shows the markdown preview of the block not its raw markdown',
      (tester) async {
        const raw = '## **Dash** cancels\n- into [wall](https://x.test) slide';
        final preview = markdownPreviewText(raw);
        expect(preview, isNot(raw), reason: 'the fixture has markup to drop');
        expect(preview, isNot(contains('**')));
        expect(preview, isNot(contains('\n')));
        await _pump399(tester, server: _dayOfTexts([raw]));
        await _openMove(tester, block: 'c0');

        expect(_lineText(_moveLine(preview, 'Player Loop')), findsOneWidget);
        expect(_inDialog(find.textContaining('**')), findsNothing);
        expect(_inDialog(find.textContaining('https://')), findsNothing);
        await _cancel(tester);
      },
    );

    testWidgets(
      'Move to cuts a long preview at 48 graphemes and shows a short one whole',
      (tester) async {
        // Each case: the block text and the preview line the rule gives.
        final cases = <(String, String, String)>[
          // (why this case, block text, expected preview)
          ('47 letters are shown whole', 'a' * 47, 'a' * 47),
          ('48 letters are shown whole', 'b' * 48, 'b' * 48),
          (
            '49 letters are cut to 48 and an ellipsis',
            'c' * 49,
            '${'c' * 48}…',
          ),
          (
            '100 letters are cut to 48 and an ellipsis',
            'd' * 100,
            '${'d' * 48}…',
          ),
          (
            'trailing whitespace at the cut is trimmed before the ellipsis',
            '${'e' * 47} ${'f' * 5}',
            '${'e' * 47}…',
          ),
          (
            '48 family emoji clusters are shown whole',
            _family * 48,
            _family * 48,
          ),
          (
            '49 family emoji clusters are cut to 48 clusters',
            _family * 49,
            '${_family * 48}…',
          ),
          ('48 combining clusters are shown whole', _eAcute * 48, _eAcute * 48),
          (
            '49 combining clusters are cut to 48 clusters',
            _eAcute * 49,
            '${_eAcute * 48}…',
          ),
          (
            'a cut after an emoji cluster keeps the cluster whole',
            '${'g' * 47}$_family${'h' * 3}',
            '${'g' * 47}$_family…',
          ),
        ];
        await _pump399(
          tester,
          server: _dayOfTexts([for (final c in cases) c.$2]),
        );
        for (final (i, c) in cases.indexed) {
          await _openMove(tester, block: 'c$i');
          expect(
            _lineText(_moveLine(c.$3, 'Player Loop')),
            findsOneWidget,
            reason: c.$1,
          );
          await _cancel(tester);
        }
      },
    );

    testWidgets(
      'Move to sits 6 px under the title and 16 px above the first field',
      (tester) async {
        await _pump399(tester);
        await _openMove(tester);

        final title = _rect(tester, _inDialog(find.text('Move to…')));
        final line = _rect(
          tester,
          _lineText(_moveLine(f260B1Text, 'Player Loop')),
        );
        final field = _rect(tester, find.byKey(f260TopicField));
        expect(line.top - title.bottom, closeTo(6, 0.01));
        expect(field.top - line.bottom, closeTo(16, 0.01));
        expect(line.left, closeTo(title.left, 0.01));
        await _cancel(tester);
      },
    );
  });

  group('the line stays in the content width (AC1, AC6)', () {
    const long =
        'one two three four five six seven eight nine ten eleven twelve';
    for (final (name, open) in <(String, int)>[
      (
        'the Move to line wraps inside the 360 px content width and leaves the dialog width alone',
        0,
      ),
      (
        'the File in line wraps inside the 360 px content width and leaves the dialog width alone',
        1,
      ),
      (
        'the Remove line wraps inside the 360 px content width and leaves the dialog width alone',
        2,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _pump399(
          tester,
          server: (db) => F260Server(
            db,
            topics: [
              F260Topic(f260Loop, 'Player Loop', [(f260B1, long)]),
            ],
            notFiled: [(f260N1, long)],
          ),
        );
        const cut = 'one two three four five six seven eight nine ten…';
        final line = switch (open) {
          0 => _moveLine(cut, 'Player Loop'),
          1 => _fileLine(cut),
          _ => _removeLine(cut, 'Player Loop'),
        };
        switch (open) {
          case 0:
            await _openMove(tester);
          case 1:
            await _openFileIn(tester);
          default:
            await _openRemove(tester);
        }
        final lineRect = _rect(tester, _lineText(line));
        final field = _rect(
          tester,
          find.byKey(open == 2 ? f260WhyField : f260TopicField),
        );
        expect(field.width, closeTo(360, 0.01), reason: 'content width');
        expect(lineRect.width, lessThanOrEqualTo(360));
        expect(lineRect.left, closeTo(field.left, 0.01));
        // Two lines or more: the fallback font draws 12 px per glyph.
        expect(lineRect.height, greaterThan(18));
        await _cancel(tester);
      });
    }
  });

  group('the line style (AC1)', () {
    for (final (name, open, line) in <(String, int, String)>[
      (
        'the Move to line is sans 12 with line height 1.5 in fg2 and normal weight',
        0,
        '“$f260B1Text” from Player Loop',
      ),
      (
        'the File in line is sans 12 with line height 1.5 in fg2 and normal weight',
        1,
        '“$f260N1Text”',
      ),
      (
        'the Remove line is sans 12 with line height 1.5 in fg2 and normal weight',
        2,
        '“$f260B1Text” stays in the day; only this block is taken out of Player Loop.',
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _pump399(tester);
        switch (open) {
          case 0:
            await _openMove(tester);
          case 1:
            await _openFileIn(tester);
          default:
            await _openRemove(tester);
        }
        final style = _style(tester, _lineText(line));
        final sans = OmType.sans(size: 12);
        expect(style.fontSize, 12);
        expect(style.height, 1.5);
        expect(style.color, OmColors.fg2);
        expect(style.fontFamily, sans.fontFamily);
        expect(style.fontWeight, anyOf(isNull, FontWeight.w400));
        await _cancel(tester);
      });
    }
  });

  group('File in line (AC2)', () {
    testWidgets(
      'File in shows the quoted preview alone with no from and no topic',
      (tester) async {
        await _pump399(tester);
        await _openFileIn(tester);

        expect(_inDialog(find.text('File in…')), findsOneWidget);
        expect(_lineText(_fileLine(f260N1Text)), findsOneWidget);
        expect(_inDialog(find.textContaining('from')), findsNothing);
        await _cancel(tester);
      },
    );

    testWidgets('File in shows the markdown preview and cuts it like Move to', (
      tester,
    ) async {
      const raw =
          '- [ ] **Call** the dentist about the long and winding root canal again';
      final preview = markdownPreviewText(raw);
      expect(preview.length, greaterThan(48));
      final cut = '${preview.substring(0, 48).trimRight()}…';
      await _pump399(
        tester,
        server: (db) => F260Server(
          db,
          topics: [
            F260Topic(f260Loop, 'Player Loop', [(f260B1, f260B1Text)]),
          ],
          notFiled: [(f260N1, raw), ('n2', 'e' * 48), ('n3', 'f' * 49)],
        ),
      );

      await _openFileIn(tester);
      expect(_lineText(_fileLine(cut)), findsOneWidget);
      await _cancel(tester);
      await _openFileIn(tester, block: 'n2');
      expect(_lineText(_fileLine('e' * 48)), findsOneWidget);
      await _cancel(tester);
      await _openFileIn(tester, block: 'n3');
      expect(_lineText(_fileLine('${'f' * 48}…')), findsOneWidget);
      await _cancel(tester);
    });

    testWidgets(
      'File in sits 6 px under the title and 16 px above the first field',
      (tester) async {
        await _pump399(tester);
        await _openFileIn(tester);

        final title = _rect(tester, _inDialog(find.text('File in…')));
        final line = _rect(tester, _lineText(_fileLine(f260N1Text)));
        final field = _rect(tester, find.byKey(f260TopicField));
        expect(line.top - title.bottom, closeTo(6, 0.01));
        expect(field.top - line.bottom, closeTo(16, 0.01));
        await _cancel(tester);
      },
    );
  });

  group('Remove title and line (AC3)', () {
    testWidgets(
      'Remove is titled with the topic and its line says the block stays in the day',
      (tester) async {
        await _pump399(tester);
        await _openRemove(tester);

        expect(_inDialog(find.text('Remove from Player Loop')), findsOneWidget);
        expect(find.text('Remove from this topic'), findsNothing);
        expect(
          _lineText(_removeLine(f260B1Text, 'Player Loop')),
          findsOneWidget,
        );
        await _cancel(tester);
      },
    );

    testWidgets('Remove names the topic of the row it was opened on', (
      tester,
    ) async {
      await _pump399(tester);
      await _openRemove(tester, topic: f260Economy, block: f260B3);

      expect(_inDialog(find.text('Remove from Economy')), findsOneWidget);
      expect(_lineText(_removeLine(f260B3Text, 'Economy')), findsOneWidget);
      expect(_inDialog(find.textContaining('Player Loop')), findsNothing);
      await _cancel(tester);
    });

    testWidgets(
      'Remove cuts the preview at 48 graphemes with the same rule as Move to',
      (tester) async {
        final cases = <(String, String)>[
          ('c' * 49, '${'c' * 48}…'),
          ('b' * 48, 'b' * 48),
          ('${'e' * 47} ${'f' * 5}', '${'e' * 47}…'),
          (_family * 49, '${_family * 48}…'),
        ];
        await _pump399(
          tester,
          server: _dayOfTexts([for (final c in cases) c.$1]),
        );
        for (final (i, c) in cases.indexed) {
          await _openRemove(tester, block: 'c$i');
          expect(
            _lineText(_removeLine(c.$2, 'Player Loop')),
            findsOneWidget,
            reason: 'case $i',
          );
          await _cancel(tester);
        }
      },
    );

    testWidgets(
      'Remove shows the markdown preview of the block not its raw markdown',
      (tester) async {
        const raw = '> **quoted** [link](https://x.test) text';
        final preview = markdownPreviewText(raw);
        expect(preview, isNot(raw));
        await _pump399(tester, server: _dayOfTexts([raw]));
        await _openRemove(tester, block: 'c0');

        expect(_lineText(_removeLine(preview, 'Player Loop')), findsOneWidget);
        await _cancel(tester);
      },
    );

    testWidgets(
      'Remove sits 6 px under its title and 16 px above the Why field',
      (tester) async {
        await _pump399(tester);
        await _openRemove(tester);

        final title = _rect(
          tester,
          _inDialog(find.text('Remove from Player Loop')),
        );
        final line = _rect(
          tester,
          _lineText(_removeLine(f260B1Text, 'Player Loop')),
        );
        final field = _rect(tester, find.byKey(f260WhyField));
        expect(line.top - title.bottom, closeTo(6, 0.01));
        expect(field.top - line.bottom, closeTo(16, 0.01));
        await _cancel(tester);
      },
    );
  });

  group('nothing else in the dialogs changes (AC4)', () {
    testWidgets(
      'the Move to dialog keeps its fields labels buttons and Keys beside the new line',
      (tester) async {
        await _pump399(tester);
        await _openMove(tester);

        expect(_lineText(_moveLine(f260B1Text, 'Player Loop')), findsOneWidget);
        expect(find.byKey(f260TopicField), findsOneWidget);
        expect(find.byKey(f260WhyField), findsOneWidget);
        expect(find.text('Topic note'), findsOneWidget);
        expect(find.text('Why? (optional)'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(f260Cancel),
            matching: find.text('Cancel'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(f260Confirm),
            matching: find.text('Move'),
          ),
          findsOneWidget,
        );
        expect(find.byType(TextButton), findsOneWidget);
        expect(find.byType(FilledButton), findsOneWidget);
        // The source topic is not offered; the others are, with their Keys.
        expect(find.byKey(f260Option(f260Loop)), findsNothing);
        expect(find.byKey(f260Option(f260Economy)), findsOneWidget);
        await _cancel(tester);
      },
    );

    testWidgets(
      'the File in dialog keeps its fields labels buttons and Keys beside the new line',
      (tester) async {
        await _pump399(tester);
        await _openFileIn(tester);

        expect(_lineText(_fileLine(f260N1Text)), findsOneWidget);
        expect(find.byKey(f260TopicField), findsOneWidget);
        expect(find.byKey(f260WhyField), findsOneWidget);
        expect(find.text('Topic note'), findsOneWidget);
        expect(find.text('Why? (optional)'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(f260Confirm),
            matching: find.text('File'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(f260Option(f260Loop)), findsOneWidget);
        await _cancel(tester);
      },
    );

    testWidgets(
      'the Remove dialog keeps only its Why field and its buttons beside the new line',
      (tester) async {
        await _pump399(tester);
        await _openRemove(tester);

        expect(
          _lineText(_removeLine(f260B1Text, 'Player Loop')),
          findsOneWidget,
        );
        expect(find.byKey(f260WhyField), findsOneWidget);
        expect(find.byKey(f260TopicField), findsNothing);
        expect(find.text('Why? (optional)'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(f260Confirm),
            matching: find.text('Remove'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(f260Cancel),
            matching: find.text('Cancel'),
          ),
          findsOneWidget,
        );
        await _cancel(tester);
      },
    );

    for (final (name, open) in <(String, int)>[
      (
        'Cancel and Esc close the Move to dialog with the new line and change nothing',
        0,
      ),
      (
        'Cancel and Esc close the File in dialog with the new line and change nothing',
        1,
      ),
      (
        'Cancel and Esc close the Remove dialog with the new line and change nothing',
        2,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final s = await _pump399(tester);
        Future<void> openIt() async {
          switch (open) {
            case 0:
              await _openMove(tester);
            case 1:
              await _openFileIn(tester);
            default:
              await _openRemove(tester);
          }
        }

        final line = switch (open) {
          0 => _moveLine(f260B1Text, 'Player Loop'),
          1 => _fileLine(f260N1Text),
          _ => _removeLine(f260B1Text, 'Player Loop'),
        };
        await openIt();
        expect(_lineText(line), findsOneWidget);
        await tester.tap(find.byKey(f260Cancel));
        await pumpFrames(tester);
        expect(_dialog, findsNothing, reason: 'Cancel closes');

        await openIt();
        expect(_lineText(line), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await pumpFrames(tester);
        expect(_dialog, findsNothing, reason: 'Esc closes');

        for (final verb in [
          'excerpt move',
          'excerpt add',
          'excerpt remove-block',
        ]) {
          expect(s.cli.callsFor(verb), isEmpty, reason: verb);
        }
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsOneWidget);
        expect(find.byKey(f260NotFiledRow(f260N1)), findsOneWidget);
      });
    }

    testWidgets('Move to still returns the chosen topic and the trimmed Why', (
      tester,
    ) async {
      final s = await _pump399(tester);
      await _openMove(tester);
      expect(_lineText(_moveLine(f260B1Text, 'Player Loop')), findsOneWidget);
      await tester.tap(find.byKey(f260Option(f260Economy)));
      await pumpFrames(tester);
      await tester.enterText(find.byKey(f260WhyField), '  this is pricing  ');
      await pumpFrames(tester);
      await tester.tap(find.byKey(f260Confirm));
      await pumpFrames(tester);

      final move = s.cli.callsFor('excerpt move').single;
      expect(move.flag('from-topic-note-id'), f260Loop);
      expect(move.flag('to-topic-note-id'), f260Economy);
      expect(move.flag('block-id'), f260B1);
      expect(move.flag('note'), 'this is pricing');
      expect(find.byKey(f260Row(f260Economy, f260B1)), findsOneWidget);
    });

    testWidgets(
      'File in still returns the chosen topic with no note when Why is blank',
      (tester) async {
        final s = await _pump399(tester);
        await _openFileIn(tester);
        expect(_lineText(_fileLine(f260N1Text)), findsOneWidget);
        await tester.tap(find.byKey(f260Option(f260Economy)));
        await pumpFrames(tester);
        await tester.tap(find.byKey(f260Confirm));
        await pumpFrames(tester);

        final file = s.cli.callsFor('excerpt add').single;
        expect(file.flag('topic-note-id'), f260Economy);
        expect(file.flag('block-id'), f260N1);
        expect(file.hasFlag('note'), isFalse);
      },
    );

    testWidgets('Remove still returns the trimmed Why', (tester) async {
      final s = await _pump399(tester);
      await _openRemove(tester);
      expect(_lineText(_removeLine(f260B1Text, 'Player Loop')), findsOneWidget);
      await tester.enterText(find.byKey(f260WhyField), ' not about this ');
      await pumpFrames(tester);
      await tester.tap(find.byKey(f260Confirm));
      await pumpFrames(tester);

      final remove = s.cli.callsFor('excerpt remove-block').single;
      expect(remove.flag('topic-note-id'), f260Loop);
      expect(remove.flag('block-id'), f260B1);
      expect(remove.flag('note'), 'not about this');
    });
  });

  group('Activity subtitle and day line (AC5)', () {
    testWidgets('the Activity subtitle is drawn in fg2 not fg3', (
      tester,
    ) async {
      await pumpF260(tester);

      final subtitle = find.text(_subtitle);
      final style = _style(tester, subtitle);
      expect(style.color, const Color(0xFF9B9A94));
      expect(style.color, OmColors.fg2);
      expect(style.color, isNot(OmColors.fg3));
      expect(style.fontSize, 10.5);
      expect(style.height, 1.6);
    });

    testWidgets(
      'each agent entry day line is drawn in fg2 and its time line stays agent',
      (tester) async {
        await pumpF260(tester);

        final entry = find.byKey(const Key('activity-entry-ac-1'));
        final day = find.descendant(of: entry, matching: find.text(f260Date));
        final dayStyle = _style(tester, day);
        expect(dayStyle.color, OmColors.fg2);
        expect(dayStyle.color, isNot(OmColors.fg3));
        expect(dayStyle.fontSize, 10.5);

        final when = find.descendant(
          of: entry,
          matching: find.text('5 Nov 2026, 14:32'),
        );
        final whenStyle = _style(tester, when);
        expect(
          whenStyle.color,
          OmColors.agent,
          reason: 'the time line is unchanged',
        );
        expect(whenStyle.fontSize, 11);
      },
    );

    testWidgets(
      'an Activity tab with no entries still draws its placeholder subtitle and empty copy in fg3',
      (tester) async {
        await pumpF260(
          tester,
          db: f260Db(agentEntry: false, reviewedRow: false),
          noteId: f260Loop,
        );

        final subtitleStyle = _style(tester, find.text(_subtitle));
        expect(
          subtitleStyle.color,
          OmColors.fg3,
          reason: 'PanelPlaceholderTab',
        );
        final emptyStyle = _style(
          tester,
          find.byKey(const Key('activity-empty')),
        );
        expect(emptyStyle.color, OmColors.fg3);
      },
    );

    testWidgets(
      'PanelPlaceholderTab pumped alone still draws its subtitle and empty copy in fg3',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildOmTheme(),
            home: const Scaffold(
              body: PanelPlaceholderTab(
                eyebrow: 'some eyebrow',
                subtitle: 'some subtitle',
                empty: 'nothing here yet',
                emptyKey: Key('placeholder-empty'),
              ),
            ),
          ),
        );
        await tester.pump();

        final subtitle = _style(tester, find.text('some subtitle'));
        expect(subtitle.color, OmColors.fg3);
        expect(subtitle.fontSize, 10.5);
        expect(subtitle.height, 1.6);
        final empty = _style(
          tester,
          find.byKey(const Key('placeholder-empty')),
        );
        expect(empty.color, OmColors.fg3);
        expect(empty.fontSize, 11);
      },
    );
  });

  group('at 1.5x text scale (AC6)', () {
    for (final (name, open) in <(String, int)>[
      (
        'at 1.5x the Move to buttons and line grow with their text and nothing overflows',
        0,
      ),
      (
        'at 1.5x the File in buttons and line grow with their text and nothing overflows',
        1,
      ),
      (
        'at 1.5x the Remove buttons and line grow with their text and nothing overflows',
        2,
      ),
    ]) {
      testWidgets(name, (tester) async {
        // The long preview makes the line wrap, to show the dialog grows.
        const long =
            'one two three four five six seven eight nine ten eleven twelve';
        final cut = '${long.substring(0, 48).trimRight()}…';
        final measured = <double, ({Size cancel, Size confirm, Size line})>{};
        for (final scale in [1.0, 1.5]) {
          await _pump399(
            tester,
            scale: scale,
            size: const Size(800, 1600),
            server: (db) => F260Server(
              db,
              topics: [
                F260Topic(f260Loop, 'Player Loop', [(f260B1, long)]),
              ],
              notFiled: [(f260N1, long)],
            ),
          );
          late String line;
          switch (open) {
            case 0:
              await _openMove(tester);
              line = _moveLine(cut, 'Player Loop');
            case 1:
              await _openFileIn(tester);
              line = _fileLine(cut);
            default:
              await _openRemove(tester);
              line = _removeLine(cut, 'Player Loop');
          }
          expect(_lineText(line), findsOneWidget, reason: '$name at $scale');
          expect(tester.takeException(), isNull, reason: '$name at $scale');
          // The dialog fills the route, so check what it holds instead:
          // everything stays on screen and the buttons sit in the dialog's
          // 360 px content column plus its padding.
          for (final f in [
            _lineText(line),
            find.byKey(f260Cancel),
            find.byKey(f260Confirm),
            find.byKey(f260WhyField),
          ]) {
            final r = _rect(tester, f);
            expect(r.left, greaterThanOrEqualTo(0));
            expect(r.right, lessThanOrEqualTo(800));
            expect(r.top, greaterThanOrEqualTo(0));
            expect(r.bottom, lessThanOrEqualTo(1600));
          }
          final lineRect = _rect(tester, _lineText(line));
          final whyRect = _rect(tester, find.byKey(f260WhyField));
          expect(
            lineRect.width,
            lessThanOrEqualTo(360),
            reason: 'the line wraps in the 360 px content width',
          );
          expect(
            whyRect.top,
            greaterThanOrEqualTo(lineRect.bottom),
            reason: 'the line never overlaps the fields',
          );
          measured[scale] = (
            cancel: tester.getSize(find.byKey(f260Cancel)),
            confirm: tester.getSize(find.byKey(f260Confirm)),
            line: tester.getSize(_lineText(line)),
          );
          expect(find.byType(TextButton), findsOneWidget);
          expect(find.byType(FilledButton), findsOneWidget);
          await _cancel(tester);
        }
        final one = measured[1.0]!;
        final big = measured[1.5]!;
        expect(big.cancel.width, greaterThan(one.cancel.width));
        // Material keeps a 48 px minimum height: it never shrinks.
        expect(big.cancel.height, greaterThanOrEqualTo(one.cancel.height));
        expect(big.confirm.width, greaterThan(one.confirm.width));
        expect(big.confirm.height, greaterThanOrEqualTo(one.confirm.height));
        expect(big.line.height, greaterThan(one.line.height));
      });
    }
  });
}
