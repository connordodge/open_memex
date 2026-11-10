// Tests for the public tree (#377, Spec #367 requirement 10 and the
// "leak check over the tree" acceptance criterion).
//
// The public repo drops five dev paths (they live in a private companion
// dir after the cutover). Everything else that git tracks must pass the Leak
// check with an empty deny-list: no home path, no personal email. The scan
// runs over a copy of the tracked files, so untracked build output and local
// files never count, and a positive control proves the scan can fail.
//
// Fixtures never hold a literal leak: the planted path is built at run time
// (leakPath), so this file passes the Leak check itself.
@Timeout(Duration(minutes: 8))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/script_harness.dart';

const _script = 'scripts/leak-check.sh';

/// The five paths that stay out of the public tree (decision D1).
const _devPaths = <String>[
  '.claude/orchestration',
  '.act',
  'ai_specs',
  'CLAUDE.md',
  'AGENTS.md',
];

bool _isDevPath(String path) =>
    _devPaths.any((d) => path == d || path.startsWith('$d/'));

/// `LEAK <where>:<n> <rule> ...` on stdout; `LEAK WARN` lines are not hits.
final _hitLine = RegExp(r'^LEAK (?!WARN)(.+)$', multiLine: true);

/// Copies every tracked path except the dev paths into [dest]; returns how
/// many it copied.
Future<int> _copyTrackedPublicFiles(
  IsolatedEnv iso,
  String root,
  String dest,
) async {
  final listed = await runGit(iso, root, ['ls-files', '-z']);
  var copied = 0;
  for (final path in listed.stdout.split('\u0000')) {
    if (path.isEmpty || _isDevPath(path)) continue;
    final src = '$root/$path';
    final type = FileSystemEntity.typeSync(src, followLinks: false);
    final target = '$dest/$path';
    switch (type) {
      case FileSystemEntityType.file:
        await Directory(File(target).parent.path).create(recursive: true);
        await File(src).copy(target);
        copied++;
      case FileSystemEntityType.link:
        await Directory(File(target).parent.path).create(recursive: true);
        await Link(target).create(await Link(src).target());
        copied++;
      default:
        // Deleted in the working tree but still in the index, or a submodule.
        break;
    }
  }
  return copied;
}

void main() {
  test(
    'tree scan over every tracked public file exits 0 and flags a planted home path',
    () async {
      final iso = await isolatedEnv();
      final root = repoRoot();
      final dest = '${iso.work.path}/public-tree';
      await Directory(dest).create(recursive: true);

      final copied = await _copyTrackedPublicFiles(iso, root, dest);
      expect(
        copied,
        greaterThan(300),
        reason: 'the copy reaches the tracked files (got $copied)',
      );
      // The dev paths stay out of the scan, the rest stays in.
      for (final dev in _devPaths) {
        expect(
          FileSystemEntity.typeSync('$dest/$dev', followLinks: false),
          FileSystemEntityType.notFound,
          reason: '$dev is not part of the public tree',
        );
      }
      expect(File('$dest/README.md').existsSync(), isTrue);
      expect(File('$dest/$_script').existsSync(), isTrue);

      final clean = await runScript(_script, [
        '--tree',
        dest,
        '--allow-empty-patterns',
      ], env: iso.env);
      final hits = _hitLine.allMatches(clean.stdout).map((m) => m[0]).toList();
      expect(hits, isEmpty, reason: 'LEAK lines in the tracked public files');
      expect(clean.exitCode, 0, reason: clean.output);

      // Positive control: the same scan fails on a planted home path, so a
      // clean result above means something.
      final planted = File('$dest/docs/planted-control.md');
      await planted.parent.create(recursive: true);
      await planted.writeAsString('see ${leakPath('stranger')}notes\n');
      final dirty = await runScript(_script, [
        '--tree',
        dest,
        '--allow-empty-patterns',
      ], env: iso.env);
      expect(dirty.exitCode, 1, reason: dirty.output);
      final dirtyHits = _hitLine.allMatches(dirty.stdout).toList();
      expect(dirtyHits, isNotEmpty, reason: 'a LEAK line for the planted file');
      expect(
        dirtyHits.any((m) => m[1]!.contains('planted-control.md')),
        isTrue,
        reason: 'the LEAK line names the planted file\n${dirty.stdout}',
      );
      expect(
        dirty.output.contains('stranger'),
        isFalse,
        reason: 'the leaked name is redacted from the output',
      );
    },
  );
}
