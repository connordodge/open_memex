// WI #78 (W2) verify mode: EditorController._createDaily reads the created
// daily note back through `VaultAccess.notes` (a new await). A failed or
// empty read-back must not leave the editor "saving" forever: per the WI and
// the method doc, on any failure other than `daily_note_exists` the text
// stays in the editor with the message, and the next edit tries again.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/today_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _today = '2026-10-03';

/// A notes domain whose first [failGets] `getNote` reads fail ([throws]) or
/// find nothing.
class _Wi78ReadBackNotes extends EditorNotesAccess {
  _Wi78ReadBackNotes({
    required super.vaultPath,
    super.db,
    super.cli,
    required this.throws,
  });

  final bool throws;
  int failGets = 1;

  @override
  Future<Note?> getNote(String id) async {
    if (failGets > 0) {
      failGets--;
      reads.add('getNote:$id');
      if (throws) throw MemexException('read failed: database is locked');
      return null;
    }
    return super.getNote(id);
  }
}

void main() {
  group('virtual Today read back (EditorController._createDaily)', () {
    for (final (name, throws) in [
      (
        'a failed virtual Today read back does not leave the editor saving and keeps the typed text',
        true,
      ),
      (
        'an empty virtual Today read back does not leave the editor saving and keeps the typed text',
        false,
      ),
    ]) {
      test(name, () async {
        final dir = await Directory.systemTemp.createTemp('om78_readback');
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()
          ..onAddDailyCreates(db)
          ..onUpdateWrites(db);
        final clock = FakeClock(DateTime(2026, 10, 3, 9));
        late _Wi78ReadBackNotes notes;
        final c = ProviderContainer(
          overrides: [
            currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
            vaultDbProvider.overrideWithValue(null),
            memexCliProvider.overrideWithValue(cli),
            clockProvider.overrideWithValue(clock),
            vaultAccessProvider.overrideWith((ref) {
              final path = ref.watch(currentVaultProvider).localPath;
              if (path == null) return null;
              return LocalVaultAccess(
                vaultPath: path,
                db: db,
                cli: cli,
                notes: notes = _Wi78ReadBackNotes(
                  vaultPath: path,
                  db: db,
                  cli: cli,
                  throws: throws,
                ),
              );
            }),
          ],
        );
        addTearDown(() async {
          final store = c.read(tabsProvider.notifier).store;
          c.dispose();
          await store.flush();
          db.close();
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });
        c.read(vaultAccessProvider);
        c.listen(tabsProvider, (_, _) {});
        await pumpEventQueue();
        final ctrl = c.read(editorControllerProvider.notifier);
        ctrl.loadNote(virtualTodayNote(_today));

        ctrl.onContentChanged('hi');
        clock.advance(saveDebounce);
        await pumpEventQueue();

        expect(notes.writes, ['addNote:$_today:daily']);
        expect(notes.reads, contains('getNote:$createdDailyId'));
        final state = c.read(editorControllerProvider);
        expect(state.contentMd, 'hi', reason: 'the typed text stays');
        expect(
          state.status,
          isNot(SaveStatus.saving),
          reason: 'nothing is in flight any more',
        );
        expect(state.status, SaveStatus.error);
        expect(state.errorMessage, isNotNull);

        ctrl.onContentChanged('hi there');
        clock.advance(saveDebounce);
        await pumpEventQueue();

        expect(
          notes.writes.where((w) => w.startsWith('addNote:')),
          hasLength(2),
          reason: 'the next edit tries again',
        );
      });
    }
  });
}
