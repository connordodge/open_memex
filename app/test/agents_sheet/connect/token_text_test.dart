// WI #404 (Spec #394 req 26-27): token masking, its Semantics label and the
// three TokenText forms a snippet substitutes.
//
// API under test (app/lib/src/agents_sheet/connect/token_text.dart):
//   String maskToken(String token)
//   String tokenSemanticsLabel(String token)
//   const String accessTokenPlaceholder
//   sealed class TokenText { String get text; }
//     MaskedTokenText(token) .text .semanticsLabel
//     RealTokenText(token)   .text
//     PlaceholderTokenText() .text
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/connect/token_text.dart';

/// Builds a token of [length] characters at run time, ending in [last4].
String _wi404Token(int length, String last4) {
  final head = List.generate(length - 4, (i) => 'abcdefghij'[i % 10]).join();
  return '$head$last4';
}

void main() {
  final dots28 = '•' * 28;
  final dots32 = '•' * 32;

  test('maskToken on 4 11 12 and 40 character tokens', () {
    final t4 = _wi404Token(4, 'wxyz');
    final t11 = _wi404Token(11, 'q9r8');
    final t12 = _wi404Token(12, '7f3a');
    final t40 = _wi404Token(40, 'c0de');
    expect(t4.length, 4);
    expect(t11.length, 11);
    expect(t12.length, 12);
    expect(t40.length, 40);

    expect(maskToken(t4), dots32);
    expect(maskToken(t11), dots32);
    expect(maskToken(t12), '${dots28}7f3a');
    expect(maskToken(t40), '${dots28}c0de');

    // The mask is a fixed 32 characters whatever the token length.
    for (final t in [t4, t11, t12, t40]) {
      expect(maskToken(t).length, 32, reason: 'length ${t.length}');
    }
    // A short token reveals none of its characters.
    expect(maskToken(t11), isNot(contains('q9r8')));
    expect(maskToken(t11), isNot(contains('8')));
  });

  test('tokenSemanticsLabel on 4 11 12 and 40 character tokens', () {
    expect(tokenSemanticsLabel(_wi404Token(4, 'wxyz')), 'access token');
    expect(tokenSemanticsLabel(_wi404Token(11, 'q9r8')), 'access token');
    expect(
      tokenSemanticsLabel(_wi404Token(12, '7f3a')),
      'access token ending 7f3a',
    );
    expect(
      tokenSemanticsLabel(_wi404Token(40, 'c0de')),
      'access token ending c0de',
    );
  });

  test(
    'MaskedTokenText keeps the mask and label of 4 11 12 and 40 character tokens',
    () {
      final cases = <(String, String, String)>[
        (_wi404Token(4, 'wxyz'), dots32, 'access token'),
        (_wi404Token(11, 'q9r8'), dots32, 'access token'),
        (_wi404Token(12, '7f3a'), '${dots28}7f3a', 'access token ending 7f3a'),
        (_wi404Token(40, 'c0de'), '${dots28}c0de', 'access token ending c0de'),
      ];
      for (final (token, text, label) in cases) {
        final masked = MaskedTokenText(token);
        expect(masked.text, text, reason: 'length ${token.length}');
        expect(masked.semanticsLabel, label, reason: 'length ${token.length}');
      }
    },
  );

  test(
    'RealTokenText gives the real token and PlaceholderTokenText the placeholder',
    () {
      final token = _wi404Token(40, '7f3a');
      expect(RealTokenText(token).text, token);

      expect(accessTokenPlaceholder, 'paste-the-access-token-here');
      expect(const PlaceholderTokenText().text, 'paste-the-access-token-here');
      // Built at run time too, so the constructor itself runs.
      final TokenText placeholder = [const PlaceholderTokenText()].first;
      expect(placeholder.text, accessTokenPlaceholder);
    },
  );

  test('no TokenText toString or masked field contains the sentinel token', () {
    const sentinel = 'SENTINEL-404-do-not-leak-0123456789-7f3a';
    final masked = MaskedTokenText(sentinel);
    final real = RealTokenText(sentinel);
    const placeholder = PlaceholderTokenText();

    // Positive anchors: each form carries what it should.
    expect(masked.text, '${dots28}7f3a');
    expect(masked.semanticsLabel, 'access token ending 7f3a');
    expect(real.text, sentinel);

    for (final shown in <String>[
      masked.toString(),
      '$masked',
      masked.text,
      masked.semanticsLabel,
      real.toString(),
      '$real',
      placeholder.toString(),
      maskToken(sentinel),
      tokenSemanticsLabel(sentinel),
    ]) {
      expect(shown, isNot(contains('SENTINEL')), reason: shown);
      expect(shown, isNot(contains(sentinel)), reason: shown);
    }
  });

  test('RealTokenText toString names the class and hides the token', () {
    final real = RealTokenText(_wi404Token(40, 'c0de'));
    expect(real.toString(), 'RealTokenText(<hidden>)');
    expect('$real', 'RealTokenText(<hidden>)');
  });
}
