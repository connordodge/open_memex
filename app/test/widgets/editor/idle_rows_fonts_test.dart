// WI #132 (Spec #122 Req 27, TD5), mutation batch 2: an idle code row
// listens to system font changes (its minimum line height is measured, and
// a font load moves it); an idle row of another kind does not.
//
// Counts, never times: `PerfCounters` `buildTextSpan` (one per idle row
// built) before and after a `fontsChange` system message. Text is synthetic.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/perf_counters.dart';
import '../../support/spelling_editor_pump.dart';
import '../../support/wi132_idle_rows.dart';

/// Delivers the platform's "system fonts changed" message.
Future<void> _t132FontsChange(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/system',
    const JSONMessageCodec().encodeMessage({
      'type': 'fontsChange',
      'data': <String, Object?>{},
    }),
    (_) {},
  );
  await tester.pump();
}

/// How many idle-row text spans a font change builds on [body], whose row
/// starting with [prefix] must be idle and of kind [kind].
Future<int> _t132FontRebuilds(
  WidgetTester tester, {
  required String body,
  required String prefix,
  required RowKind kind,
}) async {
  await pumpSpellingEditor(tester, body: body);
  final row = wi132RowOf(tester, prefix);
  expect(wi132Spec(tester, row).kind, kind, reason: 'fixture: $prefix kind');
  wi132ExpectIdle(tester, row, reason: 'fixture: the $prefix row');
  final before = PerfCounters.snapshot();
  await _t132FontsChange(tester);
  return PerfCounters.delta(before)['buildTextSpan']!;
}

void main() {
  holdFontFetches();

  testWidgets('a font change rebuilds an idle code row', (tester) async {
    final spans = await _t132FontRebuilds(
      tester,
      body: 'Prose line one\n```\ncode line one\n```\n- Anchor item\n',
      prefix: '```',
      kind: RowKind.code,
    );
    expect(
      spans,
      greaterThanOrEqualTo(1),
      reason: 'the idle code row listens to system fonts and builds again',
    );
  });

  testWidgets('a font change rebuilds no idle row that is not a code row', (
    tester,
  ) async {
    final spans = await _t132FontRebuilds(
      tester,
      body: 'Prose line one\n- Bullet item\n- Anchor item\n',
      prefix: '- Bullet item',
      kind: RowKind.bullet,
    );
    expect(spans, 0, reason: 'an idle prose or item row ignores system fonts');
  });
}
