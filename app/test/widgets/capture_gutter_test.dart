// WI #28 (A10): the captured-text gutter (Req 33). A thin rule (Key
// `capture-gutter-rule-<blockId>`) in the gutter column (Key
// `capture-gutter`) beside the daily person field marks the lines of each
// `agent` and `quick-entry` block, with the C5 hover caption; person blocks
// get none. Line positions come from the blocks' UTF-8 byte ranges.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/theme/colors.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/poll_fakes.dart';

final _at1432 = DateTime(2026, 10, 3, 14, 32);

final _mixedBlocks = [
  const SeedBlock('p-jump', 'Fixed the jump arc.'),
  SeedBlock(
    'a-bug',
    'Agent saw a bug.',
    source: 'agent',
    createdVersion: 2,
    createdAt: _at1432,
  ),
  const SeedBlock('p-sleep', 'Sleep was bad.'),
  SeedBlock(
    'q-milk',
    'Buy milk.\nCall mum.',
    source: 'quick-entry',
    createdVersion: 3,
    createdAt: _at1432,
  ),
];

Future<LiveRobot> _launch(WidgetTester tester, List<SeedBlock> blocks) async {
  final db = FakeVaultDb.v5()..seedLiveDaily(blocks: blocks);
  final clock = FakeClock(DateTime(2026, 10, 3, 15));
  final cli = FakeMemexCli()..onUpdateServer(db, clock: clock);
  return pumpLiveWorkspace(tester, db: db, cli: cli, clock: clock);
}

/// [rule] spans the vertical centre of the line at [offset].
void _expectCovers(LiveRobot r, Rect rule, int offset, {String? reason}) {
  final y = r.lineCenterY(offset);
  expect(
    rule.top <= y && y <= rule.bottom,
    isTrue,
    reason: '${reason ?? 'line at $offset'}: centre $y not in $rule',
  );
}

/// [rule] does not reach the vertical centre of the line at [offset].
void _expectMisses(LiveRobot r, Rect rule, int offset, {String? reason}) {
  final y = r.lineCenterY(offset);
  expect(
    y < rule.top || y > rule.bottom,
    isTrue,
    reason: '${reason ?? 'line at $offset'}: centre $y inside $rule',
  );
}

void main() {
  group('gutter rules for captured blocks (AC10)', () {
    testWidgets(
      'a daily note with person, agent and quick-entry blocks shows a gutter rule beside each agent and quick-entry block and none beside person blocks',
      (tester) async {
        final r = await _launch(tester, _mixedBlocks);

        expect(r.gutter, findsOneWidget);
        expect(r.gutterRule('a-bug'), findsOneWidget);
        expect(r.gutterRule('q-milk'), findsOneWidget);
        expect(r.gutterRule('p-jump'), findsNothing);
        expect(r.gutterRule('p-sleep'), findsNothing);
        expect(r.allGutterRules, findsNWidgets(2));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'each gutter rule is aligned to the lines of its block and sits beside the person field',
      (tester) async {
        final r = await _launch(tester, _mixedBlocks);
        final text = r.bodyText;
        final agent = tester.getRect(r.gutterRule('a-bug'));
        final quick = tester.getRect(r.gutterRule('q-milk'));

        _expectCovers(r, agent, text.indexOf('Agent saw a bug.'));
        _expectMisses(r, agent, text.indexOf('Fixed the jump arc.'));
        _expectMisses(r, agent, text.indexOf('Sleep was bad.'));

        // A two-line block: the rule spans both lines.
        _expectCovers(r, quick, text.indexOf('Buy milk.'));
        _expectCovers(r, quick, text.indexOf('Call mum.'));
        _expectMisses(r, quick, text.indexOf('Sleep was bad.'));

        // Beside the field, left of its text column.
        final textLeft = r.bodyTextLeft;
        for (final rule in [agent, quick]) {
          expect(
            rule.right <= textLeft + 0.5,
            isTrue,
            reason: 'rule $rule overlaps the person text starting at $textLeft',
          );
        }
      },
    );

    testWidgets('an agent block gutter rule uses the OmColors.agent token', (
      tester,
    ) async {
      final r = await _launch(tester, _mixedBlocks);

      expect(
        paintsColor(tester, r.gutterRule('a-bug'), OmColors.agent),
        isTrue,
      );
      expect(
        paintsColor(tester, r.gutterRule('q-milk'), OmColors.agent),
        isFalse,
        reason: 'quick entry uses its own theme token',
      );
    });

    testWidgets('a daily note with only person blocks shows no gutter rules', (
      tester,
    ) async {
      final r = await _launch(tester, const [
        SeedBlock('p-jump', 'Fixed the jump arc.'),
        SeedBlock('p-sleep', 'Sleep was bad.'),
      ]);

      expect(r.allGutterRules, findsNothing);
      // The captured block positive control for this fixture shape.
      r.db.serverAppend(
        liveDailyId,
        'Agent line.',
        blockId: 'a-late',
        at: DateTime(2026, 10, 3, 15, 0, 1),
      );
      await r.poll();
      expect(r.allGutterRules, findsOneWidget);
      expect(r.gutterRule('a-late'), findsOneWidget);
    });
  });

  group('gutter hover captions (AC11)', () {
    testWidgets(
      'hovering an agent block gutter rule shows captured via agent, 14:32',
      (tester) async {
        final r = await _launch(tester, _mixedBlocks);
        expect(find.text('captured via agent, 14:32'), findsNothing);

        await r.hover(r.gutterRule('a-bug'));

        expect(find.text('captured via agent, 14:32'), findsOneWidget);
        expect(find.text('added via quick entry, 14:32'), findsNothing);
      },
    );

    testWidgets(
      'hovering a quick-entry block gutter rule shows added via quick entry, 14:32',
      (tester) async {
        final r = await _launch(tester, _mixedBlocks);
        expect(find.text('added via quick entry, 14:32'), findsNothing);

        await r.hover(r.gutterRule('q-milk'));

        expect(find.text('added via quick entry, 14:32'), findsOneWidget);
        expect(find.text('captured via agent, 14:32'), findsNothing);
      },
    );

    testWidgets('the hover caption shows each block own created_at time', (
      tester,
    ) async {
      final r = await _launch(tester, [
        const SeedBlock('p-jump', 'Fixed the jump arc.'),
        SeedBlock(
          'a-early',
          'Early capture.',
          source: 'agent',
          createdAt: DateTime(2026, 10, 3, 7, 5),
        ),
      ]);

      await r.hover(r.gutterRule('a-early'));

      expect(find.text('captured via agent, 07:05'), findsOneWidget);
    });
  });

  group('multi-byte text (AC12)', () {
    testWidgets(
      'a block with cafe and coffee-cup text after multi-byte lines gets its gutter rule on its own line',
      (tester) async {
        // 20 x U+2615 (3 UTF-8 bytes, 1 UTF-16 unit each) before the block:
        // its start_byte (62) read as a UTF-16 index would land six lines
        // further down, in the `six` line.
        final r = await _launch(tester, const [
          SeedBlock('p-coffee', '☕☕☕☕☕☕☕☕☕☕☕☕☕☕☕☕☕☕☕☕'),
          SeedBlock('a-cafe', 'café ☕ notes', source: 'agent'),
          SeedBlock(
            'p-list',
            'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten',
          ),
        ]);
        final text = r.bodyText;
        expect(text.indexOf('café ☕ notes'), 22);
        final rule = tester.getRect(r.gutterRule('a-cafe'));

        _expectCovers(r, rule, 22, reason: 'the café line');
        _expectMisses(r, rule, 0, reason: 'the coffee-cup line');
        _expectMisses(r, rule, text.indexOf('one'), reason: 'the one line');
        _expectMisses(r, rule, text.indexOf('six'), reason: 'the six line');
      },
    );

    testWidgets(
      'a block after surrogate-pair emoji lines gets its gutter rule on its own line',
      (tester) async {
        // U+1F3AE is 4 UTF-8 bytes and 2 UTF-16 units.
        final r = await _launch(tester, const [
          SeedBlock('p-games', '🎮🎮🎮🎮🎮🎮🎮🎮🎮🎮'),
          SeedBlock('p-mid', 'alpha\nbeta'),
          SeedBlock('a-cafe', 'café ☕ notes', source: 'agent'),
          SeedBlock('p-list', 'one\ntwo\nthree\nfour\nfive\nsix\nseven'),
        ]);
        final text = r.bodyText;
        final start = text.indexOf('café ☕ notes');
        final rule = tester.getRect(r.gutterRule('a-cafe'));

        _expectCovers(r, rule, start, reason: 'the café line');
        _expectMisses(r, rule, text.indexOf('beta'), reason: 'the beta line');
        _expectMisses(r, rule, text.indexOf('one'), reason: 'the one line');
        _expectMisses(r, rule, text.indexOf('two'), reason: 'the two line');
        _expectMisses(r, rule, text.indexOf('three'), reason: 'the three line');
      },
    );
  });

  group('captured text stays editable (AC13)', () {
    testWidgets(
      'the person edits the text of an agent block in the single field and the edit saves through memex update',
      (tester) async {
        final r = await _launch(tester, _mixedBlocks);
        expect(r.gutterRule('a-bug'), findsOneWidget);
        // One editable person field for the daily note.
        expect(
          find.byWidgetPredicate((w) {
            final k = w.key;
            return k is ValueKey<String> &&
                RegExp(r'^text-segment-\d+$').hasMatch(k.value);
          }),
          findsOneWidget,
        );

        // Tapping the agent line puts the caret inside the agent block.
        final start = r.bodyText.indexOf('Agent saw a bug.');
        await tester.tapAt(Offset(r.bodyTextLeft + 30, r.lineCenterY(start)));
        await tester.pump(const Duration(milliseconds: 350));
        expect(r.bodyHasFocus, isTrue);
        expect(
          r.bodySelection.baseOffset,
          inInclusiveRange(start, start + 'Agent saw a bug.'.length),
        );

        final edited = r.bodyText.replaceFirst(
          'Agent saw a bug.',
          'Agent saw a big bug.',
        );
        await r.type(edited);
        await r.fireDebounce();

        expect(r.updates, hasLength(1));
        expect(r.updates.single.flag('expected-version'), '3');
        expect(
          r.updates.single.stdinBody,
          assembleDailyBody(edited, const [liveZetaTitle]),
        );
        expect(
          r.db.liveNote(liveDailyId).content,
          contains('Agent saw a big bug.'),
        );
        expect(r.editor.status, SaveStatus.clean);
      },
    );
  });
}
