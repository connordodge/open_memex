// WI #14 (Spec #7 A2, Req 31 and 33, D17 to D19): the checkable
// `Read-only for agents` item in the note's ⋯ menu.
//
// Every test pumps the real `NoteEditor` through A1's frozen
// `pumpAgentEdits` seam (D16): the menu and the title icon get the note the
// editor reads from `editorNoteAsyncProvider` (D18), and the toggle goes
// through `noteEditsActionsProvider` into the `FakeAgentEditsNotesAccess`,
// which stores the flag in the `FakeVaultDb` so the re-read note carries it.
// The checked state is read from the item's semantics (a checkable item
// reports `isChecked`), never from a private widget.
import 'dart:async';
import 'dart:ui' show CheckedState;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/cli/note_edits_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/note_edits_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/widgets/agent_edits_keys.dart';
import 'package:open_memex_app/src/widgets/editor/note_menu.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../../support/agent_edits_fakes.dart';
import '../../support/app_harness.dart' show pumpFrames;
import '../../support/fake_vault_db.dart';
import '../../support/font_fetch_hold.dart';

const _wi14Plain = '01JWI14MENUPLAIN0000000014';
const _wi14Topic = '01JWI14MENUTOPIC0000000014';
const _wi14Daily = '01JWI14MENUDAILY0000000014';
const _wi14Guide = '01JWI14MENUGUIDE0000000014';
const _wi14Virtual = 'virtual-today:2026-10-03';

const _wi14Label = 'Read-only for agents';
const _wi14MenuButton = Key('note-menu-button');
const _wi14Menu = Key('note-menu');
const _wi14InlineError = Key('inline-error');

/// The test's own gate: `agentEditsAvailableProvider` follows it when a test
/// overrides the gate (both arms of D17 in one pump).
final _wi14Gate = StateProvider<bool>((_) => true);

/// A V8 vault with a plain note, a topic note, a daily note and the Vault
/// Guide; [flagged] notes are Agent read-only.
FakeVaultDb _wi14Vault({Set<String> flagged = const {}}) {
  final db = FakeVaultDb.v5()
    ..seedNote(
      id: _wi14Plain,
      title: 'Pricing notes',
      content: 'Pricing.',
      version: 5,
    )
    ..seedNote(
      id: _wi14Topic,
      title: 'Loop topic',
      content: 'Loops.',
      role: 'topic',
      version: 3,
    )
    ..seedNote(
      id: _wi14Daily,
      title: '2026-10-02',
      content: '- went for a walk',
      role: 'daily',
      version: 2,
    )
    ..seedNote(
      id: _wi14Guide,
      title: 'Vault Guide',
      content: 'How this vault works.',
      role: 'guide',
      version: 1,
    );
  for (final id in flagged) {
    db.setAgentReadOnlyForTest(id, true);
  }
  return db;
}

Future<AgentEditsHarness> _wi14Pump(
  WidgetTester tester, {
  required FakeVaultDb db,
  required String noteId,
  bool overrideGate = false,
  bool memexConfigured = true,
}) async {
  final h = await pumpAgentEdits(
    tester,
    NoteEditor(rightPanelOpen: false, onToggleRightPanel: () {}),
    db: db,
    memexConfigured: memexConfigured,
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

Future<void> _wi14OpenMenu(WidgetTester tester) async {
  expect(find.byKey(_wi14MenuButton), findsOneWidget);
  await tester.tap(find.byKey(_wi14MenuButton));
  await pumpFrames(tester);
  expect(find.byKey(_wi14Menu), findsOneWidget, reason: 'the menu is open');
}

/// Closes an open menu by tapping outside it.
Future<void> _wi14CloseMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(1190, 790));
  await pumpFrames(tester);
  expect(find.byKey(_wi14Menu), findsNothing);
}

/// Chooses the open menu's `Read-only for agents` item (one tap, no pump).
Future<void> _wi14Choose(WidgetTester tester) async {
  expect(_wi14Item, findsOneWidget, reason: 'the item is shown');
  await tester.tap(_wi14Item);
}

Future<void> _wi14Select(AgentEditsHarness h, String noteId) async {
  h.container.read(selectedNoteIdProvider.notifier).state = noteId;
}

Finder get _wi14Item => find.byKey(noteMenuAgentReadOnlyKey);

/// The checked state the item's semantics report: the state of any node in
/// the item's subtree (or the node it merges into) that has one. Fails when
/// the item reports none or two different ones.
CheckedState _wi14Checked(WidgetTester tester) {
  expect(_wi14Item, findsOneWidget, reason: 'the item is shown');
  final states = <CheckedState>{};
  final elements = find
      .descendant(
        of: _wi14Item,
        matching: find.byWidgetPredicate((_) => true),
        matchRoot: true,
      )
      .evaluate();
  for (final e in elements) {
    RenderObject? r = e.renderObject;
    var node = r?.debugSemantics;
    while (r != null && (node == null || node.isMergedIntoParent)) {
      r = r.parent;
      node = r?.debugSemantics;
    }
    if (node == null) continue;
    final state = node.getSemanticsData().flagsCollection.isChecked;
    if (state != CheckedState.none) states.add(state);
  }
  expect(
    states,
    hasLength(1),
    reason: 'the item reports exactly one checked state, got $states',
  );
  return states.single;
}

/// The bot-off title icon of the open note.
Finder get _wi14Icon => find.byKey(agentReadOnlyIconKey);

void main() {
  holdFontFetches();

  group('the item and its check (AC1)', () {
    testWidgets(
      'on a plain note with the gate open the menu shows Read-only for agents unchecked',
      (tester) async {
        await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        expect(_wi14Item, findsNothing, reason: 'only inside the open menu');

        await _wi14OpenMenu(tester);

        expect(_wi14Item, findsOneWidget);
        expect(
          find.descendant(of: find.byKey(_wi14Menu), matching: _wi14Item),
          findsOneWidget,
          reason: 'the item lives inside NoteMenu',
        );
        expect(
          find.descendant(of: _wi14Item, matching: find.text(_wi14Label)),
          findsOneWidget,
        );
        expect(
          find.ancestor(of: _wi14Item, matching: find.byType(MenuItemButton)),
          findsNothing,
          reason: 'D19: the Key goes on the MenuItemButton itself',
        );
        expect(tester.widget(_wi14Item), isA<MenuItemButton>());
        expect(_wi14Checked(tester), CheckedState.isFalse);
      },
    );

    testWidgets(
      'on a flagged plain note the menu shows Read-only for agents checked',
      (tester) async {
        await _wi14Pump(
          tester,
          db: _wi14Vault(flagged: {_wi14Plain}),
          noteId: _wi14Plain,
        );
        await _wi14OpenMenu(tester);

        expect(
          find.descendant(of: _wi14Item, matching: find.text(_wi14Label)),
          findsOneWidget,
        );
        expect(_wi14Checked(tester), CheckedState.isTrue);
      },
    );

    testWidgets(
      'on a topic note the item is unchecked when unflagged and checked when flagged',
      (tester) async {
        final db = _wi14Vault();
        final h = await _wi14Pump(tester, db: db, noteId: _wi14Topic);
        await _wi14OpenMenu(tester);
        expect(_wi14Checked(tester), CheckedState.isFalse);
        await _wi14CloseMenu(tester);

        // The CLI flags it elsewhere; the next vault read shows it.
        db.setAgentReadOnlyForTest(_wi14Topic, true);
        h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        await _wi14OpenMenu(tester);
        expect(_wi14Checked(tester), CheckedState.isTrue);
      },
    );

    testWidgets('the item is enabled on a plain note', (tester) async {
      await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
      await _wi14OpenMenu(tester);
      expect(tester.widget<MenuItemButton>(_wi14Item).onPressed, isNotNull);
    });
  });

  group('where the item is hidden (AC2)', () {
    testWidgets(
      'the item is shown on a plain note and not shown on a daily note',
      (tester) async {
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        await _wi14OpenMenu(tester);
        expect(_wi14Item, findsOneWidget, reason: 'control: a plain note');
        await _wi14CloseMenu(tester);

        await _wi14Select(h, _wi14Daily);
        await pumpFrames(tester);
        await _wi14OpenMenu(tester);

        expect(find.byKey(const Key('note-menu-open-graph')), findsOneWidget);
        expect(_wi14Item, findsNothing);
        expect(find.text(_wi14Label), findsNothing);
      },
    );

    testWidgets(
      'the item is shown on a topic note and not shown on the Vault Guide',
      (tester) async {
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Topic);
        await _wi14OpenMenu(tester);
        expect(_wi14Item, findsOneWidget, reason: 'control: a topic note');
        await _wi14CloseMenu(tester);

        await _wi14Select(h, _wi14Guide);
        await pumpFrames(tester);
        expect(find.byKey(const Key('guide-title')), findsOneWidget);
        await _wi14OpenMenu(tester);

        expect(_wi14Item, findsNothing);
        expect(find.text(_wi14Label), findsNothing);
      },
    );

    testWidgets(
      'the item is shown on a plain note and not shown on the unsaved virtual Today note',
      (tester) async {
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        await _wi14OpenMenu(tester);
        expect(_wi14Item, findsOneWidget, reason: 'control: a plain note');
        await _wi14CloseMenu(tester);

        await _wi14Select(h, _wi14Virtual);
        await pumpFrames(tester);
        expect(VirtualTodayTab.dateOf(_wi14Virtual), '2026-10-03');
        await _wi14OpenMenu(tester);

        expect(find.byKey(const Key('note-menu-delete')), findsOneWidget);
        expect(_wi14Item, findsNothing);
        expect(find.text(_wi14Label), findsNothing);
      },
    );

    testWidgets(
      'the item follows the gate: shown while it is open and not shown while it is false',
      (tester) async {
        final h = await _wi14Pump(
          tester,
          db: _wi14Vault(),
          noteId: _wi14Plain,
          overrideGate: true,
        );
        await _wi14OpenMenu(tester);
        expect(_wi14Item, findsOneWidget, reason: 'gate open');
        await _wi14CloseMenu(tester);

        h.container.read(_wi14Gate.notifier).state = false;
        await pumpFrames(tester);
        await _wi14OpenMenu(tester);
        expect(_wi14Item, findsNothing, reason: 'gate closed');
        expect(find.byKey(const Key('note-menu-delete')), findsOneWidget);
        await _wi14CloseMenu(tester);

        h.container.read(_wi14Gate.notifier).state = true;
        await pumpFrames(tester);
        await _wi14OpenMenu(tester);
        expect(_wi14Item, findsOneWidget, reason: 'gate open again');
      },
    );

    testWidgets(
      'on a V7 vault the item is not shown until the vault reaches V8',
      (tester) async {
        final db = agentEditsV7Vault()
          ..seedNote(id: _wi14Plain, title: 'Pricing notes', content: 'P.');
        final h = await _wi14Pump(tester, db: db, noteId: _wi14Plain);
        expect(h.read(agentEditsAvailableProvider), isFalse);
        await _wi14OpenMenu(tester);
        expect(_wi14Item, findsNothing, reason: 'V7: the gate is false');
        await _wi14CloseMenu(tester);

        db.migrateAgentEditsToV8();
        h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);
        expect(h.read(agentEditsAvailableProvider), isTrue);

        await _wi14OpenMenu(tester);
        expect(_wi14Item, findsOneWidget, reason: 'V8: the gate is open');
        expect(h.notes.setAgentReadOnlyCalls, isEmpty);
      },
    );
  });

  group('choosing the item (AC3)', () {
    testWidgets(
      'choosing the item on an unflagged note calls setAgentReadOnly with true exactly once',
      (tester) async {
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        await _wi14OpenMenu(tester);

        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.notes.setAgentReadOnlyCalls, [(noteId: _wi14Plain, on: true)]);
        expect(h.bumps, 1, reason: 'D18: one bump for one successful toggle');
        expect(h.db.agentReadOnlyForTest(_wi14Plain), isTrue);
        expect(find.byKey(_wi14Menu), findsNothing, reason: 'the menu closed');
      },
    );

    testWidgets(
      'choosing the item on a flagged note calls setAgentReadOnly with false exactly once',
      (tester) async {
        final h = await _wi14Pump(
          tester,
          db: _wi14Vault(flagged: {_wi14Topic}),
          noteId: _wi14Topic,
        );
        await _wi14OpenMenu(tester);

        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.notes.setAgentReadOnlyCalls, [
          (noteId: _wi14Topic, on: false),
        ]);
        expect(h.bumps, 1);
        expect(h.db.agentReadOnlyForTest(_wi14Topic), isFalse);
      },
    );

    testWidgets(
      'choosing the item twice in a row toggles on then off with one call each',
      (tester) async {
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        await _wi14OpenMenu(tester);
        await _wi14Choose(tester);
        await pumpFrames(tester);

        await _wi14OpenMenu(tester);
        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.notes.setAgentReadOnlyCalls, [
          (noteId: _wi14Plain, on: true),
          (noteId: _wi14Plain, on: false),
        ]);
        expect(h.bumps, 2);
        expect(h.db.agentReadOnlyForTest(_wi14Plain), isFalse);
      },
    );

    testWidgets('choosing the item toggles the open note and no other note', (
      tester,
    ) async {
      final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
      await _wi14Select(h, _wi14Topic);
      await pumpFrames(tester);
      await _wi14OpenMenu(tester);

      await _wi14Choose(tester);
      await pumpFrames(tester);

      expect(h.notes.setAgentReadOnlyCalls, [(noteId: _wi14Topic, on: true)]);
      expect(h.db.agentReadOnlyForTest(_wi14Plain), isFalse);
    });
  });

  group('busy guard (AC4)', () {
    testWidgets(
      'two presses in the same frame start one setAgentReadOnly call',
      (tester) async {
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        final hold = Completer<void>();
        h.notes.holdSetAgentReadOnly = hold;
        await _wi14OpenMenu(tester);

        // No pump between the presses: both land in the same frame.
        await tester.tap(_wi14Item, warnIfMissed: false);
        await tester.tap(_wi14Item, warnIfMissed: false);
        await tester.pump();
        await tester.pump();

        expect(h.notes.setAgentReadOnlyCalls, [(noteId: _wi14Plain, on: true)]);

        hold.complete();
        await pumpFrames(tester);
        expect(h.notes.setAgentReadOnlyCalls, hasLength(1));
        expect(h.bumps, 1);
        expect(h.db.agentReadOnlyForTest(_wi14Plain), isTrue);
      },
    );

    testWidgets(
      'holding Enter on the item starts one setAgentReadOnly call and key repeats start none',
      (tester) async {
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        final hold = Completer<void>();
        h.notes.holdSetAgentReadOnly = hold;
        await _wi14OpenMenu(tester);
        final label = find.descendant(
          of: _wi14Item,
          matching: find.text(_wi14Label),
        );
        expect(label, findsOneWidget, reason: 'the item is shown');
        Focus.of(tester.element(label)).requestFocus();
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(h.notes.setAgentReadOnlyCalls, [(noteId: _wi14Plain, on: true)]);

        hold.complete();
        await pumpFrames(tester);
        expect(h.notes.setAgentReadOnlyCalls, hasLength(1));
        expect(h.bumps, 1);
      },
    );
  });

  group('state after the write lands (AC5)', () {
    testWidgets(
      'a successful toggle shows the check and the title icon from the re-read note',
      (tester) async {
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        expect(_wi14Icon, findsNothing);
        await _wi14OpenMenu(tester);
        expect(_wi14Checked(tester), CheckedState.isFalse);

        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.bumps, 1);
        expect(
          _wi14Icon,
          findsOneWidget,
          reason: 'the re-read note is flagged',
        );
        await _wi14OpenMenu(tester);
        expect(_wi14Checked(tester), CheckedState.isTrue);
      },
    );

    testWidgets(
      'a successful clear removes the check and the title icon from the re-read note',
      (tester) async {
        final h = await _wi14Pump(
          tester,
          db: _wi14Vault(flagged: {_wi14Plain}),
          noteId: _wi14Plain,
        );
        expect(_wi14Icon, findsOneWidget);

        await _wi14OpenMenu(tester);
        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.bumps, 1);
        expect(_wi14Icon, findsNothing);
        await _wi14OpenMenu(tester);
        expect(_wi14Checked(tester), CheckedState.isFalse);
      },
    );

    testWidgets(
      'nothing changes before the write lands: no icon and no check while the call is held',
      (tester) async {
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        final hold = Completer<void>();
        h.notes.holdSetAgentReadOnly = hold;
        await _wi14OpenMenu(tester);

        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.notes.setAgentReadOnlyCalls, hasLength(1));
        expect(h.bumps, 0);
        expect(_wi14Icon, findsNothing, reason: 'no optimistic icon');
        await _wi14OpenMenu(tester);
        expect(
          _wi14Checked(tester),
          CheckedState.isFalse,
          reason: 'no optimistic check',
        );
        await _wi14CloseMenu(tester);

        hold.complete();
        await pumpFrames(tester);

        expect(h.bumps, 1);
        expect(_wi14Icon, findsOneWidget);
        await _wi14OpenMenu(tester);
        expect(_wi14Checked(tester), CheckedState.isTrue);
      },
    );

    testWidgets(
      'the check follows the stored flag even when the write reports success without storing',
      (tester) async {
        // A write that answers ok but changed nothing in the vault: the menu
        // shows what the re-read note says, not what was asked for.
        final db = _wi14Vault();
        final notes = _Wi14NoStoreNotes(db: db);
        final h = await pumpAgentEdits(
          tester,
          NoteEditor(rightPanelOpen: false, onToggleRightPanel: () {}),
          db: db,
          notes: notes,
          noteId: _wi14Plain,
          surfaceSize: const Size(1200, 800),
        );
        await pumpFrames(tester);
        await _wi14OpenMenu(tester);

        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(notes.setAgentReadOnlyCalls, hasLength(1));
        expect(h.bumps, 1);
        expect(_wi14Icon, findsNothing);
        await _wi14OpenMenu(tester);
        expect(_wi14Checked(tester), CheckedState.isFalse);
      },
    );
  });

  group('a failed toggle (AC6)', () {
    testWidgets(
      'a failed toggle keeps the old state, shows the CLI message inline and does not bump',
      (tester) async {
        const message =
            'read-only set failed: note not found: 01JWI14MENUPLAIN0000000014';
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        h.notes.setAgentReadOnlyError = MemexException(
          message,
          code: 'not_found',
        );
        expect(find.byKey(_wi14InlineError), findsNothing);
        await _wi14OpenMenu(tester);

        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.notes.setAgentReadOnlyCalls, [(noteId: _wi14Plain, on: true)]);
        expect(h.bumps, 0, reason: 'D18: no bump on failure');
        expect(h.db.agentReadOnlyForTest(_wi14Plain), isFalse);
        expect(find.byKey(_wi14InlineError), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(_wi14InlineError),
            matching: find.text(message),
          ),
          findsOneWidget,
        );
        expect(_wi14Icon, findsNothing);
        await _wi14OpenMenu(tester);
        expect(_wi14Checked(tester), CheckedState.isFalse);
      },
    );

    testWidgets(
      'a failed clear on a flagged note keeps it checked with its icon and shows the server message',
      (tester) async {
        const message = 'read-only clear failed: the vault server refused it';
        final h = await _wi14Pump(
          tester,
          db: _wi14Vault(flagged: {_wi14Topic}),
          noteId: _wi14Topic,
        );
        h.notes.setAgentReadOnlyError = MemexException(
          message,
          code: 'internal',
        );
        await _wi14OpenMenu(tester);

        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.notes.setAgentReadOnlyCalls, [
          (noteId: _wi14Topic, on: false),
        ]);
        expect(h.bumps, 0);
        expect(
          find.descendant(
            of: find.byKey(_wi14InlineError),
            matching: find.text(message),
          ),
          findsOneWidget,
        );
        expect(_wi14Icon, findsOneWidget);
        await _wi14OpenMenu(tester);
        expect(_wi14Checked(tester), CheckedState.isTrue);
      },
    );

    testWidgets(
      'the failed toggle error uses the note delete error slot for the open note',
      (tester) async {
        const message = 'read-only set failed: database is locked';
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        h.notes.setAgentReadOnlyError = MemexException(message);
        await _wi14OpenMenu(tester);
        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.read(noteDeleteErrorProvider), (
          noteId: _wi14Plain,
          message: message,
        ));

        // The slot belongs to the note: another note does not show it.
        await _wi14Select(h, _wi14Topic);
        await pumpFrames(tester);
        expect(find.byKey(_wi14InlineError), findsNothing);
      },
    );
  });

  group('a toggle that cannot reach a CLI (AC6, review r1)', () {
    testWidgets(
      'with no memex CLI the toggle makes no call and shows the CLI message inline',
      (tester) async {
        final h = await _wi14Pump(
          tester,
          db: _wi14Vault(),
          noteId: _wi14Plain,
          memexConfigured: false,
        );
        await _wi14OpenMenu(tester);

        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(tester.takeException(), isNull);
        expect(h.notes.setAgentReadOnlyCalls, isEmpty);
        expect(h.bumps, 0);
        expect(h.read(noteDeleteErrorProvider), (
          noteId: _wi14Plain,
          message: 'The memex CLI is not available.',
        ));
        expect(
          find.descendant(
            of: find.byKey(_wi14InlineError),
            matching: find.text('The memex CLI is not available.'),
          ),
          findsOneWidget,
        );
        expect(h.db.agentReadOnlyForTest(_wi14Plain), isFalse);
        expect(_wi14Icon, findsNothing);
        await _wi14OpenMenu(tester);
        expect(_wi14Checked(tester), CheckedState.isFalse);
      },
    );

    testWidgets(
      'a StateError from the write shows its message inline and does not escape',
      (tester) async {
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        h.notes.setAgentReadOnlyError = StateError('The memex CLI is gone.');
        await _wi14OpenMenu(tester);

        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(tester.takeException(), isNull);
        expect(h.notes.setAgentReadOnlyCalls, [(noteId: _wi14Plain, on: true)]);
        expect(h.bumps, 0);
        expect(h.read(noteDeleteErrorProvider), (
          noteId: _wi14Plain,
          message: 'The memex CLI is gone.',
        ));
        expect(
          find.descendant(
            of: find.byKey(_wi14InlineError),
            matching: find.text('The memex CLI is gone.'),
          ),
          findsOneWidget,
        );
        expect(h.db.agentReadOnlyForTest(_wi14Plain), isFalse);
        expect(_wi14Icon, findsNothing);
      },
    );

    testWidgets(
      'a CLI timeout shows its description inline and does not escape',
      (tester) async {
        const timeout = MemexCliTimeout(
          ['note', 'read-only'],
          Duration(seconds: 30),
        );
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        h.notes.setAgentReadOnlyError = timeout;
        await _wi14OpenMenu(tester);

        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(tester.takeException(), isNull);
        expect(h.notes.setAgentReadOnlyCalls, [(noteId: _wi14Plain, on: true)]);
        expect(h.bumps, 0);
        expect(h.read(noteDeleteErrorProvider), (
          noteId: _wi14Plain,
          message: timeout.toString(),
        ));
        expect(
          find.descendant(
            of: find.byKey(_wi14InlineError),
            matching: find.text(timeout.toString()),
          ),
          findsOneWidget,
        );
        expect(h.db.agentReadOnlyForTest(_wi14Plain), isFalse);
      },
    );

    testWidgets(
      'after a failed toggle with a non-MemexException the busy guard is released',
      (tester) async {
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        h.notes.setAgentReadOnlyError = StateError('The memex CLI is gone.');
        await _wi14OpenMenu(tester);
        await _wi14Choose(tester);
        await pumpFrames(tester);

        h.notes.setAgentReadOnlyError = null;
        await _wi14OpenMenu(tester);
        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.notes.setAgentReadOnlyCalls, hasLength(2));
        expect(h.bumps, 1);
        expect(h.db.agentReadOnlyForTest(_wi14Plain), isTrue);
        expect(h.read(noteDeleteErrorProvider), isNull);
      },
    );
  });

  group('the error slot and the guard (AC6, verify)', () {
    testWidgets(
      'a later successful toggle of the same note clears its earlier toggle error',
      (tester) async {
        const message = 'read-only set failed: database is locked';
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        h.notes.setAgentReadOnlyError = MemexException(message);
        await _wi14OpenMenu(tester);
        await _wi14Choose(tester);
        await pumpFrames(tester);
        expect(find.byKey(_wi14InlineError), findsOneWidget);

        h.notes.setAgentReadOnlyError = null;
        await _wi14OpenMenu(tester);
        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.notes.setAgentReadOnlyCalls, hasLength(2));
        expect(h.bumps, 1);
        expect(h.read(noteDeleteErrorProvider), isNull);
        expect(find.byKey(_wi14InlineError), findsNothing);
        expect(h.db.agentReadOnlyForTest(_wi14Plain), isTrue);
      },
    );

    testWidgets(
      'a successful toggle of another note leaves the earlier toggle error of the first note',
      (tester) async {
        const message = 'read-only set failed: database is locked';
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        h.notes.setAgentReadOnlyError = MemexException(message);
        await _wi14OpenMenu(tester);
        await _wi14Choose(tester);
        await pumpFrames(tester);
        expect(h.read(noteDeleteErrorProvider), (
          noteId: _wi14Plain,
          message: message,
        ));

        h.notes.setAgentReadOnlyError = null;
        await _wi14Select(h, _wi14Topic);
        await pumpFrames(tester);
        await _wi14OpenMenu(tester);
        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.notes.setAgentReadOnlyCalls.last, (
          noteId: _wi14Topic,
          on: true,
        ));
        expect(h.db.agentReadOnlyForTest(_wi14Topic), isTrue);
        expect(h.read(noteDeleteErrorProvider), (
          noteId: _wi14Plain,
          message: message,
        ));
      },
    );

    testWidgets(
      'an unreachable vault server shows the snackbar and sets no inline error',
      (tester) async {
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        h.notes.setAgentReadOnlyError = const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: false,
        );
        await _wi14OpenMenu(tester);

        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(h.notes.setAgentReadOnlyCalls, [(noteId: _wi14Plain, on: true)]);
        expect(find.text("couldn't reach nas. try again."), findsOneWidget);
        expect(h.read(noteDeleteErrorProvider), isNull);
        expect(find.byKey(_wi14InlineError), findsNothing);
        expect(h.bumps, 0);
        expect(h.db.agentReadOnlyForTest(_wi14Plain), isFalse);
        expect(_wi14Icon, findsNothing);
      },
    );

    testWidgets(
      'an unreachable vault server keeps the note own earlier toggle error',
      (tester) async {
        const message = 'read-only set failed: database is locked';
        final h = await _wi14Pump(tester, db: _wi14Vault(), noteId: _wi14Plain);
        h.notes.setAgentReadOnlyError = MemexException(message);
        await _wi14OpenMenu(tester);
        await _wi14Choose(tester);
        await pumpFrames(tester);

        h.notes.setAgentReadOnlyError = const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: true,
        );
        await _wi14OpenMenu(tester);
        await _wi14Choose(tester);
        await pumpFrames(tester);

        expect(
          find.text("couldn't confirm with nas — check before trying again"),
          findsOneWidget,
        );
        expect(h.read(noteDeleteErrorProvider), (
          noteId: _wi14Plain,
          message: message,
        ));
        expect(h.bumps, 0);
      },
    );
  });

  group('the leading icon (AC1, verify)', () {
    testWidgets(
      'the leading icon is the empty square at size 14 when unflagged and the checked square when flagged',
      (tester) async {
        final db = _wi14Vault();
        final h = await _wi14Pump(tester, db: db, noteId: _wi14Plain);
        await _wi14OpenMenu(tester);
        Finder inItem(IconData d) =>
            find.descendant(of: _wi14Item, matching: find.byIcon(d));
        expect(inItem(LucideIcons.square), findsOneWidget);
        expect(inItem(LucideIcons.squareCheck), findsNothing);
        expect(tester.widget<Icon>(inItem(LucideIcons.square)).size, 14);
        await _wi14CloseMenu(tester);

        db.setAgentReadOnlyForTest(_wi14Plain, true);
        h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);
        await _wi14OpenMenu(tester);

        expect(inItem(LucideIcons.squareCheck), findsOneWidget);
        expect(inItem(LucideIcons.square), findsNothing);
        expect(tester.widget<Icon>(inItem(LucideIcons.squareCheck)).size, 14);
      },
    );
  });
}

/// A notes domain whose `setAgentReadOnly` answers ok without storing.
class _Wi14NoStoreNotes extends FakeAgentEditsNotesAccess {
  _Wi14NoStoreNotes({required FakeVaultDb super.db});

  @override
  Future<AgentReadOnlyResult> setAgentReadOnly(String noteId, bool on) async {
    setAgentReadOnlyCalls.add((noteId: noteId, on: on));
    return AgentReadOnlyResult(
      vaultId: agentEditsVaultId,
      noteId: noteId,
      agentReadOnly: on,
    );
  }
}
