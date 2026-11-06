// WI #249 (A3): MemexCli.tagAdd / tagRm against the output frozen in #242 (T4b).
// FakeMemexCli only: no test runs a real `memex`.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/fake_memex_cli.dart';

const _vault = '/tmp/om-249-vault';
const _note = '01J9V6000000000000000000A1';

Matcher _failure({required String? code, required String message}) => throwsA(
  isA<MemexException>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.message, 'message', message),
);

void main() {
  group('tagRm', () {
    test(
      'tagRm builds the memex tag rm arguments and parses removed, correction_id and version',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'tag rm',
            (_) => FakeMemexCli.ok(
              '{"note_id":"$_note","tag":"work","removed":true,'
              '"correction_id":12,"version":7}\n',
            ),
          );

        final r = await cli.tagRm(
          vaultPath: _vault,
          noteId: _note,
          tag: 'work',
        );

        expect(cli.callsFor('tag rm'), hasLength(1));
        final call = cli.callsFor('tag rm').single;
        expect(call.args.take(2), ['tag', 'rm']);
        expect(call.args, hasLength(8));
        expect(call.flag('vault'), _vault);
        expect(call.flag('note-id'), _note);
        expect(call.flag('tag'), 'work');
        expect(call.stdinBody, isNull);
        expect(r.noteId, _note);
        expect(r.tag, 'work');
        expect(r.removed, isTrue);
        expect(r.correctionId, 12);
        expect(r.version, 7);
      },
    );

    test(
      'tagRm parses an already gone tag with a null correction_id as a success',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'tag rm',
            (_) => FakeMemexCli.ok(
              '{"note_id":"$_note","tag":"gone","removed":false,'
              '"correction_id":null,"version":3}\n',
            ),
          );

        final r = await cli.tagRm(
          vaultPath: _vault,
          noteId: _note,
          tag: 'gone',
        );

        expect(r.tag, 'gone');
        expect(r.removed, isFalse);
        expect(r.correctionId, isNull);
        expect(r.version, 3);
      },
    );

    test('a tagRm CLI failure surfaces as the existing access error', () async {
      final c1 = FakeMemexCli()
        ..on(
          'tag rm',
          (_) => FakeMemexCli.error(
            'invalid_argument',
            'delete the text to remove this tag',
          ),
        );
      await expectLater(
        c1.tagRm(vaultPath: _vault, noteId: _note, tag: 'work'),
        _failure(
          code: 'invalid_argument',
          message: 'tag rm failed: delete the text to remove this tag',
        ),
      );

      final legacy = FakeMemexCli()
        ..on('tag rm', (_) => FakeMemexCli.failure('boom\n'));
      await expectLater(
        legacy.tagRm(vaultPath: _vault, noteId: _note, tag: 'work'),
        throwsA(
          isA<MemexException>()
              .having((e) => e.code, 'code', isNull)
              .having((e) => e.message, 'message', startsWith('tag rm failed')),
        ),
      );
    });

    test('tagRm rejects stdout that is not the contract shape', () async {
      for (final stdout in [
        'not json',
        '[1]',
        '{"note_id":"$_note","tag":"t","removed":true,"correction_id":null}',
        '{"note_id":"$_note","tag":"t","correction_id":null,"version":1}',
        '{"note_id":"$_note","tag":"t","removed":"yes","correction_id":null,"version":1}',
        '{"note_id":"$_note","tag":"t","removed":true,"correction_id":"12","version":1}',
      ]) {
        final cli = FakeMemexCli()
          ..on('tag rm', (_) => FakeMemexCli.ok(stdout));
        await expectLater(
          cli.tagRm(vaultPath: _vault, noteId: _note, tag: 't'),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', isNull)
                .having((e) => e.message, 'message', contains('tag rm')),
          ),
          reason: stdout,
        );
      }
    });
  });

  group('tagAdd', () {
    test(
      'tagAdd builds the memex tag add arguments and parses its output',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'tag add',
            (_) => FakeMemexCli.ok(
              '{"note_id":"$_note","tag":"work","origin":"person",'
              '"changed":true,"version":5}\n',
            ),
          );

        final r = await cli.tagAdd(
          vaultPath: _vault,
          noteId: _note,
          tag: 'work',
        );

        expect(cli.callsFor('tag add'), hasLength(1));
        final call = cli.callsFor('tag add').single;
        expect(call.args.take(2), ['tag', 'add']);
        expect(call.args, hasLength(8));
        expect(call.flag('vault'), _vault);
        expect(call.flag('note-id'), _note);
        expect(call.flag('tag'), 'work');
        expect(r.noteId, _note);
        expect(r.tag, 'work');
        expect(r.origin, 'person');
        expect(r.changed, isTrue);
        expect(r.version, 5);
      },
    );

    test('a tagAdd CLI failure keeps its code and fields', () async {
      final cli = FakeMemexCli()
        ..on(
          'tag add',
          (_) => FakeMemexCli.error(
            'guide_rule',
            'the Vault Guide takes no tags',
            {'note_id': _note},
          ),
        );

      await expectLater(
        cli.tagAdd(vaultPath: _vault, noteId: _note, tag: 'work'),
        throwsA(
          isA<MemexException>()
              .having((e) => e.code, 'code', 'guide_rule')
              .having(
                (e) => e.message,
                'message',
                'tag add failed: the Vault Guide takes no tags',
              )
              .having((e) => e.fields, 'fields', {'note_id': _note}),
        ),
      );
    });

    test('tagAdd rejects stdout that is not the contract shape', () async {
      for (final stdout in [
        'not json',
        '{"note_id":"$_note","tag":"t","origin":"person","changed":true}',
        '{"note_id":"$_note","tag":"t","origin":"person","version":1}',
      ]) {
        final cli = FakeMemexCli()
          ..on('tag add', (_) => FakeMemexCli.ok(stdout));
        await expectLater(
          cli.tagAdd(vaultPath: _vault, noteId: _note, tag: 't'),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', isNull)
                .having((e) => e.message, 'message', contains('tag add')),
          ),
          reason: stdout,
        );
      }
    });
  });
}
