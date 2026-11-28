// WI #145 (Spec #123 R7 seam): the drop-target seam. The default source wraps
// `desktop_drop`'s `DropTarget`; the tests drive it the way the macOS plugin
// does, by sending `entered` / `updated` / `exited` / `performOperation_macos`
// on the `desktop_drop` channel. The fake source fires the same callbacks
// directly, and a parity test keeps the two honest. Also pins the
// `desktop_drop` dependency (D14).
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/attachment_drop_source.dart';

import '../support/attachment_input_fakes.dart';

const _childKey = ValueKey('wi145-drop-child');
const _targetOrigin = Offset(50, 40);
const _targetSize = Size(200, 100);

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Sends [method] to the Dart side of the `desktop_drop` channel, as the
/// macOS plugin does. The Dart handler runs synchronously up to the event
/// callbacks, so no await is needed before the next pump.
void _fromNative(String method, Object? arguments) {
  _messenger.handlePlatformMessage(
    'desktop_drop',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );
}

/// Window coordinates of a point [local] to the target.
List<double> _global(double x, double y) => [
  _targetOrigin.dx + x,
  _targetOrigin.dy + y,
];

void _nativeEnter(double x, double y) => _fromNative('entered', _global(x, y));
void _nativeUpdate(double x, double y) => _fromNative('updated', _global(x, y));
void _nativeExit() => _fromNative('exited', null);
void _nativeDrop(List<String> paths) => _fromNative('performOperation_macos', [
  for (final p in paths)
    {'path': p, 'isDirectory': false, 'fromPromise': false},
]);

/// Everything the target reported, in order.
class _Log {
  final List<String> events = [];

  void entered(Offset o) => events.add('enter $o');
  void updated(Offset o) => events.add('update $o');
  void exited() => events.add('exit');
  void dropped(List<String> paths, Offset o) => events.add('drop $paths $o');
}

/// Mounts a target built through [attachmentDropSourceProvider] (the fake
/// when [source] is given, else the real default) at a known place.
Future<void> _pump(
  WidgetTester tester, {
  AttachmentDropSource? source,
  required _Log log,
  bool enabled = true,
  bool withCallbacks = true,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      if (source != null)
        attachmentDropSourceProvider.overrideWithValue(source),
    ],
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          Positioned(
            left: _targetOrigin.dx,
            top: _targetOrigin.dy,
            width: _targetSize.width,
            height: _targetSize.height,
            child: Consumer(
              builder: (context, ref, _) => ref
                  .read(attachmentDropSourceProvider)
                  .buildTarget(
                    enabled: enabled,
                    onEntered: withCallbacks ? log.entered : null,
                    onUpdated: withCallbacks ? log.updated : null,
                    onExited: withCallbacks ? log.exited : null,
                    onDropped: withCallbacks ? log.dropped : null,
                    child: const SizedBox.expand(key: _childKey),
                  ),
            ),
          ),
        ],
      ),
    ),
  ),
);

/// `dependencies:` entries of a pubspec: package -> constraint text.
Map<String, String> _wi145Dependencies(String pubspec) {
  final deps = <String, String>{};
  var inDeps = false;
  for (final line in pubspec.split('\n')) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    if (!line.startsWith(' ')) {
      inDeps = line.trimRight() == 'dependencies:';
      continue;
    }
    if (!inDeps) continue;
    final m = RegExp(r'^  ([a-z0-9_]+):\s*(\S.*)$').firstMatch(line);
    if (m != null) deps[m.group(1)!] = m.group(2)!.trim();
  }
  return deps;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dependency', () {
    test('app pubspec depends on desktop_drop caret 0.8.4', () {
      // `flutter test` runs with the package root (`app/`) as cwd.
      final deps = _wi145Dependencies(File('pubspec.yaml').readAsStringSync());
      // Control: the parser reads the block at all.
      expect(deps['flutter_riverpod'], isNotNull);
      expect(deps['desktop_drop'], '^0.8.4');
    });

    test('pubspec lock resolves desktop_drop 0.8.4 as a direct dependency', () {
      final lock = File('pubspec.lock').readAsStringSync();
      final entry = RegExp(
        r'^  desktop_drop:\n    dependency: "([^"]+)"\n(?:.*\n)*?    version: "([^"]+)"',
        multiLine: true,
      ).firstMatch(lock);
      expect(entry, isNotNull);
      expect(entry!.group(1), 'direct main');
      expect(entry.group(2), '0.8.4');
    });
  });

  group('default source', () {
    testWidgets(
      'the default provider builds a real DropTarget around the child',
      (tester) async {
        final log = _Log();
        await _pump(tester, log: log);

        expect(find.byType(DropTarget), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(DropTarget),
            matching: find.byKey(_childKey),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('the default provider source is the desktop source', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        container.read(attachmentDropSourceProvider),
        isA<DesktopAttachmentDropSource>(),
      );
    });

    testWidgets('enabled true and false reach the DropTarget enable flag', (
      tester,
    ) async {
      final log = _Log();
      await _pump(tester, log: log, enabled: true);
      expect(tester.widget<DropTarget>(find.byType(DropTarget)).enable, isTrue);

      await _pump(tester, log: log, enabled: false);
      expect(
        tester.widget<DropTarget>(find.byType(DropTarget)).enable,
        isFalse,
      );
    });

    testWidgets('a drag entering reports onEntered with the local position', (
      tester,
    ) async {
      final log = _Log();
      await _pump(tester, log: log);

      _nativeEnter(10, 10);
      await tester.pump();

      expect(log.events, ['enter ${const Offset(10, 10)}']);
    });

    testWidgets('a drag moving reports onUpdated with the local position', (
      tester,
    ) async {
      final log = _Log();
      await _pump(tester, log: log);

      _nativeEnter(10, 10);
      _nativeUpdate(30, 25);
      await tester.pump();

      expect(log.events, [
        'enter ${const Offset(10, 10)}',
        'update ${const Offset(30, 25)}',
      ]);
    });

    testWidgets('a drag leaving reports onExited', (tester) async {
      final log = _Log();
      await _pump(tester, log: log);

      _nativeEnter(10, 10);
      _nativeExit();
      await tester.pump();

      expect(log.events, ['enter ${const Offset(10, 10)}', 'exit']);
    });

    testWidgets(
      'files dropped report their paths in order and the local position',
      (tester) async {
        final log = _Log();
        await _pump(tester, log: log);
        const paths = [
          '/vaults/My Vault/Inbox/b report.pdf',
          '/vaults/My Vault/Inbox/a.png',
          '/vaults/My Vault/Inbox/c (1).txt',
        ];

        _nativeEnter(10, 10);
        _nativeUpdate(40, 20);
        _nativeDrop(paths);
        await tester.pump();

        expect(log.events, [
          'enter ${const Offset(10, 10)}',
          'update ${const Offset(40, 20)}',
          'exit',
          'drop $paths ${const Offset(40, 20)}',
        ]);
      },
    );

    testWidgets('a drop after the drag left reports nothing', (tester) async {
      final log = _Log();
      await _pump(tester, log: log);

      expect(find.byType(DropTarget), findsOneWidget);
      _nativeEnter(10, 10);
      _nativeExit();
      log.events.clear();
      _nativeDrop(['/vaults/My Vault/Inbox/a.png']);
      await tester.pump();

      expect(log.events, isEmpty);
    });

    testWidgets('a disabled target reports nothing for a whole drag', (
      tester,
    ) async {
      final log = _Log();
      await _pump(tester, log: log, enabled: false);
      expect(find.byType(DropTarget), findsOneWidget);

      _nativeEnter(10, 10);
      _nativeUpdate(20, 20);
      _nativeDrop(['/vaults/My Vault/Inbox/a.png']);
      _nativeExit();
      await tester.pump();

      expect(log.events, isEmpty);
    });

    testWidgets('disabling the target mid drag reports an exit', (
      tester,
    ) async {
      final log = _Log();
      await _pump(tester, log: log);
      _nativeEnter(10, 10);
      log.events.clear();

      await _pump(tester, log: log, enabled: false);

      expect(log.events, ['exit']);
    });

    testWidgets('a target with no callbacks takes a whole drag without error', (
      tester,
    ) async {
      final log = _Log();
      await _pump(tester, log: log, withCallbacks: false);

      _nativeEnter(10, 10);
      _nativeUpdate(20, 20);
      _nativeDrop(['/vaults/My Vault/Inbox/a.png']);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(log.events, isEmpty);
      expect(find.byType(DropTarget), findsOneWidget);
    });
  });

  group('fake source', () {
    testWidgets('the fake wraps the child and fires every callback', (
      tester,
    ) async {
      final fake = FakeAttachmentDropSource();
      final log = _Log();
      await _pump(tester, source: fake, log: log);
      expect(find.byKey(_childKey), findsOneWidget);
      expect(fake.isMounted, isTrue);

      fake.enter(const Offset(1, 2));
      fake.update(const Offset(3, 4));
      fake.exit();
      fake.drop([
        '/vaults/My Vault/a.txt',
        '/vaults/My Vault/b.txt',
      ], localPosition: const Offset(5, 6));

      expect(log.events, [
        'enter ${const Offset(1, 2)}',
        'update ${const Offset(3, 4)}',
        'exit',
        'drop [/vaults/My Vault/a.txt, /vaults/My Vault/b.txt] '
            '${const Offset(5, 6)}',
      ]);
    });

    testWidgets('the fake is silent while disabled and after unmount', (
      tester,
    ) async {
      final fake = FakeAttachmentDropSource();
      final log = _Log();
      await _pump(tester, source: fake, log: log, enabled: false);
      expect(fake.enabled, isFalse);

      fake.enter(Offset.zero);
      fake.drop(['/vaults/My Vault/a.txt']);
      expect(log.events, isEmpty);

      await _pump(tester, source: fake, log: log, enabled: true);
      expect(fake.enabled, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(fake.isMounted, isFalse);
      fake.enter(Offset.zero);
      expect(log.events, isEmpty);
    });

    testWidgets('the fake reports an exit when disabled mid drag', (
      tester,
    ) async {
      final fake = FakeAttachmentDropSource();
      final log = _Log();
      await _pump(tester, source: fake, log: log);
      fake.enter(const Offset(1, 1));
      log.events.clear();

      await _pump(tester, source: fake, log: log, enabled: false);

      expect(log.events, ['exit']);
    });
  });

  testWidgets(
    'the fake and the real drop source report the same events for the same drag',
    (tester) async {
      const paths = [
        '/vaults/My Vault/Inbox/one.pdf',
        '/vaults/My Vault/two.png',
      ];

      // Real source, driven through the desktop_drop channel.
      final realLog = _Log();
      await _pump(tester, log: realLog);
      _nativeEnter(12, 8);
      _nativeUpdate(60, 30);
      _nativeUpdate(70, 35);
      _nativeDrop(paths);
      _nativeEnter(5, 5);
      _nativeExit();
      await _pump(tester, log: realLog, enabled: false);
      await tester.pumpWidget(const SizedBox());

      // Fake source, driven by hand with the same drag.
      final fake = FakeAttachmentDropSource();
      final fakeLog = _Log();
      await _pump(tester, source: fake, log: fakeLog);
      fake.enter(const Offset(12, 8));
      fake.update(const Offset(60, 30));
      fake.update(const Offset(70, 35));
      fake.drop(paths, localPosition: const Offset(70, 35));
      fake.enter(const Offset(5, 5));
      fake.exit();
      await _pump(tester, source: fake, log: fakeLog, enabled: false);

      expect(realLog.events, isNotEmpty);
      expect(fakeLog.events, realLog.events);
    },
  );
}
