// WI #79 (Spec #61 G0, ruling D15): GLOSSARY.md gains the Outline (#54),
// Command palette (#56) and Find in note (#55) sections, inserted directly
// before `## Releases (#356)`, which stays the last section (lead ruling Q1).
// A pure source scan: flutter test runs with cwd app/, so the repo file is
// `../GLOSSARY.md`. It pins the last five headings and each new section's
// text, and deliberately does not snapshot the rest of the file, which later
// WIs edit inside their own sections.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _outlineHeading = '## Outline (#54)';
const _paletteHeading = '## Command palette (#56)';
const _findHeading = '## Find in note (#55)';
const _navigationHeading = '## Navigation (#230)';
const _releasesHeading = '## Releases (#356)';

const _outlineBody = r'''
**Outline**:
The list of a note's headings, in document order and indented by heading level, that shows the note's structure and jumps to a section.
_Avoid_: table of contents, TOC, contents, headings panel
''';

const _paletteBody = r'''
**Command bar**:
The sidebar row, labelled `search · ask · run`, that opens the Command palette.
_Avoid_: search bar, omnibar, quick open, quick switcher, spotlight

**Command palette**:
The panel the Command bar or ⌘K opens: one input, a result list and a preview of the selected result. Typing finds app commands by name, notes and canvases by title, and Passages of note text.
_Avoid_: search bar, omnibar, quick open, quick switcher, spotlight

**Passage**:
A stretch of note text the Command palette finds by keyword and by meaning (Semantic recall).
_Avoid_: snippet
''';

const _findBody = r'''
**Find in note**:
Finding every occurrence of a query within the open note, from the Find bar.
_Avoid_: find-in-page, search (finding across the vault is the Command palette's job)

**Find bar**:
The floating box in the note editor that holds the query field, the match counter, and the previous, next and close buttons.
_Avoid_: search bar, find panel

**Match**:
One occurrence of the Find bar's query in the open note.
_Avoid_: hit, result

**Current match**:
The match the person has stepped to, drawn more strongly than the other matches and kept in view.
_Avoid_: selected match, active result
''';

String _glossary() => File('../GLOSSARY.md').readAsStringSync();

List<String> _headings(String text) =>
    text.split('\n').where((l) => l.startsWith('## ')).toList();

/// The text between [heading] and the next `## ` heading (or the end of the
/// file), trimmed. Fails when [heading] is absent.
String _section(String text, String heading) {
  final lines = text.split('\n');
  final start = lines.indexOf(heading);
  expect(start, isNonNegative, reason: 'GLOSSARY.md has $heading');
  var end = lines.length;
  for (var i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith('## ')) {
      end = i;
      break;
    }
  }
  return lines.sublist(start + 1, end).join('\n').trim();
}

void main() {
  test(
    'glossary ends with the Navigation Outline Command palette Find in note Releases headings in order',
    () {
      final headings = _headings(_glossary());
      expect(headings.length, greaterThanOrEqualTo(5));
      expect(headings.sublist(headings.length - 5), [
        _navigationHeading,
        _outlineHeading,
        _paletteHeading,
        _findHeading,
        _releasesHeading,
      ]);
    },
  );

  test('each new glossary heading appears exactly once', () {
    final headings = _headings(_glossary());
    for (final heading in [_outlineHeading, _paletteHeading, _findHeading]) {
      expect(headings.where((h) => h == heading).length, 1, reason: heading);
    }
  });

  test(
    'glossary Outline section holds the Outline entry verbatim and nothing else',
    () {
      expect(_section(_glossary(), _outlineHeading), _outlineBody.trim());
    },
  );

  test(
    'glossary Command palette section holds the Command bar Command palette and Passage entries verbatim',
    () {
      expect(_section(_glossary(), _paletteHeading), _paletteBody.trim());
    },
  );

  test(
    'glossary Find in note section holds the Find in note Find bar Match and Current match entries verbatim',
    () {
      expect(_section(_glossary(), _findHeading), _findBody.trim());
    },
  );
}
