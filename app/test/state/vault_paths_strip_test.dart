// WI #362 round 2: direct pins on the trailing-separator handling of
// `isSameVaultFolder` (state/vault_paths.dart), which the vault picker body
// uses to find the open vault among the recents.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_paths.dart';
import 'package:path/path.dart' as p;

import '../support/vault_folders.dart';

void main() {
  late String dir;

  setUp(() {
    dir = createPlainFolder('om362_strip_').resolveSymbolicLinksSync();
  });

  test('a trailing slash on an existing folder is the same folder', () {
    expect(isSameVaultFolder('$dir/', dir), isTrue);
    expect(isSameVaultFolder(dir, '$dir/'), isTrue);
  });

  test('a trailing slash on a missing path is the same path', () {
    final missing = p.join(dir, 'gone-362');
    expect(isSameVaultFolder('$missing/', missing), isTrue);
    expect(isSameVaultFolder(missing, '$missing/'), isTrue);
  });

  test('a trailing slash does not make a longer name the same folder', () {
    final missing = p.join(dir, 'ab-362');
    expect(isSameVaultFolder('$missing/', '${missing}c'), isFalse);
    expect(isSameVaultFolder('${missing}c', '$missing/'), isFalse);
  });

  test('the root is the same folder as itself and not another folder', () {
    expect(isSameVaultFolder('/', '/'), isTrue);
    expect(isSameVaultFolder('/', dir), isFalse);
  });
}
