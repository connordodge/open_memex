// WI #78 (W2) widget contracts the implementer documented but no AC test
// pinned (verify mode):
// - kind chip "More…": on the first open the picker waits for the first
//   read of the link kinds, which is empty when it fails or the vault
//   changed meanwhile; on a revision bump it keeps the previous kinds (AC4);
// - wikilink autocomplete: an open popover's matches refresh when a titles
//   read lands;
// - note delete: nothing happens when the host context is gone by the time
//   the person confirms.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/editor/note_menu.dart';
import 'package:open_memex_app/src/widgets/kind_chip.dart';

import '../support/app_harness.dart';
import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/note_cli_fakes.dart';
import '../support/segment_editing_finder.dart';

const _vaultA = '/tmp/om-78-contract-a';
const _vaultB = '/tmp/om-78-contract-b';
const _alphaId = '01J9ALPHA000000000000000078';
const _usedHeading = "kinds you've already used";

void _wi78SeedLink(FakeVaultDb db, String from, String kind, int at) {
  db.db.execute(
    'INSERT INTO links (id, from_note_id, to_note_id, link_text, link_kind, '
    'position, source) VALUES (?, ?, ?, ?, ?, ?, ?)',
    ['l-$from-$at', from, 'target-$at', 'target', kind, at, 'inline_body'],
  );
}

/// A V5 vault with one note and one link of the user-coined [kind].
FakeVaultDb _kindsVault(String kind) {
  final db = FakeVaultDb.v5()..seedNote(id: _alphaId, title: 'Alpha');
  _wi78SeedLink(db, _alphaId, kind, 0);
  addTearDown(db.close);
  return db;
}

/// A notes domain whose `distinctLinkKinds` read always fails (D21: extends
/// the local class).
class _Wi78FailingKinds extends LocalNotesAccess {
  _Wi78FailingKinds({required super.vaultPath, super.db});

  int calls = 0;

  @override
  Future<List<String>> distinctLinkKinds() async {
    calls++;
    throw MemexException('read failed: database is locked');
  }
}

/// Pumps a shown [KindChip] over `[[Alpha]]` with the vault [_vaultA] open
/// and [access] as `vaultAccessProvider`.
Future<ProviderContainer> _pumpChip(
  WidgetTester tester,
  Override access,
) async {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => const LocalVaultRef(_vaultA)),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(null),
      access,
    ],
  );
  addTearDown(c.dispose);
  final chip = KindChipController()..show(start: 0, end: 9);
  final text = TextEditingController(text: '[[Alpha]]');
  addTearDown(chip.dispose);
  addTearDown(text.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Stack(
            children: [
              KindChip(
                controller: chip,
                editorController: text,
                anchor: Offset.zero,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return c;
}

Finder get _picker => find.text('PICK A KIND');

Future<void> _tapMore(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('kind-chip-more')));
  await tester.pump();
}

void main() {
  group('kind chip More picker (kind_chip contract, AC4)', () {
    testWidgets(
      'the kind chip More picker waits for the first link kinds read and lists the coined kinds',
      (tester) async {
        final a = EditorVaultDoubles(notesDb: _kindsVault('a-only'))
          ..holdFromStart = true;
        await _pumpChip(tester, editorAccessOverride({_vaultA: a}));
        expect(a.notes.gate.waiting, greaterThan(0));

        await _tapMore(tester);
        expect(_picker, findsNothing, reason: 'waits for the first read');

        a.release();
        await tester.pump();
        await tester.pump();

        expect(_picker, findsOneWidget);
        expect(find.text('A-ONLY'), findsOneWidget);
      },
    );

    testWidgets(
      'the kind chip More picker opens with no coined kinds when the first read fails',
      (tester) async {
        final db = _kindsVault('a-only');
        late _Wi78FailingKinds notes;
        await _pumpChip(
          tester,
          vaultAccessProvider.overrideWith((ref) {
            final path = ref.watch(currentVaultProvider).localPath;
            if (path == null) return null;
            return LocalVaultAccess(
              vaultPath: path,
              db: db,
              notes: notes = _Wi78FailingKinds(vaultPath: path, db: db),
            );
          }),
        );

        await _tapMore(tester);
        await tester.pump();

        expect(notes.calls, greaterThan(0));
        expect(_picker, findsOneWidget);
        expect(find.text(_usedHeading), findsNothing);
        expect(find.text('A-ONLY'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the kind chip More picker opens with no coined kinds when the vault changes during the first read',
      (tester) async {
        final a = EditorVaultDoubles(notesDb: _kindsVault('a-only'))
          ..holdFromStart = true;
        final b = EditorVaultDoubles(notesDb: _kindsVault('b-only'))
          ..holdFromStart = true;
        final c = await _pumpChip(
          tester,
          editorAccessOverride({_vaultA: a, _vaultB: b}),
        );

        await _tapMore(tester);
        expect(_picker, findsNothing);
        c.read(currentVaultProvider.notifier).state = const LocalVaultRef(
          _vaultB,
        );
        await tester.pump();
        a.release();
        await tester.pump();
        b.release();
        await tester.pump();
        await tester.pump();

        expect(_picker, findsOneWidget);
        expect(find.text('A-ONLY'), findsNothing);
        expect(find.text('B-ONLY'), findsNothing);
        expect(find.text(_usedHeading), findsNothing);
      },
    );

    testWidgets(
      'on a revision bump the kind chip More picker keeps the previous kinds until the new read completes',
      (tester) async {
        final db = _kindsVault('a-only');
        final a = EditorVaultDoubles(notesDb: db);
        final c = await _pumpChip(tester, editorAccessOverride({_vaultA: a}));
        expect(a.notes.reads, contains('distinctLinkKinds'));

        a.hold();
        _wi78SeedLink(db, _alphaId, 'a-new', 1);
        c.read(vaultRevisionProvider.notifier).state++;
        await tester.pump();
        expect(a.notes.gate.waiting, greaterThan(0));

        await _tapMore(tester);

        expect(_picker, findsOneWidget, reason: 'no wait on a reload');
        expect(find.text('A-ONLY'), findsOneWidget);
        expect(find.text('A-NEW'), findsNothing);
        a.release();
        await tester.pump();
      },
    );
  });

  group('wikilink autocomplete titles (wikilink_autocomplete contract)', () {
    testWidgets(
      'an open wikilink popover refreshes its matches when a titles read lands',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedNote(
            id: _alphaId,
            title: 'Alpha',
            content: 'alpha body',
            version: 3,
          );
        addTearDown(db.close);
        final doubles = EditorVaultDoubles(notesDb: db, dailyDb: db);
        final h = await pumpWorkspace(
          tester,
          db: FakeVaultDb.v5(),
          overrides: [editorSingleVaultOverride(doubles)],
        );
        h.read(vaultAccessProvider);
        h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_alphaId));
        await pumpFrames(tester);
        await tester.tap(find.byKey(const Key('editor-source-toggle')));
        await pumpFrames(tester);
        final body = find.byKey(editorBodyKey);

        doubles.hold();
        db.seedNote(id: '01J9GAMMA000000000000000078', title: 'Gamma Note');
        h.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);
        await tester.enterText(body, 'alpha body [[Gam');
        await pumpFrames(tester);
        expect(doubles.notes.gate.waiting, greaterThan(0));
        expect(
          find.byKey(const Key('wikilink-popover-item-Gamma Note')),
          findsNothing,
          reason: 'the previous titles have no Gamma Note',
        );

        doubles.release();
        await pumpFrames(tester);

        expect(
          find.byKey(const Key('wikilink-popover-item-Gamma Note')),
          findsOneWidget,
        );
        h.clock.advance(const Duration(milliseconds: 600));
        await pumpFrames(tester);
      },
    );
  });

  group('note delete (note_menu contract)', () {
    testWidgets(
      'note delete does nothing when the host context is gone by the time the person confirms',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('om78_delete_host');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });
        final db = FakeVaultDb.v5()
          ..seedNote(id: _alphaId, title: 'Alpha', version: 3);
        addTearDown(db.close);
        final cli = FakeMemexCli()..onRm(db);
        final doubles = EditorVaultDoubles(notesDb: db, dailyDb: db, cli: cli);
        final c = ProviderContainer(
          overrides: [
            currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
            vaultDbProvider.overrideWithValue(db),
            memexCliProvider.overrideWithValue(cli),
            clockProvider.overrideWithValue(FakeClock()),
            editorSingleVaultOverride(doubles),
          ],
        );
        addTearDown(c.dispose);
        c.read(vaultAccessProvider);
        final before = c.read(vaultRevisionProvider);
        final showHost = ValueNotifier(true);
        addTearDown(showHost.dispose);
        late BuildContext hostContext;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: MaterialApp(
              theme: buildOmTheme(),
              home: Scaffold(
                body: ValueListenableBuilder<bool>(
                  valueListenable: showHost,
                  builder: (_, show, _) => show
                      ? Builder(
                          builder: (context) {
                            hostContext = context;
                            return const Text('host');
                          },
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        );
        final note = db.getNote(_alphaId)!;

        final deleting = confirmAndDeleteNote(hostContext, c, note);
        await tester.pump();
        expect(find.byKey(const Key('delete-note-dialog')), findsOneWidget);
        showHost.value = false;
        await tester.pump();
        expect(hostContext.mounted, isFalse);
        await tester.tap(find.byKey(const Key('delete-note-confirm')));
        await tester.pump();
        await deleting;
        await tester.pump();

        expect(doubles.notes.writes, isEmpty);
        expect(cli.callsFor('rm'), isEmpty);
        expect(db.getNote(_alphaId), isNotNull);
        expect(c.read(noteDeleteErrorProvider), isNull);
        expect(c.read(vaultRevisionProvider), before);
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpFrames(tester);
      },
    );
  });
}
