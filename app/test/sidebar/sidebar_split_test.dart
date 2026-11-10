// WI #19 (A2, D22): the sidebar host composes NotesPane and CanvasesRail,
// each in its own single-owner file.
//
// These tests import the new public paths, so they fail to load on main
// (RED ON MAIN). They also pin that the split is behaviour-preserving: the
// Keys, empty states, rail sizing and tab opening all still work.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/canvas_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/db/topics_reads.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/topics_state.dart';
import 'package:open_memex_app/src/state/topics_tree.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:open_memex_app/src/widgets/sidebar/canvases_rail.dart';
import 'package:open_memex_app/src/widgets/sidebar/notes_pane.dart';
import 'package:open_memex_app/src/widgets/sidebar/topics_pane.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/token_store_fakes.dart';

// ---------------------------------------------------------------------------
// Fakes and fixtures
// ---------------------------------------------------------------------------

/// MemexCli is a concrete class; this subclass records `createCanvas` and
/// never shells out.
class _FakeCli extends MemexCli {
  _FakeCli() : super(binaryPath: '/nonexistent/memex-test-binary');

  final createdTitles = <String>[];

  @override
  Future<CanvasInfo> createCanvas({
    required String vaultPath,
    required String title,
  }) async {
    createdTitles.add(title);
    return CanvasInfo(
      canvasId: 'c-new',
      title: title,
      version: 1,
      createdAt: 0,
      updatedAt: 0,
    );
  }
}

NoteListItem _noteItem(String id, String title) =>
    NoteListItem(id: id, title: title, snippet: '', version: 1, updatedAt: 0);

CanvasRow _canvas(String id, String title, {int nodeCount = 0}) => CanvasRow(
  canvasId: id,
  title: title,
  createdAt: 0,
  updatedAt: 0,
  version: 1,
  nodeCount: nodeCount,
);

final _notes = [
  _noteItem('n1', 'Alpha note'),
  _noteItem('n2', 'Beta note'),
  _noteItem('n3', 'Gamma note'),
];

final _canvases = [
  _canvas('c1', 'Board one', nodeCount: 4),
  _canvas('c2', 'Board two'),
];

class _Harness {
  _Harness(this.vaultDir, this.cli);
  final Directory vaultDir;
  final _FakeCli cli;
  final selections = <String?>[];
  int newNoteTaps = 0;
  late ProviderContainer container;
}

/// A vault dir for the tabs store. Synchronous IO only: testWidgets runs in
/// a fake-async zone.
Directory _tempVault() {
  final root = Directory.systemTemp.createTempSync('sidebar_split_test');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  // A short vault name keeps the sidebar header within its fixed width.
  return Directory('${root.path}/v')..createSync();
}

List<Override> _overrides(
  _Harness h, {
  required SettingsController settings,
  List<NoteListItem>? notes,
  List<CanvasRow>? canvases,
}) => [
  settingsProvider.overrideWith((_) => settings),
  // #24: Topics mode reads the Smart Folder tree; these notes sit in Unsorted.
  smartFolderTreeAsyncProvider.overrideWith(
    (ref) => VaultScoped(
      ref.watch(currentVaultProvider),
      buildTopicsTree(const SmartFolderData(folders: [], members: []), [
        for (final n in notes ?? _notes)
          UnsortedNoteRow(noteId: n.id, title: n.title, role: null),
      ]),
    ),
  ),
  currentVaultProvider.overrideWith((ref) => LocalVaultRef(h.vaultDir.path)),
  vaultDbProvider.overrideWithValue(null),
  memexCliProvider.overrideWithValue(h.cli),
  notesListAsyncProvider.overrideWith(
    (ref) => VaultScoped(ref.watch(currentVaultProvider), notes ?? _notes),
  ),
  canvasesAsyncProvider.overrideWith(
    (ref) =>
        VaultScoped(ref.watch(currentVaultProvider), canvases ?? _canvases),
  ),
  tabsProvider.overrideWith((ref) {
    return TabsNotifier(
      store: UiStateStore(vaultPath: h.vaultDir.path),
      onPersistedSelection: (id) {
        h.selections.add(id);
        ref.read(selectedNoteIdProvider.notifier).state = id;
      },
    );
  }),
];

Future<_Harness> _pump(
  WidgetTester tester, {
  required Widget Function(_Harness h) build,
  List<NoteListItem>? notes,
  List<CanvasRow>? canvases,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({
    'memex.binary_path': '/nonexistent/memex-test-binary',
  });
  final settings = await loadSettingsKeepingPickedBinary();
  final h = _Harness(_tempVault(), _FakeCli());

  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(
        h,
        settings: settings,
        notes: notes,
        canvases: canvases,
      ),
      child: Consumer(
        builder: (context, ref, _) {
          h.container = ProviderScope.containerOf(context);
          return MaterialApp(
            theme: buildOmTheme(),
            // The test font renders wider than the real fonts; shrink text so
            // the fixed-width (268) sidebar lays out without overflow.
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(0.5)),
              child: child!,
            ),
            home: Scaffold(
              body: Align(alignment: Alignment.topLeft, child: build(h)),
            ),
          );
        },
      ),
    ),
  );
  await tester.pump();
  return h;
}

Widget _notesPaneHost(_Harness h, List<NoteListItem> notes) => SizedBox(
  width: 268,
  height: 600,
  child: NotesPane(
    notes: notes,
    activeNoteId: null,
    onNewNote: () => h.newNoteTaps++,
  ),
);

Widget _canvasesRailHost(List<CanvasRow> canvases) => SizedBox(
  width: 268,
  child: CanvasesRail(canvases: canvases, activeCanvasId: null),
);

/// The fill of the decorated box under the Topics row with [key].
Color? _rowFill(WidgetTester tester, String key) {
  final box =
      find
              .descendant(
                of: find.byKey(Key(key)),
                matching: find.byWidgetPredicate(
                  (w) => w is Container && w.decoration is BoxDecoration,
                ),
              )
              .evaluate()
              .first
              .widget
          as Container;
  return (box.decoration! as BoxDecoration).color;
}

Finder _in(Finder parent, Finder child) =>
    find.descendant(of: parent, matching: child);

void main() {
  // -------------------------------------------------------------------------
  // AC 8: NotesPane renders the list (notes-rail / note-list-item-<id>) and
  // its empty state.
  // -------------------------------------------------------------------------
  group('NotesPane (widgets/sidebar/notes_pane.dart)', () {
    testWidgets(
      'NotesPane renders a given note list with Keys notes-rail and note-list-item-<id>',
      (tester) async {
        await _pump(tester, build: (h) => _notesPaneHost(h, _notes));

        final rail = find.byKey(const Key('notes-rail'));
        expect(rail, findsOneWidget);
        expect(_in(find.byType(NotesPane), rail), findsOneWidget);
        for (final n in _notes) {
          final row = find.byKey(Key('note-list-item-${n.id}'));
          expect(_in(rail, row), findsOneWidget, reason: n.id);
          expect(_in(row, find.text(n.title)), findsOneWidget, reason: n.id);
        }
        expect(find.byKey(const Key('note-list-item-n4')), findsNothing);
        expect(find.text('no notes yet.'), findsNothing);
      },
    );

    testWidgets('NotesPane shows its empty state when the note list is empty', (
      tester,
    ) async {
      final h = await _pump(tester, build: (h) => _notesPaneHost(h, const []));

      expect(find.byKey(const Key('notes-rail')), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('note-list-item-'),
        ),
        findsNothing,
      );
      expect(
        _in(find.byType(NotesPane), find.text('no notes yet.')),
        findsOneWidget,
      );

      await tester.tap(_in(find.byType(NotesPane), find.text('new note')));
      await tester.pump();
      expect(h.newNoteTaps, 1);
    });

    testWidgets('a single note renders the rail, not the empty state', (
      tester,
    ) async {
      await _pump(
        tester,
        build: (h) => _notesPaneHost(h, [_noteItem('solo', 'Solo')]),
      );
      expect(find.byKey(const Key('notes-rail')), findsOneWidget);
      expect(find.byKey(const Key('note-list-item-solo')), findsOneWidget);
      expect(find.text('no notes yet.'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // AC 9: CanvasesRail renders canvases-rail with one canvas-row-<id> each.
  // -------------------------------------------------------------------------
  group('CanvasesRail (widgets/sidebar/canvases_rail.dart)', () {
    testWidgets(
      'CanvasesRail renders canvases-rail with one canvas-row-<id> per canvas',
      (tester) async {
        await _pump(tester, build: (_) => _canvasesRailHost(_canvases));

        final rail = find.byKey(const Key('canvases-rail'));
        expect(rail, findsOneWidget);
        expect(_in(find.byType(CanvasesRail), rail), findsOneWidget);
        for (final c in _canvases) {
          final row = find.byKey(Key('canvas-row-${c.canvasId}'));
          expect(_in(rail, row), findsOneWidget, reason: c.canvasId);
          expect(_in(row, find.text(c.title)), findsOneWidget);
        }
        // Node count shows only when the canvas has nodes.
        expect(
          _in(find.byKey(const Key('canvas-row-c1')), find.text('4')),
          findsOneWidget,
        );
        expect(
          _in(find.byKey(const Key('canvas-row-c2')), find.text('0')),
          findsNothing,
        );
        expect(find.text('no canvases yet.'), findsNothing);
      },
    );

    testWidgets(
      'CanvasesRail keeps its row-height sizing (26 per row, 26..156)',
      (tester) async {
        await _pump(tester, build: (_) => _canvasesRailHost(_canvases));
        expect(
          tester.getSize(find.byKey(const Key('canvases-rail'))).height,
          52,
        );
      },
    );

    testWidgets('CanvasesRail caps its height at six rows', (tester) async {
      final many = [for (var i = 0; i < 10; i++) _canvas('m$i', 'Board $i')];
      await _pump(tester, build: (_) => _canvasesRailHost(many));
      expect(
        tester.getSize(find.byKey(const Key('canvases-rail'))).height,
        156,
      );
    });

    testWidgets('CanvasesRail with one canvas is one row tall', (tester) async {
      await _pump(
        tester,
        build: (_) => _canvasesRailHost([_canvas('only', 'Only')]),
      );
      expect(tester.getSize(find.byKey(const Key('canvases-rail'))).height, 26);
      expect(find.byKey(const Key('canvas-row-only')), findsOneWidget);
    });

    testWidgets(
      'CanvasesRail shows its empty state when there are no canvases',
      (tester) async {
        await _pump(tester, build: (_) => _canvasesRailHost(const []));
        expect(find.byKey(const Key('canvases-rail')), findsNothing);
        expect(
          _in(find.byType(CanvasesRail), find.text('no canvases yet.')),
          findsOneWidget,
        );
      },
    );

    testWidgets('tapping a canvas row opens that canvas tab', (tester) async {
      final h = await _pump(tester, build: (_) => _canvasesRailHost(_canvases));
      await tester.tap(find.byKey(const Key('canvas-row-c2')));
      await tester.pump();
      expect(h.container.read(activeTabProvider), const CanvasTab('c2'));
    });
  });

  // -------------------------------------------------------------------------
  // AC 10: the host composes NotesPane and CanvasesRail; a note tap opens
  // that note's tab.
  // -------------------------------------------------------------------------
  group('Sidebar host (widgets/sidebar.dart)', () {
    Widget sidebar(_Harness h) =>
        SizedBox(height: 900, child: Sidebar(onNewNote: () => h.newNoteTaps++));

    // #23: the sidebar opens in Days mode; NotesPane is the Topics mode.
    Future<void> chooseTopics(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('sidebar-mode-topics')));
      await tester.pump();
    }

    testWidgets(
      'the sidebar host composes NotesPane and CanvasesRail and tapping a note row shows that note in the current tab',
      (tester) async {
        final h = await _pump(tester, build: sidebar);
        await chooseTopics(tester);

        // #24: the Topics pane took the Topics-mode slot from NotesPane.
        expect(
          _in(find.byType(Sidebar), find.byType(TopicsPane)),
          findsOneWidget,
        );
        expect(
          _in(find.byType(Sidebar), find.byType(CanvasesRail)),
          findsOneWidget,
        );
        expect(
          _in(find.byType(TopicsPane), find.byKey(const Key('topics-pane'))),
          findsOneWidget,
        );
        expect(
          _in(
            find.byType(CanvasesRail),
            find.byKey(const Key('canvases-rail')),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('topics-unsorted-n2')));
        await tester.pump();

        expect(h.container.read(activeTabProvider), const NoteTab('n2'));
        expect(h.container.read(selectedNoteIdProvider), 'n2');
        expect(h.selections.last, 'n2');

        // #266: tapping a second note navigates the same tab.
        await tester.tap(find.byKey(const Key('topics-unsorted-n3')));
        await tester.pump();
        final tabs = h.container.read(tabsProvider);
        expect(tabs.tabs, [const NoteTab('n3')]);
        expect(tabs.canGoBack, isTrue);
        expect(h.container.read(activeTabProvider), const NoteTab('n3'));
      },
    );

    testWidgets('the sidebar host passes the active note and canvas through', (
      tester,
    ) async {
      final h = await _pump(tester, build: sidebar);
      await chooseTopics(tester);
      h.container.read(tabsProvider.notifier).openOrFocus(const NoteTab('n1'));
      await tester.pump();
      expect(_rowFill(tester, 'topics-unsorted-n1'), OmColors.surface4);
      expect(_rowFill(tester, 'topics-unsorted-n2'), Colors.transparent);
      expect(
        tester.widget<CanvasesRail>(find.byType(CanvasesRail)).activeCanvasId,
        isNull,
      );

      h.container
          .read(tabsProvider.notifier)
          .openOrFocus(const CanvasTab('c1'));
      await tester.pump();
      expect(_rowFill(tester, 'topics-unsorted-n1'), Colors.transparent);
      expect(
        tester.widget<CanvasesRail>(find.byType(CanvasesRail)).activeCanvasId,
        'c1',
      );
    });

    testWidgets(
      'the sidebar host shows the NotesPane empty state and wires new note',
      (tester) async {
        await _pump(tester, build: sidebar, notes: const []);
        await chooseTopics(tester);
        // #24: an empty vault shows the Topics empty state, not the notes
        // pane's `no notes yet.` with a new-note button.
        expect(
          _in(find.byType(TopicsPane), find.byKey(const Key('topics-empty'))),
          findsOneWidget,
        );
        expect(find.byType(NotesPane), findsNothing);
        expect(find.byKey(const Key('copy-review-prompt')), findsOneWidget);
      },
    );

    testWidgets(
      'the sidebar host still creates a canvas through new-canvas-confirm',
      (tester) async {
        final h = await _pump(tester, build: sidebar);

        // The canvases header "+ new" (uppercased); the vaults header
        // shows MANAGE since #363.
        await tester.tap(
          find.descendant(
            of: find.ancestor(
              of: find.text('CANVASES'),
              matching: find.byType(PanelHeader),
            ),
            matching: find.text('+ NEW'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('new-canvas-confirm')), findsOneWidget);

        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          'Fresh board',
        );
        await tester.tap(find.byKey(const Key('new-canvas-confirm')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(h.cli.createdTitles, ['Fresh board']);
        expect(h.container.read(activeTabProvider), const CanvasTab('c-new'));
      },
    );
  });

  // -------------------------------------------------------------------------
  // Implementer additions: active-row highlight of the moved rows.
  // -------------------------------------------------------------------------
  group('Sidebar row highlight', () {
    Color? rowColor(WidgetTester tester, String key) {
      final box = tester.widget<Container>(find.byKey(Key(key)));
      return (box.decoration! as BoxDecoration).color;
    }

    testWidgets('NotesPane highlights only the active note row', (
      tester,
    ) async {
      await _pump(
        tester,
        build: (h) => SizedBox(
          width: 268,
          height: 600,
          child: NotesPane(notes: _notes, activeNoteId: 'n2', onNewNote: () {}),
        ),
      );
      expect(rowColor(tester, 'note-list-item-n2'), OmColors.surface4);
      expect(rowColor(tester, 'note-list-item-n1'), Colors.transparent);
      expect(rowColor(tester, 'note-list-item-n3'), Colors.transparent);
    });

    testWidgets('CanvasesRail highlights only the active canvas row', (
      tester,
    ) async {
      await _pump(
        tester,
        build: (_) => SizedBox(
          width: 268,
          child: CanvasesRail(canvases: _canvases, activeCanvasId: 'c1'),
        ),
      );
      expect(rowColor(tester, 'canvas-row-c1'), OmColors.surface4);
      expect(rowColor(tester, 'canvas-row-c2'), Colors.transparent);
    });

    testWidgets(
      'hovering a note or canvas row tints it until the mouse leaves',
      (tester) async {
        await _pump(
          tester,
          build: (h) => SizedBox(
            width: 268,
            height: 600,
            child: Column(
              children: [
                CanvasesRail(canvases: _canvases),
                Expanded(
                  child: NotesPane(notes: _notes, onNewNote: () {}),
                ),
              ],
            ),
          ),
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1100, 800));
        addTearDown(mouse.removePointer);

        for (final key in ['note-list-item-n1', 'canvas-row-c2']) {
          expect(rowColor(tester, key), Colors.transparent, reason: key);
          await mouse.moveTo(tester.getCenter(find.byKey(Key(key))));
          await tester.pump();
          expect(rowColor(tester, key), OmColors.surface3, reason: key);
          await mouse.moveTo(const Offset(1100, 800));
          await tester.pump();
          expect(rowColor(tester, key), Colors.transparent, reason: key);
        }
      },
    );
  });
}
