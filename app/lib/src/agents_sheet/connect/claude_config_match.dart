// WI #404 (Spec #394 req 29): is Claude Desktop already set up for this
// vault? Pure Dart over one [ClaudeConfigRead]; reads only `mcpServers`,
// never an entry's `env`, and never surfaces a parse error's message.
import 'dart:convert';

import 'package:path/path.dart' as p;

import 'claude_config_reader.dart';

/// Resolves symlinks in a path (injected so tests need no file system).
typedef PathResolver = String Function(String path);

/// The vault the config is checked against.
sealed class ClaudeVaultTarget {
  const ClaudeVaultTarget();
}

/// A local vault at [path] (absolute).
final class LocalClaudeVaultTarget extends ClaudeVaultTarget {
  const LocalClaudeVaultTarget(this.path);

  final String path;
}

/// A hosted vault reached at [mcpAddress] (`<server url>/vaults/<name>/mcp`).
final class HostedClaudeVaultTarget extends ClaudeVaultTarget {
  const HostedClaudeVaultTarget(this.mcpAddress);

  final String mcpAddress;
}

/// The detection result, with the status line Spec #394 req 29 shows for it.
sealed class ClaudeDesktopSetup {
  const ClaudeDesktopSetup();

  /// The exact status copy for this result.
  String get statusText;
}

/// An entry runs `memex serve --vault <this vault>`.
final class ClaudeDesktopLocalMatch extends ClaudeDesktopSetup {
  const ClaudeDesktopLocalMatch({
    required this.entryName,
    required this.withEmbeddings,
  });

  final String entryName;

  /// Whether the entry's `args` contain `--with-embeddings`.
  final bool withEmbeddings;

  @override
  String get statusText {
    final setUp = 'Claude Desktop is set up for this vault as "$entryName"';
    if (withEmbeddings) return '$setUp · semantic recall on';
    return '$setUp · without semantic recall';
  }
}

/// An entry runs `memex serve --remote <this vault's MCP address>`.
final class ClaudeDesktopHostedMatch extends ClaudeDesktopSetup {
  const ClaudeDesktopHostedMatch({required this.entryName});

  final String entryName;

  @override
  String get statusText =>
      'Claude Desktop is set up for this vault as "$entryName"';
}

/// An entry's `--vault` path starts with `~` or is relative and would match
/// once expanded, which Claude Desktop doesn’t do.
final class ClaudeDesktopTildePath extends ClaudeDesktopSetup {
  const ClaudeDesktopTildePath({required this.entryName});

  final String entryName;

  @override
  String get statusText =>
      'Set up as "$entryName", but its path uses ~, which Claude Desktop '
      'doesn’t expand.';
}

/// No entry matches this vault.
final class ClaudeDesktopNotSetUp extends ClaudeDesktopSetup {
  const ClaudeDesktopNotSetUp();

  @override
  String get statusText => 'Claude Desktop isn’t set up for this vault yet.';
}

/// The config file doesn't exist.
final class ClaudeDesktopConfigMissing extends ClaudeDesktopSetup {
  const ClaudeDesktopConfigMissing();

  @override
  String get statusText => 'Claude Desktop’s config file wasn’t found.';
}

/// The config file can't be read or parsed, or is over 1 MB.
final class ClaudeDesktopConfigUnreadable extends ClaudeDesktopSetup {
  const ClaudeDesktopConfigUnreadable();

  @override
  String get statusText => 'Couldn’t read Claude Desktop’s config file.';
}

/// Matches [read]'s `mcpServers` against [vault] (Spec #394 req 29).
///
/// An entry matches when its `command` is `memex` or ends in `/memex` and
/// its `args` hold `serve` and either `--vault <path>` / `--vault=<path>`
/// (both sides through [resolvePath]) or `--remote <url>` /
/// `--remote=<url>` (trailing slashes dropped on both sides). A `--vault`
/// path that starts with `~` or is relative, and would match once `~` is
/// expanded to [homeDirectory] or the path is resolved against it, gives
/// [ClaudeDesktopTildePath]. A real match wins over a warning whatever the
/// entry order.
///
/// Invalid JSON is [ClaudeDesktopConfigUnreadable], its message dropped;
/// valid JSON without a map `mcpServers` is [ClaudeDesktopNotSetUp].
ClaudeDesktopSetup detectClaudeDesktopSetup(
  ClaudeConfigRead read, {
  required ClaudeVaultTarget vault,
  required String homeDirectory,
  required PathResolver resolvePath,
}) {
  final String contents;
  switch (read) {
    case ClaudeConfigMissing():
      return const ClaudeDesktopConfigMissing();
    case ClaudeConfigUnreadable() || ClaudeConfigOversized():
      return const ClaudeDesktopConfigUnreadable();
    case ClaudeConfigContents(contents: final text):
      contents = text;
  }
  final Object? config;
  try {
    config = jsonDecode(contents);
  } on FormatException {
    // The message quotes the source, which can hold other servers' secrets.
    return const ClaudeDesktopConfigUnreadable();
  }
  if (config is! Map<String, Object?>) return const ClaudeDesktopNotSetUp();
  final servers = config['mcpServers'];
  if (servers is! Map<String, Object?>) return const ClaudeDesktopNotSetUp();

  ClaudeDesktopTildePath? warning;
  for (final MapEntry(key: name, value: entry) in servers.entries) {
    if (entry is! Map<String, Object?>) continue;
    final args = _memexServeArgs(entry);
    if (args == null) continue;
    switch (vault) {
      case LocalClaudeVaultTarget(:final path):
        final vaultPath = _flagValue(args, '--vault');
        if (vaultPath == null) continue;
        final target = resolvePath(path);
        if (p.isAbsolute(vaultPath)) {
          if (resolvePath(vaultPath) == target) {
            return ClaudeDesktopLocalMatch(
              entryName: name,
              withEmbeddings: args.contains('--with-embeddings'),
            );
          }
        } else if (resolvePath(_expand(vaultPath, homeDirectory)) == target) {
          warning ??= ClaudeDesktopTildePath(entryName: name);
        }
      case HostedClaudeVaultTarget(:final mcpAddress):
        final remote = _flagValue(args, '--remote');
        if (remote == null) continue;
        if (_dropTrailingSlashes(remote) == _dropTrailingSlashes(mcpAddress)) {
          return ClaudeDesktopHostedMatch(entryName: name);
        }
    }
  }
  return warning ?? const ClaudeDesktopNotSetUp();
}

/// [entry]'s `args` when its `command` is `memex` or ends in `/memex` and
/// its `args` are a list holding `serve`; otherwise null. Never reads `env`.
List<Object?>? _memexServeArgs(Map<String, Object?> entry) {
  final command = entry['command'];
  if (command is! String) return null;
  if (command != 'memex' && !command.endsWith('/memex')) return null;
  final args = entry['args'];
  if (args is! List<Object?>) return null;
  if (!args.contains('serve')) return null;
  return args;
}

/// The value of [flag] in [args], written `<flag> <value>` or
/// `<flag>=<value>`; null when absent or with no value after it.
String? _flagValue(List<Object?> args, String flag) {
  final prefix = '$flag=';
  for (final (i, arg) in args.indexed) {
    if (arg is! String) continue;
    if (arg.startsWith(prefix)) return arg.substring(prefix.length);
    if (arg != flag) continue;
    final next = args.elementAtOrNull(i + 1);
    if (next is String) return next;
  }
  return null;
}

/// A `~` or relative [path] as it reads once `~` is expanded to [home] or
/// the path is resolved against [home].
String _expand(String path, String home) {
  if (path.startsWith('~')) return '$home${path.substring(1)}';
  return p.join(home, path);
}

/// [url] without its trailing slashes, as `HostedClient` builds URLs.
String _dropTrailingSlashes(String url) {
  var trimmed = url;
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}
