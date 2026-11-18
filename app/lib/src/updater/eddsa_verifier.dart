import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_ports.dart';
import 'update_seams.dart';
import 'update_state.dart';

/// The byte length of a raw Ed25519 public key.
const _publicKeyLength = 32;

/// The byte length of an Ed25519 signature.
const _signatureLength = 64;

/// The production [EdDsaVerifier]: checks a base64 Ed25519 signature over
/// the downloaded file's bytes against [publicKey] (base64 of the 32-byte raw
/// key) in `Isolate.run` (req 19).
///
/// The message is the whole file, as Sparkle's `sign_update` signs it. The
/// checks run in this order, and the first refusal wins: no usable public
/// key ([UpdateErrorCause.noPublicKey]), no signature
/// ([UpdateErrorCause.noSignature]), a signature that is not base64 of 64
/// bytes or does not verify ([UpdateErrorCause.badSignature]). A file that
/// can't be read, or a check whose isolate fails, fails with
/// [UpdateErrorCause.downloadFailed] (the bytes were never checked). Every refusal
/// deletes the file first (req 20); a pass leaves it unchanged.
class IsolateEdDsaVerifier implements EdDsaVerifier {
  IsolateEdDsaVerifier({required this.publicKey});

  /// Base64 of the 32-byte raw Ed25519 public key; empty means no key.
  final String publicKey;

  @override
  Future<void> verify({
    required String dmgPath,
    required String edSignature,
  }) async {
    final cause = await _refusal(dmgPath, edSignature);
    if (cause == null) return;
    await _deleteQuietly(dmgPath);
    throw UpdateFailure(cause);
  }

  /// Why [edSignature] over the file at [dmgPath] is refused; null when it
  /// verifies.
  Future<UpdateErrorCause?> _refusal(String dmgPath, String edSignature) async {
    final key = _decode(publicKey, _publicKeyLength);
    if (key == null) return UpdateErrorCause.noPublicKey;
    if (edSignature.trim().isEmpty) return UpdateErrorCause.noSignature;
    final signature = _decode(edSignature, _signatureLength);
    if (signature == null) return UpdateErrorCause.badSignature;
    try {
      return await Isolate.run(() => _verifyFile(dmgPath, key, signature));
    } on Object {
      // The check never ran to the end, so the bytes were never checked.
      return UpdateErrorCause.downloadFailed;
    }
  }
}

/// [text] trimmed and decoded from base64 when it decodes to exactly
/// [length] bytes; null otherwise (empty, not base64, another length).
List<int>? _decode(String text, int length) {
  final List<int> bytes;
  try {
    bytes = base64.decode(text.trim());
  } on FormatException {
    return null;
  }
  if (bytes.length != length) return null;
  return bytes;
}

/// Runs in the background isolate: reads the file at [path] and checks
/// [signature] over its bytes against [publicKey]. Returns null when it
/// verifies, otherwise the refusal's cause.
Future<UpdateErrorCause?> _verifyFile(
  String path,
  List<int> publicKey,
  List<int> signature,
) async {
  final List<int> message;
  try {
    message = await File(path).readAsBytes();
  } on FileSystemException {
    return UpdateErrorCause.downloadFailed;
  }
  final bool valid;
  try {
    valid = await Ed25519().verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  } on Object {
    // A key or signature the algorithm can't decode never verifies.
    return UpdateErrorCause.badSignature;
  }
  return valid ? null : UpdateErrorCause.badSignature;
}

/// Deletes the file at [path], ignoring a missing file or an IO error.
Future<void> _deleteQuietly(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // The refusal still stands; the next launch deletes the directory.
  }
}

/// The production [EdDsaVerifier] behind `edDsaVerifierProvider`.
EdDsaVerifier defaultEdDsaVerifier(Ref ref) =>
    IsolateEdDsaVerifier(publicKey: ref.watch(sparkleEdPublicKeyProvider));
