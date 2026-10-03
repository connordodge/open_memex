// WI #29 (A11): the Reviewed chip in the note header. State, label and colour
// come from #21 (`reviewStateProvider`, `ReviewState.label`,
// `reviewStateColor`); the chip is read-only, hover shows the review time and
// a tap opens the right panel's Activity tab.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/review_state_colors.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';
import '../support/review_fakes.dart';

const _noteId = 'daily-2026-09-05';

/// 14:32 local on 5 Sep 2026, in unix ms.
final _reviewedAtMs = DateTime(2026, 9, 5, 14, 32).millisecondsSinceEpoch;

final _chip = find.byKey(const Key('review-chip'));

/// The label text inside the chip.
Finder _label(String text) =>
    find.descendant(of: _chip, matching: find.text(text));

Color? _labelColor(WidgetTester tester, String text) =>
    tester.widget<Text>(_label(text)).style?.color;

FakeVaultDb _dbWithDaily({
  int contentVersion = 4,
  int? reviewedContentVersion,
  int? reviewedAt,
  bool withReviewRow = true,
}) {
  final db = FakeVaultDb.v5();
  db.seedDailyNote('2026-09-05', id: _noteId);
  if (withReviewRow) {
    db.seedDayReview(
      _noteId,
      contentVersion: contentVersion,
      reviewedContentVersion: reviewedContentVersion,
      reviewedAt: reviewedAt,
    );
  }
  return db;
}

Future<WorkspaceHarness> _open(
  WidgetTester tester,
  FakeVaultDb db, {
  String noteId = _noteId,
}) async {
  final h = await pumpWorkspace(tester, db: db);
  await openNoteTab(tester, h, noteId);
  return h;
}

/// Move a mouse pointer onto [target] so hover handlers fire.
Future<void> _hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await tester.pump();
  await mouse.moveTo(tester.getCenter(target));
  await pumpFrames(tester);
}

void main() {
  group('ReviewChip label and colour (AC1, AC2, AC3)', () {
    testWidgets(
      'a daily note with no review shows the Unreviewed chip in the grey token colour',
      (tester) async {
        final db = _dbWithDaily(withReviewRow: false);
        await _open(tester, db);

        expect(_chip, findsOneWidget);
        expect(_label('Unreviewed'), findsOneWidget);
        expect(_labelColor(tester, 'Unreviewed'), OmColors.fg3);
        expect(
          _labelColor(tester, 'Unreviewed'),
          reviewStateColor(ReviewState.unreviewed),
        );
      },
    );

    testWidgets(
      'a daily note whose review row has no reviewed content version shows Unreviewed',
      (tester) async {
        final db = _dbWithDaily(
          contentVersion: 3,
          reviewedContentVersion: null,
        );
        await _open(tester, db);

        expect(_label('Unreviewed'), findsOneWidget);
        expect(_labelColor(tester, 'Unreviewed'), OmColors.fg3);
      },
    );

    testWidgets(
      'a daily note whose content version equals its reviewed content version shows Reviewed in the green token colour',
      (tester) async {
        final db = _dbWithDaily(
          contentVersion: 4,
          reviewedContentVersion: 4,
          reviewedAt: _reviewedAtMs,
        );
        await _open(tester, db);

        expect(_label('Reviewed'), findsOneWidget);
        expect(_label('Unreviewed'), findsNothing);
        expect(_label('Changed since review'), findsNothing);
        // The one green of the review states, shared with the Days dot.
        expect(
          _labelColor(tester, 'Reviewed'),
          reviewStateColor(ReviewState.reviewed),
        );
        expect(_labelColor(tester, 'Reviewed'), isNot(OmColors.fg3));
        expect(_labelColor(tester, 'Reviewed'), isNot(OmColors.warn));
      },
    );

    testWidgets(
      'a daily note whose content version is newer than its reviewed content version shows Changed since review in the amber token colour',
      (tester) async {
        final db = _dbWithDaily(
          contentVersion: 5,
          reviewedContentVersion: 4,
          reviewedAt: _reviewedAtMs,
        );
        await _open(tester, db);

        expect(_label('Changed since review'), findsOneWidget);
        expect(_label('Reviewed'), findsNothing);
        expect(_labelColor(tester, 'Changed since review'), OmColors.warn);
      },
    );

    testWidgets(
      'the chip follows the open note when another daily note with a different state is opened',
      (tester) async {
        final db = _dbWithDaily(
          contentVersion: 4,
          reviewedContentVersion: 4,
          reviewedAt: _reviewedAtMs,
        );
        db.seedDailyNote('2026-09-06', id: 'daily-2026-09-06');
        final h = await _open(tester, db);
        expect(_label('Reviewed'), findsOneWidget);

        await openNoteTab(tester, h, 'daily-2026-09-06');

        expect(_label('Unreviewed'), findsOneWidget);
        expect(_label('Reviewed'), findsNothing);
      },
    );
  });

  group('ReviewChip hover (AC4)', () {
    testWidgets(
      'hovering a Reviewed chip reviewed at 14:32 on 5 Sep 2026 shows Reviewed by agent at 5 Sep 2026, 14:32',
      (tester) async {
        final db = _dbWithDaily(
          contentVersion: 4,
          reviewedContentVersion: 4,
          reviewedAt: _reviewedAtMs,
        );
        await _open(tester, db);
        expect(
          find.text('Reviewed by agent at 5 Sep 2026, 14:32'),
          findsNothing,
        );

        await _hover(tester, _chip);

        expect(
          find.text('Reviewed by agent at 5 Sep 2026, 14:32'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'hovering a Changed since review chip shows the time of the last review',
      (tester) async {
        final db = _dbWithDaily(
          contentVersion: 5,
          reviewedContentVersion: 4,
          reviewedAt: DateTime(2026, 9, 3, 7, 5).millisecondsSinceEpoch,
        );
        await _open(tester, db);

        await _hover(tester, _chip);

        expect(
          find.text('Reviewed by agent at 3 Sep 2026, 07:05'),
          findsOneWidget,
        );
      },
    );

    testWidgets('hovering an Unreviewed chip shows no review time', (
      tester,
    ) async {
      final db = _dbWithDaily(withReviewRow: false);
      await _open(tester, db);

      await _hover(tester, _chip);

      expect(find.textContaining('Reviewed by agent'), findsNothing);
    });
  });

  group('ReviewChip only on daily notes (AC5)', () {
    testWidgets(
      'a topic note shows no reviewed chip while a daily note in the same vault does',
      (tester) async {
        final db = _dbWithDaily(withReviewRow: false);
        db.seedTopicNote('topic-1', 'Gardening');
        final h = await _open(tester, db);
        expect(_chip, findsOneWidget);

        await openNoteTab(tester, h, 'topic-1');

        expect(find.byKey(const Key('note-header')), findsOneWidget);
        expect(_chip, findsNothing);
        expect(find.text('Unreviewed'), findsNothing);
      },
    );

    testWidgets(
      'a role-less note shows no reviewed chip while a daily note in the same vault does',
      (tester) async {
        final db = _dbWithDaily(withReviewRow: false);
        db.seedNote(id: 'plain-1', title: 'Plain note');
        final h = await _open(tester, db);
        expect(_chip, findsOneWidget);

        await openNoteTab(tester, h, 'plain-1');

        expect(find.byKey(const Key('note-header')), findsOneWidget);
        expect(_chip, findsNothing);
        expect(find.text('Unreviewed'), findsNothing);
      },
    );

    testWidgets(
      'a daily note on a V4 vault shows no reviewed chip until the vault migrates to V5',
      (tester) async {
        final db = FakeVaultDb.v4();
        db.seedNote(id: _noteId, title: '2026-09-05', role: 'daily');
        final h = await _open(tester, db);
        expect(find.byKey(const Key('note-header')), findsOneWidget);
        expect(_chip, findsNothing);

        db.migrateToV5();
        h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(_label('Unreviewed'), findsOneWidget);
      },
    );
  });

  group('ReviewChip tap (AC6)', () {
    testWidgets(
      'tapping the chip opens a closed right panel with the Activity tab active',
      (tester) async {
        final db = _dbWithDaily(
          contentVersion: 4,
          reviewedContentVersion: 4,
          reviewedAt: _reviewedAtMs,
        );
        final h = await _open(tester, db);
        h.container.read(rightPanelOpenProvider.notifier).state = false;
        await pumpFrames(tester);
        expect(find.byType(RightPanel), findsNothing);

        await tester.tap(_chip);
        await pumpFrames(tester);

        expect(h.read(rightPanelOpenProvider), isTrue);
        expect(h.read(rightPanelTabProvider), RightPanelTab.activity);
        expect(find.byType(RightPanel), findsOneWidget);
        expect(find.text('AGENT ACTIVITY · THIS NOTE'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping the chip switches an open right panel from Connections to the Activity tab',
      (tester) async {
        final db = _dbWithDaily(withReviewRow: false);
        final h = await _open(tester, db);
        expect(h.read(rightPanelOpenProvider), isTrue);
        expect(h.read(rightPanelTabProvider), RightPanelTab.connections);

        await tester.tap(_chip);
        await pumpFrames(tester);

        expect(h.read(rightPanelOpenProvider), isTrue);
        expect(h.read(rightPanelTabProvider), RightPanelTab.activity);
        expect(find.text('AGENT ACTIVITY · THIS NOTE'), findsOneWidget);
        expect(find.byKey(const Key('backlinks-panel')), findsNothing);
      },
    );

    testWidgets('tapping the chip does not change the review state', (
      tester,
    ) async {
      final db = _dbWithDaily(
        contentVersion: 5,
        reviewedContentVersion: 4,
        reviewedAt: _reviewedAtMs,
      );
      await _open(tester, db);

      await tester.tap(_chip);
      await pumpFrames(tester);

      expect(_label('Changed since review'), findsOneWidget);
      final row = db.db.select(
        'SELECT content_version, reviewed_content_version FROM day_reviews '
        'WHERE note_id = ?',
        [_noteId],
      );
      expect(row.single['content_version'], 5);
      expect(row.single['reviewed_content_version'], 4);
    });
  });
}
