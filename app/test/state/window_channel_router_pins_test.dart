// WI #407 (SH; Spec #394 req 7; D18): the window channel router's
// replacement rule. `clear*Handler` stops routing only when the handler it
// is given is still the registered one, so a host that detaches late never
// unhooks the host that replaced it. Native calls are played with
// `handlePlatformMessage` on the real platform hosts.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_exit.dart';

import '../support/font_fetch_hold.dart';

const _codec = StandardMethodCodec();

/// One native -> Dart call's reply; [missing] is the empty reply a
/// MissingPluginException gives (FlutterMethodNotImplemented natively).
class _Reply {
  bool replied = false;
  ByteData? raw;

  bool get missing => replied && raw == null;
  Object? get value => raw == null ? null : _codec.decodeEnvelope(raw!);
}

/// Plays a native -> Dart call and pumps until it is answered.
Future<_Reply> _send(WidgetTester tester, String method) async {
  final reply = _Reply();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    appWindowChannel.name,
    _codec.encodeMethodCall(MethodCall(method)),
    (data) {
      reply.replied = true;
      reply.raw = data;
    },
  );
  await tester.pump();
  expect(reply.replied, isTrue, reason: '$method got a reply');
  return reply;
}

void main() {
  holdFontFetches();

  testWidgets(
    'a replaced exit host detaching late keeps the newer exit handler routed',
    (tester) async {
      var oldCloses = 0;
      var newCloses = 0;
      final oldHost = PlatformAppExitHost();
      final newHost = PlatformAppExitHost();
      addTearDown(() {
        oldHost.detach();
        newHost.detach();
      });
      oldHost.attach(
        onWindowClose: () async {
          oldCloses++;
          return false;
        },
        onQuit: () async => AppExitResponse.exit,
      );
      newHost.attach(
        onWindowClose: () async {
          newCloses++;
          return true;
        },
        onQuit: () async => AppExitResponse.exit,
      );

      // The old host detaches after the new one attached.
      oldHost.detach();
      final reply = await _send(tester, 'windowShouldClose');

      expect(reply.missing, isFalse, reason: 'still routed');
      expect(reply.value, true, reason: 'the new handler answered');
      expect(newCloses, 1);
      expect(oldCloses, 0);

      // Detaching the new one ends routing.
      newHost.detach();
      expect((await _send(tester, 'windowShouldClose')).missing, isTrue);
    },
  );

  testWidgets(
    'a replaced menu host detaching late keeps the newer openAgents callback routed',
    (tester) async {
      var oldOpens = 0;
      var newOpens = 0;
      final oldHost = PlatformWindowMenuHost();
      final newHost = PlatformWindowMenuHost();
      addTearDown(() {
        oldHost.detach();
        newHost.detach();
      });
      oldHost.attach(onOpenAgents: () => oldOpens++);
      newHost.attach(onOpenAgents: () => newOpens++);

      oldHost.detach();
      final reply = await _send(tester, 'openAgents');

      expect(reply.missing, isFalse, reason: 'still routed');
      expect(newOpens, 1);
      expect(oldOpens, 0);

      newHost.detach();
      expect((await _send(tester, 'openAgents')).missing, isTrue);
    },
  );

  testWidgets(
    'with both hosts detached the channel has no handler and every method is not implemented',
    (tester) async {
      final exit = PlatformAppExitHost();
      final menu = PlatformWindowMenuHost();
      exit.attach(
        onWindowClose: () async => true,
        onQuit: () async => AppExitResponse.exit,
      );
      menu.attach(onOpenAgents: () {});
      exit.detach();
      menu.detach();

      expect((await _send(tester, 'windowShouldClose')).missing, isTrue);
      expect((await _send(tester, 'openAgents')).missing, isTrue);
    },
  );
}
