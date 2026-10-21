// WI #101 (H7) AC1 to AC6: the banner slot (`VaultSchemaBanner`) of the
// workspace for a hosted vault (design pack 101, boards A11 states 1 and 2,
// A12 banners at 36 px). One banner at a time from the open hosted vault's
// server status; a local vault keeps today's schema-outdated banner.
//
// API under test (the lead's ruling on #77 replaces `unauthorized` with
// `tokenRejected`; there is no `vaultGone` status):
//   hostedServerNameProvider      Provider.family<String, String>
//       state/hosted_identity.dart: serverId -> display name, default = id
//   hostedUpdateTokenProvider     Provider<void Function(String serverId)>
//       default does nothing; #105 binds it to the edit-server dialog
//   hostedClientForServerProvider Provider.family<HostedClient?, String>
//       serverId -> the client "retry now" sends one request through;
//       default null (retry now then sends nothing)
//   hostedVaultGoneProvider       StateProvider.family<bool, HostedVaultRef>
//       default false; set once a request found the vault gone
//       (vault_not_found), Req 53a
//   VaultSchemaBanner (widgets/vault_schema_banner.dart) renders, for the
//   open HostedVaultRef(serverId, vaultName), one of:
//     Key hosted-banner-unreachable   status unreachable (OmButton
//                                     hosted-banner-retry, label retry now)
//     Key hosted-banner-unauthorized  status tokenRejected (OmButton
//                                     hosted-banner-update-token)
//     Key hosted-banner-vault-gone    gone flag, no button
//   The three hosted-banner keys sit on the banner root (36 px tall).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/hosted_identity.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';
import 'package:open_memex_app/src/widgets/vault_schema_banner.dart';

import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_server.dart';

const _server = 'srv-nas';
const _vault = HostedVaultRef(_server, 'work');

const _unreachableKey = Key('hosted-banner-unreachable');
const _unauthorizedKey = Key('hosted-banner-unauthorized');
const _goneKey = Key('hosted-banner-vault-gone');
const _retryKey = Key('hosted-banner-retry');
const _updateTokenKey = Key('hosted-banner-update-token');
const _allBannerKeys = [_unreachableKey, _unauthorizedKey, _goneKey];

const _unreachableText = 'can\'t reach nas — retrying…';
const _unauthorizedText = 'nas rejected the access token';
const _goneText = 'work is no longer on nas';

String _serverName(String id) => id == _server ? 'nas' : id;

/// The banner slot over a stand-in tab body, with the seams a hosted vault
/// needs. [vault] is the open vault; [overrides] come last.
Future<ProviderContainer> _pumpSlot(
  WidgetTester tester, {
  VaultRef? vault = _vault,
  bool schemaOutdated = false,
  List<Override> overrides = const [],
}) async {
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vault),
      vaultOpenProvider.overrideWith(
        (_) async => VaultOpenState(schemaOutdated: schemaOutdated),
      ),
      hostedServerNameProvider.overrideWith((ref, id) => _serverName(id)),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: const Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              VaultSchemaBanner(),
              Expanded(child: SizedBox(key: Key('stand-in-body'))),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

void _setStatus(ProviderContainer c, HostedConnectionStatus? status) =>
    c.read(hostedConnectionStatusProvider(_server).notifier).state = status;

BoxDecoration _decorationOf(WidgetTester tester, Key key) {
  final w = tester.widget(find.byKey(key));
  if (w is Container) return w.decoration! as BoxDecoration;
  if (w is DecoratedBox) return w.decoration as BoxDecoration;
  return tester
          .widget<DecoratedBox>(
            find
                .descendant(
                  of: find.byKey(key),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          )
          .decoration
      as BoxDecoration;
}

Finder _iconIn(Key key, IconData icon) =>
    find.descendant(of: find.byKey(key), matching: find.byIcon(icon));

void _expectStyle(TextStyle? actual, TextStyle expected) {
  expect(actual, isNotNull);
  expect(actual!.fontFamily, expected.fontFamily);
  expect(actual.fontSize, expected.fontSize);
  expect(actual.fontWeight, expected.fontWeight);
  expect(actual.height, expected.height);
  expect(actual.color, expected.color);
}

void _expectBannerFrame(
  WidgetTester tester,
  Key key, {
  required Color fill,
  required IconData icon,
  required Color ink,
  required String text,
}) {
  expect(tester.getSize(find.byKey(key)).height, 36);
  final deco = _decorationOf(tester, key);
  expect(deco.color, fill);
  final border = deco.border! as Border;
  expect(border.bottom.color, OmColors.line1);
  expect(border.bottom.width, 1);
  expect(border.top, BorderSide.none);
  final iconWidget = tester.widget<Icon>(_iconIn(key, icon));
  expect(iconWidget.size, 14);
  expect(iconWidget.color, ink);
  final label = find.descendant(of: find.byKey(key), matching: find.text(text));
  expect(label, findsOneWidget);
  _expectStyle(
    tester.widget<Text>(label).style,
    OmType.sans(size: 12, color: ink, height: 16.8 / 12),
  );
}

void _expectSmallSecondary(WidgetTester tester, Key key, String label) {
  final button = tester.widget<OmButton>(find.byKey(key));
  expect(button.label, label);
  expect(button.kind, OmButtonKind.secondary);
  expect(button.size, 24);
  expect(button.dense, isTrue);
  expect(button.icon, isNull);
  expect(button.onPressed, isNotNull);
}

/// A real `HostedClient` for [server] under the provider's `ref`, so a
/// request it sends writes the status like the app's client does.
HostedClient _clientFor(Ref ref, FakeVaultServer server) => HostedClient(
  ref,
  serverId: fakeServerId,
  serverName: fakeServerName,
  serverUrl: server.url.toString(),
  accessToken: fakeServerToken,
  httpClient: server.client,
);

void main() {
  group('seam defaults', () {
    test('hostedVaultGoneProvider defaults to false per vault', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final a = HostedVaultRef('srv-x', 'work');
      final b = HostedVaultRef('srv-x', 'other');
      expect(c.read(hostedVaultGoneProvider(a)), isFalse);
      c.read(hostedVaultGoneProvider(a).notifier).state = true;
      expect(
        c.read(hostedVaultGoneProvider(HostedVaultRef('srv-x', 'work'))),
        isTrue,
      );
      expect(c.read(hostedVaultGoneProvider(b)), isFalse);
    });
  });

  group('unreachable banner', () {
    testWidgets(
      'an unreachable server shows the cant reach banner with retry now',
      (tester) async {
        final c = await _pumpSlot(tester);
        expect(find.byKey(_unreachableKey), findsNothing);
        _setStatus(c, HostedConnectionStatus.unreachable);
        await tester.pump();
        expect(find.byKey(_unreachableKey), findsOneWidget);
        expect(find.text(_unreachableText), findsOneWidget);
        expect(find.byKey(_retryKey), findsOneWidget);
        expect(find.text('retry now'), findsOneWidget);
        expect(find.byKey(_unauthorizedKey), findsNothing);
        expect(find.byKey(_goneKey), findsNothing);
        expect(find.byKey(const Key('vault-schema-outdated')), findsNothing);
      },
    );

    testWidgets('the unreachable banner uses warn styling at 36 px', (
      tester,
    ) async {
      final c = await _pumpSlot(tester);
      _setStatus(c, HostedConnectionStatus.unreachable);
      await tester.pump();
      _expectBannerFrame(
        tester,
        _unreachableKey,
        fill: OmColors.warnBg,
        icon: LucideIcons.wifiOff,
        ink: OmColors.warn,
        text: _unreachableText,
      );
      _expectSmallSecondary(tester, _retryKey, 'retry now');
    });

    testWidgets('the banner names the server from hostedServerNameProvider', (
      tester,
    ) async {
      final c = await _pumpSlot(
        tester,
        overrides: [
          hostedServerNameProvider.overrideWith(
            (ref, id) => id == _server ? 'office box' : id,
          ),
        ],
      );
      _setStatus(c, HostedConnectionStatus.unreachable);
      await tester.pump();
      expect(find.text('can\'t reach office box — retrying…'), findsOneWidget);
    });

    testWidgets(
      'the unreachable banner shows above the tab bar and the loaded note stays',
      (tester) async {
        final h = await pumpWorkspace(
          tester,
          overrides: [
            hostedServerNameProvider.overrideWith((ref, id) => _serverName(id)),
          ],
        );
        h.container.read(currentVaultProvider.notifier).state = _vault;
        await pumpFrames(tester);
        h.container
            .read(tabsProvider.notifier)
            .openOrFocus(const NoteTab('n1'));
        await pumpFrames(tester);
        h.container
                .read(hostedConnectionStatusProvider(_server).notifier)
                .state =
            HostedConnectionStatus.unreachable;
        await pumpFrames(tester);

        final banner = find.byKey(_unreachableKey);
        expect(banner, findsOneWidget);
        final tabBar = find.byKey(const Key('workspace-tab-bar'));
        expect(tabBar, findsOneWidget);
        expect(
          tester.getTopLeft(banner).dy + 36,
          lessThanOrEqualTo(tester.getTopLeft(tabBar).dy),
        );
        // The note area below the banner keeps its editor.
        expect(find.byType(NoteEditor), findsOneWidget);
        expect(find.byKey(const Key('tab-not-loaded')), findsNothing);
      },
    );

    testWidgets('the banner clears as soon as the status becomes connected', (
      tester,
    ) async {
      final c = await _pumpSlot(tester);
      _setStatus(c, HostedConnectionStatus.unreachable);
      await tester.pump();
      expect(find.byKey(_unreachableKey), findsOneWidget);
      _setStatus(c, HostedConnectionStatus.connected);
      await tester.pump();
      for (final key in _allBannerKeys) {
        expect(find.byKey(key), findsNothing);
      }
      // And it comes back when the server drops out again.
      _setStatus(c, HostedConnectionStatus.unreachable);
      await tester.pump();
      expect(find.byKey(_unreachableKey), findsOneWidget);
    });
  });

  group('retry now', () {
    ({
      FakeVaultServer server,
      FakeVaultServer other,
      FakeClock clock,
      List<Override> overrides,
    })
    env() {
      final server = FakeVaultServer()..serveDomain('server');
      final other = FakeVaultServer(url: 'http://other.local:7878')
        ..serveDomain('server');
      final clock = FakeClock();
      return (
        server: server,
        other: other,
        clock: clock,
        overrides: <Override>[
          clockProvider.overrideWithValue(clock),
          utcOffsetProvider.overrideWithValue(() => Duration.zero),
          hostedClientForServerProvider.overrideWith(
            (ref, id) => switch (id) {
              fakeServerId => _clientFor(ref, server),
              'srv-other' => HostedClient(
                ref,
                serverId: 'srv-other',
                serverName: 'other',
                serverUrl: other.url.toString(),
                accessToken: fakeServerToken,
                httpClient: other.client,
              ),
              _ => null,
            },
          ),
        ],
      );
    }

    Future<void> tapRetry(WidgetTester tester) async {
      await tester.tap(find.byKey(_retryKey));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    testWidgets(
      'retry now sends exactly one request to the server at once off the poll schedule',
      (tester) async {
        final e = env();
        final c = await _pumpSlot(tester, overrides: e.overrides);
        _setStatus(c, HostedConnectionStatus.unreachable);
        await tester.pump();
        expect(e.server.requests, isEmpty);

        await tapRetry(tester);

        // One request, with the fake clock never advanced.
        expect(e.server.requests, hasLength(1));
        expect(
          e.server.requests.single.url.toString(),
          startsWith(fakeServerUrl),
        );
        expect(e.clock.now(), DateTime(2026, 10, 3, 9));
      },
    );

    testWidgets('a successful retry clears the banner', (tester) async {
      final e = env();
      final c = await _pumpSlot(tester, overrides: e.overrides);
      _setStatus(c, HostedConnectionStatus.unreachable);
      await tester.pump();

      await tapRetry(tester);

      expect(
        c.read(hostedConnectionStatusProvider(_server)),
        HostedConnectionStatus.connected,
      );
      for (final key in _allBannerKeys) {
        expect(find.byKey(key), findsNothing);
      }
    });

    testWidgets(
      'a failed retry keeps the banner and sends one request each tap',
      (tester) async {
        final e = env();
        e.server.failure = FakeServerFailure.refused;
        final c = await _pumpSlot(tester, overrides: e.overrides);
        _setStatus(c, HostedConnectionStatus.unreachable);
        await tester.pump();

        await tapRetry(tester);
        expect(e.server.requests, hasLength(1));
        expect(
          c.read(hostedConnectionStatusProvider(_server)),
          HostedConnectionStatus.unreachable,
        );
        expect(find.byKey(_unreachableKey), findsOneWidget);
        expect(find.byKey(_retryKey), findsOneWidget);

        await tapRetry(tester);
        expect(e.server.requests, hasLength(2));
        expect(find.byKey(_unreachableKey), findsOneWidget);

        // The server comes back: the next tap clears it.
        e.server.failure = null;
        await tapRetry(tester);
        expect(e.server.requests, hasLength(3));
        expect(find.byKey(_unreachableKey), findsNothing);
      },
    );

    testWidgets('retry now goes to the server of the open vault only', (
      tester,
    ) async {
      final e = env();
      final c = await _pumpSlot(tester, overrides: e.overrides);
      _setStatus(c, HostedConnectionStatus.unreachable);
      await tester.pump();

      await tapRetry(tester);

      expect(e.server.requests, hasLength(1));
      expect(e.other.requests, isEmpty);
    });

    testWidgets(
      'retry now with no bound client sends nothing and keeps the banner',
      (tester) async {
        final c = await _pumpSlot(tester);
        _setStatus(c, HostedConnectionStatus.unreachable);
        await tester.pump();

        await tapRetry(tester);

        expect(find.byKey(_unreachableKey), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('token rejected banner', () {
    testWidgets(
      'a rejected token shows the rejected banner with update token',
      (tester) async {
        final c = await _pumpSlot(tester);
        _setStatus(c, HostedConnectionStatus.tokenRejected);
        await tester.pump();
        expect(find.byKey(_unauthorizedKey), findsOneWidget);
        expect(find.text(_unauthorizedText), findsOneWidget);
        expect(find.byKey(_updateTokenKey), findsOneWidget);
        expect(find.text('update token'), findsOneWidget);
        expect(find.byKey(_unreachableKey), findsNothing);
        expect(find.byKey(_retryKey), findsNothing);
        expect(find.byKey(_goneKey), findsNothing);
      },
    );

    testWidgets('the rejected banner uses danger styling at 36 px', (
      tester,
    ) async {
      final c = await _pumpSlot(tester);
      _setStatus(c, HostedConnectionStatus.tokenRejected);
      await tester.pump();
      _expectBannerFrame(
        tester,
        _unauthorizedKey,
        fill: OmColors.dangerBg,
        icon: LucideIcons.keyRound,
        ink: OmColors.danger,
        text: _unauthorizedText,
      );
      _expectSmallSecondary(tester, _updateTokenKey, 'update token');
    });

    testWidgets('update token calls the seam with the server id', (
      tester,
    ) async {
      final calls = <String>[];
      final c = await _pumpSlot(
        tester,
        overrides: [hostedUpdateTokenProvider.overrideWithValue(calls.add)],
      );
      _setStatus(c, HostedConnectionStatus.tokenRejected);
      await tester.pump();
      expect(calls, isEmpty);

      await tester.tap(find.byKey(_updateTokenKey));
      await tester.pump();

      expect(calls, [_server]);
      // The tap does not touch the status: only a response clears it.
      expect(find.byKey(_unauthorizedKey), findsOneWidget);
    });

    testWidgets(
      'the rejected banner clears when the status becomes connected',
      (tester) async {
        final c = await _pumpSlot(tester);
        _setStatus(c, HostedConnectionStatus.tokenRejected);
        await tester.pump();
        expect(find.byKey(_unauthorizedKey), findsOneWidget);
        _setStatus(c, HostedConnectionStatus.connected);
        await tester.pump();
        for (final key in _allBannerKeys) {
          expect(find.byKey(key), findsNothing);
        }
      },
    );
  });

  group('vault gone banner', () {
    testWidgets(
      'a vault gone from its server shows the danger banner without a button',
      (tester) async {
        final c = await _pumpSlot(tester);
        _setStatus(c, HostedConnectionStatus.connected);
        c.read(hostedVaultGoneProvider(_vault).notifier).state = true;
        await tester.pump();

        expect(find.byKey(_goneKey), findsOneWidget);
        _expectBannerFrame(
          tester,
          _goneKey,
          fill: OmColors.dangerBg,
          icon: LucideIcons.folderX,
          ink: OmColors.danger,
          text: _goneText,
        );
        expect(
          find.descendant(
            of: find.byKey(_goneKey),
            matching: find.byType(OmButton),
          ),
          findsNothing,
        );
        expect(find.byKey(_unreachableKey), findsNothing);
        expect(find.byKey(_unauthorizedKey), findsNothing);
      },
    );

    testWidgets('a vault gone flag of another vault shows no banner', (
      tester,
    ) async {
      final c = await _pumpSlot(tester);
      _setStatus(c, HostedConnectionStatus.connected);
      c
              .read(
                hostedVaultGoneProvider(
                  const HostedVaultRef(_server, 'other'),
                ).notifier,
              )
              .state =
          true;
      c
              .read(
                hostedVaultGoneProvider(
                  const HostedVaultRef('srv-b', 'work'),
                ).notifier,
              )
              .state =
          true;
      await tester.pump();
      for (final key in _allBannerKeys) {
        expect(find.byKey(key), findsNothing);
      }
    });

    testWidgets('only one hosted banner shows at a time', (tester) async {
      final c = await _pumpSlot(tester);
      c.read(hostedVaultGoneProvider(_vault).notifier).state = true;
      for (final status in [
        HostedConnectionStatus.unreachable,
        HostedConnectionStatus.tokenRejected,
        HostedConnectionStatus.connected,
      ]) {
        _setStatus(c, status);
        await tester.pump();
        final shown = [
          for (final key in _allBannerKeys)
            if (find.byKey(key).evaluate().isNotEmpty) key,
        ];
        expect(shown, hasLength(1), reason: 'status $status');
      }
    });
  });

  group('no banner', () {
    testWidgets(
      'a hosted vault with no outcome or a connected server shows no banner',
      (tester) async {
        final c = await _pumpSlot(tester);
        for (final key in _allBannerKeys) {
          expect(find.byKey(key), findsNothing);
        }
        _setStatus(c, HostedConnectionStatus.connected);
        await tester.pump();
        for (final key in _allBannerKeys) {
          expect(find.byKey(key), findsNothing);
        }
        expect(
          tester.getSize(find.byKey(const Key('stand-in-body'))).height,
          600,
        );
      },
    );

    testWidgets(
      'a status of another server shows no banner for the open vault',
      (tester) async {
        final c = await _pumpSlot(tester);
        c.read(hostedConnectionStatusProvider('srv-other').notifier).state =
            HostedConnectionStatus.unreachable;
        await tester.pump();
        for (final key in _allBannerKeys) {
          expect(find.byKey(key), findsNothing);
        }
        // Switching the open vault to that server shows it.
        c.read(currentVaultProvider.notifier).state = const HostedVaultRef(
          'srv-other',
          'work',
        );
        await tester.pump();
        expect(find.byKey(_unreachableKey), findsOneWidget);
        expect(find.text('can\'t reach srv-other — retrying…'), findsOneWidget);
      },
    );
  });

  group('local vault', () {
    testWidgets(
      'a local vault with an outdated schema keeps the schema banner',
      (tester) async {
        await _pumpSlot(
          tester,
          vault: const LocalVaultRef('/tmp/om-101-vault'),
          schemaOutdated: true,
        );
        expect(find.byKey(const Key('vault-schema-outdated')), findsOneWidget);
        expect(find.text(vaultSchemaOutdatedMessage), findsOneWidget);
        for (final key in _allBannerKeys) {
          expect(find.byKey(key), findsNothing);
        }
      },
    );

    testWidgets('a local vault with a current schema shows no banner', (
      tester,
    ) async {
      await _pumpSlot(tester, vault: const LocalVaultRef('/tmp/om-101-vault'));
      expect(find.byKey(const Key('vault-schema-outdated')), findsNothing);
      for (final key in _allBannerKeys) {
        expect(find.byKey(key), findsNothing);
      }
    });

    testWidgets(
      'a local vault never shows a hosted banner whatever the server status',
      (tester) async {
        final c = await _pumpSlot(
          tester,
          vault: const LocalVaultRef('/tmp/om-101-vault'),
        );
        for (final status in HostedConnectionStatus.values) {
          _setStatus(c, status);
          c.read(hostedVaultGoneProvider(_vault).notifier).state = true;
          await tester.pump();
          for (final key in _allBannerKeys) {
            expect(find.byKey(key), findsNothing, reason: 'status $status');
          }
          expect(find.byKey(const Key('vault-schema-outdated')), findsNothing);
        }
      },
    );

    testWidgets('no open vault shows no banner', (tester) async {
      final c = await _pumpSlot(tester, vault: null);
      _setStatus(c, HostedConnectionStatus.unreachable);
      await tester.pump();
      for (final key in _allBannerKeys) {
        expect(find.byKey(key), findsNothing);
      }
    });
  });
}
