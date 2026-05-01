import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../memex_cli.dart';
import 'settings.dart';

/// The currently open vault path. `null` means no vault is open.
final currentVaultProvider = StateProvider<String?>((ref) {
  return ref.watch(settingsProvider).lastVault;
});

/// SQLite read handle for the current vault.
final vaultDbProvider = Provider<VaultDb?>((ref) {
  final path = ref.watch(currentVaultProvider);
  if (path == null) return null;
  if (!VaultDb.isVault(path)) return null;
  final db = VaultDb.open(path);
  ref.onDispose(db.close);
  return db;
});

/// Memex CLI handle bound to the configured binary path.
final memexCliProvider = Provider<MemexCli?>((ref) {
  final binary = ref.watch(settingsProvider).memexBinaryPath;
  if (binary == null || binary.isEmpty) return null;
  return MemexCli(binaryPath: binary);
});

/// A monotonic counter that increments whenever the vault should be re-read
/// from disk. Bump it after every write.
final vaultRevisionProvider = StateProvider<int>((_) => 0);

/// Sorted list of notes in the current vault.
final notesListProvider = Provider<List<NoteListItem>>((ref) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null) return const [];
  return db.listNotes(limit: 200);
});

/// The currently selected note id (or null).
final selectedNoteIdProvider = StateProvider<String?>((_) => null);

/// Hydrated form of the selected note.
final selectedNoteProvider = Provider<Note?>((ref) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  final id = ref.watch(selectedNoteIdProvider);
  if (db == null || id == null) return null;
  return db.getNote(id);
});

enum SaveStatus { idle, dirty, saving, clean, error, conflict }

class EditorStateValue {
  const EditorStateValue({
    required this.title,
    required this.contentMd,
    required this.status,
    this.errorMessage,
    this.lastSavedVersion,
  });
  final String title;
  final String contentMd;
  final SaveStatus status;
  final String? errorMessage;
  final int? lastSavedVersion;

  EditorStateValue copyWith({
    String? title,
    String? contentMd,
    SaveStatus? status,
    String? errorMessage,
    bool clearError = false,
    int? lastSavedVersion,
  }) => EditorStateValue(
    title: title ?? this.title,
    contentMd: contentMd ?? this.contentMd,
    status: status ?? this.status,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    lastSavedVersion: lastSavedVersion ?? this.lastSavedVersion,
  );
}
