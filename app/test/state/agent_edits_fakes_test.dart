// WI #13 (Spec #7 A1, D16, D19): the frozen test seam A2 (#14) and A3 (#15)
// build on. `pumpAgentEdits` renders a widget over the agent-edit fakes with
// `holdFontFetches()` applied; `FakeAgentEditsNotesAccess` records each call
// and applies its settable errors and holds; the D19 Keys are declared once,
// with their frozen values, and no other lib file spells them.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/note_edits_state.dart';
import 'package:open_memex_app/src/state/today_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/agent_edits_keys.dart';
import 'package:path/path.dart' as p;

import '../support/agent_edits_fakes.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';

const _wi13Note = '01JAGENTEDITSFAKES00000013';

/// Shows the gate and the selected note flag as text.
class _Wi13Probe extends ConsumerWidget {
  const _Wi13Probe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(agentEditsAvailableProvider);
    final note = ref.watch(editorNoteAsyncProvider).valueOrNull?.value;
    return Column(
      children: [
        Text('available:$available', key: const Key('probe-available')),
        Text('flag:${note?.agentReadOnly}', key: const Key('probe-flag')),
      ],
    );
  }
}

String _wi13Text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

/// [future]'s value or the error it threw.
Future<Object?> _wi13Outcome(Future<Object?> future) async {
  try {
    return await future;
  } catch (e) {
    return e;
  }
}

void main() {
  holdFontFetches();

  testWidgets(
    'pumpAgentEdits renders a widget over the agent edit fakes with font fetches held',
    (tester) async {
      final db = FakeVaultDb.v5()
        ..seedNote(id: _wi13Note, title: 'Pricing notes', content: 'Pricing.');
      final h = await pumpAgentEdits(
        tester,
        const _Wi13Probe(),
        db: db,
        noteId: _wi13Note,
      );
      expect(HttpOverrides.current, isNotNull, reason: 'font fetches held');
      expect(
        h.read(currentVaultProvider),
        const LocalVaultRef(agentEditsVaultPath),
      );
      expect(h.read(vaultDbProvider), same(db));
      expect(h.read(memexCliProvider), same(h.cli));
      expect(h.read(vaultAccessProvider)!.notes, same(h.notes));
      expect(_wi13Text(tester, 'probe-available'), 'available:true');
      expect(_wi13Text(tester, 'probe-flag'), 'flag:false');

      await h.read(noteEditsActionsProvider).setAgentReadOnly(_wi13Note, true);
      await tester.pump();
      await tester.pump();
      expect(h.notes.setAgentReadOnlyCalls, [(noteId: _wi13Note, on: true)]);
      expect(h.bumps, 1);
      expect(_wi13Text(tester, 'probe-flag'), 'flag:true');
    },
  );

  test(
    'FakeAgentEditsNotesAccess records each call and applies its settable errors and holds',
    () async {
      final db = FakeVaultDb.v5()
        ..seedNote(
          id: _wi13Note,
          title: 'Pricing notes',
          content: 'Pricing.',
          version: 4,
        )
        ..seedNoteRevision(
          id: 'rev-1',
          noteId: _wi13Note,
          agentChangeId: 'chg-1',
          previousMd: 'Earlier pricing.',
          previousVersion: 3,
          newVersion: 4,
        );
      addTearDown(db.close);
      final notes = FakeAgentEditsNotesAccess(db: db);

      // setAgentReadOnly: stores the flag, held until released.
      final hold = Completer<void>();
      notes.holdSetAgentReadOnly = hold;
      final pending = notes.setAgentReadOnly(_wi13Note, true);
      await pumpEventQueue();
      expect(notes.setAgentReadOnlyCalls, [(noteId: _wi13Note, on: true)]);
      expect(db.agentReadOnlyForTest(_wi13Note), isFalse, reason: 'held');
      hold.complete();
      final out = await pending;
      expect(out.agentReadOnly, isTrue);
      expect(out.noteId, _wi13Note);
      expect(out.vaultId, agentEditsVaultId);
      expect(db.agentReadOnlyForTest(_wi13Note), isTrue);
      expect((await notes.getNote(_wi13Note))!.agentReadOnly, isTrue);

      // A set error is thrown after recording; nothing stored.
      notes.holdSetAgentReadOnly = null;
      notes.setAgentReadOnlyError = MemexException(
        'read-only clear failed: no',
        code: 'internal',
      );
      final e = await _wi13Outcome(notes.setAgentReadOnly(_wi13Note, false));
      expect((e as MemexException).code, 'internal');
      expect(notes.setAgentReadOnlyCalls, hasLength(2));
      expect(db.agentReadOnlyForTest(_wi13Note), isTrue);

      // noteRevisions: the SQLite read, a settable result, a settable error.
      expect(
        [for (final r in await notes.noteRevisions(_wi13Note)) r.id],
        ['rev-1'],
      );
      notes.noteRevisionsResult = const [];
      expect(await notes.noteRevisions(_wi13Note), isEmpty);
      notes.noteRevisionsError = StateError('offline');
      expect(
        await _wi13Outcome(notes.noteRevisions(_wi13Note)),
        isA<StateError>(),
      );
      expect(notes.noteRevisionsCalls, [_wi13Note, _wi13Note, _wi13Note]);

      // restoreNoteRevision: held, then the note takes the revision text.
      final restoreHold = Completer<void>();
      notes.holdRestoreNoteRevision = restoreHold;
      final restoring = notes.restoreNoteRevision(
        noteId: _wi13Note,
        revisionId: 'rev-1',
      );
      await pumpEventQueue();
      expect(notes.restoreNoteRevisionCalls, [
        (noteId: _wi13Note, revisionId: 'rev-1'),
      ]);
      expect(db.getNote(_wi13Note)!.contentMd, 'Pricing.', reason: 'held');
      restoreHold.complete();
      final restored = await restoring;
      expect(restored.version, 5);
      expect(restored.contentMd, 'Earlier pricing.');
      expect(db.getNote(_wi13Note)!.contentMd, 'Earlier pricing.');

      // An unknown revision is not_found; a restore error is thrown as set.
      notes.holdRestoreNoteRevision = null;
      final missing = await _wi13Outcome(
        notes.restoreNoteRevision(noteId: _wi13Note, revisionId: 'gone'),
      );
      expect((missing as MemexException).code, 'not_found');
      notes.restoreNoteRevisionError = StateError('no cli');
      expect(
        await _wi13Outcome(
          notes.restoreNoteRevision(noteId: _wi13Note, revisionId: 'rev-1'),
        ),
        isA<StateError>(),
      );
      expect(notes.restoreNoteRevisionCalls, hasLength(3));
    },
  );

  test('the D19 keys are declared once with their frozen values', () {
    expect(noteMenuAgentReadOnlyKey, const Key('note-menu-agent-read-only'));
    expect(agentReadOnlyIconKey, const Key('agent-read-only-icon'));
    expect(noteRestoreConfirmKey, const Key('note-restore-confirm'));
    expect(noteRestoreCancelKey, const Key('note-restore-cancel'));
    final id = ['01JCHANGE', '0013'].join();
    expect(noteRestoreKey(id), Key('note-restore-$id'));
    expect(noteRestoreKey('chg-a'), isNot(noteRestoreKey('chg-b')));

    // Declared once: no other lib file spells a D19 key string.
    const literals = [
      "'note-menu-agent-read-only'",
      "'agent-read-only-icon'",
      "'note-restore-",
      "'note-restore-confirm'",
      "'note-restore-cancel'",
    ];
    final keysFile = p.join('lib', 'src', 'widgets', 'agent_edits_keys.dart');
    final offenders = <String>[
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File && f.path.endsWith('.dart') && f.path != keysFile)
          for (final l in literals)
            if (f.readAsStringSync().contains(l)) '${f.path}: $l',
    ];
    expect(offenders, isEmpty);
    expect(File(keysFile).existsSync(), isTrue);
  });
}
