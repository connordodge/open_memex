// WI #28 (implementer): where a captured block sits in the daily person
// field (capturedRange). The stored UTF-8 byte range is converted with #20's
// helper; when unsaved edits moved the block, its text is looked up instead.
import 'dart:convert';

import 'package:flutter/services.dart' show TextRange;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/widgets/editor/capture_gutter.dart';

BlockRow _block(String text, int startByte, {String source = 'agent'}) =>
    BlockRow(
      blockId: 'b',
      ord: 0,
      text: text,
      source: source,
      createdVersion: 1,
      createdAt: 0,
      startByte: startByte,
      endByte: startByte + utf8.encode(text).length,
    );

int _bytes(String s) => utf8.encode(s).length;

void main() {
  test(
    'the stored byte range maps to UTF-16 indexes after multi-byte text',
    () {
      const before = '☕☕ café\n\n';
      const text = '${before}Agent line.\n';

      final range = capturedRange(text, _block('Agent line.', _bytes(before)));

      expect(range, const TextRange(start: 9, end: 20));
      expect(text.substring(range!.start, range.end), 'Agent line.');
    },
  );

  test(
    'the byte range wins over an earlier copy of the same text in the field',
    () {
      const text = 'Buy milk.\n\nBuy milk.\n';

      final range = capturedRange(
        text,
        _block('Buy milk.', _bytes('Buy milk.\n\n'), source: 'quick-entry'),
      );

      expect(range, const TextRange(start: 11, end: 20));
    },
  );

  test(
    'a block moved by unsaved edits is found by its text instead of its stale range',
    () {
      const saved = 'Morning\n\n';
      const text = 'Inserted above.\n\nMorning\n\nAgent line.\n';

      final range = capturedRange(text, _block('Agent line.', _bytes(saved)));

      expect(range, const TextRange(start: 26, end: 37));
    },
  );

  test('a moved block now at the start of the field is found at offset 0', () {
    const text = 'Agent line.\n';

    final range = capturedRange(text, _block('Agent line.', 9));

    expect(range, const TextRange(start: 0, end: 11));
  });

  test(
    'a stale range that splits a multi-byte character falls back to the text',
    () {
      const text = '☕ Agent line.\n';

      // Byte 1 is inside the 3-byte U+2615.
      final range = capturedRange(text, _block('Agent line.', 1));

      expect(range, const TextRange(start: 2, end: 13));
    },
  );

  test('a block whose text the person deleted has no range', () {
    expect(capturedRange('Morning\n', _block('Agent line.', 9)), isNull);
    expect(capturedRange('', _block('Agent line.', 0)), isNull);
  });
}
