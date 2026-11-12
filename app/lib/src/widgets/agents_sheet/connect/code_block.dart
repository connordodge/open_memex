// WI #411 (Spec #394 req 30, pack #411 "Code block"): a Connect snippet in
// a surface0 box that never wraps and scrolls sideways, with its Copy
// button pinned at the top right.
import 'package:flutter/widgets.dart';

import '../../../theme/colors.dart';
import '../../../theme/typography.dart';
import '../../om_copy_button.dart';

/// How a [ConnectCodeBlock] colours its text: everything fg1, plus
///
/// - [json]: object keys (a string followed by `:`) fg2 and the string
///   `"--with-embeddings"` accent;
/// - [shell]: a trailing ` --with-embeddings` accent;
/// - [plain]: nothing else.
enum ConnectCodeSyntax { json, shell, plain }

/// The embeddings flag, coloured accent in a snippet.
const _flag = '--with-embeddings';

/// A snippet in a code block (Spec #394 req 30): surface0, a 1 px `line2`
/// border, 6 px radius, mono 12 at line height 1.6. Lines never wrap; the
/// block scrolls sideways, so the shown layout matches the copied text.
/// [copy] sits pinned at the top right while the text scrolls under it.
class ConnectCodeBlock extends StatelessWidget {
  const ConnectCodeBlock({
    super.key,
    required this.text,
    required this.copy,
    this.syntax = ConnectCodeSyntax.plain,
    this.semanticsLabel,
  });

  /// The text shown.
  final String text;

  /// The Copy button, pinned top right.
  final OmCopyButton copy;

  final ConnectCodeSyntax syntax;

  /// Replaces [text] in Semantics; a block that can show a real access token
  /// passes text that never holds one (Spec #394 req 27).
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final base = OmType.mono(size: 12, height: 1.6, color: OmColors.fg1);
    return Container(
      decoration: BoxDecoration(
        color: OmColors.surface0,
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 10, 92, 10),
            child: Text.rich(
              TextSpan(children: _spans(text, syntax)),
              style: base,
              softWrap: false,
              semanticsLabel: semanticsLabel,
            ),
          ),
          Positioned(top: 6, right: 6, child: copy),
        ],
      ),
    );
  }
}

/// A JSON string literal, and one followed by `:` (an object key).
final _jsonString = RegExp(r'"(?:[^"\\]|\\.)*"');
final _jsonKey = RegExp(r'"(?:[^"\\]|\\.)*"(?=\s*:)');

List<InlineSpan> _spans(String text, ConnectCodeSyntax syntax) {
  TextSpan run(String s, [Color? color]) => TextSpan(
    text: s,
    style: color == null ? null : TextStyle(color: color),
  );
  switch (syntax) {
    case ConnectCodeSyntax.plain:
      return [run(text)];
    case ConnectCodeSyntax.shell:
      const tail = ' $_flag';
      if (!text.endsWith(tail)) return [run(text)];
      return [
        run(text.substring(0, text.length - _flag.length)),
        run(_flag, OmColors.accent),
      ];
    case ConnectCodeSyntax.json:
      final spans = <InlineSpan>[];
      var at = 0;
      for (final m in _jsonString.allMatches(text)) {
        if (m.start > at) spans.add(run(text.substring(at, m.start)));
        final literal = m[0]!;
        final Color? color;
        if (_jsonKey.matchAsPrefix(text, m.start) != null) {
          color = OmColors.fg2;
        } else if (literal == '"$_flag"') {
          color = OmColors.accent;
        } else {
          color = null;
        }
        spans.add(run(literal, color));
        at = m.end;
      }
      if (at < text.length) spans.add(run(text.substring(at)));
      return spans;
  }
}
