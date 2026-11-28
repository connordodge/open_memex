// Spec #123 V1 (WI #141): the app's pure mirror of the attachment reference
// grammar and tables in `crates/memex-core/src/attachments.rs` (R3, R4, R31,
// R32, R33). No `package:flutter`, `dart:ui` or `package:meta` imports: the
// editor's pure files stay testable and isolate-safe.
//
// The Rust core and this file share one grammar, pinned by the fixture table
// `app/test/fixtures/attachments/refs.json`.

import 'dart:convert';

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
const List<String> inlineImageExtensions = <String>[
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
];

/// The script and executable extensions that are revealed, never opened
/// (R33), lowercase, without the dot.
const List<String> executableExtensions = <String>[
  'command',
  'tool',
  'terminal',
  'sh',
  'zsh',
  'bash',
  'py',
  'rb',
  'pl',
  'pkg',
  'mpkg',
  'dmg',
  'app',
  'workflow',
  'scpt',
  'applescript',
  'jar',
  'exe',
  'fileloc',
  'inetloc',
  'webloc',
  'afploc',
  'ftploc',
  'mailloc',
  'newsloc',
  'atloc',
];

const String _objectsDir = 'objects';

/// [markdown], the whole string, as one attachment reference (R4), or null.
///
/// The text runs to its first `]` not escaped by a backslash and may be
/// empty. The destination is everything between the `(` right after that
/// `]` and the final `)`; it holds no whitespace, `(` or `)`, and is a
/// [parseAttachmentDestination] path. Anything before or after the
/// reference, or a line break, makes it not one.
AttachmentRef? parseAttachmentReference(String markdown) {
  if (markdown.contains('\n') || markdown.contains('\r')) return null;
  final AttachmentRefKind kind;
  final String rest;
  if (markdown.startsWith('![')) {
    kind = AttachmentRefKind.image;
    rest = markdown.substring(2);
  } else if (markdown.startsWith('[')) {
    kind = AttachmentRefKind.link;
    rest = markdown.substring(1);
  } else {
    return null;
  }
  var i = 0;
  while (true) {
    if (i >= rest.length) return null;
    final unit = rest.codeUnitAt(i);
    if (unit == 0x5C) {
      i += 2;
    } else if (unit == 0x5D) {
      break;
    } else {
      i += 1;
    }
  }
  final afterText = rest.substring(i + 1);
  if (afterText.length < 2 ||
      !afterText.startsWith('(') ||
      !afterText.endsWith(')')) {
    return null;
  }
  final destination = afterText.substring(1, afterText.length - 1);
  for (final rune in destination.runes) {
    if (_isWhitespace(rune) || rune == 0x28 || rune == 0x29) return null;
  }
  final target = parseAttachmentDestination(destination);
  if (target == null) return null;
  return AttachmentRef(kind: kind, target: target);
}

/// Unicode White_Space, as Rust's `char::is_whitespace`.
bool _isWhitespace(int r) =>
    (r >= 0x09 && r <= 0x0D) ||
    r == 0x20 ||
    r == 0x85 ||
    r == 0xA0 ||
    r == 0x1680 ||
    (r >= 0x2000 && r <= 0x200A) ||
    r == 0x2028 ||
    r == 0x2029 ||
    r == 0x202F ||
    r == 0x205F ||
    r == 0x3000;

/// [destination], percent-encoded as in a link token, as an attachment path
/// (R4), or null.
///
/// `%XX` decodes in either hex case; a `%` not followed by two hex digits,
/// or bytes that are not UTF-8, make it not an attachment.
AttachmentPath? parseAttachmentDestination(String destination) {
  final decoded = _percentDecode(destination);
  if (decoded == null) return null;
  return parseAttachmentPath(decoded);
}

int? _hexDigit(int unit) {
  if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
  if (unit >= 0x41 && unit <= 0x46) return unit - 0x41 + 10;
  if (unit >= 0x61 && unit <= 0x66) return unit - 0x61 + 10;
  return null;
}

String? _percentDecode(String s) {
  final bytes = utf8.encode(s);
  final out = <int>[];
  var i = 0;
  while (i < bytes.length) {
    if (bytes[i] == 0x25) {
      if (i + 2 >= bytes.length) return null;
      final hi = _hexDigit(bytes[i + 1]);
      final lo = _hexDigit(bytes[i + 2]);
      if (hi == null || lo == null) return null;
      out.add(hi * 16 + lo);
      i += 3;
    } else {
      out.add(bytes[i]);
      i += 1;
    }
  }
  // Dart's decoder drops a leading BOM; Rust's String::from_utf8 keeps it, and
  // the path check then fails. Refuse it so both reject the same input.
  if (out.length >= 3 && out[0] == 0xEF && out[1] == 0xBB && out[2] == 0xBF) {
    return null;
  }
  try {
    return utf8.decode(out);
  } on FormatException {
    return null;
  }
}

bool _isLowerHex(String s) {
  for (final unit in s.codeUnits) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isLowerAf = unit >= 0x61 && unit <= 0x66;
    if (!isDigit && !isLowerAf) return false;
  }
  return true;
}

/// An already-decoded vault-relative [path] as an attachment path (R4), or
/// null: `objects/<2 hex>/<64 lowercase hex>/<name>`, the two hex characters
/// equal to the first two of the 64, and a non-empty name with no `/` that
/// is not `.` or `..`.
AttachmentPath? parseAttachmentPath(String path) {
  const prefix = '$_objectsDir/';
  if (!path.startsWith(prefix)) return null;
  final rel = path.substring(prefix.length);
  final firstSlash = rel.indexOf('/');
  if (firstSlash < 0) return null;
  final h2 = rel.substring(0, firstSlash);
  final rest = rel.substring(firstSlash + 1);
  final secondSlash = rest.indexOf('/');
  if (secondSlash < 0) return null;
  final hash = rest.substring(0, secondSlash);
  final name = rest.substring(secondSlash + 1);
  final hashOk = hash.length == 64 && _isLowerHex(hash) && hash.startsWith(h2);
  final nameOk =
      name.isNotEmpty && !name.contains('/') && name != '.' && name != '..';
  if (h2.length != 2 || !hashOk || !nameOk) return null;
  return AttachmentPath(path: path, hash: hash, name: name);
}

/// [name] percent-encoded for a reference URL (R3): every UTF-8 byte outside
/// `A-Z a-z 0-9 - . _ ~` as `%XX`, upper-case hex.
String encodeAttachmentName(String name) {
  final out = StringBuffer();
  for (final b in utf8.encode(name)) {
    final unreserved =
        (b >= 0x30 && b <= 0x39) ||
        (b >= 0x41 && b <= 0x5A) ||
        (b >= 0x61 && b <= 0x7A) ||
        b == 0x2D ||
        b == 0x2E ||
        b == 0x5F ||
        b == 0x7E;
    if (unreserved) {
      out.writeCharCode(b);
    } else {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

String _escapeText(String name) {
  final out = StringBuffer();
  for (final unit in name.codeUnits) {
    if (unit == 0x5B || unit == 0x5D || unit == 0x5C) out.write(r'\');
    out.writeCharCode(unit);
  }
  return out.toString();
}

/// The reference markdown for the stored [name] of the content [hash] (R3):
/// `![name](url)` for an inline image type (R31), `[name](url)` otherwise,
/// where url is `objects/<h2>/<hash>/<encoded name>`.
String attachmentMarkdown(String name, String hash) {
  final bang = isInlineImageName(name) ? '!' : '';
  final h2 = hash.length >= 2 ? hash.substring(0, 2) : hash;
  return '$bang[${_escapeText(name)}]'
      '($_objectsDir/$h2/$hash/${encodeAttachmentName(name)})';
}

/// What follows [name]'s last `.`, or null when it has no dot.
String? _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? null : name.substring(dot + 1);
}

bool _hasExtensionIn(String name, List<String> table) {
  final ext = _extension(name);
  return ext != null && table.contains(_asciiLower(ext));
}

/// Lower-cases A-Z only, as Rust's to_ascii_lowercase does (Dart's
/// toLowerCase also folds non-ASCII letters such as the Kelvin sign).
String _asciiLower(String s) => String.fromCharCodes(
  s.codeUnits.map((c) => c >= 0x41 && c <= 0x5A ? c + 0x20 : c),
);

/// Whether [name] has an inline image extension (R31), in any letter case.
bool isInlineImageName(String name) =>
    _hasExtensionIn(name, inlineImageExtensions);

/// Whether [name] has a script or executable extension (R33), in any letter
/// case.
bool isExecutableName(String name) =>
    _hasExtensionIn(name, executableExtensions);

/// The upper-case extension of [name], or `FILE` (R32).
String attachmentTypeLabel(String name) {
  final ext = _extension(name);
  return ext == null || ext.isEmpty ? 'FILE' : ext.toUpperCase();
}

/// [bytes] as `<n> B`, `<n> KB` or `<n.n> MB`, 1024-based (R32).
String formatAttachmentSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// `<TYPE> · <size>` of a file card (R32).
String attachmentCaption(String name, int bytes) =>
    '${attachmentTypeLabel(name)} · ${formatAttachmentSize(bytes)}';
