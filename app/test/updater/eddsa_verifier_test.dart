// WI #33 (Spec #31 req 19, 20, 21, D6, D9): the production EdDSA verifier.
// Every key is minted per test with Ed25519().newKeyPair() (no private key
// in the repo); the known-answer test uses the RFC 8032 section 7.1 vectors.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/eddsa_verifier.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';
import 'package:open_memex_app/src/updater/update_state.dart';
import 'package:path/path.dart' as p;

/// A freshly minted Ed25519 keypair and its base64 raw public key.
class _Wi33Key {
  _Wi33Key._(this._pair, this.publicKeyBase64);

  final SimpleKeyPair _pair;
  final String publicKeyBase64;

  static Future<_Wi33Key> mint() async {
    final pair = await Ed25519().newKeyPair();
    final public = await pair.extractPublicKey();
    return _Wi33Key._(pair, base64.encode(public.bytes));
  }

  /// The base64 detached signature over [message].
  Future<String> sign(List<int> message) async {
    final signature = await Ed25519().sign(message, keyPair: _pair);
    return base64.encode(signature.bytes);
  }
}

/// A temp directory for this test, deleted at its end.
Directory _wi33TempDir() {
  final dir = Directory.systemTemp.createTempSync('wi33_verify_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Writes [bytes] as a DMG-named file in a fresh temp dir; returns its path.
String _wi33WriteDmg(List<int> bytes) {
  final path = p.join(_wi33TempDir().path, 'Open-Memex-1.3.0-arm64.dmg');
  File(path).writeAsBytesSync(bytes, flush: true);
  return path;
}

/// The production verifier, built by `defaultEdDsaVerifier` through
/// `edDsaVerifierProvider` with [publicKey] as `sparkleEdPublicKeyProvider`.
EdDsaVerifier _wi33Verifier(String publicKey) {
  final container = ProviderContainer(
    overrides: [sparkleEdPublicKeyProvider.overrideWithValue(publicKey)],
  );
  addTearDown(container.dispose);
  return container.read(edDsaVerifierProvider);
}

Matcher _wi33FailsWith(UpdateErrorCause cause) =>
    throwsA(isA<UpdateFailure>().having((f) => f.cause, 'cause', cause));

/// Bytes that stand in for a DMG: 64 KiB plus a ragged tail, built at run
/// time.
Uint8List _wi33DmgBytes() => Uint8List.fromList([
  for (var i = 0; i < 65536 + 37; i++) (i * 31 + 7) & 0xff,
]);

List<int> _wi33Hex(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

/// RFC 8032 section 7.1, TEST 1 to TEST 3: public key, message, signature.
const _wi33Rfc8032Vectors = [
  (
    name: 'TEST 1',
    publicKey:
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
    message: '',
    signature:
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
        '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
  ),
  (
    name: 'TEST 2',
    publicKey:
        '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
    message: '72',
    signature:
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
        '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
  ),
  (
    name: 'TEST 3',
    publicKey:
        'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025',
    message: 'af82',
    signature:
        '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac'
        '18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a',
  ),
];

void main() {
  test(
    'a file signed with the public key passes verification and is kept',
    () async {
      final key = await _Wi33Key.mint();
      final other = await _Wi33Key.mint();
      final bytes = _wi33DmgBytes();
      final path = _wi33WriteDmg(bytes);
      final signature = await key.sign(bytes);

      await _wi33Verifier(
        key.publicKeyBase64,
      ).verify(dmgPath: path, edSignature: signature);

      // A pass keeps the verified file, unchanged, for the install helper.
      expect(File(path).existsSync(), isTrue);
      expect(File(path).readAsBytesSync(), bytes);

      // The same file and signature under another key do not pass: the
      // verifier checks against the injected public key.
      await expectLater(
        _wi33Verifier(
          other.publicKeyBase64,
        ).verify(dmgPath: path, edSignature: signature),
        _wi33FailsWith(UpdateErrorCause.badSignature),
      );
    },
  );

  test(
    'a file with one byte changed fails with the bad-signature cause and is deleted',
    () async {
      final key = await _Wi33Key.mint();
      final bytes = _wi33DmgBytes();
      final signature = await key.sign(bytes);
      for (final index in [0, 4096, bytes.length - 1]) {
        final tampered = Uint8List.fromList(bytes);
        tampered[index] ^= 0x01;
        final path = _wi33WriteDmg(tampered);

        await expectLater(
          _wi33Verifier(
            key.publicKeyBase64,
          ).verify(dmgPath: path, edSignature: signature),
          _wi33FailsWith(UpdateErrorCause.badSignature),
          reason: 'byte $index changed',
        );
        expect(File(path).existsSync(), isFalse, reason: 'byte $index');
      }
    },
  );

  test(
    'a signature made by another key fails with the bad-signature cause and the file is deleted',
    () async {
      final key = await _Wi33Key.mint();
      final attacker = await _Wi33Key.mint();
      final bytes = _wi33DmgBytes();
      final path = _wi33WriteDmg(bytes);

      await expectLater(
        _wi33Verifier(
          key.publicKeyBase64,
        ).verify(dmgPath: path, edSignature: await attacker.sign(bytes)),
        _wi33FailsWith(UpdateErrorCause.badSignature),
      );
      expect(File(path).existsSync(), isFalse);
    },
  );

  test(
    'an item with no signature fails with the no-signature cause and the file is deleted',
    () async {
      final key = await _Wi33Key.mint();
      final path = _wi33WriteDmg(_wi33DmgBytes());

      await expectLater(
        _wi33Verifier(
          key.publicKeyBase64,
        ).verify(dmgPath: path, edSignature: ''),
        _wi33FailsWith(UpdateErrorCause.noSignature),
      );
      expect(File(path).existsSync(), isFalse);
    },
  );

  test(
    'a signature that is not valid base64 fails with the bad-signature cause and the file is deleted',
    () async {
      final key = await _Wi33Key.mint();
      for (final signature in ['not valid base64 !!!', 'QUJD=', '%%%%']) {
        final path = _wi33WriteDmg(_wi33DmgBytes());

        await expectLater(
          _wi33Verifier(
            key.publicKeyBase64,
          ).verify(dmgPath: path, edSignature: signature),
          _wi33FailsWith(UpdateErrorCause.badSignature),
          reason: signature,
        );
        expect(File(path).existsSync(), isFalse, reason: signature);
      }
    },
  );

  test(
    'a base64 signature that is not 64 bytes fails with the bad-signature cause and the file is deleted',
    () async {
      final key = await _Wi33Key.mint();
      final bytes = _wi33DmgBytes();
      final valid = base64.decode(await key.sign(bytes));
      for (final wrong in [
        valid.sublist(0, 63),
        [...valid, 0],
        List<int>.filled(32, 7),
      ]) {
        final path = _wi33WriteDmg(bytes);

        await expectLater(
          _wi33Verifier(
            key.publicKeyBase64,
          ).verify(dmgPath: path, edSignature: base64.encode(wrong)),
          _wi33FailsWith(UpdateErrorCause.badSignature),
          reason: '${wrong.length} bytes',
        );
        expect(File(path).existsSync(), isFalse, reason: '${wrong.length}');
      }
    },
  );

  test(
    'an empty public key fails with the no-public-key cause and the file is deleted',
    () async {
      final key = await _Wi33Key.mint();
      final bytes = _wi33DmgBytes();
      final path = _wi33WriteDmg(bytes);

      await expectLater(
        _wi33Verifier(
          '',
        ).verify(dmgPath: path, edSignature: await key.sign(bytes)),
        _wi33FailsWith(UpdateErrorCause.noPublicKey),
      );
      expect(File(path).existsSync(), isFalse);
    },
  );

  test(
    'a public key that does not decode to 32 bytes fails with the no-public-key cause and the file is deleted',
    () async {
      final key = await _Wi33Key.mint();
      final bytes = _wi33DmgBytes();
      final signature = await key.sign(bytes);
      final raw = base64.decode(key.publicKeyBase64);
      final badKeys = {
        '31 bytes': base64.encode(raw.sublist(0, 31)),
        '33 bytes': base64.encode([...raw, 0]),
        '64 bytes': base64.encode([...raw, ...raw]),
        'not base64': 'not a key !!!',
      };
      for (final entry in badKeys.entries) {
        final path = _wi33WriteDmg(bytes);

        await expectLater(
          _wi33Verifier(
            entry.value,
          ).verify(dmgPath: path, edSignature: signature),
          _wi33FailsWith(UpdateErrorCause.noPublicKey),
          reason: entry.key,
        );
        expect(File(path).existsSync(), isFalse, reason: entry.key);
      }
    },
  );

  test(
    'the production verifier accepts the RFC 8032 section 7.1 test vectors and rejects them with a flipped byte',
    () async {
      for (final v in _wi33Rfc8032Vectors) {
        final publicKey = base64.encode(_wi33Hex(v.publicKey));
        final message = _wi33Hex(v.message);
        final signature = _wi33Hex(v.signature);

        final path = _wi33WriteDmg(message);
        await _wi33Verifier(
          publicKey,
        ).verify(dmgPath: path, edSignature: base64.encode(signature));
        expect(File(path).existsSync(), isTrue, reason: '${v.name} accepted');

        // A flipped signature byte (TEST 1 signs the empty message).
        final badSignature = [...signature]..[5] ^= 0x01;
        final sigPath = _wi33WriteDmg(message);
        await expectLater(
          _wi33Verifier(
            publicKey,
          ).verify(dmgPath: sigPath, edSignature: base64.encode(badSignature)),
          _wi33FailsWith(UpdateErrorCause.badSignature),
          reason: '${v.name} with a flipped signature byte',
        );
        expect(File(sigPath).existsSync(), isFalse, reason: v.name);

        // A flipped message byte.
        if (message.isNotEmpty) {
          final badMessage = [...message]..[0] ^= 0x01;
          final msgPath = _wi33WriteDmg(badMessage);
          await expectLater(
            _wi33Verifier(
              publicKey,
            ).verify(dmgPath: msgPath, edSignature: base64.encode(signature)),
            _wi33FailsWith(UpdateErrorCause.badSignature),
            reason: '${v.name} with a flipped message byte',
          );
          expect(File(msgPath).existsSync(), isFalse, reason: v.name);
        }

        // A flipped public key byte.
        final badKey = [..._wi33Hex(v.publicKey)]..[3] ^= 0x01;
        final keyPath = _wi33WriteDmg(message);
        await expectLater(
          _wi33Verifier(
            base64.encode(badKey),
          ).verify(dmgPath: keyPath, edSignature: base64.encode(signature)),
          throwsA(isA<UpdateFailure>()),
          reason: '${v.name} under a flipped key byte',
        );
        expect(File(keyPath).existsSync(), isFalse, reason: v.name);
      }
    },
  );

  test(
    'the production verifier checks the signature in Isolate.run and no other updater file does',
    () async {
      final source = File(
        'lib/src/updater/eddsa_verifier.dart',
      ).readAsStringSync();
      expect(source, contains('Isolate.run('));

      final others = Directory('lib/src/updater')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => p.basename(f.path) != 'eddsa_verifier.dart')
          .where((f) => f.readAsStringSync().contains('Isolate.run('))
          .map((f) => p.basename(f.path))
          .toList();
      expect(others, isEmpty);

      // And it really is the one behind edDsaVerifierProvider.
      expect(_wi33Verifier('k'), isA<IsolateEdDsaVerifier>());
    },
  );

  test(
    'verifying a file that does not exist fails with an UpdateFailure',
    () async {
      final key = await _Wi33Key.mint();
      final path = p.join(_wi33TempDir().path, 'missing.dmg');

      await expectLater(
        _wi33Verifier(
          key.publicKeyBase64,
        ).verify(dmgPath: path, edSignature: await key.sign(const [1, 2, 3])),
        throwsA(isA<UpdateFailure>()),
      );
    },
  );

  test(
    'a file that does not exist fails with the download-failed cause',
    () async {
      final key = await _Wi33Key.mint();
      final path = p.join(_wi33TempDir().path, 'missing.dmg');

      await expectLater(
        _wi33Verifier(
          key.publicKeyBase64,
        ).verify(dmgPath: path, edSignature: await key.sign(const [1, 2, 3])),
        _wi33FailsWith(UpdateErrorCause.downloadFailed),
      );
    },
  );

  test(
    'a file that cannot be read fails with the download-failed cause and is deleted',
    () async {
      final key = await _Wi33Key.mint();
      final bytes = _wi33DmgBytes();
      final path = _wi33WriteDmg(bytes);
      final signature = await key.sign(bytes);
      expect(Process.runSync('chmod', ['000', path]).exitCode, 0);
      addTearDown(() => Process.runSync('chmod', ['644', path]));
      // Root reads any file; the refusal below needs a real read error.
      var readable = true;
      try {
        File(path).readAsBytesSync();
      } on FileSystemException {
        readable = false;
      }
      if (readable) {
        markTestSkipped('the test runs as a user that can read mode 000');
        return;
      }

      await expectLater(
        _wi33Verifier(
          key.publicKeyBase64,
        ).verify(dmgPath: path, edSignature: signature),
        _wi33FailsWith(UpdateErrorCause.downloadFailed),
      );
      expect(File(path).existsSync(), isFalse);
    },
  );

  test(
    'the public key is checked before the signature and the signature before the file',
    () async {
      final key = await _Wi33Key.mint();
      final bytes = _wi33DmgBytes();
      final signature = await key.sign(bytes);
      final cases = [
        // (public key, signature, expected cause)
        ('', '', UpdateErrorCause.noPublicKey),
        ('', 'not valid base64 !!!', UpdateErrorCause.noPublicKey),
        ('   ', signature, UpdateErrorCause.noPublicKey),
        ('not a key !!!', '', UpdateErrorCause.noPublicKey),
        (key.publicKeyBase64, '', UpdateErrorCause.noSignature),
        (key.publicKeyBase64, '  \n\t ', UpdateErrorCause.noSignature),
      ];
      for (final (publicKey, edSignature, cause) in cases) {
        final path = _wi33WriteDmg(bytes);

        await expectLater(
          _wi33Verifier(
            publicKey,
          ).verify(dmgPath: path, edSignature: edSignature),
          _wi33FailsWith(cause),
          reason: 'key "$publicKey" signature "$edSignature"',
        );
        expect(File(path).existsSync(), isFalse);
      }
    },
  );

  test(
    'a public key and a signature padded with whitespace are trimmed before they are decoded',
    () async {
      final key = await _Wi33Key.mint();
      final bytes = _wi33DmgBytes();
      final path = _wi33WriteDmg(bytes);
      final signature = await key.sign(bytes);

      await _wi33Verifier(
        '  ${key.publicKeyBase64}\n',
      ).verify(dmgPath: path, edSignature: '\t$signature \n');

      expect(File(path).readAsBytesSync(), bytes);

      // Trimming does not make a wrong signature pass.
      final other = await _Wi33Key.mint();
      await expectLater(
        _wi33Verifier(
          ' ${key.publicKeyBase64} ',
        ).verify(dmgPath: path, edSignature: ' ${await other.sign(bytes)}\n'),
        _wi33FailsWith(UpdateErrorCause.badSignature),
      );
      expect(File(path).existsSync(), isFalse);
    },
  );

  test(
    'a 32-byte key and a 64-byte signature that are not valid Ed25519 values fail with the bad-signature cause and the file is deleted',
    () async {
      final bytes = _wi33DmgBytes();
      final cases = {
        'all 0xff': (List<int>.filled(32, 0xff), List<int>.filled(64, 0xff)),
        'all zero': (List<int>.filled(32, 0), List<int>.filled(64, 0)),
      };
      for (final entry in cases.entries) {
        final (publicKey, signature) = entry.value;
        final path = _wi33WriteDmg(bytes);

        await expectLater(
          _wi33Verifier(
            base64.encode(publicKey),
          ).verify(dmgPath: path, edSignature: base64.encode(signature)),
          _wi33FailsWith(UpdateErrorCause.badSignature),
          reason: entry.key,
        );
        expect(File(path).existsSync(), isFalse, reason: entry.key);
      }
    },
  );
}
