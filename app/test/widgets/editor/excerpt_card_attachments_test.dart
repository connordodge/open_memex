// WI #144 (Spec #123 V4: R39, with R24, R28, R32, R33, R35, R37, R41, R42;
// rulings D6, D7, D10, D17, D22; Ledger L10): excerpt cards render
// attachment lines.
//
// A transcluded line that is an image row shows the image, scaled to the
// card's width and at most 240 px tall, aspect kept; a file-card line shows
// the compact file card. Both reuse V3's widgets (`attachment_row.dart`:
// AttachmentBlock, AttachmentImageBox, AttachmentFileCard), with the same
// open, Reveal in Finder, missing and offline behaviour. The card stays
// read-only: a tap on the image places nothing, and the card's other rows
// keep CardRows' no-pointer rule (the stated R39 exception to D14).
//
// - `CardRows` on its own ([_t144PumpRows]) over a fake attachments domain
//   for `attachmentsProvider`: a local vault ([FakeAttachmentVault], files
//   on disk so the header is read at first layout, D7) or a hosted one
//   ([FakeHostedAttachments], reads wait for the test).
// - Through the workspace ([_t144LaunchNote]): a topic note whose excerpt
//   card transcludes an image block and a file block of the fixture daily
//   note.
//
// Keys: `card-row-<r>` (CardRows' row r) and, per D6, `card-attachment-<r>`
// around row r's attachment block. Image bytes are tiny generated PNGs;
// real decodes run under `runAsync`. Every file has its own path
// (`testAttachmentPath`), since image sizes are cached per path (D7).
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/attachment_ref.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';
import 'package:open_memex_app/src/state/file_revealer.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/attachments_access.dart';
import 'package:open_memex_app/src/widgets/editor/attachment_row.dart';
import 'package:open_memex_app/src/widgets/editor/card_rows.dart';

import '../../robots/segmented_editor_robot.dart';
import '../../support/app_harness.dart';
import '../../support/attachments_fakes.dart';
import '../../support/daily_seed.dart';
import '../../support/editor_scope.dart';
import '../../support/fake_file_revealer.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';

/// The tallest a card image shows (R39), in logical pixels.
const double _t144MaxHeight = 240;

/// The card width [_t144PumpRows] lays CardRows out at by default.
const double _t144Width = 400;

const _t144RowsKey = Key('t144-rows');

/// The toast of an offline open (R42, D22).
String _t144OfflineToast(String name) =>
    "Couldn't open $name: the vault server can't be reached.";

int _t144Ids = 4400;

/// A fresh attachment named [name]: its decoded path and its reference
/// markdown, image form for an inline image name unless [image] says.
({String path, String md}) _t144Attachment(String name, {bool? image}) {
  final n = ++_t144Ids;
  final bang = (image ?? isInlineImageName(name)) ? '!' : '';
  return (
    path: testAttachmentPath(n, name),
    md:
        '$bang[$name](objects/5e/${testAttachmentHash(n)}/'
        '${encodeAttachmentName(name)})',
  );
}

/// An image of [natural] logical pixels in a card [width] wide (R39):
/// scaled down, never up, to the card width and at most 240 px tall, aspect
/// kept.
Size _t144Shown(Size natural, double width) {
  final scale = math.min(
    1.0,
    math.min(width / natural.width, _t144MaxHeight / natural.height),
  );
  return Size(natural.width * scale, natural.height * scale);
}

/// What [_t144PumpRows] pumped.
final class _T144Rows {
  _T144Rows(this.opener, this.revealer);

  final RecordingUrlOpener opener;
  final FakeFileRevealer revealer;
}

/// Pumps [CardRows] of the excerpt [text], [width] wide, with [attachments]
/// as the open vault's attachments domain, a recording URL opener and a
/// fake file revealer, inside a Scaffold (for toasts).
Future<_T144Rows> _t144PumpRows(
  WidgetTester tester,
  String text,
  AttachmentsAccess attachments, {
  double width = _t144Width,
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final opener = RecordingUrlOpener();
  final revealer = FakeFileRevealer();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        attachmentsProvider.overrideWithValue(attachments),
        urlOpenerProvider.overrideWithValue(opener),
        fileRevealerProvider.overrideWithValue(revealer),
      ],
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: SizedBox(
                    width: width,
                    child: CardRows(key: _t144RowsKey, text: text),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _T144Rows(opener, revealer);
}

Finder get _t144Rows => find.byKey(_t144RowsKey);

/// Card row [r] (Key `card-row-<r>`) under [scope] (default: the pumped
/// rows).
Finder _t144Row(int r, {Finder? scope}) => find.descendant(
  of: scope ?? _t144Rows,
  matching: find.byKey(ValueKey('card-row-$r')),
);

/// Card row [r]'s attachment block (Key `card-attachment-<r>`, D6) under
/// [scope] (default: the pumped rows).
Finder _t144Block(int r, {Finder? scope}) => find.descendant(
  of: scope ?? _t144Rows,
  matching: find.byKey(ValueKey('card-attachment-$r')),
);

/// [finder] inside card row [r]'s attachment block.
Finder _t144In(int r, Finder finder, {Finder? scope}) => find.descendant(
  of: _t144Block(r, scope: scope),
  matching: finder,
);

/// The text [text] inside card row [r]'s attachment block.
Finder _t144Text(int r, String text, {Finder? scope}) =>
    _t144In(r, find.text(text, findRichText: true), scope: scope);

/// Card row [r]'s decoded image, or null before it decodes.
ui.Image? _t144Decoded(WidgetTester tester, int r, {Finder? scope}) {
  final raw = _t144In(r, find.byType(RawImage), scope: scope);
  return raw.evaluate().isEmpty ? null : tester.widget<RawImage>(raw).image;
}

/// Lets real async work (decodes, file reads) run until [done] holds.
Future<void> _t144Settle(
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
Future<void> _t144Click(
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
Future<void> _t144DoubleClick(WidgetTester tester, Offset at) async {
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

/// A secondary click at [at]: the menu offers `Open`, and `Reveal in
/// Finder` exactly when [reveal], and no text menu items; then picks [item]
/// (none: the menu is dismissed).
Future<void> _t144Menu(
  WidgetTester tester,
  Offset at, {
  required bool reveal,
  String? item,
}) async {
  await _t144Click(tester, at, buttons: kSecondaryMouseButton);
  expect(find.text('Open'), findsOneWidget, reason: 'the menu offers Open');
  expect(
    find.text('Reveal in Finder'),
    reveal ? findsOneWidget : findsNothing,
    reason: reveal
        ? 'the menu offers Reveal in Finder'
        : 'no Reveal in Finder on a hosted vault (R41)',
  );
  for (final text in ['Cut', 'Copy', 'Paste', 'Select all']) {
    expect(find.text(text), findsNothing, reason: 'no text menu: $text');
  }
  if (item == null) {
    await tester.tapAt(const Offset(1100, 1300));
    await tester.pump();
  } else {
    await tester.tap(find.text(item));
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Records, after every frame in which the pumped rows exist, the height of
/// card row [r]'s attachment block (null while it has none) and of the
/// whole card body (CardRows), until the test ends.
({List<double?> block, List<double> rows}) _t144RecordHeights(
  WidgetTester tester,
  int r, {
  Finder? scope,
  Finder? rows,
}) {
  final block = <double?>[];
  final all = <double>[];
  var on = true;
  addTearDown(() => on = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!on) return;
    final body = (rows ?? _t144Rows).evaluate();
    if (body.isEmpty) return;
    final bodyBox = body.first.renderObject;
    if (bodyBox is! RenderBox || !bodyBox.hasSize) return;
    all.add(bodyBox.size.height);
    final found = _t144Block(r, scope: scope).evaluate();
    final box = found.isEmpty ? null : found.first.renderObject;
    block.add(box is RenderBox && box.hasSize ? box.size.height : null);
  });
  return (block: block, rows: all);
}

/// The pointer-input widget types CardRows' rule (D14) keeps off card rows.
const _t144PointerTypes = <Type>[
  GestureDetector,
  RawGestureDetector,
  Listener,
  MouseRegion,
];

/// The elements of type [type] under [scope].
List<Element> _t144Under(Finder scope, Type type) =>
    find.descendant(of: scope, matching: find.byType(type)).evaluate().toList();

// ---------------------------------------------------------------- workspace

const _t144Token = '![[2026-09-05#^t144a..^t144c]]';

/// The workspace on a topic note (`Intro line`, an excerpt card, `Outro
/// line`) whose card (card 1) transcludes the fixture daily note's blocks
/// `Filed today:`, [image] and [file] (card rows 0, 1, 2), with [vault] as
/// the open vault's attachments domain.
Future<SegmentedEditorRobot> _t144LaunchNote(
  WidgetTester tester,
  FakeAttachmentVault vault, {
  required String image,
  required String file,
}) async {
  final seeded = seedSegmentedVault(
    topicBody: 'Intro line\n$_t144Token\nOutro line\n',
  );
  for (final (i, text) in ['Filed today:', image, file].indexed) {
    seeded.db.seedBlock(
      fixtureDailyId,
      't144${'abc'[i]}',
      ord: 3 + i,
      text: text,
    );
  }
  final h = await pumpWorkspace(
    tester,
    db: seeded.db,
    cli: seeded.cli,
    overrides: [attachmentsProvider.overrideWithValue(vault)],
  );
  final r = SegmentedEditorRobot(tester, h);
  await r.open(fixtureTopicId);
  await tester.pump();
  return r;
}

/// Whether the primary focus sits inside [scope].
bool _t144FocusInside(Finder scope) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final target = context as Element;
  return find
      .descendant(
        of: scope,
        matching: find.byElementPredicate((e) => identical(e, target)),
        matchRoot: true,
        skipOffstage: false,
      )
      .evaluate()
      .isNotEmpty;
}

void main() {
  holdFontFetches();

  // -------------------------------------------------------------------------
  // AC1: image lines and file lines render in the card
  // -------------------------------------------------------------------------
  group('image and file lines (AC1)', () {
    testWidgets(
      'a card image line shows the image scaled to the card width and at most 240 px tall aspect kept',
      (tester) async {
        final vault = FakeAttachmentVault();
        final sizes = <Size>[
          const Size(200, 100), // smaller than the card: never upscaled
          const Size(2000, 500), // wider than the card
          const Size(300, 600), // taller than 240
          const Size(300, 240), // exactly 240 tall
          const Size(300, 241), // just over 240
          const Size(1000, 2000), // wider and taller
          const Size(400, 100), // exactly the card width
          const Size(401, 100), // just over the card width
        ];
        final refs = [
          for (final (i, _) in sizes.indexed)
            _t144Attachment('pic$i.${i.isEven ? 'png' : 'PNG'}'),
        ];
        for (final (i, s) in sizes.indexed) {
          vault.putFile(
            refs[i].path,
            testPngBytes(s.width.toInt(), s.height.toInt()),
          );
        }
        final text = [
          'Filed today:',
          for (final r in refs) r.md,
          'And more.',
        ].join('\n');
        await _t144PumpRows(tester, text, vault);
        final cardWidth = tester.getSize(_t144Rows).width;
        expect(cardWidth, moreOrLessEquals(_t144Width, epsilon: 0.01));
        for (final (i, natural) in sizes.indexed) {
          final r = i + 1;
          final shown = _t144Shown(natural, cardWidth);
          expect(_t144Block(r), findsOneWidget, reason: 'row $r block');
          expect(
            find.descendant(of: _t144Row(r), matching: _t144Block(r)),
            findsOneWidget,
            reason: 'row $r block inside card-row-$r',
          );
          final image = _t144In(r, find.byType(Image));
          expect(image, findsOneWidget, reason: 'row $r shows an image');
          final size = tester.getSize(image);
          expect(
            size.width,
            moreOrLessEquals(shown.width, epsilon: 0.5),
            reason: 'row $r width for $natural',
          );
          expect(
            size.height,
            moreOrLessEquals(shown.height, epsilon: 0.5),
            reason: 'row $r height for $natural',
          );
          expect(
            tester.getSize(_t144Block(r)).height,
            moreOrLessEquals(shown.height, epsilon: 0.5),
            reason: 'row $r block height',
          );
          expect(size.height, lessThanOrEqualTo(_t144MaxHeight + 0.01));
          expect(size.width, lessThanOrEqualTo(cardWidth + 0.01));
          // The image shows in place of the markdown.
          expect(
            find.descendant(
              of: _t144Row(r),
              matching: find.textContaining('objects/', findRichText: true),
            ),
            findsNothing,
            reason: 'row $r shows no markdown',
          );
        }
        // Boundaries of the 240 cap: exactly 240 is kept, 241 scales down.
        expect(
          tester.getSize(_t144In(4, find.byType(Image))),
          const Size(300, 240),
        );
        expect(
          tester.getSize(_t144In(5, find.byType(Image))).height,
          moreOrLessEquals(240, epsilon: 0.01),
        );
        expect(
          tester.getSize(_t144In(5, find.byType(Image))).width,
          lessThan(300),
        );
        // Never upscaled; aspect kept.
        expect(
          tester.getSize(_t144In(1, find.byType(Image))),
          const Size(200, 100),
        );
        expect(
          tester.getSize(_t144In(3, find.byType(Image))),
          const Size(120, 240),
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'a card file line shows the compact file card with its type and size',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pdf = _t144Attachment('Q3 report.pdf');
        final pdfImageForm = _t144Attachment('scan.pdf', image: true);
        final linkPng = _t144Attachment('chart.png', image: false);
        final inline = _t144Attachment('inline.png');
        vault
          ..putFile(pdf.path, Uint8List(812 * 1024))
          ..putFile(pdfImageForm.path, Uint8List(2048))
          ..putFile(linkPng.path, testPngBytes(30, 20))
          ..putFile(inline.path, testPngBytes(30, 20));
        final pngSize = vault.files[linkPng.path]!.length;
        final text = [
          'Filed today:',
          pdf.md,
          pdfImageForm.md,
          linkPng.md,
          'See ${inline.md} here',
          '- ${inline.md}',
        ].join('\n');
        await _t144PumpRows(tester, text, vault);
        await tester.pump();
        final expected = <int, (String, String)>{
          1: ('Q3 report.pdf', 'PDF · 812 KB'),
          2: ('scan.pdf', 'PDF · 2 KB'),
          3: ('chart.png', attachmentCaption('chart.png', pngSize)),
        };
        for (final MapEntry(key: r, value: (name, caption))
            in expected.entries) {
          expect(_t144Block(r), findsOneWidget, reason: 'row $r block');
          expect(
            _t144In(r, find.byType(AttachmentFileCard)),
            findsOneWidget,
            reason: 'row $r is the compact file card',
          );
          expect(_t144Text(r, name), findsOneWidget, reason: 'row $r name');
          expect(_t144Text(r, caption), findsOneWidget, reason: 'row $r');
          expect(_t144In(r, find.byType(Icon)), findsOneWidget);
          expect(_t144In(r, find.byType(Image)), findsNothing);
          expect(
            tester.getSize(_t144Block(r)).width,
            lessThanOrEqualTo(AttachmentFileCard.maxWidth + 0.01),
            reason: 'row $r card is compact',
          );
        }
        // A reference that is not alone on its line, or sits in a list
        // item, is no attachment line: no block.
        for (final r in [4, 5]) {
          expect(_t144Row(r), findsOneWidget, reason: 'row $r exists');
          expect(_t144Block(r), findsNothing, reason: 'row $r has no block');
          expect(
            find.descendant(
              of: _t144Row(r),
              matching: find.byType(AttachmentBlock),
            ),
            findsNothing,
          );
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'card attachment lines reuse the editor attachment block read only',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t144Attachment('chart.png');
        final pdf = _t144Attachment('Q3 report.pdf');
        vault
          ..putFile(pic.path, testPngBytes(300, 200))
          ..putFile(pdf.path, Uint8List(812 * 1024));
        await _t144PumpRows(tester, '${pic.md}\n${pdf.md}', vault);
        for (final (r, path) in [(0, pic.path), (1, pdf.path)]) {
          final block = _t144In(r, find.byType(AttachmentBlock));
          expect(block, findsOneWidget, reason: 'row $r is an AttachmentBlock');
          final widget = tester.widget<AttachmentBlock>(block);
          expect(widget.reference.target.path, path);
          expect(
            widget.onPlaceCaret,
            isNull,
            reason: 'row $r: a card places no caret',
          );
        }
        expect(_t144In(0, find.byType(AttachmentImageBox)), findsOneWidget);
        expect(_t144In(1, find.byType(AttachmentFileCard)), findsOneWidget);
      },
      variant: macOnly,
    );

    testWidgets(
      'card attachments are labelled with the image name and the card name type and size',
      (tester) async {
        final handle = tester.ensureSemantics();
        final vault = FakeAttachmentVault();
        final pic = _t144Attachment('chart.png');
        final pdf = _t144Attachment('Q3 report.pdf');
        vault
          ..putFile(pic.path, testPngBytes(300, 200))
          ..putFile(pdf.path, Uint8List(812 * 1024));
        await _t144PumpRows(tester, 'Filed:\n${pic.md}\n${pdf.md}', vault);
        expect(
          find.descendant(
            of: _t144Block(1),
            matching: find.bySemanticsLabel('chart.png'),
            matchRoot: true,
          ),
          findsWidgets,
        );
        expect(
          find.descendant(
            of: _t144Block(2),
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
      'a narrow card at text scale 2 shows attachment lines without overflow',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t144Attachment('wide.png');
        final pdf = _t144Attachment(
          'A very long quarterly report name that will not fit.pdf',
        );
        vault
          ..putFile(pic.path, testPngBytes(2000, 500))
          ..putFile(pdf.path, Uint8List(812 * 1024));
        await _t144PumpRows(
          tester,
          'Filed:\n${pic.md}\n${pdf.md}',
          vault,
          width: 160,
          textScale: 2,
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'no overflow');
        expect(_t144In(1, find.byType(Image)), findsOneWidget);
        expect(
          tester.getSize(_t144In(1, find.byType(Image))).width,
          moreOrLessEquals(160, epsilon: 0.5),
        );
        expect(_t144In(2, find.byType(AttachmentFileCard)), findsOneWidget);
        expect(
          tester.getSize(_t144Block(2)).width,
          lessThanOrEqualTo(160 + 0.01),
        );
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC2: open, menu and executables through the domain
  // -------------------------------------------------------------------------
  group('presses (AC2)', () {
    testWidgets(
      'a double click on a card image opens it through the domain and a single click opens nothing',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t144Attachment('chart.png');
        vault.putFile(pic.path, testPngBytes(300, 200));
        final e = await _t144PumpRows(tester, 'Filed:\n${pic.md}', vault);
        expect(_t144In(1, find.byType(Image)), findsOneWidget);
        await _t144Click(tester, tester.getCenter(_t144Block(1)));
        expect(
          vault.openCalls,
          isEmpty,
          reason: 'a single click opens nothing',
        );
        await _t144DoubleClick(tester, tester.getCenter(_t144Block(1)));
        expect(vault.openCalls, [pic.path]);
        expect(vault.revealCalls, isEmpty);
        expect(e.opener.opened, isEmpty, reason: 'never the url opener');
        expect(e.revealer.paths, isEmpty, reason: 'never the revealer');
      },
      variant: macOnly,
    );

    testWidgets('a click on a card file card opens it through the domain', (
      tester,
    ) async {
      final vault = FakeAttachmentVault();
      final pdf = _t144Attachment('Q3 report.pdf');
      vault.putFile(pdf.path, Uint8List(812 * 1024));
      final e = await _t144PumpRows(tester, 'Filed:\n${pdf.md}', vault);
      expect(_t144Text(1, 'PDF · 812 KB'), findsOneWidget);
      await _t144Click(tester, tester.getCenter(_t144Block(1)));
      expect(vault.openCalls, [pdf.path]);
      expect(vault.revealCalls, isEmpty);
      expect(e.opener.opened, isEmpty, reason: 'never the url opener');
    }, variant: macOnly);

    testWidgets(
      'a secondary click on a card image or file card offers Open and Reveal in Finder',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t144Attachment('chart.png');
        final pdf = _t144Attachment('Q3 report.pdf');
        vault
          ..putFile(pic.path, testPngBytes(300, 200))
          ..putFile(pdf.path, Uint8List(812 * 1024));
        final e = await _t144PumpRows(
          tester,
          'Filed:\n${pic.md}\n${pdf.md}',
          vault,
        );
        await _t144Menu(
          tester,
          tester.getCenter(_t144Block(1)),
          reveal: true,
          item: 'Open',
        );
        expect(vault.openCalls, [pic.path]);
        expect(vault.revealCalls, isEmpty);
        expect(find.text('Reveal in Finder'), findsNothing, reason: 'closed');
        await _t144Menu(
          tester,
          tester.getCenter(_t144Block(1)),
          reveal: true,
          item: 'Reveal in Finder',
        );
        expect(vault.revealCalls, [pic.path]);
        await _t144Menu(
          tester,
          tester.getCenter(_t144Block(2)),
          reveal: true,
          item: 'Open',
        );
        expect(vault.openCalls, [pic.path, pdf.path]);
        await _t144Menu(
          tester,
          tester.getCenter(_t144Block(2)),
          reveal: true,
          item: 'Reveal in Finder',
        );
        expect(vault.revealCalls, [pic.path, pdf.path]);
        expect(e.opener.opened, isEmpty);
        expect(e.revealer.paths, isEmpty, reason: 'only through the domain');
      },
      variant: macOnly,
    );

    testWidgets(
      'a card executable file card click and Open call only the domain open',
      (tester) async {
        final vault = FakeAttachmentVault();
        final script = _t144Attachment('setup.sh');
        vault.putFile(script.path, Uint8List(120));
        final e = await _t144PumpRows(tester, 'Filed:\n${script.md}', vault);
        expect(_t144Text(1, 'setup.sh'), findsOneWidget);
        expect(_t144Text(1, 'SH · 120 B'), findsOneWidget);
        await _t144Click(tester, tester.getCenter(_t144Block(1)));
        expect(vault.openCalls, [script.path]);
        await _t144Menu(
          tester,
          tester.getCenter(_t144Block(1)),
          reveal: true,
          item: 'Open',
        );
        expect(vault.openCalls, [script.path, script.path]);
        expect(vault.revealCalls, isEmpty);
        expect(
          e.opener.opened,
          isEmpty,
          reason: 'no path reaches the url opener',
        );
        expect(e.revealer.paths, isEmpty, reason: 'no direct reveal');
      },
      variant: macOnly,
    );

    testWidgets(
      'a hosted card offers Open and no Reveal in Finder for images and file cards',
      (tester) async {
        final hosted = FakeHostedAttachments();
        final pic = _t144Attachment('remote.png');
        final pdf = _t144Attachment('Q3 report.pdf');
        hosted
          ..answerFile(pic.path, testPngBytes(300, 200))
          ..answerFile(pdf.path, Uint8List(812 * 1024));
        await _t144PumpRows(tester, 'Filed:\n${pic.md}\n${pdf.md}', hosted);
        await _t144Settle(
          tester,
          () => _t144In(1, find.byType(Image)).evaluate().isNotEmpty,
          reason: 'the hosted image shows once its bytes arrive',
        );
        await _t144Menu(
          tester,
          tester.getCenter(_t144Block(1)),
          reveal: false,
          item: 'Open',
        );
        expect(hosted.openCalls, [pic.path]);
        await _t144Menu(
          tester,
          tester.getCenter(_t144Block(2)),
          reveal: false,
          item: 'Open',
        );
        expect(hosted.openCalls, [pic.path, pdf.path]);
        expect(hosted.revealCalls, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'in a note a card image double click and a card file menu reach the domain',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t144Attachment('chart.png');
        final pdf = _t144Attachment('Q3 report.pdf');
        vault
          ..putFile(pic.path, testPngBytes(300, 600))
          ..putFile(pdf.path, Uint8List(812 * 1024));
        final r = await _t144LaunchNote(
          tester,
          vault,
          image: pic.md,
          file: pdf.md,
        );
        final card = r.card(1);
        expect(card, findsOneWidget);
        // The image at the card's width and the 240 cap; the file card.
        final rows = find.descendant(of: card, matching: find.byType(CardRows));
        final shown = _t144Shown(
          const Size(300, 600),
          tester.getSize(rows).width,
        );
        final image = _t144In(1, find.byType(Image), scope: card);
        expect(image, findsOneWidget, reason: 'the card shows the image');
        expect(
          tester.getSize(image).height,
          moreOrLessEquals(shown.height, epsilon: 0.5),
        );
        expect(
          tester.getSize(image).width,
          moreOrLessEquals(shown.width, epsilon: 0.5),
        );
        expect(_t144Text(2, 'PDF · 812 KB', scope: card), findsOneWidget);

        await _t144DoubleClick(
          tester,
          tester.getCenter(_t144Block(1, scope: card)),
        );
        expect(vault.openCalls, [pic.path]);
        await _t144Menu(
          tester,
          tester.getCenter(_t144Block(2, scope: card)),
          reveal: true,
          item: 'Reveal in Finder',
        );
        expect(vault.revealCalls, [pdf.path]);
        await _t144Click(tester, tester.getCenter(_t144Block(2, scope: card)));
        expect(vault.openCalls, [pic.path, pdf.path]);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC3: missing and offline states
  // -------------------------------------------------------------------------
  group('missing and offline (AC3)', () {
    testWidgets(
      'missing card attachments read Image not found and File not found and a missing file card is inert',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t144Attachment('chart.png');
        final pdf = _t144Attachment('Q3 report.pdf');
        await _t144PumpRows(tester, 'Filed:\n${pic.md}\n${pdf.md}', vault);
        await tester.pump();
        expect(_t144Text(1, 'Image not found · chart.png'), findsOneWidget);
        expect(_t144In(1, find.byType(Image)), findsNothing);
        expect(_t144Text(2, 'File not found · Q3 report.pdf'), findsOneWidget);
        expect(_t144Text(2, 'Q3 report.pdf'), findsNothing);

        await _t144Click(tester, tester.getCenter(_t144Block(2)));
        await _t144DoubleClick(tester, tester.getCenter(_t144Block(1)));
        expect(vault.openCalls, isEmpty, reason: 'missing: nothing opens');
        await _t144Click(
          tester,
          tester.getCenter(_t144Block(2)),
          buttons: kSecondaryMouseButton,
        );
        expect(find.text('Open'), findsNothing, reason: 'no menu (R35)');
        expect(find.text('Reveal in Finder'), findsNothing);
        expect(find.byType(SnackBar), findsNothing, reason: 'no toast (D22)');
      },
      variant: macOnly,
    );

    testWidgets(
      'an offline hosted card image reads Image unavailable offline and an old server Image unavailable',
      (tester) async {
        final hosted = FakeHostedAttachments();
        final offline = _t144Attachment('away.png');
        final old = _t144Attachment('old.png');
        final missing = _t144Attachment('gone.png');
        final file = _t144Attachment('gone.pdf');
        hosted
          ..answerFailure(offline.path, AttachmentLookupFailure.offline)
          ..answerFailure(old.path, AttachmentLookupFailure.serverTooOld)
          ..answerFailure(missing.path, AttachmentLookupFailure.missing)
          ..answerFailure(file.path, AttachmentLookupFailure.missing);
        await _t144PumpRows(
          tester,
          [offline.md, old.md, missing.md, file.md].join('\n'),
          hosted,
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        expect(
          _t144Text(0, 'Image unavailable offline · away.png'),
          findsOneWidget,
        );
        expect(_t144Text(1, 'Image unavailable · old.png'), findsOneWidget);
        expect(_t144Text(2, 'Image not found · gone.png'), findsOneWidget);
        expect(_t144Text(3, 'File not found · gone.pdf'), findsOneWidget);
        for (final r in [0, 1, 2]) {
          expect(_t144In(r, find.byType(Image)), findsNothing);
        }
      },
      variant: macOnly,
    );

    testWidgets('an offline open from a card file card shows the toast', (
      tester,
    ) async {
      final hosted = FakeHostedAttachments();
      final pdf = _t144Attachment('Q3 report.pdf');
      hosted
        ..answerFailure(pdf.path, AttachmentLookupFailure.offline)
        ..openResults.add(
          const AttachmentActionFailed(AttachmentLookupFailure.offline),
        );
      await _t144PumpRows(tester, 'Filed:\n${pdf.md}', hosted);
      await tester.pump();
      expect(_t144Text(1, 'Q3 report.pdf'), findsOneWidget);
      await _t144Click(tester, tester.getCenter(_t144Block(1)));
      await tester.pump(const Duration(milliseconds: 750));
      expect(hosted.openCalls, [pdf.path]);
      expect(find.text(_t144OfflineToast('Q3 report.pdf')), findsOneWidget);
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC4: read-only, and the pointer rule's one exception
  // -------------------------------------------------------------------------
  group('read only (AC4)', () {
    testWidgets('only the attachment widgets in a card take pointer input', (
      tester,
    ) async {
      final vault = FakeAttachmentVault();
      final pic = _t144Attachment('chart.png');
      final pdf = _t144Attachment('Q3 report.pdf');
      final gone = _t144Attachment('gone.pdf');
      vault
        ..putFile(pic.path, testPngBytes(300, 200))
        ..putFile(pdf.path, Uint8List(812 * 1024));
      final text = [
        'Plain prose line',
        '# A heading',
        '- a bullet item',
        '- [ ] a task item',
        '1. a numbered item',
        '> a quote line',
        '```',
        'code line',
        '```',
        '| a | b |',
        '| --- | --- |',
        '| 1 | 2 |',
        pic.md,
        pdf.md,
        gone.md,
        'Closing prose',
      ].join('\n');
      await _t144PumpRows(tester, text, vault);
      await tester.pump();
      final specs = splitRows(text, atSegmentStart: true);
      var attachments = 0;
      var others = 0;
      for (final (r, spec) in specs.indexed) {
        final row = _t144Row(r);
        if (row.evaluate().isEmpty) continue;
        if (spec.kind == RowKind.attachment) {
          attachments++;
          final block = _t144Block(r);
          expect(block, findsOneWidget, reason: 'row $r has a block');
          expect(
            _t144Under(block, GestureDetector),
            isNotEmpty,
            reason: 'row $r: the attachment widget takes pointer input',
          );
          for (final type in _t144PointerTypes) {
            expect(
              _t144Under(row, type).length,
              _t144Under(block, type).length,
              reason: 'row $r: no $type outside the attachment widget',
            );
          }
        } else {
          others++;
          expect(_t144Block(r), findsNothing, reason: 'row $r: no block');
          for (final type in _t144PointerTypes) {
            expect(
              _t144Under(row, type),
              isEmpty,
              reason: 'row $r (${spec.kind}): no $type',
            );
          }
        }
      }
      expect(attachments, 3, reason: 'fixture: three attachment rows');
      expect(others, greaterThanOrEqualTo(7), reason: 'fixture: other rows');
    }, variant: macOnly);

    testWidgets(
      'clicks on card attachments in a note place no caret and edit nothing',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t144Attachment('chart.png');
        final pdf = _t144Attachment('Q3 report.pdf');
        vault
          ..putFile(pic.path, testPngBytes(300, 200))
          ..putFile(pdf.path, Uint8List(812 * 1024));
        final r = await _t144LaunchNote(
          tester,
          vault,
          image: pic.md,
          file: pdf.md,
        );
        final card = r.card(1);
        expect(
          _t144Block(1, scope: card),
          findsOneWidget,
          reason: 'the card shows the image block',
        );
        expect(_t144Block(2, scope: card), findsOneWidget);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        final segments = [0, 2];
        for (final s in segments) {
          expect(r.segmentHasFocus(s), isFalse, reason: 'fixture: segment $s');
        }
        final topicBefore = r.h.db.db.select(
          'SELECT content_md FROM notes WHERE id = ?',
          [fixtureTopicId],
        ).single['content_md'];

        // A click on the image, beside the file card, and on the image's
        // right edge.
        final imageRect = tester.getRect(_t144Block(1, scope: card));
        final fileRect = tester.getRect(_t144Block(2, scope: card));
        final rowRect = tester.getRect(_t144Row(2, scope: card));
        await _t144Click(tester, imageRect.center);
        await _t144Click(tester, imageRect.centerRight - const Offset(2, 0));
        if (rowRect.right - fileRect.right > 8) {
          await _t144Click(
            tester,
            Offset((fileRect.right + rowRect.right) / 2, fileRect.center.dy),
          );
        }
        expect(vault.openCalls, isEmpty, reason: 'single clicks open nothing');
        expect(_t144FocusInside(card), isFalse, reason: 'no focus in a card');
        for (final s in segments) {
          expect(
            r.segmentHasFocus(s),
            isFalse,
            reason: 'segment $s gains no caret from a card click',
          );
        }

        // Typing after the clicks edits nothing.
        for (final key in [
          LogicalKeyboardKey.keyX,
          LogicalKeyboardKey.backspace,
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.delete,
        ]) {
          await tester.sendKeyEvent(key, platform: 'macos');
          await tester.pump();
        }
        await r.waitForSave();
        expect(r.updates, isEmpty, reason: 'no write');
        expect(r.segmentText(0), 'Intro line\n');
        final topicAfter = r.h.db.db.select(
          'SELECT content_md FROM notes WHERE id = ?',
          [fixtureTopicId],
        ).single['content_md'];
        expect(topicAfter, topicBefore);
        final blocks = r.h.db.db.select(
          "SELECT text FROM blocks WHERE block_id IN ('t144b', 't144c') "
          'ORDER BY ord',
        );
        expect([for (final b in blocks) b['text']], [pic.md, pdf.md]);
        expect(_t144Block(1, scope: card), findsOneWidget);
        expect(_t144Block(2, scope: card), findsOneWidget);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC5: the card's height does not change when the image decodes (D7)
  // -------------------------------------------------------------------------
  group('height stable on decode (AC5)', () {
    testWidgets(
      'a local card image has its final height in the first frame and keeps it through decode',
      (tester) async {
        final vault = FakeAttachmentVault();
        final pic = _t144Attachment('tall.png');
        vault.putFile(pic.path, testPngBytes(300, 600));
        final heights = _t144RecordHeights(tester, 1);
        await _t144PumpRows(tester, 'Filed:\n${pic.md}\nMore.', vault);
        expect(heights.block, isNotEmpty, reason: 'frames were recorded');
        expect(
          heights.block.first,
          isNotNull,
          reason: 'the block shows in the first frame',
        );
        expect(heights.block.first, moreOrLessEquals(240, epsilon: 0.5));
        expect(_t144Decoded(tester, 1), isNull, reason: 'not decoded yet');
        await _t144Settle(tester, () => _t144Decoded(tester, 1) != null);
        await tester.pump();
        for (final (i, h) in heights.block.indexed) {
          expect(h, moreOrLessEquals(240, epsilon: 0.5), reason: 'frame $i');
        }
        final first = heights.rows.first;
        for (final (i, h) in heights.rows.indexed) {
          expect(
            h,
            moreOrLessEquals(first, epsilon: 0.01),
            reason: 'card body height, frame $i',
          );
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'a hosted card image keeps its height when it decodes and a later card of that path starts at it',
      (tester) async {
        final hosted = FakeHostedAttachments();
        final pic = _t144Attachment('remote.png');
        final text = 'Filed:\n${pic.md}\nMore.';
        await _t144PumpRows(tester, text, hosted);
        await tester.pump(const Duration(milliseconds: 100));
        expect(hosted.readCalls, contains(pic.path));
        expect(_t144Block(1), findsOneWidget, reason: 'a reserve block');
        final reserve = tester.getSize(_t144Block(1)).height;
        expect(reserve, lessThan(60), reason: 'a one line reserve');

        hosted.answerFile(pic.path, testPngBytes(300, 600));
        await _t144Settle(
          tester,
          () => tester.getSize(_t144Block(1)).height > reserve + 1,
          reason: 'the final size once the bytes arrive',
        );
        // From here the decode must not move it.
        final heights = _t144RecordHeights(tester, 1);
        expect(
          tester.getSize(_t144Block(1)).height,
          moreOrLessEquals(240, epsilon: 0.5),
        );
        final body = tester.getSize(_t144Rows).height;
        await _t144Settle(tester, () => _t144Decoded(tester, 1) != null);
        await tester.pump();
        expect(heights.block, isNotEmpty);
        for (final (i, h) in heights.block.indexed) {
          expect(h, moreOrLessEquals(240, epsilon: 0.5), reason: 'frame $i');
        }
        for (final (i, h) in heights.rows.indexed) {
          expect(h, moreOrLessEquals(body, epsilon: 0.01), reason: 'frame $i');
        }

        // The same path in a freshly mounted card: its final size at first
        // layout (cached per path, D7).
        await tester.pumpWidget(const SizedBox());
        final again = _t144RecordHeights(tester, 1);
        await _t144PumpRows(tester, text, hosted);
        expect(again.block, isNotEmpty);
        for (final (i, h) in again.block.indexed) {
          expect(h, moreOrLessEquals(240, epsilon: 0.5), reason: 'frame $i');
        }
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // The shared builders' height cap (R39): the card's 240 reaches the image
  // box, its intrinsics and a relayout on a change
  // -------------------------------------------------------------------------
  group('image box height cap (AC1)', () {
    Future<void> pumpBox(
      WidgetTester tester, {
      required double maxHeight,
      Size natural = const Size(300, 600),
    }) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: AttachmentImageBox(natural: natural, maxHeight: maxHeight),
          ),
        ),
      ),
    );

    testWidgets(
      'an image box and its intrinsic sizes honour a given height cap and relayout when it changes',
      (tester) async {
        await pumpBox(tester, maxHeight: 240);
        final box = tester.renderObject<RenderBox>(
          find.byType(AttachmentImageBox),
        );
        expect(
          tester.getSize(find.byType(AttachmentImageBox)),
          const Size(120, 240),
        );
        expect(box.getMaxIntrinsicWidth(double.infinity), 120);
        expect(box.getMinIntrinsicHeight(300), 240);
        expect(box.getMaxIntrinsicHeight(300), 240);
        expect(
          box.getDryLayout(const BoxConstraints(maxWidth: 300)),
          const Size(120, 240),
        );

        // A changed cap on the mounted box lays it out again.
        await pumpBox(tester, maxHeight: 480);
        expect(
          tester.getSize(find.byType(AttachmentImageBox)),
          const Size(240, 480),
        );
        await pumpBox(tester, maxHeight: 100);
        expect(
          tester.getSize(find.byType(AttachmentImageBox)),
          const Size(50, 100),
        );

        // Never upscaled, whatever the cap.
        await pumpBox(tester, maxHeight: 900, natural: const Size(100, 50));
        expect(
          tester.getSize(find.byType(AttachmentImageBox)),
          const Size(100, 50),
        );

        // The default cap is the editor's 480.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 300),
                child: AttachmentImageBox(natural: const Size(300, 600)),
              ),
            ),
          ),
        );
        expect(
          tester.getSize(find.byType(AttachmentImageBox)),
          const Size(240, 480),
        );
        expect(
          attachmentImageSize(const Size(300, 600), 300),
          const Size(240, 480),
        );
        expect(
          attachmentImageSize(const Size(300, 600), 300, maxHeight: 240),
          const Size(120, 240),
        );
      },
    );
  });
}
