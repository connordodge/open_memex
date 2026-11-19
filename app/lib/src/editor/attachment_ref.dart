// Spec #123 V1 (WI #141): the app's pure mirror of the attachment reference
// grammar and tables in `crates/memex-core/src/attachments.rs` (R3, R4, R31,
// R32, R33). No `package:flutter`, `dart:ui` or `package:meta` imports: the
// editor's pure files stay testable and isolate-safe.
//
// The Rust core and this file share one grammar, pinned by the fixture table
// `app/test/fixtures/attachments/refs.json`.

/// The form of an attachment reference (R4).
enum AttachmentRefKind {
  /// `![text](destination)`.
  image,

  /// `[text](destination)`.
  link,
}

/// A destination that is an attachment path (R4), percent-decoded.
final class AttachmentPath {
  const AttachmentPath({
    required this.path,
    required this.hash,
    required this.name,
  });

  /// `objects/<h2>/<h>/<name>`, decoded.
  final String path;

  /// The 64 lowercase hex characters.
  final String hash;

  /// The decoded name.
  final String name;
}

/// One attachment reference (R4): its form and its decoded target.
final class AttachmentRef {
  const AttachmentRef({required this.kind, required this.target});

  final AttachmentRefKind kind;
  final AttachmentPath target;
}

/// The inline image extensions (R31), lowercase, without the dot.
const List<String> inlineImageExtensions = <String>[];

/// The script and executable extensions that are revealed, never opened
/// (R33), lowercase, without the dot.
const List<String> executableExtensions = <String>[];

/// [markdown], the whole string, as one attachment reference (R4), or null.
AttachmentRef? parseAttachmentReference(String markdown) => null;

/// [destination], percent-encoded as in a link token, as an attachment path
/// (R4), or null.
AttachmentPath? parseAttachmentDestination(String destination) => null;

/// An already-decoded vault-relative [path] as an attachment path (R4), or
/// null.
AttachmentPath? parseAttachmentPath(String path) => null;

/// [name] percent-encoded for a reference URL (R3).
String encodeAttachmentName(String name) => '';

/// The reference markdown for the stored [name] of the content [hash] (R3).
String attachmentMarkdown(String name, String hash) => '';

/// Whether [name] has an inline image extension (R31), in any letter case.
bool isInlineImageName(String name) => false;

/// Whether [name] has a script or executable extension (R33), in any letter
/// case.
bool isExecutableName(String name) => false;

/// The upper-case extension of [name], or `FILE` (R32).
String attachmentTypeLabel(String name) => '';

/// [bytes] as `<n> B`, `<n> KB` or `<n.n> MB`, 1024-based (R32).
String formatAttachmentSize(int bytes) => '';

/// `<TYPE> · <size>` of a file card (R32).
String attachmentCaption(String name, int bytes) => '';
