// WI #132 (Spec #122 Req 27, 35, 36 "Opening N2"; TD5): opening a note
// builds one editable field per text segment, its active row, and shows
// every other row as a `RichText` (`RenderParagraph`).
//
// Counts, never times: the editable fields under each text segment (a
// finder count, offstage included) and, per row, whether the row has a
// field (`rowField`) and what its geometry is (`rowBoxes`: a RichText's
// `RenderParagraphLineBoxes` for an idle row). On main one N2 open runs for
// seconds in the debug runner, so the bound is a generous timeout, and the
// count fails by assertion.
//
// Helpers carry the `_t132`/`wi132` prefix. Text is synthetic.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';

import '../robots/segmented_editor_robot.dart' show fixtureRangeToken;
import '../support/font_fetch_hold.dart';
import '../support/long_note_fixtures.dart';
import '../support/spelling_editor_pump.dart';
import '../support/wi132_idle_rows.dart';

const _t132Timeout = Timeout(Duration(minutes: 8));

/// Every text segment's rows host, in tree order.
List<SegmentViewState> _t132Hosts(WidgetTester tester) => [
  for (final e in find.byType(SegmentView, skipOffstage: false).evaluate())
    (e as StatefulElement).state as SegmentViewState,
];

/// Expects text segment [host] to hold exactly one editable field (its
/// active row's) and every other row to be a RichText with no field.
void _t132ExpectOneField(WidgetTester tester, SegmentViewState host) {
  final s = host.widget.index;
  final fields = find.descendant(
    of: find.byWidget(host.widget, skipOffstage: false),
    matching: find.byType(EditableText, skipOffstage: false),
    skipOffstage: false,
  );
  expect(
    fields.evaluate().length,
    1,
    reason: 'text segment $s builds one editable field (${host.rowCount} rows)',
  );
  final active = host.activeRow.value;
  expect(active, isNotNull, reason: 'text segment $s has an active row');
  expect(
    host.rowField(active!),
    isNotNull,
    reason: 'segment $s: the field is the active row $active',
  );
  var idle = 0;
  for (var i = 0; i < host.rowCount; i++) {
    if (i == active) continue;
    expect(host.rowField(i), isNull, reason: 'segment $s row $i: no field');
    expect(
      host.rowBoxes(i),
      isA<RenderParagraphLineBoxes>(),
      reason: 'segment $s row $i is a RenderParagraph',
    );
    idle++;
  }
  expect(idle, host.rowCount - 1, reason: 'segment $s: every other row');
}

void main() {
  holdFontFetches();

  testWidgets(
    'opening N2 builds exactly one editable field per text segment and every other row is a RenderParagraph',
    (tester) async {
      final note = longNote(LongNoteKind.n2Bullets120k);
      await pumpSpellingEditor(tester, body: '${note.text}\n');
      final hosts = _t132Hosts(tester);
      expect(hosts, isNotEmpty, reason: 'the note shows text segments');
      expect(
        hosts.first.rowCount,
        greaterThan(2900),
        reason: 'fixture: N2 is about 3,000 rows',
      );
      for (final host in hosts) {
        _t132ExpectOneField(tester, host);
      }
    },
    timeout: _t132Timeout,
  );

  testWidgets(
    'opening a note with an excerpt card builds one editable field in each text segment around it',
    (tester) async {
      await pumpSpellingEditor(
        tester,
        body:
            'Intro prose words\n- intro item one\n- intro item two\n'
            '$fixtureRangeToken\n'
            '- outro item one\nOutro prose words\n- outro item two\n',
      );
      final hosts = _t132Hosts(tester);
      expect(
        hosts.length,
        greaterThanOrEqualTo(2),
        reason: 'fixture: a text segment either side of the card',
      );
      expect(
        find.byKey(const Key('excerpt-card-1')),
        findsOneWidget,
        reason: 'fixture: the card is segment 1',
      );
      for (final host in hosts) {
        _t132ExpectOneField(tester, host);
      }
      expect(
        wi132Host(tester, 2).rowCount,
        greaterThanOrEqualTo(3),
        reason: 'fixture: the segment after the card has several rows',
      );
    },
    timeout: _t132Timeout,
  );
}
