import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memex_cli.dart';

const _vault = '/tmp/om-fake-vault';

// C2.1 stdout, verbatim (TEXT, not JSON).
const _createdNoteStdout =
    'Created note\n  note_id: 01J9Z8Y7X6W5V4T3S2R1Q0P9N8\n  title:   2026-10-03\n';
const _adoptedNoteStdout =
    'Adopted note\n  note_id: 01J9Z8Y7X6W5V4T3S2R1Q0P9N8\n  title:   2026-10-03\n';

void main() {
  group('addNote(role:) (AC7)', () {
    test(
      'addNote with role daily sends add --vault --title --role daily with empty stdin and returns the Created note id',
      () async {
        final cli = FakeMemexCli()
          ..on('add', (_) => FakeMemexCli.ok(_createdNoteStdout));

        final id = await cli.addNote(
          vaultPath: _vault,
          role: 'daily',
          title: '2026-10-03',
          contentMd: '',
        );

        expect(id, '01J9Z8Y7X6W5V4T3S2R1Q0P9N8');
        final call = cli.calls.single;
        expect(call.args, [
          'add',
          '--vault',
          _vault,
          '--title',
          '2026-10-03',
          '--role',
          'daily',
        ]);
        expect(call.stdinBody ?? '', isEmpty);
      },
    );

    test('addNote returns the same id from the Adopted note stdout', () async {
      final cli = FakeMemexCli()
        ..on('add', (_) => FakeMemexCli.ok(_adoptedNoteStdout));

      final id = await cli.addNote(
        vaultPath: _vault,
        role: 'daily',
        title: '2026-10-03',
        contentMd: '',
      );

      expect(id, '01J9Z8Y7X6W5V4T3S2R1Q0P9N8');
      expect(cli.calls.single.flag('role'), 'daily');
    });

    test(
      'addNote with role topic passes --role topic and the body on stdin',
      () async {
        final cli = FakeMemexCli()
          ..on('add', (_) => FakeMemexCli.ok(_createdNoteStdout));

        await cli.addNote(
          vaultPath: _vault,
          title: 'Player Loop',
          contentMd: '# Player Loop\n',
          role: 'topic',
        );

        final call = cli.calls.single;
        expect(call.flag('role'), 'topic');
        expect(call.flag('title'), 'Player Loop');
        expect(call.args.where((a) => a == '--role'), hasLength(1));
        expect(call.stdinBody, '# Player Loop\n');
      },
    );

    test(
      'addNote without a role sends no --role flag (existing callers unchanged)',
      () async {
        final cli = FakeMemexCli()
          ..on('add', (_) => FakeMemexCli.ok(_createdNoteStdout));

        await cli.addNote(
          vaultPath: _vault,
          title: 'Untitled',
          contentMd: '# Untitled\n\n',
          tags: const ['a', 'b'],
        );

        final call = cli.calls.single;
        expect(call.args, [
          'add',
          '--vault',
          _vault,
          '--title',
          'Untitled',
          '--tags',
          'a,b',
        ]);
        expect(call.hasFlag('role'), isFalse);
        expect(call.stdinBody, '# Untitled\n\n');
      },
    );
  });
}
