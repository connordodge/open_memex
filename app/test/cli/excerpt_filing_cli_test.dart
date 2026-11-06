// WI #259 (F7) AC1: the `memex excerpt add|remove-block|move` wrappers (#256)
// pass the Contract's exact arguments with an optional `--note`, parse the
// output object, throw a null-code MemexException for malformed stdout and
// keep the C1 code of a failure. `memex excerpt rm` is unchanged
// (excerpt_cli_test.dart).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/excerpt_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/fake_memex_cli.dart';
import '../support/vault_access_shapes.dart';

const _vault = '/tmp/om-259-vault';

String _out(Object? json) => '${jsonEncode(json)}\n';

String get _editOut =>
    _out({'vault_id': 'V1', 'topic_note_id': 'T1', 'version': 6});

String get _moveOut => _out({
  'vault_id': 'V1',
  'from_topic_note_id': 'A1',
  'from_version': 3,
  'to_topic_note_id': 'C1',
  'to_version': 8,
});

Matcher get _nullCode =>
    throwsA(isA<MemexException>().having((e) => e.code, 'code', isNull));

void main() {
  group('excerpt add', () {
    test(
      'addExcerpt sends excerpt add with the note flag and parses the result',
      () async {
        final cli = FakeMemexCli()
          ..on('excerpt add', (_) => FakeMemexCli.ok(_editOut));

        final r = await cli.addExcerpt(
          vaultPath: _vault,
          topicNoteId: 'T1',
          date: '2026-11-05',
          blockId: 'b7k2m9',
          note: 'this belongs here',
        );

        expect(cli.calls.single.args, [
          'excerpt',
          'add',
          '--vault',
          _vault,
          '--topic-note-id',
          'T1',
          '--date',
          '2026-11-05',
          '--block-id',
          'b7k2m9',
          '--note',
          'this belongs here',
        ]);
        expect(vaultAccessShape(r), {
          'ExcerptEditResult': ['V1', 'T1', 6],
        });
      },
    );

    test('addExcerpt without a note leaves the note flag out', () async {
      final cli = FakeMemexCli()
        ..on('excerpt add', (_) => FakeMemexCli.ok(_editOut));

      await cli.addExcerpt(
        vaultPath: _vault,
        topicNoteId: 'T1',
        date: '2026-11-05',
        blockId: 'b7k2m9',
      );

      expect(cli.calls.single.args, [
        'excerpt',
        'add',
        '--vault',
        _vault,
        '--topic-note-id',
        'T1',
        '--date',
        '2026-11-05',
        '--block-id',
        'b7k2m9',
      ]);
      expect(cli.calls.single.hasFlag('note'), isFalse);
    });
  });

  group('excerpt remove-block', () {
    test(
      'removeExcerptBlock sends excerpt remove-block with the note flag and parses the result',
      () async {
        final cli = FakeMemexCli()
          ..on('excerpt remove-block', (_) => FakeMemexCli.ok(_editOut));

        final r = await cli.removeExcerptBlock(
          vaultPath: _vault,
          topicNoteId: 'T1',
          date: '2026-11-05',
          blockId: 'b7k2m9',
          note: 'not about this',
        );

        expect(cli.calls.single.args, [
          'excerpt',
          'remove-block',
          '--vault',
          _vault,
          '--topic-note-id',
          'T1',
          '--date',
          '2026-11-05',
          '--block-id',
          'b7k2m9',
          '--note',
          'not about this',
        ]);
        expect(vaultAccessShape(r), {
          'ExcerptEditResult': ['V1', 'T1', 6],
        });
      },
    );

    test(
      'removeExcerptBlock without a note leaves the note flag out',
      () async {
        final cli = FakeMemexCli()
          ..on('excerpt remove-block', (_) => FakeMemexCli.ok(_editOut));

        await cli.removeExcerptBlock(
          vaultPath: _vault,
          topicNoteId: 'T1',
          date: '2026-11-05',
          blockId: 'b7k2m9',
        );

        expect(cli.calls.single.hasFlag('note'), isFalse);
        expect(cli.calls.single.args, hasLength(10));
      },
    );

    test('remove-block is a separate subcommand from excerpt rm', () async {
      final cli = FakeMemexCli()
        ..on('excerpt rm', (_) => FakeMemexCli.ok(_editOut))
        ..on('excerpt remove-block', (_) => FakeMemexCli.ok(_editOut));

      await cli.removeExcerptBlock(
        vaultPath: _vault,
        topicNoteId: 'T1',
        date: '2026-11-05',
        blockId: 'b7k2m9',
      );

      expect(cli.callsFor('excerpt remove-block'), hasLength(1));
      expect(cli.callsFor('excerpt rm'), isEmpty);
    });
  });

  group('excerpt move', () {
    test(
      'moveExcerptBlock sends excerpt move with the note flag and parses both versions',
      () async {
        final cli = FakeMemexCli()
          ..on('excerpt move', (_) => FakeMemexCli.ok(_moveOut));

        final r = await cli.moveExcerptBlock(
          vaultPath: _vault,
          date: '2026-11-05',
          blockId: 'b7k2m9',
          fromTopicNoteId: 'A1',
          toTopicNoteId: 'C1',
          note: 'wrong topic',
        );

        expect(cli.calls.single.args, [
          'excerpt',
          'move',
          '--vault',
          _vault,
          '--date',
          '2026-11-05',
          '--block-id',
          'b7k2m9',
          '--from-topic-note-id',
          'A1',
          '--to-topic-note-id',
          'C1',
          '--note',
          'wrong topic',
        ]);
        expect(vaultAccessShape(r), {
          'ExcerptMoveResult': ['V1', 'A1', 3, 'C1', 8],
        });
      },
    );

    test('moveExcerptBlock without a note leaves the note flag out', () async {
      final cli = FakeMemexCli()
        ..on('excerpt move', (_) => FakeMemexCli.ok(_moveOut));

      await cli.moveExcerptBlock(
        vaultPath: _vault,
        date: '2026-11-05',
        blockId: 'b7k2m9',
        fromTopicNoteId: 'A1',
        toTopicNoteId: 'C1',
      );

      expect(cli.calls.single.hasFlag('note'), isFalse);
      expect(cli.calls.single.args, hasLength(12));
    });
  });

  test('excerpt filing failures keep the C1 code of each command', () async {
    final cases = <(String, String, Future<Object?> Function(FakeMemexCli))>[
      (
        'excerpt add',
        'block_not_found',
        (c) => c.addExcerpt(
          vaultPath: _vault,
          topicNoteId: 'T',
          date: '2026-11-05',
          blockId: 'b',
        ),
      ),
      (
        'excerpt add',
        'invalid_date',
        (c) => c.addExcerpt(
          vaultPath: _vault,
          topicNoteId: 'T',
          date: 'x',
          blockId: 'b',
        ),
      ),
      (
        'excerpt remove-block',
        'not_found',
        (c) => c.removeExcerptBlock(
          vaultPath: _vault,
          topicNoteId: 'T',
          date: '2026-11-05',
          blockId: 'b',
        ),
      ),
      (
        'excerpt move',
        'block_not_found',
        (c) => c.moveExcerptBlock(
          vaultPath: _vault,
          date: '2026-11-05',
          blockId: 'b',
          fromTopicNoteId: 'A',
          toTopicNoteId: 'C',
        ),
      ),
      (
        'excerpt move',
        'invalid_argument',
        (c) => c.moveExcerptBlock(
          vaultPath: _vault,
          date: '2026-11-05',
          blockId: 'b',
          fromTopicNoteId: 'A',
          toTopicNoteId: 'A',
        ),
      ),
    ];
    for (final (sub, code, call) in cases) {
      final cli = FakeMemexCli()
        ..on(sub, (_) => FakeMemexCli.error(code, 'nope $code'));
      await expectLater(
        call(cli),
        throwsA(
          isA<MemexException>()
              .having((e) => e.code, 'code', code)
              .having((e) => e.message, 'message', contains('nope $code')),
        ),
        reason: '$sub $code',
      );
    }
  });

  test(
    'excerpt filing stdout that is not the Contract shape throws with a null code',
    () async {
      final editCases = [
        'not json',
        '[]',
        _out({'vault_id': 'V', 'topic_note_id': 'T'}),
        _out({'vault_id': 'V', 'version': 1}),
        _out({'topic_note_id': 'T', 'version': 1}),
        _out({'vault_id': 'V', 'topic_note_id': 'T', 'version': '1'}),
      ];
      for (final out in editCases) {
        final add = FakeMemexCli()
          ..on('excerpt add', (_) => FakeMemexCli.ok(out));
        await expectLater(
          add.addExcerpt(
            vaultPath: _vault,
            topicNoteId: 'T',
            date: '2026-11-05',
            blockId: 'b',
          ),
          _nullCode,
          reason: 'add $out',
        );
        final rm = FakeMemexCli()
          ..on('excerpt remove-block', (_) => FakeMemexCli.ok(out));
        await expectLater(
          rm.removeExcerptBlock(
            vaultPath: _vault,
            topicNoteId: 'T',
            date: '2026-11-05',
            blockId: 'b',
          ),
          _nullCode,
          reason: 'remove-block $out',
        );
      }
      final full = {
        'vault_id': 'V1',
        'from_topic_note_id': 'A1',
        'from_version': 3,
        'to_topic_note_id': 'C1',
        'to_version': 8,
      };
      final moveCases = [
        'not json',
        '[]',
        for (final key in full.keys) _out({...full}..remove(key)),
        _out({...full, 'from_version': '3'}),
        _out({...full, 'to_version': null}),
      ];
      for (final out in moveCases) {
        final cli = FakeMemexCli()
          ..on('excerpt move', (_) => FakeMemexCli.ok(out));
        await expectLater(
          cli.moveExcerptBlock(
            vaultPath: _vault,
            date: '2026-11-05',
            blockId: 'b',
            fromTopicNoteId: 'A1',
            toTopicNoteId: 'C1',
          ),
          _nullCode,
          reason: 'move $out',
        );
      }
    },
  );
}
