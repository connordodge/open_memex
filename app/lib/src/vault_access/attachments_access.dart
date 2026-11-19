import 'dart:typed_data';

/// Why a lookup, read, open or reveal of an attachment failed. A consumer
/// renders each outcome distinctly (Spec #123 R28, R42):
/// - [missing]: the file is not there (`Image not found`, `File not found`);
/// - [offline]: a hosted vault's server can't be reached
///   (`Image unavailable offline`; the toast "Couldn't open NAME: the vault
///   server can't be reached.");
/// - [serverTooOld]: a hosted server without attachment routes
///   (`Image unavailable`);
/// - [unsupported]: this vault's access has no attachments implementation
///   (the stub until W3).
enum AttachmentLookupFailure { missing, offline, serverTooOld, unsupported }

/// Why an add failed. [AttachmentAddFailed.message] holds the text to show.
enum AttachmentAddFailureReason {
  /// Over 100 MB (R15).
  tooLarge,

  /// The path is a folder; folders can't be attached (R15).
  folder,

  /// A hosted vault's server can't be reached (R42).
  unreachable,

  /// A hosted server without attachment routes (R42).
  serverTooOld,

  /// A local `memex` without the `attach` command (R42).
  memexTooOld,

  /// This vault's access has no attachments implementation (until W3).
  unsupported,

  /// Any other failure; the message says what happened.
  other,
}

/// A stored attachment: what `memex attach` and `POST /attachments` return
/// (R1, R16): `{markdown, path, name, size, type}`.
final class AddedAttachment {
  const AddedAttachment({
    required this.markdown,
    required this.path,
    required this.name,
    required this.size,
    required this.type,
  });

  /// The R3 markdown to place in a note.
  final String markdown;

  /// The decoded vault-relative path, `objects/<h2>/<h>/<name>`.
  final String path;

  /// The stored name (R1).
  final String name;

  /// The size in bytes.
  final int size;

  /// The MIME type from the extension.
  final String type;
}

/// The result of `add` and `addBytes`.
sealed class AttachmentAddResult {
  const AttachmentAddResult();
}

/// The attachment was stored.
final class AttachmentAdded extends AttachmentAddResult {
  const AttachmentAdded(this.attachment);

  final AddedAttachment attachment;
}

/// The attachment was not stored.
final class AttachmentAddFailed extends AttachmentAddResult {
  const AttachmentAddFailed(this.reason, this.message);

  final AttachmentAddFailureReason reason;

  /// The text to show the person, naming the reason.
  final String message;
}

/// The size and type of a stored attachment.
final class AttachmentInfo {
  const AttachmentInfo({required this.size, required this.type});

  /// The size in bytes.
  final int size;

  /// The MIME type from the extension.
  final String type;
}

/// The result of `read`.
sealed class AttachmentReadResult {
  const AttachmentReadResult();
}

/// The file's bytes.
final class AttachmentBytes extends AttachmentReadResult {
  const AttachmentBytes(this.bytes);

  final Uint8List bytes;
}

/// The file could not be read.
final class AttachmentReadFailed extends AttachmentReadResult {
  const AttachmentReadFailed(this.failure);

  final AttachmentLookupFailure failure;
}

/// The result of `info`.
sealed class AttachmentInfoResult {
  const AttachmentInfoResult();
}

/// The file's size and type.
final class AttachmentInfoFound extends AttachmentInfoResult {
  const AttachmentInfoFound(this.info);

  final AttachmentInfo info;
}

/// The file's info could not be read.
final class AttachmentInfoFailed extends AttachmentInfoResult {
  const AttachmentInfoFailed(this.failure);

  final AttachmentLookupFailure failure;
}

/// The result of `open` and `reveal`.
sealed class AttachmentActionResult {
  const AttachmentActionResult();
}

/// The file was opened or revealed.
final class AttachmentActionDone extends AttachmentActionResult {
  const AttachmentActionDone();
}

/// The file could not be opened or revealed.
final class AttachmentActionFailed extends AttachmentActionResult {
  const AttachmentActionFailed(this.failure);

  final AttachmentLookupFailure failure;
}

/// Attachments of the open vault (Spec #123, WI #141): add a file or bytes,
/// read bytes, size and type, open and reveal. An amendment to the frozen
/// `VaultAccess` interface.
///
/// No method throws for an expected outcome: each returns a sealed result.
/// Parameters have no defaults on this interface; pass null for "none".
///
/// D10: [open] and [reveal] are the only route from an `objects/` path to
/// `/usr/bin/open`. Nothing else opens or reveals an attachment. An
/// implementation applies R33's executable table there: a script or
/// executable is revealed, never opened.
///
/// Until W3 (#140) local and hosted vaults answer every call with the
/// `unsupported` outcome. Test doubles `extends LocalAttachmentsAccess` (D21).
abstract interface class AttachmentsAccess {
  /// Stores the file at [filePath] (`memex attach`). The stored name starts
  /// from [name], or from the file's base name when [name] is null.
  Future<AttachmentAddResult> add(String filePath, String? name);

  /// Stores [bytes] under a stored name that starts from [name].
  Future<AttachmentAddResult> addBytes(Uint8List bytes, String name);

  /// The bytes of the attachment at the decoded vault-relative [path].
  Future<AttachmentReadResult> read(String path);

  /// The size and type of the attachment at [path].
  Future<AttachmentInfoResult> info(String path);

  /// Opens the attachment at [path] in its default app. A script or
  /// executable (R33) is revealed instead, never opened (D10).
  Future<AttachmentActionResult> open(String path);

  /// Reveals the attachment at [path] in Finder.
  Future<AttachmentActionResult> reveal(String path);
}
