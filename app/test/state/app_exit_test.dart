// WI #103 (D20, L7, L13): the app-exit seam's platform side. Window close
// arrives natively as `windowShouldClose` on the window method channel and
// Dart replies with the decision; quit arrives as `System.requestAppExit`
// through `AppLifecycleListener.onExitRequested`. The app root attaches the
// seam once. The window title seam (L21) sends `setTitle` on the same
// channel. The native side (MainFlutterWindow.swift) is MANUAL.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/unsent_hosted_text.dart';

import '../support/app_exit_fakes.dart';
import '../support/app_harness.dart';
import '../support/wi363_sidebar.dart';

const _confirm = Key('leave-confirm');
const _cancel = Key('leave-confirm-cancel');
const _proceed = Key('leave-confirm-proceed');

final _unsent = UnsentHostedText(
  serverName: 'nas',
  vaultName: 'memex',
  notes: [
    UnsentHostedNote(
      title: 'hosted vault plan',
      since: DateTime(2026, 10, 20, 14, 32),
    ),
  ],
);

void main() {
  group('window channel windowShouldClose (AC6)', () {
    testWidgets(
      'windowShouldClose with no unsent text replies true at once with no dialog',
      (tester) async {
        await pumpWorkspace(tester);

        final reply = sendWindowShouldClose(tester);
        await tester.pump();

        expect(reply.replied, isTrue);
        expect(reply.decoded, true);
        expect(find.byKey(_confirm), findsNothing);
      },
    );

    testWidgets(
      'windowShouldClose with unsent text waits for the person and replies false on cancel',
      (tester) async {
        await pumpWorkspace(tester, overrides: unsentTextOverrides(_unsent));

        final reply = sendWindowShouldClose(tester);
        await pumpFrames(tester);

        expect(find.byKey(_confirm), findsOneWidget);
        expect(
          find.text("unsaved changes couldn't reach nas. close anyway?"),
          findsOneWidget,
        );
        expect(reply.replied, isFalse);

        await tester.tap(find.byKey(_cancel));
        await pumpFrames(tester);

        expect(reply.replied, isTrue);
        expect(reply.decoded, false);
        expect(find.byKey(_confirm), findsNothing);
      },
    );

    testWidgets(
      'windowShouldClose with unsent text replies true on close anyway',
      (tester) async {
        await pumpWorkspace(tester, overrides: unsentTextOverrides(_unsent));

        final reply = sendWindowShouldClose(tester);
        await pumpFrames(tester);
        expect(reply.replied, isFalse);

        await tester.tap(find.byKey(_proceed));
        await pumpFrames(tester);

        expect(reply.replied, isTrue);
        expect(reply.decoded, true);
      },
    );
  });

  group('quit through onExitRequested (AC1, AC3)', () {
    testWidgets(
      'a requestAppExit with no unsent text answers exit with no dialog',
      (tester) async {
        await pumpWorkspace(tester);

        final reply = sendRequestAppExit(tester);
        await tester.pump();

        expect(reply.replied, isTrue);
        expect(reply.decoded, AppExitResponse.exit.name);
        expect(find.byKey(_confirm), findsNothing);
      },
    );

    testWidgets(
      'a requestAppExit with unsent text shows the quit confirm and answers cancel on cancel',
      (tester) async {
        await pumpWorkspace(tester, overrides: unsentTextOverrides(_unsent));

        final reply = sendRequestAppExit(tester);
        await pumpFrames(tester);

        expect(
          find.text("unsaved changes couldn't reach nas. quit anyway?"),
          findsOneWidget,
        );
        expect(reply.replied, isFalse);

        await tester.tap(find.byKey(_cancel));
        await pumpFrames(tester);

        expect(reply.decoded, AppExitResponse.cancel.name);
      },
    );

    testWidgets(
      'a requestAppExit with unsent text answers exit on quit anyway',
      (tester) async {
        await pumpWorkspace(tester, overrides: unsentTextOverrides(_unsent));

        final reply = sendRequestAppExit(tester);
        await pumpFrames(tester);
        await tester.tap(find.byKey(_proceed));
        await pumpFrames(tester);

        expect(reply.decoded, AppExitResponse.exit.name);
      },
    );
  });

  group('window channel unknown methods (verify)', () {
    testWidgets(
      'an unknown method on the window channel gets not implemented back',
      (tester) async {
        await pumpWorkspace(tester, overrides: unsentTextOverrides(_unsent));
        const codec = StandardMethodCodec();
        var replied = false;
        ByteData? raw;
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          appWindowChannel.name,
          codec.encodeMethodCall(const MethodCall('windowWillMiniaturize')),
          (data) {
            replied = true;
            raw = data;
          },
        );
        await pumpFrames(tester);

        // An empty reply is FlutterMethodNotImplemented on the native side.
        expect(replied, isTrue);
        expect(raw, isNull);
        expect(find.byKey(_confirm), findsNothing);

        // The close request still works after it.
        final close = sendWindowShouldClose(tester);
        await pumpFrames(tester);
        expect(find.byKey(_confirm), findsOneWidget);
        await tester.tap(find.byKey(_cancel));
        await pumpFrames(tester);
        expect(close.decoded, false);
      },
    );
  });

  group('app root registration', () {
    testWidgets(
      'the app root attaches the app-exit seam once and keeps it across a vault switch',
      (tester) async {
        final exit = FakeAppExitHost();
        await pumpWorkspace(
          tester,
          overrides: [appExitHostProvider.overrideWithValue(exit)],
        );
        expect(exit.attachCount, 1);
        expect(exit.isAttached, isTrue);

        wi363LeaveVault(tester);
        await pumpFrames(tester);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await pumpFrames(tester);
        expect(find.byType(VaultPickerScreen), findsOneWidget);

        expect(exit.attachCount, 1);
        expect(exit.detachCount, 0);
        expect(await exit.requestClose(), isTrue);
      },
    );

    testWidgets('unmounting the app detaches the app-exit seam', (
      tester,
    ) async {
      final exit = FakeAppExitHost();
      await pumpWorkspace(
        tester,
        overrides: [appExitHostProvider.overrideWithValue(exit)],
      );
      expect(exit.isAttached, isTrue);

      await tester.pumpWidget(const SizedBox());

      expect(exit.isAttached, isFalse);
      expect(exit.detachCount, 1);
    });

    testWidgets(
      'after the app unmounts the window channel no longer answers windowShouldClose',
      (tester) async {
        await pumpWorkspace(tester);
        final mounted = sendWindowShouldClose(tester);
        await tester.pump();
        expect(mounted.decoded, true);

        await tester.pumpWidget(const SizedBox());

        final reply = sendWindowShouldClose(tester);
        await tester.pump();

        // No Dart handler: the engine gets an empty reply (native then
        // falls back to closing).
        expect(reply.replied, isTrue);
        expect(reply.decoded, isNull);
      },
    );
  });

  group('window title seam (lead decision, L21)', () {
    testWidgets(
      'PlatformWindowTitle sends setTitle with the title on the window channel',
      (tester) async {
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          appWindowChannel,
          (call) async {
            calls.add(call);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            appWindowChannel,
            null,
          ),
        );

        await const PlatformWindowTitle().setTitle('memex · nas');

        expect(calls, hasLength(1));
        expect(calls.single.method, 'setTitle');
        expect(calls.single.arguments, 'memex · nas');
      },
    );

    testWidgets(
      'PlatformWindowTitle does nothing when no native handler is registered',
      (tester) async {
        // A real platform send: it only completes outside fake async.
        Object? error;
        var done = false;
        await tester.runAsync(() async {
          try {
            await const PlatformWindowTitle()
                .setTitle('memex')
                .timeout(const Duration(seconds: 5));
            done = true;
          } catch (e) {
            error = e;
          }
        });
        expect(error, isNull);
        expect(done, isTrue);
      },
    );
  });
}
