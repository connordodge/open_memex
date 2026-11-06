// WI #253 (A5): the meta rail's tags and the right panel's tag count. Design
// pack 253: the whole rail is fg2 with no clock icon, the tags are a group with
// an 8 px gap, read-only, and a click reveals the tag in Tags mode.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/app_harness.dart';
import '../support/note_footer_harness.dart';

Finder _inHeader(Finder what) =>
    find.descendant(of: noteHeader, matching: what);

Finder get _separators => _inHeader(find.text('·'));

void main() {
  group('rail tags', () {
    testWidgets(
      'the rail shows non-system tags as read-only text with their keys and no system tags',
      (tester) async {
        final r = await launchFooterNote(
          tester,
          seedFooterVault(
            footerTags: ['memex', 'pricing'],
            bodyTags: ['work'],
            systemTags: ['inbox', 'agent-authored'],
          ),
        );

        for (final tag in ['memex', 'pricing', 'work']) {
          expect(railTag(tag), findsOneWidget);
          expect(
            find.descendant(of: railTag(tag), matching: find.text('#$tag')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: railTag(tag),
              matching: find.byType(EditableText),
            ),
            findsNothing,
          );
        }
        expect(railTag('inbox'), findsNothing);
        expect(railTag('agent-authored'), findsNothing);
        expect(_inHeader(find.text('#inbox')), findsNothing);
        expect(_inHeader(find.text('#agent-authored')), findsNothing);
        expect(r.h.db.getNote(footerNoteId)!.tags, contains('inbox'));
      },
    );

    testWidgets('the separate tag line under the title is gone', (
      tester,
    ) async {
      await launchFooterNote(
        tester,
        seedFooterVault(footerTags: ['memex'], bodyTags: ['work']),
      );

      expect(_inHeader(find.text('#work')), findsOneWidget);
      expect(_inHeader(find.text('#memex')), findsOneWidget);
      expect(
        find.descendant(of: railTag('work'), matching: find.text('#work')),
        findsOneWidget,
      );
      // Every tag sits above the title, in the rail.
      expect(
        tester.getTopLeft(railTag('work')).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('editor-title'))).dy),
      );
    });

    testWidgets('clicking a rail tag calls revealTag', (tester) async {
      final r = await launchFooterNote(
        tester,
        seedFooterVault(footerTags: ['memex'], bodyTags: ['work']),
      );

      await tester.tap(railTag('work'));
      await pumpFrames(tester);

      expectRevealed(r.h, 'work');
    });

    testWidgets('each rail tag reveals itself and not its neighbour', (
      tester,
    ) async {
      final r = await launchFooterNote(
        tester,
        seedFooterVault(footerTags: ['memex'], bodyTags: ['work']),
      );

      await tester.tap(railTag('memex'));
      await pumpFrames(tester);

      expectRevealed(r.h, 'memex');
    });

    testWidgets(
      'rail tags are alphabetical with an 8 px gap and the two separators before them',
      (tester) async {
        await launchFooterNote(
          tester,
          seedFooterVault(footerTags: ['pricing', 'memex'], bodyTags: ['work']),
        );

        final memex = tester.getRect(railTag('memex'));
        final pricing = tester.getRect(railTag('pricing'));
        final work = tester.getRect(railTag('work'));
        expect(pricing.left - memex.right, 8);
        expect(work.left - pricing.right, 8);
        expect(_separators, findsNWidgets(2));
        expect(
          tester.getTopRight(_separators.last).dx,
          lessThanOrEqualTo(memex.left),
        );
        // Each rail item keeps its 14 px gap: the words, then the dot.
        expect(memex.left - tester.getTopRight(_separators.last).dx, 14);
      },
    );

    testWidgets('the whole rail is fg2 with no clock icon', (tester) async {
      await launchFooterNote(
        tester,
        seedFooterVault(footerTags: ['memex'], bodyTags: ['work']),
      );

      expect(_inHeader(find.byIcon(LucideIcons.clock)), findsNothing);
      expect(colorOf(tester, _inHeader(find.text('#memex'))), OmColors.fg2);
      expect(colorOf(tester, _inHeader(find.text('#work'))), OmColors.fg2);
      expect(
        colorOf(tester, _inHeader(find.textContaining('updated '))),
        OmColors.fg2,
      );
      expect(
        colorOf(tester, _inHeader(find.textContaining(' words'))),
        OmColors.fg2,
      );
      for (final dot in _separators.evaluate()) {
        expect((dot.widget as Text).style?.color, OmColors.fg2);
      }
    });

    testWidgets('a rail tag draws no underline and no hover colour', (
      tester,
    ) async {
      await launchFooterNote(tester, seedFooterVault(bodyTags: ['work']));
      final text = _inHeader(find.text('#work'));
      final mouse = await addMouse(tester);

      await hover(tester, mouse, railTag('work'));

      expect(colorOf(tester, text), OmColors.fg2);
      expect(
        effectiveStyle(tester, text).decoration ?? TextDecoration.none,
        TextDecoration.none,
      );
    });

    testWidgets(
      'a note with only system tags shows one separator and no tag group',
      (tester) async {
        await launchFooterNote(
          tester,
          seedFooterVault(systemTags: ['inbox', 'agent-authored']),
        );

        expect(_separators, findsOneWidget);
        expect(railTag('inbox'), findsNothing);
        expect(_inHeader(find.textContaining('#')), findsNothing);
        expect(
          (_separators.evaluate().single.widget as Text).style?.color,
          OmColors.fg2,
        );
      },
    );

    testWidgets('a note with no tags keeps its rail words in fg2', (
      tester,
    ) async {
      await launchFooterNote(tester, seedFooterVault());

      expect(_separators, findsOneWidget);
      expect(
        colorOf(tester, _inHeader(find.textContaining(' words'))),
        OmColors.fg2,
      );
    });

    testWidgets(
      'a long list of rail tags wraps without overflow at the narrowest width and large text',
      (tester) async {
        final tags = [
          for (var i = 0; i < 14; i++) 'rail-tag-number-$i',
          'a-very-long-rail-tag-${'x' * 120}',
        ];
        final vault = seedFooterVault(bodyTags: tags);

        await pumpBareNote(tester, vault.db, width: 320, textScale: 2);

        expect(tester.takeException(), isNull);
        for (final tag in tags) {
          expect(railTag(tag), findsOneWidget);
        }
        final rows = {
          for (final tag in tags) tester.getTopLeft(railTag(tag)).dy,
        };
        expect(rows.length, greaterThan(1));
      },
    );
  });

  group('right panel', () {
    testWidgets('right_panel counts visibleTags', (tester) async {
      final r = await launchFooterNote(
        tester,
        seedFooterVault(
          footerTags: ['memex'],
          bodyTags: ['work'],
          systemTags: ['inbox', 'agent-authored'],
        ),
      );
      r.h.container.read(rightPanelOpenProvider.notifier).state = true;
      r.h.container.read(rightPanelTabProvider.notifier).state =
          RightPanelTab.connections;
      await pumpFrames(tester);

      expect(find.text('0 outgoing · 0 backlinks · 2 tags'), findsOneWidget);
    });
  });
}
