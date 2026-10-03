import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/fake_memex_cli.dart';

const _vault = '/tmp/om-fake-vault';

// C1 samples, verbatim from contracts-1.md.
const _dailyNoteExistsC1 =
    '{"error":{"code":"daily_note_exists","message":"a daily note for 2026-10-03 already exists: 01J9Z8Y7X6W5V4T3S2R1Q0P9N8","date":"2026-10-03","existing_id":"01J9Z8Y7X6W5V4T3S2R1Q0P9N8"}}';
const _versionConflictC1 =
    '{"error":{"code":"version_conflict","message":"version conflict: expected 3, current 4","expected":3,"current":4}}';

// The same errors as the Rust CLI actually serializes them: object keys in
// alphabetical order (serde_json map). Parse, never compare bytes.
const _dailyNoteExistsRust =
    '{"error":{"code":"daily_note_exists","date":"2026-10-03","existing_id":"01J9Z8Y7X6W5V4T3S2R1Q0P9N8","message":"a daily note for 2026-10-03 already exists: 01J9Z8Y7X6W5V4T3S2R1Q0P9N8"}}';
const _versionConflictRust =
    '{"error":{"code":"version_conflict","current":4,"expected":3,"message":"version conflict: expected 3, current 4"}}';

Future<void> _addDaily(MemexCli cli) => cli.addNote(
  vaultPath: _vault,
  title: '2026-10-03',
  contentMd: '',
  role: 'daily',
);

Future<NoteUpdateResult> _update(MemexCli cli) => cli.updateNote(
  vaultPath: _vault,
  noteId: '01J9Z8Y7X6W5V4T3S2R1Q0P9N8',
  expectedVersion: 3,
  contentMd: 'x',
);

/// [m] is an `isA<MemexException>()` matcher; a ProcessException or a
/// FormatException does not satisfy it.
Matcher _throwsMemex(Matcher m) => throwsA(m);

Future<void> _expectDailyNoteExists(String stderrLine) async {
  final cli = FakeMemexCli()
    ..on('add', (_) => FakeMemexCli.failure('$stderrLine\n'));

  MemexException? caught;
  try {
    await _addDaily(cli);
  } on MemexException catch (e) {
    caught = e;
  }

  expect(caught, isNotNull, reason: 'addNote must throw MemexException');
  expect(caught!.code, 'daily_note_exists');
  expect(caught.fields['existing_id'], '01J9Z8Y7X6W5V4T3S2R1Q0P9N8');
  expect(caught.fields['date'], '2026-10-03');
  expect(caught.kind, MemexErrorKind.other);
  expect(
    caught.message,
    contains(
      'a daily note for 2026-10-03 already exists: 01J9Z8Y7X6W5V4T3S2R1Q0P9N8',
    ),
  );
}

Future<void> _expectVersionConflict(String stderrLine) async {
  final cli = FakeMemexCli()
    ..on('update', (_) => FakeMemexCli.failure('$stderrLine\n'));
  await expectLater(
    _update(cli),
    _throwsMemex(
      isA<MemexException>()
          .having((e) => e.kind, 'kind', MemexErrorKind.versionConflict)
          .having((e) => e.code, 'code', 'version_conflict')
          .having((e) => e.fields['expected'], 'expected', 3)
          .having((e) => e.fields['current'], 'current', 4)
          .having(
            (e) => e.message,
            'message',
            contains('version conflict: expected 3, current 4'),
          ),
    ),
  );
}

void main() {
  group('C1 JSON error contract (AC5)', () {
    test(
      'a daily_note_exists stderr line surfaces as MemexException code and existing_id',
      () => _expectDailyNoteExists(_dailyNoteExistsC1),
    );

    test(
      'a daily_note_exists line with alphabetical keys surfaces the same code and fields',
      () => _expectDailyNoteExists(_dailyNoteExistsRust),
    );

    test(
      'MemexException.fromCliFailure parses the C1 line for CLI wrapper extensions',
      () {
        final e = MemexException.fromCliFailure(
          'folder new',
          FakeMemexCli.failure(
            '{"error":{"code":"depth_exceeded","message":"Smart Folder depth 3 exceeds the vault maximum of 2","max_depth":2,"required_depth":3}}\n',
          ),
        );
        expect(e.code, 'depth_exceeded');
        expect(e.fields['max_depth'], 2);
        expect(e.fields['required_depth'], 3);
        expect(e.kind, MemexErrorKind.other);
        expect(
          e.message,
          contains('Smart Folder depth 3 exceeds the vault maximum of 2'),
        );
      },
    );

    test(
      'MemexException.fromCliFailure keeps the legacy message and a null code for non-JSON stderr',
      () {
        final e = MemexException.fromCliFailure(
          'folder new',
          FakeMemexCli.failure(
            "error: unrecognized subcommand 'folder'\n",
            exitCode: 2,
          ),
        );
        expect(e.code, isNull);
        expect(e.fields, isEmpty);
        expect(e.kind, MemexErrorKind.other);
        expect(
          e.message,
          "folder new failed: error: unrecognized subcommand 'folder'\n",
        );
      },
    );

    test('a C1 JSON line after log lines on stderr is still parsed', () async {
      final cli = FakeMemexCli()
        ..on(
          'add',
          (_) => FakeMemexCli.failure(
            'WARN memex_core: embeddings disabled\n$_dailyNoteExistsRust\n',
          ),
        );
      await expectLater(
        _addDaily(cli),
        _throwsMemex(
          isA<MemexException>()
              .having((e) => e.code, 'code', 'daily_note_exists')
              .having(
                (e) => e.fields['existing_id'],
                'existing_id',
                '01J9Z8Y7X6W5V4T3S2R1Q0P9N8',
              ),
        ),
      );
    });

    test(
      'malformed or non-error JSON on stderr yields a null code without crashing',
      () async {
        for (final stderr in [
          '{"error":',
          '{"ok":true}',
          '{"error":"plain string"}',
          '[1,2,3]',
          '',
        ]) {
          final cli = FakeMemexCli()
            ..on('add', (_) => FakeMemexCli.failure(stderr));
          await expectLater(
            _addDaily(cli),
            _throwsMemex(
              isA<MemexException>()
                  .having((e) => e.code, 'code', isNull)
                  .having((e) => e.message, 'message', 'add failed: $stderr'),
            ),
            reason: 'stderr: $stderr',
          );
        }
      },
    );
  });

  group('version conflict detection (AC6)', () {
    test(
      'the C1 version_conflict JSON from update yields MemexErrorKind.versionConflict',
      () => _expectVersionConflict(_versionConflictC1),
    );

    test(
      'a version_conflict line with alphabetical keys also yields MemexErrorKind.versionConflict',
      () => _expectVersionConflict(_versionConflictRust),
    );

    test(
      'a JSON error with another code from update is not a version conflict',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'update',
            (_) => FakeMemexCli.error('not_found', 'note not found: 01J9'),
          );
        await expectLater(
          _update(cli),
          _throwsMemex(
            isA<MemexException>()
                .having((e) => e.kind, 'kind', MemexErrorKind.other)
                .having((e) => e.code, 'code', 'not_found'),
          ),
        );
      },
    );

    test(
      'non-JSON version conflict stderr from update keeps today\'s kind and message with a null code',
      () async {
        for (final stderr in [
          'Error: version conflict: expected 3, current 4\n',
          'Error: VersionConflict { expected: 3, current: 4 }\n',
        ]) {
          final cli = FakeMemexCli()
            ..on('update', (_) => FakeMemexCli.failure(stderr));
          await expectLater(
            _update(cli),
            _throwsMemex(
              isA<MemexException>()
                  .having((e) => e.kind, 'kind', MemexErrorKind.versionConflict)
                  .having((e) => e.code, 'code', isNull)
                  .having((e) => e.fields, 'fields', isEmpty)
                  .having(
                    (e) => e.message,
                    'message',
                    'update failed: $stderr',
                  ),
            ),
            reason: stderr,
          );
        }
      },
    );

    test(
      'non-JSON stderr from update yields code null, kind other and today\'s message',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'update',
            (_) => FakeMemexCli.failure('Error: disk I/O error\n'),
          );
        await expectLater(
          _update(cli),
          _throwsMemex(
            isA<MemexException>()
                .having((e) => e.kind, 'kind', MemexErrorKind.other)
                .having((e) => e.code, 'code', isNull)
                .having(
                  (e) => e.message,
                  'message',
                  'update failed: Error: disk I/O error\n',
                ),
          ),
        );
      },
    );
  });
}
