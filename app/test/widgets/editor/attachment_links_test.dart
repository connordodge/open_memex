// WI #142 (Spec #123 V2: R27, R29, R33, R34; rulings D1, D9, D10): image and
// attachment link tokens in live preview, and how a click opens them.
//
// - Rendering: `buildLivePreviewSpan` (the pure builder the row controller
//   relays, pinned in live_preview_spans_test.dart) shows an image's
//   bracketed text link-styled (info, underlined) and hides `![` and
//   `](url)` off the caret line, as it does for a `[text](url)` link.
// - Opening: the whole segmented editor (`pumpTable`) under a recording
//   `urlOpenerProvider` and a `FakeAttachmentsAccess` for
//   `attachmentsProvider`. Click points come from the row-geometry accessor
//   (`editor_rows_probe.dart`, D17), never from a row's field widgets.
//   A click on a mid-text attachment reference calls the domain's `open`
//   with the decoded path and never the URL opener (D10); the domain applies
//   R33's executable table, so an executable reaches it the same way.
// - Web images (R29): link styled, opened by the existing link rules, never
//   fetched (no HTTP request, no image widget).
// - Spelling: the `objects/...` URL is a url skip, the bracketed name is
//   still checked.
import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/spell_ranges.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/vault_access/attachments_access.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_styles.dart';

import '../../support/attachments_fakes.dart';
import '../../support/editor_rows_probe.dart';
import '../../support/editor_scope.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/table_harness.dart';

/// 64 lowercase hex characters whose first two are the `<h2>` folder `3f`.
const _t142Hash =
    '3f1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcd';

/// The vault-relative path of the attachment [name] (decoded).
String _t142Path(String name) => 'objects/3f/$_t142Hash/$name';

/// The editor body base style (text_segment.dart's `_bodyStyle`).
TextStyle _t142Base() =>
    OmType.mono(size: 13.5, color: OmColors.fg0, height: 1.7);

/// The effective style of the code unit at [offset] of [root]: every
/// ancestor's style merged down to its leaf.
TextStyle _t142StyleAt(InlineSpan root, int offset) {
  TextStyle? found;
  var pos = 0;
  bool visit(InlineSpan span, TextStyle? inherited) {
    expect(span, isA<TextSpan>(), reason: 'no WidgetSpan (D1)');
    final own = span.style;
    final style = inherited == null
        ? own
        : (own == null ? inherited : inherited.merge(own));
    final textSpan = span as TextSpan;
    final t = textSpan.text ?? '';
    if (offset >= pos && offset < pos + t.length) {
      found = style;
      return false;
    }
    pos += t.length;
    for (final child in textSpan.children ?? const <InlineSpan>[]) {
      if (!visit(child, style)) return false;
    }
    return true;
  }

  visit(root, null);
  expect(found, isNotNull, reason: 'a style covers offset $offset');
  return found!;
}

/// Every code unit of [needle] (its [nth] occurrence) in [text] is link
/// styled: info and underlined.
void _t142ExpectLinkStyled(
  TextSpan span,
  String text,
  String needle, {
  int nth = 0,
}) {
  var at = -1;
  for (var i = 0; i <= nth; i++) {
    at = text.indexOf(needle, at + 1);
  }
  expect(at, isNonNegative, reason: 'text holds "$needle"');
  for (var o = at; o < at + needle.length; o++) {
    final s = _t142StyleAt(span, o);
    final why = '"$needle" offset $o in ${text.replaceAll('\n', r'\n')}';
    expect(s.color, OmColors.info, reason: why);
    expect(
      s.decoration?.contains(TextDecoration.underline) ?? false,
      isTrue,
      reason: why,
    );
  }
}

/// Every code unit of [needle] in [text] (its first occurrence at or after
/// [after]'s) is a hidden marker.
void _t142ExpectHidden(
  TextSpan span,
  String text,
  String needle, {
  String after = '',
}) {
  final at = text.indexOf(needle, text.indexOf(after));
  expect(at, isNonNegative, reason: 'text holds "$needle"');
  for (var o = at; o < at + needle.length; o++) {
    expect(
      _t142StyleAt(span, o).fontSize,
      livePreviewHiddenStyle.fontSize,
      reason: '"$needle" offset $o is hidden',
    );
  }
}

/// The global centre of [needle]'s first box in editor row [row] of text
/// segment 0, from the row-geometry accessor (row text offsets).
Offset _t142PointOn(WidgetTester tester, int row, String needle) {
  final text = rowTextOf(tester, 0, row);
  final at = text.indexOf(needle);
  expect(at, isNonNegative, reason: 'row $row holds "$needle": $text');
  final boxes = rowBoxesOf(tester, 0, row);
  final rects = boxes.boxesFor(TextRange(start: at, end: at + needle.length));
  expect(rects, isNotEmpty, reason: '"$needle" is laid out in row $row');
  return boxes.box.localToGlobal(rects.first.center);
}

/// A plain primary-button mouse click at [at] (global), with Cmd held when
/// [cmd]; then lets any click chain expire.
Future<void> _t142Click(
  WidgetTester tester,
  Offset at, {
  bool cmd = false,
}) async {
  if (cmd) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  }
  final gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryButton,
  );
  await tester.pump();
  await gesture.up();
  await tester.pump();
  if (cmd) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  }
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
  await tester.pump();
}

/// What [_t142Pump] pumped.
final class _T142Editor {
  _T142Editor(this.body, this.opener, this.attachments);

  final TableBody body;
  final RecordingUrlOpener opener;
  final FakeAttachmentsAccess? attachments;
}

/// Pumps the segmented editor on [text] with a recording URL opener and a
/// fake attachments domain (none when [noAttachments]).
Future<_T142Editor> _t142Pump(
  WidgetTester tester,
  String text, {
  bool noAttachments = false,
}) async {
  final opener = RecordingUrlOpener();
  final attachments = noAttachments ? null : FakeAttachmentsAccess();
  final body = await pumpTable(
    tester,
    text,
    opener: opener,
    overrides: [attachmentsProvider.overrideWithValue(attachments)],
  );
  await tester.pump();
  return _T142Editor(body, opener, attachments);
}

/// Records every HTTP request the app starts and never answers one.
final class _T142HttpRecorder extends HttpOverrides {
  final List<Uri> requested = [];
  int clients = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    return _T142RecordingClient(requested);
  }
}

final class _T142RecordingClient implements HttpClient {
  _T142RecordingClient(this.requested);

  final List<Uri> requested;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    for (final a in invocation.positionalArguments) {
      if (a is Uri) requested.add(a);
      if (a is String && a.contains('://')) requested.add(Uri.parse(a));
    }
    if (invocation.isMethod) return Completer<Never>().future;
    return null;
  }
}

void main() {
  holdFontFetches();

  group('rendering (R27, R29, R34)', () {
    test(
      'a mid text attachment image or link in a sentence list item or quote renders as a link styled name',
      () {
        final text =
            'See ![mock.png](${_t142Path('mock.png')}) here\n'
            '- list [spec.pdf](${_t142Path('spec.pdf')}) item\n'
            '> quote ![chart.png](${_t142Path('chart.png')}) end\n'
            'other';
        final span = buildLivePreviewSpan(
          text,
          style: _t142Base(),
          selection: TextSelection.collapsed(offset: text.length),
        );
        expect(span.toPlainText(), text);
        _t142ExpectLinkStyled(span, text, 'mock.png');
        _t142ExpectLinkStyled(span, text, 'spec.pdf');
        _t142ExpectLinkStyled(span, text, 'chart.png');
        _t142ExpectHidden(span, text, '![', after: 'See');
        _t142ExpectHidden(span, text, '](${_t142Path('mock.png')})');
        _t142ExpectHidden(span, text, '![', after: 'quote');
        _t142ExpectHidden(span, text, '[', after: 'list');
        _t142ExpectHidden(span, text, '](${_t142Path('chart.png')})');
        _t142ExpectHidden(span, text, '](${_t142Path('spec.pdf')})');
        // The words around them keep the body style.
        final see = _t142StyleAt(span, 0);
        expect(see.color, OmColors.fg0);
      },
    );

    test('an image on the caret line shows its bang with its markers', () {
      final text = 'See ![mock.png](${_t142Path('mock.png')}) here\nother';
      final span = buildLivePreviewSpan(
        text,
        style: _t142Base(),
        selection: const TextSelection.collapsed(offset: 1),
      );
      _t142ExpectLinkStyled(span, text, 'mock.png');
      final bang = text.indexOf('!');
      final shown = _t142StyleAt(span, bang);
      expect(
        shown.fontSize,
        isNot(livePreviewHiddenStyle.fontSize),
        reason: 'the bang is a revealed marker on the caret line',
      );
      expect(shown.color, OmColors.fg2, reason: 'a revealed marker is fg2');
    });
  });

  group('attachment names stay literal (R27, R34)', () {
    test(
      'an attachment name with underscores or stars shows as written while a web image text keeps emphasis',
      () {
        final text =
            'a ![_draft_.png](${_t142Path('_draft_.png')}) b\n'
            'c [*star*.txt](${_t142Path('*star*.txt')}) d\n'
            'e ![_web_](https://example.com/w.png) f\n'
            'other';
        final span = buildLivePreviewSpan(
          text,
          style: _t142Base(),
          selection: TextSelection.collapsed(offset: text.length),
        );
        _t142ExpectLinkStyled(span, text, '_draft_.png');
        _t142ExpectLinkStyled(span, text, '*star*.txt');
        // Not one character of the name is hidden and none is italic.
        for (final name in ['_draft_.png', '*star*.txt']) {
          final at = text.indexOf(name);
          for (var o = at; o < at + name.length; o++) {
            final s = _t142StyleAt(span, o);
            expect(
              s.fontSize,
              isNot(livePreviewHiddenStyle.fontSize),
              reason: '"$name" @$o is shown',
            );
            expect(s.fontStyle, isNot(FontStyle.italic), reason: name);
          }
        }
        // A web image keeps main's link rule: emphasis in its text applies.
        final web = text.indexOf('_web_');
        expect(
          _t142StyleAt(span, web).fontSize,
          livePreviewHiddenStyle.fontSize,
          reason: 'the web alt text opens italic, hiding its first underscore',
        );
        expect(_t142StyleAt(span, web + 1).fontStyle, FontStyle.italic);
      },
    );
  });

  group('empty brackets (R27, R34, ruling D21)', () {
    test(
      'an empty bracket attachment ref shows its file name link styled with the rest hidden',
      () {
        final text =
            'See ![](${_t142Path('chart.png')}) and [](${_t142Path('r.pdf')}) end\nother';
        final span = buildLivePreviewSpan(
          text,
          style: _t142Base(),
          selection: TextSelection.collapsed(offset: text.length),
        );
        expect(span.toPlainText(), text);
        _t142ExpectLinkStyled(span, text, 'chart.png');
        _t142ExpectLinkStyled(span, text, 'r.pdf');
        _t142ExpectHidden(span, text, '![](objects/3f/$_t142Hash/');
        _t142ExpectHidden(
          span,
          text,
          '[](objects/3f/$_t142Hash/',
          after: 'and',
        );
        _t142ExpectHidden(span, text, ')', after: 'chart.png');
        expect(_t142StyleAt(span, 0).color, OmColors.fg0);
        // A percent-encoded name shows as written (D21).
        final enc = '![](${_t142Path('My%20chart.png')})';
        final encSpan = buildLivePreviewSpan(
          enc,
          style: _t142Base(),
          selection: const TextSelection.collapsed(offset: 0),
        );
        expect(encSpan.toPlainText(), enc);
      },
    );

    testWidgets(
      'a click on an empty bracket attachment ref opens its decoded path through the attachments domain',
      (tester) async {
        final text =
            'See ![](${_t142Path('My%20chart.png')}) and []('
            '${_t142Path('run.command')}) end\nother';
        final e = await _t142Pump(tester, text);
        await _t142Click(tester, _t142PointOn(tester, 0, 'My%20chart.png'));
        await _t142Click(tester, _t142PointOn(tester, 0, 'run.command'));
        expect(e.attachments!.openCalls, [
          _t142Path('My chart.png'),
          _t142Path('run.command'),
        ]);
        expect(e.attachments!.revealCalls, isEmpty);
        expect(e.opener.opened, isEmpty, reason: 'never urlOpenerProvider');
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on an empty bracket link with any other destination opens nothing',
      (tester) async {
        // Each case sits on its own line, so a click on one never reveals
        // another (only the clicked line shows its markers). Clicked where a wrong tokenization would show the name.
        final cases = <(String, String)>[
          ('![](https://example.com/x.png)', 'x.png'),
          ('[](https://example.org)', 'example.org'),
          ('[](a/b.png)', 'b.png'),
        ];
        // The control sits in a sentence: a lone reference line is an
        // attachment row (#143), not a link in a paragraph row.
        final control = 'see ![](${_t142Path('ok.png')}) end';
        final text =
            'head\n${[for (final c in cases) c.$1].join('\n')}\n$control\ntail';
        // Rendered: none is link styled or hidden (no token), the control is.
        final span = buildLivePreviewSpan(
          text,
          style: _t142Base(),
          selection: TextSelection.collapsed(offset: text.length),
        );
        for (final (ref, _) in cases) {
          final at = text.indexOf(ref);
          for (var o = at; o < at + ref.length; o++) {
            final s = _t142StyleAt(span, o);
            expect(s.color, isNot(OmColors.info), reason: '$ref @$o');
            expect(
              s.fontSize,
              isNot(livePreviewHiddenStyle.fontSize),
              reason: '$ref @$o is not a hidden marker',
            );
          }
        }
        _t142ExpectLinkStyled(span, text, 'ok.png');

        final e = await _t142Pump(tester, text);
        expect(rowTextOf(tester, 0, 0), text, reason: 'one paragraph row');
        for (final (_, name) in cases) {
          await _t142Click(tester, _t142PointOn(tester, 0, name));
        }
        expect(e.attachments!.openCalls, isEmpty);
        expect(e.opener.opened, isEmpty);
        // The same click on a real empty bracket attachment ref opens it:
        // the clicks above did reach link rows.
        await _t142Click(tester, _t142PointOn(tester, 0, 'ok.png'));
        expect(e.attachments!.openCalls, [_t142Path('ok.png')]);
        expect(e.opener.opened, isEmpty);
      },
      variant: macOnly,
    );
  });

  group('web images (R29)', () {
    testWidgets(
      'a web image renders as link styled alt text and nothing fetches it',
      (tester) async {
        const text = 'See ![logo](https://example.com/logo.png) here\nother';
        final span = buildLivePreviewSpan(
          text,
          style: _t142Base(),
          selection: TextSelection.collapsed(offset: text.length),
        );
        _t142ExpectLinkStyled(span, text, 'logo');
        _t142ExpectHidden(span, text, '![');
        _t142ExpectHidden(span, text, '](https://example.com/logo.png)');

        final previous = HttpOverrides.current;
        final http = _T142HttpRecorder();
        HttpOverrides.global = http;
        addTearDown(() => HttpOverrides.global = previous);
        final e = await _t142Pump(tester, text);
        await tester.pump(const Duration(seconds: 1));
        expect(rowTextOf(tester, 0, 0), text);
        expect(find.byType(Image), findsNothing);
        expect(find.byType(RawImage), findsNothing);
        expect(
          [
            for (final u in http.requested)
              if (u.host == 'example.com') u,
          ],
          isEmpty,
          reason: 'the web image is never fetched',
        );
        expect(e.attachments!.readCalls, isEmpty);
        expect(e.attachments!.infoCalls, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on a web image opens its url as a link does and never the attachments domain',
      (tester) async {
        const text = 'See ![logo](https://example.com/logo.png) here\nother';
        final e = await _t142Pump(tester, text);
        await _t142Click(tester, _t142PointOn(tester, 0, 'logo'));
        expect(e.opener.opened, ['https://example.com/logo.png']);
        expect(e.attachments!.openCalls, isEmpty);
        expect(e.attachments!.revealCalls, isEmpty);
      },
      variant: macOnly,
    );
  });

  group('opening attachments (R27, R33, R34, D10)', () {
    testWidgets(
      'a click on a mid text attachment image opens its decoded path through the attachments domain',
      (tester) async {
        final text =
            'See ![My chart.png](${_t142Path('My%20chart.png')}) here\nother';
        final e = await _t142Pump(tester, text);
        await _t142Click(tester, _t142PointOn(tester, 0, 'chart'));
        expect(e.attachments!.openCalls, [_t142Path('My chart.png')]);
        expect(e.attachments!.revealCalls, isEmpty);
        expect(e.opener.opened, isEmpty, reason: 'never urlOpenerProvider');
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on an attachment link in a sentence list item or quote opens it through the attachments domain',
      (tester) async {
        final text =
            'See [notes.txt](${_t142Path('notes.txt')}) here\n'
            '- list [spec.pdf](${_t142Path('spec.pdf')}) item\n'
            '> quote ![pic.png](${_t142Path('pic.png')}) end\n'
            'other';
        final e = await _t142Pump(tester, text);
        expect(rowTextOf(tester, 0, 1), contains('spec.pdf'));
        expect(rowTextOf(tester, 0, 2), contains('pic.png'));
        await _t142Click(tester, _t142PointOn(tester, 0, 'notes.txt'));
        await _t142Click(tester, _t142PointOn(tester, 1, 'spec.pdf'));
        await _t142Click(tester, _t142PointOn(tester, 2, 'pic.png'));
        expect(e.attachments!.openCalls, [
          _t142Path('notes.txt'),
          _t142Path('spec.pdf'),
          _t142Path('pic.png'),
        ]);
        expect(e.opener.opened, isEmpty, reason: 'never urlOpenerProvider');
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on a mid text link to an executable calls the attachments domain and no url opener',
      (tester) async {
        final text =
            'Run [run.command](${_t142Path('run.command')}) now\n'
            'and [Setup.APP](${_t142Path('Setup.APP')}) too\nother';
        final e = await _t142Pump(tester, text);
        await _t142Click(tester, _t142PointOn(tester, 0, 'run.command'));
        await _t142Click(tester, _t142PointOn(tester, 0, 'Setup.APP'));
        expect(e.attachments!.openCalls, [
          _t142Path('run.command'),
          _t142Path('Setup.APP'),
        ]);
        expect(
          [
            for (final u in e.opener.opened)
              if (u.contains('objects/')) u,
          ],
          isEmpty,
          reason: 'no /usr/bin/open call with an objects/ path',
        );
        expect(e.opener.opened, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on an attachment link whose open fails asks the domain once and never the url opener',
      (tester) async {
        final text = 'See [gone.pdf](${_t142Path('gone.pdf')}) here\nother';
        final e = await _t142Pump(tester, text);
        e.attachments!.openResults.add(
          const AttachmentActionFailed(AttachmentLookupFailure.missing),
        );
        await _t142Click(tester, _t142PointOn(tester, 0, 'gone.pdf'));
        expect(e.attachments!.openCalls, [_t142Path('gone.pdf')]);
        expect(
          e.opener.opened,
          isEmpty,
          reason: 'a failed open never falls back to the url opener',
        );
        expect(tester.takeException(), isNull);
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd click on an attachment link on the caret line opens it through the attachments domain',
      (tester) async {
        final text = 'See [spec.pdf](${_t142Path('spec.pdf')}) here\nother';
        final e = await _t142Pump(tester, text);
        await activateRow(tester, 0, 0, offset: 1);
        // A plain click on a revealed line places the caret and opens nothing.
        await _t142Click(tester, _t142PointOn(tester, 0, 'spec.pdf'));
        expect(e.attachments!.openCalls, isEmpty);
        await _t142Click(
          tester,
          _t142PointOn(tester, 0, 'spec.pdf'),
          cmd: true,
        );
        expect(e.attachments!.openCalls, [_t142Path('spec.pdf')]);
        expect(e.opener.opened, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'hovering an attachment name shows the click cursor and a relative non attachment link does not',
      (tester) async {
        final text =
            'See [spec.pdf](${_t142Path('spec.pdf')}) and [doc](notes/a.md)\n'
            'other';
        await _t142Pump(tester, text);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await tester.pump();
        MouseCursor? cursor() =>
            RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
        await mouse.moveTo(_t142PointOn(tester, 0, 'spec.pdf'));
        await tester.pump();
        expect(cursor(), SystemMouseCursors.click);
        await mouse.moveTo(_t142PointOn(tester, 0, 'doc'));
        await tester.pump();
        expect(cursor(), isNot(SystemMouseCursors.click));
      },
      variant: macOnly,
    );

    testWidgets(
      'with no vault attachments domain a click on an attachment link opens nothing',
      (tester) async {
        final text = 'See [spec.pdf](${_t142Path('spec.pdf')}) here\nother';
        final e = await _t142Pump(tester, text, noAttachments: true);
        await _t142Click(tester, _t142PointOn(tester, 0, 'spec.pdf'));
        expect(e.opener.opened, isEmpty, reason: 'never urlOpenerProvider');
        // The same click on a web link still opens it.
        await tester.pumpWidget(const SizedBox());
        final web = await _t142Pump(
          tester,
          'See [site](https://example.com/a) here\nother',
          noAttachments: true,
        );
        await _t142Click(tester, _t142PointOn(tester, 0, 'site'));
        expect(web.opener.opened, ['https://example.com/a']);
      },
      variant: macOnly,
    );
  });

  group('links as on main (R29)', () {
    testWidgets(
      'http https and mailto links open through the url opener and a relative path or malformed attachment opens nothing',
      (tester) async {
        final bad = 'objects/3f/${_t142Hash.substring(1)}/x.pdf';
        final text =
            'A [one](http://a.example/1) B [two](HTTPS://b.example/2) '
            'C [three](mailto:c@d.example)\n'
            'D [doc](notes/a.md) E ![pic](pics/cat.png) F [bad]($bad) '
            'G [upper](${_t142Path('x.pdf').toUpperCase()})\n'
            'H ![shot](https://e.example/s.png)\nother';
        final e = await _t142Pump(tester, text);
        for (final name in ['one', 'two', 'three']) {
          await _t142Click(tester, _t142PointOn(tester, 0, name));
        }
        for (final name in ['doc', 'pic', 'bad', 'upper']) {
          await _t142Click(tester, _t142PointOn(tester, 0, name));
        }
        await _t142Click(tester, _t142PointOn(tester, 0, 'shot'));
        expect(e.opener.opened, [
          'http://a.example/1',
          'HTTPS://b.example/2',
          'mailto:c@d.example',
          'https://e.example/s.png',
        ]);
        expect(e.attachments!.openCalls, isEmpty);
        expect(e.attachments!.revealCalls, isEmpty);
      },
      variant: macOnly,
    );
  });

  group('spelling (watch list)', () {
    test(
      'spelling skips an attachment reference url and still checks its bracketed name',
      () {
        final cases = <(String, String)>[
          (
            'See ![Recieve form.png](${_t142Path('Recieve%20form.png')}) ok',
            'Recieve form.png',
          ),
          (
            '- list [Teh spec.pdf](${_t142Path('Teh%20spec.pdf')}) item',
            'Teh spec.pdf',
          ),
          ('> quote ![Wierd.gif](${_t142Path('Wierd.gif')}) end', 'Wierd.gif'),
        ];
        for (final (text, name) in cases) {
          final skips = spellSkipRanges(text, atSegmentStart: true);
          final open = text.indexOf('](') + 2;
          final close = text.lastIndexOf(')');
          final urls = [
            for (final s in skips)
              if (s.kind == SpellSkipKind.url) text.substring(s.start, s.end),
          ];
          expect(urls, contains(text.substring(open, close)), reason: text);
          // Every code unit of the url is skipped.
          for (var o = open; o < close; o++) {
            expect(dropsSpelling(o, o + 1, skips), isTrue, reason: '$text @$o');
          }
          // The bracketed name is checked: no skip touches it.
          final at = text.indexOf(name);
          for (final word in name.split(RegExp(r'[ .]'))) {
            final w = text.indexOf(word, at);
            expect(
              dropsSpelling(w, w + word.length, skips),
              isFalse,
              reason: '"$word" in $text is checked',
            );
          }
        }
      },
    );
  });
}
