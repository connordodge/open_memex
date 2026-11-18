// WI #81 (Spec #61 F5; Reqs 11, 14-17; TD5; D9): the native `find` route
// on `open_memex/window` and the Dart → native `setFindMenuEnabled`.
//
// Native sends `find` with an action string (`show`, `next`, `previous`,
// `useSelection`) for Find… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G) and
// Use Selection for Find (⌘E). The channel's one router routes it to the find
// handler as a `FindMenuAction`; the app attaches a handler that dispatches
// on `findMenuActionsProvider` (F1), which F6's editor performs. An unknown
// action string is ignored. With no find handler the call is not
// implemented, like any other unhandled window method. These tests play the
// native side with `handlePlatformMessage` on the real router and hosts.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/state/find_menu_enablement.dart';

import '../support/app_exit_fakes.dart';
import '../support/app_harness.dart';
import '../support/font_fetch_hold.dart';
import '../support/window_menu_fakes.dart';

const _codec = StandardMethodCodec();

/// One native → Dart call's reply: [raw] null is the empty reply a
/// MissingPluginException gives (FlutterMethodNotImplemented natively).
class _Wi81Reply {
  bool replied = false;
  ByteData? raw;

  bool get missing => replied && raw == null;
  Object? get value => raw == null ? null : _codec.decodeEnvelope(raw!);
}

/// Plays a native → Dart call on the window channel and pumps once.
Future<_Wi81Reply> _wi81Send(
  WidgetTester tester,
  String method, [
  Object? arguments,
]) async {
  final reply = _Wi81Reply();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    appWindowChannel.name,
    _codec.encodeMethodCall(MethodCall(method, arguments)),
    (data) {
      reply.replied = true;
      reply.raw = data;
    },
  );
  await tester.pump();
  expect(reply.replied, isTrue, reason: '$method got a reply');
  return reply;
}

/// A find handler that records every action it is given.
class _Wi81FindRecorder {
  final actions = <FindMenuAction>[];
  late final FindMenuHandler handler = actions.add;

  /// Routes find to this recorder until the test ends.
  void attach() {
    appWindowRouter.setFindHandler(handler);
    addTearDown(() => appWindowRouter.clearFindHandler(handler));
  }
}

/// The exit and Window menu hosts with counting handlers, detached after
/// the test.
class _Wi81Hosts {
  final exit = PlatformAppExitHost();
  final menu = PlatformWindowMenuHost();
  int closes = 0;
  int opens = 0;

  static _Wi81Hosts attached() {
    final h = _Wi81Hosts();
    h.exit.attach(
      onWindowClose: () async {
        h.closes++;
        return true;
      },
      onQuit: () async => AppExitResponse.exit,
    );
    h.menu.attach(onOpenAgents: () => h.opens++);
    addTearDown(() {
      h.menu.detach();
      h.exit.detach();
    });
    return h;
  }
}

void main() {
  holdFontFetches();

  group('the find route (AC find route)', () {
    testWidgets(
      'find with show next previous and useSelection reaches the find handler once each with the matching FindMenuAction',
      (tester) async {
        final find = _Wi81FindRecorder()..attach();
        for (final (arg, action) in [
          ('show', FindMenuAction.show),
          ('next', FindMenuAction.next),
          ('previous', FindMenuAction.previous),
          ('useSelection', FindMenuAction.useSelection),
        ]) {
          find.actions.clear();
          final reply = await _wi81Send(tester, 'find', arg);
          expect(
            reply.missing,
            isFalse,
            reason: 'find $arg is handled: a success envelope',
          );
          expect(reply.value, isNull, reason: 'native never reads the reply');
          expect(find.actions, [action], reason: 'find $arg');
        }
      },
    );

    testWidgets(
      'find with an unknown action string reaches no handler and replies without throwing',
      (tester) async {
        final find = _Wi81FindRecorder()..attach();
        for (final arg in <Object?>[
          'Show',
          'use-selection',
          'replace',
          '',
          ' show',
          null,
          1,
          true,
        ]) {
          final reply = await _wi81Send(tester, 'find', arg);
          expect(
            reply.missing,
            isFalse,
            reason:
                'find $arg is ignored, not a MissingPluginException (no '
                'throw)',
          );
          expect(reply.value, isNull);
          expect(find.actions, isEmpty, reason: 'find $arg dispatches nothing');
          expect(tester.takeException(), isNull);
        }
        // A known action still works after the unknown ones.
        await _wi81Send(tester, 'find', 'next');
        expect(find.actions, [FindMenuAction.next]);
      },
    );

    testWidgets(
      'with no find handler attached find is not implemented and attaching it leaves windowShouldClose and openAgents working',
      (tester) async {
        final h = _Wi81Hosts.attached();

        final before = await _wi81Send(tester, 'find', 'show');
        expect(
          before.missing,
          isTrue,
          reason: 'no find handler: MissingPluginException (empty reply)',
        );

        final find = _Wi81FindRecorder()..attach();
        expect((await _wi81Send(tester, 'find', 'show')).missing, isFalse);
        expect(find.actions, [FindMenuAction.show]);

        final close = await _wi81Send(tester, 'windowShouldClose');
        expect(close.value, true, reason: 'the exit handler still answers');
        expect(h.closes, 1);
        final open = await _wi81Send(tester, 'openAgents');
        expect(open.missing, isFalse, reason: 'openAgents is still routed');
        expect(h.opens, 1);
        expect(
          find.actions,
          [FindMenuAction.show],
          reason:
              'windowShouldClose and openAgents never reach the find handler',
        );
      },
    );

    testWidgets(
      'with only the find handler attached the channel routes find and other methods are not implemented',
      (tester) async {
        final find = _Wi81FindRecorder()..attach();

        expect((await _wi81Send(tester, 'find', 'previous')).missing, isFalse);
        expect(find.actions, [FindMenuAction.previous]);
        expect((await _wi81Send(tester, 'windowShouldClose')).missing, isTrue);
        expect((await _wi81Send(tester, 'openAgents')).missing, isTrue);

        appWindowRouter.clearFindHandler(find.handler);
        expect(
          (await _wi81Send(tester, 'find', 'previous')).missing,
          isTrue,
          reason: 'cleared: find is not implemented again',
        );
        expect(find.actions, [FindMenuAction.previous]);
      },
    );

    testWidgets(
      'clearing the find handler leaves windowShouldClose and openAgents routed',
      (tester) async {
        final h = _Wi81Hosts.attached();
        final find = _Wi81FindRecorder()..attach();
        appWindowRouter.clearFindHandler(find.handler);

        expect((await _wi81Send(tester, 'find', 'show')).missing, isTrue);
        expect(find.actions, isEmpty);
        expect((await _wi81Send(tester, 'windowShouldClose')).value, true);
        expect((await _wi81Send(tester, 'openAgents')).missing, isFalse);
        expect(h.closes, 1);
        expect(h.opens, 1);
      },
    );

    testWidgets(
      'a replaced find handler cleared late keeps the newer find handler routed',
      (tester) async {
        final older = _Wi81FindRecorder()..attach();
        final newer = _Wi81FindRecorder()..attach();

        appWindowRouter.clearFindHandler(older.handler);
        final reply = await _wi81Send(tester, 'find', 'useSelection');

        expect(reply.missing, isFalse, reason: 'still routed');
        expect(newer.actions, [FindMenuAction.useSelection]);
        expect(older.actions, isEmpty);

        appWindowRouter.clearFindHandler(newer.handler);
        expect((await _wi81Send(tester, 'find', 'show')).missing, isTrue);
      },
    );
  });

  group('the app attaches the find route (AC find route)', () {
    testWidgets(
      'reading findMenuEnablementProvider routes each find call to one findMenuActionsProvider dispatch',
      (tester) async {
        final c = ProviderContainer(
          overrides: [
            windowMenuHostProvider.overrideWithValue(FakeWindowMenuHost()),
          ],
        );
        addTearDown(c.dispose);
        c.read(findMenuEnablementProvider);
        final seen = <FindMenuDispatch?>[];
        c.listen<FindMenuDispatch?>(
          findMenuActionsProvider,
          (_, next) => seen.add(next),
        );

        await _wi81Send(tester, 'find', 'show');
        await _wi81Send(tester, 'find', 'next');
        await _wi81Send(tester, 'find', 'next');
        await _wi81Send(tester, 'find', 'bogus');
        await _wi81Send(tester, 'find', 'previous');
        await _wi81Send(tester, 'find', 'useSelection');

        expect(seen, const [
          FindMenuDispatch(FindMenuAction.show, 1),
          FindMenuDispatch(FindMenuAction.next, 2),
          FindMenuDispatch(FindMenuAction.next, 3),
          FindMenuDispatch(FindMenuAction.previous, 4),
          FindMenuDispatch(FindMenuAction.useSelection, 5),
        ]);
      },
    );

    testWidgets(
      'disposing the container that attached the find route stops routing find',
      (tester) async {
        final c = ProviderContainer(
          overrides: [
            windowMenuHostProvider.overrideWithValue(FakeWindowMenuHost()),
          ],
        );
        c.read(findMenuEnablementProvider);
        expect((await _wi81Send(tester, 'find', 'show')).missing, isFalse);
        c.dispose();

        expect(
          (await _wi81Send(tester, 'find', 'show')).missing,
          isTrue,
          reason: 'a disposed container never receives find',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'in the running app a native find show dispatches exactly one FindMenuAction show and windowShouldClose still answers true',
      (tester) async {
        final menu = FakeWindowMenuHost();
        final app = await pumpWorkspace(
          tester,
          overrides: [windowMenuHostProvider.overrideWithValue(menu)],
        );
        expect(app.read(findMenuActionsProvider), isNull);

        final reply = sendFind(tester, 'show');
        await pumpFrames(tester);

        expect(reply.replied, isTrue);
        expect(reply.raw, isNotNull, reason: 'the app handled find');
        expect(
          app.read(findMenuActionsProvider),
          const FindMenuDispatch(FindMenuAction.show, 1),
        );

        sendFind(tester, 'useSelection');
        await pumpFrames(tester);
        expect(
          app.read(findMenuActionsProvider),
          const FindMenuDispatch(FindMenuAction.useSelection, 2),
        );

        final close = sendWindowShouldClose(tester);
        await pumpFrames(tester);
        expect(close.replied, isTrue);
        expect(close.decoded, true);
      },
    );
  });

  group('setFindMenuEnabled (AC enablement out)', () {
    testWidgets(
      'setFindMenuEnabled sends its Bool on the window channel and completes without throwing when no native handler is registered',
      (tester) async {
        final calls = <MethodCall>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(appWindowChannel, (call) async {
          calls.add(call);
          return null;
        });
        final host = PlatformWindowMenuHost();
        await host.setFindMenuEnabled(true);
        await host.setFindMenuEnabled(false);
        expect(calls.map((c) => c.method), [
          'setFindMenuEnabled',
          'setFindMenuEnabled',
        ]);
        expect(calls.map((c) => c.arguments), [true, false]);
        expect(
          calls.map((c) => c.arguments),
          everyElement(isA<bool>()),
          reason: 'a real Bool: native refuses an int 0 or 1',
        );

        messenger.setMockMethodCallHandler(appWindowChannel, null);
        Object? error;
        var done = false;
        await tester.runAsync(() async {
          try {
            await host
                .setFindMenuEnabled(true)
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
      'setFindMenuEnabled passes a native PlatformException on and swallows only MissingPluginException',
      (tester) async {
        var sent = 0;
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(appWindowChannel, (call) async {
          if (call.method == 'setFindMenuEnabled') sent++;
          throw PlatformException(code: 'bad_arguments');
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(appWindowChannel, null),
        );

        await expectLater(
          PlatformWindowMenuHost().setFindMenuEnabled(true),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'bad_arguments',
            ),
          ),
        );
        expect(sent, 1);
      },
    );

    test(
      'the fake records setFindMenuEnabled apart from setAgentsMenuEnabled',
      () async {
        final menu = FakeWindowMenuHost();
        expect(menu.findEnabled, isNull);
        await menu.setFindMenuEnabled(true);
        await menu.setAgentsMenuEnabled(false);
        await menu.setFindMenuEnabled(false);
        expect(menu.findEnabledCalls, [true, false]);
        expect(menu.findEnabled, isFalse);
        expect(menu.enabledCalls, [false]);
      },
    );
  });
}
