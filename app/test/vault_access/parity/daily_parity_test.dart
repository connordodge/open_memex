// WI #82 (V2), AC 2, 3 and 4: the daily reads hold one contract on both sides.
//
// - AC 2: the local `DailyReads` (`LocalDailyAccess` over
//   `seededFakeVaultDb()`) on the frozen seed equal the `api_v1/daily`
//   fixture rows, parsed into the app's models.
// - AC 3: every hosted daily read, driven through `fake_vault_server.dart`
//   on the same rows, returns equal models; the review strings map to
//   `ReviewState` by their exact labels.
// - AC 4: a date without a daily note (or a string that isn't a date) is
//   null on both sides.
//
// Only the rows before the first write row are compared with the local seed:
// later GET rows show the vault after the fixture's writes.
//
// API under test:
//   HostedDailyAccess({required HostedClient client, required String vaultName})
//     .dailyNotes / dailyNoteForDate / reviewState / blocksForNote /
//      footerChips
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/daily_access.dart';
import 'package:open_memex_app/src/vault_access/hosted/daily.dart';
import 'package:open_memex_app/src/vault_access/local/daily.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';
import '../../support/vault_access_shapes.dart';

const _wi82DailyDir = '$apiV1FixturesDir/daily';
const _wi82Base = '/vaults/seed/api/v1';

class _Wi82Pair {
  _Wi82Pair(this.hosted, this.local, this.server);

  final HostedDailyAccess hosted;
  final LocalDailyAccess local;
  final FakeVaultServer server;
}

_Wi82Pair _pair() {
  final server = FakeVaultServer()..serveDomain('daily');
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  final db = seededFakeVaultDb();
  addTearDown(db.close);
  return _Wi82Pair(
    HostedDailyAccess(
      client: server.connect(container),
      vaultName: seedVaultName,
    ),
    LocalDailyAccess(vaultPath: '/unused/wi82', db: db),
    server,
  );
}

/// The read kinds of the daily routes.
enum _Wi82Read { dailyNotes, forDate, review, blocks, chips }

/// A seed-state GET row: its kind, its argument (date or note id) and its
/// fixture response.
class _Wi82ReadRow {
  _Wi82ReadRow(this.kind, this.arg, this.row);

  final _Wi82Read kind;
  final String arg;
  final FixtureRow row;

  Object? get json => row.readResponseJson();
}

/// Every GET row before the first write row.
List<_Wi82ReadRow> _seedReadRows() {
  final out = <_Wi82ReadRow>[];
  for (final row in loadFixtureRows(_wi82DailyDir)) {
    if (row.method != 'GET') break;
    final uri = Uri.parse(row.path);
    expect(uri.path.startsWith(_wi82Base), isTrue, reason: row.path);
    final seg = uri.pathSegments.sublist(4);
    final (kind, arg) = switch (seg) {
      ['daily-notes'] => (_Wi82Read.dailyNotes, ''),
      ['daily-notes', final d] => (_Wi82Read.forDate, d),
      ['notes', final id, 'review'] => (_Wi82Read.review, id),
      ['notes', final id, 'blocks'] => (_Wi82Read.blocks, id),
      ['notes', final id, 'footer-chips'] => (_Wi82Read.chips, id),
      _ => throw StateError('unknown daily read row ${row.path}'),
    };
    out.add(_Wi82ReadRow(kind, arg, row));
  }
  return out;
}

ReviewState _wi82State(Object? label) =>
    ReviewState.values.singleWhere((s) => s.label == label);

DailyNoteRow? _wi82DailyNote(Object? json) {
  if (json == null) return null;
  final m = json as Map<String, Object?>;
  return DailyNoteRow(
    date: m['date']! as String,
    noteId: m['note_id']! as String,
    preview: m['preview']! as String,
    reviewState: _wi82State(m['review_state']),
  );
}

/// The fixture response of [r] parsed into the model the read returns.
Object? _wi82Parsed(_Wi82ReadRow r) {
  final m = r.json! as Map<String, Object?>;
  return switch (r.kind) {
    _Wi82Read.dailyNotes => [
      for (final d in m['daily_notes']! as List) _wi82DailyNote(d),
    ],
    _Wi82Read.forDate => _wi82DailyNote(m['daily_note']),
    _Wi82Read.review => ReviewInfo(
      state: _wi82State(m['state']),
      reviewedAt: m['reviewed_at'] as int?,
    ),
    _Wi82Read.blocks => [
      for (final b in (m['blocks']! as List).cast<Map<String, Object?>>())
        BlockRow(
          blockId: b['block_id']! as String,
          ord: b['ord']! as int,
          text: b['text']! as String,
          source: b['source']! as String,
          createdVersion: b['created_version']! as int,
          createdAt: b['created_at']! as int,
          startByte: b['start_byte']! as int,
          endByte: b['end_byte']! as int,
        ),
    ],
    _Wi82Read.chips => [
      for (final c in (m['chips']! as List).cast<Map<String, Object?>>())
        FooterChipRow(
          topicNoteId: c['topic_note_id']! as String,
          topicTitle: c['topic_title']! as String,
          origin: c['origin']! as String,
        ),
    ],
  };
}

Future<Object?> _wi82Read(DailyAccess access, _Wi82ReadRow r) {
  final arg = Uri.decodeComponent(r.arg);
  return switch (r.kind) {
    _Wi82Read.dailyNotes => access.dailyNotes(),
    _Wi82Read.forDate => access.dailyNoteForDate(arg),
    _Wi82Read.review => access.reviewState(arg),
    _Wi82Read.blocks => access.blocksForNote(arg),
    _Wi82Read.chips => access.footerChips(arg),
  };
}

void main() {
  test('the daily fixture has seed read rows for every read route', () {
    final kinds = {for (final r in _seedReadRows()) r.kind};
    expect(kinds, _Wi82Read.values.toSet());
  });

  test('local daily reads on the seed equal the parsed fixture rows', () async {
    final p = _pair();
    final rows = _seedReadRows();
    for (final r in rows) {
      expect(
        vaultAccessShape(await _wi82Read(p.local, r)),
        vaultAccessShape(_wi82Parsed(r)),
        reason: r.row.path,
      );
    }
    // 1 list, 9 dates, 7 review states, 6 block lists, 6 chip lists.
    expect(rows.length, 29);
  });

  test(
    'hosted daily reads through the fake server equal the local reads',
    () async {
      final p = _pair();
      for (final r in _seedReadRows()) {
        expect(
          vaultAccessShape(await _wi82Read(p.hosted, r)),
          vaultAccessShape(await _wi82Read(p.local, r)),
          reason: r.row.path,
        );
      }
      final paths = [for (final q in p.server.requests) q.url.path];
      expect(paths, [
        for (final r in _seedReadRows()) Uri.parse(r.row.path).path,
      ], reason: 'one request per read, on the fixture path');
    },
  );

  test('hosted daily reads equal the parsed fixture rows', () async {
    final p = _pair();
    for (final r in _seedReadRows()) {
      expect(
        vaultAccessShape(await _wi82Read(p.hosted, r)),
        vaultAccessShape(_wi82Parsed(r)),
        reason: r.row.path,
      );
    }
  });

  test(
    'hosted review strings map to ReviewState by their exact labels',
    () async {
      final p = _pair();
      final byLabel = <String, ReviewState>{};
      for (final r in _seedReadRows()) {
        if (r.kind != _Wi82Read.review) continue;
        final label = (r.json! as Map)['state']! as String;
        byLabel[label] = (await p.hosted.reviewState(r.arg))!.state;
      }
      expect(byLabel, {
        'Unreviewed': ReviewState.unreviewed,
        'Reviewed': ReviewState.reviewed,
        'Changed since review': ReviewState.changedSinceReview,
      });
      final days = await p.hosted.dailyNotes();
      expect(
        [for (final d in days) d.reviewState],
        [
          ReviewState.unreviewed,
          ReviewState.reviewed,
          ReviewState.changedSinceReview,
          ReviewState.unreviewed,
          ReviewState.unreviewed,
        ],
      );
    },
  );

  test('hosted reviewState keeps reviewed_at and null for no row', () async {
    final p = _pair();
    final day17 = await p.hosted.reviewState('01M5DQAYZ5T5B865CDF2RWAC37');
    expect(day17!.state, ReviewState.changedSinceReview);
    expect(day17.reviewedAt, 1760001020000);
    final day15 = await p.hosted.reviewState('01M5DQAYZ592W2515HPSDF5Q16');
    expect(day15!.state, ReviewState.unreviewed);
    expect(day15.reviewedAt, isNull);
  });

  test('dailyNoteForDate without a daily note is null on both sides', () async {
    final p = _pair();
    for (final date in [
      '2026-10-20',
      'not-a-date',
      'Loose Thought',
      'Broken Frontmatter',
    ]) {
      expect(await p.local.dailyNoteForDate(date), isNull, reason: date);
      expect(await p.hosted.dailyNoteForDate(date), isNull, reason: date);
    }
    expect(p.server.requests.map((r) => r.url.path), [
      '$_wi82Base/daily-notes/2026-10-20',
      '$_wi82Base/daily-notes/not-a-date',
      '$_wi82Base/daily-notes/Loose%20Thought',
      '$_wi82Base/daily-notes/Broken%20Frontmatter',
    ]);
  });
}
