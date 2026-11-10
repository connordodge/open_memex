// WI #321 (A0, D19): backup file names, the Dart side of D10 (req 4). The
// signatures are frozen; WI #322 (A1) wrote the bodies. All of them pass the
// shared `file_names.json` fixture and agree with Rust's `backup::names`.

/// A file name that matches `<label>-<YYYYMMDDTHHMMSSZ>-<vault_id>.memex.zip`.
class ParsedBackupName {
  const ParsedBackupName({
    required this.label,
    required this.timestamp,
    required this.vaultId,
  });

  /// 1-64 characters of `[A-Za-z0-9_-]`.
  final String label;

  /// The UTC time in the name.
  final DateTime timestamp;

  /// 26 characters.
  final String vaultId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParsedBackupName &&
          other.label == label &&
          other.timestamp == timestamp &&
          other.vaultId == vaultId;

  @override
  int get hashCode => Object.hash(label, timestamp, vaultId);

  @override
  String toString() => 'ParsedBackupName($label, $timestamp, $vaultId)';
}

/// Parses [fileName] by the strict, case-sensitive grammar, from the right:
/// the last 26 characters before `.memex.zip` are the vault id, then a
/// 16-character `\d{8}T\d{6}Z` timestamp, then the label. Null when it
/// doesn't match (look-alikes, `.partial` files, other extensions).
ParsedBackupName? parseBackupFileName(String fileName) {
  final m = _backupName.firstMatch(fileName);
  if (m == null) return null;
  final stamp = m.group(2)!;
  int part(int from, int to) => int.parse(stamp.substring(from, to));
  return ParsedBackupName(
    label: m.group(1)!,
    timestamp: DateTime.utc(
      part(0, 4),
      part(4, 6),
      part(6, 8),
      part(9, 11),
      part(11, 13),
      part(13, 15),
    ),
    vaultId: m.group(3)!,
  );
}

// ASCII only: `[0-9]`, never `\d`, and no case folding. The tail has a fixed
// width, so the split from the right is unique.
final _backupName = RegExp(
  r'^([A-Za-z0-9_-]{1,64})-([0-9]{8}T[0-9]{6}Z)-([A-Za-z0-9]{26})\.memex\.zip$',
);

/// The vault name the Restore dialog prefills (req 35): the parsed label, or,
/// for a name that doesn't match, [fileName] without `.memex.zip` or `.zip`.
String suggestedRestoreName(String fileName) {
  final parsed = parseBackupFileName(fileName);
  if (parsed != null) return parsed.label;
  for (final extension in const ['.memex.zip', '.zip']) {
    if (fileName.endsWith(extension)) {
      return fileName.substring(0, fileName.length - extension.length);
    }
  }
  return fileName;
}

/// The label a backup of the vault folder [folder] gets (D10): every Unicode
/// scalar outside `[A-Za-z0-9_-]` becomes one `-`, cut to 64 characters. The
/// Dart port of Rust's `label_for`; it iterates runes, not UTF-16 code units.
String backupLabelFor(String folder) {
  final label = StringBuffer();
  for (final rune in folder.runes.take(_labelMax)) {
    // Below 128 first: a non-ASCII scalar never passes the class test.
    final keep =
        rune < 128 &&
        ((rune >= 0x30 && rune <= 0x39) ||
            (rune >= 0x41 && rune <= 0x5A) ||
            (rune >= 0x61 && rune <= 0x7A) ||
            rune == 0x5F ||
            rune == 0x2D);
    label.write(keep ? String.fromCharCode(rune) : '-');
  }
  return label.toString();
}

const _labelMax = 64;
