// WI #253 (A5): the meta rail and the right panel's tag count. The whole rail
// is fg2 with no clock icon. A note's tags are listed only in the Note footer,
// not the rail (Connor, 2026-11-09).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/editor/segments.dart' show topicsMarker;
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/note_header.dart'
    show noteWordCount;
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/app_harness.dart';
import '../support/note_footer_harness.dart';

Finder _inHeader(Finder what) =>
    find.descendant(of: noteHeader, matching: what);

Finder get _separators => _inHeader(find.text('·'));

void main() {
  group('the rail lists no tags', () {
    testWidgets(
      'body, footer and system tags stay out of the rail; the footer lists the non-system ones',
      (tester) async {
        final r = await launchFooterNote(
          tester,
          seedFooterVault(
            footerTags: ['memex', 'pricing'],
            bodyTags: ['work'],
            systemTags: ['inbox', 'agent-authored'],
          ),
        );

        expect(_inHeader(find.textContaining('#')), findsNothing);
        expect(_separators, findsOneWidget);
        for (final tag in ['memex', 'pricing', 'work']) {
          expect(footerTag(tag), findsOneWidget);
        }
        expect(footerTag('inbox'), findsNothing);
        expect(r.h.db.getNote(footerNoteId)!.tags, contains('inbox'));
      },
    );

    testWidgets('the whole rail is fg2 with no clock icon', (tester) async {
      await launchFooterNote(
        tester,
        seedFooterVault(footerTags: ['memex'], bodyTags: ['work']),
      );

      expect(_inHeader(find.byIcon(LucideIcons.clock)), findsNothing);
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
  });

  group('rail word count', () {
    const person = 'one two three four five\n';

    Finder words(String text) => _inHeader(find.text(text));

    testWidgets('a non-daily note counts only its person section', (
      tester,
    ) async {
      await launchFooterNote(
        tester,
        seedFooterVault(
          body: footerBody(person, chips: ['Pricing'], tags: ['alpha', 'beta']),
          footerTags: ['alpha', 'beta'],
          chips: {pricingTopicId: 'Pricing'},
        ),
      );

      expect(words('5 words'), findsOneWidget);
      expect(_inHeader(find.textContaining(' words')), findsOneWidget);
    });

    testWidgets(
      'a backfilled note with rows and no footer text counts it all',
      (tester) async {
        await launchFooterNote(
          tester,
          seedFooterVault(body: person, footerTags: ['alpha']),
        );

        expect(words('5 words'), findsOneWidget);
      },
    );

    testWidgets('a non-daily note keeps a marker inside a fence as text', (
      tester,
    ) async {
      final body = 'alpha beta\n```\n$topicsMarker\ngamma delta\n```\n';
      await launchFooterNote(tester, seedFooterVault(body: body));

      expect(words('${noteWordCount(body)} words'), findsOneWidget);
      expect(noteWordCount(body), greaterThan(3));
    });

    testWidgets('a daily note counts only the text above its marker', (
      tester,
    ) async {
      await launchFooterNote(
        tester,
        seedFooterVault(
          body: footerBody(person, chips: ['Pricing'], tags: ['alpha']),
          role: 'daily',
          footerTags: ['alpha'],
          chips: {pricingTopicId: 'Pricing'},
        ),
      );

      expect(words('5 words'), findsOneWidget);
    });

    testWidgets('a daily note splits at the first marker even inside a fence', (
      tester,
    ) async {
      final body = 'alpha beta\n```\n$topicsMarker\ngamma delta\n```\n';
      await launchFooterNote(
        tester,
        seedFooterVault(body: body, role: 'daily'),
      );

      // The marker line itself (three words) is no text; the stray lines below
      // it join the person section.
      expect(words('${noteWordCount(body) - 3} words'), findsOneWidget);
      expect(words('${noteWordCount(body)} words'), findsNothing);
    });

    testWidgets('a guide note counts its whole body, marker line included', (
      tester,
    ) async {
      final body = footerBody(person, chips: ['Pricing'], tags: ['alpha']);
      await launchFooterNote(
        tester,
        seedFooterVault(body: body, role: 'guide'),
      );

      expect(words('${noteWordCount(body)} words'), findsOneWidget);
      expect(noteWordCount(body), greaterThan(5));
    });
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
