// WI #251 (A4): pumps the sidebar's Tags mode over a canned tags domain (a
// double that `extends LocalTagsAccess`, D21) or over a FakeVaultDb, with
// the real `tabsProvider` recorded by a TabsRecorder.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/tags_reads.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:open_memex_app/src/widgets/sidebar/tags_pane.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'recording_tabs.dart';

TagRow tagRow(String tag, int count, {bool system = false}) =>
    TagRow(tag: tag, noteCount: count, system: system);

TagNoteRow tagNote(
  String id,
  String title, {
  String? firstLine,
  int updatedAt = 1000,
}) => TagNoteRow(
  noteId: id,
  title: title,
  role: null,
  firstLine: firstLine,
  updatedAt: updatedAt,
);

/// Board B2 cell 1: the tags of a vault with both kinds, alphabetical as
/// `TagsAccess.allTags` answers them (system tags among the rest).
List<TagRow> standardTagRows() => [
  tagRow('agent-authored', 87, system: true),
  tagRow('health', 2),
  tagRow('inbox', 87, system: true),
  tagRow('memex', 12),
  tagRow('pricing', 3),
  tagRow('reading', 5),
  tagRow('work', 7),
];

/// The notes behind [standardTagRows]'s `pricing`, `work`, `inbox` and
/// `agent-authored`, newest first as `TagsAccess.notesForTag` answers them
/// (board B2 cell 2).
Map<String, List<TagNoteRow>> standardTagNotes() => {
  'pricing': [
    tagNote('d-today', '2026-11-06', updatedAt: 3000),
    tagNote('p-1', 'Pricing', updatedAt: 2000),
    tagNote(
      'd-old',
      '2026-11-02',
      firstLine: 'renewal tiers feel wrong #pricing',
      updatedAt: 1000,
    ),
  ],
  'work': [
    tagNote(
      'w-1',
      'Call notes',
      firstLine: 'call with Sam about pricing #work',
      updatedAt: 2000,
    ),
    tagNote('w-2', 'Roadmap', updatedAt: 1000),
  ],
  'inbox': [tagNote('i-1', 'Inbox one', updatedAt: 2000)],
  'agent-authored': [tagNote('a-1', 'Agent note', updatedAt: 2000)],
};

/// A tags domain over canned rows. Reads can be held on a gate and made to
/// throw, and are counted.
class TagsDouble extends LocalTagsAccess {
  TagsDouble({List<TagRow>? rows, Map<String, List<TagNoteRow>>? notes})
    : rows = rows ?? standardTagRows(),
      notes = notes ?? standardTagNotes(),
      super(vaultPath: '/tmp/om-251-vault');

  List<TagRow> rows;
  Map<String, List<TagNoteRow>> notes;

  /// While true every `allTags` call waits for its own completer in
  /// [tagGates].
  bool gateTags = false;
  final tagGates = <Completer<void>>[];

  /// Thrown by `allTags` while set.
  Object? failTags;

  int allTagsCalls = 0;
  final notesCalls = <String>[];

  @override
  Future<List<TagRow>> allTags() async {
    allTagsCalls++;
    final snapshot = List<TagRow>.of(rows);
    if (gateTags) {
      final gate = Completer<void>();
      tagGates.add(gate);
      await gate.future;
    }
    final error = failTags;
    if (error != null) throw error;
    return snapshot;
  }

  @override
  Future<List<TagNoteRow>> notesForTag(String tag) async {
    notesCalls.add(tag);
    return List<TagNoteRow>.of(notes[tag] ?? const []);
  }
}

class TagsEnv {
  TagsEnv(this.vault, this.tabs);

  final Directory vault;
  final TabsRecorder tabs;
  late ProviderContainer container;

  /// The `WidgetRef` of a Consumer above the app, for `revealTag`.
  late WidgetRef ref;

  /// `<vault>/.memex/ui_state.json`.
  File get uiStateFile => File(p.join(vault.path, '.memex', 'ui_state.json'));

  /// Lets reads reach the screen: the futures, the provider notifications and
  /// a frame after a post-frame callback. Never `pumpAndSettle`: the sidebar
  /// has a repeating pulse.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// A temp vault directory removed after the test. A queued ui_state write may
/// land during the delete, so retry and then give up quietly.
Directory tagsTempVault() {
  final dir = Directory.systemTemp.createTempSync('om251');
  addTearDown(() {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        // A queued write raced the delete.
      }
    }
  });
  return dir;
}

Override _access(Directory vault, TagsDouble? tags, VaultDb? db) =>
    vaultAccessProvider.overrideWithValue(
      LocalVaultAccess(vaultPath: vault.path, db: db, tags: tags),
    );

Future<TagsEnv> _pump(
  WidgetTester tester, {
  required Widget Function(TagsEnv env) home,
  required TagsDouble? tags,
  required Size surface,
  required double textScale,
  required bool hosted,
  required VaultDb? db,
  required Directory vault,
  required List<Override> overrides,
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': '/nonexistent/memex-test-binary',
  });
  final settings = await SettingsController.load();
  final env = TagsEnv(vault, TabsRecorder());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith((_) => settings),
        currentVaultProvider.overrideWith((_) => LocalVaultRef(vault.path)),
        vaultDbProvider.overrideWithValue(db),
        memexCliProvider.overrideWithValue(null),
        _access(vault, tags, db),
        if (hosted) vaultIsHostedProvider.overrideWithValue(true),
        env.tabs.override,
        ...overrides,
      ],
      child: Consumer(
        builder: (context, ref, _) {
          env.ref = ref;
          env.container = ProviderScope.containerOf(context);
          return MaterialApp(
            theme: buildOmTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(
              backgroundColor: OmColors.surface1,
              body: Align(alignment: Alignment.topLeft, child: home(env)),
            ),
          );
        },
      ),
    ),
  );
  await env.settle(tester);
  return env;
}

/// The Tags pane alone in a [width] x [height] box (the host's Key is
/// `tags-host`), over [tags] or, when [db] is given, over that database.
Future<TagsEnv> pumpTagsPane(
  WidgetTester tester, {
  TagsDouble? tags,
  VaultDb? db,
  double width = 268,
  double height = 600,
  double textScale = 1.0,
  bool hosted = false,
  List<Override> overrides = const [],
}) async {
  assert(tags != null || db != null);
  return _pump(
    tester,
    home: (_) => SizedBox(
      key: const Key('tags-host'),
      width: width,
      height: height,
      child: const TagsPane(),
    ),
    tags: tags,
    surface: const Size(1200, 1000),
    textScale: textScale,
    hosted: hosted,
    db: db,
    vault: tagsTempVault(),
    overrides: overrides,
  );
}

/// The whole sidebar over [tags]. [storedMode] is written to the vault's
/// `ui_state.json` before the sidebar mounts. Text is scaled down as the
/// other sidebar tests do: the test font is far wider than the real one.
Future<TagsEnv> pumpTagsSidebar(
  WidgetTester tester, {
  required TagsDouble tags,
  Object? storedMode,
  Directory? vault,
  double textScale = 0.5,
  bool hosted = false,
  double height = 1000,
  List<Override> overrides = const [],
}) async {
  final dir = vault ?? tagsTempVault();
  if (storedMode != null) {
    final f = File(p.join(dir.path, '.memex', 'ui_state.json'));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('{"sidebar_mode": ${_json(storedMode)}}');
  }
  return _pump(
    tester,
    home: (_) => Sidebar(onNewNote: () {}),
    tags: tags,
    surface: Size(1200, height),
    textScale: textScale,
    hosted: hosted,
    db: null,
    vault: dir,
    overrides: overrides,
  );
}

String _json(Object v) => v is String ? '"$v"' : '$v';

/// The fill colour of the first decorated box under [of] (null when none).
Color? firstFill(WidgetTester tester, Finder of) {
  final boxes = find.descendant(of: of, matching: find.byType(DecoratedBox));
  for (final e in boxes.evaluate()) {
    final d = (e.widget as DecoratedBox).decoration;
    if (d is BoxDecoration && d.color != null) return d.color;
  }
  return null;
}

/// Whether a decorated box under [of] is filled with [color].
bool hasFill(WidgetTester tester, Finder of, Color color) {
  for (final e
      in find
          .descendant(of: of, matching: find.byType(DecoratedBox))
          .evaluate()) {
    final d = (e.widget as DecoratedBox).decoration;
    if (d is BoxDecoration && d.color == color) return true;
  }
  return false;
}
