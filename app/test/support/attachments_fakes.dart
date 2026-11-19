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
import 'dart:collection';
import 'dart:typed_data';

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
