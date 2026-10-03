// WI #22 (A5): the fixed date header replaces the editable title for
// `role: daily` notes, with a `Today` badge only on today's date (Req 4, 48,
// 49; C5 header format).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/editor/daily_date_header.dart';
import 'package:open_memex_app/src/widgets/editor/note_header.dart';

import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';

Note _note({required String title, String frontmatter = '{"role":"daily"}'}) =>
    Note(
      id: '01J9TTTTTTTTTTTTTTTTTTTTTT',
      title: title,
      contentMd: 'Morning pages\n',
      frontmatter: frontmatter,
      version: 3,
      createdAt: 1759474800000,
      updatedAt: 1759474800000,
      tags: const [],
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  FakeClock? clock,
}) async {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clockProvider.overrideWithValue(clock ?? FakeClock()),
        currentVaultProvider.overrideWith((_) => '/vaults/v'),
        vaultDbProvider.overrideWithValue(db),
        memexCliProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
}

Widget _header(Note note) => NoteHeader(
  note: note,
  titleCtrl: TextEditingController(text: note.title),
  onTitleChanged: (_) {},
);

final _dateHeader = find.byKey(const Key('daily-date-header'));
final _badge = find.byKey(const Key('daily-today-badge'));
final _title = find.byKey(const Key('editor-title'));

Finder _inHeader(String text) =>
    find.descendant(of: _dateHeader, matching: find.text(text));

void main() {
  group('date header replaces the title (AC6)', () {
    testWidgets(
      'a role daily note shows daily-date-header and no editor-title field',
      (tester) async {
        await _pump(tester, _header(_note(title: '2026-10-03')));

        expect(_dateHeader, findsOneWidget);
        expect(_inHeader('Saturday, 3 October 2026'), findsOneWidget);
        expect(_title, findsNothing);
        expect(find.byType(TextField), findsNothing);
      },
    );

    testWidgets(
      'a daily note titled 2026-09-05 reads Saturday, 5 September 2026',
      (tester) async {
        await _pump(tester, _header(_note(title: '2026-09-05')));

        expect(_inHeader('Saturday, 5 September 2026'), findsOneWidget);
        expect(_title, findsNothing);
      },
    );

    testWidgets(
      'a role-less note titled with an ISO date keeps the editable title while the role daily note for that date shows the date header',
      (tester) async {
        await _pump(
          tester,
          Column(
            children: [
              KeyedSubtree(
                key: const Key('roleless'),
                child: _header(_note(title: '2026-10-03', frontmatter: '{}')),
              ),
              KeyedSubtree(
                key: const Key('daily'),
                child: _header(_note(title: '2026-10-03')),
              ),
            ],
          ),
        );

        final roleless = find.byKey(const Key('roleless'));
        final daily = find.byKey(const Key('daily'));
        final rolelessTitle = find.descendant(of: roleless, matching: _title);
        expect(rolelessTitle, findsOneWidget);
        expect(
          tester.widget<TextField>(rolelessTitle).controller!.text,
          '2026-10-03',
        );
        expect(
          find.descendant(of: roleless, matching: _dateHeader),
          findsNothing,
        );
        expect(find.descendant(of: roleless, matching: _badge), findsNothing);
        expect(
          find.descendant(of: daily, matching: _dateHeader),
          findsOneWidget,
        );
        expect(find.descendant(of: daily, matching: _title), findsNothing);
      },
    );

    testWidgets(
      'a role topic note keeps the editable title while a role daily note shows the date header',
      (tester) async {
        await _pump(
          tester,
          Column(
            children: [
              KeyedSubtree(
                key: const Key('topic'),
                child: _header(
                  _note(title: 'Player Loop', frontmatter: '{"role":"topic"}'),
                ),
              ),
              KeyedSubtree(
                key: const Key('daily'),
                child: _header(_note(title: '2026-10-02')),
              ),
            ],
          ),
        );

        final topic = find.byKey(const Key('topic'));
        final daily = find.byKey(const Key('daily'));
        expect(find.descendant(of: topic, matching: _title), findsOneWidget);
        expect(find.descendant(of: topic, matching: _dateHeader), findsNothing);
        expect(find.descendant(of: topic, matching: _badge), findsNothing);
        expect(
          find.descendant(
            of: daily,
            matching: find.text('Friday, 2 October 2026'),
          ),
          findsOneWidget,
        );
        expect(find.descendant(of: daily, matching: _title), findsNothing);
      },
    );
  });

  group('Today badge (AC7)', () {
    testWidgets(
      'the Today badge shows when the daily note date equals todayDateProvider',
      (tester) async {
        await _pump(
          tester,
          DailyDateHeader(note: _note(title: '2026-10-03')),
          clock: FakeClock(DateTime(2026, 10, 3, 9)),
        );

        expect(_inHeader('Saturday, 3 October 2026'), findsOneWidget);
        expect(_badge, findsOneWidget);
        expect(
          find.descendant(of: _badge, matching: find.text('Today')),
          findsOneWidget,
        );
      },
    );

    testWidgets('no Today badge on the daily note for yesterday', (
      tester,
    ) async {
      await _pump(
        tester,
        DailyDateHeader(note: _note(title: '2026-10-02')),
        clock: FakeClock(DateTime(2026, 10, 3, 9)),
      );

      expect(_inHeader('Friday, 2 October 2026'), findsOneWidget);
      expect(_badge, findsNothing);
      expect(find.text('Today'), findsNothing);
    });

    testWidgets('no Today badge on the daily note for tomorrow', (
      tester,
    ) async {
      await _pump(
        tester,
        DailyDateHeader(note: _note(title: '2026-10-04')),
        clock: FakeClock(DateTime(2026, 10, 3, 9)),
      );

      expect(_inHeader('Sunday, 4 October 2026'), findsOneWidget);
      expect(_badge, findsNothing);
    });

    testWidgets(
      'the Today badge leaves the header of the daily note for 2026-10-03 at local midnight',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 10, 3, 23, 59));
        await _pump(
          tester,
          DailyDateHeader(note: _note(title: '2026-10-03')),
          clock: clock,
        );
        expect(_badge, findsOneWidget);

        clock.advance(const Duration(minutes: 2));
        await tester.pump();

        expect(_badge, findsNothing);
        expect(_inHeader('Saturday, 3 October 2026'), findsOneWidget);
      },
    );

    testWidgets(
      'a daily note for 2026-10-04 gains the Today badge at local midnight',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 10, 3, 23, 59));
        await _pump(
          tester,
          DailyDateHeader(note: _note(title: '2026-10-04')),
          clock: clock,
        );
        expect(_badge, findsNothing);

        clock.advance(const Duration(minutes: 2));
        await tester.pump();

        expect(_badge, findsOneWidget);
      },
    );
  });
}
