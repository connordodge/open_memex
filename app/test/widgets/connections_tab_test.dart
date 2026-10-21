// WI #90 (W6): the right panel's Connections and Activity tabs read through
// VaultAccess and keep today's grouping, labels, empty copy and Keys. The
// links and entries live only in Completer-gated doubles (the database holds
// just the note), so each test fails unless the tab reads them through
// vaultAccessProvider.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/activity_reads.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/app_harness.dart';
import '../support/fake_vault_db.dart';
import '../support/links_seeds.dart';
import '../support/review_fakes.dart';

const _target = 'n90-target';

FakeVaultDb _dbWithTargetOnly() {
  final db = FakeVaultDb.v5();
  db.seedNote(id: _target, title: 'Target', tags: const ['t1', 't2']);
  return db;
}

/// Links as the vault holds them (see `seedLinksFixture`): five outgoing,
/// eight incoming, one source without a title.
List<LinkRow> _outgoing() => [
  wi90Link(
    'out-ref',
    from: _target,
    to: 'n90-s2',
    text: 'Alpha',
    label: 'see also',
  ),
  wi90Link('out-ghost', from: _target, text: 'Nowhere', position: 1),
  wi90Link(
    'out-ext',
    from: _target,
    to: 'n90-s3',
    text: 'Mike',
    kind: 'extends',
    position: 2,
  ),
  wi90Link(
    'out-zeta',
    from: _target,
    to: 'n90-s1',
    text: 'Zulu',
    kind: 'zeta-kind',
    position: 3,
  ),
  wi90Link(
    'out-beta',
    from: _target,
    to: 'n90-s2',
    text: 'Alpha again',
    kind: 'beta-kind',
    position: 4,
  ),
];

List<LinkRow> _incoming() => [
  wi90Link('in-ext-zulu', from: 'n90-s1', to: _target, kind: 'extends'),
  wi90Link('in-ext-alpha', from: 'n90-s2', to: _target, kind: 'extends'),
  wi90Link('in-ext-mike', from: 'n90-s3', to: _target, kind: 'extends'),
  wi90Link('in-ext-gone', from: 'n90-gone', to: _target, kind: 'extends'),
  wi90Link('in-con-mike', from: 'n90-s3', to: _target, kind: 'contradicts'),
  wi90Link('in-ref-zulu', from: 'n90-s1', to: _target),
  wi90Link('in-zeta-alpha', from: 'n90-s2', to: _target, kind: 'zeta-kind'),
  wi90Link('in-alpha-mike', from: 'n90-s3', to: _target, kind: 'alpha-kind'),
];

const _titles = {'n90-s1': 'Zulu', 'n90-s2': 'Alpha', 'n90-s3': 'Mike'};

Future<WorkspaceHarness> _open(
  WidgetTester tester, {
  List<LinkRow>? out,
  List<LinkRow>? incoming,
  List<AgentChangeRow> changes = const [],
  RightPanelTab tab = RightPanelTab.connections,
  bool select = true,
}) async {
  final db = _dbWithTargetOnly();
  final notes = Wi90GatedNotes(
    vaultPath: '/unused',
    db: db,
    gate: Wi90Gate(),
    out: out ?? _outgoing(),
    incoming: incoming ?? _incoming(),
    titles: _titles,
  );
  final graph = Wi90GatedGraph(
    vaultPath: '/unused',
    db: db,
    gate: Wi90Gate(),
    changes: changes,
  );
  final h = await pumpWorkspace(
    tester,
    db: db,
    overrides: [
      vaultAccessProvider.overrideWith(
        (ref) => LocalVaultAccess(
          vaultPath: ref.watch(currentVaultProvider).localPath!,
          db: ref.watch(vaultDbProvider),
          notes: notes,
          graph: graph,
        ),
      ),
    ],
  );
  if (select) await openNoteTab(tester, h, _target);
  h.container.read(rightPanelOpenProvider.notifier).state = true;
  h.container.read(rightPanelTabProvider.notifier).state = tab;
  await pumpFrames(tester);
  return h;
}

Finder _out(String id) => find.byKey(Key('outgoing-link-$id'));
Finder _back(String from, String id) =>
    find.byKey(Key('backlink-item-$from-$id'));

double _top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

void _expectAbove(WidgetTester tester, Finder upper, Finder lower) {
  expect(upper, findsOneWidget);
  expect(lower, findsOneWidget);
  expect(_top(tester, upper), lessThan(_top(tester, lower)));
}

void main() {
  group('Connections tab', () {
    testWidgets(
      'the Connections tab lists outgoing links under built-in kinds first then user kinds alphabetically',
      (tester) async {
        await _open(tester);

        _expectAbove(tester, _out('out-ref'), _out('out-ghost'));
        _expectAbove(tester, _out('out-ghost'), _out('out-ext'));
        _expectAbove(tester, _out('out-ext'), _out('out-beta'));
        _expectAbove(tester, _out('out-beta'), _out('out-zeta'));
        expect(find.text('EXTENDS'), findsOneWidget);
        expect(find.text('BETA-KIND'), findsOneWidget);
        expect(find.text('see also'), findsOneWidget);
        expect(find.text('GHOST'), findsOneWidget);
      },
    );

    testWidgets(
      'the Connections tab groups backlinks by kind with the backlinkLabelForKind headers in order',
      (tester) async {
        await _open(tester);

        expect(find.text('EXTENDED BY'), findsOneWidget);
        expect(find.text('CONTRADICTED BY'), findsOneWidget);
        _expectAbove(
          tester,
          _back('n90-s1', 'in-ref-zulu'),
          _back('n90-s2', 'in-ext-alpha'),
        );
        _expectAbove(
          tester,
          _back('n90-s2', 'in-ext-alpha'),
          _back('n90-s3', 'in-con-mike'),
        );
        _expectAbove(
          tester,
          _back('n90-s3', 'in-con-mike'),
          _back('n90-s3', 'in-alpha-mike'),
        );
        _expectAbove(
          tester,
          _back('n90-s3', 'in-alpha-mike'),
          _back('n90-s2', 'in-zeta-alpha'),
        );
      },
    );

    testWidgets(
      'the Connections tab lists backlinks in a kind sorted by source title with the source id for a missing title',
      (tester) async {
        await _open(tester);

        _expectAbove(
          tester,
          _back('n90-s2', 'in-ext-alpha'),
          _back('n90-s3', 'in-ext-mike'),
        );
        _expectAbove(
          tester,
          _back('n90-s3', 'in-ext-mike'),
          _back('n90-s1', 'in-ext-zulu'),
        );
        _expectAbove(
          tester,
          _back('n90-s1', 'in-ext-zulu'),
          _back('n90-gone', 'in-ext-gone'),
        );
        expect(
          find.descendant(
            of: _back('n90-gone', 'in-ext-gone'),
            matching: find.text('n90-gone'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'the Connections tab counts outgoing links backlinks and tags from the loaded reads',
      (tester) async {
        await _open(tester);

        expect(find.text('5 outgoing · 8 backlinks · 2 tags'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping a backlink in the Connections tab selects its source note',
      (tester) async {
        final h = await _open(tester);
        final item = _back('n90-s2', 'in-ext-alpha');
        await tester.ensureVisible(item);
        await tester.pump();

        await tester.tap(item);
        await tester.pump();

        expect(h.container.read(selectedNoteIdProvider), 'n90-s2');
      },
    );

    testWidgets(
      'tapping an outgoing link in the Connections tab selects its target note',
      (tester) async {
        final h = await _open(tester);
        final item = _out('out-ext');
        await tester.ensureVisible(item);
        await tester.pump();

        await tester.tap(item);
        await tester.pump();

        expect(h.container.read(selectedNoteIdProvider), 'n90-s3');
      },
    );

    testWidgets(
      'the Connections tab shows no links yet for a note with no links',
      (tester) async {
        await _open(tester, out: const [], incoming: const []);

        expect(find.textContaining('no links yet.'), findsOneWidget);
        expect(find.text('0 outgoing · 0 backlinks · 2 tags'), findsOneWidget);
        expect(find.byKey(const Key('backlinks-panel')), findsOneWidget);
      },
    );

    testWidgets(
      'the Connections tab asks to select a note when nothing is selected',
      (tester) async {
        await _open(tester, select: false);

        expect(
          find.text('select a note to see its connections.'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('backlinks-panel')), findsNothing);
      },
    );
  });

  group('Activity tab', () {
    testWidgets(
      'the Activity tab lists entries read through VaultAccess with timestamp day and bullets',
      (tester) async {
        final at = DateTime(2026, 9, 5, 14, 32).millisecondsSinceEpoch;
        await _open(
          tester,
          tab: RightPanelTab.activity,
          changes: [
            AgentChangeRow(
              id: 'ac-new',
              noteId: _target,
              day: '2026-09-05',
              createdAt: at,
              bullets: const ['Tidied the list', 'Linked Gardening'],
            ),
            AgentChangeRow(
              id: 'ac-old',
              noteId: _target,
              day: '2026-09-02',
              createdAt: at - 86400000,
              bullets: const ['Read the entry'],
            ),
          ],
        );

        final entry = find.byKey(const Key('activity-entry-ac-new'));
        expect(entry, findsOneWidget);
        expect(
          find.descendant(
            of: entry,
            matching: find.textContaining('5 Sep 2026, 14:32'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: entry, matching: find.text('2026-09-05')),
          findsOneWidget,
        );
        expect(find.text('· Tidied the list'), findsOneWidget);
        expect(find.text('· Linked Gardening'), findsOneWidget);
        _expectAbove(
          tester,
          entry,
          find.byKey(const Key('activity-entry-ac-old')),
        );
        expect(find.byKey(const Key('activity-empty')), findsNothing);
      },
    );

    testWidgets(
      'the Activity tab shows the empty copy under Key activity-empty with no note selected',
      (tester) async {
        await _open(tester, tab: RightPanelTab.activity, select: false);

        expect(find.byKey(const Key('activity-empty')), findsOneWidget);
      },
    );

    testWidgets(
      'the Activity tab shows the empty copy under Key activity-empty for a note with no entries',
      (tester) async {
        await _open(tester, tab: RightPanelTab.activity);

        expect(find.byKey(const Key('activity-empty')), findsOneWidget);
      },
    );
  });
}
