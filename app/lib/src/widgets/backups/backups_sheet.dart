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

  /// The selected provider row.
  BackupDestinationOption? _selectedOption;

  /// "choose folder…" is the selected row (with [_chosenFolder]).
  bool _chooseSelected = false;

  /// The folder "choose folder…" picked while picking.
  String? _chosenFolder;

  /// This sheet's `backUpNow` call is still running.
  bool _pending = false;

  /// "turn on backups" is resolving and saving: the list stays, with
  /// "turn on backups" and "cancel" disabled, until the save lands, so a
  /// cancel can't be overtaken by the save.
  bool _turningOn = false;

  /// Why the last destination save failed (`backup_destination_unavailable`
  /// copy), shown until the next destination save or pick.
  String? _saveError;

  /// The tail of the settings saves in flight. Each change reads the stored
  /// settings only after the one before it landed.
  Future<void>? _saving;

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

  /// Saves [change] of the stored settings, after any save still in flight,
  /// and skips the save when nothing changes. With no save in flight the
  /// save starts before this returns.
  Future<void> _update(
    VaultBackupSettings Function(VaultBackupSettings current) change,
  ) {
    Future<void> run() async {
      final path = _path;
      if (path == null || !mounted) return;
      final current = _stored(path);
      final next = change(current);
      if (next == current) return;
      await ref.read(saveVaultBackupSettingsProvider)(path, next);
    }

    final previous = _saving;
    final future = previous == null ? run() : previous.then((_) => run());
    late final Future<void> tail;
    tail = future.then<void>((_) {}, onError: (Object _) {}).then((_) {
      if (identical(_saving, tail)) _saving = null;
    });
    _saving = tail;
    return future;
  }

  /// Reports a failed settings save that has no copy of its own.
  void _settle(Future<void> save) {
    save.catchError((Object error, StackTrace stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'backups sheet',
          context: ErrorDescription('while saving backup settings'),
        ),
      );
    });
  }

  /// The copy for a destination that could not be made, resolved or saved.
  String _destinationError(String destination, BackupProvider? provider) {
    final now = ref.read(clockProvider).now();
    return backupFailureMessage(
      code: backupDestinationUnavailableCode,
      automatic: false,
      failedAt: now,
      now: now,
      destination: destination,
      provider: provider,
    ).detail;
  }

  /// [option]'s folder, made when missing and symlinks resolved (A2's
  /// resolver), or null with [_saveError] set to why it can't be used.
  /// [picked] is the folder "choose folder…" picked.
  Future<String?> _resolve(
    BackupDestinationOption option, {
    String? picked,
  }) async {
    final resolution = await ref
        .read(resolveBackupDestinationProvider)
        .resolve(option, pickedFolder: picked);
    switch (resolution) {
      case BackupDestinationResolved(:final path):
        return path;
      case BackupDestinationUnavailable():
        if (mounted) {
          setState(
            () => _saveError = _destinationError(
              picked ?? option.path!,
              option.provider,
            ),
          );
        }
        return null;
    }
  }

  Future<void> _runBackup() async {
    if (_pending) return;
    setState(() {
      _pending = true;
    });
    try {
      await ref.read(backupControllerProvider.notifier).backUpNow(widget.vault);
    } finally {
      if (mounted) setState(() => _pending = false);
    }
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
      _selectedOption = null;
      _chooseSelected = false;
      _chosenFolder = null;
      _saveError = null;
    });
    _discover();
  }

  void _cancelPicking() => setState(() {
    _picking = false;
    _pickCancelled = true;
    _saveError = null;
  });

  void _selectProvider(BackupDestinationOption option) => setState(() {
    _selectedOption = option;
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

  /// Makes and resolves [option]'s folder ([picked] for "choose folder…"),
  /// then saves it with backups on. The list stays, "turn on backups" and
  /// "cancel" disabled, until the save lands; a folder that can't be used, or a save that
  /// fails, keeps it with why in its card.
  Future<void> _turnOnBackups(
    BackupDestinationOption option, {
    String? picked,
  }) async {
    setState(() {
      _turningOn = true;
      _saveError = null;
    });
    final destination = await _resolve(option, picked: picked);
    if (!mounted) return;
    if (destination == null) {
      setState(() => _turningOn = false);
      return;
    }
    try {
      await _update(
        (current) => current.copyWith(enabled: true, destination: destination),
      );
    } on Exception {
      if (!mounted) return;
      setState(() {
        _turningOn = false;
        _saveError = _destinationError(picked ?? option.path!, option.provider);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _turningOn = false;
      _picking = false;
      _pickCancelled = false;
    });
  }

  void _turnOffBackups() {
    _closeMenu();
    setState(() {
      _picking = false;
      _saveError = null;
    });
    _settle(_update((current) => current.copyWith(enabled: false)));
  }

  void _toggleAutomatic() {
    _settle(
      _update((current) => current.copyWith(automatic: !current.automatic)),
    );
  }

  void _stepKeep(int delta) {
    _settle(
      _update((current) {
        final next = math.min(
          backupKeepMax,
          math.max(backupKeepMin, current.keep + delta),
        );
        if (next == current.keep) return current;
        _keepText.text = '$next';
        return current.copyWith(keep: next);
      }),
    );
  }

  void _onKeepFocus() {
    if (!_keepFocus.hasFocus) _commitKeep();
  }

  /// Saves the typed keep count, clamped to 1-365, when it is a whole
  /// number and differs from the stored one; otherwise the field shows the
  /// stored one.
  void _commitKeep() {
    final path = _path;
    if (!mounted || path == null) return;
    final typed = int.tryParse(_keepText.text.trim());
    if (typed == null) {
      _keepText.text = '${_stored(path).keep}';
      return;
    }
    final keep = math.min(backupKeepMax, math.max(backupKeepMin, typed));
    _keepText.text = '$keep';
    _settle(_update((current) => current.copyWith(keep: keep)));
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

  /// Makes and resolves [option]'s folder ([picked] for "choose folder…")
  /// and saves it at once; a folder that can't be used, or a save that
  /// fails, shows why under the settings.
  Future<void> _menuSelect(
    BackupDestinationOption option, {
    String? picked,
  }) async {
    _closeMenu();
    if (_saveError != null) setState(() => _saveError = null);
    final destination = await _resolve(option, picked: picked);
    if (destination == null || !mounted) return;
    try {
      await _update(
        (current) => destination == current.destination
            ? current
            : current.copyWith(destination: destination),
      );
    } on Exception {
      if (mounted) {
        setState(
          () => _saveError = _destinationError(
            picked ?? option.path!,
            option.provider,
          ),
        );
      }
    }
  }

  Future<void> _menuChooseFolder() async {
    _closeMenu();
    final folder = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where backups go',
    );
    if (folder == null || !mounted) return;
    await _menuSelect(_chooseFolderOption, picked: folder);
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    ref.watch(backupControllerProvider);
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
        if (_saveError case final error?) ...[
          const SizedBox(height: 10),
          Text(error, style: _smallStyle.copyWith(color: OmColors.danger)),
        ],
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
    final chosen = _chosenFolder;
    final provider = _selectedOption;
    final VoidCallback? turnOn;
    if (_turningOn) {
      turnOn = null;
    } else if (_chooseSelected) {
      turnOn = chosen == null
          ? null
          : () => _turnOnBackups(_chooseFolderOption, picked: chosen);
    } else {
      turnOn = provider == null ? null : () => _turnOnBackups(provider);
    }
    final error = _saveError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusCard(
          tone: error == null ? _Tone.normal : _Tone.error,
          icon: error == null ? LucideIcons.archive : LucideIcons.triangleAlert,
          title: _pickTitle,
          body: [_small(error ?? _pickBody)],
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
                                name: _optionName(option),
                                path: _whereOf(option.path!).relative,
                                selected:
                                    !_chooseSelected &&
                                    _selectedOption?.path == option.path,
                                onTap: () => _selectProvider(option),
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
              onPressed: _turningOn ? null : _cancelPicking,
            ),
            const SizedBox(width: 8),
            _SheetButton(key: _turnOnKey, label: _turnOn, onPressed: turnOn),
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
        final started = view.startedAt;
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
        final message = view.message;
        return _StatusCard(
          tone: _Tone.error,
          icon: LucideIcons.triangleAlert,
          title: message?.title ?? _failedFallback,
          body: [
            if (message != null) _paragraph(message.detail),
            const SizedBox(height: 6),
            _small(_lastGoodLine(status, now, retries: stored.automatic)),
          ],
          action: _retryAction(busy: busy, icon: LucideIcons.refreshCw),
        );
      case BackupSheetMode.memexTooOld || BackupSheetMode.binaryNotFound:
        final message = view.message;
        final binary = app.memexBinaryPath;
        return _StatusCard(
          tone: _Tone.error,
          icon: LucideIcons.triangleAlert,
          title: message?.title ?? _failedFallback,
          body: [
            if (message != null) _paragraph(message.detail),
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
                // A click opens the menu without focusing anything: take
                // focus into it, so Escape reaches the sheet's Actions and
                // closes the menu, not the sheet. Opened from the keyboard,
                // the destination button keeps focus.
                child: Focus(
                  autofocus: true,
                  skipTraversal: true,
                  child: Material(
                    type: MaterialType.transparency,
                    child: _MenuPanel(
                      providers: [
                        for (final (option, key) in options)
                          _MenuItem(
                            key: key,
                            label: _optionName(option),
                            current: option.path == current,
                            onTap: () => _menuSelect(option),
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
      case BackupSheetMode.off || BackupSheetMode.pickingDestination:
        // The server's status isn't read yet: claim nothing about it, and
        // send nothing until it is known.
        return _StatusCard(
          tone: _Tone.normal,
          icon: LucideIcons.server,
          title: _hostedCheckingTitle(server),
          body: [_small(_unreachableBody(server))],
          action: const _CardAction(
            key: backupsNowKey,
            label: _backUpNow,
            onPressed: null,
          ),
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
        final message = view.message;
        return _StatusCard(
          tone: _Tone.error,
          icon: LucideIcons.triangleAlert,
          title: message?.title ?? _failedFallback,
          body: [
            if (message != null) _paragraph(message.detail),
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
