import 'dart:typed_data';

import '../attachments_access.dart';
import 'hosted_client.dart';

const _unsupportedAdd = AttachmentAddFailed(
  AttachmentAddFailureReason.unsupported,
  'Attachments are not available in this vault yet.',
);
const _unsupportedAction = AttachmentActionFailed(
  AttachmentLookupFailure.unsupported,
);

/// [AttachmentsAccess] for a hosted vault. Until W3 (#140) every call
/// answers the `unsupported` outcome and sends no request.
class HostedAttachmentsAccess implements AttachmentsAccess {
  HostedAttachmentsAccess({required this.client, required this.vaultName});

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
