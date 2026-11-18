// WI #36 (Spec #31 reqs 1-3, 8, D12, D21): scripts/release/generate_appcast.sh.
//
// The generator inserts or refreshes one Release's <item> in the gh-pages
// checkout's appcast.xml. Each test runs the real script with Process.run
// (runScript) in a temp fixture and checks exact exit codes.
//
// CLI the tests pin (the release.yml appcast job calls it the same way):
//
//   scripts/release/generate_appcast.sh --version <x.y.z> \
//     --input <dir> --appcast <file>
//
// - Run from the tag's checkout root: like check-version.sh it reads
//   app/pubspec.yaml (`version: <x.y.z>+<build>`), release-notes/v<x.y.z>.md
//   and the macOS deployment target (MACOSX_DEPLOYMENT_TARGET in
//   app/macos/Runner.xcodeproj/project.pbxproj) relative to the current
//   directory.
// - --input is the downloaded appcast-input artifact: it holds
//   Open-Memex-<x.y.z>-arm64.dmg.edsig and Open-Memex-<x.y.z>-arm64.dmg.length,
//   one line each (build.sh writes them with a trailing newline).
// - --appcast is the gh-pages checkout's appcast.xml. It must exist.
// - Exit 0 on success; exit 2 for a usage error (unknown or missing argument,
//   a version that is not x.y.z); exit 1 when an input is missing or bad.
//   Every failure prints a message naming the problem on stderr and leaves
//   the gh-pages checkout exactly as it was.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/appcast.dart';
import 'package:xml/xml.dart';

import 'support/script_harness.dart';

const _script = 'scripts/release/generate_appcast.sh';
const _releases = 'https://github.com/connordodge/open_memex/releases';
const _pbxproj = 'app/macos/Runner.xcodeproj/project.pbxproj';

String _fixture(String name) =>
    File('${repoRoot()}/app/test/fixtures/updater/$name').readAsStringSync();

String _dmg(String version) => 'Open-Memex-$version-arm64.dmg';

/// A tag checkout, an appcast-input directory and a gh-pages checkout.
class _Gen {
  _Gen(this.iso, this.repo, this.input, this.pages);

  final IsolatedEnv iso;
  final String repo;
  final String input;
  final String pages;

  String get appcast => '$pages/appcast.xml';

  /// Writes the pubspec version line, the notes and the appcast-input files
  /// for one Release.
  void release(
    String version, {
    String build = '42',
    String notes = '## Highlights\n- Something new\n',
    String edsig = 'c2lnbmF0dXJlLWZvci0xLjIuMw==\n',
    String length = '38123456\n',
  }) {
    File('$repo/app/pubspec.yaml').writeAsStringSync(
      'name: open_memex_app\n'
      'description: fixture\n'
      'version: $version+$build\n',
    );
    File('$repo/release-notes/v$version.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(notes);
    File('$input/${_dmg(version)}.edsig').writeAsStringSync(edsig);
    File('$input/${_dmg(version)}.length').writeAsStringSync(length);
  }

  Future<ScriptResult> run(
    String version, {
    List<String>? args,
    Map<String, String> env = const {},
  }) => runScript(
    _script,
    args ?? ['--version', version, '--input', input, '--appcast', appcast],
    workingDirectory: repo,
    env: {...iso.env, ...env},
  );

  /// Every file under the gh-pages checkout and its bytes, to show a failed
  /// run changed nothing.
  Map<String, String> pagesSnapshot() => {
    for (final f in Directory(pages).listSync(recursive: true))
      if (f is File) f.path: f.readAsStringSync(),
  };
}

Future<_Gen> _setUp({
  String? pbxproj,
  String seed = 'appcast_empty_channel.xml',
}) async {
  final iso = await isolatedEnv();
  final repo = Directory('${iso.work.path}/repo')..createSync();
  final input = Directory('${iso.work.path}/appcast-input')..createSync();
  final pages = Directory('${iso.work.path}/gh-pages')..createSync();
  File('${repo.path}/$_pbxproj')
    ..createSync(recursive: true)
    ..writeAsStringSync(
      pbxproj ?? File('${repoRoot()}/$_pbxproj').readAsStringSync(),
    );
  File('${pages.path}/.nojekyll').writeAsStringSync('');
  File('${pages.path}/appcast.xml').writeAsStringSync(_fixture(seed));
  final g = _Gen(iso, repo.path, input.path, pages.path);
  g.release('1.2.3');
  return g;
}

XmlDocument _doc(_Gen g) =>
    XmlDocument.parse(File(g.appcast).readAsStringSync());

List<XmlElement> _items(XmlDocument doc) =>
    doc.rootElement.getElement('channel')!.findElements('item').toList();

String _sp(XmlElement item, String name) =>
    item.getElement(name, namespaceUri: sparkleNamespace)?.innerText.trim() ??
    '';

List<XmlElement> _itemsFor(XmlDocument doc, String shortVersion) => [
  for (final i in _items(doc))
    if (_sp(i, 'shortVersionString') == shortVersion) i,
];

String _minimalPbxproj(String target) => [
  '// !\$*UTF8*\$!',
  '{',
  '\tobjects = {',
  for (final c in ['Debug', 'Release', 'Profile']) ...[
    '\t\tAAAA$c /* $c */ = {',
    '\t\t\tbuildSettings = {',
    '\t\t\t\tMACOSX_DEPLOYMENT_TARGET = $target;',
    '\t\t\t};',
    '\t\t\tname = $c;',
    '\t\t};',
  ],
  '\t};',
  '}',
  '',
].join('\n');

void main() {
  group('a new item', () {
    test(
      'on an empty channel the generator adds one item with the version, build number, notes, link, minimum system version and enclosure',
      () async {
        final g = await _setUp();
        const notes =
            '## Highlights\n- Self-update\n\n## Upgrade\nNo vault changes\n';
        g.release('1.2.3', build: '42', notes: notes);
        final r = await g.run(
          '1.2.3',
          // The URLs are fixed by the Spec, never taken from the run's repo.
          env: {'GITHUB_REPOSITORY': 'example-owner/example-repo'},
        );
        expect(r.exitCode, 0, reason: '$r');

        final doc = _doc(g);
        final items = _items(doc);
        expect(items, hasLength(1), reason: doc.toXmlString());
        final item = items.single;
        expect(_sp(item, 'version'), '42', reason: 'the pubspec build number');
        expect(_sp(item, 'shortVersionString'), '1.2.3');
        expect(item.getElement('description')!.innerText, notes);
        expect(
          item.getElement('link')!.innerText.trim(),
          '$_releases/tag/v1.2.3',
        );
        expect(_sp(item, 'minimumSystemVersion'), '14.0');
        final enclosure = item.getElement('enclosure')!;
        expect(
          enclosure.getAttribute('url'),
          '$_releases/download/v1.2.3/Open-Memex-1.2.3-arm64.dmg',
        );
        expect(
          enclosure.getAttribute('edSignature', namespaceUri: sparkleNamespace),
          'c2lnbmF0dXJlLWZvci0xLjIuMw==',
          reason: 'the .edsig line without its newline',
        );
        expect(
          enclosure.getAttribute('length'),
          '38123456',
          reason: 'the .length line without its newline',
        );
        expect(enclosure.getAttribute('type'), 'application/octet-stream');
        expect(
          doc.rootElement.getElement('channel')!.getElement('title')?.innerText,
          'Open Memex',
          reason: 'the channel metadata is kept',
        );
      },
    );

    test('the generator writes the notes in a CDATA section', () async {
      final g = await _setUp();
      g.release('1.2.3', notes: 'Search & replace <now>\n');
      final r = await g.run('1.2.3');
      expect(r.exitCode, 0, reason: '$r');
      final desc = _itemsFor(
        _doc(g),
        '1.2.3',
      ).single.getElement('description')!;
      final nodes = desc.children.where(
        (n) => n is! XmlText || n.value.trim().isNotEmpty,
      );
      expect(nodes, isNotEmpty);
      expect(
        nodes,
        everyElement(isA<XmlCDATA>()),
        reason: 'the raw Markdown sits in CDATA, not escaped text',
      );
    });

    test(
      'the generator reads the minimum system version from the macOS deployment target',
      () async {
        final g = await _setUp(pbxproj: _minimalPbxproj('13.5'));
        final r = await g.run('1.2.3');
        expect(r.exitCode, 0, reason: '$r');
        expect(
          _sp(_itemsFor(_doc(g), '1.2.3').single, 'minimumSystemVersion'),
          '13.5',
          reason: 'read from MACOSX_DEPLOYMENT_TARGET, not hard-coded',
        );
      },
    );
  });

  group('re-runs', () {
    test(
      'rerunning the generator for the same version replaces its item with the new values',
      () async {
        final g = await _setUp();
        final first = await g.run('1.2.3');
        expect(first.exitCode, 0, reason: '$first');
        g.release(
          '1.2.3',
          build: '43',
          notes: 'Rebuilt notes\n',
          edsig: 'bmV3LXNpZ25hdHVyZQ==\n',
          length: '40000001\n',
        );
        final second = await g.run('1.2.3');
        expect(second.exitCode, 0, reason: '$second');

        final doc = _doc(g);
        expect(_items(doc), hasLength(1), reason: doc.toXmlString());
        final item = _itemsFor(doc, '1.2.3').single;
        expect(_sp(item, 'version'), '43');
        expect(item.getElement('description')!.innerText, 'Rebuilt notes\n');
        final enclosure = item.getElement('enclosure')!;
        expect(
          enclosure.getAttribute('edSignature', namespaceUri: sparkleNamespace),
          'bmV3LXNpZ25hdHVyZQ==',
        );
        expect(enclosure.getAttribute('length'), '40000001');
      },
    );

    test(
      'the generator keys items on the short version so another Release with the same build number keeps its item',
      () async {
        final g = await _setUp();
        g.release('1.2.2', build: '42', edsig: 'b2xkZXI=\n', length: '1\n');
        expect((await g.run('1.2.2')).exitCode, 0);
        g.release('1.2.3', build: '42');
        final r = await g.run('1.2.3');
        expect(r.exitCode, 0, reason: '$r');
        final doc = _doc(g);
        expect(
          _itemsFor(doc, '1.2.2'),
          hasLength(1),
          reason: doc.toXmlString(),
        );
        expect(_itemsFor(doc, '1.2.3'), hasLength(1));
      },
    );

    test(
      'the generator matches the short version exactly so 1.2.30 keeps its item when 1.2.3 is generated',
      () async {
        final g = await _setUp();
        g.release('1.2.30', build: '40', edsig: 'b3RoZXI=\n', length: '2\n');
        expect((await g.run('1.2.30')).exitCode, 0);
        g.release('1.2.3', build: '41');
        expect((await g.run('1.2.3')).exitCode, 0);
        g.release('1.2.3', build: '42');
        final r = await g.run('1.2.3');
        expect(r.exitCode, 0, reason: '$r');
        final doc = _doc(g);
        expect(
          _itemsFor(doc, '1.2.30'),
          hasLength(1),
          reason: doc.toXmlString(),
        );
        expect(_itemsFor(doc, '1.2.3'), hasLength(1));
        expect(_sp(_itemsFor(doc, '1.2.3').single, 'version'), '42');
      },
    );

    test(
      'the generator replaces an existing item whose short version has surrounding white space',
      () async {
        final g = await _setUp();
        File(g.appcast).writeAsStringSync(
          _fixture('appcast_empty_channel.xml').replaceFirst(
            '  </channel>',
            '    <item>\n'
                '      <sparkle:version>41</sparkle:version>\n'
                '      <sparkle:shortVersionString>\n        1.2.3\n      </sparkle:shortVersionString>\n'
                '      <enclosure url="$_releases/download/v1.2.3/Open-Memex-1.2.3-arm64.dmg" sparkle:edSignature="b2xk" length="3" type="application/octet-stream"/>\n'
                '    </item>\n'
                '  </channel>',
          ),
        );
        final r = await g.run('1.2.3');
        expect(r.exitCode, 0, reason: '$r');
        final doc = _doc(g);
        expect(_items(doc), hasLength(1), reason: doc.toXmlString());
        expect(_sp(_items(doc).single, 'version'), '42');
      },
    );
  });

  group('other versions', () {
    test('generating a second version keeps the first version item', () async {
      final g = await _setUp();
      g.release('1.2.3', build: '42', notes: 'First\n');
      expect((await g.run('1.2.3')).exitCode, 0);
      g.release(
        '1.2.4',
        build: '43',
        notes: 'Second\n',
        edsig: 'c2Vjb25k\n',
        length: '777\n',
      );
      final r = await g.run('1.2.4');
      expect(r.exitCode, 0, reason: '$r');

      final doc = _doc(g);
      expect(_items(doc), hasLength(2), reason: doc.toXmlString());
      final first = _itemsFor(doc, '1.2.3').single;
      expect(_sp(first, 'version'), '42');
      expect(first.getElement('description')!.innerText, 'First\n');
      expect(
        first
            .getElement('enclosure')!
            .getAttribute('edSignature', namespaceUri: sparkleNamespace),
        'c2lnbmF0dXJlLWZvci0xLjIuMw==',
      );
      expect(first.getElement('enclosure')!.getAttribute('length'), '38123456');
      final second = _itemsFor(doc, '1.2.4').single;
      expect(_sp(second, 'version'), '43');
      expect(
        second.getElement('enclosure')!.getAttribute('url'),
        '$_releases/download/v1.2.4/Open-Memex-1.2.4-arm64.dmg',
      );
    });

    test(
      'generating a version keeps every other item in the feed with its unknown elements and notes',
      () async {
        final g = await _setUp();
        // A feed written by a later generator: the schema only grows (D12).
        File(g.appcast).writeAsStringSync(
          _fixture('appcast_valid.xml').replaceFirst(
            '<sparkle:version>8</sparkle:version>',
            '<sparkle:version>8</sparkle:version>\n'
                '      <sparkle:criticalUpdate sparkle:version="7"/>',
          ),
        );
        final before = parseAppcast(File(g.appcast).readAsStringSync());
        g.release('1.3.1', build: '10');
        final r = await g.run('1.3.1');
        expect(r.exitCode, 0, reason: '$r');

        final text = File(g.appcast).readAsStringSync();
        final after = parseAppcast(text);
        expect(after, hasLength(3));
        for (final old in before) {
          final kept = after
              .where((i) => i.shortVersionString == old.shortVersionString)
              .single;
          expect(kept.version, old.version);
          expect(kept.notes, old.notes);
          expect(kept.link, old.link);
          expect(kept.url, old.url);
          expect(kept.edSignature, old.edSignature);
          expect(kept.length, old.length);
          expect(kept.minimumSystemVersion, old.minimumSystemVersion);
        }
        final kept = _itemsFor(XmlDocument.parse(text), '1.2.4').single;
        expect(
          kept.getElement('criticalUpdate', namespaceUri: sparkleNamespace),
          isNotNull,
          reason: 'an element this generator does not know is kept',
        );
      },
    );
  });

  group('XML and notes', () {
    test(
      'the generator output is well-formed XML with the sparkle namespace on the root',
      () async {
        final g = await _setUp();
        final r = await g.run('1.2.3');
        expect(r.exitCode, 0, reason: '$r');
        final text = File(g.appcast).readAsStringSync();
        final doc = XmlDocument.parse(text);
        expect(doc.rootElement.name.local, 'rss');
        expect(doc.rootElement.getAttribute('xmlns:sparkle'), sparkleNamespace);
        expect(doc.rootElement.findElements('channel'), hasLength(1));
      },
    );

    test(
      'the generator splits a CDATA terminator in the notes across two CDATA sections',
      () async {
        final g = await _setUp();
        g.release('1.2.3', notes: 'a ]]> b\n');
        final r = await g.run('1.2.3');
        expect(r.exitCode, 0, reason: '$r');
        expect(
          File(g.appcast).readAsStringSync(),
          contains('a ]]]]><![CDATA[> b'),
        );
      },
    );

    for (final (name, notes) in [
      (
        'notes with a CDATA terminator and an ampersand come back unchanged',
        '## Highlights\n- Notes may hold ]]> now\n- Search & replace\n',
      ),
      ('notes ending in a CDATA terminator come back unchanged', 'Ends ]]>'),
      (
        'notes with repeated CDATA terminators come back unchanged',
        'a]]>]]>b ]]]> c ]]>\n',
      ),
      (
        'notes with markup, entities and non-ASCII text come back unchanged',
        '<b>bold</b> &amp; &lt; café — ✓\nline two\n\n',
      ),
    ]) {
      test(name, () async {
        final g = await _setUp();
        g.release('1.2.3', notes: notes);
        final r = await g.run('1.2.3');
        expect(r.exitCode, 0, reason: '$r');
        final item = _itemsFor(_doc(g), '1.2.3').single;
        expect(item.getElement('description')!.innerText, notes);
      });
    }

    test(
      'notes and feed text with shell syntax come back unchanged and are never run',
      () async {
        final g = await _setUp();
        const notes =
            r'$(touch pwned-notes) `touch pwned-tick` ${HOME} %s \n'
            '\n';
        File(g.appcast).writeAsStringSync(
          _fixture('appcast_empty_channel.xml').replaceFirst(
            '<title>Open Memex</title>',
            r'<title>Open Memex $(touch pwned-feed) `touch pwned-feed2`</title>',
          ),
        );
        g.release('1.2.3', notes: notes);
        final r = await g.run('1.2.3');
        expect(r.exitCode, 0, reason: '$r');
        final doc = _doc(g);
        expect(
          _itemsFor(doc, '1.2.3').single.getElement('description')!.innerText,
          notes,
        );
        expect(
          doc.rootElement.getElement('channel')!.getElement('title')!.innerText,
          r'Open Memex $(touch pwned-feed) `touch pwned-feed2`',
        );
        final pwned = g.iso.root
            .listSync(recursive: true)
            .where((f) => f.path.split('/').last.startsWith('pwned'));
        expect(pwned, isEmpty, reason: 'gh-pages and notes text is data');
      },
    );
  });

  group('the app parser reads the output', () {
    test(
      'the app Appcast parser reads the generator output back with every field',
      () async {
        final g = await _setUp();
        const notes = '## Highlights\n- Holds ]]> & more\n';
        g.release(
          '1.2.3',
          build: '42',
          notes: notes,
          edsig: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\n',
          length: '36600123\n',
        );
        final r = await g.run('1.2.3');
        expect(r.exitCode, 0, reason: '$r');
        final items = parseAppcast(File(g.appcast).readAsStringSync());
        expect(items, hasLength(1));
        final item = items.single;
        expect(item.shortVersionString, '1.2.3');
        expect(item.version, '42');
        expect(item.notes, notes);
        expect(item.link, '$_releases/tag/v1.2.3');
        expect(
          item.url,
          '$_releases/download/v1.2.3/Open-Memex-1.2.3-arm64.dmg',
        );
        expect(
          item.edSignature,
          'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
        );
        expect(item.length, 36600123);
        expect(item.minimumSystemVersion, '14.0');
      },
    );

    test(
      'the app Appcast parser reads every item after a version is added to a feed with other Releases',
      () async {
        final g = await _setUp(seed: 'appcast_valid.xml');
        g.release('1.3.1', build: '10', notes: 'Third\n');
        final r = await g.run('1.3.1');
        expect(r.exitCode, 0, reason: '$r');
        final items = parseAppcast(File(g.appcast).readAsStringSync());
        expect(
          items.map((i) => '${i.shortVersionString}+${i.version}').toSet(),
          {'1.2.4+8', '1.3.0+9', '1.3.1+10'},
        );
        final added = items.singleWhere((i) => i.shortVersionString == '1.3.1');
        expect(added.notes, 'Third\n');
        expect(added.minimumSystemVersion, '14.0');
      },
    );
  });

  group('failures change nothing', () {
    Future<void> expectRefused(
      _Gen g,
      ScriptResult r, {
      required int code,
      required Map<String, String> before,
      required String mentions,
    }) async {
      expect(r.exitCode, code, reason: '$r');
      expect(r.stderr, contains(mentions), reason: 'a clear message\n$r');
      expect(
        r.stderr,
        contains('generate_appcast:'),
        reason: 'the script own message, not an interpreter crash\n$r',
      );
      expect(
        r.stderr,
        isNot(contains('Traceback')),
        reason: 'a clear message, not a stack trace\n$r',
      );
      expect(g.pagesSnapshot(), before, reason: 'gh-pages is untouched');
    }

    for (final (name, file) in [
      (
        'the generator fails and changes nothing when the notes file is missing',
        'release-notes/v1.2.3.md',
      ),
      (
        'the generator fails and changes nothing when the edsig file is missing',
        'Open-Memex-1.2.3-arm64.dmg.edsig',
      ),
      (
        'the generator fails and changes nothing when the length file is missing',
        'Open-Memex-1.2.3-arm64.dmg.length',
      ),
    ]) {
      test(name, () async {
        final g = await _setUp();
        final path = file.startsWith('release-notes/')
            ? '${g.repo}/$file'
            : '${g.input}/$file';
        File(path).deleteSync();
        final before = g.pagesSnapshot();
        final r = await g.run('1.2.3');
        await expectRefused(
          g,
          r,
          code: 1,
          before: before,
          mentions: file.split('/').last,
        );
      });
    }

    for (final (name, edit, mentions) in [
      (
        'the generator fails and changes nothing when the edsig file is empty',
        (_Gen g) => File(
          '${g.input}/Open-Memex-1.2.3-arm64.dmg.edsig',
        ).writeAsStringSync('\n'),
        '.edsig',
      ),
      (
        'the generator fails and changes nothing when the length file is not a whole number',
        (_Gen g) => File(
          '${g.input}/Open-Memex-1.2.3-arm64.dmg.length',
        ).writeAsStringSync('12 MB\n'),
        '.length',
      ),
      (
        'the generator fails and changes nothing when the pubspec version does not match',
        (_Gen g) => File(
          '${g.repo}/app/pubspec.yaml',
        ).writeAsStringSync('name: open_memex_app\nversion: 1.2.4+42\n'),
        'pubspec',
      ),
      (
        'the generator fails and changes nothing when the pubspec version has no build number',
        (_Gen g) => File(
          '${g.repo}/app/pubspec.yaml',
        ).writeAsStringSync('name: open_memex_app\nversion: 1.2.3\n'),
        'build number',
      ),
      (
        'the generator fails and changes nothing when the deployment target is missing',
        (_Gen g) => File(
          '${g.repo}/$_pbxproj',
        ).writeAsStringSync('// !\$*UTF8*\$!\n{\n}\n'),
        'MACOSX_DEPLOYMENT_TARGET',
      ),
      (
        'the generator fails and changes nothing when the Appcast is not well-formed XML',
        (_Gen g) =>
            File(g.appcast).writeAsStringSync(_fixture('appcast_bad_xml.xml')),
        'appcast.xml',
      ),
      (
        'the generator fails and changes nothing when the Appcast has no channel',
        (_Gen g) => File(
          g.appcast,
        ).writeAsStringSync(_fixture('appcast_no_channel.xml')),
        'channel',
      ),
    ]) {
      test(name, () async {
        final g = await _setUp();
        edit(g);
        final before = g.pagesSnapshot();
        final r = await g.run('1.2.3');
        await expectRefused(g, r, code: 1, before: before, mentions: mentions);
      });
    }

    test(
      'the generator fails and creates nothing when the Appcast file is missing',
      () async {
        final g = await _setUp();
        File(g.appcast).deleteSync();
        final before = g.pagesSnapshot();
        final r = await g.run('1.2.3');
        await expectRefused(
          g,
          r,
          code: 1,
          before: before,
          mentions: 'appcast.xml',
        );
        expect(
          r.stderr,
          contains('gh-pages checkout'),
          reason: 'the message points at the missing checkout\n$r',
        );
      },
    );

    for (final (name, args) in [
      (
        'the generator exits 2 on a version with a leading v',
        ['--version', 'v1.2.3'],
      ),
      ('the generator exits 2 on a two-part version', ['--version', '1.2']),
      ('the generator exits 2 on an unknown argument', ['--channel', 'beta']),
      ('the generator exits 2 when --version is missing', <String>[]),
    ]) {
      test(name, () async {
        final g = await _setUp();
        final before = g.pagesSnapshot();
        final full = [
          ...args,
          if (!args.contains('--version') && args.isNotEmpty) ...[
            '--version',
            '1.2.3',
          ],
          '--input',
          g.input,
          '--appcast',
          g.appcast,
        ];
        final r = await g.run('1.2.3', args: full);
        expect(r.exitCode, 2, reason: '$r');
        expect(r.stderr.trim(), isNotEmpty, reason: 'a usage message\n$r');
        expect(g.pagesSnapshot(), before);
      });
    }

    for (final (name, drop) in [
      ('the generator exits 2 when --input is missing', '--input'),
      ('the generator exits 2 when --appcast is missing', '--appcast'),
    ]) {
      test(name, () async {
        final g = await _setUp();
        final before = g.pagesSnapshot();
        final pairs = {
          '--version': '1.2.3',
          '--input': g.input,
          '--appcast': g.appcast,
        }..remove(drop);
        final r = await g.run(
          '1.2.3',
          args: [
            for (final e in pairs.entries) ...[e.key, e.value],
          ],
        );
        expect(r.exitCode, 2, reason: '$r');
        expect(r.stderr, contains(drop), reason: '$r');
        expect(g.pagesSnapshot(), before);
      });
    }
  });

  group('guards that refuse and re-run stability', () {
    const header = '<?xml version="1.0" encoding="utf-8"?>\n';
    const ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle';

    for (final (name, feed, mentions) in [
      (
        'the generator fails and changes nothing when the Appcast root does not declare the sparkle namespace',
        '$header<rss version="2.0"><channel><title>Open Memex</title></channel></rss>\n',
        'xmlns:sparkle',
      ),
      (
        'the generator fails and changes nothing when the Appcast has two channels',
        '$header<rss version="2.0" xmlns:sparkle="$ns">'
            '<channel><title>A</title></channel>'
            '<channel><title>B</title></channel></rss>\n',
        'channel',
      ),
    ]) {
      test(name, () async {
        final g = await _setUp();
        File(g.appcast).writeAsStringSync(feed);
        final before = g.pagesSnapshot();
        final r = await g.run('1.2.3');
        expect(r.exitCode, 1, reason: '$r');
        expect(r.stderr, contains(mentions), reason: '$r');
        expect(g.pagesSnapshot(), before);
      });
    }

    test(
      'the generator fails and changes nothing when the deployment targets disagree',
      () async {
        final g = await _setUp();
        final pbx = File('${g.repo}/$_pbxproj');
        pbx.writeAsStringSync(
          pbx.readAsStringSync().replaceFirst(
            'MACOSX_DEPLOYMENT_TARGET = 14.0;',
            'MACOSX_DEPLOYMENT_TARGET = 15.0;',
          ),
        );
        final before = g.pagesSnapshot();
        final r = await g.run('1.2.3');
        expect(r.exitCode, 1, reason: '$r');
        expect(r.stderr, contains('MACOSX_DEPLOYMENT_TARGET'), reason: '$r');
        expect(g.pagesSnapshot(), before);
      },
    );

    test(
      'the generator fails and changes nothing when the notes hold a character XML forbids',
      () async {
        final g = await _setUp();
        g.release('1.2.3', notes: 'Bad \u0001 control character\n');
        final before = g.pagesSnapshot();
        final r = await g.run('1.2.3');
        expect(r.exitCode, 1, reason: '$r');
        expect(r.stderr, contains('well-formed'), reason: '$r');
        expect(g.pagesSnapshot(), before);
      },
    );

    test(
      'the generator fails and changes nothing when the edsig file is not base64',
      () async {
        final g = await _setUp();
        g.release('1.2.3', edsig: 'not a signature!\n');
        final before = g.pagesSnapshot();
        final r = await g.run('1.2.3');
        expect(r.exitCode, 1, reason: '$r');
        expect(r.stderr, contains('.edsig'), reason: '$r');
        expect(g.pagesSnapshot(), before);
      },
    );

    test(
      'the generator exits 2 when an option is given without a value',
      () async {
        final g = await _setUp();
        final before = g.pagesSnapshot();
        final r = await g.run(
          '1.2.3',
          args: ['--input', g.input, '--appcast', g.appcast, '--version'],
        );
        expect(r.exitCode, 2, reason: '$r');
        expect(r.stderr, contains('--version'), reason: '$r');
        expect(g.pagesSnapshot(), before);
      },
    );

    test(
      'the generator reads a quoted pubspec version with a trailing comment and a quoted deployment target',
      () async {
        final g = await _setUp(pbxproj: _minimalPbxproj('"14.0"'));
        File('${g.repo}/app/pubspec.yaml').writeAsStringSync(
          'name: open_memex_app\nversion: "1.2.3+77"   # the build\n',
        );
        final r = await g.run('1.2.3');
        expect(r.exitCode, 0, reason: '$r');
        final item = _itemsFor(_doc(g), '1.2.3').single;
        expect(_sp(item, 'version'), '77');
        expect(_sp(item, 'minimumSystemVersion'), '14.0');
      },
    );

    test(
      'rerunning the generator with the same inputs leaves a byte identical file',
      () async {
        final g = await _setUp();
        File(g.appcast).writeAsStringSync(_fixture('appcast_valid.xml'));
        expect((await g.run('1.2.3')).exitCode, 0);
        final once = File(g.appcast).readAsStringSync();
        final r = await g.run('1.2.3');
        expect(r.exitCode, 0, reason: '$r');
        expect(
          File(g.appcast).readAsStringSync(),
          once,
          reason: 'the appcast job relies on this to push nothing',
        );
      },
    );

    test(
      'generating a version collapses duplicate items for it and keeps the other versions',
      () async {
        final g = await _setUp();
        String item(String short, String build) =>
            '    <item>\n'
            '      <sparkle:version>$build</sparkle:version>\n'
            '      <sparkle:shortVersionString>$short</sparkle:shortVersionString>\n'
            '      <enclosure url="https://example.test/$short.dmg" sparkle:edSignature="c2ln" length="1" type="application/octet-stream"/>\n'
            '    </item>\n';
        File(g.appcast).writeAsStringSync(
          '$header<rss version="2.0" xmlns:sparkle="$ns">\n  <channel>\n'
          '    <title>Open Memex</title>\n'
          '${item('1.2.3', '5')}${item('1.2.2', '4')}${item('1.2.3', '6')}'
          '  </channel>\n</rss>\n',
        );
        g.release('1.2.3', build: '9');
        final r = await g.run('1.2.3');
        expect(r.exitCode, 0, reason: '$r');
        final doc = _doc(g);
        expect(_items(doc), hasLength(2), reason: doc.toXmlString());
        expect(_sp(_itemsFor(doc, '1.2.3').single, 'version'), '9');
        expect(_sp(_itemsFor(doc, '1.2.2').single, 'version'), '4');
      },
    );
  });
}
