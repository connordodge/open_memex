// WI #372 (Spec #367 Req 13 app side, Req 14; D8, R5): SettingsController.load
// resolves the memex binary as picked path (if the file exists) > Bundled
// memex beside the executable > cargo > /usr/local > homebrew. A dead picked
// path is skipped but never removed from preferences. Fake file-exists seam;
// no real memex binary.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/token_store_fakes.dart';

const _kBinary = 'memex.binary_path';
const _exe = '/fake/Open Memex.app/Contents/MacOS/Open Memex';
const _bundled = '/fake/Open Memex.app/Contents/MacOS/memex';
const _home = '/fake/home';
const _cargo = '/fake/home/.cargo/bin/memex';
const _usrLocal = '/usr/local/bin/memex';
const _homebrew = '/opt/homebrew/bin/memex';
const _picked = '/fake/picked/bin/memex';

/// Loads settings from the current prefs with only [present] paths existing.
Future<SettingsController> _loadAgain(Set<String> present) =>
    SettingsController.load(
      tokenStore: FakeTokenStore(),
      executablePath: _exe,
      exists: present.contains,
      home: _home,
    );

/// Loads settings with [prefs] seeded, and only [present] paths existing.
Future<SettingsController> _load(
  Set<String> present, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  return _loadAgain(present);
}

void main() {
  group('binary lookup order', () {
    test(
      'the Bundled memex wins over a picked path that exists',
      () async {
        // A picked path outlives the binary it named, and the Bundled memex
        // always matches the app's schema (v0.3.0: a stale picked memex
        // refused every write on the migrated vault).
        final settings = await _load(
          {_picked, _bundled, _cargo},
          prefs: {_kBinary: _picked},
        );

        expect(settings.state.memexBinaryPath, _bundled);
      },
    );

    test(
      'without a Bundled memex a picked path that exists wins over cargo',
      () async {
        final settings = await _load(
          {_picked, _cargo},
          prefs: {_kBinary: _picked},
        );

        expect(settings.state.memexBinaryPath, _picked);
      },
    );

    test('a dead picked path falls through to the Bundled memex', () async {
      final settings = await _load(
        {_bundled, _cargo},
        prefs: {_kBinary: _picked},
      );

      expect(settings.state.memexBinaryPath, _bundled);
    });

    test('a dead picked path stays in preferences', () async {
      await _load({_bundled}, prefs: {_kBinary: _picked});

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_kBinary), _picked);
    });

    test('a dead picked path works again when the file comes back', () async {
      await _load({_cargo}, prefs: {_kBinary: _picked});

      // Same preferences, the picked file exists now (no Bundled memex).
      final again = await _loadAgain({_picked, _cargo});

      expect(again.state.memexBinaryPath, _picked);
    });

    test('a dead picked path with nothing else found gives null', () async {
      final settings = await _load(<String>{}, prefs: {_kBinary: _picked});

      expect(settings.state.memexBinaryPath, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_kBinary), _picked);
    });

    test(
      'no picked path uses the Bundled memex even when cargo exists',
      () async {
        final settings = await _load({_bundled, _cargo, _usrLocal});

        expect(settings.state.memexBinaryPath, _bundled);
      },
    );

    test(
      'with no picked path and no Bundled memex cargo wins over usr local',
      () async {
        final settings = await _load({_cargo, _usrLocal, _homebrew});

        expect(settings.state.memexBinaryPath, _cargo);
      },
    );

    test('with no cargo the usr local binary wins over homebrew', () async {
      final settings = await _load({_usrLocal, _homebrew});

      expect(settings.state.memexBinaryPath, _usrLocal);
    });

    test('homebrew is found when it is the only binary', () async {
      final settings = await _load({_homebrew});

      expect(settings.state.memexBinaryPath, _homebrew);
    });

    test('nothing found anywhere leaves memexBinaryPath null', () async {
      final settings = await _load(<String>{});

      expect(settings.state.memexBinaryPath, isNull);
    });
  });

  group('picking a binary', () {
    test(
      'setMemexBinary then a reload uses that path when it exists',
      () async {
        // A build with no Bundled memex (a dev build).
        final settings = await _load({_cargo, _picked});
        await settings.setMemexBinary(_picked);
        expect(settings.state.memexBinaryPath, _picked);

        final again = await _loadAgain({_cargo, _picked});
        expect(again.state.memexBinaryPath, _picked);
      },
    );

    test(
      'clearing the picked path with setMemexBinary null returns to bundled',
      () async {
        final settings = await _load(
          {_bundled, _picked},
          prefs: {_kBinary: _picked},
        );

        await settings.setMemexBinary(null);

        final again = await _loadAgain({_bundled, _picked});
        expect(again.state.memexBinaryPath, _bundled);
      },
    );
  });
}
