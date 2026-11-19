import 'dart:typed_data';

import '../attachments_access.dart';

/// [AttachmentsAccess] for a local vault at [vaultPath]. Until W3 (#140)
/// every call answers the `unsupported` outcome and touches nothing.
class LocalAttachmentsAccess implements AttachmentsAccess {
  LocalAttachmentsAccess({required this.vaultPath});

  final String vaultPath;

  @override
  Future<AttachmentAddResult> add(String filePath, String? name) async =>
      const AttachmentAddFailed(AttachmentAddFailureReason.other, '');

  @override
  Future<AttachmentAddResult> addBytes(Uint8List bytes, String name) async =>
      const AttachmentAddFailed(AttachmentAddFailureReason.other, '');

  @override
  Future<AttachmentReadResult> read(String path) async =>
      const AttachmentReadFailed(AttachmentLookupFailure.missing);

  @override
  Future<AttachmentInfoResult> info(String path) async =>
      const AttachmentInfoFailed(AttachmentLookupFailure.missing);

  @override
  Future<AttachmentActionResult> open(String path) async =>
      const AttachmentActionFailed(AttachmentLookupFailure.missing);

  @override
  Future<AttachmentActionResult> reveal(String path) async =>
      const AttachmentActionFailed(AttachmentLookupFailure.missing);
}
