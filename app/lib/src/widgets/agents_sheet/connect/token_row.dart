// WI #411 (Spec #394 req 25-27, 46; pack #411 "Hosted", RULINGS #3): the
// hosted Connect tab's field rows: the MCP address, the access token
// (masked, or revealed) and the no-token row.
//
// These widgets never hold the real token: the revealed text is passed in
// by the Connect tab's State for one build and is shown, never put in a
// Semantics label.
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../theme/colors.dart';
import '../../../theme/typography.dart';
import '../../atoms.dart';
import '../../om_copy_button.dart';

/// A field label above a row: sans 12 fg2, 14 px above and 6 px below.
class ConnectFieldLabel extends StatelessWidget {
  const ConnectFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Text(
        text,
        style: OmType.sans(size: 12, height: 1.4, color: OmColors.fg2),
      ),
    );
  }
}

/// The `.tok` row box: surface0, 1 px `line2`, radius 6, padding
/// 5 / 6 / 5 / 12, its [children] in a row 6 px apart.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 5, 6, 5),
      decoration: BoxDecoration(
        color: OmColors.surface0,
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0) const SizedBox(width: 6),
            child,
          ],
        ],
      ),
    );
  }
}

/// The row's value text: mono 12, line height 1.5, fg1, one line,
/// ellipsized.
Widget _value(String text) => Text(
  text,
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  softWrap: false,
  style: OmType.mono(size: 12, height: 1.5, color: OmColors.fg1),
);

/// The MCP address and its plain Copy (`Copy MCP address`).
class ConnectAddressRow extends StatelessWidget {
  const ConnectAddressRow({super.key, required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    return _FieldRow(
      children: [
        Expanded(child: _value(address)),
        OmCopyButton(text: () => address, semanticLabel: 'Copy MCP address'),
      ],
    );
  }
}

/// The access token row: [shown] (the mask, or the real token while
/// revealed), the `Reveal` / `Hide` toggle and a sensitive Copy (no icon,
/// RULINGS #3) whose [copyToken] reads the Keychain on each press.
///
/// The token text is one Semantics node labelled [semanticsLabel]
/// (`access token ending <last 4>`), revealed or not.
class ConnectTokenRow extends StatelessWidget {
  const ConnectTokenRow({
    super.key,
    required this.shown,
    required this.semanticsLabel,
    required this.revealed,
    required this.onToggle,
    required this.copyToken,
  });

  final String shown;
  final String semanticsLabel;
  final bool revealed;
  final VoidCallback onToggle;
  final Future<String> Function() copyToken;

  @override
  Widget build(BuildContext context) {
    return _FieldRow(
      children: [
        Expanded(
          child: Semantics(
            container: true,
            label: semanticsLabel,
            excludeSemantics: true,
            child: _value(shown),
          ),
        ),
        OmButton(
          onPressed: onToggle,
          kind: OmButtonKind.secondary,
          size: 24,
          dense: true,
          focusable: true,
          icon: revealed ? LucideIcons.eyeOff : LucideIcons.eye,
          label: revealed ? 'Hide' : 'Reveal',
          semanticLabel: revealed ? 'Hide access token' : 'Reveal access token',
          toggled: revealed,
        ),
        OmCopyButton(
          text: copyToken,
          semanticLabel: 'Copy access token',
          showIcon: false,
          sensitive: true,
        ),
      ],
    );
  }
}

/// No token in the Keychain for the server: the row reads so in fg2, with
/// the app's update-token action on the right.
class ConnectNoTokenRow extends StatelessWidget {
  const ConnectNoTokenRow({super.key, required this.onUpdateToken});

  final VoidCallback onUpdateToken;

  @override
  Widget build(BuildContext context) {
    return _FieldRow(
      children: [
        Expanded(
          child: Text(
            'No token in this Mac’s Keychain for this server',
            style: OmType.sans(size: 12.5, height: 1.5, color: OmColors.fg2),
          ),
        ),
        OmButton(
          onPressed: onUpdateToken,
          kind: OmButtonKind.secondary,
          size: 24,
          dense: true,
          focusable: true,
          label: 'Update token',
        ),
      ],
    );
  }
}
