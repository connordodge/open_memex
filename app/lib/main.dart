import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/screens/vault_picker.dart';
import 'src/screens/workspace.dart';
import 'src/state/settings.dart';
import 'src/state/vault_state.dart';
import 'src/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await SettingsController.load();
  runApp(
    ProviderScope(
      overrides: [settingsProvider.overrideWith((_) => settings)],
      child: const OpenMemexApp(),
    ),
  );
}

class OpenMemexApp extends ConsumerStatefulWidget {
  const OpenMemexApp({super.key});

  @override
  ConsumerState<OpenMemexApp> createState() => _OpenMemexAppState();
}

// Launch reopen lives in the vault picker (#92): no vault is open at launch,
// so the picker shows and reopens the last vault through `memex vault check`.
class _OpenMemexAppState extends ConsumerState<OpenMemexApp> {
  @override
  Widget build(BuildContext context) {
    final theme = buildOmTheme();
    return MaterialApp(
      title: 'Open Memex',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: theme,
      darkTheme: theme,
      home: const _Router(),
    );
  }
}

class _Router extends ConsumerWidget {
  const _Router();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(currentVaultProvider);
    if (current == null) {
      return const VaultPickerScreen();
    }
    return const Workspace();
  }
}
