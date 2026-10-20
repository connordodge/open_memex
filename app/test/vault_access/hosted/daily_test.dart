// WI #82 (V2): HostedDailyAccess over HostedClient (D13, D17), against the
// `api_v1/daily` fixture rows replayed by `fake_vault_server.dart`.
//
// Pinned wire shapes (under `/vaults/<vault>/api/v1`):
//   reads:  GET /daily-notes                 {"daily_notes":[{date,note_id,preview,review_state}]}
//           GET /daily-notes/{date}          {"daily_note":{...}|null}  (date is one
//             encoded path segment, never validated)
//           GET /notes/{id}/review           {"state","reviewed_at"}
//           GET /notes/{id}/blocks           {"blocks":[{block_id,ord,text,source,
//             created_version,created_at,start_byte,end_byte}]}
//           GET /notes/{id}/footer-chips     {"chips":[{topic_note_id,topic_title,origin}]}
//   writes: POST /notes/{daily_note_id}/footer-chips {"topic_note_id"}
//             -> {vault_id,daily_note_id,topic_note_id,origin,version}
//           DELETE /notes/{topic_note_id}/excerpts?date=D&block_ids=FROM[,TO]
//             -> {vault_id,topic_note_id,version}
//   `block_ids` is what the CLI wrapper passes to --block-ids: FROM alone, or
//   FROM,TO whenever toBlockId is given (even empty).
// Errors are MemexException.fromC1 with the CLI wrapper labels `excerpt rm`
// and `footer add`, so a hosted failure reads like the CLI failure.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/daily_access.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/daily.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';
import '../../support/vault_access_shapes.dart';

const _wi82DailyDir = '$apiV1FixturesDir/daily';
const _wi82Base = '/vaults/seed/api/v1';
const _wi82PlayerLoop = '01M5DQAYZ3WP7H0NXZZV9M2315';
const _wi82Economy = '01M5DQAYZ47QW55S90ZF0A56AH';
const _wi82Loose = '01M5DQAYZ4RYSGA8T0YEEF8QRS';
const _wi82Day17 = '01M5DQAYZ5T5B865CDF2RWAC37';
const _wi82Day18 = '01M5DQAYZ4TAPTHDWE5PNWE4W5';
const _wi82Day19 = '01M5DQAYZ51PF87XFZWSV5PWXK';
const _wi82Unknown = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';

class _Wi82Env {
  _Wi82Env(this.container, this.server, this.daily);

  final ProviderContainer container;
  final FakeVaultServer server;
  final HostedDailyAccess daily;

  http.Request get last => server.requests.last;
}

_Wi82Env _env({bool rows = true}) {
  final server = FakeVaultServer();
  if (rows) server.serveDomain('daily');
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Wi82Env(
    container,
    server,
    HostedDailyAccess(
      client: server.connect(container),
      vaultName: seedVaultName,
    ),
  );
}

/// The row of `daily/index.json` that answers [response].
FixtureRow _row(String response) =>
    loadFixtureRows(_wi82DailyDir).firstWhere((r) => r.response == response);

Map<String, Object?> _json(String response) =>
    _row(response).readResponseJson()! as Map<String, Object?>;

/// The exception the CLI wrapper builds for a failed `memex <operation>`
/// whose stderr is [response]'s C1 body.
MemexException _cliFailure(String operation, String response) =>
    MemexException.fromCliFailure(
      operation,
      MemexResult(
        exitCode: 1,
        stdout: '',
        stderr: 'memex: something went wrong\n${jsonEncode(_json(response))}\n',
      ),
    );

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

/// [e] as plain values: message, code, fields, kind.
Object? _wi82ErrorShape(Object? e) => e is MemexException
    ? {
        'message': e.message,
        'code': e.code,
        'fields': e.fields,
        'kind': e.kind.name,
      }
    : e;

void main() {
  test('HostedDailyAccess is a DailyAccess', () {
    expect(_env().daily, isA<DailyAccess>());
  });

  group('reads', () {
    test('hosted daily reads send the documented GET paths', () async {
      final env = _env();
      await env.daily.dailyNotes();
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi82Base/daily-notes');
      expect(env.last.url.query, isEmpty);

      await env.daily.dailyNoteForDate('2026-10-19');
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi82Base/daily-notes/2026-10-19');

      await env.daily.reviewState(_wi82Day19);
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi82Base/notes/$_wi82Day19/review');

      await env.daily.blocksForNote(_wi82Day19);
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi82Base/notes/$_wi82Day19/blocks');

      await env.daily.footerChips(_wi82Day19);
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi82Base/notes/$_wi82Day19/footer-chips');

      for (final r in env.server.requests) {
        expect(r.headers['authorization'], 'Bearer $fakeServerToken');
        expect(r.body, isEmpty, reason: 'reads send no body');
      }
    });

    test(
      'hosted dailyNoteForDate sends the title as one encoded segment',
      () async {
        final env = _env(rows: false);
        env.server.route(
          'GET',
          '$_wi82Base/daily-notes/a%2Fb%3Fc%20d',
          json: {'daily_note': null},
        );
        expect(await env.daily.dailyNoteForDate('a/b?c d'), isNull);
        expect(env.last.url.pathSegments.last, 'a/b?c d');
        expect(env.last.url.query, isEmpty);
      },
    );

    test('hosted dailyNoteForDate decodes a hit', () async {
      final env = _env();
      final day = (await env.daily.dailyNoteForDate('2026-10-16'))!;
      expect(day.date, '2026-10-16');
      expect(day.noteId, '01M5DQAYZ50YGKE126FXV02TEY');
      expect(day.preview, 'Morning playtest with the new crafting tree');
      expect(day.reviewState, ReviewState.unreviewed);
    });

    test(
      'hosted blocksForNote decodes all eight fields in ord order',
      () async {
        final env = _env();
        final blocks = await env.daily.blocksForNote(_wi82Day17);
        expect(vaultAccessShape(blocks), [
          {
            'BlockRow': [
              '40s3hr',
              0,
              'Tuned the shop prices.',
              'person',
              1,
              1760000360000,
              0,
              22,
            ],
          },
          {
            'BlockRow': [
              'ps0m60',
              1,
              'Then undid half of it.',
              'person',
              2,
              1792535788530,
              24,
              46,
            ],
          },
        ]);
      },
    );

    test('hosted footerChips decodes both chip origins', () async {
      final env = _env();
      expect(vaultAccessShape(await env.daily.footerChips(_wi82Day18)), [
        {
          'FooterChipRow': [_wi82Economy, 'Economy Design', 'person'],
        },
      ]);
      expect(vaultAccessShape(await env.daily.footerChips(_wi82Day19)), [
        {
          'FooterChipRow': [_wi82Economy, 'Economy Design', 'excerpt'],
        },
      ]);
    });

    test('hosted reads ignore unknown response keys', () async {
      final env = _env(rows: false);
      env.server.route(
        'GET',
        '$_wi82Base/daily-notes',
        json: {
          'daily_notes': [
            {
              'date': '2026-10-19',
              'note_id': _wi82Day19,
              'preview': 'p',
              'review_state': 'Reviewed',
              'future_field': 1,
            },
          ],
          'next_cursor': null,
        },
      );
      env.server.route(
        'GET',
        '$_wi82Base/notes/$_wi82Day19/review',
        json: {
          'state': 'Changed since review',
          'reviewed_at': 5,
          'reviewed_by': 'agent',
        },
      );
      final days = await env.daily.dailyNotes();
      expect(vaultAccessShape(days), [
        {
          'DailyNoteRow': ['2026-10-19', _wi82Day19, 'p', 'reviewed'],
        },
      ]);
      final review = await env.daily.reviewState(_wi82Day19);
      expect(vaultAccessShape(review), {
        'ReviewInfo': ['changedSinceReview', 5],
      });
    });

    test('hosted reads rethrow a C1 error instead of an empty value', () async {
      final env = _env(rows: false);
      final error = {
        'error': {'code': 'internal', 'message': 'disk on fire'},
      };
      for (final path in [
        '/daily-notes',
        '/daily-notes/2026-10-19',
        '/notes/$_wi82Day19/review',
        '/notes/$_wi82Day19/blocks',
        '/notes/$_wi82Day19/footer-chips',
      ]) {
        env.server.route('GET', '$_wi82Base$path', status: 500, json: error);
      }
      final calls = <Future<Object?> Function()>[
        env.daily.dailyNotes,
        () => env.daily.dailyNoteForDate('2026-10-19'),
        () => env.daily.reviewState(_wi82Day19),
        () => env.daily.blocksForNote(_wi82Day19),
        () => env.daily.footerChips(_wi82Day19),
      ];
      for (final call in calls) {
        final e = await _outcome(call());
        expect(e, isA<MemexException>());
        expect((e! as MemexException).code, 'internal');
      }
    });

    test('hosted daily read errors are labelled get', () async {
      final env = _env(rows: false);
      final paths = [
        '/daily-notes',
        '/daily-notes/2026-10-19',
        '/notes/$_wi82Day19/review',
        '/notes/$_wi82Day19/blocks',
        '/notes/$_wi82Day19/footer-chips',
      ];
      final calls = <Future<Object?> Function()>[
        env.daily.dailyNotes,
        () => env.daily.dailyNoteForDate('2026-10-19'),
        () => env.daily.reviewState(_wi82Day19),
        () => env.daily.blocksForNote(_wi82Day19),
        () => env.daily.footerChips(_wi82Day19),
      ];
      // A C1 body.
      for (final path in paths) {
        env.server.route(
          'GET',
          '$_wi82Base$path',
          status: 500,
          json: {
            'error': {'code': 'internal', 'message': 'disk on fire'},
          },
        );
      }
      for (final call in calls) {
        final e = await _outcome(call());
        expect(e, isA<MemexException>());
        expect((e! as MemexException).message, 'get failed: disk on fire');
      }
      // A failure without a C1 body.
      for (final path in paths) {
        env.server.route('GET', '$_wi82Base$path', status: 502, json: []);
      }
      for (final call in calls) {
        final e = await _outcome(call());
        expect(e, isA<MemexException>());
        expect((e! as MemexException).message, 'get failed: HTTP 502');
        expect((e as MemexException).code, isNull);
      }
    });

    test(
      'an unknown review state label throws a MemexException with a null code',
      () async {
        final env = _env(rows: false);
        Map<String, Object?> day(String state) => {
          'date': '2026-10-19',
          'note_id': _wi82Day19,
          'preview': 'p',
          'review_state': state,
        };
        env.server
          ..route(
            'GET',
            '$_wi82Base/notes/$_wi82Day19/review',
            json: {'state': 'reviewed', 'reviewed_at': null},
          )
          ..route(
            'GET',
            '$_wi82Base/daily-notes',
            json: {
              'daily_notes': [day('Archived')],
            },
          )
          ..route(
            'GET',
            '$_wi82Base/daily-notes/2026-10-19',
            json: {'daily_note': day('Reviewed ')},
          );
        final cases = <String, Future<Object?> Function()>{
          'reviewed': () => env.daily.reviewState(_wi82Day19),
          'Archived': env.daily.dailyNotes,
          'Reviewed ': () => env.daily.dailyNoteForDate('2026-10-19'),
        };
        for (final MapEntry(key: label, value: call) in cases.entries) {
          final e = await _outcome(call());
          expect(e, isA<MemexException>(), reason: label);
          final m = e! as MemexException;
          expect(m.message, 'get: unknown review state: $label');
          expect(m.code, isNull, reason: label);
          expect(m.kind, MemexErrorKind.other, reason: label);
        }
      },
    );
  });

  group('addFooterChip', () {
    test(
      'hosted addFooterChip posts the topic and returns the CLI struct',
      () async {
        final env = _env();
        final result = await env.daily.addFooterChip(
          dailyNoteId: _wi82Day17,
          topicNoteId: _wi82PlayerLoop,
        );
        expect(env.last.method, 'POST');
        expect(env.last.url.path, '$_wi82Base/notes/$_wi82Day17/footer-chips');
        expect(env.last.url.query, isEmpty);
        expect(
          env.last.headers['content-type'],
          startsWith('application/json'),
        );
        expect(jsonDecode(env.last.body), {'topic_note_id': _wi82PlayerLoop});
        final want = _json('footer_add.json');
        expect(vaultAccessShape(result), {
          'FooterAddResult': [
            want['vault_id'],
            want['daily_note_id'],
            want['topic_note_id'],
            'person',
            want['version'],
          ],
        });
        expect(result.vaultId, seedVaultId());

        // A repeat answers the same struct.
        final again = await env.daily.addFooterChip(
          dailyNoteId: _wi82Day17,
          topicNoteId: _wi82PlayerLoop,
        );
        expect(vaultAccessShape(again), vaultAccessShape(result));
      },
    );

    test('hosted addFooterChip failures carry the CLI codes', () async {
      final env = _env();
      // Skip to the error rows: they follow the successful adds.
      await env.daily.addFooterChip(
        dailyNoteId: _wi82Day17,
        topicNoteId: _wi82PlayerLoop,
      );
      final cases = [
        (
          _wi82Loose,
          _wi82PlayerLoop,
          'role_rule',
          'footer_add_role_rule_daily.json',
        ),
        (
          _wi82Day18,
          _wi82Day19,
          'role_rule',
          'footer_add_role_rule_topic.json',
        ),
        (
          _wi82Unknown,
          _wi82PlayerLoop,
          'not_found',
          'footer_add_not_found.json',
        ),
        (
          _wi82Day18,
          _wi82Unknown,
          'not_found',
          'footer_add_unknown_topic.json',
        ),
      ];
      for (final (daily, topic, code, response) in cases) {
        final e = await _outcome(
          env.daily.addFooterChip(dailyNoteId: daily, topicNoteId: topic),
        );
        expect(e, isA<MemexException>(), reason: response);
        expect((e! as MemexException).code, code, reason: response);
        expect(
          _wi82ErrorShape(e),
          _wi82ErrorShape(_cliFailure('footer add', response)),
          reason: '$response reads like the CLI failure',
        );
      }
    });
  });

  group('removeExcerpt', () {
    test(
      'hosted removeExcerpt deletes by date and block_ids and returns the CLI struct',
      () async {
        final env = _env();
        final result = await env.daily.removeExcerpt(
          topicNoteId: _wi82Economy,
          date: '2026-10-19',
          fromBlockId: 'et8g8y',
        );
        expect(env.last.method, 'DELETE');
        expect(env.last.url.path, '$_wi82Base/notes/$_wi82Economy/excerpts');
        expect(env.last.url.queryParameters, {
          'date': '2026-10-19',
          'block_ids': 'et8g8y',
        });
        expect(env.last.body, isEmpty);
        final want = _json('excerpt_rm.json');
        expect(vaultAccessShape(result), {
          'ExcerptRemoveResult': [
            want['vault_id'],
            want['topic_note_id'],
            want['version'],
          ],
        });
      },
    );

    test('hosted removeExcerpt sends a range as from,to', () async {
      final env = _env(rows: false);
      env.server.route(
        'DELETE',
        '$_wi82Base/notes/$_wi82Economy/excerpts?date=2026-10-18&block_ids=6v4mr7%2C65a642',
        json: {
          'vault_id': seedVaultId(),
          'topic_note_id': _wi82Economy,
          'version': 9,
        },
      );
      env.server.route(
        'DELETE',
        '$_wi82Base/notes/$_wi82Economy/excerpts?date=2026-10-18&block_ids=6v4mr7,65a642',
        json: {
          'vault_id': seedVaultId(),
          'topic_note_id': _wi82Economy,
          'version': 9,
        },
      );
      final result = await env.daily.removeExcerpt(
        topicNoteId: _wi82Economy,
        date: '2026-10-18',
        fromBlockId: '6v4mr7',
        toBlockId: '65a642',
      );
      expect(env.last.url.queryParameters, {
        'date': '2026-10-18',
        'block_ids': '6v4mr7,65a642',
      });
      expect(result.version, 9);
      expect(result.topicNoteId, _wi82Economy);
    });

    test('hosted removeExcerpt failures carry the CLI codes', () async {
      final env = _env();
      // The first call removes the excerpt; the same call again is
      // not_found (the next fixture row).
      await env.daily.removeExcerpt(
        topicNoteId: _wi82Economy,
        date: '2026-10-19',
        fromBlockId: 'et8g8y',
      );
      final cases = [
        (
          _wi82Economy,
          '2026-10-19',
          'et8g8y',
          null,
          'not_found',
          'excerpt_rm_not_found.json',
        ),
        (
          _wi82Day18,
          '2026-10-18',
          '6v4mr7',
          null,
          'role_rule',
          'excerpt_rm_role_rule.json',
        ),
        (
          _wi82Unknown,
          '2026-10-19',
          'et8g8y',
          null,
          'not_found',
          'excerpt_rm_unknown_topic.json',
        ),
        (
          _wi82Economy,
          '2026-13-01',
          'et8g8y',
          null,
          'invalid_date',
          'excerpt_rm_invalid_date.json',
        ),
        (
          _wi82Economy,
          '2026-10-19',
          'et8g8y',
          '',
          'invalid_argument',
          'excerpt_rm_blank_block_id.json',
        ),
        (
          _wi82Economy,
          '2026-10-19',
          '',
          null,
          'invalid_argument',
          'excerpt_rm_empty_block_ids.json',
        ),
      ];
      for (final (topic, date, from, to, code, response) in cases) {
        final e = await _outcome(
          env.daily.removeExcerpt(
            topicNoteId: topic,
            date: date,
            fromBlockId: from,
            toBlockId: to,
          ),
        );
        expect(e, isA<MemexException>(), reason: response);
        expect((e! as MemexException).code, code, reason: response);
        expect(
          _wi82ErrorShape(e),
          _wi82ErrorShape(_cliFailure('excerpt rm', response)),
          reason: '$response reads like the CLI failure',
        );
      }
    });

    test('a C1 body from the excerpt route reads like the CLI failure', () async {
      final env = _env(rows: false);
      final body = {
        'error': {
          'code': 'version_conflict',
          'message': 'version conflict: note $_wi82Economy is at version 4',
          'current_version': 4,
          'note_id': _wi82Economy,
        },
      };
      env.server.route(
        'DELETE',
        '$_wi82Base/notes/$_wi82Economy/excerpts?date=2026-10-19&block_ids=et8g8y',
        status: 409,
        json: body,
      );
      final e = await _outcome(
        env.daily.removeExcerpt(
          topicNoteId: _wi82Economy,
          date: '2026-10-19',
          fromBlockId: 'et8g8y',
        ),
      );
      final cli = MemexException.fromCliFailure(
        'excerpt rm',
        MemexResult(exitCode: 1, stdout: '', stderr: jsonEncode(body)),
      );
      expect(_wi82ErrorShape(e), _wi82ErrorShape(cli));
      expect((e! as MemexException).kind, MemexErrorKind.versionConflict);
      expect((e as MemexException).fields, {
        'current_version': 4,
        'note_id': _wi82Economy,
      });
    });

    test(
      'hosted writes fail at once when the server cannot be reached',
      () async {
        final env = _env();
        env.server.failure = FakeServerFailure.refused;
        expect(
          await _outcome(
            env.daily.removeExcerpt(
              topicNoteId: _wi82Economy,
              date: '2026-10-19',
              fromBlockId: 'et8g8y',
            ),
          ),
          isA<VaultUnreachableException>(),
        );
        expect(
          await _outcome(
            env.daily.addFooterChip(
              dailyNoteId: _wi82Day17,
              topicNoteId: _wi82PlayerLoop,
            ),
          ),
          isA<VaultUnreachableException>(),
        );
        expect(env.server.requests, hasLength(2), reason: 'no retry, no queue');
      },
    );
  });
}
