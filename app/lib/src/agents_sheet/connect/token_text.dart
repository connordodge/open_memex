// WI #404 (Spec #394 req 26-27): how an access token reads in the Connect
// tab's snippets and token row. Pure Dart; holds no token beyond the one
// call that needs it.

/// The literal each snippet uses when the Keychain has no token for the
/// server (Spec #394 req 26).
const String accessTokenPlaceholder = 'paste-the-access-token-here';

/// The on-screen form of [token]: `•` × 28 followed by its last 4
/// characters, or `•` × 32 with nothing revealed when [token] is shorter
/// than 12 characters (Spec #394 req 26).
String maskToken(String token) {
  if (token.length < _minRevealLength) return '•' * 32;
  return '${'•' * 28}${_last4(token)}';
}

/// Tokens shorter than this reveal none of their characters.
const int _minRevealLength = 12;

String _last4(String token) => token.substring(token.length - 4);

/// The Semantics label of a masked [token]: `access token ending <last 4>`,
/// or `access token` when [token] is shorter than 12 characters.
String tokenSemanticsLabel(String token) {
  if (token.length < _minRevealLength) return 'access token';
  return 'access token ending ${_last4(token)}';
}

/// What a snippet substitutes where the access token goes: the masked form
/// (display), the real token (copy or revealed), or the placeholder (no
/// token in the Keychain).
///
/// No subclass has a `toString`, `==` or field that exposes a real token,
/// except [RealTokenText.text], which a caller reads only to build the one
/// snippet it copies or reveals.
sealed class TokenText {
  const TokenText();

  /// The text substituted into a snippet.
  String get text;
}

/// The masked token: keeps only [maskToken]'s output and its Semantics
/// label, never the token.
final class MaskedTokenText extends TokenText {
  MaskedTokenText(String token)
    : text = maskToken(token),
      semanticsLabel = tokenSemanticsLabel(token);

  @override
  final String text;

  /// [tokenSemanticsLabel] of the token this was built from.
  final String semanticsLabel;
}

/// The real token, for a copy or a revealed snippet. Its `toString` never
/// contains the token.
final class RealTokenText extends TokenText {
  RealTokenText(String token) : _token = token;

  final String _token;

  @override
  String get text => _token;

  @override
  String toString() => 'RealTokenText(<hidden>)';
}

/// [accessTokenPlaceholder], used when the Keychain has no token.
final class PlaceholderTokenText extends TokenText {
  const PlaceholderTokenText();

  @override
  String get text => accessTokenPlaceholder;
}
