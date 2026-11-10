// WI #361 (Spec #357 Req 17, 18, 21–25, 34): seams for the picker row tests.
// - `wi361PumpRows` pumps bare `RecentRow`s (so a test can pass
//   `open: true`, which the full-screen picker never does) over mock prefs,
//   a FakeFileRevealer, a FakeVaultTrash and a recording picker-actions
//   seam. No real Finder, Trash, network or `memex` binary.
// - `wi361PumpMenu` pumps a bare `VaultMenuRegion` around a plain box.
// - Menu probes: which `vault-menu-*` items show and in what order, and
//   arrow-key focus moves.
// Helpers carry the `wi361` prefix so stacked siblings never collide.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/file_revealer.dart';
import 'package:open_memex_app/src/state/picker_actions.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/state/vault_trash.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/picker/recent_row.dart';
import 'package:open_memex_app/src/widgets/vault_menu.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_file_revealer.dart';
import 'fake_vault_trash.dart';
import 'token_store_fakes.dart';
import 'vault_folders.dart';
import 'vault_picker_harness.dart';
import 'wi349_keyboard.dart';

/// The sidebar's pill palette, in its order (`_vaultColorFor` in
/// `widgets/sidebar.dart` ~502).
const wi361Palette = [
  OmColors.accent,
  OmColors.info,
  OmColors.warn,
  OmColors.agent,
  OmColors.fg2,
];

/// The sidebar's hash of [label]: `palette[label.hashCode.abs() % 5]`.
Color wi361Bucket(String label) =>
    wi361Palette[label.hashCode.abs() % wi361Palette.length];

/// The first of a run of candidate names that [ok] accepts.
String wi361NameWhere(bool Function(String name) ok) {
  final candidates = [
    'memex',
    'work-notes',
    'reading-notes',
    'journal',
    'team',
    for (var i = 0; i < 200; i++) 'vault$i',
  ];
  return candidates.firstWhere(ok);
}

/// A real vault folder named exactly [name] (inside a fresh temp folder),
/// so the row's label is known. Removed after the test.
String wi361VaultNamed(String name) {
  final parent = createPlainFolder('om361_');
  final path = p.join(parent.path, name);
  initVaultFolder(path);
  return path;
}

/// Makes the vault folder at [path] stop being a vault (`VaultDb.isVault`
/// false): its `memex.db` goes away.
void wi361Unvault(String path) {
  File(p.join(path, 'memex.db')).deleteSync();
}

/// The keys of the vault menu items, in the menu's order.
const wi361MenuKeys = [
  'vault-menu-finder',
  'vault-menu-remove',
  'vault-menu-delete',
  'vault-menu-manage',
];

/// The `vault-menu-*` items now shown, top to bottom.
List<String> wi361MenuShown(WidgetTester tester) {
  final shown = [
    for (final k in wi361MenuKeys)
      if (find.byKey(Key(k)).evaluate().isNotEmpty) k,
  ];
  shown.sort(
    (a, b) => tester
        .getRect(find.byKey(Key(a)))
        .top
        .compareTo(tester.getRect(find.byKey(Key(b))).top),
  );
  return shown;
}

/// How many `surface3` Materials are on screen: the menu panel is one (a
/// secondary click that wrongly opens an empty menu still draws it, with no
/// items), so a test compares the count before and after the click.
int wi361MenuSurfaces() => find
    .byWidgetPredicate((w) => w is Material && w.color == OmColors.surface3)
    .evaluate()
    .length;

/// A secondary (right) click on [target], at [at] when given (global), else
/// at its centre; then lets the menu draw.
Future<void> wi361SecondaryClick(
  WidgetTester tester,
  Finder target, {
  Offset? at,
}) async {
  await tester.tapAt(
    at ?? tester.getCenter(target),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await wi97Settle(tester);
}

/// Presses the down arrow until the focus is inside [target]; fails after
/// [max] presses.
Future<void> wi361ArrowTo(
  WidgetTester tester,
  Finder target, {
  int max = 8,
}) async {
  for (var i = 0; i < max; i++) {
    if (wi349FocusIn(target)) return;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
  }
  if (wi349FocusIn(target)) return;
  fail('the down arrow never reached $target');
}

String _wi361EncodeRef(VaultRef ref) => jsonEncode(switch (ref) {
  LocalVaultRef(:final path) => {'kind': 'local', 'path': path},
  HostedVaultRef(:final serverId, :final vaultName) => {
    'kind': 'hosted',
    'server': serverId,
    'vault': vaultName,
  },
});

/// Everything a bare-row or bare-menu test needs.
class Wi361Rows {
  Wi361Rows({
    required this.container,
    required this.revealer,
    required this.trash,
    required this.actions,
  });

  final ProviderContainer container;
  final FakeFileRevealer revealer;
  final FakeVaultTrash trash;
  final Wi97PickerActions actions;

  /// Every `onOpen` call, as the entry of the row that made it.
  final List<VaultRef> opened = [];

  AppSettings get settings => container.read(settingsProvider);
}

Future<Wi361Rows> _wi361Env(
  WidgetTester tester, {
  required List<VaultRef> recents,
  required List<SavedServer> savedServers,
  required Map<VaultRef, RecentRowOutcome> recorded,
}) async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': 'fake-memex',
    'memex.recent_refs': [for (final r in recents) _wi361EncodeRef(r)],
    'memex.vault_servers': [
      for (final s in savedServers)
        jsonEncode({'id': s.id, 'name': s.name, 'url': s.url}),
    ],
  });
  final tokens = FakeTokenStore({
    for (final s in savedServers) s.id: wi97TokenFor(s.id),
  });
  final settings = (await tester.runAsync(
    () => loadSettingsKeepingPickedBinary(tokenStore: tokens),
  ))!;
  final revealer = FakeFileRevealer();
  final trash = FakeVaultTrash();
  final actions = Wi97PickerActions();
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      fileRevealerProvider.overrideWithValue(revealer),
      vaultTrashProvider.overrideWithValue(trash),
      pickerActionsProvider.overrideWithValue(actions),
    ],
  );
  addTearDown(container.dispose);
  for (final MapEntry(:key, :value) in recorded.entries) {
    container.read(recentRowOutcomeProvider(key).notifier).state = value;
  }
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  return Wi361Rows(
    container: container,
    revealer: revealer,
    trash: trash,
    actions: actions,
  );
}

Widget _wi361App(ProviderContainer container, Widget body) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          backgroundColor: OmColors.surface1,
          body: Center(child: SizedBox(width: 560, child: body)),
        ),
      ),
    );

/// Bare `RecentRow`s for [entries] (index = position), 6 apart in a 560
/// column, with [entries] as the recents in prefs. The row at [openIndex]
/// gets `open: true`; every row records its taps in `Wi361Rows.opened`.
Future<Wi361Rows> wi361PumpRows(
  WidgetTester tester, {
  required List<VaultRef> entries,
  int? openIndex,
  bool binaryMissing = false,
  List<SavedServer> savedServers = const [wi97Nas],
  Map<VaultRef, RecentRowOutcome> recorded = const {},
}) async {
  final env = await _wi361Env(
    tester,
    recents: entries,
    savedServers: savedServers,
    recorded: recorded,
  );
  await tester.pumpWidget(
    _wi361App(
      env.container,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < entries.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: RecentRow(
                index: i,
                entry: entries[i],
                opening: false,
                binaryMissing: binaryMissing,
                onOpen: () => env.opened.add(entries[i]),
                open: i == openIndex,
              ),
            ),
        ],
      ),
    ),
  );
  await wi97Settle(tester);
  return env;
}

/// The plain 300x56 box a bare [VaultMenuRegion] wraps (Key
/// `wi361-anchor`).
final wi361Anchor = find.byKey(const Key('wi361-anchor'));

/// A bare [VaultMenuRegion] for [vault] around [wi361Anchor], with [vault]
/// in the recents.
Future<Wi361Rows> wi361PumpMenu(
  WidgetTester tester, {
  required VaultRef vault,
  required bool isOpen,
  VoidCallback? onManage,
  List<SavedServer> savedServers = const [wi97Nas],
}) async {
  final env = await _wi361Env(
    tester,
    recents: [vault],
    savedServers: savedServers,
    recorded: const {},
  );
  await tester.pumpWidget(
    _wi361App(
      env.container,
      Align(
        alignment: Alignment.topLeft,
        child: VaultMenuRegion(
          vault: vault,
          isOpen: isOpen,
          onManage: onManage,
          child: const SizedBox(
            key: Key('wi361-anchor'),
            width: 300,
            height: 56,
            child: ColoredBox(color: OmColors.surface2),
          ),
        ),
      ),
    ),
  );
  await wi97Settle(tester);
  return env;
}

/// [body] in the bare-row app (mock prefs with [recents], the fakes), for
/// a test that drives a seam such as `showVaultInFinder` directly.
Future<Wi361Rows> wi361PumpBody(
  WidgetTester tester,
  Widget body, {
  List<VaultRef> recents = const [],
}) async {
  final env = await _wi361Env(
    tester,
    recents: recents,
    savedServers: const [wi97Nas],
    recorded: const {},
  );
  await tester.pumpWidget(_wi361App(env.container, body));
  await wi97Settle(tester);
  return env;
}
