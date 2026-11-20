import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../cli/attach_cli.dart';
import '../../editor/attachment_ref.dart';
import '../../memex_cli.dart';
import '../../state/file_revealer.dart';
import '../../state/url_opener.dart';
import '../attachments_access.dart';

/// How the domain reads a file's metadata (size, mode): `FileStat.stat` by
/// default. Tests inject a counting seam (D13).
typedef AttachmentFileStat = Future<FileStat> Function(String path);

/// Any of the owner, group and other execute bits (0o111).
const _anyExecuteBit = 0x49;

const _noCli = AttachmentAddFailed(
  AttachmentAddFailureReason.unsupported,
  'Attachments are not available in this vault yet.',
);

const _missing = AttachmentLookupFailure.missing;

/// [AttachmentsAccess] for a local vault at [vaultPath] (Spec #123 W3).
///
/// - `add` and `addBytes` store through `memex attach` ([cli]); bytes go
///   through a temporary file outside the vault, deleted afterwards whatever
///   the outcome (R16).
/// - `read`, `info`, `open` and `reveal` take only an R4 attachment path
///   (`objects/<h2>/<hash>/<name>`) and reach `<vault>/objects/…` directly,
///   never through a symlink: any other path is the missing result.
/// - `open` reveals instead of opening a file whose name is in R33's
///   executable table or that has an execute permission bit (D10).
/// - D13: the app's own add puts the stored size and type in the info
///   cache, so `info` of that path makes no stat.
///
/// Seams (all optional, production defaults): [cli] runs `memex attach`
/// (null: adding answers the `unsupported` failure); `urlOpener`
/// ([SystemUrlOpener]) and `fileRevealer` ([SystemFileRevealer]) open and
/// reveal; `stat` (`FileStat.stat`) reads file metadata.
class LocalAttachmentsAccess implements AttachmentsAccess {
  LocalAttachmentsAccess({
    required this.vaultPath,
    this.cli,
    UrlOpener? urlOpener,
    FileRevealer? fileRevealer,
    AttachmentFileStat? stat,
  }) : _opener = urlOpener ?? SystemUrlOpener(),
       _revealer = fileRevealer ?? SystemFileRevealer(),
       _stat = stat ?? FileStat.stat;

  final String vaultPath;

  /// The `memex` CLI that stores files; null when none is configured.
  final MemexCli? cli;

  final UrlOpener _opener;
  final FileRevealer _revealer;
  final AttachmentFileStat _stat;

  /// Size and type per vault-relative path: the app's own adds (D13) and
  /// earlier lookups. A stored attachment's path names its content, so an
  /// entry never goes stale.
  final Map<String, AttachmentInfo> _info = {};

  @override
  Future<AttachmentAddResult> add(String filePath, String? name) async {
    final cli = this.cli;
    if (cli == null) return _noCli;
    return _attach(cli, filePath, name);
  }

  @override
  Future<AttachmentAddResult> addBytes(Uint8List bytes, String name) async {
    final cli = this.cli;
    if (cli == null) return _noCli;
    Directory? temp;
    try {
      temp = await Directory.systemTemp.createTemp('memex-attach-');
      final file = File(p.join(temp.path, 'attachment'));
      await file.writeAsBytes(bytes, flush: true);
      return await _attach(cli, file.path, name);
    } on FileSystemException catch (e) {
      return AttachmentAddFailed(AttachmentAddFailureReason.other, e.message);
    } finally {
      try {
        await temp?.delete(recursive: true);
      } on FileSystemException {
        // Already gone; nothing else to clean up.
      }
    }
  }

  Future<AttachmentAddResult> _attach(
    MemexCli cli,
    String filePath,
    String? name,
  ) async {
    final AttachmentAddResult result;
    try {
      result = await cli.attach(
        vaultPath: vaultPath,
        filePath: filePath,
        name: name,
      );
    } on ProcessException catch (e) {
      return AttachmentAddFailed(AttachmentAddFailureReason.other, e.message);
    }
    if (result is AttachmentAdded) {
      final a = result.attachment;
      _info[a.path] = AttachmentInfo(size: a.size, type: a.type);
    }
    return result;
  }

  @override
  Future<AttachmentReadResult> read(String path) async {
    final file = await _locate(path);
    if (file == null) return const AttachmentReadFailed(_missing);
    try {
      return AttachmentBytes(await File(file).readAsBytes());
    } on FileSystemException {
      return const AttachmentReadFailed(_missing);
    }
  }

  @override
  Future<AttachmentInfoResult> info(String path) async {
    if (parseAttachmentPath(path) == null) {
      return const AttachmentInfoFailed(_missing);
    }
    final cached = _info[path];
    if (cached != null) return AttachmentInfoFound(cached);
    final file = await _locate(path);
    if (file == null) return const AttachmentInfoFailed(_missing);
    final stat = await _stat(file);
    if (stat.type != FileSystemEntityType.file) {
      return const AttachmentInfoFailed(_missing);
    }
    // A stat has no type; only the store's answer (D13) names one.
    final info = AttachmentInfo(
      size: stat.size,
      type: 'application/octet-stream',
    );
    _info[path] = info;
    return AttachmentInfoFound(info);
  }

  @override
  Future<AttachmentActionResult> open(String path) async {
    final file = await _locate(path);
    if (file == null) return const AttachmentActionFailed(_missing);
    final stat = await _stat(file);
    if (stat.type != FileSystemEntityType.file) {
      return const AttachmentActionFailed(_missing);
    }
    final executable =
        isExecutableName(p.basename(file)) || stat.mode & _anyExecuteBit != 0;
    if (executable) {
      await _revealer.reveal(file);
    } else {
      await _opener.open(file);
    }
    return const AttachmentActionDone();
  }

  @override
  Future<AttachmentActionResult> reveal(String path) async {
    final file = await _locate(path);
    if (file == null) return const AttachmentActionFailed(_missing);
    await _revealer.reveal(file);
    return const AttachmentActionDone();
  }

  /// The absolute path of the regular file at the R4 attachment [path] under
  /// `<vault>/objects`, reached without a symlink (as the server's
  /// download route), or null: not an attachment path, missing, a symlink on
  /// the way, or not what it should be.
  Future<String?> _locate(String path) async {
    final target = parseAttachmentPath(path);
    if (target == null) return null;
    final parts = target.path.split('/');
    var at = vaultPath;
    for (var i = 0; i < parts.length; i++) {
      at = p.join(at, parts[i]);
      final type = await FileSystemEntity.type(at, followLinks: false);
      final want = i == parts.length - 1
          ? FileSystemEntityType.file
          : FileSystemEntityType.directory;
      if (type != want) return null;
    }
    return at;
  }
}
