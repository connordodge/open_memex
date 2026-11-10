// WI #372 (Spec #367 Req 14, D8): MemexCli.autodiscover finds the Bundled
// memex (next to the running executable) before the well-known install
// locations. Fake paths and a fake file-exists function; no real memex.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:path/path.dart' as p;

const _exe = '/fake/Open Memex.app/Contents/MacOS/Open Memex';
const _bundled = '/fake/Open Memex.app/Contents/MacOS/memex';
const _home = '/fake/home';
const _cargo = '/fake/home/.cargo/bin/memex';
const _usrLocal = '/usr/local/bin/memex';
const _homebrew = '/opt/homebrew/bin/memex';

String? _discover(Set<String> present) => MemexCli.autodiscover(
  executablePath: _exe,
  exists: present.contains,
  home: _home,
);

void main() {
  group('autodiscover lookup order', () {
    test('the Bundled memex wins over every well-known location', () {
      expect(_discover({_bundled, _cargo, _usrLocal, _homebrew}), _bundled);
    });

    test('the Bundled memex is found next to the executable alone', () {
      expect(_discover({_bundled}), _bundled);
    });

    test('without a Bundled memex the cargo binary wins over the rest', () {
      expect(_discover({_cargo, _usrLocal, _homebrew}), _cargo);
    });

    test('without cargo the usr local binary wins over homebrew', () {
      expect(_discover({_usrLocal, _homebrew}), _usrLocal);
    });

    test('homebrew is the last resort', () {
      expect(_discover({_homebrew}), _homebrew);
    });

    test('nothing found anywhere gives null', () {
      expect(_discover(<String>{}), isNull);
    });

    test('only a memex beside the executable counts as bundled', () {
      // A memex in another directory is not the Bundled one.
      expect(
        _discover({'/fake/Open Memex.app/Contents/Resources/memex'}),
        isNull,
      );
    });

    test('a null HOME skips the cargo location and still finds the rest', () {
      expect(
        MemexCli.autodiscover(
          executablePath: _exe,
          exists: {_cargo, _usrLocal}.contains,
          home: null,
        ),
        isNot(_cargo),
      );
    });
  });

  group('autodiscover with real files (default file-exists)', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('memex_discover_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a real file beside the executable is found as the Bundled memex', () {
      final macos = Directory(p.join(tmp.path, 'Open Memex.app', 'MacOS'))
        ..createSync(recursive: true);
      final bundled = File(p.join(macos.path, 'memex'))..writeAsStringSync('#');
      final cargo = File(p.join(tmp.path, 'home', '.cargo', 'bin', 'memex'))
        ..createSync(recursive: true);
      expect(cargo.existsSync(), isTrue);

      final found = MemexCli.autodiscover(
        executablePath: p.join(macos.path, 'Open Memex'),
        home: p.join(tmp.path, 'home'),
      );

      expect(found, bundled.path);
    });

    test(
      'a real cargo file is found when no memex sits beside the executable',
      () {
        final macos = Directory(p.join(tmp.path, 'App', 'MacOS'))
          ..createSync(recursive: true);
        final cargo = File(p.join(tmp.path, 'home', '.cargo', 'bin', 'memex'))
          ..createSync(recursive: true);

        final found = MemexCli.autodiscover(
          executablePath: p.join(macos.path, 'App'),
          home: p.join(tmp.path, 'home'),
        );

        // /usr/local and homebrew rank below cargo, so cargo wins even on a
        // machine that has them.
        expect(found, cargo.path);
      },
    );
  });
}
