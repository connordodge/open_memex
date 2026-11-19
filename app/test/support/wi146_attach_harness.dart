// WI #146 (Spec #123 A4): the attach action's test harness, shared by its
// controller, menu and journey tests. Owned by #146.
//
// It pumps the whole app (`pumpWorkspace`) on `seedSegmentedVault`'s vault
// plus two plain notes, with:
// - `attachmentsProvider` and the vault access's attachments domain both on
//   one [Wi146HeldAttachments] (a `FakeAttachmentsAccess` that can hold each
//   store until the test releases it);
// - `vaultAccessProvider` a `LocalVaultAccess` whose CLI follows
//   [wi146WritableProvider], so a test flips `VaultAccess.canWrite`;
// - the Command palette's production sources (`paletteShellOverrides`);
// - a `FakeFilePicker` as `FilePicker.platform`.
// The editor is read through its handles (`editor_rows_probe.dart`,
// `segment_editing_finder.dart`) and `editorControllerProvider`.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/attach_controller.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/attachments_access.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/command_palette/command_palette.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../robots/segmented_editor_robot.dart';
import 'app_harness.dart';
import 'attachments_fakes.dart';
import 'editor_rows_probe.dart';
import 'fake_clock.dart';
import 'file_picker_fakes.dart';
import 'segment_editing_finder.dart';

/// The plain note the attach tests work on.
const wi146NoteId = 'n-146-planning-notes';
const wi146NoteTitle = 'Planning notes';

/// A second plain note, to switch to.
const wi146OtherId = 'n-146-other-plans';
const wi146OtherBody = 'Other body';

/// The R12 example body.
const wi146Example = 'Review the draft\nNext steps';

/// The "Attach file…" item in the note's ⋯ menu.
const wi146MenuItemKey = Key('note-menu-attach-file');
const wi146MenuButtonKey = Key('note-menu-button');
const wi146MenuKey = Key('note-menu');

/// The exact copy (WI #146).
const wi146Label = 'Attach file…';

/// Picked paths (invented, never a home folder).
const wi146MockPath = '/vaults/Inbox/mock.png';
const wi146SpecPath = '/vaults/Inbox/spec.pdf';

/// The markdown line the fake domain stores for [name].
String wi146Line(String name) => fakeAddedAttachment(name).markdown;

/// Whether the vault's access has a CLI (`VaultAccess.canWrite`).
final wi146WritableProvider = StateProvider<bool>((_) => true);

/// A [FakeAttachmentsAccess] whose stores wait for the test while
/// [holding]: each `add`/`addBytes` is recorded at once and answers only
/// when [releaseNext] or [releaseAll] lets it.
class Wi146HeldAttachments extends FakeAttachmentsAccess {
  bool holding = false;
  final List<Completer<void>> _holds = [];

  /// Stores still waiting.
  int get pending => _holds.where((c) => !c.isCompleted).length;

  Future<AttachmentAddResult> _held(Future<AttachmentAddResult> result) async {
    if (!holding) return result;
    final hold = Completer<void>();
    _holds.add(hold);
    await hold.future;
    return result;
  }

  @override
  Future<AttachmentAddResult> add(String filePath, String? name) =>
      _held(super.add(filePath, name));

  @override
  Future<AttachmentAddResult> addBytes(Uint8List bytes, String name) =>
      _held(super.addBytes(bytes, name));

  /// Lets the oldest waiting store answer.
  void releaseNext() {
    for (final c in _holds) {
      if (!c.isCompleted) {
        c.complete();
        return;
      }
    }
    throw TestFailure('no store is waiting');
  }
}

/// Everything an attach test needs.
class Wi146Harness {
  Wi146Harness(this.tester, this.h, this.robot, this.attachments, this.picker);

  final WidgetTester tester;
  final WorkspaceHarness h;
  final SegmentedEditorRobot robot;
  final Wi146HeldAttachments attachments;
  final FakeFilePicker picker;

  /// Every new `contentMd` the editor reported, in order.
  final List<String> bodyChanges = [];

  /// The editor's current markdown (the whole note body).
  String get body => h.read(editorControllerProvider).contentMd;

  /// The note editor's context (under the app's ScaffoldMessenger).
  BuildContext get context => tester.element(find.byType(NoteEditor));

  AttachController get controller => h.read(attachControllerProvider);

  /// Releases every waiting store (also ones that start meanwhile) and
  /// pumps until none waits and the action has ended.
  Future<void> releaseAll() async {
    for (var i = 0; i < 20; i++) {
      while (attachments.pending > 0) {
        attachments.releaseNext();
      }
      await pumpFrames(tester);
      if (attachments.pending == 0) break;
    }
    await tester.pump(const Duration(seconds: 1));
    await pumpFrames(tester);
  }

  /// Opens [noteId] (default [wi146NoteId]) in the active tab.
  Future<void> open([String noteId = wi146NoteId]) async {
    await robot.open(noteId);
    await pumpFrames(tester);
  }

  /// Puts the live preview caret right after the first [text] in text
  /// segment [segment] (focusing the row holding it, as a click there
  /// would) and lets the editor settle.
  Future<void> caretAfter(String text, {int segment = 0}) async {
    final host = rowsHostOf(tester, segment);
    final at = host.text.indexOf(text);
    expect(at, isNonNegative, reason: '$text is in segment $segment');
    final offset = at + text.length;
    for (var i = 0; i < host.rowCount; i++) {
      final spec = host.rowSpec(i)!;
      if (offset < spec.textStart || offset > spec.textEnd) continue;
      await activateRow(tester, segment, i, offset: offset - spec.textStart);
      await tester.pump(const Duration(seconds: 1));
      expect(segmentEditingAt(tester, segment).selection.baseOffset, offset);
      return;
    }
    fail('no editor row of segment $segment holds offset $offset');
  }

  /// The content of [noteId] in the vault database.
  String storedContent(String noteId) =>
      h.db.db.select('SELECT content_md FROM notes WHERE id = ?', [
            noteId,
          ]).single['content_md']
          as String;

  /// The Source mode body field's controller.
  TextEditingController get sourceController => tester
      .widget<EditableText>(
        find.descendant(
          of: robot.sourceBody,
          matching: find.byType(EditableText),
          matchRoot: true,
        ),
      )
      .controller;

  /// Switches to Source mode, focuses the body field and puts the caret at
  /// [caret].
  Future<void> sourceCaret(int caret) async {
    if (robot.sourceSurface.evaluate().isEmpty) await robot.toggleSource();
    expect(robot.sourceSurface, findsOneWidget);
    await tester.showKeyboard(robot.sourceBody);
    await tester.pump();
    sourceController.selection = TextSelection.collapsed(offset: caret);
    await tester.pump();
  }

  /// Types into the focused Source field as the platform text system does:
  /// [value] replaces its value.
  Future<void> sourceInput(TextEditingValue value) async {
    tester.testTextInput.editingState = value.toJSON();
    tester.testTextInput.updateEditingValue(value);
    await tester.pump();
  }

  /// Opens the note's ⋯ menu.
  Future<void> openMenu() async {
    await tester.tap(find.byKey(wi146MenuButtonKey));
    await pumpFrames(tester);
    expect(find.byKey(wi146MenuKey), findsOneWidget, reason: 'menu is open');
  }

  /// Opens the ⋯ menu and chooses "Attach file…".
  Future<void> chooseMenuAttach() async {
    await openMenu();
    expect(find.byKey(wi146MenuItemKey), findsOneWidget);
    await tester.tap(find.byKey(wi146MenuItemKey));
    await pumpFrames(tester);
  }

  /// Shows the Command palette over the workspace, as the Command bar and
  /// Cmd+K do.
  Future<void> openPalette() async {
    unawaited(showCommandPalette(tester.element(find.byType(Workspace))));
    await pumpFrames(tester);
    expect(find.byKey(const Key('command-palette')), findsOneWidget);
  }

  /// The palette's Attach file row.
  Finder get paletteRow =>
      find.byKey(const Key('palette-row-command-attachFile'));

  /// Types [query] into the open palette.
  Future<void> typePalette(String query) async {
    await tester.enterText(find.byKey(const Key('palette-input')), query);
    await pumpFrames(tester);
  }

  /// Closes the open palette without a choice.
  void closePalette() => closeCommandPalette(h.container);

  /// Opens the palette, types `attach` and chooses the Attach file row.
  Future<void> choosePaletteAttach() async {
    await openPalette();
    await typePalette('attach');
    expect(paletteRow, findsOneWidget, reason: 'the command is listed');
    await tester.tap(paletteRow);
    await pumpFrames(tester);
  }

  /// The `pickFiles` calls the picker received.
  List<FakeFilePickerCall> get pickCalls => [
    for (final c in picker.calls)
      if (c.method == 'pickFiles') c,
  ];
}

/// Pumps the app on the attach vault: `seedSegmentedVault(topicBody:)`
/// plus [wi146NoteId] (`Planning notes`, [body]) and [wi146OtherId]. Opens
/// nothing; call [Wi146Harness.open].
Future<Wi146Harness> wi146Pump(
  WidgetTester tester, {
  String body = wi146Example,
  String? topicBody,
  FakeClock? clock,
  Size surfaceSize = const Size(1600, 1000),
}) async {
  final vault = topicBody == null
      ? seedSegmentedVault()
      : seedSegmentedVault(topicBody: topicBody);
  vault.db.seedNote(id: wi146NoteId, title: wi146NoteTitle, content: body);
  vault.db.seedNote(
    id: wi146OtherId,
    title: 'Other plans',
    content: wi146OtherBody,
  );
  final attachments = Wi146HeldAttachments();
  final picker = installFakeFilePicker();
  final h = await pumpWorkspace(
    tester,
    db: vault.db,
    cli: vault.cli,
    clock: clock,
    surfaceSize: surfaceSize,
    overrides: [
      attachmentsProvider.overrideWithValue(attachments),
      vaultAccessProvider.overrideWith((ref) {
        final path = ref.watch(currentVaultProvider).localPath;
        if (path == null) return null;
        return LocalVaultAccess(
          vaultPath: path,
          db: ref.watch(vaultDbProvider),
          cli: ref.watch(wi146WritableProvider)
              ? ref.watch(memexCliProvider)
              : null,
          attachments: attachments,
        );
      }),
      ...paletteShellOverrides,
    ],
  );
  final harness = Wi146Harness(
    tester,
    h,
    SegmentedEditorRobot(tester, h),
    attachments,
    picker,
  );
  h.container.listen<String>(
    editorControllerProvider.select((s) => s.contentMd),
    (_, next) => harness.bodyChanges.add(next),
  );
  return harness;
}
