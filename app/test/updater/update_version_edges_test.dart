// WI #32 (Spec #31 req 9, D12a, D21): the version decision's documented
// edge rules: unknown builds, unparseable minimums, non-x.y.z versions,
// overflow, ties, and the macOS version parse anchors.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/appcast.dart';
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

void main() {
  test('an installed version that is not x.y.z gets no offer', () {
    final newer = _item('9.9.9', build: '99');

    expect(
      _decide([newer], installed: '1.2.3'),
      same(newer),
      reason: 'control',
    );
    expect(_decide([newer], installed: ''), isNull);
    expect(_decide([newer], installed: '1.2'), isNull);
    expect(_decide([newer], installed: '1.2.3.4'), isNull);
    expect(_decide([newer], installed: 'dev'), isNull);
    expect(_decide([newer], installed: '1.2.3-beta'), isNull);
  });

  test('an unknown installed build never makes an equal x.y.z newer', () {
    final same123 = _item('1.2.3', build: '8');
    final newer = _item('1.2.4', build: '1');

    // The build number is empty until main overrides it (D6).
    expect(_decide([same123], build: ''), isNull);
    expect(_decide([same123], build: 'abc'), isNull);
    expect(_decide([same123], build: '7'), same(same123), reason: 'control');

    // A newer x.y.z is still offered when the installed build is unknown.
    expect(_decide([same123, newer], build: ''), same(newer));
  });

  test('an item with an unknown build is not newer than an equal x.y.z', () {
    expect(_decide([_item('1.2.3', build: '')]), isNull);
    expect(_decide([_item('1.2.3', build: 'abc')]), isNull);
    expect(_decide([_item('1.2.3', build: '8')]), isNotNull, reason: 'control');

    // A newer x.y.z with an unknown build is still offered.
    final newer = _item('1.2.4', build: 'abc');
    expect(_decide([newer]), same(newer));
  });

  test(
    'between equal x.y.z candidates with an unknown build the first wins',
    () {
      final unknown = _item('1.3.0', build: 'abc');
      final known = _item('1.3.0', build: '9');

      expect(_decide([unknown, known]), same(unknown));
      expect(_decide([known, unknown]), same(known));
    },
  );

  test('between identical releases the first in document order wins', () {
    final first = _item('1.3.0', build: '9');
    final second = _item('1.3.0', build: '9');

    expect(_decide([first, second]), same(first));
    expect(_decide([second, first]), same(second));
  });

  test(
    'an unparseable minimum macOS is never offered unless macOS is unknown',
    () {
      final odd = _item('1.3.0', build: '9', minimum: 'soon');
      final older = _item('1.2.4', build: '8');

      expect(_decide([odd]), isNull);
      expect(_decide([odd, older]), same(older));
      expect(_decide([odd], macos: null), same(odd));
      for (final minimum in ['14.', '.14', '14.x', '-1', '14 0']) {
        expect(
          _decide([_item('1.3.0', build: '9', minimum: minimum)]),
          isNull,
          reason: minimum,
        );
      }
    },
  );

  test('version parts too large for an int are skipped not thrown', () {
    const huge = '99999999999999999999';

    expect(SystemVersion.tryParse('$huge.0'), isNull);
    expect(SystemVersion.tryParse('14.$huge'), isNull);

    final valid = _item('1.2.4', build: '8');
    expect(_decide([_item('1.2.$huge'), valid]), same(valid));
    expect(_decide([_item('$huge.0.0'), valid]), same(valid));
    expect(_decide([valid], installed: '1.2.$huge'), isNull);
    expect(
      _decide([_item('1.3.0', minimum: '$huge.0'), valid]),
      same(valid),
      reason: 'an overflowing minimum is unparseable',
    );
  });

  test('a build number too large for an int counts as unknown', () {
    expect(_decide([_item('1.2.3', build: '99999999999999999999')]), isNull);
    final newer = _item('1.2.4', build: '99999999999999999999');
    expect(_decide([newer]), same(newer));
  });

  test('the running macOS version is read only from a leading Version', () {
    SystemVersion? parse(String text) => parseOperatingSystemVersion(text);

    expect(parse('Version 15.1 (Build 24B83)')?.parts, [15, 1]);
    expect(parse('Version 15 (Build 24A1)')?.parts, [15]);
    expect(parse('Version 15.1')?.parts, [15, 1]);
    expect(parse('Version 14.6.1')?.parts, [14, 6, 1]);
    expect(parse('Version 15.x (Build 1)'), isNull);
    expect(parse('Version 15. (Build 1)'), isNull);
    expect(parse('Version  15.1'), isNull);
    expect(parse('Version 15.1.'), isNull);
    expect(parse('version 15.1'), isNull);
    expect(parse('Darwin Version 15.1'), isNull);
    expect(parse(' Version 15.1'), isNull);
  });

  test('SystemVersion orders by the most significant differing part', () {
    int cmp(List<int> a, List<int> b) =>
        SystemVersion(a).compareTo(SystemVersion(b)).sign;

    expect(cmp([15, 0], [14, 9, 9]), 1);
    expect(cmp([14, 9, 9], [15, 0]), -1);
    expect(cmp([15, 1], [15, 1, 0, 0]), 0);
    expect(cmp([15, 1], [15, 1, 0, 1]), -1);
    expect(cmp([15, 1, 0, 1], [15, 1]), 1);
    expect(cmp([15], [15, 0, 0]), 0);
    expect(SystemVersion.tryParse('15.1.0.0.1')?.parts, [15, 1, 0, 0, 1]);
  });
}
