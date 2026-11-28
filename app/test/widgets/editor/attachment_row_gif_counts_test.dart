// WI #143 (Spec #123 V3: R31; rulings D7, D8): an animated GIF in an image
// row plays without making the editor work (#125 W1 counters,
// `perf_counters.dart`).
//
// - One GIF frame: no row build or segment setState, no row selection,
//   marker column, Find or squiggle paint, no line measure or walk and no
//   decoration layout. Each image paints in its own RepaintBoundary inside
//   the row's, with no visibility gating.
// - A decode at known dims (a local image, its height final at first
//   layout): no relayout of the image's editor row, read from the layout
//   log (`debugPrintLayouts`), which this file shows does log the row when
//   it does relayout.
//
// The GIF and PNG bytes are tiny generated images; real decodes and frame
// fetches run under `runAsync`.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/attachment_ref.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart';

import '../../support/attachments_fakes.dart';
import '../../support/editor_rows_probe.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/perf_counters.dart';
import '../../support/table_harness.dart';

int _t143GifIds = 2000;

/// A fresh image attachment named [name]: its decoded path and its
/// reference markdown.
({String path, String md}) _t143GifAttachment(String name) {
  final n = ++_t143GifIds;
  return (
    path: testAttachmentPath(n, name),
    md:
        '![$name](objects/5e/${testAttachmentHash(n)}/'
        '${encodeAttachmentName(name)})',
  );
}

/// Row [r]'s decoded image frame (Key `editor-attachment-0-<r>`), or null.
ui.Image? _t143Frame(WidgetTester tester, int r) {
  final raw = find.descendant(
    of: find.byKey(ValueKey('editor-attachment-0-$r')),
    matching: find.byType(RawImage),
  );
  return raw.evaluate().isEmpty ? null : tester.widget<RawImage>(raw).image;
}

/// Lets real async work run, a frame at a time, until [done] holds.
Future<void> _t143GifSettle(
  WidgetTester tester,
  bool Function() done, {
  Duration step = Duration.zero,
  String? reason,
}) async {
  for (var i = 0; i < 60 && !done(); i++) {
    if (step > Duration.zero) await tester.pump(step);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: reason);
}

/// The render object at the root of editor row [r] of text segment 0.
RenderObject _t143RowRender(WidgetTester tester, int r) => tester.renderObject(
  find.byWidgetPredicate(
    (w) => w is EditorRow && w.segment == 0 && w.index == r,
    description: 'EditorRow 0-$r',
    skipOffstage: false,
  ),
);

/// Runs [body] with every render object layout logged; returns the log.
Future<List<String>> _t143LayoutLog(Future<void> Function() body) async {
  final log = <String>[];
  final previous = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) => log.add(message ?? '');
  debugPrintLayouts = true;
  try {
    await body();
  } finally {
    debugPrintLayouts = false;
    debugPrint = previous;
  }
  return log;
}

void main() {
  holdFontFetches();

  testWidgets(
    'one GIF frame causes no row build setState paint line measure or decoration layout',
    (tester) async {
      final vault = FakeAttachmentVault();
      final gif = _t143GifAttachment('spinner.gif');
      vault.putFile(gif.path, testAnimatedGifBytes(40, 30, frames: 4));
      final text = [
        'Intro line with words',
        '- an item',
        gif.md,
        '1. numbered',
        'Outro line',
      ].join('\n');
      await pumpTable(
        tester,
        text,
        overrides: [attachmentsProvider.overrideWithValue(vault)],
      );
      expect(rowsHostOf(tester).rowSpec(2)?.kind, RowKind.attachment);
      await _t143GifSettle(
        tester,
        () => _t143Frame(tester, 2) != null,
        reason: 'the GIF shows its first frame',
      );
      // Let the editor's own start-up work finish.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();

      final shown = _t143Frame(tester, 2);
      final before = PerfCounters.snapshot();
      await _t143GifSettle(
        tester,
        () => !identical(_t143Frame(tester, 2), shown),
        step: const Duration(milliseconds: 50),
        reason: 'the GIF plays: a new frame shows',
      );
      final delta = PerfCounters.delta(before);
      expect(
        {
          for (final MapEntry(:key, :value) in delta.entries)
            if (value != 0) key: value,
        },
        isEmpty,
        reason: 'one GIF frame does no editor work',
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('editor-attachment-0-2'))),
        const Size(40, 30),
      );
    },
    variant: macOnly,
  );

  testWidgets('a decode at known dims causes no relayout of the image row', (
    tester,
  ) async {
    final vault = FakeAttachmentVault();
    final pic = _t143GifAttachment('chart.png');
    vault.putFile(pic.path, testPngBytes(300, 200));
    final body = await pumpTable(
      tester,
      'Intro line\n${pic.md}\nOutro line',
      overrides: [attachmentsProvider.overrideWithValue(vault)],
    );
    expect(rowsHostOf(tester).rowSpec(1)?.kind, RowKind.attachment);
    // Let the editor's own start-up frames finish; the decode needs real
    // async work, so it is still pending.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_t143Frame(tester, 1), isNull, reason: 'not decoded yet');
    final row = describeIdentity(_t143RowRender(tester, 1));
    final before = PerfCounters.snapshot();

    final decodeLog = await _t143LayoutLog(
      () => _t143GifSettle(
        tester,
        () => _t143Frame(tester, 1) != null,
        reason: 'the image decodes',
      ),
    );
    expect(
      decodeLog.where((m) => m.contains(row)),
      isEmpty,
      reason: 'the decode relaid out the row',
    );
    final delta = PerfCounters.delta(before);
    for (final counter in [
      'rowBuilds',
      'segmentBuilds',
      'segmentSetStates',
      'editableLineMeasures',
      'paragraphLineMeasures',
      'layoutDecorations',
    ]) {
      expect(delta[counter], 0, reason: counter);
    }
    expect(
      tester.getSize(find.byKey(const ValueKey('editor-attachment-0-1'))),
      const Size(300, 200),
    );

    // The log does see the row when it relays out: revealing its text.
    final revealLog = await _t143LayoutLog(() => activateRow(tester, 0, 1));
    expect(revealLog.where((m) => m.contains(row)), isNotEmpty);
    await body.focusOutside();
  }, variant: macOnly);
}
