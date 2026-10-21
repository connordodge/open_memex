// WI #101 (H7) AC7 to AC9: the not-loaded state of a tab whose content never
// loaded while its vault server can't be reached (design pack 101, board A11
// state 3), and the recovery when the server answers again.
//
// API under test:
//   class NotLoadedState (widgets/hosted/not_loaded_state.dart)
//       const NotLoadedState({Key? key, required String title,
//           required String serverName})
//       its root carries Key('tab-not-loaded'); it shows LucideIcons.wifiOff
//       16 px fg2, "<title> isn't loaded and <server> can't be reached."
//       (Inter Tight 13 fg1, line height 19.5) and "it opens as soon as
//       <server> answers." (JetBrains Mono 11 fg2, line height 16.5), centred
//       both ways with a 10 px gap.
//   The workspace body (`_TabBody` in screens/workspace.dart) shows it in
//   place of the note, canvas or graph body when ALL hold:
//     - the open vault is a HostedVaultRef,
//     - hostedConnectionStatusProvider(serverId) is unreachable,
//     - the active tab never loaded: its content read through
//       vaultAccessProvider (note: notes.getNote(id); canvas:
//       canvas.getCanvasDetail(id); graph: graph.graphNotes() and
//       graph.graphLinks()) failed with VaultUnreachableException and no
//       earlier read of that tab succeeded,
//     <title> is the title the tab chip shows; <server> is
//     hostedServerNameProvider(serverId).
//   Recovery: when that server's status goes unreachable -> connected the
//   workspace bumps vaultRevisionProvider exactly once (no other transition
//   bumps it), and a not-loaded tab reads its content once more and renders
//   it without a reopen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/graph_reads.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/hosted_identity.dart';
import 'package:open_memex_app/src/state/note_state.dart';
import 'package:open_memex_app/src/state/tab_not_loaded.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/canvas_view.dart';
import 'package:open_memex_app/src/widgets/graph/graph_view.dart';
import 'package:open_memex_app/src/widgets/hosted/not_loaded_state.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../support/app_harness.dart';

const _server = 'srv-nas';
const _vault = HostedVaultRef(_server, 'work');
const _notLoadedKey = Key('tab-not-loaded');

/// Whether the content reads of the double throw, and how many ran.
class _Wi101ReadGate {
  bool fail = true;
  int noteReads = 0;
  int canvasReads = 0;
  int graphReads = 0;

  void check() {
    if (fail) {
      throw const VaultUnreachableException(
        serverName: 'nas',
        mayHaveCommitted: false,
      );
    }
  }
}

/// Content-read doubles (D21): extend the local domain classes.
class _Wi101Notes extends LocalNotesAccess {
  _Wi101Notes(this.gate) : super(vaultPath: '/tmp/om-101');
  final _Wi101ReadGate gate;

  @override
  Future<Note?> getNote(String id) async {
    gate.noteReads++;
    gate.check();
    return Note(
      id: id,
      title: 'Loaded $id',
      contentMd: '# Loaded $id\n',
      frontmatter: '{}',
      version: 1,
      createdAt: 1759500000000,
      updatedAt: 1759500000000,
      tags: const [],
    );
  }
}

/// [_Wi101Notes] that also answers the title reads from [titles], through
/// the same gate: offline, `titlesForIds` and `allTitles` fail too.
class _Wi101TitledNotes extends _Wi101Notes {
  _Wi101TitledNotes(super.gate, this.titles);
  final Map<String, String> titles;

  @override
  Future<Map<String, String>> titlesForIds(List<String> ids) async {
    gate.check();
    return {
      for (final id in ids)
        if (titles[id] case final t?) id: t,
    };
  }

  @override
  Future<List<NoteTitle>> allTitles({int limit = 1000}) async {
    gate.check();
    return [
      for (final e in titles.entries)
        NoteTitle(id: e.key, title: e.value, updatedAt: 1759500000000),
    ];
  }
}

class _Wi101Canvas extends LocalCanvasAccess {
  _Wi101Canvas(this.gate) : super(vaultPath: '/tmp/om-101');
  final _Wi101ReadGate gate;

  @override
  Future<CanvasDetailRow?> getCanvasDetail(String canvasId) async {
    gate.canvasReads++;
    gate.check();
    return null;
  }
}

class _Wi101Graph extends LocalGraphAccess {
  _Wi101Graph(this.gate) : super(vaultPath: '/tmp/om-101');
  final _Wi101ReadGate gate;

  @override
  Future<List<GraphNoteRow>> graphNotes() async {
    gate.graphReads++;
    gate.check();
    return const [];
  }

  @override
  Future<List<GraphLinkRow>> graphLinks() async {
    gate.check();
    return const [];
  }
}

/// A tab kind under test: its tab, its body widget and its read counter.
typedef _Kind = ({
  String name,
  WorkspaceTab Function(String id) tab,
  Type body,
  int Function(_Wi101ReadGate) reads,
});

final _kinds = <_Kind>[
  (
    name: 'note',
    tab: (id) => NoteTab(id),
    body: NoteEditor,
    reads: (g) => g.noteReads,
  ),
  (
    name: 'canvas',
    tab: (id) => CanvasTab(id),
    body: CanvasView,
    reads: (g) => g.canvasReads,
  ),
  (
    name: 'graph',
    tab: (id) => GraphTab(const GraphScope.vault()),
    body: GraphView,
    reads: (g) => g.graphReads,
  ),
];

/// Pumps the whole workspace on a hosted vault whose content reads go
/// through [gate]'s doubles. Starts with status [status] (null = no outcome).
Future<(WorkspaceHarness, _Wi101ReadGate)> _pumpHosted(
  WidgetTester tester, {
  bool failing = true,
  VaultRef vault = _vault,
  HostedConnectionStatus? status,
  List<Override> extraOverrides = const [],
  Map<String, String>? titles,
}) async {
  final gate = _Wi101ReadGate()..fail = failing;
  final h = await pumpWorkspace(
    tester,
    overrides: [
      ...extraOverrides,
      hostedServerNameProvider.overrideWith(
        (ref, id) => id == _server ? 'nas' : id,
      ),
      vaultAccessProvider.overrideWith(
        (ref) => LocalVaultAccess(
          vaultPath: '/tmp/om-101',
          notes: titles == null
              ? _Wi101Notes(gate)
              : _Wi101TitledNotes(gate, titles),
          canvas: _Wi101Canvas(gate),
          graph: _Wi101Graph(gate),
        ),
      ),
    ],
  );
  h.container.read(currentVaultProvider.notifier).state = vault;
  await pumpFrames(tester);
  h.container.read(hostedConnectionStatusProvider(_server).notifier).state =
      status;
  await pumpFrames(tester);
  return (h, gate);
}

Future<void> _open(WidgetTester tester, WorkspaceHarness h, WorkspaceTab tab) {
  h.container.read(tabsProvider.notifier).openOrFocus(tab);
  return pumpFrames(tester);
}

Future<void> _setStatus(
  WidgetTester tester,
  WorkspaceHarness h,
  HostedConnectionStatus? status,
) {
  h.container.read(hostedConnectionStatusProvider(_server).notifier).state =
      status;
  return pumpFrames(tester);
}

/// The title the chip of [tab] shows.
String _chipTitle(WidgetTester tester, WorkspaceTab tab) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(Key('tab-${tab.tabId}')),
        matching: find.byType(Text),
      ),
    )
    .data!;

void _expectCopy(WidgetTester tester, String title) {
  expect(find.byKey(_notLoadedKey), findsOneWidget);
  expect(
    find.text('$title isn\'t loaded and nas can\'t be reached.'),
    findsOneWidget,
  );
  expect(find.text('it opens as soon as nas answers.'), findsOneWidget);
  expect(
    find.descendant(
      of: find.byKey(_notLoadedKey),
      matching: find.byIcon(LucideIcons.wifiOff),
    ),
    findsOneWidget,
  );
}

void _expectStyle(TextStyle? actual, TextStyle expected) {
  expect(actual, isNotNull);
  expect(actual!.fontFamily, expected.fontFamily);
  expect(actual.fontSize, expected.fontSize);
  expect(actual.fontWeight, expected.fontWeight);
  expect(actual.height, expected.height);
  expect(actual.color, expected.color);
}

void main() {
  group('NotLoadedState widget', () {
    Future<void> pumpState(WidgetTester tester, String title, String server) {
      return tester.pumpWidget(
        MaterialApp(
          theme: buildOmTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 500,
              child: NotLoadedState(title: title, serverName: server),
            ),
          ),
        ),
      );
    }

    testWidgets('the not loaded state shows the icon and the two lines', (
      tester,
    ) async {
      final title = ['weekly', 'review'].join(' ');
      await pumpState(tester, title, 'nas');
      expect(find.byKey(_notLoadedKey), findsOneWidget);
      expect(
        find.text('weekly review isn\'t loaded and nas can\'t be reached.'),
        findsOneWidget,
      );
      expect(find.text('it opens as soon as nas answers.'), findsOneWidget);
      expect(find.byIcon(LucideIcons.wifiOff), findsOneWidget);
    });

    testWidgets(
      'the not loaded state names whatever title and server it is given',
      (tester) async {
        await pumpState(tester, 'Graph · Whole vault', 'office box');
        expect(
          find.text(
            'Graph · Whole vault isn\'t loaded and office box can\'t be reached.',
          ),
          findsOneWidget,
        );
        expect(
          find.text('it opens as soon as office box answers.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'the not loaded state follows the A11 type, colour and spacing',
      (tester) async {
        await pumpState(tester, 'weekly review', 'nas');
        final icon = tester.widget<Icon>(find.byIcon(LucideIcons.wifiOff));
        expect(icon.size, 16);
        expect(icon.color, OmColors.fg2);

        final first = find.text(
          'weekly review isn\'t loaded and nas can\'t be reached.',
        );
        final second = find.text('it opens as soon as nas answers.');
        _expectStyle(
          tester.widget<Text>(first).style,
          OmType.sans(size: 13, color: OmColors.fg1, height: 19.5 / 13),
        );
        _expectStyle(
          tester.widget<Text>(second).style,
          OmType.mono(size: 11, color: OmColors.fg2, height: 16.5 / 11),
        );

        // Column, gap 10, centred both ways in the 800 x 500 area.
        final iconRect = tester.getRect(find.byIcon(LucideIcons.wifiOff));
        final firstRect = tester.getRect(first);
        final secondRect = tester.getRect(second);
        expect(firstRect.top - iconRect.bottom, 10);
        expect(secondRect.top - firstRect.bottom, 10);
        expect(iconRect.center.dx, 400);
        expect(firstRect.center.dx, 400);
        expect(secondRect.center.dx, 400);
        final top =
            iconRect.top - tester.getTopLeft(find.byKey(_notLoadedKey)).dy;
        final bottom =
            tester.getBottomLeft(find.byKey(_notLoadedKey)).dy -
            secondRect.bottom;
        expect((top - bottom).abs(), lessThan(1));
      },
    );
  });

  group('not loaded tab body', () {
    for (final kind in _kinds) {
      // The literal names keep the AC map lint happy.
      final names = switch (kind.name) {
        'note' =>
          'a never loaded note tab shows the not loaded state while the server is unreachable',
        'canvas' =>
          'a never loaded canvas tab shows the not loaded state while the server is unreachable',
        _ =>
          'a never loaded graph tab shows the not loaded state while the server is unreachable',
      };
      testWidgets(names, (tester) async {
        final (h, _) = await _pumpHosted(
          tester,
          status: HostedConnectionStatus.unreachable,
        );
        final tab = kind.tab('x1');
        await _open(tester, h, tab);

        _expectCopy(tester, _chipTitle(tester, tab));
        // In place of the body, with the tab bar and its chip still there.
        expect(find.byType(kind.body), findsNothing);
        expect(find.byKey(const Key('workspace-tab-bar')), findsOneWidget);
        expect(find.byKey(Key('tab-${tab.tabId}')), findsOneWidget);
      });
    }

    testWidgets('the not loaded state shows the hosted server name', (
      tester,
    ) async {
      final (h, _) = await _pumpHosted(
        tester,
        status: HostedConnectionStatus.unreachable,
      );
      await _open(tester, h, const NoteTab('x1'));
      expect(find.textContaining('nas can\'t be reached'), findsOneWidget);
      expect(find.textContaining(_server), findsNothing);
    });

    testWidgets(
      'a note tab with a known title shows that title in the not loaded line',
      (tester) async {
        final (h, _) = await _pumpHosted(
          tester,
          status: HostedConnectionStatus.unreachable,
        );
        await _open(tester, h, const NoteTab('x1'));
        final title = _chipTitle(tester, const NoteTab('x1'));
        expect(title, isNotEmpty);
        expect(
          find.text('$title isn\'t loaded and nas can\'t be reached.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a tab whose read works shows its body while the server is unreachable',
      (tester) async {
        final (h, gate) = await _pumpHosted(
          tester,
          failing: false,
          status: HostedConnectionStatus.unreachable,
        );
        await _open(tester, h, const NoteTab('x1'));
        expect(gate.noteReads, greaterThan(0));
        expect(find.byKey(_notLoadedKey), findsNothing);
        expect(find.byType(NoteEditor), findsOneWidget);
      },
    );

    for (final status in <HostedConnectionStatus?>[
      null,
      HostedConnectionStatus.connected,
    ]) {
      final name = status == null
          ? 'a failed read with no server outcome yet shows no not loaded state'
          : 'a failed read with a connected server shows no not loaded state';
      testWidgets(name, (tester) async {
        final (h, _) = await _pumpHosted(tester, status: status);
        await _open(tester, h, const NoteTab('x1'));
        expect(find.byKey(_notLoadedKey), findsNothing);
        expect(find.byType(NoteEditor), findsOneWidget);
      });
    }

    testWidgets(
      'the status of another server does not show the not loaded state',
      (tester) async {
        final (h, _) = await _pumpHosted(tester);
        h.container
                .read(hostedConnectionStatusProvider('srv-other').notifier)
                .state =
            HostedConnectionStatus.unreachable;
        await _open(tester, h, const NoteTab('x1'));
        expect(find.byKey(_notLoadedKey), findsNothing);
      },
    );

    testWidgets('a local vault never shows the not loaded state', (
      tester,
    ) async {
      final (h, _) = await _pumpHosted(
        tester,
        vault: const LocalVaultRef('/tmp/om-101-local'),
        status: HostedConnectionStatus.unreachable,
      );
      await _open(tester, h, const NoteTab('x1'));
      expect(find.byKey(_notLoadedKey), findsNothing);
      expect(find.byType(NoteEditor), findsOneWidget);
    });

    testWidgets(
      'a tab loaded before the outage never shows the not loaded state',
      (tester) async {
        final (h, gate) = await _pumpHosted(
          tester,
          failing: false,
          status: HostedConnectionStatus.connected,
        );
        await _open(tester, h, const NoteTab('loaded'));
        expect(find.byType(NoteEditor), findsOneWidget);

        // The outage: the server drops and every later read fails.
        gate.fail = true;
        await _setStatus(tester, h, HostedConnectionStatus.unreachable);
        h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);
        expect(find.byKey(_notLoadedKey), findsNothing);
        expect(find.byType(NoteEditor), findsOneWidget);

        // A tab opened during the outage never loaded, and shows it.
        await _open(tester, h, const NoteTab('later'));
        expect(find.byKey(_notLoadedKey), findsOneWidget);
        expect(find.byType(NoteEditor), findsNothing);

        // Back on the loaded tab, its last content is still there.
        h.container.read(tabsProvider.notifier).setActive(0);
        await pumpFrames(tester);
        expect(find.byKey(_notLoadedKey), findsNothing);
        expect(find.byType(NoteEditor), findsOneWidget);
      },
    );
  });

  group('recovery', () {
    // (from, to, bumps): only unreachable -> connected bumps.
    final transitions =
        <(HostedConnectionStatus?, HostedConnectionStatus?, int)>[
          (
            HostedConnectionStatus.unreachable,
            HostedConnectionStatus.connected,
            1,
          ),
          (null, HostedConnectionStatus.connected, 0),
          (
            HostedConnectionStatus.connected,
            HostedConnectionStatus.unreachable,
            0,
          ),
          (
            HostedConnectionStatus.unreachable,
            HostedConnectionStatus.tokenRejected,
            0,
          ),
          (
            HostedConnectionStatus.tokenRejected,
            HostedConnectionStatus.connected,
            0,
          ),
          (HostedConnectionStatus.unreachable, null, 0),
        ];

    for (final (from, to, bumps) in transitions) {
      testWidgets(
        'status transition ${from?.name} to ${to?.name} bumps the revision $bumps times',
        (tester) async {
          final (h, _) = await _pumpHosted(
            tester,
            failing: false,
            status: from,
          );
          final before = h.read(vaultRevisionProvider);
          await _setStatus(tester, h, to);
          expect(h.read(vaultRevisionProvider), before + bumps);
        },
      );
    }

    testWidgets(
      'each unreachable to connected transition bumps the revision once',
      (tester) async {
        final (h, _) = await _pumpHosted(
          tester,
          failing: false,
          status: HostedConnectionStatus.unreachable,
        );
        final before = h.read(vaultRevisionProvider);
        await _setStatus(tester, h, HostedConnectionStatus.connected);
        expect(h.read(vaultRevisionProvider), before + 1);
        await _setStatus(tester, h, HostedConnectionStatus.unreachable);
        expect(h.read(vaultRevisionProvider), before + 1);
        await _setStatus(tester, h, HostedConnectionStatus.connected);
        expect(h.read(vaultRevisionProvider), before + 2);
      },
    );

    testWidgets('another server recovering does not bump the revision', (
      tester,
    ) async {
      final (h, _) = await _pumpHosted(tester, failing: false);
      final other = hostedConnectionStatusProvider('srv-other').notifier;
      h.container.read(other).state = HostedConnectionStatus.unreachable;
      await pumpFrames(tester);
      final before = h.read(vaultRevisionProvider);
      h.container.read(other).state = HostedConnectionStatus.connected;
      await pumpFrames(tester);
      expect(h.read(vaultRevisionProvider), before);
    });

    testWidgets('a local vault ignores a server recovering', (tester) async {
      final (h, _) = await _pumpHosted(
        tester,
        failing: false,
        vault: const LocalVaultRef('/tmp/om-101-local'),
        status: HostedConnectionStatus.unreachable,
      );
      final before = h.read(vaultRevisionProvider);
      await _setStatus(tester, h, HostedConnectionStatus.connected);
      expect(h.read(vaultRevisionProvider), before);
    });

    for (final kind in _kinds) {
      final name = switch (kind.name) {
        'note' =>
          'a not loaded note tab reads again once and renders when the server answers',
        'canvas' =>
          'a not loaded canvas tab reads again once and renders when the server answers',
        _ =>
          'a not loaded graph tab reads again once and renders when the server answers',
      };
      testWidgets(name, (tester) async {
        // What the tab body alone reads when it mounts (the canvas and graph
        // views read through their async providers): the same tab on a
        // connected server with the not-loaded check switched off.
        final (bodyHarness, bodyGate) = await _pumpHosted(
          tester,
          failing: false,
          status: HostedConnectionStatus.connected,
          extraOverrides: [
            tabNotLoadedProvider.overrideWith((ref, tab) => null),
          ],
        );
        await _open(tester, bodyHarness, kind.tab('x1'));
        expect(find.byType(kind.body), findsOneWidget);
        final bodyMountReads = kind.reads(bodyGate);
        await tester.pumpWidget(const SizedBox());
        await pumpFrames(tester);

        final (h, gate) = await _pumpHosted(
          tester,
          status: HostedConnectionStatus.unreachable,
        );
        await _open(tester, h, kind.tab('x1'));
        expect(find.byKey(_notLoadedKey), findsOneWidget);
        final readsWhileDown = kind.reads(gate);
        expect(readsWhileDown, greaterThan(0));

        // The server answers again: reads work from now on. The not-loaded
        // check reads once more, and the body that then mounts does its own
        // first read.
        gate.fail = false;
        await _setStatus(tester, h, HostedConnectionStatus.connected);

        expect(find.byKey(_notLoadedKey), findsNothing);
        expect(find.byType(kind.body), findsOneWidget);
        expect(kind.reads(gate), readsWhileDown + 1 + bodyMountReads);
        // Quiet afterwards: no further read without another trigger.
        await pumpFrames(tester);
        expect(kind.reads(gate), readsWhileDown + 1 + bodyMountReads);
      });
    }

    testWidgets(
      'a not loaded tab stays not loaded when the recovery read fails again',
      (tester) async {
        final (h, gate) = await _pumpHosted(
          tester,
          status: HostedConnectionStatus.unreachable,
        );
        await _open(tester, h, const NoteTab('x1'));
        expect(find.byKey(_notLoadedKey), findsOneWidget);

        // Answers once, then drops again before the re-read completes.
        await _setStatus(tester, h, HostedConnectionStatus.connected);
        await _setStatus(tester, h, HostedConnectionStatus.unreachable);

        expect(gate.fail, isTrue);
        expect(find.byKey(_notLoadedKey), findsOneWidget);
        expect(find.byType(NoteEditor), findsNothing);
      },
    );
  });
  group('the title of a not loaded note while offline', () {
    /// A hosted vault that answered: x1 opened (loaded) and every note title
    /// read, then the server stops answering.
    Future<(WorkspaceHarness, _Wi101ReadGate)> pumpTitlesThenOffline(
      WidgetTester tester,
    ) async {
      final (h, gate) = await _pumpHosted(
        tester,
        failing: false,
        status: HostedConnectionStatus.connected,
        titles: const {'x1': 'Loaded x1', 'x9': 'Weekly Review'},
      );
      await _open(tester, h, const NoteTab('x1'));
      final loaded = await h.container.read(noteTitlesAsyncProvider.future);
      expect(
        loaded.value.map((t) => t.title),
        contains('Weekly Review'),
        reason: 'the titles were read while the server answered',
      );
      gate.fail = true;
      await _setStatus(tester, h, HostedConnectionStatus.unreachable);
      // A revision bump while offline re-reads the titles and fails.
      h.container.read(vaultRevisionProvider.notifier).state++;
      await pumpFrames(tester);
      return (h, gate);
    }

    testWidgets(
      'while the server cannot be reached the not loaded state names the note by the title already known',
      (tester) async {
        final (h, _) = await pumpTitlesThenOffline(tester);

        await _open(tester, h, const NoteTab('x9'));

        _expectCopy(tester, 'Weekly Review');
        expect(_chipTitle(tester, const NoteTab('x9')), 'Weekly Review');
      },
    );

    testWidgets('with no known title the not loaded state still reads note', (
      tester,
    ) async {
      final (h, _) = await pumpTitlesThenOffline(tester);

      await _open(tester, h, const NoteTab('x7'));

      _expectCopy(tester, 'note');
      expect(_chipTitle(tester, const NoteTab('x7')), 'note');
    });
  });
}
