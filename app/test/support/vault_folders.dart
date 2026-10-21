// WI #69: temp folders standing in for vaults on disk.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'fake_vault_db.dart';

/// A temp folder that `VaultDb.isVault` accepts: `manifest.json` plus a real
/// V5 `memex.db` built from the schema fixture. Removed after the test.
Directory createVaultFolder([String prefix = 'om69_vault_']) {
  final dir = createPlainFolder(prefix);
  File(
    p.join(dir.path, 'manifest.json'),
  ).writeAsStringSync('{"vault_id":"01HV0000000000000000000069"}');
  writeV5Database(p.join(dir.path, 'memex.db'));
  return dir;
}

/// A temp folder that is not a vault (no manifest.json, no memex.db).
/// Removed after the test.
Directory createPlainFolder([String prefix = 'om69_plain_']) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() => deleteFolderQuietly(dir));
  return dir;
}

/// Write a V5 vault database file at [dbPath] from the schema fixture.
void writeV5Database(String dbPath) {
  final db = sqlite3.open(dbPath);
  try {
    db.execute(File(vaultSchemaV5FixturePath).readAsStringSync());
  } finally {
    db.dispose();
  }
}

/// What `memex init <path>` leaves behind: the folder with a manifest and a
/// V5 database.
void initVaultFolder(String path) {
  Directory(path).createSync(recursive: true);
  File(
    p.join(path, 'manifest.json'),
  ).writeAsStringSync('{"vault_id":"01HV0000000000000000000069"}');
  writeV5Database(p.join(path, 'memex.db'));
}

/// Best-effort removal: unawaited `ui_state.json` writes may land while the
/// folder is being deleted.
void deleteFolderQuietly(Directory dir) {
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      // A queued write raced the delete; try again.
    }
  }
}
