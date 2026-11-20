import 'dart:typed_data';

import '../../state/file_revealer.dart';
import '../../state/url_opener.dart';
import '../attachments_access.dart';
import 'hosted_client.dart';

/// The bound of the in-memory LRU of downloaded attachment bytes (Spec #123
/// TD "Image decoding"): 256 MB. Skeleton: W3 (#140) sets the value.
const int hostedAttachmentCacheMaxBytes = 0;

const _unsupportedAdd = AttachmentAddFailed(
  AttachmentAddFailureReason.unsupported,
  'Attachments are not available in this vault yet.',
);
const _unsupportedAction = AttachmentActionFailed(
  AttachmentLookupFailure.unsupported,
);

/// [AttachmentsAccess] for a hosted vault. Until W3 (#140) every call
/// answers the `unsupported` outcome and sends no request.
///
/// W3 seams (all optional, production defaults): `urlOpener` and
/// `fileRevealer` open and reveal the downloaded copy; `openCacheRoot` is the
/// folder under which each server and vault gets its own open cache folder
/// (null: the app's cache directory); `maxCachedBytes` bounds the LRU of
/// downloaded bytes.
class HostedAttachmentsAccess implements AttachmentsAccess {
  HostedAttachmentsAccess({
    required this.client,
    required this.vaultName,
    UrlOpener? urlOpener,
    FileRevealer? fileRevealer,
    String? openCacheRoot,
    int maxCachedBytes = hostedAttachmentCacheMaxBytes,
  });

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  @override
  Future<AttachmentAddResult> add(String filePath, String? name) async =>
      _unsupportedAdd;

  @override
  Future<AttachmentAddResult> addBytes(Uint8List bytes, String name) async =>
      _unsupportedAdd;

  @override
  Future<AttachmentReadResult> read(String path) async =>
      const AttachmentReadFailed(AttachmentLookupFailure.unsupported);

  @override
  Future<AttachmentInfoResult> info(String path) async =>
      const AttachmentInfoFailed(AttachmentLookupFailure.unsupported);

  @override
  Future<AttachmentActionResult> open(String path) async => _unsupportedAction;

  @override
  Future<AttachmentActionResult> reveal(String path) async =>
      _unsupportedAction;
}
