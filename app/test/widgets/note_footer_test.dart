// WI #253 (A5): the Note footer on every note. Rows decide what shows (a
// backfilled note has rows and no footer text until its next footer write, L10);
// split only keeps footer text out of the editable text. Two aligned rows of
// pills under TOPICS and TAGS; the Tags row lists every non-system tag, body
// and footer alike (Connor, 2026-11-09).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/capture_gutter.dart';
import 'package:open_memex_app/src/widgets/editor/footer_chip_row.dart'
    show FooterPill;

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/note_footer_harness.dart';
import '../support/recording_tabs.dart';
import '../support/tags_seed.dart';

const _chips = {pricingTopicId: 'Pricing', memexTopicId: 'Open Memex'};
const _chipTitles = ['Pricing', 'Open Memex'];
const _tags = ['memex', 'pricing'];

final String _body = footerBody(footerPerson, chips: _chipTitles, tags: _tags);

/// A note with both rows and its footer text.
FooterVault _full() =>
    seedFooterVault(body: _body, footerTags: _tags, chips: _chips);

/// Every piece of the footer's text is out of the note's editable text.
void _expectFooterNotEditable(SegmentedEditorRobot r) {
  for (final text in r.allSegments.map((s) => s.text)) {
    expect(text, isNot(contains(topicsMarker)));
    expect(text, isNot(contains('~about]]')));
    expect(text, isNot(contains('#memex')));
  }
}

void main() {
  group('the footer on a non-daily note', () {
    testWidgets(
      'a non-daily note with footer content shows the footer and its marker and footer lines are not editable text',
      (tester) async {
        final r = await launchFooterNote(tester, _full());

        expect(footerRow, findsOneWidget);
        expect(footerChip(pricingTopicId), findsOneWidget);
        expect(footerTag('memex'), findsOneWidget);
        expect(r.segmentText(0), footerPerson);
        expect(r.allTextSegments, findsOneWidget);
        _expectFooterNotEditable(r);
      },
    );

    testWidgets(
      'a backfilled note with tag rows and no marker shows the footer',
      (tester) async {
        final r = await launchFooterNote(
          tester,
          seedFooterVault(body: 'No footer text yet\n', footerTags: ['memex']),
        );

        expect(footerTag('memex'), findsOneWidget);
        expect(r.segmentText(0), 'No footer text yet\n');
      },
    );

    testWidgets(
      'a backfilled note with chip rows and no marker shows the footer',
      (tester) async {
        final r = await launchFooterNote(
          tester,
          seedFooterVault(body: 'No footer text yet\n', chips: _chips),
        );

        expect(footerChip(memexTopicId), findsOneWidget);
        expect(r.segmentText(0), 'No footer text yet\n');
      },
    );

    testWidgets(
      'a marker with no rows behind it shows no footer and stays out of the text',
      (tester) async {
        final r = await launchFooterNote(
          tester,
          seedFooterVault(body: footerBody(footerPerson, tags: ['stale'])),
        );

        expect(footerRow, findsNothing);
        expect(r.segmentText(0), footerPerson);
      },
    );

    testWidgets('a non-daily note with a footer has no capture gutter', (
      tester,
    ) async {
      final r = await launchFooterNote(tester, _full());

      expect(footerRow, findsOneWidget);
      expect(find.byType(CaptureGutter), findsNothing);
      expect(r.textSegment(0), findsOneWidget);
    });

    testWidgets(
      'a card above the footer stays a card and the footer comes after the last text',
      (tester) async {
        const card = '![[2026-09-05#^b7k2m9]]\n';
        final r = await launchFooterNote(
          tester,
          seedFooterVault(
            body: footerBody('Intro\n${card}Outro\n', tags: ['memex']),
            footerTags: ['memex'],
          ),
        );

        expect(r.allCards, findsOneWidget);
        expect(r.segmentText(0), 'Intro\n');
        expect(r.segmentText(2), 'Outro\n');
        expect(
          tester.getTopLeft(footerRow).dy,
          greaterThan(tester.getBottomLeft(r.textSegment(2)).dy - 1),
        );
      },
    );

    testWidgets('opening a note with a footer writes nothing', (tester) async {
      final r = await launchFooterNote(tester, _full());

      await r.waitForSave();

      expect(r.updates, isEmpty);
      expect(footerRow, findsOneWidget);
    });

    testWidgets(
      'a non-daily note with no footer shows one plain text segment',
      (tester) async {
        final r = await launchFooterNote(tester, seedFooterVault());

        expect(footerRow, findsNothing);
        expect(r.allTextSegments, findsOneWidget);
        expect(r.segmentText(0), footerPerson);
      },
    );

    testWidgets('opening another note shows that note footer', (tester) async {
      final vault = _full();
      seedFooterNote(
        vault.db,
        id: otherNoteId,
        title: 'Other',
        footerTags: ['other-tag'],
      );
      final r = await launchFooterNote(tester, vault);
      expect(footerTag('memex'), findsOneWidget);

      await r.open(otherNoteId);

      expect(footerTag('other-tag'), findsOneWidget);
      expect(footerTag('memex'), findsNothing);
      expect(footerChip(pricingTopicId), findsNothing);
    });
  });

  group('which rows show', () {
    testWidgets('a note with neither row shows no footer', (tester) async {
      final vault = seedFooterVault();
      vault.db.seedDailyNote('2026-09-05', id: 'daily-empty');
      final r = await launchFooterNote(tester, vault, noteId: 'daily-empty');

      expect(r.textSegment(0), findsOneWidget);
      expect(footerRow, findsNothing);
      expect(find.text('TOPICS'), findsNothing);
      expect(find.text('TAGS'), findsNothing);
    });

    testWidgets('a note with only system tags shows no footer', (tester) async {
      final vault = seedFooterVault();
      seedFooterNote(
        vault.db,
        id: 'daily-system',
        title: '2026-09-06',
        role: 'daily',
        systemTags: ['inbox', 'agent-authored'],
      );
      final r = await launchFooterNote(tester, vault, noteId: 'daily-system');

      expect(r.textSegment(0), findsOneWidget);
      expect(footerRow, findsNothing);
    });

    testWidgets('a note with only topics shows only the Topics row', (
      tester,
    ) async {
      await launchFooterNote(tester, seedFooterVault(chips: _chips));

      expect(footerLabel('TOPICS'), findsOneWidget);
      expect(footerLabel('TAGS'), findsNothing);
    });

    testWidgets('a note with only tags shows only the Tags row', (
      tester,
    ) async {
      await launchFooterNote(tester, seedFooterVault(footerTags: _tags));

      expect(footerLabel('TAGS'), findsOneWidget);
      expect(footerLabel('TOPICS'), findsNothing);
    });

    testWidgets(
      'the Tags row shows body and footer tags alphabetically and never system tags',
      (tester) async {
        await launchFooterNote(
          tester,
          seedFooterVault(
            footerTags: ['pricing'],
            bodyTags: ['work', 'alpha'],
            systemTags: ['inbox', 'agent-authored'],
          ),
        );

        for (final tag in ['alpha', 'pricing', 'work']) {
          expect(footerTagName(tag), findsOneWidget);
        }
        final xs = [
          for (final tag in ['alpha', 'pricing', 'work'])
            tester.getTopLeft(footerTag(tag)).dx,
        ];
        expect(xs, orderedEquals([...xs]..sort()));
        expect(footerTag('inbox'), findsNothing);
        expect(footerTag('agent-authored'), findsNothing);
        expect(
          find.descendant(of: footerRow, matching: find.text('#inbox')),
          findsNothing,
        );
      },
    );

    testWidgets('a note with only body tags shows the Tags row', (
      tester,
    ) async {
      await launchFooterNote(tester, seedFooterVault(bodyTags: ['work']));

      expect(footerLabel('TAGS'), findsOneWidget);
      expect(footerTag('work'), findsOneWidget);
    });

    testWidgets('a daily note shows both rows like any other note', (
      tester,
    ) async {
      final vault = seedFooterVault();
      seedFooterNote(
        vault.db,
        id: 'daily-both',
        title: '2026-09-07',
        role: 'daily',
        body: footerBody(
          'Day\n',
          chips: const ['Pricing'],
          tags: const ['memex'],
        ),
        footerTags: ['memex'],
        chips: const {pricingTopicId: 'Pricing'},
      );
      final r = await launchFooterNote(tester, vault, noteId: 'daily-both');

      expect(footerLabel('TOPICS'), findsOneWidget);
      expect(footerLabel('TAGS'), findsOneWidget);
      expect(footerTag('memex'), findsOneWidget);
      expect(r.segmentText(0), 'Day\n');
    });

    testWidgets('the virtual Today note shows no footer', (tester) async {
      final vault = seedFooterVault();
      final h = await pumpWorkspace(tester, db: vault.db, cli: vault.cli);
      final r = SegmentedEditorRobot(tester, h);
      await pumpFrames(tester);

      expect(r.activeTab, isA<VirtualTodayTab>());
      expect(r.textSegment(0), findsOneWidget);
      expect(footerRow, findsNothing);
    });

    testWidgets(
      'a guide note with stray rows shows no footer while a topic note with the same rows does',
      (tester) async {
        final vault = _full();
        seedFooterNote(
          vault.db,
          id: 'note-guide',
          title: 'Vault Guide',
          role: 'guide',
          footerTags: ['memex'],
          chips: const {pricingTopicId: 'Pricing'},
        );
        final r = await launchFooterNote(tester, vault);
        expect(footerRow, findsOneWidget, reason: 'the topic note');

        await r.open('note-guide');

        expect(r.textSegment(0), findsOneWidget);
        expect(footerRow, findsNothing);
        expect(footerTag('memex'), findsNothing);
        expect(footerChip(pricingTopicId), findsNothing);
      },
    );
  });

  group('rows refresh from the vault', () {
    testWidgets(
      'a footer tag added by a server write shows without reopening',
      (tester) async {
        final r = await launchFooterNote(
          tester,
          seedFooterVault(footerTags: ['memex']),
        );
        expect(footerTag('later'), findsNothing);

        r.h.db.seedTag(footerNoteId, 'later', origin: 'agent');
        r.h.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(footerTag('later'), findsOneWidget);
        expect(footerTag('memex'), findsOneWidget);
      },
    );

    testWidgets(
      'a tag the person writes in the body stays in the footer and loses its x',
      (tester) async {
        final r = await launchFooterNote(
          tester,
          seedFooterVault(footerTags: ['memex', 'pricing']),
        );
        expect(footerTag('pricing'), findsOneWidget);

        r.h.db.db.execute(
          "UPDATE tags SET origin = 'body' WHERE note_id = ? AND tag = ?",
          [footerNoteId, 'pricing'],
        );
        r.h.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(footerTag('pricing'), findsOneWidget);
        expect(footerRemove('pricing'), findsNothing);
        expect(footerRemove('memex'), findsOneWidget);
      },
    );
  });

  group('saves keep the footer', () {
    testWidgets(
      'a save on a non-daily note with a footer sends the footer unchanged',
      (tester) async {
        final r = await launchFooterNote(tester, _full());

        await r.typeInSegment(0, 'Annual plan final\n');
        await r.waitForSave();

        expect(
          r.updates.single.stdinBody,
          footerBody('Annual plan final\n', chips: _chipTitles, tags: _tags),
        );
        expect(r.h.read(editorControllerProvider).status, SaveStatus.clean);
        expect(r.segmentText(0), 'Annual plan final\n');
        expect(footerTag('memex'), findsOneWidget);
      },
    );

    testWidgets(
      'a save that drops the last newline keeps the marker on its own line',
      (tester) async {
        final r = await launchFooterNote(tester, _full());

        await r.typeInSegment(0, 'No newline');
        await r.waitForSave();

        expect(
          r.updates.single.stdinBody,
          footerBody('No newline\n', chips: _chipTitles, tags: _tags),
        );
        _expectFooterNotEditable(r);
      },
    );

    testWidgets('a save keeps a card and the footer in place', (tester) async {
      const card = '![[2026-09-05#^b7k2m9]]\n';
      final r = await launchFooterNote(
        tester,
        seedFooterVault(
          body: footerBody('Intro\n${card}Outro\n', tags: ['memex']),
          footerTags: ['memex'],
        ),
      );

      await r.typeInSegment(2, 'Outro edited\n');
      await r.waitForSave();

      expect(
        r.updates.single.stdinBody,
        footerBody('Intro\n${card}Outro edited\n', tags: ['memex']),
      );
    });

    testWidgets(
      'a save on a backfilled note writes no footer text of its own',
      (tester) async {
        final r = await launchFooterNote(
          tester,
          seedFooterVault(body: 'No footer yet\n', footerTags: ['memex']),
        );

        await r.typeInSegment(0, 'Edited\n');
        await r.waitForSave();

        expect(r.updates.single.stdinBody, 'Edited\n');
        expect(footerTag('memex'), findsOneWidget);
      },
    );

    testWidgets(
      'a server write that adds the first footer item keeps the text segment and the caret',
      (tester) async {
        final r = await launchFooterNote(tester, seedFooterVault());
        await r.focusSegment(0, offset: 3);
        final handle = r.segment(0);

        r.h.db.seedTag(footerNoteId, 'memex', origin: 'agent');
        r.h.db.db.execute(
          'UPDATE notes SET content_md = ?, version = 5 WHERE id = ?',
          [
            footerBody(footerPerson, tags: ['memex']),
            footerNoteId,
          ],
        );
        r.h
            .read(editorControllerProvider.notifier)
            .loadNote(r.h.db.getNote(footerNoteId));
        r.h.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(footerTag('memex'), findsOneWidget);
        expect(r.segment(0), same(handle));
        expect(r.segmentText(0), footerPerson);
        expect(r.segmentSelection(0), const TextSelection.collapsed(offset: 3));
      },
    );
  });

  group('Source mode', () {
    testWidgets(
      'source mode shows the saved markdown and keeps the footer on save',
      (tester) async {
        final r = await launchFooterNote(tester, _full());

        await r.toggleSource();
        expect(r.sourceText, _body);

        await tester.enterText(
          r.sourceBody,
          'Edited\n${_body.substring(footerPerson.length)}',
        );
        await r.waitForSave();
        expect(
          r.updates.single.stdinBody,
          footerBody('Edited\n', chips: _chipTitles, tags: _tags),
        );

        await r.toggleSource();
        expect(footerTag('memex'), findsOneWidget);
        expect(r.segmentText(0), 'Edited\n');
        _expectFooterNotEditable(r);
      },
    );

    testWidgets('source mode shows no footer rows beside the markdown', (
      tester,
    ) async {
      final r = await launchFooterNote(tester, _full());
      expect(footerRow, findsOneWidget);

      await r.toggleSource();

      expect(footerRow, findsNothing);
      expect(r.sourceText, contains(topicsMarker));
    });
  });

  group('clicks', () {
    testWidgets('clicking a footer tag calls revealTag', (tester) async {
      final r = await launchFooterNote(
        tester,
        seedFooterVault(footerTags: _tags),
      );
      expectNotRevealed(r.h);

      await tester.tap(footerTag('pricing'));
      await pumpFrames(tester);

      expectRevealed(r.h, 'pricing');
      expect(r.h.cli.callsFor('tag rm'), isEmpty);
    });

    testWidgets('clicking a footer topic records its follow target', (
      tester,
    ) async {
      final tabs = TabsRecorder();
      await launchFooterNote(tester, _full(), overrides: [tabs.override]);

      await tester.tap(footerChip(memexTopicId));
      await pumpFrames(tester);

      expect(tabs.followed, [const NoteTab(memexTopicId)]);
    });
  });

  group('the look', () {
    testWidgets(
      'topics and tags are pills: fg1 on surface3 with a line2 border, fg2 labels',
      (tester) async {
        await launchFooterNote(tester, _full());

        expect(
          find.descendant(of: footerRow, matching: find.byType(FooterPill)),
          findsNWidgets(4),
        );
        expect(colorOf(tester, footerLabel('TOPICS')), OmColors.fg2);
        expect(colorOf(tester, footerLabel('TAGS')), OmColors.fg2);
        final pricing = find.descendant(
          of: footerChip(pricingTopicId),
          matching: find.text('Pricing'),
        );
        expect(colorOf(tester, pricing), OmColors.fg1);
        expect(colorOf(tester, footerTagName('memex')), OmColors.fg1);
        for (final item in [footerChip(pricingTopicId), footerTag('memex')]) {
          expect(footerPillBorder(tester, item), OmColors.line2);
          final box = tester.widget<Container>(
            find.descendant(of: item, matching: find.byType(Container)).first,
          );
          final deco = box.decoration! as BoxDecoration;
          expect(deco.color, OmColors.surface3);
          expect(deco.borderRadius, BorderRadius.circular(4));
        }
      },
    );

    testWidgets('hovering a topic pill turns it accentSoft', (tester) async {
      await launchFooterNote(tester, _full());
      final mouse = await addMouse(tester);
      final title = find.descendant(
        of: footerChip(pricingTopicId),
        matching: find.text('Pricing'),
      );

      await hover(tester, mouse, footerChip(pricingTopicId));

      expect(colorOf(tester, title), OmColors.accentSoft);
      expect(
        footerPillBorder(tester, footerChip(pricingTopicId)),
        OmColors.accentSoft,
      );
      expect(
        footerPillBorder(tester, footerChip(memexTopicId)),
        OmColors.line2,
      );
    });

    testWidgets('both rows start their items 64 px after the labels', (
      tester,
    ) async {
      await launchFooterNote(tester, _full());

      final labels = tester.getTopLeft(footerLabel('TOPICS')).dx;
      expect(tester.getTopLeft(footerLabel('TAGS')).dx, labels);
      expect(tester.getTopLeft(footerChip(pricingTopicId)).dx, labels + 64);
      expect(tester.getTopLeft(footerTag('memex')).dx, labels + 64);
    });

    testWidgets('pills in a row sit 6 px apart', (tester) async {
      await launchFooterNote(tester, _full());

      expect(
        tester.getTopLeft(footerChip(memexTopicId)).dx -
            tester.getTopRight(footerChip(pricingTopicId)).dx,
        6,
      );
      expect(
        tester.getTopLeft(footerTag('pricing')).dx -
            tester.getTopRight(footerTag('memex')).dx,
        6,
      );
    });

    testWidgets('the pills are 22 high with 6 between rows at text scale 1', (
      tester,
    ) async {
      final vault = _full();

      await pumpBareNote(tester, vault.db, width: 1400, textScale: 1);

      expect(tester.takeException(), isNull);
      expect(tester.getSize(footerChip(pricingTopicId)).height, 22);
      expect(tester.getSize(footerTag('memex')).height, 22);
      expect(
        tester.getTopLeft(footerTag('memex')).dy -
            tester.getTopLeft(footerChip(pricingTopicId)).dy,
        28,
      );
    });

    testWidgets('the footer has a 1 px line1 rule above its rows', (
      tester,
    ) async {
      await launchFooterNote(tester, _full());

      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: footerRow,
              matching: find.byType(DecoratedBox),
              matchRoot: true,
            )
            .first,
      );
      final border = (box.decoration as BoxDecoration).border! as Border;
      expect(border.top.color, OmColors.line1);
      expect(border.top.width, 1);
    });
  });

  group('wrapping', () {
    testWidgets(
      'a long list of tags wraps in the footer without overflow at the narrowest width and large text',
      (tester) async {
        final tags = [
          for (var i = 0; i < 14; i++) 'footer-tag-number-$i',
          'a-very-long-footer-tag-${'x' * 120}',
        ];
        final vault = seedFooterVault(footerTags: tags, chips: _chips);

        await pumpBareNote(tester, vault.db, width: 320, textScale: 2);

        expect(tester.takeException(), isNull);
        for (final tag in tags) {
          expect(footerTag(tag), findsOneWidget);
          expect(footerRemove(tag), findsOneWidget);
        }
        final rows = {
          for (final tag in tags) tester.getTopLeft(footerTag(tag)).dy,
        };
        expect(rows.length, greaterThan(1));
        // Wrapped runs stay in the column right of the labels.
        final column = tester.getTopLeft(footerLabel('TAGS')).dx + 64;
        final starts = [
          for (final tag in tags) tester.getTopLeft(footerTag(tag)).dx,
        ];
        expect(starts.reduce(math.min), column);
        expect(starts.where((x) => x == column).length, greaterThan(1));
      },
    );

    testWidgets(
      'a long topic title wraps without overflow at the narrowest width and large text',
      (tester) async {
        final vault = seedFooterVault(
          chips: {
            'topic-long': 'A very long topic title ${'y' * 120}',
            pricingTopicId: 'Pricing',
          },
        );

        await pumpBareNote(tester, vault.db, width: 320, textScale: 2);

        expect(tester.takeException(), isNull);
        expect(footerChip('topic-long'), findsOneWidget);
        expect(footerChip(pricingTopicId), findsOneWidget);
      },
    );
  });
}
