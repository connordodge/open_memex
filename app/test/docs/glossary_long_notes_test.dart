// WI #132 (Spec #122 Req 27, ruling D16; Ledger L9): GLOSSARY.md gains the
// `## Long notes (#120)` section with Active row and Idle row, right after
// `## Markdown tables (#192)`, and #122 rewords the Editor row entry. A pure
// source scan (cwd app/, so the repo file is `../GLOSSARY.md`); the last
// five headings stay pinned by `glossary_run_20261118_test.dart`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _tablesHeading = '## Markdown tables (#192)';
const _longNotesHeading = '## Long notes (#120)';

const _longNotesBody = r'''
**Active row**:
The one editor row of a text segment that is shown as an editable field: the row whose field has keyboard focus while the segment is focused (a selection that crosses rows keeps it in the row the selection started from), otherwise the row holding the segment's selection extent.
_Avoid_: focused row, live row, editing row

**Idle row**:
Any editor row that is not the active row, shown as static text laid out exactly as its field would be, selection highlight, revealed markup, spelling squiggles and find highlights included. It becomes the active row when the caret moves into it.
_Avoid_: static row, resting row, read-only row
''';

const _editorRowEntry = r'''
**Editor row**:
One row of a text segment in the live-preview editor: an item row holds one list item, task or quote line with its marker in a left column, and a prose row holds a run of consecutive lines that are not item lines. At any moment an editor row is either the active row or an idle row. Not the same thing as a block.
_Avoid_: block, block field, line field
''';

String _glossary() => File('../GLOSSARY.md').readAsStringSync();

List<String> _headings(String text) =>
    text.split('\n').where((l) => l.startsWith('## ')).toList();

/// The text between [heading] and the next `## ` heading, trimmed.
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
    'glossary has the Long notes heading once right after the Markdown tables heading',
    () {
      final headings = _headings(_glossary());
      expect(
        headings.where((h) => h == _longNotesHeading),
        hasLength(1),
        reason: 'one $_longNotesHeading',
      );
      final tables = headings.indexOf(_tablesHeading);
      expect(tables, isNonNegative, reason: 'GLOSSARY.md has $_tablesHeading');
      expect(
        headings[tables + 1],
        _longNotesHeading,
        reason: 'Long notes follows Markdown tables',
      );
    },
  );

  test(
    'glossary Long notes section holds the Active row and Idle row entries verbatim',
    () {
      expect(_section(_glossary(), _longNotesHeading), _longNotesBody.trim());
    },
  );

  test(
    'glossary Editor row entry is reworded for active and idle rows and keeps its Avoid line',
    () {
      final text = _glossary();
      expect(
        text,
        contains(_editorRowEntry.trim()),
        reason: 'the reworded Editor row entry',
      );
      expect(
        '**Editor row**:'.allMatches(text),
        hasLength(1),
        reason: 'one Editor row entry',
      );
    },
  );
}
