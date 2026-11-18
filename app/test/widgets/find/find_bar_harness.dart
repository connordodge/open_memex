// WI #82 (Spec #61 F2): the Find bar test host, shared by this WI's test
// files only (find_bar_test.dart, find_bar_layout_test.dart,
// find_bar_golden_test.dart). Helpers carry a `wi82` prefix.
//
// The host is `find_pump.dart`'s sized body holding a `Stack`, as F6's
// `_bodyOverlays` slot will: a recording `Listener` filling the body at the
// bottom (it stands in for `segment_pointer_layer.dart`), an editor
// `TextField` near the bottom left (a sibling field with its own selection),
// and the `FindBarOverlay` on top.
//
// Text lays out in the fonts the app ships: [wi82LoadFonts] registers the
// bundled JetBrains Mono and Inter Tight files under the names google_fonts
// gives OmType's TextStyles (as `version_label_fit_test.dart` does), so the
// counter forms and widths match design B4. `holdFontFetches()` still keeps
// google_fonts itself from loading or fetching anything.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/widgets/find/find_bar.dart';
import 'package:open_memex_app/src/widgets/find/find_keys.dart';

import '../../support/find_pump.dart';

/// The sibling editor field in the host body.
const Key wi82EditorKey = ValueKey<String>('wi82-editor');

/// The recording layer under the Find bar (fills the body).
const Key wi82UnderKey = ValueKey<String>('wi82-under');

/// The query of the seeded note: 12 matches in [wi82Twelve].
const String wi82Word = 'hydration';

/// One body segment holding [wi82Word] 12 times, one per line.
final List<FindSource> wi82Twelve = [
  FindSource(
    segment: 0,
    kind: FindSourceKind.body,
    text: List.generate(12, (i) => 'step $i: raise $wi82Word').join('\n'),
  ),
];

/// One body segment holding `x` [count] times.
List<FindSource> wi82Many(int count) => [
  FindSource(
    segment: 0,
    kind: FindSourceKind.body,
    text: List.filled(count, 'x').join(' '),
  ),
];

/// The 12 matches of [wi82Word] in [wi82Twelve], in order.
List<FindMatch> get wi82TwelveMatches => findMatches(wi82Twelve, wi82Word);

/// The editor field's text and the selection it starts with.
const String wi82EditorText = 'alpha beta gamma';
const TextSelection wi82EditorSelection = TextSelection(
  baseOffset: 6,
  extentOffset: 10,
);

/// What the Find bar called back with, and the presses the layer under it
/// saw.
class Wi82Calls {
  final List<FindMatch> steps = [];
  final List<FindMatch?> closes = [];
  int downs = 0;
}

/// The host body: the recording layer, the editor field and the Find bar.
class Wi82Body extends StatelessWidget {
  const Wi82Body({super.key, required this.calls, required this.editor});

  final Wi82Calls calls;
  final TextEditingController editor;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Stack(
      children: [
        Positioned.fill(
          child: Listener(
            key: wi82UnderKey,
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => calls.downs++,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          width: 150,
          child: TextField(key: wi82EditorKey, controller: editor),
        ),
        FindBarOverlay(
          bodyWidth: constraints.maxWidth,
          onStep: calls.steps.add,
          onClose: calls.closes.add,
        ),
      ],
    ),
  );
}

/// Everything a Find bar test needs after [wi82Pump].
class Wi82Rig {
  Wi82Rig(this.find, this.calls, this.editor);

  final FindPumpHarness find;
  final Wi82Calls calls;
  final TextEditingController editor;
}

/// Pumps [Wi82Body] through `pumpFind`, seeded with [sources] (default
/// [wi82Twelve]) and [query] (default [wi82Word]); [current] is the index of
/// the current match.
Future<Wi82Rig> wi82Pump(
  WidgetTester tester, {
  List<FindSource>? sources,
  String query = wi82Word,
  String? lastQuery,
  bool open = true,
  int? current,
  FindCaret? caret,
  double bodyWidth = findPumpBodyWidth,
}) async {
  final calls = Wi82Calls();
  final editor = TextEditingController(text: wi82EditorText)
    ..selection = wi82EditorSelection;
  addTearDown(editor.dispose);
  final h = await pumpFind(
    tester,
    child: Wi82Body(calls: calls, editor: editor),
    sources: sources ?? wi82Twelve,
    query: query,
    lastQuery: lastQuery,
    open: open,
    current: current,
    caret: caret,
    bodyWidth: bodyWidth,
  );
  if (open) {
    expect(wi82Box, findsOneWidget, reason: 'the open Find bar shows its box');
  }
  return Wi82Rig(h, calls, editor);
}

/// Lets focus, hover and border animations finish (fake time; no wall time).
Future<void> wi82Settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Finder get wi82Box => find.byKey(findBarKey);
Finder get wi82Field => find.byKey(findBarFieldKey);
Finder get wi82Counter => find.byKey(findBarCounterKey);
Finder get wi82Previous => find.byKey(findBarPreviousKey);
Finder get wi82Next => find.byKey(findBarNextKey);
Finder get wi82Close => find.byKey(findBarCloseKey);

/// The magnifier glyph inside the Find bar.
Finder get wi82Magnifier =>
    find.descendant(of: wi82Box, matching: wi82LucideIcon(LucideIcons.search));

/// An `Icon` showing the Lucide glyph [icon] in any Lucide weight family
/// (the weights share code points).
Finder wi82LucideIcon(IconData icon) => find.byWidgetPredicate(
  (w) =>
      w is Icon &&
      w.icon?.codePoint == icon.codePoint &&
      w.icon?.fontPackage == icon.fontPackage,
  description: 'Lucide icon ${icon.codePoint}',
);

/// The query field's `EditableText`.
EditableText wi82Editable(WidgetTester tester) {
  expect(wi82Field, findsOneWidget, reason: 'the Find bar shows its field');
  return tester.widget<EditableText>(
    find.descendant(
      of: wi82Field,
      matching: find.byType(EditableText),
      matchRoot: true,
    ),
  );
}

/// The sibling editor field's `EditableText`.
EditableText wi82EditorEditable(WidgetTester tester) =>
    tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(wi82EditorKey),
        matching: find.byType(EditableText),
      ),
    );

/// The body host's global rect.
Rect wi82Host(WidgetTester tester) =>
    tester.getRect(find.byKey(findPumpHostKey));

/// The counter's text (all its text runs joined), or null when there is no
/// counter in the tree.
String? wi82CounterText(WidgetTester tester) {
  if (wi82Counter.evaluate().isEmpty) return null;
  return tester
      .widgetList<RichText>(
        find.descendant(
          of: wi82Counter,
          matching: find.byType(RichText),
          matchRoot: true,
        ),
      )
      .map((t) => t.text.toPlainText())
      .join();
}

/// The colour the counter's text draws in.
Color? wi82CounterColour(WidgetTester tester) => tester
    .widget<RichText>(
      find
          .descendant(
            of: wi82Counter,
            matching: find.byType(RichText),
            matchRoot: true,
          )
          .first,
    )
    .text
    .style
    ?.color;

/// Whether the counter shows no text: absent, empty, or zero wide.
bool wi82CounterHidden(WidgetTester tester) {
  final text = wi82CounterText(tester);
  if (text == null) return true;
  return text.isEmpty || tester.getSize(wi82Counter).width == 0;
}

/// Every `Paint` colour (ARGB) the render object behind [of] and its
/// children paint with, recorded on a test canvas.
Set<int> wi82PaintColours(WidgetTester tester, Finder of) {
  final canvas = TestRecordingCanvas();
  final context = TestRecordingPaintingContext(canvas);
  tester.renderObject(of).paint(context, Offset.zero);
  context.dispose();
  return {
    for (final call in canvas.invocations)
      for (final arg in call.invocation.positionalArguments)
        if (arg is Paint) arg.color.toARGB32(),
  };
}

/// [c] as ARGB, to compare with [wi82PaintColours].
int wi82Argb(Color c) => c.toARGB32();

/// The colour of the icon inside the button [button].
Color? wi82IconColour(WidgetTester tester, Finder button) => tester
    .widget<Icon>(find.descendant(of: button, matching: find.byType(Icon)))
    .color;

/// Focuses the Find bar's query field (no pointer press).
Future<void> wi82FocusField(WidgetTester tester) async {
  await tester.showKeyboard(wi82Field);
  await tester.pump();
}

/// Focuses the sibling editor field and puts its selection back to
/// [wi82EditorSelection].
Future<void> wi82FocusEditor(WidgetTester tester, Wi82Rig rig) async {
  await tester.showKeyboard(find.byKey(wi82EditorKey));
  await tester.pump();
  rig.editor.selection = wi82EditorSelection;
  await tester.pump();
}

/// Sends one key down (or repeat, or up) as macOS does and returns whether
/// the framework handled it.
Future<bool> wi82KeyDown(WidgetTester tester, LogicalKeyboardKey key) =>
    tester.sendKeyDownEvent(key, platform: 'macos');

/// Registers the bundled JetBrains Mono and Inter Tight weights under the
/// family names google_fonts gives OmType's styles (`JetBrainsMono_regular`,
/// `JetBrainsMono_500`, ...) and, when [icons], the Lucide icon font, once
/// for the file.
void wi82LoadFonts({bool icons = false}) {
  setUpAll(() async {
    await _wi82LoadFamily('JetBrainsMono');
    await _wi82LoadFamily('InterTight');
    if (icons) {
      final lucide = FontLoader('packages/lucide_icons_flutter/Lucide')
        ..addFont(
          rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
        );
      await lucide.load();
    }
  });
}

const Map<int, String> _wi82Weights = {
  100: 'Thin',
  200: 'ExtraLight',
  300: 'Light',
  400: 'Regular',
  500: 'Medium',
  600: 'SemiBold',
  700: 'Bold',
  800: 'ExtraBold',
  900: 'Black',
};

Future<void> _wi82LoadFamily(String family) async {
  for (final MapEntry(key: weight, value: word) in _wi82Weights.entries) {
    final file = File('assets/google_fonts/$family-$word.ttf');
    if (!file.existsSync()) continue;
    final name = weight == 400 ? '${family}_regular' : '${family}_$weight';
    final loader = FontLoader(name)
      ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await loader.load();
  }
}
