// WI #32 (Spec #31 req 2, D12, D12a, D21): the Appcast parser.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/appcast.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_state.dart';
import 'package:open_memex_app/src/updater/update_version.dart';

import '../support/updater_fakes.dart';

const _release = 'https://github.com/connordodge/open_memex/releases';

Matcher get _throwsFeedUnreadable => throwsA(
  isA<UpdateFailure>().having(
    (f) => f.cause,
    'cause',
    UpdateErrorCause.feedUnreadable,
  ),
);

void main() {
  test('parsing a valid Appcast returns every item with all its fields', () {
    final items = parseAppcast(updaterFixture('appcast_valid.xml'));

    expect(items, hasLength(2));
    final first = items[0];
    final second = items[1];

    // Document order.
    expect(first.shortVersionString, '1.2.4');
    expect(first.version, '8');
    expect(first.notes, '## v1.2.4\n- Fixes a crash when a note is empty');
    expect(first.link, '$_release/tag/v1.2.4');
    expect(first.url, '$_release/download/v1.2.4/Open-Memex-1.2.4-arm64.dmg');
    expect(first.edSignature, 'c2lnbmF0dXJlLWZvci0xLjIuNA==');
    expect(first.length, 38123456);
    expect(first.minimumSystemVersion, '', reason: 'no minimum: empty');

    expect(second.shortVersionString, '1.3.0');
    expect(second.version, '9');
    expect(second.notes, '## v1.3.0\n- Self-update\n- Faster search');
    expect(second.link, '$_release/tag/v1.3.0');
    expect(second.url, '$_release/download/v1.3.0/Open-Memex-1.3.0-arm64.dmg');
    expect(second.edSignature, 'c2lnbmF0dXJlLWZvci0xLjMuMA==');
    expect(second.length, 38765432);
    expect(second.minimumSystemVersion, '14.0');
  });

  test(
    'notes split across two CDATA sections parse back to the end marker and keep the ampersand',
    () {
      final items = parseAppcast(updaterFixture('appcast_cdata_split.xml'));

      expect(items, hasLength(1));
      expect(
        items.single.notes,
        '## v1.3.0\n- Notes may hold ]]> now\n- Search & replace',
      );
    },
  );

  test('the parser ignores unknown elements and attributes', () {
    final items = parseAppcast(updaterFixture('appcast_unknown_fields.xml'));

    expect(items, hasLength(1));
    final item = items.single;
    expect(item.version, '9');
    expect(item.shortVersionString, '1.3.0');
    expect(item.notes, '## v1.3.0\n- Self-update');
    expect(item.link, '$_release/tag/v1.3.0');
    expect(item.url, '$_release/download/v1.3.0/Open-Memex-1.3.0-arm64.dmg');
    expect(item.edSignature, 'c2lnbmF0dXJlLWZvci0xLjMuMA==');
    expect(item.length, 38765432);
    expect(item.minimumSystemVersion, '14.0');
  });

  test(
    'the parser skips items missing a required field and keeps one missing only signature and length',
    () {
      final items = parseAppcast(updaterFixture('appcast_missing_fields.xml'));

      // Skipped: no sparkle:version (1.4.0), no shortVersionString (build
      // 11), no enclosure (1.4.2), an enclosure without url (1.4.3).
      expect(items.map((i) => i.shortVersionString), ['1.2.4', '1.3.0']);

      final unsigned = items[0];
      expect(unsigned.version, '8');
      expect(unsigned.edSignature, '', reason: 'no signature: empty');
      expect(unsigned.length, isNull, reason: 'no length: empty');
      expect(
        unsigned.url,
        '$_release/download/v1.2.4/Open-Memex-1.2.4-arm64.dmg',
      );

      final complete = items[1];
      expect(complete.edSignature, 'c2lnbmF0dXJlLWZvci0xLjMuMA==');
      expect(complete.length, 38765432);
    },
  );

  test('an enclosure with an empty url counts as lacking the url', () {
    final xml = updaterFixture(
      'appcast_valid.xml',
    ).replaceFirst(RegExp(r'url="[^"]*1\.2\.4[^"]*"'), 'url=""');

    final items = parseAppcast(xml);

    expect(items.map((i) => i.shortVersionString), ['1.3.0']);
  });

  test(
    'bad XML, a feed with no channel or a channel of only invalid items throws the feed unreadable failure',
    () {
      expect(
        () => parseAppcast(updaterFixture('appcast_bad_xml.xml')),
        _throwsFeedUnreadable,
      );
      expect(
        () => parseAppcast(updaterFixture('appcast_no_channel.xml')),
        _throwsFeedUnreadable,
      );
      expect(
        () => parseAppcast(updaterFixture('appcast_all_invalid.xml')),
        _throwsFeedUnreadable,
      );
    },
  );

  test('a body that is not XML at all throws the feed unreadable failure', () {
    expect(() => parseAppcast('Not Found'), _throwsFeedUnreadable);
    expect(() => parseAppcast(''), _throwsFeedUnreadable);
    expect(
      () => parseAppcast('<html><body>404</body></html>'),
      _throwsFeedUnreadable,
    );
  });

  test(
    'a channel with zero items parses to no items and the decision reads it as up to date',
    () {
      // Control: the parser reads items at all.
      expect(parseAppcast(updaterFixture('appcast_valid.xml')), isNotEmpty);

      // The gh-pages starting point (D12a): an empty channel.
      final items = parseAppcast(updaterFixture('appcast_empty_channel.xml'));

      expect(items, isEmpty);
      expect(
        decideUpdate(
          items,
          installedVersion: '1.2.3',
          installedBuild: '7',
          runningMacos: const SystemVersion([15, 1]),
        ),
        isNull,
      );
    },
  );
}
