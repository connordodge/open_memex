// WI #325 (A4): the Backups sheet's building blocks (design pack 325): the
// focusable press target every control uses, the status card, the settings
// group and its rows, the switch, the keep stepper, the destination rows and
// menu, and the hosted command row.
part of 'backups_sheet.dart';

/// Card and disc border of an error state (pack 325 `dangerLine`).
final _dangerLine = OmColors.danger.withAlpha(77);

/// Card and disc border of a warning state (pack 325 `warnLine`).
final _warnLine = OmColors.warn.withAlpha(77);

TextStyle get _smallStyle =>
    OmType.sans(size: 12, height: 1.5, color: OmColors.fg2);
TextStyle get _paragraphStyle =>
    OmType.sans(size: 13, height: 1.55, color: OmColors.fg1);
TextStyle get _titleStyle =>
    OmType.sans(size: 17, weight: FontWeight.w600, height: 1.3);
TextStyle get _labelStyle =>
    OmType.sans(size: 13, height: 1.55, color: OmColors.fg0);
TextStyle get _monoSubStyle =>
    OmType.mono(size: 11, height: 1.5, color: OmColors.fg2);
TextStyle get _buttonLabelStyle =>
    OmType.sans(size: 13, weight: FontWeight.w500);

Widget _small(String text) => Text(text, style: _smallStyle);
Widget _paragraph(String text) => Text(text, style: _paragraphStyle);
Widget _fileName(String text) =>
    Text(text, style: OmType.mono(size: 12, height: 1.25, color: OmColors.fg1));

/// [text]'s one-line width in [style] at the current text scale.
double _textWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// A control's whole box as one focusable, labelled press target: Tab
/// reaches it, Enter and Space activate it, and its semantics carry the
/// label, the role and the enabled state. Disabled when [onPressed] is null:
/// still focusable, so a screen reader finds it, but nothing activates it.
class _Pressable extends StatefulWidget {
  const _Pressable({
    super.key,
    required this.label,
    required this.onPressed,
    required this.child,
    this.handlesTap = true,
    this.toggled,
    this.checked,
    this.radius = 6,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget child;

  /// False when [child] takes its own taps (an [OmButton]).
  final bool handlesTap;

  /// A switch's state.
  final bool? toggled;

  /// A radio row's state.
  final bool? checked;

  /// The focus ring's corner radius.
  final double radius;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _focusRing = false;

  Object? _activate([Intent? _]) {
    widget.onPressed?.call();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    Widget child = ExcludeSemantics(child: widget.child);
    if (widget.handlesTap) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: child,
      );
    }
    return Semantics(
      container: true,
      button: widget.toggled == null && widget.checked == null,
      enabled: enabled,
      toggled: widget.toggled,
      checked: widget.checked,
      inMutuallyExclusiveGroup: widget.checked == null ? null : true,
      label: widget.label,
      onTap: widget.onPressed,
      child: FocusableActionDetector(
        // A disabled control stays reachable with Tab (its state is read
        // out as disabled); Enter and Space then do nothing.
        mouseCursor: enabled && widget.handlesTap
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        onShowFocusHighlight: (on) => setState(() => _focusRing = on),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: _activate),
          ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: _activate,
          ),
        },
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: _focusRing ? Border.all(color: OmColors.accent) : null,
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// An [OmButton] that Tab reaches and Enter and Space press. Its height
/// grows with the text scale (a minimum, never a fixed box).
class _SheetButton extends StatelessWidget {
  const _SheetButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = OmButtonKind.primary,
    this.icon,
    this.small = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final OmButtonKind kind;
  final IconData? icon;

  /// The small ghost button (24 high, 12 px label).
  final bool small;

  @override
  Widget build(BuildContext context) {
    final fontSize = small ? 12.0 : 13.0;
    final size = math.max(
      small ? 24.0 : 30.0,
      MediaQuery.textScalerOf(context).scale(fontSize) * 1.5 + 4,
    );
    return _Pressable(
      label: label,
      onPressed: onPressed,
      handlesTap: false,
      child: OmButton(
        onPressed: onPressed,
        kind: kind,
        size: size,
        label: label,
        icon: icon,
        dense: small,
      ),
    );
  }
}

/// A 24 px square icon button (radius 5, surface3 on hover).
class _IconBtn extends StatefulWidget {
  const _IconBtn({
    super.key,
    required this.icon,
    required this.iconSize,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final double iconSize;
  final String label;
  final VoidCallback onTap;

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      label: widget.label,
      onPressed: widget.onTap,
      radius: 5,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hover ? OmColors.surface3 : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Icon(widget.icon, size: widget.iconSize, color: OmColors.fg2),
        ),
      ),
    );
  }
}

/// The status card's look: normal, ok, running, error or warning.
enum _Tone { normal, ok, running, error, warn }

/// The status card's one action.
class _CardAction {
  const _CardAction({
    required this.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final Key key;
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
}

/// The card at the top of the sheet ("hero"): the icon disc, the status text
/// column (`backups-status`) and the one action that matters now. When the
/// title and the button do not fit on one line the button drops under the
/// text, inset past the disc (B4-2).
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.tone,
    required this.icon,
    required this.title,
    this.body = const [],
    this.action,
    this.alertBorder = false,
  });

  final _Tone tone;
  final IconData icon;
  final String title;
  final List<Widget> body;
  final _CardAction? action;

  /// A warning card draws its border in the warning colour (B3-5).
  final bool alertBorder;

  @override
  Widget build(BuildContext context) {
    final border = switch (tone) {
      _Tone.error => _dangerLine,
      _Tone.warn when alertBorder => _warnLine,
      _ => OmColors.line2,
    };
    final text = KeyedSubtree(
      key: backupsStatusKey,
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: _titleStyle),
            if (body.isNotEmpty) const SizedBox(height: 4),
            ...body,
          ],
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OmColors.surface3,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final head = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Disc(tone: tone, icon: icon),
                const SizedBox(width: 14),
                Expanded(child: text),
              ],
            );
            final action = this.action;
            if (action == null) return head;
            final button = _SheetButton(
              key: action.key,
              label: action.label,
              icon: action.icon,
              onPressed: action.onPressed,
            );
            final buttonWidth =
                _textWidth(context, action.label, _buttonLabelStyle) +
                (action.icon == null ? 26 : 47);
            final titleWidth = _textWidth(context, title, _titleStyle);
            if (50 + titleWidth + 14 + buttonWidth <= constraints.maxWidth) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: head),
                  const SizedBox(width: 14),
                  button,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                head,
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.only(left: 50),
                  child: button,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The card's 36 px icon disc.
class _Disc extends StatelessWidget {
  const _Disc({required this.tone, required this.icon});

  final _Tone tone;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final (fill, line, fg) = switch (tone) {
      _Tone.normal => (OmColors.surface2, OmColors.line2, OmColors.fg1),
      _Tone.ok => (
        OmColors.successBg,
        OmColors.accent.withAlpha(77),
        OmColors.accent,
      ),
      _Tone.running => (
        OmColors.infoBg,
        OmColors.info.withAlpha(77),
        OmColors.info,
      ),
      _Tone.error => (OmColors.dangerBg, _dangerLine, OmColors.danger),
      _Tone.warn => (OmColors.warnBg, _warnLine, OmColors.warn),
    };
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill,
        border: Border.all(color: line),
      ),
      child: tone == _Tone.running
          ? _Spinner(icon: icon, color: fg)
          : Icon(icon, size: 16, color: fg),
    );
  }
}

/// The running disc's turning loader (still when animations are off).
class _Spinner extends StatefulWidget {
  const _Spinner({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turns = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _turns.stop();
    } else {
      _turns.repeat();
    }
  }

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _turns,
    child: Icon(widget.icon, size: 16, color: widget.color),
  );
}

/// A section eyebrow (`SETTINGS`, `ON <SERVER>`).
Widget _eyebrow(String text) => Text(text, style: OmType.eyebrow());

/// The settings group: a bordered box with a hairline between rows.
class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Container(height: 1, color: OmColors.line1),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// One settings row: label and sub on the left, the control on the right.
/// When label plus control do not fit, the control drops under the label,
/// end-aligned (B4-2). Rows are content height, never fixed.
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    required this.sub,
    required this.control,
    required this.controlWidth,
    this.subMono = false,
  });

  final String label;
  final String sub;
  final Widget control;

  /// [control]'s width at the current text scale.
  final double controlWidth;
  final bool subMono;

  @override
  Widget build(BuildContext context) {
    final subStyle = subMono ? _monoSubStyle : _smallStyle;
    final labels = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: _labelStyle),
        Text(sub, style: subStyle),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final labelWidth = math.max(
            _textWidth(context, label, _labelStyle),
            _textWidth(context, sub, subStyle),
          );
          if (labelWidth + 12 + controlWidth <= constraints.maxWidth) {
            return Row(
              children: [
                Expanded(child: labels),
                const SizedBox(width: 12),
                control,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              labels,
              SizedBox(height: MediaQuery.textScalerOf(context).scale(8)),
              Align(alignment: Alignment.centerRight, child: control),
            ],
          );
        },
      ),
    );
  }
}

/// A hosted vault's read-only setting: the label left, the server's value
/// right (B3). The value wraps under its own column.
class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14),
      child: Row(
        children: [
          Text(label, style: _labelStyle),
          const SizedBox(width: 12),
          Expanded(
            child: Text(value, textAlign: TextAlign.end, style: _smallStyle),
          ),
        ],
      ),
    );
  }
}

/// "back up automatically": a 32 x 18 switch.
class _Switch extends StatelessWidget {
  const _Switch({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      label: label,
      toggled: value,
      onPressed: onChanged,
      radius: 9,
      child: Container(
        width: 32,
        height: 18,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: value ? OmColors.accentDeep : OmColors.surface4,
          border: Border.all(
            color: value ? OmColors.accent.withAlpha(115) : OmColors.line2,
          ),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: value ? OmColors.accent : OmColors.fg2,
          ),
        ),
      ),
    );
  }
}

/// The keep stepper: −, the value field (`backups-keep`), +.
class _KeepStepper extends StatelessWidget {
  const _KeepStepper({
    required this.keep,
    required this.controller,
    required this.focusNode,
    required this.onStep,
    required this.onSubmit,
  });

  /// Its width: two 28 px cells, the 46 px field and the border.
  static const width = 104.0;

  final int keep;
  final TextEditingController controller;
  final FocusNode focusNode;
  final void Function(int delta) onStep;
  final VoidCallback onSubmit;

  Widget _cell(Key key, String glyph, String label, VoidCallback? onPressed) {
    return _Pressable(
      key: key,
      label: label,
      onPressed: onPressed,
      radius: 5,
      child: Opacity(
        opacity: onPressed == null ? 0.4 : 1,
        child: Container(
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          alignment: Alignment.center,
          child: Text(
            glyph,
            style: OmType.sans(size: 16, height: 1, color: OmColors.fg1),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OmColors.surface3,
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        // Inside the border, so the cells never paint over it.
        padding: const EdgeInsets.all(1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _cell(
              _keepDecKey,
              '−',
              'keep one fewer backup',
              keep > backupKeepMin ? () => onStep(-1) : null,
            ),
            Container(
              width: 46,
              constraints: const BoxConstraints(minHeight: 28),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: OmColors.surface2,
                border: Border.symmetric(
                  vertical: BorderSide(color: OmColors.line2),
                ),
              ),
              child: MergeSemantics(
                child: Semantics(
                  label: 'keep',
                  child: TextField(
                    key: backupsKeepKey,
                    controller: controller,
                    focusNode: focusNode,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    style: OmType.mono(size: 12.5, color: OmColors.fg0),
                    cursorColor: OmColors.accent,
                    decoration: const InputDecoration.collapsed(hintText: null),
                    onSubmitted: (_) => onSubmit(),
                  ),
                ),
              ),
            ),
            _cell(
              _keepIncKey,
              '+',
              'keep one more backup',
              keep < backupKeepMax ? () => onStep(1) : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// The picking list's radio (14 px; selected: accent ring and 7 px dot).
class _Radio extends StatelessWidget {
  const _Radio({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: selected ? OmColors.accent : OmColors.fg2),
      ),
      child: selected
          ? Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: OmColors.accent,
              ),
            )
          : null,
    );
  }
}

/// One row of the picking list: the whole row is the tap target.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.name,
    required this.path,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final String path;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      label: '$name, $path',
      checked: selected,
      onPressed: onTap,
      radius: 0,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        color: selected ? OmColors.surface4 : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
        child: Row(
          children: [
            _Radio(selected: selected),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name, style: OmType.sans(size: 13, height: 1.3)),
                  Text(
                    path,
                    style: OmType.mono(
                      size: 11,
                      height: 1.3,
                      color: OmColors.fg2,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The destination dropdown button (B2-9).
class _DestinationButton extends StatelessWidget {
  const _DestinationButton({
    required this.label,
    required this.provider,
    required this.onPressed,
  });

  /// Its width at the current text scale (paddings, icons and gaps around
  /// the label).
  static double widthFor(BuildContext context, String label) =>
      _textWidth(context, label, _style) + 63;

  static TextStyle get _style => OmType.sans(size: 12.5);

  final String label;
  final bool provider;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      key: _menuKey,
      label: '$_destinationLabel: $label',
      onPressed: onPressed,
      child: Container(
        constraints: const BoxConstraints(minHeight: 30),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: OmColors.surface3,
          border: Border.all(color: OmColors.line2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              provider ? LucideIcons.cloud : LucideIcons.folder,
              size: 12,
              color: OmColors.fg0,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(LucideIcons.chevronDown, size: 12, color: OmColors.fg1),
          ],
        ),
      ),
    );
  }
}

/// One destination menu item.
class _MenuItem {
  const _MenuItem({
    required this.key,
    required this.label,
    required this.current,
    required this.onTap,
  });

  final Key key;
  final String label;
  final bool current;
  final VoidCallback onTap;
}

/// The destination menu (B2-9): the discovered destinations, a separator,
/// then "choose folder…".
class _MenuPanel extends StatelessWidget {
  const _MenuPanel({required this.providers, required this.choose});

  final List<_MenuItem> providers;
  final _MenuItem choose;

  Widget _item(_MenuItem item) {
    return _Pressable(
      key: item.key,
      label: item.label,
      onPressed: item.onTap,
      radius: 4,
      child: Container(
        constraints: const BoxConstraints(minHeight: 30),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: item.current ? OmColors.surface4 : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            if (item.current) ...[
              const Icon(LucideIcons.check, size: 12, color: OmColors.fg0),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OmType.sans(
                  size: 13,
                  color: item.current ? OmColors.fg0 : OmColors.fg1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: OmColors.surface3,
        border: Border.all(color: OmColors.line3),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: OmColors.dialogShadow.withAlpha(128),
            offset: const Offset(0, 12),
            blurRadius: 32,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in providers) _item(item),
          if (providers.isNotEmpty)
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(vertical: 4),
              color: OmColors.line2,
            ),
          _item(choose),
        ],
      ),
    );
  }
}

/// Hosted "not configured": the copyable `memex serve` command.
class _CommandRow extends StatelessWidget {
  const _CommandRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 38),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: OmColors.surface0,
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            // Wraps rather than clips: `--backup-dir <dir>` is the point.
            child: Text(
              _hostedCommand,
              softWrap: true,
              style: OmType.mono(size: 12, color: OmColors.fg1),
            ),
          ),
          const SizedBox(width: 8),
          _IconBtn(
            key: _copyCommandKey,
            icon: LucideIcons.copy,
            iconSize: 12,
            label: 'copy the command',
            onTap: () =>
                Clipboard.setData(const ClipboardData(text: _hostedCommand)),
          ),
        ],
      ),
    );
  }
}

/// Hosted footer: "full guide: docs/backups.md" with its copy button, and
/// "close".
class _GuideFooter extends StatelessWidget {
  const _GuideFooter();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Text(_fullGuide, style: _smallStyle),
              Flexible(
                child: Text(
                  _docsPath,
                  key: _guideLinkKey,
                  style: OmType.sans(
                    size: 12,
                    color: OmColors.info,
                  ).copyWith(decoration: TextDecoration.underline),
                ),
              ),
              const SizedBox(width: 4),
              _IconBtn(
                icon: LucideIcons.copy,
                iconSize: 12,
                label: 'copy $_docsPath',
                onTap: () =>
                    Clipboard.setData(const ClipboardData(text: _docsPath)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _SheetButton(
          key: _closeButtonKey,
          kind: OmButtonKind.ghost,
          label: 'close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
