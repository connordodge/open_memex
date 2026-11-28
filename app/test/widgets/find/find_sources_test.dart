// WI #80 (Spec #61 F1): livePreviewHiddenRanges reads the zero-width runs of
// buildLivePreviewSpan(forceHidden: true), for FindSource.hidden (Reqs 4,
// 26). The expected ranges are the runs the span builder hides today.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/widgets/find/find_sources.dart';

import '../../support/font_fetch_hold.dart';

void main() {
  holdFontFetches();

  test(
    'livePreviewHiddenRanges gives the hidden runs of a link bold and heading and none for plain text',
    () {
      expect(livePreviewHiddenRanges('[a](url)'), const [
        FindRange(0, 1),
        FindRange(2, 8),
      ]);
      expect(livePreviewHiddenRanges('**b**'), const [
        FindRange(0, 2),
        FindRange(3, 5),
      ]);
      expect(livePreviewHiddenRanges('# h'), const [FindRange(0, 2)]);
      expect(livePreviewHiddenRanges('plain'), isEmpty);
      expect(livePreviewHiddenRanges(''), isEmpty);
    },
  );

  test('livePreviewHiddenRanges gives text offsets across lines', () {
    expect(
      livePreviewHiddenRanges('x **b** y\n# h2\nsee [lab](http://x.com) now'),
      const [
        FindRange(2, 4),
        FindRange(5, 7),
        FindRange(10, 12),
        FindRange(19, 20),
        FindRange(23, 38),
      ],
    );
    // A list marker stays visible; only the bold markers hide.
    expect(livePreviewHiddenRanges('- item **b**'), const [
      FindRange(7, 9),
      FindRange(10, 12),
    ]);
  });

  test(
    'livePreviewHiddenRanges forwards itemText and codeRow to the span builder',
    () {
      // Item text is cut from its line, so a hash there is no heading.
      expect(livePreviewHiddenRanges('# h', itemText: true), isEmpty);
      expect(livePreviewHiddenRanges('**b**', itemText: true), const [
        FindRange(0, 2),
        FindRange(3, 5),
      ]);
      // A code row hides its opening fence line terminator too.
      const fence = '```\ncode\n```';
      expect(livePreviewHiddenRanges(fence), const [
        FindRange(0, 3),
        FindRange(9, 12),
      ]);
      expect(livePreviewHiddenRanges(fence, codeRow: true), const [
        FindRange(0, 4),
        FindRange(9, 12),
      ]);
    },
  );
}
