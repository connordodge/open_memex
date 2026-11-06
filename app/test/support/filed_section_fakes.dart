// WI #260 (F8): fixtures for the `Filed from this day` section. A fake
// `memex` server that holds where the blocks of one day are filed and answers
// `filing`, `excerpt add|move|remove-block` from that state (so a write is
// visible after the section re-reads), recording domain doubles for the
// calls, and a harness that opens a daily note's Activity tab.
//
// Keys: `<t>` is a topic note id, `<b>` a block id.
//   filed-section, filed-row-<t>-<b>, filed-move-<t>-<b>,
//   filed-remove-<t>-<b>, not-filed-row-<b>, file-in-<b>,
//   filed-topic-field, filed-why-field, filed-confirm, filed-cancel,
//   filed-topic-option-<t> (one option row of the dialog's list; WI #260
//   names it because the issue gives no key), filed-topic-create (the
//   `Create "<name>"` row).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import 'activity_seeds.dart';
import 'app_harness.dart';
import 'daily_seed.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'feedback_seeds.dart';
import 'footer_cli_fakes.dart';
import 'review_fakes.dart' show openNoteTab;
import 'today_cli_fakes.dart';
import 'topics_access_doubles.dart';

const f260Date = '2026-11-05';
const f260DailyId = 'daily-2026-11-05';

// Topic notes of the fixture (all `role: topic`).
const f260Loop = 'topic-loop';
const f260Economy = 'topic-economy';
const f260Level = 'topic-level'; // in the Smart Folder `Games`
const f260Sleep = 'topic-sleep';
const f260Orphan = 'topic-orphan';
const f260Loose = 'note-loose'; // role-less: never a target

// Blocks of the day.
const f260B1 = 'b1'; // Player Loop
const f260B2 = 'b2'; // Player Loop
const f260B3 = 'b3'; // Economy
const f260N1 = 'n1'; // not filed

const f260B1Text = 'coyote time for ledge jumps';
const f260B2Text = 'check the jump arc';
const f260B3Text = 'price the gold sink';
const f260N1Text = 'call the dentist';

Key f260Row(String t, String b) => Key('filed-row-$t-$b');
Key f260Move(String t, String b) => Key('filed-move-$t-$b');
Key f260Remove(String t, String b) => Key('filed-remove-$t-$b');
Key f260NotFiledRow(String b) => Key('not-filed-row-$b');
Key f260FileIn(String b) => Key('file-in-$b');
Key f260Option(String t) => Key('filed-topic-option-$t');
const f260Section = Key('filed-section');
const f260TopicField = Key('filed-topic-field');
const f260WhyField = Key('filed-why-field');
const f260Confirm = Key('filed-confirm');
const f260Cancel = Key('filed-cancel');
const f260Create = Key('filed-topic-create');

/// One topic of the day: [blocks] are `(id, text)` in filing order.
class F260Topic {
  F260Topic(this.id, this.title, [List<(String, String)>? blocks])
    : blocks = [...?blocks];
  final String id;
  final String title;
  final List<(String, String)> blocks;
}

/// Where the blocks of the day [date] are filed, as the `memex` binary
/// answers it. [install] puts the handlers on a [FakeMemexCli].
class F260Server {
  F260Server(
    this.db, {
    required this.topics,
    required this.notFiled,
    this.reviewed = true,
    this.chipBumpsDaily = true,
  });

  final FakeVaultDb db;
  final List<F260Topic> topics;
  final List<(String, String)> notFiled;
  bool reviewed;

  /// Whether filing into a topic with no footer chip yet adds the chip and
  /// bumps the daily note's version (`excerpts.rs:116`).
  bool chipBumpsDaily;

  /// The result the next write answers instead of working (once).
  MemexResult? nextWriteError;

  int _n = 0;

  F260Topic _topic(String id) {
    for (final t in topics) {
      if (t.id == id) return t;
    }
    final title =
        db.db.select('SELECT title FROM notes WHERE id = ?', [
              id,
            ]).first['title']
            as String;
    final t = F260Topic(id, title);
    topics.add(t);
    return t;
  }

  Map<String, Object?> filingJson() => {
    'vault_id': 'V',
    'date': f260Date,
    'note_id': f260DailyId,
    'reviewed': reviewed,
    'topics': [
      for (final t in topics)
        {
          'topic_note_id': t.id,
          'title': t.title,
          'blocks': [
            for (final b in t.blocks) {'id': b.$1, 'text': b.$2},
          ],
        },
    ],
    'not_filed': [
      for (final b in notFiled) {'id': b.$1, 'text': b.$2},
    ],
  };

  /// Removes block [id] from wherever it is filed (a block the person fixed
  /// elsewhere meanwhile), without telling the app.
  void dropBlock(String id) {
    notFiled.removeWhere((b) => b.$1 == id);
    for (final t in topics) {
      t.blocks.removeWhere((b) => b.$1 == id);
    }
  }

  static String _ok(Object? json) => '${jsonEncode(json)}\n';

  void _chip(String topicId) {
    if (!chipBumpsDaily) return;
    final has = db.db.select(
      'SELECT 1 FROM footer_chips WHERE daily_note_id = ? '
      'AND topic_note_id = ?',
      [f260DailyId, topicId],
    );
    if (has.isNotEmpty) return;
    db.db.execute(
      'INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, '
      'created_at) VALUES (?, ?, ?, ?)',
      [f260DailyId, topicId, 'excerpt', 1759500000000],
    );
    db.db.execute('UPDATE notes SET version = version + 1 WHERE id = ?', [
      f260DailyId,
    ]);
  }

  MemexResult? _failure() {
    final e = nextWriteError;
    nextWriteError = null;
    return e;
  }

  static MemexResult _noBlock() =>
      FakeMemexCli.error('block_not_found', 'no such block in that topic');

  void install(FakeMemexCli cli) {
    cli.on('filing', (call) {
      if (call.flag('date') != f260Date) {
        return FakeMemexCli.error('not_found', 'no daily note');
      }
      return FakeMemexCli.ok(_ok(filingJson()));
    });
    cli.on('excerpt add', (call) {
      final failure = _failure();
      if (failure != null) return failure;
      final topic = call.flag('topic-note-id')!;
      final block = call.flag('block-id')!;
      final i = notFiled.indexWhere((b) => b.$1 == block);
      if (i < 0) return _noBlock();
      final t = _topic(topic);
      t.blocks.add(notFiled.removeAt(i));
      _chip(topic);
      return FakeMemexCli.ok(
        _ok({'vault_id': 'V', 'topic_note_id': topic, 'version': 2}),
      );
    });
    cli.on('excerpt remove-block', (call) {
      final failure = _failure();
      if (failure != null) return failure;
      final topic = call.flag('topic-note-id')!;
      final block = call.flag('block-id')!;
      final t = _topic(topic);
      final i = t.blocks.indexWhere((b) => b.$1 == block);
      if (i < 0) return _noBlock();
      notFiled.add(t.blocks.removeAt(i));
      return FakeMemexCli.ok(
        _ok({'vault_id': 'V', 'topic_note_id': topic, 'version': 3}),
      );
    });
    cli.on('excerpt move', (call) {
      final failure = _failure();
      if (failure != null) return failure;
      final from = _topic(call.flag('from-topic-note-id')!);
      final to = _topic(call.flag('to-topic-note-id')!);
      final block = call.flag('block-id')!;
      final i = from.blocks.indexWhere((b) => b.$1 == block);
      if (i < 0) return _noBlock();
      final moved = from.blocks.removeAt(i);
      to.blocks.add(moved);
      _chip(to.id);
      db.seedFeedback(
        'fb-${_n++}',
        kind: 'correction',
        source: 'person',
        noteId: f260DailyId,
        day: f260Date,
        text: call.flag('note'),
        correction: {
          'kind': 'excerpt_moved',
          'date': f260Date,
          'block_id': block,
          'preview': moved.$2,
          'from_topic_note_id': from.id,
          'from_title': from.title,
          'to_topic_note_id': to.id,
          'to_title': to.title,
        },
      );
      return FakeMemexCli.ok(
        _ok({
          'vault_id': 'V',
          'from_topic_note_id': from.id,
          'from_version': 3,
          'to_topic_note_id': to.id,
          'to_version': 4,
        }),
      );
    });
  }
}

/// The default day: Player Loop holds `b1`, `b2`; Economy holds `b3`; `n1` is
/// not filed. Deliberately not in alphabetical order, so order tests are
/// about filing order.
F260Server f260DefaultServer(FakeVaultDb db) => F260Server(
  db,
  topics: [
    F260Topic(f260Loop, 'Player Loop', [
      (f260B1, f260B1Text),
      (f260B2, f260B2Text),
    ]),
    F260Topic(f260Economy, 'Economy', [(f260B3, f260B3Text)]),
  ],
  notFiled: [(f260N1, f260N1Text)],
);

/// A V6 vault with the reviewed daily note [f260Date], five topic notes (one
/// in a Smart Folder), a role-less note and one agent entry on the day.
FakeVaultDb f260Db({bool agentEntry = true, bool reviewedRow = true}) {
  final db = FakeVaultDb.v6();
  db.seedDailyNote(f260Date, id: f260DailyId);
  if (reviewedRow) {
    db.seedDayReview(
      f260DailyId,
      contentVersion: 4,
      reviewedContentVersion: 4,
      reviewedAt: DateTime(2026, 11, 5, 14, 32).millisecondsSinceEpoch,
    );
  }
  db.seedTopicNote(f260Loop, 'Player Loop');
  db.seedTopicNote(f260Economy, 'Economy');
  db.seedTopicNote(f260Level, 'Level Design');
  db.seedTopicNote(f260Sleep, 'Sleep');
  db.seedTopicNote(f260Orphan, 'Orphan topic');
  db.seedNote(id: f260Loose, title: 'Loose thought', content: 'x');
  db.seedSmartFolder('f-games', 'Games');
  db.seedFolderMember('f-games', f260Level);
  if (agentEntry) {
    db.seedAgentChange(
      'ac-1',
      f260DailyId,
      day: f260Date,
      createdAt: DateTime(2026, 11, 5, 14, 32).millisecondsSinceEpoch,
      bullets: ['Filed two blocks'],
    );
  }
  return db;
}

/// Everything a #260 test drives.
class F260 {
  F260({
    required this.h,
    required this.db,
    required this.cli,
    required this.server,
    required this.doubles,
  });

  final WorkspaceHarness h;
  final FakeVaultDb db;
  final FakeMemexCli cli;
  final F260Server server;
  final AccessDoubles doubles;

  RecordingFeedbackAccess get feedback => doubles.feedbackAt(h.vaultPath);
  RecordingNotesAccess get notes => doubles.notesAt(h.vaultPath);

  List<RecordedCall> get moves => feedback.callsTo('moveBlock');
  List<RecordedCall> get removes => feedback.callsTo('removeBlock');
  List<RecordedCall> get files => feedback.callsTo('fileBlock');
  List<RecordedCall> get writes => [...moves, ...removes, ...files];
}

/// The `memex` fake for [db]: settings, `add` (creates topic notes), `update`
/// (saves the daily note) and the filing handlers of [server].
FakeMemexCli f260Cli(FakeVaultDb db, F260Server server) {
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..onAddCreates(db)
    ..onUpdateWrites(db);
  server.install(cli);
  return cli;
}

/// Pumps the app on a reviewed day, opens [noteId] (default the daily note)
/// as the active tab and shows the right panel's Activity tab.
Future<F260> pumpF260(
  WidgetTester tester, {
  FakeVaultDb? db,
  F260Server? server,
  String noteId = f260DailyId,
  bool openActivity = true,
}) async {
  final database = db ?? f260Db();
  final srv = server ?? f260DefaultServer(database);
  final cli = f260Cli(database, srv);
  final doubles = AccessDoubles();
  final h = await pumpWorkspace(
    tester,
    db: database,
    cli: cli,
    overrides: [doubles.override],
  );
  await openNoteTab(tester, h, noteId);
  if (openActivity) {
    h.container.read(rightPanelOpenProvider.notifier).state = true;
    h.container.read(rightPanelTabProvider.notifier).state =
        RightPanelTab.activity;
    await pumpFrames(tester);
  }
  return F260(h: h, db: database, cli: cli, server: srv, doubles: doubles);
}

// ---------- driving ----------

Future<void> f260Tap(WidgetTester tester, Key key) async {
  final f = find.byKey(key);
  expect(f, findsOneWidget, reason: '$key');
  await tester.tap(f);
  await pumpFrames(tester);
}

/// Types [text] into the dialog's topic field.
Future<void> f260TypeTopic(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(f260TopicField), text);
  await pumpFrames(tester);
}

Future<void> f260TypeWhy(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(f260WhyField), text);
  await pumpFrames(tester);
}

/// Opens `Move to…` on a row, picks [target] from the list, types [why] when
/// given and confirms.
Future<void> f260MoveTo(
  WidgetTester tester, {
  required String from,
  required String block,
  required String target,
  String? why,
}) async {
  await f260Tap(tester, f260Move(from, block));
  await f260Tap(tester, f260Option(target));
  if (why != null) await f260TypeWhy(tester, why);
  await f260Tap(tester, f260Confirm);
}

/// Text equal to [text] ignoring case (the shared Eyebrow atom upper-cases).
Finder f260TextCI(String text) => find.byWidgetPredicate(
  (w) => w is Text && w.data?.toLowerCase() == text.toLowerCase(),
  description: 'Text "$text" (any case)',
);

Finder f260In(Finder scope, Finder what) =>
    find.descendant(of: scope, matching: what);

/// The inline error inside the section.
Finder get f260Error => find.descendant(
  of: find.byKey(f260Section),
  matching: find.byKey(const Key('inline-error')),
);

/// Top edge of the widget with [key].
double f260Top(WidgetTester tester, Key key) =>
    tester.getTopLeft(find.byKey(key)).dy;

/// A daily note with a reviewed chip (used by the journey).
Future<void> f260OpenFromChip(WidgetTester tester) async {
  await f260Tap(tester, const Key('review-chip'));
}
