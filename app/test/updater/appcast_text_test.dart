// WI #32 (Spec #31 req 2, D12): the Appcast parser's text and namespace
// contracts that the doc comments promise: scalar text trimmed, notes and
// attributes kept as written, a non-integer length read as null, sparkle
// fields matched by namespace, items read only as direct channel children.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/appcast.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

const _ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle';

String _feed(String items, {String declarations = 'xmlns:sparkle="$_ns"'}) =>
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<rss version="2.0" $declarations><channel>$items</channel></rss>';

String _item({
  String version = '<sparkle:version>8</sparkle:version>',
  String short =
      '<sparkle:shortVersionString>1.2.4</sparkle:shortVersionString>',
  String extra = '',
  String enclosure =
      '<enclosure url="https://example.test/a.dmg" '
      'sparkle:edSignature="c2ln" length="100"/>',
}) => '<item>$version$short$extra$enclosure</item>';

void main() {
  test('scalar element text is trimmed but notes are kept as written', () {
    final items = parseAppcast(
      _feed(
        _item(
          version: '<sparkle:version>\n  8 \n</sparkle:version>',
          short:
              '<sparkle:shortVersionString> 1.2.4\t</sparkle:shortVersionString>',
          extra:
              '<sparkle:minimumSystemVersion> 14.0 </sparkle:minimumSystemVersion>'
              '<link>\n  https://example.test/r\n</link>'
              '<description><![CDATA[\n  ## notes  \n]]></description>',
        ),
      ),
    );

    final item = items.single;
    expect(item.version, '8');
    expect(item.shortVersionString, '1.2.4');
    expect(item.minimumSystemVersion, '14.0');
    expect(item.link, 'https://example.test/r');
    expect(item.notes, '\n  ## notes  \n');
  });

  test('a version element of only whitespace counts as missing', () {
    final items = parseAppcast(
      _feed(
        _item(version: '<sparkle:version>  \n </sparkle:version>') +
            _item(
              short:
                  '<sparkle:shortVersionString> </sparkle:shortVersionString>',
            ) +
            _item(),
      ),
    );

    expect(items, hasLength(1));
    expect(items.single.shortVersionString, '1.2.4');
  });

  test('attributes are kept as written and a bad length reads as null', () {
    String lengthOf(String attribute) => parseAppcast(
      _feed(
        _item(
          enclosure: '<enclosure url="https://example.test/a.dmg" $attribute/>',
        ),
      ),
    ).single.length.toString();

    expect(lengthOf('length="38123456"'), '38123456');
    expect(lengthOf('length="12.5"'), 'null');
    expect(lengthOf('length="big"'), 'null');
    expect(lengthOf('length=""'), 'null');
    expect(lengthOf(''), 'null');

    final item = parseAppcast(
      _feed(
        _item(
          enclosure:
              '<enclosure url=" https://example.test/a.dmg " '
              'sparkle:edSignature=" c2ln " length="1"/>',
        ),
      ),
    ).single;
    expect(item.url, ' https://example.test/a.dmg ');
    expect(item.edSignature, ' c2ln ');
  });

  test('sparkle fields are matched by namespace not by prefix', () {
    final items = parseAppcast(
      _feed(
        '<item>'
        '<s:version>8</s:version>'
        '<s:shortVersionString>1.2.4</s:shortVersionString>'
        '<s:minimumSystemVersion>14.0</s:minimumSystemVersion>'
        '<enclosure url="https://example.test/a.dmg" s:edSignature="c2ln"/>'
        '</item>',
        declarations: 'xmlns:s="$_ns"',
      ),
    );

    final item = items.single;
    expect(item.version, '8');
    expect(item.shortVersionString, '1.2.4');
    expect(item.minimumSystemVersion, '14.0');
    expect(item.edSignature, 'c2ln');
  });

  test('elements and attributes outside the sparkle namespace are ignored', () {
    final items = parseAppcast(
      _feed(
        // A good control item first, then look-alikes.
        '${_item()}'
        '<item>'
        '<other:version>20</other:version>'
        '<other:shortVersionString>9.9.9</other:shortVersionString>'
        '<enclosure url="https://example.test/b.dmg"/>'
        '</item>'
        '<item>'
        '<version>21</version>'
        '<shortVersionString>9.9.8</shortVersionString>'
        '<enclosure url="https://example.test/c.dmg"/>'
        '</item>'
        '<item>'
        '<sparkle:version>22</sparkle:version>'
        '<sparkle:shortVersionString>9.9.7</sparkle:shortVersionString>'
        '<other:minimumSystemVersion>wrong</other:minimumSystemVersion>'
        '<enclosure url="https://example.test/d.dmg" '
        'other:edSignature="x" edSignature="y"/>'
        '</item>',
        declarations:
            'xmlns:sparkle="$_ns" xmlns:other="https://example.test/other"',
      ),
    );

    expect(items.map((i) => i.shortVersionString), ['1.2.4', '9.9.7']);
    final lookalike = items[1];
    // An edSignature in another namespace, or none, is not the signature.
    expect(lookalike.edSignature, '');
    expect(lookalike.minimumSystemVersion, '');
  });

  test('only items that are direct children of the channel are read', () {
    final items = parseAppcast(
      _feed(
        '<group>${_item()}</group>'
        '${_item(short: '<sparkle:shortVersionString>1.3.0</sparkle:shortVersionString>')}',
      ),
    );

    expect(items.map((i) => i.shortVersionString), ['1.3.0']);

    // A nested item alone is a channel with no items (up to date), not a
    // malformed feed.
    expect(parseAppcast(_feed('<group>${_item()}</group>')), isEmpty);
  });

  test('the channel is a child of the root element and nowhere deeper', () {
    expect(
      () => parseAppcast(
        '<rss xmlns:sparkle="$_ns"><wrap><channel>${_item()}</channel></wrap></rss>',
      ),
      throwsA(
        isA<UpdateFailure>().having(
          (f) => f.cause,
          'cause',
          UpdateErrorCause.feedUnreadable,
        ),
      ),
    );
    expect(parseAppcast(_feed(_item())), hasLength(1), reason: 'control');
  });

  test('the parsed item list is unmodifiable', () {
    final items = parseAppcast(_feed(_item()));

    expect(() => items.add(items.first), throwsUnsupportedError);
    expect(items.clear, throwsUnsupportedError);
    expect(
      () => parseAppcast(_feed('')).add(items.first),
      throwsUnsupportedError,
    );
  });

  test('an AppcastItem built from run-time values keeps every field', () {
    final length = int.parse('512');
    final item = AppcastItem(
      version: ['1', '1'].join(),
      shortVersionString: ['2', '0', '1'].join('.'),
      url: ['https:', '', 'example.test', 'x.dmg'].join('/'),
      notes: 'n' * 2,
      link: 'l' * 2,
      edSignature: 's' * 2,
      length: length,
      minimumSystemVersion: ['1', '4'].join('.'),
    );

    expect(item.version, '11');
    expect(item.shortVersionString, '2.0.1');
    expect(item.url, 'https://example.test/x.dmg');
    expect(item.notes, 'nn');
    expect(item.link, 'll');
    expect(item.edSignature, 'ss');
    expect(item.length, 512);
    expect(item.minimumSystemVersion, '1.4');

    const bare = AppcastItem(
      version: '1',
      shortVersionString: '1.0.0',
      url: 'u',
    );
    expect(bare.notes, '');
    expect(bare.link, '');
    expect(bare.edSignature, '');
    expect(bare.length, isNull);
    expect(bare.minimumSystemVersion, '');
  });
}
