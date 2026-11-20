// WI #140 (Spec #123 W3; R15, R16, R33, R42; rulings D10, D13): the local
// vault's attachments domain, `LocalAttachmentsAccess`.
//
// - `add` and `addBytes` store through `memex attach --vault <vault> <file>
//   [--name <name>]` (the fake CLI; never a real `memex`). Bytes go through a
//   temporary file that is deleted afterwards, on success and on failure.
// - `read` and `info` read `<vault>/objects/…` directly; nothing outside
//   `objects/` is ever read or opened.
// - `open` calls the URL opener with the absolute path, except for R33's
//   executable table and files with an executable permission bit: those are
//   revealed, never opened (D10, L17).
// - D13: after the app's own add, `info` of the new path makes no stat.
//
// Every vault lives in a runtime temp dir named `My Vault`.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/attachment_ref.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';
import 'package:open_memex_app/src/state/file_revealer.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/attachments_access.dart';
import 'package:open_memex_app/src/vault_access/local/attachments.dart';
import 'package:path/path.dart' as p;

import '../../support/attachments_fakes.dart';
import '../../support/fake_file_revealer.dart';
import '../../support/fake_memex_cli.dart';

const _memexTooOld =
    "This vault's memex is too old for attachments; update memex.";

class _Wi140UrlOpener implements UrlOpener {
  final List<String> opened = [];

  @override
  Future<void> open(String url) async => opened.add(url);
}

/// The vault-relative path of a stored attachment named [name].
String _path(String name) => 'objects/aa/$fakeAttachmentHash/$name';

class _Env {
  _Env(this.root, this.vaultPath);

  final String root;
  final String vaultPath;
  final cli = FakeMemexCli();
  final opener = _Wi140UrlOpener();
  final revealer = FakeFileRevealer();
  final List<String> stats = [];

  late final LocalAttachmentsAccess access = LocalAttachmentsAccess(
    vaultPath: vaultPath,
    cli: cli,
    urlOpener: opener,
    fileRevealer: revealer,
    stat: (path) {
      stats.add(path);
      return FileStat.stat(path);
    },
  );

  /// Writes [bytes] at the vault-relative [path] and returns its absolute
  /// path.
  String put(String path, List<int> bytes) {
    final file = File(p.join(vaultPath, path));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file.path;
  }

  /// Registers an `attach` handler answering [answer] for every call.
  void onAttach(MemexResult Function(FakeCliCall call) answer) =>
      cli.on('attach', answer);
}

_Env _env() {
  final root = Directory.systemTemp.createTempSync('wi140-local-');
  addTearDown(() => root.deleteSync(recursive: true));
  final vault = Directory(p.join(root.path, 'My Vault'))..createSync();
  return _Env(root.path, vault.path);
}

/// The value after `--<name>` (or in `--<name>=<value>`) in [call], or null.
String? _flag(FakeCliCall call, String name) {
  final a = call.args;
  for (var i = 0; i < a.length; i++) {
    if (a[i] == '--') return null;
    if (a[i] == '--$name' && i + 1 < a.length) return a[i + 1];
    if (a[i].startsWith('--$name=')) return a[i].substring(name.length + 3);
  }
  return null;
}

/// The positional arguments after `attach` (flags and their values left
/// out; everything after `--` kept).
List<String> _positionals(FakeCliCall call) {
  final a = call.args;
  final out = <String>[];
  for (var i = 1; i < a.length; i++) {
    final s = a[i];
    if (s == '--') {
      out.addAll(a.sublist(i + 1));
      break;
    }
    if (s == '--vault' || s == '--name') {
      i++;
      continue;
    }
    if (s.startsWith('--')) continue;
    out.add(s);
  }
  return out;
}

/// `memex attach`'s one JSON line for [name].
MemexResult _stored(
  String name, {
  int size = 812,
  String type = 'application/pdf',
}) {
  final a = fakeAddedAttachment(name, size: size, type: type);
  return FakeMemexCli.ok(
    '${jsonEncode({'markdown': a.markdown, 'path': a.path, 'name': a.name, 'size': a.size, 'type': a.type})}\n',
  );
}

/// What clap prints for a subcommand it doesn't know (exit 2).
final _unknownSubcommand = FakeMemexCli.failure(
  "error: unrecognized subcommand 'attach'\n\nUsage: memex <COMMAND>\n\n"
  "For more information, try '--help'.\n",
  exitCode: 2,
);

/// [o] as a [T], failing the test (not throwing) when it is not one.
T _as<T>(Object? o) {
  expect(o, isA<T>());
  return o as T;
}

/// The one element of [l], failing the test when there isn't exactly one.
T _single<T>(List<T> l) {
  expect(l, hasLength(1));
  return l.single;
}

void main() {
  group('add', () {
    test(
      'local add runs memex attach with the vault and the file and returns its JSON fields',
      () async {
        final env = _env();
        final file = File(p.join(env.root, 'Q3 report.pdf'))
          ..writeAsBytesSync([1, 2, 3]);
        env.onAttach((_) => _stored('Q3 report.pdf'));

        final result = await env.access.add(file.path, null);

        final calls = env.cli.callsFor('attach');
        expect(calls, hasLength(1));
        expect(_flag(calls.single, 'vault'), env.vaultPath);
        expect(_positionals(calls.single), [file.path]);
        expect(_flag(calls.single, 'name'), isNull);
        expect(result, isA<AttachmentAdded>());
        final added = _as<AttachmentAdded>(result).attachment;
        final want = fakeAddedAttachment(
          'Q3 report.pdf',
          size: 812,
          type: 'application/pdf',
        );
        expect(added.markdown, want.markdown);
        expect(added.path, want.path);
        expect(added.name, 'Q3 report.pdf');
        expect(added.size, 812);
        expect(added.type, 'application/pdf');
      },
    );

    test('local add with a name passes it as the name flag', () async {
      final env = _env();
      final file = File(p.join(env.root, 'scan.pdf'))..writeAsBytesSync([1]);
      env.onAttach((c) => _stored(_flag(c, 'name') ?? 'scan.pdf'));

      final result = await env.access.add(file.path, 'Signed lease.pdf');

      final call = _single(env.cli.callsFor('attach'));
      expect(_flag(call, 'name'), 'Signed lease.pdf');
      expect(_flag(call, 'vault'), env.vaultPath);
      expect(_positionals(call), [file.path]);
      expect(_as<AttachmentAdded>(result).attachment.name, 'Signed lease.pdf');
    });

    test(
      'local addBytes writes the bytes to a temp file, attaches it with the name flag and deletes it',
      () async {
        final env = _env();
        final bytes = Uint8List.fromList(List.generate(300, (i) => i % 256));
        String? tempPath;
        List<int>? tempBytes;
        env.onAttach((c) {
          tempPath = _positionals(c).single;
          final f = File(tempPath!);
          tempBytes = f.existsSync() ? f.readAsBytesSync() : null;
          return _stored(
            _flag(c, 'name')!,
            size: bytes.length,
            type: 'image/png',
          );
        });

        final result = await env.access.addBytes(
          bytes,
          'Pasted image 2026-11-19 09.30.00.png',
        );

        final call = _single(env.cli.callsFor('attach'));
        expect(_flag(call, 'vault'), env.vaultPath);
        expect(_flag(call, 'name'), 'Pasted image 2026-11-19 09.30.00.png');
        expect(tempBytes, bytes, reason: 'the temp file holds the bytes');
        expect(
          p.isWithin(env.vaultPath, tempPath!),
          isFalse,
          reason: 'the temp file is not written into the vault',
        );
        expect(File(tempPath!).existsSync(), isFalse, reason: 'deleted');
        final added = _as<AttachmentAdded>(result).attachment;
        expect(added.name, 'Pasted image 2026-11-19 09.30.00.png');
        expect(added.size, 300);
        expect(added.type, 'image/png');
      },
    );

    test(
      'local addBytes deletes the temp file when memex refuses it',
      () async {
        final env = _env();
        String? tempPath;
        bool? existed;
        env.onAttach((c) {
          tempPath = _positionals(c).single;
          existed = File(tempPath!).existsSync();
          return FakeMemexCli.error(
            'invalid_argument',
            "big.bin is larger than 100 MB and wasn't attached.",
          );
        });

        final result = await env.access.addBytes(Uint8List(16), 'big.bin');

        expect(existed, isTrue);
        expect(File(tempPath!).existsSync(), isFalse);
        expect(result, isA<AttachmentAddFailed>());
        expect(
          _as<AttachmentAddFailed>(result).message,
          "big.bin is larger than 100 MB and wasn't attached.",
        );
      },
    );

    test(
      'local addBytes deletes the temp file when memex is too old',
      () async {
        final env = _env();
        String? tempPath;
        env.onAttach((c) {
          tempPath = _positionals(c).single;
          return _unknownSubcommand;
        });

        final result = await env.access.addBytes(Uint8List(4), 'shot.png');

        expect(tempPath, isNotNull);
        expect(File(tempPath!).existsSync(), isFalse);
        expect(_as<AttachmentAddFailed>(result).message, _memexTooOld);
      },
    );

    test(
      'local add surfaces a C1 error message as the failure reason',
      () async {
        final env = _env();
        final file = File(p.join(env.root, 'big.bin'))..writeAsBytesSync([0]);
        const messages = [
          "big.bin is larger than 100 MB and wasn't attached.",
          "Folders can't be attached.",
          "fifo isn't a regular file and wasn't attached.",
          'permission denied: big.bin',
        ];
        for (final message in messages) {
          env.onAttach(
            (_) => FakeMemexCli.error(
              message.startsWith('permission') ? 'io' : 'invalid_argument',
              message,
            ),
          );

          final result = await env.access.add(file.path, null);

          expect(result, isA<AttachmentAddFailed>(), reason: message);
          final failed = _as<AttachmentAddFailed>(result);
          expect(failed.message, message, reason: 'exactly the C1 message');
          expect(
            failed.reason,
            isNot(
              anyOf(
                AttachmentAddFailureReason.memexTooOld,
                AttachmentAddFailureReason.unsupported,
                AttachmentAddFailureReason.unreachable,
              ),
            ),
            reason: message,
          );
        }
      },
    );

    test(
      'a local memex without attach gives the memex too old failure',
      () async {
        final env = _env();
        final file = File(p.join(env.root, 'a.pdf'))..writeAsBytesSync([0]);
        env.onAttach((_) => _unknownSubcommand);

        final fromFile = await env.access.add(file.path, null);
        final fromBytes = await env.access.addBytes(Uint8List(2), 'b.png');

        for (final result in [fromFile, fromBytes]) {
          expect(result, isA<AttachmentAddFailed>());
          final failed = _as<AttachmentAddFailed>(result);
          expect(failed.reason, AttachmentAddFailureReason.memexTooOld);
          expect(failed.message, _memexTooOld);
        }
      },
    );

    test(
      'an exit 2 with a C1 JSON error is not the memex too old failure',
      () async {
        final env = _env();
        final file = File(p.join(env.root, 'a.pdf'))..writeAsBytesSync([0]);
        env.onAttach(
          (_) => MemexResult(
            exitCode: 2,
            stdout: '',
            stderr:
                '${jsonEncode({
                  'error': {'code': 'io', 'message': 'disk full'},
                })}\n',
          ),
        );

        final result = await env.access.add(file.path, null);

        final failed = _as<AttachmentAddFailed>(result);
        expect(failed.reason, isNot(AttachmentAddFailureReason.memexTooOld));
        expect(failed.message, 'disk full');
      },
    );

    test(
      'local add answers a failure when memex prints output it cannot read',
      () async {
        final env = _env();
        final file = File(p.join(env.root, 'a.pdf'))..writeAsBytesSync([0]);
        env.onAttach((_) => FakeMemexCli.ok('stored a.pdf\n'));

        final result = await env.access.add(file.path, null);

        expect(result, isA<AttachmentAddFailed>());
        expect(
          _as<AttachmentAddFailed>(result).reason,
          AttachmentAddFailureReason.other,
        );
      },
    );
  });

  group('read and info', () {
    test('local read returns the bytes of the file under objects', () async {
      final env = _env();
      final bytes = List.generate(1000, (i) => (i * 7) % 256);
      env.put(_path('My photo.png'), bytes);

      final result = await env.access.read(_path('My photo.png'));

      expect(result, isA<AttachmentBytes>());
      expect(_as<AttachmentBytes>(result).bytes, bytes);
      expect(env.cli.calls, isEmpty, reason: 'reads never run memex');
    });

    test('local info gives the size of the file under objects', () async {
      final env = _env();
      env.put(_path('report.pdf'), List.filled(4321, 1));

      final result = await env.access.info(_path('report.pdf'));

      expect(result, isA<AttachmentInfoFound>());
      expect(_as<AttachmentInfoFound>(result).info.size, 4321);
      expect(env.cli.calls, isEmpty);
    });

    test(
      'local read info and open of a missing file give the missing result',
      () async {
        final env = _env();

        final read = await env.access.read(_path('gone.png'));
        final info = await env.access.info(_path('gone.pdf'));
        final open = await env.access.open(_path('gone.pdf'));

        expect(read, isA<AttachmentReadFailed>());
        expect(
          _as<AttachmentReadFailed>(read).failure,
          AttachmentLookupFailure.missing,
        );
        expect(info, isA<AttachmentInfoFailed>());
        expect(
          _as<AttachmentInfoFailed>(info).failure,
          AttachmentLookupFailure.missing,
        );
        expect(open, isA<AttachmentActionFailed>());
        expect(
          _as<AttachmentActionFailed>(open).failure,
          AttachmentLookupFailure.missing,
        );
        expect(env.opener.opened, isEmpty);
        expect(env.revealer.paths, isEmpty);
      },
    );

    test(
      'local read info and open never reach a path outside objects',
      () async {
        final env = _env();
        File(p.join(env.root, 'secret.txt')).writeAsStringSync('outside');
        File(p.join(env.vaultPath, 'secret.txt')).writeAsStringSync('vault');
        env.put('notes/plan.md', utf8.encode('# plan'));
        // The control: a path under objects/ reads and opens.
        env.put(_path('inside.pdf'), [7]);
        final inside = await env.access.read(_path('inside.pdf'));
        expect(_as<AttachmentBytes>(inside).bytes, [7]);
        expect(
          await env.access.open(_path('inside.pdf')),
          isA<AttachmentActionDone>(),
        );
        env.opener.opened.clear();
        final outside = [
          '../secret.txt',
          'secret.txt',
          'notes/plan.md',
          'objects/../secret.txt',
          'objects/aa/$fakeAttachmentHash/../../../secret.txt',
          'objects/aa/$fakeAttachmentHash/../../../../secret.txt',
          p.join(env.root, 'secret.txt'),
        ];
        for (final path in outside) {
          final read = await env.access.read(path);
          final info = await env.access.info(path);
          final open = await env.access.open(path);
          final reveal = await env.access.reveal(path);

          expect(read, isA<AttachmentReadFailed>(), reason: path);
          expect(info, isA<AttachmentInfoFailed>(), reason: path);
          expect(open, isA<AttachmentActionFailed>(), reason: path);
          expect(reveal, isA<AttachmentActionFailed>(), reason: path);
        }
        expect(env.opener.opened, isEmpty);
        expect(env.revealer.paths, isEmpty);
      },
    );
  });

  group('D13 write-through', () {
    test('after a local add info makes no filesystem stat', () async {
      final env = _env();
      final file = File(p.join(env.root, 'deck.pdf'))..writeAsBytesSync([1]);
      // The fake CLI stores nothing on disk: only the info cache can answer.
      env.onAttach((c) {
        final name = _flag(c, 'name');
        return name == null
            ? _stored('deck.pdf', size: 9000, type: 'application/pdf')
            : _stored(name, size: 77, type: 'image/png');
      });

      final added = await env.access.add(file.path, null);
      final bytesAdded = await env.access.addBytes(Uint8List(77), 'clip.png');
      env.stats.clear();

      for (final (result, size, type) in [
        (added, 9000, 'application/pdf'),
        (bytesAdded, 77, 'image/png'),
      ]) {
        final path = _as<AttachmentAdded>(result).attachment.path;
        for (var i = 0; i < 2; i++) {
          final info = await env.access.info(path);
          expect(info, isA<AttachmentInfoFound>(), reason: path);
          expect(_as<AttachmentInfoFound>(info).info.size, size);
          expect(_as<AttachmentInfoFound>(info).info.type, type);
        }
      }
      expect(env.stats, isEmpty, reason: 'no stat after the app add');
    });
  });

  group('open and reveal', () {
    test(
      'local open of a pdf calls the url opener with the absolute path',
      () async {
        final env = _env();
        final abs = env.put(_path('Q3 report.pdf'), [1, 2]);

        final result = await env.access.open(_path('Q3 report.pdf'));

        expect(result, isA<AttachmentActionDone>());
        expect(env.opener.opened, [abs]);
        expect(p.isAbsolute(env.opener.opened.single), isTrue);
        expect(env.revealer.paths, isEmpty);
      },
    );

    test(
      'local open of every executable table type reveals and never opens',
      () async {
        final env = _env();
        final names = [
          for (final ext in executableExtensions) ...[
            'tool.$ext',
            'TOOL.${ext.toUpperCase()}',
          ],
        ];
        final expected = <String>[];
        for (final name in names) {
          expected.add(env.put(_path(name), [0]));

          final result = await env.access.open(_path(name));

          expect(result, isA<AttachmentActionDone>(), reason: name);
        }
        expect(env.revealer.paths, expected);
        expect(env.opener.opened, isEmpty);
      },
    );

    test(
      'local open of a file with an executable bit reveals and never opens',
      () async {
        final env = _env();
        final modes = {
          'owner.txt': '744',
          'group.txt': '654',
          'other.txt': '645',
          'plain.txt': '644',
        };
        final abs = <String, String>{};
        for (final MapEntry(key: name, value: mode) in modes.entries) {
          abs[name] = env.put(_path(name), utf8.encode(name));
          final chmod = await Process.run('chmod', [mode, abs[name]!]);
          expect(chmod.exitCode, 0);
        }

        for (final name in modes.keys) {
          final result = await env.access.open(_path(name));
          expect(result, isA<AttachmentActionDone>(), reason: name);
        }

        expect(env.revealer.paths, [
          abs['owner.txt'],
          abs['group.txt'],
          abs['other.txt'],
        ]);
        expect(env.opener.opened, [abs['plain.txt']]);
      },
    );

    test(
      'local reveal calls the file revealer with the absolute path',
      () async {
        final env = _env();
        final abs = env.put(_path('Q3 report.pdf'), [1]);

        final result = await env.access.reveal(_path('Q3 report.pdf'));

        expect(result, isA<AttachmentActionDone>());
        expect(env.revealer.paths, [abs]);
        expect(env.opener.opened, isEmpty);
      },
    );
  });

  group('verify: contracts of the domain docs', () {
    test(
      'local read info open and reveal refuse a symlink under objects',
      () async {
        final env = _env();
        final outside = Directory(p.join(env.root, 'elsewhere'))..createSync();
        File(p.join(outside.path, 'x.pdf')).writeAsBytesSync([9, 9]);
        final h2 = Directory(p.join(env.vaultPath, 'objects', 'aa'))
          ..createSync(recursive: true);
        // The hash folder is a link to a folder outside the vault.
        Link(p.join(h2.path, fakeAttachmentHash)).createSync(outside.path);
        // The file itself is a link to a file outside the vault.
        final other =
            '${fakeAttachmentHash.substring(0, 2)}'
            '${'b' * 62}';
        final otherDir = Directory(p.join(h2.path, other))..createSync();
        Link(
          p.join(otherDir.path, 'y.pdf'),
        ).createSync(p.join(outside.path, 'x.pdf'));
        // The objects folder of a second vault is a link to a real one.
        final second = Directory(p.join(env.root, 'Second'))..createSync();
        final real = Directory(p.join(env.root, 'real objects'))..createSync();
        Link(p.join(second.path, 'objects')).createSync(real.path);
        final viaObjectsLink = LocalAttachmentsAccess(
          vaultPath: second.path,
          urlOpener: env.opener,
          fileRevealer: env.revealer,
        );
        Directory(
          p.join(real.path, 'aa', fakeAttachmentHash),
        ).createSync(recursive: true);
        File(
          p.join(real.path, 'aa', fakeAttachmentHash, 'z.pdf'),
        ).writeAsBytesSync([1]);

        final cases = <(LocalAttachmentsAccess, String)>[
          (env.access, 'objects/aa/$fakeAttachmentHash/x.pdf'),
          (env.access, 'objects/aa/$other/y.pdf'),
          (viaObjectsLink, 'objects/aa/$fakeAttachmentHash/z.pdf'),
        ];
        for (final (access, path) in cases) {
          final read = await access.read(path);
          final info = await access.info(path);
          final open = await access.open(path);
          final reveal = await access.reveal(path);

          expect(
            _as<AttachmentReadFailed>(read).failure,
            AttachmentLookupFailure.missing,
            reason: path,
          );
          expect(
            _as<AttachmentInfoFailed>(info).failure,
            AttachmentLookupFailure.missing,
            reason: path,
          );
          expect(
            _as<AttachmentActionFailed>(open).failure,
            AttachmentLookupFailure.missing,
            reason: path,
          );
          expect(
            _as<AttachmentActionFailed>(reveal).failure,
            AttachmentLookupFailure.missing,
            reason: path,
          );
        }
        expect(env.opener.opened, isEmpty);
        expect(env.revealer.paths, isEmpty);
      },
    );

    test(
      'local read info and open of a folder at the path give missing',
      () async {
        final env = _env();
        Directory(
          p.join(env.vaultPath, _path('folder.pdf')),
        ).createSync(recursive: true);

        final read = await env.access.read(_path('folder.pdf'));
        final info = await env.access.info(_path('folder.pdf'));
        final open = await env.access.open(_path('folder.pdf'));

        expect(
          _as<AttachmentReadFailed>(read).failure,
          AttachmentLookupFailure.missing,
        );
        expect(
          _as<AttachmentInfoFailed>(info).failure,
          AttachmentLookupFailure.missing,
        );
        expect(
          _as<AttachmentActionFailed>(open).failure,
          AttachmentLookupFailure.missing,
        );
        expect(env.opener.opened, isEmpty);
      },
    );

    test(
      'local info stats once and caches the size and a generic type',
      () async {
        final env = _env();
        env.put(_path('report.pdf'), List.filled(55, 1));

        final first = await env.access.info(_path('report.pdf'));
        final second = await env.access.info(_path('report.pdf'));

        for (final r in [first, second]) {
          final found = _as<AttachmentInfoFound>(r).info;
          expect(found.size, 55);
          expect(found.type, 'application/octet-stream');
        }
        expect(env.stats, hasLength(1), reason: 'the second info is cached');
      },
    );

    test('local add refusals map by the R15 text to their reason', () async {
      final env = _env();
      final file = File(p.join(env.root, 'big.bin'))..writeAsBytesSync([0]);
      final table = {
        "big.bin is larger than 100 MB and wasn't attached.":
            AttachmentAddFailureReason.tooLarge,
        "Q3 report.pdf is larger than 100 MB and wasn't attached.":
            AttachmentAddFailureReason.tooLarge,
        "Folders can't be attached.": AttachmentAddFailureReason.folder,
        "fifo isn't a regular file and wasn't attached.":
            AttachmentAddFailureReason.other,
        'Folders can not be attached.': AttachmentAddFailureReason.other,
        'permission denied: big.bin': AttachmentAddFailureReason.other,
      };
      for (final MapEntry(key: message, value: reason) in table.entries) {
        env.onAttach((_) => FakeMemexCli.error('invalid_argument', message));

        final result = await env.access.add(file.path, null);

        final failed = _as<AttachmentAddFailed>(result);
        expect(failed.message, message);
        expect(failed.reason, reason, reason: message);
      }
    });

    test(
      'local add puts the file after a double dash in the memex call',
      () async {
        final env = _env();
        final file = File(p.join(env.root, '-odd name.pdf'))
          ..writeAsBytesSync([0]);
        env.onAttach((_) => _stored('-odd name.pdf'));

        await env.access.add(file.path, 'a b.pdf');

        final args = _single(env.cli.callsFor('attach')).args;
        expect(args.first, 'attach');
        expect(args.last, file.path);
        expect(
          args[args.length - 2],
          '--',
          reason: 'a file never reads as a flag',
        );
        expect(args, contains('--vault'));
        expect(args.indexOf('--vault') + 1, lessThan(args.length - 2));
        expect(args[args.indexOf('--vault') + 1], env.vaultPath);
        expect(
          args.any((a) => a == '--name=a b.pdf' || a == 'a b.pdf'),
          isTrue,
          reason: 'the name is passed whole',
        );
      },
    );

    test('local add answers a failure when memex cannot be started', () async {
      final env = _env();
      final file = File(p.join(env.root, 'a.pdf'))..writeAsBytesSync([0]);
      env.onAttach(
        (_) =>
            throw const ProcessException('memex', ['attach'], 'no such file'),
      );

      final added = await env.access.add(file.path, null);
      final bytes = await env.access.addBytes(Uint8List(3), 'a.png');

      for (final r in [added, bytes]) {
        final failed = _as<AttachmentAddFailed>(r);
        expect(failed.reason, AttachmentAddFailureReason.other);
        expect(failed.message, 'no such file');
      }
    });

    test(
      'local add without a memex answers unsupported and runs nothing',
      () async {
        final env = _env();
        final noCli = LocalAttachmentsAccess(vaultPath: env.vaultPath);
        final file = File(p.join(env.root, 'a.pdf'))..writeAsBytesSync([0]);

        final added = await noCli.add(file.path, null);
        final bytes = await noCli.addBytes(Uint8List(3), 'a.png');

        for (final r in [added, bytes]) {
          expect(
            _as<AttachmentAddFailed>(r).reason,
            AttachmentAddFailureReason.unsupported,
          );
        }
      },
    );

    test(
      'local add of a non-JSON failure shows the stderr or the exit code',
      () async {
        final env = _env();
        final file = File(p.join(env.root, 'a.pdf'))..writeAsBytesSync([0]);

        env.onAttach((_) => FakeMemexCli.failure('  boom: disk on fire\n'));
        final withText = await env.access.add(file.path, null);
        env.onAttach((_) => FakeMemexCli.failure('', exitCode: 3));
        final silent = await env.access.add(file.path, null);

        final text = _as<AttachmentAddFailed>(withText);
        expect(text.reason, AttachmentAddFailureReason.other);
        expect(text.message, 'boom: disk on fire');
        final empty = _as<AttachmentAddFailed>(silent);
        expect(empty.reason, AttachmentAddFailureReason.other);
        expect(empty.message, 'memex attach failed (exit 3).');
      },
    );

    test(
      'local add reads the first non-empty line and refuses a wrong shape',
      () async {
        final env = _env();
        final file = File(p.join(env.root, 'a.pdf'))..writeAsBytesSync([0]);
        final good = <String, Object?>{
          'markdown': '[a.pdf](objects/aa/h/a.pdf)',
          'path': 'objects/aa/h/a.pdf',
          'name': 'a.pdf',
          'size': 5,
          'type': 'application/pdf',
        };

        env.onAttach(
          (_) => FakeMemexCli.ok('\n  \n${jsonEncode(good)}\nextra\n'),
        );
        final lead = await env.access.add(file.path, null);
        expect(
          _as<AttachmentAdded>(lead).attachment.path,
          'objects/aa/h/a.pdf',
        );

        final bad = <String, String>{
          'empty output': '',
          'blank lines only': '\n  \n',
          'not json': 'nope\n',
          'a json array': '[1]\n',
          ...{
            for (final key in good.keys)
              'no $key': '${jsonEncode({...good}..remove(key))}\n',
          },
          'size is text': '${jsonEncode({...good, 'size': '5'})}\n',
          'name is a number': '${jsonEncode({...good, 'name': 5})}\n',
          'path is null': '${jsonEncode({...good, 'path': null})}\n',
          'markdown is a number': '${jsonEncode({...good, 'markdown': 1})}\n',
          'type is a number': '${jsonEncode({...good, 'type': 1})}\n',
        };
        for (final MapEntry(key: why, value: out) in bad.entries) {
          env.onAttach((_) => FakeMemexCli.ok(out));

          final result = await env.access.add(file.path, null);

          expect(result, isA<AttachmentAddFailed>(), reason: why);
          expect(
            _as<AttachmentAddFailed>(result).reason,
            AttachmentAddFailureReason.other,
            reason: why,
          );
        }
      },
    );
  });

  group('verify r1: the providers reach the domain', () {
    test(
      'a local vault opened through the providers opens and reveals through the overridden opener and revealer',
      () async {
        final env = _env();
        final pdf = env.put(_path('report.pdf'), [1, 2]);
        final script = env.put(_path('setup.sh'), [3]);
        final opener = _Wi140UrlOpener();
        final revealer = FakeFileRevealer();
        final container = ProviderContainer(
          overrides: [
            currentVaultProvider.overrideWith(
              (_) => LocalVaultRef(env.vaultPath),
            ),
            vaultDbProvider.overrideWithValue(null),
            memexCliProvider.overrideWithValue(null),
            urlOpenerProvider.overrideWithValue(opener),
            fileRevealerProvider.overrideWithValue(revealer),
          ],
        );
        addTearDown(container.dispose);

        final attachments = container.read(attachmentsProvider)!;
        final opened = await attachments.open(_path('report.pdf'));
        final revealedScript = await attachments.open(_path('setup.sh'));
        final revealed = await attachments.reveal(_path('report.pdf'));

        expect(opened, isA<AttachmentActionDone>());
        expect(revealedScript, isA<AttachmentActionDone>());
        expect(revealed, isA<AttachmentActionDone>());
        expect(opener.opened, [pdf]);
        expect(revealer.paths, [script, pdf]);
      },
    );
  });
}
