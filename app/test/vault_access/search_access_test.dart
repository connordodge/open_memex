// #74 (56-A1): the app search seam (Spec #59 req 34, 39). SearchHit parsing
// and value equality, the sealed result and reasons, the VaultAccess wiring
// (local default, no CLI, the hosted placeholder until #75) and the
// FakeSearchAccess double that #76-#78 drive palette state with.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_server.dart';
import '../support/search_fakes.dart';

const _vault = '/vaults/My Vault';

/// A req 34 hit object, every key present and non-null.
Map<String, Object?> _row() => {
  'note_id': '01JSEARCHDAILY0000000000002',
  'note_title': '2026-11-17',
  'note_role': 'daily',
  'day': '2026-11-17',
  'chunk_id': '01JSEARCHCHUNK0000000000002',
  'snippet': 'Talked about pricing at lunch.',
  'start_byte': 128,
  'via': '2026-11-18',
  'note_updated_at': 1731800000000,
};

/// The hit [_row] describes, built from run-time values.
SearchHit _hit({
  String? noteId,
  String? noteTitle,
  String? noteRole = 'daily',
  String? day = '2026-11-17',
  String? chunkId,
  String? snippet,
  int? startByte = 128,
  String? via = '2026-11-18',
  int? noteUpdatedAt,
}) => SearchHit(
  noteId: noteId ?? '01JSEARCHDAILY0000000000002'.toString(),
  noteTitle: noteTitle ?? '2026-11-17'.toString(),
  noteRole: noteRole,
  day: day,
  chunkId: chunkId ?? '01JSEARCHCHUNK0000000000002'.toString(),
  snippet: snippet ?? 'Talked about pricing at lunch.'.toString(),
  startByte: startByte,
  via: via,
  noteUpdatedAt: noteUpdatedAt ?? int.parse('1731800000000'),
);

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

void main() {
  group('SearchHit.fromJson', () {
    test(
      'SearchHit fromJson reads every R34 hit key, accepts null nullable keys, and rejects a missing note_id or a wrong-typed start_byte',
      () {
        expect(SearchHit.fromJson(_row()), _hit());

        final nulls = _row()
          ..['note_role'] = null
          ..['day'] = null
          ..['start_byte'] = null
          ..['via'] = null;
        final parsed = SearchHit.fromJson(nulls);
        expect(
          parsed,
          _hit(noteRole: null, day: null, startByte: null, via: null),
        );
        expect(parsed.noteId, '01JSEARCHDAILY0000000000002');
        expect(parsed.chunkId, '01JSEARCHCHUNK0000000000002');
        expect(parsed.snippet, 'Talked about pricing at lunch.');
        expect(parsed.noteUpdatedAt, 1731800000000);

        expect(
          () => SearchHit.fromJson(_row()..remove('note_id')),
          throwsFormatException,
        );
        expect(
          () => SearchHit.fromJson(_row()..['start_byte'] = '128'),
          throwsFormatException,
        );
      },
    );

    test('SearchHit fromJson reads each field into its own property', () {
      final hit = SearchHit.fromJson(_row());

      expect(hit.noteId, '01JSEARCHDAILY0000000000002');
      expect(hit.noteTitle, '2026-11-17');
      expect(hit.noteRole, 'daily');
      expect(hit.day, '2026-11-17');
      expect(hit.chunkId, '01JSEARCHCHUNK0000000000002');
      expect(hit.snippet, 'Talked about pricing at lunch.');
      expect(hit.startByte, 128);
      expect(hit.via, '2026-11-18');
      expect(hit.noteUpdatedAt, 1731800000000);
    });

    test('SearchHit fromJson accepts absent nullable keys as null', () {
      final hit = SearchHit.fromJson(
        _row()
          ..remove('note_role')
          ..remove('day')
          ..remove('start_byte')
          ..remove('via'),
      );

      expect(hit, _hit(noteRole: null, day: null, startByte: null, via: null));
    });

    for (final key in const [
      'note_id',
      'note_title',
      'chunk_id',
      'snippet',
      'note_updated_at',
    ]) {
      test('SearchHit fromJson rejects a missing or null required $key', () {
        expect(
          () => SearchHit.fromJson(_row()..remove(key)),
          throwsFormatException,
          reason: 'missing $key',
        );
        expect(
          () => SearchHit.fromJson(_row()..[key] = null),
          throwsFormatException,
          reason: 'null $key',
        );
      });
    }

    final wrongTypes = <(String, Object)>[
      ('note_id', 7),
      ('note_title', 7),
      ('note_role', 7),
      ('day', 20261117),
      ('chunk_id', 7),
      ('snippet', <String>['text']),
      ('start_byte', 1.5),
      ('via', true),
      ('note_updated_at', '1731800000000'),
    ];
    for (final (key, value) in wrongTypes) {
      test('SearchHit fromJson rejects a wrong-typed $key', () {
        expect(
          () => SearchHit.fromJson(_row()..[key] = value),
          throwsFormatException,
        );
      });
    }
  });

  group('value equality', () {
    test('SearchHit has value equality on every field', () {
      final a = _hit();
      final b = _hit();
      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);

      final differing = <String, SearchHit>{
        'noteId': _hit(noteId: 'other'),
        'noteTitle': _hit(noteTitle: 'other'),
        'noteRole': _hit(noteRole: 'topic'),
        'noteRole null': _hit(noteRole: null),
        'day': _hit(day: '2026-11-16'),
        'chunkId': _hit(chunkId: 'other'),
        'snippet': _hit(snippet: 'other'),
        'startByte': _hit(startByte: 129),
        'startByte null': _hit(startByte: null),
        'via': _hit(via: '2026-11-19'),
        'noteUpdatedAt': _hit(noteUpdatedAt: 1),
      };
      for (final MapEntry(:key, :value) in differing.entries) {
        expect(a == value, isFalse, reason: key);
      }
      expect(a == Object(), isFalse);
    });

    test('SearchReady has value equality on hits semantic and truncated', () {
      SearchReady ready({
        List<SearchHit>? hits,
        Semantic semantic = Semantic.on,
        bool truncated = false,
      }) => SearchReady(
        hits ?? [_hit(), _hit(chunkId: 'second')],
        semantic: semantic,
        truncated: truncated,
      );

      final a = ready();
      final b = ready();
      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);

      final differing = <String, SearchReady>{
        'semantic': ready(semantic: Semantic.unknown),
        'truncated': ready(truncated: true),
        'fewer hits': ready(hits: [_hit()]),
        'more hits': ready(
          hits: [
            _hit(),
            _hit(chunkId: 'second'),
            _hit(),
          ],
        ),
        'other hit': ready(
          hits: [
            _hit(),
            _hit(chunkId: 'third'),
          ],
        ),
        'order': ready(
          hits: [
            _hit(chunkId: 'second'),
            _hit(),
          ],
        ),
        'no hits': ready(hits: []),
      };
      for (final MapEntry(:key, :value) in differing.entries) {
        expect(a == value, isFalse, reason: key);
      }
      expect(a == SearchUnavailable(SearchNoCli()), isFalse);
    });

    test('SearchUnavailable and its reasons have value equality', () {
      final reasons = <SearchUnavailableReason Function()>[
        () => SearchNoCli(),
        () => MemexOutdated(),
        () => ServerOutdated(),
      ];
      for (var i = 0; i < reasons.length; i++) {
        final a = reasons[i]();
        final b = reasons[i]();
        expect(identical(a, b), isFalse);
        expect(a, b, reason: '$a');
        expect(a.hashCode, b.hashCode, reason: '$a');
        expect(SearchUnavailable(a), SearchUnavailable(b), reason: '$a');
        expect(
          SearchUnavailable(a).hashCode,
          SearchUnavailable(b).hashCode,
          reason: '$a',
        );
        for (var j = 0; j < reasons.length; j++) {
          if (i == j) continue;
          expect(a == reasons[j](), isFalse, reason: '$a vs ${reasons[j]()}');
          expect(
            SearchUnavailable(a) == SearchUnavailable(reasons[j]()),
            isFalse,
          );
        }
      }
    });

    test('SearchUnavailable and its reasons print their names', () {
      expect(SearchNoCli().toString(), 'SearchNoCli()');
      expect(MemexOutdated().toString(), 'MemexOutdated()');
      expect(ServerOutdated().toString(), 'ServerOutdated()');
      expect(
        SearchUnavailable(MemexOutdated()).toString(),
        'SearchUnavailable(MemexOutdated())',
      );
    });
  });

  group('VaultAccess wiring', () {
    test(
      'local vault with no CLI configured returns SearchUnavailable SearchNoCli and runs nothing',
      () async {
        final VaultAccess vault = LocalVaultAccess(vaultPath: _vault);

        final result = await vault.search.search('pricing');

        expect(result, const SearchUnavailable(SearchNoCli()));
        expect(result, SearchUnavailable(SearchNoCli()));

        final direct = await LocalSearchAccess(
          vaultPath: _vault,
        ).search('pricing', allowDownload: true);
        expect(direct, SearchUnavailable(SearchNoCli()));
      },
    );

    test(
      'LocalVaultAccess default search runs memex search on its vault and CLI',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'search',
            (_) => FakeMemexCli.ok(
              '{"query":"pricing","semantic":"on","hits":[],"truncated":false}\n',
            ),
          );
        final VaultAccess vault = LocalVaultAccess(vaultPath: _vault, cli: cli);

        final result = await vault.search.search('pricing');

        expect(
          result,
          const SearchReady([], semantic: Semantic.on, truncated: false),
        );
        expect(cli.callsFor('search').single.flag('vault'), _vault);
      },
    );

    test('LocalVaultAccess search takes a FakeSearchAccess override', () {
      final fake = FakeSearchAccess();

      final vault = LocalVaultAccess(vaultPath: _vault, search: fake);

      expect(identical(vault.search, fake), isTrue);
    });

    test(
      'HostedVaultAccess search answers SearchUnavailable ServerOutdated until the hosted route lands',
      () async {
        final server = FakeVaultServer();
        final container = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(FakeClock()),
            utcOffsetProvider.overrideWithValue(() => Duration.zero),
          ],
        );
        addTearDown(container.dispose);
        final VaultAccess vault = HostedVaultAccess(
          client: server.connect(container),
          vaultName: 'seed',
        );

        expect(
          await vault.search.search('pricing'),
          const SearchUnavailable(ServerOutdated()),
        );
        expect(
          await vault.search.search('pricing', allowDownload: true),
          SearchUnavailable(ServerOutdated()),
        );
        expect(server.requests, isEmpty);
      },
    );
  });

  group('FakeSearchAccess', () {
    test(
      'FakeSearchAccess holds an answer until released and records each call query and allowDownload',
      () async {
        final fake = FakeSearchAccess();
        final ready = SearchReady(
          [_hit()],
          semantic: Semantic.on,
          truncated: false,
        );
        fake.enqueue(ready);
        fake.gate = Completer<void>();

        final outcomes = <Object?>[];
        unawaited(_outcome(fake.search('pricing')).then(outcomes.add));
        await pumpEventQueue();

        expect(outcomes, isEmpty, reason: 'held by the gate');
        expect(fake.inFlight, 1);
        expect(fake.calls, hasLength(1));
        expect(fake.calls.single.query, 'pricing');
        expect(fake.calls.single.allowDownload, isFalse);
        expect(fake.calls.single.finished, isFalse);

        fake.gate!.complete();
        await pumpEventQueue();

        expect(outcomes, [ready]);
        expect(fake.inFlight, 0);
        expect(fake.calls.single.finished, isTrue);

        fake.gate = null;
        await fake.search('-1', allowDownload: true);
        expect(fake.calls, hasLength(2));
        expect(fake.calls[1].query, '-1');
        expect(fake.calls[1].allowDownload, isTrue);
      },
    );

    test(
      'FakeSearchAccess answers queued results in order then its result',
      () async {
        final first = SearchReady(
          [_hit()],
          semantic: Semantic.modelNotDownloaded,
          truncated: false,
        );
        final fallback = SearchReady(
          [_hit(chunkId: 'fallback')],
          semantic: Semantic.on,
          truncated: true,
        );
        final fake = FakeSearchAccess(result: fallback)
          ..enqueue(first)
          ..enqueue(const SearchUnavailable(MemexOutdated()));

        expect(await fake.search('a'), first);
        expect(
          await fake.search('b'),
          const SearchUnavailable(MemexOutdated()),
        );
        expect(await fake.search('c'), fallback);
        expect(await fake.search('d'), fallback);
        expect(fake.calls.map((c) => c.query), ['a', 'b', 'c', 'd']);
      },
    );

    test(
      'FakeSearchAccess throws a queued answer that is not a result',
      () async {
        final fake = FakeSearchAccess()..enqueue(StateError('search broke'));
        fake.gate = Completer<void>();

        final outcomes = <Object?>[];
        unawaited(_outcome(fake.search('pricing')).then(outcomes.add));
        await pumpEventQueue();
        expect(outcomes, isEmpty);
        expect(fake.inFlight, 1);

        fake.gate!.complete();
        await pumpEventQueue();

        expect(outcomes.single, isA<StateError>());
        expect(fake.inFlight, 0);
        expect(fake.calls.single.finished, isTrue);
      },
    );

    test(
      'FakeSearchAccess calls wait on the gate they saw and release one at a time',
      () async {
        final fake = FakeSearchAccess();
        final firstGate = Completer<void>();
        fake.gate = firstGate;
        final outcomes = <String>[];
        unawaited(fake.search('first').then((_) => outcomes.add('first')));
        final secondGate = Completer<void>();
        fake.gate = secondGate;
        unawaited(fake.search('second').then((_) => outcomes.add('second')));
        await pumpEventQueue();
        expect(fake.inFlight, 2);

        secondGate.complete();
        await pumpEventQueue();
        expect(outcomes, ['second']);
        expect(fake.calls[0].finished, isFalse);
        expect(fake.calls[1].finished, isTrue);

        firstGate.complete();
        await pumpEventQueue();
        expect(outcomes, ['second', 'first']);
        expect(fake.inFlight, 0);
      },
    );

    test('FakeSearchAccess default answer is an empty ready search', () async {
      final fake = FakeSearchAccess();

      expect(
        await fake.search('pricing'),
        const SearchReady([], semantic: Semantic.on, truncated: false),
      );
      expect(fake.calls.single.query, 'pricing');
    });
  });
}
