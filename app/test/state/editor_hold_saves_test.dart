// WI #429 (391-A4), fix round 4: `EditorController.holdSaves` /
// `releaseSaves`. While a hold is on, the save debounce sends nothing and a
// landed save leaves its `vaultRevisionProvider` bump to the caller of the
// last release; any flush still sends at once. With no hold the editor
// behaves as before. The echo link (flushThenWrite with holdSaves) relies on
// it so text typed while `add-link` runs is not saved on the version the
// link replaces.
//
// A real EditorController over a LocalVaultAccess with a FakeVaultDb and
// FakeMemexCli; time moves only through the FakeClock.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _wi429A = '01JHOLDSAVESNOTEA000000429';
const _wi429B = '01JHOLDSAVESNOTEB000000429';
const _wi429Body = 'Level design notes.';
const _wi429Start = 3;

class _Wi429Env {
  _Wi429Env(this.c, this.db, this.cli, this.clock);

  final ProviderContainer c;
  final FakeVaultDb db;
  final FakeMemexCli cli;
  final FakeClock clock;

  /// How many times `vaultRevisionProvider` changed since the env started.
  int bumps = 0;

  EditorController get editor => c.read(editorControllerProvider.notifier);
  EditorStateValue get state => c.read(editorControllerProvider);
  Note note(String id) => db.getNote(id)!;

  Future<void> past(Duration d) async {
    clock.advance(d);
    await pumpEventQueue();
  }
}

Future<_Wi429Env> _wi429Launch() async {
  final dir = Directory.systemTemp.createTempSync('om429_hold');
  final db = FakeVaultDb.v5()
    ..seedNote(
      id: _wi429A,
      title: 'Level design',
      content: _wi429Body,
      role: 'topic',
      version: _wi429Start,
    )
    ..seedNote(
      id: _wi429B,
      title: 'Loot tables',
      content: 'Loot.',
      version: _wi429Start,
    );
  final cli = FakeMemexCli()..onUpdateWrites(db);
  final clock = FakeClock();
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(clock),
    ],
  );
  addTearDown(() {
    c.dispose();
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final env = _Wi429Env(c, db, cli, clock);
  c.listen<int>(vaultRevisionProvider, (_, _) => env.bumps++);
  env.editor.loadNote(env.note(_wi429A));
  return env;
}

void main() {
  group('EditorController holdSaves and releaseSaves', () {
    test(
      'a save that comes due during a hold is not sent and goes through the debounce again on the last release',
      () async {
        final env = await _wi429Launch();
        env.editor.holdSaves();
        env.editor.onContentChanged('$_wi429Body typed');

        await env.past(const Duration(seconds: 2));
        expect(env.cli.callsFor('update'), isEmpty, reason: 'held');
        expect(env.state.status, SaveStatus.dirty);

        expect(env.editor.releaseSaves(), isFalse, reason: 'nothing landed');
        expect(env.cli.callsFor('update'), isEmpty, reason: 'rescheduled');
        await env.past(const Duration(milliseconds: 100));
        expect(
          env.cli.callsFor('update'),
          isEmpty,
          reason: 'the debounce restarted, it does not fire at once',
        );

        await env.past(const Duration(seconds: 2));
        final update = env.cli.callsFor('update').single;
        expect(update.stdinBody, '$_wi429Body typed');
        expect(update.flag('expected-version'), '$_wi429Start');
        expect(env.state.status, SaveStatus.clean);
      },
    );

    test(
      'flushPendingSaveAndWait during a hold sends the held save at once and the save does not bump the revision',
      () async {
        final env = await _wi429Launch();
        env.editor.holdSaves();
        env.editor.onContentChanged('$_wi429Body typed');
        await env.past(const Duration(seconds: 2));
        expect(env.cli.callsFor('update'), isEmpty);

        expect(await env.editor.flushPendingSaveAndWait(), isTrue);

        expect(env.cli.callsFor('update'), hasLength(1));
        expect(env.note(_wi429A).contentMd, '$_wi429Body typed');
        expect(env.bumps, 0, reason: 'the bump is held for the release');
        expect(env.editor.releaseSaves(), isTrue, reason: 'a save landed');
        expect(env.bumps, 0, reason: 'the caller of the release bumps');
        await env.past(const Duration(seconds: 2));
        expect(env.cli.callsFor('update'), hasLength(1), reason: 'no resave');
      },
    );

    test('flushPendingSave during a hold sends a save that was held', () async {
      final env = await _wi429Launch();
      env.editor.holdSaves();
      env.editor.onContentChanged('$_wi429Body typed');
      await env.past(const Duration(seconds: 2));
      expect(env.cli.callsFor('update'), isEmpty);

      env.editor.flushPendingSave();
      await pumpEventQueue();

      expect(env.cli.callsFor('update'), hasLength(1));
      expect(env.note(_wi429A).contentMd, '$_wi429Body typed');
      env.editor.releaseSaves();
    });

    test(
      'flushPendingSave during a hold sends a save still waiting on its debounce',
      () async {
        final env = await _wi429Launch();
        env.editor.holdSaves();
        env.editor.onContentChanged('$_wi429Body typed');
        expect(env.cli.callsFor('update'), isEmpty);

        env.editor.flushPendingSave();
        await pumpEventQueue();

        expect(env.cli.callsFor('update'), hasLength(1));
        env.editor.releaseSaves();
      },
    );

    test(
      'loading another note drops a held save so a later flush sends nothing',
      () async {
        final env = await _wi429Launch();
        env.editor.holdSaves();
        env.editor.onContentChanged('$_wi429Body typed');
        await env.past(const Duration(seconds: 2));

        env.editor.loadNote(env.note(_wi429B));
        env.editor.flushPendingSave();
        await pumpEventQueue();

        expect(
          env.cli.callsFor('update'),
          isEmpty,
          reason: 'the held save of the first note is gone',
        );
        expect(env.state.status, SaveStatus.clean);
        env.editor.releaseSaves();
        await env.past(const Duration(seconds: 2));
        expect(env.cli.callsFor('update'), isEmpty);
      },
    );

    test(
      'a nested hold keeps the landed save bump held until the last release',
      () async {
        final env = await _wi429Launch();
        env.editor.holdSaves();
        env.editor.holdSaves();
        env.editor.onContentChanged('$_wi429Body typed');
        expect(await env.editor.flushPendingSaveAndWait(), isTrue);
        expect(env.bumps, 0);

        expect(env.editor.releaseSaves(), isFalse, reason: 'one hold is left');
        env.editor.onContentChanged('$_wi429Body typed more');
        await env.past(const Duration(seconds: 2));
        expect(
          env.cli.callsFor('update'),
          hasLength(1),
          reason: 'still held by the second hold',
        );

        expect(env.editor.releaseSaves(), isTrue, reason: 'the save landed');
        expect(env.bumps, 0);
        await env.past(const Duration(seconds: 2));
        expect(env.cli.callsFor('update'), hasLength(2));
        expect(env.bumps, 1, reason: 'the later save is not held any more');
      },
    );

    test(
      'releaseSaves with no hold returns false and does not turn into a hold',
      () async {
        final env = await _wi429Launch();
        expect(env.editor.releaseSaves(), isFalse);
        env.editor.holdSaves();
        env.editor.onContentChanged('$_wi429Body typed');

        await env.past(const Duration(seconds: 2));

        expect(env.cli.callsFor('update'), isEmpty, reason: 'the hold holds');
        env.editor.releaseSaves();
      },
    );

    test(
      'releaseSaves returns false and leaves the editor alone when no save landed or came due',
      () async {
        final env = await _wi429Launch();
        env.editor.holdSaves();

        expect(env.editor.releaseSaves(), isFalse);

        await env.past(const Duration(seconds: 2));
        expect(env.cli.callsFor('update'), isEmpty);
        expect(env.bumps, 0);
        expect(env.state.status, SaveStatus.clean);
      },
    );

    test(
      'a debounce still waiting at the release fires once at its own time',
      () async {
        final env = await _wi429Launch();
        env.editor.holdSaves();
        env.editor.onContentChanged('$_wi429Body typed');
        expect(env.editor.releaseSaves(), isFalse);

        await env.past(const Duration(seconds: 2));

        expect(env.cli.callsFor('update'), hasLength(1));
        expect(env.bumps, 1);
      },
    );

    test(
      'with no hold a save comes due at the debounce and bumps the revision once as it lands',
      () async {
        final env = await _wi429Launch();
        env.editor.onContentChanged('$_wi429Body typed');
        expect(env.cli.callsFor('update'), isEmpty);

        await env.past(const Duration(seconds: 2));

        expect(env.cli.callsFor('update'), hasLength(1));
        expect(env.state.status, SaveStatus.clean);
        expect(env.bumps, 1);
      },
    );
  });
}
