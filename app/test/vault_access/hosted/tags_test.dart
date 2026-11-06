// WI #249 (A3): HostedTagsAccess and `footer_tags` on hosted reads, against the
// routes frozen in #242 (T4b). The JSON below is literal: #242 owns the
// `api_v1/tags` fixtures, and they land after this WI.
//
//   GET /tags -> {tags:[{tag,note_count,system}]} alphabetical
//   GET /tags/{tag}/notes -> {notes:[{note_id,title,role,first_line,
//     updated_at}]} most recently updated first; first_line may be null
//   DELETE /notes/{note_id}/tags/{tag} -> {note_id,tag,removed,correction_id,
//     version}; already gone is 200 with removed:false
//   GET /notes/{note_id} gains footer_tags:[string]; missing means empty
//   {tag} is percent-encoded in the path (Uri.encodeComponent).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/tags_reads.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/vault_access/hosted/notes.dart';
import 'package:open_memex_app/src/vault_access/hosted/tags.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../../support/fake_clock.dart';
import '../../support/fake_vault_db.dart';
import '../../support/fake_vault_server.dart';
import '../../support/tags_seed.dart';
import '../../support/vault_access_shapes.dart';

const _base = '/vaults/seed/api/v1';
const _note = '01J9V6000000000000000000A1';
const _other = '01J9V6000000000000000000B2';

/// `café/été`, one path segment on the wire.
const _nonAscii = 'café/été';
const _nonAsciiPath = 'caf%C3%A9%2F%C3%A9t%C3%A9';

class _Env {
  _Env(this.server, this.container);

  final FakeVaultServer server;
  final ProviderContainer container;

  HostedTagsAccess get tags =>
      HostedTagsAccess(client: server.connect(container), vaultName: 'seed');

  HostedNotesAccess get notes =>
      HostedNotesAccess(client: server.connect(container), vaultName: 'seed');
}

_Env _env() {
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Env(FakeVaultServer(), container);
}

Map<String, Object?> _noteJson({List<String>? footerTags}) => {
  'note_id': _note,
  'title': 'Plan',
  'content_md': 'body',
  'frontmatter': <String, Object?>{},
  'version': 3,
  'created_at': 1000,
  'updated_at': 2000,
  'tags': ['inbox', 'written', 'by-agent'],
  'footer_tags': ?footerTags,
};

void main() {
  group('reads', () {
    test('hosted allTags parses the frozen response', () async {
      final env = _env();
      env.server.route(
        'GET',
        '$_base/tags',
        json: {
          'tags': [
            {'tag': 'alpha', 'note_count': 2, 'system': false},
            {'tag': 'inbox', 'note_count': 5, 'system': true},
          ],
        },
      );

      final rows = await env.tags.allTags();

      expect(env.server.requests, hasLength(1));
      expect(env.server.requests.single.method, 'GET');
      expect(vaultAccessShape(rows), [
        vaultAccessShape(
          const TagRow(tag: 'alpha', noteCount: 2, system: false),
        ),
        vaultAccessShape(
          const TagRow(tag: 'inbox', noteCount: 5, system: true),
        ),
      ]);
    });

    test(
      'hosted notesForTag parses the frozen response with a percent-encoded non-ASCII tag in the path',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '$_base/tags/$_nonAsciiPath/notes',
          json: {
            'notes': [
              {
                'note_id': _note,
                'title': 'Newest',
                'role': 'topic',
                'first_line': 'a #café line',
                'updated_at': 3000,
              },
              {
                'note_id': _other,
                'title': 'Footer only',
                'role': null,
                'first_line': null,
                'updated_at': 1000,
              },
            ],
          },
        );

        final rows = await env.tags.notesForTag(_nonAscii);

        expect(env.server.requests, hasLength(1));
        expect(env.server.requests.single.method, 'GET');
        expect(
          env.server.requests.single.url.path,
          '$_base/tags/$_nonAsciiPath/notes',
        );
        expect(vaultAccessShape(rows), [
          vaultAccessShape(
            const TagNoteRow(
              noteId: _note,
              title: 'Newest',
              role: 'topic',
              firstLine: 'a #café line',
              updatedAt: 3000,
            ),
          ),
          vaultAccessShape(
            const TagNoteRow(
              noteId: _other,
              title: 'Footer only',
              role: null,
              firstLine: null,
              updatedAt: 1000,
            ),
          ),
        ]);
      },
    );

    test(
      'hosted tag reads reject a response that is not the frozen shape',
      () async {
        for (final json in <Object?>[
          <String, Object?>{},
          {'tags': 'nope', 'notes': 'nope'},
          {
            'tags': [
              {'tag': 'x'},
            ],
            'notes': [
              {'note_id': _note},
            ],
          },
          {
            'tags': [
              {'tag': 'x', 'note_count': '2', 'system': false},
            ],
            'notes': [
              {
                'note_id': _note,
                'title': 't',
                'role': 7,
                'first_line': null,
                'updated_at': 1,
              },
            ],
          },
        ]) {
          final env = _env();
          env.server
            ..route('GET', '$_base/tags', json: json)
            ..route('GET', '$_base/tags/work/notes', json: json);

          final shape = isA<MemexException>().having(
            (e) => e.code,
            'code',
            isNull,
          );
          await expectLater(
            env.tags.allTags(),
            throwsA(shape),
            reason: '$json',
          );
          await expectLater(
            env.tags.notesForTag('work'),
            throwsA(shape),
            reason: '$json',
          );
        }
      },
    );

    test(
      'hosted tag reads reject a list that has one good row and one bad row',
      () async {
        final good = {'tag': 'x', 'note_count': 1, 'system': false};
        final goodNote = {
          'note_id': _note,
          'title': 't',
          'role': null,
          'first_line': null,
          'updated_at': 1,
        };
        for (final bad in <Object?>[
          {'tag': 'y'},
          5,
        ]) {
          final env = _env();
          env.server
            ..route(
              'GET',
              '$_base/tags',
              json: {
                'tags': [good, bad],
              },
            )
            ..route(
              'GET',
              '$_base/tags/work/notes',
              json: {
                'notes': [goodNote, bad],
              },
            );

          await expectLater(
            env.tags.allTags(),
            throwsA(isA<MemexException>()),
            reason: '$bad',
          );
          await expectLater(
            env.tags.notesForTag('work'),
            throwsA(isA<MemexException>()),
            reason: '$bad',
          );
        }
      },
    );

    test('hosted tag reads equal the local reads on the same rows', () async {
      final db = FakeVaultDb.v6();
      addTearDown(db.close);
      db.seedNote(id: _note, title: 'Newest', role: 'topic', updatedAt: 3000);
      db.seedNote(id: _other, title: 'Older', updatedAt: 1000);
      db.seedTag(_note, 'work', origin: 'body', firstLine: 'a #work line');
      db.seedTag(_other, 'work', origin: 'agent');
      db.seedTag(_other, 'inbox', origin: 'agent');
      final local = LocalTagsAccess(vaultPath: '/unused/249', db: db);

      final env = _env();
      env.server
        ..route(
          'GET',
          '$_base/tags',
          json: {
            'tags': [
              {'tag': 'inbox', 'note_count': 1, 'system': true},
              {'tag': 'work', 'note_count': 2, 'system': false},
            ],
          },
        )
        ..route(
          'GET',
          '$_base/tags/work/notes',
          json: {
            'notes': [
              {
                'note_id': _note,
                'title': 'Newest',
                'role': 'topic',
                'first_line': 'a #work line',
                'updated_at': 3000,
              },
              {
                'note_id': _other,
                'title': 'Older',
                'role': null,
                'first_line': null,
                'updated_at': 1000,
              },
            ],
          },
        );

      final hostedTags = await env.tags.allTags();
      expect(hostedTags, hasLength(2));
      expect(
        vaultAccessShape(hostedTags),
        vaultAccessShape(await local.allTags()),
      );
      expect(
        vaultAccessShape(await env.tags.notesForTag('work')),
        vaultAccessShape(await local.notesForTag('work')),
      );
    });

    test(
      'hosted getNote reads footer_tags and treats a missing footer_tags as empty',
      () async {
        final env = _env();
        env.server.route(
          'GET',
          '$_base/notes/$_note',
          json: _noteJson(footerTags: ['by-agent']),
        );
        final present = (await env.notes.getNote(_note))!;
        expect(present.tags, ['inbox', 'written', 'by-agent']);
        expect(present.footerTags, ['by-agent']);

        env.server.route('GET', '$_base/notes/$_note', json: _noteJson());
        final missing = (await env.notes.getNote(_note))!;
        expect(missing.tags, ['inbox', 'written', 'by-agent']);
        expect(missing.footerTags, isEmpty);
      },
    );
  });

  group('removeTag', () {
    test(
      'hosted removeTag sends DELETE with a percent-encoded non-ASCII tag and parses the frozen response',
      () async {
        final env = _env();
        env.server.route(
          'DELETE',
          '$_base/notes/$_note/tags/$_nonAsciiPath',
          json: {
            'note_id': _note,
            'tag': _nonAscii,
            'removed': true,
            'correction_id': 12,
            'version': 7,
          },
        );

        final r = await env.tags.removeTag(_note, _nonAscii);

        expect(env.server.requests, hasLength(1));
        final request = env.server.requests.single;
        expect(request.method, 'DELETE');
        expect(request.url.path, '$_base/notes/$_note/tags/$_nonAsciiPath');
        expect(request.body, isEmpty);
        expect(r.noteId, _note);
        expect(r.tag, _nonAscii);
        expect(r.removed, isTrue);
        expect(r.correctionId, 12);
        expect(r.version, 7);
      },
    );

    test(
      'hosted removeTag counts an already gone tag as a success with its version',
      () async {
        final env = _env();
        env.server.route(
          'DELETE',
          '$_base/notes/$_note/tags/gone',
          json: {
            'note_id': _note,
            'tag': 'gone',
            'removed': false,
            'correction_id': null,
            'version': 4,
          },
        );

        final r = await env.tags.removeTag(_note, 'gone');

        expect(r.tag, 'gone');
        expect(r.removed, isFalse);
        expect(r.correctionId, isNull);
        expect(r.version, 4);
      },
    );

    test('hosted removeTag labels a C1 error and keeps its fields', () async {
      final env = _env();
      env.server.route(
        'DELETE',
        '$_base/notes/$_note/tags/work',
        status: 400,
        json: {
          'error': {
            'code': 'invalid_argument',
            'message': 'delete the text',
            'tag': 'work',
          },
        },
      );

      await expectLater(
        env.tags.removeTag(_note, 'work'),
        throwsA(
          isA<MemexException>()
              .having((e) => e.code, 'code', 'invalid_argument')
              .having(
                (e) => e.message,
                'message',
                'tag rm failed: delete the text',
              )
              .having((e) => e.fields, 'fields', {'tag': 'work'}),
        ),
      );
    });

    test(
      'hosted removeTag rejects a response that is not the frozen shape',
      () async {
        for (final json in <Object?>[
          <String, Object?>{},
          {
            'note_id': _note,
            'tag': 't',
            'removed': true,
            'correction_id': null,
          },
          {
            'note_id': _note,
            'tag': 't',
            'removed': 'yes',
            'correction_id': null,
            'version': 1,
          },
        ]) {
          final env = _env();
          env.server.route('DELETE', '$_base/notes/$_note/tags/t', json: json);

          await expectLater(
            env.tags.removeTag(_note, 't'),
            throwsA(
              isA<MemexException>()
                  .having((e) => e.code, 'code', isNull)
                  .having((e) => e.message, 'message', contains('tag rm')),
            ),
            reason: '$json',
          );
        }
      },
    );

    test('hosted removeTag on an unreachable server says so', () async {
      final env = _env();
      env.server.failure = FakeServerFailure.refused;

      await expectLater(
        env.tags.removeTag(_note, 'work'),
        throwsA(isA<VaultUnreachableException>()),
      );
      expect(env.server.requests, hasLength(1));
      expect(env.server.requests.single.method, 'DELETE');
    });
  });

  group('HostedVaultAccess.tags', () {
    test(
      'HostedVaultAccess tags use the composite client so a gone vault reports and a disposed one refuses',
      () async {
        final env = _env();
        var gone = 0;
        final access = HostedVaultAccess(
          client: env.server.connect(env.container),
          vaultName: 'seed',
          onVaultGone: () => gone++,
        );
        env.server.route(
          'GET',
          '$_base/tags',
          json: {
            'tags': [
              {'tag': 'work', 'note_count': 1, 'system': false},
            ],
          },
        );
        expect([for (final r in await access.tags.allTags()) r.tag], ['work']);

        env.server.route(
          'GET',
          '$_base/tags',
          status: 404,
          json: {
            'error': {'code': 'vault_not_found', 'message': 'gone'},
          },
        );
        await expectLater(
          access.tags.allTags(),
          throwsA(
            isA<MemexException>().having(
              (e) => e.code,
              'code',
              'vault_not_found',
            ),
          ),
        );
        expect(gone, 1);

        final sent = env.server.requests.length;
        access.dispose();
        await expectLater(access.tags.allTags(), throwsStateError);
        await expectLater(access.tags.removeTag(_note, 'x'), throwsStateError);
        expect(env.server.requests, hasLength(sent));
      },
    );
  });
}
