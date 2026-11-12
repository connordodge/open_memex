// #424 (391-A0): the echoes seam's frozen contracts. The models parse V4's
// echo JSON and compare by value, `VaultAccess.echoes` is wired for local
// and hosted vaults, and `pumpEchoesTab` pumps the right panel's echoes tab
// over the echoes fakes. Stub-neutral tests live one file per filler
// (`echoes_seam_stubs_a1_test.dart`, `state/echoes_seam_stubs_a*_test.dart`).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/echo_link_actions.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/vault_access/hosted/topics.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/echoes_fakes.dart';
import '../support/echoes_pump.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_server.dart';
import '../support/font_fetch_hold.dart';

/// A daily echo as `memex echoes` prints it (Spec #391 req 14).
const _dailyEchoJson = '''
{
  "note_id": "01JECHODAILY0000000000000A",
  "note_title": "2026-09-05",
  "note_role": "daily",
  "day": "2026-09-05",
  "passage": "Walked the coast path and thought about levels.",
  "start_byte": 1207,
  "note_updated_at": 1757080800123
}
''';

/// A plain note's echo indexed before byte offsets: every nullable key null.
const _plainEchoJson = '''
{
  "note_id": "01JECHOPLAIN0000000000000B",
  "note_title": "Level Design",
  "note_role": null,
  "day": null,
  "passage": "Levels teach by showing.",
  "start_byte": null,
  "note_updated_at": 1756000000000
}
''';

Map<String, Object?> _decode(String json) =>
    (jsonDecode(json) as Map).cast<String, Object?>();

/// An echo built from run-time values, so the constructor and `==` really
/// run (a const instance is canonicalised and never compares by value).
Echo _echo({
  String noteId = 'n1',
  String noteTitle = 'Title',
  String? noteRole = 'topic',
  String? day = '2026-09-05',
  String passage = 'passage',
  int? startByte = 12,
  int noteUpdatedAt = 1000,
}) => Echo(
  noteId: noteId,
  noteTitle: noteTitle,
  noteRole: noteRole,
  day: day,
  passage: passage,
  startByte: startByte,
  noteUpdatedAt: noteUpdatedAt,
);

/// The echoes tab's eyebrow, `echoes · forgotten threads` (req 25), as
/// `Eyebrow` draws it (upper case).
final _eyebrow = find.text('echoes · forgotten threads'.toUpperCase());

/// Asserts [a] and [b] are equal with equal hash codes.
void _expectSame(Object a, Object b) {
  expect(identical(a, b), isFalse, reason: 'compare two instances');
  expect(a, equals(b));
  expect(a.hashCode, b.hashCode);
}

void main() {
  holdFontFetches();

  group('Echo.fromJson', () {
    test('Echo.fromJson parses every field of a V4 echo', () {
      final echo = Echo.fromJson(_decode(_dailyEchoJson));

      expect(echo.noteId, '01JECHODAILY0000000000000A');
      expect(echo.noteTitle, '2026-09-05');
      expect(echo.noteRole, 'daily');
      expect(echo.day, '2026-09-05');
      expect(echo.passage, 'Walked the coast path and thought about levels.');
      expect(echo.startByte, 1207);
      expect(echo.noteUpdatedAt, 1757080800123);
    });

    test('Echo.fromJson reads null note_role day and start_byte', () {
      final echo = Echo.fromJson(_decode(_plainEchoJson));

      expect(echo.noteId, '01JECHOPLAIN0000000000000B');
      expect(echo.noteTitle, 'Level Design');
      expect(echo.noteRole, isNull);
      expect(echo.day, isNull);
      expect(echo.passage, 'Levels teach by showing.');
      expect(echo.startByte, isNull);
      expect(echo.noteUpdatedAt, 1756000000000);
    });

    test('Echo.fromJson reads a topic echo', () {
      final json = _decode(_plainEchoJson)
        ..['note_role'] = 'topic'
        ..['start_byte'] = 0;
      final echo = Echo.fromJson(json);

      expect(echo.noteRole, 'topic');
      expect(echo.startByte, 0);
      expect(echo.day, isNull);
    });

    test('Echo.fromJson treats absent nullable keys as null', () {
      final json = _decode(_dailyEchoJson)
        ..remove('note_role')
        ..remove('day')
        ..remove('start_byte');
      final echo = Echo.fromJson(json);

      expect(echo.noteId, '01JECHODAILY0000000000000A');
      expect(echo.noteRole, isNull);
      expect(echo.day, isNull);
      expect(echo.startByte, isNull);
      expect(echo.noteUpdatedAt, 1757080800123);
    });

    test('Echo.fromJson equals the echo built from the same values', () {
      _expectSame(
        Echo.fromJson(_decode(_dailyEchoJson)),
        _echo(
          noteId: '01JECHODAILY0000000000000A',
          noteTitle: '2026-09-05',
          noteRole: 'daily',
          day: '2026-09-05',
          passage: 'Walked the coast path and thought about levels.',
          startByte: 1207,
          noteUpdatedAt: 1757080800123,
        ),
      );
    });

    for (final key in const [
      'note_id',
      'note_title',
      'passage',
      'note_updated_at',
    ]) {
      test('Echo.fromJson rejects a missing required key: $key', () {
        final json = _decode(_dailyEchoJson)..remove(key);
        expect(() => Echo.fromJson(json), throwsFormatException);
      });

      test('Echo.fromJson rejects a null required key: $key', () {
        final json = _decode(_dailyEchoJson)..[key] = null;
        expect(() => Echo.fromJson(json), throwsFormatException);
      });
    }

    for (final (key, value) in const [
      ('note_id', 7),
      ('note_title', false),
      ('note_role', 3),
      ('day', 20260905),
      ('passage', <String>['x']),
      ('start_byte', '1207'),
      ('start_byte', 12.5),
      ('note_updated_at', '1757080800123'),
    ]) {
      test('Echo.fromJson rejects a wrong-typed value: $key = $value', () {
        final json = _decode(_dailyEchoJson)..[key] = value;
        expect(() => Echo.fromJson(json), throwsFormatException);
      });
    }
  });

  group('echo models compare by value', () {
    test('Echo equals and hashCode distinguish every field', () {
      final base = _echo();
      _expectSame(base, _echo());
      final variants = <Echo>[
        _echo(noteId: 'n2'),
        _echo(noteTitle: 'Other'),
        _echo(noteRole: null),
        _echo(noteRole: 'daily'),
        _echo(day: null),
        _echo(day: '2026-09-06'),
        _echo(passage: 'other passage'),
        _echo(startByte: null),
        _echo(startByte: 13),
        _echo(noteUpdatedAt: 1001),
      ];
      for (final v in variants) {
        expect(v, isNot(equals(base)), reason: '$v');
        expect(base, isNot(equals(v)), reason: '$v');
      }
    });

    test('EchoesReady compares by echoes emptyNote and pending', () {
      final pending = int.parse('3');
      final base = EchoesReady([_echo()], emptyNote: false, pending: pending);
      _expectSame(base, EchoesReady([_echo()], emptyNote: false, pending: 3));
      _expectSame(
        EchoesReady(<Echo>[], emptyNote: false, pending: 0),
        EchoesReady(<Echo>[], emptyNote: false, pending: 0),
      );
      for (final v in [
        EchoesReady(<Echo>[], emptyNote: false, pending: 3),
        EchoesReady([_echo(noteId: 'n2')], emptyNote: false, pending: 3),
        EchoesReady([_echo(), _echo()], emptyNote: false, pending: 3),
        EchoesReady([_echo()], emptyNote: true, pending: 3),
        EchoesReady([_echo()], emptyNote: false, pending: 4),
      ]) {
        expect(v, isNot(equals(base)));
        expect(base, isNot(equals(v)));
      }
      // Order matters: the CLI's order is the tab's order.
      expect(
        EchoesReady(
          [_echo(noteId: 'a'), _echo(noteId: 'b')],
          emptyNote: false,
          pending: 0,
        ),
        isNot(
          equals(
            EchoesReady(
              [_echo(noteId: 'b'), _echo(noteId: 'a')],
              emptyNote: false,
              pending: 0,
            ),
          ),
        ),
      );
    });

    test('EchoesUnavailableReason variants compare by value', () {
      final makers = <EchoesUnavailableReason Function()>[
        EmbeddingsOff.new,
        ModelNotDownloaded.new,
        () => EmbedderUnavailable('timed out'),
        NoCli.new,
        Outdated.new,
      ];
      for (var i = 0; i < makers.length; i++) {
        _expectSame(makers[i](), makers[i]());
        for (var j = 0; j < makers.length; j++) {
          if (i == j) continue;
          expect(makers[i](), isNot(equals(makers[j]())), reason: '$i vs $j');
        }
      }
      final message = ['timed', 'out'].join(' ');
      _expectSame(EmbedderUnavailable(message), EmbedderUnavailable(message));
      expect(
        EmbedderUnavailable('timed out'),
        isNot(equals(EmbedderUnavailable('offline'))),
      );
    });

    test('EchoesUnavailable compares by reason', () {
      _expectSame(
        EchoesUnavailable(EmbedderUnavailable('offline')),
        EchoesUnavailable(EmbedderUnavailable('offline')),
      );
      _expectSame(EchoesUnavailable(NoCli()), EchoesUnavailable(NoCli()));
      expect(
        EchoesUnavailable(EmbedderUnavailable('offline')),
        isNot(equals(EchoesUnavailable(EmbedderUnavailable('timed out')))),
      );
      expect(
        EchoesUnavailable(NoCli()),
        isNot(equals(EchoesUnavailable(Outdated()))),
      );
      expect(
        EchoesUnavailable(NoCli()),
        isNot(equals(EchoesReady(<Echo>[], emptyNote: false, pending: 0))),
      );
    });
  });

  group('VaultAccess.echoes', () {
    test('LocalVaultAccess echoes is the injected LocalEchoesAccess', () {
      final injected = FakeEchoesAccess(vaultPath: '/v-injected');
      final VaultAccess access = LocalVaultAccess(
        vaultPath: '/v-local',
        cli: FakeMemexCli(),
        echoes: injected,
      );

      expect(identical(access.echoes, injected), isTrue);
    });

    test(
      'LocalVaultAccess echoes defaults to a LocalEchoesAccess on the vault path and CLI',
      () {
        final cli = FakeMemexCli();
        final access = LocalVaultAccess(vaultPath: '/v-default', cli: cli);

        expect(access.echoes, isA<LocalEchoesAccess>());
        expect(access.echoes, isNot(isA<FakeEchoesAccess>()));
        expect(access.echoes.vaultPath, '/v-default');
        expect(identical(access.echoes.cli, cli), isTrue);
        expect(identical(access.echoes, access.echoes), isTrue);
      },
    );

    test(
      'LocalVaultAccess default echoes has no CLI when the vault has none',
      () {
        final access = LocalVaultAccess(vaultPath: '/v-no-cli');

        expect(access.echoes.vaultPath, '/v-no-cli');
        expect(access.echoes.cli, isNull);
      },
    );

    test(
      'HostedVaultAccess echoes is a HostedEchoesAccess for the vault over the composite client',
      () {
        final server = FakeVaultServer();
        final container = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(FakeClock()),
            utcOffsetProvider.overrideWithValue(() => Duration.zero),
          ],
        );
        addTearDown(container.dispose);
        final VaultAccess access = HostedVaultAccess(
          client: server.connect(container),
          vaultName: 'seed',
        );

        final echoes = access.echoes;
        expect(echoes, isA<HostedEchoesAccess>());
        echoes as HostedEchoesAccess;
        expect(echoes.vaultName, 'seed');
        // The same composite client every other domain uses, so a disposed
        // composite refuses echoes reads too.
        final topics = access.topics as HostedTopicsAccess;
        expect(identical(echoes.client, topics.client), isTrue);
        expect(identical(access.echoes, echoes), isTrue);
      },
    );
  });

  group('pumpEchoesTab', () {
    testWidgets('pumpEchoesTab pumps the echoes tab with the fakes', (
      tester,
    ) async {
      final echoes = FakeEchoesAccess();
      final links = FakeEchoLinkActions();
      final clock = FakeClock(DateTime(2026, 11, 11, 8));
      final cli = FakeMemexCli();
      final h = await pumpEchoesTab(
        tester,
        echoes: echoes,
        links: links,
        clock: clock,
        cli: cli,
        noteId: 'n-open',
        openTitle: 'Level Design',
        openRole: 'topic',
      );

      expect(_eyebrow, findsOneWidget);
      expect(find.byType(RightPanel), findsOneWidget);

      final access = h.read(vaultAccessProvider)!;
      expect(identical(access.echoes, echoes), isTrue);
      expect(identical(h.echoes, echoes), isTrue);
      expect(identical(h.read(echoLinkActionsProvider), links), isTrue);
      expect(identical(h.links, links), isTrue);
      expect(identical(h.read(clockProvider), clock), isTrue);
      expect(identical(h.clock, clock), isTrue);
      expect(identical(h.read(memexCliProvider), cli), isTrue);
      expect(access.canWrite, isTrue);
      expect(h.read(selectedNoteIdProvider), 'n-open');
      expect(h.noteId, 'n-open');
      expect(h.read(rightPanelOpenProvider), isTrue);
      expect(h.read(rightPanelTabProvider), RightPanelTab.echoes);

      final open = await access.notes.getNote('n-open');
      expect(open?.title, 'Level Design');
      expect(open?.role, 'topic');
    });

    testWidgets('pumpEchoesTab defaults wire fresh fakes into the tab', (
      tester,
    ) async {
      final h = await pumpEchoesTab(tester);

      expect(_eyebrow, findsOneWidget);
      final access = h.read(vaultAccessProvider)!;
      expect(identical(access.echoes, h.echoes), isTrue);
      expect(identical(h.read(echoLinkActionsProvider), h.links), isTrue);
      expect(identical(h.read(clockProvider), h.clock), isTrue);
      expect(identical(h.read(memexCliProvider), h.cli), isTrue);
      expect(h.read(selectedNoteIdProvider), echoesOpenNoteId);
      // The echoes tab (#427) reads the open note, and only it.
      expect(
        h.echoes.calls.map((c) => c.noteId),
        everyElement(echoesOpenNoteId),
      );
      expect(h.links.calls, isEmpty);
      final open = await access.notes.getNote(echoesOpenNoteId);
      expect(open, isNotNull);
      expect(open!.role, isNull);
    });

    testWidgets('pumpEchoesTab can select no note and configure no CLI', (
      tester,
    ) async {
      final h = await pumpEchoesTab(
        tester,
        noteId: null,
        memexConfigured: false,
      );

      expect(_eyebrow, findsOneWidget);
      expect(h.read(selectedNoteIdProvider), isNull);
      expect(h.cli, isNull);
      expect(h.read(memexCliProvider), isNull);
      final access = h.read(vaultAccessProvider)!;
      expect(access.canWrite, isFalse);
      expect(identical(access.echoes, h.echoes), isTrue);
    });

    testWidgets('pumpEchoesTab can open another panel tab or close it', (
      tester,
    ) async {
      final h = await pumpEchoesTab(
        tester,
        tab: RightPanelTab.connections,
        panelOpen: false,
      );

      expect(h.read(rightPanelOpenProvider), isFalse);
      expect(h.read(rightPanelTabProvider), RightPanelTab.connections);
      expect(_eyebrow, findsNothing);
      expect(identical(h.read(vaultAccessProvider)!.echoes, h.echoes), isTrue);
    });

    testWidgets('pumpEchoesTab selects the virtual Today note unseeded', (
      tester,
    ) async {
      const today = 'virtual-today:2026-10-03';
      final h = await pumpEchoesTab(tester, noteId: today);

      expect(h.read(selectedNoteIdProvider), today);
      final access = h.read(vaultAccessProvider)!;
      expect(await access.notes.getNote(today), isNull);
      expect(identical(access.echoes, h.echoes), isTrue);
    });

    testWidgets('pumpEchoesTab lays text out at the given scale', (
      tester,
    ) async {
      final h = await pumpEchoesTab(tester, textScale: 0.6);

      expect(identical(h.read(vaultAccessProvider)!.echoes, h.echoes), isTrue);
      final context = tester.element(_eyebrow);
      expect(MediaQuery.textScalerOf(context).scale(10), 6);
    });
  });

  group('echoes fakes', () {
    test('FakeEchoesAccess answers queued results then the default', () async {
      final ready = EchoesReady([_echo()], emptyNote: false, pending: 2);
      final fake = FakeEchoesAccess(result: ready)
        ..enqueue(EchoesUnavailable(ModelNotDownloaded()));

      expect(await fake.echoes('a'), EchoesUnavailable(ModelNotDownloaded()));
      expect(await fake.echoes('b', allowDownload: true), ready);
      expect(await fake.echoes('c'), ready);
      expect([for (final c in fake.calls) c.noteId], ['a', 'b', 'c']);
      expect(
        [for (final c in fake.calls) c.allowDownload],
        [false, true, false],
      );
      expect(fake.inFlight, 0);
    });

    test('FakeEchoesAccess defaults to no echoes', () async {
      final fake = FakeEchoesAccess();
      expect(
        await fake.echoes('a'),
        EchoesReady(<Echo>[], emptyNote: false, pending: 0),
      );
      expect(fake.vaultPath, '/fake-echoes-vault');
    });

    test('FakeEchoesAccess throws a queued error', () async {
      final fake = FakeEchoesAccess()..enqueue(StateError('boom'));

      await expectLater(fake.echoes('a'), throwsStateError);
      expect(fake.calls.single.finished, isTrue);
      expect(fake.inFlight, 0);
    });

    test('FakeEchoesAccess holds each call on the gate it saw', () async {
      final fake = FakeEchoesAccess();
      final first = Completer<void>();
      fake.gate = first;
      final a = fake.echoes('a');
      final second = Completer<void>();
      fake.gate = second;
      final b = fake.echoes('b');
      await Future<void>.delayed(Duration.zero);
      expect(fake.inFlight, 2);

      second.complete();
      await b;
      expect(fake.calls[1].finished, isTrue);
      expect(fake.calls[0].finished, isFalse);
      expect(fake.inFlight, 1);

      first.complete();
      await a;
      expect(fake.inFlight, 0);
    });

    test('FakeEchoesAccess picks each answer when the call starts', () async {
      final fake = FakeEchoesAccess()
        ..enqueue(EchoesUnavailable(NoCli()))
        ..enqueue(EchoesUnavailable(Outdated()));
      final gate = Completer<void>();
      fake.gate = gate;
      final a = fake.echoes('a');
      fake.gate = null;
      final b = await fake.echoes('b');
      gate.complete();

      expect(b, EchoesUnavailable(Outdated()));
      expect(await a, EchoesUnavailable(NoCli()));
    });

    test(
      'FakeEchoLinkActions records calls holds on its gate and throws a scripted failure',
      () async {
        final links = FakeEchoLinkActions();
        final echo = _echo();
        final gate = Completer<void>();
        links.gate = gate;
        var done = false;
        final held = links
            .link(openNoteId: 'open', echo: echo, plan: EchoLinkPlan.fromOpen)
            .then((_) => done = true);
        await Future<void>.delayed(Duration.zero);
        expect(done, isFalse);
        expect(links.calls.single.openNoteId, 'open');
        expect(links.calls.single.echo, echo);
        expect(links.calls.single.plan, EchoLinkPlan.fromOpen);
        gate.complete();
        await held;
        expect(done, isTrue);

        links
          ..gate = null
          ..failure = StateError('link failed');
        await expectLater(
          links.link(
            openNoteId: 'open',
            echo: echo,
            plan: EchoLinkPlan.footerChip,
          ),
          throwsStateError,
        );
        expect(links.calls, hasLength(2));
        expect(links.calls.last.plan, EchoLinkPlan.footerChip);
      },
    );
  });
}
