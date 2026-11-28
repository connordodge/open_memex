// WI #85 (Spec #61 F6), mutation follow-up batch 2: pins the find editor
// predicates the batch's first run did not kill.
// - SegmentView re-decorates its rows when its active flag or its segment
//   index changes, each alone.
// - A card reveal anchors on the row that starts exactly at the match.
// - SegmentedBody hands its text segments to the editor link while mounted,
//   clears them when it goes away, and never clears another body's.
//
// Note text is invented (public repo). Every helper carries the wi85b2
// prefix.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/excerpt_render.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/editor/excerpt_card.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';
import 'package:open_memex_app/src/widgets/find/find_in_note_host.dart';

import '../../support/fake_vault_db.dart';
import '../../support/find_pump.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/wi83_find_paint.dart';
import '../../support/wi85_find_editor.dart';

// ------------------------------------------------------- SegmentView ink

/// One text segment of [text] at segment [index], active or not.
class _Wi85b2Segment extends StatefulWidget {
  const _Wi85b2Segment({
    required this.text,
    required this.index,
    required this.active,
  });

  final String text;
  final int index;
  final bool active;

  @override
  State<_Wi85b2Segment> createState() => _Wi85b2SegmentState();
}

class _Wi85b2SegmentState extends State<_Wi85b2Segment> {
  late final _controller = LivePreviewController(text: widget.text);
  final _focus = FocusNode();
  final _gate = ValueNotifier(false);
  final _chips = KindChipHost();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _gate.dispose();
    _chips.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: SegmentView(
      index: widget.index,
      controller: _controller,
      focusNode: _focus,
      revealGate: _gate,
      minLines: 1,
      hintText: null,
      onChanged: () {},
      onRowRemoved: (_) {},
      active: widget.active,
      fieldBuilder: (context, row) => TextSegmentField(
        controller: row.controller,
        focusNode: row.focusNode,
        kindChips: _chips,
        paintsSelection: false,
      ),
      builder: (context, rows, _) => rows,
    ),
  );
}

/// The colour the one row field draws code unit [offset] of its text in.
Color? _wi85b2InkAt(WidgetTester tester, int offset) {
  final field = find.descendant(
    of: find.byType(SegmentView),
    matching: find.byType(EditableText),
  );
  expect(field, findsOneWidget, reason: 'the segment shows one row');
  final controller =
      tester.widget<EditableText>(field).controller as LivePreviewController;
  final span = controller.buildTextSpan(
    context: tester.element(field),
    withComposing: false,
  );
  return wi85ColorAt(span, offset);
}

// ------------------------------------------------------- SegmentedBody

Note _wi85b2Note(String content) => Note(
  id: 'topic-85b2',
  title: 'Mutation notes',
  contentMd: content,
  frontmatter: '{"role":"topic"}',
  version: 3,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

/// A [SegmentedBody] over [content] that shares [primary] with its editor
/// link, keyed [bodyKey].
Widget _wi85b2Body(String content, FocusNode primary, Key? bodyKey) =>
    ProviderScope(
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: SegmentedBody(
            key: bodyKey,
            note: _wi85b2Note(content),
            content: content,
            savedVersion: 3,
            primaryFocusNode: primary,
            onContentChanged: (_) {},
          ),
        ),
      ),
    );

// ------------------------------------------------------- card anchor

const _wi85b2CardNoteId = 'topic-85b2-card';

/// Intro, a card, a tail: the card is segment 1.
const _wi85b2CardNoteBody = 'Intro line.\n$wi85Token\nTail line.\n';

/// 200 list items, then a prose row that starts with the only `deep rye`.
final _wi85b2CardText = [
  for (var i = 0; i < 200; i++) '- filler item $i',
  'deep rye line',
].join('\n');

FakeVaultDb _wi85b2Vault() {
  final db = wi85SeedVault();
  db.seedNote(
    id: _wi85b2CardNoteId,
    title: 'Row start card',
    content: _wi85b2CardNoteBody,
  );
  return db;
}

/// The global rect of the lines of [needle] in the one [RichText] under
/// [under] whose text holds it, from the paragraph's own line boxes.
Rect _wi85b2TextRect(WidgetTester tester, Finder under, String needle) {
  final text = find.descendant(
    of: under,
    matching: find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().contains(needle),
    ),
  );
  expect(text, findsOneWidget, reason: '"$needle" shows once');
  final paragraph = tester.renderObject<RenderParagraph>(text);
  final at = paragraph.text.toPlainText().indexOf(needle);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: at, extentOffset: at + needle.length),
  );
  expect(boxes, isNotEmpty, reason: '"$needle" is laid out');
  final origin = paragraph.localToGlobal(Offset.zero);
  return boxes
      .map((b) => b.toRect())
      .reduce((a, b) => a.expandToInclude(b))
      .shift(origin);
}

void main() {
  holdFontFetches();

  group('card reveal anchor', () {
    testWidgets(
      'a current match at the very start of a card row lands that row in the band',
      (tester) async {
        // The fixture: the match starts the last row exactly, a prose row
        // after 200 item rows (a card taller than the viewport).
        final specs = splitRows(_wi85b2CardText, atSegmentStart: true);
        final matchAt = _wi85b2CardText.indexOf('deep rye');
        expect(specs.last.kind, RowKind.prose, reason: 'fixture');
        expect(specs.last.start, matchAt, reason: 'fixture: at a row start');
        expect(specs[specs.length - 2].kind, isNot(RowKind.prose));

        final w = await pumpWi85(
          tester,
          open: _wi85b2CardNoteId,
          db: _wi85b2Vault(),
          overrides: [
            excerptRenderProvider.overrideWith((ref, token) async {
              final vault = ref.watch(currentVaultProvider);
              return VaultScoped(
                vault,
                RenderedExcerpt(
                  date: wi85DailyDate,
                  text: _wi85b2CardText,
                  removed: false,
                ),
              );
            }),
          ],
        );
        final card = find.byKey(const Key('excerpt-card-1'));
        final view = w.h.viewport();
        expect(
          _wi85b2TextRect(tester, card, 'deep rye line').top,
          greaterThan(view.bottom),
          reason: 'fixture: the match starts below the viewport',
        );
        await w.send('show');
        final reveals = w.reveals();

        await w.typeQuery('deep rye');
        expect(reveals.count, 1);
        final at = reveals.last.at as RevealAtCard;
        expect(at.start, matchAt);
        final line = _wi85b2TextRect(tester, card, 'deep rye line');
        expect(line.top - view.top, greaterThanOrEqualTo(60 - 0.51));
        expect(
          line.bottom,
          lessThanOrEqualTo(view.bottom + 0.51),
          reason: 'the row holding the match, not the row before it, anchors',
        );
      },
    );
  });

  group('SegmentView find decoration', () {
    const text = 'rye one';
    const query = 'rye';

    testWidgets(
      'a segment view whose active flag alone changes inks its match only while active',
      (tester) async {
        final sources = [wi83Body(0, text)];
        Future<void> pump(bool active) => pumpFind(
          tester,
          sources: sources,
          query: query,
          current: 0,
          child: _Wi85b2Segment(text: text, index: 0, active: active),
        );

        await pump(false);
        expect(
          _wi85b2InkAt(tester, 0),
          isNot(OmColors.surface0),
          reason: 'inactive from the first frame: no match ink',
        );
        await pump(true);
        expect(
          _wi85b2InkAt(tester, 0),
          OmColors.surface0,
          reason: 'turning active inks the current match',
        );
        await pump(false);
        expect(
          _wi85b2InkAt(tester, 0),
          isNot(OmColors.surface0),
          reason: 'turning inactive takes the ink away',
        );
      },
    );

    testWidgets(
      'a segment view whose index alone changes inks the matches of its new segment',
      (tester) async {
        // Segment 0 matches at 0, segment 1 at 4; the current match is the
        // one in segment 1.
        const other = 'xyz rye';
        final sources = [wi83Body(0, text), wi83Body(1, other)];
        Future<void> pump(int index) => pumpFind(
          tester,
          sources: sources,
          query: query,
          current: 1,
          child: _Wi85b2Segment(text: text, index: index, active: true),
        );

        await pump(0);
        expect(
          _wi85b2InkAt(tester, 4),
          isNot(OmColors.surface0),
          reason: 'segment 0 holds no current match at offset 4',
        );
        await pump(1);
        expect(
          _wi85b2InkAt(tester, 4),
          OmColors.surface0,
          reason: 'at index 1 the current match of segment 1 inks',
        );
        await pump(0);
        expect(
          _wi85b2InkAt(tester, 4),
          isNot(OmColors.surface0),
          reason: 'back at index 0 the ink goes',
        );
      },
    );
  });

  group('SegmentedBody find link', () {
    const content = 'Plain rye line.\nAnother line.\n';

    testWidgets(
      'a mounted segmented body gives the link its text segments and clears them when it goes away',
      (tester) async {
        final primary = FocusNode(debugLabel: 'wi85b2-primary');
        addTearDown(primary.dispose);
        final link = FindEditorLink.of(primary);
        expect(link.fields, isNull, reason: 'fixture: nothing registered');

        await tester.pumpWidget(_wi85b2Body(content, primary, null));
        await tester.pump();
        final fields = link.fields;
        expect(fields, isNotNull, reason: 'mounted: the link has the fields');
        expect(
          [for (final f in fields!()) f.segment],
          [0],
          reason: 'the note is one text segment',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(link.fields, isNull, reason: 'gone: the link is cleared');
      },
    );

    testWidgets(
      'a segmented body that goes away after its replacement mounted leaves the replacement fields',
      (tester) async {
        final primary = FocusNode(debugLabel: 'wi85b2-primary');
        addTearDown(primary.dispose);
        final link = FindEditorLink.of(primary);

        await tester.pumpWidget(
          _wi85b2Body(content, primary, const ValueKey('first')),
        );
        await tester.pump();
        final first = link.fields;
        expect(first, isNotNull);

        // A new body takes over the same primary focus node while the first
        // is unmounted in the same frame: the new one registers first.
        await tester.pumpWidget(
          _wi85b2Body(content, primary, const ValueKey('second')),
        );
        await tester.pump();
        final second = link.fields;
        expect(second, isNotNull, reason: 'the replacement stays registered');
        expect(second, isNot(equals(first)), reason: 'they are the new one');
        expect([for (final f in second!()) f.segment], [0]);
      },
    );
  });
}
