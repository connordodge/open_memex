import 'dart:typed_data';

import '../attachments_access.dart';

const _unsupportedAdd = AttachmentAddFailed(
  AttachmentAddFailureReason.unsupported,
  'Attachments are not available in this vault yet.',
);
const _unsupportedAction = AttachmentActionFailed(
  AttachmentLookupFailure.unsupported,
);

/// [AttachmentsAccess] for a local vault at [vaultPath]. Until W3 (#140)
/// every call answers the `unsupported` outcome and touches nothing.
class LocalAttachmentsAccess implements AttachmentsAccess {
  LocalAttachmentsAccess({required this.vaultPath});

  final String vaultPath;

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
