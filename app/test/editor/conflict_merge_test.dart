// WI #20 (A3): Req 60 conflict rebuild as a pure function, with the C3.1
// append separator rule.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/conflict_merge.dart';

ServerBlock _b(String source, int createdVersion, int ord, String text) =>
    ServerBlock(
      source: source,
      createdVersion: createdVersion,
      ord: ord,
      text: text,
    );

const _footer = '<!-- memex:topics -->\n[[Player Loop~about]]\n';

void main() {
  group('mergeConflict (Req 60)', () {
    test('appends a newer agent block and keeps the server footer', () {
      final merged = mergeConflict(
        localPerson: 'My note\n',
        baseVersion: 4,
        serverBody: 'My note\n\nCaptured: ship it\n$_footer',
        serverBlocks: [
          _b('person', 3, 0, 'My note'),
          _b('agent', 5, 1, 'Captured: ship it'),
        ],
      );
      expect(
        merged,
        'My note\n\nCaptured: ship it\n<!-- memex:topics -->\n[[Player Loop~about]]\n',
      );
    });

    test(
      'does not duplicate a newer agent block already in the local text',
      () {
        final merged = mergeConflict(
          localPerson: 'My note\n\nCaptured: ship it\n',
          baseVersion: 4,
          serverBody: 'My note\n\nCaptured: ship it\n$_footer',
          serverBlocks: [
            _b('person', 3, 0, 'My note'),
            _b('agent', 5, 1, 'Captured: ship it'),
          ],
        );
        expect(merged, 'My note\n\nCaptured: ship it\n$_footer');
      },
    );

    test(
      'treats a block contained inside edited local text as already present',
      () {
        final merged = mergeConflict(
          localPerson: 'My note\nCaptured: ship it, and then some\n',
          baseVersion: 4,
          serverBody: 'My note\n\nCaptured: ship it\n$_footer',
          serverBlocks: [
            _b('person', 3, 0, 'My note'),
            _b('agent', 5, 1, 'Captured: ship it'),
            _b('quick-entry', 6, 2, 'Buy milk'),
          ],
        );
        expect(
          merged,
          'My note\nCaptured: ship it, and then some\n\nBuy milk\n$_footer',
        );
      },
    );

    test(
      'ignores agent and quick-entry blocks at or below base, and all person blocks',
      () {
        final merged = mergeConflict(
          localPerson: 'My note\n',
          baseVersion: 4,
          serverBody: 'Old agent\n\nOld quick\n\nNewer person\n$_footer',
          serverBlocks: [
            _b('agent', 4, 0, 'Old agent'),
            _b('quick-entry', 3, 1, 'Old quick'),
            _b('person', 5, 2, 'Newer person'),
            _b('person', 9, 3, 'Another person edit'),
          ],
        );
        expect(merged, 'My note\n$_footer');
      },
    );

    test('appends a block created at base + 1 but not one created at base', () {
      final merged = mergeConflict(
        localPerson: 'My note\n',
        baseVersion: 4,
        serverBody: 'My note\n\nAt base\n\nJust newer\n$_footer',
        serverBlocks: [
          _b('person', 3, 0, 'My note'),
          _b('agent', 4, 1, 'At base'),
          _b('quick-entry', 5, 2, 'Just newer'),
        ],
      );
      expect(merged, 'My note\n\nJust newer\n$_footer');
    });

    test(
      'appends a newer quick-entry and agent block in ord order, blank-line separated',
      () {
        final merged = mergeConflict(
          localPerson: 'My note\n',
          baseVersion: 4,
          serverBody: 'My note\n\nFirst by ord\n\nSecond by ord\n$_footer',
          // Deliberately out of ord order in the list.
          serverBlocks: [
            _b('agent', 6, 2, 'Second by ord'),
            _b('person', 3, 0, 'My note'),
            _b('quick-entry', 5, 1, 'First by ord'),
          ],
        );
        expect(
          merged,
          'My note\n\nFirst by ord\n\nSecond by ord\n<!-- memex:topics -->\n[[Player Loop~about]]\n',
        );
      },
    );

    test(
      'pads local text without a trailing newline to a blank line before appending',
      () {
        final merged = mergeConflict(
          localPerson: 'My note',
          baseVersion: 4,
          serverBody: _footer,
          serverBlocks: [_b('quick-entry', 5, 1, 'A'), _b('agent', 7, 2, 'B')],
        );
        expect(merged, 'My note\n\nA\n\nB\n$_footer');
      },
    );

    test(
      'does not add extra newlines when local text already ends with a blank line',
      () {
        final merged = mergeConflict(
          localPerson: 'My note\n\n',
          baseVersion: 4,
          serverBody: _footer,
          serverBlocks: [_b('agent', 5, 1, 'A')],
        );
        expect(merged, 'My note\n\nA\n$_footer');
      },
    );

    test('appends without a leading separator when local text is empty', () {
      final merged = mergeConflict(
        localPerson: '',
        baseVersion: 0,
        serverBody: 'A\n\nB\n$_footer',
        serverBlocks: [_b('agent', 1, 0, 'A'), _b('quick-entry', 2, 1, 'B')],
      );
      expect(merged, 'A\n\nB\n$_footer');
    });

    test('keeps multi-byte local text and block text intact', () {
      final merged = mergeConflict(
        localPerson: 'Café ☕ notes\n',
        baseVersion: 2,
        serverBody: 'Café ☕ notes\n\n😀 jump arc\n$_footer',
        serverBlocks: [
          _b('person', 1, 0, 'Café ☕ notes'),
          _b('agent', 3, 1, '😀 jump arc'),
        ],
      );
      expect(merged, 'Café ☕ notes\n\n😀 jump arc\n$_footer');
    });

    test(
      'footer-only conflict returns local text followed by the server footer',
      () {
        final merged = mergeConflict(
          localPerson: 'My note\nmore typing\n',
          baseVersion: 4,
          serverBody:
              'My note\n<!-- memex:topics -->\n[[Sleep~about]]\n[[Player Loop~about]]\n',
          serverBlocks: [_b('person', 3, 0, 'My note')],
        );
        expect(
          merged,
          'My note\nmore typing\n<!-- memex:topics -->\n[[Sleep~about]]\n[[Player Loop~about]]\n',
        );
      },
    );

    test(
      'footer-only conflict with unterminated local text adds one newline before the marker',
      () {
        final merged = mergeConflict(
          localPerson: 'My note',
          baseVersion: 4,
          serverBody: 'My note\n$_footer',
          serverBlocks: [_b('person', 3, 0, 'My note')],
        );
        expect(merged, 'My note\n$_footer');
      },
    );

    test(
      'footer-only conflict with a chip-less server body keeps an empty footer',
      () {
        final merged = mergeConflict(
          localPerson: 'My note\n',
          baseVersion: 4,
          serverBody: 'My note\n',
          serverBlocks: const [],
        );
        expect(merged, 'My note\n<!-- memex:topics -->\n');
      },
    );

    test(
      'takes chips from the server body, not stray server text below the marker',
      () {
        final merged = mergeConflict(
          localPerson: 'Mine\n',
          baseVersion: 4,
          serverBody:
              'Theirs\n<!-- memex:topics -->\n[[X~about]]\nstray\n[[Y~about]]\n',
          serverBlocks: const [],
        );
        expect(
          merged,
          'Mine\n<!-- memex:topics -->\n[[X~about]]\n[[Y~about]]\n',
        );
      },
    );
  });
}
