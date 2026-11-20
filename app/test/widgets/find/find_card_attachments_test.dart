// WI #144 (Spec #123 R39; ruling D27; review round 1): Find in note and an
// excerpt card's attachment lines.
//
// A card shows a transcluded attachment line as the image or the file card
// and none of its text, so a match on the bracketed name would count and
// step with nothing to highlight or reveal. Find therefore skips whole
// attachment lines inside cards (as it drops a wholly hidden card match,
// Req 4). Editor-body attachment lines still match, and every other card
// row (a sentence holding a reference, plain text) still matches.
//
// The real workspace over the shared Find fixture ([pumpWi85]), whose daily
// note gains three blocks; the topic note's card transcludes them. Find is
// opened the way the native menu does it ([Wi85.openOn]).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';

import '../../support/attachments_fakes.dart';
import '../../support/daily_seed.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/wi85_find_editor.dart';

const _t144TopicId = 'topic-144-find';

/// The card's three blocks: a plain line holding the query, an attachment
/// line whose name holds it, and a sentence holding a reference whose name
/// holds it (its file name too: that part of the link stays hidden).
const _t144Plain = 'Diagram sketch notes';
final _t144Image =
    '![diagram](objects/5e/${testAttachmentHash(1)}/diagram.png)';
final _t144Sentence =
    'Then ![diagram](objects/5e/${testAttachmentHash(2)}/diagram-two.png) inline';

/// The topic note: an Outro line and a body attachment line, both holding
/// the query, after the card.
final _t144Body =
    'Intro line\n'
    '![[$wi85DailyDate#^t144a..^t144c]]\n'
    'Outro diagram line\n'
    '![diagram](objects/5e/${testAttachmentHash(3)}/body.png)\n';

void main() {
  holdFontFetches();

  testWidgets(
    'find counts a card plain line and a sentence but not a card attachment line and still counts body attachment lines',
    (tester) async {
      final db = wi85SeedVault();
      db.seedBlock(wi85DailyId, 't144a', ord: 2, text: _t144Plain);
      db.seedBlock(wi85DailyId, 't144b', ord: 3, text: _t144Image);
      db.seedBlock(wi85DailyId, 't144c', ord: 4, text: _t144Sentence);
      db.seedNote(
        id: _t144TopicId,
        title: 'Diagram notes',
        role: 'topic',
        content: _t144Body,
      );
      final w = await pumpWi85(
        tester,
        db: db,
        open: _t144TopicId,
        overrides: [
          attachmentsProvider.overrideWithValue(FakeAttachmentVault()),
        ],
      );
      // Fixture: the card shows the attachment block for its second row.
      expect(
        find.byKey(const ValueKey('card-attachment-1')),
        findsOneWidget,
        reason: 'the card shows its attachment line as a block',
      );

      await w.openOn('diagram');

      final cardText = [_t144Plain, _t144Image, _t144Sentence].join('\n');
      final cardMatches = [
        for (final m in w.state.matches)
          if (m.kind == FindSourceKind.card) m,
      ];
      expect(
        [for (final m in cardMatches) m.start],
        [
          cardText.indexOf('Diagram'),
          cardText.indexOf('diagram', cardText.indexOf('Then')),
        ],
        reason: 'the plain line and the sentence, never the attachment line',
      );
      final imageStart = cardText.indexOf(_t144Image);
      for (final m in cardMatches) {
        expect(
          m.start < imageStart || m.start >= imageStart + _t144Image.length,
          isTrue,
          reason: 'no match inside the card attachment line',
        );
      }
      final bodyMatches = [
        for (final m in w.state.matches)
          if (m.kind == FindSourceKind.body) m,
      ];
      expect(
        bodyMatches,
        hasLength(2),
        reason: 'the Outro line and the body attachment line still match',
      );
      expect(w.counter, endsWith(' of 4'));
    },
  );
}
