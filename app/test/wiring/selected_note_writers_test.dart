// WI #271 (N8, Spec #232 TD5): `tabsProvider`'s selection callback and the
// vault-open controllers are the only code under `app/lib` that writes
// `selectedNoteIdProvider`. The right panel used to write it directly; it now
// follows through `TabsNotifier.follow`.
//
// A source scan: any use of `selectedNoteIdProvider.notifier` is a write (a
// read goes through `ref.watch(selectedNoteIdProvider)`), however the call is
// split over lines, so whitespace is dropped before matching.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The files allowed to write `selectedNoteIdProvider`, relative to `app/lib`.
const _allowed = {
  'src/state/tabs_state.dart',
  'src/state/vault_open_controller.dart',
  'src/state/vault_open_hosted.dart',
};

final _write = RegExp(r'selectedNoteIdProvider\.notifier');

/// Whether [source] reaches the provider's notifier, in any layout.
bool _writes(String source) =>
    _write.hasMatch(source.replaceAll(RegExp(r'\s+'), ''));

/// Every file under `lib`, as a path relative to it with `/` separators.
Map<String, String> _libSources() {
  final lib = Directory('lib');
  expect(lib.existsSync(), isTrue, reason: 'the test runs from app/');
  return {
    for (final f in lib.listSync(recursive: true))
      if (f is File && f.path.endsWith('.dart'))
        f.path.substring('lib/'.length).replaceAll(r'\', '/'): f
            .readAsStringSync(),
  };
}

void main() {
  group('the scan', () {
    test('catches a write split over lines like the right panel had', () {
      const split = '''
        onTap: () => ref
            .read(selectedNoteIdProvider.notifier)
            .state = e.fromNoteId,
      ''';
      const oneLine = 'ref.read(selectedNoteIdProvider.notifier).state = id;';
      const broken =
          'ref.read(selectedNoteIdProvider\n  .notifier).state = id;';
      expect(_writes(split), isTrue);
      expect(_writes(oneLine), isTrue);
      expect(_writes(broken), isTrue);
    });

    test('lets a read of the selection through', () {
      const read = '''
        final id = ref.watch(selectedNoteIdProvider);
        ref.read(selectedNoteIdProvider);
        ref.invalidate(selectedNoteIdProvider);
      ''';
      expect(_writes(read), isFalse);
    });
  });

  group('writers of selectedNoteIdProvider', () {
    test(
      'no code under app lib outside the tabs selection callback and the vault open controllers writes selectedNoteIdProvider',
      () {
        final sources = _libSources();
        expect(sources, isNotEmpty, reason: 'the scan found lib/');

        final writers = {
          for (final e in sources.entries)
            if (_writes(e.value)) e.key,
        };

        expect(
          writers.difference(_allowed),
          isEmpty,
          reason: 'these files write selectedNoteIdProvider',
        );
        expect(
          writers,
          contains('src/state/tabs_state.dart'),
          reason: 'the scan sees the one writer that must stay',
        );
      },
    );
  });
}
