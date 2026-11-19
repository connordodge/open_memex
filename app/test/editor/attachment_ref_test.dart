// WI #141 (Spec #123 V1; R3, R4, R31, R32, R33): the Dart mirror of the
// attachment reference grammar and tables in
// `crates/memex-core/src/attachments.rs`, pinned by the shared fixture table
// `test/fixtures/attachments/refs.json` (D18). Every row is read.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/attachment_ref.dart';

/// `flutter test` runs with the package root (`app/`) as cwd.
const _fixturePath = 'test/fixtures/attachments/refs.json';
const _rustPath = '../crates/memex-core/src/attachments.rs';

const _hash =
    '66bc7611813b7443f25c4af21004864b3975eb83fb7c74be572b9d6aa74bd462';
const _dir = 'objects/66/$_hash';

Map<String, Object?> _fixture() =>
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> _rows(String key) => [
  for (final row in (_fixture()[key]! as List)) row as Map<String, Object?>,
];

/// The quoted strings of the Rust `const <name>: &[&str] = &[ … ];`.
List<String> _rustTable(String name) {
  final source = File(_rustPath).readAsStringSync();
  final body = RegExp(
    '$name: &\\[&str\\] = &\\[(.*?)\\];',
    dotAll: true,
  ).firstMatch(source);
  expect(body, isNotNull, reason: '$name found in $_rustPath');
  return [
    for (final m in RegExp(r'"([^"]*)"').allMatches(body!.group(1)!))
      m.group(1)!,
  ];
}

/// [value], failing the test by assertion when it is null.
T _some<T extends Object>(T? value) {
  expect(value, isNotNull);
  return value!;
}

void main() {
  group('reference grammar (R4)', () {
    test('parseAttachmentReference matches every refs json reference row', () {
      final rows = _rows('references');
      expect(rows, hasLength(34), reason: 'every fixture row is read');
      final wrong = <String>[];
      for (final row in rows) {
        final markdown = row['markdown']! as String;
        final got = parseAttachmentReference(markdown);
        if (row['valid']! as bool) {
          final kind = row['kind'] == 'image'
              ? AttachmentRefKind.image
              : AttachmentRefKind.link;
          final path = row['path']! as String;
          final ok =
              got != null &&
              got.kind == kind &&
              got.target.path == path &&
              got.target.name == row['name'] &&
              got.target.hash == path.split('/')[2];
          if (!ok) wrong.add('accept: ${row['why']} :: $markdown');
        } else if (got != null) {
          wrong.add('reject: ${row['why']} :: $markdown');
        }
      }
      expect(wrong, isEmpty);
    });

    test(
      'parseAttachmentReference takes the name from the path for empty text',
      () {
        final ref = _some(parseAttachmentReference('[]($_dir/notes.txt)'));
        expect(ref.kind, AttachmentRefKind.link);
        expect(ref.target.name, 'notes.txt');
        expect(ref.target.path, '$_dir/notes.txt');
        expect(ref.target.hash, _hash);
      },
    );

    test(
      'parseAttachmentReference ends the text at the first unescaped bracket',
      () {
        // An escaped bracket and an escaped backslash stay in the text.
        expect(
          parseAttachmentReference(
            r'[a\]b]('
            '$_dir/x.txt)',
          ),
          isNotNull,
        );
        expect(
          parseAttachmentReference(
            r'[a\\]('
            '$_dir/x.txt)',
          ),
          isNotNull,
        );
        // An unescaped `[` in the text is allowed.
        expect(parseAttachmentReference('[a[b]($_dir/x.txt)'), isNotNull);
        // An unescaped `]` ends the text, and `(` must follow it.
        expect(parseAttachmentReference('[a]b]($_dir/x.txt)'), isNull);
        // A text that never closes is not a reference.
        expect(parseAttachmentReference(r'[a\'), isNull);
        expect(parseAttachmentReference('[a'), isNull);
        expect(parseAttachmentReference(''), isNull);
        expect(parseAttachmentReference('!'), isNull);
        expect(parseAttachmentReference('!['), isNull);
      },
    );

    test(
      'parseAttachmentReference refuses whitespace and parentheses in the destination',
      () {
        expect(parseAttachmentReference('[x]($_dir/a b.txt)'), isNull);
        expect(parseAttachmentReference('[x]($_dir/a\tb.txt)'), isNull);
        expect(parseAttachmentReference('[x]($_dir/a(b.txt)'), isNull);
        expect(parseAttachmentReference('[x]($_dir/a)b.txt)'), isNull);
        expect(parseAttachmentReference('[x]($_dir/a%28b%29.txt)'), isNotNull);
        expect(parseAttachmentReference('[x]($_dir/x.txt)\r'), isNull);
        expect(parseAttachmentReference('[x]($_dir/x.txt)\n'), isNull);
      },
    );

    test(
      'parseAttachmentReference refuses every Unicode whitespace code point in the destination',
      () {
        const whitespace = [
          0x09,
          0x0B,
          0x0C,
          0x20,
          0x85,
          0xA0,
          0x1680,
          0x2000,
          0x2005,
          0x200A,
          0x2028,
          0x2029,
          0x202F,
          0x205F,
          0x3000,
        ];
        // Neighbours of each range that Rust does not treat as whitespace.
        const notWhitespace = [
          0x08,
          0x0E,
          0x1F,
          0x21,
          0x84,
          0x86,
          0xA1,
          0x167F,
          0x1681,
          0x1FFF,
          0x200B,
          0x2027,
          0x202A,
          0x202E,
          0x2030,
          0x205E,
          0x2060,
          0x2FFF,
          0x3001,
          0xFEFF,
        ];
        final accepted = [
          for (final cp in whitespace)
            if (parseAttachmentReference(
                  '[x]($_dir/a${String.fromCharCode(cp)}b.txt)',
                ) !=
                null)
              cp.toRadixString(16),
        ];
        final refused = [
          for (final cp in notWhitespace)
            if (parseAttachmentReference(
                  '[x]($_dir/a${String.fromCharCode(cp)}b.txt)',
                ) ==
                null)
              cp.toRadixString(16),
        ];
        expect(accepted, isEmpty, reason: 'whitespace refused');
        expect(refused, isEmpty, reason: 'non whitespace accepted');
      },
    );

    test(
      'parseAttachmentReference refuses a carriage return or line feed in the text',
      () {
        expect(parseAttachmentReference('[a b]($_dir/x.txt)'), isNotNull);
        expect(parseAttachmentReference('[a\nb]($_dir/x.txt)'), isNull);
        expect(parseAttachmentReference('[a\rb]($_dir/x.txt)'), isNull);
        expect(parseAttachmentReference('![a\rb]($_dir/x.png)'), isNull);
      },
    );

    test('parseAttachmentReference reads the image form as image', () {
      final ref = _some(parseAttachmentReference('![x]($_dir/x.png)'));
      expect(ref.kind, AttachmentRefKind.image);
      expect(ref.target.name, 'x.png');
      expect(
        _some(parseAttachmentReference('[x]($_dir/x.png)')).kind,
        AttachmentRefKind.link,
      );
    });

    test(
      'parseAttachmentDestination decodes percent escapes in either hex case',
      () {
        final upper = _some(parseAttachmentDestination('$_dir/caf%C3%A9.txt'));
        final lower = _some(parseAttachmentDestination('$_dir/caf%c3%a9.txt'));
        for (final got in [upper, lower]) {
          expect(got.name, 'café.txt');
          expect(got.path, '$_dir/café.txt');
          expect(got.hash, _hash);
        }
        expect(
          _some(parseAttachmentDestination('$_dir/100%25.txt')).name,
          '100%.txt',
        );
        expect(
          _some(parseAttachmentDestination('$_dir/a%20b.txt')).name,
          'a b.txt',
        );
        expect(_some(parseAttachmentDestination('$_dir/x.txt')).name, 'x.txt');
      },
    );

    test(
      'parseAttachmentDestination refuses a bad percent escape or invalid UTF-8',
      () {
        // Control: the same shape with a good escape is accepted.
        expect(parseAttachmentDestination('$_dir/100%25.txt'), isNotNull);
        expect(parseAttachmentDestination('$_dir/100%.txt'), isNull);
        expect(parseAttachmentDestination('$_dir/a%zz.txt'), isNull);
        expect(parseAttachmentDestination('$_dir/a%2'), isNull);
        expect(parseAttachmentDestination('$_dir/a%'), isNull);
        expect(parseAttachmentDestination('$_dir/a%FF.txt'), isNull);
        expect(parseAttachmentDestination('$_dir/%2E%2E'), isNull);
        expect(parseAttachmentDestination('$_dir/a%2Fb.txt'), isNull);
        expect(parseAttachmentDestination('https://example.com/x.pdf'), isNull);
        expect(parseAttachmentDestination(''), isNull);
      },
    );

    test(
      'parseAttachmentDestination decodes only hex digits after a percent sign',
      () {
        // Every hex digit, both cases, in both positions of an escape.
        expect(
          _some(
            parseAttachmentDestination(
              '$_dir/a%F0%9F%98%80%c3%a9%C3%A9%09%7A%00',
            ),
          ).name,
          'a😀éé\t'
          'z\u0000',
        );
        final accepted = <String>[];
        for (final c in ['/', ':', '@', '`', 'g', 'G']) {
          if (parseAttachmentDestination('$_dir/a%4${c}b') != null) {
            accepted.add('lo $c');
          }
          if (parseAttachmentDestination('$_dir/a%${c}1b') != null) {
            accepted.add('hi $c');
          }
        }
        expect(accepted, isEmpty);
      },
    );

    test(
      'parseAttachmentDestination refuses a leading byte order mark like Rust',
      () {
        // Control: the same destination without the mark is accepted.
        expect(parseAttachmentDestination('$_dir/x.png'), isNotNull);
        // Percent-encoded BOM bytes in front of the path.
        expect(parseAttachmentDestination('%EF%BB%BF$_dir/x.png'), isNull);
        expect(parseAttachmentDestination('%ef%bb%bf$_dir/x.png'), isNull);
        // A literal U+FEFF in front of the path.
        expect(parseAttachmentDestination('\uFEFF$_dir/x.png'), isNull);
        expect(
          parseAttachmentReference('![x.png](%EF%BB%BF$_dir/x.png)'),
          isNull,
        );
        // Only a leading mark is refused: one inside the name is kept.
        expect(
          _some(parseAttachmentDestination('$_dir/a%EF%BB%BFb.png')).name,
          'a\uFEFFb.png',
        );
      },
    );

    test('parseAttachmentDestination decodes an escape at the very end', () {
      expect(_some(parseAttachmentDestination('$_dir/100%25')).name, '100%');
      expect(_some(parseAttachmentDestination('$_dir/a%41')).name, 'aA');
    });

    test('parseAttachmentPath accepts a decoded path and keeps it as is', () {
      final got = _some(parseAttachmentPath('$_dir/100%.txt'));
      expect(got.path, '$_dir/100%.txt');
      expect(got.name, '100%.txt');
      expect(got.hash, _hash);
      // A decoded path is never decoded again.
      expect(_some(parseAttachmentPath('$_dir/%2E%2E')).name, '%2E%2E');
      expect(
        _some(parseAttachmentPath('$_dir/a b [c].txt')).name,
        'a b [c].txt',
      );
      expect(_some(parseAttachmentPath('$_dir/.hidden')).name, '.hidden');
    });

    test('parseAttachmentPath refuses a path cut short before the name', () {
      expect(parseAttachmentPath('$_dir/x.txt'), isNotNull);
      for (final path in [
        'objects',
        'objects/',
        'objects/66',
        'objects/66/',
        'objects/66/$_hash',
        'objects//$_hash/x.txt',
      ]) {
        expect(parseAttachmentPath(path), isNull, reason: path);
      }
    });

    test(
      'parseAttachmentPath accepts only lowercase hex digits in the hash',
      () {
        final head = _hash.substring(0, 63);
        for (final c in ['0', '9', 'a', 'f']) {
          expect(
            parseAttachmentPath('objects/66/$head$c/x.txt'),
            isNotNull,
            reason: c,
          );
        }
        for (final c in ['/', ':', '@', '`', 'g', 'G', 'A', 'F']) {
          expect(
            parseAttachmentPath('objects/66/$head$c/x.txt'),
            isNull,
            reason: c,
          );
        }
      },
    );

    test('parseAttachmentPath refuses every malformed path', () {
      final bad = <String, String>{
        'not objects': 'notes/66/$_hash/x.txt',
        'Objects': 'Objects/66/$_hash/x.txt',
        'leading slash': '/$_dir/x.txt',
        'leading dot slash': './$_dir/x.txt',
        'no prefix slash': 'objects66/$_hash/x.txt',
        'uppercase hash': 'objects/66/${_hash.toUpperCase()}/x.txt',
        'h2 mismatch': 'objects/67/$_hash/x.txt',
        'short h2': 'objects/6/$_hash/x.txt',
        'long h2': 'objects/666/$_hash/x.txt',
        '63 hex': 'objects/66/${_hash.substring(1)}/x.txt',
        '65 hex': 'objects/66/${_hash}0/x.txt',
        'non hex': 'objects/66/${_hash.substring(0, 63)}g/x.txt',
        'empty name': '$_dir/',
        'no name': _dir,
        'dot name': '$_dir/.',
        'dotdot name': '$_dir/..',
        'deep name': '$_dir/a/b.txt',
        'empty': '',
      };
      // Control: the well-formed path is accepted.
      expect(parseAttachmentPath('$_dir/x.txt'), isNotNull);
      final accepted = [
        for (final e in bad.entries)
          if (parseAttachmentPath(e.value) != null) e.key,
      ];
      expect(accepted, isEmpty);
    });
  });

  group('encoding (R3)', () {
    test('encodeAttachmentName produces every refs json encode row', () {
      final rows = _rows('encode');
      expect(rows, hasLength(22), reason: 'every fixture row is read');
      final wrong = <String>[];
      for (final row in rows) {
        final name = row['name']! as String;
        final got = encodeAttachmentName(name);
        if (got != row['encoded_name']) wrong.add('$name -> $got');
      }
      expect(wrong, isEmpty);
    });

    test('attachmentMarkdown produces every refs json encode row markdown', () {
      final wrong = <String>[];
      for (final row in _rows('encode')) {
        final name = row['name']! as String;
        final got = attachmentMarkdown(name, row['hash']! as String);
        if (got != row['markdown']) wrong.add('$name -> $got');
      }
      expect(wrong, isEmpty);
    });

    test('attachmentMarkdown output parses back to the same name and form', () {
      final rows = _rows('encode');
      final wrong = <String>[];
      for (final row in rows) {
        final name = row['name']! as String;
        final hash = row['hash']! as String;
        final ref = parseAttachmentReference(attachmentMarkdown(name, hash));
        final kind = row['kind'] == 'image'
            ? AttachmentRefKind.image
            : AttachmentRefKind.link;
        final ok =
            ref != null &&
            ref.kind == kind &&
            ref.target.name == name &&
            ref.target.hash == hash &&
            ref.target.path == 'objects/${hash.substring(0, 2)}/$hash/$name';
        if (!ok) wrong.add(name);
      }
      expect(wrong, isEmpty);
    });

    test(
      'encodeAttachmentName keeps exactly the unreserved ASCII characters',
      () {
        final unreserved = RegExp(r'[A-Za-z0-9\-._~]');
        final wrong = <String>[];
        for (var code = 0; code < 128; code++) {
          final c = String.fromCharCode(code);
          final want = unreserved.hasMatch(c)
              ? c
              : '%${code.toRadixString(16).toUpperCase().padLeft(2, '0')}';
          if (encodeAttachmentName(c) != want) wrong.add('$code');
        }
        expect(wrong, isEmpty);
      },
    );

    test(
      'encodeAttachmentName encodes every UTF-8 byte with uppercase hex',
      () {
        expect(encodeAttachmentName('é'), '%C3%A9');
        expect(encodeAttachmentName('😀'), '%F0%9F%98%80');
        expect(encodeAttachmentName(''), '');
      },
    );

    test('attachmentMarkdown escapes brackets and backslashes in the text', () {
      expect(
        attachmentMarkdown('a[b]c\\d.txt', _hash),
        '[a\\[b\\]c\\\\d.txt]($_dir/a%5Bb%5Dc%5Cd.txt)',
      );
    });

    test('attachmentMarkdown uses the image form only for inline types', () {
      expect(attachmentMarkdown('a.png', _hash), startsWith('!['));
      expect(attachmentMarkdown('a.PNG', _hash), startsWith('!['));
      expect(attachmentMarkdown('a.pdf', _hash), startsWith('[a.pdf]'));
      expect(attachmentMarkdown('a.svg', _hash), startsWith('[a.svg]'));
    });
  });

  group('types (R31, R33)', () {
    test('inlineImageExtensions equals the Rust table', () {
      expect(inlineImageExtensions, ['png', 'jpg', 'jpeg', 'gif', 'webp']);
      expect(inlineImageExtensions, _rustTable('INLINE_IMAGE_EXTENSIONS'));
    });

    test('executableExtensions equals the Rust table', () {
      expect(executableExtensions, [
        'command',
        'tool',
        'terminal',
        'sh',
        'zsh',
        'bash',
        'py',
        'rb',
        'pl',
        'pkg',
        'mpkg',
        'dmg',
        'app',
        'workflow',
        'scpt',
        'applescript',
        'jar',
        'exe',
      ]);
      expect(executableExtensions, _rustTable('EXECUTABLE_EXTENSIONS'));
    });

    test('isInlineImageName accepts the five types in any letter case', () {
      final wrong = <String>[];
      for (final ext in ['png', 'jpg', 'jpeg', 'gif', 'webp']) {
        for (final e in [
          ext,
          ext.toUpperCase(),
          ext[0].toUpperCase() + ext.substring(1),
        ]) {
          if (!isInlineImageName('pic.$e')) wrong.add(e);
        }
      }
      expect(wrong, isEmpty);
      expect(isInlineImageName('PHOTO.JPG'), isTrue);
      expect(isInlineImageName('anim.GiF'), isTrue);
    });

    test('isInlineImageName refuses every other type', () {
      // Control: a name of an inline type is accepted.
      expect(isInlineImageName('x.png'), isTrue);
      for (final name in [
        'photo.heic',
        'logo.svg',
        'scan.tiff',
        'scan.tif',
        'pic.bmp',
        'doc.pdf',
        'x.png.txt',
        'png',
        'pic.pn',
        'pic.pngx',
        'archive.tar.gz',
        'trailing.',
        '',
      ]) {
        expect(isInlineImageName(name), isFalse, reason: name);
      }
    });

    test('isExecutableName matches every refs json executable row', () {
      final rows = _rows('executable');
      expect(rows, hasLength(25), reason: 'every fixture row is read');
      final wrong = <String>[];
      for (final row in rows) {
        final name = row['name']! as String;
        if (isExecutableName(name) != row['executable']) {
          wrong.add('$name: ${row['why']}');
        }
      }
      expect(wrong, isEmpty);
    });

    test(
      'isExecutableName covers every table extension in any letter case',
      () {
        final wrong = <String>[];
        for (final ext in executableExtensions) {
          for (final e in [ext, ext.toUpperCase()]) {
            if (!isExecutableName('file.$e')) wrong.add(e);
          }
        }
        expect(wrong, isEmpty);
        expect(executableExtensions, isNotEmpty);
      },
    );

    test('extension matching folds ASCII letters only like Rust', () {
      // U+212A KELVIN SIGN lower-cases to k in Dart but is not ASCII.
      expect(isExecutableName('x.wor\u212Aflow'), isFalse);
      expect(isExecutableName('x.worKflow'), isTrue);
      expect(isExecutableName('x.\u212Aflow'), isFalse);
      expect(isInlineImageName('x.p\u212Ang'), isFalse);
      expect(isInlineImageName('x.\u0130mg'), isFalse);
    });

    test('an extension is what follows the last dot, even for a dotfile', () {
      // The Rust core: `extension` is what follows a name's last `.`.
      expect(isExecutableName('.sh'), isTrue);
      expect(isInlineImageName('.png'), isTrue);
      expect(isExecutableName('sh'), isFalse);
      expect(isExecutableName('trailing.'), isFalse);
    });
  });

  group('size and type labels (R32)', () {
    test('formatAttachmentSize shows bytes under 1 KB', () {
      expect(formatAttachmentSize(0), '0 B');
      expect(formatAttachmentSize(1), '1 B');
      expect(formatAttachmentSize(512), '512 B');
      expect(formatAttachmentSize(1023), '1023 B');
    });

    test('formatAttachmentSize shows whole KB from 1024 bytes up to 1 MB', () {
      expect(formatAttachmentSize(1024), '1 KB');
      expect(formatAttachmentSize(1500), '1 KB');
      expect(formatAttachmentSize(1600), '2 KB');
      expect(formatAttachmentSize(812 * 1024), '812 KB');
      expect(formatAttachmentSize(1048000), '1023 KB');
    });

    test('formatAttachmentSize shows MB with one decimal from 1 MB', () {
      expect(formatAttachmentSize(1048576), '1.0 MB');
      expect(formatAttachmentSize(1099776), '1.0 MB');
      expect(formatAttachmentSize(1572864), '1.5 MB');
      expect(formatAttachmentSize(4404019), '4.2 MB');
      expect(formatAttachmentSize(2055209), '2.0 MB');
      expect(formatAttachmentSize(104857600), '100.0 MB');
      expect(formatAttachmentSize(1073741824), '1024.0 MB');
    });

    test('attachmentTypeLabel is the upper-case extension or FILE', () {
      expect(attachmentTypeLabel('Q3 report.pdf'), 'PDF');
      expect(attachmentTypeLabel('photo.JPG'), 'JPG');
      expect(attachmentTypeLabel('photo.jpeg'), 'JPEG');
      expect(attachmentTypeLabel('archive.tar.gz'), 'GZ');
      expect(attachmentTypeLabel('x.png.txt'), 'TXT');
      expect(attachmentTypeLabel('notes.Md'), 'MD');
      expect(attachmentTypeLabel('no extension'), 'FILE');
      expect(attachmentTypeLabel('png'), 'FILE');
    });

    test('attachmentTypeLabel is FILE when nothing follows the last dot', () {
      expect(attachmentTypeLabel('report.'), 'FILE');
      expect(attachmentTypeLabel('a.b.'), 'FILE');
      expect(attachmentTypeLabel('.hidden'), 'HIDDEN');
    });

    test('attachmentCaption joins type and size with a middle dot', () {
      expect(attachmentCaption('Q3 report.pdf', 812 * 1024), 'PDF · 812 KB');
      expect(attachmentCaption('big.zip', 4404019), 'ZIP · 4.2 MB');
      expect(attachmentCaption('tiny', 512), 'FILE · 512 B');
    });
  });

  group('pure Dart (AC imports)', () {
    test('attachment_ref imports no flutter, dart ui or meta package', () {
      const path = 'lib/src/editor/attachment_ref.dart';
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: path);
      final imports = [
        for (final line in const LineSplitter().convert(
          file.readAsStringSync(),
        ))
          if (RegExp(r'^\s*(import|export|part)\s').hasMatch(line)) line.trim(),
      ];
      for (final line in imports) {
        expect(line, isNot(contains('package:flutter')), reason: path);
        expect(line, isNot(contains('dart:ui')), reason: path);
        expect(line, isNot(contains('package:meta')), reason: path);
      }
    });
  });
}
