// WI #19 (A2, D22): the note editor is split into single-owner files.
//
// These tests import the new public paths, so they fail to load on main
// (RED ON MAIN). They also pin that the split is behaviour-preserving: the
// debounced save, conflict handling, Keys, breadcrumb, meta rail, tags and
// wikilink autocomplete all still work through the new seams.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart'
    show
        LocalVaultRef,
        currentVaultProvider,
        linkKindsAsyncProvider,
        linkKindsProvider,
        memexCliProvider,
        noteTitlesAsyncProvider,
        noteTitlesProvider,
        selectedNoteAsyncProvider,
        selectedNoteProvider,
        vaultDbProvider,
        vaultRevisionProvider;
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/editor/daily_date_header.dart';
import 'package:open_memex_app/src/widgets/editor/editor_toolbar.dart';
import 'package:open_memex_app/src/widgets/editor/note_header.dart';
import 'package:open_memex_app/src/widgets/editor/note_menu.dart';
import 'package:open_memex_app/src/widgets/editor/review_chip.dart';
import 'package:open_memex_app/src/widgets/editor/source_surface.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _UpdateCall {
  _UpdateCall({
    required this.vaultPath,
    required this.noteId,
    required this.expectedVersion,
    required this.title,
    required this.contentMd,
  });
  final String vaultPath;
  final String noteId;
  final int expectedVersion;
  final String? title;
  final String contentMd;
}

/// MemexCli is a concrete class; this subclass records `updateNote` calls
/// and never shells out.
class _FakeCli extends MemexCli {
  _FakeCli() : super(binaryPath: '/nonexistent/memex-test-binary');

  final calls = <_UpdateCall>[];

  /// Version returned by the next successful save.
  int nextVersion = 8;

  /// When set, `updateNote` throws this after recording the call.
  Object? error;

  /// When set, `updateNote` waits on it before answering.
  Completer<void>? gate;

  @override
  Future<NoteUpdateResult> updateNote({
    required String vaultPath,
    required String noteId,
    required int expectedVersion,
    String? title,
    required String contentMd,
    bool withEmbeddings = false,
    bool noRenameLinks = false,
  }) async {
    calls.add(
      _UpdateCall(
        vaultPath: vaultPath,
        noteId: noteId,
        expectedVersion: expectedVersion,
        title: title,
        contentMd: contentMd,
      ),
    );
    final g = gate;
    if (g != null) await g.future;
    final e = error;
    if (e != null) throw e;
    return NoteUpdateResult(noteId: noteId, version: nextVersion, updatedAt: 1);
  }
}

/// Answers each `updateNote` call only when the test completes its entry in
/// [pending], so saves can overlap.
class _QueuedCli extends MemexCli {
  _QueuedCli() : super(binaryPath: '/nonexistent/memex-test-binary');

  final pending = <Completer<NoteUpdateResult>>[];

  @override
  Future<NoteUpdateResult> updateNote({
    required String vaultPath,
    required String noteId,
    required int expectedVersion,
    String? title,
    required String contentMd,
    bool withEmbeddings = false,
    bool noRenameLinks = false,
  }) {
    final c = Completer<NoteUpdateResult>();
    pending.add(c);
    return c.future;
  }
}

const _vaultPath = '/vaults/work';

Note _note({
  String id = 'n1',
  String title = 'My Note',
  String contentMd = 'one two three',
  int version = 7,
  List<String> tags = const ['alpha', 'beta'],
}) => Note(
  id: id,
  title: title,
  contentMd: contentMd,
  frontmatter: '',
  version: version,
  createdAt: 0,
  updatedAt: 0,
  tags: tags,
);

// ---------------------------------------------------------------------------
// Controller harness (AC 1-3)
// ---------------------------------------------------------------------------

ProviderContainer _container(MemexCli? cli, {String? vault = _vaultPath}) {
  final c = ProviderContainer(
    overrides: [
      memexCliProvider.overrideWithValue(cli),
      currentVaultProvider.overrideWith(
        (ref) => vault == null ? null : LocalVaultRef(vault),
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

// ---------------------------------------------------------------------------
// Widget harness (AC 4-7)
// ---------------------------------------------------------------------------

final _titles = [
  NoteTitle(id: 'n2', title: 'Other note', updatedAt: 0),
  NoteTitle(id: 'n3', title: 'Third note', updatedAt: 0),
];

class _Host {
  int rightToggles = 0;
  int backTaps = 0;
}

Future<_Host> _pumpEditor(
  WidgetTester tester, {
  required Note? note,
  _FakeCli? cli,
  bool rightPanelOpen = true,
  bool zoomedFromCanvas = false,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final host = _Host();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // #78 (D14a): the editor's widgets read the async providers; the
        // facades keep their overrides for the readers #105 converts.
        selectedNoteProvider.overrideWithValue(note),
        selectedNoteAsyncProvider.overrideWith(
          (ref) => VaultScoped(const LocalVaultRef(_vaultPath), note),
        ),
        currentVaultProvider.overrideWith((ref) => LocalVaultRef(_vaultPath)),
        memexCliProvider.overrideWithValue(cli ?? _FakeCli()),
        vaultDbProvider.overrideWithValue(null),
        noteTitlesProvider.overrideWithValue(_titles),
        noteTitlesAsyncProvider.overrideWith(
          (ref) => VaultScoped(const LocalVaultRef(_vaultPath), _titles),
        ),
        linkKindsProvider.overrideWithValue(const []),
        linkKindsAsyncProvider.overrideWith(
          (ref) => const VaultScoped(LocalVaultRef(_vaultPath), <String>[]),
        ),
      ],
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: NoteEditor(
            rightPanelOpen: rightPanelOpen,
            onToggleRightPanel: () => host.rightToggles++,
            onBackToCanvas: zoomedFromCanvas ? () => host.backTaps++ : null,
          ),
        ),
      ),
    ),
  );
  // The editor hydrates in a post-frame callback; one more frame renders it.
  await tester.pump();
  await tester.pump();
  return host;
}

/// Switch the body to the Source surface: the segmented view is the
/// default since WI #27.
Future<void> _showSource(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('editor-source-toggle')));
  await tester.pump();
}

Finder _toolbar() => find.byKey(const Key('editor-toolbar'));
Finder _header() => find.byKey(const Key('note-header'));
Finder _source() => find.byKey(const Key('editor-source-surface'));

Finder _in(Finder parent, Finder child) =>
    find.descendant(of: parent, matching: child);

/// The body field: the one TextField inside the source surface that is not
/// the title field.
Finder _bodyField() => find.descendant(
  of: _source(),
  matching: find.byWidgetPredicate(
    (w) => w is TextField && w.key != const Key('editor-title'),
  ),
);

void main() {
  // -------------------------------------------------------------------------
  // AC 1: EditorController & friends live in state/editor_controller.dart
  // -------------------------------------------------------------------------
  group('EditorController (state/editor_controller.dart)', () {
    testWidgets(
      'EditorController, editorControllerProvider, EditorStateValue and SaveStatus import from state/editor_controller.dart',
      (tester) async {
        final container = _container(_FakeCli());
        final EditorController controller = container.read(
          editorControllerProvider.notifier,
        );
        final EditorStateValue value = container.read(editorControllerProvider);
        expect(controller, isA<EditorController>());
        expect(value.status, SaveStatus.idle);
        expect(value.title, '');
        expect(value.contentMd, '');
        expect(value.lastSavedVersion, isNull);
        expect(SaveStatus.values, hasLength(6));
      },
    );

    testWidgets('loadNote hydrates a clean state at the note version', (
      tester,
    ) async {
      final container = _container(_FakeCli());
      final controller = container.read(editorControllerProvider.notifier);
      controller.loadNote(_note(version: 7));
      final s = container.read(editorControllerProvider);
      expect(s.status, SaveStatus.clean);
      expect(s.title, 'My Note');
      expect(s.contentMd, 'one two three');
      expect(s.lastSavedVersion, 7);

      controller.loadNote(null);
      final cleared = container.read(editorControllerProvider);
      expect(cleared.status, SaveStatus.idle);
      expect(cleared.title, '');
      expect(cleared.contentMd, '');
    });

    // -----------------------------------------------------------------------
    // AC 2: one save, 500 ms later, at the loaded version → clean
    // -----------------------------------------------------------------------
    testWidgets(
      'onContentChanged saves once 500 ms later with the loaded version and ends clean at the returned version',
      (tester) async {
        final cli = _FakeCli()..nextVersion = 8;
        final container = _container(cli);
        final controller = container.read(editorControllerProvider.notifier);
        final revisionBefore = container.read(vaultRevisionProvider);

        controller.loadNote(_note(version: 7));
        controller.onContentChanged('x');
        expect(
          container.read(editorControllerProvider).status,
          SaveStatus.dirty,
        );
        expect(container.read(editorControllerProvider).contentMd, 'x');

        await tester.pump(const Duration(milliseconds: 499));
        expect(cli.calls, isEmpty, reason: 'debounce is 500 ms, not shorter');

        await tester.pump(const Duration(milliseconds: 1));
        expect(cli.calls, hasLength(1));
        final call = cli.calls.single;
        expect(call.expectedVersion, 7);
        expect(call.noteId, 'n1');
        expect(call.vaultPath, _vaultPath);
        expect(call.contentMd, 'x');
        expect(call.title, 'My Note');

        await tester.pump();
        final s = container.read(editorControllerProvider);
        expect(s.status, SaveStatus.clean);
        expect(s.lastSavedVersion, 8);
        expect(s.errorMessage, isNull);
        expect(container.read(vaultRevisionProvider), revisionBefore + 1);

        // No second save fires later.
        await tester.pump(const Duration(seconds: 2));
        expect(cli.calls, hasLength(1));
      },
    );

    testWidgets(
      'a second change inside the window restarts the 500 ms debounce',
      (tester) async {
        final cli = _FakeCli();
        final container = _container(cli);
        final controller = container.read(editorControllerProvider.notifier);
        controller.loadNote(_note(version: 3));

        controller.onContentChanged('x');
        await tester.pump(const Duration(milliseconds: 300));
        controller.onContentChanged('xy');
        await tester.pump(const Duration(milliseconds: 499));
        expect(cli.calls, isEmpty);
        await tester.pump(const Duration(milliseconds: 1));
        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.contentMd, 'xy');
        expect(cli.calls.single.expectedVersion, 3);
        await tester.pump();
      },
    );

    testWidgets(
      'the next save uses the version returned by the previous save',
      (tester) async {
        final cli = _FakeCli()..nextVersion = 8;
        final container = _container(cli);
        final controller = container.read(editorControllerProvider.notifier);
        controller.loadNote(_note(version: 7));

        controller.onContentChanged('x');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        cli.nextVersion = 9;
        controller.onContentChanged('xy');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(cli.calls.map((c) => c.expectedVersion), [7, 8]);
        expect(container.read(editorControllerProvider).lastSavedVersion, 9);
      },
    );

    testWidgets('a change equal to the loaded body or title saves nothing', (
      tester,
    ) async {
      final cli = _FakeCli();
      final container = _container(cli);
      final controller = container.read(editorControllerProvider.notifier);
      controller.loadNote(_note());

      controller.onContentChanged('one two three');
      controller.onTitleChanged('My Note');
      expect(container.read(editorControllerProvider).status, SaveStatus.clean);
      await tester.pump(const Duration(seconds: 1));
      expect(cli.calls, isEmpty);
    });

    testWidgets('changes before any note is loaded are ignored', (
      tester,
    ) async {
      final cli = _FakeCli();
      final container = _container(cli);
      final controller = container.read(editorControllerProvider.notifier);

      controller.onContentChanged('x');
      controller.onTitleChanged('t');
      expect(container.read(editorControllerProvider).status, SaveStatus.idle);
      await tester.pump(const Duration(seconds: 1));
      expect(cli.calls, isEmpty);
    });

    testWidgets(
      'a title change saves the trimmed title; a blank title saves as null',
      (tester) async {
        final cli = _FakeCli();
        final container = _container(cli);
        final controller = container.read(editorControllerProvider.notifier);
        controller.loadNote(_note(version: 7));

        controller.onTitleChanged('  Renamed  ');
        expect(
          container.read(editorControllerProvider).status,
          SaveStatus.dirty,
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        expect(cli.calls.last.title, 'Renamed');
        expect(cli.calls.last.contentMd, 'one two three');

        controller.onTitleChanged('   ');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        expect(cli.calls, hasLength(2));
        expect(cli.calls.last.title, isNull);
      },
    );

    testWidgets('status is saving while updateNote is in flight', (
      tester,
    ) async {
      final cli = _FakeCli()..gate = Completer<void>();
      final container = _container(cli);
      final controller = container.read(editorControllerProvider.notifier);
      controller.loadNote(_note(version: 7));

      controller.onContentChanged('x');
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        container.read(editorControllerProvider).status,
        SaveStatus.saving,
      );

      cli.gate!.complete();
      await tester.pump();
      expect(container.read(editorControllerProvider).status, SaveStatus.clean);
    });

    testWidgets('no save is attempted without a CLI or an open vault', (
      tester,
    ) async {
      final noCli = _container(null);
      final c1 = noCli.read(editorControllerProvider.notifier);
      c1.loadNote(_note());
      c1.onContentChanged('x');
      await tester.pump(const Duration(seconds: 1));
      expect(noCli.read(editorControllerProvider).status, SaveStatus.dirty);

      final cli = _FakeCli();
      final noVault = _container(cli, vault: null);
      final c2 = noVault.read(editorControllerProvider.notifier);
      c2.loadNote(_note());
      c2.onContentChanged('x');
      await tester.pump(const Duration(seconds: 1));
      expect(cli.calls, isEmpty);
      expect(noVault.read(editorControllerProvider).status, SaveStatus.dirty);
    });

    // -----------------------------------------------------------------------
    // AC 3: version conflict → SaveStatus.conflict, message kept
    // -----------------------------------------------------------------------
    testWidgets(
      'a version-conflict MemexException ends in SaveStatus.conflict and keeps the message',
      (tester) async {
        final cli = _FakeCli()
          ..error = MemexException(
            'update failed: version conflict (expected 7, found 9)',
            kind: MemexErrorKind.versionConflict,
          );
        final container = _container(cli);
        final controller = container.read(editorControllerProvider.notifier);
        final revisionBefore = container.read(vaultRevisionProvider);
        controller.loadNote(_note(version: 7));

        controller.onContentChanged('x');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(cli.calls, hasLength(1));
        final s = container.read(editorControllerProvider);
        expect(s.status, SaveStatus.conflict);
        expect(
          s.errorMessage,
          'update failed: version conflict (expected 7, found 9)',
        );
        expect(
          s.lastSavedVersion,
          7,
          reason: 'a failed save keeps the version',
        );
        expect(container.read(vaultRevisionProvider), revisionBefore);
      },
    );

    testWidgets('any other MemexException ends in SaveStatus.error', (
      tester,
    ) async {
      final cli = _FakeCli()
        ..error = MemexException('update failed: disk full');
      final container = _container(cli);
      final controller = container.read(editorControllerProvider.notifier);
      controller.loadNote(_note());

      controller.onContentChanged('x');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final s = container.read(editorControllerProvider);
      expect(s.status, SaveStatus.error);
      expect(s.errorMessage, 'update failed: disk full');
    });

    testWidgets('a non-Memex error ends in SaveStatus.error with its text', (
      tester,
    ) async {
      final cli = _FakeCli()..error = StateError('boom');
      final container = _container(cli);
      final controller = container.read(editorControllerProvider.notifier);
      controller.loadNote(_note());

      controller.onContentChanged('x');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final s = container.read(editorControllerProvider);
      expect(s.status, SaveStatus.error);
      expect(s.errorMessage, contains('boom'));
    });

    testWidgets('the next edit after a failed save clears the error message', (
      tester,
    ) async {
      final cli = _FakeCli()
        ..error = MemexException(
          'conflict',
          kind: MemexErrorKind.versionConflict,
        );
      final container = _container(cli);
      final controller = container.read(editorControllerProvider.notifier);
      controller.loadNote(_note());
      controller.onContentChanged('x');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(container.read(editorControllerProvider).errorMessage, 'conflict');

      cli.error = null;
      controller.onContentChanged('xy');
      final s = container.read(editorControllerProvider);
      expect(s.status, SaveStatus.dirty);
      expect(s.errorMessage, isNull);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(container.read(editorControllerProvider).status, SaveStatus.clean);
    });

    testWidgets(
      'a save that answers after another note was loaded is ignored',
      (tester) async {
        for (final failing in [false, true]) {
          final cli = _FakeCli()..gate = Completer<void>();
          if (failing) {
            cli.error = MemexException(
              'stale',
              kind: MemexErrorKind.versionConflict,
            );
          }
          final container = _container(cli);
          final controller = container.read(editorControllerProvider.notifier);
          controller.loadNote(_note(id: 'n1', version: 7));
          controller.onContentChanged('x');
          await tester.pump(const Duration(milliseconds: 500));
          expect(cli.calls, hasLength(1));

          controller.loadNote(
            _note(id: 'n2', title: 'Second', contentMd: 'b', version: 2),
          );
          cli.gate!.complete();
          await tester.pump();

          final s = container.read(editorControllerProvider);
          expect(s.status, SaveStatus.clean, reason: 'failing=$failing');
          expect(s.lastSavedVersion, 2, reason: 'failing=$failing');
          expect(s.title, 'Second');
          expect(s.errorMessage, isNull);
        }
      },
    );

    testWidgets('loading another note cancels a pending save', (tester) async {
      final cli = _FakeCli();
      final container = _container(cli);
      final controller = container.read(editorControllerProvider.notifier);
      controller.loadNote(_note(id: 'n1'));
      controller.onContentChanged('x');
      controller.loadNote(_note(id: 'n2', version: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(cli.calls, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // AC 4: toolbar (editor-toolbar) keeps breadcrumb, save indicator, toggle
  // -------------------------------------------------------------------------
  group('EditorToolbar (widgets/editor/editor_toolbar.dart)', () {
    testWidgets(
      'the editor toolbar renders with Key editor-toolbar and keeps the breadcrumb, save indicator and right-panel toggle',
      (tester) async {
        final host = await _pumpEditor(tester, note: _note());

        expect(_toolbar(), findsOneWidget);
        expect(
          _in(find.byType(NoteEditor), find.byType(EditorToolbar)),
          findsOneWidget,
        );
        expect(_in(find.byType(EditorToolbar), _toolbar()), findsOneWidget);

        // Breadcrumb: vault name / note title.md
        expect(_in(_toolbar(), find.text('work')), findsOneWidget);
        expect(_in(_toolbar(), find.text('My Note.md')), findsOneWidget);

        // Save indicator still present and reports the hydrated state.
        expect(find.byKey(const Key('save-indicator')), findsOneWidget);
        expect(
          _in(find.byKey(const Key('save-indicator')), find.text('saved')),
          findsOneWidget,
        );

        // Right-panel toggle still lives in the toolbar and still toggles.
        final toggle = _in(_toolbar(), find.byIcon(LucideIcons.atom));
        expect(toggle, findsOneWidget);
        await tester.tap(toggle);
        await tester.pump();
        expect(host.rightToggles, 1);
      },
    );

    testWidgets(
      'the toolbar shows no breadcrumb and no back button without a note',
      (tester) async {
        await _pumpEditor(tester, note: null);
        expect(_toolbar(), findsOneWidget);
        expect(_in(_toolbar(), find.textContaining('.md')), findsNothing);
        expect(find.byKey(const Key('zoom-out-back-button')), findsNothing);
        expect(find.text('select a note from the sidebar'), findsOneWidget);
        expect(find.byKey(const Key('save-indicator')), findsOneWidget);
        expect(
          _in(find.byKey(const Key('save-indicator')), find.text('idle')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'the toolbar keeps zoom-out-back-button when zoomed from a canvas',
      (tester) async {
        final host = await _pumpEditor(
          tester,
          note: _note(),
          zoomedFromCanvas: true,
        );
        final back = _in(
          _toolbar(),
          find.byKey(const Key('zoom-out-back-button')),
        );
        expect(back, findsOneWidget);
        await tester.tap(back);
        await tester.pump();
        expect(host.backTaps, 1);
      },
    );

    testWidgets(
      'a save conflict shows the conflict chip in the toolbar and the indicator',
      (tester) async {
        final cli = _FakeCli()
          ..error = MemexException(
            'update failed: version conflict',
            kind: MemexErrorKind.versionConflict,
          );
        await _pumpEditor(tester, note: _note(), cli: cli);
        await _showSource(tester);

        await tester.enterText(_bodyField(), 'changed body');
        await tester.pump();
        expect(
          _in(find.byKey(const Key('save-indicator')), find.text('unsaved')),
          findsOneWidget,
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(cli.calls, hasLength(1));
        expect(_in(_toolbar(), find.text('CONFLICT — RELOAD')), findsOneWidget);
        expect(
          _in(find.byKey(const Key('save-indicator')), find.text('conflict')),
          findsOneWidget,
        );
        expect(find.text('update failed: version conflict'), findsOneWidget);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC 5: ellipsis button (note-menu-button) opens an empty NoteMenu
  // -------------------------------------------------------------------------
  group('NoteMenu (widgets/editor/note_menu.dart)', () {
    testWidgets(
      'the ellipsis button note-menu-button is enabled and opens an empty NoteMenu popup with Key note-menu',
      (tester) async {
        await _pumpEditor(tester, note: _note());

        final button = _in(
          _toolbar(),
          find.byKey(const Key('note-menu-button')),
        );
        expect(button, findsOneWidget);
        expect(
          _in(button, find.byIcon(LucideIcons.ellipsis)),
          findsOneWidget,
          reason: 'the existing ellipsis button is the menu button',
        );
        expect(find.byKey(const Key('note-menu')), findsNothing);
        expect(find.byType(NoteMenu), findsNothing);

        await tester.tap(button);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byKey(const Key('note-menu')), findsOneWidget);
        expect(find.byType(NoteMenu), findsOneWidget);
        expect(
          _in(find.byType(NoteMenu), find.byKey(const Key('note-menu'))),
          findsOneWidget,
        );
        // Items are added by later WIs (#31 Delete note, #30 Open graph);
        // their own tests pin them, so the menu is no longer asserted empty.
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC 6: note header (note-header) with title, tags, meta rail and slots
  // -------------------------------------------------------------------------
  group('NoteHeader (widgets/editor/note_header.dart)', () {
    testWidgets(
      'the note header renders with Key note-header and holds the title, tags, meta rail and empty DailyDateHeader and ReviewChip slots',
      (tester) async {
        await _pumpEditor(tester, note: _note());

        expect(_header(), findsOneWidget);
        expect(_in(find.byType(NoteHeader), _header()), findsOneWidget);

        // Title field, hydrated with the note title.
        final title = _in(_header(), find.byKey(const Key('editor-title')));
        expect(title, findsOneWidget);
        expect(tester.widget<TextField>(title).controller!.text, 'My Note');

        // Tags.
        expect(_in(_header(), find.text('#alpha')), findsOneWidget);
        expect(_in(_header(), find.text('#beta')), findsOneWidget);

        // Meta rail: relative update time + word count.
        expect(_in(_header(), find.textContaining('updated ')), findsOneWidget);
        expect(_in(_header(), find.text('3 words')), findsOneWidget);

        // Empty slots for #22 and #29.
        final daily = _in(_header(), find.byType(DailyDateHeader));
        final review = _in(_header(), find.byType(ReviewChip));
        expect(daily, findsOneWidget);
        expect(review, findsOneWidget);
        expect(_in(daily, find.byType(Text)), findsNothing);
        expect(_in(review, find.byType(Text)), findsNothing);
        expect(_in(daily, find.byType(Icon)), findsNothing);
        expect(_in(review, find.byType(Icon)), findsNothing);
        expect(tester.getSize(daily).height, 0);
        expect(tester.getSize(review).height, 0);
      },
    );

    testWidgets('a note without tags renders no tag text in the header', (
      tester,
    ) async {
      await _pumpEditor(tester, note: _note(tags: const []));
      expect(_header(), findsOneWidget);
      expect(_in(_header(), find.textContaining('#')), findsNothing);
    });

    testWidgets('editing the header title saves the new title', (tester) async {
      final cli = _FakeCli();
      await _pumpEditor(tester, note: _note(version: 7), cli: cli);

      await tester.enterText(
        _in(_header(), find.byKey(const Key('editor-title'))),
        'Renamed',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(cli.calls, hasLength(1));
      expect(cli.calls.single.title, 'Renamed');
      expect(cli.calls.single.expectedVersion, 7);
    });
  });

  // -------------------------------------------------------------------------
  // AC 7: SourceSurface (editor-source-surface), one plain body TextField,
  // wikilink autocomplete on [[
  // -------------------------------------------------------------------------
  group('SourceSurface (widgets/editor/source_surface.dart)', () {
    testWidgets(
      'SourceSurface with Key editor-source-surface renders the note body in one plain TextField',
      (tester) async {
        await _pumpEditor(
          tester,
          note: _note(contentMd: 'body line one\nbody line two'),
        );
        await _showSource(tester);

        expect(_source(), findsOneWidget);
        expect(_in(find.byType(SourceSurface), _source()), findsOneWidget);
        expect(
          _in(find.byType(NoteEditor), find.byType(SourceSurface)),
          findsOneWidget,
        );

        final body = _bodyField();
        expect(body, findsOneWidget, reason: 'exactly one body field');
        final field = tester.widget<TextField>(body);
        expect(field.controller!.text, 'body line one\nbody line two');
        expect(field.maxLines, isNull, reason: 'plain multi-line field');
      },
    );

    testWidgets('no SourceSurface is shown when no note is selected', (
      tester,
    ) async {
      await _pumpEditor(tester, note: null);
      expect(_source(), findsNothing);
      expect(find.byType(SourceSurface), findsNothing);
      expect(_header(), findsNothing);
    });

    testWidgets(
      'wikilink autocomplete still opens on [[ inside SourceSurface',
      (tester) async {
        await _pumpEditor(tester, note: _note());
        await _showSource(tester);
        expect(find.byKey(const Key('wikilink-popover')), findsNothing);

        await tester.enterText(_bodyField(), 'see [[');
        await tester.pump();

        expect(find.byKey(const Key('wikilink-popover')), findsOneWidget);
        expect(
          find.byKey(const Key('wikilink-popover-item-Other note')),
          findsOneWidget,
        );

        // Let the debounced save fire so no timer is left pending.
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
      },
    );

    testWidgets(
      'typing in SourceSurface saves the body through the controller',
      (tester) async {
        final cli = _FakeCli();
        await _pumpEditor(tester, note: _note(version: 7), cli: cli);
        await _showSource(tester);

        await tester.enterText(_bodyField(), 'new body');
        await tester.pump(const Duration(milliseconds: 499));
        expect(cli.calls, isEmpty);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();

        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.contentMd, 'new body');
        expect(cli.calls.single.expectedVersion, 7);
        expect(
          _in(find.byKey(const Key('save-indicator')), find.text('saved')),
          findsOneWidget,
        );
      },
    );

    testWidgets('Escape closes the wikilink popover inside SourceSurface', (
      tester,
    ) async {
      await _pumpEditor(tester, note: _note());
      await _showSource(tester);
      await tester.enterText(_bodyField(), 'see [[');
      await tester.pump();
      expect(find.byKey(const Key('wikilink-popover')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('wikilink-popover')), findsNothing);

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    });
  });

  // -------------------------------------------------------------------------
  // Implementer additions: behaviour of moved code (mutation coverage).
  // -------------------------------------------------------------------------
  group('Moved editor details', () {
    testWidgets('the breadcrumb dims the vault name and has one separator', (
      tester,
    ) async {
      await _pumpEditor(tester, note: _note());
      final vault = tester.widget<Text>(_in(_toolbar(), find.text('work')));
      final file = tester.widget<Text>(
        _in(_toolbar(), find.text('My Note.md')),
      );
      expect(vault.style!.color, OmColors.fg3);
      expect(file.style!.color, OmColors.fg1);
      expect(_in(_toolbar(), find.text('/')), findsOneWidget);
    });

    testWidgets('the right-panel toggle reflects whether the panel is open', (
      tester,
    ) async {
      Color? atomColor() => tester
          .widget<Icon>(_in(_toolbar(), find.byIcon(LucideIcons.atom)))
          .color;
      await _pumpEditor(tester, note: _note(), rightPanelOpen: true);
      expect(atomColor(), OmColors.fg0);
      await _pumpEditor(tester, note: _note(), rightPanelOpen: false);
      expect(atomColor(), OmColors.fg2);
    });

    testWidgets(
      'the toolbar shows the save-failed chip only after a failed save',
      (tester) async {
        final cli = _FakeCli()..error = MemexException('update failed: disk');
        await _pumpEditor(tester, note: _note(), cli: cli);
        await _showSource(tester);
        expect(_in(_toolbar(), find.text('SAVE FAILED')), findsNothing);
        expect(_in(_toolbar(), find.text('CONFLICT — RELOAD')), findsNothing);

        await tester.enterText(_bodyField(), 'changed body');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        expect(_in(_toolbar(), find.text('SAVE FAILED')), findsOneWidget);
        expect(_in(_toolbar(), find.text('CONFLICT — RELOAD')), findsNothing);
      },
    );

    testWidgets('a second tap on note-menu-button closes the NoteMenu', (
      tester,
    ) async {
      await _pumpEditor(tester, note: _note());
      final button = find.byKey(const Key('note-menu-button'));
      await tester.tap(button);
      await tester.pump();
      expect(find.byType(NoteMenu), findsOneWidget);
      await tester.tap(button);
      await tester.pump();
      expect(find.byType(NoteMenu), findsNothing);
    });

    testWidgets('note-menu-button is disabled when no note is open', (
      tester,
    ) async {
      await _pumpEditor(tester, note: null);
      final button = find.byKey(const Key('note-menu-button'));
      expect(button, findsOneWidget);
      expect(tester.widget<OmButton>(button).onPressed, isNull);
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      expect(find.byType(NoteMenu), findsNothing);
    });

    testWidgets('a title edit after a failed save clears the error message', (
      tester,
    ) async {
      final cli = _FakeCli()
        ..error = MemexException(
          'conflict',
          kind: MemexErrorKind.versionConflict,
        );
      final container = _container(cli);
      final controller = container.read(editorControllerProvider.notifier);
      controller.loadNote(_note());
      controller.onContentChanged('x');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(container.read(editorControllerProvider).errorMessage, 'conflict');

      cli.error = null;
      controller.onTitleChanged('Renamed');
      final s = container.read(editorControllerProvider);
      expect(s.status, SaveStatus.dirty);
      expect(s.errorMessage, isNull);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    });

    testWidgets(
      'a save that succeeds after an overlapping save failed ends without an error',
      (tester) async {
        final cli = _QueuedCli();
        final container = _container(cli);
        final controller = container.read(editorControllerProvider.notifier);
        controller.loadNote(_note(version: 7));

        // Save 1 goes out and stays in flight.
        controller.onContentChanged('x');
        await tester.pump(const Duration(milliseconds: 500));
        // Save 2 goes out while save 1 is still pending.
        controller.onContentChanged('xy');
        await tester.pump(const Duration(milliseconds: 500));
        expect(cli.pending, hasLength(2));

        cli.pending[0].completeError(
          MemexException('conflict', kind: MemexErrorKind.versionConflict),
        );
        await tester.pump();
        expect(
          container.read(editorControllerProvider).errorMessage,
          'conflict',
        );

        cli.pending[1].complete(
          NoteUpdateResult(noteId: 'n1', version: 8, updatedAt: 1),
        );
        await tester.pump();
        final s = container.read(editorControllerProvider);
        expect(s.status, SaveStatus.clean);
        expect(s.lastSavedVersion, 8);
        expect(s.errorMessage, isNull);
      },
    );

    testWidgets(
      'moving the caret to the start of the body hides the kind chip',
      (tester) async {
        await _pumpEditor(tester, note: _note());
        await _showSource(tester);
        await tester.enterText(_bodyField(), 'see [[');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        final body = tester.widget<TextField>(_bodyField()).controller!;
        expect(body.text, startsWith('see [[Other note'));
        expect(find.byKey(const Key('kind-chip')), findsOneWidget);

        body.selection = const TextSelection.collapsed(offset: 0);
        await tester.pump();
        expect(find.byKey(const Key('kind-chip')), findsNothing);

        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
      },
    );

    test('formatUpdatedAgo buckets minutes, hours and days', () {
      final now = DateTime.utc(2026, 10, 3, 12);
      final t = now.millisecondsSinceEpoch;
      String ago(int ms) => formatUpdatedAgo(t - ms, now: now);
      const min = 60 * 1000;
      const hour = 60 * min;
      const day = 24 * hour;
      expect(ago(0), 'just now');
      expect(ago(min - 1), 'just now');
      expect(ago(min), '1 minute ago');
      expect(ago(2 * min), '2 minutes ago');
      expect(ago(hour - 1), '59 minutes ago');
      expect(ago(hour), '1 hour ago');
      expect(ago(2 * hour), '2 hours ago');
      expect(ago(day - 1), '23 hours ago');
      expect(ago(day), '1 day ago');
      expect(ago(3 * day), '3 days ago');
    });

    test('noteWordCount counts whitespace-separated words', () {
      expect(noteWordCount(''), 0);
      expect(noteWordCount('   \n '), 0);
      expect(noteWordCount('one'), 1);
      expect(noteWordCount('  one\ttwo\n\nthree  '), 3);
    });
  });
}
