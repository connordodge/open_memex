// WI #260 (F8), fix round r2: a fix keeps the day whose row was pressed, a
// failed rebase read is not a failed fix, and a Create that outlives the
// section still writes. Test names use no apostrophes.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/activity/filed_section.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/filed_section_fakes.dart';
import '../support/review_fakes.dart' show openNoteTab;

void main() {
  group('a failed rebase read after a worked fix', () {
    testWidgets(
      'is not a failed fix so the row comes back with no error and nothing uncaught',
      (tester) async {
        final f = await pumpF260(tester);
        f.feedback.gate('moveBlock');
        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260Tap(tester, f260Option(f260Sleep));
        await f260Tap(tester, f260Confirm);
        expect(f.moves, hasLength(1));

        // The write succeeds, then the daily note read of the rebase fails.
        f.notes.failAlways('getNote', StateError('read failed'));
        f.feedback.gates['moveBlock']!.single.complete();
        await pumpFrames(tester);
        f.notes.stopFailing('getNote');
        await pumpFrames(tester);

        expect(tester.takeException(), isNull);
        expect(f.moves, hasLength(1));
        expect(f260Error, findsNothing);
        expect(find.byKey(f260Row(f260Sleep, f260B1)), findsOneWidget);
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsNothing);
        final button = tester.widget<OmButton>(
          find.byKey(f260Move(f260Sleep, f260B1)),
        );
        expect(button.onPressed, isNotNull, reason: 'the row is enabled again');
      },
    );
  });

  group('a fix keeps the day whose row was pressed', () {
    testWidgets(
      'a note switch while Create runs still writes the pressed date',
      (tester) async {
        final f = await _pumpTwoDays(tester);

        f.notes.gate('addNote');
        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260TypeTopic(tester, 'Fresh Topic');
        await f260Tap(tester, f260Create);
        await f260Tap(tester, f260Confirm);

        await _switchToOtherDay(tester, f);

        f.notes.gates['addNote']!.single.complete();
        await pumpFrames(tester);

        expect(tester.takeException(), isNull);
        expect(f.moves, hasLength(1));
        expect(f.moves.single.args['date'], f260Date);
        expect(f.moves.single.args['date'], isNot('2026-11-04'));
      },
    );

    testWidgets(
      'a note switch while the Remove dialog is open still removes on the pressed date',
      (tester) async {
        final f = await _pumpTwoDays(tester);

        await f260Tap(tester, f260Remove(f260Loop, f260B1));
        await _switchToOtherDay(tester, f);
        await f260Tap(tester, f260Confirm);

        expect(f.removes, hasLength(1));
        expect(f.removes.single.args['date'], f260Date);
      },
    );

    testWidgets(
      'a note switch while the Move to dialog is open still moves on the pressed date',
      (tester) async {
        final f = await _pumpTwoDays(tester);

        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260Tap(tester, f260Option(f260Sleep));
        await _switchToOtherDay(tester, f);
        await f260Tap(tester, f260Confirm);

        expect(f.moves, hasLength(1));
        expect(f.moves.single.args['date'], f260Date);
      },
    );

    testWidgets(
      'a note switch while the File in dialog is open still files on the pressed date',
      (tester) async {
        final f = await _pumpTwoDays(tester);

        await f260Tap(tester, f260FileIn(f260N1));
        await f260Tap(tester, f260Option(f260Economy));
        await _switchToOtherDay(tester, f);
        await f260Tap(tester, f260Confirm);

        expect(f.files, hasLength(1));
        expect(f.files.single.args['date'], f260Date);
      },
    );
  });

  group('a Create that outlives the section', () {
    testWidgets(
      'writes the move for the pressed day and throws nothing when the section is gone',
      (tester) async {
        final f = await pumpF260(tester);
        f.notes.gate('addNote');
        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await f260TypeTopic(tester, 'Fresh Topic');
        await f260Tap(tester, f260Create);
        await f260Tap(tester, f260Confirm);

        f.h.container.read(rightPanelTabProvider.notifier).state =
            RightPanelTab.connections;
        await pumpFrames(tester);
        expect(find.byKey(f260Section), findsNothing);

        f.notes.gates['addNote']!.single.complete();
        await pumpFrames(tester);

        expect(tester.takeException(), isNull);
        expect(f.moves, hasLength(1));
        expect(f.moves.single.args['date'], f260Date);
      },
    );
  });
}

const _otherId = 'daily-2026-11-04';

/// The pressed day open with its section, the other day already visited (a
/// first visit shows the section loading), and the fake answering any day.
Future<F260> _pumpTwoDays(WidgetTester tester) async {
  final db = f260Db();
  db.seedDailyNote('2026-11-04', id: _otherId);
  final f = await pumpF260(tester, db: db);
  f.cli.on(
    'filing',
    (_) => FakeMemexCli.ok('${jsonEncode(f.server.filingJson())}\n'),
  );
  await openNoteTab(tester, f.h, _otherId);
  await pumpFrames(tester);
  await openNoteTab(tester, f.h, f260DailyId);
  await pumpFrames(tester);
  return f;
}

Future<void> _switchToOtherDay(WidgetTester tester, F260 f) async {
  await openNoteTab(tester, f.h, _otherId);
  await pumpFrames(tester);
  expect(
    tester.widget<FiledSection>(find.byType(FiledSection)).note.title,
    '2026-11-04',
    reason: 'the section shows the other day while the dialog is open',
  );
}
