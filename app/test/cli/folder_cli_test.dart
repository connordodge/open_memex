// WI #25 (A8): the `memex folder new|update|rm|add|remove` wrappers
// (C2.6–C2.10, C1, D19, D21). Samples are copied verbatim from contracts-1.md.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/folder_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/fake_memex_cli.dart';

const _vault = '/tmp/om-fake-vault';

/// C2.6 sample stdout (also the C2.7 shape).
const _c26Sample =
    '{"vault_id":"01HV…","id":"01J9…","name":"Games","parent_id":null,"pinned":true,"depth":1,"created_at":1759500000000,"updated_at":1759500000000}';

/// C2.8 sample stdout.
const _c28Sample = '{"vault_id":"01HV…","id":"01J9…","deleted":true}';

/// C2.9 sample stdout.
const _c29Sample =
    '{"vault_id":"01HV…","smart_folder_id":"01J9…","note_id":"01J9…","pinned":true,"role_set":false}';

/// C2.10 sample stdout.
const _c210Sample =
    '{"vault_id":"01HV…","smart_folder_id":"01J9…","note_id":"01J9…","removed":true}';

/// C1 depth error, verbatim.
const _c1DepthStderr =
    '{"error":{"code":"depth_exceeded","message":"Smart Folder depth 3 exceeds the vault maximum of 2","max_depth":2,"required_depth":3}}\n';

/// A folder object that differs from the sample in every field.
const _otherFolder =
    '{"vault_id":"01HVOTHER","id":"01J9CHILD","name":"Design","parent_id":"01J9PARENT","pinned":false,"depth":2,"created_at":1759500000001,"updated_at":1759500000999}';

Matcher _cliError(String code, String message) => throwsA(
  isA<MemexException>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.message, 'message', contains(message)),
);

Matcher get _nullCodeError =>
    throwsA(isA<MemexException>().having((e) => e.code, 'code', isNull));

void main() {
  group('folder new wrapper (AC16)', () {
    test(
      'createFolder at root sends folder new --vault --name and parses the C2.6 sample',
      () async {
        final cli = FakeMemexCli()
          ..on('folder new', (_) => FakeMemexCli.ok('$_c26Sample\n'));

        final f = await cli.createFolder(vaultPath: _vault, name: 'Games');

        expect(cli.calls.single.args, [
          'folder',
          'new',
          '--vault',
          _vault,
          '--name',
          'Games',
        ]);
        expect(f.vaultId, '01HV…');
        expect(f.id, '01J9…');
        expect(f.name, 'Games');
        expect(f.parentId, isNull);
        expect(f.pinned, isTrue);
        expect(f.depth, 1);
        expect(f.createdAt, 1759500000000);
        expect(f.updatedAt, 1759500000000);
      },
    );

    test(
      'createFolder inside a folder adds --parent-id and reads every field from stdout',
      () async {
        final cli = FakeMemexCli()
          ..on('folder new', (_) => FakeMemexCli.ok(_otherFolder));

        final f = await cli.createFolder(
          vaultPath: _vault,
          name: 'Design',
          parentId: '01J9PARENT',
        );

        expect(cli.calls.single.args, [
          'folder',
          'new',
          '--vault',
          _vault,
          '--name',
          'Design',
          '--parent-id',
          '01J9PARENT',
        ]);
        expect(f.vaultId, '01HVOTHER');
        expect(f.id, '01J9CHILD');
        expect(f.name, 'Design');
        expect(f.parentId, '01J9PARENT');
        expect(f.pinned, isFalse);
        expect(f.depth, 2);
        expect(f.createdAt, 1759500000001);
        expect(f.updatedAt, 1759500000999);
      },
    );

    test(
      'a depth_exceeded stderr yields code depth_exceeded with required_depth 3',
      () async {
        final cli = FakeMemexCli()
          ..on('folder new', (_) => FakeMemexCli.failure(_c1DepthStderr));

        await expectLater(
          cli.createFolder(vaultPath: _vault, name: 'Deep', parentId: 'p'),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', 'depth_exceeded')
                .having((e) => e.fields['required_depth'], 'required_depth', 3)
                .having((e) => e.fields['max_depth'], 'max_depth', 2)
                .having(
                  (e) => e.message,
                  'message',
                  contains(
                    'Smart Folder depth 3 exceeds the vault maximum of 2',
                  ),
                ),
          ),
        );
      },
    );

    test(
      'name_conflict and not_found from folder new surface their codes',
      () async {
        for (final code in ['name_conflict', 'not_found']) {
          final cli = FakeMemexCli()
            ..on('folder new', (_) => FakeMemexCli.error(code, 'msg $code'));
          await expectLater(
            cli.createFolder(vaultPath: _vault, name: 'Games'),
            _cliError(code, 'msg $code'),
            reason: code,
          );
        }
      },
    );

    test(
      'folder new stdout that is not the C2.6 shape throws with a null code',
      () async {
        for (final out in ['not json', '[]', '{"id":"x"}']) {
          final cli = FakeMemexCli()
            ..on('folder new', (_) => FakeMemexCli.ok(out));
          await expectLater(
            cli.createFolder(vaultPath: _vault, name: 'Games'),
            _nullCodeError,
            reason: out,
          );
        }
      },
    );
  });

  group('folder update wrapper (AC16)', () {
    test(
      'updateFolder rename sends only --id and --name and parses the C2.7 shape',
      () async {
        final cli = FakeMemexCli()
          ..on('folder update', (_) => FakeMemexCli.ok(_c26Sample));

        final f = await cli.updateFolder(
          vaultPath: _vault,
          id: '01J9…',
          name: 'Games',
        );

        expect(cli.calls.single.args, [
          'folder',
          'update',
          '--vault',
          _vault,
          '--id',
          '01J9…',
          '--name',
          'Games',
        ]);
        expect(f.id, '01J9…');
        expect(f.name, 'Games');
        expect(f.pinned, isTrue);
        expect(f.depth, 1);
        expect(f.parentId, isNull);
      },
    );

    test(
      'updateFolder move under a parent sends --parent-id and reads the result',
      () async {
        final cli = FakeMemexCli()
          ..on('folder update', (_) => FakeMemexCli.ok(_otherFolder));

        final f = await cli.updateFolder(
          vaultPath: _vault,
          id: '01J9CHILD',
          parentId: '01J9PARENT',
        );

        expect(cli.calls.single.args, [
          'folder',
          'update',
          '--vault',
          _vault,
          '--id',
          '01J9CHILD',
          '--parent-id',
          '01J9PARENT',
        ]);
        expect(f.parentId, '01J9PARENT');
        expect(f.depth, 2);
        expect(f.pinned, isFalse);
      },
    );

    test('updateFolder move to root sends the bare --to-root flag', () async {
      final cli = FakeMemexCli()
        ..on('folder update', (_) => FakeMemexCli.ok(_c26Sample));

      await cli.updateFolder(vaultPath: _vault, id: 'f1', toRoot: true);

      expect(cli.calls.single.args, [
        'folder',
        'update',
        '--vault',
        _vault,
        '--id',
        'f1',
        '--to-root',
      ]);
    });

    test(
      'updateFolder pinned false and pinned true send --pinned with that value',
      () async {
        final cli = FakeMemexCli()
          ..on('folder update', (_) => FakeMemexCli.ok(_c26Sample));

        await cli.updateFolder(vaultPath: _vault, id: 'f1', pinned: false);
        await cli.updateFolder(vaultPath: _vault, id: 'f1', pinned: true);

        expect(cli.calls[0].args, [
          'folder',
          'update',
          '--vault',
          _vault,
          '--id',
          'f1',
          '--pinned',
          'false',
        ]);
        expect(cli.calls[1].args, [
          'folder',
          'update',
          '--vault',
          _vault,
          '--id',
          'f1',
          '--pinned',
          'true',
        ]);
      },
    );

    test(
      'a depth_exceeded stderr from folder update yields required_depth 3',
      () async {
        final cli = FakeMemexCli()
          ..on('folder update', (_) => FakeMemexCli.failure(_c1DepthStderr));

        await expectLater(
          cli.updateFolder(vaultPath: _vault, id: 'f1', parentId: 'p'),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', 'depth_exceeded')
                .having((e) => e.fields['required_depth'], 'required_depth', 3),
          ),
        );
      },
    );

    test(
      'folder_cycle name_conflict and not_found from folder update surface their codes',
      () async {
        for (final code in ['folder_cycle', 'name_conflict', 'not_found']) {
          final cli = FakeMemexCli()
            ..on('folder update', (_) => FakeMemexCli.error(code, 'msg $code'));
          await expectLater(
            cli.updateFolder(vaultPath: _vault, id: 'f1', name: 'x'),
            _cliError(code, 'msg $code'),
            reason: code,
          );
        }
      },
    );

    test(
      'folder update stdout that is not the C2.7 shape throws with a null code',
      () async {
        for (final out in ['nope', '{"id":"x","name":"y"}']) {
          final cli = FakeMemexCli()
            ..on('folder update', (_) => FakeMemexCli.ok(out));
          await expectLater(
            cli.updateFolder(vaultPath: _vault, id: 'f1', name: 'y'),
            _nullCodeError,
            reason: out,
          );
        }
      },
    );
  });

  group('folder rm wrapper (AC16)', () {
    test(
      'deleteFolder sends folder rm --vault --id and parses the C2.8 sample',
      () async {
        final cli = FakeMemexCli()
          ..on('folder rm', (_) => FakeMemexCli.ok('$_c28Sample\n'));

        final r = await cli.deleteFolder(vaultPath: _vault, id: '01J9…');

        expect(cli.calls.single.args, [
          'folder',
          'rm',
          '--vault',
          _vault,
          '--id',
          '01J9…',
        ]);
        expect(r.vaultId, '01HV…');
        expect(r.id, '01J9…');
        expect(r.deleted, isTrue);
      },
    );

    test(
      'deleteFolder reads id and deleted from stdout, not constants',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'folder rm',
            (_) => FakeMemexCli.ok(
              '{"deleted":false,"id":"01J9OTHER","vault_id":"01HVOTHER"}',
            ),
          );

        final r = await cli.deleteFolder(vaultPath: _vault, id: '01J9OTHER');

        expect(r.id, '01J9OTHER');
        expect(r.vaultId, '01HVOTHER');
        expect(r.deleted, isFalse);
      },
    );

    test('a not_found stderr from folder rm surfaces code not_found', () async {
      final cli = FakeMemexCli()
        ..on('folder rm', (_) => FakeMemexCli.error('not_found', 'gone'));
      await expectLater(
        cli.deleteFolder(vaultPath: _vault, id: 'f1'),
        _cliError('not_found', 'gone'),
      );
    });

    test(
      'folder rm stdout that is not the C2.8 shape throws with a null code',
      () async {
        final cli = FakeMemexCli()
          ..on('folder rm', (_) => FakeMemexCli.ok('{"id":"x"}'));
        await expectLater(
          cli.deleteFolder(vaultPath: _vault, id: 'f1'),
          _nullCodeError,
        );
      },
    );
  });

  group('folder add wrapper (AC16)', () {
    test(
      'addToFolder without pinned sends folder add --vault --id --note-id and parses the C2.9 sample',
      () async {
        final cli = FakeMemexCli()
          ..on('folder add', (_) => FakeMemexCli.ok('$_c29Sample\n'));

        final m = await cli.addToFolder(
          vaultPath: _vault,
          folderId: '01J9…',
          noteId: '01J9…',
        );

        expect(cli.calls.single.args, [
          'folder',
          'add',
          '--vault',
          _vault,
          '--id',
          '01J9…',
          '--note-id',
          '01J9…',
        ]);
        expect(m.vaultId, '01HV…');
        expect(m.smartFolderId, '01J9…');
        expect(m.noteId, '01J9…');
        expect(m.pinned, isTrue);
        expect(m.roleSet, isFalse);
      },
    );

    test(
      'addToFolder pinned false and pinned true send --pinned with that value',
      () async {
        final cli = FakeMemexCli()
          ..on('folder add', (_) => FakeMemexCli.ok(_c29Sample));

        await cli.addToFolder(
          vaultPath: _vault,
          folderId: 'f1',
          noteId: 'n1',
          pinned: false,
        );
        await cli.addToFolder(
          vaultPath: _vault,
          folderId: 'f1',
          noteId: 'n1',
          pinned: true,
        );

        expect(cli.calls[0].args, [
          'folder',
          'add',
          '--vault',
          _vault,
          '--id',
          'f1',
          '--note-id',
          'n1',
          '--pinned',
          'false',
        ]);
        expect(cli.calls[1].args.sublist(cli.calls[1].args.length - 2), [
          '--pinned',
          'true',
        ]);
      },
    );

    test(
      'addToFolder reads role_set true and the other fields from stdout',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'folder add',
            (_) => FakeMemexCli.ok(
              '{"vault_id":"01HVOTHER","smart_folder_id":"01J9F","note_id":"01J9N","pinned":false,"role_set":true}',
            ),
          );

        final m = await cli.addToFolder(
          vaultPath: _vault,
          folderId: '01J9F',
          noteId: '01J9N',
          pinned: false,
        );

        expect(m.vaultId, '01HVOTHER');
        expect(m.smartFolderId, '01J9F');
        expect(m.noteId, '01J9N');
        expect(m.pinned, isFalse);
        expect(m.roleSet, isTrue);
      },
    );

    test(
      'role_rule and not_found from folder add surface their codes',
      () async {
        for (final code in ['role_rule', 'not_found']) {
          final cli = FakeMemexCli()
            ..on('folder add', (_) => FakeMemexCli.error(code, 'msg $code'));
          await expectLater(
            cli.addToFolder(vaultPath: _vault, folderId: 'f1', noteId: 'n1'),
            _cliError(code, 'msg $code'),
            reason: code,
          );
        }
      },
    );

    test(
      'folder add stdout that is not the C2.9 shape throws with a null code',
      () async {
        final cli = FakeMemexCli()
          ..on('folder add', (_) => FakeMemexCli.ok('{"note_id":"n1"}'));
        await expectLater(
          cli.addToFolder(vaultPath: _vault, folderId: 'f1', noteId: 'n1'),
          _nullCodeError,
        );
      },
    );
  });

  group('folder remove wrapper (AC16)', () {
    test(
      'removeFromFolder sends folder remove --vault --id --note-id and parses the C2.10 sample',
      () async {
        final cli = FakeMemexCli()
          ..on('folder remove', (_) => FakeMemexCli.ok('$_c210Sample\n'));

        final r = await cli.removeFromFolder(
          vaultPath: _vault,
          folderId: '01J9…',
          noteId: '01J9…',
        );

        expect(cli.calls.single.args, [
          'folder',
          'remove',
          '--vault',
          _vault,
          '--id',
          '01J9…',
          '--note-id',
          '01J9…',
        ]);
        expect(r.vaultId, '01HV…');
        expect(r.smartFolderId, '01J9…');
        expect(r.noteId, '01J9…');
        expect(r.removed, isTrue);
      },
    );

    test(
      'removeFromFolder reads its fields from stdout, not constants',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'folder remove',
            (_) => FakeMemexCli.ok(
              '{"vault_id":"01HVOTHER","smart_folder_id":"01J9F","note_id":"01J9N","removed":false}',
            ),
          );

        final r = await cli.removeFromFolder(
          vaultPath: _vault,
          folderId: '01J9F',
          noteId: '01J9N',
        );

        expect(r.vaultId, '01HVOTHER');
        expect(r.smartFolderId, '01J9F');
        expect(r.noteId, '01J9N');
        expect(r.removed, isFalse);
      },
    );

    test(
      'a not_found stderr from folder remove surfaces code not_found and bad stdout a null code',
      () async {
        final failing = FakeMemexCli()
          ..on('folder remove', (_) => FakeMemexCli.error('not_found', 'nope'));
        await expectLater(
          failing.removeFromFolder(
            vaultPath: _vault,
            folderId: 'f',
            noteId: 'n',
          ),
          _cliError('not_found', 'nope'),
        );

        final garbled = FakeMemexCli()
          ..on('folder remove', (_) => FakeMemexCli.ok('garbled'));
        await expectLater(
          garbled.removeFromFolder(
            vaultPath: _vault,
            folderId: 'f',
            noteId: 'n',
          ),
          _nullCodeError,
        );
      },
    );
  });
}
