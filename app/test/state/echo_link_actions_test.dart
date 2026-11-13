// WI #429 (391-A4): the real `EchoLinkActions` behind `echoLinkActionsProvider`
// (Spec #391 reqs 29, 31, 32; Interview Ledger L4, L7):
// - `fromOpen` (open topic or plain note): through the D19 helper, the edit
//   waiting on the save debounce is stored, then `memex add-link --from open
//   --to echo --kind references`, then the editor is rebased on the stored
//   note, so the typed text and the auto-added link both survive;
// - `footerChip` (open daily, topic echo): `memex footer add`, then a rebase
//   that keeps the pending editor text on top; the daily note's text is not
//   written;
// - `fromEcho` (open daily, plain echo): `memex add-link --from echo --to
//   open`; the open daily note is not written and the editor is untouched;
// - each success bumps `vaultRevisionProvider` exactly once, a failure bumps
//   nothing and propagates to the tab.
//
// A real EditorController over a LocalVaultAccess with a FakeVaultDb and the
// FakeMemexCli handlers in echo_link_cli_fakes.dart; time moves only through
// the FakeClock.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/echo_link_actions.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

import '../support/daily_seed.dart';
import '../support/echo_link_cli_fakes.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/footer_cli_fakes.dart';
import '../support/today_cli_fakes.dart';

const _wi429Topic = '01JLINKOPENTOPIC0000000429';
const _wi429Daily = '01JLINKOPENDAILY0000000429';
const _wi429PlainEcho = '01JLINKPLAINECHO0000000429';
const _wi429TopicEcho = '01JLINKTOPICECHO0000000429';

const _wi429TopicBody = 'Level design notes.';
const _wi429DailyBody = 'Slept well. Sketched the loot tables.';
const _wi429PlainBody = 'Loot tables should feel generous early.';
const _wi429Typed = ' More about pacing.';

/// Starting versions: different per note so a wrong id shows.
const _wi429TopicVersion = 3;
const _wi429DailyVersion = 5;
const _wi429PlainVersion = 8;

Echo _wi429Echo(String id, {String? role}) => Echo(
  noteId: id,
  noteTitle: id == _wi429PlainEcho ? 'Loot tables' : 'Combat',
  noteRole: role,
  passage: 'A passage of $id',
  startByte: int.parse('0'),
  noteUpdatedAt: int.parse('1759000000000'),
);

final _wi429PlainEchoValue = _wi429Echo(_wi429PlainEcho);
final _wi429TopicEchoValue = _wi429Echo(_wi429TopicEcho, role: 'topic');

class _Wi429Env {
  _Wi429Env(this.c, this.db, this.cli, this.clock, this.openId);

  final ProviderContainer c;
  final FakeVaultDb db;
  final FakeMemexCli cli;
  final FakeClock clock;
  final String openId;

  /// How many times `vaultRevisionProvider` changed since the env started.
  int bumps = 0;

  /// Every editor status since the env started.
  final List<SaveStatus> statuses = [];

  EditorController get editor => c.read(editorControllerProvider.notifier);
  EditorStateValue get state => c.read(editorControllerProvider);
  EchoLinkActions get actions => c.read(echoLinkActionsProvider);
  Note stored(String id) => db.getNote(id)!;

  /// The subcommands the CLI ran, in order.
  List<String> get subcommands => [for (final c in cli.calls) c.subcommand];

  Future<void> link(Echo echo, EchoLinkPlan plan) =>
      actions.link(openNoteId: openId, echo: echo, plan: plan);

  /// Types [suffix] at the end of the editor text and leaves the save
  /// debounce pending.
  void type(String suffix) =>
      editor.onContentChanged('${state.contentMd}$suffix');

  /// Lets the save debounce fire and the fake CLI answer.
  Future<void> drain() async {
    clock.advance(const Duration(seconds: 2));
    await pumpEventQueue();
  }
}

/// A vault with an open topic note, an open daily note, a plain echo and a
/// topic echo; [openId] is selected and loaded in the editor.
Future<_Wi429Env> _wi429Launch(
  String openId, {
  Completer<void>? Function()? addLinkGate,
  Completer<void>? Function()? addLinkAnswerGate,
}) async {
  final dir = Directory.systemTemp.createTempSync('om429_link');
  final db = FakeVaultDb.v5()
    ..seedNote(
      id: _wi429Topic,
      title: 'Level design',
      content: _wi429TopicBody,
      role: 'topic',
      version: _wi429TopicVersion,
    )
    ..seedDailyNote('2026-10-03', id: _wi429Daily, version: _wi429DailyVersion)
    ..seedNote(
      id: _wi429PlainEcho,
      title: 'Loot tables',
      content: _wi429PlainBody,
      version: _wi429PlainVersion,
    )
    ..seedTopicNote(_wi429TopicEcho, 'Combat');
  db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
    _wi429DailyBody,
    _wi429Daily,
  ]);
  final cli = FakeMemexCli()
    ..onUpdateWrites(db)
    ..onFooterAdd(db)
    ..onAddLinkWrites(db, gate: addLinkGate, afterWrite: addLinkAnswerGate);
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
  final env = _Wi429Env(c, db, cli, clock, openId);
  c.listen<int>(vaultRevisionProvider, (_, _) => env.bumps++);
  c.listen<EditorStateValue>(
    editorControllerProvider,
    (_, next) => env.statuses.add(next.status),
    fireImmediately: true,
  );
  c.read(selectedNoteIdProvider.notifier).state = openId;
  env.editor.loadNote(env.stored(openId));
  return env;
}

/// Stores [body] as [id]'s text (same version) and loads it in the editor.
void _wi429SetBody(_Wi429Env env, String id, String body) {
  env.db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [body, id]);
  env.editor.loadNote(env.stored(id));
}

/// How many `## Auto-added links` headings [text] holds.
int _wi429Sections(String text) =>
    '\n$text'.split('\n## Auto-added links\n').length - 1;

/// [future]'s value or the error it threw.
Future<Object?> _wi429Outcome(Future<Object?> future) async {
  try {
    await future;
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  group('fromOpen', () {
    test(
      'fromOpen saves the pending edit before addLink and the editor holds the stored link and the typed text',
      () async {
        final env = await _wi429Launch(_wi429Topic);
        env.type(_wi429Typed);
        expect(env.cli.callsFor('update'), isEmpty, reason: 'still pending');

        await env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen);

        expect(env.subcommands, ['update', 'add-link']);
        final update = env.cli.callsFor('update').single;
        expect(update.flag('note-id'), _wi429Topic);
        expect(update.stdinBody, '$_wi429TopicBody$_wi429Typed');
        final link = env.cli.callsFor('add-link').single;
        expect(link.flag('from'), _wi429Topic);
        expect(link.flag('to'), _wi429PlainEcho);
        expect(link.flag('kind'), 'references');

        final expected = wi429WithAutoAddedLink(
          '$_wi429TopicBody$_wi429Typed',
          'Loot tables',
        );
        final stored = env.stored(_wi429Topic);
        expect(stored.contentMd, expected, reason: 'typed text and link');
        expect(stored.version, _wi429TopicVersion + 2);
        expect(env.state.contentMd, expected);
        expect(env.state.lastSavedVersion, _wi429TopicVersion + 2);
        expect(env.state.status, SaveStatus.clean);

        await env.drain();
        expect(
          env.cli.callsFor('update'),
          hasLength(1),
          reason: 'no later save drops the auto-added link',
        );
        expect(env.stored(_wi429Topic).contentMd, expected);
        expect(env.statuses, isNot(contains(SaveStatus.conflict)));
      },
    );

    test(
      'fromOpen with no pending edit calls addLink once and the editor takes the stored link',
      () async {
        final env = await _wi429Launch(_wi429Topic);

        await env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen);

        expect(env.subcommands, ['add-link']);
        final expected = wi429WithAutoAddedLink(_wi429TopicBody, 'Loot tables');
        expect(env.state.contentMd, expected);
        expect(env.state.lastSavedVersion, _wi429TopicVersion + 1);
        expect(env.state.status, SaveStatus.clean);
      },
    );

    test(
      'fromOpen with a failed flush calls no addLink and fails with the save-first message',
      () async {
        final env = await _wi429Launch(_wi429Topic);
        env.cli.on(
          'update',
          (_) => FakeMemexCli.error('internal', 'disk is full'),
        );
        env.type(_wi429Typed);

        final outcome = await _wi429Outcome(
          env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen),
        );

        expect(outcome, isNotNull, reason: 'the link fails');
        // The echoes tab shows `failure.toString()` in the row.
        expect(outcome.toString(), 'Could not save your changes first.');
        expect(env.cli.callsFor('add-link'), isEmpty);
        expect(env.stored(_wi429Topic).contentMd, _wi429TopicBody);
        expect(env.stored(_wi429Topic).version, _wi429TopicVersion);
        expect(env.state.contentMd, '$_wi429TopicBody$_wi429Typed');
        expect(env.bumps, 0, reason: 'a failed link bumps nothing');
      },
    );

    test(
      'fromOpen keeps text typed while addLink runs and saves it on the linked version with no conflict',
      () async {
        final gate = Completer<void>();
        final env = await _wi429Launch(_wi429Topic, addLinkGate: () => gate);
        env.type(_wi429Typed);

        final linking = env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen);
        await pumpEventQueue();
        expect(env.cli.callsFor('add-link'), hasLength(1), reason: 'held');
        env.type(' And loot.');
        gate.complete();
        await linking;

        // D54: the newer text wins and the link is carried into it.
        final later = wi429WithAutoAddedLink(
          '$_wi429TopicBody$_wi429Typed And loot.',
          'Loot tables',
        );
        expect(
          env.state.contentMd,
          later,
          reason: 'newer editor text and the link',
        );
        expect(env.state.lastSavedVersion, _wi429TopicVersion + 2);
        expect(env.state.status, SaveStatus.dirty);

        await env.drain();
        final updates = env.cli.callsFor('update');
        expect(updates, hasLength(2));
        expect(updates.last.stdinBody, later);
        expect(
          updates.last.flag('expected-version'),
          '${_wi429TopicVersion + 2}',
        );
        expect(env.state.status, SaveStatus.clean);
        expect(env.stored(_wi429Topic).contentMd, later);
        expect(
          env.statuses,
          isNot(contains(SaveStatus.conflict)),
          reason: 'no conflict banner',
        );
      },
    );

    test(
      'fromOpen keeps text typed at the very end of a body that ends in its auto-added links section and adds the link after it',
      () async {
        final gate = Completer<void>();
        final env = await _wi429Launch(_wi429Topic, addLinkGate: () => gate);
        final linked = wi429WithAutoAddedLink(_wi429TopicBody, 'Combat');
        _wi429SetBody(env, _wi429Topic, linked);

        final linking = env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen);
        await pumpEventQueue();
        expect(env.cli.callsFor('add-link'), hasLength(1), reason: 'held');
        env.type('Trailing thought.');
        gate.complete();
        await linking;

        final expected = '${linked}Trailing thought.\n[[Loot tables]]\n';
        expect(env.state.contentMd, expected);
        expect(env.state.status, SaveStatus.dirty);

        await env.drain();
        expect(env.cli.callsFor('update').last.stdinBody, expected);
        expect(env.stored(_wi429Topic).contentMd, expected);
        expect(_wi429Sections(expected), 1);
        expect(env.state.status, SaveStatus.clean);
        expect(env.statuses, isNot(contains(SaveStatus.conflict)));
      },
    );

    test(
      'fromOpen merges the link into an auto-added links section edited while addLink runs and keeps exactly one section',
      () async {
        final gate = Completer<void>();
        final env = await _wi429Launch(_wi429Topic, addLinkGate: () => gate);
        final linked = wi429WithAutoAddedLink(_wi429TopicBody, 'Combat');
        _wi429SetBody(env, _wi429Topic, linked);

        final linking = env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen);
        await pumpEventQueue();
        env.editor.onContentChanged(
          '${linked.replaceFirst('[[Combat]]', '[[Combat|fights]]')}'
          '[[Boss rush]]\n',
        );
        gate.complete();
        await linking;

        final edited = wi429WithAutoAddedLink(_wi429TopicBody, 'Combat|fights');
        final merged = '$edited[[Boss rush]]\n[[Loot tables]]\n';
        expect(
          env.state.contentMd,
          merged,
          reason: 'the edits kept, the link added, no second section',
        );
        expect(
          env.state.contentMd,
          isNot(contains('[[Combat]]')),
          reason: 'a line edited away while the link was written stays away',
        );
        expect(_wi429Sections(env.state.contentMd), 1);

        await env.drain();
        expect(env.stored(_wi429Topic).contentMd, merged);
        expect(env.state.status, SaveStatus.clean);
      },
    );
  });

  group('fromOpen with saves in flight and typing during the link', () {
    test(
      'fromOpen waits for an autosave in flight and then links on what it stored instead of failing',
      () async {
        final gate = Completer<void>();
        final env = await _wi429Launch(_wi429Topic);
        final slow = FakeMemexCli()..onUpdateWrites(env.db);
        env.cli.on('update', (call) async {
          if (env.cli.callsFor('update').length == 1) await gate.future;
          return slow.run(call.args, stdinBody: call.stdinBody);
        });
        env.type(_wi429Typed);
        env.clock.advance(const Duration(milliseconds: 600));
        await pumpEventQueue();
        expect(env.cli.callsFor('update'), hasLength(1), reason: 'in flight');
        env.type(' And loot.');

        final linking = _wi429Outcome(
          env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen),
        );
        await pumpEventQueue();
        expect(
          env.cli.callsFor('add-link'),
          isEmpty,
          reason: 'waits for the save in flight',
        );
        gate.complete();
        final outcome = await linking;

        expect(outcome, isNull, reason: 'a save in flight is no failed flush');
        expect(env.subcommands, ['update', 'update', 'add-link']);
        final expected = wi429WithAutoAddedLink(
          '$_wi429TopicBody$_wi429Typed And loot.',
          'Loot tables',
        );
        expect(env.stored(_wi429Topic).contentMd, expected);
        expect(env.state.contentMd, expected);
        expect(env.state.status, SaveStatus.clean);
        expect(env.bumps, greaterThanOrEqualTo(1));
        await env.drain();
        expect(env.cli.callsFor('update'), hasLength(2), reason: 'no resave');
        expect(env.statuses, isNot(contains(SaveStatus.conflict)));
      },
    );

    test(
      'fromOpen with a save still in flight and nothing newer waits for it and links',
      () async {
        final gate = Completer<void>();
        final env = await _wi429Launch(_wi429Topic);
        final slow = FakeMemexCli()..onUpdateWrites(env.db);
        env.cli.on('update', (call) async {
          await gate.future;
          return slow.run(call.args, stdinBody: call.stdinBody);
        });
        env.type(_wi429Typed);
        env.clock.advance(const Duration(milliseconds: 600));
        await pumpEventQueue();
        expect(env.state.status, SaveStatus.saving);

        final linking = _wi429Outcome(
          env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen),
        );
        await pumpEventQueue();
        gate.complete();

        expect(await linking, isNull);
        expect(env.subcommands, ['update', 'add-link']);
        expect(
          env.state.contentMd,
          wi429WithAutoAddedLink('$_wi429TopicBody$_wi429Typed', 'Loot tables'),
        );
      },
    );

    test(
      'fromOpen with a failed save still fails with the save-first message at once and does not wait',
      () async {
        final env = await _wi429Launch(_wi429Topic);
        // TEST-CHANGE (#16, Req 34a): the server changed the line the
        // person typed on (an overlap), so the conflict is not merged.
        env.cli.on('update', (call) {
          env.db.db.execute(
            'UPDATE notes SET content_md = ?, version = version + 1 WHERE id = ?',
            ['Changed on the server.', call.flag('note-id')],
          );
          return FakeMemexCli.error(
            'version_conflict',
            'note changed on the server',
          );
        });
        env.type(_wi429Typed);

        final outcome = await _wi429Outcome(
          env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen),
        );

        expect(outcome.toString(), 'Could not save your changes first.');
        expect(env.cli.callsFor('update'), hasLength(1));
        expect(env.cli.callsFor('add-link'), isEmpty);
        expect(env.bumps, 0);
      },
    );

    test(
      'fromOpen holds the autosave of text typed while addLink runs until the link is stored so it never saves on the old version and shows no conflict',
      () async {
        final answer = Completer<void>();
        final env = await _wi429Launch(
          _wi429Topic,
          addLinkAnswerGate: () => answer,
        );
        env.type(_wi429Typed);

        final linking = env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen);
        await pumpEventQueue();
        expect(env.cli.callsFor('add-link'), hasLength(1), reason: 'running');
        expect(
          env.stored(_wi429Topic).version,
          _wi429TopicVersion + 2,
          reason: 'the link is stored, the answer is still on its way',
        );
        env.type(' And loot.');
        env.clock.advance(const Duration(seconds: 2));
        await pumpEventQueue();

        expect(
          env.cli.callsFor('update'),
          hasLength(1),
          reason: 'only the flush saved: nothing beside the link',
        );
        expect(env.statuses, isNot(contains(SaveStatus.conflict)));
        answer.complete();
        await linking;

        final later = wi429WithAutoAddedLink(
          '$_wi429TopicBody$_wi429Typed And loot.',
          'Loot tables',
        );
        expect(env.state.contentMd, later);
        expect(env.state.status, SaveStatus.dirty);
        await env.drain();
        final updates = env.cli.callsFor('update');
        expect(updates, hasLength(2));
        expect(updates.last.stdinBody, later);
        expect(
          updates.last.flag('expected-version'),
          '${_wi429TopicVersion + 2}',
        );
        expect(env.stored(_wi429Topic).contentMd, later);
        expect(env.state.status, SaveStatus.clean);
        expect(env.statuses, isNot(contains(SaveStatus.conflict)));
        expect(env.bumps, 2, reason: 'the link, then the later text saved');
      },
    );
  });

  group('footerChip', () {
    test(
      'footerChip calls addFooterChip for the open daily note and keeps the pending edit on the new version',
      () async {
        final env = await _wi429Launch(_wi429Daily);
        env.type(' Typed later.');

        await env.link(_wi429TopicEchoValue, EchoLinkPlan.footerChip);

        expect(env.cli.callsFor('footer add'), hasLength(1));
        final footer = env.cli.callsFor('footer add').single;
        expect(footer.flag('daily-note-id'), _wi429Daily);
        expect(footer.flag('topic-note-id'), _wi429TopicEcho);
        expect(env.cli.callsFor('add-link'), isEmpty);
        expect(
          env.cli.callsFor('update'),
          isEmpty,
          reason: 'the daily note text is not written',
        );
        final stored = env.stored(_wi429Daily);
        expect(stored.contentMd, _wi429DailyBody);
        expect(stored.version, _wi429DailyVersion + 1);
        expect(env.state.contentMd, '$_wi429DailyBody Typed later.');
        expect(env.state.lastSavedVersion, _wi429DailyVersion + 1);
        expect(env.state.status, SaveStatus.dirty);

        await env.drain();
        final update = env.cli.callsFor('update').single;
        expect(update.flag('expected-version'), '${_wi429DailyVersion + 1}');
        expect(update.stdinBody, '$_wi429DailyBody Typed later.');
        expect(env.state.status, SaveStatus.clean);
        expect(env.statuses, isNot(contains(SaveStatus.conflict)));
      },
    );
  });

  group('fromEcho', () {
    test(
      'fromEcho calls addLink from the echo to the open daily note and leaves the daily note and editor unchanged',
      () async {
        final env = await _wi429Launch(_wi429Daily);
        env.type(' Typed later.');

        await env.link(_wi429PlainEchoValue, EchoLinkPlan.fromEcho);

        expect(env.cli.callsFor('add-link'), hasLength(1));
        final link = env.cli.callsFor('add-link').single;
        expect(link.flag('from'), _wi429PlainEcho);
        expect(link.flag('to'), _wi429Daily);
        expect(link.flag('kind'), 'references');
        expect(env.cli.callsFor('update'), isEmpty, reason: 'no flush');
        expect(env.cli.callsFor('footer add'), isEmpty);
        final daily = env.stored(_wi429Daily);
        expect(daily.contentMd, _wi429DailyBody);
        expect(daily.version, _wi429DailyVersion);
        expect(
          env.stored(_wi429PlainEcho).contentMd,
          wi429WithAutoAddedLink(_wi429PlainBody, '2026-10-03'),
          reason: 'the echoed note body takes the link',
        );
        expect(env.state.contentMd, '$_wi429DailyBody Typed later.');
        expect(env.state.lastSavedVersion, _wi429DailyVersion);
        expect(env.state.status, SaveStatus.dirty);
      },
    );
  });

  group('vault revision', () {
    for (final (name, openId, echo, plan) in [
      (
        'a successful fromOpen link bumps the vault revision exactly once',
        _wi429Topic,
        _wi429PlainEchoValue,
        EchoLinkPlan.fromOpen,
      ),
      (
        'a successful footerChip link bumps the vault revision exactly once',
        _wi429Daily,
        _wi429TopicEchoValue,
        EchoLinkPlan.footerChip,
      ),
      (
        'a successful fromEcho link bumps the vault revision exactly once',
        _wi429Daily,
        _wi429PlainEchoValue,
        EchoLinkPlan.fromEcho,
      ),
    ]) {
      test(name, () async {
        final env = await _wi429Launch(openId);
        final before = env.c.read(vaultRevisionProvider);

        await env.link(echo, plan);

        expect(env.cli.calls, isNotEmpty, reason: 'the link wrote');
        expect(env.bumps, 1);
        expect(env.c.read(vaultRevisionProvider), before + 1);
        await env.drain();
        expect(env.bumps, 1, reason: 'nothing bumps again later');
      });
    }

    test(
      'a successful fromOpen link with a pending edit to flush bumps the vault revision exactly once',
      () async {
        final env = await _wi429Launch(_wi429Topic);
        final before = env.c.read(vaultRevisionProvider);
        env.type(_wi429Typed);

        await env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen);

        expect(env.subcommands, ['update', 'add-link']);
        expect(
          env.bumps,
          1,
          reason: 'the saved edit and the link reach the revision as one bump',
        );
        expect(env.c.read(vaultRevisionProvider), before + 1);
        await env.drain();
        expect(env.bumps, 1);
      },
    );

    for (final (name, openId, echo, plan, subcommand) in [
      (
        'a failed fromOpen addLink bumps nothing and propagates its error',
        _wi429Topic,
        _wi429PlainEchoValue,
        EchoLinkPlan.fromOpen,
        'add-link',
      ),
      (
        'a failed footerChip addFooterChip bumps nothing and propagates its error',
        _wi429Daily,
        _wi429TopicEchoValue,
        EchoLinkPlan.footerChip,
        'footer add',
      ),
      (
        'a failed fromEcho addLink bumps nothing and propagates its error',
        _wi429Daily,
        _wi429PlainEchoValue,
        EchoLinkPlan.fromEcho,
        'add-link',
      ),
    ]) {
      test(name, () async {
        final env = await _wi429Launch(openId);
        env.cli.on(
          subcommand,
          (_) => FakeMemexCli.error('not_found', 'note not found'),
        );
        final before = env.c.read(vaultRevisionProvider);

        final outcome = await _wi429Outcome(env.link(echo, plan));

        expect(env.cli.callsFor(subcommand), hasLength(1));
        expect(outcome, isA<MemexException>());
        expect(
          (outcome! as MemexException).code,
          'not_found',
          reason: 'the tab re-reads the list on not_found',
        );
        expect(env.bumps, 0);
        expect(env.c.read(vaultRevisionProvider), before);
        expect(env.state.lastSavedVersion, env.stored(openId).version);
      });
    }
  });

  group('two links in flight on one open note', () {
    test(
      'two fromOpen links started together run one after the other and both links survive in the stored note and the editor',
      () async {
        final gates = [Completer<void>(), Completer<void>()];
        var next = 0;
        final env = await _wi429Launch(
          _wi429Topic,
          addLinkGate: () => next < gates.length ? gates[next++] : null,
        );
        env.type(_wi429Typed);

        final first = env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen);
        final second = env.link(_wi429TopicEchoValue, EchoLinkPlan.fromOpen);
        await pumpEventQueue();
        expect(
          env.cli.callsFor('add-link'),
          hasLength(1),
          reason: 'the second link waits for the first to finish',
        );

        gates[0].complete();
        await first;
        await pumpEventQueue();
        expect(env.cli.callsFor('add-link'), hasLength(2));
        gates[1].complete();
        await second;

        // One section holding both links, as add-link writes the second.
        final both = wi429InsertAutoAddedLink(
          wi429WithAutoAddedLink('$_wi429TopicBody$_wi429Typed', 'Loot tables'),
          'Combat',
        );
        expect(_wi429Sections(both), 1);
        expect(env.stored(_wi429Topic).contentMd, both);
        expect(env.state.contentMd, both, reason: 'the editor has both links');
        expect(env.state.lastSavedVersion, _wi429TopicVersion + 3);
        expect(env.state.status, SaveStatus.clean);
        expect(
          env.bumps,
          2,
          reason:
              'the first link and its flush save bump once, the second once',
        );

        await env.drain();
        expect(
          env.cli.callsFor('update'),
          hasLength(1),
          reason: 'no later save overwrites a link',
        );
        expect(env.stored(_wi429Topic).contentMd, both);
        expect(env.statuses, isNot(contains(SaveStatus.conflict)));
      },
    );

    test(
      'a queued second fromOpen link flushes text typed during the first link with the first link in it so both links and the text survive',
      () async {
        final gates = [Completer<void>(), Completer<void>()];
        var next = 0;
        final env = await _wi429Launch(
          _wi429Topic,
          addLinkGate: () => next < gates.length ? gates[next++] : null,
        );

        final first = env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen);
        final second = env.link(_wi429TopicEchoValue, EchoLinkPlan.fromOpen);
        await pumpEventQueue();
        expect(env.cli.callsFor('add-link'), hasLength(1));
        env.type(_wi429Typed);
        gates[0].complete();
        await first;

        final afterFirst = wi429WithAutoAddedLink(
          '$_wi429TopicBody$_wi429Typed',
          'Loot tables',
        );
        expect(env.state.contentMd, afterFirst, reason: 'A carried over');
        await pumpEventQueue();
        expect(env.cli.callsFor('add-link'), hasLength(2));
        final flush = env.cli.callsFor('update').single;
        expect(
          flush.stdinBody,
          afterFirst,
          reason: 'the second link flushes the first link with the text',
        );
        gates[1].complete();
        await second;

        final both = wi429InsertAutoAddedLink(afterFirst, 'Combat');
        expect(env.stored(_wi429Topic).contentMd, both);
        expect(env.state.contentMd, both);
        expect(_wi429Sections(both), 1);
        expect(env.state.status, SaveStatus.clean);

        await env.drain();
        expect(env.cli.callsFor('update'), hasLength(1));
        expect(env.stored(_wi429Topic).contentMd, both);
        expect(env.statuses, isNot(contains(SaveStatus.conflict)));
      },
    );

    test(
      'a fromOpen link that fails does not stop the link queued behind it',
      () async {
        final env = await _wi429Launch(_wi429Topic);
        var calls = 0;
        final inner = FakeMemexCli()..onAddLinkWrites(env.db);
        env.cli.on('add-link', (call) {
          calls++;
          if (calls == 1) return FakeMemexCli.error('internal', 'boom');
          return inner.run(call.args);
        });

        final first = _wi429Outcome(
          env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen),
        );
        final second = _wi429Outcome(
          env.link(_wi429TopicEchoValue, EchoLinkPlan.fromOpen),
        );

        expect(await first, isA<MemexException>());
        expect(await second, isNull);
        expect(env.bumps, 1, reason: 'only the second link wrote');
        expect(
          env.stored(_wi429Topic).contentMd,
          wi429WithAutoAddedLink(_wi429TopicBody, 'Combat'),
        );
        expect(env.state.contentMd, env.stored(_wi429Topic).contentMd);
      },
    );
  });

  group('guards', () {
    for (final (name, openId, echo, plan) in [
      (
        'fromOpen with an open note that no longer exists fails not_found before it flushes or writes anything',
        _wi429Topic,
        _wi429PlainEchoValue,
        EchoLinkPlan.fromOpen,
      ),
      (
        'footerChip with an open note that no longer exists fails not_found before it writes anything',
        _wi429Daily,
        _wi429TopicEchoValue,
        EchoLinkPlan.footerChip,
      ),
    ]) {
      test(name, () async {
        final env = await _wi429Launch(openId);
        env.type(_wi429Typed);
        env.db.db.execute('DELETE FROM notes WHERE id = ?', [openId]);

        final outcome = await _wi429Outcome(env.link(echo, plan));

        expect(outcome, isA<MemexException>());
        expect((outcome! as MemexException).code, 'not_found');
        expect(env.cli.calls, isEmpty, reason: 'no flush, no write');
        expect(env.bumps, 0);
      });
    }

    test(
      'the none plan throws ArgumentError and writes and bumps nothing',
      () async {
        final env = await _wi429Launch(_wi429Daily);

        final outcome = await _wi429Outcome(
          env.link(_wi429PlainEchoValue, EchoLinkPlan.none),
        );

        expect(outcome, isA<ArgumentError>());
        expect(env.cli.calls, isEmpty);
        expect(env.bumps, 0);
      },
    );

    test(
      'a link with no vault open fails with No vault is open and writes nothing',
      () async {
        final cli = FakeMemexCli();
        final c = ProviderContainer(
          overrides: [memexCliProvider.overrideWithValue(cli)],
        );
        addTearDown(c.dispose);
        var bumps = 0;
        c.listen<int>(vaultRevisionProvider, (_, _) => bumps++);

        final outcome = await _wi429Outcome(
          c
              .read(echoLinkActionsProvider)
              .link(
                openNoteId: _wi429Topic,
                echo: _wi429PlainEchoValue,
                plan: EchoLinkPlan.fromOpen,
              ),
        );

        expect(outcome, isA<MemexException>());
        expect(outcome.toString(), 'No vault is open.');
        expect(cli.calls, isEmpty);
        expect(bumps, 0);
      },
    );

    test(
      'a fromOpen link whose write succeeded still bumps the revision once when the stored note then cannot be read',
      () async {
        final env = await _wi429Launch(_wi429Topic);
        final inner = FakeMemexCli()..onAddLinkWrites(env.db);
        env.cli.on('add-link', (call) async {
          final result = await inner.run(call.args);
          env.db.db.execute('ALTER TABLE notes RENAME TO notes_gone');
          return result;
        });

        final outcome = await _wi429Outcome(
          env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen),
        );
        env.db.db.execute('ALTER TABLE notes_gone RENAME TO notes');

        expect(env.cli.callsFor('add-link'), hasLength(1));
        expect(
          outcome,
          isNull,
          reason: 'the link was written, so a failed read-back is no failure',
        );
        expect(env.bumps, 1, reason: 'the link itself was written');
        expect(
          env.state.lastSavedVersion,
          _wi429TopicVersion,
          reason: 'the editor stays on its old version',
        );
        expect(env.state.contentMd, _wi429TopicBody);
        expect(env.state.status, SaveStatus.clean);
      },
    );

    test(
      'a fromOpen link whose read-back fails after the write does not rethrow with a pending edit and the editor stays on the flushed version',
      () async {
        final env = await _wi429Launch(_wi429Topic);
        final inner = FakeMemexCli()..onAddLinkWrites(env.db);
        env.cli.on('add-link', (call) async {
          final result = await inner.run(call.args);
          env.db.db.execute('ALTER TABLE notes RENAME TO notes_gone');
          return result;
        });
        env.type(_wi429Typed);

        final outcome = await _wi429Outcome(
          env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen),
        );
        env.db.db.execute('ALTER TABLE notes_gone RENAME TO notes');

        expect(outcome, isNull);
        expect(
          env.bumps,
          1,
          reason: 'the saved edit and the written link, once',
        );
        expect(env.subcommands, ['update', 'add-link']);
        // The editor still holds the flushed version and text.
        expect(env.state.lastSavedVersion, _wi429TopicVersion + 1);
        expect(env.state.contentMd, '$_wi429TopicBody$_wi429Typed');
      },
    );

    test(
      'a fromOpen failure before the write still propagates when the flush saved something',
      () async {
        final env = await _wi429Launch(_wi429Topic);
        env.cli.on(
          'add-link',
          (_) => FakeMemexCli.error('internal', 'link failed'),
        );
        env.type(_wi429Typed);

        final outcome = await _wi429Outcome(
          env.link(_wi429PlainEchoValue, EchoLinkPlan.fromOpen),
        );

        expect(outcome, isA<MemexException>());
        expect((outcome! as MemexException).code, 'internal');
        expect(env.subcommands, ['update', 'add-link']);
        expect(env.bumps, 1, reason: 'only the saved edit; the link failed');
      },
    );
  });

  group('carryAutoAddedLinks (D54)', () {
    const heading = '## Auto-added links';
    const footer = '<!-- memex:topics -->\n#games\n';

    test('a write that added no auto-added link line keeps the typed text', () {
      expect(
        carryAutoAddedLinks(
          typed: 'Body. More.',
          flushed: 'Body.',
          stored: 'Body.',
        ),
        'Body. More.',
      );
      final linked = wi429WithAutoAddedLink('Body.', 'Combat');
      expect(
        carryAutoAddedLinks(
          typed: 'Body. More.',
          flushed: linked,
          stored: linked,
        ),
        'Body. More.',
        reason: 'the stored lines were all there when it flushed',
      );
    });

    test(
      'typed text without the section gets it above the Note footer where add-link puts it',
      () {
        expect(
          carryAutoAddedLinks(
            typed: 'Body. More.\n$footer',
            flushed: 'Body.\n$footer',
            stored: 'Body.\n\n$heading\n\n[[Loot tables]]\n$footer',
          ),
          'Body. More.\n\n$heading\n\n[[Loot tables]]\n$footer',
        );
      },
    );

    test(
      'a section that is only its heading gets a blank line then the link',
      () {
        final stored = wi429WithAutoAddedLink('Body.', 'Loot tables');
        expect(
          carryAutoAddedLinks(
            typed: 'Body.\n\n$heading',
            flushed: 'Body.',
            stored: stored,
          ),
          stored,
        );
        expect(
          carryAutoAddedLinks(
            typed: 'Body.\n\n$heading\n',
            flushed: 'Body.',
            stored: stored,
          ),
          stored,
        );
      },
    );

    test(
      'the link goes after the last line of the section and before the next heading',
      () {
        expect(
          carryAutoAddedLinks(
            typed: 'Body.\n\n$heading\n\n[[Combat]]\n\n## Later\nMore.\n',
            flushed: 'Body.\n\n$heading\n\n[[Combat]]\n',
            stored: 'Body.\n\n$heading\n\n[[Combat]]\n[[Loot tables]]\n',
          ),
          'Body.\n\n$heading\n\n[[Combat]]\n[[Loot tables]]\n\n## Later\nMore.\n',
        );
      },
    );

    test('a link line the typed section already has is not added again', () {
      final stored = wi429WithAutoAddedLink('Body.', 'Loot tables');
      final typed = wi429WithAutoAddedLink('Body. More.', 'Loot tables');
      expect(
        carryAutoAddedLinks(typed: typed, flushed: 'Body.', stored: stored),
        typed,
      );
    });

    for (final (name, next, nextStored, nextFlushed) in [
      (
        'carryAutoAddedLinks ends the section at a heading of depth 2 and leaves the lines under it alone',
        '## Later\nMore.\n',
        '## Later\nnew line\n',
        '## Later\nold line\n',
      ),
      (
        'carryAutoAddedLinks ends the section at a heading of depth 1 and leaves the lines under it alone',
        '# Title\nMore.\n',
        '# Title\nnew line\n',
        '# Title\nold line\n',
      ),
      (
        'carryAutoAddedLinks ends the section at a heading of depth 3 and leaves the lines under it alone',
        '### Sub\nMore.\n',
        '### Sub\nnew line\n',
        '### Sub\nold line\n',
      ),
    ]) {
      test(name, () {
        final result = carryAutoAddedLinks(
          typed: 'Body.\n\n$heading\n\n[[Combat]]\n\n$next',
          flushed: 'Body.\n\n$heading\n\n[[Combat]]\n\n$nextFlushed',
          stored:
              'Body.\n\n$heading\n\n[[Combat]]\n[[Loot tables]]\n\n$nextStored',
        );

        expect(
          result,
          'Body.\n\n$heading\n\n[[Combat]]\n[[Loot tables]]\n\n$next',
          reason: 'only the section line is carried, and into the section',
        );
      });
    }

    test(
      'carryAutoAddedLinks ignores surrounding whitespace when it compares link lines',
      () {
        // The write kept [[Combat]] (padded differently when it flushed), the
        // person deleted it from the typed text: it must not come back.
        expect(
          carryAutoAddedLinks(
            typed: 'Body.\n\n$heading\n\n[[Mine]]\n',
            flushed: 'Body.\n\n$heading\n\n  [[Combat]]\n',
            stored: 'Body.\n\n$heading\n\n[[Combat]]  \n[[Loot tables]]\n',
          ),
          'Body.\n\n$heading\n\n[[Mine]]\n[[Loot tables]]\n',
        );
        // The typed section already has the line, with padding: no duplicate.
        final typed = 'Body.\n\n$heading\n\n  [[Loot tables]]  \n';
        expect(
          carryAutoAddedLinks(
            typed: typed,
            flushed: 'Body.',
            stored: wi429WithAutoAddedLink('Body.', 'Loot tables'),
          ),
          typed,
        );
      },
    );

    test(
      'carryAutoAddedLinks does not add an indented stored link line that the typed section has without indentation',
      () {
        final typed = 'Body.\n\n$heading\n\n[[Loot tables]]\n';
        expect(
          carryAutoAddedLinks(
            typed: typed,
            flushed: 'Body.',
            stored: 'Body.\n\n$heading\n\n  [[Loot tables]]\n',
          ),
          typed,
        );
      },
    );

    test(
      'carryAutoAddedLinks keeps the indentation of a carried line and drops its trailing whitespace',
      () {
        expect(
          carryAutoAddedLinks(
            typed: 'Body. More.',
            flushed: 'Body.',
            stored: 'Body.\n\n$heading\n\n  [[Loot tables]]  \n',
          ),
          'Body. More.\n\n$heading\n\n  [[Loot tables]]\n',
        );
      },
    );

    test(
      'carryAutoAddedLinks finds a typed section heading that has trailing whitespace and starts no second section',
      () {
        final result = carryAutoAddedLinks(
          typed: 'Body.\n\n$heading  \n\n[[Combat]]\n',
          flushed: 'Body.\n\n$heading\n\n[[Combat]]\n',
          stored: 'Body.\n\n$heading\n\n[[Combat]]\n[[Loot tables]]\n',
        );

        expect(result, 'Body.\n\n$heading  \n\n[[Combat]]\n[[Loot tables]]\n');
        expect(_wi429Sections(result.replaceFirst('  \n', '\n')), 1);
      },
    );
  });
}
