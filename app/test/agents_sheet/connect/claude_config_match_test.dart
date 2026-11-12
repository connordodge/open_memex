// WI #404 (Spec #394 req 29): Claude Desktop setup detection over one
// config read, and the status copy for each result. Pure: paths resolve
// through an injected resolver, so no test touches the file system.
//
// API under test (app/lib/src/agents_sheet/connect/claude_config_match.dart):
//   ClaudeDesktopSetup detectClaudeDesktopSetup(ClaudeConfigRead read,
//       {vault, homeDirectory, resolvePath})
//   LocalClaudeVaultTarget(path), HostedClaudeVaultTarget(mcpAddress)
//   ClaudeDesktopLocalMatch / HostedMatch / TildePath / NotSetUp /
//       ConfigMissing / ConfigUnreadable, each with statusText
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/connect/claude_config_match.dart';
import 'package:open_memex_app/src/agents_sheet/connect/claude_config_reader.dart';

import '../../support/claude_config_reader_fakes.dart';

const _home = '/Users/you';
const _vault = '/Users/you/Notes/Studio';
const _bundled = '/Applications/Open Memex.app/Contents/MacOS/memex';
const _address = 'http://192.168.1.20:7878/vaults/studio/mcp';

String _wi404Identity(String path) => path;

/// Detects against a config whose `mcpServers` is [servers].
ClaudeDesktopSetup _wi404Detect(
  Object? servers, {
  ClaudeVaultTarget vault = const LocalClaudeVaultTarget(_vault),
  PathResolver resolvePath = _wi404Identity,
}) => detectClaudeDesktopSetup(
  ClaudeConfigContents(jsonEncode({'mcpServers': servers})),
  vault: vault,
  homeDirectory: _home,
  resolvePath: resolvePath,
);

Map<String, Object?> _wi404Entry(Object? args, {Object? command = _bundled}) =>
    {'command': command, 'args': args};

Matcher _isLocal(String name, {required bool withEmbeddings}) =>
    isA<ClaudeDesktopLocalMatch>()
        .having((m) => m.entryName, 'entryName', name)
        .having((m) => m.withEmbeddings, 'withEmbeddings', withEmbeddings);

Matcher _isHosted(String name) => isA<ClaudeDesktopHostedMatch>().having(
  (m) => m.entryName,
  'entryName',
  name,
);

Matcher _isTilde(String name) =>
    isA<ClaudeDesktopTildePath>().having((m) => m.entryName, 'entryName', name);

final _notSetUp = isA<ClaudeDesktopNotSetUp>();

const _hosted = HostedClaudeVaultTarget(_address);

void main() {
  test('local match via --vault path and --vault=path', () {
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', _vault]),
      }),
      _isLocal('memex', withEmbeddings: false),
    );
    expect(
      _wi404Detect({
        'my notes': _wi404Entry(['serve', '--vault=$_vault']),
      }),
      _isLocal('my notes', withEmbeddings: false),
    );
    // A different vault in either form doesn't match.
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', '/Users/you/Notes/Other']),
      }),
      _notSetUp,
    );
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault=/Users/you/Notes/Other']),
      }),
      _notSetUp,
    );
  });

  test('local match through a symlink on either side', () {
    const link = '/Users/you/Desktop/Studio link';
    String resolve(String path) => path == link ? _vault : path;

    // The entry names the symlink; the vault is the real path.
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', link]),
      }, resolvePath: resolve),
      _isLocal('memex', withEmbeddings: false),
    );
    // The vault was opened through the symlink; the entry names the target.
    expect(
      _wi404Detect(
        {
          'memex': _wi404Entry(['serve', '--vault=$_vault']),
        },
        vault: const LocalClaudeVaultTarget(link),
        resolvePath: resolve,
      ),
      _isLocal('memex', withEmbeddings: false),
    );
    // Control: without resolving, the symlink doesn't match.
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', link]),
      }),
      _notSetUp,
    );
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', _vault]),
      }, vault: const LocalClaudeVaultTarget(link)),
      _notSetUp,
    );
  });

  test('local match reports withEmbeddings from --with-embeddings', () {
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', _vault, '--with-embeddings']),
      }),
      _isLocal('memex', withEmbeddings: true),
    );
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--with-embeddings', '--vault=$_vault']),
      }),
      _isLocal('memex', withEmbeddings: true),
    );
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', _vault]),
      }),
      _isLocal('memex', withEmbeddings: false),
    );
  });

  test('local match accepts a command of memex or ending in /memex', () {
    for (final command in ['memex', _bundled, '/Users/you/.cargo/bin/memex']) {
      expect(
        _wi404Detect({
          'memex': _wi404Entry(['serve', '--vault', _vault], command: command),
        }),
        _isLocal('memex', withEmbeddings: false),
        reason: command,
      );
    }
  });

  test('hosted match via --remote url and --remote=url', () {
    expect(
      _wi404Detect({
        'memex-studio': _wi404Entry(['serve', '--remote', _address]),
      }, vault: _hosted),
      _isHosted('memex-studio'),
    );
    expect(
      _wi404Detect({
        'nas': _wi404Entry(['serve', '--remote=$_address']),
      }, vault: _hosted),
      _isHosted('nas'),
    );
    // Another vault on the same server doesn't match.
    expect(
      _wi404Detect({
        'memex-home': _wi404Entry([
          'serve',
          '--remote',
          'http://192.168.1.20:7878/vaults/home/mcp',
        ]),
      }, vault: _hosted),
      _notSetUp,
    );
    expect(
      _wi404Detect({
        'memex-home': _wi404Entry([
          'serve',
          '--remote=http://192.168.1.20:7878/vaults/home/mcp',
        ]),
      }, vault: _hosted),
      _notSetUp,
    );
  });

  test('hosted match ignores a trailing slash on either side', () {
    // On the entry.
    expect(
      _wi404Detect({
        'memex-studio': _wi404Entry(['serve', '--remote', '$_address/']),
      }, vault: _hosted),
      _isHosted('memex-studio'),
    );
    expect(
      _wi404Detect({
        'memex-studio': _wi404Entry(['serve', '--remote=$_address//']),
      }, vault: _hosted),
      _isHosted('memex-studio'),
    );
    // On the vault address.
    expect(
      _wi404Detect({
        'memex-studio': _wi404Entry(['serve', '--remote', _address]),
      }, vault: const HostedClaudeVaultTarget('$_address/')),
      _isHosted('memex-studio'),
    );
  });

  test(
    'a local vault never matches a --remote entry and a hosted vault never matches a --vault entry',
    () {
      expect(
        _wi404Detect({
          'memex-studio': _wi404Entry(['serve', '--remote', _vault]),
        }),
        _notSetUp,
      );
      expect(
        _wi404Detect({
          'memex': _wi404Entry(['serve', '--vault', _address]),
        }, vault: _hosted),
        _notSetUp,
      );
      // Control: each flag matches its own kind of vault.
      expect(
        _wi404Detect({
          'memex-studio': _wi404Entry(['serve', '--remote', _address]),
        }, vault: _hosted),
        _isHosted('memex-studio'),
      );
      expect(
        _wi404Detect({
          'memex': _wi404Entry(['serve', '--vault', _vault]),
        }),
        _isLocal('memex', withEmbeddings: false),
      );
    },
  );

  test('a tilde path that would match gives the tilde warning', () {
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', '~/Notes/Studio']),
      }),
      _isTilde('memex'),
    );
    expect(
      _wi404Detect({
        'tilde': _wi404Entry(['serve', '--vault=~/Notes/Studio']),
      }),
      _isTilde('tilde'),
    );
    // A tilde path to another vault is simply no match.
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', '~/Notes/Other']),
      }),
      _notSetUp,
    );
    // The same vault written absolute is a real match, not a warning.
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', '/Users/you/Notes/Studio']),
      }),
      _isLocal('memex', withEmbeddings: false),
    );
  });

  test('a relative path that would match gives the tilde warning', () {
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', 'Notes/Studio']),
      }),
      _isTilde('memex'),
    );
    expect(
      _wi404Detect({
        'rel': _wi404Entry(['serve', '--vault=Notes/Studio']),
      }),
      _isTilde('rel'),
    );
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', 'Notes/Other']),
      }),
      _notSetUp,
    );
  });

  test('a real match wins over a tilde warning in either entry order', () {
    final tilde = _wi404Entry(['serve', '--vault', '~/Notes/Studio']);
    final real = _wi404Entry(['serve', '--vault', _vault, '--with-embeddings']);
    expect(
      _wi404Detect({'a-tilde': tilde, 'b-real': real}),
      _isLocal('b-real', withEmbeddings: true),
    );
    expect(
      _wi404Detect({'a-real': real, 'b-tilde': tilde}),
      _isLocal('a-real', withEmbeddings: true),
    );
  });

  test('a non-memex command gives no match', () {
    for (final command in [
      'node',
      '/usr/local/bin/notmemex',
      '/usr/local/bin/memex-dev',
      'memexd',
      'xmemex',
      '',
    ]) {
      expect(
        _wi404Detect({
          'memex': _wi404Entry(['serve', '--vault', _vault], command: command),
        }),
        _notSetUp,
        reason: command,
      );
    }
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', _vault], command: 42),
      }),
      _notSetUp,
    );
    // Control: the same entry with the memex command matches.
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', _vault]),
      }),
      _isLocal('memex', withEmbeddings: false),
    );
  });

  test('missing args or args without serve give no match', () {
    expect(
      _wi404Detect({
        'memex': {'command': _bundled},
      }),
      _notSetUp,
    );
    expect(
      _wi404Detect({'memex': _wi404Entry('serve --vault $_vault')}),
      _notSetUp,
    );
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['--vault', _vault]),
      }),
      _notSetUp,
    );
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['index', '--vault', _vault]),
      }),
      _notSetUp,
    );
    // --vault with no value after it.
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault']),
      }),
      _notSetUp,
    );
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--remote']),
      }, vault: _hosted),
      _notSetUp,
    );
    // Control: the same entry with serve matches.
    expect(
      _wi404Detect({
        'memex': _wi404Entry(['serve', '--vault', _vault]),
      }),
      _isLocal('memex', withEmbeddings: false),
    );
  });

  test('no matching entry gives no match', () {
    expect(_wi404Detect(<String, Object?>{}), _notSetUp);
    expect(_wi404Detect(null), _notSetUp);
    expect(_wi404Detect(['not', 'a', 'map']), _notSetUp);
    expect(_wi404Detect({'memex': 'not an entry'}), _notSetUp);
    expect(
      detectClaudeDesktopSetup(
        ClaudeConfigContents(jsonEncode({'globalShortcut': 'Cmd+K'})),
        vault: const LocalClaudeVaultTarget(_vault),
        homeDirectory: _home,
        resolvePath: _wi404Identity,
      ),
      _notSetUp,
    );
    // Control: the matching entry among others is found.
    expect(
      _wi404Detect({
        'other': 'not an entry',
        'filesystem': _wi404Entry(['-y', 'server-filesystem'], command: 'npx'),
        'memex': _wi404Entry(['serve', '--vault', _vault]),
      }),
      _isLocal('memex', withEmbeddings: false),
    );
  });

  test(
    'missing file gives missing and oversized or unreadable files give unreadable',
    () async {
      ClaudeDesktopSetup detect(ClaudeConfigRead read) =>
          detectClaudeDesktopSetup(
            read,
            vault: const LocalClaudeVaultTarget(_vault),
            homeDirectory: _home,
            resolvePath: _wi404Identity,
          );
      expect(
        detect(await FakeClaudeConfigReader.missing().read()),
        isA<ClaudeDesktopConfigMissing>(),
      );
      expect(
        detect(await FakeClaudeConfigReader.oversized().read()),
        isA<ClaudeDesktopConfigUnreadable>(),
      );
      expect(
        detect(await FakeClaudeConfigReader.unreadable().read()),
        isA<ClaudeDesktopConfigUnreadable>(),
      );
    },
  );

  test('invalid JSON gives unreadable with no message surfaced or logged', () {
    const secret = 'OTHER-SERVER-SECRET-404';
    final logs = <String>[];
    final previous = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => logs.add('$m');
    late List<ClaudeDesktopSetup> results;
    try {
      results = runZoned(
        () => [
          for (final text in [
            '{"mcpServers": {"x": {"env": {"API_KEY": "$secret"}}',
            '',
            'not json $secret',
            '{"mcpServers": {"x": "$secret",}}',
          ])
            detectClaudeDesktopSetup(
              ClaudeConfigContents(text),
              vault: const LocalClaudeVaultTarget(_vault),
              homeDirectory: _home,
              resolvePath: _wi404Identity,
            ),
        ],
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => logs.add(line),
        ),
      );
    } finally {
      debugPrint = previous;
    }
    for (final r in results) {
      expect(r, isA<ClaudeDesktopConfigUnreadable>());
      expect(r.statusText, 'Couldn’t read Claude Desktop’s config file.');
      expect(r.toString(), isNot(contains(secret)));
      expect(r.toString(), isNot(contains('FormatException')));
    }
    expect(logs, isEmpty);
  });

  test('env values never appear in any result', () {
    const secret = 'ENV-SECRET-404-abcdef0123456789';
    final local = _wi404Detect({
      'memex': {
        'command': _bundled,
        'args': ['serve', '--vault', _vault],
        'env': {'MEMEX_ACCESS_TOKEN': secret, 'OTHER': secret},
      },
    });
    final hosted = _wi404Detect({
      'memex-studio': {
        'command': _bundled,
        'args': ['serve', '--remote', _address],
        'env': {'MEMEX_ACCESS_TOKEN': secret},
      },
    }, vault: _hosted);
    final tilde = _wi404Detect({
      'memex': {
        'command': _bundled,
        'args': ['serve', '--vault', '~/Notes/Studio'],
        'env': {'MEMEX_ACCESS_TOKEN': secret},
      },
    });
    expect(local, _isLocal('memex', withEmbeddings: false));
    expect(hosted, _isHosted('memex-studio'));
    expect(tilde, _isTilde('memex'));
    for (final r in [local, hosted, tilde]) {
      expect(r.toString(), isNot(contains(secret)));
      expect(r.statusText, isNot(contains(secret)));
    }
  });

  test('each detection result maps to the exact status copy', () {
    // Built from run-time values so each constructor runs.
    final name = ['memex', 'studio'].join('-');
    expect(
      ClaudeDesktopLocalMatch(entryName: name, withEmbeddings: true).statusText,
      'Claude Desktop is set up for this vault as "memex-studio" · semantic recall on',
    );
    expect(
      ClaudeDesktopLocalMatch(
        entryName: name,
        withEmbeddings: name.isEmpty,
      ).statusText,
      'Claude Desktop is set up for this vault as "memex-studio" · without semantic recall',
    );
    expect(
      ClaudeDesktopHostedMatch(entryName: name).statusText,
      'Claude Desktop is set up for this vault as "memex-studio"',
    );
    expect(
      ClaudeDesktopTildePath(entryName: name).statusText,
      'Set up as "memex-studio", but its path uses ~, which Claude Desktop doesn’t expand.',
    );
    expect(
      const ClaudeDesktopNotSetUp().statusText,
      'Claude Desktop isn’t set up for this vault yet.',
    );
    expect(
      const ClaudeDesktopConfigMissing().statusText,
      'Claude Desktop’s config file wasn’t found.',
    );
    expect(
      const ClaudeDesktopConfigUnreadable().statusText,
      'Couldn’t read Claude Desktop’s config file.',
    );
  });

  test('detection results from each reader outcome carry the status copy', () async {
    Future<String> status(
      FakeClaudeConfigReader reader, {
      ClaudeVaultTarget vault = const LocalClaudeVaultTarget(_vault),
    }) async => detectClaudeDesktopSetup(
      await reader.read(),
      vault: vault,
      homeDirectory: _home,
      resolvePath: _wi404Identity,
    ).statusText;

    String config(List<String> args) => jsonEncode({
      'mcpServers': {'memex': _wi404Entry(args)},
    });

    expect(
      await status(
        FakeClaudeConfigReader.contents(
          config(['serve', '--vault', _vault, '--with-embeddings']),
        ),
      ),
      'Claude Desktop is set up for this vault as "memex" · semantic recall on',
    );
    expect(
      await status(
        FakeClaudeConfigReader.contents(config(['serve', '--vault', _vault])),
      ),
      'Claude Desktop is set up for this vault as "memex" · without semantic recall',
    );
    expect(
      await status(
        FakeClaudeConfigReader.contents(
          config(['serve', '--remote', _address]),
        ),
        vault: _hosted,
      ),
      'Claude Desktop is set up for this vault as "memex"',
    );
    expect(
      await status(
        FakeClaudeConfigReader.contents(
          config(['serve', '--vault', '~/Notes/Studio']),
        ),
      ),
      'Set up as "memex", but its path uses ~, which Claude Desktop doesn’t expand.',
    );
    expect(
      await status(FakeClaudeConfigReader.contents(config(['serve']))),
      'Claude Desktop isn’t set up for this vault yet.',
    );
    expect(
      await status(FakeClaudeConfigReader.missing()),
      'Claude Desktop’s config file wasn’t found.',
    );
    expect(
      await status(FakeClaudeConfigReader.oversized()),
      'Couldn’t read Claude Desktop’s config file.',
    );
    expect(
      await status(FakeClaudeConfigReader.unreadable()),
      'Couldn’t read Claude Desktop’s config file.',
    );
    expect(
      await status(FakeClaudeConfigReader.contents('{')),
      'Couldn’t read Claude Desktop’s config file.',
    );
  });

  test('the first of two tilde entries is the one the warning names', () {
    final tilde = _wi404Entry(['serve', '--vault', '~/Notes/Studio']);
    final relative = _wi404Entry(['serve', '--vault', 'Notes/Studio']);
    expect(
      _wi404Detect({'a-first': tilde, 'b-second': relative}),
      _isTilde('a-first'),
    );
    expect(
      _wi404Detect({'a-first': relative, 'b-second': tilde}),
      _isTilde('a-first'),
    );
  });

  test(
    'non-string args elements and flags without a string value are skipped',
    () {
      // JSON numbers, null and bool in args are skipped, not thrown on.
      expect(
        _wi404Detect({
          'memex': _wi404Entry(['serve', 42, null, true, '--vault', _vault]),
        }),
        _isLocal('memex', withEmbeddings: false),
      );
      expect(
        _wi404Detect({
          'memex': _wi404Entry([7, 'serve', null, '--vault=$_vault']),
        }),
        _isLocal('memex', withEmbeddings: false),
      );
      expect(
        _wi404Detect({
          'memex': _wi404Entry(['serve', 1.5, '--remote', _address]),
        }, vault: _hosted),
        _isHosted('memex'),
      );
      // A flag whose next element isn't a string, or with nothing after it,
      // has no value.
      expect(
        _wi404Detect({
          'memex': _wi404Entry(['serve', '--vault', 5]),
        }),
        _notSetUp,
      );
      expect(
        _wi404Detect({
          'memex': _wi404Entry(['serve', '--vault', null]),
        }),
        _notSetUp,
      );
      expect(
        _wi404Detect({
          'memex': _wi404Entry(['serve', '--vault']),
        }),
        _notSetUp,
      );
      expect(
        _wi404Detect({
          'memex': _wi404Entry(['serve', '--remote']),
        }, vault: _hosted),
        _notSetUp,
      );
    },
  );

  test(
    'a hosted vault matches a later entry after a non-matching memex entry',
    () {
      const otherAddress = 'http://192.168.1.20:7878/vaults/home/mcp';
      expect(
        _wi404Detect({
          'memex-home': _wi404Entry(['serve', '--remote', otherAddress]),
          'memex-studio': _wi404Entry(['serve', '--remote=$_address']),
        }, vault: _hosted),
        _isHosted('memex-studio'),
      );
      // The same two entries the other way round settle on the first.
      expect(
        _wi404Detect({
          'memex-studio': _wi404Entry(['serve', '--remote', _address]),
          'memex-home': _wi404Entry(['serve', '--remote', otherAddress]),
        }, vault: _hosted),
        _isHosted('memex-studio'),
      );
      // Three entries: neither of the first two matches.
      expect(
        _wi404Detect({
          'a': _wi404Entry(['serve', '--remote', otherAddress]),
          'b': _wi404Entry(['serve', '--remote=$otherAddress/']),
          'c': _wi404Entry(['serve', '--remote', '$_address/']),
        }, vault: _hosted),
        _isHosted('c'),
      );
    },
  );

  test(
    'a local vault matches a later entry after a non-matching memex entry',
    () {
      expect(
        _wi404Detect({
          'memex-other': _wi404Entry([
            'serve',
            '--vault',
            '/Users/you/Notes/Other',
          ]),
          'memex': _wi404Entry([
            'serve',
            '--vault=$_vault',
            '--with-embeddings',
          ]),
        }),
        _isLocal('memex', withEmbeddings: true),
      );
      // An absolute path to another vault doesn't end the search, and the
      // matching entry after it is found.
      expect(
        _wi404Detect({
          'a': _wi404Entry(['serve', '--vault', '/Users/you/Notes/Other']),
          'b': _wi404Entry(['serve', '--vault=/Users/you/Notes/Third']),
          'c': _wi404Entry(['serve', '--vault', _vault]),
        }),
        _isLocal('c', withEmbeddings: false),
      );
    },
  );

  test(
    'a remote entry ahead of a vault entry does not hide the match for either kind of vault',
    () {
      final remoteEntry = _wi404Entry(['serve', '--remote', _address]);
      final vaultEntry = _wi404Entry(['serve', '--vault', _vault]);

      // Local vault: a --remote entry (no --vault flag) comes first.
      expect(
        _wi404Detect({'memex-remote': remoteEntry, 'memex-local': vaultEntry}),
        _isLocal('memex-local', withEmbeddings: false),
      );
      // Hosted vault: a --vault entry (no --remote flag) comes first.
      expect(
        _wi404Detect({
          'memex-local': vaultEntry,
          'memex-remote': remoteEntry,
        }, vault: _hosted),
        _isHosted('memex-remote'),
      );
      // Each kind still ignores the other's entry when it is the only one.
      expect(_wi404Detect({'memex-remote': remoteEntry}), _notSetUp);
      expect(
        _wi404Detect({'memex-local': vaultEntry}, vault: _hosted),
        _notSetUp,
      );
    },
  );
}
