// WI #32 (Spec #31 req 9, D21): the version decision and the running macOS
// version.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/appcast.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';
import 'package:open_memex_app/src/updater/update_version.dart';

import '../support/updater_fakes.dart';

AppcastItem _item(
  String shortVersion, {
  String build = '1',
  String minimum = '',
}) => testAppcastItem(
  shortVersionString: shortVersion,
  version: build,
  minimumSystemVersion: minimum,
);

const _macos15 = SystemVersion([15, 1]);

AppcastItem? _decide(
  List<AppcastItem> items, {
  String installed = '1.2.3',
  String build = '7',
  SystemVersion? macos = _macos15,
}) => decideUpdate(
  items,
  installedVersion: installed,
  installedBuild: build,
  runningMacos: macos,
);

String? _offered(
  List<AppcastItem> items, {
  String installed = '1.2.3',
  String build = '7',
  SystemVersion? macos = _macos15,
}) {
  final item = _decide(items, installed: installed, build: build, macos: macos);
  return item == null ? null : '${item.shortVersionString}+${item.version}';
}

void main() {
  test(
    'the version decision offers only the newest item newer than the installed version',
    () {
      final v124 = _item('1.2.4', build: '8');
      final v130 = _item('1.3.0', build: '9');
      final v122 = _item('1.2.2', build: '6');

      expect(_decide([v124, v130]), same(v130));
      expect(_decide([v130, v124]), same(v130), reason: 'not list order');
      expect(_decide([v122, v130, v124]), same(v130));
      expect(_decide([v124, v122]), same(v124));
    },
  );

  test(
    'equal x.y.z falls back to the build number and never offers an equal or older build',
    () {
      // Installed 1.2.3+7.
      expect(_offered([_item('1.2.3', build: '8')]), '1.2.3+8');
      expect(_offered([_item('1.2.3', build: '7')]), isNull);
      expect(_offered([_item('1.2.2', build: '9')]), isNull);
      expect(
        _offered([
          _item('1.2.3', build: '7'),
          _item('1.2.2', build: '9'),
          _item('1.2.3', build: '8'),
        ]),
        '1.2.3+8',
      );

      // Of two items with the same x.y.z, the higher build wins.
      final b8 = _item('1.3.0', build: '8');
      final b9 = _item('1.3.0', build: '9');
      expect(_decide([b8, b9]), same(b9));
      expect(_decide([b9, b8]), same(b9));
    },
  );

  test('no item newer than the installed version means no offer', () {
    // Control: the decision offers a newer item at all.
    expect(_offered([_item('1.2.4', build: '8')]), '1.2.4+8');

    expect(_offered([]), isNull);
    expect(
      _offered([
        _item('1.2.3', build: '7'),
        _item('1.2.3', build: '6'),
        _item('1.2.2', build: '20'),
        _item('1.1.9', build: '30'),
        _item('0.9.0', build: '99'),
      ]),
      isNull,
      reason: 'no downgrade and no reinstall',
    );
  });

  test('each version part decides only when the parts before it are equal', () {
    // Installed 1.2.3+7.
    expect(_offered([_item('2.0.0')]), '2.0.0+1');
    expect(_offered([_item('1.3.0')]), '1.3.0+1');
    expect(_offered([_item('1.2.4')]), '1.2.4+1');
    expect(_offered([_item('0.9.9', build: '50')]), isNull);
    expect(_offered([_item('1.1.9', build: '50')]), isNull);
    expect(_offered([_item('1.2.2', build: '50')]), isNull);
    expect(
      _offered([_item('1.9.9', build: '3'), _item('2.0.0', build: '2')]),
      '2.0.0+2',
    );
    expect(
      _offered([_item('1.3.9', build: '3'), _item('1.4.0', build: '2')]),
      '1.4.0+2',
    );
    expect(
      _offered([_item('1.2.9', build: '3'), _item('1.2.10', build: '2')]),
      '1.2.10+2',
    );
  });

  test('versions and build numbers compare as numbers not as text', () {
    expect(_offered([_item('1.10.0')], installed: '1.9.0'), '1.10.0+1');
    expect(_offered([_item('1.9.0')], installed: '1.10.0'), isNull);
    expect(_offered([_item('1.2.3', build: '10')], build: '9'), '1.2.3+10');
    expect(_offered([_item('1.2.3', build: '9')], build: '10'), isNull);
  });

  test('an item whose short version is not x.y.z is never offered', () {
    expect(
      _offered([
        _item('1.3', build: '20'),
        _item('next', build: '21'),
        _item('1.2.4', build: '8'),
      ]),
      '1.2.4+8',
    );
  });

  test(
    'an item whose minimum macOS exceeds the running version is never offered and the newest eligible older item is',
    () {
      final items = [
        _item('1.4.0', build: '10', minimum: '15.0'),
        _item('1.3.0', build: '9', minimum: '14.0'),
        _item('1.2.4', build: '8'),
      ];

      expect(_offered(items, macos: const SystemVersion([14, 6])), '1.3.0+9');
      expect(
        _offered(items, macos: const SystemVersion([13, 7])),
        '1.2.4+8',
        reason: 'an item with no minimum has no limit',
      );
      expect(
        _offered(items, macos: const SystemVersion([15, 0])),
        '1.4.0+10',
        reason: 'a minimum equal to the running version is met',
      );
      expect(
        _offered([
          _item('1.4.0', build: '10', minimum: '15.0'),
        ], macos: const SystemVersion([14, 6])),
        isNull,
      );
    },
  );

  test('an item with no minimum macOS has no limit', () {
    expect(
      _offered([_item('1.3.0', build: '9')], macos: const SystemVersion([10])),
      '1.3.0+9',
    );
  });

  test('missing trailing parts of a macOS version count as zero', () {
    final macos151 = SystemVersion.tryParse('15.1');
    expect(macos151, isNotNull);
    expect(
      _offered([_item('1.3.0', minimum: '15.1.0')], macos: macos151),
      '1.3.0+1',
    );
    expect(
      _offered([_item('1.3.0', minimum: '15.1.1')], macos: macos151),
      isNull,
    );
    expect(
      _offered([_item('1.3.0', minimum: '15')], macos: macos151),
      '1.3.0+1',
    );
    expect(
      _offered([
        _item('1.3.0', minimum: '15'),
      ], macos: SystemVersion.tryParse('14.9')),
      isNull,
    );
  });

  test('an unknown running macOS version meets every minimum', () {
    expect(
      _offered([_item('1.3.0', build: '9', minimum: '99.0')], macos: null),
      '1.3.0+9',
    );
  });

  test('SystemVersion parses dotted numbers and orders them numerically', () {
    expect(SystemVersion.tryParse('15.1')?.parts, [15, 1]);
    expect(SystemVersion.tryParse('14.0')?.parts, [14, 0]);
    expect(SystemVersion.tryParse('14.6.1')?.parts, [14, 6, 1]);
    expect(SystemVersion.tryParse('15')?.parts, [15]);
    expect(SystemVersion.tryParse(''), isNull);
    expect(SystemVersion.tryParse('15.x'), isNull);
    expect(SystemVersion.tryParse('abc'), isNull);

    int cmp(String a, String b) =>
        SystemVersion.tryParse(a)!.compareTo(SystemVersion.tryParse(b)!).sign;
    expect(cmp('15.1', '15.1.0'), 0);
    expect(cmp('15.1', '15.2'), -1);
    expect(cmp('15.2', '15.1'), 1);
    expect(cmp('15.10', '15.9'), 1);
    expect(cmp('14.6.1', '15.0'), -1);
    expect(cmp('16', '15.9.9'), 1);
  });

  test(
    'runningMacosVersionProvider parses Version 15.1 (Build 24B83) as 15.1',
    () {
      expect(parseOperatingSystemVersion('Version 15.1 (Build 24B83)')?.parts, [
        15,
        1,
      ]);
      expect(
        parseOperatingSystemVersion('Version 14.6.1 (Build 23G93)')?.parts,
        [14, 6, 1],
      );
      expect(
        parseOperatingSystemVersion('Version 26.0 (Build 25A354)')?.parts,
        [26, 0],
      );

      // The provider parses this host's Platform.operatingSystemVersion.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final running = container.read(runningMacosVersionProvider);
      expect(
        running?.parts,
        parseOperatingSystemVersion(Platform.operatingSystemVersion)?.parts,
      );
      if (Platform.isMacOS) expect(running, isNotNull);
    },
  );

  test(
    'an unparseable operating system version counts as meeting every minimum',
    () {
      expect(parseOperatingSystemVersion(''), isNull);
      expect(parseOperatingSystemVersion('Darwin'), isNull);
      expect(parseOperatingSystemVersion('Version unknown'), isNull);

      final running = parseOperatingSystemVersion('Version unknown');
      expect(
        _offered([_item('1.3.0', build: '9', minimum: '14.0')], macos: running),
        '1.3.0+9',
      );
      // Control: a parsed version below the minimum is refused.
      expect(
        _offered([
          _item('1.3.0', build: '9', minimum: '14.0'),
        ], macos: parseOperatingSystemVersion('Version 13.7 (Build 22H123)')),
        isNull,
      );
    },
  );
}
