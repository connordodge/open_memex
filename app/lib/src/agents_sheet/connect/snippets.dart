// WI #404 (Spec #394 req 23-25, 28): the Connect tab's copy-ready setup
// strings. Pure Dart; every input is a plain value.
import 'dart:convert';

import '../../vault_access/hosted/utc_offset.dart';
import 'token_text.dart';

/// [value] as the Connect tab's JSON layout (Spec #394 req 23, lead ruling
/// r2 #1): an object is written one key per line, indented two spaces per
/// level past [indent]; a string array stays on one line as
/// `["a", "b"]`. Every string goes through `jsonEncode`, so escaping is
/// `jsonEncode`'s.
String _prettyJson(Object value, [String indent = '']) => switch (value) {
  Map<String, Object>() =>
    '{\n'
        '${value.entries.map((e) => '$indent  ${jsonEncode(e.key)}: ${_prettyJson(e.value, '$indent  ')}').join(',\n')}'
        '\n$indent}',
  List<String>() => '[${value.map(jsonEncode).join(', ')}]',
  _ => jsonEncode(value),
};

/// Claude Desktop's config file, as shown and copied in step 1 (Spec #394
/// req 23).
const String claudeDesktopConfigPath =
    '~/Library/Application Support/Claude/claude_desktop_config.json';

/// [value] as one single-quoted shell word, with each `'` written as
/// `'\''` (Spec #394 req 28).
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// The hosted vault's MCP address, `<server url>/vaults/<vault name>/mcp`,
/// with [serverUrl]'s trailing slashes dropped as `HostedClient` does
/// (Spec #394 req 25).
String mcpAddress({required String serverUrl, required String vaultName}) {
  var base = serverUrl;
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return '$base/vaults/$vaultName/mcp';
}

/// Local vault, Claude Desktop (Spec #394 req 23): the whole
/// `{"mcpServers": {"memex": …}}` object, laid out by `_prettyJson`
/// (two-space objects, inline string arrays). [vaultPath] is already
/// absolute (`p.absolute(LocalVaultRef.path)`). [withEmbeddings] appends
/// `--with-embeddings` to `args`.
String localClaudeDesktopConfig({
  required String memexPath,
  required String vaultPath,
  required bool withEmbeddings,
}) => _prettyJson({
  'mcpServers': {
    'memex': {
      'command': memexPath,
      'args': _localArgs(vaultPath, withEmbeddings: withEmbeddings),
    },
  },
});

/// `memex serve` args for a local vault, as JSON array elements.
List<String> _localArgs(String vaultPath, {required bool withEmbeddings}) => [
  'serve',
  '--vault',
  vaultPath,
  if (withEmbeddings) '--with-embeddings',
];

/// Local vault, Claude Code (Spec #394 req 24):
/// `claude mcp add --scope user memex -- '<memex>' serve --vault '<vault>'`
/// plus ` --with-embeddings` when [withEmbeddings].
String localClaudeCodeCommand({
  required String memexPath,
  required String vaultPath,
  required bool withEmbeddings,
}) {
  final command =
      'claude mcp add --scope user memex -- ${shellQuote(memexPath)} '
      'serve --vault ${shellQuote(vaultPath)}';
  if (!withEmbeddings) return command;
  return '$command --with-embeddings';
}

/// Hosted vault, Claude Desktop (Spec #394 req 25): the
/// `"memex-<vault name>": {…}` entry to merge into `mcpServers`, with
/// `command`, `args` `["serve", "--remote", <address>]` and
/// `env.MEMEX_ACCESS_TOKEN` set to [token]'s text. No embeddings flag.
String hostedClaudeDesktopEntry({
  required String memexPath,
  required String vaultName,
  required String mcpAddress,
  required TokenText token,
}) {
  final entry = _prettyJson({
    'command': memexPath,
    'args': ['serve', '--remote', mcpAddress],
    'env': {'MEMEX_ACCESS_TOKEN': token.text},
  });
  return '${jsonEncode('memex-$vaultName')}: $entry';
}

/// Hosted vault, Claude Code (Spec #394 req 25), one line:
/// `claude mcp add --transport http 'memex-<vault name>' '<address>'`
/// `--header 'Authorization: Bearer <token>'`
/// `--header 'X-Memex-UTC-Offset: <±HH:MM>'`, the offset written by
/// `formatUtcOffset(utcOffset)`.
String hostedClaudeCodeCommand({
  required String vaultName,
  required String mcpAddress,
  required TokenText token,
  required Duration utcOffset,
}) => [
  'claude mcp add --transport http',
  shellQuote('memex-$vaultName'),
  shellQuote(mcpAddress),
  '--header',
  shellQuote('Authorization: Bearer ${token.text}'),
  '--header',
  shellQuote('X-Memex-UTC-Offset: ${formatUtcOffset(utcOffset)}'),
].join(' ');
