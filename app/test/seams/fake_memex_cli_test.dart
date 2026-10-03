import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/settings_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/fake_memex_cli.dart';

const _vault = '/tmp/om-fake-vault';
const _noteId = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';

/// One existing `MemexCli` wrapper, the subcommand it must send through
/// `run`, a valid stdout for it, and the legacy failure-message operation.
class _Wrapper {
  const _Wrapper(this.subcommand, this.operation, this.stdout, this.invoke);
  final String subcommand;
  final String operation;
  final String stdout;
  final Future<Object?> Function(MemexCli cli) invoke;
}

final _wrappers = <_Wrapper>[
  _Wrapper('init', 'init', 'Initialised vault\n', (c) => c.initVault(_vault)),
  _Wrapper(
    'add',
    'add',
    'Created note\n  note_id: $_noteId\n  title:   Untitled\n',
    (c) => c.addNote(vaultPath: _vault, title: 'Untitled', contentMd: 'x'),
  ),
  _Wrapper(
    'update',
    'update',
    '{"note_id":"$_noteId","version":4,"updated_at":1759500000000}',
    (c) => c.updateNote(
      vaultPath: _vault,
      noteId: _noteId,
      expectedVersion: 3,
      contentMd: 'x',
    ),
  ),
  _Wrapper(
    'add-link',
    'add-link',
    '{"link_id":"L1","from":"A","to":"B","kind":"references",'
        '"source":"inline_body","was_existing":false,"note_version":2}',
    (c) => c.addLink(vaultPath: _vault, fromNoteId: 'A', toNoteId: 'B'),
  ),
  _Wrapper(
    'update-link',
    'update-link',
    '{"link_id":"L1","from_note_id":"A","to_note_id":"B","kind":"extends",'
        '"label":null,"source":"inline_body","position":0}',
    (c) => c.updateLink(vaultPath: _vault, linkId: 'L1', kind: 'extends'),
  ),
  _Wrapper(
    'canvas new',
    'canvas new',
    '{"canvas_id":"C1","title":"Board","version":1,"created_at":1,"updated_at":1}',
    (c) => c.createCanvas(vaultPath: _vault, title: 'Board'),
  ),
  _Wrapper(
    'canvas ls',
    'canvas ls',
    '{"canvases":[]}',
    (c) => c.listCanvases(vaultPath: _vault),
  ),
  _Wrapper(
    'canvas get',
    'canvas get',
    '{"canvas_id":"C1","title":"Board","version":1,"created_at":1,'
        '"updated_at":1,"nodes":[],"edges":[]}',
    (c) => c.getCanvas(vaultPath: _vault, canvasId: 'C1'),
  ),
  _Wrapper(
    'canvas rename',
    'canvas rename',
    '{"canvas_id":"C1","title":"Board 2","version":2,"created_at":1,"updated_at":2}',
    (c) => c.renameCanvas(
      vaultPath: _vault,
      canvasId: 'C1',
      title: 'Board 2',
      expectedVersion: 1,
    ),
  ),
  _Wrapper(
    'canvas rm',
    'canvas rm',
    '',
    (c) =>
        c.deleteCanvas(vaultPath: _vault, canvasId: 'C1', expectedVersion: 1),
  ),
  _Wrapper(
    'canvas add',
    'canvas add',
    '{"canvas_id":"C1","note_id":"N1","note_title":"T","x":0,"y":0,"z_order":0}',
    (c) => c.addToCanvas(vaultPath: _vault, canvasId: 'C1', noteId: 'N1'),
  ),
  _Wrapper(
    'canvas remove',
    'canvas remove',
    '',
    (c) => c.removeFromCanvas(vaultPath: _vault, canvasId: 'C1', noteId: 'N1'),
  ),
  _Wrapper(
    'canvas move',
    'canvas move',
    '{"canvas_id":"C1","note_id":"N1","note_title":"T","x":5,"y":6,"z_order":1}',
    (c) =>
        c.moveNode(vaultPath: _vault, canvasId: 'C1', noteId: 'N1', x: 5, y: 6),
  ),
  _Wrapper(
    'get',
    'get',
    '{"note_id":"N1","title":"T","content_md":"x","version":1,"tags":[]}',
    (c) => c.getNote(vaultPath: _vault, noteId: 'N1'),
  ),
];

void main() {
  group('FakeMemexCli dispatch (AC3)', () {
    test(
      'FakeMemexCli dispatches run to the handler for the subcommand path and records args and stdin',
      () async {
        final cli = FakeMemexCli();
        final seen = <String>[];
        cli
          ..on('add', (call) {
            seen.add('add');
            return FakeMemexCli.ok(
              'Created note\n  note_id: $_noteId\n  title:   2026-10-03\n',
            );
          })
          ..on('add-link', (call) {
            seen.add('add-link');
            return FakeMemexCli.ok('{}');
          })
          ..on('settings get', (call) {
            seen.add('settings get:${call.flag('key')}');
            return FakeMemexCli.ok(
              '{"vault_id":"01HV","key":"smart_folder_max_depth","value":2}',
            );
          });

        // Through the production wrappers: they must reach the fake's `run`.
        final id = await cli.addNote(
          vaultPath: _vault,
          title: 'Untitled',
          contentMd: '# Untitled\n\n',
        );
        final depth = await cli.getSetting(_vault, 'smart_folder_max_depth');

        expect(id, _noteId);
        expect(depth, 2);
        expect(seen, ['add', 'settings get:smart_folder_max_depth']);
        expect(cli.calls, hasLength(2));
        expect(cli.calls[0].subcommand, 'add');
        expect(cli.calls[0].args, [
          'add',
          '--vault',
          _vault,
          '--title',
          'Untitled',
        ]);
        expect(cli.calls[0].stdinBody, '# Untitled\n\n');
        expect(cli.calls[1].subcommand, 'settings get');
        expect(cli.calls[1].args, [
          'settings',
          'get',
          '--vault',
          _vault,
          '--key',
          'smart_folder_max_depth',
        ]);
        expect(cli.callsFor('settings get'), hasLength(1));
        expect(cli.callsFor('add-link'), isEmpty);
      },
    );

    test(
      'FakeMemexCli returns exit 1 with a code internal JSON error for an unregistered subcommand',
      () async {
        final cli = FakeMemexCli();

        final raw = await cli.run([
          'folder',
          'new',
          '--vault',
          _vault,
          '--name',
          'Games',
        ], stdinBody: 'ignored');
        expect(raw.exitCode, 1);
        expect(raw.stdout, isEmpty);
        final err =
            (jsonDecode(raw.stderr.trim()) as Map<String, dynamic>)['error']
                as Map<String, dynamic>;
        expect(err['code'], 'internal');
        expect(
          err['message'],
          'FakeMemexCli: no handler for folder new --vault $_vault --name Games',
        );
        expect(cli.calls.single.stdinBody, 'ignored');
        expect(cli.calls.single.subcommand, 'folder new');

        // A production wrapper surfaces that error as a typed MemexException.
        await expectLater(
          cli.updateNote(
            vaultPath: _vault,
            noteId: _noteId,
            expectedVersion: 1,
            contentMd: 'x',
          ),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', 'internal')
                .having(
                  (e) => e.message,
                  'message',
                  contains('FakeMemexCli: no handler for update'),
                ),
          ),
        );
        expect(cli.calls, hasLength(2));
        expect(cli.calls.last.subcommand, 'update');
      },
    );
  });

  group('every wrapper goes through public run (AC4)', () {
    test(
      'a FakeMemexCli update handler drives updateNote without spawning a process',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'update',
            (call) => FakeMemexCli.ok(
              '{"vault_id":"01HV","note_id":"${call.flag('note-id')}",'
              '"version":4,"updated_at":1759500000000}',
            ),
          );

        final r = await cli.updateNote(
          vaultPath: _vault,
          noteId: _noteId,
          expectedVersion: 3,
          contentMd: 'Morning pages\n',
        );

        expect(r.noteId, _noteId);
        expect(r.version, 4);
        expect(r.updatedAt, 1759500000000);
        expect(cli.calls.single.args, [
          'update',
          '--vault',
          _vault,
          '--note-id',
          _noteId,
          '--expected-version',
          '3',
        ]);
        expect(cli.calls.single.stdinBody, 'Morning pages\n');
      },
    );

    test(
      'every existing MemexCli wrapper sends its subcommand through run',
      () async {
        final cli = FakeMemexCli();
        for (final w in _wrappers) {
          cli.on(w.subcommand, (_) => FakeMemexCli.ok(w.stdout));
        }
        for (final w in _wrappers) {
          await w.invoke(cli);
          expect(
            cli.calls.last.subcommand,
            w.subcommand,
            reason: '${w.operation} must call run',
          );
          expect(cli.calls.last.args, contains(_vault), reason: w.operation);
        }
        expect(cli.calls, hasLength(_wrappers.length));
      },
    );

    test(
      'every existing MemexCli wrapper turns a C1 stderr error into MemexException.code',
      () async {
        final cli = FakeMemexCli();
        for (final w in _wrappers) {
          cli.on(
            w.subcommand,
            (_) => FakeMemexCli.failure(
              '{"error":{"code":"not_found","message":"no such thing: ${w.operation}"}}\n',
            ),
          );
        }
        for (final w in _wrappers) {
          await expectLater(
            w.invoke(cli),
            throwsA(
              isA<MemexException>()
                  .having((e) => e.code, 'code', 'not_found')
                  .having(
                    (e) => e.message,
                    'message',
                    contains('no such thing: ${w.operation}'),
                  ),
            ),
            reason: w.operation,
          );
        }
      },
    );

    test(
      'every existing MemexCli wrapper keeps the legacy message for non-JSON stderr',
      () async {
        final cli = FakeMemexCli();
        for (final w in _wrappers) {
          cli.on(w.subcommand, (_) => FakeMemexCli.failure('Error: boom\n'));
        }
        for (final w in _wrappers) {
          await expectLater(
            w.invoke(cli),
            throwsA(
              isA<MemexException>()
                  .having((e) => e.code, 'code', isNull)
                  .having(
                    (e) => e.message,
                    'message',
                    '${w.operation} failed: Error: boom\n',
                  ),
            ),
            reason: w.operation,
          );
        }
      },
    );
  });
}
