import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'src/screens/vault_picker.dart';
import 'src/screens/workspace.dart';
import 'src/state/agents_sheet/agents_menu_enablement.dart';
import 'src/state/app_exit.dart';
import 'src/state/app_support_dir.dart';
import 'src/state/app_version.dart';
import 'src/state/hosted_identity.dart';
import 'src/state/picker_actions.dart';
import 'src/state/settings.dart';
import 'src/state/spelling_menu_sync.dart';
import 'src/state/vault_open_controller.dart';
import 'src/state/vault_open_hosted.dart';
import 'src/state/vault_state.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/font_setup.dart';
import 'src/widgets/hosted/hosted_bindings.dart';
import 'src/widgets/hosted/leave_confirm_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureFonts();
  final settings = await SettingsController.load();
  // Hosted vaults keep their UI state here (Req 35, D19).
  final appSupport = await getApplicationSupportDirectory();
  // The app's own version for the picker and sidebar labels (never the
  // build number).
  final info = await PackageInfo.fromPlatform();
  runApp(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith((_) => settings),
        appSupportDirProvider.overrideWithValue(appSupport.path),
        appVersionProvider.overrideWithValue(info.version),
        ...appRootOverrides,
      ],
      child: const OpenMemexApp(),
    ),
  );
}

/// The app's navigator key: [OpenMemexApp]'s navigator, and the context
/// the seams that carry no BuildContext show their dialogs over.
final appNavigatorKeyProvider = Provider<GlobalKey<NavigatorState>>(
  (_) => GlobalKey<NavigatorState>(),
);

/// The overrides the app root adds to its [ProviderScope]: the widget-layer
/// wiring of state seams, kept here so state/ imports no widget.
///
/// - `leaveVaultGuardProvider` becomes the switch confirm (#103): with no
///   unsent hosted text (read when the switch is asked for) it allows at
///   once; otherwise it shows the leave confirm and allows only on "switch
///   anyway".
/// - `pickerActionsProvider` becomes [AppPickerActions] (#105): the connect
///   and edit-server dialogs, the open and create on a server dialogs and
///   the set-up sheet.
/// - `updateTokenSeamProvider` (a failed open's "update token") and
///   `hostedUpdateTokenProvider` (the banner's) open the edit-server dialog
///   for that server over the app's navigator.
final List<Override> appRootOverrides = [
  leaveVaultGuardProvider.overrideWith(
    (ref) =>
        (context) => confirmLeave(context, LeaveAction.switchVault, ref.read),
  ),
  pickerActionsProvider.overrideWithValue(const AppPickerActions()),
  updateTokenSeamProvider.overrideWith(_editServerSeam),
  hostedUpdateTokenProvider.overrideWith(_editServerSeam),
];

/// An update-token seam: the picker actions' edit-server dialog for the
/// server, over the app's navigator.
void Function(String serverId) _editServerSeam(Ref ref) =>
    (serverId) => editServerFromAnywhere(
      ref.read(appNavigatorKeyProvider),
      ref.read(pickerActionsProvider),
      serverId,
    );

class OpenMemexApp extends ConsumerStatefulWidget {
  const OpenMemexApp({super.key});

  @override
  ConsumerState<OpenMemexApp> createState() => _OpenMemexAppState();
}

// Launch reopen lives in the vault picker (#92): no vault is open at launch,
// so the picker shows and reopens the last vault through `memex vault check`.
class _OpenMemexAppState extends ConsumerState<OpenMemexApp> {
  late final _navigatorKey = ref.read(appNavigatorKeyProvider);

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
    // The native window title follows the open vault (L21).
    ref.listenManual<String>(
      windowTitleTextProvider,
      (_, title) => ref.read(windowTitleProvider).setTitle(title),
      fireImmediately: true,
    );
    ref.read(spellingMenuSyncProvider); // Spelling menu and tags (#392, D24).
    ref.read(agentsMenuEnablementProvider); // Window ▸ Agents… (#408, D24).
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
