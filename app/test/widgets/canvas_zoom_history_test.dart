// WI #268 (N5): zooming into a note on a canvas is a Tab history entry, in the
// whole workspace. A double click navigates to `CanvasTab(id, zoomedNoteId:)`,
// Back and Forward zoom out and in, the "back to canvas" pill is gone, the
// editor loads the zoomed note on every entry into it, and deleting the note
// zooms the canvas out. The tab model itself is in
// `app/test/state/tabs_canvas_zoom_test.dart`.
//
// Never pumpAndSettle the workspace (OmDot pulses forever): pumpFrames only.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/canvas_state.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/app_harness.dart';
import '../support/canvas_seeds.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/note_cli_fakes.dart';

const _canvas = CanvasTab(C89.newer);
const _zoomedAlpha = CanvasTab(C89.newer, zoomedNoteId: C89.alpha);
const _zoomedBeta = CanvasTab(C89.newer, zoomedNoteId: C89.beta);

Finder get _canvasView => find.byKey(const Key('canvas-tab-${C89.newer}'));
Finder _zoomedView(String noteId) => find.byKey(Key('zoomed-$noteId'));
Finder _node(String noteId) => find.byKey(Key('canvas-node-$noteId'));
Finder get _pill => find.byKey(const Key('zoom-out-back-button'));

extension on WorkspaceHarness {
  TabsNotifier get tabs => read(tabsProvider.notifier);
  TabsState get tabState => read(tabsProvider);
  EditorStateValue get editor => read(editorControllerProvider);
}

/// The app on a vault with the canvas Newer holding the notes Alpha and Beta,
/// and zoom animations of no length. The only tab shows the canvas.
Future<WorkspaceHarness> _onCanvas(WidgetTester tester) async {
  final db = seedCanvasFixture(FakeVaultDb.v5());
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..onRm(db);
  final h = await pumpWorkspace(
    tester,
    db: db,
    cli: cli,
    overrides: [
      canvasAnimationConfigProvider.overrideWithValue(
        const CanvasAnimationConfig(zoomDuration: Duration.zero),
      ),
    ],
  );
  h.tabs.navigate(_canvas);
  await pumpFrames(tester);
  await pumpFrames(tester);
  expect(_canvasView, findsOneWidget, reason: 'the canvas is shown');
  return h;
}

/// Double clicks the node card of [noteId].
Future<void> _zoomInto(WidgetTester tester, String noteId) async {
  final at = tester.getCenter(_node(noteId));
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(at);
  await pumpFrames(tester);
}

void main() {
  group('double clicking a note', () {
    testWidgets(
      'double clicking a note on a canvas zooms into it as a new entry that back zooms out of and forward zooms back into',
      (tester) async {
        final h = await _onCanvas(tester);

        await _zoomInto(tester, C89.alpha);

        expect(h.tabState.activeTab, _zoomedAlpha);
        expect((h.tabState.activeTab! as CanvasTab).zoomedNoteId, C89.alpha);
        expect(_zoomedView(C89.alpha), findsOneWidget);
        expect(_canvasView, findsNothing);
        expect(h.editor.title, 'Alpha', reason: 'the editor shows the note');

        h.tabs.back();
        await pumpFrames(tester);
        expect(h.tabState.activeTab, _canvas);
        expect((h.tabState.activeTab! as CanvasTab).zoomedNoteId, isNull);
        expect(_canvasView, findsOneWidget);
        expect(_zoomedView(C89.alpha), findsNothing);
        expect(h.tabState.canGoForward, isTrue);

        h.tabs.forward();
        await pumpFrames(tester);
        expect(h.tabState.activeTab, _zoomedAlpha);
        expect((h.tabState.activeTab! as CanvasTab).zoomedNoteId, C89.alpha);
        expect(_zoomedView(C89.alpha), findsOneWidget);
        expect(_canvasView, findsNothing);
        expect(h.editor.title, 'Alpha', reason: 'Forward loads the note too');
      },
    );

    testWidgets(
      'the zoomed note shows no back to canvas pill and zooming from one note to another shows the other note',
      (tester) async {
        final h = await _onCanvas(tester);

        await _zoomInto(tester, C89.alpha);

        expect(_zoomedView(C89.alpha), findsOneWidget);
        expect(_pill, findsNothing);
        expect(find.byKey(const Key('editor-toolbar')), findsOneWidget);

        h.tabs.navigate(_zoomedBeta);
        await pumpFrames(tester);
        expect(_zoomedView(C89.beta), findsOneWidget);
        expect(_zoomedView(C89.alpha), findsNothing);
        expect(_pill, findsNothing);
        expect(h.editor.title, 'Beta');
      },
    );

    testWidgets(
      'following a link from a zoomed note navigates and the first back returns to the zoomed note with its editor and the next to the canvas',
      (tester) async {
        final h = await _onCanvas(tester);
        await _zoomInto(tester, C89.alpha);
        expect(h.tabState.activeTab, _zoomedAlpha);

        h.tabs.follow(const NoteTab(C89.gamma));
        await pumpFrames(tester);
        expect(h.tabState.activeTab, const NoteTab(C89.gamma));
        expect(h.editor.title, 'Gamma');

        h.tabs.back();
        await pumpFrames(tester);
        expect(h.tabState.activeTab, _zoomedAlpha);
        expect((h.tabState.activeTab! as CanvasTab).zoomedNoteId, C89.alpha);
        expect(_zoomedView(C89.alpha), findsOneWidget);
        expect(h.editor.title, 'Alpha', reason: 'Back loads the zoomed note');

        h.tabs.back();
        await pumpFrames(tester);
        expect(h.tabState.activeTab, _canvas);
        expect(_canvasView, findsOneWidget);
      },
    );

    testWidgets('two tabs on one canvas zoom independently', (tester) async {
      final h = await _onCanvas(tester);
      h.tabs.openOrFocus(const NoteTab(C89.gamma));
      await pumpFrames(tester);
      h.tabs.navigate(_canvas); // [canvas] [canvas*]
      await pumpFrames(tester);
      h.tabs.setActive(0);
      await pumpFrames(tester);
      expect(_canvasView, findsOneWidget);

      await _zoomInto(tester, C89.alpha); // [zoomedAlpha*] [canvas]

      expect(h.tabState.tabs, [_zoomedAlpha, _canvas]);
      expect(_zoomedView(C89.alpha), findsOneWidget);
      expect(_canvasView, findsNothing);

      h.tabs.setActive(1);
      await pumpFrames(tester);
      expect(_canvasView, findsOneWidget, reason: 'the other tab is unzoomed');
      expect(_zoomedView(C89.alpha), findsNothing);

      await _zoomInto(tester, C89.beta); // [zoomedAlpha] [zoomedBeta*]
      expect(h.tabState.tabs, [_zoomedAlpha, _zoomedBeta]);
      expect(_zoomedView(C89.beta), findsOneWidget);

      h.tabs.setActive(0);
      await pumpFrames(tester);
      expect(_zoomedView(C89.alpha), findsOneWidget);
      expect(_zoomedView(C89.beta), findsNothing);
      expect(h.editor.title, 'Alpha');
    });
  });

  group('selectedNoteIdProvider while zoomed', () {
    testWidgets(
      'while a tab is zoomed selectedNoteIdProvider holds the zoomed note id and after zooming out it holds null',
      (tester) async {
        final h = await _onCanvas(tester);
        expect(h.read(selectedNoteIdProvider), isNull);

        await _zoomInto(tester, C89.alpha);
        expect(h.read(selectedNoteIdProvider), C89.alpha);

        h.tabs.back();
        await pumpFrames(tester);
        expect(h.read(selectedNoteIdProvider), isNull);

        h.tabs.forward();
        await pumpFrames(tester);
        expect(h.read(selectedNoteIdProvider), C89.alpha);

        h.tabs.navigate(_zoomedBeta);
        await pumpFrames(tester);
        expect(h.read(selectedNoteIdProvider), C89.beta);
      },
    );

    testWidgets(
      'the zoomed note view does not write the selection once the tab shows another note',
      (tester) async {
        final h = await _onCanvas(tester);
        await _zoomInto(tester, C89.alpha);
        expect((h.tabState.activeTab! as CanvasTab).zoomedNoteId, C89.alpha);

        h.tabs.follow(const NoteTab(C89.gamma));
        await pumpFrames(tester);
        await pumpFrames(tester);

        expect(h.read(selectedNoteIdProvider), C89.gamma);
        h.tabs.back();
        await pumpFrames(tester);
        await pumpFrames(tester);
        h.tabs.back();
        await pumpFrames(tester);
        await pumpFrames(tester);
        expect(h.read(selectedNoteIdProvider), isNull);
      },
    );
  });

  group('deleting a zoomed note', () {
    testWidgets(
      'deleting a note zooms out a canvas tab zoomed into it without closing the tab and closes note tabs showing it',
      (tester) async {
        final h = await _onCanvas(tester);
        h.tabs.openOrFocus(const NoteTab(C89.alpha));
        await pumpFrames(tester);
        h.tabs.setActive(0);
        await pumpFrames(tester);
        await _zoomInto(tester, C89.alpha); // [zoomedAlpha*] [alpha]
        expect(h.tabState.tabs, [_zoomedAlpha, const NoteTab(C89.alpha)]);
        expect((h.tabState.tabs.first as CanvasTab).zoomedNoteId, C89.alpha);

        await tester.tap(find.byKey(const Key('note-menu-button')));
        await pumpFrames(tester);
        await tester.tap(find.byKey(const Key('note-menu-delete')));
        await pumpFrames(tester);
        await tester.tap(find.byKey(const Key('delete-note-confirm')));
        await pumpFrames(tester);
        await pumpFrames(tester);

        expect(h.cli.callsFor('rm'), hasLength(1));
        expect(h.tabState.tabs, [_canvas], reason: 'the note tab closed');
        expect((h.tabState.tabs.single as CanvasTab).zoomedNoteId, isNull);
        expect(_canvasView, findsOneWidget);
        expect(_zoomedView(C89.alpha), findsNothing);
        expect(h.read(selectedNoteIdProvider), isNull);
      },
    );
  });

  group('the zoom state and the pill are gone from the source', () {
    List<File> libFiles() => [
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File && f.path.endsWith('.dart')) f,
    ];

    test(
      'the pill and canvasZoomProvider are gone from lib and the zoomed note view writes no selection',
      () {
        final files = libFiles();
        expect(files, isNotEmpty, reason: 'the scan found lib/');
        final gone = RegExp(
          r'canvasZoomProvider|CanvasZoomState|onBackToCanvas|'
          r'_BackToCanvasButton|zoom-out-back-button',
        );
        final offenders = {
          for (final f in files)
            if (gone.allMatches(f.readAsStringSync()) case final m
                when m.isNotEmpty)
              f.path: m.map((x) => x.group(0)).toSet(),
        };
        expect(offenders, isEmpty);

        final workspace = files.singleWhere(
          (f) => f.path.endsWith('screens/workspace.dart'),
        );
        expect(
          workspace.readAsStringSync(),
          isNot(contains('selectedNoteIdProvider')),
          reason: 'the zoomed note view is not a writer of the selection',
        );
      },
    );
  });
}
