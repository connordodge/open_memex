// WI #253 (r3): what SegmentedBody does when the note it shows changes under
// it. A role change alone (daily, topic, guide) rebuilds the segments and the
// footer even when the markdown is the same; a content change alone is taken
// even when no save completed; another note puts the caret at the end of its
// text, never where the previous note's caret was.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';

import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/note_footer_harness.dart';
import '../support/segment_editing_finder.dart';

typedef _Shown = ({Note note, String content, int? version});

/// [note] with [role] in its frontmatter, as the editor receives it.
Note _as(Note note, String role) => Note(
  id: note.id,
  title: note.title,
  contentMd: note.contentMd,
  frontmatter: jsonEncode({'role': role}),
  version: note.version,
  createdAt: note.createdAt,
  updatedAt: note.updatedAt,
  tags: note.tags,
  footerTags: note.footerTags,
);

/// Pumps a [SegmentedBody] that shows whatever the returned notifier holds.
Future<ValueNotifier<_Shown>> _pumpShown(
  WidgetTester tester,
  FakeVaultDb db,
  _Shown first,
) async {
  final dir = Directory.systemTemp.createTempSync('om253k');
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(FakeMemexCli()),
      clockProvider.overrideWithValue(FakeClock()),
    ],
  );
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A queued ui_state write raced the delete.
    }
  });
  addTearDown(db.close);
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  container.read(tabsProvider.notifier).openOrFocus(NoteTab(first.note.id));
  final shown = ValueNotifier<_Shown>(first);
  addTearDown(shown.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<_Shown>(
            valueListenable: shown,
            builder: (_, s, _) => SegmentedBody(
              note: s.note,
              content: s.content,
              savedVersion: s.version,
              onContentChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
  return shown;
}

Future<void> _show(
  WidgetTester tester,
  ValueNotifier<_Shown> shown,
  _Shown next,
) async {
  shown.value = next;
  await pumpFrames(tester);
}

/// A marker line inside a fence: text to a non-daily note, the start of the
/// footer to a daily one.
final _fenced = '```\n$topicsMarker\n```\nafter\n';

/// The same body as a daily note shows it: the marker line is dropped and the
/// lines below it join the person text.
const _dailyPerson = '```\n```\nafter\n';

void main() {
  group('a role change alone, with the same markdown', () {
    testWidgets(
      'a note that becomes a daily note splits at the marker inside the fence',
      (tester) async {
        final vault = seedFooterVault(body: _fenced);
        final note = vault.db.getNote(footerNoteId)!;
        final shown = await _pumpShown(tester, vault.db, (
          note: _as(note, 'topic'),
          content: note.contentMd,
          version: note.version,
        ));
        expect(segmentEditingAt(tester, 0).text, _fenced);

        await _show(tester, shown, (
          note: _as(note, 'daily'),
          content: note.contentMd,
          version: note.version,
        ));

        expect(segmentEditingAt(tester, 0).text, _dailyPerson);
      },
    );

    testWidgets(
      'a daily note that becomes a topic note keeps the fenced marker as text',
      (tester) async {
        final vault = seedFooterVault(body: _fenced);
        final note = vault.db.getNote(footerNoteId)!;
        final shown = await _pumpShown(tester, vault.db, (
          note: _as(note, 'daily'),
          content: note.contentMd,
          version: note.version,
        ));
        expect(segmentEditingAt(tester, 0).text, _dailyPerson);

        await _show(tester, shown, (
          note: _as(note, 'topic'),
          content: note.contentMd,
          version: note.version,
        ));

        expect(segmentEditingAt(tester, 0).text, _fenced);
      },
    );

    testWidgets('a note that becomes a guide note loses its footer', (
      tester,
    ) async {
      final vault = seedFooterVault(
        body: footerBody(footerPerson, tags: ['pricing']),
        footerTags: ['pricing'],
      );
      final note = vault.db.getNote(footerNoteId)!;
      final shown = await _pumpShown(tester, vault.db, (
        note: _as(note, 'topic'),
        content: note.contentMd,
        version: note.version,
      ));
      expect(footerRow, findsOneWidget);
      expect(segmentEditingAt(tester, 0).text, footerPerson);

      await _show(tester, shown, (
        note: _as(note, 'guide'),
        content: note.contentMd,
        version: note.version,
      ));

      expect(footerRow, findsNothing);
      // A guide body is text to the end: the marker line is part of it.
      expect(segmentEditingAt(tester, 0).text, note.contentMd);
    });

    testWidgets('a guide note that becomes a topic note gets its footer', (
      tester,
    ) async {
      final vault = seedFooterVault(
        body: footerBody(footerPerson, tags: ['pricing']),
        footerTags: ['pricing'],
      );
      final note = vault.db.getNote(footerNoteId)!;
      final shown = await _pumpShown(tester, vault.db, (
        note: _as(note, 'guide'),
        content: note.contentMd,
        version: note.version,
      ));
      expect(footerRow, findsNothing);
      expect(segmentEditingAt(tester, 0).text, note.contentMd);

      await _show(tester, shown, (
        note: _as(note, 'topic'),
        content: note.contentMd,
        version: note.version,
      ));

      expect(footerRow, findsOneWidget);
      expect(segmentEditingAt(tester, 0).text, footerPerson);
    });
  });

  group('a content change alone', () {
    testWidgets(
      'new content for the same note and kind is shown when no save completed',
      (tester) async {
        final vault = seedFooterVault(body: 'first draft\n');
        final note = _as(vault.db.getNote(footerNoteId)!, 'topic');
        final shown = await _pumpShown(tester, vault.db, (
          note: note,
          content: 'first draft\n',
          version: note.version,
        ));
        expect(segmentEditingAt(tester, 0).text, 'first draft\n');

        await _show(tester, shown, (
          note: note,
          content: 'second draft\n',
          version: note.version,
        ));

        expect(segmentEditingAt(tester, 0).text, 'second draft\n');
      },
    );
  });

  group('another note', () {
    testWidgets(
      'puts the caret at the end of its text, not where the last note had it',
      (tester) async {
        final vault = seedFooterVault(body: 'first note text\n');
        seedFooterNote(
          vault.db,
          id: otherNoteId,
          title: 'Other',
          body: 'second note text here\n',
        );
        final first = _as(vault.db.getNote(footerNoteId)!, 'topic');
        final second = _as(vault.db.getNote(otherNoteId)!, 'topic');
        final shown = await _pumpShown(tester, vault.db, (
          note: first,
          content: first.contentMd,
          version: first.version,
        ));
        await focusSegmentAt(tester, find.byKey(textSegmentKey(0)), offset: 3);
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 3),
        );

        await _show(tester, shown, (
          note: second,
          content: second.contentMd,
          version: second.version,
        ));

        expect(segmentEditingAt(tester, 0).text, 'second note text here\n');
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(
            offset: 'second note text here\n'.length,
          ),
        );
      },
    );

    testWidgets(
      'a server write to the open note keeps the caret where it was',
      (tester) async {
        final vault = seedFooterVault(body: 'first note text\n');
        final note = _as(vault.db.getNote(footerNoteId)!, 'topic');
        final shown = await _pumpShown(tester, vault.db, (
          note: note,
          content: note.contentMd,
          version: note.version,
        ));
        await focusSegmentAt(tester, find.byKey(textSegmentKey(0)), offset: 3);

        await _show(tester, shown, (
          note: note,
          content: 'first note text, longer\n',
          version: note.version,
        ));

        expect(segmentEditingAt(tester, 0).text, 'first note text, longer\n');
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 3),
        );
      },
    );
  });
}
