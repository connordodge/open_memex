import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../cli/attach_cli.dart';
import '../../editor/attachment_ref.dart';
import '../../memex_cli.dart';
import '../../state/file_revealer.dart';
import '../../state/url_opener.dart';
import '../attachments_access.dart';
import '../errors.dart';
import 'hosted_client.dart';

/// The bound of the in-memory LRU of downloaded attachment bytes (Spec #123
/// TD "Image decoding"): 256 MB.
const int hostedAttachmentCacheMaxBytes = 256 * 1024 * 1024;

/// R42's add-failure reason for a vault server that can't be reached.
const hostedUnreachableAddMessage = "the vault server can't be reached";

/// R42's failure for a vault server without the attachment routes.
const serverTooOldForAttachmentsMessage =
    "This vault's server is too old for attachments; update memex on the "
    'server.';

/// The largest body an older server takes on any route (its 8 MiB limit):
/// an upload over it checks the server first (R42).
const _olderServerBodyLimit = 8 * 1024 * 1024;

/// The largest attachment (R15): a local file over it is refused before it
/// is read.
const _maxAttachmentBytes = 100 * 1024 * 1024;

/// An older server's answer to a route it does not have (D19).
const _noRouteMessage = 'not found: no route for this path';

/// An R4 path that names no stored file: the route check's GET answers the
/// missing 404 on a server with the routes and the no-route 404 without.
const _routeCheckPath =
    '/attachments/objects/00/'
    '0000000000000000000000000000000000000000000000000000000000000000/check';

const _upload = 'attach';
const _download = 'read attachment';

const _missing = AttachmentLookupFailure.missing;
const _offline = AttachmentLookupFailure.offline;
const _serverTooOld = AttachmentLookupFailure.serverTooOld;

const _unreachableAdd = AttachmentAddFailed(
  AttachmentAddFailureReason.unreachable,
  hostedUnreachableAddMessage,
);
const _serverTooOldAdd = AttachmentAddFailed(
  AttachmentAddFailureReason.serverTooOld,
  serverTooOldForAttachmentsMessage,
);

/// Any of the owner, group and other execute bits (0o111).
const _anyExecuteBit = 0x49;

/// [AttachmentsAccess] for a hosted vault (Spec #123 W3, R41, R42, D19) over
/// [client]'s attachment routes:
///
/// - `add`/`addBytes`: `POST /attachments?name=<name>` with the raw body,
///   waiting 60 s + 1 s per MB. Before an upload over 8 MiB the server is
///   checked once per server session, so an older server's 8 MiB 413 never
///   reads as a size error.
/// - `read`: `GET /attachments/<path>`; image bytes go in an LRU bounded at
///   [maxCachedBytes]. `info`: `HEAD`, cached per path.
/// - D13: the app's own add puts `{size, type}` in the info cache and image
///   bytes in the LRU, so `info` and `read` of the new path send nothing.
/// - `open` downloads to a per-server, per-vault cache folder and opens the
///   copy, or reveals it when its name is in R33's executable table or the
///   copy has an execute bit (D10). `reveal` is unsupported except for
///   executable names, which download and reveal the copy.
///
/// Outcomes: an unreachable server is offline; the exact no-route 404 is
/// server too old; `not found: attachment …` (or any other 404 or 400) is
/// missing.
///
/// Seams (all optional, production defaults): `urlOpener`
/// ([SystemUrlOpener]) and `fileRevealer` ([SystemFileRevealer]) open and
/// reveal the downloaded copy; `openCacheRoot` is the folder under which
/// each server and vault gets its own open cache folder (null: the app's
/// cache directory); `maxCachedBytes` bounds the LRU of downloaded bytes.
class HostedAttachmentsAccess implements AttachmentsAccess {
  HostedAttachmentsAccess({
    required this.client,
    required this.vaultName,
    UrlOpener? urlOpener,
    FileRevealer? fileRevealer,
    String? openCacheRoot,
    int maxCachedBytes = hostedAttachmentCacheMaxBytes,
  }) : _opener = urlOpener ?? SystemUrlOpener(),
       _revealer = fileRevealer ?? SystemFileRevealer(),
       _openCacheRoot = openCacheRoot,
       _lru = _ByteLru(maxCachedBytes);

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  final UrlOpener _opener;
  final FileRevealer _revealer;
  final String? _openCacheRoot;
  final _ByteLru _lru;

  /// Size and type per path: HEAD answers, downloads and the app's own adds.
  /// A stored attachment's path names its content, so an entry never goes
  /// stale.
  final Map<String, AttachmentInfo> _info = {};

  @override
  Future<AttachmentAddResult> add(String filePath, String? name) async {
    final stored = name ?? p.basename(filePath);
    final FileStat stat;
    try {
      stat = await FileStat.stat(filePath);
    } on FileSystemException catch (e) {
      return AttachmentAddFailed(AttachmentAddFailureReason.other, e.message);
    }
    switch (stat.type) {
      case FileSystemEntityType.directory:
        return const AttachmentAddFailed(
          AttachmentAddFailureReason.folder,
          "Folders can't be attached.",
        );
      case FileSystemEntityType.notFound:
        return AttachmentAddFailed(
          AttachmentAddFailureReason.other,
          "$stored can't be read.",
        );
      case FileSystemEntityType.file:
        break;
      default:
        return AttachmentAddFailed(
          AttachmentAddFailureReason.other,
          "$stored isn't a regular file and wasn't attached.",
        );
    }
    if (stat.size > _maxAttachmentBytes) {
      return AttachmentAddFailed(
        AttachmentAddFailureReason.tooLarge,
        "$stored is larger than 100 MB and wasn't attached.",
      );
    }
    final Uint8List bytes;
    try {
      bytes = await File(filePath).readAsBytes();
    } on FileSystemException catch (e) {
      return AttachmentAddFailed(AttachmentAddFailureReason.other, e.message);
    }
    return addBytes(bytes, stored);
  }

  @override
  Future<AttachmentAddResult> addBytes(Uint8List bytes, String name) async {
    try {
      if (bytes.length > _olderServerBodyLimit && !await _hasRoutes()) {
        return _serverTooOldAdd;
      }
      final answer = await client.uploadBytes(
        vaultName,
        '/attachments',
        bytes,
        operation: _upload,
        query: {'name': name},
      );
      _routesPresent(true);
      final added = _parseAdded(answer.bytes);
      if (added == null) {
        return const AttachmentAddFailed(
          AttachmentAddFailureReason.other,
          'The vault server sent an answer the app cannot read.',
        );
      }
      _info[added.path] = AttachmentInfo(size: added.size, type: added.type);
      if (isInlineImageName(added.name)) _lru.put(added.path, bytes);
      return AttachmentAdded(added);
    } on VaultUnreachableException {
      return _unreachableAdd;
    } on MemexException catch (e) {
      if (_isNoRoute(e, _upload)) {
        _routesPresent(false);
        return _serverTooOldAdd;
      }
      final message = c1MessageOf(e, _upload);
      if (e.code == 'payload_too_large') {
        return AttachmentAddFailed(
          AttachmentAddFailureReason.tooLarge,
          message,
        );
      }
      return AttachmentAddFailed(attachRefusalReason(message), message);
    }
  }

  @override
  Future<AttachmentReadResult> read(String path) => _fetch(path);

  @override
  Future<AttachmentInfoResult> info(String path) async {
    final target = parseAttachmentPath(path);
    if (target == null) return const AttachmentInfoFailed(_missing);
    final cached = _info[path];
    if (cached != null) return AttachmentInfoFound(cached);
    try {
      final answer = await client.head(
        vaultName,
        _routePath(target),
        operation: _download,
      );
      _routesPresent(true);
      final info = AttachmentInfo(
        size: answer.contentLength ?? 0,
        type: _typeOf(answer),
      );
      _info[path] = info;
      return AttachmentInfoFound(info);
    } on VaultUnreachableException {
      return const AttachmentInfoFailed(_offline);
    } on HostedStatusException catch (e) {
      // A HEAD answer has no body, so a 404 can't say which one it is: the
      // session's route check tells.
      if (e.statusCode != HttpStatus.notFound) {
        return const AttachmentInfoFailed(_missing);
      }
      try {
        return AttachmentInfoFailed(
          await _hasRoutes() ? _missing : _serverTooOld,
        );
      } on VaultUnreachableException {
        return const AttachmentInfoFailed(_offline);
      }
    } on MemexException catch (e) {
      return AttachmentInfoFailed(_lookupFailure(e, _download));
    }
  }

  @override
  Future<AttachmentActionResult> open(String path) => _openCopy(path);

  @override
  Future<AttachmentActionResult> reveal(String path) async {
    final target = parseAttachmentPath(path);
    if (target == null) return const AttachmentActionFailed(_missing);
    if (!isExecutableName(target.name)) {
      return const AttachmentActionFailed(AttachmentLookupFailure.unsupported);
    }
    return _openCopy(path);
  }

  /// Downloads [path] to its open cache copy, then reveals the copy when it
  /// is an executable (by name or by the copy's mode), else opens it.
  Future<AttachmentActionResult> _openCopy(String path) async {
    final target = parseAttachmentPath(path);
    if (target == null) return const AttachmentActionFailed(_missing);
    final fetched = await _fetch(path);
    final Uint8List bytes;
    switch (fetched) {
      case AttachmentReadFailed(:final failure):
        return AttachmentActionFailed(failure);
      case AttachmentBytes(bytes: final b):
        bytes = b;
    }
    final copy = await _writeCopy(target, bytes);
    final mode = (await FileStat.stat(copy)).mode;
    if (isExecutableName(target.name) || mode & _anyExecuteBit != 0) {
      await _revealer.reveal(copy);
    } else {
      await _opener.open(copy);
    }
    return const AttachmentActionDone();
  }

  /// Writes [bytes] to the open cache copy of [target] and returns its
  /// absolute path: `<root>/server-<id>/vault-<name>/<hash>/<name>`. An
  /// existing copy is rewritten in place, so it keeps its mode; a new one is
  /// written beside and renamed, so no half-written copy is ever opened.
  Future<String> _writeCopy(AttachmentPath target, Uint8List bytes) async {
    final root = _openCacheRoot ?? await _defaultOpenCacheRoot();
    final folder = p.join(
      root,
      'server-${Uri.encodeComponent(client.serverId)}',
      'vault-${Uri.encodeComponent(vaultName)}',
      target.hash,
    );
    final copy = File(p.join(folder, target.name));
    if (await copy.exists()) {
      await copy.writeAsBytes(bytes, flush: true);
      return copy.path;
    }
    await Directory(folder).create(recursive: true);
    final part = File('${copy.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(copy.path);
    return copy.path;
  }

  static Future<String> _defaultOpenCacheRoot() async =>
      p.join((await getApplicationCacheDirectory()).path, 'attachments');

  /// The bytes of [path]: from the LRU, else a GET (an image's bytes then go
  /// in the LRU).
  Future<AttachmentReadResult> _fetch(String path) async {
    final target = parseAttachmentPath(path);
    if (target == null) return const AttachmentReadFailed(_missing);
    final cached = _lru.get(path);
    if (cached != null) return AttachmentBytes(cached);
    try {
      final answer = await client.downloadBytes(
        vaultName,
        _routePath(target),
        operation: _download,
        expectedBytes: _info[path]?.size,
      );
      _routesPresent(true);
      final bytes = answer.bytes;
      _info[path] = AttachmentInfo(size: bytes.length, type: _typeOf(answer));
      if (isInlineImageName(target.name)) _lru.put(path, bytes);
      return AttachmentBytes(bytes);
    } on VaultUnreachableException {
      return const AttachmentReadFailed(_offline);
    } on MemexException catch (e) {
      return AttachmentReadFailed(_lookupFailure(e, _download));
    }
  }

  /// A lookup's failure for an error answer: the no-route 404 is server too
  /// old (and recorded for the session); anything else is missing.
  AttachmentLookupFailure _lookupFailure(MemexException e, String operation) {
    if (_isNoRoute(e, operation)) {
      _routesPresent(false);
      return _serverTooOld;
    }
    if (e.code == 'not_found') _routesPresent(true);
    return _missing;
  }

  /// Whether the server has the attachment routes: known for the session
  /// (the client's [HostedClient.attachmentRoutesCheck]), else one GET of a
  /// path that names no file. Throws `VaultUnreachableException` when the
  /// server can't be reached; the next call checks again.
  Future<bool> _hasRoutes() async {
    final known = client.attachmentRoutesCheck;
    if (known != null) return known;
    final check = _checkRoutes();
    client.attachmentRoutesCheck = check;
    try {
      return await check;
    } on Object {
      if (identical(client.attachmentRoutesCheck, check)) {
        client.attachmentRoutesCheck = null;
      }
      rethrow;
    }
  }

  Future<bool> _checkRoutes() async {
    try {
      await client.downloadBytes(
        vaultName,
        _routeCheckPath,
        operation: _download,
        expectedBytes: 0,
      );
    } on MemexException catch (e) {
      return !_isNoRoute(e, _download);
    }
    return true;
  }

  /// Records what an attachment route's answer showed for the session.
  void _routesPresent(bool present) =>
      client.attachmentRoutesCheck = Future.value(present);

  static bool _isNoRoute(MemexException e, String operation) =>
      e.code == 'not_found' &&
      e.message == '$operation failed: $_noRouteMessage';

  /// `/attachments/<path>`, each segment percent-encoded.
  static String _routePath(AttachmentPath target) =>
      '/attachments/${target.path.split('/').map(Uri.encodeComponent).join('/')}';

  static String _typeOf(HostedBytes answer) {
    final header = answer.contentType;
    if (header == null || header.isEmpty) return 'application/octet-stream';
    return header.split(';').first.trim();
  }

  static AddedAttachment? _parseAdded(Uint8List body) {
    try {
      return addedAttachmentFromJson(jsonDecode(utf8.decode(body)));
    } on FormatException {
      return null;
    }
  }
}

/// Byte arrays by key, least recently used first, holding at most
/// [maxBytes] in all (the bound is inclusive). An entry larger than the
/// bound is never held.
class _ByteLru {
  _ByteLru(this.maxBytes);

  final int maxBytes;
  final _entries = <String, Uint8List>{};
  int _total = 0;

  Uint8List? get(String key) {
    final bytes = _entries.remove(key);
    if (bytes != null) _entries[key] = bytes;
    return bytes;
  }

  void put(String key, Uint8List bytes) {
    final old = _entries.remove(key);
    if (old != null) _total -= old.length;
    if (bytes.length > maxBytes) return;
    _entries[key] = bytes;
    _total += bytes.length;
    while (_total > maxBytes) {
      final oldest = _entries.keys.first;
      _total -= _entries.remove(oldest)!.length;
    }
  }
}
