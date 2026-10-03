// WI #20 (A3): UTF-8 byte offsets (server `blocks.start_byte`/`end_byte`,
// Rust side) <-> Dart UTF-16 indexes.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/byte_offsets.dart';

void main() {
  group('utf16ToUtf8 / utf8ToUtf16', () {
    test('maps "café ![[" index 5 to byte 6 and back', () {
      expect(utf16ToUtf8('café ![[', 5), 6);
      expect(utf8ToUtf16('café ![[', 6), 5);
    });

    test('maps "a😀b" index 3 to byte 5 and back', () {
      expect(utf16ToUtf8('a😀b', 3), 5);
      expect(utf8ToUtf16('a😀b', 5), 3);
    });

    test('throws ArgumentError for byte 2 inside the emoji in "a😀b"', () {
      expect(() => utf8ToUtf16('a😀b', 2), throwsArgumentError);
    });

    test(
      'throws ArgumentError for every byte offset inside a multi-byte character',
      () {
        for (final b in [2, 3, 4]) {
          expect(
            () => utf8ToUtf16('a😀b', b),
            throwsArgumentError,
            reason: 'byte $b',
          );
        }
        // é is two bytes (3..5); byte 4 is inside it.
        expect(() => utf8ToUtf16('café', 4), throwsArgumentError);
        // € is three bytes (0..3).
        expect(() => utf8ToUtf16('€x', 1), throwsArgumentError);
        expect(() => utf8ToUtf16('€x', 2), throwsArgumentError);
      },
    );

    test(
      'throws ArgumentError for a UTF-16 index between surrogate halves',
      () {
        expect(() => utf16ToUtf8('a😀b', 2), throwsArgumentError);
      },
    );

    test('maps every character boundary of "a😀b" both ways', () {
      const s = 'a😀b';
      const pairs = [
        [0, 0],
        [1, 1],
        [3, 5],
        [4, 6],
      ];
      for (final p in pairs) {
        expect(utf16ToUtf8(s, p[0]), p[1], reason: 'index ${p[0]}');
        expect(utf8ToUtf16(s, p[1]), p[0], reason: 'byte ${p[1]}');
      }
    });

    test('maps 1-, 2-, 3- and 4-byte characters at their boundaries', () {
      // a(1) é(2) €(3) 😀(4) z(1)
      const s = 'aé€😀z';
      const pairs = [
        [0, 0],
        [1, 1],
        [2, 3],
        [3, 6],
        [5, 10],
        [6, 11],
      ];
      for (final p in pairs) {
        expect(utf16ToUtf8(s, p[0]), p[1], reason: 'index ${p[0]}');
        expect(utf8ToUtf16(s, p[1]), p[0], reason: 'byte ${p[1]}');
      }
    });

    test('ASCII offsets are identical in both encodings', () {
      const s = 'hello\nworld';
      for (var i = 0; i <= s.length; i++) {
        expect(utf16ToUtf8(s, i), i);
        expect(utf8ToUtf16(s, i), i);
      }
    });

    test('empty string maps 0 to 0', () {
      expect(utf16ToUtf8('', 0), 0);
      expect(utf8ToUtf16('', 0), 0);
    });

    test('throws ArgumentError for offsets outside the string', () {
      expect(() => utf16ToUtf8('a😀b', -1), throwsArgumentError);
      expect(() => utf16ToUtf8('a😀b', 5), throwsArgumentError);
      expect(() => utf8ToUtf16('a😀b', -1), throwsArgumentError);
      expect(() => utf8ToUtf16('a😀b', 7), throwsArgumentError);
      expect(() => utf8ToUtf16('', 1), throwsArgumentError);
    });

    test(
      'server block byte range extracts the block text from multi-byte content',
      () {
        // content_md as the server stores it; the block "😀 jump" sits at
        // bytes 7..16 (c a f é=2 \n \n = 7; 😀=4 + " jump"=5 → 16).
        const content = 'café\n\n😀 jump\n';
        final start = utf8ToUtf16(content, 7);
        final end = utf8ToUtf16(content, 16);
        expect(start, 6);
        expect(end, 13);
        expect(content.substring(start, end), '😀 jump');
        expect(utf16ToUtf8(content, start), 7);
        expect(utf16ToUtf8(content, end), 16);
      },
    );
  });
}
