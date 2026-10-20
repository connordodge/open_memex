import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';

const _docsPath = 'docs/hosted-vault.md';

/// The "set up a vault server" sheet (board A8). Resolves to `true` when the
/// person chose "connect to a vault server…" and `false` for "close", the
/// close X or any other dismissal. Static content: no providers, no requests.
Future<bool> showSetUpVaultServerSheet(BuildContext context) async {
  final chose = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'close',
    barrierColor: OmColors.surface0.withAlpha(184),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (context, _, _) => const _SetUpVaultServerSheet(),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
  return chose ?? false;
}

class _SetUpVaultServerSheet extends StatelessWidget {
  const _SetUpVaultServerSheet();

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: height),
          child: SizedBox(
            width: 620,
            child: DecoratedBox(
              key: const Key('setup-sheet'),
              decoration: BoxDecoration(
                color: OmColors.surface2,
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(10),
                ),
                border: Border.all(color: OmColors.line2),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF000000).withAlpha(153),
                    offset: const Offset(0, 24),
                    blurRadius: 64,
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 21, 24, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Header(),
                    const SizedBox(height: 14),
                    const Flexible(
                      child: SingleChildScrollView(child: _Body()),
                    ),
                    const SizedBox(height: 14),
                    const _Footer(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          Flexible(
            child: Text(
              'SET UP A VAULT SERVER',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OmType.eyebrow(),
            ),
          ),
          const Spacer(),
          _IconBtn(
            key: const Key('setup-close-x'),
            icon: LucideIcons.x,
            iconSize: 14,
            label: 'close',
            onTap: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body();

  @override
  Widget build(BuildContext context) {
    final sub = OmType.sans(size: 12.5, color: OmColors.fg2);
    final path = OmType.mono(size: 12, color: OmColors.fg1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'a vault server is memex running on an always-on machine. it keeps '
          'your vaults on its own disk; this mac and your agents reach them '
          'over your network.',
          style: OmType.sans(size: 12.5, color: OmColors.fg2, height: 1.65),
        ),
        const SizedBox(height: 14),
        _Step(
          number: 1,
          title: 'install memex on the always-on machine',
          subline: Text.rich(
            TextSpan(
              style: sub,
              children: [
                const TextSpan(text: '(see '),
                TextSpan(text: _docsPath, style: path),
                const TextSpan(text: ' for a nas, linux or a mac)'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        _Step(
          number: 2,
          title: "create a vault in the server's vault root",
          command: 'memex init /volume1/memex/memex',
          copyKey: const Key('setup-copy-2'),
          subline: Text(
            'or create one from this app after you connect.',
            style: sub,
          ),
        ),
        const SizedBox(height: 14),
        _Step(
          number: 3,
          title: 'start the vault server',
          command:
              'memex serve --root /volume1/memex --listen 192.168.1.20:7878',
          copyKey: const Key('setup-copy-3'),
          subline: Text(
            "listen on the machine's home-network or tailscale address.",
            style: sub,
          ),
        ),
        const SizedBox(height: 14),
        const _Step(
          number: 4,
          title: 'copy the access token',
          command: 'cat /volume1/memex/.memex/access-token',
          copyKey: Key('setup-copy-4'),
        ),
        const SizedBox(height: 14),
        _Step(
          number: 5,
          title: 'connect from this app',
          subline: Text(
            'choose connect to a vault server…, then paste the url and the '
            'token.',
            style: sub,
          ),
        ),
        const SizedBox(height: 14),
        const _Warning(),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    this.command,
    this.copyKey,
    this.subline,
  });

  final int number;
  final String title;
  final String? command;
  final Key? copyKey;
  final Widget? subline;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: OmColors.line3),
          ),
          child: Text(
            '$number',
            style: OmType.mono(
              size: 11,
              weight: FontWeight.w500,
              color: OmColors.fg1,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: OmType.sans(
                  size: 13.5,
                  weight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
              if (command != null) ...[
                const SizedBox(height: 6),
                _CodeBlock(command: command!, copyKey: copyKey),
              ],
              if (subline != null) ...[const SizedBox(height: 6), subline!],
            ],
          ),
        ),
      ],
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.command, this.copyKey});

  final String command;
  final Key? copyKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: OmColors.surface0,
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              command,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OmType.mono(size: 12, color: OmColors.fg1),
            ),
          ),
          const SizedBox(width: 8),
          _IconBtn(
            key: copyKey,
            icon: LucideIcons.copy,
            iconSize: 12,
            label: 'copy',
            onTap: () => Clipboard.setData(ClipboardData(text: command)),
          ),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: OmColors.warnBg,
        border: Border.all(color: OmColors.warn.withAlpha(64)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              LucideIcons.alertTriangle,
              size: 14,
              color: OmColors.warn,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'use your home network or tailscale. never expose the server '
              'to the internet.',
              style: OmType.sans(size: 12.5, color: OmColors.warn, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      style: OmType.sans(size: 12, color: OmColors.fg2),
                      children: [
                        const TextSpan(text: 'full guide: '),
                        TextSpan(
                          text: _docsPath,
                          style: OmType.mono(size: 12, color: OmColors.fg1),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                _IconBtn(
                  key: const Key('setup-copy-docs'),
                  icon: LucideIcons.copy,
                  iconSize: 12,
                  label: 'copy',
                  onTap: () =>
                      Clipboard.setData(const ClipboardData(text: _docsPath)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OmButton(
            key: const Key('setup-close'),
            kind: OmButtonKind.ghost,
            label: 'close',
            onPressed: () => Navigator.of(context).pop(false),
          ),
          const SizedBox(width: 8),
          OmButton(
            key: const Key('setup-connect'),
            kind: OmButtonKind.primary,
            label: 'connect to a vault server…',
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
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
    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? OmColors.surface3 : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: OmColors.fg2,
            ),
          ),
        ),
      ),
    );
  }
}
