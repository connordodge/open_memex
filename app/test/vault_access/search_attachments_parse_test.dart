// WI #148 (Spec #123 R48, compat): the search model reads the additive
// attachment fields.
//
// - A hit may carry `attachment: {name, path}`; a hit without it parses as
//   before (attachment null, every other field unchanged).
// - The answer may carry a top-level `attachments` list of `{name, path,
//   type, size, snippet?, notes: [{id, title}]}`, in the answer's order.
// - Absent fields mean none: an older `memex` or server that prints neither
//   still parses, with no attachments. The v0.6 required hit keys
//   (`chunk_id`, `snippet`, `note_updated_at`) stay required.
// - A present field of the wrong shape fails the search, as every other
//   wrong-typed key does (`MemexException`, never `FormatException`).
//
// Seam: the one parser both `memex search` and the hosted search route use
// (`searchReadyFromJson`), fed #137's fixture
// `api_v1/search/attachments.json` (read-only here, D18) and hand-built
// answers.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart' show MemexException;
import 'package:open_memex_app/src/vault_access/search_access.dart';
import 'package:path/path.dart' as p;

import '../support/api_fixtures.dart';

/// #137's fixture, decoded.
Map<String, Object?> _fixture() =>
    jsonDecode(
          File(
            p.join(apiV1FixturesDir, 'search', 'attachments.json'),
          ).readAsStringSync(),
        )
        as Map<String, Object?>;

/// The fixture's hit row with [chunkId].
Map<String, Object?> _fixtureHit(String chunkId) => [
  for (final row in _fixture()['hits']! as List<Object?>)
    row! as Map<String, Object?>,
].singleWhere((row) => row['chunk_id'] == chunkId);

const _fieldNotesPath =
    'objects/f1/f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1/Field Notes.txt';
const _heronPath =
    'objects/a5/a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5/Heron Sketch.png';

/// A v0.6 hit object (no attachment field), built from run-time values.
Map<String, Object?> _plainHit({String chunk = 'c-148-plain'}) => {
  'note_id': ['n-148', 'plain'].join('-'),
  'note_title': ['Alpha', 'Walk'].join(' '),
  'note_role': null,
  'day': null,
  'chunk_id': chunk,
  'snippet': ['Saw a heron', 'at dawn.'].join(' '),
  'start_byte': 7 * 6,
  'via': null,
  'note_updated_at': 1795125860000 + 460,
};

/// A v0.6 answer around [hits], with [extra] top-level keys.
Map<String, Object?> _answer(
  List<Object?> hits, {
  Map<String, Object?> extra = const {},
}) => {
  'query': 'heron',
  'semantic': 'on',
  'hits': hits,
  'truncated': false,
  ...extra,
};

/// One wire attachment entry, built from run-time values.
Map<String, Object?> _wireAttachment({
  String name = 'Q3 report.pdf',
  Object? snippet = '…revenue grew 12%…',
  bool withSnippet = true,
  List<Object?>? notes,
}) => {
  'name': name,
  'path': ['objects/b2', 'b2${'0' * 62}', name].join('/'),
  'size': 1024 * 3,
  'type': ['application', 'pdf'].join('/'),
  'snippet': ?(withSnippet ? snippet : null),
  'notes':
      notes ??
      [
        {'id': 'n-148-planning', 'title': 'Planning notes'},
        {'id': 'n-148-daily', 'title': '2026-11-18'},
      ],
};

Object? _outcome(Object? decoded) {
  try {
    return searchReadyFromJson(decoded);
  } catch (e) {
    return e;
  }
}

void main() {
  group('the fixture', () {
    test('a fixture hit with an attachment exposes its name and path', () {
      final ready = searchReadyFromJson(_fixture());

      final bay = ready.hits.singleWhere(
        (h) => h.chunkId == '01M7TXDP3F3109807QBVE13740',
      );
      expect(bay.attachment, isNotNull);
      expect(bay.attachment!.name, 'Field Notes.txt');
      expect(bay.attachment!.path, _fieldNotesPath);
      expect(
        bay.snippet,
        'Field Notes.txt · The heron waited by the mill race until dusk.',
      );

      // The name-only daily hit keeps its attachment too.
      final daily = ready.hits.singleWhere(
        (h) => h.chunkId == '01M7TXDP38CVN2HVTT8F95CJX1',
      );
      expect(daily.attachment?.name, 'Heron Sketch.png');
      expect(daily.attachment?.path, _heronPath);
      expect(daily.snippet, 'Heron Sketch.png');
    });

    test(
      'a fixture daily hit with via keeps its attachment and its via date',
      () {
        final ready = searchReadyFromJson(_fixture());

        final via = ready.hits.singleWhere(
          (h) => h.chunkId == '01M7TXDP3KQEZ2VV70M3XHMDQ8',
        );
        expect(via.via, '2026-10-20');
        expect(via.noteTitle, 'Bird Topics');
        expect(via.attachment?.name, 'Heron Sketch.png');
        expect(via.attachment?.path, _heronPath);
      },
    );

    test(
      'a fixture hit without an attachment parses with no attachment and its other fields unchanged',
      () {
        final ready = searchReadyFromJson(_fixture());

        final alpha = ready.hits.singleWhere(
          (h) => h.chunkId == '01M7TXDP3CW8H6A9N44FKM19F8',
        );
        expect(alpha.attachment, isNull);
        expect(
          alpha,
          SearchHit.fromJson(_fixtureHit('01M7TXDP3CW8H6A9N44FKM19F8')),
        );
        expect(alpha.noteId, '01M7TXDP3C3C8GN8H7AQ11RP0E');
        expect(alpha.noteTitle, 'Alpha Walk');
        expect(alpha.snippet, 'Saw a heron at dawn.');
        expect(alpha.startByte, 0);
        expect(alpha.noteUpdatedAt, 1795125860460);
        // Every fixture hit parsed, in order.
        expect(ready.hits, hasLength(7));
      },
    );

    test(
      'the fixture attachments list parses with name path size type snippet and notes in order',
      () {
        final ready = searchReadyFromJson(_fixture());

        expect(ready.attachments, hasLength(2));
        final field = ready.attachments[0];
        expect(field.name, 'Field Notes.txt');
        expect(field.path, _fieldNotesPath);
        expect(field.size, 2048);
        expect(field.type, 'text/plain');
        expect(field.snippet, 'The heron waited by the mill race until dusk.');
        expect(
          [for (final n in field.notes) n.title],
          ['Bay', 'Cove', 'Dune', 'Fen'],
        );
        expect(
          [for (final n in field.notes) n.id],
          [
            '01M7TXDP3FFD7THMZRQ0NFNHW4',
            '01M7TXDP3QVAJKX82MTXXYARQX',
            '01M7TXDP3V0NSS6W1T9T89MK0Q',
            '01M7TXDP3YEJ07AM3TKAYMNE39',
          ],
        );
      },
    );

    test('a fixture name only attachment parses with no snippet', () {
      final ready = searchReadyFromJson(_fixture());

      final heron = ready.attachments.singleWhere(
        (a) => a.name == 'Heron Sketch.png',
      );
      expect(heron.snippet, isNull);
      expect(heron.path, _heronPath);
      expect(heron.size, 81234);
      expect(heron.type, 'image/png');
      expect(heron.notes, hasLength(1));
      expect(heron.notes.single.id, '01M7TXDP2R2Z15MG015CZ625G1');
      expect(heron.notes.single.title, '2026-10-20');
    });
  });

  group('compat', () {
    test(
      'an answer with neither attachment field parses as before with no attachments',
      () {
        final ready = searchReadyFromJson(_answer([_plainHit()]));

        expect(ready.attachments, isEmpty);
        expect(ready.hits, hasLength(1));
        expect(ready.hits.single.attachment, isNull);
        expect(ready.hits.single, SearchHit.fromJson(_plainHit()));
        expect(ready.semantic, Semantic.on);
        expect(ready.truncated, isFalse);
      },
    );

    test(
      'a null attachment on a hit or a null attachments list means none',
      () {
        final ready = searchReadyFromJson(
          _answer(
            [
              {..._plainHit(), 'attachment': null},
            ],
            extra: {'attachments': null},
          ),
        );

        expect(ready.hits.single.attachment, isNull);
        expect(ready.attachments, isEmpty);
      },
    );

    test(
      'an empty attachments list parses to no attachments and keeps the hits',
      () {
        final ready = searchReadyFromJson(
          _answer(
            [_plainHit(), _plainHit(chunk: 'c-148-second')],
            extra: {'attachments': <Object?>[]},
          ),
        );

        expect(ready.attachments, isEmpty);
        expect(
          [for (final h in ready.hits) h.chunkId],
          ['c-148-plain', 'c-148-second'],
        );
      },
    );

    test(
      'an attachments list built at run time parses each entry with its notes in order',
      () {
        final notes = [
          for (final t in ['Bay', 'Cove', 'Dune', 'Fen'])
            {'id': 'n-148-${t.toLowerCase()}', 'title': t},
        ];
        final ready = searchReadyFromJson(
          _answer(
            [_plainHit()],
            extra: {
              'attachments': [
                _wireAttachment(),
                _wireAttachment(
                  name: 'Revenue plan.png',
                  withSnippet: false,
                  notes: notes,
                ),
              ],
            },
          ),
        );

        expect(
          [for (final a in ready.attachments) a.name],
          ['Q3 report.pdf', 'Revenue plan.png'],
        );
        final q3 = ready.attachments.first;
        expect(q3.path, 'objects/b2/b2${'0' * 62}/Q3 report.pdf');
        expect(q3.size, 3072);
        expect(q3.type, 'application/pdf');
        expect(q3.snippet, '…revenue grew 12%…');
        expect(
          [for (final n in q3.notes) (n.id, n.title)],
          [('n-148-planning', 'Planning notes'), ('n-148-daily', '2026-11-18')],
        );
        final plan = ready.attachments.last;
        expect(plan.snippet, isNull);
        expect(
          [for (final n in plan.notes) n.title],
          ['Bay', 'Cove', 'Dune', 'Fen'],
        );
      },
    );

    test('the v0.6 required hit keys stay required next to an attachment', () {
      for (final key in ['chunk_id', 'snippet', 'note_updated_at']) {
        final hit = {
          ..._plainHit(),
          'attachment': {'name': 'Q3 report.pdf', 'path': 'objects/x/y/z'},
        }..remove(key);
        expect(
          _outcome(_answer([hit])),
          isA<MemexException>(),
          reason: 'a hit with an attachment and no $key',
        );
      }
    });
  });

  group('malformed attachment fields fail the search', () {
    final cases = <(String, Map<String, Object?>)>[
      (
        'a hit attachment that is not an object',
        _answer([
          {..._plainHit(), 'attachment': 'Q3 report.pdf'},
        ]),
      ),
      (
        'a hit attachment with no path',
        _answer([
          {
            ..._plainHit(),
            'attachment': {'name': 'Q3 report.pdf'},
          },
        ]),
      ),
      (
        'a hit attachment with no name',
        _answer([
          {
            ..._plainHit(),
            'attachment': {'path': 'objects/x/y/Q3 report.pdf'},
          },
        ]),
      ),
      (
        'an attachments value that is not a list',
        _answer([_plainHit()], extra: {'attachments': 'Q3 report.pdf'}),
      ),
      (
        'an attachments entry that is not an object',
        _answer(
          [_plainHit()],
          extra: {
            'attachments': ['Q3 report.pdf'],
          },
        ),
      ),
      (
        'an attachments entry with no notes list',
        _answer(
          [_plainHit()],
          extra: {
            'attachments': [_wireAttachment()..remove('notes')],
          },
        ),
      ),
      (
        'an attachments entry with a size that is not an int',
        _answer(
          [_plainHit()],
          extra: {
            'attachments': [
              {..._wireAttachment(), 'size': '3072'},
            ],
          },
        ),
      ),
      (
        'an attachments entry with a snippet that is not a string',
        _answer(
          [_plainHit()],
          extra: {
            'attachments': [_wireAttachment(snippet: 12)],
          },
        ),
      ),
      (
        'an attachments note with no title',
        _answer(
          [_plainHit()],
          extra: {
            'attachments': [
              _wireAttachment(
                notes: [
                  {'id': 'n-148-planning'},
                ],
              ),
            ],
          },
        ),
      ),
    ];
    for (final (name, answer) in cases) {
      test(name, () {
        final outcome = _outcome(answer);
        expect(outcome, isA<MemexException>());
        expect(outcome, isNot(isA<FormatException>()));
      });
    }
  });

  group('value equality', () {
    test('search hits that differ only in their attachment are not equal', () {
      final plain = SearchHit.fromJson(_plainHit());
      final withQ3 = SearchHit.fromJson({
        ..._plainHit(),
        'attachment': {'name': 'Q3 report.pdf', 'path': 'objects/b2/x/Q3.pdf'},
      });
      final withPlan = SearchHit.fromJson({
        ..._plainHit(),
        'attachment': {'name': 'Plan.png', 'path': 'objects/b2/x/Plan.png'},
      });

      expect(withQ3.attachment, isNotNull);
      expect(withQ3, isNot(plain));
      expect(plain, isNot(withQ3));
      expect(withQ3, isNot(withPlan));
    });

    test('hit attachments with the same name and path are equal', () {
      final name = ['Q3', 'report.pdf'].join(' ');
      final a = SearchHitAttachment(name: name, path: 'objects/b2/x/$name');
      final b = SearchHitAttachment(
        name: 'Q3 report.pdf',
        path: 'objects/b2/x/Q3 report.pdf',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(SearchHitAttachment(name: name, path: 'objects/c3/y')));
      expect(a, isNot(SearchHitAttachment(name: 'Other', path: a.path)));
    });

    test(
      'two parses of one answer are equal and answers that differ only in attachments are not',
      () {
        Map<String, Object?> answer(List<Object?> attachments) =>
            _answer([_plainHit()], extra: {'attachments': attachments});

        final one = searchReadyFromJson(answer([_wireAttachment()]));
        final again = searchReadyFromJson(answer([_wireAttachment()]));
        expect(one, again);
        expect(one.hashCode, again.hashCode);

        expect(one, isNot(searchReadyFromJson(answer([]))));
        expect(
          one,
          isNot(searchReadyFromJson(answer([_wireAttachment(name: 'Q4.pdf')]))),
        );
        expect(
          one,
          isNot(
            searchReadyFromJson(answer([_wireAttachment(withSnippet: false)])),
          ),
        );
        expect(
          one,
          isNot(
            searchReadyFromJson(
              answer([
                _wireAttachment(
                  notes: [
                    {'id': 'n-148-planning', 'title': 'Planning notes'},
                  ],
                ),
              ]),
            ),
          ),
        );
      },
    );
  });
}
