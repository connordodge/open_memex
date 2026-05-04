import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Widget wrap(Widget child, SettingsController settings) {
    return ProviderScope(
      overrides: [settingsProvider.overrideWith((_) => settings)],
      child: MaterialApp(theme: buildOmTheme(), home: child),
    );
  }

  testWidgets('vault picker shows empty state with no recents', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsController.load();

    await tester.pumpWidget(wrap(const VaultPickerScreen(), settings));

    expect(find.text('CHOOSE A VAULT'), findsOneWidget);
    expect(find.byKey(const Key('vault-picker-create')), findsOneWidget);
    expect(find.byKey(const Key('vault-picker-open')), findsOneWidget);
    // No recent vault tiles → no folder icon visible.
    expect(find.byIcon(LucideIcons.folder), findsNothing);
  });

  testWidgets('vault picker shows recent vault tile when settings have one', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'memex.recent_vaults': <String>['/tmp/some-vault-that-does-not-exist'],
    });
    final settings = await SettingsController.load();

    await tester.pumpWidget(wrap(const VaultPickerScreen(), settings));

    expect(find.text('RECENT'), findsOneWidget);
    expect(find.text('some-vault-that-does-not-exist'), findsOneWidget);
    // Path doesn't actually exist as a vault, so it shows the "off" icon.
    expect(find.byIcon(LucideIcons.folderX), findsOneWidget);
  });
}
