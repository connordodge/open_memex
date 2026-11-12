// WI #407 (SH; Spec #394 req 5, 7; D18, D24): the `open_memex/window`
// router. One Dart handler serves the channel: `windowShouldClose` goes to
// the AppExitHost's handler, `openAgents` to the WindowMenuHost's callback,
// anything else throws MissingPluginException (an empty reply natively).
// Neither host sets its own handler, so attaching one never unhooks the
// other. `setAgentsMenuEnabled(bool)` goes Dart → native and is a no-op
// without a native handler. These tests play the native side with
// `handlePlatformMessage` on the real platform hosts.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_exit.dart';

import '../support/app_exit_fakes.dart';
import '../support/app_harness.dart';
import '../support/font_fetch_hold.dart';

const _codec = StandardMethodCodec();

/// One native → Dart call's reply: [raw] null is the empty reply a
/// MissingPluginException gives (FlutterMethodNotImplemented natively).
class _Reply {
  bool replied = false;
  ByteData? raw;

  Object? get decoded => raw == null ? null : _codec.decodeEnvelope(raw!);
}

_Reply _send(WidgetTester tester, String method) {
  final reply = _Reply();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    appWindowChannel.name,
    _codec.encodeMethodCall(MethodCall(method)),
    (data) {
      reply.replied = true;
      reply.raw = data;
    },
  );
  return reply;
}

/// The two real hosts with counting handlers, detached after the test.
class _Hosts {
  _Hosts() : exit = PlatformAppExitHost(), menu = PlatformWindowMenuHost();

  final PlatformAppExitHost exit;
  final PlatformWindowMenuHost menu;
  int closes = 0;
  int quits = 0;
  int opens = 0;

  void attachExit() => exit.attach(
    onWindowClose: () async {
      closes++;
      return true;
    },
    onQuit: () async {
      quits++;
      return AppExitResponse.exit;
    },
  );

  void attachMenu() => menu.attach(onOpenAgents: () => opens++);
}

_Hosts _hosts({bool exitFirst = true}) {
  final h = _Hosts();
  if (exitFirst) {
    h.attachExit();
    h.attachMenu();
  } else {
    h.attachMenu();
    h.attachExit();
  }
  addTearDown(() {
    h.menu.detach();
    h.exit.detach();
  });
  return h;
}

void main() {
  holdFontFetches();

  group('routing (AC router)', () {
    testWidgets(
      'windowShouldClose reaches the exit host once and the menu host zero times',
      (tester) async {
        final h = _hosts();
        // Both hosts are live: the menu host gets its own method.
        _send(tester, 'openAgents');
        await tester.pump();
        expect(h.opens, 1, reason: 'the menu host is routed to');

        final reply = _send(tester, 'windowShouldClose');
        await tester.pump();

        expect(reply.replied, isTrue);
        expect(reply.decoded, true, reason: 'the exit handler answered');
        expect(h.closes, 1);
        expect(h.opens, 1, reason: 'windowShouldClose never reaches it');
        expect(h.quits, 0);
      },
    );

    testWidgets(
      'openAgents reaches the menu host once and the exit host zero times',
      (tester) async {
        final h = _hosts();

        final reply = _send(tester, 'openAgents');
        await tester.pump();

        expect(reply.replied, isTrue);
        expect(
          reply.raw,
          isNotNull,
          reason: 'handled: a success envelope, not MissingPluginException',
        );
        expect(reply.decoded, isNull);
        expect(h.opens, 1);
        expect(h.closes, 0);
        expect(h.quits, 0);
      },
    );

    testWidgets(
      'attaching the menu host before the exit host still routes both methods',
      (tester) async {
        final h = _hosts(exitFirst: false);

        final close = _send(tester, 'windowShouldClose');
        await tester.pump();
        final open = _send(tester, 'openAgents');
        await tester.pump();

        expect(close.decoded, true);
        expect(open.raw, isNotNull);
        expect(h.closes, 1);
        expect(h.opens, 1);
      },
    );

    testWidgets(
      'an unknown method throws MissingPluginException and reaches neither host',
      (tester) async {
        final h = _hosts();

        final reply = _send(tester, 'windowWillMiniaturize');
        await tester.pump();

        expect(reply.replied, isTrue);
        expect(
          reply.raw,
          isNull,
          reason: 'an empty reply is FlutterMethodNotImplemented natively',
        );
        expect(h.closes, 0);
        expect(h.opens, 0);

        // Both methods still work after it.
        _send(tester, 'windowShouldClose');
        _send(tester, 'openAgents');
        await tester.pump();
        expect(h.closes, 1);
        expect(h.opens, 1);
      },
    );

    testWidgets(
      'after the menu host detaches openAgents is not implemented and windowShouldClose still answers',
      (tester) async {
        final h = _hosts();
        h.menu.detach();

        final open = _send(tester, 'openAgents');
        await tester.pump();
        expect(open.replied, isTrue);
        expect(open.raw, isNull);
        expect(h.opens, 0);
        expect(h.closes, 0);

        final close = _send(tester, 'windowShouldClose');
        await tester.pump();
        expect(close.decoded, true);
        expect(h.closes, 1);

        // Attaching again routes openAgents again.
        h.attachMenu();
        _send(tester, 'openAgents');
        await tester.pump();
        expect(h.opens, 1);
      },
    );

    testWidgets(
      'after the exit host detaches windowShouldClose is not implemented and openAgents still answers',
      (tester) async {
        final h = _hosts();
        h.exit.detach();

        final close = _send(tester, 'windowShouldClose');
        await tester.pump();
        // No Dart guard: native falls back to closing.
        expect(close.replied, isTrue);
        expect(close.raw, isNull);
        expect(h.closes, 0);

        final open = _send(tester, 'openAgents');
        await tester.pump();
        expect(open.raw, isNotNull);
        expect(h.opens, 1);

        h.attachExit();
        final again = _send(tester, 'windowShouldClose');
        await tester.pump();
        expect(again.decoded, true);
        expect(h.closes, 1);
      },
    );
  });

  group('setAgentsMenuEnabled (AC menu enablement out)', () {
    testWidgets(
      'setAgentsMenuEnabled sends its flag on the window channel and completes without throwing when no native handler is registered',
      (tester) async {
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          appWindowChannel,
          (call) async {
            calls.add(call);
            return null;
          },
        );
        final host = PlatformWindowMenuHost();
        await host.setAgentsMenuEnabled(true);
        await host.setAgentsMenuEnabled(false);
        expect(calls.map((c) => c.method), [
          'setAgentsMenuEnabled',
          'setAgentsMenuEnabled',
        ]);
        expect(calls.map((c) => c.arguments), [true, false]);

        // No native handler: a real platform send, which only completes
        // outside fake async.
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          appWindowChannel,
          null,
        );
        Object? error;
        var done = false;
        await tester.runAsync(() async {
          try {
            await host
                .setAgentsMenuEnabled(true)
                .timeout(const Duration(seconds: 5));
            done = true;
          } catch (e) {
            error = e;
          }
        });
        expect(error, isNull);
        expect(done, isTrue);
      },
    );

    testWidgets(
      'setAgentsMenuEnabled passes a native PlatformException on and swallows only MissingPluginException',
      (tester) async {
        var sent = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          appWindowChannel,
          (call) async {
            sent++;
            throw PlatformException(code: 'menu_failed');
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            appWindowChannel,
            null,
          ),
        );

        await expectLater(
          PlatformWindowMenuHost().setAgentsMenuEnabled(true),
          throwsA(isA<PlatformException>()),
        );
        expect(sent, 1);
      },
    );
  });

  group('in the running app (AC exit behaviour unchanged)', () {
    testWidgets(
      'in the running app a native openAgents opens the sheet and windowShouldClose still answers true',
      (tester) async {
        final app = await pumpWorkspace(tester);

        final open = _send(tester, 'openAgents');
        await pumpFrames(tester);
        app.clock.advance(const Duration(milliseconds: 300));
        await pumpFrames(tester);

        expect(open.replied, isTrue);
        expect(open.raw, isNotNull, reason: 'the workspace handled openAgents');
        expect(find.byKey(const Key('agents-sheet')), findsOneWidget);

        final close = sendWindowShouldClose(tester);
        await pumpFrames(tester);
        expect(close.replied, isTrue);
        expect(close.decoded, true);
      },
    );
  });
}
