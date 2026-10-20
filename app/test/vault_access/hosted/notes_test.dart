// WI #81 (V1): HostedNotesAccess over HostedClient (D13, D17), against the
// `api_v1/notes` fixture rows replayed by `fake_vault_server.dart`.
//
// Pinned wire shapes (under `/vaults/<vault>/api/v1`):
//   reads:  GET /notes?limit=N (listNotes default 200), GET /notes/{id},
//           GET /titles?limit=N (allTitles default 1000),
//           GET /notes/{id}/links/out, GET /notes/{id}/links/in[?kind=],
//           POST /titles/lookup {"ids":[...]}, GET /link-kinds
//   writes: POST /notes {content_md, title?, tags?, role?}
//           PATCH /notes/{id} {expected_version, content_md, title?,
//             no_rename_links?}
//           DELETE /notes/{id}?expected_version=N
//           POST /links {from, to, kind, label?}
//           PATCH /links/{id} {kind?, label?, clear_label?}
//   An optional field is sent only when the CLI wrapper would pass its flag:
//   no empty title, no empty tags, no false booleans, no empty label, and no
//   label while clearing it.
// Errors are MemexException.fromC1 with the CLI wrapper's operation label
// (get, add, update, rm, add-link, update-link).
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/notes.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/notes_access.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';
import '../../support/vault_access_writes.dart';

const _wi81NotesDir = '$apiV1FixturesDir/notes';
const _wi81Base = '/vaults/seed/api/v1';
const _wi81PlayerLoop = '01M5DQAYZ3WP7H0NXZZV9M2315';
const _wi81Pacing = '01M5DQAYZ4YAPYMEDWXP8WCNGJ';
const _wi81Loose = '01M5DQAYZ4RYSGA8T0YEEF8QRS';
const _wi81Day19 = '01M5DQAYZ51PF87XFZWSV5PWXK';
const _wi81Day15 = '01M5DQAYZ592W2515HPSDF5Q16';
const _wi81Unknown = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';
const _wi81PacingLink = '01M5DQAYZDBGZSDQ7X3PJT783V';
const _wi81EconomyLink = '01M5DQAYZFCB2T0ECN4HG7XFQM';

class _Wi81Env {
  _Wi81Env(this.container, this.server, this.notes);

  final ProviderContainer container;
  final FakeVaultServer server;
  final HostedNotesAccess notes;

  http.Request get last => server.requests.last;

  Object? get lastBody => jsonDecode(last.body);
}

_Wi81Env _env({bool rows = true}) {
  final server = FakeVaultServer();
  if (rows) server.serveDomain('notes');
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Wi81Env(
    container,
    server,
    HostedNotesAccess(
      client: server.connect(container),
      vaultName: seedVaultName,
    ),
  );
}

/// The row of `notes/index.json` that answers [response].
FixtureRow _row(String response) =>
    loadFixtureRows(_wi81NotesDir).firstWhere((r) => r.response == response);

Object? _requestJson(String response) =>
    jsonDecode(utf8.decode(_row(response).readRequestBytes()!));

Map<String, Object?> _c1(String response) =>
    (_row(response).readResponseJson()! as Map<String, Object?>)['error']!
        as Map<String, Object?>;

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

void main() {
  test('HostedNotesAccess is a NotesAccess', () {
    expect(_env().notes, isA<NotesAccess>());
  });

  group('reads', () {
    test('hosted reads send the documented paths and default limits', () async {
      final env = _env();
      await env.notes.listNotes();
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi81Base/notes');
      expect(env.last.url.queryParameters, {'limit': '200'});

      await env.notes.allTitles();
      expect(env.last.url.path, '$_wi81Base/titles');
      expect(env.last.url.queryParameters, {'limit': '1000'});

      await env.notes.linksOutFor(_wi81PlayerLoop);
      expect(env.last.url.path, '$_wi81Base/notes/$_wi81PlayerLoop/links/out');
      expect(env.last.url.query, isEmpty);

      await env.notes.linksInFor(_wi81PlayerLoop);
      expect(env.last.url.path, '$_wi81Base/notes/$_wi81PlayerLoop/links/in');
      expect(env.last.url.query, isEmpty, reason: 'no kind, no query');

      await env.notes.linksInFor(_wi81PlayerLoop, kind: 'references');
      expect(env.last.url.queryParameters, {'kind': 'references'});

      await env.notes.titlesForIds(const [
        _wi81PlayerLoop,
        _wi81Loose,
        _wi81Unknown,
      ]);
      expect(env.last.method, 'POST');
      expect(env.last.url.path, '$_wi81Base/titles/lookup');
      expect(env.lastBody, {
        'ids': [_wi81PlayerLoop, _wi81Loose, _wi81Unknown],
      });

      await env.notes.distinctLinkKinds();
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi81Base/link-kinds');

      for (final r in env.server.requests) {
        expect(r.headers['authorization'], 'Bearer $fakeServerToken');
      }
    });

    test('hosted getNote returns null for an unknown id', () async {
      final env = _env();
      expect(await env.notes.getNote(_wi81Unknown), isNull);
      expect(env.last.url.path, '$_wi81Base/notes/$_wi81Unknown');
    });

    test('hosted getNote rethrows every error but not_found', () async {
      final env = _env(rows: false);
      env.server.route(
        'GET',
        '$_wi81Base/notes/$_wi81Loose',
        status: 500,
        json: {
          'error': {'code': 'internal', 'message': 'disk on fire'},
        },
      );
      final e = await _outcome(env.notes.getNote(_wi81Loose));
      expect(e, isA<MemexException>());
      e as MemexException;
      expect(e.code, 'internal');
      expect(e.message, 'get failed: disk on fire');
    });

    test(
      'hosted getNote decodes the get object and re-encodes frontmatter',
      () async {
        final env = _env();
        final note = (await env.notes.getNote(_wi81PlayerLoop))!;
        expect(note.id, _wi81PlayerLoop);
        expect(note.title, 'Player Loop');
        expect(note.tags, ['core', 'loop']);
        expect(note.frontmatter, isA<String>());
        expect(jsonDecode(note.frontmatter), {'role': 'topic'});
        expect(note.role, 'topic');
        // A daily note carries review and latest_change fields; they are
        // ignored (req 21).
        final day = (await env.notes.getNote('01M5DQAYZ4TAPTHDWE5PNWE4W5'))!;
        expect(day.role, 'daily');
        expect(day.version, 2);
      },
    );

    test('hosted reads ignore unknown response keys', () async {
      final env = _env(rows: false);
      env.server.route(
        'GET',
        '$_wi81Base/link-kinds',
        json: {
          'kinds': ['about'],
          'future_field': true,
        },
      );
      expect(await env.notes.distinctLinkKinds(), ['about']);
    });
  });

  group('addNote', () {
    test('hosted addNote posts the note and returns note_id', () async {
      final env = _env();
      final id = await env.notes.addNote(
        title: 'Fresh Idea',
        tags: const ['idea', 'new'],
        contentMd: 'A fresh idea worth keeping.\n',
      );
      expect(env.last.method, 'POST');
      expect(env.last.url.path, '$_wi81Base/notes');
      expect(env.lastBody, _requestJson('add_note.json'));
      final row = _row('add_note.json').readResponseJson()! as Map;
      expect(id, row['note_id']);
    });

    test('hosted addNote leaves out absent title and empty tags', () async {
      final env = _env();
      final id = await env.notes.addNote(
        contentMd: '# Combat Feel\n\nHit stop and screen shake.\n',
        role: 'topic',
      );
      expect(env.lastBody, _requestJson('add_note_topic.json'));
      expect((env.lastBody! as Map).containsKey('tags'), isFalse);
      expect((env.lastBody! as Map).containsKey('title'), isFalse);
      expect(
        id,
        (_row('add_note_topic.json').readResponseJson()! as Map)['note_id'],
      );

      final env2 = _env(rows: false);
      env2.server.route(
        'POST',
        '$_wi81Base/notes',
        status: 201,
        json: {
          'note_id': '01M5DQB000000000000000000A',
          'title': 'x',
          'tags': <String>[],
          'adopted': false,
        },
      );
      await env2.notes.addNote(title: '', contentMd: 'Body.\n');
      expect(env2.lastBody, {'content_md': 'Body.\n'});
    });

    test('hosted addNote adopting a dated note returns its id', () async {
      final env = _env();
      final id = await env.notes.addNote(
        title: '2026-10-21',
        contentMd: '',
        role: 'daily',
      );
      expect(env.lastBody, _requestJson('add_note_daily_adopt.json'));
      expect(
        id,
        (_row('add_note_daily_adopt.json').readResponseJson()!
            as Map)['note_id'],
      );
    });

    test(
      'hosted addNote on a taken daily date throws daily_note_exists with existing_id',
      () async {
        final env = _env();
        final e = await _outcome(
          env.notes.addNote(
            title: '2026-10-19',
            contentMd: 'Another entry.\n',
            role: 'daily',
          ),
        );
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, 'daily_note_exists');
        expect(e.fields['existing_id'], _wi81Day19);
        expect(e.kind, MemexErrorKind.other);
        expect(
          e.message,
          'add failed: ${_c1('add_note_daily_exists.json')['message']}',
        );
      },
    );

    // L4 parity: the local wrapper joins tags into one `--tags a,b` value
    // and clap splits it on commas (value_delimiter = ','), so a tag holding
    // a comma is stored as several tags. POST /notes stores its list as given
    // (api_notes.rs post_notes_stores_each_tag_as_given), so the hosted body
    // must carry the tags the local argv stores.
    test('hosted addNote sends the tags the local add argv stores', () async {
      for (final tags in const [
        ['a,b'],
        ['idea', 'x,y'],
        ['solo'],
      ]) {
        final cli = vaultAccessSampleCli();
        final local = LocalVaultAccess(vaultPath: '/unused/wi81', cli: cli);
        await local.notes.addNote(
          title: 'Tag Probe',
          tags: tags,
          contentMd: 'Body.\n',
        );
        final args = cli.callsFor('add').single.args;
        final storedLocally = args[args.indexOf('--tags') + 1].split(',');

        final env = _env(rows: false);
        env.server.route(
          'POST',
          '$_wi81Base/notes',
          status: 201,
          json: {
            'note_id': '01M5DQB000000000000000000A',
            'title': 'Tag Probe',
            'tags': storedLocally,
            'adopted': false,
          },
        );
        await env.notes.addNote(
          title: 'Tag Probe',
          tags: tags,
          contentMd: 'Body.\n',
        );
        expect(
          (env.lastBody! as Map)['tags'],
          storedLocally,
          reason: 'addNote(tags: $tags)',
        );
      }
    });

    test('hosted addNote with empty content throws invalid_argument', () async {
      final env = _env();
      final e = await _outcome(env.notes.addNote(contentMd: '   \n'));
      expect(e, isA<MemexException>());
      e as MemexException;
      expect(e.code, 'invalid_argument');
      expect(e.message, startsWith('add failed: '));
    });
  });

  group('updateNote', () {
    test('hosted updateNote patches the note and parses the result', () async {
      final env = _env(rows: false);
      env.server.route(
        'PATCH',
        '$_wi81Base/notes/$_wi81Loose',
        json: {
          'note_id': _wi81Loose,
          'version': 2,
          'updated_at': 1760000999000,
        },
      );
      final r = await env.notes.updateNote(
        noteId: _wi81Loose,
        expectedVersion: 1,
        contentMd: 'Maybe the map folds like paper?\n\nOr like a fan.\n',
      );
      expect(env.last.method, 'PATCH');
      expect(env.lastBody, _requestJson('update_note.json'));
      expect(
        [r.noteId, r.version, r.updatedAt],
        [_wi81Loose, 2, 1760000999000],
      );
    });

    test(
      'hosted updateNote sends title and no_rename_links only when set',
      () async {
        final env = _env(rows: false);
        env.server.route(
          'PATCH',
          '$_wi81Base/notes/$_wi81Loose',
          json: {'note_id': _wi81Loose, 'version': 3, 'updated_at': 5},
        );
        await env.notes.updateNote(
          noteId: _wi81Loose,
          expectedVersion: 2,
          title: 'Folded Map',
          contentMd: 'Body.\n',
          noRenameLinks: true,
        );
        expect(env.lastBody, {
          'expected_version': 2,
          'title': 'Folded Map',
          'content_md': 'Body.\n',
          'no_rename_links': true,
        });
        await env.notes.updateNote(
          noteId: _wi81Loose,
          expectedVersion: 2,
          title: '',
          contentMd: 'Body.\n',
        );
        expect(env.lastBody, {'expected_version': 2, 'content_md': 'Body.\n'});
      },
    );

    test(
      'hosted updateNote on a stale version throws versionConflict',
      () async {
        final env = _env();
        final e = await _outcome(
          env.notes.updateNote(
            noteId: _wi81Loose,
            expectedVersion: 1,
            contentMd: 'A stale write.\n',
          ),
        );
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.kind, MemexErrorKind.versionConflict);
        expect(e.code, 'version_conflict');
        expect(e.fields, {'expected': 1, 'current': 2});
      },
    );

    test(
      'a hosted update failure reads exactly like the CLI failure on the same body',
      () async {
        final env = _env();
        final e = await _outcome(
          env.notes.updateNote(
            noteId: _wi81Loose,
            expectedVersion: 1,
            contentMd: 'A stale write.\n',
          ),
        );
        final body = _row(
          'update_note_version_conflict.json',
        ).readResponseJson();
        final cli = MemexException.fromCliFailure(
          'update',
          MemexResult(exitCode: 1, stdout: '', stderr: '${jsonEncode(body)}\n'),
        );
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.message, cli.message);
        expect(e.code, cli.code);
        expect(e.fields, cli.fields);
        expect(e.kind, cli.kind);
      },
    );

    test('hosted updateNote of an unknown note throws not_found', () async {
      final env = _env();
      final e = await _outcome(
        env.notes.updateNote(
          noteId: _wi81Unknown,
          expectedVersion: 1,
          contentMd: 'Nobody home.\n',
        ),
      );
      e as MemexException;
      expect(e.code, 'not_found');
      expect(e.message, startsWith('update failed: '));
    });
  });

  group('deleteNote', () {
    test(
      'hosted deleteNote sends expected_version and parses the result',
      () async {
        final env = _env();
        final r = await env.notes.deleteNote(
          noteId: _wi81Day15,
          expectedVersion: 1,
        );
        expect(env.last.method, 'DELETE');
        expect(env.last.url.path, '$_wi81Base/notes/$_wi81Day15');
        expect(env.last.url.queryParameters, {'expected_version': '1'});
        expect(
          [r.vaultId, r.noteId, r.deleted],
          [seedVaultId(), _wi81Day15, true],
        );
      },
    );

    test(
      'hosted deleteNote on a stale version throws versionConflict as rm',
      () async {
        final env = _env();
        final e = await _outcome(
          env.notes.deleteNote(noteId: _wi81Day15, expectedVersion: 2),
        );
        e as MemexException;
        expect(e.kind, MemexErrorKind.versionConflict);
        expect(e.fields, {'expected': 2, 'current': 1});
        expect(
          e.message,
          'rm failed: ${_c1('delete_note_version_conflict.json')['message']}',
        );
      },
    );
  });

  group('links', () {
    test('hosted addLink posts the link and parses the result', () async {
      final env = _env();
      final r = await env.notes.addLink(
        fromNoteId: _wi81Loose,
        toNoteId: _wi81Pacing,
        kind: 'extends',
      );
      expect(env.last.url.path, '$_wi81Base/links');
      expect(env.lastBody, _requestJson('add_link.json'));
      final row = _row('add_link.json').readResponseJson()! as Map;
      expect(
        [r.linkId, r.fromNoteId, r.toNoteId, r.kind, r.source],
        [row['link_id'], _wi81Loose, _wi81Pacing, 'extends', 'frontmatter'],
      );
      expect(r.wasExisting, isFalse);
      expect(r.noteVersion, 3);

      // The second identical call is the existing link.
      final again = await env.notes.addLink(
        fromNoteId: _wi81Loose,
        toNoteId: _wi81Pacing,
        kind: 'extends',
      );
      expect(again.wasExisting, isTrue);
      expect(again.noteVersion, 3);
    });

    test('hosted addLink sends the label and the default kind', () async {
      final env = _env();
      await env.notes.addLink(
        fromNoteId: _wi81Loose,
        toNoteId: _wi81PlayerLoop,
        label: 'the loop',
      );
      expect(env.lastBody, _requestJson('add_link_label.json'));

      final env2 = _env(rows: false);
      env2.server.route(
        'POST',
        '$_wi81Base/links',
        json: _row('add_link.json').readResponseJson(),
      );
      await env2.notes.addLink(
        fromNoteId: _wi81Loose,
        toNoteId: _wi81Pacing,
        label: '',
      );
      expect(env2.lastBody, {
        'from': _wi81Loose,
        'to': _wi81Pacing,
        'kind': 'references',
      });
    });

    test(
      'hosted addLink with an invalid kind throws invalid_argument as add-link',
      () async {
        final env = _env();
        final e = await _outcome(
          env.notes.addLink(
            fromNoteId: _wi81Loose,
            toNoteId: _wi81Pacing,
            kind: 'bad_kind',
          ),
        );
        e as MemexException;
        expect(e.code, 'invalid_argument');
        expect(
          e.message,
          'add-link failed: ${_c1('add_link_invalid_kind.json')['message']}',
        );
      },
    );

    test('hosted updateLink clears the label', () async {
      final env = _env();
      final r = await env.notes.updateLink(
        linkId: _wi81PacingLink,
        clearLabel: true,
      );
      expect(env.last.method, 'PATCH');
      expect(env.last.url.path, '$_wi81Base/links/$_wi81PacingLink');
      expect(env.lastBody, _requestJson('update_link_clear_label.json'));
      expect(r.label, isNull);
      expect(
        [r.fromNoteId, r.toNoteId, r.kind, r.source, r.position],
        [_wi81Pacing, _wi81PlayerLoop, 'references', 'inline_body', 171],
      );
    });

    test('hosted updateLink sends only the fields given', () async {
      final env = _env();
      final r = await env.notes.updateLink(
        linkId: _wi81EconomyLink,
        kind: 'contradicts',
        label: 'not quite',
      );
      expect(env.lastBody, _requestJson('update_link.json'));
      expect([r.kind, r.label], ['contradicts', 'not quite']);

      final env2 = _env(rows: false);
      env2.server.route(
        'PATCH',
        '$_wi81Base/links/$_wi81EconomyLink',
        json: _row('update_link.json').readResponseJson(),
      );
      await env2.notes.updateLink(
        linkId: _wi81EconomyLink,
        label: 'dropped while clearing',
        clearLabel: true,
      );
      expect(env2.lastBody, {'clear_label': true});
      await env2.notes.updateLink(linkId: _wi81EconomyLink, kind: '');
      expect(env2.lastBody, <String, Object?>{});
    });

    test(
      'hosted updateLink with an invalid kind throws invalid_argument as update-link',
      () async {
        final env = _env();
        final e = await _outcome(
          env.notes.updateLink(
            linkId: '01M5DQAYZHCFX0P4QP3718HC8N',
            kind: 'bad_kind',
          ),
        );
        e as MemexException;
        expect(e.code, 'invalid_argument');
        expect(
          e.message,
          'update-link failed: ${_c1('update_link_invalid_kind.json')['message']}',
        );
      },
    );
  });

  test('hosted writes leave the vault revision to the call sites', () async {
    final env = _env();
    final before = env.container.read(vaultRevisionProvider);
    await env.notes.addLink(
      fromNoteId: _wi81Loose,
      toNoteId: _wi81Pacing,
      kind: 'extends',
    );
    await env.notes.deleteNote(noteId: _wi81Day15, expectedVersion: 1);
    expect(env.container.read(vaultRevisionProvider), before);
  });
}
