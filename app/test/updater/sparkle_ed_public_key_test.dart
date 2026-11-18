// WI #36 (Spec #31 req 21, D9 as adjusted by D9a): the committed release
// public key. `flutter test` passes no --dart-define, so sparkleEdPublicKey
// is the committed value here.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/sparkle_ed_public_key.dart';

void main() {
  test(
    'the committed sparkleEdPublicKey decodes from base64 to exactly 32 bytes',
    () {
      expect(
        sparkleEdPublicKey,
        isNotEmpty,
        reason: 'an empty key refuses every install',
      );
      final bytes = base64.decode(sparkleEdPublicKey);
      expect(bytes, hasLength(32), reason: 'an Ed25519 public key');
      expect(
        base64.encode(bytes),
        sparkleEdPublicKey,
        reason: 'canonical padded base64, as generate_keys prints it',
      );
      expect(
        bytes.any((b) => b != 0),
        isTrue,
        reason: 'a real key, not a zero placeholder',
      );
    },
  );
}
