// #69 (54-O3): the hub that lets the editor's section tracker see whether
// `outlineSectionProvider` is watched and where it reports. Unit level: the
// microtask that clears the current entry when a tracker goes away must not
// override a new tracker's report, and a re-listen is counted once.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/outline.dart';
import 'package:open_memex_app/src/state/outline_section.dart';

OutlineEntry _wi69Entry(String text) =>
    OutlineEntry(level: 2, depth: 0, text: text, segment: 0, local: 0);

void main() {
  late ProviderContainer container;
  late OutlineSectionHub hub;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    hub = container.read(outlineSectionHubProvider);
  });

  test('the hub is watched only while the provider has a listener', () {
    expect(hub.watched, isFalse);
    final sub = container.listen(outlineSectionProvider, (_, _) {});
    expect(hub.watched, isTrue);
    sub.close();
    expect(hub.watched, isFalse);
  });

  test('a re-listen after the last listener left notifies once per change', () {
    var notified = 0;
    hub.addListener(() => notified++);
    final first = container.listen(outlineSectionProvider, (_, _) {});
    expect(notified, 1, reason: 'gained a listener');
    first.close();
    expect(notified, 2, reason: 'lost it');
    final second = container.listen(outlineSectionProvider, (_, _) {});
    expect(notified, 3, reason: 'back before the provider was disposed');
    expect(hub.watched, isTrue);
    // A second listener on top changes nothing.
    final third = container.listen(outlineSectionProvider, (_, _) {});
    expect(notified, 3, reason: 'already watched');
    second.close();
    third.close();
    expect(notified, 4);
    expect(hub.watched, isFalse);
  });

  test(
    'a tracker that leaves clears the current entry after a microtask',
    () async {
      final sub = container.listen(outlineSectionProvider, (_, _) {});
      final tracker = Object();
      hub.report(tracker, _wi69Entry('A'));
      expect(sub.read(), _wi69Entry('A'));

      hub.leave(tracker);
      expect(sub.read(), _wi69Entry('A'), reason: 'not within the same turn');
      await Future<void>.value();
      expect(sub.read(), isNull);
    },
  );

  test(
    'a new tracker that reports before the microtask keeps its entry',
    () async {
      final sub = container.listen(outlineSectionProvider, (_, _) {});
      final old = Object();
      final next = Object();
      hub.report(old, _wi69Entry('A'));
      hub.leave(old);
      hub.report(next, _wi69Entry('B'));
      await Future<void>.value();
      expect(sub.read(), _wi69Entry('B'), reason: 'not overridden by the null');
    },
  );

  test(
    'a tracker that is not the last reporter does not clear the entry',
    () async {
      final sub = container.listen(outlineSectionProvider, (_, _) {});
      final old = Object();
      final next = Object();
      hub.report(old, _wi69Entry('A'));
      hub.report(next, _wi69Entry('B'));
      hub.leave(old);
      await Future<void>.value();
      expect(sub.read(), _wi69Entry('B'));
    },
  );

  test('a report with nothing watching does not throw and is not kept', () {
    final tracker = Object();
    hub.report(tracker, _wi69Entry('A'));
    final sub = container.listen(outlineSectionProvider, (_, _) {});
    expect(sub.read(), isNull);
  });

  test(
    'a jump notifies the hub, replaces the earlier one and can be dropped',
    () {
      var notified = 0;
      hub.addListener(() => notified++);
      final a = OutlineJump(
        noteId: 'n',
        entry: _wi69Entry('A'),
        content: 'c',
        arrivals: 1,
      );
      final b = OutlineJump(
        noteId: 'n',
        entry: _wi69Entry('B'),
        content: 'c',
        arrivals: 1,
      );
      hub.jumped(a);
      expect(hub.jump, a);
      expect(hub.jumpLanded, isFalse);
      expect(notified, 1);
      hub.markLanded();
      expect(hub.jumpLanded, isTrue);
      hub.jumped(b);
      expect(hub.jump, b, reason: 'replaced');
      expect(hub.jumpLanded, isFalse, reason: 'a new jump has not landed');
      expect(notified, 2);
      hub.dropJump();
      expect(hub.jump, isNull);
      expect(hub.jumpLanded, isFalse);
    },
  );
}
