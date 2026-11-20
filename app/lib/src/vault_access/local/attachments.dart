import 'dart:io';
import 'dart:typed_data';

import '../../memex_cli.dart';
import '../../state/file_revealer.dart';
import '../../state/url_opener.dart';
import '../attachments_access.dart';

/// How the domain reads a file's metadata (size, mode): `FileStat.stat` by
/// default. Tests inject a counting seam (D13).
typedef AttachmentFileStat = Future<FileStat> Function(String path);

const _unsupportedAdd = AttachmentAddFailed(
  AttachmentAddFailureReason.unsupported,
  'Attachments are not available in this vault yet.',
);
const _unsupportedAction = AttachmentActionFailed(
  AttachmentLookupFailure.unsupported,
);

/// [AttachmentsAccess] for a local vault at [vaultPath]. Until W3 (#140)
/// every call answers the `unsupported` outcome and touches nothing.
///
/// W3 seams (all optional, production defaults): [cli] runs `memex attach`;
/// `urlOpener` and `fileRevealer` open and reveal; `stat` reads file
/// metadata.
class LocalAttachmentsAccess implements AttachmentsAccess {
  LocalAttachmentsAccess({
    required this.vaultPath,
    this.cli,
    UrlOpener? urlOpener,
    FileRevealer? fileRevealer,
    AttachmentFileStat? stat,
  });

  final String vaultPath;

  /// The `memex` CLI that stores files; null when none is configured.
  final MemexCli? cli;

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
