// WI #407 (SH; Spec #394 req 3, 4; D15): the editor status bar's Agents
// button and the ⇧⌘A rule. `_StatusBar`'s `agents API · ⌘;` label becomes
// the button `agents ⇧⌘A` (Key `status-bar-agents`, mono 10.5, fg2, fg0 on
// hover) that calls `openAgentsSheet`. No Flutter handler takes ⇧⌘A: the
// native Window menu does, so with focus in an editor field the key event
// goes back unhandled.
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../support/agents_sheet_harness.dart';
import '../support/font_fetch_hold.dart';

const _button = Key('status-bar-agents');

Note _note() => Note(
  id: 'n1',
  title: 'My Note',
  contentMd: 'one two three',
  frontmatter: '',
  version: 7,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

/// The note editor (with its status bar) as the page under the harness.
Future<AgentsSheetHarness> _pumpEditor(WidgetTester tester) async {
  final s = await pumpAgentsSheet(
    tester,
    open: false,
    size: const Size(1400, 900),
    host: NoteEditor(rightPanelOpen: false, onToggleRightPanel: () {}),
    overrides: [
      selectedNoteAsyncProvider.overrideWith(
        (ref) => VaultScoped(agentsSheetLocalVault, _note()),
      ),
      noteTitlesAsyncProvider.overrideWith(
        (ref) => const VaultScoped(agentsSheetLocalVault, <NoteTitle>[]),
      ),
      linkKindsAsyncProvider.overrideWith(
        (ref) => const VaultScoped(agentsSheetLocalVault, <String>[]),
      ),
    ],
  );
  // The editor hydrates in a post-frame callback.
  await tester.pump();
  await tester.pump();
  return s;
}

/// The button's label paragraph.
RenderParagraph _label(WidgetTester tester) => tester.renderObject(
  find.descendant(of: find.byKey(_button), matching: find.byType(RichText)),
);

Color? _labelColor(WidgetTester tester) =>
    _label(tester).text.style?.color ??
    (_label(tester).text as TextSpan).children?.first.style?.color;

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// ⇧⌘A as key events; returns whether the framework handled the A.
Future<bool> _pressShiftCmdA(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  final handled = await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  return handled;
}

void main() {
  holdFontFetches();

  group('status bar button (AC status bar)', () {
    testWidgets(
      'the status bar shows status-bar-agents labelled agents Shift Cmd A in mono 10.5 fg2 and the old label is gone',
      (tester) async {
        await _pumpEditor(tester);

        expect(find.byKey(_button), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('save-indicator')),
            matching: find.byKey(_button),
          ),
          findsOneWidget,
          reason: 'it sits in the status bar',
        );
        expect(_label(tester).text.toPlainText(), 'agents ⇧⌘A');
        final style = _label(tester).text.style!;
        expect(style.fontSize, 10.5);
        expect(_labelColor(tester)?.toARGB32(), OmColors.fg2.toARGB32());
        expect(find.textContaining('agents API'), findsNothing);
        expect(find.textContaining('⌘;'), findsNothing);
      },
    );

    testWidgets(
      'the status bar button turns fg0 while hovered and back to fg2 on exit',
      (tester) async {
        await _pumpEditor(tester);
        expect(find.byKey(_button), findsOneWidget);
        expect(_labelColor(tester)?.toARGB32(), OmColors.fg2.toARGB32());

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await tester.pump();

        await mouse.moveTo(tester.getCenter(find.byKey(_button)));
        await tester.pump();
        expect(_labelColor(tester)?.toARGB32(), OmColors.fg0.toARGB32());

        final r = tester.getRect(find.byKey(_button));
        await mouse.moveTo(Offset(r.left - 60, r.center.dy));
        await tester.pump();
        expect(_labelColor(tester)?.toARGB32(), OmColors.fg2.toARGB32());
      },
    );

    testWidgets('a tap on the status bar button opens the Agents sheet', (
      tester,
    ) async {
      final s = await _pumpEditor(tester);
      expect(find.byKey(_button), findsOneWidget);
      expect(agentsSheetFinder, findsNothing);

      await tester.tap(find.byKey(_button));
      await _frames(tester);
      await s.decide();

      expect(agentsSheetFinder, findsOneWidget);
      expect(s.routes.dialogs, hasLength(1));
    });

    testWidgets(
      'the status bar button is announced as a tappable agents button',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await _pumpEditor(tester);
        expect(find.byKey(_button), findsOneWidget);
        final node = tester.getSemantics(find.byKey(_button));
        expect(node.label, contains('agents ⇧⌘A'));
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        semantics.dispose();
      },
    );

    testWidgets(
      'closing a sheet opened from the status bar gives focus back to the editor title field',
      (tester) async {
        final s = await _pumpEditor(tester);
        await tester.tap(find.byKey(const Key('editor-title')));
        await tester.pump();
        final title = tester.widget<TextField>(
          find.byKey(const Key('editor-title')),
        );
        expect(title.focusNode?.hasFocus ?? true, isTrue);
        final focusedBefore = FocusManager.instance.primaryFocus;
        expect(find.byKey(_button), findsOneWidget);

        await tester.tap(find.byKey(_button));
        await _frames(tester);
        await s.decide();
        expect(agentsSheetFinder, findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _frames(tester);
        expect(agentsSheetFinder, findsNothing);
        expect(FocusManager.instance.primaryFocus, same(focusedBefore));
      },
    );
  });

  group('Shift Cmd A in the editor (AC no Dart handler)', () {
    testWidgets(
      'Shift Cmd A with focus in the editor title field returns ignored and opens no sheet',
      (tester) async {
        final s = await _pumpEditor(tester);
        await tester.tap(find.byKey(const Key('editor-title')));
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<EditableText>(),
          isNotNull,
          reason: 'focus is in an editor text field',
        );

        expect(await _pressShiftCmdA(tester), isFalse);
        await _frames(tester);
        expect(agentsSheetFinder, findsNothing);
        expect(s.routes.dialogs, isEmpty);
        expect(s.menuHost.openAgentsDelivered, 0);
      },
    );
  });
}
