// WI #161 (A2): live preview row geometry (Spec R11, R12, R13; TD10). Every
// number comes from the design pack `design/156-live-preview/packs/161.md`,
// which wins over numbers copied into the WI.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/row_geometry.dart';

const _eps = 1e-9;

Matcher _px(double v) => closeTo(v, _eps);

void main() {
  group('mono column', () {
    test('mono column is 8.1 px at 13.5 and scales with font size', () {
      expect(monoFontSize, _px(13.5));
      expect(monoColumnWidth, _px(8.1));
      expect(monoAdvance(13.5), _px(8.1));
      expect(monoAdvance(20), _px(12.0));
      expect(monoAdvance(17), _px(10.2));
      expect(monoAdvance(15), _px(9.0));
    });
  });

  group('marker columns (AC R11)', () {
    test('marker column widths follow the R11 table in columns and pixels', () {
      final cases = <(MarkerColumnKind, int, bool, int)>[
        (MarkerColumnKind.bullet, 1, false, 2),
        (MarkerColumnKind.bullet, 1, true, 2),
        (MarkerColumnKind.numbered, 1, false, 3),
        (MarkerColumnKind.numbered, 2, false, 4),
        (MarkerColumnKind.numbered, 3, false, 5),
        (MarkerColumnKind.numbered, 2, true, 4),
        (MarkerColumnKind.quote, 1, false, 2),
        (MarkerColumnKind.quote, 1, true, 2),
        (MarkerColumnKind.task, 1, false, 4),
        (MarkerColumnKind.task, 1, true, 6),
      ];
      for (final (kind, digits, revealed, cols) in cases) {
        final why = '$kind digits $digits revealed $revealed';
        expect(
          markerColumns(kind, numberDigits: digits, revealed: revealed),
          cols,
          reason: why,
        );
        expect(
          markerColumnWidth(kind, numberDigits: digits, revealed: revealed),
          _px(cols * 8.1),
          reason: why,
        );
      }
      // The design pack's pixel values.
      expect(markerColumnWidth(MarkerColumnKind.bullet), _px(16.2));
      expect(markerColumnWidth(MarkerColumnKind.numbered), _px(24.3));
      expect(
        markerColumnWidth(MarkerColumnKind.numbered, numberDigits: 2),
        _px(32.4),
      );
      expect(
        markerColumnWidth(MarkerColumnKind.numbered, numberDigits: 3),
        _px(40.5),
      );
      expect(markerColumnWidth(MarkerColumnKind.task), _px(32.4));
      expect(
        markerColumnWidth(MarkerColumnKind.task, revealed: true),
        _px(48.6),
      );
    });

    test('digit count only widens numbered columns', () {
      for (final kind in [
        MarkerColumnKind.bullet,
        MarkerColumnKind.quote,
        MarkerColumnKind.task,
      ]) {
        expect(
          markerColumns(kind, numberDigits: 3),
          markerColumns(kind),
          reason: '$kind',
        );
      }
      expect(markerColumns(MarkerColumnKind.numbered, numberDigits: 9), 11);
    });

    test('a numbered run with fewer than one digit is an error', () {
      expect(
        () => markerColumns(MarkerColumnKind.numbered, numberDigits: 0),
        throwsArgumentError,
      );
      expect(
        () => markerColumnWidth(MarkerColumnKind.numbered, numberDigits: 0),
        throwsArgumentError,
      );
      expect(markerColumns(MarkerColumnKind.numbered, numberDigits: 1), 3);
    });

    test('painted numbers right align so the dots line up', () {
      final col = markerColumnWidth(MarkerColumnKind.numbered, numberDigits: 2);
      // `9.` is 2 chars, `10.` is 3 chars.
      expect(
        numberedMarkerLeft(columnLeft: 0, columnWidth: col, textWidth: 16.2),
        _px(8.1),
      );
      expect(
        numberedMarkerLeft(columnLeft: 0, columnWidth: col, textWidth: 24.3),
        _px(0),
      );
      expect(
        numberedMarkerLeft(columnLeft: 194, columnWidth: 24.3, textWidth: 16.2),
        _px(194),
      );
    });
  });

  group('item x and nesting (AC R12)', () {
    test('item text x is the marker x plus the column width', () {
      const t = 194.0;
      final cases = <(MarkerColumnKind, int, bool, int, double)>[
        (MarkerColumnKind.bullet, 1, false, 2, t + 16.2),
        (MarkerColumnKind.task, 1, false, 4, t + 32.4),
        (MarkerColumnKind.task, 1, true, 6, t + 48.6),
        (MarkerColumnKind.numbered, 1, false, 3, t + 24.3),
        (MarkerColumnKind.numbered, 2, false, 4, t + 32.4),
        (MarkerColumnKind.quote, 1, false, 2, t + 16.2),
      ];
      for (final (kind, digits, revealed, cols, textX) in cases) {
        final g = itemGeometry(
          markerX: t,
          kind: kind,
          numberDigits: digits,
          revealed: revealed,
        );
        final why = '$kind digits $digits revealed $revealed';
        expect(g.markerX, _px(t), reason: why);
        expect(g.columns, cols, reason: why);
        expect(g.columnWidth, _px(cols * 8.1), reason: why);
        expect(g.textX, _px(textX), reason: why);
      }
    });

    test(
      'a child marker starts at the parent unrevealed text x even when the parent is revealed',
      () {
        const t = 42.0;
        final hidden = itemGeometry(markerX: t, kind: MarkerColumnKind.task);
        final shown = itemGeometry(
          markerX: t,
          kind: MarkerColumnKind.task,
          revealed: true,
        );
        expect(hidden.textX, _px(t + 32.4));
        expect(shown.textX, _px(t + 48.6));
        expect(hidden.childMarkerX, _px(hidden.textX));
        expect(shown.childMarkerX, _px(hidden.textX));

        // A2 board: bullet child of a bullet, and of the `10.` row.
        final bullet = itemGeometry(markerX: t, kind: MarkerColumnKind.bullet);
        final child = itemGeometry(
          markerX: bullet.childMarkerX,
          kind: MarkerColumnKind.bullet,
        );
        expect(child.markerX, _px(t + 16.2));
        expect(child.textX, _px(t + 32.4));

        final ten = itemGeometry(
          markerX: t,
          kind: MarkerColumnKind.numbered,
          numberDigits: 2,
        );
        final tenChild = itemGeometry(
          markerX: ten.childMarkerX,
          kind: MarkerColumnKind.bullet,
        );
        expect(tenChild.markerX, _px(t + 32.4));
        expect(tenChild.textX, _px(t + 48.6));

        // A revealed grandparent task still leaves the grandchild in place.
        final revealedChild = itemGeometry(
          markerX: shown.childMarkerX,
          kind: MarkerColumnKind.task,
          revealed: true,
        );
        expect(revealedChild.markerX, _px(t + 32.4));
        expect(revealedChild.textX, _px(t + 32.4 + 48.6));
        expect(revealedChild.childMarkerX, _px(t + 32.4 + 32.4));
      },
    );

    test('revealing a bullet numbered or quote column moves nothing', () {
      for (final kind in [
        MarkerColumnKind.bullet,
        MarkerColumnKind.numbered,
        MarkerColumnKind.quote,
      ]) {
        final a = itemGeometry(markerX: 10, kind: kind);
        final b = itemGeometry(markerX: 10, kind: kind, revealed: true);
        expect(b.textX, _px(a.textX), reason: '$kind');
        expect(b.childMarkerX, _px(a.childMarkerX), reason: '$kind');
        expect(b.columns, a.columns, reason: '$kind');
      }
    });

    test('quote rows keep a one column right inset and other rows none', () {
      expect(itemTextRightInset(MarkerColumnKind.quote), _px(8.1));
      expect(itemTextRightInset(MarkerColumnKind.bullet), _px(0));
      expect(itemTextRightInset(MarkerColumnKind.numbered), _px(0));
      expect(itemTextRightInset(MarkerColumnKind.task), _px(0));
    });
  });

  group('line heights (AC R13)', () {
    test('line heights match the design pack table', () {
      final expected = <LineHeightKind, double>{
        LineHeightKind.body: 22.95,
        LineHeightKind.item: 22.95,
        LineHeightKind.task: 22.95,
        LineHeightKind.quote: 22.95,
        LineHeightKind.heading1: 40,
        LineHeightKind.heading2: 34,
        LineHeightKind.heading3: 28.5,
        LineHeightKind.heading4: 22.95,
        LineHeightKind.heading5: 22.95,
        LineHeightKind.heading6: 22.95,
        LineHeightKind.blank: 22.95,
        LineHeightKind.rule: 22.95,
        LineHeightKind.code: 22.95,
        LineHeightKind.fenceHidden: 8,
        LineHeightKind.fenceRevealed: 22.95,
      };
      expect(expected.keys, containsAll(LineHeightKind.values));
      for (final MapEntry(:key, :value) in expected.entries) {
        expect(lineHeight(key), _px(value), reason: '$key');
      }
      expect(minimumStrutHeight, _px(22.95));
    });

    test('heading line height by level and out of range levels throw', () {
      final expected = [40.0, 34.0, 28.5, 22.95, 22.95, 22.95];
      for (var level = 1; level <= 6; level++) {
        expect(
          headingLineHeight(level),
          _px(expected[level - 1]),
          reason: 'H$level',
        );
      }
      expect(() => headingLineHeight(0), throwsArgumentError);
      expect(() => headingLineHeight(7), throwsArgumentError);
    });

    test('a rule is a 1 px line 11 px below its line top', () {
      expect(ruleOffsetY, _px(11));
      expect(ruleThickness, _px(1));
    });
  });

  group('code row (AC insets)', () {
    test('code row text insets are 16.2 px left and 10 px right', () {
      expect(codeTextInsetLeft, _px(16.2));
      expect(codeTextInsetLeft, _px(2 * monoColumnWidth));
      expect(codeTextInsetRight, _px(10));
    });

    test('code text width subtracts both insets', () {
      expect(codeTextWidth(746), _px(719.8));
      expect(codeTextWidth(650), _px(623.8));
    });

    test('a revealed code box reaches 8 px past each fence line', () {
      expect(codeBoxRevealedOutset, _px(8));
      expect(
        codeBoxRevealedOutset,
        _px(lineHeight(LineHeightKind.fenceHidden)),
      );
    });
  });

  group('pure Dart (AC imports)', () {
    test('neither core file imports package flutter', () {
      for (final path in [
        'lib/src/editor/markdown_inline.dart',
        'lib/src/editor/row_geometry.dart',
      ]) {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: path);
        final imports = file
            .readAsLinesSync()
            .map((l) => l.trim())
            .where((l) => l.startsWith('import ') || l.startsWith('export '))
            .toList();
        expect(
          imports.where((l) => l.contains('package:flutter')),
          isEmpty,
          reason: '$path imports $imports',
        );
        expect(
          imports.where((l) => l.contains('dart:ui')),
          isEmpty,
          reason: '$path imports $imports',
        );
      }
    });
  });
}
