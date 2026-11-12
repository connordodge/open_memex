// WI #404 (Spec #394 req 29): the default Claude Desktop config reader,
// against a temp home directory (never the real ~/Library), and the real
// symlink resolver the matcher defaults to.
//
// API under test (app/lib/src/agents_sheet/connect/claude_config_reader.dart):
//   const int claudeConfigMaxBytes
//   FileClaudeConfigReader({homeDirectory}) .path .read()
//   ClaudeConfigContents(contents) / Missing / Unreadable / Oversized
//   String resolveSymlinksOrSelf(String path)
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/connect/claude_config_match.dart';
import 'package:open_memex_app/src/agents_sheet/connect/claude_config_reader.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory home;
  late String configPath;

  setUp(() {
    home = Directory.systemTemp.createTempSync('wi404_home_');
    configPath = p.join(
      home.path,
      'Library',
      'Application Support',
      'Claude',
      'claude_desktop_config.json',
    );
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  File writeConfig(List<int> bytes) {
    final file = File(configPath)..parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file;
  }

  test(
    'FileClaudeConfigReader reads the Claude Desktop config under the given home',
    () async {
      final reader = FileClaudeConfigReader(homeDirectory: home.path);
      expect(reader.path, configPath);

      const text =
          '{"mcpServers": {"memex": {"command": "memex", '
          '"args": ["serve", "--vault", "/Users/you/Büro 日記"]}}}';
      writeConfig(utf8.encode(text));
      final read = await reader.read();
      expect(
        read,
        isA<ClaudeConfigContents>().having((r) => r.contents, 'contents', text),
      );
    },
  );

  test(
    'FileClaudeConfigReader gives missing when there is no config file and creates nothing',
    () async {
      final read = await FileClaudeConfigReader(
        homeDirectory: home.path,
      ).read();
      expect(read, isA<ClaudeConfigMissing>());
      expect(Directory(p.join(home.path, 'Library')).existsSync(), isFalse);
    },
  );

  test(
    'FileClaudeConfigReader gives unreadable for a directory or invalid UTF-8 at the path',
    () async {
      final reader = FileClaudeConfigReader(homeDirectory: home.path);

      Directory(configPath).createSync(recursive: true);
      expect(await reader.read(), isA<ClaudeConfigUnreadable>());
      Directory(configPath).deleteSync();

      writeConfig([0x7b, 0xff, 0xfe, 0x7d]);
      expect(await reader.read(), isA<ClaudeConfigUnreadable>());
    },
  );

  test(
    'FileClaudeConfigReader reads exactly 1 MB and gives oversized at 1 MB plus 1 byte',
    () async {
      expect(claudeConfigMaxBytes, 1024 * 1024);
      final reader = FileClaudeConfigReader(homeDirectory: home.path);

      // A JSON string padded to exactly the limit.
      final atLimit = '{"pad": "${'x' * (claudeConfigMaxBytes - 11)}"}';
      expect(utf8.encode(atLimit).length, claudeConfigMaxBytes);
      writeConfig(utf8.encode(atLimit));
      final read = await reader.read();
      expect(read, isA<ClaudeConfigContents>());
      expect(
        (read as ClaudeConfigContents).contents.length,
        claudeConfigMaxBytes,
      );

      final overLimit = '{"pad": "${'x' * (claudeConfigMaxBytes - 10)}"}';
      expect(utf8.encode(overLimit).length, claudeConfigMaxBytes + 1);
      writeConfig(utf8.encode(overLimit));
      expect(await reader.read(), isA<ClaudeConfigOversized>());
    },
  );

  test('FileClaudeConfigReader never changes the config file', () async {
    const text = '{"mcpServers": {}}';
    final file = writeConfig(utf8.encode(text));
    final past = DateTime(2020, 1, 2, 3, 4, 5);
    file.setLastModifiedSync(past);
    final modeBefore = file.statSync().mode;

    final read = await FileClaudeConfigReader(homeDirectory: home.path).read();
    expect(
      read,
      isA<ClaudeConfigContents>().having((r) => r.contents, 'contents', text),
    );
    expect(file.readAsStringSync(), text);
    expect(file.lastModifiedSync(), past);
    expect(file.statSync().mode, modeBefore);
    expect(file.parent.listSync().map((e) => p.basename(e.path)), [
      'claude_desktop_config.json',
    ]);
  });

  test(
    'resolveSymlinksOrSelf resolves a real symlink and keeps a missing path',
    () {
      final real = Directory(p.join(home.path, 'Notes', 'Studio'))
        ..createSync(recursive: true);
      final link = Link(p.join(home.path, 'Studio link'))
        ..createSync(real.path);
      final resolvedReal = real.resolveSymbolicLinksSync();

      expect(resolveSymlinksOrSelf(link.path), resolvedReal);
      expect(resolveSymlinksOrSelf(real.path), resolvedReal);

      final missing = p.join(home.path, 'no such vault');
      expect(resolveSymlinksOrSelf(missing), missing);
    },
  );

  test(
    'detection through resolveSymlinksOrSelf matches a vault opened through a real symlink',
    () {
      final real = Directory(p.join(home.path, 'Notes', 'Studio'))
        ..createSync(recursive: true);
      final link = Link(p.join(home.path, 'Studio link'))
        ..createSync(real.path);
      final config = ClaudeConfigContents(
        jsonEncode({
          'mcpServers': {
            'memex': {
              'command': '/Applications/Open Memex.app/Contents/MacOS/memex',
              'args': ['serve', '--vault', real.path, '--with-embeddings'],
            },
          },
        }),
      );
      expect(
        detectClaudeDesktopSetup(
          config,
          vault: LocalClaudeVaultTarget(link.path),
          homeDirectory: home.path,
          resolvePath: resolveSymlinksOrSelf,
        ),
        isA<ClaudeDesktopLocalMatch>()
            .having((m) => m.entryName, 'entryName', 'memex')
            .having((m) => m.withEmbeddings, 'withEmbeddings', isTrue),
      );
    },
  );

  test(
    'FileClaudeConfigReader gives unreadable for a file the process may not read',
    () async {
      final file = writeConfig(utf8.encode('{"mcpServers": {}}'));
      final reader = FileClaudeConfigReader(homeDirectory: home.path);
      expect(await reader.read(), isA<ClaudeConfigContents>());

      expect(Process.runSync('chmod', ['000', file.path]).exitCode, 0);
      addTearDown(() {
        if (file.existsSync()) Process.runSync('chmod', ['600', file.path]);
      });
      // A process that may read it anyway (root) can't show the branch.
      final canStillRead = () {
        try {
          file.readAsBytesSync();
          return true;
        } on FileSystemException {
          return false;
        }
      }();
      if (canStillRead) {
        markTestSkipped('the process can read a mode 000 file (root)');
        return;
      }
      expect(await reader.read(), isA<ClaudeConfigUnreadable>());

      // Restoring the mode reads it again, so the result came from the mode.
      expect(Process.runSync('chmod', ['600', file.path]).exitCode, 0);
      expect(await reader.read(), isA<ClaudeConfigContents>());
    },
  );
}
