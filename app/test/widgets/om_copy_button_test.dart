// WI #406 (Spec #394 req 31 and 46, ruling D9, design pack #406 and
// RULINGS #2-#4): the shared `OmCopyButton`. Plain copies go through
// `Clipboard.setData`; sensitive ones through `copySensitive` on
// `open_memex/files`, falling back to `Clipboard.setData` once on any
// channel failure. After a copy it shows `Copied` for exactly 2 s on the app
// clock and announces `copied` once. Every platform channel is mocked through
// `TestDefaultBinaryMessenger`; time comes from `FakeClock`, never wall time.
import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/vault_trash.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/om_copy_button.dart';

import '../support/fake_clock.dart';
import '../support/font_fetch_hold.dart';

/// How the mocked native `copySensitive` answers.
enum _Wi406Native { ok, platformError, missingPlugin }

/// Everything the button sent to the platform during one test.
class _Wi406Rig {
  _Wi406Rig(this.clock);

  final FakeClock clock;

  /// `text` of every `Clipboard.setData` call, in order.
  final clipboard = <String>[];

  /// The argument of every `copySensitive` call, in order.
  final sensitive = <Object?>[];

  /// The data map of every `announce` accessibility event, in order.
  final announcements = <Map<Object?, Object?>>[];

  _Wi406Native native = _Wi406Native.ok;

  /// When set, `Clipboard.setData` / `copySensitive` reply only once it
  /// completes (a copy still in flight).
  Completer<void>? holdClipboard;
  Completer<void>? holdSensitive;

  int get copies => clipboard.length + sensitive.length;

  List<String> get announced => [
    for (final a in announcements) a['message'] as String,
  ];
}

Widget _wi406App(FakeClock clock, Widget child, {bool loose = false}) =>
    ProviderScope(
      overrides: [clockProvider.overrideWithValue(clock)],
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          // `loose` hands the button plain bounded, loose constraints, as a
          // real parent does; otherwise an unbounded width.
          body: Center(child: loose ? child : UnconstrainedBox(child: child)),
        ),
      ),
    );

Future<_Wi406Rig> _wi406Pump(
  WidgetTester tester,
  Widget button, {
  _Wi406Native native = _Wi406Native.ok,
  bool loose = false,
}) async {
  final rig = _Wi406Rig(FakeClock())..native = native;
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      final args = call.arguments as Map<Object?, Object?>;
      rig.clipboard.add(args['text'] as String);
      final hold = rig.holdClipboard;
      if (hold != null) await hold.future;
    }
    return null;
  });
  messenger.setMockMethodCallHandler(vaultFilesChannel, (call) async {
    if (call.method != 'copySensitive') return null;
    rig.sensitive.add(call.arguments);
    final hold = rig.holdSensitive;
    if (hold != null) await hold.future;
    switch (rig.native) {
      case _Wi406Native.ok:
        return null;
      case _Wi406Native.platformError:
        // The message carries the value: logging the exception would leak it.
        throw PlatformException(
          code: 'copy_failed',
          message: 'could not copy ${call.arguments}',
          details: call.arguments,
        );
      case _Wi406Native.missingPlugin:
        throw MissingPluginException('no copySensitive for ${call.arguments}');
    }
  });
  messenger.setMockDecodedMessageHandler<Object?>(
    SystemChannels.accessibility,
    (message) async {
      final m = message! as Map<Object?, Object?>;
      if (m['type'] == 'announce') {
        rig.announcements.add(m['data']! as Map<Object?, Object?>);
      }
      return null;
    },
  );
  addTearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(vaultFilesChannel, null);
    messenger.setMockDecodedMessageHandler<Object?>(
      SystemChannels.accessibility,
      null,
    );
  });
  await tester.pumpWidget(_wi406App(rig.clock, button, loose: loose));
  return rig;
}

final _wi406Button = find.byType(OmCopyButton);

/// The device id `TestPointer` gives a mouse.
const _wi406MouseDevice = 1;

/// Lets an in-flight copy (and a fallback after a channel failure) finish
/// without moving the fake clock.
Future<void> _wi406Settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  // Long enough for any implicit colour or switcher animation to end.
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _wi406Press(WidgetTester tester) async {
  await tester.tap(_wi406Button, warnIfMissed: false);
  await _wi406Settle(tester);
}

/// The button's own filled, bordered box.
BoxDecoration _wi406Box(WidgetTester tester) {
  final boxes = tester
      .widgetList<DecoratedBox>(
        find.descendant(
          of: _wi406Button,
          matching: find.byType(DecoratedBox),
          matchRoot: true,
        ),
      )
      .map((d) => d.decoration)
      .whereType<BoxDecoration>()
      .where((d) => d.color != null && d.border != null)
      .toList();
  expect(
    boxes,
    isNotEmpty,
    reason: 'OmCopyButton draws a filled, bordered box',
  );
  return boxes.first;
}

BorderSide _wi406Side(WidgetTester tester) {
  final border = _wi406Box(tester).border;
  expect(border, isA<Border>(), reason: 'a uniform 1 px border');
  return (border! as Border).top;
}

/// The effective text style a [Text] or [Icon] is painted with.
TextStyle _wi406Painted(WidgetTester tester, Finder of) {
  final paragraphs = find.descendant(
    of: of,
    matching: find.byType(RichText),
    matchRoot: true,
  );
  expect(paragraphs, findsWidgets, reason: '$of paints text');
  return tester.renderObject<RenderParagraph>(paragraphs.first).text.style!;
}

bool _wi406Focused() {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  return find
      .descendant(
        of: _wi406Button,
        matching: find.byElementPredicate((e) => identical(e, focused)),
        matchRoot: true,
      )
      .evaluate()
      .isNotEmpty;
}

Future<void> _wi406TabTo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (_wi406Focused()) return;
  }
  fail('Tab never reached OmCopyButton: it is not a keyboard focus stop');
}

/// The one semantics node labelled exactly [label].
SemanticsNode _wi406Node(String label) {
  final nodes = find.semantics.byLabel(label).evaluate().toList();
  expect(
    nodes,
    hasLength(1),
    reason: 'one semantics node labelled exactly "$label"',
  );
  return nodes.single;
}

void main() {
  holdFontFetches();

  const configLabel = 'Copy Claude Desktop config';

  OmCopyButton plain({
    FutureOr<String> Function()? text,
    String semanticLabel = configLabel,
    String label = 'Copy',
    bool showIcon = true,
  }) => OmCopyButton(
    text: text ?? () => 'the snippet',
    semanticLabel: semanticLabel,
    label: label,
    showIcon: showIcon,
  );

  OmCopyButton sensitive({FutureOr<String> Function()? text}) => OmCopyButton(
    text: text ?? () => 'tok-secret-1234',
    semanticLabel: 'Copy access token',
    sensitive: true,
  );

  group('plain copy', () {
    testWidgets(
      'a plain press calls Clipboard.setData once with the text and never copySensitive',
      (tester) async {
        // `sensitive` left at its default.
        final rig = await _wi406Pump(
          tester,
          OmCopyButton(
            text: () => '{"mcpServers": {}}',
            semanticLabel: configLabel,
          ),
        );

        await _wi406Press(tester);

        expect(rig.clipboard, ['{"mcpServers": {}}']);
        expect(rig.sensitive, isEmpty, reason: 'no copySensitive call');
      },
    );
  });

  group('sensitive copy', () {
    testWidgets(
      'a sensitive press calls copySensitive once with the value and never Clipboard.setData',
      (tester) async {
        final rig = await _wi406Pump(
          tester,
          sensitive(text: () => 'tok-abcdefgh-9876'),
        );

        await _wi406Press(tester);

        expect(rig.sensitive, ['tok-abcdefgh-9876']);
        expect(rig.clipboard, isEmpty, reason: 'copySensitive succeeded');
      },
    );

    for (final (name, native) in [
      (
        'a PlatformException from copySensitive falls back to Clipboard.setData once and logs nothing of the value',
        _Wi406Native.platformError,
      ),
      (
        'a MissingPluginException from copySensitive falls back to Clipboard.setData once and logs nothing of the value',
        _Wi406Native.missingPlugin,
      ),
    ]) {
      testWidgets(name, (tester) async {
        const value = 'SENTINEL-406-token-do-not-log';
        final logs = <String>[];
        final rig = await _wi406Pump(
          tester,
          sensitive(text: () => value),
          native: native,
        );

        final previousDebugPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) =>
            logs.add(message ?? '');
        try {
          await runZoned(
            () => _wi406Press(tester),
            zoneSpecification: ZoneSpecification(
              print: (self, parent, zone, line) => logs.add(line),
            ),
          );
        } finally {
          debugPrint = previousDebugPrint;
        }

        expect(rig.sensitive, [value], reason: 'copySensitive tried once');
        expect(rig.clipboard, [value], reason: 'one fallback copy');
        expect(
          logs.where((l) => l.contains(value)),
          isEmpty,
          reason: 'the value never reaches print or debugPrint',
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('text() at press time', () {
    testWidgets('text() is called once per press and never at build time', (
      tester,
    ) async {
      var calls = 0;
      String text() => 'value ${++calls}';
      final rig = await _wi406Pump(tester, plain(text: text));
      expect(calls, 0, reason: 'not read at build');

      // Rebuilds (a new widget, a hover) never read it either.
      await tester.pumpWidget(
        _wi406App(
          rig.clock,
          plain(text: text, semanticLabel: 'Copy MCP address'),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(_wi406Button));
      await tester.pump();
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(calls, 0, reason: 'not read on rebuild or hover');

      await _wi406Press(tester);
      expect(calls, 1);
      expect(rig.clipboard, ['value 1']);

      rig.clock.advance(const Duration(seconds: 2));
      await _wi406Settle(tester);
      expect(calls, 1, reason: 'reverting reads nothing');

      await _wi406Press(tester);
      expect(calls, 2);
      expect(rig.clipboard, ['value 1', 'value 2'], reason: 'read afresh');
    });
  });

  group('Copied state', () {
    testWidgets(
      'after a copy it shows Copied with a check and reverts after exactly 2 s on the fake clock',
      (tester) async {
        final rig = await _wi406Pump(tester, plain());
        expect(find.text('Copy'), findsOneWidget);
        expect(find.byIcon(LucideIcons.copy), findsOneWidget);

        await _wi406Press(tester);
        expect(find.text('Copied'), findsOneWidget);
        expect(find.text('Copy'), findsNothing);
        expect(find.byIcon(LucideIcons.check), findsOneWidget);
        expect(find.byIcon(LucideIcons.copy), findsNothing);

        // Test time passing (not the app clock) changes nothing.
        await tester.pump(const Duration(seconds: 5));
        expect(find.text('Copied'), findsOneWidget, reason: 'app clock only');

        rig.clock.advance(const Duration(milliseconds: 1900));
        await _wi406Settle(tester);
        expect(find.text('Copied'), findsOneWidget, reason: 'at 1.9 s');

        rig.clock.advance(const Duration(milliseconds: 99));
        await _wi406Settle(tester);
        expect(find.text('Copied'), findsOneWidget, reason: 'at 1.999 s');

        rig.clock.advance(const Duration(milliseconds: 1));
        await _wi406Settle(tester);
        expect(find.text('Copied'), findsNothing, reason: 'at 2.0 s');
        expect(find.text('Copy'), findsOneWidget);
        expect(find.byIcon(LucideIcons.copy), findsOneWidget);
        expect(find.byIcon(LucideIcons.check), findsNothing);
      },
    );

    testWidgets(
      'a second copy while Copied copies again and restarts the 2 s window',
      (tester) async {
        final rig = await _wi406Pump(tester, plain());

        await _wi406Press(tester);
        rig.clock.advance(const Duration(milliseconds: 1500));
        await _wi406Settle(tester);
        expect(find.text('Copied'), findsOneWidget);

        await _wi406Press(tester);
        expect(rig.clipboard, hasLength(2), reason: 'a fresh press copies');
        expect(
          rig.clock.pendingTimers,
          1,
          reason: 'the old window is cancelled',
        );

        rig.clock.advance(const Duration(milliseconds: 1500));
        await _wi406Settle(tester);
        expect(
          find.text('Copied'),
          findsOneWidget,
          reason: '1.5 s after the second copy, 3 s after the first',
        );

        rig.clock.advance(const Duration(milliseconds: 500));
        await _wi406Settle(tester);
        expect(find.text('Copied'), findsNothing);
        expect(find.text('Copy'), findsOneWidget);
      },
    );

    testWidgets('disposing while Copied cancels the revert timer', (
      tester,
    ) async {
      final rig = await _wi406Pump(tester, plain());
      await _wi406Press(tester);
      expect(find.text('Copied'), findsOneWidget);
      expect(
        rig.clock.pendingTimers,
        1,
        reason: 'the 2 s window is on the app clock',
      );

      await tester.pumpWidget(_wi406App(rig.clock, const SizedBox()));
      expect(rig.clock.pendingTimers, 0);

      rig.clock.advance(const Duration(seconds: 3));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a custom label shows idle, Copied after a copy, and comes back',
      (tester) async {
        final rig = await _wi406Pump(
          tester,
          plain(label: 'Copy config', semanticLabel: 'Copy config'),
        );
        expect(find.text('Copy config'), findsOneWidget);
        expect(find.text('Copy'), findsNothing);

        await _wi406Press(tester);
        expect(find.text('Copied'), findsOneWidget);
        expect(find.text('Copy config'), findsNothing);

        rig.clock.advance(const Duration(seconds: 2));
        await _wi406Settle(tester);
        expect(find.text('Copy config'), findsOneWidget);
      },
    );

    testWidgets(
      'with showIcon false the button shows no icon, idle or Copied',
      (tester) async {
        final rig = await _wi406Pump(
          tester,
          plain(showIcon: false, semanticLabel: 'Copy access token'),
        );
        expect(find.text('Copy'), findsOneWidget);
        expect(find.byType(Icon), findsNothing);

        await _wi406Press(tester);
        expect(find.text('Copied'), findsOneWidget);
        expect(find.byType(Icon), findsNothing, reason: 'label only (.sm.ok)');
        expect(_wi406Box(tester).color, OmColors.copiedBg);
        expect(
          _wi406Painted(tester, find.text('Copied')).color,
          OmColors.accent,
        );

        rig.clock.advance(const Duration(seconds: 2));
        await _wi406Settle(tester);
        expect(find.text('Copy'), findsOneWidget);
        expect(find.byType(Icon), findsNothing);
      },
    );
  });

  group('announcement', () {
    for (final (name, isSensitive) in [
      ('each plain copy sends one copied announcement', false),
      ('each sensitive copy sends one copied announcement', true),
    ]) {
      testWidgets(name, (tester) async {
        final rig = await _wi406Pump(
          tester,
          isSensitive ? sensitive() : plain(),
        );
        expect(rig.announcements, isEmpty, reason: 'nothing at build');

        await _wi406Press(tester);
        expect(rig.announced, ['copied']);
        final data = rig.announcements.single;
        expect(data['textDirection'], TextDirection.ltr.index);
        expect(data['viewId'], tester.view.viewId);

        rig.clock.advance(const Duration(seconds: 2));
        await _wi406Settle(tester);
        expect(rig.announced, [
          'copied',
        ], reason: 'reverting announces nothing');

        await _wi406Press(tester);
        expect(rig.announced, ['copied', 'copied']);
      });
    }
  });

  group('busy guard and key repeats', () {
    testWidgets('two plain presses in the same frame make one copy', (
      tester,
    ) async {
      final rig = await _wi406Pump(tester, plain());
      rig.holdClipboard = Completer<void>();

      await tester.tap(_wi406Button, warnIfMissed: false);
      await tester.tap(_wi406Button, warnIfMissed: false);
      await tester.pump();
      expect(
        rig.clipboard,
        hasLength(1),
        reason: 'the second press is ignored',
      );

      rig.holdClipboard!.complete();
      await _wi406Settle(tester);
      expect(rig.clipboard, hasLength(1));
      expect(rig.announced, ['copied']);
    });

    testWidgets('two sensitive presses in the same frame make one copy', (
      tester,
    ) async {
      final rig = await _wi406Pump(tester, sensitive());
      rig.holdSensitive = Completer<void>();

      await tester.tap(_wi406Button, warnIfMissed: false);
      await tester.tap(_wi406Button, warnIfMissed: false);
      await tester.pump();
      expect(
        rig.sensitive,
        hasLength(1),
        reason: 'the second press is ignored',
      );

      rig.holdSensitive!.complete();
      await _wi406Settle(tester);
      expect(rig.copies, 1);
      expect(rig.announced, ['copied']);
    });

    testWidgets('two Enter presses in the same frame make one copy', (
      tester,
    ) async {
      final rig = await _wi406Pump(tester, plain());
      await _wi406TabTo(tester);
      rig.holdClipboard = Completer<void>();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(rig.clipboard, hasLength(1));

      rig.holdClipboard!.complete();
      await _wi406Settle(tester);
      expect(rig.clipboard, hasLength(1));
    });

    for (final (name, key) in [
      (
        'a held Enter with KeyRepeatEvents makes one copy',
        LogicalKeyboardKey.enter,
      ),
      (
        'a held Space with KeyRepeatEvents makes one copy',
        LogicalKeyboardKey.space,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final rig = await _wi406Pump(tester, plain());
        await _wi406TabTo(tester);

        await tester.sendKeyDownEvent(key);
        await _wi406Settle(tester);
        expect(rig.clipboard, hasLength(1), reason: 'the key down copies');

        await tester.sendKeyRepeatEvent(key);
        await tester.sendKeyRepeatEvent(key);
        await _wi406Settle(tester);
        await tester.sendKeyRepeatEvent(key);
        await tester.sendKeyUpEvent(key);
        await _wi406Settle(tester);

        expect(rig.clipboard, hasLength(1), reason: 'repeats are ignored');
        expect(rig.announced, ['copied']);
      });
    }

    testWidgets('a KeyRepeatEvent alone copies nothing', (tester) async {
      final rig = await _wi406Pump(tester, plain());
      await _wi406TabTo(tester);

      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await _wi406Settle(tester);

      expect(rig.copies, 0);
      expect(find.text('Copy'), findsOneWidget);
    });
  });

  group('keyboard', () {
    for (final (name, key) in [
      ('Enter on the focused button copies once', LogicalKeyboardKey.enter),
      ('Space on the focused button copies once', LogicalKeyboardKey.space),
    ]) {
      testWidgets(name, (tester) async {
        final rig = await _wi406Pump(tester, plain());
        await _wi406TabTo(tester);

        await tester.sendKeyEvent(key);
        await _wi406Settle(tester);

        expect(rig.clipboard, ['the snippet']);
        expect(find.text('Copied'), findsOneWidget);
      });
    }

    testWidgets('other keys on the focused button copy nothing', (
      tester,
    ) async {
      final rig = await _wi406Pump(tester, plain());
      await _wi406TabTo(tester);

      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.arrowDown,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await _wi406Settle(tester);

      expect(rig.copies, 0);
    });
  });

  group('semantics', () {
    testWidgets(
      'the button is one semantics button labelled semanticLabel, not the visible Copy',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _wi406Pump(tester, plain());

        final node = _wi406Node(configLabel);
        expect(node, isSemantics(label: configLabel, isButton: true));
        expect(
          node.childrenCount,
          0,
          reason: 'a leaf: the visible label and icon are excluded',
        );
        expect(
          find.semantics.byLabel('Copy').evaluate(),
          isEmpty,
          reason: 'the visible label is not a semantics label',
        );
        expect(
          find.semantics.byLabel(RegExp('Copy\$')).evaluate(),
          isEmpty,
          reason: 'nor merged into another label',
        );
        handle.dispose();
      },
    );

    testWidgets(
      'the semantics label stays semanticLabel while Copied and the node stays a leaf',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _wi406Pump(tester, sensitive());

        await _wi406Press(tester);
        expect(find.text('Copied'), findsOneWidget);

        final node = _wi406Node('Copy access token');
        expect(node, isSemantics(isButton: true));
        expect(node.childrenCount, 0);
        expect(find.semantics.byLabel(RegExp('Copied')).evaluate(), isEmpty);
        handle.dispose();
      },
    );

    testWidgets('a semantics tap (VoiceOver activate) copies once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final rig = await _wi406Pump(tester, plain());

      final node = _wi406Node(configLabel);
      expect(node, isSemantics(hasTapAction: true));
      tester.semantics.tap(find.semantics.byLabel(configLabel));
      await _wi406Settle(tester);

      expect(rig.clipboard, ['the snippet']);
      expect(rig.announced, ['copied']);
      handle.dispose();
    });
  });

  group('look', () {
    testWidgets(
      'idle: 24 high, radius 6, surface3 fill, line2 border, fg1 11.5 w500 label, 12 px copy icon',
      (tester) async {
        await _wi406Pump(tester, plain());
        // First frame: not hovered, not copied.

        expect(tester.getSize(_wi406Button).height, 24);
        final box = _wi406Box(tester);
        expect(box.color, OmColors.surface3);
        expect(box.borderRadius, BorderRadius.circular(6));
        final side = _wi406Side(tester);
        expect(side.color, OmColors.line2);
        expect(side.width, 1);

        final label = _wi406Painted(tester, find.text('Copy'));
        expect(label.color, OmColors.fg1);
        expect(label.fontSize, 11.5);
        expect(label.fontWeight, FontWeight.w500);
        expect(label.height, 1.0);

        final icon = find.byIcon(LucideIcons.copy);
        expect(tester.getSize(icon), const Size(12, 12));
        expect(_wi406Painted(tester, icon).color, OmColors.fg1);
      },
    );

    testWidgets(
      'idle spacing: 1 px border plus 8 padding each side and a 5 px icon gap',
      (tester) async {
        await _wi406Pump(tester, plain());

        final button = tester.getRect(_wi406Button);
        final icon = tester.getRect(find.byIcon(LucideIcons.copy));
        final label = tester.getRect(find.text('Copy'));
        expect(icon.left - button.left, 9);
        expect(label.left - icon.right, 5);
        expect(button.right - label.right, 9);
      },
    );

    testWidgets(
      'without the icon the label sits 1 px border plus 8 padding from each side',
      (tester) async {
        await _wi406Pump(tester, plain(showIcon: false));

        final button = tester.getRect(_wi406Button);
        final label = tester.getRect(find.text('Copy'));
        expect(label.left - button.left, 9);
        expect(button.right - label.right, 9);
        expect(button.height, 24);
      },
    );

    testWidgets(
      'Copied: copiedBg fill, accentLine border, accent label and check',
      (tester) async {
        await _wi406Pump(tester, plain());
        await _wi406Press(tester);

        expect(tester.getSize(_wi406Button).height, 24);
        final box = _wi406Box(tester);
        expect(box.color, OmColors.copiedBg);
        expect(box.borderRadius, BorderRadius.circular(6));
        final side = _wi406Side(tester);
        expect(side.color, OmColors.accentLine);
        expect(side.width, 1);

        final label = _wi406Painted(tester, find.text('Copied'));
        expect(label.color, OmColors.accent);
        expect(label.fontSize, 11.5);
        expect(label.fontWeight, FontWeight.w500);

        final check = find.byIcon(LucideIcons.check);
        expect(tester.getSize(check), const Size(12, 12));
        expect(_wi406Painted(tester, check).color, OmColors.accent);
      },
    );

    testWidgets('hover fills surface4 on mouse in and surface3 on mouse out', (
      tester,
    ) async {
      await _wi406Pump(tester, plain());
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();
      expect(_wi406Box(tester).color, OmColors.surface3);

      await mouse.moveTo(tester.getCenter(_wi406Button));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_wi406Box(tester).color, OmColors.surface4, reason: 'mouse in');

      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_wi406Box(tester).color, OmColors.surface3, reason: 'mouse out');
    });
  });

  group('verify: contracts the first pass left unpinned', () {
    testWidgets('numpad Enter on the focused button copies once', (
      tester,
    ) async {
      final rig = await _wi406Pump(tester, plain());
      await _wi406TabTo(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await _wi406Settle(tester);

      expect(rig.clipboard, ['the snippet']);
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets(
      'Enter and Space down, repeat and up are consumed, other keys pass to the parent',
      (tester) async {
        final seen = <LogicalKeyboardKey>[];
        final rig = await _wi406Pump(
          tester,
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (node, event) {
              seen.add(event.logicalKey);
              return KeyEventResult.ignored;
            },
            child: plain(),
          ),
        );
        await _wi406TabTo(tester);

        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.space,
        ]) {
          await tester.sendKeyDownEvent(key);
          await tester.sendKeyRepeatEvent(key);
          await tester.sendKeyUpEvent(key);
          await _wi406Settle(tester);
        }
        expect(rig.copies, 3, reason: 'three key downs, three copies');
        expect(
          seen.where((k) => k != LogicalKeyboardKey.tab),
          isEmpty,
          reason: 'activation keys never reach an ancestor',
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        expect(seen.where((k) => k != LogicalKeyboardKey.tab), [
          LogicalKeyboardKey.keyA,
          LogicalKeyboardKey.keyA,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowDown,
        ], reason: 'other keys bubble up (down and up events)');
        expect(rig.copies, 3);
      },
    );

    testWidgets('hovering while Copied keeps the Copied fill', (tester) async {
      final rig = await _wi406Pump(tester, plain());
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await _wi406Press(tester);
      expect(_wi406Box(tester).color, OmColors.copiedBg);

      await mouse.moveTo(tester.getCenter(_wi406Button));
      await _wi406Settle(tester);
      expect(
        _wi406Box(tester).color,
        OmColors.copiedBg,
        reason: 'Copied wins over hover',
      );

      rig.clock.advance(const Duration(seconds: 2));
      await _wi406Settle(tester);
      expect(
        _wi406Box(tester).color,
        OmColors.surface4,
        reason: 'still hovered once Copied reverts',
      );
    });

    testWidgets('the pointer is a click cursor over the button only', (
      tester,
    ) async {
      await _wi406Pump(tester, plain());
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();
      final tracker = RendererBinding.instance.mouseTracker;
      expect(
        tracker.debugDeviceActiveCursor(_wi406MouseDevice),
        isNot(SystemMouseCursors.click),
      );

      await mouse.moveTo(tester.getCenter(_wi406Button));
      await tester.pump();
      expect(
        tracker.debugDeviceActiveCursor(_wi406MouseDevice),
        SystemMouseCursors.click,
      );
    });

    testWidgets('the semantics node is focusable and follows keyboard focus', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final other = FocusNode(debugLabel: 'elsewhere');
      addTearDown(other.dispose);
      await _wi406Pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            plain(),
            Focus(focusNode: other, child: const SizedBox(height: 10)),
          ],
        ),
      );

      expect(
        _wi406Node(configLabel),
        isSemantics(isButton: true, isFocusable: true, isFocused: false),
        reason: 'idle: focusable, not focused (first frame)',
      );

      await _wi406TabTo(tester);
      await _wi406Settle(tester);
      expect(
        _wi406Node(configLabel),
        isSemantics(isButton: true, isFocusable: true, isFocused: true),
      );

      other.requestFocus();
      await _wi406Settle(tester);
      expect(
        _wi406Node(configLabel),
        isSemantics(isButton: true, isFocusable: true, isFocused: false),
        reason: 'focus moved away',
      );
      handle.dispose();
    });

    testWidgets(
      'the button stays its own semantics node under a labelled parent',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _wi406Pump(
          tester,
          Semantics(label: 'Config panel', child: plain()),
        );
        expect(_wi406Node(configLabel), isSemantics(isButton: true));
        expect(_wi406Node('Config panel'), isSemantics(isButton: false));
        handle.dispose();
      },
    );

    testWidgets(
      'disposing while a copy is in flight makes no Copied, timer or announcement',
      (tester) async {
        final rig = await _wi406Pump(tester, plain());
        rig.holdClipboard = Completer<void>();

        await tester.tap(_wi406Button, warnIfMissed: false);
        await tester.pump();
        expect(rig.clipboard, hasLength(1));

        await tester.pumpWidget(_wi406App(rig.clock, const SizedBox()));
        rig.holdClipboard!.complete();
        await _wi406Settle(tester);

        expect(rig.clock.pendingTimers, 0);
        expect(rig.announced, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the busy guard is released after a copy so a later press copies again',
      (tester) async {
        final rig = await _wi406Pump(tester, sensitive());
        await _wi406Press(tester);
        expect(find.text('Copied'), findsOneWidget);
        rig.clock.advance(const Duration(seconds: 2));
        await _wi406Settle(tester);

        // The busy guard is released after a copy: a later press copies again.
        rig.native = _Wi406Native.platformError;
        await _wi406Press(tester);
        expect(rig.sensitive, hasLength(2));
        expect(rig.clipboard, hasLength(1), reason: 'one fallback');
        expect(find.text('Copied'), findsOneWidget);
      },
    );
  });

  group('verify r1: async text, focus look, content width', () {
    testWidgets(
      'an async text() is read once for two presses, copies after it resolves',
      (tester) async {
        final read = Completer<String>();
        var reads = 0;
        final rig = await _wi406Pump(
          tester,
          plain(
            text: () {
              reads++;
              return read.future;
            },
          ),
        );

        await tester.tap(_wi406Button, warnIfMissed: false);
        await tester.tap(_wi406Button, warnIfMissed: false);
        await tester.pump();
        expect(reads, 1, reason: 'the second press is ignored while reading');
        expect(rig.copies, 0, reason: 'nothing copied before the read ends');
        expect(find.text('Copy'), findsOneWidget, reason: 'still idle');
        expect(find.text('Copied'), findsNothing);

        read.complete('late value');
        await _wi406Settle(tester);
        expect(reads, 1);
        expect(rig.clipboard, ['late value']);
        expect(find.text('Copied'), findsOneWidget);
        expect(rig.announced, ['copied']);

        // The guard is released afterwards.
        rig.clock.advance(const Duration(seconds: 2));
        await _wi406Settle(tester);
        await _wi406Press(tester);
        expect(reads, 2);
      },
    );

    testWidgets('an async sensitive text() copies concealed once it resolves', (
      tester,
    ) async {
      final read = Completer<String>();
      final rig = await _wi406Pump(tester, sensitive(text: () => read.future));

      await tester.tap(_wi406Button, warnIfMissed: false);
      await tester.pump();
      expect(rig.copies, 0);

      read.complete('keychain-token');
      await _wi406Settle(tester);
      expect(rig.sensitive, ['keychain-token']);
      expect(rig.clipboard, isEmpty);
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets(
      'disposing during an async text() read copies nothing and starts no timer',
      (tester) async {
        final read = Completer<String>();
        final rig = await _wi406Pump(tester, plain(text: () => read.future));

        await tester.tap(_wi406Button, warnIfMissed: false);
        await tester.pump();
        await tester.pumpWidget(_wi406App(rig.clock, const SizedBox()));

        read.complete('too late');
        await _wi406Settle(tester);
        expect(rig.copies, 0, reason: 'a removed button copies nothing');
        expect(rig.announced, isEmpty);
        expect(rig.clock.pendingTimers, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a sync text() still copies in the same press', (tester) async {
      final rig = await _wi406Pump(tester, plain(text: () => 'sync'));
      await tester.tap(_wi406Button, warnIfMissed: false);
      await tester.pump();
      expect(rig.clipboard, ['sync']);
    });

    DecoratedBox? foreground(WidgetTester tester) {
      final boxes = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: _wi406Button,
              matching: find.byType(DecoratedBox),
            ),
          )
          .where((d) => d.position == DecorationPosition.foreground)
          .toList();
      expect(boxes.length, lessThanOrEqualTo(1));
      return boxes.isEmpty ? null : boxes.single;
    }

    void resetHighlight() => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic;

    testWidgets(
      'keyboard focus draws a 2 px inside accent ring and the surface4 fill',
      (tester) async {
        addTearDown(resetHighlight);
        final other = FocusNode(debugLabel: 'elsewhere');
        addTearDown(other.dispose);
        final rig = await _wi406Pump(
          tester,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              plain(),
              Focus(focusNode: other, child: const SizedBox(height: 10)),
            ],
          ),
        );
        expect(foreground(tester), isNull, reason: 'no ring before focus');
        expect(_wi406Box(tester).color, OmColors.surface3);
        final size = tester.getSize(_wi406Button);

        await _wi406TabTo(tester);
        await _wi406Settle(tester);
        expect(
          _wi406Box(tester).color,
          OmColors.surface4,
          reason: 'focus fill',
        );
        final ring = foreground(tester)!.decoration as BoxDecoration;
        final side = (ring.border! as Border).top;
        expect(side.color, OmColors.accent);
        expect(side.width, 2);
        expect(side.strokeAlign, BorderSide.strokeAlignInside);
        expect(ring.borderRadius, BorderRadius.circular(6));
        expect(
          tester.getSize(_wi406Button),
          size,
          reason: 'the ring never changes the size',
        );
        expect(
          _wi406Side(tester).color,
          OmColors.line2,
          reason: '1 px border stays',
        );

        // Copied wins the fill over focus; the ring stays while focused.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _wi406Settle(tester);
        expect(rig.copies, 1);
        expect(_wi406Box(tester).color, OmColors.copiedBg);
        expect(foreground(tester), isNotNull);

        rig.clock.advance(const Duration(seconds: 2));
        await _wi406Settle(tester);
        expect(
          _wi406Box(tester).color,
          OmColors.surface4,
          reason: 'focus again',
        );

        other.requestFocus();
        await _wi406Settle(tester);
        expect(foreground(tester), isNull, reason: 'ring leaves with focus');
        expect(_wi406Box(tester).color, OmColors.surface3);
      },
    );

    testWidgets(
      'the focus ring and fill show only in keyboard highlight mode',
      (tester) async {
        addTearDown(resetHighlight);
        await _wi406Pump(tester, plain());
        await _wi406TabTo(tester);
        await _wi406Settle(tester);
        expect(foreground(tester), isNotNull);

        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTouch;
        await _wi406Settle(tester);
        expect(_wi406Focused(), isTrue, reason: 'still focused');
        expect(foreground(tester), isNull, reason: 'no ring in touch mode');
        expect(_wi406Box(tester).color, OmColors.surface3);

        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        await _wi406Settle(tester);
        expect(foreground(tester), isNotNull, reason: 'ring back');
        expect(_wi406Box(tester).color, OmColors.surface4);
      },
    );

    testWidgets('a hovered, unfocused button has no ring', (tester) async {
      await _wi406Pump(tester, plain());
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(_wi406Button));
      await _wi406Settle(tester);
      expect(_wi406Box(tester).color, OmColors.surface4);
      expect(foreground(tester), isNull);
    });

    testWidgets(
      'focus adds no semantics node of its own: one node is focused, the labelled button',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _wi406Pump(tester, plain());
        await _wi406TabTo(tester);
        await _wi406Settle(tester);

        final focused = find.semantics
            .byPredicate(
              (n) =>
                  n.getSemanticsData().flagsCollection.isFocused ==
                  Tristate.isTrue,
            )
            .evaluate()
            .toList();
        expect(focused, hasLength(1), reason: 'one focused semantics node');
        expect(focused.single.label, configLabel);
        handle.dispose();
      },
    );

    testWidgets(
      'under loose bounded constraints the button is as wide as its content',
      (tester) async {
        final rig = await _wi406Pump(tester, plain(), loose: true);
        // 9 = 1 px border + 8 padding; 12 icon; 5 gap.
        expect(
          tester.getSize(_wi406Button).width,
          9 + 12 + 5 + tester.getSize(find.text('Copy')).width + 9,
        );

        await _wi406Press(tester);
        expect(
          tester.getSize(_wi406Button).width,
          9 + 12 + 5 + tester.getSize(find.text('Copied')).width + 9,
          reason: 'Copied is content-sized too',
        );
        rig.clock.advance(const Duration(seconds: 2));
        await _wi406Settle(tester);

        await tester.pumpWidget(
          _wi406App(rig.clock, plain(showIcon: false), loose: true),
        );
        expect(
          tester.getSize(_wi406Button).width,
          9 + tester.getSize(find.text('Copy')).width + 9,
          reason: 'no icon, no gap',
        );
      },
    );

    testWidgets('the label stays on one line', (tester) async {
      await _wi406Pump(tester, plain(label: 'a\nb'), loose: true);
      final one = tester.getSize(find.text('a\nb')).height;
      await tester.pumpWidget(
        _wi406App(FakeClock(), plain(label: 'a'), loose: true),
      );
      expect(tester.getSize(find.text('a')).height, one);
    });
  });

  group('tokens', () {
    test(
      'OmColors carries opaque copiedBg #1C2D29 and writesTagBg #222431',
      () {
        expect(OmColors.copiedBg, const Color(0xFF1C2D29));
        expect(OmColors.writesTagBg, const Color(0xFF222431));
        expect(OmColors.copiedBg.a, 1.0);
        expect(OmColors.writesTagBg.a, 1.0);
      },
    );
  });
}
