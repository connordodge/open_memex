// Test support for WI #28 (A10): live daily-note updates, the save-conflict
// merge and the captured-text gutter.
//
// - [PollSeed] seeds a daily note whose blocks carry real UTF-8 byte ranges
//   and simulates the server writes the poller must notice (agent append,
//   quick entry, footer chip) the way memex core makes them: new body,
//   version + 1, a new `updated_at`, new block rows.
// - [PollCliFakes] answers `memex update` against the FakeVaultDb with a hook
//   that can race a server write in before the version check.
// - [pumpLiveWorkspace] is `pumpWorkspace` with extra provider overrides (to
//   count the poller's reads) and returns a [LiveRobot] that finds widgets by
//   the WI's stable Keys only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/main.dart';
import 'package:open_memex_app/src/editor/conflict_merge.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_harness.dart';
import 'fake_clock.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';

/// Today for every live-update test: the [FakeClock]'s date.
const liveToday = '2026-10-03';

/// Id of today's daily note in the live-update fixtures.
const liveDailyId = 'daily-2026-10-03';

/// Footer topics used by the fixtures.
const liveZetaId = 'topic-zeta';
const liveZetaTitle = 'Zeta Game';
const liveAlphaId = 'topic-alpha';
const liveAlphaTitle = 'Alpha Topic';

/// One block of a seeded daily note's person section, in order.
class SeedBlock {
  const SeedBlock(
    this.blockId,
    this.text, {
    this.source = 'person',
    this.createdVersion = 1,
    this.createdAt,
  });

  final String blockId;
  final String text;

  /// `person`, `agent` or `quick-entry`.
  final String source;
  final int createdVersion;

  /// Local time the block was created; defaults to 2026-10-03 08:00.
  final DateTime? createdAt;
}

/// UTF-8 byte length of [s].
int utf8Length(String s) => utf8.encode(s).length;

extension PollSeed on FakeVaultDb {
  /// Seeds a `role: daily` note [id] titled [date] whose person section is
  /// [blocks] joined with the C3.1 separator (`appendToPerson`), with one
  /// `blocks` row per entry carrying its real UTF-8 `start_byte`/`end_byte`,
  /// and the footer [chips] (topic id, title) as topic notes, footer rows
  /// and footer lines. Returns the note's content.
  String seedLiveDaily({
    String id = liveDailyId,
    String date = liveToday,
    List<SeedBlock> blocks = const [SeedBlock('p-morning', 'Morning pages')],
    List<(String, String)> chips = const [(liveZetaId, liveZetaTitle)],
    int version = 3,
    int updatedAt = 1759474800000,
  }) {
    var person = '';
    final ranges = <(int, int)>[];
    for (final b in blocks) {
      person = appendToPerson(person, b.text);
      final end = utf8Length(person) - 1; // the block's trailing "\n"
      ranges.add((end - utf8Length(b.text), end));
    }
    for (final (topicId, title) in chips) {
      final exists = db.select('SELECT 1 FROM notes WHERE id = ?', [topicId]);
      if (exists.isEmpty) {
        seedNote(id: topicId, title: title, role: 'topic');
      }
    }
    final content = assembleDailyBody(person, [for (final c in chips) c.$2]);
    seedNote(
      id: id,
      title: date,
      role: 'daily',
      content: content,
      version: version,
      createdAt: 1759474800000,
      updatedAt: updatedAt,
    );
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      _insertBlock(
        id,
        b.blockId,
        ord: i,
        text: b.text,
        source: b.source,
        startByte: ranges[i].$1,
        endByte: ranges[i].$2,
        createdVersion: b.createdVersion,
        createdAt: b.createdAt ?? DateTime(2026, 10, 3, 8),
      );
    }
    for (final (topicId, _) in chips) {
      db.execute(
        'INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, '
        'created_at) VALUES (?, ?, ?, ?)',
        [id, topicId, 'excerpt', 1759474800000],
      );
    }
    return content;
  }

  /// The server appends [text] to the end of note [noteId]'s person section
  /// (C3.1, as `append_to_daily_note` / `memex append` do): new body,
  /// version + 1, `updated_at` = [at], and a new last block [blockId] with
  /// [source] and `created_version` = the new version. Returns the new
  /// version.
  int serverAppend(
    String noteId,
    String text, {
    required String blockId,
    required DateTime at,
    String source = 'agent',
  }) {
    final row = liveNote(noteId);
    final body = splitDailyBody(row.content);
    final person = appendToPerson(body.person, text);
    final end = utf8Length(person) - 1;
    final next = row.version + 1;
    db.execute(
      'UPDATE notes SET content_md = ?, version = ?, updated_at = ? '
      'WHERE id = ?',
      [
        assembleDailyBody(person, body.chips),
        next,
        at.millisecondsSinceEpoch,
        noteId,
      ],
    );
    final ord =
        ((db.select(
                  'SELECT COALESCE(MAX(ord), -1) AS m FROM blocks '
                  'WHERE note_id = ?',
                  [noteId],
                ).first['m']
                as num)
            .toInt()) +
        1;
    _insertBlock(
      noteId,
      blockId,
      ord: ord,
      text: text,
      source: source,
      startByte: end - utf8Length(text),
      endByte: end,
      createdVersion: next,
      createdAt: at,
    );
    return next;
  }

  /// The server adds footer chip [topicId] ([title]) to note [noteId] (a
  /// footer write, as `add_excerpt` / `memex footer add` do): footer row,
  /// re-rendered footer lines, version + 1, `updated_at` = [at]. The person
  /// section is unchanged. Returns the new version.
  int serverAddFooterChip(
    String noteId,
    String topicId,
    String title, {
    required DateTime at,
  }) {
    final exists = db.select('SELECT 1 FROM notes WHERE id = ?', [topicId]);
    if (exists.isEmpty) seedNote(id: topicId, title: title, role: 'topic');
    db.execute(
      'INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, '
      'created_at) VALUES (?, ?, ?, ?)',
      [noteId, topicId, 'excerpt', at.millisecondsSinceEpoch],
    );
    final row = liveNote(noteId);
    final body = splitDailyBody(row.content);
    final next = row.version + 1;
    db.execute(
      'UPDATE notes SET content_md = ?, version = ?, updated_at = ? '
      'WHERE id = ?',
      [
        assembleDailyBody(body.person, [...body.chips, title]),
        next,
        at.millisecondsSinceEpoch,
        noteId,
      ],
    );
    return next;
  }

  /// The stored content, version and `updated_at` of note [id].
  ({String content, int version, int updatedAt}) liveNote(String id) {
    final r = db.select(
      'SELECT content_md, version, updated_at FROM notes WHERE id = ?',
      [id],
    ).first;
    return (
      content: r['content_md'] as String,
      version: (r['version'] as num).toInt(),
      updatedAt: (r['updated_at'] as num).toInt(),
    );
  }

  void _insertBlock(
    String noteId,
    String blockId, {
    required int ord,
    required String text,
    required String source,
    required int startByte,
    required int endByte,
    required int createdVersion,
    required DateTime createdAt,
  }) {
    db.execute(
      'INSERT INTO blocks (note_id, block_id, ord, start_byte, end_byte, '
      'text, content_hash, source, created_version, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        noteId,
        blockId,
        ord,
        startByte,
        endByte,
        text,
        'h-$blockId',
        source,
        createdVersion,
        createdAt.millisecondsSinceEpoch,
      ],
    );
  }
}

/// Called before `memex update` checks the version; [call] is 1 for the
/// first update. A server write made here races the app's save.
typedef BeforeUpdate = void Function(int call, FakeCliCall update);

extension PollCliFakes on FakeMemexCli {
  /// `memex settings get` with the C2.11 sample.
  void onSettingsGet() =>
      on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout));

  /// `memex update` against [db]: runs [before], then checks
  /// `--expected-version` (C1 `version_conflict` with `expected`/`current`
  /// on a mismatch), writes stdin as the content, bumps the version, sets
  /// `updated_at` to the [clock]'s now and prints the update JSON.
  void onUpdateServer(
    FakeVaultDb db, {
    required FakeClock clock,
    BeforeUpdate? before,
  }) {
    var n = 0;
    on('update', (call) {
      n++;
      before?.call(n, call);
      final id = call.flag('note-id')!;
      final expected = int.parse(call.flag('expected-version')!);
      final rows = db.db.select('SELECT version FROM notes WHERE id = ?', [id]);
      if (rows.isEmpty) {
        return FakeMemexCli.error('not_found', 'note $id not found');
      }
      final current = (rows.first['version'] as num).toInt();
      if (current != expected) {
        return FakeMemexCli.error(
          'version_conflict',
          'version conflict: expected $expected, current $current',
          {'expected': expected, 'current': current},
        );
      }
      final next = current + 1;
      final updatedAt = clock.now().millisecondsSinceEpoch;
      db.db.execute(
        'UPDATE notes SET content_md = ?, version = ?, updated_at = ? '
        'WHERE id = ?',
        [call.stdinBody ?? '', next, updatedAt, id],
      );
      return FakeMemexCli.ok(
        jsonEncode({
          'vault_id': '01HV0000000000000000000000',
          'note_id': id,
          'version': next,
          'updated_at': updatedAt,
        }),
      );
    });
  }
}

/// Counts the poller's `updated_at` reads (through
/// `noteUpdatedAtReaderProvider`).
class PollReadCounter {
  int reads = 0;
  final List<String> noteIds = [];

  void record(String noteId) {
    reads++;
    noteIds.add(noteId);
  }
}

/// [pumpWorkspace] with extra [overrides]: SharedPreferences mock settings,
/// a temp-dir vault, [db], [cli] (a `settings get` handler is added), and
/// [clock] (default 2026-10-03 09:00 local). The workspace launches on the
/// Today tab, i.e. today's daily note when [db] holds one.
Future<LiveRobot> pumpLiveWorkspace(
  WidgetTester tester, {
  required FakeVaultDb db,
  required FakeMemexCli cli,
  FakeClock? clock,
  List<Override> overrides = const [],
}) async {
  final vaultDir = Directory.systemTemp.createTempSync('omv-live');
  final fakeClock = clock ?? FakeClock(DateTime(2026, 10, 3, 9));
  cli.onSettingsGet();

  SharedPreferences.setMockInitialValues({
    'memex.binary_path': 'fake-memex',
    'memex.recent_vaults': <String>[vaultDir.path],
    'memex.last_vault': vaultDir.path,
  });
  final settings = await SettingsController.load();

  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;

  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      currentVaultProvider.overrideWith((_) => LocalVaultRef(vaultDir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(fakeClock),
      ...overrides,
    ],
  );

  addTearDown(() => _deleteQuietly(vaultDir));
  addTearDown(db.close);
  addTearDown(container.dispose);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const OpenMemexApp(),
    ),
  );
  await pumpFrames(tester, frames: 8);

  return LiveRobot(
    tester,
    WorkspaceHarness(
      container: container,
      db: db,
      cli: cli,
      clock: fakeClock,
      vaultPath: vaultDir.path,
    ),
  );
}

/// Robot for the live-update, conflict and gutter journeys (WI #28). Finds
/// widgets by Key only: `editor-body`, `capture-gutter`,
/// `capture-gutter-rule-<blockId>`, `save-indicator`, `inline-error`,
/// `footer-chip-<topicNoteId>`.
///
/// Time: the poller and (per D14) the save debounce run on the [FakeClock];
/// [fireDebounce] also moves the test binding's time in case the debounce
/// timer is still a real `Timer`. [settle] only pumps zero-length frames, so
/// it never fires a timer by itself.
class LiveRobot {
  LiveRobot(this.tester, this.h);

  final WidgetTester tester;
  final WorkspaceHarness h;

  FakeClock get clock => h.clock;
  FakeVaultDb get db => h.db;

  // ---------------------------------------------------------------- finders

  /// The daily person field's [EditableText] (Key `editor-body`).
  Finder get body => find.descendant(
    of: find.byKey(const Key('editor-body')),
    matching: find.byType(EditableText),
  );

  Finder get gutter => find.byKey(const Key('capture-gutter'));
  Finder gutterRule(String blockId) =>
      find.byKey(Key('capture-gutter-rule-$blockId'));

  /// Every gutter rule (`capture-gutter-rule-<blockId>`).
  Finder get allGutterRules => find.byWidgetPredicate((w) {
    final k = w.key;
    return k is ValueKey<String> && k.value.startsWith('capture-gutter-rule-');
  });

  Finder get saveIndicator => find.byKey(const Key('save-indicator'));
  Finder get inlineError => find.byKey(const Key('inline-error'));
  Finder footerChip(String topicNoteId) =>
      find.byKey(Key('footer-chip-$topicNoteId'));

  /// The editor page's scroll view: the nearest [Scrollable] above the
  /// person field.
  Finder get pageScrollable => find
      .ancestor(
        of: find.byKey(const Key('editor-body')),
        matching: find.byType(Scrollable),
      )
      .first;

  // ------------------------------------------------------------------ state

  EditableText get _bodyWidget => tester.widget<EditableText>(body);
  String get bodyText => _bodyWidget.controller.text;
  TextSelection get bodySelection => _bodyWidget.controller.selection;
  bool get bodyHasFocus => _bodyWidget.focusNode.hasFocus;
  double get scrollPixels =>
      tester.state<ScrollableState>(pageScrollable).position.pixels;

  int get revision => h.read(vaultRevisionProvider);
  EditorStateValue get editor => h.read(editorControllerProvider);
  List<FakeCliCall> get updates => h.cli.callsFor('update');
  WorkspaceTab? get activeTab => h.read(tabsProvider).activeTab;

  /// The save indicator's label (`synced` when clean).
  bool saveIndicatorShows(String label) => find
      .descendant(of: saveIndicator, matching: find.text(label))
      .evaluate()
      .isNotEmpty;

  /// The vertical centre (global) of the text line holding UTF-16 [offset]
  /// of the person field.
  double lineCenterY(int offset) {
    final render = tester.state<EditableTextState>(body).renderEditable;
    final caret = render.getLocalRectForCaret(TextPosition(offset: offset));
    return render.localToGlobal(caret.center).dy;
  }

  /// The person field's global rect.
  Rect get bodyRect => tester.getRect(body);

  // ---------------------------------------------------------------- actions

  /// Flush futures and rebuilds without moving any clock.
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  /// Move only the [FakeClock] (fires the poller) and settle.
  Future<void> advance(Duration by) async {
    clock.advance(by);
    await settle();
  }

  /// One poll interval (2 s) on the [FakeClock].
  Future<void> poll() => advance(const Duration(seconds: 2));

  /// Let the 500 ms save debounce fire once (on the [FakeClock] and on the
  /// binding's time) and the fake CLI round trips complete.
  Future<void> fireDebounce() async {
    clock.advance(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await settle();
  }

  /// Replace the person field's text as the person typing would.
  Future<void> type(String text) async {
    await tester.enterText(body, text);
    await tester.pump();
  }

  /// Focus the person field and put the caret at [offset].
  Future<void> placeCaret(int offset) async {
    await tester.showKeyboard(body);
    await tester.pump();
    _bodyWidget.controller.selection = TextSelection.collapsed(offset: offset);
    await tester.pump();
  }

  /// Scroll the editor page to [pixels].
  Future<void> scrollTo(double pixels) async {
    tester.state<ScrollableState>(pageScrollable).position.jumpTo(pixels);
    await tester.pump();
  }

  /// Hover the mouse over [finder]'s centre and let any tooltip appear.
  Future<TestGesture> hover(Finder finder) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    return gesture;
  }
}

/// True when [finder]'s widget, or one below it, paints [color] as a
/// `ColoredBox` or `DecoratedBox` (`Container(color:)` / `decoration:`).
bool paintsColor(WidgetTester tester, Finder finder, Color color) {
  final candidates = find.descendant(
    of: finder,
    matching: find.byWidgetPredicate(
      (w) => w is ColoredBox || w is DecoratedBox,
    ),
    matchRoot: true,
  );
  for (final w in tester.widgetList(candidates)) {
    if (w is ColoredBox && w.color == color) return true;
    if (w is DecoratedBox) {
      final d = w.decoration;
      if (d is BoxDecoration && d.color == color) return true;
    }
  }
  return false;
}

/// [RenderBox] global rect helper for [finder].
Rect globalRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return box.localToGlobal(Offset.zero) & box.size;
}

void _deleteQuietly(Directory dir) {
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      // A queued UiStateStore write raced the delete; try again.
    }
  }
}
