// WI #38 (A4; Spec #31 req 10, 15, 16, 16a, 17, 18, 22, 23; D2, D4, D14,
// D15, D17): the update modal and the version label that opens it.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/agent_activity.dart';
import '../state/app_version.dart';
import '../state/url_opener.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/atoms.dart' show OmButtonKind;
import '../widgets/dialog_button.dart';
import '../widgets/hosted/leave_confirm_dialog.dart';
import 'appcast.dart';
import 'update_controller.dart';
import 'update_seams.dart';
import 'update_state.dart';

/// The Releases page **download from GitHub** falls back to (D14).
const _releasesPage = 'https://github.com/connordodge/open_memex/releases';

/// The only `<link>` prefix **download from GitHub** opens as written (D14).
const _releasesPrefix = '$_releasesPage/';

/// The tallest the release notes' scroll area grows (req 15).
const _notesMaxHeight = 240.0;

/// Whether the update modal is up in this app (one per provider container).
class _OpenModal {
  bool open = false;
}

final _openModalProvider = Provider<_OpenModal>((_) => _OpenModal());

/// Opens the update modal over [context] at the controller's current state,
/// reading providers through [read]. A request while the modal is already
/// open opens no second one (req 18).
Future<void> openUpdateModal(BuildContext context, ProviderReader read) async {
  final state = read(_openModalProvider);
  if (state.open) return;
  state.open = true;
  try {
    await showDialog<void>(
      context: context,
      builder: (_) => const _UpdateModal(),
    );
  } finally {
    state.open = false;
  }
}

/// The page **download from GitHub** opens for [item]: its `<link>` when it
/// is on this repo's Releases path, otherwise the Releases page (D14).
String _gitHubPage(AppcastItem? item) {
  final link = item?.link ?? '';
  return _isReleasesLink(link) ? link : _releasesPage;
}

/// Whether [link] stays on this repo's Releases path once a browser resolves
/// it (D14): it starts with [_releasesPrefix], is plain `https` on
/// `github.com` with no user info or port, names a page below `releases/`,
/// and has no dot segment, encoded dot or slash, or backslash that could
/// climb out of that path.
bool _isReleasesLink(String link) {
  if (!link.startsWith(_releasesPrefix)) return false;
  final lower = link.toLowerCase();
  if (lower.contains(r'\') ||
      lower.contains('%2e') ||
      lower.contains('%2f') ||
      lower.contains('%5c')) {
    return false;
  }
  final uri = Uri.tryParse(link);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'github.com' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort) {
    return false;
  }
  // The path as written, before any normalizing parse: no `.` or `..`.
  final rawPath = link.split(RegExp('[?#]')).first;
  if (rawPath.split('/').any((s) => s == '.' || s == '..')) return false;
  final segments = uri.pathSegments;
  return segments.length > 3 &&
      segments[0] == 'connordodge' &&
      segments[1] == 'open_memex' &&
      segments[2] == 'releases' &&
      segments.skip(3).any((s) => s.isNotEmpty);
}

/// The error body for [error] (req 15's cause table, verbatim).
String _errorBody(UpdateError error, String current) => switch (error.cause) {
  UpdateErrorCause.offline =>
    "Open Memex couldn't reach the update feed. Check your connection "
        'and try again.',
  UpdateErrorCause.feedUnreadable =>
    "The update feed couldn't be read. Try again later.",
  UpdateErrorCause.noAppcast => 'No updates have been published yet.',
  UpdateErrorCause.badSignature =>
    "The update isn't signed by the Open Memex release key, so it "
        "wasn't installed.",
  UpdateErrorCause.noSignature =>
    "The update has no signature, so it wasn't installed.",
  UpdateErrorCause.noPublicKey =>
    "This build can't verify updates. Download the update from GitHub "
        'instead.',
  UpdateErrorCause.downloadFailed =>
    "The download didn't finish. Check your connection and try again.",
  UpdateErrorCause.folderNotWritable =>
    "Open Memex can't replace itself in ${error.folder ?? ''}. Download "
        'the update from GitHub instead.',
  UpdateErrorCause.diskImage =>
    'Open Memex is running from a disk image or a temporary location, so '
        "it can't replace itself. Move Open Memex to your Applications "
        'folder, open it from there and try again.',
  UpdateErrorCause.failureRecorded =>
    "The last update couldn't be installed: ${error.reason ?? ''}. "
        'Open Memex is still on $current.',
};

/// The update modal (D17): the LocalOpenRefusalDialog shell over the
/// controller's state, or the Off copy while updates are off (req 10).
class _UpdateModal extends ConsumerStatefulWidget {
  const _UpdateModal();

  @override
  ConsumerState<_UpdateModal> createState() => _UpdateModalState();
}

class _UpdateModalState extends ConsumerState<_UpdateModal> {
  /// An install, try again, relaunch or GitHub open is in flight.
  bool _busy = false;

  /// The modal has popped itself; a second close or later pops nothing.
  bool _closed = false;

  /// What the modal last showed. Once it has popped itself it keeps showing
  /// this while it fades out, so a state change that **later** causes (Idle)
  /// never flashes another state's copy.
  _Content? _shown;

  UpdateController get _controller =>
      ref.read(updateControllerProvider.notifier);

  /// Pops the modal's own route, once, and only while it is the top route:
  /// after an Esc or barrier dismiss it pops nothing (never the page under
  /// it).
  void _close() {
    if (_closed) return;
    _closed = true;
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.of(context).pop();
    }
  }

  void _later() {
    if (_closed) return;
    _controller.later();
    _close();
  }

  /// Runs [action] unless another one is in flight, so two presses in one
  /// frame start it once. While it runs, the buttons that start one show as
  /// disabled.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _setBusy(true);
    try {
      await action();
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool busy) {
    if (mounted) {
      setState(() => _busy = busy);
    } else {
      _busy = busy;
    }
  }

  void _install() => _run(_controller.install);

  void _tryAgain() => _run(_controller.tryAgain);

  void _relaunch() => _run(() async {
    final outcome = await _controller.relaunch(
      confirmQuit: () => mounted
          ? confirmLeave(context, LeaveAction.quit, ref.read)
          : Future.value(false),
    );
    if (outcome == RelaunchOutcome.cancelled && mounted) _close();
  });

  void _openGitHub(AppcastItem? item) =>
      _run(() => ref.read(urlOpenerProvider).open(_gitHubPage(item)));

  @override
  Widget build(BuildContext context) {
    final content = _closed && _shown != null
        ? _shown!
        : (_shown = ref.watch(updatesEnabledProvider)
              ? _content(ref.watch(updateControllerProvider))
              : _offContent());
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      child: Container(
        key: const Key('update-modal'),
        width: 472,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: OmColors.surface2,
          border: Border.all(color: OmColors.line2, width: 1),
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [
            BoxShadow(
              color: OmColors.dialogShadow,
              offset: Offset(0, 24),
              blurRadius: 64,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              content.title,
              key: const Key('update-modal-title'),
              style: OmType.sans(
                size: 15,
                weight: FontWeight.w600,
                height: 21 / 15,
              ),
            ),
            for (final part in content.body) ...[
              const SizedBox(height: 12),
              part,
            ],
            const SizedBox(height: 20),
            // A Wrap, not a Row: at a large text scale the second action
            // drops below the first instead of overflowing.
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: content.actions,
            ),
          ],
        ),
      ),
    );
  }

  _Content _offContent() => _Content(
    title: 'Updates are off',
    body: [_bodyText('Updates are off in development builds.')],
    actions: [_closeButton()],
  );

  _Content _content(UpdateState state) => switch (state) {
    UpdateIdle() || UpdateChecking() => _Content(
      title: 'Checking for updates',
      body: [const Align(alignment: Alignment.centerLeft, child: _Spinner())],
      actions: [_closeButton()],
    ),
    UpdateUpToDate() => _Content(
      title: "You're up to date",
      body: [
        _bodyText(
          'Open Memex ${ref.watch(appVersionProvider)} is the newest version.',
        ),
      ],
      actions: [_closeButton()],
    ),
    UpdateAvailable(:final item) => _Content(
      title: 'Update available',
      body: [
        _bodyText('Version ${item.shortVersionString} is available.'),
        if (item.notes.isNotEmpty) _Notes(notes: item.notes),
      ],
      actions: [
        _laterButton(),
        _button(
          'update-modal-install',
          'install',
          OmButtonKind.primary,
          _unlessBusy(_install),
        ),
      ],
    ),
    UpdateDownloading(:final progress) => _Content(
      title: 'Downloading update',
      body: [
        LinearProgressIndicator(
          key: const Key('update-modal-progress'),
          value: progress,
          minHeight: 4,
          color: OmColors.accent,
          backgroundColor: OmColors.surface4,
          borderRadius: BorderRadius.circular(2),
        ),
        if (progress != null)
          Text(
            '${(progress * 100).round()}%',
            key: const Key('update-modal-body'),
            style: OmType.mono(size: 12, color: OmColors.fg1),
          ),
      ],
      actions: [_laterButton()],
    ),
    UpdateVerifying() => _Content(
      title: 'Verifying update',
      body: [
        Row(
          children: [
            const _Spinner(),
            const SizedBox(width: 10),
            Expanded(child: _bodyText("Checking the update's signature.")),
          ],
        ),
      ],
      actions: [_laterButton()],
    ),
    UpdateReady(:final item) => _Content(
      title: 'Update ready',
      body: [
        _bodyText(
          'Version ${item.shortVersionString} is downloaded. Relaunch to '
          'apply it.',
        ),
        if (_agentsConnected())
          Text(
            'Connected agents keep using the current memex until they '
            'restart.',
            style: OmType.sans(size: 13, color: OmColors.fg2, height: 19 / 13),
          ),
      ],
      actions: [
        _laterButton(),
        _button(
          'update-modal-relaunch',
          'relaunch',
          OmButtonKind.primary,
          _unlessBusy(_relaunch),
        ),
      ],
    ),
    final UpdateError error => _Content(
      title: error.cause.isCheckFailure
          ? 'Update check failed'
          : 'Update failed',
      body: [_bodyText(_errorBody(error, ref.watch(appVersionProvider)))],
      actions: [
        _closeButton(),
        if (error.cause.tryAgain != UpdateRetryTarget.none)
          _button(
            'update-modal-try-again',
            'try again',
            OmButtonKind.primary,
            _unlessBusy(_tryAgain),
          ),
        if (error.cause.offersGitHubDownload)
          _button(
            'update-modal-download-github',
            'download from GitHub',
            OmButtonKind.primary,
            _unlessBusy(() => _openGitHub(error.item)),
          ),
      ],
    ),
  };

  /// Whether the open vault's agent view has finished loading and lists a
  /// connected agent (req 22, D4). A loading view, even one still carrying
  /// an old vault's value, counts as none.
  bool _agentsConnected() {
    final agents = ref.watch(agentActivityAsyncProvider);
    if (agents.isLoading) return false;
    return agents.valueOrNull?.connected.isNotEmpty ?? false;
  }

  Widget _bodyText(String text) => Text(
    text,
    key: const Key('update-modal-body'),
    style: OmType.sans(size: 13.5, color: OmColors.fg0, height: 20.93 / 13.5),
  );

  /// [action], or null (a disabled button) while another action runs.
  VoidCallback? _unlessBusy(VoidCallback action) => _busy ? null : action;

  Widget _closeButton() =>
      _button('update-modal-close', 'close', OmButtonKind.ghost, _close);

  Widget _laterButton() =>
      _button('update-modal-later', 'later', OmButtonKind.ghost, _later);

  Widget _button(
    String key,
    String label,
    OmButtonKind kind,
    VoidCallback? onPressed,
  ) => DialogButton(
    key: Key(key),
    kind: kind,
    label: label,
    onPressed: onPressed,
  );
}

/// What the modal shows for one state: its title, body parts (top to
/// bottom) and actions (left to right).
class _Content {
  const _Content({
    required this.title,
    required this.body,
    required this.actions,
  });

  final String title;
  final List<Widget> body;
  final List<Widget> actions;
}

/// The indeterminate spinner of Checking and Verifying.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(
      key: Key('update-modal-progress'),
      strokeWidth: 2,
      color: OmColors.accent,
    ),
  );
}

/// The release notes: the raw Markdown as selectable plain text in a scroll
/// area at most [_notesMaxHeight] tall (req 15).
class _Notes extends StatelessWidget {
  const _Notes({required this.notes});

  final String notes;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    key: const Key('update-modal-notes'),
    constraints: const BoxConstraints(maxHeight: _notesMaxHeight),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: OmColors.surface0,
        border: Border.all(color: OmColors.line2, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        child: SelectableText(
          notes,
          style: OmType.mono(size: 12, color: OmColors.fg1, height: 1.5),
        ),
      ),
    ),
  );
}

/// The sidebar's and the vault picker's version label (req 17, D15): one
/// Text keyed [textKey] reading `v<version>`, or `v<version> · update ready`
/// while the controller is Ready, in [style]. Only in Ready is it a button,
/// and pressing it opens the update modal (at Ready).
///
/// The Text is one line that ellipsizes rather than wraps, so inside a
/// Flexible it never overflows its row.
class UpdateVersionLabel extends ConsumerWidget {
  const UpdateVersionLabel({
    super.key,
    required this.textKey,
    required this.version,
    required this.style,
    required this.hitHeight,
  });

  final Key textKey;
  final String version;
  final TextStyle style;

  /// How tall the Ready button's hit area is, centred on the text; it never
  /// widens the label. Callers pass a height their row already has, so Ready
  /// moves nothing else in the row.
  final double hitHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(
      updateControllerProvider.select((s) => s is UpdateReady),
    );
    final label = ready ? 'v$version · update ready' : 'v$version';
    final text = Text(
      label,
      key: textKey,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (!ready) return text;
    return _ReadyLabelButton(
      label: label,
      hitHeight: hitHeight,
      onPressed: () => openUpdateModal(context, ref.read),
      child: text,
    );
  }
}

/// The Ready version label as a button: a click, or Enter or Space while it
/// has the focus (a held key presses it once), calls [onPressed]. It reads
/// as a button labelled [label], shows a focus ring while focused from the
/// keyboard, and takes clicks across [hitHeight].
class _ReadyLabelButton extends StatefulWidget {
  const _ReadyLabelButton({
    required this.label,
    required this.hitHeight,
    required this.onPressed,
    required this.child,
  });

  final String label;
  final double hitHeight;
  final VoidCallback onPressed;
  final Widget child;

  @override
  State<_ReadyLabelButton> createState() => _ReadyLabelButtonState();
}

class _ReadyLabelButtonState extends State<_ReadyLabelButton> {
  bool _highlight = false;

  late final Map<Type, Action<Intent>> _actions = {
    ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: _press),
    ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
      onInvoke: _press,
    ),
  };

  Object? _press(Intent _) {
    widget.onPressed();
    return null;
  }

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    shortcuts: keyboardButtonShortcuts,
    actions: _actions,
    mouseCursor: SystemMouseCursors.click,
    onShowFocusHighlight: (v) => setState(() => _highlight = v),
    child: Semantics(
      container: true,
      button: true,
      label: widget.label,
      onTap: widget.onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: SizedBox(
          height: widget.hitHeight,
          child: Align(
            widthFactor: 1,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: _highlight
                    ? Border.all(color: OmColors.accentSoft)
                    : null,
                borderRadius: BorderRadius.circular(3),
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    ),
  );
}
