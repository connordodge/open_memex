// WI #77 (56-A3, Spec #59 reqs 4-16, 19-27, 40-43; D12, D13, D17, D19):
// the Command palette's shell, its Commands, Notes and Recent groups, its
// keys, the ⌘K handler and the command actions.
//
// Two pumps, both #76's `pumpPaletteHost` (fakes only, no vault on disk):
// - the host: the palette shown with `showCommandPalette` over a plain
//   Scaffold body whose context stands in for the Workspace's;
// - the workspace: the real `Workspace` as the host's body (sidebar,
//   editor, `_HistoryKeys` and the ⌘K handler), at text scale 0.5 as the
//   app harness pumps it.
// Choices are read from `tabsProvider` (TabsRecorder for navigate), the
// vault's FakeMemexCli and the dialogs the existing actions show. Rows are
// read from the `PaletteRow` widgets the shell builds (#76's Keys).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/main.dart' show appRootOverrides;
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/db.dart' show Note;
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/search_access.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/agents_sheet.dart';
import 'package:open_memex_app/src/widgets/backups/backups_sheet.dart';
import 'package:open_memex_app/src/widgets/command_palette/command_palette.dart';
import 'package:open_memex_app/src/widgets/command_palette/palette_preview.dart';
import 'package:open_memex_app/src/widgets/command_palette/palette_row.dart';
import 'package:open_memex_app/src/widgets/command_palette/passages_states.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';
import 'package:open_memex_app/src/widgets/picker/vault_picker_modal.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:open_memex_app/src/widgets/vault_settings_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/app_harness.dart'
    show pumpFrames, settingsGetMaxDepthStdout;
import '../../support/canvas_seeds.dart';
import '../../support/fake_memex_cli.dart';
import '../../support/fake_vault_db.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/palette_pump.dart';
import '../../support/search_fakes.dart';
import '../../support/segment_editing_finder.dart';
import '../../support/token_store_fakes.dart';

const _meta = LogicalKeyboardKey.metaLeft;
const _shift = LogicalKeyboardKey.shiftLeft;
const _ctrl = LogicalKeyboardKey.controlLeft;
const _alt = LogicalKeyboardKey.altLeft;
const _keyK = LogicalKeyboardKey.keyK;

const _newNoteId = '01J77NEWNOTE00000000000000';
const _newCanvasId = 'cv-77-new-canvas';
const _editorNoteId = 'n-77-editor-note';

Finder get _palette => find.byKey(PaletteKeys.palette);
Finder get _input => find.byKey(PaletteKeys.input);

PaletteItemId _cmd(PaletteCommand c) =>
    PaletteItemId(PaletteItemKind.command, c.name);
PaletteItemId _note(String id) => PaletteItemId(PaletteItemKind.note, id);
PaletteItemId _daily(String id) => PaletteItemId(PaletteItemKind.daily, id);
PaletteItemId _canvas(String id) => PaletteItemId(PaletteItemKind.canvas, id);

Finder _row(PaletteItemId id) =>
    find.byKey(PaletteKeys.row(id), skipOffstage: false);

List<PaletteRow> _rows() => [
  for (final e in find.byType(PaletteRow, skipOffstage: false).evaluate())
    e.widget as PaletteRow,
];

List<PaletteItemId> _rowIds() => [for (final r in _rows()) r.item.id];

List<PaletteItemId> _selected() => [
  for (final r in _rows())
    if (r.selected) r.item.id,
];

EditableText _field(WidgetTester tester) => tester.widget<EditableText>(
  find.descendant(
    of: _input,
    matching: find.byType(EditableText),
    matchRoot: true,
  ),
);

/// The route the open palette is shown in.
ModalRoute<Object?> _paletteRoute(WidgetTester tester) =>
    ModalRoute.of(tester.element(_input))!;

const _requirement19 = [
  PaletteCommand.newNote,
  PaletteCommand.newCanvas,
  PaletteCommand.openToday,
  PaletteCommand.openVaultGraph,
  PaletteCommand.switchVault,
  PaletteCommand.vaultSettings,
  PaletteCommand.backups,
  PaletteCommand.agents,
  PaletteCommand.rightPanel,
  PaletteCommand.showDays,
  PaletteCommand.showTopics,
  PaletteCommand.showTags,
];

/// [PaletteSeeds] plus five older notes, so Recent has more than 8 to pick
/// from: `n-77-archive-<1..5>`, 200 h to 240 h ago.
FakeVaultDb _dbWithArchive() {
  final db = FakeVaultDb.v5();
  for (var i = 1; i <= 5; i++) {
    db.seedNote(
      id: 'n-77-archive-$i',
      title: 'Archive note $i',
      updatedAt: paletteHoursAgo(190 + 10 * i),
    );
  }
  return db;
}

/// A CLI whose `add` and `canvas new` write like the real ones into [db].
FakeMemexCli _writingCli(FakeVaultDb db) => FakeMemexCli()
  ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
  ..on('add', (call) {
    db.seedNote(
      id: _newNoteId,
      title: call.flag('title') ?? '',
      content: call.stdinBody ?? '',
      updatedAt: paletteHoursAgo(0),
    );
    return FakeMemexCli.ok('note_id: $_newNoteId\n');
  })
  ..on('canvas new', (call) {
    db.seedCanvas(
      _newCanvasId,
      call.flag('title') ?? '',
      updatedAt: paletteHoursAgo(0),
    );
    return FakeMemexCli.ok(
      '{"canvas_id":"$_newCanvasId","title":"${call.flag('title')}",'
      '"version":1,"created_at":1759500009000,"updated_at":1759500009000}',
    );
  });

Future<Override> _settings() async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': 'fake-memex',
    'memex.recent_vaults': <String>[paletteVaultPath],
    'memex.last_vault': paletteVaultPath,
  });
  final settings = await loadSettingsKeepingPickedBinary();
  return settingsProvider.overrideWith((_) => settings);
}

/// The host body's context: stands in for the Workspace's.
late BuildContext _wi77HostContext;

/// The host pump (no Workspace). Hydrates `tabsProvider` (today's launch
/// tab) before returning.
Future<PaletteHarness> _host(
  WidgetTester tester, {
  Size size = paletteWideSize,
  double textScale = 1.0,
  FakeVaultDb? db,
  FakeMemexCli? cli,
  bool memexConfigured = true,
  bool seed = true,
  Widget? body,
  List<Override> overrides = const [],
}) async {
  final settings = await _settings();
  final fakeDb = db ?? FakeVaultDb.v5();
  final h = await pumpPaletteHost(
    tester,
    size: size,
    textScale: textScale,
    seed: seed,
    db: fakeDb,
    cli: cli ?? (memexConfigured ? _writingCli(fakeDb) : null),
    memexConfigured: memexConfigured,
    child: Builder(
      builder: (context) {
        _wi77HostContext = context;
        return body ?? const SizedBox.expand();
      },
    ),
    overrides: [
      settings,
      uiStateStoreProvider.overrideWithValue(null),
      ...paletteShellOverrides,
      ...overrides,
    ],
  );
  h.read(tabsProvider);
  await pumpFrames(tester);
  return h;
}

/// Shows the palette over the host body.
Future<void> _open(WidgetTester tester) async {
  unawaited(showCommandPalette(_wi77HostContext));
  await pumpFrames(tester);
  expect(_palette, findsOneWidget, reason: 'showCommandPalette shows it');
}

/// The workspace pump: the real Workspace as the host's body. [db] gets
/// [PaletteSeeds] plus a note with body text, [_editorNoteId].
Future<PaletteHarness> _workspace(
  WidgetTester tester, {
  FakeVaultDb? db,
  Widget Function(Widget workspace)? wrap,
  _SlowNotes Function(FakeVaultDb db, FakeMemexCli cli)? slowNotes,
  List<Override> overrides = const [],
}) async {
  final settings = await _settings();
  final fakeDb = db ?? FakeVaultDb.v5();
  fakeDb.seedNote(
    id: _editorNoteId,
    title: 'Editor note',
    content: 'First line of the editor note',
    updatedAt: paletteHoursAgo(3),
  );
  const workspace = Workspace();
  final cli = _writingCli(fakeDb);
  final notes = slowNotes?.call(fakeDb, cli);
  final h = await pumpPaletteHost(
    tester,
    textScale: 0.5,
    db: fakeDb,
    cli: cli,
    child: wrap == null ? workspace : wrap(workspace),
    overrides: [
      settings,
      ...paletteShellOverrides,
      if (notes != null)
        vaultAccessProvider.overrideWith(
          (ref) => LocalVaultAccess(
            vaultPath: paletteVaultPath,
            db: fakeDb,
            cli: cli,
            notes: notes,
            search: FakeSearchAccess(vaultPath: paletteVaultPath, cli: cli),
          ),
        ),
      ...overrides,
    ],
  );
  await pumpFrames(tester);
  return h;
}

/// Shows [_editorNoteId] in the active tab and puts the caret in its body.
Future<FocusNode> _focusEditor(WidgetTester tester, PaletteHarness h) async {
  h.read(tabsProvider.notifier).navigate(const NoteTab(_editorNoteId));
  await pumpFrames(tester);
  await focusSegmentAt(tester, find.byKey(editorBodyKey));
  await pumpFrames(tester);
  final node = FocusManager.instance.primaryFocus;
  expect(node, isNotNull);
  return node!;
}

/// Press [key] with [mods] held; returns whether the key down was handled.
Future<bool> _chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  List<LogicalKeyboardKey> mods = const [_meta],
}) async {
  for (final m in mods) {
    await tester.sendKeyDownEvent(m, platform: 'macos');
  }
  final handled = await tester.sendKeyEvent(key, platform: 'macos');
  for (final m in mods.reversed) {
    await tester.sendKeyUpEvent(m, platform: 'macos');
  }
  await pumpFrames(tester);
  return handled;
}

Future<bool> _cmdK(WidgetTester tester) => _chord(tester, _keyK);

/// One key press, then one frame (never pumpAndSettle).
Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key, platform: 'macos');
  await tester.pump();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_input, text);
  await pumpFrames(tester);
}

/// ⌘↵: Cmd is released before any frame runs, so only the flag captured at
/// the key can carry it.
Future<void> _cmdEnter(WidgetTester tester) async {
  await tester.sendKeyDownEvent(_meta, platform: 'macos');
  await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'macos');
  await tester.sendKeyUpEvent(_meta, platform: 'macos');
  await pumpFrames(tester);
}

void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

/// Records, at every change of [provider], whether the palette's route was
/// still the current route (R24: actions run after it pops).
List<bool> _currentAtChange<T>(
  WidgetTester tester,
  PaletteHarness h,
  ProviderListenable<T> provider,
) {
  final route = _paletteRoute(tester);
  final log = <bool>[];
  final sub = h.container.listen<T>(
    provider,
    (_, _) => log.add(route.isCurrent),
  );
  addTearDown(sub.close);
  return log;
}

/// A notes access whose read of [_editorNoteId] answers only once [release] runs
/// (a hosted vault's network read).
class _SlowNotes extends LocalNotesAccess {
  _SlowNotes({required super.db, required super.cli})
    : super(vaultPath: paletteVaultPath);

  final _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<Note?> getNote(String id) async {
    if (id == _editorNoteId) await _gate.future;
    return super.getNote(id);
  }
}

/// A modal other than the palette, with a focused field: the update modal or
/// the leave-confirm dialog.
const _modalField = Key('wi77-modal-field');

void _showOtherModal(BuildContext context) => unawaited(
  showDialog<void>(
    context: context,
    builder: (_) => const AlertDialog(
      content: TextField(key: _modalField, autofocus: true),
    ),
  ),
);

bool _modalFieldFocused(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(_modalField),
        matching: find.byType(EditableText),
      ),
    )
    .focusNode
    .hasFocus;

/// The focused editor field in the Workspace's editor, if any.
Finder get _focusedEditorField => find.descendant(
  of: find.byType(NoteEditor),
  matching: find.byWidgetPredicate(
    (w) => w is EditableText && w.focusNode.hasFocus,
    description: 'the focused editor field',
  ),
);

/// The Passages seam as #78 fills it, emitting what a test asks.
class _Wi77Passages extends PalettePassagesNotifier {
  final queries = <String>[];
  var closes = 0;

  @override
  PassagesView build() => const PassagesIdle();

  @override
  void setQuery(String query) => queries.add(query);

  @override
  void close() => closes++;

  void emit(PassagesView view) => state = view;
}

/// The preview seam as #78 fills it, counting closes.
class _Wi77Preview extends PalettePreviewNotifier {
  var closes = 0;

  @override
  PreviewView build() => const PreviewNone();

  @override
  void close() => closes++;
}

_Wi77Passages? _passages;
_Wi77Preview? _preview;

List<Override> _fakeSources() => [
  palettePassagesProvider.overrideWith(() => _passages = _Wi77Passages()),
  palettePreviewProvider.overrideWith(() => _preview = _Wi77Preview()),
];

void main() {
  holdFontFetches();

  test(
    'a container built on appRootOverrides resolves the commands source to the real one',
    () {
      final container = ProviderContainer(overrides: appRootOverrides);
      addTearDown(container.dispose);

      final rows = container.read(paletteCommandsSourceProvider)('');

      expect(
        [for (final r in rows) r.command],
        [
          for (final c in _requirement19)
            if (c != PaletteCommand.newNote && c != PaletteCommand.newCanvas) c,
        ],
        reason: 'the app root fills #76 empty default, no vault can be written',
      );
    },
  );

  group('the shell', () {
    testWidgets(
      'the palette opens with an empty input focused and the first row selected',
      (tester) async {
        await _host(tester);
        await _open(tester);

        expect(_palette, findsOneWidget);
        expect(_field(tester).controller.text, isEmpty);
        expect(_field(tester).focusNode.hasFocus, isTrue);
        expect(_selected(), [_cmd(PaletteCommand.newNote)]);
      },
    );

    testWidgets(
      'the palette is a dialog labelled Command palette and the input is labelled Search notes, note text and commands',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await _host(tester);
        await _open(tester);

        expect(find.bySemanticsLabel('Command palette'), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            RegExp(r'^Search notes, note text and commands'),
          ),
          findsOneWidget,
        );
        expect(
          find.text('search notes, note text and commands…'),
          findsOneWidget,
        );
        semantics.dispose();
      },
    );

    testWidgets('two opens in one frame show one palette', (tester) async {
      await _host(tester);
      unawaited(showCommandPalette(_wi77HostContext));
      unawaited(showCommandPalette(_wi77HostContext));
      await pumpFrames(tester);

      expect(_palette, findsOneWidget);
      await _key(tester, LogicalKeyboardKey.escape);
      await pumpFrames(tester);
      expect(_palette, findsNothing, reason: 'no second palette under it');
    });

    testWidgets('Tab inside the palette never leaves it', (tester) async {
      await _host(tester);
      await _open(tester);
      final route = _paletteRoute(tester);

      for (var i = 0; i < 6; i++) {
        await _key(tester, LogicalKeyboardKey.tab);
        final focus = FocusManager.instance.primaryFocus?.context;
        expect(focus, isNotNull);
        expect(ModalRoute.of(focus!), same(route), reason: 'Tab $i');
      }
    });

    testWidgets('Esc closes the palette and focus returns to the editor', (
      tester,
    ) async {
      final h = await _workspace(tester);
      final editor = await _focusEditor(tester, h);
      expect(await _cmdK(tester), isTrue);
      expect(_palette, findsOneWidget);
      expect(_field(tester).focusNode.hasFocus, isTrue);

      await _key(tester, LogicalKeyboardKey.escape);
      await pumpFrames(tester);

      expect(_palette, findsNothing);
      expect(FocusManager.instance.primaryFocus, same(editor));
      expect(h.tabs.navigated, [const NoteTab(_editorNoteId)]);
    });

    testWidgets(
      'a scrim click closes the palette and focus returns to the editor',
      (tester) async {
        final h = await _workspace(tester);
        final editor = await _focusEditor(tester, h);
        expect(await _cmdK(tester), isTrue);
        expect(_palette, findsOneWidget);

        // Left of the card (x 160 at 1280 wide) and below its top (96).
        await tester.tapAt(const Offset(60, 400));
        await pumpFrames(tester);

        expect(_palette, findsNothing);
        expect(FocusManager.instance.primaryFocus, same(editor));
        expect(h.tabs.navigated, [const NoteTab(_editorNoteId)]);
      },
    );

    testWidgets('closing the palette tells the passages and preview sources', (
      tester,
    ) async {
      await _host(tester, overrides: _fakeSources());
      await _open(tester);
      expect(_palette, findsOneWidget);
      await _type(tester, '  back ');
      expect(_passages!.queries.last, 'back');
      expect(_passages!.closes, 0);

      await _key(tester, LogicalKeyboardKey.escape);
      await pumpFrames(tester);

      expect(_palette, findsNothing);
      expect(_passages!.closes, 1);
      expect(_preview!.closes, 1);
    });

    testWidgets(
      'changing the current vault while the palette is open closes it',
      (tester) async {
        final h = await _host(tester);
        await _open(tester);
        expect(_palette, findsOneWidget);

        h.read(currentVaultProvider.notifier).state = const LocalVaultRef(
          '/vaults/Other Vault',
        );
        await pumpFrames(tester);

        expect(_palette, findsNothing);
        expect(h.tabs.navigated, isEmpty, reason: 'closed without a choice');
      },
    );

    testWidgets(
      'unmounting the workspace while the palette is open closes it and Cmd+K is no longer handled',
      (tester) async {
        final mounted = ValueNotifier(true);
        addTearDown(mounted.dispose);
        await _workspace(
          tester,
          wrap: (workspace) => ValueListenableBuilder<bool>(
            valueListenable: mounted,
            builder: (_, on, _) => on ? workspace : const SizedBox.expand(),
          ),
        );
        _unfocus();
        expect(await _cmdK(tester), isTrue);
        expect(_palette, findsOneWidget);

        mounted.value = false;
        await pumpFrames(tester);

        expect(find.byType(Workspace), findsNothing);
        expect(_palette, findsNothing);
        expect(await _cmdK(tester), isFalse);
        expect(_palette, findsNothing);
      },
    );
  });

  group('Cmd+K', () {
    testWidgets(
      'Cmd+K opens the palette from the workspace while the note editor has focus and Cmd+K while it is open closes it',
      (tester) async {
        final h = await _workspace(tester);
        final editor = await _focusEditor(tester, h);
        final tabsBefore = h.read(tabsProvider);

        expect(await _cmdK(tester), isTrue);
        expect(_palette, findsOneWidget);
        expect(_field(tester).focusNode.hasFocus, isTrue);
        expect(_field(tester).controller.text, isEmpty);
        expect(_selected(), [_cmd(PaletteCommand.newNote)]);

        expect(await _cmdK(tester), isTrue);
        expect(_palette, findsNothing);
        expect(FocusManager.instance.primaryFocus, same(editor));
        // Cmd+K never steps tab history (TD6).
        expect(h.read(tabsProvider).activeTab, tabsBefore.activeTab);
        expect(h.read(tabsProvider).canGoBack, tabsBefore.canGoBack);
      },
    );

    testWidgets('a Cmd+K key repeat is claimed and does not toggle again', (
      tester,
    ) async {
      await _workspace(tester);
      _unfocus();
      await tester.pump();

      await tester.sendKeyDownEvent(_meta, platform: 'macos');
      expect(await tester.sendKeyDownEvent(_keyK, platform: 'macos'), isTrue);
      await pumpFrames(tester);
      expect(_palette, findsOneWidget);

      expect(
        await tester.sendKeyRepeatEvent(_keyK, platform: 'macos'),
        isTrue,
        reason: 'a held chord is claimed',
      );
      await tester.pump();
      expect(await tester.sendKeyRepeatEvent(_keyK, platform: 'macos'), isTrue);
      await pumpFrames(tester);
      expect(_palette, findsOneWidget, reason: 'the repeats did not close it');

      expect(
        await tester.sendKeyUpEvent(_keyK, platform: 'macos'),
        isFalse,
        reason: 'only the key down and repeats are claimed',
      );
      await tester.sendKeyUpEvent(_meta, platform: 'macos');
      await pumpFrames(tester);
      expect(_palette, findsOneWidget);
    });

    testWidgets(
      'two Cmd+K key downs in one frame are both claimed and leave at most one palette',
      (tester) async {
        await _workspace(tester);
        _unfocus();
        await tester.pump();

        await tester.sendKeyDownEvent(_meta, platform: 'macos');
        final first = await tester.sendKeyEvent(_keyK, platform: 'macos');
        final second = await tester.sendKeyEvent(_keyK, platform: 'macos');
        await tester.sendKeyUpEvent(_meta, platform: 'macos');
        await pumpFrames(tester);

        expect(first, isTrue);
        expect(second, isTrue);
        expect(_palette.evaluate().length, lessThanOrEqualTo(1));
      },
    );

    for (final (name, open, shown)
        in <
          (String, Future<void> Function(WidgetTester, BuildContext), Finder)
        >[
          (
            'Cmd+K is not handled while the vault picker is the current route',
            (_, c) async => unawaited(showVaultPickerModal(c)),
            find.byKey(const Key('vault-picker-modal')),
          ),
          (
            'Cmd+K is not handled while vault settings is the current route',
            (_, c) async => unawaited(showVaultSettingsDialog(c)),
            find.byKey(const Key('vault-settings-dialog')),
          ),
          (
            'Cmd+K is not handled while backups is the current route',
            (_, c) async => unawaited(
              showBackupsSheet(c, const LocalVaultRef(paletteVaultPath)),
            ),
            find.byKey(const Key('backups-close')),
          ),
          (
            'Cmd+K is not handled while the Agents sheet is the current route',
            (_, c) async => unawaited(openAgentsSheet(c)),
            find.byKey(const Key('agents-sheet')),
          ),
          (
            'Cmd+K is not handled while the new canvas prompt is the current route',
            (t, _) async {
              await t.tap(find.text('+ NEW'));
            },
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('New canvas'),
            ),
          ),
        ]) {
      testWidgets(name, (tester) async {
        final h = await _workspace(tester);
        await open(tester, tester.element(find.byType(Sidebar)));
        await pumpFrames(tester);
        expect(shown, findsOneWidget);

        expect(await _cmdK(tester), isFalse);
        expect(_palette, findsNothing);
        expect(shown, findsOneWidget, reason: 'the modal keeps the keyboard');

        // Once it closes, Cmd+K works again.
        h.navigatorKey.currentState!.pop();
        await pumpFrames(tester, frames: 8);
        expect(shown, findsNothing);
        _unfocus();
        expect(await _cmdK(tester), isTrue);
        expect(_palette, findsOneWidget);
      });
    }

    for (final (name, mods, key)
        in <(String, List<LogicalKeyboardKey>, LogicalKeyboardKey)>[
          (
            'Cmd+F is not handled by the Cmd+K handler',
            [_meta],
            LogicalKeyboardKey.keyF,
          ),
          (
            'Cmd+G is not handled by the Cmd+K handler',
            [_meta],
            LogicalKeyboardKey.keyG,
          ),
          (
            'Cmd+E is not handled by the Cmd+K handler',
            [_meta],
            LogicalKeyboardKey.keyE,
          ),
          ('Cmd+Shift+K is not handled', [_meta, _shift], _keyK),
          ('Cmd+Option+K is not handled', [_meta, _alt], _keyK),
          ('Cmd+Ctrl+K is not handled', [_meta, _ctrl], _keyK),
          ('Ctrl+K is not handled', [_ctrl], _keyK),
          ('K alone is not handled', <LogicalKeyboardKey>[], _keyK),
        ]) {
      testWidgets(name, (tester) async {
        await _workspace(tester);
        _unfocus();
        await tester.pump();

        expect(await _chord(tester, key, mods: mods), isFalse);
        expect(_palette, findsNothing);

        // The handler is mounted: the exact chord is claimed.
        expect(await _cmdK(tester), isTrue);
        expect(_palette, findsOneWidget);
      });
    }

    testWidgets(
      'while the palette shows Cmd+[ and Cmd+] do not step tab history',
      (tester) async {
        final h = await _workspace(tester);
        final tabs = h.read(tabsProvider.notifier);
        tabs
          ..navigate(NoteTab(PaletteSeeds.backlog))
          ..navigate(NoteTab(PaletteSeeds.feedbackLog))
          ..back();
        await pumpFrames(tester);
        _unfocus();
        expect(h.read(tabsProvider).activeTab, NoteTab(PaletteSeeds.backlog));

        expect(await _cmdK(tester), isTrue);
        expect(_palette, findsOneWidget);
        await _chord(tester, LogicalKeyboardKey.bracketLeft);
        await _chord(tester, LogicalKeyboardKey.bracketRight);
        expect(h.read(tabsProvider).activeTab, NoteTab(PaletteSeeds.backlog));
        expect(_palette, findsOneWidget);

        // Once it closes, the chords step again.
        await _key(tester, LogicalKeyboardKey.escape);
        await pumpFrames(tester);
        _unfocus();
        expect(await _chord(tester, LogicalKeyboardKey.bracketRight), isTrue);
        expect(
          h.read(tabsProvider).activeTab,
          NoteTab(PaletteSeeds.feedbackLog),
        );
      },
    );
  });

  group('the groups', () {
    testWidgets(
      'empty input shows COMMANDS 12 in requirement 19 order then RECENT 8 then the type to search note text footer',
      (tester) async {
        await _host(tester, db: _dbWithArchive());
        await _open(tester);

        expect(find.text('COMMANDS · 12', skipOffstage: false), findsOneWidget);
        expect(find.text('RECENT · 8', skipOffstage: false), findsOneWidget);
        expect(_rowIds(), [
          for (final c in _requirement19) _cmd(c),
          _daily(PaletteSeeds.today),
          _note(PaletteSeeds.pricingModel),
          _daily(PaletteSeeds.yesterday),
          _note(PaletteSeeds.backlog),
          _note(PaletteSeeds.feedbackLog),
          _note('n-77-archive-1'),
          _note('n-77-archive-2'),
          _note('n-77-archive-3'),
        ]);
        expect(
          find.byKey(PaletteKeys.group(PaletteGroupKind.notes)),
          findsNothing,
        );
        expect(
          find.byKey(PaletteKeys.group(PaletteGroupKind.passages)),
          findsNothing,
        );

        final commands = tester.getRect(
          find.byKey(
            PaletteKeys.group(PaletteGroupKind.commands),
            skipOffstage: false,
          ),
        );
        final recent = tester.getRect(
          find.byKey(
            PaletteKeys.group(PaletteGroupKind.recent),
            skipOffstage: false,
          ),
        );
        final footer = find.text(
          'type to search note text',
          skipOffstage: false,
        );
        expect(footer, findsOneWidget);
        final lastRecent = tester.getRect(_row(_note('n-77-archive-3')));
        expect(commands.top, lessThan(recent.top));
        expect(
          tester.getRect(footer).top,
          greaterThanOrEqualTo(lastRecent.bottom),
        );
      },
    );

    testWidgets(
      'on a vault that cannot be written Commands starts at Open today with COMMANDS 10 and no type to search note text footer',
      (tester) async {
        await _host(tester, memexConfigured: false);
        await _open(tester);

        expect(find.text('COMMANDS · 10', skipOffstage: false), findsOneWidget);
        final commands = [
          for (final id in _rowIds())
            if (id.kind == PaletteItemKind.command) id,
        ];
        expect(commands, [for (final c in _requirement19.skip(2)) _cmd(c)]);
        expect(_selected(), [_cmd(PaletteCommand.openToday)]);
        expect(_row(_cmd(PaletteCommand.newNote)), findsNothing);
        expect(_row(_cmd(PaletteCommand.newCanvas)), findsNothing);
        expect(find.text('RECENT · 5', skipOffstage: false), findsOneWidget);
        expect(
          find.text('type to search note text', skipOffstage: false),
          findsNothing,
        );
      },
    );

    testWidgets(
      'typing back lists Backups then the notes and canvas matching back best first',
      (tester) async {
        await _host(tester);
        await _open(tester);
        await _type(tester, 'back');

        expect(find.text('COMMANDS · 1'), findsOneWidget);
        expect(find.text('NOTES · 3'), findsOneWidget);
        expect(_rowIds(), [
          _cmd(PaletteCommand.backups),
          _note(PaletteSeeds.backlog),
          _canvas(PaletteSeeds.backendMigration),
          _note(PaletteSeeds.feedbackLog),
        ]);
        expect(_selected(), [_cmd(PaletteCommand.backups)]);
        final rows = {for (final r in _rows()) r.item.id: r.item};
        expect(rows[_note(PaletteSeeds.feedbackLog)]!.matched, [4, 5, 6, 7]);
        expect(
          rows[_canvas(PaletteSeeds.backendMigration)]!.meta,
          'canvas · 2 w ago',
        );
        expect(rows[_cmd(PaletteCommand.backups)]!.matched, [0, 1, 2, 3]);
      },
    );

    testWidgets(
      'the right panel row label follows the panel while the palette is open',
      (tester) async {
        final h = await _host(tester);
        h.read(rightPanelOpenProvider.notifier).state = true;
        await _open(tester);
        final row = _row(_cmd(PaletteCommand.rightPanel));
        expect(
          find.descendant(of: row, matching: find.text('Hide right panel')),
          findsOneWidget,
        );

        h.read(rightPanelOpenProvider.notifier).state = false;
        await pumpFrames(tester);

        expect(
          find.descendant(of: row, matching: find.text('Show right panel')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a failed titles read leaves Notes and Recent out and Commands still show',
      (tester) async {
        final h = await _host(tester);
        // Every title read now fails.
        h.db.db.execute('ALTER TABLE notes RENAME TO notes_77_gone');
        await _open(tester);

        expect(find.text('COMMANDS · 12', skipOffstage: false), findsOneWidget);
        expect(
          find.byKey(
            PaletteKeys.group(PaletteGroupKind.recent),
            skipOffstage: false,
          ),
          findsNothing,
        );
        expect(_selected(), [_cmd(PaletteCommand.newNote)]);

        await _type(tester, 'back');
        expect(_rowIds(), [_cmd(PaletteCommand.backups)]);
        expect(
          find.byKey(PaletteKeys.group(PaletteGroupKind.notes)),
          findsNothing,
        );
      },
    );

    testWidgets(
      'a vaultRevisionProvider change while open re-reads titles keeps the selected item and makes no search call',
      (tester) async {
        final h = await _host(tester, overrides: _fakeSources());
        await _open(tester);
        await _type(tester, 'back');
        await _key(tester, LogicalKeyboardKey.arrowDown);
        await _key(tester, LogicalKeyboardKey.arrowDown);
        expect(_selected(), [_canvas(PaletteSeeds.backendMigration)]);
        final searches = h.search.calls.length;
        final queries = _passages!.queries.length;

        h.db.seedNote(
          id: 'n-77-backstage',
          title: 'Backstage',
          updatedAt: paletteHoursAgo(0),
        );
        h.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(_rowIds(), [
          _cmd(PaletteCommand.backups),
          _note(PaletteSeeds.backlog),
          _note('n-77-backstage'),
          _canvas(PaletteSeeds.backendMigration),
          _note(PaletteSeeds.feedbackLog),
        ]);
        expect(_selected(), [_canvas(PaletteSeeds.backendMigration)]);
        expect(h.search.calls.length, searches);
        expect(
          _passages!.queries.length,
          queries,
          reason: 'no Passages re-run',
        );
      },
    );

    testWidgets(
      'the shell places passage rows with their footer and the passages state row',
      (tester) async {
        await _host(tester, overrides: _fakeSources());
        await _open(tester);
        await _type(tester, 'pricing');

        _passages!.emit(const PassagesSearching());
        await pumpFrames(tester);
        expect(find.byType(PassagesStateRow), findsOneWidget);

        const hit = SearchHit(
          noteId: PaletteSeeds.pricingModel,
          noteTitle: 'Pricing model',
          chunkId: 'ch-77-1',
          snippet: 'the pricing model for next year',
          startByte: 0,
          noteUpdatedAt: 0,
        );
        _passages!.emit(
          const PassagesShown(
            rows: [PassageItem(hit, meta: 'note · 2 h ago')],
            semantic: Semantic.on,
          ),
        );
        await pumpFrames(tester);

        expect(find.text('PASSAGES · 1'), findsOneWidget);
        expect(find.text('keyword + meaning'), findsOneWidget);
        final passage = _row(
          const PaletteItemId(PaletteItemKind.passage, 'ch-77-1'),
        );
        expect(passage, findsOneWidget);
        final footer = find.byType(PassagesFooter);
        expect(footer, findsOneWidget);
        expect(
          tester.getRect(footer).top,
          greaterThanOrEqualTo(tester.getRect(passage).bottom),
        );
      },
    );
    testWidgets(
      'dimmed passage rows are drawn at half opacity and shown ones are not dimmed',
      (tester) async {
        await _host(tester, overrides: _fakeSources());
        await _open(tester);
        await _type(tester, 'pricing');
        const hit = SearchHit(
          noteId: PaletteSeeds.pricingModel,
          noteTitle: 'Pricing model',
          chunkId: 'ch-77-3',
          snippet: 'the pricing model for next year',
          startByte: 0,
          noteUpdatedAt: 0,
        );
        const item = PassageItem(hit, meta: 'note · 2 h ago');
        final passage = _row(
          const PaletteItemId(PaletteItemKind.passage, 'ch-77-3'),
        );
        Finder dimming() => find.ancestor(
          of: passage,
          matching: find.byWidgetPredicate(
            (w) => w is Opacity && w.opacity == 0.5,
          ),
        );

        _passages!.emit(const PassagesDimmed([item], hint: 'keyword only'));
        await pumpFrames(tester);
        expect(passage, findsOneWidget);
        expect(dimming(), findsOneWidget, reason: 'the previous answer dims');
        expect(
          find.ancestor(
            of: _row(_note(PaletteSeeds.pricingModel)),
            matching: find.byWidgetPredicate((w) => w is Opacity),
          ),
          findsNothing,
          reason: 'only Passages rows dim',
        );

        _passages!.emit(
          const PassagesShown(rows: [item], semantic: Semantic.embeddingsOff),
        );
        await pumpFrames(tester);
        expect(passage, findsOneWidget);
        expect(dimming(), findsNothing, reason: 'the latest answer is full');
      },
    );
  });

  group('the keys', () {
    testWidgets('Up and Down move the selection and stop at the ends', (
      tester,
    ) async {
      await _host(tester);
      await _open(tester);
      final ids = _rowIds();
      expect(ids, hasLength(17), reason: '12 commands, 5 recent');

      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_selected(), [_cmd(PaletteCommand.newCanvas)]);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(_selected(), [_cmd(PaletteCommand.newNote)], reason: 'top');

      for (var i = 0; i < ids.length + 3; i++) {
        await _key(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(_selected(), [ids.last], reason: 'bottom');
      expect(_palette, findsOneWidget);
      expect(_field(tester).focusNode.hasFocus, isTrue);
    });

    testWidgets('typing selects the first row', (tester) async {
      await _host(tester);
      await _open(tester);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_selected(), [_cmd(PaletteCommand.openToday)]);

      await _type(tester, 'ba');

      expect(_selected(), [_rowIds().first]);
      expect(_rowIds().first, _cmd(PaletteCommand.backups));
    });

    testWidgets('Enter with no rows does nothing and keeps the palette open', (
      tester,
    ) async {
      final h = await _host(tester);
      await _open(tester);
      await _type(tester, 'qzxv');
      expect(_rows(), isEmpty);

      await _key(tester, LogicalKeyboardKey.enter);
      await pumpFrames(tester);

      expect(_palette, findsOneWidget);
      expect(h.tabs.navigated, isEmpty);
      expect(h.tabs.followed, isEmpty);
    });

    testWidgets('the selected row is scrolled into view', (tester) async {
      await _host(tester, size: paletteNarrowSize, db: _dbWithArchive());
      await _open(tester);
      final ids = _rowIds();
      expect(ids, hasLength(20));

      for (var i = 0; i < ids.length - 1; i++) {
        await _key(tester, LogicalKeyboardKey.arrowDown);
      }
      await pumpFrames(tester);

      expect(_selected(), [ids.last]);
      final card = tester.getRect(_palette);
      final row = tester.getRect(_row(ids.last));
      expect(row.top, greaterThanOrEqualTo(card.top + 52 - 0.5));
      // Above the 34 px list-only hint footer.
      expect(row.bottom, lessThanOrEqualTo(card.bottom - 34));

      // Up again to a middle row that scrolled out above the viewport: the
      // list scrolls back to it, not only to the first row.
      for (var i = ids.length - 1; i > 3; i--) {
        await _key(tester, LogicalKeyboardKey.arrowUp);
        await pumpFrames(tester);
        final r = tester.getRect(_row(ids[i - 1]));
        expect(r.top, greaterThanOrEqualTo(card.top + 52 - 0.5), reason: '$i');
        expect(r.bottom, lessThanOrEqualTo(card.bottom - 34 + 0.5));
      }
      expect(_selected(), [ids[3]]);

      for (var i = 0; i < 3; i++) {
        await _key(tester, LogicalKeyboardKey.arrowUp);
      }
      await pumpFrames(tester);
      expect(_selected(), [ids.first]);
      final first = tester.getRect(_row(ids.first));
      expect(first.top, greaterThanOrEqualTo(card.top + 52 - 0.5));
      expect(first.bottom, lessThanOrEqualTo(card.bottom - 34));
    });
  });

  group('choosing a note', () {
    testWidgets(
      'Enter on a note row navigates the current tab to it after the palette closes',
      (tester) async {
        final h = await _host(tester);
        final tabCount = h.read(tabsProvider).tabs.length;
        await _open(tester);
        await _type(tester, 'backlog');
        expect(_selected(), [_note(PaletteSeeds.backlog)]);
        final current = _currentAtChange(tester, h, tabsProvider);

        await _key(tester, LogicalKeyboardKey.enter);
        await pumpFrames(tester);

        expect(_palette, findsNothing);
        expect(h.tabs.navigated, [NoteTab(PaletteSeeds.backlog)]);
        expect(h.read(tabsProvider).tabs, hasLength(tabCount));
        expect(h.read(tabsProvider).activeTab, NoteTab(PaletteSeeds.backlog));
        expect(current, isNotEmpty);
        expect(current, everyElement(isFalse), reason: 'after the pop');
      },
    );

    testWidgets(
      'Cmd+Enter on a note row opens it with openOrFocus in a new tab',
      (tester) async {
        final h = await _host(tester);
        final tabCount = h.read(tabsProvider).tabs.length;
        await _open(tester);
        await _type(tester, 'backlog');

        await _cmdEnter(tester);

        expect(_palette, findsNothing);
        final state = h.read(tabsProvider);
        expect(state.tabs, hasLength(tabCount + 1));
        expect(state.activeTab, NoteTab(PaletteSeeds.backlog));
        expect(state.activeIndex, state.tabs.length - 1);
        expect(
          h.tabs.navigated,
          isNot(contains(NoteTab(PaletteSeeds.backlog))),
        );
      },
    );

    testWidgets('Cmd+Enter on a note already open in a tab focuses that tab', (
      tester,
    ) async {
      final h = await _host(tester);
      final tabs = h.read(tabsProvider.notifier);
      final at = tabs.openOrFocus(NoteTab(PaletteSeeds.backlog));
      tabs.setActive(0);
      await pumpFrames(tester);
      final tabCount = h.read(tabsProvider).tabs.length;
      await _open(tester);
      await _type(tester, 'backlog');

      await _cmdEnter(tester);

      final state = h.read(tabsProvider);
      expect(state.tabs, hasLength(tabCount));
      expect(state.activeIndex, at);
      expect(state.activeTab, NoteTab(PaletteSeeds.backlog));
    });

    testWidgets('a Cmd click on a note row opens it with openOrFocus', (
      tester,
    ) async {
      final h = await _host(tester);
      final tabCount = h.read(tabsProvider).tabs.length;
      await _open(tester);
      await _type(tester, 'back');

      await tester.sendKeyDownEvent(_meta, platform: 'macos');
      await tester.tap(_row(_note(PaletteSeeds.feedbackLog)));
      await tester.sendKeyUpEvent(_meta, platform: 'macos');
      await pumpFrames(tester);

      expect(_palette, findsNothing);
      final state = h.read(tabsProvider);
      expect(state.tabs, hasLength(tabCount + 1));
      expect(state.activeTab, NoteTab(PaletteSeeds.feedbackLog));
    });

    testWidgets(
      'a click on a canvas row navigates the current tab to the canvas',
      (tester) async {
        final h = await _host(tester);
        final tabCount = h.read(tabsProvider).tabs.length;
        await _open(tester);
        await _type(tester, 'backend');

        await tester.tap(_row(_canvas(PaletteSeeds.backendMigration)));
        await pumpFrames(tester);

        expect(_palette, findsNothing);
        expect(h.tabs.navigated, [
          const CanvasTab(PaletteSeeds.backendMigration),
        ]);
        expect(h.read(tabsProvider).tabs, hasLength(tabCount));
      },
    );

    testWidgets(
      'Enter on a daily note row navigates the current tab to that daily note',
      (tester) async {
        final h = await _host(tester);
        await _open(tester);
        await _type(tester, '2026-11-17');
        expect(_selected(), [_daily(PaletteSeeds.yesterday)]);

        await _key(tester, LogicalKeyboardKey.enter);
        await pumpFrames(tester);

        expect(h.tabs.navigated, [NoteTab(PaletteSeeds.yesterday)]);
      },
    );

    testWidgets('choosing a note leaves keyboard focus in that notes editor', (
      tester,
    ) async {
      final h = await _workspace(tester);
      _unfocus();
      expect(await _cmdK(tester), isTrue);
      await _type(tester, 'editor note');
      expect(_selected(), [_note(_editorNoteId)]);

      await _key(tester, LogicalKeyboardKey.enter);
      await pumpFrames(tester, frames: 8);

      expect(_palette, findsNothing);
      expect(h.read(tabsProvider).activeTab, const NoteTab(_editorNoteId));
      expect(
        find.descendant(
          of: find.byType(NoteEditor),
          matching: find.byWidgetPredicate(
            (w) => w is EditableText && w.focusNode.hasFocus,
            description: 'the focused editor field',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(NoteEditor),
          matching: find.text('First line of the editor note'),
        ),
        findsWidgets,
        reason: 'the editor shows the chosen note',
      );
    });
  });

  group('the commands', () {
    for (final (name, query, command, setup, check)
        in <
          (
            String,
            String,
            PaletteCommand,
            Future<void> Function(WidgetTester, PaletteHarness)?,
            Future<void> Function(WidgetTester, PaletteHarness, List<bool>),
          )
        >[
          (
            'Enter on New note runs its action once after the palette closes',
            'new note',
            PaletteCommand.newNote,
            null,
            (t, h, current) async {
              expect(h.cli!.callsFor('add'), hasLength(1));
              expect(h.cli!.callsFor('add').single.flag('title'), 'Untitled');
              expect(h.tabs.navigated, [const NoteTab(_newNoteId)]);
              expect(h.read(tabsProvider).tabs, hasLength(1));
              expect(current, isNotEmpty);
              expect(current, everyElement(isFalse));
            },
          ),
          (
            'Enter on New canvas runs its action once after the palette closes',
            'new canvas',
            PaletteCommand.newCanvas,
            null,
            (t, h, current) async {
              final prompt = find.byType(AlertDialog);
              expect(prompt, findsOneWidget);
              expect(
                find.descendant(of: prompt, matching: find.text('New canvas')),
                findsOneWidget,
              );
              await t.enterText(
                find.descendant(of: prompt, matching: find.byType(TextField)),
                'Roadmap',
              );
              await t.tap(find.byKey(const Key('new-canvas-confirm')));
              await pumpFrames(t);
              expect(prompt, findsNothing);
              expect(h.cli!.callsFor('canvas new'), hasLength(1));
              expect(
                h.cli!.callsFor('canvas new').single.flag('title'),
                'Roadmap',
              );
              expect(h.tabs.navigated, [const CanvasTab(_newCanvasId)]);
              expect(current, everyElement(isFalse));
            },
          ),
          (
            'Enter on Open today runs its action once after the palette closes',
            'open today',
            PaletteCommand.openToday,
            (t, h) async {
              h
                  .read(tabsProvider.notifier)
                  .navigate(NoteTab(PaletteSeeds.backlog));
              await pumpFrames(t);
            },
            (t, h, current) async {
              final state = h.read(tabsProvider);
              expect(state.tabs, hasLength(1));
              expect(state.activeTab, NoteTab(PaletteSeeds.today));
              expect(h.tabs.navigated.last, NoteTab(PaletteSeeds.today));
              expect(current, isNotEmpty);
              expect(current, everyElement(isFalse));
            },
          ),
          (
            'Enter on Open vault graph runs its action once after the palette closes',
            'open vault graph',
            PaletteCommand.openVaultGraph,
            null,
            (t, h, current) async {
              final state = h.read(tabsProvider);
              expect(state.tabs, hasLength(1));
              expect(state.activeTab, GraphTab(const GraphScope.vault()));
              expect(h.tabs.navigated, [GraphTab(const GraphScope.vault())]);
              expect(current, isNotEmpty);
              expect(current, everyElement(isFalse));
            },
          ),
          (
            'Enter on Switch vault runs its action once after the palette closes',
            'switch vault',
            PaletteCommand.switchVault,
            null,
            (t, h, current) async {
              expect(
                find.byKey(const Key('vault-picker-modal')),
                findsOneWidget,
              );
            },
          ),
          (
            'Enter on Vault settings runs its action once after the palette closes',
            'vault settings',
            PaletteCommand.vaultSettings,
            null,
            (t, h, current) async {
              expect(
                find.byKey(const Key('vault-settings-dialog')),
                findsOneWidget,
              );
            },
          ),
          (
            'Enter on Backups runs its action once after the palette closes',
            'backups',
            PaletteCommand.backups,
            null,
            (t, h, current) async {
              expect(find.byKey(const Key('backups-close')), findsOneWidget);
            },
          ),
          (
            'Enter on Agents runs its action once after the palette closes',
            'agents',
            PaletteCommand.agents,
            null,
            (t, h, current) async {
              expect(find.byKey(const Key('agents-sheet')), findsOneWidget);
            },
          ),
          (
            'Enter on the right panel command runs its action once after the palette closes',
            'right panel',
            PaletteCommand.rightPanel,
            (t, h) async {
              h.read(rightPanelOpenProvider.notifier).state = true;
              await pumpFrames(t);
            },
            (t, h, current) async {
              expect(h.read(rightPanelOpenProvider), isFalse);
              expect(current, [false], reason: 'toggled once, after the pop');
            },
          ),
          (
            'Enter on Show Days runs its action once after the palette closes',
            'show days',
            PaletteCommand.showDays,
            (t, h) async {
              await h
                  .read(sidebarModeProvider.notifier)
                  .select(SidebarMode.topics);
            },
            (t, h, current) async {
              expect(h.read(sidebarModeProvider), SidebarMode.days);
              expect(current, isNotEmpty);
              expect(current, everyElement(isFalse));
            },
          ),
          (
            'Enter on Show Topics runs its action once after the palette closes',
            'show topics',
            PaletteCommand.showTopics,
            null,
            (t, h, current) async {
              expect(h.read(sidebarModeProvider), SidebarMode.topics);
              expect(current, isNotEmpty);
              expect(current, everyElement(isFalse));
            },
          ),
          (
            'Enter on Show Tags runs its action once after the palette closes',
            'show tags',
            PaletteCommand.showTags,
            null,
            (t, h, current) async {
              expect(h.read(sidebarModeProvider), SidebarMode.tags);
              expect(current, isNotEmpty);
              expect(current, everyElement(isFalse));
            },
          ),
        ]) {
      testWidgets(name, (tester) async {
        final h = await _host(tester);
        await setup?.call(tester, h);
        await _open(tester);
        await _type(tester, query);
        expect(_selected(), [_cmd(command)]);
        final watched =
            switch (command) {
                  PaletteCommand.rightPanel => rightPanelOpenProvider,
                  PaletteCommand.showDays ||
                  PaletteCommand.showTopics ||
                  PaletteCommand.showTags => sidebarModeProvider,
                  _ => tabsProvider,
                }
                as ProviderListenable<Object?>;
        final current = _currentAtChange(tester, h, watched);

        await _key(tester, LogicalKeyboardKey.enter);
        await pumpFrames(tester, frames: 8);

        expect(_palette, findsNothing, reason: 'the palette closed first');
        await check(tester, h, current);
      });
    }

    testWidgets('Cmd+Enter on Open today uses openOrFocus', (tester) async {
      final h = await _host(tester);
      h.read(tabsProvider.notifier).navigate(NoteTab(PaletteSeeds.backlog));
      await pumpFrames(tester);
      await _open(tester);
      await _type(tester, 'open today');

      await _cmdEnter(tester);

      final state = h.read(tabsProvider);
      expect(state.tabs, hasLength(2), reason: 'no tab showed today');
      expect(state.activeTab, NoteTab(PaletteSeeds.today));
      expect(state.tabs.first, NoteTab(PaletteSeeds.backlog));
    });

    testWidgets('Cmd+Enter on Open vault graph uses openOrFocus', (
      tester,
    ) async {
      final h = await _host(tester);
      await _open(tester);
      await _type(tester, 'open vault graph');

      await _cmdEnter(tester);

      final state = h.read(tabsProvider);
      expect(state.tabs, hasLength(2));
      expect(state.activeTab, GraphTab(const GraphScope.vault()));
      expect(h.tabs.navigated, isEmpty);
    });

    testWidgets('Cmd+Enter on New note acts like Enter', (tester) async {
      final h = await _host(tester);
      await _open(tester);
      await _type(tester, 'new note');

      await _cmdEnter(tester);

      expect(h.cli!.callsFor('add'), hasLength(1));
      expect(h.tabs.navigated, [const NoteTab(_newNoteId)]);
      expect(h.read(tabsProvider).tabs, hasLength(1));
    });
  });

  group('the layout', () {
    testWidgets('at 1280x800 the card shows the list and the preview slot', (
      tester,
    ) async {
      await _host(tester);
      await _open(tester);

      final card = tester.getRect(_palette);
      expect(card.left, closeTo(160, 0.5));
      expect(card.top, closeTo(96, 0.5), reason: 'top-anchored at 96');
      expect(card.width, closeTo(960, 0.5));
      expect(card.height, closeTo(560, 0.5), reason: 'min(560, h - 144)');
      final preview = find.byType(PalettePreview);
      expect(preview, findsOneWidget);
      final slot = tester.getRect(preview);
      expect(slot.left, closeTo(card.left + 401, 0.5));
      expect(slot.top, closeTo(card.top + 53, 0.5));
      expect(slot.width, closeTo(558, 0.5));
      expect(
        tester.getSize(_row(_cmd(PaletteCommand.newNote))).width,
        closeTo(387, 0.5),
        reason: 'the 400 px list column',
      );
    });

    testWidgets(
      'at 900x640 the preview slot is absent and the card is 640 wide',
      (tester) async {
        await _host(tester, size: paletteNarrowSize);
        await _open(tester);

        final card = tester.getRect(_palette);
        expect(card.width, closeTo(640, 0.5));
        expect(card.left, closeTo(130, 0.5));
        expect(card.top, closeTo(96, 0.5));
        expect(card.height, closeTo(496, 0.5));
        expect(find.byType(PalettePreview), findsNothing);
        expect(
          tester.getSize(_row(_cmd(PaletteCommand.newNote))).width,
          closeTo(626, 0.5),
        );
      },
    );

    testWidgets(
      'a short window keeps the card top-anchored and min 560 or h minus 144 tall',
      (tester) async {
        await _host(tester, size: const Size(1280, 500));
        await _open(tester);

        final card = tester.getRect(_palette);
        expect(card.top, closeTo(96, 0.5));
        expect(card.height, closeTo(500 - 144, 0.5));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the wide hint footer names run for a command and choose for a note',
      (tester) async {
        await _host(tester);
        await _open(tester);

        expect(find.text('move'), findsOneWidget);
        expect(find.text('run'), findsOneWidget);
        expect(find.text('in a new tab'), findsOneWidget);
        expect(find.text('close'), findsOneWidget);
        final selected = _rows().singleWhere((r) => r.selected);
        expect(selected.showEnterChip, isFalse, reason: 'wide card: no chip');

        await _type(tester, 'backlog');

        expect(find.text('choose'), findsOneWidget);
        expect(find.text('new tab'), findsOneWidget);
        expect(find.text('run'), findsNothing);
        expect(find.text('in a new tab'), findsNothing);
      },
    );

    testWidgets(
      'the narrow card shows its own hint footer and the Enter chip on the selected row',
      (tester) async {
        await _host(tester, size: paletteNarrowSize);
        await _open(tester);

        expect(find.text('move'), findsOneWidget);
        expect(find.text('choose'), findsOneWidget);
        expect(find.text('new tab'), findsOneWidget);
        expect(find.text('close'), findsOneWidget);
        expect(find.text('run'), findsNothing);
        final rows = _rows();
        expect(rows.singleWhere((r) => r.selected).showEnterChip, isTrue);
      },
    );

    testWidgets(
      'at text scale 1.5 in a 900x640 window the palette with 12 commands and 8 notes reports no overflow',
      (tester) async {
        final db = _dbWithArchive();
        for (var i = 1; i <= 3; i++) {
          db.seedNote(
            id: 'n-77-note-$i',
            title: 'A long note title number $i that will need an ellipsis',
            updatedAt: paletteHoursAgo(10 + i),
          );
        }
        await _host(tester, size: paletteNarrowSize, textScale: 1.5, db: db);
        await _open(tester);

        expect(find.text('COMMANDS · 12', skipOffstage: false), findsOneWidget);
        expect(find.text('RECENT · 8', skipOffstage: false), findsOneWidget);
        expect(tester.takeException(), isNull);

        await _type(tester, 'note');
        expect(find.text('NOTES · 8', skipOffstage: false), findsOneWidget);
        expect(tester.takeException(), isNull);

        for (var i = 0; i < 12; i++) {
          await _key(tester, LogicalKeyboardKey.arrowDown);
        }
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('a modal over the palette', () {
    testWidgets(
      'Cmd+K is not handled while a modal covers the showing palette',
      (tester) async {
        final h = await _workspace(tester);
        final editor = await _focusEditor(tester, h);
        expect(await _cmdK(tester), isTrue);
        expect(_palette, findsOneWidget);

        _showOtherModal(h.context);
        await pumpFrames(tester);
        expect(find.byKey(_modalField), findsOneWidget);
        expect(_modalFieldFocused(tester), isTrue);

        expect(await _cmdK(tester), isFalse);
        expect(_palette, findsOneWidget, reason: 'the palette stays');
        expect(find.byKey(_modalField), findsOneWidget);
        expect(
          _modalFieldFocused(tester),
          isTrue,
          reason: 'the modal keeps it',
        );
        expect(FocusManager.instance.primaryFocus, isNot(same(editor)));

        // Once the modal closes, Cmd+K closes the palette again.
        h.navigatorKey.currentState!.pop();
        await pumpFrames(tester, frames: 8);
        expect(find.byKey(_modalField), findsNothing);
        expect(await _cmdK(tester), isTrue);
        expect(_palette, findsNothing);
        expect(FocusManager.instance.primaryFocus, same(editor));
      },
    );

    testWidgets(
      'closing a palette that a modal covers leaves the focus in the modal and the Command bar at rest',
      (tester) async {
        const field = Key('wi77-host-field');
        final hostFocus = FocusNode();
        addTearDown(hostFocus.dispose);
        final h = await _host(
          tester,
          body: TextField(key: field, focusNode: hostFocus, autofocus: true),
        );
        await pumpFrames(tester);
        expect(hostFocus.hasFocus, isTrue);
        await _open(tester);
        expect(h.read(commandPaletteOpenProvider), isTrue);
        _showOtherModal(_wi77HostContext);
        await pumpFrames(tester);
        expect(_modalFieldFocused(tester), isTrue);

        closeCommandPalette(h.container);
        await pumpFrames(tester);

        expect(_palette, findsNothing, reason: 'removed under the modal');
        expect(find.byKey(_modalField), findsOneWidget);
        expect(
          _modalFieldFocused(tester),
          isTrue,
          reason: 'the modal keeps it',
        );
        expect(hostFocus.hasFocus, isFalse, reason: 'not restored under it');
        expect(
          h.read(commandPaletteOpenProvider),
          isFalse,
          reason: 'the Command bar returns to rest',
        );

        // A later open and close does not leave the bar latched open.
        h.navigatorKey.currentState!.pop();
        await pumpFrames(tester, frames: 8);
        await _open(tester);
        expect(h.read(commandPaletteOpenProvider), isTrue);
        await _key(tester, LogicalKeyboardKey.escape);
        await pumpFrames(tester, frames: 8);
        expect(_palette, findsNothing);
        expect(h.read(commandPaletteOpenProvider), isFalse);
        expect(hostFocus.hasFocus, isTrue, reason: 'a current close restores');
      },
    );

    testWidgets('a vault change while a modal covers the palette closes it', (
      tester,
    ) async {
      final h = await _host(tester);
      await _open(tester);
      _showOtherModal(_wi77HostContext);
      await pumpFrames(tester);
      expect(_modalFieldFocused(tester), isTrue);

      h.read(currentVaultProvider.notifier).state = const LocalVaultRef(
        '/vaults/Other Vault',
      );
      await pumpFrames(tester);
      // Riverpod's debug assert 'Only one task can be scheduled at a time'
      // fires when the removed route unmounts in the frame the vault's
      // providers refresh (debug builds only, nothing of the palette's).
      tester.takeException();

      expect(_palette, findsNothing, reason: 'closed under the modal');
      expect(find.byKey(_modalField), findsOneWidget);
      expect(_modalFieldFocused(tester), isTrue);
      expect(h.read(commandPaletteOpenProvider), isFalse);
    });
  });

  group('the editor focus after a choice', () {
    /// Chooses [_editorNoteId] from the palette while its read is held.
    Future<(PaletteHarness, _SlowNotes)> choose(WidgetTester tester) async {
      late _SlowNotes notes;
      final h = await _workspace(
        tester,
        slowNotes: (db, cli) => notes = _SlowNotes(db: db, cli: cli),
      );
      _unfocus();
      expect(await _cmdK(tester), isTrue);
      await _type(tester, 'editor note');
      expect(_selected(), [_note(_editorNoteId)]);
      await _key(tester, LogicalKeyboardKey.enter);
      await pumpFrames(tester, frames: 8);
      expect(_palette, findsNothing);
      expect(h.read(tabsProvider).activeTab, const NoteTab(_editorNoteId));
      return (h, notes);
    }

    testWidgets(
      'a note that loads after many frames still gets the keyboard focus',
      (tester) async {
        final (_, notes) = await choose(tester);
        expect(_focusedEditorField, findsNothing, reason: 'still loading');

        // Far more frames than the old 40 frame wait.
        await pumpFrames(tester, frames: 120);
        expect(_focusedEditorField, findsNothing);
        notes.release();
        await pumpFrames(tester, frames: 12);

        expect(_focusedEditorField, findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(NoteEditor),
            matching: find.text('First line of the editor note'),
          ),
          findsWidgets,
        );
      },
    );

    testWidgets(
      'a note that loads later than the wait does not take the focus',
      (tester) async {
        final (h, notes) = await choose(tester);
        await pumpFrames(tester, frames: 8);

        h.clock.advance(const Duration(seconds: 11));
        notes.release();
        await pumpFrames(tester, frames: 12);

        expect(
          find.descendant(
            of: find.byType(NoteEditor),
            matching: find.text('First line of the editor note'),
          ),
          findsWidgets,
          reason: 'the note still loads',
        );
        expect(_focusedEditorField, findsNothing);
      },
    );

    testWidgets(
      'a note that loads after the active tab moved on does not take the focus',
      (tester) async {
        final (h, notes) = await choose(tester);

        h.read(tabsProvider.notifier).navigate(NoteTab(PaletteSeeds.backlog));
        await pumpFrames(tester, frames: 4);
        notes.release();
        await pumpFrames(tester, frames: 12);

        expect(h.read(tabsProvider).activeTab, NoteTab(PaletteSeeds.backlog));
        expect(_focusedEditorField, findsNothing);
      },
    );
  });

  group('the palette card', () {
    for (final (name, target) in <(String, Finder Function())>[
      ('the hint footer', () => find.text('close')),
      ('a group header', () => find.text('COMMANDS · 12')),
    ]) {
      testWidgets('a mouse click on $name keeps the keyboard in the palette', (
        tester,
      ) async {
        await _host(tester);
        await _open(tester);

        await tester.tap(target(), kind: PointerDeviceKind.mouse);
        await pumpFrames(tester);

        expect(_palette, findsOneWidget);
        expect(_field(tester).focusNode.hasFocus, isTrue);
        await _key(tester, LogicalKeyboardKey.arrowDown);
        expect(_selected(), [_cmd(PaletteCommand.newCanvas)]);
        await _key(tester, LogicalKeyboardKey.escape);
        await pumpFrames(tester, frames: 8);
        expect(_palette, findsNothing);
      });
    }
  });

  group('shell contracts', () {
    const hit = SearchHit(
      noteId: PaletteSeeds.pricingModel,
      noteTitle: 'Pricing model',
      chunkId: 'ch-77-9',
      snippet: 'the pricing model for next year',
      startByte: 0,
      noteUpdatedAt: 0,
    );
    const passageId = PaletteItemId(PaletteItemKind.passage, 'ch-77-9');

    testWidgets('the wide hint footer for a passage row names show here', (
      tester,
    ) async {
      await _host(tester, overrides: _fakeSources());
      await _open(tester);
      await _type(tester, 'pricing');
      _passages!.emit(
        const PassagesShown(
          rows: [PassageItem(hit, meta: 'note')],
          semantic: Semantic.on,
        ),
      );
      await pumpFrames(tester);
      for (var i = 0; i < 6 && !_selected().contains(passageId); i++) {
        await _key(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(_selected(), [passageId]);

      expect(find.text('show here, at this passage'), findsOneWidget);
      expect(find.text('new tab'), findsOneWidget);
      expect(find.text('close'), findsOneWidget);
      expect(find.text('move'), findsNothing);
      expect(find.text('choose'), findsNothing);
      expect(find.text('run'), findsNothing);
    });

    testWidgets(
      'the wide hint footer with no selection offers move and close',
      (tester) async {
        await _host(tester);
        await _open(tester);
        await _type(tester, 'qzxv');
        expect(_selected(), isEmpty);

        expect(find.text('move'), findsOneWidget);
        expect(find.text('close'), findsOneWidget);
        expect(find.text('choose'), findsNothing);
        expect(find.text('new tab'), findsNothing);
        expect(find.text('run'), findsNothing);
        expect(find.text('in a new tab'), findsNothing);
        expect(find.text('show here, at this passage'), findsNothing);
      },
    );

    testWidgets(
      'the no matches row and the passages state row follow the input and the passages state',
      (tester) async {
        await _host(tester, overrides: _fakeSources());
        await _open(tester);
        final noMatches = find.byKey(PaletteKeys.noMatches);

        // Empty input: neither, whatever Passages says.
        _passages!.emit(const PassagesSearching());
        await pumpFrames(tester);
        expect(find.byType(PassagesStateRow), findsNothing);
        expect(noMatches, findsNothing);

        await _type(tester, 'qzxv');
        expect(find.byType(PassagesStateRow), findsOneWidget);
        expect(noMatches, findsNothing, reason: 'Passages is still searching');

        _passages!.emit(const PassagesShown(rows: [], semantic: Semantic.on));
        await pumpFrames(tester);
        expect(noMatches, findsOneWidget);
        expect(find.text('no matches for “qzxv”'), findsOneWidget);
        expect(find.byType(PassagesStateRow), findsNothing);

        _passages!.emit(const PassagesIdle());
        await pumpFrames(tester);
        expect(noMatches, findsOneWidget);
        expect(find.byType(PassagesStateRow), findsNothing);

        // Rows listed: no no-matches row; an idle Passages adds no state row.
        await _type(tester, 'pricing');
        expect(noMatches, findsNothing);
        expect(find.byType(PassagesStateRow), findsNothing);

        // Passages answered with no rows next to notes: its state row.
        _passages!.emit(const PassagesShown(rows: [], semantic: Semantic.on));
        await pumpFrames(tester);
        expect(noMatches, findsNothing);
        expect(find.byType(PassagesStateRow), findsOneWidget);

        // Passage rows listed: their footer, never the state row.
        _passages!.emit(
          const PassagesShown(
            rows: [PassageItem(hit, meta: 'note')],
            semantic: Semantic.on,
          ),
        );
        await pumpFrames(tester);
        expect(find.byType(PassagesStateRow), findsNothing);
        expect(find.byType(PassagesFooter), findsOneWidget);
      },
    );

    testWidgets('an Up or Down key repeat moves the selection and is claimed', (
      tester,
    ) async {
      await _host(tester);
      await _open(tester);

      expect(
        await tester.sendKeyRepeatEvent(
          LogicalKeyboardKey.arrowDown,
          platform: 'macos',
        ),
        isTrue,
      );
      await tester.pump();
      expect(_selected(), [_cmd(PaletteCommand.newCanvas)]);
      expect(
        await tester.sendKeyRepeatEvent(
          LogicalKeyboardKey.arrowUp,
          platform: 'macos',
        ),
        isTrue,
      );
      await tester.pump();
      expect(_selected(), [_cmd(PaletteCommand.newNote)]);
    });

    testWidgets('an Enter or Esc key repeat is claimed and does nothing', (
      tester,
    ) async {
      final h = await _host(tester);
      await _open(tester);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_selected(), [_cmd(PaletteCommand.openVaultGraph)]);

      for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.escape]) {
        expect(
          await tester.sendKeyRepeatEvent(key, platform: 'macos'),
          isTrue,
          reason: 'a held $key is claimed',
        );
        await pumpFrames(tester);
        expect(_palette, findsOneWidget, reason: '$key repeat closed it');
        expect(h.tabs.navigated, isEmpty, reason: '$key repeat chose a row');
      }
    });

    testWidgets('releasing Enter, Esc, Up or Down does nothing', (
      tester,
    ) async {
      final h = await _host(tester);
      await _open(tester);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      final before = _selected();

      for (final key in [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
      ]) {
        await tester.sendKeyUpEvent(key, platform: 'macos');
        await pumpFrames(tester);
      }

      expect(_palette, findsOneWidget);
      expect(_selected(), before);
      expect(h.tabs.navigated, isEmpty);
    });

    testWidgets('the numpad Enter chooses the selected row', (tester) async {
      final h = await _host(tester);
      await _open(tester);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_selected(), [_cmd(PaletteCommand.openVaultGraph)]);

      expect(
        await tester.sendKeyEvent(
          LogicalKeyboardKey.numpadEnter,
          platform: 'macos',
        ),
        isTrue,
      );
      await pumpFrames(tester, frames: 8);

      expect(_palette, findsNothing);
      expect(h.tabs.navigated, [GraphTab(const GraphScope.vault())]);
    });

    testWidgets('a key the palette does not use is left to the field', (
      tester,
    ) async {
      await _host(tester);
      await _open(tester);

      final handled = await tester.sendKeyEvent(
        LogicalKeyboardKey.keyA,
        platform: 'macos',
      );
      await tester.pump();

      expect(handled, isFalse);
      expect(_palette, findsOneWidget);
      expect(_selected(), [_cmd(PaletteCommand.newNote)]);
    });

    testWidgets('a 950 px window shows the preview with a 902 px card', (
      tester,
    ) async {
      await _host(tester, size: const Size(950, 700));
      await _open(tester);
      expect(find.byType(PalettePreview), findsOneWidget);
      expect(tester.getSize(_palette).width, closeTo(902, 0.5));
    });

    testWidgets('a 949 px window shows the list-only card', (tester) async {
      await _host(tester, size: const Size(949, 700));
      await _open(tester);
      expect(find.byType(PalettePreview), findsNothing);
      expect(tester.getSize(_palette).width, closeTo(640, 0.5));
    });

    testWidgets('a window narrower than the card leaves 24 px each side', (
      tester,
    ) async {
      await _host(tester, size: const Size(600, 700));
      await _open(tester);
      final card = tester.getRect(_palette);
      expect(card.left, closeTo(24, 0.5));
      expect(card.width, closeTo(552, 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'showCommandPalette does nothing while another modal covers it',
      (tester) async {
        await _host(tester);
        unawaited(
          showDialog<void>(
            context: _wi77HostContext,
            builder: (_) => const AlertDialog(content: Text('other modal')),
          ),
        );
        await pumpFrames(tester);
        expect(find.text('other modal'), findsOneWidget);

        unawaited(showCommandPalette(_wi77HostContext));
        await pumpFrames(tester);

        expect(_palette, findsNothing);
        expect(find.text('other modal'), findsOneWidget);
      },
    );

    testWidgets(
      'Open today with no daily note yet shows the virtual Today note',
      (tester) async {
        final h = await _host(tester, seed: false);
        await _open(tester);
        await _type(tester, 'open today');
        expect(_selected(), [_cmd(PaletteCommand.openToday)]);

        await _key(tester, LogicalKeyboardKey.enter);
        await pumpFrames(tester, frames: 8);

        expect(h.tabs.navigated, [VirtualTodayTab('2026-11-18')]);
      },
    );

    testWidgets('the command bar open state follows the palette', (
      tester,
    ) async {
      final h = await _host(tester);
      expect(h.read(commandPaletteOpenProvider), isFalse);
      await _open(tester);
      expect(h.read(commandPaletteOpenProvider), isTrue);

      await _key(tester, LogicalKeyboardKey.escape);
      await pumpFrames(tester);
      expect(_palette, findsNothing);
      expect(h.read(commandPaletteOpenProvider), isFalse);
    });
  });
}
