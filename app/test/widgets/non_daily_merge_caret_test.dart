// WI #16 (Spec #7 Req 34a), fix round 1: what the open note editor shows after
// a non-daily merged save or a polled server write. The caret stays on the
// person's line (the segmented body carries each end of its selection through
// `carrySelection`), and Source mode follows the merged text, so the next
// keystroke builds on it instead of saving over the server's change.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart'
    show carrySelection;

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/font_fetch_hold.dart';
import '../support/spelling_editor_pump.dart';

const _base = 'Alpha\nBravo\nCharlie\n';

/// The topic note holds [body] at [version] on the server.
void _serverWrites(WorkspaceHarness h, String body, int version) {
  h.db.db.execute('UPDATE notes SET content_md = ?, version = ? WHERE id = ?', [
    body,
    version,
    fixtureTopicId,
  ]);
}

void main() {
  holdFontFetches();

  group('carrySelection', () {
    for (final (name, selection, before, after, expected) in [
      (
        'a caret on a line below an added line moves down with its line',
        const TextSelection.collapsed(offset: 8),
        'Alpha\nBravo\n',
        'Zero\nAlpha\nBravo\n',
        const TextSelection.collapsed(offset: 13),
      ),
      (
        'both ends of a range follow their own lines',
        const TextSelection(baseOffset: 1, extentOffset: 8),
        'Alpha\nBravo\n',
        'Zero\nAlpha\nBravo\n',
        const TextSelection(baseOffset: 6, extentOffset: 13),
      ),
      (
        'a backwards range keeps its direction',
        const TextSelection(baseOffset: 8, extentOffset: 1),
        'Alpha\nBravo\n',
        'Zero\nAlpha\nBravo\n',
        const TextSelection(baseOffset: 13, extentOffset: 6),
      ),
      (
        'an end past the old text is clamped to the new text',
        const TextSelection(baseOffset: 2, extentOffset: 40),
        'Alpha\n',
        'Zero\nAlpha\n',
        const TextSelection(baseOffset: 7, extentOffset: 11),
      ),
      (
        'an invalid selection is clamped to the start of the new text',
        const TextSelection.collapsed(offset: -1),
        'Alpha\n',
        'Zero\nAlpha\n',
        const TextSelection.collapsed(offset: 0),
      ),
    ]) {
      test(name, () {
        final carried = carrySelection(selection, before, after);
        expect(carried.baseOffset, expected.baseOffset);
        expect(carried.extentOffset, expected.extentOffset);
      });
    }
  });

  group('live preview', () {
    testWidgets(
      'a merged save keeps the caret on the person line when the server added a line above it',
      (tester) async {
        final vault = seedSegmentedVault(topicBody: _base);
        final r = await launchSegmented(tester, vault: vault);
        await r.open(fixtureTopicId);
        _serverWrites(r.h, 'Zero\n$_base', 5);
        await r.typeInSegment(0, 'Alpha\nBravo\nCharlie mine\n');
        // The caret ends the person's line.
        const caret = 'Alpha\nBravo\nCharlie mine'.length;
        await r.focusSegment(0, offset: caret);
        expect(r.segmentSelection(0).baseOffset, caret);

        await r.waitForSave();

        const merged = 'Zero\nAlpha\nBravo\nCharlie mine\n';
        expect(r.segmentText(0), merged);
        expect(r.h.db.getNote(fixtureTopicId)!.contentMd, merged);
        expect(r.h.read(editorControllerProvider).status, SaveStatus.clean);
        expect(r.segmentSelection(0).isCollapsed, isTrue);
        expect(r.segmentSelection(0).baseOffset, caret + 'Zero\n'.length);
      },
    );

    testWidgets(
      'a polled server change to a clean note keeps the caret on its line when a line was added above it',
      (tester) async {
        final vault = seedSegmentedVault(topicBody: _base);
        final r = await launchSegmented(tester, vault: vault);
        await r.open(fixtureTopicId);
        await r.focusSegment(0, offset: 'Alpha\nBra'.length);
        _serverWrites(r.h, 'Zero\n$_base', 5);

        final changed = await r.h
            .read(editorControllerProvider.notifier)
            .serverChanged(fixtureTopicId);
        await pumpFrames(tester);

        expect(changed, isTrue);
        expect(r.segmentText(0), 'Zero\n$_base');
        expect(r.segmentSelection(0).baseOffset, 'Zero\nAlpha\nBra'.length);
      },
    );
  });

  group('Source mode', () {
    testWidgets(
      'a merged save shows the merged text in the Source field with the caret on its line',
      (tester) async {
        final s = await pumpSpellingEditor(tester, body: _base, source: true);
        _serverWrites(s.workspace, 'Zero\n$_base', 5);
        final field = tester.widget<EditableText>(s.sourceField);
        await tester.enterText(s.sourceField, 'Alpha\nBravo\nCharlie mine\n');
        await tester.pump();
        const caret = 'Alpha\nBravo\nCharlie mine'.length;
        field.controller.selection = const TextSelection.collapsed(
          offset: caret,
        );
        await tester.pump();

        await s.advance(const Duration(milliseconds: 600));

        const merged = 'Zero\nAlpha\nBravo\nCharlie mine\n';
        final shown = tester.widget<EditableText>(s.sourceField).controller;
        expect(shown.text, merged);
        expect(shown.selection.baseOffset, caret + 'Zero\n'.length);
        expect(s.bodyText, merged);
      },
    );

    testWidgets(
      'the keystroke after a merged save builds on the merged text and keeps the server change',
      (tester) async {
        final s = await pumpSpellingEditor(tester, body: _base, source: true);
        _serverWrites(s.workspace, 'Zero\n$_base', 5);
        await tester.enterText(s.sourceField, 'Alpha\nBravo\nCharlie mine\n');
        await tester.pump();
        await s.advance(const Duration(milliseconds: 600));
        const merged = 'Zero\nAlpha\nBravo\nCharlie mine\n';
        expect(s.bodyText, merged);

        await s.typeAtEnd('More.\n');
        await s.advance(const Duration(milliseconds: 600));

        const typed = '${merged}More.\n';
        final note = s.workspace.db.getNote(fixtureTopicId)!;
        expect(note.contentMd, typed);
        expect(note.contentMd, startsWith('Zero\n'));
        expect(s.bodyText, typed);
        expect(
          s.container.read(editorControllerProvider).status,
          SaveStatus.clean,
        );
      },
    );

    testWidgets(
      'a polled server change to a clean note shows in the Source field with the caret on its line',
      (tester) async {
        final s = await pumpSpellingEditor(tester, body: _base, source: true);
        final controller = tester
            .widget<EditableText>(s.sourceField)
            .controller;
        controller.selection = const TextSelection.collapsed(
          offset: 'Alpha\nBra'.length,
        );
        await tester.pump();
        _serverWrites(s.workspace, 'Zero\n$_base', 5);

        await s.container
            .read(editorControllerProvider.notifier)
            .serverChanged(fixtureTopicId);
        await pumpFrames(tester);

        final shown = tester.widget<EditableText>(s.sourceField).controller;
        expect(shown.text, 'Zero\n$_base');
        expect(shown.selection.baseOffset, 'Zero\nAlpha\nBra'.length);
      },
    );

    testWidgets(
      'text typed in the Source field is not replaced by the controller text it matches',
      (tester) async {
        final s = await pumpSpellingEditor(tester, body: _base, source: true);

        await s.typeAtEnd('More.\n');
        final controller = tester
            .widget<EditableText>(s.sourceField)
            .controller;
        controller.selection = const TextSelection.collapsed(offset: 3);
        await tester.pump();
        await s.advance(const Duration(milliseconds: 600));

        expect(controller.text, '${_base}More.\n');
        expect(controller.selection.baseOffset, 3);
      },
    );
  });
}
