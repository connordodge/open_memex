import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('vault picker shows empty state with no recents', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsController.load();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith((_) => settings)],
        child: const MaterialApp(home: VaultPickerScreen()),
      ),
    );

    expect(find.text('Choose a vault'), findsOneWidget);
    expect(find.byKey(const Key('vault-picker-create')), findsOneWidget);
    expect(find.byKey(const Key('vault-picker-open')), findsOneWidget);
    // No recent vault tiles.
    expect(find.byIcon(Icons.folder), findsNothing);
  });

  testWidgets('vault picker shows recent vault tile when settings have one', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'memex.recent_vaults': <String>['/tmp/some-vault-that-does-not-exist'],
    });
    final settings = await SettingsController.load();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith((_) => settings)],
        child: const MaterialApp(home: VaultPickerScreen()),
      ),
    );

    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('some-vault-that-does-not-exist'), findsOneWidget);
    // Path doesn't actually exist as a vault, so it shows the "off" icon.
    expect(find.byIcon(Icons.folder_off), findsOneWidget);
  });
}
