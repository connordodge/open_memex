// WI #97 (H3): picker contracts the implementer's handoff listed as unpinned
// and the implementer's row decisions:
// - flag off: hosted recents are hidden, row indexes count shown rows, the
//   subtitle and the binary card keep today's local copy;
// - a recorded outcome wins over a newer probe status until it is cleared
//   (by the open controller, the x, or remove from recents);
// - a vault-gone row still opens on tap; not-memex, api-mismatch,
//   schema-refused and probe-incompatible rows do not;
// - every row that is not opening has the x;
// - the opening row carries the inner key `recent-row-opening`;
// - a non-hosted recorded failure shows the danger layout with its message
//   and still opens.
//
// Seams: test/support/vault_picker_harness.dart.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:path/path.dart' as p;

import '../support/fake_vault_server.dart';
import '../support/vault_folders.dart';
import '../support/vault_picker_harness.dart';

const _memex = HostedVaultRef(fakeServerId, 'memex');

const _hostedSubtitle =
    'a vault is a folder of your notes. open one on this mac, or one hosted '
    'by a vault server.';
const _localSubtitle =
    'a vault is a folder of your notes (manifest.json + memex.db). open one '
    'you have, or create a new one.';

const _unreachable = HostedServerUnreachable(
  _memex,
  fakeServerName,
  "can't reach nas",
);
const _tokenRejected = HostedTokenRejected(
  _memex,
  fakeServerName,
  'nas rejected the access token',
);
const _gone = HostedVaultGone(
  _memex,
  fakeServerName,
  'memex is no longer on nas',
);
const _notMemex = HostedNotMemexServer(
  _memex,
  fakeServerName,
  "nas isn't a memex vault server",
);
const _mismatch = HostedApiMismatch(
  _memex,
  fakeServerName,
  'nas runs another memex release',
  serverVersion: '0.9.3',
);
const _schema = HostedSchemaRefused(
  _memex,
  fakeServerName,
  'nas refused the vault schema',
);
const _notSaved = VaultOpenFailure(
  'this vault server is no longer saved. add it again to open its vaults.',
);

/// Keeps nas's probe in flight, so the row shows only its recorded outcome.
void _holdNas(Map<String, FakeVaultServer> s) => s[fakeServerId]!.hold();

/// Answers every open with a plain failure, so a tap never runs the real
/// open path.
void _fakeOpen(Wi97OpenController o) =>
    o.onOpen = (_) async => const VaultOpenFailure('fake open');

void main() {
  wi97HoldFontFetches();

  group('subtitle', () {
    testWidgets('the subtitle names vault servers', (tester) async {
      await pumpVaultPicker(tester);

      expect(find.text(_hostedSubtitle), findsOneWidget);
      expect(find.text(_localSubtitle), findsNothing);
    });
  });

  group('recorded outcome over probe status', () {
    testWidgets(
      'a recorded unreachable outcome beats a newer connected probe until it is cleared',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_memex],
          recorded: {_memex: const RecentRowFailed(_unreachable)},
        );

        // The probe returned connected after the outcome was recorded.
        expect(env.infoRequests(fakeServerId), hasLength(1));
        expect(
          wi97DotIn(tester, 'server-row-srv-nas'),
          StatusDotState.connected,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.cantReach);
        expect(
          wi97Inside('recent-row-0', find.text("can't reach nas")),
          findsOneWidget,
        );
        expect(
          wi97Inside('recent-row-0', find.text('nas · nas.local:7878')),
          findsNothing,
        );

        // A refocus probe that also connects changes nothing.
        env.focus.set(false);
        await wi97Settle(tester);
        env.focus.set(true);
        await wi97Settle(tester);
        expect(env.infoRequests(fakeServerId), hasLength(2));
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.cantReach);

        // Cleared (as the open controller does on success): the probe shows.
        env.container.read(recentRowOutcomeProvider(_memex).notifier).state =
            null;
        await wi97Settle(tester);
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.connected);
        expect(
          wi97Inside('recent-row-0', find.text('nas · nas.local:7878')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('recent-row-retry-0')), findsNothing);
      },
    );

    testWidgets(
      'a recorded token rejected outcome beats a newer connected probe',
      (tester) async {
        await pumpVaultPicker(
          tester,
          recents: const [_memex],
          recorded: {_memex: const RecentRowFailed(_tokenRejected)},
        );

        expect(
          wi97DotIn(tester, 'server-row-srv-nas'),
          StatusDotState.connected,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
        expect(
          find.byKey(const Key('recent-row-update-token-0')),
          findsOneWidget,
        );
      },
    );

    testWidgets('the x on a row clears its recorded outcome', (tester) async {
      final env = await pumpVaultPicker(
        tester,
        recents: const [_memex],
        recorded: {_memex: const RecentRowFailed(_unreachable)},
      );

      await tester.tap(find.byKey(const Key('recent-row-remove-0')));
      await wi97Settle(tester);

      expect(env.settings.recentRefs, isEmpty);
      expect(env.container.read(recentRowOutcomeProvider(_memex)), isNull);

      // Opened again later, the entry starts from the probe status.
      await env.container.read(settingsProvider.notifier).rememberRef(_memex);
      await wi97Settle(tester);
      expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.connected);
      expect(
        wi97Inside('recent-row-0', find.text("can't reach nas")),
        findsNothing,
      );
    });

    testWidgets(
      'remove from recents on a vault gone row clears its recorded outcome',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_memex],
          recorded: {_memex: const RecentRowFailed(_gone)},
        );

        await tester.tap(
          find.byKey(const Key('recent-row-remove-from-recents-0')),
        );
        await wi97Settle(tester);

        expect(env.settings.recentRefs, isEmpty);
        expect(env.container.read(recentRowOutcomeProvider(_memex)), isNull);
      },
    );

    testWidgets('the x on one row leaves the recorded outcome of another row', (
      tester,
    ) async {
      const work = HostedVaultRef(fakeServerId, 'work');
      final env = await pumpVaultPicker(
        tester,
        recents: const [_memex, work],
        recorded: {
          _memex: const RecentRowFailed(_unreachable),
          work: const RecentRowFailed(_tokenRejected),
        },
      );

      await tester.tap(find.byKey(const Key('recent-row-remove-0')));
      await wi97Settle(tester);

      expect(env.settings.recentRefs, [work]);
      expect(
        env.container.read(recentRowOutcomeProvider(work)),
        isA<RecentRowFailed>(),
      );
      expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
    });
  });

  group('which rows open', () {
    testWidgets('a recorded vault gone row still opens on tap', (tester) async {
      final env = await pumpVaultPicker(
        tester,
        recents: const [_memex],
        beforePump: _holdNas,
        recorded: {_memex: const RecentRowFailed(_gone)},
        configureOpener: _fakeOpen,
      );

      await _tapRow(tester, 0);
      await wi97Settle(tester);

      expect(env.opener.opened, [_memex]);
    });

    for (final (name, failure) in const [
      ('a recorded not memex row does not open on tap', _notMemex),
      ('a recorded api mismatch row does not open on tap', _mismatch),
      ('a recorded schema refused row does not open on tap', _schema),
    ]) {
      testWidgets(name, (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_memex],
          beforePump: _holdNas,
          recorded: {_memex: RecentRowFailed(failure)},
          configureOpener: _fakeOpen,
        );

        expect(
          wi97Inside('recent-row-0', find.text(failure.message)),
          findsOneWidget,
        );
        await _tapRow(tester, 0);
        await wi97Settle(tester);

        expect(env.opener.opened, isEmpty);
        expect(find.byKey(const Key('recent-row-remove-0')), findsOneWidget);
      });
    }

    for (final (name, setUp) in <(String, void Function(FakeVaultServer))>[
      (
        'a hosted row whose probe found no memex server does not open on tap',
        (s) => s.servesHtml = true,
      ),
      (
        'a hosted row whose probe found another api version does not open on tap',
        (s) => s.route(
          'GET',
          '/api/v1/info',
          json: {'api_version': 2, 'server_version': '0.9.3'},
        ),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_memex],
          beforePump: (s) => setUp(s[fakeServerId]!),
          configureOpener: _fakeOpen,
        );

        expect(env.status(fakeServerId), isNotNull);
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
        await _tapRow(tester, 0);
        await wi97Settle(tester);

        expect(env.opener.opened, isEmpty);
        expect(find.byKey(const Key('recent-row-remove-0')), findsOneWidget);
      });
    }

    testWidgets(
      'a recorded failure that is not hosted shows the danger layout with its message and still opens',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_memex],
          beforePump: _holdNas,
          recorded: {_memex: const RecentRowFailed(_notSaved)},
          configureOpener: _fakeOpen,
        );

        expect(
          wi97TextColorIn(tester, 'recent-row-0', _notSaved.message),
          OmColors.danger,
        );
        expect(wi97DotIn(tester, 'recent-row-0'), StatusDotState.tokenRejected);
        expect(
          wi97Inside('recent-row-0', find.byIcon(LucideIcons.alertTriangle)),
          findsOneWidget,
        );
        expect(find.byKey(const Key('recent-row-retry-0')), findsNothing);
        expect(
          find.byKey(const Key('recent-row-update-token-0')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('recent-row-remove-from-recents-0')),
          findsNothing,
        );
        expect(find.byKey(const Key('recent-row-remove-0')), findsOneWidget);

        await _tapRow(tester, 0);
        await wi97Settle(tester);
        expect(env.opener.opened, [_memex]);
      },
    );
  });

  group('the x on every row that is not opening', () {
    for (final (name, outcome) in const [
      ('a recorded unreachable row has the x', RecentRowFailed(_unreachable)),
      (
        'a recorded token rejected row has the x',
        RecentRowFailed(_tokenRejected),
      ),
      ('a recorded vault gone row has the x', RecentRowFailed(_gone)),
      ('a recorded not memex row has the x', RecentRowFailed(_notMemex)),
      ('a recorded api mismatch row has the x', RecentRowFailed(_mismatch)),
      ('a recorded schema refused row has the x', RecentRowFailed(_schema)),
      (
        'a recorded not hosted failure row has the x',
        RecentRowFailed(_notSaved),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_memex],
          beforePump: _holdNas,
          recorded: {_memex: outcome},
        );

        final x = find.byKey(const Key('recent-row-remove-0'));
        expect(x, findsOneWidget);
        await tester.tap(x);
        await wi97Settle(tester);
        expect(env.settings.recentRefs, isEmpty);
      });
    }

    for (final (name, setUp) in <(String, void Function(FakeVaultServer))>[
      ('a hosted row still checking has the x', (s) => s.hold()),
      (
        'a hosted row that cannot reach its server has the x',
        (s) => s.failure = FakeServerFailure.refused,
      ),
      (
        'a hosted row whose token is rejected has the x',
        (s) => s.token = 'rotated-on-server',
      ),
      (
        'a hosted row on a server that is not memex has the x',
        (s) => s.servesHtml = true,
      ),
      ('a connected hosted row has the x', (_) {}),
    ]) {
      testWidgets(name, (tester) async {
        await pumpVaultPicker(
          tester,
          recents: const [_memex],
          beforePump: (s) => setUp(s[fakeServerId]!),
        );

        expect(find.byKey(const Key('recent-row-remove-0')), findsOneWidget);
      });
    }

    testWidgets('a local row with a missing folder has the x', (tester) async {
      final missing = p.join(createPlainFolder().path, 'gone');
      await pumpVaultPicker(tester, recents: [LocalVaultRef(missing)]);

      expect(find.byKey(const Key('recent-row-remove-0')), findsOneWidget);
    });
  });

  group('the opening row', () {
    testWidgets(
      'an opening hosted row carries the inner key recent-row-opening and does not open',
      (tester) async {
        final env = await pumpVaultPicker(
          tester,
          recents: const [_memex],
          beforePump: _holdNas,
          recorded: {_memex: const RecentRowOpening()},
          configureOpener: _fakeOpen,
        );

        expect(
          wi97Inside(
            'recent-row-0',
            find.byKey(const Key('recent-row-opening')),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('recent-row-remove-0')), findsNothing);
        await _tapRow(tester, 0);
        await wi97Settle(tester);
        expect(env.opener.opened, isEmpty);
      },
    );

    testWidgets('a row that is not opening has no recent-row-opening key', (
      tester,
    ) async {
      await pumpVaultPicker(tester, recents: const [_memex]);

      expect(find.byKey(const Key('recent-row-opening')), findsNothing);
    });
  });

  group('row hover', () {
    testWidgets(
      'hovering a row that opens fills it surface3 and leaving restores surface2',
      (tester) async {
        await pumpVaultPicker(tester, recents: const [_memex]);
        expect(_rowFill(tester, 0), OmColors.surface2);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(
          tester.getTopLeft(find.byKey(const Key('recent-row-0'))) +
              const Offset(18, 18),
        );
        await tester.pump();
        expect(_rowFill(tester, 0), OmColors.surface3);

        await mouse.moveTo(Offset.zero);
        await tester.pump();
        expect(_rowFill(tester, 0), OmColors.surface2);
      },
    );

    testWidgets('hovering a row that does not open keeps it surface2', (
      tester,
    ) async {
      await pumpVaultPicker(
        tester,
        recents: const [_memex],
        beforePump: _holdNas,
        recorded: {_memex: const RecentRowFailed(_schema)},
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getTopLeft(find.byKey(const Key('recent-row-0'))) +
            const Offset(18, 18),
      );
      await tester.pump();
      expect(_rowFill(tester, 0), OmColors.surface2);
    });
  });
}

/// The fill of row [n]'s decorated container.
Color? _rowFill(WidgetTester tester, int n) {
  final boxes = tester.widgetList<Container>(
    wi97Inside('recent-row-$n', find.byType(Container)),
  );
  final decorated = boxes.firstWhere((c) => c.decoration is BoxDecoration);
  return (decorated.decoration! as BoxDecoration).color;
}

/// Taps row [n] on its icon, clear of the trailing buttons (the test font
/// is wide enough that the centre of a row with an action can land on it).
Future<void> _tapRow(WidgetTester tester, int n) => tester.tapAt(
  tester.getTopLeft(find.byKey(Key('recent-row-$n'))) + const Offset(18, 18),
);
