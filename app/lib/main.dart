import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/screens/vault_picker.dart';
import 'src/screens/workspace.dart';
import 'src/state/app_exit.dart';
import 'src/state/settings.dart';
import 'src/state/vault_state.dart';
import 'src/theme/app_theme.dart';
import 'src/widgets/hosted/leave_confirm_dialog.dart';

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
  final _navigatorKey = GlobalKey<NavigatorState>();

  /// The app-exit seam, attached once for the app's life (vault switches
  /// keep it) and detached on unmount.
  late final AppExitHost _exitHost;

  /// A window close was allowed. The app then terminates, and the quit that
  /// follows once the window is gone must not ask again.
  bool _closeAllowed = false;

  @override
  void initState() {
    super.initState();
    _exitHost = ref.read(appExitHostProvider)
      ..attach(onWindowClose: _onWindowClose, onQuit: _onQuit);
  }

  @override
  void dispose() {
    _exitHost.detach();
    super.dispose();
  }

  Future<bool> _onWindowClose() async {
    final allowed = await confirmLeave(
      _navigatorKey.currentContext!,
      LeaveAction.close,
      ref.read,
    );
    if (allowed) _closeAllowed = true;
    return allowed;
  }

  Future<AppExitResponse> _onQuit() async {
    if (_closeAllowed) return AppExitResponse.exit;
    final allowed = await confirmLeave(
      _navigatorKey.currentContext!,
      LeaveAction.quit,
      ref.read,
    );
    return allowed ? AppExitResponse.exit : AppExitResponse.cancel;
  }

  @override
  Widget build(BuildContext context) {
    final theme = buildOmTheme();
    return MaterialApp(
      navigatorKey: _navigatorKey,
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
