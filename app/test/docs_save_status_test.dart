// WI #78 (W2) AC13, Req 56: the save status reads `saved`, never `synced`,
// in the two acceptance docs. `flutter test` runs with `app/` as cwd.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _docs = ['../docs/acceptance-test.md', '../docs/canvas-acceptance.md'];

void main() {
  test(
    'the acceptance docs describe the save status as unsaved saving saved and never say synced',
    () {
      for (final path in _docs) {
        final text = File(path).readAsStringSync();
        expect(
          text,
          contains('unsaved → saving → saved'),
          reason: '$path describes the save status',
        );
        expect(
          text.toLowerCase(),
          isNot(contains('synced')),
          reason: '$path still says synced',
        );
      }
    },
  );
}
