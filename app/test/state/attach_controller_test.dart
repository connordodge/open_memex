// WI #146 (Spec #123 A4, R9, R12-R15; L2, L14, L16): the attach action,
// driven through `attachControllerProvider` over the real note editor in
// live preview and in Source mode (wi146_attach_harness.dart).
//
// Stores go through the held `FakeAttachmentsAccess`, so a test can act
// while storing. The editor is read through its handles and
// `editorControllerProvider`; one undo step is checked with Cmd+Z.

import 'package:material_ui/material_ui.dart' show FocusManager, SnackBar;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/attach_controller.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/attachments_access.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart' show pumpFrames;
import '../support/attachments_fakes.dart';
import '../support/editor_rows_probe.dart';
import '../support/fake_clock.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';
import '../support/wi146_attach_harness.dart';

const _wi146BigMessage = 'big.mov is larger than 100 MB and wasn’t attached.';
const _wi146BigMessageAscii =
    "big.mov is larger than 100 MB and wasn't attached.";
const _wi146HugeMessage = "huge.zip is larger than 100 MB and wasn't attached.";
const _wi146BigPath = '/vaults/Inbox/big.mov';
const _wi146HugePath = '/vaults/Inbox/huge.zip';

/// The R12 example after attaching mock.png and spec.pdf at line 0.
final _wi146ExampleAfter =
    'Review the draft\n\n${wi146Line('mock.png')}\n${wi146Line('spec.pdf')}'
    '\n\nNext steps';

/// Starts [paths]' action at the caret line without waiting for it.
void _wi146Start(Wi146Harness r, List<String> paths, {int? anchorLine}) {
  unawaited(r.controller.attachPaths(r.context, paths, anchorLine: anchorLine));
}

/// Runs [paths]' action to its end (stores answer at once).
Future<void> _wi146Attach(
  Wi146Harness r,
  List<String> paths, {
  int? anchorLine,
}) async {
  _wi146Start(r, paths, anchorLine: anchorLine);
  await r.releaseAll();
}

void main() {
  holdFontFetches();

  group('one action inserts once, as one edit (AC3)', () {
    testWidgets(
      'the lines are inserted once after every file is stored as one edit',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.attachments.holding = true;
        r.bodyChanges.clear();

        _wi146Start(r, const [wi146MockPath, wi146SpecPath]);
        await pumpFrames(tester);
        expect(r.attachments.pending, greaterThan(0), reason: 'storing');
        r.attachments.releaseNext();
        await pumpFrames(tester);
        expect(
          r.body,
          wi146Example,
          reason: 'nothing is inserted while a file is still storing',
        );
        expect(r.bodyChanges, isEmpty);

        await r.releaseAll();
        expect(r.body, _wi146ExampleAfter);
        expect(r.bodyChanges, [
          _wi146ExampleAfter,
        ], reason: 'one edit reports the body once');
        expect(
          [for (final c in r.attachments.addCalls) c.filePath],
          [wi146MockPath, wi146SpecPath],
          reason: 'each file stored once, in order',
        );
      },
    );

    testWidgets(
      'one Cmd Z removes the whole group in live preview and the files stay stored',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');

        await _wi146Attach(r, const [wi146MockPath, wi146SpecPath]);
        expect(segmentEditingAt(tester, 0).text, _wi146ExampleAfter);
        expect(r.body, _wi146ExampleAfter);

        rowsHostOf(tester).widget.focusNode.requestFocus();
        await tester.pump(const Duration(seconds: 1));
        await tester.macCmdChord(LogicalKeyboardKey.keyZ);
        await pumpFrames(tester);
        expect(segmentEditingAt(tester, 0).text, wi146Example);
        expect(r.body, wi146Example, reason: 'one undo removes both lines');
        expect(r.attachments.addCalls, hasLength(2));
        expect(r.attachments.openCalls, isEmpty);
        expect(r.attachments.revealCalls, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'one Cmd Z removes the whole group in Source mode and the files stay stored',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.sourceCaret('Review the draft'.length);
        await tester.pump(const Duration(milliseconds: 600));

        await _wi146Attach(r, const [wi146MockPath, wi146SpecPath]);
        expect(r.robot.sourceText, _wi146ExampleAfter);
        expect(r.body, _wi146ExampleAfter);

        await tester.pump(const Duration(milliseconds: 600));
        await tester.macCmdChord(LogicalKeyboardKey.keyZ);
        await pumpFrames(tester);
        expect(r.robot.sourceText, wi146Example, reason: 'one undo step');
        expect(r.body, wi146Example);
        expect(r.attachments.addCalls, hasLength(2));
      },
      variant: macOnly,
    );

    testWidgets(
      'in live preview the caret goes to the start of the blank line after the group',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');

        await _wi146Attach(r, const [wi146MockPath, wi146SpecPath]);
        final sel = segmentEditingAt(tester, 0).selection;
        final want = _wi146ExampleAfter.indexOf('\n\nNext steps') + 1;
        expect(sel.isCollapsed, isTrue);
        expect(sel.baseOffset, want);
      },
    );

    testWidgets(
      'in Source mode the caret goes to the start of the blank line after the group',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.sourceCaret(3);

        await _wi146Attach(r, const [wi146MockPath, wi146SpecPath]);
        expect(r.robot.sourceText, _wi146ExampleAfter);
        final sel = r.sourceController.selection;
        expect(sel.isCollapsed, isTrue);
        expect(
          sel.baseOffset,
          _wi146ExampleAfter.indexOf('\n\nNext steps') + 1,
        );
      },
    );

    testWidgets('an explicit anchor line puts the group after that line', (
      tester,
    ) async {
      final r = await wi146Pump(tester, body: 'Alpha\nBeta\nGamma');
      await r.open();
      await r.caretAfter('Alpha');

      await _wi146Attach(r, const [wi146MockPath], anchorLine: 2);
      expect(r.body, 'Alpha\nBeta\nGamma\n\n${wi146Line('mock.png')}');
    });

    testWidgets(
      'attachBytes stores the bytes under the given name and inserts its line at the caret line',
      (tester) async {
        final r = await wi146Pump(tester, body: 'Alpha\nBeta');
        await r.open();
        await r.caretAfter('Alpha');
        const name = 'Pasted image 2026-11-18 14.03.22.png';
        final bytes = Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47]);

        unawaited(r.controller.attachBytes(r.context, bytes, name));
        await r.releaseAll();

        expect(r.attachments.addBytesCalls, hasLength(1));
        expect(r.attachments.addBytesCalls.single.name, name);
        expect(r.attachments.addBytesCalls.single.bytes, bytes);
        expect(r.attachments.addCalls, isEmpty);
        expect(r.body, 'Alpha\n\n${wi146Line(name)}\n\nBeta');
      },
    );

    testWidgets(
      'in live preview with an excerpt card the group goes in the text segment holding the caret',
      (tester) async {
        const topic = 'Intro line\n$fixtureRangeToken\nOutro line';
        final r = await wi146Pump(tester, topicBody: topic);
        await r.open(fixtureTopicId);
        expect(r.body, topic);
        await r.caretAfter('Outro line', segment: 2);

        await _wi146Attach(r, const [wi146MockPath]);
        expect(r.body, '$topic\n\n${wi146Line('mock.png')}');
        expect(segmentEditingAt(tester, 0).text, isNot(contains('mock.png')));
      },
    );
  });

  group('the footer in both modes (AC2)', () {
    testWidgets(
      'in a daily note in live preview the group stays above the Topics footer',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open(fixtureDailyId);
        final before = assembleDailyBody(fixturePerson, const [
          'Zeta Game',
          'Alpha Topic',
        ]);
        expect(r.body, before);
        await r.caretAfter('Sleep was bad.');

        await _wi146Attach(r, const [wi146MockPath]);
        expect(
          r.body,
          before.replaceFirst(
            'Sleep was bad.\n',
            'Sleep was bad.\n\n${wi146Line('mock.png')}\n',
          ),
        );
        expect(splitDailyBody(r.body).chips, ['Zeta Game', 'Alpha Topic']);
      },
    );

    testWidgets(
      'in a daily note in Source mode a caret on a footer line puts the group above the Topics footer',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open(fixtureDailyId);
        final before = r.body;
        await r.sourceCaret(before.indexOf('[[Zeta Game~about]]') + 3);

        await _wi146Attach(r, const [wi146MockPath]);
        final want = before.replaceFirst(
          'Sleep was bad.\n',
          'Sleep was bad.\n\n${wi146Line('mock.png')}\n',
        );
        expect(r.robot.sourceText, want);
        expect(r.body, want);
      },
    );

    testWidgets(
      'in a note with a Note footer in Source mode a caret on the footer puts the group above it',
      (tester) async {
        const body = 'Plan\n$topicsMarker\n[[Zeta Game~about]]\n';
        final r = await wi146Pump(tester, body: body);
        await r.open();
        await r.sourceCaret(body.indexOf('[[Zeta'));

        await _wi146Attach(r, const [wi146MockPath]);
        expect(
          r.body,
          'Plan\n\n${wi146Line('mock.png')}\n$topicsMarker\n[[Zeta Game~about]]\n',
        );
      },
    );
  });

  group('the anchor is carried while storing (AC4)', () {
    testWidgets(
      'text typed above the anchor while storing keeps the group on the anchor line',
      (tester) async {
        const body = 'Alpha\nBeta\nGamma';
        final r = await wi146Pump(tester, body: body);
        await r.open();
        await r.caretAfter('Beta');
        r.attachments.holding = true;

        _wi146Start(r, const [wi146MockPath]);
        await pumpFrames(tester);
        // Typed above the anchor, and the caret moved to the last line.
        const typed = 'New\n$body';
        segmentEditingAt(tester, 0).applyEdit(
          SegmentEdit(
            start: 0,
            end: 0,
            replacement: 'New\n',
            selection: SegmentSelection.collapsed(typed.length),
          ),
        );
        await pumpFrames(tester);
        expect(r.body, typed);

        await r.releaseAll();
        expect(
          r.body,
          'New\nAlpha\nBeta\n\n${wi146Line('mock.png')}\n\nGamma',
          reason: 'the group follows Beta, not the caret line',
        );
      },
    );

    testWidgets(
      'in Source mode text typed above the anchor while storing keeps the group on the anchor line',
      (tester) async {
        const body = 'Alpha\nBeta\nGamma';
        final r = await wi146Pump(tester, body: body);
        await r.open();
        await r.sourceCaret('Alpha\nBe'.length);
        r.attachments.holding = true;

        _wi146Start(r, const [wi146MockPath]);
        await pumpFrames(tester);
        const typed = 'New\n$body';
        await r.sourceInput(
          const TextEditingValue(
            text: typed,
            selection: TextSelection.collapsed(offset: typed.length),
          ),
        );
        await pumpFrames(tester);
        expect(r.body, typed);

        await r.releaseAll();
        expect(
          r.robot.sourceText,
          'New\nAlpha\nBeta\n\n${wi146Line('mock.png')}\n\nGamma',
        );
      },
    );

    testWidgets(
      'with the anchor line deleted while storing the group goes after the caret line',
      (tester) async {
        const body = 'Alpha\nBeta\nGamma';
        final r = await wi146Pump(tester, body: body);
        await r.open();
        await r.caretAfter('Beta');
        r.attachments.holding = true;

        _wi146Start(r, const [wi146MockPath]);
        await pumpFrames(tester);
        // Beta's whole line is deleted; the caret ends on Gamma, not on the
        // line above the deleted anchor.
        segmentEditingAt(tester, 0).applyEdit(
          const SegmentEdit(
            start: 6,
            end: 11,
            replacement: '',
            selection: SegmentSelection.collapsed(11),
          ),
        );
        await pumpFrames(tester);
        expect(r.body, 'Alpha\nGamma');

        await r.releaseAll();
        expect(
          r.body,
          'Alpha\nGamma\n\n${wi146Line('mock.png')}',
          reason: 'after the caret line (Gamma), not the line above Beta',
        );
      },
    );

    testWidgets(
      'in Source mode with the anchor line deleted while storing the group goes after the caret line',
      (tester) async {
        const body = 'Alpha\nBeta\nGamma';
        final r = await wi146Pump(tester, body: body);
        await r.open();
        await r.sourceCaret('Alpha\nBe'.length);
        r.attachments.holding = true;

        _wi146Start(r, const [wi146MockPath]);
        await pumpFrames(tester);
        const typed = 'Alpha\nGamma';
        await r.sourceInput(
          const TextEditingValue(
            text: typed,
            selection: TextSelection.collapsed(offset: typed.length),
          ),
        );
        await pumpFrames(tester);
        expect(r.body, typed);

        await r.releaseAll();
        expect(
          r.robot.sourceText,
          'Alpha\nGamma\n\n${wi146Line('mock.png')}',
          reason: 'after the caret line (Gamma), not the line above Beta',
        );
      },
    );
  });

  group('the note closed while storing (AC4)', () {
    testWidgets(
      'with the note switched before storing ends nothing is inserted and the toast names the closed note',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.attachments.holding = true;

        _wi146Start(r, const [wi146MockPath, wi146SpecPath]);
        await pumpFrames(tester);
        await r.open(wi146OtherId);
        expect(r.body, wi146OtherBody);

        await r.releaseAll();
        expect(
          r.body,
          wi146OtherBody,
          reason: 'nothing goes in the other note',
        );
        expect(
          find.text(
            'Attached 2 files, but Planning notes was closed; drop or pick '
            'them again to add them.',
          ),
          findsOneWidget,
        );
        expect(r.storedContent(wi146NoteId), wi146Example);
        await r.open();
        expect(r.body, wi146Example, reason: 'nothing was inserted');
        expect(r.attachments.addCalls, hasLength(2), reason: 'files stay');
      },
    );

    testWidgets(
      'with the note tab closed before storing ends nothing is inserted and the toast reads Attached 1 file',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.attachments.holding = true;

        _wi146Start(r, const [wi146MockPath]);
        await pumpFrames(tester);
        r.h.read(tabsProvider.notifier).close(const NoteTab(wi146NoteId));
        await pumpFrames(tester);

        await r.releaseAll();
        expect(
          find.text(
            'Attached 1 file, but Planning notes was closed; drop or pick '
            'them again to add them.',
          ),
          findsOneWidget,
        );
        expect(r.storedContent(wi146NoteId), wi146Example);
        await r.open();
        expect(r.body, wi146Example);
      },
    );
  });

  group('toasts (AC5)', () {
    testWidgets(
      'while storing two files the toast reads Attaching 2 files and it is replaced when the action ends',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.attachments.holding = true;

        _wi146Start(r, const [wi146MockPath, wi146SpecPath]);
        await pumpFrames(tester);
        expect(find.text('Attaching 2 files…'), findsOneWidget);
        // Longer than a SnackBar's default 4 s: still shown while storing.
        await tester.pump(const Duration(seconds: 6));
        await pumpFrames(tester);
        expect(find.text('Attaching 2 files…'), findsOneWidget);

        await r.releaseAll();
        expect(find.text('Attaching 2 files…'), findsNothing);
        expect(r.body, _wi146ExampleAfter);
      },
    );

    testWidgets('while storing one file the toast reads Attaching 1 file', (
      tester,
    ) async {
      final r = await wi146Pump(tester);
      await r.open();
      await r.caretAfter('Review the draft');
      r.attachments.holding = true;

      _wi146Start(r, const [wi146MockPath]);
      await pumpFrames(tester);
      expect(find.text('Attaching 1 file…'), findsOneWidget);
      expect(find.text('Attaching 1 files…'), findsNothing);

      await r.releaseAll();
      expect(find.text('Attaching 1 file…'), findsNothing);
    });

    testWidgets(
      'one failed file shows the single failure toast and the other files still attach',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.attachments.addResults
          ..add(AttachmentAdded(fakeAddedAttachment('mock.png')))
          ..add(
            const AttachmentAddFailed(
              AttachmentAddFailureReason.tooLarge,
              _wi146BigMessageAscii,
            ),
          );

        await _wi146Attach(r, const [wi146MockPath, _wi146BigPath]);
        expect(
          find.text("Couldn't attach big.mov: $_wi146BigMessageAscii"),
          findsOneWidget,
        );
        expect(find.textContaining('Attaching'), findsNothing);
        expect(
          r.body,
          'Review the draft\n\n${wi146Line('mock.png')}\n\nNext steps',
        );
      },
    );

    testWidgets(
      'the failure reason is shown verbatim from the domain message',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.attachments.addResults.add(
          const AttachmentAddFailed(
            AttachmentAddFailureReason.tooLarge,
            _wi146BigMessage,
          ),
        );

        await _wi146Attach(r, const [_wi146BigPath]);
        expect(
          find.text('Couldn’t attach big.mov: $_wi146BigMessage'),
          findsNothing,
          reason: 'the prefix copy uses a straight apostrophe',
        );
        expect(
          find.text("Couldn't attach big.mov: $_wi146BigMessage"),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'two failed files show one toast with the count and the first reason',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.attachments.addResults
          ..add(
            const AttachmentAddFailed(
              AttachmentAddFailureReason.tooLarge,
              _wi146BigMessageAscii,
            ),
          )
          ..add(AttachmentAdded(fakeAddedAttachment('mock.png')))
          ..add(
            const AttachmentAddFailed(
              AttachmentAddFailureReason.tooLarge,
              _wi146HugeMessage,
            ),
          );

        await _wi146Attach(r, const [
          _wi146BigPath,
          wi146MockPath,
          _wi146HugePath,
        ]);
        expect(
          find.text("Couldn't attach 2 files: $_wi146BigMessageAscii"),
          findsOneWidget,
        );
        expect(find.textContaining('huge.zip'), findsNothing);
        expect(
          r.body,
          'Review the draft\n\n${wi146Line('mock.png')}\n\nNext steps',
          reason: 'the stored file still attaches',
        );
      },
    );

    testWidgets('an action whose files all fail inserts nothing', (
      tester,
    ) async {
      final r = await wi146Pump(tester);
      await r.open();
      await r.caretAfter('Review the draft');
      r.attachments.addResults
        ..add(
          const AttachmentAddFailed(
            AttachmentAddFailureReason.tooLarge,
            _wi146BigMessageAscii,
          ),
        )
        ..add(
          const AttachmentAddFailed(
            AttachmentAddFailureReason.tooLarge,
            _wi146HugeMessage,
          ),
        );
      r.bodyChanges.clear();

      await _wi146Attach(r, const [_wi146BigPath, _wi146HugePath]);
      expect(r.attachments.addCalls, hasLength(2));
      expect(
        find.text("Couldn't attach 2 files: $_wi146BigMessageAscii"),
        findsOneWidget,
      );
      expect(r.body, wi146Example);
      expect(r.bodyChanges, isEmpty, reason: 'no edit at all');
    });

    testWidgets('a folder refusal is shown through the failure toast', (
      tester,
    ) async {
      final r = await wi146Pump(tester);
      await r.open();
      await r.caretAfter('Review the draft');
      r.attachments.addResults.add(
        const AttachmentAddFailed(
          AttachmentAddFailureReason.folder,
          "Folders can't be attached.",
        ),
      );

      await _wi146Attach(r, const ['/vaults/Inbox/Assets']);
      expect(
        find.text("Couldn't attach Assets: Folders can't be attached."),
        findsOneWidget,
      );
      expect(r.body, wi146Example);
    });
  });

  group('stores that go wrong or have nothing to do (AC5)', () {
    testWidgets(
      'a store that throws becomes a failure toast and the other files still attach',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.attachments.throwingNames.add('spec.pdf');

        await _wi146Attach(r, const [wi146MockPath, wi146SpecPath]);
        expect(
          find.text("Couldn't attach spec.pdf: Exception: disk gone"),
          findsOneWidget,
        );
        expect(
          r.body,
          'Review the draft\n\n${wi146Line('mock.png')}\n\nNext steps',
        );
        expect(find.textContaining('Attaching'), findsNothing);
      },
    );

    testWidgets(
      'a failed pasted image shows the failure toast with its name and inserts nothing',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.attachments.addBytesResults.add(
          const AttachmentAddFailed(
            AttachmentAddFailureReason.unsupported,
            'Not supported here.',
          ),
        );
        r.bodyChanges.clear();
        const name = 'Pasted image 2026-11-18 14.03.22.png';

        unawaited(
          r.controller.attachBytes(
            r.context,
            Uint8List.fromList(const [1, 2, 3]),
            name,
          ),
        );
        await r.releaseAll();
        expect(
          find.text("Couldn't attach $name: Not supported here."),
          findsOneWidget,
        );
        expect(r.body, wi146Example);
        expect(r.bodyChanges, isEmpty);
      },
    );

    testWidgets('an action with no paths stores nothing and shows no toast', (
      tester,
    ) async {
      final r = await wi146Pump(tester);
      await r.open();
      await r.caretAfter('Review the draft');
      r.bodyChanges.clear();

      await _wi146Attach(r, const []);
      expect(r.attachments.addCalls, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      expect(r.bodyChanges, isEmpty);
    });

    testWidgets(
      'a closed note toast and a failure toast both show, the closed one first',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.attachments.addResults
          ..add(AttachmentAdded(fakeAddedAttachment('mock.png')))
          ..add(
            const AttachmentAddFailed(
              AttachmentAddFailureReason.tooLarge,
              _wi146BigMessageAscii,
            ),
          );
        r.attachments.holding = true;

        _wi146Start(r, const [wi146MockPath, _wi146BigPath]);
        await pumpFrames(tester);
        await r.open(wi146OtherId);
        await r.releaseAll();

        expect(find.textContaining('was closed'), findsOneWidget);
        expect(find.textContaining("Couldn't attach"), findsNothing);
        final failure = find.textContaining("Couldn't attach");
        for (var i = 0; i < 30 && failure.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(
          find.text("Couldn't attach big.mov: $_wi146BigMessageAscii"),
          findsOneWidget,
          reason: 'the failure toast follows the closed toast',
        );
      },
    );
  });

  group('the anchor and caret edges (AC4)', () {
    testWidgets(
      'in Source mode typing on the anchor line while storing keeps the group after that line',
      (tester) async {
        const body = 'Alpha\nBeta\nGamma';
        final r = await wi146Pump(tester, body: body);
        await r.open();
        await r.sourceCaret('Alpha\nBeta'.length);
        r.attachments.holding = true;

        _wi146Start(r, const [wi146MockPath]);
        await pumpFrames(tester);
        const typed = 'Alpha\nBeta!!\nGamma';
        await r.sourceInput(
          const TextEditingValue(
            text: typed,
            selection: TextSelection.collapsed(offset: typed.length),
          ),
        );
        await pumpFrames(tester);

        await r.releaseAll();
        expect(
          r.robot.sourceText,
          'Alpha\nBeta!!\n\n${wi146Line('mock.png')}\n\nGamma',
        );
      },
    );

    testWidgets(
      'in Source mode with no caret since the mode started the group goes at the end of the person section',
      (tester) async {
        const body = 'Alpha\nBeta\nGamma';
        final r = await wi146Pump(tester, body: body);
        await r.open();
        await r.robot.toggleSource();
        await pumpFrames(tester);
        expect(r.robot.sourceSurface, findsOneWidget);
        FocusManager.instance.primaryFocus?.unfocus();
        await pumpFrames(tester);

        await _wi146Attach(r, const [wi146MockPath]);
        expect(
          r.robot.sourceText,
          'Alpha\nBeta\nGamma\n\n${wi146Line('mock.png')}',
        );
      },
    );
  });

  group('anchors on and above an excerpt card in live preview (AC2, AC7)', () {
    const card = fixtureRangeToken;
    final mock = wi146Line('mock.png');

    testWidgets(
      'a caret on the empty last row above a card puts the group after the line above the card',
      (tester) async {
        const topic = 'Intro line\n$card\nOutro line';
        final r = await wi146Pump(tester, topicBody: topic);
        await r.open(fixtureTopicId);
        expect(segmentEditingAt(tester, 0).text, 'Intro line\n');
        await r.caretAfter('Intro line\n');
        expect(segmentEditingAt(tester, 0).selection.baseOffset, 11);

        await _wi146Attach(r, const [wi146MockPath]);
        expect(
          r.body,
          'Intro line\n\n$mock\n\n$card\nOutro line',
          reason: 'inserted above the card, not inside it',
        );
        expect(
          find.textContaining('Attached'),
          findsNothing,
          reason: 'no toast',
        );
      },
    );

    testWidgets(
      'a caret in the empty segment between two cards puts the group after the first card',
      (tester) async {
        const topic = 'Intro line\n$card\n$card\nOutro line';
        final r = await wi146Pump(tester, topicBody: topic);
        await r.open(fixtureTopicId);
        await r.caretAfter('', segment: 2);

        await _wi146Attach(r, const [wi146MockPath]);
        expect(r.body, 'Intro line\n$card\n\n$mock\n\n$card\nOutro line');
        expect(
          find.textContaining('Attached'),
          findsNothing,
          reason: 'no toast',
        );
      },
    );

    testWidgets('an anchor line on a card puts the group after that card', (
      tester,
    ) async {
      const topic = 'Intro line\n$card\nOutro line';
      final r = await wi146Pump(tester, topicBody: topic);
      await r.open(fixtureTopicId);
      await r.caretAfter('Outro line', segment: 2);

      await _wi146Attach(r, const [wi146MockPath], anchorLine: 1);
      expect(r.body, 'Intro line\n$card\n\n$mock\n\nOutro line');
      expect(find.textContaining('Attached'), findsNothing, reason: 'no toast');
    });

    testWidgets(
      'with no caret and a card ending the person section above the Note footer the group goes after the card',
      (tester) async {
        const footer = '$topicsMarker\n[[Zeta Game~about]]\n';
        const topic = 'Intro line\n$card\n$footer';
        final r = await wi146Pump(tester, topicBody: topic);
        await r.open(fixtureTopicId);
        expect(r.body, topic);

        await _wi146Attach(r, const [wi146MockPath]);
        expect(r.body, 'Intro line\n$card\n\n$mock\n$footer');
        expect(
          find.textContaining('Attached'),
          findsNothing,
          reason: 'no toast',
        );
      },
    );

    testWidgets(
      'a note whose first line is a card with the caret in its empty first segment puts the group after that card',
      (tester) async {
        const topic = '$card\nOutro line';
        final r = await wi146Pump(tester, topicBody: topic);
        await r.open(fixtureTopicId);
        await r.caretAfter('', segment: 0);

        await _wi146Attach(r, const [wi146MockPath]);
        expect(r.body, '$card\n\n$mock\n\nOutro line');
        expect(
          find.textContaining('Attached'),
          findsNothing,
          reason: 'no toast',
        );
      },
    );
  });

  group('the vault must take writes (R11)', () {
    testWidgets(
      'with canWrite false attachPaths attachBytes and attachFromPicker store nothing and open no picker',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.picker.fileLists.add([wi146MockPath]);
        r.h.read(wi146WritableProvider.notifier).state = false;
        await pumpFrames(tester);
        r.bodyChanges.clear();

        await r.controller.attachPaths(r.context, const [wi146MockPath]);
        await r.controller.attachBytes(
          r.context,
          Uint8List.fromList(const [1, 2, 3]),
          'Pasted image 2026-11-18 14.03.22.png',
        );
        await r.controller.attachFromPicker(r.context);
        await r.releaseAll();

        expect(r.attachments.addCalls, isEmpty);
        expect(r.attachments.addBytesCalls, isEmpty);
        expect(r.pickCalls, isEmpty, reason: 'no picker is opened');
        expect(r.body, wi146Example);
        expect(r.bodyChanges, isEmpty);
        expect(find.byType(SnackBar), findsNothing, reason: 'no toast');
      },
    );

    testWidgets('with canWrite true the same three entry points do attach', (
      tester,
    ) async {
      final r = await wi146Pump(tester, body: 'Alpha');
      await r.open();
      await r.caretAfter('Alpha');
      r.picker.fileLists.add([wi146SpecPath]);

      await r.controller.attachPaths(r.context, const [wi146MockPath]);
      await r.releaseAll();
      await r.controller.attachBytes(
        r.context,
        Uint8List.fromList(const [1, 2, 3]),
        'pasted.png',
      );
      await r.releaseAll();
      await r.controller.attachFromPicker(r.context);
      await r.releaseAll();

      expect(r.attachments.addCalls, hasLength(2));
      expect(r.attachments.addBytesCalls, hasLength(1));
      expect(r.pickCalls, hasLength(1));
    });
  });

  group('the vault switched while storing (R13)', () {
    testWidgets(
      'with the vault switched while storing nothing is inserted and the toast names the closed note',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.attachments.holding = true;

        _wi146Start(r, const [wi146MockPath]);
        await pumpFrames(tester);
        expect(r.attachments.pending, greaterThan(0), reason: 'storing');
        // Another vault opens while a note editor with the same session is
        // shown (a virtual Today note has one id in every vault, and the
        // workspace stays mounted): its editor takes inserts as the first.
        final session = r.h.read(attachEditorProvider)!.session;
        r.h.read(currentVaultProvider.notifier).state = const LocalVaultRef(
          '/vaults/Second Vault',
        );
        await pumpFrames(tester);
        final other = _Wi146SameSessionEditor(session);
        r.h.read(attachEditorProvider.notifier).state = other;

        r.bodyChanges.clear();
        await r.releaseAll();
        expect(other.inserts, isEmpty, reason: 'nothing is inserted');
        expect(r.bodyChanges, isEmpty);
        expect(
          find.text(
            'Attached 1 file, but Planning notes was closed; drop or pick '
            'them again to add them.',
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('an editor that cannot take the edit (R13)', () {
    Future<Wi146Harness> pumpRefusing(WidgetTester tester) async {
      final r = await wi146Pump(tester);
      await r.open();
      await r.caretAfter('Review the draft');
      final real = r.h.read(attachEditorProvider)!;
      r.h.read(attachEditorProvider.notifier).state = _Wi146RefusingEditor(
        real,
      );
      return r;
    }

    testWidgets(
      'an insert the open note cannot take shows the could not add toast for 2 files',
      (tester) async {
        final r = await pumpRefusing(tester);

        await _wi146Attach(r, const [wi146MockPath, wi146SpecPath]);
        expect(
          find.text(
            "Attached 2 files, but couldn't add them to Planning notes; "
            'drop or pick them again to add them.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('was closed'), findsNothing);
        expect(r.body, wi146Example);
        expect(r.attachments.addCalls, hasLength(2), reason: 'files stay');
      },
    );

    testWidgets(
      'an insert the open note cannot take shows the could not add toast for 1 file',
      (tester) async {
        final r = await pumpRefusing(tester);

        await _wi146Attach(r, const [wi146MockPath]);
        expect(
          find.text(
            "Attached 1 file, but couldn't add them to Planning notes; "
            'drop or pick them again to add them.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('was closed'), findsNothing);
      },
    );
  });

  group('the Attaching toast behind another toast (AC5)', () {
    testWidgets(
      'an Attaching toast that waited behind a failure toast is removed when it shows after its action ended',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.caretAfter('Review the draft');
        r.attachments.addResults.add(
          const AttachmentAddFailed(
            AttachmentAddFailureReason.tooLarge,
            _wi146BigMessageAscii,
          ),
        );
        await _wi146Attach(r, const [_wi146BigPath]);
        final failure = find.text(
          "Couldn't attach big.mov: $_wi146BigMessageAscii",
        );
        expect(failure, findsOneWidget, reason: 'the first toast is showing');

        r.attachments.holding = true;
        _wi146Start(r, const [wi146MockPath]);
        await pumpFrames(tester);
        expect(
          find.textContaining('Attaching'),
          findsNothing,
          reason: 'queued behind the failure toast',
        );
        await r.releaseAll();
        expect(failure, findsOneWidget, reason: 'still the first toast');
        expect(r.body, contains(wi146Line('mock.png')));

        // The failure toast goes after its 4 s; the queued one then shows
        // and is removed at once because its action ended.
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        await pumpFrames(tester);
        expect(failure, findsNothing);
        expect(find.textContaining('Attaching'), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
      },
    );
  });

  group('the pasted image name (AC6)', () {
    String nameAt(DateTime now) {
      final container = ProviderContainer(
        overrides: [clockProvider.overrideWithValue(FakeClock(now))],
      );
      addTearDown(container.dispose);
      return container.read(attachControllerProvider).pastedImageName();
    }

    test(
      'the pasted image name from a fake clock at 2026-11-18 14:03:22 local time is Pasted image 2026-11-18 14.03.22.png',
      () {
        expect(
          nameAt(DateTime(2026, 11, 18, 14, 3, 22)),
          'Pasted image 2026-11-18 14.03.22.png',
        );
      },
    );

    test('the pasted image name zero pads every field', () {
      expect(
        nameAt(DateTime(2026, 1, 2, 3, 4, 5)),
        'Pasted image 2026-01-02 03.04.05.png',
      );
    });

    test('the pasted image name follows the clock as it moves', () {
      final clock = FakeClock(DateTime(2026, 11, 18, 23, 59, 59));
      final container = ProviderContainer(
        overrides: [clockProvider.overrideWithValue(clock)],
      );
      addTearDown(container.dispose);
      final controller = container.read(attachControllerProvider);
      expect(
        controller.pastedImageName(),
        'Pasted image 2026-11-18 23.59.59.png',
      );
      clock.advance(const Duration(seconds: 1));
      expect(
        controller.pastedImageName(),
        'Pasted image 2026-11-19 00.00.00.png',
      );
    });

    test('the pasted image name uses local time for a UTC clock reading', () {
      final utc = DateTime.utc(2026, 11, 18, 14, 3, 22);
      final local = utc.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      final want =
          'Pasted image ${local.year}-${two(local.month)}-${two(local.day)} '
          '${two(local.hour)}.${two(local.minute)}.${two(local.second)}.png';
      final utcName = 'Pasted image 2026-11-18 14.03.22.png';
      if (local.timeZoneOffset == Duration.zero) {
        // A UTC host (the CI runners) can't tell local time from UTC.
        markTestSkipped('the host time zone is UTC: local equals UTC');
        return;
      }
      expect(want, isNot(utcName), reason: 'the reading differs by zone');
      expect(nameAt(utc), want);
      expect(nameAt(utc), isNot(utcName), reason: 'not the UTC fields');
    });
  });
}

/// An editor that shows the open note as [_real] does but cannot take any
/// edit, as a host whose fields have moved on can't.
class _Wi146RefusingEditor implements AttachEditor {
  _Wi146RefusingEditor(this._real);

  final AttachEditor _real;

  @override
  Object get session => _real.session;

  @override
  String get noteTitle => _real.noteTitle;

  @override
  int? get caretLine => _real.caretLine;

  @override
  bool insert(List<String> lines, int? anchorLine) => false;
}

/// An editor of another vault that shows a note under [session], as the
/// editor of the first vault did; it records the inserts it is given.
class _Wi146SameSessionEditor implements AttachEditor {
  _Wi146SameSessionEditor(this.session);

  @override
  final Object session;

  final List<List<String>> inserts = [];

  @override
  String get noteTitle => 'Planning notes';

  @override
  int? get caretLine => null;

  @override
  bool insert(List<String> lines, int? anchorLine) {
    inserts.add(lines);
    return true;
  }
}
