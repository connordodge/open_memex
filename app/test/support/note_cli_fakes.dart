import 'dart:convert';

import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';

/// `rm` handlers for [FakeMemexCli] (C2.2, WI #31).
extension NoteCliFakes on FakeMemexCli {
  /// Register an `rm` handler that behaves like `memex rm` against [vault]:
  /// `not_found` when the note is missing, `version_conflict` when
  /// `--expected-version` differs from the stored version, otherwise it deletes
  /// the row (the real CLI also purges dependants; FK cascades cover that
  /// here) and answers the C2.2 sample shape.
  void onRm(FakeVaultDb vault) {
    on('rm', (call) {
      final id = call.flag('note-id');
      final expected = int.tryParse(call.flag('expected-version') ?? '');
      final rows = vault.db.select('SELECT version FROM notes WHERE id = ?', [
        id,
      ]);
      if (rows.isEmpty) {
        return FakeMemexCli.error('not_found', 'note not found: $id');
      }
      final current = (rows.first['version'] as num).toInt();
      if (expected != current) {
        return FakeMemexCli.error(
          'version_conflict',
          'note changed since last read',
          {'current_version': current},
        );
      }
      vault.db.execute('DELETE FROM notes WHERE id = ?', [id]);
      final body = jsonEncode({
        'vault_id': '01HV0000000000000000000000',
        'note_id': id,
        'deleted': true,
      });
      return FakeMemexCli.ok('$body\n');
    });
  }
}
