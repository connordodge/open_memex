// WI #143 (Spec #123 V3): the contracts of the attachment row's pieces that
// `attachment_row_test.dart` reaches only through the whole editor, pinned
// one by one: the pure helpers (header parsing, sizing, caps, shown name,
// icons), the presenter's seam answers (`textHidden`, `blockBoxes`,
// `ownsPress`), the public card, notice and image widgets that excerpt cards
// reuse (#144), and a few editor-level paths (no domain, secondary click on
// an inert block, offline Reveal, a header deep in a JPEG, hosted caps).
//
// Every helper here carries the `_v143` prefix. Paths are invented (public
// repo) and unique per test, since sizes cache per path for the session.
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/editor/attachment_ref.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/attachments_access.dart';
import 'package:open_memex_app/src/widgets/editor/attachment_row.dart';
import 'package:open_memex_app/src/widgets/editor/find_decoration.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/row_kinds.dart';

import '../../support/attachments_fakes.dart';
import '../../support/editor_rows_probe.dart';
import '../../support/editor_scope.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/table_harness.dart';

int _v143Ids = 5000;

/// A fresh attachment named [name]: its decoded path and its reference
/// markdown (image form when [image]).
({String path, String md}) _v143Attachment(String name, {bool image = false}) {
  final n = ++_v143Ids;
  return (
    path: testAttachmentPath(n, name),
    md:
        '${image ? '!' : ''}[$name](objects/5e/${testAttachmentHash(n)}/'
        '${encodeAttachmentName(name)})',
  );
}

List<int> _v143Be16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
List<int> _v143Le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _v143Le24(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF];
List<int> _v143Le32(int v) => [..._v143Le24(v), (v >> 24) & 0xFF];

/// A JPEG segment of [marker] holding [payload].
List<int> _v143JpegSegment(int marker, List<int> payload) => [
  0xFF,
  marker,
  ..._v143Be16(payload.length + 2),
  ...payload,
];

/// A start-of-frame segment of [marker] for a [w] x [h] image.
List<int> _v143Sof(int marker, int w, int h) => _v143JpegSegment(marker, [
  8,
  ..._v143Be16(h),
  ..._v143Be16(w),
  3,
  1,
  0x22,
  0,
  2,
  0x11,
  1,
  3,
  0x11,
  1,
]);

/// SOI, then [parts].
List<int> _v143Jpeg(List<List<int>> parts) => [
  0xFF,
  0xD8,
  for (final p in parts) ...p,
];

/// A WebP file: `RIFF`, `WEBP`, then one chunk [fourcc] holding [body].
Uint8List _v143Webp(String fourcc, List<int> body) {
  final chunk = [...fourcc.codeUnits, ..._v143Le32(body.length), ...body];
  return Uint8List.fromList([
    ...'RIFF'.codeUnits,
    ..._v143Le32(4 + chunk.length),
    ...'WEBP'.codeUnits,
    ...chunk,
  ]);
}

/// A GIF header: [signature], then [w] and [h] little-endian.
List<int> _v143GifHeader(String signature, int w, int h) => [
  ...signature.codeUnits,
  ..._v143Le16(w),
  ..._v143Le16(h),
  0,
  0,
  0,
];

/// What [_v143MountPresenter] mounted: the presenter's row, its slot calls.
final class _V143Mounted {
  _V143Mounted(this.controller, this.row, this.gate, this.slots, this.block);

  final LivePreviewController controller;
  final PresentedRow row;
  final ValueNotifier<bool> gate;

  /// The `offstage` of every text slot call, in order.
  final List<bool> slots;

  /// The block's global rect, once it is laid out.
  Rect Function(WidgetTester tester) block;
}

/// Mounts `AttachmentRowPresenter.build` on a row of [text] over [access]
/// (D2 seam), outside any editor.
Future<_V143Mounted> _v143MountPresenter(
  WidgetTester tester,
  String text,
  AttachmentsAccess? access,
) async {
  final controller = LivePreviewController(text: text);
  final gate = ValueNotifier(false);
  addTearDown(controller.dispose);
  addTearDown(gate.dispose);
  controller.revealGate = gate;
  final blockKey = GlobalKey(debugLabel: 'v143-block');
  final row = PresentedRow(
    segment: 0,
    index: 1,
    kind: RowKind.attachment,
    controller: controller,
    blockKey: blockKey,
  );
  final slots = <bool>[];
  await pumpEditorScoped(
    tester,
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 600,
            child: Builder(
              builder: (context) => const AttachmentRowPresenter().build(
                context,
                row,
                ({required bool offstage}) {
                  slots.add(offstage);
                  return Offstage(
                    offstage: offstage,
                    child: const SizedBox(
                      key: ValueKey('v143-slot'),
                      height: 18,
                      width: 600,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
    overrides: [attachmentsProvider.overrideWithValue(access)],
  );
  await tester.pump();
  return _V143Mounted(
    controller,
    row,
    gate,
    slots,
    (t) => t.getRect(find.byKey(blockKey)),
  );
}

/// A PDF reference line padded with spaces on both sides, over a vault that
/// holds its file, so the presenter shows a file card.
Future<_V143Mounted> _v143MountCard(WidgetTester tester) async {
  final vault = FakeAttachmentVault();
  final pdf = _v143Attachment('doc.pdf');
  vault.putFile(pdf.path, Uint8List(2048));
  return _v143MountPresenter(tester, '  ${pdf.md}   ', vault);
}

/// Reveals the row as the segment does: the gate open, a valid selection.
Future<void> _v143Reveal(WidgetTester tester, _V143Mounted m) async {
  m.controller.selection = const TextSelection.collapsed(offset: 3);
  m.gate.value = true;
  await tester.pump();
}

/// Pumps a lone [child] at the top left of a window.
Future<void> _v143PumpAt(WidgetTester tester, Widget child) =>
    tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    );

/// The BoxDecoration of the first Container in [of].
BoxDecoration _v143Decoration(WidgetTester tester, Finder of) {
  final container = find.descendant(of: of, matching: find.byType(Container));
  return tester.widget<Container>(container.first).decoration! as BoxDecoration;
}

/// A mouse pointer parked away from everything.
Future<TestGesture> _v143Mouse(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(790, 590));
  addTearDown(mouse.removePointer);
  await tester.pump();
  return mouse;
}

/// The segmented editor on [text] over [attachments].
Future<TableBody> _v143PumpEditor(
  WidgetTester tester,
  String text,
  AttachmentsAccess? attachments,
) async {
  final body = await pumpTable(
    tester,
    text,
    overrides: [attachmentsProvider.overrideWithValue(attachments)],
  );
  await tester.pump();
  return body;
}

Finder _v143Block(int r) => find.byKey(ValueKey('editor-attachment-0-$r'));

Finder _v143Text(int r, String text) => find.descendant(
  of: _v143Block(r),
  matching: find.text(text, findRichText: true),
);

Future<void> _v143Click(
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

Future<void> _v143Settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 60 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(done(), isTrue);
}

void main() {
  holdFontFetches();

  group('image header sizes (AC2, AC4)', () {
    test('a PNG header gives its pixel size and a bad one gives none', () {
      expect(
        attachmentImageDims(testPngHeaderOnly(123, 45)),
        const Size(123, 45),
      );
      expect(attachmentImageDims(testPngHeaderOnly(0, 45)), isNull);
      expect(attachmentImageDims(testPngHeaderOnly(123, 0)), isNull);
      final png = testPngHeaderOnly(123, 45);
      expect(attachmentImageDims(png.sublist(0, 24)), const Size(123, 45));
      expect(attachmentImageDims(png.sublist(0, 23)), isNull, reason: 'cut');
      final noIhdr = Uint8List.fromList(png)..[12] = 0x58;
      expect(attachmentImageDims(noIhdr), isNull, reason: 'no IHDR');
      final noMagic = Uint8List.fromList(png)..[0] = 0x88;
      expect(attachmentImageDims(noMagic), isNull, reason: 'not a PNG');
      expect(attachmentImageDims(const <int>[]), isNull);
    });

    test('a GIF header gives its pixel size and a bad one gives none', () {
      expect(
        attachmentImageDims(_v143GifHeader('GIF89a', 300, 200)),
        const Size(300, 200),
      );
      expect(
        attachmentImageDims(_v143GifHeader('GIF87a', 513, 258)),
        const Size(513, 258),
      );
      final gif = _v143GifHeader('GIF89a', 300, 200);
      expect(attachmentImageDims(gif.sublist(0, 10)), const Size(300, 200));
      expect(attachmentImageDims(gif.sublist(0, 9)), isNull, reason: 'cut');
      expect(attachmentImageDims(_v143GifHeader('GIF88a', 300, 200)), isNull);
      expect(attachmentImageDims(_v143GifHeader('GIF89a', 0, 200)), isNull);
      expect(attachmentImageDims(_v143GifHeader('GIF89a', 300, 0)), isNull);
    });

    test('a JPEG header gives its pixel size from any frame marker', () {
      // Width and height are read from their own offsets.
      expect(
        attachmentImageDims(_v143Jpeg([_v143Sof(0xC0, 640, 480)])),
        const Size(640, 480),
      );
      for (final marker in [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xCA, 0xCF]) {
        expect(
          attachmentImageDims(_v143Jpeg([_v143Sof(marker, 321, 123)])),
          const Size(321, 123),
          reason: 'marker ${marker.toRadixString(16)}',
        );
      }
      // Segments before the frame are skipped by their length.
      final app0 = _v143JpegSegment(0xE0, List.filled(14, 0x31));
      final dqt = _v143JpegSegment(0xDB, List.filled(65, 0x07));
      expect(
        attachmentImageDims(_v143Jpeg([app0, dqt, _v143Sof(0xC0, 800, 600)])),
        const Size(800, 600),
      );
      // DHT, JPG and DAC segments are not frames (their bytes mimic one).
      for (final marker in [0xC4, 0xC8, 0xCC]) {
        final decoy = _v143JpegSegment(marker, List.filled(16, 0x07));
        expect(
          attachmentImageDims(_v143Jpeg([decoy, _v143Sof(0xC0, 800, 600)])),
          const Size(800, 600),
          reason: 'marker ${marker.toRadixString(16)} is not a frame',
        );
      }
      // Fill bytes, restarts and the stand-alone markers hold no length.
      for (final lone in [
        [0xFF],
        [0xFF, 0x01],
        [0xFF, 0xD0],
        [0xFF, 0xD7],
        [0xFF, 0xD8],
      ]) {
        expect(
          attachmentImageDims(_v143Jpeg([lone, _v143Sof(0xC0, 800, 600)])),
          const Size(800, 600),
          reason: 'before it: $lone',
        );
      }
      // Marker bytes that are no frame and no stand-alone marker (0xBF,
      // 0xE0) keep their length.
      expect(
        attachmentImageDims(
          _v143Jpeg([
            _v143JpegSegment(0xBF, [0xC0, 0xC0, 0xC0]),
            _v143Sof(0xC0, 800, 600),
          ]),
        ),
        const Size(800, 600),
      );
    });

    test('a JPEG header that is cut short or malformed gives none', () {
      final sof = _v143Jpeg([_v143Sof(0xC0, 640, 480)]);
      // The frame's width is its last needed byte: 11 bytes are enough.
      expect(attachmentImageDims(sof.sublist(0, 11)), const Size(640, 480));
      expect(attachmentImageDims(sof.sublist(0, 10)), isNull, reason: 'cut');
      // Image data (SOS) or the end (EOI) before any frame.
      expect(
        attachmentImageDims(
          _v143Jpeg([
            _v143JpegSegment(0xDA, [1, 2, 3]),
            _v143Sof(0xC0, 640, 480),
          ]),
        ),
        isNull,
      );
      expect(
        attachmentImageDims(
          _v143Jpeg([
            [0xFF, 0xD9],
            _v143Sof(0xC0, 640, 480),
          ]),
        ),
        isNull,
      );
      // A byte that is no marker where a marker belongs.
      expect(
        attachmentImageDims(
          _v143Jpeg([
            [0x00, 0x00, 0x00, 0x00],
            _v143Sof(0xC0, 640, 480),
          ]),
        ),
        isNull,
      );
      // A length below 2.
      expect(
        attachmentImageDims([
          0xFF,
          0xD8,
          0xFF,
          0xE0,
          0x00,
          0x01,
          ..._v143Sof(0xC0, 640, 480),
        ]),
        isNull,
      );
      // No bytes after the start of image.
      expect(attachmentImageDims(const [0xFF, 0xD8]), isNull);
      expect(attachmentImageDims(const [0xFF, 0xD8, 0xFF]), isNull);
      // A frame of no pixels.
      expect(attachmentImageDims(_v143Jpeg([_v143Sof(0xC0, 0, 480)])), isNull);
      expect(attachmentImageDims(_v143Jpeg([_v143Sof(0xC0, 640, 0)])), isNull);
    });

    test('a WebP header gives its pixel size for every chunk kind', () {
      // Lossy: 14-bit sizes at 26 and 28, the top bits are a scale.
      final vp8 = _v143Webp('VP8 ', [
        0,
        0,
        0,
        0x9D,
        0x01,
        0x2A,
        ..._v143Le16(640 | 0x4000),
        ..._v143Le16(480 | 0xC000),
      ]);
      expect(attachmentImageDims(vp8), const Size(640, 480));
      // Lossless: width - 1 in 14 bits, then height - 1 in 14 bits.
      final bits = (1234 - 1) | ((567 - 1) << 14);
      final vp8l = _v143Webp('VP8L', [0x2F, ..._v143Le32(bits), 0, 0, 0, 0, 0]);
      expect(attachmentImageDims(vp8l), const Size(1234, 567));
      final noSignature = _v143Webp('VP8L', [
        0x2E,
        ..._v143Le32(bits),
        0,
        0,
        0,
        0,
        0,
      ]);
      expect(attachmentImageDims(noSignature), isNull);
      // Extended: width - 1 and height - 1 in 24 bits at 24 and 27.
      final vp8x = _v143Webp('VP8X', [
        0,
        0,
        0,
        0,
        ..._v143Le24(20000 - 1),
        ..._v143Le24(30000 - 1),
      ]);
      expect(attachmentImageDims(vp8x), const Size(20000, 30000));
      // Anything else, or cut short.
      expect(
        attachmentImageDims(_v143Webp('VP8Z', List.filled(10, 1))),
        isNull,
      );
      expect(attachmentImageDims(vp8x.sublist(0, 29)), isNull, reason: 'cut');
      expect(
        attachmentImageDims(vp8x.sublist(0, 30)),
        const Size(20000, 30000),
      );
      final notWebp = Uint8List.fromList(vp8x)..[8] = 0x58;
      expect(attachmentImageDims(notWebp), isNull);
      final notRiff = Uint8List.fromList(vp8x)..[0] = 0x58;
      expect(attachmentImageDims(notRiff), isNull);
      // A lossy frame of no pixels.
      final empty = _v143Webp('VP8 ', [
        0,
        0,
        0,
        0x9D,
        0x01,
        0x2A,
        ..._v143Le16(0),
        ..._v143Le16(480),
      ]);
      expect(attachmentImageDims(empty), isNull);
    });
  });

  group('image sizing and caps (AC2, AC4)', () {
    test('an image scales down to the column and 480 px but never up', () {
      Size fit(double w, double h, double column) =>
          attachmentImageSize(Size(w, h), column);
      expect(fit(200, 100, 1000), const Size(200, 100), reason: 'never up');
      expect(fit(1000, 400, 1000), const Size(1000, 400), reason: 'exact');
      expect(fit(2000, 500, 1000), const Size(1000, 250), reason: 'width');
      expect(fit(600, 1200, 1000), const Size(240, 480), reason: 'height');
      expect(fit(300, 480, 1000), const Size(300, 480), reason: 'at 480');
      expect(fit(300, 481, 1000).height, moreOrLessEquals(480, epsilon: 1e-9));
      expect(fit(2000, 2000, 1000), const Size(480, 480), reason: 'height');
      expect(fit(2000, 600, 1000), const Size(1000, 300), reason: 'width');
      expect(fit(600, 1200, 100), const Size(100, 200), reason: 'tight');
      expect(
        attachmentImageSize(const Size(2000, 500), double.infinity),
        const Size(1920, 480),
        reason: 'unbounded: the height cap only',
      );
      expect(attachmentImageSize(Size.zero, 500), Size.zero);
      expect(attachmentImageSize(const Size(0, 10), 500), Size.zero);
      expect(attachmentImageSize(const Size(10, 0), 500), Size.zero);
      expect(attachmentImageSize(const Size(-5, 10), 500), Size.zero);
      expect(attachmentImageSize(const Size(10, -5), 500), Size.zero);
    });

    test('an image is over a cap above 100 megapixels or 30 MB only', () {
      const mb30 = 30 * 1024 * 1024;
      bool over({Size? dims, int? bytes}) =>
          attachmentImageOverCap(dims: dims, bytes: bytes);
      expect(over(), isFalse);
      expect(over(dims: const Size(10000, 10000)), isFalse, reason: '100 MP');
      expect(over(dims: const Size(10000, 10001)), isTrue);
      expect(over(dims: const Size(20000, 5001)), isTrue);
      expect(over(dims: const Size(1, 1)), isFalse);
      expect(over(bytes: mb30), isFalse, reason: '30 MB');
      expect(over(bytes: mb30 + 1), isTrue);
      expect(over(bytes: 0), isFalse);
      expect(over(dims: const Size(1, 1), bytes: mb30), isFalse);
      expect(over(dims: const Size(1, 1), bytes: mb30 + 1), isTrue);
      expect(over(dims: const Size(10000, 10001), bytes: 10), isTrue);
    });
  });

  group('shown names and icons (AC13, AC8)', () {
    test('the shown name is the bracketed text without its escapes', () {
      final image = parseAttachmentReference(
        '![chart](objects/5e/${testAttachmentHash(1)}/chart.png)',
      )!;
      final link = parseAttachmentReference(
        '[doc.pdf](objects/5e/${testAttachmentHash(2)}/doc.pdf)',
      )!;
      expect(attachmentShownName('![chart](x)', image), 'chart');
      expect(attachmentShownName('[Q3 plan](x)', link), 'Q3 plan');
      // The brackets' own start is skipped by kind: 2 for an image, 1 for a
      // link.
      expect(attachmentShownName('![a](x)', image), 'a');
      expect(attachmentShownName('[a](x)', link), 'a');
      // Empty brackets show the stored name.
      expect(attachmentShownName('![](x)', image), 'chart.png');
      expect(attachmentShownName('[](x)', link), 'doc.pdf');
      // Backslash escapes of ASCII punctuation drop their backslash.
      for (final c in r'!"#$%&()*+,-./:;<=>?@[\]^_`{|}~'.split('')) {
        expect(
          attachmentShownName('![a\\${c}b](x)', image),
          'a${c}b',
          reason: 'escaped $c',
        );
      }
      // Other characters keep it, whatever their neighbours.
      for (final c in [' ', '0', '9', 'A', 'Z', 'a', 'z', '\u007F', 'é']) {
        expect(
          attachmentShownName('![a\\${c}b](x)', image),
          'a\\${c}b',
          reason: 'not an escape: $c',
        );
      }
      expect(attachmentShownName(r'![a\\b](x)', image), r'a\b');
      expect(attachmentShownName(r'![a\]b](x)', image), 'a]b');
      expect(attachmentShownName(r'![x\', image), r'x\', reason: 'trailing');
      expect(attachmentShownName('![ab', image), 'ab', reason: 'unclosed');
    });

    test(
      'a file type group shows its lucide icon and an executable its own',
      () {
        final groups = <IconData, List<String>>{
          LucideIcons.fileImage: [
            'png',
            'jpg',
            'jpeg',
            'gif',
            'webp',
            'heic',
            'heif',
            'tif',
            'tiff', //
            'bmp', 'svg', 'avif',
          ],
          LucideIcons.fileVideo: ['mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm'],
          LucideIcons.fileAudio: [
            'mp3', 'm4a', 'wav', 'aac', 'flac', 'ogg', 'aif', 'aiff', //
          ],
          LucideIcons.fileArchive: [
            'zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', //
          ],
          LucideIcons.fileSpreadsheet: [
            'csv', 'tsv', 'xls', 'xlsx', 'numbers', 'ods', //
          ],
          LucideIcons.fileCode: [
            'json', 'js', 'ts', 'dart', 'rs', 'go', 'c', 'h', 'cpp', 'java', //
            'kt', 'swift', 'html', 'css', 'xml', 'yaml', 'yml', 'toml',
          ],
          LucideIcons.fileText: [
            'pdf', 'txt', 'md', 'rtf', 'doc', 'docx', 'pages', 'odt', 'epub', //
          ],
          LucideIcons.fileTerminal: [
            'sh', 'command', 'py', 'exe', 'app', 'dmg', 'jar', //
          ],
          LucideIcons.file: ['xyz', 'bin', 'dat'],
        };
        for (final MapEntry(key: icon, value: extensions) in groups.entries) {
          for (final ext in extensions) {
            expect(attachmentTypeIcon('thing.$ext'), icon, reason: '.$ext');
            expect(
              attachmentTypeIcon('THING.${ext.toUpperCase()}'),
              icon,
              reason: '.${ext.toUpperCase()}',
            );
          }
        }
        expect(attachmentTypeIcon('README'), LucideIcons.file);
        expect(attachmentTypeIcon('trailing.'), LucideIcons.file);
        expect(attachmentTypeIcon('a.tar.gz'), LucideIcons.fileArchive);
        expect(attachmentTypeIcon('.png'), LucideIcons.fileImage);
      },
    );
  });

  group('presenter seam answers (AC5, AC6, AC8)', () {
    testWidgets(
      'a reference row hides its text until the gate and a valid selection reveal it',
      (tester) async {
        final m = await _v143MountCard(tester);
        const presenter = AttachmentRowPresenter();
        expect(m.slots.last, isTrue, reason: 'idle: the text slot is offstage');
        expect(presenter.textHidden(m.row), isTrue);

        // The gate alone, or a selection alone, does not reveal.
        m.controller.selection = const TextSelection.collapsed(offset: -1);
        m.gate.value = true;
        await tester.pump();
        expect(presenter.textHidden(m.row), isTrue, reason: 'no selection');
        expect(m.slots.last, isTrue);
        m.gate.value = false;
        m.controller.selection = const TextSelection.collapsed(offset: 3);
        await tester.pump();
        expect(presenter.textHidden(m.row), isTrue, reason: 'gate closed');
        expect(m.slots.last, isTrue);

        // Both: revealed.
        m.gate.value = true;
        await tester.pump();
        expect(presenter.textHidden(m.row), isFalse);
        expect(m.slots.last, isFalse);

        // The selection leaves: hidden again.
        m.controller.selection = const TextSelection.collapsed(offset: -1);
        await tester.pump();
        expect(presenter.textHidden(m.row), isTrue);
        expect(m.slots.last, isTrue);
      },
    );

    testWidgets(
      'a Find reveal range shows the row text and an empty decoration does not',
      (tester) async {
        final m = await _v143MountCard(tester);
        const presenter = AttachmentRowPresenter();
        final find = ValueNotifier<FindDecoration?>(null);
        addTearDown(find.dispose);
        m.controller.findDecoration = find;
        await tester.pump();
        expect(presenter.textHidden(m.row), isTrue, reason: 'no decoration');

        // Ink without a reveal range (a visible match) keeps it hidden.
        find.value = const FindDecoration(
          inkRanges: [TextRange(start: 3, end: 6)],
          current: TextRange(start: 3, end: 6),
        );
        await tester.pump();
        expect(presenter.textHidden(m.row), isTrue, reason: 'ink only');
        expect(m.slots.last, isTrue);

        // The current match is hidden: Find reveals the line.
        find.value = const FindDecoration(
          revealRange: TextRange(start: 3, end: 6),
          inkRanges: [TextRange(start: 3, end: 6)],
          current: TextRange(start: 3, end: 6),
        );
        await tester.pump();
        expect(
          presenter.textHidden(m.row),
          isFalse,
          reason: 'revealed by Find',
        );
        expect(m.slots.last, isFalse);
        expect(presenter.blockBoxes(m.row), isNull);

        find.value = null;
        await tester.pump();
        expect(presenter.textHidden(m.row), isTrue);
        expect(m.slots.last, isTrue);
      },
    );

    testWidgets('a row whose text is no reference shows its text slot alone', (
      tester,
    ) async {
      final m = await _v143MountPresenter(
        tester,
        'plain words',
        FakeAttachmentVault(),
      );
      const presenter = AttachmentRowPresenter();
      expect(m.slots.last, isFalse);
      expect(presenter.textHidden(m.row), isFalse);
      expect(presenter.blockBoxes(m.row), isNull);
      expect(presenter.ownsPress(m.row, const Offset(5, 5)), isFalse);
      expect(find.byKey(const ValueKey('editor-attachment-0-1')), findsNothing);
      expect(find.byKey(const ValueKey('v143-slot')), findsOneWidget);
    });

    testWidgets('block line boxes span the block and hold the whole row text', (
      tester,
    ) async {
      final m = await _v143MountCard(tester);
      const presenter = AttachmentRowPresenter();
      final boxes = presenter.blockBoxes(m.row);
      expect(boxes, isNotNull);
      final rect = m.block(tester);
      expect(boxes!.box.size, rect.size);
      expect(boxes.box.localToGlobal(Offset.zero), rect.topLeft);
      final line = boxes.lines.single;
      // The row text counts its padding spaces too.
      expect(
        m.controller.text.length,
        greaterThan(m.controller.text.trim().length),
      );
      expect(line.range, TextRange(start: 0, end: m.controller.text.length));
      expect(line.bottom, rect.height);
      expect(line.top, 0);

      await _v143Reveal(tester, m);
      expect(presenter.blockBoxes(m.row), isNull, reason: 'revealed: no block');
    });

    testWidgets('the block owns presses inside its painted rect only', (
      tester,
    ) async {
      final m = await _v143MountCard(tester);
      const presenter = AttachmentRowPresenter();
      final r = m.block(tester);
      expect(r.width, lessThan(600), reason: 'a card, narrower than the row');
      bool owns(Offset p) => presenter.ownsPress(m.row, p);
      expect(owns(r.center), isTrue);
      expect(owns(r.topLeft), isTrue, reason: 'top left edge is inside');
      expect(owns(r.bottomRight - const Offset(0.01, 0.01)), isTrue);
      expect(owns(r.topRight - const Offset(0.01, 0)), isTrue);
      expect(owns(r.topLeft + Offset(0, r.height - 0.01)), isTrue);
      expect(owns(Offset(r.right, r.center.dy)), isFalse, reason: 'right edge');
      expect(owns(Offset(r.right + 20, r.center.dy)), isFalse);
      expect(owns(Offset(r.left - 0.01, r.center.dy)), isFalse);
      expect(owns(Offset(r.center.dx, r.top - 0.01)), isFalse);
      expect(owns(Offset(r.center.dx, r.bottom)), isFalse, reason: 'bottom');

      // Revealed, the block below the text line still owns its presses.
      await _v143Reveal(tester, m);
      expect(owns(m.block(tester).center), isTrue);
      expect(owns(Offset(m.block(tester).right + 20, r.center.dy)), isFalse);

      // The text became no reference (before the next build): no press.
      m.controller.value = const TextEditingValue(text: 'plain words');
      expect(owns(m.block(tester).center), isFalse);
      expect(presenter.textHidden(m.row), isFalse);
    });

    testWidgets(
      'a row without a laid out block owns no press and measures nothing',
      (tester) async {
        final m = await _v143MountCard(tester);
        const presenter = AttachmentRowPresenter();
        final unmounted = PresentedRow(
          segment: 0,
          index: 1,
          kind: RowKind.attachment,
          controller: m.controller,
          blockKey: GlobalKey(),
        );
        expect(presenter.textHidden(unmounted), isTrue);
        expect(presenter.blockBoxes(unmounted), isNull);
        expect(presenter.ownsPress(unmounted, const Offset(10, 10)), isFalse);
        final keyless = PresentedRow(
          segment: 0,
          index: 1,
          kind: RowKind.attachment,
          controller: m.controller,
        );
        expect(presenter.blockBoxes(keyless), isNull);
        expect(presenter.ownsPress(keyless, const Offset(10, 10)), isFalse);
      },
    );
  });

  group('file card, notice and image widgets (AC7, AC8, AC12)', () {
    testWidgets(
      'a file card is raised while the mouse is over it and shows a click cursor',
      (tester) async {
        await _v143PumpAt(
          tester,
          const AttachmentFileCard(
            name: 'doc.pdf',
            type: 'PDF',
            icon: LucideIcons.fileText,
            size: '2 KB',
          ),
        );
        final card = find.byType(AttachmentFileCard);
        expect(_v143Decoration(tester, card).color, OmColors.surface3);
        final mouse = await _v143Mouse(tester);
        await mouse.moveTo(tester.getCenter(card));
        await tester.pump();
        expect(_v143Decoration(tester, card).color, OmColors.surface4);
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.click,
        );
        await mouse.moveTo(const Offset(790, 590));
        await tester.pump();
        expect(_v143Decoration(tester, card).color, OmColors.surface3);
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          isNot(SystemMouseCursors.click),
        );
        // In again, then out through the card's own edge.
        await mouse.moveTo(tester.getCenter(card));
        await tester.pump();
        expect(_v143Decoration(tester, card).color, OmColors.surface4);
        await mouse.moveTo(
          tester.getRect(card).bottomRight + const Offset(2, 2),
        );
        await tester.pump();
        expect(_v143Decoration(tester, card).color, OmColors.surface3);
      },
    );

    testWidgets(
      'a missing file card is never raised and shows no click cursor',
      (tester) async {
        await _v143PumpAt(
          tester,
          const AttachmentFileCard(
            name: 'doc.pdf',
            type: 'PDF',
            icon: LucideIcons.fileText,
            missing: true,
          ),
        );
        final card = find.byType(AttachmentFileCard);
        final mouse = await _v143Mouse(tester);
        await mouse.moveTo(tester.getCenter(card));
        await tester.pump();
        expect(_v143Decoration(tester, card).color, OmColors.surface3);
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          isNot(SystemMouseCursors.click),
        );
        final icon = tester.widget<Icon>(find.byType(Icon));
        expect(icon.color, OmColors.fg3, reason: 'a muted icon');
      },
    );

    testWidgets(
      'a file card is one leaf semantics node labelled with its name type and size',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _v143PumpAt(
          tester,
          const Column(
            children: [
              AttachmentFileCard(
                name: 'doc.pdf',
                type: 'PDF',
                icon: LucideIcons.fileText,
                size: '2 KB',
              ),
              AttachmentFileCard(
                name: 'later.zip',
                type: 'ZIP',
                icon: LucideIcons.fileArchive,
              ),
              AttachmentFileCard(
                name: 'gone.pdf',
                type: 'PDF',
                icon: LucideIcons.fileText,
                missing: true,
              ),
            ],
          ),
        );
        final cards = find.byType(AttachmentFileCard);
        final known = tester.getSemantics(cards.at(0));
        expect(
          known,
          matchesSemantics(label: 'doc.pdf, PDF, 2 KB', isButton: true),
        );
        expect(known.childrenCount, 0, reason: 'excludeSemantics: a leaf');
        final unknown = tester.getSemantics(cards.at(1));
        expect(
          unknown,
          matchesSemantics(label: 'later.zip, ZIP', isButton: true),
        );
        expect(unknown.childrenCount, 0);
        final missing = tester.getSemantics(cards.at(2));
        expect(missing, matchesSemantics(label: 'File not found · gone.pdf'));
        expect(missing.childrenCount, 0);
        handle.dispose();
      },
    );

    testWidgets(
      'a file card caption shows the type and size and a dash while the size is unknown',
      (tester) async {
        await _v143PumpAt(
          tester,
          const Column(
            children: [
              AttachmentFileCard(
                name: 'doc.pdf',
                type: 'PDF',
                icon: LucideIcons.fileText,
                size: '2 KB',
              ),
              AttachmentFileCard(
                name: 'later.zip',
                type: 'ZIP',
                icon: LucideIcons.fileArchive,
              ),
            ],
          ),
        );
        expect(find.text('PDF · 2 KB'), findsOneWidget);
        expect(find.text('ZIP · —'), findsOneWidget);
        expect(find.text('doc.pdf'), findsOneWidget);
        // At most 360 px wide, however long the name.
        await _v143PumpAt(
          tester,
          SizedBox(
            width: 800,
            child: Column(
              children: [
                AttachmentFileCard(
                  name: 'n' * 200,
                  type: 'PDF',
                  icon: LucideIcons.fileText,
                  size: '2 KB',
                ),
              ],
            ),
          ),
        );
        expect(
          tester.getSize(find.byType(AttachmentFileCard)).width,
          AttachmentFileCard.maxWidth,
        );
      },
    );

    testWidgets(
      'a notice is a muted leaf label and an empty one is a bare one line reserve',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _v143PumpAt(
          tester,
          const SizedBox(
            width: 400,
            child: Column(
              children: [
                AttachmentNotice(text: 'Image not found · a.png'),
                AttachmentNotice(text: ''),
              ],
            ),
          ),
        );
        final notices = find.byType(AttachmentNotice);
        final filled = notices.at(0);
        final empty = notices.at(1);
        final filledBox = _v143NoticeBox(tester, filled);
        final emptyBox = _v143NoticeBox(tester, empty);
        expect(filledBox.color, OmColors.surface3);
        expect(emptyBox.color, isNull, reason: 'the reserve paints nothing');
        expect(
          tester.getSize(filled).height,
          moreOrLessEquals(tester.getSize(empty).height, epsilon: 0.01),
          reason: 'both are one line tall',
        );
        final filledText = find.descendant(
          of: filled,
          matching: find.text('Image not found · a.png'),
        );
        expect(
          tester.getTopLeft(filledText).dx - tester.getTopLeft(filled).dx,
          8,
          reason: 'padded by 8',
        );
        expect(tester.widget<Text>(filledText).style?.color, OmColors.fg3);
        final node = tester.getSemantics(filled);
        expect(node, matchesSemantics(label: 'Image not found · a.png'));
        expect(node.childrenCount, 0, reason: 'a leaf');
        handle.dispose();
      },
    );

    testWidgets('an empty notice has no side padding', (tester) async {
      await _v143PumpAt(
        tester,
        const SizedBox(width: 400, child: AttachmentNotice(text: '')),
      );
      final padding = tester.widget<Padding>(
        find.descendant(
          of: find.byType(AttachmentNotice),
          matching: find.byType(Padding),
        ),
      );
      expect(padding.padding, EdgeInsets.zero);
    });

    testWidgets(
      'an image box sizes from its natural size alone and decodes at its shown width',
      (tester) async {
        await _v143PumpAt(
          tester,
          const SizedBox(
            width: 500,
            child: AttachmentImageBox(natural: Size(2000, 400)),
          ),
        );
        expect(
          tester.getSize(find.byType(AttachmentImageBox)),
          const Size(500, 100),
        );
        expect(find.byType(Image), findsNothing, reason: 'no image yet');

        // At device pixel ratio 0.3 a 1 px wide image would round to 0 px.
        final image = MemoryImage(testPngBytes(1, 1));
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(devicePixelRatio: 0.3),
              child: Align(
                alignment: Alignment.topLeft,
                child: AttachmentImageBox(
                  natural: const Size(1, 1),
                  image: image,
                ),
              ),
            ),
          ),
        );
        final widget = tester.widget<Image>(find.byType(Image));
        expect((widget.image as ResizeImage).width, 1);
        expect(widget.gaplessPlayback, isTrue);
        expect(widget.fit, BoxFit.fill);
        expect(widget.excludeFromSemantics, isTrue);

        // At the view's device pixel ratio the width is the shown width times it.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: AttachmentImageBox(
                  natural: const Size(300, 200),
                  image: MemoryImage(testPngBytes(30, 20)),
                ),
              ),
            ),
          ),
        );
        final bare = tester.widget<Image>(find.byType(Image));
        expect(
          (bare.image as ResizeImage).width,
          (300 * tester.view.devicePixelRatio).round(),
        );
        expect(
          tester.getSize(find.byType(AttachmentImageBox)),
          const Size(300, 200),
        );
      },
    );

    testWidgets('an image box whose image fails to decode reports it once', (
      tester,
    ) async {
      var errors = 0;
      await _v143PumpAt(
        tester,
        SizedBox(
          width: 300,
          child: AttachmentImageBox(
            natural: const Size(30, 20),
            image: MemoryImage(Uint8List.fromList(List.filled(40, 3))),
            onError: () => errors++,
          ),
        ),
      );
      await _v143Settle(tester, () => errors > 0);
      expect(errors, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('editor paths (AC3, AC4, AC6, AC7, AC8, AC12, AC14)', () {
    testWidgets(
      'with no attachments domain an image shows Image unavailable and a card a dash',
      (tester) async {
        final pic = _v143Attachment('chart.png', image: true);
        final pdf = _v143Attachment('doc.pdf');
        await _v143PumpEditor(
          tester,
          'Intro line\n${pic.md}\n${pdf.md}\nOutro line',
          null,
        );
        expect(rowsHostOf(tester).rowSpec(1)?.kind, RowKind.attachment);
        expect(_v143Text(1, 'Image unavailable · chart.png'), findsOneWidget);
        expect(_v143Text(2, 'PDF · —'), findsOneWidget);
        expect(_v143Text(2, 'doc.pdf'), findsOneWidget);
        await _v143Click(tester, tester.getCenter(_v143Block(2)));
        expect(tester.takeException(), isNull);
      },
      variant: macOnly,
    );

    testWidgets(
      'a secondary click on an inert image notice or missing card shows no menu',
      (tester) async {
        final vault = FakeAttachmentVault();
        final gone = _v143Attachment('gone.png', image: true);
        final goneFile = _v143Attachment('gone.pdf');
        await _v143PumpEditor(
          tester,
          'Intro line\n${gone.md}\n${goneFile.md}\nOutro line',
          vault,
        );
        expect(_v143Text(1, 'Image not found · gone.png'), findsOneWidget);
        expect(_v143Text(2, 'File not found · gone.pdf'), findsOneWidget);
        for (final r in [1, 2]) {
          await _v143Click(
            tester,
            tester.getCenter(_v143Block(r)),
            buttons: kSecondaryMouseButton,
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            find.byType(AdaptiveTextSelectionToolbar),
            findsNothing,
            reason: 'row $r offers no menu at all',
          );
          expect(find.text('Open'), findsNothing);
          expect(find.text('Reveal in Finder'), findsNothing);
          expect(find.text('Paste'), findsNothing);
        }
        expect(vault.openCalls, isEmpty);
        expect(vault.revealCalls, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'an offline Reveal in Finder shows the toast and a missing one does not',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pdf = _v143Attachment('doc.pdf');
        vault.putFile(pdf.path, Uint8List(2048));
        vault.revealResults
          ..add(const AttachmentActionFailed(AttachmentLookupFailure.offline))
          ..add(const AttachmentActionFailed(AttachmentLookupFailure.missing));
        await _v143PumpEditor(
          tester,
          'Intro line\n${pdf.md}\nOutro line',
          vault,
        );
        for (final (i, toast) in [true, false].indexed) {
          await _v143Click(
            tester,
            tester.getCenter(_v143Block(1)),
            buttons: kSecondaryMouseButton,
          );
          await tester.tap(find.text('Reveal in Finder'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 750));
          expect(vault.revealCalls.length, i + 1);
          expect(
            find.text(
              "Couldn't open doc.pdf: the vault server can't be reached.",
            ),
            toast ? findsOneWidget : findsNothing,
            reason: 'reveal $i',
          );
          expect(vault.openCalls, isEmpty);
          if (toast) {
            tester
                .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
                .removeCurrentSnackBar();
            await tester.pump();
          }
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'a JPEG whose size lies deep in its header shows its final height at first layout',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _v143Attachment('photo.jpg', image: true);
        // Two 60 KB APP1 segments (EXIF) before the frame.
        vault.putFile(
          pic.path,
          Uint8List.fromList(
            _v143Jpeg([
              _v143JpegSegment(0xE1, List.filled(60 * 1024, 0x45)),
              _v143JpegSegment(0xE1, List.filled(60 * 1024, 0x45)),
              _v143Sof(0xC0, 300, 200),
              _v143JpegSegment(0xDA, [1, 2, 3]),
            ]),
          ),
        );
        await _v143PumpEditor(
          tester,
          'Intro line\n${pic.md}\nOutro line',
          vault,
        );
        expect(tester.getSize(_v143Block(1)).height, 200);
        expect(tester.getSize(_v143Block(1)).width, 300);
      },
      variant: macOnly,
    );

    testWidgets(
      'a hosted image over a cap or without a header shows as a file card',
      (tester) async {
        const mb30 = 30 * 1024 * 1024;
        final hosted = FakeHostedAttachments();
        final heavy = _v143Attachment('heavy.png', image: true);
        final full = _v143Attachment('full.png', image: true);
        final huge = _v143Attachment('huge.png', image: true);
        final plain = _v143Attachment('plain.png', image: true);
        Uint8List padded(int size) =>
            Uint8List(size)..setAll(0, testPngBytes(100, 100));
        hosted
          ..answerRead(heavy.path, AttachmentBytes(padded(mb30 + 1)))
          ..answerRead(full.path, AttachmentBytes(padded(mb30)))
          ..answerRead(
            huge.path,
            AttachmentBytes(testPngHeaderOnly(10000, 10001)),
          )
          ..answerRead(
            plain.path,
            AttachmentBytes(Uint8List.fromList('not an image'.codeUnits)),
          );
        await _v143PumpEditor(
          tester,
          ['Intro', heavy.md, full.md, huge.md, plain.md].join('\n'),
          hosted,
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        Finder image(int r) =>
            find.descendant(of: _v143Block(r), matching: find.byType(Image));
        expect(_v143Text(1, 'PNG · 30.0 MB'), findsOneWidget, reason: 'heavy');
        expect(image(1), findsNothing);
        expect(image(2), findsOneWidget, reason: 'exactly 30 MB is an image');
        expect(tester.getSize(_v143Block(2)).height, 100);
        expect(_v143Text(3, 'huge.png'), findsOneWidget, reason: 'over 100 MP');
        expect(image(3), findsNothing);
        expect(_v143Text(4, 'PNG · 12 B'), findsOneWidget, reason: 'no header');
        expect(image(4), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets('a row that now holds another attachment shows that one', (
      tester,
    ) async {
      final vault = FakeAttachmentVault();
      final first = _v143Attachment('first.pdf');
      final second = _v143Attachment('second.zip');
      vault
        ..putFile(first.path, Uint8List(2048))
        ..putFile(second.path, Uint8List(5 * 1024 * 1024));
      final e = await _v143PumpEditor(
        tester,
        'Intro line\n${first.md}\nOutro line',
        vault,
      );
      expect(_v143Text(1, 'PDF · 2 KB'), findsOneWidget);
      await activateRow(tester, 0, 1);
      await tester.macEditingValue(second.md);
      await e.settleTyping();
      await e.focusOutside();
      expect(e.text(), 'Intro line\n${second.md}\nOutro line');
      expect(rowsHostOf(tester).rowSpec(1)?.kind, RowKind.attachment);
      expect(_v143Text(1, 'second.zip'), findsOneWidget);
      expect(_v143Text(1, 'ZIP · 5.0 MB'), findsOneWidget);
      expect(_v143Text(1, 'PDF · 2 KB'), findsNothing);
      await _v143Click(tester, tester.getCenter(_v143Block(1)));
      expect(vault.openCalls, [second.path]);
    }, variant: macOnly);

    testWidgets(
      'a tap in the image while its line shows puts the caret at the line start',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _v143Attachment('chart.png', image: true);
        vault.putFile(pic.path, testPngBytes(300, 200));
        final e = await _v143PumpEditor(
          tester,
          'Intro line\n${pic.md}\nOutro line',
          vault,
        );
        await activateRow(tester, 0, 1, offset: 9);
        final host = rowsHostOf(tester);
        final start = host.rowSpec(1)!.textStart;
        expect(host.selection, TextSelection.collapsed(offset: start + 9));
        await _v143Click(tester, tester.getCenter(_v143Block(1)));
        expect(
          rowsHostOf(tester).selection,
          TextSelection.collapsed(offset: start),
        );
        expect(rowsHostOf(tester).focusedRow, 1);
        expect(vault.openCalls, isEmpty);
        await e.focusOutside();
      },
      variant: macOnly,
    );

    testWidgets(
      'an image block is one leaf semantics node labelled with its name',
      (tester) async {
        final handle = tester.ensureSemantics();
        final vault = FakeAttachmentVault();
        final pic = _v143Attachment('chart.png', image: true);
        vault.putFile(pic.path, testPngBytes(300, 200));
        await _v143PumpEditor(
          tester,
          'Intro line\n${pic.md}\nOutro line',
          vault,
        );
        await _v143Settle(
          tester,
          () => find
              .descendant(of: _v143Block(1), matching: find.byType(RawImage))
              .evaluate()
              .isNotEmpty,
        );
        final node = tester.getSemantics(_v143Block(1));
        expect(node.label, 'chart.png');
        expect(node.childrenCount, 0, reason: 'the pixels are not read out');
        expect(
          node.getSemanticsData().flagsCollection.isImage,
          isTrue,
          reason: 'announced as an image',
        );
        handle.dispose();
      },
      variant: macOnly,
    );
  });
}

/// The BoxDecoration of the notice's own DecoratedBox.
BoxDecoration _v143NoticeBox(WidgetTester tester, Finder notice) {
  final box = find.descendant(of: notice, matching: find.byType(DecoratedBox));
  return tester.widget<DecoratedBox>(box.first).decoration as BoxDecoration;
}
