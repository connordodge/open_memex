import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_ports.dart';
import 'update_seams.dart';

// Skeleton (test author, #33). A1 #33 fills this file and keeps
// `defaultEdDsaVerifier`.

/// The production [EdDsaVerifier]: checks a base64 Ed25519 signature over
/// the downloaded file's bytes against [publicKey] (base64 of the 32-byte raw
/// key) in `Isolate.run` (req 19).
class IsolateEdDsaVerifier implements EdDsaVerifier {
  IsolateEdDsaVerifier({required this.publicKey});

  /// Base64 of the 32-byte raw Ed25519 public key; empty means no key.
  final String publicKey;

  @override
  Future<void> verify({required String dmgPath, required String edSignature}) =>
      Future.value();
}

/// The production [EdDsaVerifier] behind `edDsaVerifierProvider`.
EdDsaVerifier defaultEdDsaVerifier(Ref ref) =>
    IsolateEdDsaVerifier(publicKey: ref.watch(sparkleEdPublicKeyProvider));
