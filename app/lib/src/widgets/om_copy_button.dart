import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/clock.dart';
import '../state/vault_trash.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// The shared copy button (Spec #394 req 31, ruling D9, pack #406).
///
/// - [text] is called only when the button is pressed, never at build time,
///   so a caller that copies an access token reads it only then (req 27).
///   It may be async (a Keychain read); presses while it is pending are
///   ignored, and nothing is copied if the button is disposed meanwhile.
/// - A plain copy uses `Clipboard.setData`. A [sensitive] copy (every copy
///   that holds the real token) invokes `copySensitive` on
///   `open_memex/files` (`vaultFilesChannel`), which marks the item
///   concealed on the pasteboard; any failure falls back to
///   `Clipboard.setData` once. The value is never logged.
/// - After a copy it shows `Copied` (with a check when [showIcon]) for 2 s on
///   the app clock (`clockProvider`) and announces `copied` once.
/// - Semantics: a button labelled [semanticLabel]; the visible [label] is not
///   the Semantics label. Enter and Space activate it; key repeats are
///   ignored, and a second press while a copy is in flight is ignored.
/// - Keyboard focus (focus-visible only) draws the #393 focus look (D29):
///   a 2 px accent ring inside the box and the surface4 fill.
class OmCopyButton extends ConsumerStatefulWidget {
  const OmCopyButton({
    super.key,
    required this.text,
    required this.semanticLabel,
    this.label = 'Copy',
    this.showIcon = true,
    this.sensitive = false,
  });

  /// Returns the value to copy; called once per press. May be async.
  final FutureOr<String> Function() text;

  /// The Semantics label, for example `Copy Claude Desktop config`.
  final String semanticLabel;

  /// The visible idle label (design ruling #2): `Copy` or `Copy config`.
  final String label;

  /// Whether the leading copy / check icon shows (design ruling #3: every
  /// copy button except the token row's).
  final bool showIcon;

  /// Copy through `copySensitive` (concealed) instead of `Clipboard.setData`.
  final bool sensitive;

  @override
  ConsumerState<OmCopyButton> createState() => _OmCopyButtonState();
}

class _OmCopyButtonState extends ConsumerState<OmCopyButton> {
  /// How long `Copied` shows after a copy (pack #406).
  static const _copiedFor = Duration(seconds: 2);

  final _focusNode = FocusNode(debugLabel: 'OmCopyButton');
  bool _hover = false;
  bool _focused = false;
  bool _copied = false;

  /// A copy is in flight; further presses are ignored until it finishes.
  bool _busy = false;
  Timer? _revert;

  @override
  void dispose() {
    _revert?.cancel();
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    _focusNode.dispose();
    super.dispose();
  }

  void _setFocused(bool focused) {
    // The ring follows the highlight mode only while focused.
    if (focused) {
      FocusManager.instance.addHighlightModeListener(_onHighlightMode);
    } else {
      FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    }
    _focused = focused;
  }

  void _onHighlightMode(FocusHighlightMode _) => setState(() {});

  Future<void> _press() async {
    // Set before the first await so a second press in the same frame is
    // ignored.
    if (_busy) return;
    _busy = true;
    try {
      final value = await widget.text();
      if (!mounted) return;
      await _write(value);
    } finally {
      _busy = false;
    }
    if (!mounted) return;
    _revert?.cancel();
    _revert = ref.read(clockProvider).after(_copiedFor, _onRevert);
    setState(() => _copied = true);
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        'copied',
        Directionality.of(context),
      ),
    );
  }

  void _onRevert() {
    _revert = null;
    if (mounted) setState(() => _copied = false);
  }

  static Future<void> _writePlain(String value) =>
      Clipboard.setData(ClipboardData(text: value));

  /// Copies [value], concealed when [OmCopyButton.sensitive]. A failed
  /// `copySensitive` falls back to the plain clipboard once; neither [value]
  /// nor the exception (whose message may carry it) is logged.
  Future<void> _write(String value) async {
    if (!widget.sensitive) return _writePlain(value);
    try {
      await vaultFilesChannel.invokeMethod<void>('copySensitive', value);
    } on PlatformException {
      await _writePlain(value);
    } on MissingPluginException {
      await _writePlain(value);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final activates =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space;
    if (!activates) return KeyEventResult.ignored;
    // A held key's repeats are consumed without copying again.
    if (event is KeyDownEvent) unawaited(_press());
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final fg = _copied ? OmColors.accent : OmColors.fg1;
    // Keyboard focus only (CSS :focus-visible): no ring after a click, and
    // none while the focus highlight is off.
    final ring =
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final Color fill;
    if (_copied) {
      fill = OmColors.copiedBg;
    } else if (ring) {
      fill = OmColors.surface4;
    } else if (_hover) {
      fill = OmColors.surface4;
    } else {
      fill = OmColors.surface3;
    }
    final border = _copied ? OmColors.accentLine : OmColors.line2;

    return Focus(
      focusNode: _focusNode,
      includeSemantics: false,
      onKeyEvent: _onKey,
      onFocusChange: (focused) => setState(() => _setFocused(focused)),
      child: Semantics(
        container: true,
        excludeSemantics: true,
        button: true,
        focusable: true,
        focused: _focused,
        label: widget.semanticLabel,
        onTap: _press,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _press,
            child: Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: fill,
                border: Border.all(color: border),
                borderRadius: BorderRadius.circular(6),
              ),
              // The 2 px ring is drawn inside the box, so the size never
              // changes. Null without the ring keeps the default tree as is.
              foregroundDecoration: ring
                  ? BoxDecoration(
                      border: Border.all(
                        color: OmColors.accent,
                        width: 2,
                        strokeAlign: BorderSide.strokeAlignInside,
                      ),
                      borderRadius: BorderRadius.circular(6),
                    )
                  : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.showIcon) ...[
                    Icon(
                      _copied ? LucideIcons.check : LucideIcons.copy,
                      size: 12,
                      color: fg,
                    ),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    _copied ? 'Copied' : widget.label,
                    maxLines: 1,
                    style: OmType.sans(
                      size: 11.5,
                      weight: FontWeight.w500,
                      height: 1.0,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
