// WI #103 (D20): test doubles for the app-exit seam and the window title
// seam, plus helpers that play the native side of the window channel.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/unsent_hosted_text.dart';

/// Overrides that make the unsent-text seam report [text] as unsent.
List<Override> unsentTextOverrides(UnsentHostedText text) => [
  hasUnsentHostedTextProvider.overrideWithValue(true),
  unsentHostedTextProvider.overrideWithValue(text),
];

/// A fake [AppExitHost]: [requestClose] and [requestQuit] simulate the red
/// close button and ⌘Q, and every answer is recorded.
class FakeAppExitHost implements AppExitHost {
  WindowCloseHandler? _onWindowClose;
  QuitHandler? _onQuit;

  /// How many times the app attached its handlers.
  int attachCount = 0;

  /// How many times the app detached.
  int detachCount = 0;

  /// Every window-close answer, oldest first.
  final List<bool> closeAnswers = [];

  /// Every quit answer, oldest first.
  final List<AppExitResponse> quitAnswers = [];

  bool get isAttached => _onWindowClose != null;

  @override
  void attach({
    required WindowCloseHandler onWindowClose,
    required QuitHandler onQuit,
  }) {
    attachCount++;
    _onWindowClose = onWindowClose;
    _onQuit = onQuit;
  }

  @override
  void detach() {
    detachCount++;
    _onWindowClose = null;
    _onQuit = null;
  }

  /// The person clicks the window's close button. The answer lands in
  /// [closeAnswers] once the app decides (after a confirm, if one shows).
  Future<bool> requestClose() async {
    final handler = _onWindowClose;
    if (handler == null) {
      throw StateError(
        'no app-exit handlers attached: the app root did not attach to '
        'appExitHostProvider',
      );
    }
    final answer = await handler();
    closeAnswers.add(answer);
    return answer;
  }

  /// The person quits (⌘Q). The answer lands in [quitAnswers].
  Future<AppExitResponse> requestQuit() async {
    final handler = _onQuit;
    if (handler == null) {
      throw StateError(
        'no app-exit handlers attached: the app root did not attach to '
        'appExitHostProvider',
      );
    }
    final answer = await handler();
    quitAnswers.add(answer);
    return answer;
  }
}

/// A [WindowTitle] that records every title set.
class RecordingWindowTitle implements WindowTitle {
  final List<String> titles = [];

  String? get current => titles.isEmpty ? null : titles.last;

  @override
  Future<void> setTitle(String title) async => titles.add(title);
}

/// The reply to one native → Dart method call; [decoded] is null until Dart
/// replies.
class NativeCallReply {
  bool replied = false;
  Object? decoded;
}

/// Play the native window delegate: send `windowShouldClose` on
/// [appWindowChannel]. The returned reply fills in when Dart answers.
NativeCallReply sendWindowShouldClose(WidgetTester tester) {
  const codec = StandardMethodCodec();
  final reply = NativeCallReply();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    appWindowChannel.name,
    codec.encodeMethodCall(const MethodCall('windowShouldClose')),
    (data) {
      reply.replied = true;
      reply.decoded = data == null ? null : codec.decodeEnvelope(data);
    },
  );
  return reply;
}

/// Play the engine asking to quit: `System.requestAppExit` on the platform
/// channel, which reaches `AppLifecycleListener.onExitRequested`. The reply's
/// [NativeCallReply.decoded] is the response name (`exit` or `cancel`).
NativeCallReply sendRequestAppExit(WidgetTester tester) {
  const codec = JSONMethodCodec();
  final reply = NativeCallReply();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.platform.name,
    codec.encodeMethodCall(const MethodCall('System.requestAppExit')),
    (data) {
      reply.replied = true;
      if (data != null) {
        final envelope = codec.decodeEnvelope(data);
        reply.decoded = envelope is Map ? envelope['response'] : envelope;
      }
    },
  );
  return reply;
}
