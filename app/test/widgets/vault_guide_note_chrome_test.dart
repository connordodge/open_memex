// WI #262 (F10): what a `role: guide` note looks like when it is open: a
// read-only title (Key `guide-title`, no `editor-title`), and a note menu
// without `Delete note` and `Open graph`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/widgets/editor/note_menu.dart';

import '../support/app_harness.dart';
import '../support/review_fakes.dart';
import '../support/topics_seed.dart';
import '../support/vault_guide_fixture.dart';

const _guideTitle = Key('guide-title');
const _editorTitle = Key('editor-title');
const _menuButton = Key('note-menu-button');
const _menuDelete = Key('note-menu-delete');
const _menuGraph = Key('note-menu-open-graph');

Future<GuideEnv> _openNote(WidgetTester tester, String id) async {
  final env = await launchGuideWorkspace(tester, topicsMode: false);
  await openNoteTab(tester, env.h, id);
  return env;
}

Future<void> _openMenu(WidgetTester tester) async {
  final button = find.byKey(_menuButton);
  expect(button, findsOneWidget, reason: 'the note menu button');
  await tester.tap(button);
  await pumpFrames(tester);
  expect(find.byKey(const Key('note-menu')), findsOneWidget);
}

/// Opens the guide first (so each guard below also needs the guide's own
/// behaviour), then [id] in the same workspace.
Future<GuideEnv> _openGuideThen(WidgetTester tester, String id) async {
  final env = await launchGuideWorkspace(tester, topicsMode: false);
  await openNoteTab(tester, env.h, guideNoteId);
  expect(find.byKey(_guideTitle), findsOneWidget);
  await openNoteTab(tester, env.h, id);
  return env;
}

/// The note menu is open and the guide's menu lacks `Delete note`, then the
/// menu of [id] is opened.
Future<void> _guideMenuThen(WidgetTester tester, String id) async {
  final env = await launchGuideWorkspace(tester, topicsMode: false);
  await openNoteTab(tester, env.h, guideNoteId);
  await tester.tap(find.byKey(_menuButton));
  await pumpFrames(tester);
  expect(find.byKey(_menuDelete), findsNothing);
  await tester.tapAt(const Offset(2, 2));
  await pumpFrames(tester);
  await openNoteTab(tester, env.h, id);
  await tester.tap(find.byKey(_menuButton));
  await pumpFrames(tester);
}

void main() {
  group('read-only title (AC3)', () {
    testWidgets(
      'a guide note shows the read-only guide-title and no editor-title field',
      (tester) async {
        await _openNote(tester, guideNoteId);

        expect(find.byKey(_guideTitle), findsOneWidget);
        expect(find.byKey(_editorTitle), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('note-header')),
            matching: find.text(guideNoteTitle),
          ),
          findsOneWidget,
          reason: 'the title text is still shown',
        );
      },
    );

    testWidgets('the guide title cannot be edited', (tester) async {
      final env = await _openNote(tester, guideNoteId);
      expect(find.byKey(_guideTitle), findsOneWidget);

      // Whatever widget draws the title, none of its text fields accepts input.
      final fields = tester.widgetList<EditableText>(
        find.descendant(
          of: find.byKey(_guideTitle),
          matching: find.byType(EditableText),
        ),
      );
      for (final f in fields) {
        expect(f.readOnly, isTrue);
      }
      await tester.tap(find.byKey(_guideTitle));
      await pumpFrames(tester);
      tester.testTextInput.enterText('Renamed guide');
      await pumpFrames(tester);

      expect(env.h.read(editorControllerProvider).title, guideNoteTitle);
      expect(find.text('Renamed guide'), findsNothing);
    });

    testWidgets('a topic note still shows the editable editor-title', (
      tester,
    ) async {
      await _openGuideThen(tester, TP.loop);

      expect(find.byKey(_editorTitle), findsOneWidget);
      expect(find.byKey(_guideTitle), findsNothing);
    });

    testWidgets('a role-less note still shows the editable editor-title', (
      tester,
    ) async {
      await _openGuideThen(tester, TP.looseNote);

      expect(find.byKey(_editorTitle), findsOneWidget);
      expect(find.byKey(_guideTitle), findsNothing);
    });

    testWidgets('a daily note shows neither title field', (tester) async {
      await _openGuideThen(tester, 'daily-2026-10-02');

      expect(find.byKey(_editorTitle), findsNothing);
      expect(find.byKey(_guideTitle), findsNothing);
    });
  });

  group('note menu on the guide (AC4)', () {
    testWidgets('the note menu of a guide offers no Delete note', (
      tester,
    ) async {
      await _openNote(tester, guideNoteId);
      await _openMenu(tester);

      expect(find.byKey(_menuDelete), findsNothing);
      expect(find.text('Delete note'), findsNothing);
    });

    testWidgets('the note menu of a guide offers no Open graph', (
      tester,
    ) async {
      await _openNote(tester, guideNoteId);
      await _openMenu(tester);

      expect(find.byKey(_menuGraph), findsNothing);
      expect(find.text('Open graph'), findsNothing);
    });

    testWidgets(
      'the note menu of a topic note keeps Delete note and Open graph',
      (tester) async {
        await _guideMenuThen(tester, TP.loop);

        expect(find.byKey(_menuDelete), findsOneWidget);
        expect(find.byKey(_menuGraph), findsOneWidget);
      },
    );

    testWidgets('the note menu of a role-less note keeps Delete note', (
      tester,
    ) async {
      await _guideMenuThen(tester, TP.looseNote);

      expect(find.byKey(_menuDelete), findsOneWidget);
      expect(find.byKey(_menuGraph), findsNothing);
    });

    testWidgets(
      'the note menu of a daily note keeps Delete note and Open graph',
      (tester) async {
        await _guideMenuThen(tester, 'daily-2026-10-02');

        expect(find.byKey(_menuDelete), findsOneWidget);
        expect(find.byKey(_menuGraph), findsOneWidget);
      },
    );

    test('graphScopeFor gives a guide note no Graph scope', () {
      final guide = Note(
        id: guideNoteId,
        title: guideNoteTitle,
        contentMd: guideBody,
        frontmatter: '{"role":"guide"}',
        version: guideVersion,
        createdAt: 1,
        updatedAt: 1,
        tags: const [],
      );

      expect(guide.role, 'guide');
      expect(NoteMenu.graphScopeFor(guide), isNull);
    });
  });
}
