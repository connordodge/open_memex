// WI #362 (Spec #357 Req 4-16, 26, 34, TD1, TD8): seams for the vault
// picker modal tests. The whole app (`_Router` -> Workspace) with a vault
// open, over #96's hosted harness:
// - `wi362PumpLocal`: the local vault `memex` open (a real temp vault
//   folder) with the local `work-notes` and the hosted `seed` on nas in the
//   recents, in the order [work-notes, memex, seed]; `memex vault check`
//   answers `Wi362Env.check`; a FakeVaultDb, FakeVaultTrash,
//   FakeFileRevealer and FakeFilePicker; a recording picker-actions seam and
//   a recording leave guard.
// - `wi362PumpHosted`: the hosted `seed` on nas open (opened through the
//   real hosted path), `work` on studio in the recents, no `memex` binary.
// Helpers carry the `wi362` prefix so stacked siblings never collide. Never
// a real `memex` binary, Finder, Trash or vault; temp dirs only.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/file_revealer.dart';
import 'package:open_memex_app/src/state/picker_actions.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/state/vault_trash.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/dialog_button.dart';
import 'package:open_memex_app/src/widgets/picker/server_row.dart';
import 'package:open_memex_app/src/widgets/picker/vault_picker_modal.dart';

import 'app_harness.dart';
import 'fake_file_revealer.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'fake_vault_trash.dart';
import 'file_picker_fakes.dart';
import 'hosted_harness.dart';
import 'vault_picker_harness.dart';
import 'wi361_rows.dart';

const wi362ModalKey = Key('vault-picker-modal');
const wi362CloseKey = Key('vault-picker-modal-close');

Finder get wi362Modal => find.byKey(wi362ModalKey);
Finder get wi362Close => find.byKey(wi362CloseKey);

/// [matching] inside the modal.
Finder wi362InModal(Finder matching) =>
    find.descendant(of: wi362Modal, matching: matching);

/// The widget keyed [key] inside the modal.
Finder wi362KeyInModal(String key) => wi362InModal(find.byKey(Key(key)));

/// The studio server of the hosted tests (`work` lives there).
HostedServerFixture wi362Studio() => HostedServerFixture(
  id: 'srv-studio',
  name: 'studio',
  url: 'http://studio.local:9000',
  token: 'studio-token-362',
  vaultName: 'work',
);

/// The recording picker-actions seam, with hooks that run inside the hosted
/// flows (as `AppPickerActions` opens a vault inside its own dialogs).
class Wi362Actions extends Wi97PickerActions {
  Future<void> Function()? onOpenOnServer;
  Future<void> Function()? onCreateOnServer;

  @override
  Future<void> openOnServer(BuildContext context) async {
    await super.openOnServer(context);
    await onOpenOnServer?.call();
  }

  @override
  Future<void> createOnServer(BuildContext context) async {
    await super.createOnServer(context);
    await onCreateOnServer?.call();
  }
}

/// Everything a modal test needs.
class Wi362Env {
  Wi362Env({
    required this.h,
    required this.actions,
    required this.files,
    required this.trash,
    required this.revealer,
    required this.openPath,
    required this.otherPath,
  });

  final HostedHarness h;
  final Wi362Actions actions;
  final FakeFilePicker files;
  final FakeVaultTrash trash;
  final FakeFileRevealer revealer;

  /// The open local vault (`memex`), or null in the hosted env.
  final String? openPath;

  /// The other local vault in the recents (`work-notes`), or null.
  final String? otherPath;

  /// One entry per leave-guard call: whether anything (a dialog, a file
  /// chooser, a picker action) had started before the guard was asked.
  final List<bool> guardCalls = [];

  /// What the guard answers; [guardHold], when set, holds it.
  bool allow = true;
  Completer<bool>? guardHold;

  /// What `memex vault check` answers (default: safe).
  FutureOr<MemexResult> Function(FakeCliCall call) check = (_) =>
      FakeMemexCli.ok();

  /// Set once the future of the last [wi362OpenModal] completed.
  bool modalDone = false;

  ProviderContainer get c => h.container;
  AppSettings get settings => c.read(settingsProvider);
  VaultRef? get current => c.read(currentVaultProvider);
  VaultOpenController get controller => c.read(vaultOpenControllerProvider);
}

/// Whether a dialog, a file chooser or a picker action has started.
bool _wi362Started(Wi362Env env) =>
    env.files.calls.isNotEmpty ||
    env.actions.calls.isNotEmpty ||
    find.text('CREATE NEW VAULT').evaluate().isNotEmpty ||
    find.byKey(const Key('restore-dialog')).evaluate().isNotEmpty;

List<Override> _wi362Overrides(
  Wi362Env Function() env,
  Wi362Actions actions,
  FakeVaultTrash trash,
  FakeFileRevealer revealer,
) => [
  vaultTrashProvider.overrideWithValue(trash),
  fileRevealerProvider.overrideWithValue(revealer),
  pickerActionsProvider.overrideWithValue(actions),
  leaveVaultGuardProvider.overrideWithValue((_) async {
    final e = env();
    e.guardCalls.add(_wi362Started(e));
    final hold = e.guardHold;
    if (hold != null) return hold.future;
    return e.allow;
  }),
];

/// The app with the local vault `memex` open (the last vault), and the
/// recents [work-notes, memex, seed on nas] unless [recentsOrder] says
/// otherwise (`'open'`, `'other'`, `'hosted'`). [servers] are saved (default:
/// nas). With [openNote] a note tab is open and selected. [aliases] adds
/// more recents (after the others) built from the open vault's folder.
Future<Wi362Env> wi362PumpLocal(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  List<HostedServerFixture>? servers,
  List<String> recentsOrder = const ['other', 'open', 'hosted'],
  bool openNote = true,
  List<VaultRef> Function(String openPath)? aliases,
}) async {
  final openPath = wi361VaultNamed('memex');
  final otherPath = wi361VaultNamed('work-notes');
  final saved = servers ?? [HostedServerFixture()];
  final refs = <String, VaultRef>{
    'open': LocalVaultRef(openPath),
    'other': LocalVaultRef(otherPath),
    'hosted': seedHostedRef,
  };
  final actions = Wi362Actions();
  final files = installFakeFilePicker();
  final trash = FakeVaultTrash();
  final revealer = FakeFileRevealer();
  late Wi362Env env;
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..on('vault check', (call) => env.check(call));
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  final h = await pumpHostedApp(
    tester,
    servers: saved,
    recents: [
      for (final r in recentsOrder) refs[r]!,
      ...?aliases?.call(openPath),
    ],
    lastVault: LocalVaultRef(openPath),
    current: LocalVaultRef(openPath),
    cli: cli,
    surfaceSize: size,
    overrides: [
      vaultDbProvider.overrideWithValue(db),
      ..._wi362Overrides(() => env, actions, trash, revealer),
    ],
  );
  env = Wi362Env(
    h: h,
    actions: actions,
    files: files,
    trash: trash,
    revealer: revealer,
    openPath: openPath,
    otherPath: otherPath,
  );
  // Flush each vault's queued UI state before its temp folder goes.
  addTearDown(() => UiStateStore(vaultPath: openPath).flush());
  addTearDown(() => UiStateStore(vaultPath: otherPath).flush());
  await wi362Settle(tester);
  expect(find.byType(Workspace), findsOneWidget, reason: 'memex is open');
  if (openNote) {
    h.container
        .read(tabsProvider.notifier)
        .openOrFocus(const NoteTab('01M362'));
    h.container.read(selectedNoteIdProvider.notifier).state = '01M362';
    await wi362Settle(tester);
  }
  return env;
}

/// The app with the hosted vault `seed` on nas open (opened through the
/// hosted path), `work` on studio in the recents, nas and studio saved and
/// no `memex` binary configured.
Future<Wi362Env> wi362PumpHosted(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
}) async {
  final studio = wi362Studio();
  final actions = Wi362Actions();
  final files = installFakeFilePicker();
  final trash = FakeVaultTrash();
  final revealer = FakeFileRevealer();
  late Wi362Env env;
  final h = await pumpHostedApp(
    tester,
    servers: [HostedServerFixture(), studio],
    recents: [studio.ref('work')],
    surfaceSize: size,
    overrides: _wi362Overrides(() => env, actions, trash, revealer),
  );
  env = Wi362Env(
    h: h,
    actions: actions,
    files: files,
    trash: trash,
    revealer: revealer,
    openPath: null,
    otherPath: null,
  );
  await pumpWhile(tester, () => h.controller.openVault(seedHostedRef));
  expect(find.byType(Workspace), findsOneWidget, reason: 'seed is open');
  await wi362Settle(tester);
  return env;
}

/// Lets real I/O (UI state writes, prefs, fake servers) and fake-clock work
/// finish, then draws. Never pumpAndSettle: the workspace animates forever.
Future<void> wi362Settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Opens the vault picker modal from a context inside the Workspace (as the
/// sidebar's MANAGE will); its future sets [Wi362Env.modalDone].
Future<void> wi362OpenModal(WidgetTester tester, Wi362Env env) async {
  final workspace = find.byType(Workspace);
  expect(workspace, findsOneWidget, reason: 'a vault is open');
  env.modalDone = false;
  unawaited(
    showVaultPickerModal(
      tester.element(workspace),
    ).then((_) => env.modalDone = true),
  );
  await wi362Settle(tester, rounds: 6);
}

/// Taps [f] (scrolled into view first) and settles.
Future<void> wi362Tap(WidgetTester tester, Finder f) async {
  expect(f, findsOneWidget);
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await wi362Settle(tester);
}

/// What a modal must leave alone: the current vault, the last vault, the
/// recents order, the selected note and the tabs.
String wi362Snapshot(Wi362Env env) {
  final s = env.settings;
  final tabs = env.c.read(tabsProvider);
  return [
    'current ${env.current}',
    'last ${s.lastVaultRef}',
    'recents ${s.recentRefs.join(', ')}',
    'selected ${env.c.read(selectedNoteIdProvider)}',
    'tabs ${[for (final t in tabs.tabs) t.tabId].join(', ')}',
    'active ${tabs.activeIndex}',
  ].join('\n');
}

/// Whether the primary focus is inside the modal.
bool wi362FocusInModal() {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  return find
      .descendant(
        of: wi362Modal,
        matching: find.byElementPredicate((e) => identical(e, focused)),
        matchRoot: true,
      )
      .evaluate()
      .isNotEmpty;
}

/// The Key value (`recent-row-<i>`, `server-row-<id>`) of the picker row
/// ([PickerRowShell]) whose own focus node has the primary focus, or null
/// when the focus is elsewhere (on one of a row's buttons, say).
String? wi362FocusedRow() {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null || focused is! Element) return null;
  String? row;
  bool visit(Element e) {
    final w = e.widget;
    if (w is PickerRowIconButton || w is OmButton || w is DialogButton) {
      return false;
    }
    if (w is PickerRowShell) {
      final k = w.key;
      row = k is ValueKey<String> ? k.value : '';
      return false;
    }
    return true;
  }

  if (visit(focused)) focused.visitAncestorElements(visit);
  return row;
}

/// Presses Tab until the picker row keyed [rowKey] itself has the focus;
/// fails after [max] presses.
Future<void> wi362TabToRow(
  WidgetTester tester,
  String rowKey, {
  int max = 80,
}) async {
  for (var i = 0; i < max; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (wi362FocusedRow() == rowKey) return;
  }
  fail('Tab never focused the row $rowKey');
}

/// The semantics nodes flagged as buttons whose rect lies inside [target]'s
/// box (2 px slack). Needs `tester.ensureSemantics()`.
List<SemanticsNode> wi362ButtonNodesIn(WidgetTester tester, Finder target) {
  final box = tester.getRect(target).inflate(2);
  var root = tester.getSemantics(target);
  while (root.parent != null) {
    root = root.parent!;
  }
  final out = <SemanticsNode>[];
  void walk(SemanticsNode n, Matrix4 parent) {
    final m = n.transform == null ? parent : parent.multiplied(n.transform!);
    final r = MatrixUtils.transformRect(m, n.rect);
    final d = n.getSemanticsData();
    if (!n.isInvisible &&
        !n.isMergedIntoParent &&
        r.width > 0 &&
        box.contains(r.topLeft) &&
        box.contains(r.bottomRight) &&
        d.flagsCollection.isButton) {
      out.add(n);
    }
    n.visitChildren((c) {
      walk(c, m);
      return true;
    });
  }

  final dpr = tester.view.devicePixelRatio;
  walk(root, Matrix4.diagonal3Values(1 / dpr, 1 / dpr, 1));
  return out;
}

/// Whether the tooltip [message] shows after a mouse rests on [target].
Future<bool> wi362TooltipShows(
  WidgetTester tester,
  Finder target,
  String message,
) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: tester.getCenter(target));
  await tester.pump();
  await mouse.moveTo(tester.getCenter(target));
  await tester.pump(const Duration(seconds: 2));
  final shows = find.text(message).evaluate().isNotEmpty;
  await mouse.moveTo(Offset.zero);
  await mouse.removePointer();
  await tester.pump(const Duration(seconds: 1));
  return shows;
}
