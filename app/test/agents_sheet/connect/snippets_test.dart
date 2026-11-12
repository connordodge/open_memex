// WI #404 (Spec #394 req 23-25, 28): the Connect tab's exact snippet
// strings, snapshot against the docs' commands (which differ only in
// quoting), plus the sentinel-token test across every builder and the
// Claude Desktop matcher.
//
// API under test (app/lib/src/agents_sheet/connect/snippets.dart):
//   const String claudeDesktopConfigPath
//   String shellQuote(String value)
//   String mcpAddress({serverUrl, vaultName})
//   String localClaudeDesktopConfig({memexPath, vaultPath, withEmbeddings})
//   String localClaudeCodeCommand({memexPath, vaultPath, withEmbeddings})
//   String hostedClaudeDesktopEntry({memexPath, vaultName, mcpAddress, token})
//   String hostedClaudeCodeCommand({vaultName, mcpAddress, token, utcOffset})
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/connect/claude_config_match.dart';
import 'package:open_memex_app/src/agents_sheet/connect/claude_config_reader.dart';
import 'package:open_memex_app/src/agents_sheet/connect/snippets.dart';
import 'package:open_memex_app/src/agents_sheet/connect/token_text.dart';

const _bundled = '/Applications/Open Memex.app/Contents/MacOS/memex';

/// A local vault path, its `jsonEncode`d form and its single-quoted shell
/// word, all written out by hand.
typedef _Wi404Path = ({String label, String path, String json, String shell});

const List<_Wi404Path> _paths = [
  (
    label: 'path with spaces',
    path: '/Users/you/My Notes/Studio',
    json: '"/Users/you/My Notes/Studio"',
    shell: "'/Users/you/My Notes/Studio'",
  ),
  (
    label: 'path with an apostrophe',
    path: "/Users/you/Connor's Notes",
    json: '"/Users/you/Connor\'s Notes"',
    shell: r"'/Users/you/Connor'\''s Notes'",
  ),
  (
    label: 'non-ASCII path',
    path: '/Users/you/Notizen/Büro 日記',
    json: '"/Users/you/Notizen/Büro 日記"',
    shell: "'/Users/you/Notizen/Büro 日記'",
  ),
];

String _localDesktop(String memexJson, String pathJson, {required bool on}) =>
    '{\n'
    '  "mcpServers": {\n'
    '    "memex": {\n'
    '      "command": $memexJson,\n'
    '      "args": ["serve", "--vault", $pathJson${on ? ', "--with-embeddings"' : ''}]\n'
    '    }\n'
    '  }\n'
    '}';

String _hostedDesktop({
  required String keyJson,
  required String memexJson,
  required String addressJson,
  required String tokenJson,
}) =>
    '$keyJson: {\n'
    '  "command": $memexJson,\n'
    '  "args": ["serve", "--remote", $addressJson],\n'
    '  "env": {\n'
    '    "MEMEX_ACCESS_TOKEN": $tokenJson\n'
    '  }\n'
    '}';

/// The repo's `docs/<name>` (tests run with `app/` as the working dir).
String _doc(String name) {
  final candidates = [File('../docs/$name'), File('docs/$name')];
  return candidates.firstWhere((f) => f.existsSync()).readAsStringSync();
}

/// The body of the first fenced block tagged [lang] after [heading].
String _fence(String doc, String heading, String lang) {
  final from = doc.indexOf(heading);
  expect(from, isNonNegative, reason: 'heading $heading');
  final open = doc.indexOf('```$lang\n', from);
  final start = open + '```$lang\n'.length;
  final end = doc.indexOf('```', start);
  return doc.substring(start, end);
}

/// Runs [body], returning every `print` and `debugPrint` line it made and
/// every error it threw (as text).
List<String> _wi404CaptureOutput(void Function() body) {
  final lines = <String>[];
  final previous = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) => lines.add('$message');
  try {
    runZoned(
      () {
        try {
          body();
        } catch (e, st) {
          lines
            ..add('$e')
            ..add('$st');
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      ),
    );
  } finally {
    debugPrint = previous;
  }
  return lines;
}

void main() {
  final dots28 = '•' * 28;

  test('claudeDesktopConfigPath is the Claude Desktop config file path', () {
    expect(
      claudeDesktopConfigPath,
      '~/Library/Application Support/Claude/claude_desktop_config.json',
    );
  });

  test(
    'local Claude Desktop config equals the exact JSON with recall on and off for spaces, apostrophe and non-ASCII paths',
    () {
      for (final c in _paths) {
        for (final on in [true, false]) {
          expect(
            localClaudeDesktopConfig(
              memexPath: _bundled,
              vaultPath: c.path,
              withEmbeddings: on,
            ),
            _localDesktop('"$_bundled"', c.json, on: on),
            reason: '${c.label}, withEmbeddings $on',
          );
        }
      }
    },
  );

  test(
    'local Claude Desktop config escapes quotes and backslashes through jsonEncode',
    () {
      const memex = r'/opt/a "b" \tools/memex';
      const vault = r'/Users/you/x "y" \z';
      expect(
        localClaudeDesktopConfig(
          memexPath: memex,
          vaultPath: vault,
          withEmbeddings: false,
        ),
        _localDesktop(
          r'"/opt/a \"b\" \\tools/memex"',
          r'"/Users/you/x \"y\" \\z"',
          on: false,
        ),
      );
      // Round-trips to the same values.
      final decoded =
          jsonDecode(
                localClaudeDesktopConfig(
                  memexPath: memex,
                  vaultPath: vault,
                  withEmbeddings: true,
                ),
              )
              as Map<String, Object?>;
      expect(decoded, {
        'mcpServers': {
          'memex': {
            'command': memex,
            'args': ['serve', '--vault', vault, '--with-embeddings'],
          },
        },
      });
    },
  );

  test(
    'local Claude Desktop config matches docs claude-desktop-setup.md apart from quoting',
    () {
      final doc = _doc('claude-desktop-setup.md');
      const docVault = '/Users/YOUR_USERNAME/Documents/MyMemex';

      final off = jsonDecode(
        _fence(doc, '## 4. Configure Claude Desktop', 'json'),
      );
      final oursOff = localClaudeDesktopConfig(
        memexPath: _bundled,
        vaultPath: docVault,
        withEmbeddings: false,
      );
      expect(oursOff, startsWith('{\n  "mcpServers": {'));
      expect(jsonDecode(oursOff), off);

      final onArgs =
          jsonDecode(
                '{${_fence(doc, '### With semantic (vector) search enabled', 'json')}}',
              )
              as Map<String, Object?>;
      final on =
          jsonDecode(
                localClaudeDesktopConfig(
                  memexPath: _bundled,
                  vaultPath: docVault,
                  withEmbeddings: true,
                ),
              )
              as Map<String, Object?>;
      final memexEntry =
          (on['mcpServers']! as Map<String, Object?>)['memex']!
              as Map<String, Object?>;
      expect(memexEntry['args'], onArgs['args']);
    },
  );

  test(
    'local Claude Code command equals the single-quoted form with recall on and off for spaces, apostrophe and non-ASCII paths',
    () {
      for (final c in _paths) {
        final base =
            "claude mcp add --scope user memex -- '$_bundled' serve --vault ${c.shell}";
        expect(
          localClaudeCodeCommand(
            memexPath: _bundled,
            vaultPath: c.path,
            withEmbeddings: true,
          ),
          '$base --with-embeddings',
          reason: '${c.label}, on',
        );
        expect(
          localClaudeCodeCommand(
            memexPath: _bundled,
            vaultPath: c.path,
            withEmbeddings: false,
          ),
          base,
          reason: '${c.label}, off',
        );
      }
      // The binary path is quoted and escaped the same way.
      expect(
        localClaudeCodeCommand(
          memexPath: "/Users/you/Bob's tools/memex",
          vaultPath: '/v',
          withEmbeddings: false,
        ),
        r"claude mcp add --scope user memex -- '/Users/you/Bob'\''s tools/memex' serve --vault '/v'",
      );
    },
  );

  test(
    'local Claude Code command matches docs daily-review.md apart from quoting',
    () {
      final line = _doc('daily-review.md')
          .split('\n')
          .firstWhere((l) => l.startsWith('claude mcp add --scope user'));
      final ours = localClaudeCodeCommand(
        memexPath: _bundled,
        vaultPath: '/Users/YOU/Documents/MyMemex',
        withEmbeddings: false,
      );
      expect(ours, startsWith('claude mcp add'));
      expect(ours.replaceAll("'", ''), line.replaceAll('"', '').trim());
    },
  );

  test('shellQuote single-quotes a value and escapes each apostrophe', () {
    expect(shellQuote('plain'), "'plain'");
    expect(shellQuote(''), "''");
    expect(shellQuote('a b'), "'a b'");
    expect(shellQuote("it's"), r"'it'\''s'");
    expect(shellQuote("''"), r"''\'''\'''");
    expect(shellQuote(r'$HOME "x" \n'), r"""'$HOME "x" \n'""");
  });

  test('mcpAddress drops trailing slashes from the server URL', () {
    const want = 'http://192.168.1.20:7878/vaults/home/mcp';
    for (final url in [
      'http://192.168.1.20:7878',
      'http://192.168.1.20:7878/',
      'http://192.168.1.20:7878///',
    ]) {
      expect(
        mcpAddress(serverUrl: url, vaultName: 'home'),
        want,
        reason: url,
      );
    }
    // A path prefix on the saved URL is kept.
    expect(
      mcpAddress(serverUrl: 'https://nas.example/memex/', vaultName: 'studio'),
      'https://nas.example/memex/vaults/studio/mcp',
    );
  });

  test(
    'hosted Claude Desktop entry equals the exact JSON with masked, real and placeholder tokens',
    () {
      const token = 'tok-0123456789abcdef0123456789abcd-7f3a';
      const address = 'http://192.168.1.20:7878/vaults/studio/mcp';
      final cases = <(TokenText, String)>[
        (MaskedTokenText(token), '"${dots28}7f3a"'),
        (RealTokenText(token), '"$token"'),
        (const PlaceholderTokenText(), '"paste-the-access-token-here"'),
      ];
      for (final (tokenText, tokenJson) in cases) {
        expect(
          hostedClaudeDesktopEntry(
            memexPath: _bundled,
            vaultName: 'studio',
            mcpAddress: address,
            token: tokenText,
          ),
          _hostedDesktop(
            keyJson: '"memex-studio"',
            memexJson: '"$_bundled"',
            addressJson: '"$address"',
            tokenJson: tokenJson,
          ),
          reason: tokenText.runtimeType.toString(),
        );
      }
      // The address comes from mcpAddress, trailing slashes dropped.
      expect(
        hostedClaudeDesktopEntry(
          memexPath: _bundled,
          vaultName: "Bob's",
          mcpAddress: mcpAddress(
            serverUrl: 'http://192.168.1.20:7878//',
            vaultName: 'studio',
          ),
          token: const PlaceholderTokenText(),
        ),
        _hostedDesktop(
          keyJson: '"memex-Bob\'s"',
          memexJson: '"$_bundled"',
          addressJson: '"$address"',
          tokenJson: '"paste-the-access-token-here"',
        ),
      );
    },
  );

  test(
    'hosted Claude Desktop entry matches docs hosted-vault.md apart from quoting',
    () {
      final doc = _doc('hosted-vault.md');
      final block =
          jsonDecode(_fence(doc, '### Claude Desktop', 'json'))
              as Map<String, Object?>;
      final ours = hostedClaudeDesktopEntry(
        memexPath: _bundled,
        vaultName: 'home',
        mcpAddress: mcpAddress(
          serverUrl: 'http://192.168.1.20:7878/',
          vaultName: 'home',
        ),
        token: const PlaceholderTokenText(),
      );
      expect(ours, startsWith('"memex-home": {'));
      expect(jsonDecode('{$ours}'), block['mcpServers']);
    },
  );

  test(
    'hosted Claude Code command equals the single-quoted form with masked, real and placeholder tokens',
    () {
      const token = 'tok-0123456789abcdef0123456789abcd-7f3a';
      const address = 'http://192.168.1.20:7878/vaults/studio/mcp';
      final cases = <(TokenText, String)>[
        (MaskedTokenText(token), '${dots28}7f3a'),
        (RealTokenText(token), token),
        (const PlaceholderTokenText(), 'paste-the-access-token-here'),
      ];
      for (final (tokenText, shown) in cases) {
        expect(
          hostedClaudeCodeCommand(
            vaultName: 'studio',
            mcpAddress: address,
            token: tokenText,
            utcOffset: const Duration(hours: 1),
          ),
          "claude mcp add --transport http 'memex-studio' '$address' "
          "--header 'Authorization: Bearer $shown' "
          "--header 'X-Memex-UTC-Offset: +01:00'",
          reason: tokenText.runtimeType.toString(),
        );
      }
      // Every substituted value is quoted and escaped, the token included.
      expect(
        hostedClaudeCodeCommand(
          vaultName: "Bob's",
          mcpAddress: mcpAddress(
            serverUrl: 'http://192.168.1.20:7878/',
            vaultName: "Bob's",
          ),
          token: RealTokenText("ab'cd"),
          utcOffset: Duration.zero,
        ),
        r"claude mcp add --transport http 'memex-Bob'\''s' "
        r"'http://192.168.1.20:7878/vaults/Bob'\''s/mcp' "
        r"--header 'Authorization: Bearer ab'\''cd' "
        r"--header 'X-Memex-UTC-Offset: +00:00'",
      );
    },
  );

  test(
    'hosted Claude Code command matches docs hosted-vault.md apart from quoting',
    () {
      final doc = _doc('hosted-vault.md');
      final block = _fence(doc, '### Claude Code', 'bash');
      final docLine = block
          .split('\n')
          .where((l) => !l.startsWith('export '))
          .join('\n')
          .replaceAll('\\\n', ' ')
          .replaceAll(r'$MEMEX_ACCESS_TOKEN', 'paste-the-access-token-here')
          .replaceAll('"', '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final ours = hostedClaudeCodeCommand(
        vaultName: 'home',
        mcpAddress: mcpAddress(
          serverUrl: 'http://192.168.1.20:7878',
          vaultName: 'home',
        ),
        token: const PlaceholderTokenText(),
        utcOffset: const Duration(hours: 1),
      );
      expect(ours, startsWith('claude mcp add'));
      expect(ours.replaceAll("'", ''), docLine);
    },
  );

  test(
    'hosted Claude Code UTC offset header uses formatUtcOffset for positive, negative and zero offsets',
    () {
      final cases = <(Duration, String)>[
        (const Duration(hours: 5, minutes: 45), '+05:45'),
        (const Duration(hours: 14), '+14:00'),
        (const Duration(minutes: -30), '-00:30'),
        (const Duration(hours: -12), '-12:00'),
        (Duration.zero, '+00:00'),
      ];
      for (final (offset, header) in cases) {
        expect(
          hostedClaudeCodeCommand(
            vaultName: 'home',
            mcpAddress: 'http://h/vaults/home/mcp',
            token: const PlaceholderTokenText(),
            utcOffset: offset,
          ),
          endsWith(" --header 'X-Memex-UTC-Offset: $header'"),
          reason: '$offset',
        );
      }
    },
  );

  test(
    'sentinel token never appears in any toString, error or log output of builders and matcher',
    () {
      const sentinel = 'SENTINEL-404-do-not-leak-0123456789-7f3a';
      const address = 'http://192.168.1.20:7878/vaults/studio/mcp';
      final shown = <String>[];
      late String maskedDesktop;
      late String maskedCode;
      late ClaudeDesktopSetup envMatch;
      late ClaudeDesktopSetup brokenJson;

      final logs = _wi404CaptureOutput(() {
        final masked = MaskedTokenText(sentinel);
        final real = RealTokenText(sentinel);
        maskedDesktop = hostedClaudeDesktopEntry(
          memexPath: _bundled,
          vaultName: 'studio',
          mcpAddress: address,
          token: masked,
        );
        maskedCode = hostedClaudeCodeCommand(
          vaultName: 'studio',
          mcpAddress: address,
          token: masked,
          utcOffset: const Duration(hours: -5),
        );
        // Real-token snippets carry the token by design (Copy); building them
        // must still log nothing.
        hostedClaudeDesktopEntry(
          memexPath: _bundled,
          vaultName: 'studio',
          mcpAddress: address,
          token: real,
        );
        hostedClaudeCodeCommand(
          vaultName: 'studio',
          mcpAddress: address,
          token: real,
          utcOffset: Duration.zero,
        );
        envMatch = detectClaudeDesktopSetup(
          ClaudeConfigContents(
            jsonEncode({
              'mcpServers': {
                'memex-studio': {
                  'command': _bundled,
                  'args': ['serve', '--remote', address],
                  'env': {'MEMEX_ACCESS_TOKEN': sentinel},
                },
              },
            }),
          ),
          vault: const HostedClaudeVaultTarget(address),
          homeDirectory: '/Users/you',
          resolvePath: (p) => p,
        );
        brokenJson = detectClaudeDesktopSetup(
          ClaudeConfigContents(
            '{"mcpServers": {"memex-studio": {"env": '
            '{"MEMEX_ACCESS_TOKEN": "$sentinel"}',
          ),
          vault: const HostedClaudeVaultTarget(address),
          homeDirectory: '/Users/you',
          resolvePath: (p) => p,
        );
        shown.addAll([
          masked.toString(),
          real.toString(),
          maskedDesktop,
          maskedCode,
          envMatch.toString(),
          envMatch.statusText,
          brokenJson.toString(),
          brokenJson.statusText,
        ]);
      });

      // Positive anchors: the builders and matcher did their work.
      expect(maskedDesktop, contains('"MEMEX_ACCESS_TOKEN": "${dots28}7f3a"'));
      expect(maskedCode, contains("'Authorization: Bearer ${dots28}7f3a'"));
      expect(
        envMatch,
        isA<ClaudeDesktopHostedMatch>().having(
          (m) => m.entryName,
          'entryName',
          'memex-studio',
        ),
      );
      expect(brokenJson, isA<ClaudeDesktopConfigUnreadable>());

      for (final text in [...shown, ...logs]) {
        expect(text, isNot(contains('SENTINEL')), reason: text);
      }
    },
  );
}
