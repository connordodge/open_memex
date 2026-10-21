// WI #91 (D18): `hostedVaultsEnabledProvider` defaults OFF
// (`bool.fromEnvironment('MEMEX_HOSTED_VAULTS')`); #105 deletes it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/hosted_vaults_flag.dart';

/// A reader derived from the flag, as hosted UI providers will be.
final _hostedCopy = Provider<String>(
  (ref) => ref.watch(hostedVaultsEnabledProvider) ? 'hosted on' : 'hosted off',
);

void main() {
  test(
    'hostedVaultsEnabledProvider reads false under flutter test with no dart define',
    () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(c.read(hostedVaultsEnabledProvider), isFalse);
      expect(c.read(_hostedCopy), 'hosted off');
    },
  );

  testWidgets(
    'a ProviderScope override of hostedVaultsEnabledProvider to true is seen by readers',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [hostedVaultsEnabledProvider.overrideWithValue(true)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Column(
                children: [
                  Text('flag ${ref.watch(hostedVaultsEnabledProvider)}'),
                  Text(ref.watch(_hostedCopy)),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('flag true'), findsOneWidget);
      expect(find.text('hosted on'), findsOneWidget);
    },
  );
}
