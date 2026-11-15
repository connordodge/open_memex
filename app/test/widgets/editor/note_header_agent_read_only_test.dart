// WI #14 (Spec #7 A2, Req 32, D17 to D19): the bot-off icon next to the
// title of an Agent read-only note. It has no gesture (the ⋯ menu item is
// the one control), one semantics leaf labelled `Read-only for agents`, the
// tooltip `Read-only for agents`, and the frozen Key `agent-read-only-icon`
// on its SizedBox inside the Tooltip.
//
// The editor journeys pump the real `NoteEditor` through A1's frozen
// `pumpAgentEdits` seam (D16), so the header gets the note the editor reads
// from `editorNoteAsyncProvider` (D18). The narrow-width test pumps
// `NoteHeader` alone at the 320 px editor's content width: the full editor
// toolbar is not part of the title row.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/note_edits_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/agent_edits_keys.dart';
import 'package:open_memex_app/src/widgets/editor/note_header.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../../support/agent_edits_fakes.dart';
import '../../support/app_harness.dart' show pumpFrames;
import '../../support/fake_vault_db.dart';
import '../../support/font_fetch_hold.dart';

const _wi14Flagged = '01JWI14HEADFLAGGED00000014';
const _wi14Plain = '01JWI14HEADPLAIN0000000014';
const _wi14Label = 'Read-only for agents';
const _wi14Title = Key('editor-title');
const _wi14Header = Key('note-header');
const _wi14Menu = Key('note-menu');

/// The test's own gate: `agentEditsAvailableProvider` follows it when a test
/// overrides the gate (both arms of D17 in one pump).
final _wi14Gate = StateProvider<bool>((_) => true);

/// A V8 vault with a flagged topic note and an unflagged plain note.
FakeVaultDb _wi14Vault() => FakeVaultDb.v5()
  ..seedNote(
    id: _wi14Flagged,
    title: 'Pricing notes',
    content: 'Pricing.',
    role: 'topic',
    version: 4,
  )
  ..seedNote(id: _wi14Plain, title: 'Loose note', content: 'Loose.', version: 2)
  ..setAgentReadOnlyForTest(_wi14Flagged, true);

Future<AgentEditsHarness> _wi14PumpEditor(
  WidgetTester tester, {
  required FakeVaultDb db,
  required String noteId,
  bool overrideGate = false,
}) async {
  final h = await pumpAgentEdits(
    tester,
    NoteEditor(rightPanelOpen: false, onToggleRightPanel: () {}),
    db: db,
    noteId: noteId,
    surfaceSize: const Size(1200, 800),
    overrides: [
      if (overrideGate)
        agentEditsAvailableProvider.overrideWith((ref) => ref.watch(_wi14Gate)),
    ],
  );
  await pumpFrames(tester);
  return h;
}

Finder get _wi14Icon => find.byKey(agentReadOnlyIconKey);

void _wi14Bump(AgentEditsHarness h) =>
    h.container.read(vaultRevisionProvider.notifier).state++;

void main() {
  holdFontFetches();

  group('the icon on a flagged note (AC7)', () {
    testWidgets(
      'a flagged note shows the bot-off icon next to its title with the tooltip Read-only for agents',
      (tester) async {
        await _wi14PumpEditor(tester, db: _wi14Vault(), noteId: _wi14Flagged);

        expect(_wi14Icon, findsOneWidget);
        expect(
          tester.widget(_wi14Icon),
          isA<SizedBox>(),
          reason: 'D19: the Key goes on the icon SizedBox',
        );
        expect(
          find.descendant(
            of: _wi14Icon,
            matching: find.byIcon(LucideIcons.botOff),
          ),
          findsOneWidget,
        );
        final tooltips = find.ancestor(
          of: _wi14Icon,
          matching: find.byType(Tooltip),
        );
        expect(
          tooltips,
          findsOneWidget,
          reason: 'D19: the SizedBox sits inside the Tooltip',
        );
        expect(tester.widget<Tooltip>(tooltips).message, _wi14Label);
        expect(find.byTooltip(_wi14Label), findsOneWidget);

        // Next to the title: inside the header, on the title row.
        expect(
          find.descendant(of: find.byKey(_wi14Header), matching: _wi14Icon),
          findsOneWidget,
        );
        expect(
          find.descendant(of: find.byKey(_wi14Title), matching: _wi14Icon),
          findsNothing,
          reason: 'beside the title field, not inside it',
        );
        final title = tester.getRect(find.byKey(_wi14Title));
        final icon = tester.getRect(_wi14Icon);
        expect(icon.center.dy, greaterThan(title.top));
        expect(icon.center.dy, lessThan(title.bottom));
        expect(
          icon.left >= title.right - 0.5 || icon.right <= title.left + 0.5,
          isTrue,
          reason: 'the icon $icon sits beside the title field $title',
        );
      },
    );

    testWidgets(
      'long pressing the icon shows the tooltip Read-only for agents',
      (tester) async {
        final h = await _wi14PumpEditor(
          tester,
          db: _wi14Vault(),
          noteId: _wi14Flagged,
        );
        expect(_wi14Icon, findsOneWidget);
        expect(find.text(_wi14Label), findsNothing);

        await tester.longPress(_wi14Icon);
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text(_wi14Label), findsOneWidget);
        expect(h.notes.setAgentReadOnlyCalls, isEmpty);
      },
    );

    testWidgets(
      'the icon appears when the flag is set elsewhere and the vault is read again',
      (tester) async {
        final db = _wi14Vault();
        final h = await _wi14PumpEditor(tester, db: db, noteId: _wi14Plain);
        expect(_wi14Icon, findsNothing);

        db.setAgentReadOnlyForTest(_wi14Plain, true);
        _wi14Bump(h);
        await pumpFrames(tester);

        expect(_wi14Icon, findsOneWidget);
      },
    );
  });

  group('where the icon is absent (AC8)', () {
    testWidgets(
      'the icon is shown on a flagged note and absent on an unflagged note',
      (tester) async {
        final h = await _wi14PumpEditor(
          tester,
          db: _wi14Vault(),
          noteId: _wi14Flagged,
        );
        expect(_wi14Icon, findsOneWidget, reason: 'control: flagged');

        h.container.read(selectedNoteIdProvider.notifier).state = _wi14Plain;
        await pumpFrames(tester);

        expect(find.byKey(_wi14Title), findsOneWidget);
        expect(_wi14Icon, findsNothing);
        expect(find.byTooltip(_wi14Label), findsNothing);
        expect(find.byIcon(LucideIcons.botOff), findsNothing);
      },
    );

    testWidgets('the icon goes away when the flag is cleared elsewhere', (
      tester,
    ) async {
      final db = _wi14Vault();
      final h = await _wi14PumpEditor(tester, db: db, noteId: _wi14Flagged);
      expect(_wi14Icon, findsOneWidget, reason: 'control: flagged');

      db.setAgentReadOnlyForTest(_wi14Flagged, false);
      _wi14Bump(h);
      await pumpFrames(tester);

      expect(_wi14Icon, findsNothing);
    });

    testWidgets(
      'the icon follows the gate: absent while it is false and shown while it is open',
      (tester) async {
        final h = await _wi14PumpEditor(
          tester,
          db: _wi14Vault(),
          noteId: _wi14Flagged,
          overrideGate: true,
        );
        expect(_wi14Icon, findsOneWidget, reason: 'gate open');

        h.container.read(_wi14Gate.notifier).state = false;
        await pumpFrames(tester);
        expect(_wi14Icon, findsNothing, reason: 'gate closed');
        expect(find.byTooltip(_wi14Label), findsNothing);
        expect(find.byKey(_wi14Title), findsOneWidget);

        h.container.read(_wi14Gate.notifier).state = true;
        await pumpFrames(tester);
        expect(_wi14Icon, findsOneWidget, reason: 'gate open again');
      },
    );
  });

  group('the icon has no action (AC9)', () {
    testWidgets('tapping the icon makes no call and opens no menu', (
      tester,
    ) async {
      final h = await _wi14PumpEditor(
        tester,
        db: _wi14Vault(),
        noteId: _wi14Flagged,
      );
      expect(_wi14Icon, findsOneWidget);

      await tester.tap(_wi14Icon);
      await pumpFrames(tester);
      await tester.tap(_wi14Icon);
      await pumpFrames(tester);

      expect(h.notes.setAgentReadOnlyCalls, isEmpty);
      expect(h.bumps, 0);
      expect(find.byKey(_wi14Menu), findsNothing);
      expect(h.db.agentReadOnlyForTest(_wi14Flagged), isTrue);
      expect(_wi14Icon, findsOneWidget, reason: 'still flagged, still shown');
    });

    testWidgets('the icon has no button or tap semantics', (tester) async {
      await _wi14PumpEditor(tester, db: _wi14Vault(), noteId: _wi14Flagged);
      expect(_wi14Icon, findsOneWidget);

      final data = tester.getSemantics(_wi14Icon).getSemanticsData();
      expect(data.flagsCollection.isButton, isFalse);
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      expect(
        find.ancestor(
          of: _wi14Icon,
          matching: find.byWidgetPredicate(
            (w) =>
                (w is GestureDetector && w.onTap != null) ||
                (w is InkWell && w.onTap != null),
          ),
        ),
        findsNothing,
        reason: 'no tap handler wraps the icon',
      );
    });
  });

  group('the icon semantics (AC10)', () {
    testWidgets(
      'the icon is one semantics leaf labelled Read-only for agents',
      (tester) async {
        await _wi14PumpEditor(tester, db: _wi14Vault(), noteId: _wi14Flagged);
        expect(_wi14Icon, findsOneWidget);

        final node = tester.getSemantics(_wi14Icon);
        expect(node.label, _wi14Label);
        expect(node.childrenCount, 0, reason: 'one leaf node');
        expect(
          find.bySemanticsLabel(_wi14Label),
          findsOneWidget,
          reason: 'the label is read once',
        );
      },
    );

    testWidgets(
      'the tooltip adds no second semantics announcement of Read-only for agents',
      (tester) async {
        await _wi14PumpEditor(tester, db: _wi14Vault(), noteId: _wi14Flagged);
        expect(_wi14Icon, findsOneWidget);

        // The leaf carries the label; the Tooltip's own semantics are off, so
        // no node anywhere in the tree reports the message as a tooltip.
        final tooltips = <String>[];
        void walk(SemanticsNode node) {
          final data = node.getSemanticsData();
          if (data.tooltip.isNotEmpty) tooltips.add(data.tooltip);
          node.visitChildren((c) {
            walk(c);
            return true;
          });
        }

        var root = tester.getSemantics(_wi14Icon);
        while (root.parent != null) {
          root = root.parent!;
        }
        walk(root);
        expect(
          tooltips.where((t) => t.contains(_wi14Label)),
          isEmpty,
          reason: 'D19: one leaf announces it, not the tooltip as well',
        );
      },
    );

    testWidgets(
      'the title field keeps its own semantics apart from the icon leaf',
      (tester) async {
        await _wi14PumpEditor(tester, db: _wi14Vault(), noteId: _wi14Flagged);
        expect(_wi14Icon, findsOneWidget);

        final icon = tester.getSemantics(_wi14Icon);
        final field = tester.getSemantics(
          find.descendant(
            of: find.byKey(_wi14Title),
            matching: find.byType(EditableText),
          ),
        );
        expect(field.id, isNot(icon.id));
        expect(field.label, isNot(contains(_wi14Label)));
      },
    );
  });

  group('narrow width and large text (AC11)', () {
    testWidgets(
      'at a 320 px editor and 1.5x text scale the title row with the icon has no overflow',
      (tester) async {
        // NoteEditor pads its body 28 px each side: a 320 px editor gives the
        // header 264 px.
        const width = 264.0;
        final db = _wi14Vault();
        final note = Note(
          id: _wi14Flagged,
          title: 'Pricing notes for the whole of next year',
          contentMd: 'Pricing.',
          frontmatter: '{"role":"topic"}',
          version: 4,
          createdAt: 1759500000000,
          updatedAt: 1759500000000,
          tags: const [],
          agentReadOnly: true,
        );
        final ctrl = TextEditingController(text: note.title);
        addTearDown(ctrl.dispose);
        await pumpAgentEdits(
          tester,
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: NoteHeader(
                note: note,
                titleCtrl: ctrl,
                onTitleChanged: (_) {},
              ),
            ),
          ),
          db: db,
          noteId: _wi14Flagged,
          textScale: 1.5,
          surfaceSize: const Size(400, 800),
        );
        await pumpFrames(tester);

        expect(tester.takeException(), isNull, reason: 'no overflow');
        expect(_wi14Icon, findsOneWidget);
        final header = tester.getRect(find.byKey(_wi14Header));
        final icon = tester.getRect(_wi14Icon);
        final title = tester.getRect(find.byKey(_wi14Title));
        expect(header.width, width);
        expect(icon.right, lessThanOrEqualTo(header.right + 0.5));
        expect(icon.left, greaterThanOrEqualTo(header.left - 0.5));
        expect(title.right, lessThanOrEqualTo(header.right + 0.5));
        expect(
          icon.overlaps(title.deflate(0.5)),
          isFalse,
          reason: 'the icon $icon and the title field $title do not overlap',
        );
        expect(icon.center.dy, greaterThan(title.top));
        expect(icon.center.dy, lessThan(title.bottom));
      },
    );
  });
}
