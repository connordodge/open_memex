// WI #141 (Spec #123 V1, D17, D21): the shared AttachmentsAccess test double.
// This file is owned by #141; later WIs add one hunk each, or put their own
// fakes in their own files.
//
// `FakeAttachmentsAccess` extends LocalAttachmentsAccess, so it goes both
// into `LocalVaultAccess(attachments: …)` and an `attachmentsProvider`
// override.
//
// - Every call is recorded first, with its arguments, in [addCalls],
//   [addBytesCalls], [readCalls], [infoCalls], [openCalls] and [revealCalls]
//   (each in call order).
// - Each op answers from its own FIFO queue ([addResults], [addBytesResults],
//   [readResults], [infoResults], [openResults], [revealResults]): the
//   oldest queued result is removed and returned.
// - When an op's queue is empty it answers the default for that op:
//   - `add`: [AttachmentAdded] of [fakeAddedAttachment] for the given name
//     (the file's base name when the name is null), size 0;
//   - `addBytes`: [AttachmentAdded] of [fakeAddedAttachment] for the given
//     name and the byte count;
//   - `read`: [AttachmentBytes] with no bytes;
//   - `info`: [AttachmentInfoFound], size 0, type `application/octet-stream`;
//   - `open` and `reveal`: [AttachmentActionDone].
// Nothing touches the filesystem or the network.
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' show addTearDown;
import 'package:open_memex_app/src/vault_access/attachments_access.dart';
import 'package:open_memex_app/src/vault_access/local/attachments.dart';

/// The hash [fakeAddedAttachment] stamps: 64 lowercase hex characters whose
/// first two are the `<h2>` folder.
const fakeAttachmentHash =
    'aa00000000000000000000000000000000000000000000000000000000000000';

/// An [AddedAttachment] as a store would return it for [name]: the path is
/// `objects/aa/<hash>/<name>`, the markdown is a plain
/// `[<name>](<that path>)` (no percent-encoding: a fake never parses it).
AddedAttachment fakeAddedAttachment(
  String name, {
  int size = 0,
  String type = 'application/octet-stream',
}) {
  final path = 'objects/aa/$fakeAttachmentHash/$name';
  return AddedAttachment(
    markdown: '[$name]($path)',
    path: path,
    name: name,
    size: size,
    type: type,
  );
}

class FakeAttachmentsAccess extends LocalAttachmentsAccess {
  FakeAttachmentsAccess({super.vaultPath = '/vaults/My Vault'});

  final List<({String filePath, String? name})> addCalls = [];
  final List<({Uint8List bytes, String name})> addBytesCalls = [];
  final List<String> readCalls = [];
  final List<String> infoCalls = [];
  final List<String> openCalls = [];
  final List<String> revealCalls = [];

  final Queue<AttachmentAddResult> addResults = Queue();
  final Queue<AttachmentAddResult> addBytesResults = Queue();
  final Queue<AttachmentReadResult> readResults = Queue();
  final Queue<AttachmentInfoResult> infoResults = Queue();
  final Queue<AttachmentActionResult> openResults = Queue();
  final Queue<AttachmentActionResult> revealResults = Queue();

  @override
  Future<AttachmentAddResult> add(String filePath, String? name) async {
    addCalls.add((filePath: filePath, name: name));
    if (addResults.isNotEmpty) return addResults.removeFirst();
    return AttachmentAdded(
      fakeAddedAttachment(name ?? filePath.split('/').last),
    );
  }

  @override
  Future<AttachmentAddResult> addBytes(Uint8List bytes, String name) async {
    addBytesCalls.add((bytes: bytes, name: name));
    if (addBytesResults.isNotEmpty) return addBytesResults.removeFirst();
    return AttachmentAdded(fakeAddedAttachment(name, size: bytes.length));
  }

  @override
  Future<AttachmentReadResult> read(String path) async {
    readCalls.add(path);
    if (readResults.isNotEmpty) return readResults.removeFirst();
    return AttachmentBytes(Uint8List(0));
  }

  @override
  Future<AttachmentInfoResult> info(String path) async {
    infoCalls.add(path);
    if (infoResults.isNotEmpty) return infoResults.removeFirst();
    return const AttachmentInfoFound(
      AttachmentInfo(size: 0, type: 'application/octet-stream'),
    );
  }

  @override
  Future<AttachmentActionResult> open(String path) async {
    openCalls.add(path);
    if (openResults.isNotEmpty) return openResults.removeFirst();
    return const AttachmentActionDone();
  }

  @override
  Future<AttachmentActionResult> reveal(String path) async {
    revealCalls.add(path);
    if (revealResults.isNotEmpty) return revealResults.removeFirst();
    return const AttachmentActionDone();
  }
}

// --------------------------------------------------------------------------
// WI #143 (Spec #123 V3) additions: a local vault whose files lie on disk,
// a hosted vault whose reads wait for the test, and tiny generated images.
// --------------------------------------------------------------------------

/// A local vault (a [FakeAttachmentsAccess], so a `LocalAttachmentsAccess`)
/// whose attachments lie on disk under a fresh temporary `vaultPath`.
///
/// [putFile] writes a file to `<vaultPath>/<path>`; `read` then answers its
/// bytes and `info` its size, by path. [putFailure] makes `read` and `info`
/// of a path answer that failure. Any other path is `missing`. A queued
/// answer (the FIFO queues) still comes first, and every call is still
/// recorded. The temporary folder is deleted when the test ends.
class FakeAttachmentVault extends FakeAttachmentsAccess {
  FakeAttachmentVault._(String path) : super(vaultPath: path);

  /// A vault in a fresh temporary folder, deleted when the test ends.
  factory FakeAttachmentVault() {
    final dir = Directory.systemTemp.createTempSync('t143-vault');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return FakeAttachmentVault._(dir.path);
  }

  /// The bytes of each file [putFile] wrote, by decoded vault path.
  final Map<String, Uint8List> files = {};

  /// The failure each path answers, by decoded vault path.
  final Map<String, AttachmentLookupFailure> failures = {};

  /// The absolute path of the vault-relative [path].
  String absolute(String path) => '$vaultPath/$path';

  /// Writes [bytes] at [path], padded with zero bytes to [padTo] bytes when
  /// given (the file on disk and the bytes `read` answers alike).
  Uint8List putFile(String path, Uint8List bytes, {int? padTo}) {
    final data = padTo == null || padTo <= bytes.length
        ? bytes
        : (Uint8List(padTo)..setRange(0, bytes.length, bytes));
    final file = File(absolute(path));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data);
    files[path] = data;
    return data;
  }

  /// `read` and `info` of [path] answer [failure].
  void putFailure(String path, AttachmentLookupFailure failure) =>
      failures[path] = failure;

  @override
  Future<AttachmentReadResult> read(String path) async {
    readCalls.add(path);
    if (readResults.isNotEmpty) return readResults.removeFirst();
    final failure = failures[path];
    if (failure != null) return AttachmentReadFailed(failure);
    final bytes = files[path];
    if (bytes == null) {
      return const AttachmentReadFailed(AttachmentLookupFailure.missing);
    }
    return AttachmentBytes(bytes);
  }

  @override
  Future<AttachmentInfoResult> info(String path) async {
    infoCalls.add(path);
    if (infoResults.isNotEmpty) return infoResults.removeFirst();
    final failure = failures[path];
    if (failure != null) return AttachmentInfoFailed(failure);
    final bytes = files[path];
    if (bytes == null) {
      return const AttachmentInfoFailed(AttachmentLookupFailure.missing);
    }
    return AttachmentInfoFound(
      AttachmentInfo(size: bytes.length, type: 'application/octet-stream'),
    );
  }
}

/// A hosted vault's attachments (not a `LocalAttachmentsAccess`): every
/// `read` and `info` of a path waits until the test answers it
/// ([answerRead], [answerInfo], [answerFile], [answerFailure]); once
/// answered, later calls for that path answer the same at once. `open` and
/// `reveal` record their path and answer from their FIFO queues, else
/// [AttachmentActionDone]. Nothing touches the network.
class FakeHostedAttachments implements AttachmentsAccess {
  final List<String> readCalls = [];
  final List<String> infoCalls = [];
  final List<String> openCalls = [];
  final List<String> revealCalls = [];
  final Queue<AttachmentActionResult> openResults = Queue();
  final Queue<AttachmentActionResult> revealResults = Queue();

  final Map<String, Completer<AttachmentReadResult>> _reads = {};
  final Map<String, Completer<AttachmentInfoResult>> _infos = {};

  Completer<AttachmentReadResult> _read(String path) =>
      _reads.putIfAbsent(path, Completer.new);
  Completer<AttachmentInfoResult> _info(String path) =>
      _infos.putIfAbsent(path, Completer.new);

  /// Answers every pending and later `read` of [path] with [result].
  void answerRead(String path, AttachmentReadResult result) {
    final c = _read(path);
    if (!c.isCompleted) c.complete(result);
  }

  /// Answers every pending and later `info` of [path] with [result].
  void answerInfo(String path, AttachmentInfoResult result) {
    final c = _info(path);
    if (!c.isCompleted) c.complete(result);
  }

  /// Answers [path]'s reads with [bytes] and its info with their size.
  void answerFile(String path, Uint8List bytes) {
    answerRead(path, AttachmentBytes(bytes));
    answerInfo(
      path,
      AttachmentInfoFound(
        AttachmentInfo(size: bytes.length, type: 'application/octet-stream'),
      ),
    );
  }

  /// Answers [path]'s reads and info with [failure].
  void answerFailure(String path, AttachmentLookupFailure failure) {
    answerRead(path, AttachmentReadFailed(failure));
    answerInfo(path, AttachmentInfoFailed(failure));
  }

  @override
  Future<AttachmentAddResult> add(String filePath, String? name) async =>
      AttachmentAdded(fakeAddedAttachment(name ?? filePath.split('/').last));

  @override
  Future<AttachmentAddResult> addBytes(Uint8List bytes, String name) async =>
      AttachmentAdded(fakeAddedAttachment(name, size: bytes.length));

  @override
  Future<AttachmentReadResult> read(String path) {
    readCalls.add(path);
    return _read(path).future;
  }

  @override
  Future<AttachmentInfoResult> info(String path) {
    infoCalls.add(path);
    return _info(path).future;
  }

  @override
  Future<AttachmentActionResult> open(String path) async {
    openCalls.add(path);
    if (openResults.isNotEmpty) return openResults.removeFirst();
    return const AttachmentActionDone();
  }

  @override
  Future<AttachmentActionResult> reveal(String path) async {
    revealCalls.add(path);
    if (revealResults.isNotEmpty) return revealResults.removeFirst();
    return const AttachmentActionDone();
  }
}

/// 64 lowercase hex characters for test attachment [n], starting `5e`, so
/// each test's file gets its own path (image sizes cache per path).
String testAttachmentHash(int n) => '5e${n.toRadixString(16).padLeft(62, '0')}';

/// The decoded vault path of test attachment [n] named [name].
String testAttachmentPath(int n, String name) =>
    'objects/5e/${testAttachmentHash(n)}/$name';

/// A one-colour 8-bit RGB PNG of [width] x [height] pixels.
Uint8List testPngBytes(int width, int height, {int rgb = 0x3366CC}) {
  final row = Uint8List(1 + width * 3);
  for (var x = 0; x < width; x++) {
    row[1 + x * 3] = (rgb >> 16) & 0xFF;
    row[2 + x * 3] = (rgb >> 8) & 0xFF;
    row[3 + x * 3] = rgb & 0xFF;
  }
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < height; y++) {
    raw.add(row);
  }
  final idat = ZLibEncoder().convert(raw.takeBytes());
  return _t143PngFile(width, height, [_t143PngChunk('IDAT', idat)]);
}

/// A PNG whose header claims [width] x [height] pixels and whose image data
/// is [data] (default: none, so it never decodes).
Uint8List testPngHeaderOnly(int width, int height, {List<int>? data}) =>
    _t143PngFile(width, height, [
      if (data != null) _t143PngChunk('IDAT', data),
    ]);

Uint8List _t143PngFile(int width, int height, List<List<int>> chunks) {
  final ihdr = [..._t143Be32(width), ..._t143Be32(height), 8, 2, 0, 0, 0];
  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_t143PngChunk('IHDR', ihdr));
  for (final c in chunks) {
    out.add(c);
  }
  out.add(_t143PngChunk('IEND', const []));
  return out.takeBytes();
}

List<int> _t143Be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

List<int> _t143PngChunk(String type, List<int> data) {
  final typed = [...type.codeUnits, ...data];
  return [..._t143Be32(data.length), ...typed, ..._t143Be32(_t143Crc(typed))];
}

final List<int> _t143CrcTable = List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _t143Crc(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _t143CrcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// An animated GIF of [width] x [height] pixels with [frames] frames that
/// alternate black and white, each shown [delayCs] hundredths of a second,
/// looping forever.
Uint8List testAnimatedGifBytes(
  int width,
  int height, {
  int frames = 2,
  int delayCs = 10,
}) {
  List<int> le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
  final out = BytesBuilder()
    ..add('GIF89a'.codeUnits)
    ..add(le16(width))
    ..add(le16(height))
    ..add(const [0xF0, 0, 0])
    ..add(const [0, 0, 0, 0xFF, 0xFF, 0xFF])
    ..add([0x21, 0xFF, 0x0B, ...'NETSCAPE2.0'.codeUnits, 3, 1, 0, 0, 0]);
  for (var f = 0; f < frames; f++) {
    out
      ..add([0x21, 0xF9, 4, 0x04, ...le16(delayCs), 0, 0])
      ..add([0x2C, ...le16(0), ...le16(0), ...le16(width), ...le16(height), 0])
      ..addByte(2);
    // LZW with minimum code size 2: a clear code before every pixel keeps
    // every code 3 bits wide.
    final codes = <int>[
      for (var p = 0; p < width * height; p++) ...[4, f % 2],
      5,
    ];
    final packed = <int>[];
    var acc = 0;
    var bits = 0;
    for (final code in codes) {
      acc |= code << bits;
      bits += 3;
      while (bits >= 8) {
        packed.add(acc & 0xFF);
        acc >>= 8;
        bits -= 8;
      }
    }
    if (bits > 0) packed.add(acc & 0xFF);
    for (var i = 0; i < packed.length; i += 255) {
      final end = i + 255 < packed.length ? i + 255 : packed.length;
      out
        ..addByte(end - i)
        ..add(packed.sublist(i, end));
    }
    out.addByte(0);
  }
  out.addByte(0x3B);
  return out.takeBytes();
}
