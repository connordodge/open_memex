// WI #258 (F0): the Activity tab and the shared placeholder tab live in their
// own libraries. These tests import those libraries directly and pump each
// standalone, with no RightPanel around them. On main neither library exists,
// so this file does not compile there.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/activity_reads.dart';
import 'package:open_memex_app/src/state/activity_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/activity_tab.dart';
import 'package:open_memex_app/src/widgets/panel_placeholder_tab.dart';

const _vault = LocalVaultRef('/tmp/activity-tab-library-test');
const _emptyCopy =
    'no activity yet.\nconnect an agent via the MCP server to see what they touch.';

Note _note(String id) => Note(
  id: id,
  title: 'Topic $id',
  contentMd: '',
  frontmatter: '{}',
  version: 1,
  createdAt: DateTime(2026, 9, 5).millisecondsSinceEpoch,
  updatedAt: DateTime(2026, 9, 5).millisecondsSinceEpoch,
  tags: const [],
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [currentVaultProvider.overrideWith((_) => _vault), ...overrides],
    child: MaterialApp(home: Scaffold(body: child)),
  ),
);

void main() {
  group('Activity tab library (moved out of right_panel.dart)', () {
    testWidgets(
      'ActivityTab pumped standalone with no note selected shows the empty copy under Key activity-empty',
      (tester) async {
        await _pump(
          tester,
          const ActivityTab(),
          overrides: [
            selectedNoteAsyncProvider.overrideWith(
              (_) async => const VaultScoped<Note?>(_vault, null),
            ),
          ],
        );
        await tester.pump();

        expect(find.byKey(const Key('activity-empty')), findsOneWidget);
        expect(find.text(_emptyCopy), findsOneWidget);
      },
    );

    testWidgets(
      'ActivityTab pumped standalone lists the selected notes entry under Key activity-entry-id',
      (tester) async {
        await _pump(
          tester,
          const ActivityTab(),
          overrides: [
            selectedNoteAsyncProvider.overrideWith(
              (_) async => VaultScoped<Note?>(_vault, _note('n1')),
            ),
            agentChangesAsyncProvider('n1').overrideWith(
              (_) async => VaultScoped<List<AgentChangeRow>>(_vault, [
                AgentChangeRow(
                  id: 'ac-1',
                  noteId: 'n1',
                  day: '2026-09-05',
                  createdAt: DateTime(
                    2026,
                    9,
                    5,
                    14,
                    32,
                  ).millisecondsSinceEpoch,
                  bullets: const ['Linked Gardening'],
                ),
              ]),
            ),
          ],
        );
        await tester.pump();
        await tester.pump();

        expect(find.byKey(const Key('activity-entry-ac-1')), findsOneWidget);
        expect(find.text('· Linked Gardening'), findsOneWidget);
        expect(find.text('5 Sep 2026, 14:32'), findsOneWidget);
        expect(find.text('2026-09-05'), findsOneWidget);
        expect(find.byKey(const Key('activity-empty')), findsNothing);
      },
    );
  });

  group('PanelPlaceholderTab library (moved out of right_panel.dart)', () {
    testWidgets(
      'PanelPlaceholderTab pumped standalone shows its eyebrow subtitle and empty copy under the given key',
      (tester) async {
        await _pump(
          tester,
          const PanelPlaceholderTab(
            eyebrow: 'some eyebrow',
            subtitle: 'some subtitle',
            empty: 'nothing here yet',
            emptyKey: Key('placeholder-empty'),
          ),
        );

        expect(find.text('SOME EYEBROW'), findsOneWidget);
        expect(find.text('some subtitle'), findsOneWidget);
        expect(find.text('nothing here yet'), findsOneWidget);
        expect(find.byKey(const Key('placeholder-empty')), findsOneWidget);
      },
    );

    testWidgets(
      'PanelPlaceholderTab pumped standalone with an empty subtitle omits the subtitle line',
      (tester) async {
        await _pump(
          tester,
          const PanelPlaceholderTab(
            eyebrow: 'e',
            subtitle: '',
            empty: 'nothing here yet',
          ),
        );

        expect(find.text('nothing here yet'), findsOneWidget);
        // Eyebrow and empty copy only: no subtitle Text.
        expect(find.byType(Text), findsNWidgets(2));
      },
    );
  });
}
