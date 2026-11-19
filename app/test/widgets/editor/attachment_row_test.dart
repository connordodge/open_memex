// WI #143 (Spec #123 V3: R23-R26, R28, R30-R33, R35-R38, R42; rulings D5,
// D6, D7, D10, D17, D22): attachment rows in live preview, image rows and
// file cards, on the row-kind seam (`AttachmentRowPresenter`).
//
// The whole segmented editor (`pumpTable`) runs over a fake attachments
// domain for `attachmentsProvider`:
// - a local vault ([FakeAttachmentVault], a `LocalAttachmentsAccess`): its
//   files lie on disk under its `vaultPath` and `read`/`info` answer them by
//   path, so a row may read an image header from disk at first layout (D7);
// - a hosted vault ([FakeHostedAttachments]): `read`/`info` wait until the
//   test answers them.
// Every file gets its own path (`testAttachmentPath`), since sizes cache per
// path for the session (D7).
//
// Geometry comes from the row-geometry accessor (`editor_rows_probe.dart`,
// D17) and from the block's Key `editor-attachment-<s>-<r>` (D6); no text
// field finder and no render-editable lookup. Image bytes are tiny generated
// PNGs; real decodes run under `runAsync`.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/attachment_ref.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/attachments_access.dart';
import 'package:open_memex_app/src/widgets/editor/attachment_row.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart';

import '../../support/attachments_fakes.dart';
import '../../support/editor_rows_probe.dart';
import '../../support/editor_scope.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/segment_editing_finder.dart';
import '../../support/spelling_editor_pump.dart';
import '../../support/table_harness.dart';

/// The cap on an image row's height (R24).
const double _t143MaxHeight = 480;

/// 30 MB, 1024-based like every size the app shows (R24, R32).
const int _t143MaxBytes = 30 * 1024 * 1024;

/// The toast of an offline open (R42, D22).
String _t143OfflineToast(String name) =>
    "Couldn't open $name: the vault server can't be reached.";

int _t143Ids = 1000;

/// A fresh attachment named [name]: its decoded path and its reference
/// markdown, image form for an inline image name unless [image] says.
({String path, String md}) _t143Attachment(String name, {bool? image}) {
  final n = ++_t143Ids;
  final bang = (image ?? isInlineImageName(name)) ? '!' : '';
  return (
    path: testAttachmentPath(n, name),
    md:
        '$bang[$name](objects/5e/${testAttachmentHash(n)}/'
        '${encodeAttachmentName(name)})',
  );
}

/// What [_t143Pump] pumped.
final class _T143Editor {
  _T143Editor(this.body, this.opener);

  final TableBody body;
  final RecordingUrlOpener opener;
}

/// Pumps the segmented editor on [text] with [attachments] as the open
/// vault's attachments domain and a recording URL opener.
Future<_T143Editor> _t143Pump(
  WidgetTester tester,
  String text,
  AttachmentsAccess attachments, {
  double width = tableDesktopWidth,
  double textScale = 1,
}) async {
  final opener = RecordingUrlOpener();
  final body = await pumpTable(
    tester,
    text,
    width: width,
    textScale: textScale,
    opener: opener,
    overrides: [attachmentsProvider.overrideWithValue(attachments)],
  );
  await tester.pump();
  return _T143Editor(body, opener);
}

/// The block of attachment row [r] of text segment 0 (Key
/// `editor-attachment-0-<r>`, D6).
Finder _t143Block(int r) => find.byKey(ValueKey('editor-attachment-0-$r'));

/// [finder] inside row [r]'s block.
Finder _t143In(int r, Finder finder) =>
    find.descendant(of: _t143Block(r), matching: finder);

/// The text [text] inside row [r]'s block.
Finder _t143Text(int r, String text) =>
    _t143In(r, find.text(text, findRichText: true));

/// Row [r]'s text slot while it is on stage (Key `editor-row-0-<r>`).
Finder _t143Slot(int r) => find.byKey(ValueKey('editor-row-0-$r'));

/// Row [r]'s text slot, also while it is offstage.
Finder _t143SlotAny(int r) =>
    find.byKey(ValueKey('editor-row-0-$r'), skipOffstage: false);

/// Editor row [r] of text segment 0.
Finder _t143Row(int r) => find.byWidgetPredicate(
  (w) => w is EditorRow && w.segment == 0 && w.index == r,
  description: 'EditorRow 0-$r',
  skipOffstage: false,
);

/// The width of editor row [r]: the text column.
double _t143Column(WidgetTester tester, int r) =>
    tester.getSize(_t143Row(r)).width;

/// The height of one text line: row 0's, a one-line prose row.
double _t143Line(WidgetTester tester) => rowRectOf(tester, 0, 0).height;

/// An image of [natural] logical pixels shown in a [column] wide text
/// column (R24): scaled down, never up, to the column width and at most
/// 480 px tall, aspect kept.
Size _t143Shown(Size natural, double column) {
  final scale = math.min(
    1.0,
    math.min(column / natural.width, _t143MaxHeight / natural.height),
  );
  return Size(natural.width * scale, natural.height * scale);
}

/// Row [r]'s decoded image, or null before it decodes.
ui.Image? _t143Decoded(WidgetTester tester, int r) {
  final raw = _t143In(r, find.byType(RawImage));
  return raw.evaluate().isEmpty ? null : tester.widget<RawImage>(raw).image;
}

/// Lets real async work (decodes, file reads) run until [done] holds.
Future<void> _t143Settle(
  WidgetTester tester,
  bool Function() done, {
  String? reason,
}) async {
  for (var i = 0; i < 60 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: reason);
}

/// A mouse click with [buttons] at [at] (global); then lets any click chain
/// expire.
Future<void> _t143Click(
  WidgetTester tester,
  Offset at, {
  int buttons = kPrimaryButton,
}) async {
  final gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: buttons,
  );
  await tester.pump();
  await gesture.up();
  await tester.pump();
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
  await tester.pump();
}

/// Two quick primary mouse clicks at [at] (global).
Future<void> _t143DoubleClick(WidgetTester tester, Offset at) async {
  for (var i = 0; i < 2; i++) {
    final gesture = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 40));
  }
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
  await tester.pump();
}

/// A secondary click at [at], then the menu item [item] it offers.
Future<void> _t143MenuPick(WidgetTester tester, Offset at, String item) async {
  await _t143Click(tester, at, buttons: kSecondaryMouseButton);
  expect(find.text('Open'), findsOneWidget, reason: 'the menu offers Open');
  expect(
    find.text('Reveal in Finder'),
    findsOneWidget,
    reason: 'the menu offers Reveal in Finder',
  );
  await tester.tap(find.text(item));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// The segment selection lies on row [r]: collapsed or not, both ends in
/// the row's text, and row [r] has focus.
void _t143ExpectCaretOn(WidgetTester tester, int r) {
  final host = rowsHostOf(tester);
  final spec = host.rowSpec(r)!;
  final sel = host.selection;
  expect(host.focusedRow, r, reason: 'row $r has focus');
  expect(sel.start, greaterThanOrEqualTo(spec.textStart), reason: '$sel');
  expect(sel.end, lessThanOrEqualTo(spec.textEnd), reason: '$sel');
}

/// Whether row [r]'s text slot is offstage now: the rows host keeps the
/// field mounted under an `Offstage` that is offstage (`RowTextSlot`).
bool _t143SlotHidden(WidgetTester tester, int r) {
  final wrapper = find.descendant(
    of: _t143SlotAny(r),
    matching: find.byType(Offstage, skipOffstage: false),
    skipOffstage: false,
  );
  return wrapper.evaluate().isNotEmpty &&
      tester.widget<Offstage>(wrapper.first).offstage;
}

/// Row [r] shows its block, not its text: the text slot is mounted but
/// offstage.
void _t143ExpectIdle(WidgetTester tester, int r) {
  expect(_t143Block(r), findsOneWidget, reason: 'row $r shows its block');
  expect(_t143SlotAny(r), findsOneWidget, reason: 'its field stays mounted');
  expect(_t143SlotHidden(tester, r), isTrue, reason: 'its text is offstage');
}

/// Row [r] shows its markdown as a text line directly above its block.
void _t143ExpectRevealed(WidgetTester tester, int r) {
  expect(_t143Block(r), findsOneWidget, reason: 'row $r keeps its block');
  expect(_t143SlotAny(r), findsOneWidget, reason: 'its text slot');
  expect(_t143SlotHidden(tester, r), isFalse, reason: 'its text line shows');
  final slot = tester.getRect(_t143Slot(r));
  final block = tester.getRect(_t143Block(r));
  expect(slot.height, greaterThan(1), reason: 'the text line has height');
  expect(slot.bottom, lessThanOrEqualTo(block.top + 0.5), reason: 'above');
  expect(block.top - slot.bottom, lessThan(1.0), reason: 'directly above');
}

/// The one ScaffoldMessenger's state.
ScaffoldMessengerState _t143Messenger(WidgetTester tester) =>
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger));

/// The global centre of [needle] in editor row [row] of text segment 0,
/// from the row-geometry accessor.
Offset _t143PointOn(WidgetTester tester, int row, String needle) {
  final text = rowTextOf(tester, 0, row);
  final at = text.indexOf(needle);
  expect(at, isNonNegative, reason: 'row $row holds "$needle": $text');
  final boxes = rowBoxesOf(tester, 0, row);
  final rects = boxes.boxesFor(TextRange(start: at, end: at + needle.length));
  expect(rects, isNotEmpty);
  return boxes.box.localToGlobal(rects.first.center);
}

/// Records, after every frame in which text segment 0 exists, the height
/// of row [r]'s block (null while it has none) until the test ends.
List<double?> _t143RecordHeights(WidgetTester tester, int r) {
  final heights = <double?>[];
  var on = true;
  addTearDown(() => on = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!on) return;
    if (find.byKey(textSegmentKey(0)).evaluate().isEmpty) return;
    final block = _t143Block(r).evaluate();
    final box = block.isEmpty ? null : block.first.renderObject;
    heights.add(box is RenderBox && box.hasSize ? box.size.height : null);
  });
  return heights;
}

void main() {
  holdFontFetches();

  group('image rows (AC2)', () {
    testWidgets(
      'an image row shows the image at natural size scaled to the column and at most 480 px tall',
      (tester) async {
        final vault = FakeAttachmentVault();
        final sizes = <Size>[
          const Size(200, 100), // smaller than the column: never upscaled
          const Size(2000, 500), // wider than the column
          const Size(600, 1200), // taller than 480
          const Size(300, 480), // exactly 480 tall
          const Size(300, 481), // just over
        ];
        final refs = [
          for (final (i, _) in sizes.indexed)
            _t143Attachment('pic$i.${i.isEven ? 'png' : 'PNG'}'),
        ];
        for (final (i, s) in sizes.indexed) {
          vault.putFile(
            refs[i].path,
            testPngBytes(s.width.toInt(), s.height.toInt()),
          );
        }
        final text = [
          'Intro line',
          for (final r in refs) r.md,
          'Outro line',
        ].join('\n');
        await _t143Pump(tester, text, vault);
        for (final (i, natural) in sizes.indexed) {
          final r = i + 1;
          expect(rowsHostOf(tester).rowSpec(r)?.kind, RowKind.attachment);
          final shown = _t143Shown(natural, _t143Column(tester, r));
          final image = _t143In(r, find.byType(Image));
          expect(image, findsOneWidget, reason: 'row $r shows an image');
          final size = tester.getSize(image);
          expect(size.width, moreOrLessEquals(shown.width, epsilon: 0.5));
          expect(size.height, moreOrLessEquals(shown.height, epsilon: 0.5));
          expect(
            tester.getSize(_t143Block(r)).height,
            moreOrLessEquals(shown.height, epsilon: 0.5),
            reason: 'row $r block height',
          );
          expect(size.height, lessThanOrEqualTo(_t143MaxHeight + 0.01));
        }
        // The aspect ratio holds and nothing is upscaled.
        expect(
          tester.getSize(_t143In(1, find.byType(Image))),
          const Size(200, 100),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'an image decodes at its shown width times the device pixel ratio',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t143Attachment('wide.png');
        vault.putFile(pic.path, testPngBytes(2000, 500));
        await _t143Pump(tester, 'Intro line\n${pic.md}\nOutro line', vault);
        expect(rowsHostOf(tester).rowSpec(1)?.kind, RowKind.attachment);
        tester.view
          ..devicePixelRatio = 2
          ..physicalSize = const Size(2 * tableDesktopWidth, 2000);
        await tester.pump();
        await tester.pump();
        final shown = _t143Shown(const Size(2000, 500), _t143Column(tester, 1));
        expect(shown.width, lessThan(1000), reason: 'fixture: downscaled');
        await _t143Settle(
          tester,
          () => _t143Decoded(tester, 1)?.width == (shown.width * 2).round(),
          reason: 'decoded at ${(shown.width * 2).round()} px wide',
        );
        final decoded = _t143Decoded(tester, 1)!;
        expect(decoded.width, (shown.width * 2).round());
        expect(decoded.width, lessThan(2000), reason: 'not full size');
        expect(
          tester.getSize(_t143In(1, find.byType(Image))).width,
          moreOrLessEquals(shown.width, epsilon: 0.5),
        );
      },
      variant: macOnly,
    );
  });

  group('reserved height (AC3)', () {
    testWidgets(
      'a local image row has its final height at first layout before and after decode idle and active',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t143Attachment('chart.png');
        vault.putFile(pic.path, testPngBytes(300, 200));
        final heights = _t143RecordHeights(tester, 1);
        final e = await _t143Pump(
          tester,
          'Intro line\n${pic.md}\nOutro line',
          vault,
        );
        expect(heights, isNotEmpty, reason: 'frames were recorded');
        expect(
          heights.first,
          isNotNull,
          reason: 'the block shows in the first frame',
        );
        expect(heights.first, moreOrLessEquals(200, epsilon: 0.5));
        expect(_t143Decoded(tester, 1), isNull, reason: 'not decoded yet');

        // Decode.
        await _t143Settle(tester, () => _t143Decoded(tester, 1) != null);
        // Active, then idle again.
        await activateRow(tester, 0, 1);
        _t143ExpectRevealed(tester, 1);
        await e.body.focusOutside();
        _t143ExpectIdle(tester, 1);
        await tester.pump();
        for (final (i, h) in heights.indexed) {
          expect(h, moreOrLessEquals(200, epsilon: 0.5), reason: 'frame $i');
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'a hosted image row is one line tall until its bytes arrive then changes once for that path in the session',
      (tester) async {
        final hosted = FakeHostedAttachments();
        final pic = _t143Attachment('remote.png');
        final text = 'Intro line\n${pic.md}\nOutro line';
        final heights = _t143RecordHeights(tester, 1);
        await _t143Pump(tester, text, hosted);
        await tester.pump(const Duration(milliseconds: 200));
        final line = _t143Line(tester);
        expect(hosted.readCalls, contains(pic.path));
        expect(
          tester.getSize(_t143Block(1)).height,
          moreOrLessEquals(line, epsilon: 1),
          reason: 'a one line reserve while the bytes are pending',
        );

        hosted.answerFile(pic.path, testPngBytes(300, 200));
        await _t143Settle(
          tester,
          () => tester.getSize(_t143Block(1)).height > line + 1,
          reason: 'the final size once the bytes arrive',
        );
        await _t143Settle(tester, () => _t143Decoded(tester, 1) != null);
        expect(
          tester.getSize(_t143Block(1)).height,
          moreOrLessEquals(200, epsilon: 0.5),
        );
        final seen = heights.whereType<double>().toList();
        expect(heights, everyElement(isNotNull), reason: 'always a block');
        var changes = 0;
        for (var i = 1; i < seen.length; i++) {
          if ((seen[i] - seen[i - 1]).abs() > 0.5) changes++;
        }
        expect(changes, 1, reason: 'one line, then final: $seen');

        // The same path in a freshly mounted editor, later in the session:
        // its final size at first layout.
        await tester.pumpWidget(const SizedBox());
        heights.clear();
        await _t143Pump(tester, text, hosted);
        expect(heights, isNotEmpty);
        for (final (i, h) in heights.indexed) {
          expect(h, moreOrLessEquals(200, epsilon: 0.5), reason: 'frame $i');
        }
      },
      variant: macOnly,
    );
  });

  group('size caps and undecodable images (AC4)', () {
    testWidgets(
      'an image over 100 megapixels or over 30 MB renders as a file card',
      (tester) async {
        final vault = FakeAttachmentVault();
        final overPixels = _t143Attachment('huge.png');
        final atPixels = _t143Attachment('big.png');
        final overBytes = _t143Attachment('heavy.png');
        final atBytes = _t143Attachment('full.png');
        // 10000 x 10001 is over 100 MP; 10000 x 10000 is exactly 100 MP.
        final overPixelsBytes = vault.putFile(
          overPixels.path,
          testPngHeaderOnly(10000, 10001),
        );
        vault.putFile(atPixels.path, testPngHeaderOnly(10000, 10000));
        final overBytesBytes = vault.putFile(
          overBytes.path,
          testPngBytes(100, 100),
          padTo: _t143MaxBytes + 1,
        );
        vault.putFile(
          atBytes.path,
          testPngBytes(100, 100),
          padTo: _t143MaxBytes,
        );
        final text = [
          'Intro line',
          overPixels.md,
          atPixels.md,
          overBytes.md,
          atBytes.md,
        ].join('\n');
        await _t143Pump(tester, text, vault);

        // Over a cap: a file card with its name and `<TYPE> · <size>`.
        expect(_t143Text(1, 'huge.png'), findsOneWidget);
        expect(
          _t143Text(1, attachmentCaption('huge.png', overPixelsBytes.length)),
          findsOneWidget,
        );
        expect(_t143In(1, find.byType(Image)), findsNothing);
        expect(_t143Text(3, 'heavy.png'), findsOneWidget);
        expect(
          _t143Text(3, attachmentCaption('heavy.png', overBytesBytes.length)),
          findsOneWidget,
        );
        expect(_t143In(3, find.byType(Image)), findsNothing);

        // At a cap: still an image row (before its decode).
        expect(_t143In(2, find.byType(Image)), findsOneWidget);
        expect(
          tester.getSize(_t143Block(2)).height,
          moreOrLessEquals(_t143MaxHeight, epsilon: 0.5),
        );
        expect(_t143In(4, find.byType(Image)), findsOneWidget);
        expect(
          tester.getSize(_t143Block(4)).height,
          moreOrLessEquals(100, epsilon: 0.5),
        );
        expect(_t143Text(4, 'PNG · 30.0 MB'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets('an undecodable image file renders as a file card', (
      tester,
    ) async {
      final vault = FakeAttachmentVault();
      final junk = _t143Attachment('broken.png');
      final corrupt = _t143Attachment('corrupt.png');
      vault.putFile(junk.path, Uint8List.fromList('not an image'.codeUnits));
      final corruptBytes = vault.putFile(
        corrupt.path,
        testPngHeaderOnly(40, 20, data: List.filled(64, 7)),
      );
      await _t143Pump(
        tester,
        'Intro line\n${junk.md}\n${corrupt.md}\nOutro line',
        vault,
      );
      // No image header: a card at once.
      expect(_t143Text(1, 'broken.png'), findsOneWidget);
      expect(_t143Text(1, 'PNG · 12 B'), findsOneWidget);
      expect(_t143In(1, find.byType(Image)), findsNothing);
      // A header whose image data fails to decode: a card once it fails.
      final caption = attachmentCaption('corrupt.png', corruptBytes.length);
      await _t143Settle(
        tester,
        () => _t143Text(2, caption).evaluate().isNotEmpty,
        reason: 'the undecodable image becomes a card',
      );
      expect(_t143Text(2, 'corrupt.png'), findsOneWidget);
      expect(_t143In(2, find.byType(Image)), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: macOnly);
  });

  group('caret reveal (AC5)', () {
    testWidgets(
      'with the caret or selection on the line the markdown shows as an editable line above the image',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t143Attachment('chart.png');
        vault.putFile(pic.path, testPngBytes(300, 200));
        final text = 'Intro line\n${pic.md}\nOutro line';
        final e = await _t143Pump(tester, text, vault);
        _t143ExpectIdle(tester, 1);
        expect(rowsHostOf(tester).rowSpec(1)?.kind, RowKind.attachment);

        // The caret on the line.
        await activateRow(tester, 0, 1, offset: 2);
        _t143ExpectRevealed(tester, 1);
        expect(rowTextOf(tester, 0, 1), pic.md);
        // It is editable: typing reaches the row's text.
        final at = rowsHostOf(tester).rowSpec(1)!.textStart + pic.md.length;
        e.body.segment().select(TextSelection.collapsed(offset: at));
        await tester.pump();
        await e.body.typeChar(' ');
        expect(e.body.text(), 'Intro line\n${pic.md} \nOutro line');
        expect(rowsHostOf(tester).rowSpec(1)?.kind, RowKind.attachment);
        _t143ExpectRevealed(tester, 1);

        // Focus elsewhere: the image alone again.
        await e.body.focusOutside();
        _t143ExpectIdle(tester, 1);

        // A selection reaching into the line reveals it too.
        await e.body.select(TextSelection(baseOffset: 2, extentOffset: at - 3));
        _t143ExpectRevealed(tester, 1);
        await e.body.settleTyping();
      },
      variant: macOnly,
    );

    testWidgets('arrow keys move onto across and off the attachment line', (
      tester,
    ) async {
      final vault = FakeAttachmentVault();
      final pic = _t143Attachment('chart.png');
      vault.putFile(pic.path, testPngBytes(300, 200));
      final text = 'Intro line\n${pic.md}\nOutro line';
      final e = await _t143Pump(tester, text, vault);
      _t143ExpectIdle(tester, 1);
      final spec = rowsHostOf(tester).rowSpec(1)!;

      // Onto it, from the line above.
      await e.body.placeCaret(3);
      await e.body.press(LogicalKeyboardKey.arrowDown);
      _t143ExpectCaretOn(tester, 1);
      _t143ExpectRevealed(tester, 1);
      // Across it.
      e.body.segment().select(TextSelection.collapsed(offset: spec.textStart));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await e.body.press(LogicalKeyboardKey.arrowRight);
      }
      expect(
        e.body.selection(),
        TextSelection.collapsed(offset: spec.textStart + 3),
      );
      _t143ExpectRevealed(tester, 1);
      // Off it, to the line below (past each visual line of its wrapped
      // markdown): the image alone again.
      final lines = rowBoxesOf(tester, 0, 1).lines.length;
      for (var i = 0; i < lines && rowsHostOf(tester).focusedRow == 1; i++) {
        await e.body.press(LogicalKeyboardKey.arrowDown);
      }
      _t143ExpectCaretOn(tester, 2);
      _t143ExpectIdle(tester, 1);
      // Back onto it from below.
      await e.body.press(LogicalKeyboardKey.arrowUp);
      _t143ExpectCaretOn(tester, 1);
      _t143ExpectRevealed(tester, 1);
      // And off it upwards.
      for (var i = 0; i < lines && rowsHostOf(tester).focusedRow == 1; i++) {
        await e.body.press(LogicalKeyboardKey.arrowUp);
      }
      _t143ExpectCaretOn(tester, 0);
      _t143ExpectIdle(tester, 1);
    }, variant: macOnly);

    testWidgets(
      'an edit that breaks the grammar turns the row into prose keeping the controller and focus',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t143Attachment('chart.png');
        vault.putFile(pic.path, testPngBytes(300, 200));
        final text = 'Intro line\n${pic.md}\nOutro line';
        final e = await _t143Pump(tester, text, vault);
        expect(rowsHostOf(tester).rowSpec(1)?.kind, RowKind.attachment);
        await activateRow(tester, 0, 1);
        _t143ExpectRevealed(tester, 1);
        final node = FocusManager.instance.primaryFocus;
        final controller = e.body.focusedField().widget.controller;

        // `x` before `![` breaks the grammar.
        await e.body.typeChar('x');
        expect(e.body.text(), 'Intro line\nx${pic.md}\nOutro line');
        final host = rowsHostOf(tester);
        final focused = host.focusedRow;
        expect(focused, isNotNull, reason: 'a row keeps focus');
        expect(host.rowSpec(focused!)?.kind, RowKind.prose);
        expect(
          find.byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith(
                  'editor-attachment-',
                ),
          ),
          findsNothing,
          reason: 'no block once it is prose',
        );
        expect(
          identical(FocusManager.instance.primaryFocus, node),
          isTrue,
          reason: 'the same focus node',
        );
        expect(
          identical(e.body.focusedField().widget.controller, controller),
          isTrue,
          reason: 'the same controller',
        );
        // Typing goes on in the same field.
        await e.body.typeChar('y');
        expect(e.body.text(), 'Intro line\nxy${pic.md}\nOutro line');
        await e.body.settleTyping();
      },
      variant: macOnly,
    );
  });

  group('image presses (AC6)', () {
    testWidgets('a tap in the image puts the caret on its line', (
      tester,
    ) async {
      final vault = FakeAttachmentVault();
      final pic = _t143Attachment('chart.png');
      vault.putFile(pic.path, testPngBytes(300, 200));
      final e = await _t143Pump(
        tester,
        'Intro line\n${pic.md}\nOutro line',
        vault,
      );
      _t143ExpectIdle(tester, 1);
      expect(rowsHostOf(tester).focusedRow, isNull);
      await _t143Click(tester, tester.getCenter(_t143Block(1)));
      _t143ExpectCaretOn(tester, 1);
      _t143ExpectRevealed(tester, 1);
      expect(vault.openCalls, isEmpty);
      expect(vault.revealCalls, isEmpty);
      expect(e.opener.opened, isEmpty);
    }, variant: macOnly);

    testWidgets('a double click in the image opens it through the domain', (
      tester,
    ) async {
      final vault = FakeAttachmentVault();
      final pic = _t143Attachment('chart.png');
      vault.putFile(pic.path, testPngBytes(300, 200));
      final e = await _t143Pump(
        tester,
        'Intro line\n${pic.md}\nOutro line',
        vault,
      );
      _t143ExpectIdle(tester, 1);
      await _t143DoubleClick(tester, tester.getCenter(_t143Block(1)));
      expect(vault.openCalls, [pic.path]);
      expect(vault.revealCalls, isEmpty);
      expect(e.opener.opened, isEmpty, reason: 'never the url opener');
    }, variant: macOnly);

    // The case #142's empty-bracket control used to pin as a lone line
    // (lead Q1 addendum): an empty-bracket reference line is an image row.
    testWidgets(
      'a lone empty bracket image line is an image row that a tap and a double click reach',
      (tester) async {
        final vault = FakeAttachmentVault();
        final path = testAttachmentPath(++_t143Ids, 'ok.png');
        vault.putFile(path, testPngBytes(300, 200));
        final e = await _t143Pump(
          tester,
          'Intro line\n![]($path)\nOutro line',
          vault,
        );
        expect(_t143Block(1), findsOneWidget);
        _t143ExpectIdle(tester, 1);
        await _t143Click(tester, tester.getCenter(_t143Block(1)));
        _t143ExpectCaretOn(tester, 1);
        expect(vault.openCalls, isEmpty);
        // Leave the line, then double-click the idle image.
        await _t143Click(tester, _t143PointOn(tester, 2, 'Outro'));
        _t143ExpectIdle(tester, 1);
        await _t143DoubleClick(tester, tester.getCenter(_t143Block(1)));
        expect(vault.openCalls, [path]);
        expect(vault.revealCalls, isEmpty);
        expect(e.opener.opened, isEmpty, reason: 'never the url opener');
      },
      variant: macOnly,
    );

    testWidgets(
      'a secondary click in the image offers Open and Reveal in Finder',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t143Attachment('chart.png');
        vault.putFile(pic.path, testPngBytes(300, 200));
        final e = await _t143Pump(
          tester,
          'Intro line\n${pic.md}\nOutro line',
          vault,
        );
        _t143ExpectIdle(tester, 1);
        await _t143MenuPick(tester, tester.getCenter(_t143Block(1)), 'Open');
        expect(vault.openCalls, [pic.path]);
        expect(vault.revealCalls, isEmpty);
        expect(find.text('Reveal in Finder'), findsNothing, reason: 'closed');
        await _t143MenuPick(
          tester,
          tester.getCenter(_t143Block(1)),
          'Reveal in Finder',
        );
        expect(vault.openCalls, [pic.path]);
        expect(vault.revealCalls, [pic.path]);
        expect(e.opener.opened, isEmpty);
      },
      variant: macOnly,
    );
  });

  group('missing and unavailable images (AC7)', () {
    testWidgets(
      'a missing image shows a muted one line box reading Image not found',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t143Attachment('chart.png');
        await _t143Pump(tester, 'Intro line\n${pic.md}\nOutro line', vault);
        expect(_t143Text(1, 'Image not found · chart.png'), findsOneWidget);
        expect(_t143In(1, find.byType(Image)), findsNothing);
        expect(
          tester.getSize(_t143Block(1)).height,
          moreOrLessEquals(_t143Line(tester), epsilon: 1),
          reason: 'one text line tall',
        );
        final style = tester
            .widget<Text>(_t143In(1, find.byType(Text)).first)
            .style;
        expect(
          style?.color,
          isNot(OmColors.fg0),
          reason: 'muted, not body text',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'offline and old server image rows show Image unavailable offline and Image unavailable',
      (tester) async {
        final hosted = FakeHostedAttachments();
        final offline = _t143Attachment('away.png');
        final old = _t143Attachment('old.png');
        final missing = _t143Attachment('gone.png');
        hosted
          ..answerFailure(offline.path, AttachmentLookupFailure.offline)
          ..answerFailure(old.path, AttachmentLookupFailure.serverTooOld)
          ..answerFailure(missing.path, AttachmentLookupFailure.missing);
        await _t143Pump(
          tester,
          'Intro line\n${offline.md}\n${old.md}\n${missing.md}\nOutro',
          hosted,
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        final line = _t143Line(tester);
        expect(
          _t143Text(1, 'Image unavailable offline · away.png'),
          findsOneWidget,
        );
        expect(_t143Text(2, 'Image unavailable · old.png'), findsOneWidget);
        expect(_t143Text(3, 'Image not found · gone.png'), findsOneWidget);
        for (final r in [1, 2, 3]) {
          expect(
            tester.getSize(_t143Block(r)).height,
            moreOrLessEquals(line, epsilon: 1),
            reason: 'row $r is one line tall',
          );
          expect(_t143In(r, find.byType(Image)), findsNothing);
        }
      },
      variant: macOnly,
    );
  });

  group('file cards (AC8)', () {
    testWidgets(
      'a file card shows an icon the name and its type and size in the excerpt card tokens',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pdf = _t143Attachment('Q3 report.pdf');
        final readme = _t143Attachment('README');
        final heic = _t143Attachment('scan.heic', image: true);
        final linkPng = _t143Attachment('chart.png', image: false);
        vault
          ..putFile(pdf.path, Uint8List(812 * 1024))
          ..putFile(readme.path, Uint8List(3))
          ..putFile(heic.path, Uint8List(2048))
          ..putFile(linkPng.path, testPngBytes(30, 20));
        final pngSize = vault.files[linkPng.path]!.length;
        final text = [
          'Intro line',
          pdf.md,
          readme.md,
          heic.md,
          linkPng.md,
        ].join('\n');
        await _t143Pump(tester, text, vault);
        await tester.pump();
        final expected = <int, (String, String)>{
          1: ('Q3 report.pdf', 'PDF · 812 KB'),
          2: ('README', 'FILE · 3 B'),
          3: ('scan.heic', 'HEIC · 2 KB'),
          4: ('chart.png', attachmentCaption('chart.png', pngSize)),
        };
        for (final MapEntry(key: r, value: (name, caption))
            in expected.entries) {
          expect(_t143Text(r, name), findsOneWidget, reason: 'row $r name');
          expect(_t143Text(r, caption), findsOneWidget, reason: 'row $r');
          expect(_t143In(r, find.byType(Icon)), findsOneWidget);
          expect(_t143In(r, find.byType(Image)), findsNothing);
          // A compact card: narrower than the text column.
          expect(
            tester.getRect(_t143Block(r)).right,
            lessThan(tester.getRect(_t143Row(r)).right - 40),
          );
          // ExcerptCard's border and radius tokens.
          final boxes = tester.widgetList<DecoratedBox>(
            _t143In(r, find.byType(DecoratedBox)),
          );
          expect(
            boxes.any((b) {
              final d = b.decoration;
              return d is BoxDecoration &&
                  d.border is Border &&
                  (d.border! as Border).top.color == OmColors.line2 &&
                  d.borderRadius == BorderRadius.circular(6);
            }),
            isTrue,
            reason: 'row $r card border',
          );
        }
      },
      variant: macOnly,
    );

    testWidgets('a click on a file card opens it through the domain', (
      tester,
    ) async {
      final vault = FakeAttachmentVault();
      final pdf = _t143Attachment('Q3 report.pdf');
      vault.putFile(pdf.path, Uint8List(812 * 1024));
      final e = await _t143Pump(
        tester,
        'Intro line\n${pdf.md}\nOutro line',
        vault,
      );
      expect(_t143Text(1, 'PDF · 812 KB'), findsOneWidget);
      await _t143Click(tester, tester.getCenter(_t143Block(1)));
      expect(vault.openCalls, [pdf.path]);
      expect(vault.revealCalls, isEmpty);
      expect(e.opener.opened, isEmpty, reason: 'never the url opener');
    }, variant: macOnly);

    testWidgets(
      'a secondary click on a file card offers Open and Reveal in Finder',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pdf = _t143Attachment('Q3 report.pdf');
        vault.putFile(pdf.path, Uint8List(812 * 1024));
        await _t143Pump(tester, 'Intro line\n${pdf.md}\nOutro line', vault);
        expect(_t143Text(1, 'PDF · 812 KB'), findsOneWidget);
        await _t143MenuPick(tester, tester.getCenter(_t143Block(1)), 'Open');
        expect(vault.openCalls, [pdf.path]);
        expect(vault.revealCalls, isEmpty);
        await _t143MenuPick(
          tester,
          tester.getCenter(_t143Block(1)),
          'Reveal in Finder',
        );
        expect(vault.openCalls, [pdf.path]);
        expect(vault.revealCalls, [pdf.path]);
      },
      variant: macOnly,
    );

    testWidgets('a click right of a file card puts the caret on its line', (
      tester,
    ) async {
      final vault = FakeAttachmentVault();
      final pdf = _t143Attachment('Q3 report.pdf');
      vault.putFile(pdf.path, Uint8List(812 * 1024));
      await _t143Pump(tester, 'Intro line\n${pdf.md}\nOutro line', vault);
      expect(_t143Text(1, 'PDF · 812 KB'), findsOneWidget);
      final card = tester.getRect(_t143Block(1));
      final row = tester.getRect(_t143Row(1));
      expect(card.right, lessThan(row.right - 40), reason: 'room to its right');
      await _t143Click(
        tester,
        Offset((card.right + row.right) / 2, card.center.dy),
      );
      _t143ExpectCaretOn(tester, 1);
      _t143ExpectRevealed(tester, 1);
      expect(vault.openCalls, isEmpty, reason: 'the card was not clicked');
    }, variant: macOnly);

    testWidgets(
      'a missing file card reads File not found does nothing on click and offers no menu',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pdf = _t143Attachment('Q3 report.pdf');
        final e = await _t143Pump(
          tester,
          'Intro line\n${pdf.md}\nOutro line',
          vault,
        );
        expect(_t143Text(1, 'File not found · Q3 report.pdf'), findsOneWidget);
        final style = tester
            .widget<Text>(_t143In(1, find.byType(Text)).first)
            .style;
        expect(style?.color, isNot(OmColors.fg0), reason: 'muted');
        await _t143Click(tester, tester.getCenter(_t143Block(1)));
        expect(vault.openCalls, isEmpty);
        expect(e.opener.opened, isEmpty);
        await _t143Click(
          tester,
          tester.getCenter(_t143Block(1)),
          buttons: kSecondaryMouseButton,
        );
        expect(find.text('Open'), findsNothing, reason: 'no menu');
        expect(find.text('Reveal in Finder'), findsNothing);
        expect(vault.revealCalls, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets('a hosted card of unknown size shows its type and a dash', (
      tester,
    ) async {
      final hosted = FakeHostedAttachments();
      final pending = _t143Attachment('Q3 report.pdf');
      final offline = _t143Attachment('away.zip');
      final known = _t143Attachment('known.pdf');
      hosted
        ..answerInfo(
          offline.path,
          const AttachmentInfoFailed(AttachmentLookupFailure.offline),
        )
        ..answerFile(known.path, Uint8List(812 * 1024));
      await _t143Pump(
        tester,
        'Intro line\n${pending.md}\n${offline.md}\n${known.md}\nOutro',
        hosted,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(_t143Text(1, 'Q3 report.pdf'), findsOneWidget);
      expect(_t143Text(1, 'PDF · —'), findsOneWidget, reason: 'size pending');
      expect(_t143Text(2, 'away.zip'), findsOneWidget);
      expect(_t143Text(2, 'ZIP · —'), findsOneWidget, reason: 'unreachable');
      expect(_t143Text(3, 'PDF · 812 KB'), findsOneWidget);
      // Once the size arrives it shows.
      hosted.answerInfo(
        pending.path,
        const AttachmentInfoFound(
          AttachmentInfo(size: 4404019, type: 'application/pdf'),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(_t143Text(1, 'PDF · 4.2 MB'), findsOneWidget);
      expect(_t143Text(1, 'PDF · —'), findsNothing);
    }, variant: macOnly);
  });

  group('executables (AC9)', () {
    testWidgets(
      'an executable card click and Open call the domain open and never the url opener',
      (tester) async {
        final vault = FakeAttachmentVault();
        final script = _t143Attachment('setup.sh');
        vault.putFile(script.path, Uint8List(120));
        final e = await _t143Pump(
          tester,
          'Intro line\n${script.md}\nOutro line',
          vault,
        );
        expect(_t143Text(1, 'setup.sh'), findsOneWidget);
        expect(_t143Text(1, 'SH · 120 B'), findsOneWidget);
        await _t143Click(tester, tester.getCenter(_t143Block(1)));
        expect(vault.openCalls, [script.path]);
        await _t143MenuPick(tester, tester.getCenter(_t143Block(1)), 'Open');
        expect(vault.openCalls, [script.path, script.path]);
        expect(
          e.opener.opened.where((u) => u.contains('objects/')),
          isEmpty,
          reason: 'no objects path reaches the url opener',
        );
        expect(e.opener.opened, isEmpty);
      },
      variant: macOnly,
    );
  });

  group('keys (AC11)', () {
    testWidgets(
      'the attachment key wraps only the block box and the row key wraps the text slot',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t143Attachment('chart.png');
        final gone = _t143Attachment('gone.png');
        final pdf = _t143Attachment('Q3 report.pdf');
        vault
          ..putFile(pic.path, testPngBytes(300, 200))
          ..putFile(pdf.path, Uint8List(812 * 1024));
        final text = [
          'Intro line',
          pic.md,
          gone.md,
          pdf.md,
          'Outro line',
        ].join('\n');
        final e = await _t143Pump(tester, text, vault);
        for (final r in [1, 2, 3]) {
          expect(rowsHostOf(tester).rowSpec(r)?.kind, RowKind.attachment);
          expect(_t143Block(r), findsOneWidget, reason: 'row $r block');
        }
        // The image: the block is the image box.
        expect(tester.getSize(_t143Block(1)), const Size(300, 200));
        expect(
          tester.getRect(_t143In(1, find.byType(Image))),
          tester.getRect(_t143Block(1)),
        );
        // The missing placeholder is the block.
        expect(_t143Text(2, 'Image not found · gone.png'), findsOneWidget);
        // The card: the block is the card, not the row.
        expect(_t143Text(3, 'PDF · 812 KB'), findsOneWidget);
        expect(
          tester.getRect(_t143Block(3)).width,
          lessThan(_t143Column(tester, 3)),
        );
        // Neither key holds the other.
        for (final r in [1, 2, 3]) {
          expect(
            find.descendant(of: _t143Block(r), matching: _t143SlotAny(r)),
            findsNothing,
            reason: 'row $r block holds no text slot',
          );
          expect(
            find.descendant(
              of: _t143SlotAny(r),
              matching: find.byKey(ValueKey('editor-attachment-0-$r')),
              skipOffstage: false,
            ),
            findsNothing,
            reason: 'row $r text slot holds no block',
          );
        }
        // Active: the text slot shows under its key, the block under its own.
        await activateRow(tester, 0, 3);
        _t143ExpectRevealed(tester, 3);
        expect(
          tester.getRect(_t143Slot(3)).width,
          moreOrLessEquals(_t143Column(tester, 3), epsilon: 1),
          reason: 'the text slot spans the column',
        );
        await e.body.focusOutside();
      },
      variant: macOnly,
    );

    testWidgets('idle and active share one image decode for the block', (
      tester,
    ) async {
      final vault = FakeAttachmentVault();
      final pic = _t143Attachment('chart.png');
      vault.putFile(pic.path, testPngBytes(300, 200));
      final e = await _t143Pump(
        tester,
        'Intro line\n${pic.md}\nOutro line',
        vault,
      );
      await _t143Settle(tester, () => _t143Decoded(tester, 1) != null);
      final image = _t143In(1, find.byType(Image));
      final state = tester.state(image);
      final decoded = _t143Decoded(tester, 1);
      final reads = vault.readCalls.length;

      await activateRow(tester, 0, 1);
      _t143ExpectRevealed(tester, 1);
      expect(identical(tester.state(image), state), isTrue, reason: 'kept');
      expect(identical(_t143Decoded(tester, 1), decoded), isTrue);

      await e.body.focusOutside();
      _t143ExpectIdle(tester, 1);
      expect(identical(tester.state(image), state), isTrue, reason: 'kept');
      expect(identical(_t143Decoded(tester, 1), decoded), isTrue);
      expect(vault.readCalls.length, reads, reason: 'no new read');
    }, variant: macOnly);
  });

  group('semantics and narrow widths (AC12)', () {
    testWidgets(
      'an image is labelled with its name and a card with its name type and size',
      (tester) async {
        final handle = tester.ensureSemantics();
        final vault = FakeAttachmentVault();
        final pic = _t143Attachment('chart.png');
        final pdf = _t143Attachment('Q3 report.pdf');
        vault
          ..putFile(pic.path, testPngBytes(300, 200))
          ..putFile(pdf.path, Uint8List(812 * 1024));
        await _t143Pump(
          tester,
          'Intro line\n${pic.md}\n${pdf.md}\nOutro line',
          vault,
        );
        expect(
          find.descendant(
            of: _t143Block(1),
            matching: find.bySemanticsLabel('chart.png'),
            matchRoot: true,
          ),
          findsWidgets,
        );
        expect(
          find.descendant(
            of: _t143Block(2),
            matching: find.bySemanticsLabel('Q3 report.pdf, PDF, 812 KB'),
            matchRoot: true,
          ),
          findsWidgets,
        );
        handle.dispose();
      },
      variant: macOnly,
    );

    testWidgets(
      'a 360 px wide editor at text scale 2 shows attachment rows without overflow',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t143Attachment('wide.png');
        final pdf = _t143Attachment(
          'A very long quarterly report name for the whole board.pdf',
        );
        final gone = _t143Attachment('a missing picture with a long name.png');
        vault
          ..putFile(pic.path, testPngBytes(2000, 500))
          ..putFile(pdf.path, Uint8List(812 * 1024));
        await _t143Pump(
          tester,
          'Intro\n${pic.md}\n${pdf.md}\n${gone.md}\nOutro',
          vault,
          width: 360,
          textScale: 2,
        );
        expect(tester.takeException(), isNull, reason: 'no overflow');
        for (final r in [1, 2, 3]) {
          expect(_t143Block(r), findsOneWidget, reason: 'row $r block');
          final block = tester.getRect(_t143Block(r));
          final row = tester.getRect(_t143Row(r));
          expect(block.left, greaterThanOrEqualTo(row.left - 0.5));
          expect(block.right, lessThanOrEqualTo(row.right + 0.5));
        }
        final column = _t143Column(tester, 1);
        expect(
          tester.getSize(_t143In(1, find.byType(Image))).width,
          moreOrLessEquals(column, epsilon: 0.5),
        );
        expect(_t143Text(2, 'PDF · 812 KB'), findsOneWidget);
      },
      variant: macOnly,
    );
  });

  group('Source mode and renames (AC13)', () {
    testWidgets('source mode shows the raw markdown with no image or card', (
      tester,
    ) async {
      final vault = FakeAttachmentVault();
      final pdf = _t143Attachment('Q3 report.pdf');
      final pic = _t143Attachment('chart.png');
      vault
        ..putFile(pdf.path, Uint8List(812 * 1024))
        ..putFile(pic.path, testPngBytes(300, 200));
      final body = 'Intro line\n${pdf.md}\n${pic.md}\nOutro line';
      final e = await pumpSpellingEditor(
        tester,
        body: body,
        overrides: [attachmentsProvider.overrideWithValue(vault)],
      );
      final blocks = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('editor-attachment-'),
      );
      // Live preview: a card and an image.
      expect(blocks, findsNWidgets(2));
      expect(find.text('PDF · 812 KB', findRichText: true), findsOneWidget);
      // Source: the raw markdown only.
      await e.robot.toggleSource();
      expect(blocks, findsNothing);
      expect(find.text('PDF · 812 KB', findRichText: true), findsNothing);
      expect(
        find.descendant(of: e.sourceSurface, matching: find.byType(Image)),
        findsNothing,
      );
      expect(e.robot.sourceText, body);
      // Back to live preview.
      await e.robot.toggleSource();
      expect(blocks, findsNWidgets(2));
    }, variant: macOnly);

    testWidgets(
      'editing the bracketed text changes the shown name and leaves the file unchanged',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pdf = _t143Attachment('Q3 report.pdf');
        final bytes = vault.putFile(pdf.path, Uint8List(812 * 1024));
        final e = await _t143Pump(
          tester,
          'Intro line\n${pdf.md}\nOutro line',
          vault,
        );
        expect(_t143Text(1, 'Q3 report.pdf'), findsOneWidget);
        await activateRow(tester, 0, 1);
        // No extension in the new name: the type, icon and size still come
        // from the stored file name (R38).
        final renamed = pdf.md.replaceFirst('[Q3 report.pdf]', '[Q3 plan]');
        await tester.macEditingValue(renamed);
        await e.body.settleTyping();
        await e.body.focusOutside();
        expect(e.body.text(), 'Intro line\n$renamed\nOutro line');
        expect(rowsHostOf(tester).rowSpec(1)?.kind, RowKind.attachment);
        expect(_t143Text(1, 'Q3 plan'), findsOneWidget);
        expect(_t143Text(1, 'Q3 report.pdf'), findsNothing);
        expect(_t143Text(1, 'PDF · 812 KB'), findsOneWidget);
        expect(
          tester.widget<Icon>(_t143In(1, find.byType(Icon))).icon,
          attachmentTypeIcon('Q3 report.pdf'),
          reason: 'the icon comes from the stored name',
        );
        expect(
          attachmentTypeIcon('Q3 report.pdf'),
          isNot(attachmentTypeIcon('Q3 plan')),
          reason: 'the shown name would give another icon',
        );
        // The file on disk is the same file, and nothing was stored.
        final file = File(vault.absolute(pdf.path));
        expect(file.readAsBytesSync(), bytes);
        final stored = Directory(
          '${vault.vaultPath}/objects',
        ).listSync(recursive: true).whereType<File>().toList();
        expect(stored.map((f) => f.path), [file.path]);
        expect(vault.addCalls, isEmpty);
        expect(vault.addBytesCalls, isEmpty);
        // It still opens the same path.
        await _t143Click(tester, tester.getCenter(_t143Block(1)));
        expect(vault.openCalls, [pdf.path]);
      },
      variant: macOnly,
    );
  });

  group('Source mode and renames (AC13) image form', () {
    testWidgets(
      'renaming an image to text without an extension keeps it an image row',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t143Attachment('chart.png');
        vault.putFile(pic.path, testPngBytes(300, 200));
        final e = await _t143Pump(
          tester,
          'Intro line\n${pic.md}\nOutro line',
          vault,
        );
        await _t143Settle(tester, () => _t143Decoded(tester, 1) != null);
        await activateRow(tester, 0, 1);
        final renamed = pic.md.replaceFirst('![chart.png]', '![my chart]');
        expect(renamed, isNot(pic.md));
        await tester.macEditingValue(renamed);
        await e.body.settleTyping();
        await e.body.focusOutside();
        expect(e.body.text(), 'Intro line\n$renamed\nOutro line');
        expect(rowsHostOf(tester).rowSpec(1)?.kind, RowKind.attachment);
        // The image-form decision comes from the stored name, not the shown
        // one: still an image at its final size, not a file card.
        expect(_t143In(1, find.byType(Image)), findsOneWidget);
        expect(
          tester.getSize(_t143Block(1)).height,
          moreOrLessEquals(200, epsilon: 0.5),
        );
        expect(_t143Text(1, 'PNG · 1 KB'), findsNothing);
      },
      variant: macOnly,
    );
  });

  group('open failure toast (AC14)', () {
    testWidgets(
      'showAttachmentOpenFailure shows the offline toast and nothing for other failures',
      (tester) async {
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (c) {
                  context = c;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        );
        showAttachmentOpenFailure(
          context,
          'Q3 report.pdf',
          AttachmentLookupFailure.offline,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 750));
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.text(_t143OfflineToast('Q3 report.pdf')), findsOneWidget);
        _t143Messenger(tester).removeCurrentSnackBar();
        await tester.pump();
        expect(find.byType(SnackBar), findsNothing);

        for (final failure in [
          AttachmentLookupFailure.missing,
          AttachmentLookupFailure.serverTooOld,
          AttachmentLookupFailure.unsupported,
        ]) {
          showAttachmentOpenFailure(context, 'Q3 report.pdf', failure);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 750));
          expect(find.byType(SnackBar), findsNothing, reason: '$failure');
        }

        // No ScaffoldMessenger: nothing, and no error.
        late BuildContext bare;
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (c) {
                bare = c;
                return const SizedBox();
              },
            ),
          ),
        );
        showAttachmentOpenFailure(
          bare,
          'Q3 report.pdf',
          AttachmentLookupFailure.offline,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an offline open from a file card click or its menu Open shows the toast',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pdf = _t143Attachment('Q3 report.pdf');
        vault.putFile(pdf.path, Uint8List(812 * 1024));
        vault.openResults
          ..add(const AttachmentActionFailed(AttachmentLookupFailure.offline))
          ..add(const AttachmentActionFailed(AttachmentLookupFailure.offline));
        await _t143Pump(tester, 'Intro line\n${pdf.md}\nOutro line', vault);
        expect(_t143Text(1, 'PDF · 812 KB'), findsOneWidget);

        await _t143Click(tester, tester.getCenter(_t143Block(1)));
        await tester.pump(const Duration(milliseconds: 750));
        expect(vault.openCalls, [pdf.path]);
        expect(find.text(_t143OfflineToast('Q3 report.pdf')), findsOneWidget);
        _t143Messenger(tester).removeCurrentSnackBar();
        await tester.pump();

        await _t143MenuPick(tester, tester.getCenter(_t143Block(1)), 'Open');
        await tester.pump(const Duration(milliseconds: 750));
        expect(vault.openCalls, [pdf.path, pdf.path]);
        expect(find.text(_t143OfflineToast('Q3 report.pdf')), findsOneWidget);
      },
      variant: macOnly,
    );

    testWidgets(
      'an offline open from a mid text attachment link shows the toast',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pdf = _t143Attachment('Q3 report.pdf');
        vault.putFile(pdf.path, Uint8List(812 * 1024));
        vault.openResults.add(
          const AttachmentActionFailed(AttachmentLookupFailure.offline),
        );
        final e = await _t143Pump(tester, 'See ${pdf.md} here\nother', vault);
        expect(rowsHostOf(tester).rowSpec(0)?.kind, RowKind.prose);
        await _t143Click(tester, _t143PointOn(tester, 0, 'report'));
        await tester.pump(const Duration(milliseconds: 750));
        expect(vault.openCalls, [pdf.path]);
        expect(find.text(_t143OfflineToast('Q3 report.pdf')), findsOneWidget);
        expect(e.opener.opened, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets('missing and unsupported open results show no toast', (
      tester,
    ) async {
      final vault = FakeAttachmentVault();
      final pdf = _t143Attachment('Q3 report.pdf');
      vault.putFile(pdf.path, Uint8List(812 * 1024));
      vault.openResults
        ..add(const AttachmentActionFailed(AttachmentLookupFailure.missing))
        ..add(const AttachmentActionFailed(AttachmentLookupFailure.unsupported))
        ..add(const AttachmentActionFailed(AttachmentLookupFailure.missing));
      await _t143Pump(
        tester,
        'Intro line\n${pdf.md}\nSee ${pdf.md} here',
        vault,
      );
      expect(_t143Text(1, 'PDF · 812 KB'), findsOneWidget);
      for (var i = 0; i < 2; i++) {
        await _t143Click(tester, tester.getCenter(_t143Block(1)));
        await tester.pump(const Duration(milliseconds: 750));
        expect(find.byType(SnackBar), findsNothing, reason: 'click $i');
      }
      await _t143Click(tester, _t143PointOn(tester, 2, 'report'));
      await tester.pump(const Duration(milliseconds: 750));
      expect(vault.openCalls, [pdf.path, pdf.path, pdf.path]);
      expect(find.byType(SnackBar), findsNothing, reason: 'mid text link');
    }, variant: macOnly);
  });
}
