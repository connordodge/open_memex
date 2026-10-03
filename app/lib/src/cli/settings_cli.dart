import 'dart:convert';

import '../memex_cli.dart';

/// The vault setting that caps Smart Folder nesting (C2.11).
const smartFolderMaxDepthKey = 'smart_folder_max_depth';

/// `memex settings get|set` wrappers (C2.11, D21).
extension SettingsCli on MemexCli {
  /// `memex settings get --vault <vaultPath> --key <key>` → the setting value.
  ///
  /// Stdout is `{"vault_id":…,"key":…,"value":<int>}`. A CLI failure throws
  /// [MemexException] with the C1 `code` (e.g. `setting_invalid`); stdout
  /// without an integer `value` throws a [MemexException] with a null code.
  Future<int> getSetting(String vaultPath, String key) =>
      _settingsCall('get', ['--vault', vaultPath, '--key', key]);

  /// `memex settings set --vault <vaultPath> --key <key> --value <value>` →
  /// the stored value (C2.11, same stdout shape as `get`). A CLI failure
  /// throws [MemexException] with the C1 `code` (e.g. `setting_invalid`).
  Future<int> setSetting(String vaultPath, String key, int value) =>
      _settingsCall('set', [
        '--vault',
        vaultPath,
        '--key',
        key,
        '--value',
        '$value',
      ]);

  /// Runs `memex settings <sub> <args>` and returns the integer `value` on
  /// stdout. A non-zero exit throws [MemexException.fromCliFailure]; stdout
  /// without an integer `value` throws a null-code [MemexException].
  Future<int> _settingsCall(String sub, List<String> args) async {
    final r = await run(['settings', sub, ...args]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('settings $sub', r);
    }
    Object? json;
    try {
      json = jsonDecode(r.stdout.trim());
    } on FormatException {
      json = null;
    }
    final value = json is Map<String, Object?> ? json['value'] : null;
    if (value is! int) {
      throw MemexException(
        'settings $sub: could not parse value from output: ${r.stdout}',
      );
    }
    return value;
  }
}
