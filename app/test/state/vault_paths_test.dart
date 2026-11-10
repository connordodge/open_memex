// WI #360, ruling F1: `isSameVaultFolder` decides whether two spellings of
// a path name the same vault folder. Real temp folders and links only.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_paths.dart';
import 'package:path/path.dart' as p;

import '../support/vault_folders.dart';

void main() {
  late String dir;

  setUp(() {
    // Resolved, so a spelling that does not exist (a case variant on a
    // case-sensitive volume) still differs from it only by case.
    dir = createPlainFolder('om360_paths_').resolveSymbolicLinksSync();
  });

  test('the same path is the same folder', () {
    expect(isSameVaultFolder(dir, dir), isTrue);
  });

  test('a trailing separator is the same folder', () {
    expect(isSameVaultFolder('$dir/', dir), isTrue);
    expect(isSameVaultFolder(dir, '$dir//'), isTrue);
  });

  test('dot and dot dot segments are the same folder', () {
    final dotted = p.join(dir, '.', 'child', '..');
    expect(isSameVaultFolder(dotted, dir), isTrue);
  });

  test('a symlink to the folder is the same folder', () {
    final links = createPlainFolder('om360_links_');
    final link = Link(p.join(links.path, 'to_vault'))..createSync(dir);
    addTearDown(() {
      if (link.existsSync()) link.deleteSync();
    });
    expect(isSameVaultFolder(link.path, dir), isTrue);
  });

  test('a symlinked parent spelling is the same folder', () {
    final vault = Directory(p.join(dir, 'vault'))..createSync();
    final links = createPlainFolder('om360_links_');
    final link = Link(p.join(links.path, 'parent'))..createSync(dir);
    addTearDown(() {
      if (link.existsSync()) link.deleteSync();
    });
    expect(isSameVaultFolder(p.join(link.path, 'vault'), vault.path), isTrue);
  });

  test('a case difference is the same folder', () {
    final vault = Directory(p.join(dir, 'Vault'))..createSync();
    expect(isSameVaultFolder(p.join(dir, 'VAULT'), vault.path), isTrue);
    expect(isSameVaultFolder(p.join(dir, 'vault'), vault.path), isTrue);
  });

  test('two different folders are not the same folder', () {
    final a = Directory(p.join(dir, 'a'))..createSync();
    final b = Directory(p.join(dir, 'b'))..createSync();
    expect(isSameVaultFolder(a.path, b.path), isFalse);
  });

  test('a folder and its parent are not the same folder', () {
    final a = Directory(p.join(dir, 'a'))..createSync();
    expect(isSameVaultFolder(a.path, dir), isFalse);
  });

  test('a path that does not exist compares by its normalized spelling', () {
    final missing = p.join(dir, 'gone', 'Vault');
    expect(isSameVaultFolder(missing, missing), isTrue);
    expect(
      isSameVaultFolder('$missing/', p.join(dir, 'gone', 'vault')),
      isTrue,
    );
    expect(isSameVaultFolder(missing, p.join(dir, 'gone', 'other')), isFalse);
    expect(isSameVaultFolder(missing, dir), isFalse);
  });
}
