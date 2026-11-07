// WI #253 (A5), verify-mode pins: contracts of the footer's split and its x
// that the mapped tests leave to their neighbours. The last footer item
// leaving keeps the text field, a guide note keeps a marker line as text, a
// one-row footer has no gap row, a removed tag the vault gets back shows again, and the x's key handler activates on key down
// only and swallows exactly the keys it uses.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/note_footer_harness.dart';
import '../support/tags_seed.dart';

const _tags = ['memex', 'pricing'];

/// The state of the note's first text segment view: a new one means the
/// segments were rebuilt, the same one means their controllers were kept.
State _firstSegmentView(WidgetTester tester) =>
    tester.state(find.byType(SegmentView).first);

void main() {
  group('a guide note', () {
    testWidgets('keeps a marker line and the lines below it as editable text', (
      tester,
    ) async {
      final body = footerBody(footerPerson, tags: const ['memex']);
      final r = await launchFooterNote(
        tester,
        seedFooterVault(body: body, role: 'guide'),
      );

      expect(r.segmentText(0), body);
      expect(footerRow, findsNothing);
    });
  });

  group('the segments', () {
    testWidgets(
      'a guide note opened from a topic note shows its marker as text',
      (tester) async {
        final body = footerBody('Same\n', tags: const ['memex']);
        final vault = seedFooterVault(body: body, footerTags: const ['memex']);
        seedFooterNote(
          vault.db,
          id: 'note-guide',
          title: 'Guide',
          body: body,
          role: 'guide',
          footerTags: const ['memex'],
        );
        final r = await launchFooterNote(tester, vault);
        expect(footerTag('memex'), findsOneWidget);

        await r.open('note-guide');

        expect(r.segmentText(0), body);
        expect(footerRow, findsNothing);
      },
    );

    testWidgets('the last footer item leaving after a x keeps the text field', (
      tester,
    ) async {
      final r = await launchFooterNote(
        tester,
        seedFooterVault(
          body: footerBody(footerPerson, tags: const ['memex']),
          footerTags: const ['memex'],
        ),
      );
      final mouse = await addMouse(tester);
      final before = _firstSegmentView(tester);

      await clickX(tester, mouse, 'memex');
      await pumpFrames(tester);

      expect(footerRow, findsNothing);
      expect(
        r.h.read(editorControllerProvider).contentMd,
        footerPerson,
        reason: 'the editor took the server write',
      );
      expect(r.segmentText(0), footerPerson);
      expect(identical(_firstSegmentView(tester), before), isTrue);
    });
  });

  group('a footer with one row', () {
    testWidgets('a Tags row alone has no gap row under it', (tester) async {
      final vault = seedFooterVault(footerTags: _tags);

      await pumpBareNote(tester, vault.db, width: 1400, textScale: 1);

      // 1 px rule + 10 px padding above the row, nothing below it.
      expect(
        tester.getTopLeft(footerTag('memex')).dy -
            tester.getTopLeft(footerRow).dy,
        33,
      );
      expect(
        tester.getBottomLeft(footerRow).dy,
        tester.getBottomLeft(footerTag('memex')).dy,
      );
    });

    testWidgets('a Topics row alone has no gap row under it', (tester) async {
      final vault = seedFooterVault(chips: const {pricingTopicId: 'Pricing'});

      await pumpBareNote(tester, vault.db, width: 1400, textScale: 1);

      expect(
        tester.getTopLeft(footerChip(pricingTopicId)).dy -
            tester.getTopLeft(footerRow).dy,
        33,
      );
      expect(
        tester.getBottomLeft(footerRow).dy,
        tester.getBottomLeft(footerChip(pricingTopicId)).dy,
      );
    });
  });

  group('a removed tag', () {
    testWidgets('shows again when the vault gets it back', (tester) async {
      final vault = seedFooterVault(
        body: footerBody(footerPerson, tags: _tags),
        footerTags: _tags,
      );
      final r = await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);

      await clickX(tester, mouse, 'pricing');
      await pumpFrames(tester);
      expect(footerTag('pricing'), findsNothing);

      r.h.db.seedTag(footerNoteId, 'pricing', origin: 'agent');
      r.h.read(vaultRevisionProvider.notifier).state++;
      await pumpFrames(tester);

      expect(footerTag('pricing'), findsOneWidget);
      expect(footerTag('memex'), findsOneWidget);
    });
  });

  group('the x key handler', () {
    FooterVault failing() {
      final vault = seedFooterVault(
        body: footerBody(footerPerson, tags: _tags),
        footerTags: _tags,
      );
      vault.cli.on(
        'tag rm',
        (_) => FakeMemexCli.error('internal', 'the disk is full'),
      );
      return vault;
    }

    testWidgets('the numpad Enter key removes the tag', (tester) async {
      final r = await launchFooterNote(tester, failing());

      expect(await shiftTabToX(tester, 'pricing'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await pumpFrames(tester);

      expect(r.h.cli.callsFor('tag rm'), hasLength(1));
      expect(r.h.cli.callsFor('tag rm').single.flag('tag'), 'pricing');
    });

    for (final (name, key) in [
      ('Enter', LogicalKeyboardKey.enter),
      ('Space', LogicalKeyboardKey.space),
    ]) {
      testWidgets(
        'one press of $name removes once on key down and not on repeat or release',
        (tester) async {
          final r = await launchFooterNote(tester, failing());
          expect(await shiftTabToX(tester, 'pricing'), isTrue);

          await tester.sendKeyDownEvent(key);
          await pumpFrames(tester);
          expect(r.h.cli.callsFor('tag rm'), hasLength(1));
          expect(footerError, findsOneWidget, reason: 'the write finished');

          await tester.sendKeyRepeatEvent(key);
          await pumpFrames(tester);
          await tester.sendKeyUpEvent(key);
          await pumpFrames(tester);

          expect(r.h.cli.callsFor('tag rm'), hasLength(1));
        },
      );
    }

    testWidgets(
      'Enter, numpad Enter and Space stop at the x on down, repeat and up, and other keys go on',
      (tester) async {
        await launchFooterNote(tester, failing());
        expect(await shiftTabToX(tester, 'pricing'), isTrue);
        final root = FocusManager.instance.rootScope;
        final before = root.onKeyEvent;
        final seen = <(LogicalKeyboardKey, Type)>[];
        root.onKeyEvent = (node, event) {
          seen.add((event.logicalKey, event.runtimeType));
          return KeyEventResult.ignored;
        };
        addTearDown(() => root.onKeyEvent = before);

        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.space,
        ]) {
          await tester.sendKeyDownEvent(key);
          await pumpFrames(tester);
          await tester.sendKeyRepeatEvent(key);
          await tester.sendKeyUpEvent(key);
          await pumpFrames(tester);
        }
        expect(seen, isEmpty);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await pumpFrames(tester);
        expect(seen.map((e) => e.$1), contains(LogicalKeyboardKey.keyA));
      },
    );
  });

  test('split with noteFooter false keeps a marker line as text', () {
    const body = 'Plan\n$topicsMarker\n[[Pricing~about]]\n#memex\n';

    final segments = split(body, isDaily: false, noteFooter: false);

    expect(segments, hasLength(1));
    expect((segments.single as TextSegment).text, body);
    expect(join(segments), body);
  });
}
