// WI #29 (A11) robot journey (Spec TS4): typing turns the chip amber.
//
// FakeMemexCli's `update` handler (ReviewFakes.onUpdate) stands in for the
// server (D9): it writes the new body into FakeVaultDb and bumps
// `day_reviews.content_version` when the person section changes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/theme/colors.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/review_fakes.dart';

const _noteId = 'daily-2026-09-05';

final _chip = find.byKey(const Key('review-chip'));

Finder _label(String text) =>
    find.descendant(of: _chip, matching: find.text(text));

/// The body field: the one TextField inside the source surface that is not
/// the title field.
Finder _bodyField() => find.descendant(
  of: find.byKey(const Key('editor-source-surface')),
  matching: find.byWidgetPredicate(
    (w) => w is TextField && w.key != const Key('editor-title'),
  ),
);

({FakeVaultDb db, FakeMemexCli cli}) _reviewedDaily() {
  final db = FakeVaultDb.v5();
  db.seedDailyNote('2026-09-05', id: _noteId, version: 3);
  db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
    assembleDailyBody('Morning notes\n', const []),
    _noteId,
  ]);
  db.seedDayReview(
    _noteId,
    contentVersion: 4,
    reviewedContentVersion: 4,
    reviewedAt: DateTime(2026, 9, 5, 14, 32).millisecondsSinceEpoch,
  );
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..on('update', ReviewFakes.onUpdate(db));
  return (db: db, cli: cli);
}

/// Switch the body to the Source surface: the segmented view is the
/// default since WI #27.
Future<void> _showSource(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('editor-source-toggle')));
  await pumpFrames(tester);
}

int _contentVersion(FakeVaultDb db) =>
    (db.db.select('SELECT content_version FROM day_reviews WHERE note_id = ?', [
              _noteId,
            ]).single['content_version']
            as num)
        .toInt();

void main() {
  group('Reviewed chip journey (AC10)', () {
    testWidgets(
      'typing in the person section of a Reviewed daily note and saving turns the chip to Changed since review',
      (tester) async {
        final fixture = _reviewedDaily();
        final h = await pumpWorkspace(tester, db: fixture.db, cli: fixture.cli);
        await openNoteTab(tester, h, _noteId);
        await _showSource(tester);
        expect(_label('Reviewed'), findsOneWidget);
        expect(_label('Changed since review'), findsNothing);

        await tester.enterText(
          _bodyField(),
          assembleDailyBody('Morning notes\nplus typed text\n', const []),
        );
        // The save is debounced by 500 ms; let it fire and complete.
        await tester.pump(const Duration(milliseconds: 600));
        await pumpFrames(tester);

        expect(fixture.cli.callsFor('update'), hasLength(1));
        expect(_contentVersion(fixture.db), 5);
        expect(_label('Changed since review'), findsOneWidget);
        expect(_label('Reviewed'), findsNothing);
        final text = tester.widget<Text>(_label('Changed since review'));
        expect(text.style?.color, OmColors.warn);
      },
    );

    testWidgets(
      'the chip stays Reviewed while the typed save has not completed yet',
      (tester) async {
        final fixture = _reviewedDaily();
        final h = await pumpWorkspace(tester, db: fixture.db, cli: fixture.cli);
        await openNoteTab(tester, h, _noteId);
        await _showSource(tester);

        await tester.enterText(
          _bodyField(),
          assembleDailyBody('Morning notes\nplus typed text\n', const []),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // Debounce not elapsed: nothing saved, the review state is unchanged.
        expect(fixture.cli.callsFor('update'), isEmpty);
        expect(_label('Reviewed'), findsOneWidget);

        // Let the pending debounce timer fire so the test ends clean.
        await tester.pump(const Duration(milliseconds: 600));
        await pumpFrames(tester);
        expect(_label('Changed since review'), findsOneWidget);
      },
    );
  });
}
