// WI #144 (Spec #123 R39; ruling D10; review round 1): the local attachments
// domain's synchronous locate, `LocalAttachmentsAccess.locateSync`, which the
// attachment block uses to learn a local file's size and header before its
// first frame.
//
// It must find a file on the same terms `read`, `info`, `open` and `reveal`
// do: the absolute path of a regular file under `<vault>/objects/<h2>/<hash>/`
// reached with no symlink on the way, else null. Each case is also checked
// against `info`, so the two never disagree.
//
// Every vault lives in a runtime temp dir named `My Vault`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/vault_access/attachments_access.dart';
import 'package:open_memex_app/src/vault_access/local/attachments.dart';
import 'package:path/path.dart' as p;


/// The vault-relative path of a stored attachment named [name] under the
/// folder of the 64 hex characters [hash].
String _t144Path(String hash, String name) =>
    'objects/${hash.substring(0, 2)}/$hash/$name';

String _t144Hash(String fill) => 'cd${fill * 62}';

void main() {
  late Directory root;
  late String vaultPath;
  late LocalAttachmentsAccess access;

  setUp(() {
    root = Directory.systemTemp.createTempSync('t144-locate');
    vaultPath = p.join(root.path, 'My Vault');
    Directory(vaultPath).createSync();
    access = LocalAttachmentsAccess(vaultPath: vaultPath);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Writes [bytes] at the vault-relative [path].
  String put(String path, List<int> bytes) {
    final file = File(p.join(vaultPath, path));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file.path;
  }

  Future<void> expectMissingToo(String path) async {
    final info = await access.info(path);
    expect(
      info,
      isA<AttachmentInfoFailed>().having(
        (f) => f.failure,
        'failure',
        AttachmentLookupFailure.missing,
      ),
      reason: 'the domain answers missing for $path',
    );
  }

  group('locateSync (review r1)', () {
    test('locateSync gives the absolute path of a regular stored file', () {
      final hash = _t144Hash('a');
      final path = _t144Path(hash, 'Q3 report.pdf');
      final abs = put(path, [1, 2, 3]);

      expect(access.locateSync(path), abs);
      expect(p.isAbsolute(access.locateSync(path)!), isTrue);
    });

    test('locateSync gives null for a path that is not an attachment path', () {
      put('notes/plain.pdf', [1]);

      for (final path in [
        'notes/plain.pdf',
        'objects/ab/short/x.pdf',
        'objects/ab/${_t144Hash('a')}',
        '',
      ]) {
        expect(access.locateSync(path), isNull, reason: path);
      }
    });

    test('locateSync gives null for a file that is missing', () {
      final hash = _t144Hash('b');

      expect(access.locateSync(_t144Path(hash, 'none.pdf')), isNull);
      // The folder is there, the file is not.
      Directory(
        p.join(vaultPath, 'objects', 'cd', hash),
      ).createSync(recursive: true);
      expect(access.locateSync(_t144Path(hash, 'none.pdf')), isNull);
    });

    test(
      'locateSync gives null where a folder stands at the file path',
      () async {
        final hash = _t144Hash('c');
        final path = _t144Path(hash, 'folder.pdf');
        Directory(p.join(vaultPath, path)).createSync(recursive: true);

        expect(access.locateSync(path), isNull);
        await expectMissingToo(path);
      },
    );

    test('locateSync gives null for a file that is a symlink', () async {
      final hash = _t144Hash('d');
      final path = _t144Path(hash, 'x.pdf');
      final outside = File(p.join(root.path, 'elsewhere.pdf'))
        ..writeAsBytesSync([9, 9]);
      Directory(p.dirname(p.join(vaultPath, path))).createSync(recursive: true);
      Link(p.join(vaultPath, path)).createSync(outside.path);

      expect(access.locateSync(path), isNull);
      await expectMissingToo(path);
    });

    test('locateSync gives null under a symlinked hash folder', () async {
      final hash = _t144Hash('e');
      final path = _t144Path(hash, 'x.pdf');
      final outside = Directory(p.join(root.path, 'elsewhere'))..createSync();
      File(p.join(outside.path, 'x.pdf')).writeAsBytesSync([9]);
      Directory(p.join(vaultPath, 'objects', 'cd')).createSync(recursive: true);
      Link(p.join(vaultPath, 'objects', 'cd', hash)).createSync(outside.path);

      expect(access.locateSync(path), isNull);
      await expectMissingToo(path);
    });

    test('locateSync gives null under a symlinked h2 folder', () async {
      final hash = _t144Hash('f');
      final path = _t144Path(hash, 'x.pdf');
      final outside = Directory(p.join(root.path, 'elsewhere'))..createSync();
      File(p.join(outside.path, hash, 'x.pdf'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([9]);
      Directory(p.join(vaultPath, 'objects')).createSync();
      Link(p.join(vaultPath, 'objects', 'cd')).createSync(outside.path);

      expect(access.locateSync(path), isNull);
      await expectMissingToo(path);
    });

    test('locateSync gives null when objects is a symlink', () async {
      final hash = _t144Hash('0');
      final path = _t144Path(hash, 'x.pdf');
      final real = Directory(p.join(root.path, 'real objects'))..createSync();
      File(p.join(real.path, 'cd', hash, 'x.pdf'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([9]);
      Link(p.join(vaultPath, 'objects')).createSync(real.path);

      expect(access.locateSync(path), isNull);
      await expectMissingToo(path);
    });
  });
}
