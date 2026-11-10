// WI #321 (A0, D19): backup file names, the Dart side of D10 (req 4). The
// signatures are frozen; the bodies are stubs A1 (#322) replaces. Both
// functions pass the shared `file_names.json` fixture.

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
}

/// Parses [fileName] by the strict, case-sensitive grammar, from the right:
/// the last 26 characters before `.memex.zip` are the vault id, then a
/// 16-character `\d{8}T\d{6}Z` timestamp, then the label. Null when it
/// doesn't match (look-alikes, `.partial` files, other extensions).
ParsedBackupName? parseBackupFileName(String fileName) => null;

/// The vault name the Restore dialog prefills (req 35): the parsed label, or,
/// for a name that doesn't match, [fileName] without `.memex.zip` or `.zip`.
String suggestedRestoreName(String fileName) => '';
