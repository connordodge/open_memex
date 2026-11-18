// WI #32 (Spec #31 req 23, D3): the exit confirmation holder and the
// process-exit seam.
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_exit.dart';

import '../support/updater_fakes.dart';

void main() {
  test(
    'ExitConfirmation starts unconfirmed and reads confirmed after confirm',
    () {
      final confirmation = ExitConfirmation();
      expect(confirmation.confirmed, isFalse);

      confirmation.confirm();
      expect(confirmation.confirmed, isTrue);

      confirmation.confirm();
      expect(confirmation.confirmed, isTrue, reason: 'confirm is idempotent');
    },
  );

  test('each provider container holds its own exit confirmation', () {
    final first = ProviderContainer();
    addTearDown(first.dispose);
    final second = ProviderContainer();
    addTearDown(second.dispose);

    expect(first.read(appExitConfirmationProvider).confirmed, isFalse);
    first.read(appExitConfirmationProvider).confirm();

    expect(first.read(appExitConfirmationProvider).confirmed, isTrue);
    expect(
      identical(
        first.read(appExitConfirmationProvider),
        first.read(appExitConfirmationProvider),
      ),
      isTrue,
      reason: 'one holder per container, so the quit handler sees the mark',
    );
    expect(second.read(appExitConfirmationProvider).confirmed, isFalse);
  });

  testWidgets(
    'appProcessExitProvider defaults to exitApplication and an override receives the exit type',
    (tester) async {
      // The default goes through ServicesBinding.instance.exitApplication.
      // The test binding answers a cancelable exit with cancel and throws on
      // a required one, so a required exit proves the call reached it.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final exit = container.read(appProcessExitProvider);

      expect(await exit(AppExitType.cancelable), AppExitResponse.cancel);
      await expectLater(
        exit(AppExitType.required),
        throwsA(
          isA<FlutterError>().having(
            (e) => e.message,
            'message',
            contains('Unexpected application exit request'),
          ),
        ),
      );

      // A test override receives the type it was called with.
      final recorder = RecordingProcessExit();
      final overridden = ProviderContainer(
        overrides: [appProcessExitProvider.overrideWithValue(recorder.call)],
      );
      addTearDown(overridden.dispose);
      final response = await overridden.read(appProcessExitProvider)(
        AppExitType.required,
      );

      expect(recorder.calls, [AppExitType.required]);
      expect(response, AppExitResponse.exit);
    },
  );
}
