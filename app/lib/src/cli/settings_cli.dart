import '../memex_cli.dart';

/// `memex settings` wrappers (C2.11). #25 adds `set` to this file.
extension SettingsCli on MemexCli {
  /// `memex settings get --vault <vaultPath> --key <key>` → the setting value.
  Future<int> getSetting(String vaultPath, String key) =>
      throw UnimplementedError('getSetting');
}
