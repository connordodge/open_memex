// WI #408 (EP; Spec #394 req 5; D24): `agentsMenuEnablementProvider` keeps
// Window ▸ Agents… (and with it ⇧⌘A) in step with the open vault. It
// listens to `currentVaultProvider` from its own provider (vault_state.dart
// is not edited) and sends `setAgentsMenuEnabled` through
// `windowMenuHostProvider`: false at launch while no vault is open, true on
// every open, false on every close. The app root attaches it with one
// appended line in main.dart, so the app-level tests pump the real
// OpenMemexApp through the journey harness.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/agents_sheet/agents_menu_enablement.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/journey_harness.dart';
import '../support/vault_folders.dart';
import '../support/window_menu_fakes.dart';

/// Vault refs built from run-time values (not const), so the ref
/// constructors run.
LocalVaultRef _wi408Local(String name) => LocalVaultRef('/vaults/408/$name');
HostedVaultRef _wi408Hosted(String name) => HostedVaultRef('srv-408', name);

/// A container whose `windowMenuHostProvider` is a fresh
/// [FakeWindowMenuHost], with [vault] open (none by default). The
/// enablement is not read yet.
({ProviderContainer container, FakeWindowMenuHost menu}) _wi408Container({
  VaultRef? vault,
}) {
  final menu = FakeWindowMenuHost();
  final c = ProviderContainer(
    overrides: [windowMenuHostProvider.overrideWithValue(menu)],
  );
  addTearDown(c.dispose);
  if (vault != null) c.read(currentVaultProvider.notifier).state = vault;
  return (container: c, menu: menu);
}

void _wi408SetVault(ProviderContainer c, VaultRef? v) =>
    c.read(currentVaultProvider.notifier).state = v;

void main() {
  holdFontFetches();

  group('enablement follows the open vault (AC enablement order)', () {
    test(
      'with no vault open the enablement sends setAgentsMenuEnabled false once at launch',
      () async {
        final s = _wi408Container();
        expect(s.menu.enabledCalls, isEmpty);
        s.container.read(agentsMenuEnablementProvider);
        await pumpEventQueue();
        expect(s.menu.enabledCalls, [false]);
        expect(s.menu.enabled, isFalse);
      },
    );

    test(
      'opening a vault sends true and closing it sends false in order',
      () async {
        final s = _wi408Container();
        s.container.read(agentsMenuEnablementProvider);
        await pumpEventQueue();

        _wi408SetVault(s.container, _wi408Local('alpha'));
        await pumpEventQueue();
        expect(s.menu.enabledCalls, [false, true]);
        expect(s.menu.enabled, isTrue);

        _wi408SetVault(s.container, null);
        await pumpEventQueue();
        expect(s.menu.enabledCalls, [false, true, false]);
        expect(s.menu.enabled, isFalse);
      },
    );

    test(
      'reopening a vault after a close sends true again so the calls read false true false true',
      () async {
        final s = _wi408Container();
        s.container.read(agentsMenuEnablementProvider);
        await pumpEventQueue();

        _wi408SetVault(s.container, _wi408Local('alpha'));
        await pumpEventQueue();
        _wi408SetVault(s.container, null);
        await pumpEventQueue();
        _wi408SetVault(s.container, _wi408Local('alpha'));
        await pumpEventQueue();

        expect(s.menu.enabledCalls, [false, true, false, true]);
        expect(s.menu.enabled, isTrue);
      },
    );

    test(
      'opening a hosted vault sends true and closing it sends false',
      () async {
        final s = _wi408Container();
        s.container.read(agentsMenuEnablementProvider);
        await pumpEventQueue();

        _wi408SetVault(s.container, _wi408Hosted('studio'));
        await pumpEventQueue();
        expect(s.menu.enabledCalls, [false, true]);

        _wi408SetVault(s.container, null);
        await pumpEventQueue();
        expect(s.menu.enabledCalls, [false, true, false]);
      },
    );

    test(
      'switching straight from one open vault to another never sends false and leaves the menu enabled',
      () async {
        final s = _wi408Container();
        s.container.read(agentsMenuEnablementProvider);
        await pumpEventQueue();
        _wi408SetVault(s.container, _wi408Local('alpha'));
        await pumpEventQueue();
        expect(s.menu.enabledCalls, [false, true]);

        _wi408SetVault(s.container, _wi408Local('bravo'));
        await pumpEventQueue();
        _wi408SetVault(s.container, _wi408Hosted('studio'));
        await pumpEventQueue();

        expect(
          s.menu.enabledCalls.skip(1),
          everyElement(isTrue),
          reason: 'no false between two open vaults: ${s.menu.enabledCalls}',
        );
        expect(s.menu.enabled, isTrue);
      },
    );

    test(
      'attached while a vault is already open the enablement sends true and no false',
      () async {
        final s = _wi408Container(vault: _wi408Local('alpha'));
        s.container.read(agentsMenuEnablementProvider);
        await pumpEventQueue();
        expect(s.menu.enabledCalls, [true]);
      },
    );

    test(
      'reading the enablement again sends no second setAgentsMenuEnabled',
      () async {
        final s = _wi408Container();
        s.container.read(agentsMenuEnablementProvider);
        await pumpEventQueue();
        s.container.read(agentsMenuEnablementProvider);
        await pumpEventQueue();
        expect(s.menu.enabledCalls, [false]);

        _wi408SetVault(s.container, _wi408Local('alpha'));
        await pumpEventQueue();
        s.container.read(agentsMenuEnablementProvider);
        await pumpEventQueue();
        expect(s.menu.enabledCalls, [false, true]);
      },
    );
  });

  group('native error reply (AC enablement order)', () {
    testWidgets(
      'a native error on setAgentsMenuEnabled raises no uncaught error and later opens and closes still send',
      (tester) async {
        // The real PlatformWindowMenuHost passes a native PlatformException
        // on (#407). The enablement fires its calls from a listener, so an
        // escaping error would reach the test zone and fail this test.
        final sent = <Object?>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(appWindowChannel, (call) async {
          if (call.method == 'setAgentsMenuEnabled') sent.add(call.arguments);
          throw PlatformException(code: 'menu_failed', message: 'nope');
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(appWindowChannel, null),
        );

        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.read(agentsMenuEnablementProvider);
        await tester.pump();
        _wi408SetVault(c, _wi408Local('alpha'));
        await tester.pump();
        _wi408SetVault(c, null);
        await tester.pump();
        _wi408SetVault(c, _wi408Local('alpha'));
        await tester.pump();

        expect(sent, [false, true, false, true]);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('native error is logged (AC enablement order)', () {
    testWidgets(
      'a native error on setAgentsMenuEnabled is logged once per failed call with the value sent',
      (tester) async {
        final logs = <String>[];
        final oldDebugPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) =>
            logs.add(message ?? '');
        // Restored in the body: the framework's invariant check runs before
        // addTearDown callbacks.
        void restore() => debugPrint = oldDebugPrint;

        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(appWindowChannel, (call) async {
          throw PlatformException(code: 'menu_failed', message: 'nope');
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(appWindowChannel, null),
        );

        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.read(agentsMenuEnablementProvider);
        await tester.pump();
        expect(logs, hasLength(1));
        expect(logs.single, contains('setAgentsMenuEnabled(false)'));
        expect(logs.single, contains('menu_failed'));

        _wi408SetVault(c, _wi408Local('alpha'));
        await tester.pump();
        expect(logs, hasLength(2));
        expect(logs.last, contains('setAgentsMenuEnabled(true)'));
        restore();
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('the app root attaches it (AC enablement order)', () {
    testWidgets(
      'the running app sends setAgentsMenuEnabled false at launch before the last vault reopens then true then false on close and true on reopen',
      (tester) async {
        final vault = createVaultFolder('om408_menu_');
        final ref = LocalVaultRef(vault.path);
        final menu = FakeWindowMenuHost();
        final app = await pumpJourneyApp(
          tester,
          db: FakeVaultDb.v5(),
          clock: FakeClock(),
          recents: [ref],
          lastVault: ref,
          overrides: [windowMenuHostProvider.overrideWithValue(menu)],
        );

        // Launch reopened the last vault: false went first (no vault yet),
        // then true once it opened.
        expect(app.read(currentVaultProvider), ref);
        expect(menu.enabledCalls, [false, true]);

        // Switch vault: leave for the picker (clears the last vault, so the
        // picker does not reopen it).
        journeyFire(
          app.controller.leaveVault(tester.element(find.byType(Workspace))),
        );
        await app.settle();
        expect(app.read(currentVaultProvider), isNull);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(menu.enabledCalls, [false, true, false]);

        // Open it again from the picker's controller.
        journeyFire(app.controller.openVault(ref));
        await app.settle();
        expect(app.read(currentVaultProvider), ref);
        expect(menu.enabledCalls, [false, true, false, true]);
      },
    );
  });
}
