// WI #325 (A4, D24): the Backups sheet, every local and hosted state (Spec
// #315 reqs 19-22a, 25, 26, 31, 31b, 37; design pack
// design/315-vault-backups/packs/325.md, option B). The sheet renders the
// controller's view state and calls the controller and the settings save; it
// holds no schedule, CLI or polling logic.
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../../state/backup_controller.dart';
import '../../state/backup_destinations.dart';
import '../../state/backup_messages.dart';
import '../../state/backup_models.dart';
import '../../state/backup_settings_state.dart';
import '../../state/clock.dart';
import '../../state/settings.dart';
import '../../state/vault_open_hosted.dart' show hostedUnreachableMessage;
import '../../state/vault_ref.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import '../memex_too_old_dialog.dart' show locateMemexBinary;
import 'backup_keys.dart';

part 'backups_sheet_copy.dart';
part 'backups_sheet_widgets.dart';

// Local Keys the design adds (pack 325, "Mismatches").
const _closeKey = Key('backups-close');
const _cancelKey = Key('backups-cancel');
const _turnOnKey = Key('backups-turn-on');
const _menuKey = Key('backups-destination-menu');
const _keepDecKey = Key('backups-keep-dec');
const _keepIncKey = Key('backups-keep-inc');
const _copyCommandKey = Key('backups-copy-command');
const _guideLinkKey = Key('backups-guide-link');
const _closeButtonKey = Key('backups-close-button');

/// Opens the Backups sheet for [vault] (the setup-sheet pattern: a 620-wide
/// panel). Completes when the sheet closes (the close button, Escape or a
/// tap outside). Tells the controller the sheet opened and closed, which
/// scopes a hosted vault's status poll.
Future<void> showBackupsSheet(BuildContext context, VaultRef vault) async {
  // The dialog is built under the root navigator, outside the caller's
  // subtree: hand it the caller's container.
  final container = ProviderScope.containerOf(context, listen: false);
  final controller = container.read(backupControllerProvider.notifier);
  controller.openSheet(vault);
  try {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'close',
      barrierColor: OmColors.surface0.withAlpha(184),
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, _, _) => UncontrolledProviderScope(
        container: container,
        child: _BackupsSheet(vault: vault),
      ),
      transitionBuilder: (context, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    );
  } finally {
    if (controller.mounted) controller.closeSheet(vault);
  }
}

class _BackupsSheet extends ConsumerStatefulWidget {
  const _BackupsSheet({required this.vault});

  final VaultRef vault;

  @override
  ConsumerState<_BackupsSheet> createState() => _BackupsSheetState();
}

class _BackupsSheetState extends ConsumerState<_BackupsSheet> {
  /// "turn on backups…" was pressed in the off state: the destination list
  /// shows until "turn on backups" or "cancel".
  bool _picking = false;

  /// "cancel" was pressed on a picking state the controller reports.
  bool _pickCancelled = false;

  /// The destinations discovery found, for the picking list and the menu
  /// when the view state lists none.
  List<BackupDestinationOption>? _discovered;

  /// The selected provider row's path.
  String? _selectedPath;

  /// "choose folder…" is the selected row (with [_chosenFolder]).
  bool _chooseSelected = false;

  /// The folder "choose folder…" picked while picking.
  String? _chosenFolder;

  /// This sheet's `backUpNow` call is still running.
  bool _pending = false;

  /// A run was started from this sheet (its failure reads "back up now
  /// failed"), and when.
  bool _pressed = false;
  DateTime? _pressedAt;

  /// When the running backup started, if this sheet saw it start.
  DateTime? _startedAt;

  bool _menuOpen = false;
  OverlayPortalController _menu = OverlayPortalController();
  final _menuLink = LayerLink();
  final _menuGroup = Object();

  late final TextEditingController _keepText;
  final _keepFocus = FocusNode(debugLabel: 'backups keep');

  String? get _path => widget.vault.localPath;

  @override
  void initState() {
    super.initState();
    final path = _path;
    _keepText = TextEditingController(
      text: path == null
          ? ''
          : '${ref.read(vaultBackupSettingsProvider(path)).keep}',
    );
    _keepFocus.addListener(_onKeepFocus);
  }

  @override
  void dispose() {
    _keepFocus.removeListener(_onKeepFocus);
    _keepFocus.dispose();
    _keepText.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- actions

  VaultBackupSettings _stored(String path) =>
      ref.read(vaultBackupSettingsProvider(path));

  Future<void> _save(VaultBackupSettings settings) =>
      ref.read(saveVaultBackupSettingsProvider)(_path!, settings);

  Future<void> _runBackup() async {
    if (_pending) return;
    setState(() {
      _pending = true;
      _pressed = true;
      _pressedAt = ref.read(clockProvider).now();
    });
    try {
      await ref.read(backupControllerProvider.notifier).backUpNow(widget.vault);
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  /// Notes when a run this sheet sees start began: the press time for a
  /// run this sheet started, else the moment the state turned to backing
  /// up. A sheet opened mid-run does not know, and shows no start time.
  void _onViewChange(
    Map<VaultRef, BackupViewState>? before,
    Map<VaultRef, BackupViewState> after,
  ) {
    if (before == null) return;
    final was = before[widget.vault]?.mode;
    final mode = ref
        .read(backupControllerProvider.notifier)
        .viewStateOf(widget.vault)
        .mode;
    if (was == mode) return;
    DateTime? started;
    if (mode == BackupSheetMode.backingUp) {
      started = _pending ? _pressedAt : ref.read(clockProvider).now();
    }
    setState(() => _startedAt = started);
  }

  Future<void> _discover() async {
    final found = await discoverBackupDestinations(
      ref.read(cloudFolderProbeProvider),
    );
    if (mounted) setState(() => _discovered = found);
  }

  void _startPicking() {
    setState(() {
      _picking = true;
      _pickCancelled = false;
      _selectedPath = null;
      _chooseSelected = false;
      _chosenFolder = null;
    });
    _discover();
  }

  void _cancelPicking() => setState(() {
    _picking = false;
    _pickCancelled = true;
  });

  void _selectProvider(String path) => setState(() {
    _selectedPath = path;
    _chooseSelected = false;
  });

  Future<void> _pickFolder() async {
    final folder = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where backups go',
    );
    if (folder == null || !mounted) return;
    setState(() {
      _chosenFolder = folder;
      _chooseSelected = true;
    });
  }

  void _turnOnBackups(String destination) {
    final path = _path!;
    setState(() {
      _picking = false;
      _pickCancelled = false;
    });
    _save(_stored(path).copyWith(enabled: true, destination: destination));
  }

  void _turnOffBackups() {
    final path = _path!;
    _closeMenu();
    setState(() => _picking = false);
    _save(_stored(path).copyWith(enabled: false));
  }

  void _toggleAutomatic() {
    final current = _stored(_path!);
    _save(current.copyWith(automatic: !current.automatic));
  }

  void _stepKeep(int delta) {
    final current = _stored(_path!);
    final next = (current.keep + delta).clamp(backupKeepMin, backupKeepMax);
    if (next == current.keep) return;
    _keepText.text = '$next';
    _save(current.copyWith(keep: next));
  }

  void _onKeepFocus() {
    if (!_keepFocus.hasFocus) _commitKeep();
  }

  /// Saves the typed keep count when it is a whole number in 1-365 and
  /// differs from the stored one; otherwise the field shows the stored one.
  void _commitKeep() {
    final path = _path;
    if (!mounted || path == null) return;
    final current = _stored(path);
    final typed = int.tryParse(_keepText.text.trim());
    if (typed == null || typed < backupKeepMin || typed > backupKeepMax) {
      _keepText.text = '${current.keep}';
      return;
    }
    _keepText.text = '$typed';
    if (typed != current.keep) _save(current.copyWith(keep: typed));
  }

  void _openMenu() {
    _menu.show();
    setState(() => _menuOpen = true);
    _discover();
  }

  void _closeMenu() {
    if (_menu.isShowing) _menu.hide();
    if (_menuOpen) setState(() => _menuOpen = false);
  }

  void _menuSelect(String destination) {
    _closeMenu();
    final current = _stored(_path!);
    if (destination == current.destination) return;
    _save(current.copyWith(destination: destination));
  }

  Future<void> _menuChooseFolder() async {
    _closeMenu();
    final folder = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where backups go',
    );
    if (folder == null || !mounted) return;
    _menuSelect(folder);
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    ref.watch(backupControllerProvider);
    ref.listen(backupControllerProvider, _onViewChange);
    final view = ref
        .read(backupControllerProvider.notifier)
        .viewStateOf(widget.vault);
    final now = ref.watch(clockProvider).now();
    final app = ref.watch(settingsProvider);
    final vault = widget.vault;

    final String eyebrow;
    final Widget body;
    switch (vault) {
      case LocalVaultRef(:final path):
        ref.listen(vaultBackupSettingsProvider(path), (_, next) {
          if (!_keepFocus.hasFocus) _keepText.text = '${next.keep}';
        });
        final inFlight = ref.watch(backupInFlightProvider).contains(path);
        eyebrow = 'BACKUPS · ${p.basename(path).toUpperCase()}';
        body = _localBody(view, now, app, path, busy: _pending || inFlight);
      case HostedVaultRef(:final serverId, :final vaultName):
        final server = _serverName(app, serverId);
        eyebrow =
            'BACKUPS · ${vaultName.toUpperCase()} · ${server.toUpperCase()}';
        body = _hostedBody(view, now, server, vaultName);
    }
    return _shell(context, eyebrow, body);
  }

  static String _serverName(AppSettings app, String serverId) {
    for (final server in app.savedServers) {
      if (server.id == serverId) return server.name;
    }
    return serverId;
  }

  Widget _shell(BuildContext context, String eyebrow, Widget body) {
    final window = MediaQuery.sizeOf(context);
    final width = math.max(0.0, math.min(620.0, window.width - 32));
    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: window.height),
          child: SizedBox(
            width: width,
            child: DecoratedBox(
              key: backupsSheetKey,
              decoration: BoxDecoration(
                color: OmColors.surface2,
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(10),
                ),
                border: Border.all(color: OmColors.line2),
                boxShadow: const [
                  BoxShadow(
                    color: OmColors.dialogShadow,
                    offset: Offset(0, 24),
                    blurRadius: 64,
                  ),
                ],
              ),
              child: Actions(
                // Escape closes the open destination menu first.
                actions: _menuOpen
                    ? {
                        DismissIntent: CallbackAction<DismissIntent>(
                          onInvoke: (_) {
                            _closeMenu();
                            return null;
                          },
                        ),
                      }
                    : const <Type, Action<Intent>>{},
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 21, 24, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 24),
                        child: Row(
                          children: [
                            Expanded(child: _eyebrow(eyebrow)),
                            const SizedBox(width: 8),
                            _IconBtn(
                              key: _closeKey,
                              icon: LucideIcons.x,
                              iconSize: 14,
                              label: 'close',
                              onTap: () => Navigator.of(context).pop(),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Flexible(child: SingleChildScrollView(child: body)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------- local

  Widget _localBody(
    BackupViewState view,
    DateTime now,
    AppSettings app,
    String path, {
    required bool busy,
  }) {
    final stored = ref.watch(vaultBackupSettingsProvider(path));
    final mode = view.mode;
    final off =
        mode == BackupSheetMode.off ||
        mode == BackupSheetMode.pickingDestination;
    if (off && _menuOpen) {
      // The menu's row is gone: forget the menu.
      _menuOpen = false;
      _menu = OverlayPortalController();
    }
    final picking =
        (mode == BackupSheetMode.off && _picking) ||
        (mode == BackupSheetMode.pickingDestination && !_pickCancelled);
    if (picking) return _pickingBody(view, stored);
    if (off) return _offView();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _localCard(view, now, app, stored, busy: busy),
        const SizedBox(height: 20),
        _eyebrow(_settingsEyebrow),
        const SizedBox(height: 8),
        _Group(
          children: [
            _destinationRow(view, stored),
            _keepRow(stored),
            _automaticRow(stored),
          ],
        ),
        const SizedBox(height: 14),
        if (_menuOpen)
          _small(_oldFolderNote)
        else
          Row(
            children: [
              Flexible(child: _small(_req25)),
              const SizedBox(width: 16),
              _SheetButton(
                key: backupsToggleKey,
                kind: OmButtonKind.ghost,
                small: true,
                label: _turnOff,
                onPressed: _turnOffBackups,
              ),
            ],
          ),
      ],
    );
  }

  Widget _offView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusCard(
          tone: _Tone.normal,
          icon: LucideIcons.archive,
          title: _offTitle,
          body: [_small(_offBody)],
          action: _CardAction(
            key: backupsToggleKey,
            label: _turnOnEllipsis,
            onPressed: _startPicking,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          _offLead,
          style: OmType.sans(size: 13, height: 1.55, color: OmColors.fg2),
        ),
      ],
    );
  }

  /// The provider rows to list: the view state's, else discovery's.
  List<BackupDestinationOption> _providerOptions(BackupViewState view) {
    final source = view.options.isNotEmpty
        ? view.options
        : (_discovered ?? const <BackupDestinationOption>[]);
    return [
      for (final option in source)
        if (option.provider != null && option.path != null) option,
    ];
  }

  /// Each provider option with its Key (`<i>` counts within a provider).
  static List<(BackupDestinationOption, Key)> _keyed(
    List<BackupDestinationOption> options,
  ) {
    final seen = <BackupProvider, int>{};
    return [
      for (final option in options)
        (
          option,
          backupDestinationKey(
            option.provider!,
            seen[option.provider!] = (seen[option.provider!] ?? -1) + 1,
          ),
        ),
    ];
  }

  Widget _pickingBody(BackupViewState view, VaultBackupSettings stored) {
    final options = _keyed(_providerOptions(view));
    final selection = _chooseSelected ? _chosenFolder : _selectedPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusCard(
          tone: _Tone.normal,
          icon: LucideIcons.archive,
          title: _pickTitle,
          body: [_small(_pickBody)],
        ),
        const SizedBox(height: 20),
        _eyebrow(_settingsEyebrow),
        const SizedBox(height: 8),
        _Group(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_destinationLabel, style: _labelStyle),
                  _small(options.isEmpty ? _noProviderSub : _foundOnThisMac),
                  const SizedBox(height: 8),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: OmColors.line2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(1),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final (option, key) in options) ...[
                              _OptionRow(
                                key: key,
                                name: option.label,
                                path: _whereOf(option.path!).relative,
                                selected:
                                    !_chooseSelected &&
                                    _selectedPath == option.path,
                                onTap: () => _selectProvider(option.path!),
                              ),
                              Container(height: 1, color: OmColors.line1),
                            ],
                            _OptionRow(
                              key: backupsDestinationChooseKey,
                              name: _chooseFolder,
                              path: _chosenFolder ?? _chooseFolderSub,
                              selected: _chooseSelected,
                              onTap: _pickFolder,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (options.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _small(_pickNote),
                  ],
                ],
              ),
            ),
            _keepRow(stored),
            _automaticRow(stored),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _SheetButton(
              key: _cancelKey,
              kind: OmButtonKind.ghost,
              label: _cancel,
              onPressed: _cancelPicking,
            ),
            const SizedBox(width: 8),
            _SheetButton(
              key: _turnOnKey,
              label: _turnOn,
              onPressed: selection == null
                  ? null
                  : () => _turnOnBackups(selection),
            ),
          ],
        ),
      ],
    );
  }

  _CardAction _nowAction(BackupViewState view, {required bool busy}) {
    final running = view.mode == BackupSheetMode.backingUp;
    return _CardAction(
      key: backupsNowKey,
      label: running ? _backingUpTitle : _backUpNow,
      onPressed:
          busy || running || view.mode == BackupSheetMode.hostedUnreachable
          ? null
          : _runBackup,
    );
  }

  _CardAction _retryAction({required bool busy, IconData? icon}) => _CardAction(
    key: backupsRetryKey,
    label: _retry,
    icon: icon,
    onPressed: busy ? null : _runBackup,
  );

  Widget _localCard(
    BackupViewState view,
    DateTime now,
    AppSettings app,
    VaultBackupSettings stored, {
    required bool busy,
  }) {
    final status = view.status;
    final destination = stored.destination;
    switch (view.mode) {
      case BackupSheetMode.backingUp:
        final started = _startedAt;
        return _StatusCard(
          tone: _Tone.running,
          icon: LucideIcons.loaderCircle,
          title: _backingUpTitle,
          body: [
            _small(
              '${started == null ? '' : _startedLine(started)}$_backingUpBody',
            ),
          ],
          action: _nowAction(view, busy: busy),
        );
      case BackupSheetMode.success:
        final at = status?.lastFileCreatedAt ?? status?.lastSuccessAt;
        final file = status?.lastFile;
        final saved = destination == null
            ? null
            : _savedLine(status?.lastBytes, destination, compact: _menuOpen);
        return _StatusCard(
          tone: _Tone.ok,
          icon: LucideIcons.check,
          title: at == null ? 'backed up' : 'backed up ${backupWhen(at, now)}',
          body: [
            if (file != null && !_menuOpen) _fileName(file),
            if (saved != null) ...[
              if (file != null && !_menuOpen) const SizedBox(height: 6),
              _small(saved),
            ],
          ],
          action: _nowAction(view, busy: busy),
        );
      case BackupSheetMode.error:
        final message = backupFailureMessage(
          code: view.errorCode ?? status?.lastResult ?? 'internal',
          message: status?.lastError,
          automatic: !_pressed,
          failedAt: status?.lastAttemptAt ?? now,
          now: now,
          destination: destination,
          provider: destination == null ? null : _whereOf(destination).provider,
        );
        return _StatusCard(
          tone: _Tone.error,
          icon: LucideIcons.triangleAlert,
          title: message.title,
          body: [
            _paragraph(view.message ?? message.detail),
            const SizedBox(height: 6),
            _small(_lastGoodLine(status, now, retries: stored.automatic)),
          ],
          action: _retryAction(busy: busy, icon: LucideIcons.refreshCw),
        );
      case BackupSheetMode.memexTooOld || BackupSheetMode.binaryNotFound:
        final message = view.mode == BackupSheetMode.memexTooOld
            ? backupTooOldMessage()
            : backupBinaryNotFoundMessage();
        final binary = app.memexBinaryPath;
        return _StatusCard(
          tone: _Tone.error,
          icon: LucideIcons.triangleAlert,
          title: message.title,
          body: [
            _paragraph(view.message ?? message.detail),
            if (binary != null) Text(binary, style: _monoSubStyle),
            const SizedBox(height: 10),
            _SheetButton(
              kind: OmButtonKind.ghost,
              small: true,
              label: _locateBinary,
              onPressed: () =>
                  locateMemexBinary(ref.read(settingsProvider.notifier)),
            ),
          ],
          action: _retryAction(busy: busy),
        );
      case _:
        return _StatusCard(
          tone: _Tone.normal,
          icon: LucideIcons.archive,
          title: _neverTitle,
          body: [if (stored.automatic) _small(_neverBody)],
          action: _nowAction(view, busy: busy),
        );
    }
  }

  Widget _destinationRow(BackupViewState view, VaultBackupSettings stored) {
    final destination = stored.destination;
    final where = destination == null ? null : _whereOf(destination);
    final label = where?.label ?? _chooseFolder;
    final current = destination;
    final options = _keyed(_providerOptions(view));
    return _SettingRow(
      label: _destinationLabel,
      sub: where?.relative ?? '',
      subMono: true,
      controlWidth: _DestinationButton.widthFor(context, label),
      control: TapRegion(
        groupId: _menuGroup,
        child: OverlayPortal(
          controller: _menu,
          overlayChildBuilder: (context) => Positioned(
            width: 300,
            child: CompositedTransformFollower(
              link: _menuLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 13),
              child: TapRegion(
                groupId: _menuGroup,
                onTapOutside: (_) => _closeMenu(),
                child: Material(
                  type: MaterialType.transparency,
                  child: _MenuPanel(
                    providers: [
                      for (final (option, key) in options)
                        _MenuItem(
                          key: key,
                          label: option.label,
                          current: option.path == current,
                          onTap: () => _menuSelect(option.path!),
                        ),
                    ],
                    choose: _MenuItem(
                      key: backupsDestinationChooseKey,
                      label: _chooseFolder,
                      current: false,
                      onTap: _menuChooseFolder,
                    ),
                  ),
                ),
              ),
            ),
          ),
          child: CompositedTransformTarget(
            link: _menuLink,
            child: _DestinationButton(
              label: label,
              provider: where?.provider != null,
              onPressed: _menuOpen ? _closeMenu : _openMenu,
            ),
          ),
        ),
      ),
    );
  }

  Widget _keepRow(VaultBackupSettings stored) => _SettingRow(
    label: _keepLabel,
    sub: _keepSub,
    controlWidth: _KeepStepper.width,
    control: _KeepStepper(
      keep: stored.keep,
      controller: _keepText,
      focusNode: _keepFocus,
      onStep: _stepKeep,
      onSubmit: _commitKeep,
    ),
  );

  Widget _automaticRow(VaultBackupSettings stored) => _SettingRow(
    label: _automaticLabel,
    sub: _automaticSub,
    controlWidth: 32,
    control: _Switch(
      key: backupsAutomaticKey,
      value: stored.automatic,
      label: _automaticLabel,
      onChanged: _toggleAutomatic,
    ),
  );

  // -------------------------------------------------------------- hosted

  Widget _hostedBody(
    BackupViewState view,
    DateTime now,
    String server,
    String vaultName,
  ) {
    final status = view.status;
    final busy = _pending;
    switch (view.mode) {
      case BackupSheetMode.hostedNotConfigured:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusCard(
              tone: _Tone.normal,
              icon: LucideIcons.server,
              title: _notConfiguredTitle,
              body: [_small(_notConfiguredBody(server, vaultName))],
            ),
            const SizedBox(height: 8),
            const _CommandRow(),
            const SizedBox(height: 20),
            const _GuideFooter(),
          ],
        );
      case BackupSheetMode.hostedUnreachable:
        return _StatusCard(
          tone: _Tone.warn,
          alertBorder: true,
          icon: LucideIcons.wifiOff,
          title: hostedUnreachableMessage(server),
          body: [_small(_unreachableBody(server))],
          action: _nowAction(view, busy: busy),
        );
      case BackupSheetMode.hostedServerTooOld:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusCard(
              tone: _Tone.warn,
              icon: LucideIcons.server,
              title: _tooOldTitle(server),
              body: [_small(_tooOldBody(server))],
            ),
            const SizedBox(height: 20),
            const _GuideFooter(),
          ],
        );
      case _:
        // The note shows with a result (B3-1); not while running or after a
        // failure (B3-2, B3-3).
        final note =
            view.mode == BackupSheetMode.success ||
            view.mode == BackupSheetMode.neverBackedUp;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _hostedCard(view, now, server, busy: busy),
            const SizedBox(height: 20),
            _eyebrow('ON ${server.toUpperCase()}'),
            const SizedBox(height: 8),
            _Group(
              children: [
                _ReadOnlyRow(
                  label: 'backup folder',
                  value: 'set on $server with --backup-dir',
                ),
                _ReadOnlyRow(
                  label: _keepLabel,
                  value: 'latest ${status?.keep ?? backupKeepDefault}',
                ),
                _ReadOnlyRow(
                  label: 'schedule',
                  value: 'once a day when $vaultName changed',
                ),
              ],
            ),
            if (note) ...[const SizedBox(height: 14), _small(_hostedNote)],
          ],
        );
    }
  }

  Widget _hostedCard(
    BackupViewState view,
    DateTime now,
    String server, {
    required bool busy,
  }) {
    final status = view.status;
    final at = status?.lastFileCreatedAt ?? status?.lastSuccessAt;
    final hasBackup = status != null && status.hasBackup && at != null;
    switch (view.mode) {
      case BackupSheetMode.backingUp:
        final last = hasBackup
            ? ' last backup: ${_whenAndSize(at, status.lastBytes, now)}.'
            : '';
        return _StatusCard(
          tone: _Tone.running,
          icon: LucideIcons.loaderCircle,
          title: _hostedBackingUpTitle(server),
          body: [_small('${_hostedBackingUpBody(server)}$last')],
          action: _nowAction(view, busy: busy),
        );
      case BackupSheetMode.success when hasBackup:
        final file = status.lastFile;
        return _StatusCard(
          tone: _Tone.ok,
          icon: LucideIcons.check,
          title: 'backed up ${backupWhen(at, now)}',
          body: [
            if (file != null) ...[_fileName(file), const SizedBox(height: 6)],
            _small('${_sizePrefix(status.lastBytes)}on $server'),
          ],
          action: _nowAction(view, busy: busy),
        );
      case BackupSheetMode.error:
        final message = backupFailureMessage(
          code: view.errorCode ?? status?.lastResult ?? 'internal',
          message: status?.lastError,
          automatic: !_pressed,
          failedAt: status?.lastAttemptAt ?? now,
          now: now,
          serverName: server,
        );
        return _StatusCard(
          tone: _Tone.error,
          icon: LucideIcons.triangleAlert,
          title: message.title,
          body: [
            _paragraph(view.message ?? message.detail),
            const SizedBox(height: 6),
            _small(_lastGoodLine(status, now, server: server, retries: true)),
          ],
          action: _retryAction(busy: busy, icon: LucideIcons.refreshCw),
        );
      case _:
        return _StatusCard(
          tone: _Tone.normal,
          icon: LucideIcons.archive,
          title: _neverTitle,
          body: [_small(_hostedNeverBody(server))],
          action: _nowAction(view, busy: busy),
        );
    }
  }
}
