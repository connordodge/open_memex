import 'dart:convert';

import '../memex_cli.dart';

/// The vault setting that caps Smart Folder nesting (C2.11).
const smartFolderMaxDepthKey = 'smart_folder_max_depth';

/// `memex settings` wrappers (C2.11). #25 adds `set` to this file.
extension SettingsCli on MemexCli {
  /// `memex settings get --vault <vaultPath> --key <key>` → the setting value.
  ///
  /// Stdout is `{"vault_id":…,"key":…,"value":<int>}`. A CLI failure throws
  /// [MemexException] with the C1 `code` (e.g. `setting_invalid`); stdout
  /// without an integer `value` throws a [MemexException] with a null code.
  Future<int> getSetting(String vaultPath, String key) async {
    final r = await run([
      'settings',
      'get',
      '--vault',
      vaultPath,
      '--key',
      key,
    ]);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('settings get', r);
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
        'settings get: could not parse value from output: ${r.stdout}',
      );
    }
    return value;
  }
}
