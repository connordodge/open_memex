// WI #147 (Spec #123 A2: R7, R11; rulings D12, D17): the note editor's drop
// target, over the real app (wi147_drop_paste_harness.dart).
//
// Drops go through A1's fake drop seam (`FakeAttachmentDropSource`): a test
// fires enter, update, exit and drop at a global point converted to the
// `AttachmentDropTarget` box's local frame. Stores go to #146's held
// `FakeAttachmentsAccess` through A4's real controller, so the anchor shows
// in the inserted body (`planAttachmentInsert`). Each anchor test puts the
// caret on another line first, so a drop that fell back to the caret line
// would insert elsewhere.
//
// The outline (Key `editor-drop-outline`) is the agents sheet's focus-ring
// style: a `BoxDecoration` border, 2 px `OmColors.accent` on every side,
// over the whole drop target.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/attachment_drop_target.dart';
import 'package:open_memex_app/src/widgets/editor/excerpt_card.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';

import '../../robots/segmented_editor_robot.dart';
import '../../support/app_harness.dart' show pumpFrames;
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/segment_editing_finder.dart';
import '../../support/wi146_attach_harness.dart';
import '../../support/wi147_drop_paste_harness.dart';

const _card = fixtureRangeToken;
const _footer = '$topicsMarker\n[[Zeta Game~about]]\n';

final _m = wi146Line('mock.png');
final _s = wi146Line('spec.pdf');

/// The outline shows: one bordered box, 2 px accent on every side, over the
/// whole drop target.
void _expectOutline(Wi147Rig g) {
  final outline = find.byKey(attachmentDropOutlineKey);
  expect(outline, findsOneWidget, reason: 'the drop outline shows');
  final bordered = [
    for (final d in g.tester.widgetList<DecoratedBox>(
      find.descendant(
        of: outline,
        matching: find.byType(DecoratedBox),
        matchRoot: true,
      ),
    ))
      if (d.decoration case BoxDecoration(border: final Border border)) border,
  ];
  expect(bordered, hasLength(1), reason: 'one bordered box');
  final border = bordered.single;
  for (final side in [border.top, border.right, border.bottom, border.left]) {
    expect(side.color, OmColors.accent);
    expect(side.width, 2);
    expect(side.style, BorderStyle.solid);
  }
  expect(
    g.tester.getRect(outline),
    g.targetRect(),
    reason: 'the outline goes around the whole editor body',
  );
}

void _expectNoOutline() => expect(
  find.byKey(attachmentDropOutlineKey),
  findsNothing,
  reason: 'no drop outline',
);

/// Opens [noteId] and expects the drop target around its body.
Future<void> _open(Wi147Rig g, [String noteId = wi146NoteId]) async {
  await g.r.open(noteId);
  g.targetRect();
}

/// A modal of [kind] shown over the workspace, with a way to close it.
Future<void Function()> _showModal(Wi147Rig g, String kind) async {
  final tester = g.tester;
  switch (kind) {
    case 'palette':
      await g.r.openPalette();
      return g.r.closePalette;
    case 'dialog':
      unawaited(
        showDialog<void>(
          context: g.r.context,
          builder: (_) => const AlertDialog(content: Text('wi147 dialog')),
        ),
      );
      await pumpFrames(tester);
      expect(find.text('wi147 dialog'), findsOneWidget);
      return () =>
          Navigator.of(tester.element(find.text('wi147 dialog'))).pop();
    case 'sheet':
      unawaited(
        showModalBottomSheet<void>(
          context: g.r.context,
          builder: (_) =>
              const SizedBox(height: 120, child: Text('wi147 sheet')),
        ),
      );
      await pumpFrames(tester);
      expect(find.text('wi147 sheet'), findsOneWidget);
      return () => Navigator.of(tester.element(find.text('wi147 sheet'))).pop();
  }
  throw ArgumentError(kind);
}

void main() {
  holdFontFetches();

  group('a drop on a line (AC1)', () {
    testWidgets(
      'dropping two files on a line calls the controller with both files in drop order anchored to that line',
      (tester) async {
        final g = await wi147Pump(tester, body: 'Alpha\nBeta\nGamma');
        await _open(g);
        await g.r.caretAfter('Gamma');
        g.r.bodyChanges.clear();

        await g.dropAt(g.lineCenter(1), const [wi147PngPath, wi147PdfPath]);

        expect(g.addedPaths, [wi147PngPath, wi147PdfPath]);
        expect(g.body, 'Alpha\nBeta\n\n$_m\n$_s\n\nGamma');
        expect(g.r.bodyChanges, hasLength(1), reason: 'one edit');
      },
    );

    testWidgets(
      'a drop on the first line anchors there and not at the caret line',
      (tester) async {
        final g = await wi147Pump(tester);
        await _open(g);
        await g.r.caretAfter('Next steps');

        await g.dropAt(g.lineCenter(0), const [wi147PngPath, wi147PdfPath]);

        expect(g.body, 'Review the draft\n\n$_m\n$_s\n\nNext steps');
      },
    );

    testWidgets('a drop keeps the order the files were dropped in', (
      tester,
    ) async {
      final g = await wi147Pump(tester, body: 'Alpha\nBeta\nGamma');
      await _open(g);
      await g.r.caretAfter('Alpha');

      await g.dropAt(g.lineCenter(1), const [wi147PdfPath, wi147PngPath]);

      expect(g.addedPaths, [wi147PdfPath, wi147PngPath]);
      expect(g.body, 'Alpha\nBeta\n\n$_s\n$_m\n\nGamma');
    });

    testWidgets(
      'a drop on the second visual line of a wrapped line anchors to that markdown line',
      (tester) async {
        final long = List.filled(160, 'wrapping').join(' ');
        final g = await wi147Pump(tester, body: 'Alpha\n$long\nGamma');
        await _open(g);
        await g.r.caretAfter('Gamma');
        final handle = segmentEditingAt(tester, 0);
        const start = 'Alpha\n'.length;
        final first = handle.rectForOffset(start + 1);
        final last = handle.rectForOffset(start + long.length - 2);
        expect(
          last.center.dy,
          greaterThan(first.bottom),
          reason: 'markdown line 1 wraps onto more visual lines',
        );
        final at = Offset(last.left, last.center.dy);

        await g.dropAt(at, const [wi147PngPath]);

        expect(g.body, 'Alpha\n$long\n\n$_m\n\nGamma');
      },
    );

    testWidgets(
      'in Source mode the same drop anchors to the line under the point',
      (tester) async {
        final g = await wi147Pump(tester, body: 'Alpha\nBeta\nGamma');
        await _open(g);
        await g.r.sourceCaret(0);
        g.targetRect();
        g.r.bodyChanges.clear();

        await g.dropAt(g.sourceLineCenter(1), const [
          wi147PngPath,
          wi147PdfPath,
        ]);

        expect(g.addedPaths, [wi147PngPath, wi147PdfPath]);
        expect(g.body, 'Alpha\nBeta\n\n$_m\n$_s\n\nGamma');
        expect(g.r.robot.sourceText, g.body);
        expect(g.r.bodyChanges, hasLength(1), reason: 'one edit');
      },
      variant: macOnly,
    );

    testWidgets(
      'a dropped folder path goes to the controller unchanged so the domain can refuse it',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('w147-folder');
        addTearDown(() => dir.deleteSync(recursive: true));
        final g = await wi147Pump(tester, body: 'Alpha\nBeta');
        await _open(g);

        await g.dropAt(g.lineCenter(0), [dir.path]);

        expect(g.addedPaths, [dir.path], reason: 'never stat-filtered here');
      },
    );
  });

  group('below the last line and on an excerpt card (AC2)', () {
    testWidgets(
      'a drop below the last line anchors to the last line of the person section',
      (tester) async {
        const topic = 'Intro line\nOutro line\n$_footer';
        final g = await wi147Pump(tester, topicBody: topic);
        await _open(g, fixtureTopicId);
        await g.r.caretAfter('Intro line');

        await g.dropAt(g.belowLastLine(), const [wi147PngPath]);

        expect(g.addedPaths, [wi147PngPath]);
        expect(g.body, 'Intro line\nOutro line\n\n$_m\n$_footer');
      },
    );

    testWidgets(
      'a drop below the last line of a note without a footer anchors to its last line',
      (tester) async {
        final g = await wi147Pump(tester);
        await _open(g);
        await g.r.caretAfter('Review the draft');

        await g.dropAt(g.belowLastLine(), const [wi147PngPath, wi147PdfPath]);

        expect(g.body, 'Review the draft\nNext steps\n\n$_m\n$_s');
      },
    );

    testWidgets(
      'in Source mode a drop below the last line anchors to the last line of the person section',
      (tester) async {
        const topic = 'Intro line\nOutro line\n$_footer';
        final g = await wi147Pump(tester, topicBody: topic);
        await _open(g, fixtureTopicId);
        await g.r.sourceCaret(0);

        await g.dropAt(g.belowLastLine(), const [wi147PngPath]);

        expect(g.body, 'Intro line\nOutro line\n\n$_m\n$_footer');
      },
      variant: macOnly,
    );

    testWidgets('a drop on an excerpt card anchors to the line of the card', (
      tester,
    ) async {
      const topic = 'Intro line\n$_card\nOutro line';
      final g = await wi147Pump(tester, topicBody: topic);
      await _open(g, fixtureTopicId);
      await g.r.caretAfter('Outro line', segment: 2);
      final card = find.byType(ExcerptCard);
      expect(card, findsOneWidget);

      await g.dropAt(tester.getCenter(card), const [wi147PngPath]);

      expect(g.addedPaths, [wi147PngPath]);
      expect(g.body, 'Intro line\n$_card\n\n$_m\n\nOutro line');
    });
  });

  group('drops elsewhere do nothing (AC2)', () {
    testWidgets(
      'a drop on the note header does nothing while a drop on a line attaches',
      (tester) async {
        final g = await wi147Pump(tester);
        await _open(g);
        g.r.bodyChanges.clear();

        await g.dropAt(g.headerCenter(), const [wi147PngPath]);
        expect(g.attaches, 0, reason: 'the header takes no drop');
        expect(g.body, wi146Example);
        expect(g.r.bodyChanges, isEmpty);

        await g.dropAt(g.lineCenter(0), const [wi147PngPath]);
        expect(g.addedPaths, [wi147PngPath]);
      },
    );

    testWidgets(
      'in Source mode a drop on the note header does nothing while a drop on a line attaches',
      (tester) async {
        final g = await wi147Pump(tester);
        await _open(g);
        await g.r.sourceCaret(0);
        g.r.bodyChanges.clear();

        await g.dropAt(g.headerCenter(), const [wi147PngPath]);
        expect(g.attaches, 0, reason: 'the header takes no drop');
        expect(g.body, wi146Example);

        await g.dropAt(g.sourceLineCenter(1), const [wi147PngPath]);
        expect(g.addedPaths, [wi147PngPath]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a drop reported over the sidebar outside the editor body does nothing while a drop on a line attaches',
      (tester) async {
        final g = await wi147Pump(tester);
        await _open(g);
        final sidebar = find.byType(Sidebar);
        expect(sidebar, findsOneWidget);
        final at = tester.getCenter(sidebar);
        expect(g.targetRect().contains(at), isFalse);

        await g.dropAt(at, const [wi147PngPath]);
        expect(g.attaches, 0, reason: 'the sidebar takes no drop');
        expect(g.body, wi146Example);

        await g.dropAt(g.lineCenter(1), const [wi147PngPath]);
        expect(g.addedPaths, [wi147PngPath]);
      },
    );
  });

  group('the drag outline (AC3)', () {
    testWidgets(
      'while files are dragged over the editor a 2 px accent outline shows and it goes away on exit',
      (tester) async {
        final g = await wi147Pump(tester);
        await _open(g);
        _expectNoOutline();

        final at = g.local(g.lineCenter(0));
        g.drop.enter(at);
        await tester.pump();
        _expectOutline(g);
        g.drop.update(at.translate(0, 4));
        await tester.pump();
        _expectOutline(g);

        g.drop.exit();
        await tester.pump();
        _expectNoOutline();
        expect(g.attaches, 0, reason: 'an exit attaches nothing');
        expect(g.body, wi146Example);
      },
    );

    testWidgets('the outline goes away when the files are dropped', (
      tester,
    ) async {
      final g = await wi147Pump(tester);
      await _open(g);

      await g.dragOver(g.lineCenter(0));
      _expectOutline(g);
      g.drop.drop(const [
        wi147PngPath,
      ], localPosition: g.local(g.lineCenter(0)));
      await tester.pump();
      _expectNoOutline();
      await g.r.releaseAll();
      _expectNoOutline();
      expect(g.addedPaths, [wi147PngPath]);
    });

    testWidgets(
      'in Source mode the outline shows while files are dragged over the editor',
      (tester) async {
        final g = await wi147Pump(tester);
        await _open(g);
        await g.r.sourceCaret(0);
        _expectNoOutline();

        await g.dragOver(g.sourceLineCenter(0));
        _expectOutline(g);
        g.drop.exit();
        await tester.pump();
        _expectNoOutline();
      },
      variant: macOnly,
    );
  });

  group('a modal over the editor (AC4)', () {
    for (final (kind, name) in [
      (
        'palette',
        'with the Command palette open a drop over the editor does nothing and shows no outline',
      ),
      (
        'dialog',
        'with a dialog open a drop over the editor does nothing and shows no outline',
      ),
      (
        'sheet',
        'with a sheet open a drop over the editor does nothing and shows no outline',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final g = await wi147Pump(tester);
        await _open(g);
        final at = g.lineCenter(0);
        final close = await _showModal(g, kind);
        g.r.bodyChanges.clear();

        await g.dragOver(at);
        _expectNoOutline();
        await g.dropAt(at, const [wi147PngPath]);
        expect(g.attaches, 0, reason: 'no drop under the $kind');
        expect(g.body, wi146Example);
        expect(g.r.bodyChanges, isEmpty);

        close();
        await pumpFrames(tester);
        await tester.pump(const Duration(seconds: 1));
        await g.dropAt(at, const [wi147PngPath]);
        expect(g.addedPaths, [
          wi147PngPath,
        ], reason: 'once the $kind is closed the same drop attaches');
      });
    }
  });

  group('a vault that cannot be written (AC8)', () {
    testWidgets(
      'with canWrite false a drop does nothing and shows no outline while with canWrite true it attaches',
      (tester) async {
        final g = await wi147Pump(tester);
        await _open(g);
        await g.setWritable(false);
        g.r.bodyChanges.clear();

        await g.dragOver(g.lineCenter(0));
        _expectNoOutline();
        await g.dropAt(g.lineCenter(0), const [wi147PngPath]);
        expect(g.attaches, 0);
        expect(g.body, wi146Example);
        expect(g.r.bodyChanges, isEmpty);

        await g.setWritable(true);
        await g.dragOver(g.lineCenter(0));
        _expectOutline(g);
        await g.dropAt(g.lineCenter(0), const [wi147PngPath]);
        expect(g.addedPaths, [wi147PngPath]);
      },
    );
  });
}
