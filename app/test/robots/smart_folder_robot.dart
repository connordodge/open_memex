import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/topics_state.dart';

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/folder_cli_fakes.dart';
import 'topics_robot.dart';

/// Robot for Smart Folder management in the Topics sidebar (WI #25). Reuses
/// [TopicsRobot] (#24) for the tree finders and adds the WI's stable Keys:
///
/// - header: `topics-new-folder`, `topics-graph-action`,
///   `topics-vault-settings` (opens the per-vault settings surface);
/// - folder rows: `folder-row-<id>` (drop target), `folder-menu-<id>` (opens
///   the folder edit menu); menu items `folder-menu-rename`,
///   `folder-menu-move`, `folder-menu-pinned`, `folder-menu-delete`,
///   `folder-menu-open-graph`;
/// - membership context menu: secondary tap (right click) on a topic row
///   `topics-topic-<folderId>-<noteId>`, item
///   `membership-menu-pinned-<folderId>-<noteId>`;
/// - name dialog (new / rename): `folder-name-dialog`, `folder-name-field`,
///   `folder-name-confirm`, `folder-name-cancel`;
/// - move picker: `folder-move-dialog`, `folder-move-target-<id>`,
///   `folder-move-target-root`;
/// - delete confirmation: `folder-delete-dialog`, `folder-delete-confirm`,
///   `folder-delete-cancel`;
/// - depth dialog: `depth-dialog`, `depth-dialog-confirm`,
///   `depth-dialog-cancel`;
/// - vault settings: `vault-settings-dialog`, `vault-settings-depth` (text
///   field), `vault-settings-save`;
/// - errors: `inline-error`, `inline-error-dismiss`.
///
/// Tapping a folder row (`topics-folder-<id>`) selects that folder: `+ New
/// Smart Folder` then creates inside it. With no folder tapped it creates at
/// root.
class SmartFolderRobot {
  SmartFolderRobot(this.tester) : topics = TopicsRobot(tester);

  final WidgetTester tester;
  final TopicsRobot topics;
  late WorkspaceHarness h;
  late FolderCliFake server;

  FakeMemexCli get cli => h.cli;

  /// Launch the workspace on [db] with the folder / settings server fake
  /// installed, then switch the sidebar to Topics mode.
  Future<WorkspaceHarness> launch({required FakeVaultDb db}) async {
    final cli = FakeMemexCli();
    server = FolderCliFake(db)..install(cli);
    h = await pumpWorkspace(
      tester,
      db: db,
      cli: cli,
      surfaceSize: const Size(1600, 1400),
    );
    topics.h = h;
    await topics.chooseTopics();
    return h;
  }

  // ---------------------------------------------------------------- finders

  Finder byKey(String k) => find.byKey(Key(k));

  Finder get pane => topics.pane;
  Finder get newFolderButton => byKey('topics-new-folder');
  Finder get graphAction => byKey('topics-graph-action');
  Finder get vaultSettingsButton => byKey('topics-vault-settings');

  Finder folder(String id) => topics.folder(id);
  Finder folderRow(String id) => byKey('folder-row-$id');
  Finder folderMenu(String id) => byKey('folder-menu-$id');
  Finder get menuRename => byKey('folder-menu-rename');
  Finder get menuMove => byKey('folder-menu-move');
  Finder get menuPinned => byKey('folder-menu-pinned');
  Finder get menuDelete => byKey('folder-menu-delete');
  Finder get menuOpenGraph => byKey('folder-menu-open-graph');
  Finder membershipPinned(String folderId, String noteId) =>
      byKey('membership-menu-pinned-$folderId-$noteId');

  Finder get nameDialog => byKey('folder-name-dialog');
  Finder get nameField => byKey('folder-name-field');
  Finder get nameConfirm => byKey('folder-name-confirm');
  Finder get nameCancel => byKey('folder-name-cancel');

  Finder get moveDialog => byKey('folder-move-dialog');
  Finder moveTarget(String id) => byKey('folder-move-target-$id');
  Finder get moveTargetRoot => byKey('folder-move-target-root');

  Finder get deleteDialog => byKey('folder-delete-dialog');
  Finder get deleteConfirm => byKey('folder-delete-confirm');
  Finder get deleteCancel => byKey('folder-delete-cancel');

  Finder get depthDialog => byKey('depth-dialog');
  Finder get depthConfirm => byKey('depth-dialog-confirm');
  Finder get depthCancel => byKey('depth-dialog-cancel');

  Finder get settingsDialog => byKey('vault-settings-dialog');
  Finder get depthField => byKey('vault-settings-depth');
  Finder get settingsSave => byKey('vault-settings-save');

  /// The inline error inside the Topics pane.
  Finder get paneError =>
      find.descendant(of: pane, matching: byKey('inline-error'));

  /// The inline error anywhere on screen.
  Finder get anyError => byKey('inline-error');
  Finder get errorDismiss => byKey('inline-error-dismiss');

  Finder topic(String folderId, String noteId) =>
      topics.topic(folderId, noteId);
  Finder unsortedNote(String noteId) => topics.unsortedNote(noteId);
  Finder folderGlyph(String id) => topics.folderGlyph(id);
  Finder memberGlyph(String folderId, String noteId) =>
      topics.memberGlyph(folderId, noteId);

  // ------------------------------------------------------------------ state

  WorkspaceTab? get activeTab => h.read(tabsProvider).activeTab;
  Set<String> get expanded => h.read(expandedTopicFoldersProvider);

  /// The text of the [EditableText] at or under [f].
  String fieldText(Finder f) => tester
      .widget<EditableText>(
        find.descendant(
          of: f,
          matching: find.byType(EditableText),
          matchRoot: true,
        ),
      )
      .controller
      .text;

  /// Left edge of the label [name] inside folder row [id].
  double folderLabelLeft(String id, String name) =>
      topics.labelLeft(folder(id), name);

  /// Every string drawn under [of].
  List<String> textsUnder(Finder of) => topics.textsUnder(of);

  // ---------------------------------------------------------------- actions

  Future<void> tap(Finder f) async {
    expect(f, findsOneWidget, reason: '$f');
    await tester.tap(f);
    await pumpFrames(tester);
  }

  /// Expand folder [id] unless it is already expanded.
  Future<void> ensureExpanded(String id) async {
    if (!expanded.contains(id)) await topics.toggleFolder(id);
  }

  /// Tap folder row [id] (selects it, toggling its expansion).
  Future<void> selectFolder(String id) => tap(folder(id));

  Future<void> enterName(String name) async {
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, name);
    await pumpFrames(tester);
  }

  /// `+ New Smart Folder` → type [name] → confirm.
  Future<void> createFolder(String name) async {
    await tap(newFolderButton);
    await enterName(name);
    await tap(nameConfirm);
  }

  Future<void> openFolderMenu(String id) => tap(folderMenu(id));

  Future<void> renameFolder(String id, String name) async {
    await openFolderMenu(id);
    await tap(menuRename);
    await enterName(name);
    await tap(nameConfirm);
  }

  /// Folder menu → Move → pick [targetId], or root when null.
  Future<void> moveFolder(String id, String? targetId) async {
    await openFolderMenu(id);
    await tap(menuMove);
    await tap(targetId == null ? moveTargetRoot : moveTarget(targetId));
  }

  Future<void> toggleFolderPinned(String id) async {
    await openFolderMenu(id);
    await tap(menuPinned);
  }

  /// Folder menu → Delete; confirms when [confirm], cancels otherwise.
  Future<void> deleteFolder(String id, {required bool confirm}) async {
    await openFolderMenu(id);
    await tap(menuDelete);
    await tap(confirm ? deleteConfirm : deleteCancel);
  }

  Future<void> openFolderGraph(String id) async {
    await openFolderMenu(id);
    await tap(menuOpenGraph);
  }

  /// Right click on topic row [folderId]/[noteId].
  Future<void> openMembershipMenu(String folderId, String noteId) async {
    final row = topic(folderId, noteId);
    expect(row, findsOneWidget);
    await tester.tap(row, buttons: kSecondaryButton);
    await pumpFrames(tester);
  }

  Future<void> toggleMembershipPinned(String folderId, String noteId) async {
    await openMembershipMenu(folderId, noteId);
    await tap(membershipPinned(folderId, noteId));
  }

  /// Drag [source] (a topic or Unsorted row) and drop it on
  /// `folder-row-<folderId>`. Holds still briefly first so either a
  /// `Draggable` or a `LongPressDraggable` picks it up.
  Future<void> dragOntoFolder(Finder source, String folderId) async {
    expect(source, findsOneWidget);
    final target = folderRow(folderId);
    expect(target, findsOneWidget);
    final from = tester.getCenter(source);
    final to = tester.getCenter(target);
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 600));
    const steps = 12;
    for (var i = 1; i <= steps; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await pumpFrames(tester);
  }

  Future<void> openVaultSettings() => tap(vaultSettingsButton);

  /// Type [value] into `vault-settings-depth` and tap save.
  Future<void> saveDepth(String value) async {
    expect(depthField, findsOneWidget);
    await tester.enterText(depthField, value);
    await pumpFrames(tester);
    await tap(settingsSave);
  }

  Future<void> dismissError() => tap(errorDismiss);

  // ------------------------------------------------------------- assertions

  /// The inline error in the Topics pane shows [message].
  void expectPaneError(String message) {
    expect(paneError, findsOneWidget);
    expect(
      textsUnder(paneError).any((t) => t.contains(message)),
      isTrue,
      reason:
          'inline error should contain "$message": ${textsUnder(paneError)}',
    );
  }

  /// Calls of [subcommand] made since launch.
  List<FakeCliCall> callsFor(String subcommand) => cli.callsFor(subcommand);

  /// Every folder / settings write made since launch, in order, as
  /// subcommand paths.
  List<String> get writes => [
    for (final c in cli.calls)
      if (c.subcommand.startsWith('folder ') || c.subcommand == 'settings set')
        c.subcommand,
  ];
}
