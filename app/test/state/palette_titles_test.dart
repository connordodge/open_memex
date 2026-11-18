// WI #77 (56-A3, Spec #59 reqs 13-16, 42, TD5; D19; AC 10, 14-17): the
// Command palette's Notes and Recent source, read through #76's
// `paletteTitlesSourceProvider` with #77's `paletteTitlesOverride` in a
// plain ProviderContainer. Kept alive by a listener, as the open palette
// keeps it.
//
// Seams: a `LocalVaultAccess` over a FakeVaultDb whose notes domain records
// every `allTitles` limit, and can hold or fail the palette's read (any
// limit other than the 1,000 `noteTitlesAsyncProvider` passes); a FakeClock
// for the relative metas.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/state/palette_titles.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../support/canvas_seeds.dart';
import '../support/daily_seed.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';

const _wi77Vault = '/vaults/My Vault';

/// 2026-11-18 09:00 local.
final _now = DateTime(2026, 11, 18, 9);

int _hoursAgo(num hours) => _now
    .subtract(Duration(minutes: (hours * 60).round()))
    .millisecondsSinceEpoch;

class _Wi77Notes extends LocalNotesAccess {
  _Wi77Notes({required super.vaultPath, super.db});

  /// Every `allTitles` limit, in call order.
  final limits = <int>[];

  /// While set, the palette's read (a limit other than 1,000) waits for it.
  Completer<void>? hold;

  /// When set, the palette's read throws it (after [hold]).
  Object? failure;

  /// The palette's reads: every limit but `noteTitlesAsyncProvider`'s.
  List<int> get paletteLimits => [
    for (final l in limits)
      if (l != 1000) l,
  ];

  @override
  Future<List<NoteTitle>> allTitles({int limit = 1000}) async {
    limits.add(limit);
    if (limit != 1000) {
      final held = hold;
      if (held != null) await held.future;
      final error = failure;
      if (error != null) throw error;
    }
    return super.allTitles(limit: limit);
  }
}

class _Wi77Titles {
  _Wi77Titles({bool seed = true}) {
    db = FakeVaultDb.v5();
    addTearDown(db.close);
    if (seed) {
      db.seedNote(
        id: 'n-pricing',
        title: 'Pricing model',
        updatedAt: _hoursAgo(2),
      );
      db.seedNote(id: 'n-backlog', title: 'Backlog', updatedAt: _hoursAgo(96));
      db.seedNote(
        id: 'n-feedback',
        title: 'Feedback log',
        updatedAt: _hoursAgo(144),
      );
      db.seedDailyNote('2026-11-18', id: 'd-today', updatedAt: _hoursAgo(1));
      db.seedDailyNote(
        '2026-11-17',
        id: 'd-yesterday',
        updatedAt: _hoursAgo(24),
      );
      db.seedCanvas(
        'cv-backend',
        'Backend migration',
        updatedAt: _hoursAgo(336),
      );
    }
    notes = _Wi77Notes(vaultPath: _wi77Vault, db: db);
  }

  late final FakeVaultDb db;
  late final _Wi77Notes notes;
  ProviderContainer? _container;

  ProviderContainer get container => _container!;

  /// Builds the container and starts listening (the palette opening).
  ProviderContainer start({bool listen = true}) {
    final c = ProviderContainer(
      overrides: [
        currentVaultProvider.overrideWith(
          (_) => const LocalVaultRef(_wi77Vault),
        ),
        vaultDbProvider.overrideWithValue(db),
        memexCliProvider.overrideWithValue(null),
        clockProvider.overrideWithValue(FakeClock(_now)),
        uiStateStoreProvider.overrideWithValue(null),
        vaultAccessProvider.overrideWith(
          (_) => LocalVaultAccess(vaultPath: _wi77Vault, db: db, notes: notes),
        ),
        paletteTitlesOverride,
      ],
    );
    addTearDown(c.dispose);
    _container = c;
    if (listen) open();
    return c;
  }

  ProviderSubscription<PaletteTitlesSource>? _sub;

  /// The palette opens: something listens to the source.
  void open() =>
      _sub = container.listen(paletteTitlesSourceProvider, (_, _) {});

  /// The palette closes: nothing listens any more.
  void close() => _sub?.close();

  List<NoteItem> rows(String query) =>
      container.read(paletteTitlesSourceProvider)(query);

  List<String> ids(String query) => [for (final r in rows(query)) r.noteId];

  NoteItem row(String query, String id) {
    final found = [
      for (final r in rows(query))
        if (r.noteId == id) r,
    ];
    expect(found, hasLength(1), reason: '$id listed once for "$query"');
    return found.single;
  }
}

Future<void> _settle() => pumpEventQueue();

void main() {
  test('the titles read passes kPaletteTitleLimit once per open', () async {
    expect(kPaletteTitleLimit, 1 << 30);
    expect(kPaletteTitleLimit, greaterThan(0));

    final rig = _Wi77Titles()..start();
    await _settle();
    rig.rows('');
    rig.rows('back');
    rig.rows('pricing');
    await _settle();

    expect(rig.notes.paletteLimits, [kPaletteTitleLimit]);
    expect(rig.ids(''), isNotEmpty);
  });

  test('reopening the palette reads the titles again', () async {
    final rig = _Wi77Titles()..start();
    await _settle();
    expect(rig.notes.paletteLimits, [kPaletteTitleLimit]);

    rig.close();
    await _settle();
    rig.open();
    await _settle();
    rig.rows('');

    expect(rig.notes.paletteLimits, [kPaletteTitleLimit, kPaletteTitleLimit]);
  });

  test('a note title outside the newest 1000 matches', () async {
    final rig = _Wi77Titles(seed: false);
    rig.db.seedNote(
      id: 'n-zebra',
      title: 'Zebra crossing',
      updatedAt: _hoursAgo(5000),
    );
    for (var i = 0; i < 1000; i++) {
      rig.db.seedNote(
        id: 'n-filler-$i',
        title: 'Filler $i',
        updatedAt: _hoursAgo(1) - i,
      );
    }
    rig.start();
    await _settle();

    expect(rig.ids('zebra'), ['n-zebra']);
  });

  test(
    'the empty input lists the 8 newest notes newest first as Recent with their kinds and metas',
    () async {
      final rig = _Wi77Titles();
      for (var i = 1; i <= 5; i++) {
        rig.db.seedNote(
          id: 'n-archive-$i',
          title: 'Archive note $i',
          updatedAt: _hoursAgo(190 + 10 * i),
        );
      }
      rig.start();
      await _settle();

      final rows = rig.rows('');
      expect(
        [for (final r in rows) r.noteId],
        [
          'd-today',
          'n-pricing',
          'd-yesterday',
          'n-backlog',
          'n-feedback',
          'n-archive-1',
          'n-archive-2',
          'n-archive-3',
        ],
        reason: 'canvases are not in Recent (Spec Out of Scope)',
      );
      expect(
        [for (final r in rows) r.kind],
        [
          PaletteNoteKind.daily,
          PaletteNoteKind.note,
          PaletteNoteKind.daily,
          PaletteNoteKind.note,
          PaletteNoteKind.note,
          PaletteNoteKind.note,
          PaletteNoteKind.note,
          PaletteNoteKind.note,
        ],
      );
      expect(
        [for (final r in rows) r.meta],
        [
          'daily · today',
          'note · 2 h ago',
          'daily · 1 d ago',
          'note · 4 d ago',
          'note · 6 d ago',
          'note · 1 w ago',
          'note · 1 w ago',
          'note · 1 w ago',
        ],
      );
      expect(rows.first.title, '2026-11-18');
      expect(
        rows.first.id,
        const PaletteItemId(PaletteItemKind.daily, 'd-today'),
      );
      expect(
        rows[1].id,
        const PaletteItemId(PaletteItemKind.note, 'n-pricing'),
      );
      for (final r in rows) {
        expect(r.matched, isEmpty, reason: '${r.title}: nothing typed');
      }
    },
  );

  test(
    'typing back lists notes and canvases best first with matched characters',
    () async {
      final rig = _Wi77Titles()..start();
      await _settle();

      final rows = rig.rows('back');
      expect(
        [for (final r in rows) r.title],
        ['Backlog', 'Backend migration', 'Feedback log'],
      );
      expect(
        [for (final r in rows) r.kind],
        [PaletteNoteKind.note, PaletteNoteKind.canvas, PaletteNoteKind.note],
      );
      expect(
        [for (final r in rows) r.meta],
        ['note · 4 d ago', 'canvas · 2 w ago', 'note · 6 d ago'],
      );
      expect(
        [for (final r in rows) r.matched],
        [
          [0, 1, 2, 3],
          [0, 1, 2, 3],
          [4, 5, 6, 7],
        ],
      );
      expect(
        rows[1].id,
        const PaletteItemId(PaletteItemKind.canvas, 'cv-backend'),
      );
    },
  );

  test('a typed daily note is listed with its daily kind', () async {
    final rig = _Wi77Titles()..start();
    await _settle();

    final row = rig.row('2026-11-17', 'd-yesterday');
    expect(row.kind, PaletteNoteKind.daily);
    expect(row.meta, 'daily · 1 d ago');
    expect(row.id, const PaletteItemId(PaletteItemKind.daily, 'd-yesterday'));
  });

  test('notes that tie on score list newer updated_at first', () async {
    final rig = _Wi77Titles(seed: false);
    // Same length, both prefix matches: equal fuzzyScore.
    rig.db.seedNote(id: 'n-old', title: 'Plan A', updatedAt: _hoursAgo(50));
    rig.db.seedNote(id: 'n-new', title: 'Plan B', updatedAt: _hoursAgo(3));
    rig.db.seedNote(id: 'n-mid', title: 'Plan C', updatedAt: _hoursAgo(20));
    rig.db.seedCanvas('cv-plan', 'Plan D', updatedAt: _hoursAgo(10));
    rig.start();
    await _settle();

    expect(rig.ids('plan'), ['n-new', 'cv-plan', 'n-mid', 'n-old']);
  });

  test('a better match lists before a newer weaker one', () async {
    final rig = _Wi77Titles(seed: false);
    rig.db.seedNote(id: 'n-sub', title: 'Old plan', updatedAt: _hoursAgo(1));
    rig.db.seedNote(id: 'n-pre', title: 'Plan', updatedAt: _hoursAgo(90));
    rig.start();
    await _settle();

    expect(rig.ids('plan'), ['n-pre', 'n-sub']);
  });

  test('at most 8 notes rows are listed', () async {
    final rig = _Wi77Titles(seed: false);
    for (var i = 0; i < 6; i++) {
      rig.db.seedNote(
        id: 'n-topic-$i',
        title: 'Topic $i',
        updatedAt: _hoursAgo(i + 1),
      );
    }
    for (var i = 0; i < 4; i++) {
      rig.db.seedCanvas(
        'cv-topic-$i',
        'Topic map $i',
        updatedAt: _hoursAgo(i + 1),
      );
    }
    rig.start();
    await _settle();

    final ids = rig.ids('topic');
    expect(ids, hasLength(8));
    // The six shorter titles score higher than the four canvases.
    expect(ids.take(6), [for (var i = 0; i < 6; i++) 'n-topic-$i']);
    expect(ids.skip(6), ['cv-topic-0', 'cv-topic-1']);
  });

  test('a title scoring zero or below is not a match', () async {
    final rig = _Wi77Titles(seed: false);
    // A scattered subsequence in a long title scores 100 + 4 - 152 < 0.
    rig.db.seedNote(
      id: 'n-long',
      title: 'q${'a' * 150}j',
      updatedAt: _hoursAgo(1),
    );
    rig.db.seedNote(id: 'n-short', title: 'qaj', updatedAt: _hoursAgo(2));
    rig.start();
    await _settle();

    expect(rig.ids('qj'), ['n-short']);
  });

  test(
    'daily notes come from the daily notes source not from the title',
    () async {
      final rig = _Wi77Titles(seed: false);
      // A plain note whose title looks like a date stays a note.
      rig.db.seedNote(
        id: 'n-datelike',
        title: '2026-11-16',
        updatedAt: _hoursAgo(3),
      );
      rig.db.seedDailyNote('2026-11-15', id: 'd-15', updatedAt: _hoursAgo(4));
      rig.start();
      await _settle();

      expect(rig.row('2026-11-1', 'n-datelike').kind, PaletteNoteKind.note);
      expect(rig.row('2026-11-1', 'd-15').kind, PaletteNoteKind.daily);
      expect(rig.row('', 'n-datelike').meta, 'note · 3 h ago');
      expect(rig.row('', 'd-15').meta, 'daily · 4 h ago');
    },
  );

  test('the age meta steps from hours to days to weeks', () async {
    final rig = _Wi77Titles(seed: false);
    for (final (id, hours) in [
      ('n-23h', 23.5),
      ('n-24h', 24),
      ('n-167h', 167),
      ('n-168h', 168),
      ('n-3w', 24 * 7 * 3 + 5),
    ]) {
      rig.db.seedNote(id: id, title: id, updatedAt: _hoursAgo(hours));
    }
    rig.start();
    await _settle();

    expect(rig.row('', 'n-23h').meta, 'note · 23 h ago');
    expect(rig.row('', 'n-24h').meta, 'note · 1 d ago');
    expect(rig.row('', 'n-167h').meta, 'note · 6 d ago');
    expect(rig.row('', 'n-168h').meta, 'note · 1 w ago');
    expect(rig.row('', 'n-3w').meta, 'note · 3 w ago');
  });

  test('a note stamped after the clock never reads a negative age', () async {
    final rig = _Wi77Titles(seed: false);
    // The wall clock jumped back: the note looks 5 h in the future.
    rig.db.seedNote(id: 'n-future', title: 'Ahead', updatedAt: _hoursAgo(-5));
    rig.start();
    await _settle();

    final meta = rig.row('', 'n-future').meta;
    expect(meta, startsWith('note · '));
    expect(meta, isNot(contains('-')));
  });

  test(
    'while the titles read is pending Notes and Recent seed from noteTitlesAsyncProvider',
    () async {
      final rig = _Wi77Titles();
      final c = rig.start(listen: false);
      // The rest of the app has read the titles already.
      await c.read(noteTitlesAsyncProvider.future);
      // A note that only the palette's own read can see.
      rig.db.seedNote(
        id: 'n-fresh',
        title: 'Fresh idea',
        updatedAt: _hoursAgo(0.5),
      );
      rig.notes.hold = Completer<void>();
      rig.open();
      await _settle();

      expect(rig.notes.paletteLimits, [kPaletteTitleLimit]);
      expect(rig.ids(''), [
        'd-today',
        'n-pricing',
        'd-yesterday',
        'n-backlog',
        'n-feedback',
      ], reason: 'seeded from noteTitlesAsyncProvider');
      expect(rig.ids('back'), contains('n-backlog'));

      rig.notes.hold!.complete();
      await _settle();

      expect(rig.ids('').first, 'n-fresh', reason: 'the read answered');
      expect(rig.ids('fresh'), ['n-fresh']);
    },
  );

  test('a failed titles read leaves Notes and Recent out', () async {
    final rig = _Wi77Titles();
    final c = rig.start(listen: false);
    await c.read(noteTitlesAsyncProvider.future);
    rig.notes
      ..hold = Completer<void>()
      ..failure = StateError('titles read failed');
    rig.open();
    await _settle();
    expect(rig.ids(''), isNotEmpty, reason: 'seeded while pending');

    rig.notes.hold!.complete();
    await _settle();

    expect(rig.rows(''), isEmpty);
    expect(rig.rows('back'), isEmpty);
    expect(rig.rows('pricing'), isEmpty);
  });

  test(
    'a vaultRevisionProvider change re-reads the titles with the same limit',
    () async {
      final rig = _Wi77Titles();
      final c = rig.start();
      await _settle();
      expect(rig.ids('backstage'), isEmpty);

      rig.db.seedNote(
        id: 'n-backstage',
        title: 'Backstage',
        updatedAt: _hoursAgo(0.5),
      );
      c.read(vaultRevisionProvider.notifier).state++;
      await _settle();

      expect(rig.notes.paletteLimits, [kPaletteTitleLimit, kPaletteTitleLimit]);
      expect(rig.ids('backstage'), ['n-backstage']);
      expect(rig.ids('back'), [
        'n-backlog',
        'n-backstage',
        'cv-backend',
        'n-feedback',
      ]);
    },
  );

  test('a canvas renamed and re-read shows its new title', () async {
    final rig = _Wi77Titles();
    final c = rig.start();
    await _settle();
    expect(rig.ids('launch'), isEmpty);

    rig.db.seedCanvas('cv-launch', 'Launch map', updatedAt: _hoursAgo(1));
    c.read(vaultRevisionProvider.notifier).state++;
    await _settle();

    expect(rig.row('launch', 'cv-launch').kind, PaletteNoteKind.canvas);
    expect(rig.row('launch', 'cv-launch').meta, 'canvas · 1 h ago');
  });
}
