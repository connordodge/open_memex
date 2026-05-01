import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../memex_cli.dart';

class AppSettings {
  AppSettings({
    required this.memexBinaryPath,
    required this.recentVaults,
    required this.lastVault,
  });

  final String? memexBinaryPath;
  final List<String> recentVaults;
  final String? lastVault;

  AppSettings copyWith({
    String? memexBinaryPath,
    List<String>? recentVaults,
    String? lastVault,
    bool clearLastVault = false,
  }) => AppSettings(
    memexBinaryPath: memexBinaryPath ?? this.memexBinaryPath,
    recentVaults: recentVaults ?? this.recentVaults,
    lastVault: clearLastVault ? null : (lastVault ?? this.lastVault),
  );
}

class SettingsController extends StateNotifier<AppSettings> {
  SettingsController._(this._prefs, AppSettings initial) : super(initial);

  final SharedPreferences _prefs;

  static const _kBinary = 'memex.binary_path';
  static const _kRecents = 'memex.recent_vaults';
  static const _kLast = 'memex.last_vault';

  static Future<SettingsController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final binary = prefs.getString(_kBinary) ?? MemexCli.autodiscover();
    final recents = prefs.getStringList(_kRecents) ?? const <String>[];
    final last = prefs.getString(_kLast);
    return SettingsController._(
      prefs,
      AppSettings(
        memexBinaryPath: binary,
        recentVaults: recents,
        lastVault: last,
      ),
    );
  }

  Future<void> setMemexBinary(String? path) async {
    if (path == null || path.isEmpty) {
      await _prefs.remove(_kBinary);
    } else {
      await _prefs.setString(_kBinary, path);
    }
    state = state.copyWith(memexBinaryPath: path);
  }

  Future<void> rememberVault(String path) async {
    final list = [path, ...state.recentVaults.where((p) => p != path)];
    final trimmed = list.take(8).toList();
    await _prefs.setStringList(_kRecents, trimmed);
    await _prefs.setString(_kLast, path);
    state = state.copyWith(recentVaults: trimmed, lastVault: path);
  }

  Future<void> forgetVault(String path) async {
    final list = state.recentVaults.where((p) => p != path).toList();
    await _prefs.setStringList(_kRecents, list);
    if (state.lastVault == path) {
      await _prefs.remove(_kLast);
      state = state.copyWith(recentVaults: list, clearLastVault: true);
    } else {
      state = state.copyWith(recentVaults: list);
    }
  }

  Future<void> clearLastVault() async {
    await _prefs.remove(_kLast);
    state = state.copyWith(clearLastVault: true);
  }
}

final settingsProvider = StateNotifierProvider<SettingsController, AppSettings>(
  (_) => throw UnimplementedError('overridden in main()'),
);
