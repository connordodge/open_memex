// WI #412 (Spec #394 req 13, 15, 32-35; AC: groups and their order, the
// unknown-group `Other`, the filter's matching, `memex tools` read once and
// classified: exit 2 is too old, no binary is not found). The model, the
// grouping and `ToolsCli` over a FakeMemexCli; nothing here spawns a process
// or hand-copies the tool list: the list is the T1 wire fixture
// `test/fixtures/api_v1/tools/tools.json`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/tools/tool_catalog.dart';
import 'package:open_memex_app/src/cli/tools_cli.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_memex_cli.dart';

const _fixturePath = '$apiV1FixturesDir/tools/tools.json';

/// The fixture's raw wire object (a fresh decode each call).
Map<String, Object?> _wire() =>
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> _wireTools() =>
    (_wire()['tools']! as List).cast<Map<String, Object?>>();

/// Spec req 34's table: the group ids and labels, in order.
const _groups = <(String, String)>[
  ('notes', 'Notes and search'),
  ('daily', 'Daily review'),
  ('folders', 'Smart Folders'),
  ('tags', 'Tags and Note footer'),
  ('feedback', 'Feedback and Vault Guide'),
  ('canvas', 'Canvases'),
];

/// A tool built from run-time values (never a const instance).
ToolInfo _tool(String name, String group, {bool writes = false}) =>
    ToolInfo(name: name, summary: 'does $name', group: group, writes: writes);

String _json(List<Map<String, Object?>> tools) =>
    jsonEncode({'tools': tools, 'prompts': const <Object?>[]});

void main() {
  group('ToolCatalog.fromJson', () {
    test('reads every tool and prompt of the T1 wire fixture in order', () {
      final wire = _wire();
      final catalog = ToolCatalog.fromJson(wire);
      final tools = (wire['tools']! as List).cast<Map<String, Object?>>();
      final prompts = (wire['prompts']! as List).cast<Map<String, Object?>>();
      expect(tools, isNotEmpty);
      expect(prompts, isNotEmpty);
      expect(catalog.tools.map((t) => t.name), [
        for (final t in tools) t['name'],
      ]);
      expect(catalog.tools.map((t) => t.summary), [
        for (final t in tools) t['summary'],
      ]);
      expect(catalog.tools.map((t) => t.group), [
        for (final t in tools) t['group'],
      ]);
      expect(catalog.tools.map((t) => t.writes), [
        for (final t in tools) t['writes'],
      ]);
      expect(catalog.prompts.map((p) => p.name), [
        for (final p in prompts) p['name'],
      ]);
      expect(catalog.prompts.map((p) => p.summary), [
        for (final p in prompts) p['summary'],
      ]);
    });

    test('keeps the order the binary returned and does not sort', () {
      final catalog = ToolCatalog.fromJson({
        'tools': [
          {'name': 'zeta', 'summary': 'z', 'group': 'notes', 'writes': false},
          {'name': 'alpha', 'summary': 'a', 'group': 'notes', 'writes': true},
        ],
        'prompts': [
          {'name': 'second', 'summary': 's'},
          {'name': 'first', 'summary': 'f'},
        ],
      });
      expect(catalog.tools.map((t) => t.name), ['zeta', 'alpha']);
      expect(catalog.tools.map((t) => t.writes), [false, true]);
      expect(catalog.prompts.map((p) => p.name), ['second', 'first']);
    });

    test('accepts empty tool and prompt lists', () {
      final catalog = ToolCatalog.fromJson({'tools': [], 'prompts': []});
      expect(catalog.tools, isEmpty);
      expect(catalog.prompts, isEmpty);
    });

    const tool = {
      'name': 'a',
      'summary': 's',
      'group': 'notes',
      'writes': false,
    };
    const prompt = {'name': 'p', 'summary': 's'};
    final bad = <(String, Object?)>[
      ('fromJson rejects a body that is not an object', [tool]),
      (
        'fromJson rejects a body with no tools',
        {
          'prompts': [prompt],
        },
      ),
      (
        'fromJson rejects a body with no prompts',
        {
          'tools': [tool],
        },
      ),
      (
        'fromJson rejects tools that is not a list',
        {
          'tools': 'x',
          'prompts': [prompt],
        },
      ),
      (
        'fromJson rejects a tool that is not an object',
        {
          'tools': ['a'],
          'prompts': [prompt],
        },
      ),
      (
        'fromJson rejects a tool with no name',
        {
          'tools': [
            {'summary': 's', 'group': 'notes', 'writes': false},
          ],
          'prompts': [prompt],
        },
      ),
      (
        'fromJson rejects a tool whose summary is not a string',
        {
          'tools': [
            {'name': 'a', 'summary': 1, 'group': 'notes', 'writes': false},
          ],
          'prompts': [prompt],
        },
      ),
      (
        'fromJson rejects a tool with no group',
        {
          'tools': [
            {'name': 'a', 'summary': 's', 'writes': false},
          ],
          'prompts': [prompt],
        },
      ),
      (
        'fromJson rejects a tool whose writes is not a bool',
        {
          'tools': [
            {'name': 'a', 'summary': 's', 'group': 'notes', 'writes': 'yes'},
          ],
          'prompts': [prompt],
        },
      ),
      (
        'fromJson rejects a prompt with no summary',
        {
          'tools': [tool],
          'prompts': [
            {'name': 'p'},
          ],
        },
      ),
    ];
    for (final (name, json) in bad) {
      test(name, () {
        expect(() => ToolCatalog.fromJson(json), throwsFormatException);
      });
    }
  });

  group('toolGroups and groupTools', () {
    test('toolGroups are the six req 34 groups in order with their labels', () {
      expect([for (final g in toolGroups) (g.id, g.label)], _groups);
    });

    test('the T1 fixture groups into the six sections in req 34 order', () {
      final catalog = ToolCatalog.fromJson(_wire());
      final sections = groupTools(catalog.tools);
      expect([for (final s in sections) (s.id, s.label)], _groups);
      final wire = _wireTools();
      for (final s in sections) {
        expect(s.tools.map((t) => t.name), [
          for (final t in wire)
            if (t['group'] == s.id) t['name'],
        ], reason: s.label);
      }
      expect(sections.expand((s) => s.tools), hasLength(wire.length));
    });

    test('a group with no tools is left out and the rest keep their order', () {
      final sections = groupTools([
        _tool('c1', 'canvas'),
        _tool('n1', 'notes'),
      ]);
      expect(sections.map((s) => s.id), ['notes', 'canvas']);
      expect(sections.map((s) => s.label), ['Notes and search', 'Canvases']);
    });

    test('tools inside a section keep the order they came in', () {
      final sections = groupTools([
        _tool('zeta', 'daily'),
        _tool('mid', 'notes'),
        _tool('alpha', 'daily'),
      ]);
      expect(sections.map((s) => s.id), ['notes', 'daily']);
      expect(sections.last.tools.map((t) => t.name), ['zeta', 'alpha']);
    });

    test('unknown group ids share one trailing Other section in order', () {
      final sections = groupTools([
        _tool('f1', 'future'),
        _tool('c1', 'canvas'),
        _tool('f2', 'beta'),
        _tool('n1', 'notes'),
      ]);
      expect(sections.map((s) => s.id), ['notes', 'canvas', otherToolGroupId]);
      expect(sections.last.label, 'Other');
      expect(sections.last.tools.map((t) => t.name), ['f1', 'f2']);
    });

    test('Other is the only section when every group is unknown', () {
      final sections = groupTools([_tool('f1', 'future')]);
      expect(sections.map((s) => s.label), ['Other']);
    });

    test('no tools give no sections and no Other', () {
      expect(groupTools(const []), isEmpty);
    });

    test('a group id is matched exactly, not by case', () {
      final sections = groupTools([_tool('n1', 'Notes')]);
      expect(sections.map((s) => s.label), ['Other']);
    });
  });

  group('ToolCatalog.matchingTools', () {
    final catalog = ToolCatalog.fromJson(_wire());
    List<String> names(String q) => [
      for (final t in catalog.matchingTools(q)) t.name,
    ];

    test('a blank query keeps every tool in order', () {
      final all = [for (final t in catalog.tools) t.name];
      expect(names(''), all);
      expect(names('   '), all);
    });

    test('TAG finds tag_note, whatever the case of the query', () {
      expect(names('TAG'), contains('tag_note'));
      expect(names('tag'), names('TAG'));
      expect(names('tAg'), names('TAG'));
    });

    test('a query is trimmed before it matches', () {
      expect(names('  TAG  '), names('tag'));
      expect(names('\ttag\n'), names('tag'));
      expect(names('  TAG  '), contains('tag_note'));
    });

    test('matches names and summaries alike, case-insensitively', () {
      for (final q in ['tag', 'UNIQUE', 'Wikilink', 'daily', 'zzz-no-match']) {
        final needle = q.toLowerCase();
        expect(names(q), [
          for (final t in catalog.tools)
            if (t.name.toLowerCase().contains(needle) ||
                t.summary.toLowerCase().contains(needle))
              t.name,
        ], reason: q);
      }
      // The fixture has a summary-only hit and a name-only hit.
      expect(names('UNIQUE'), contains('create_canvas'));
      expect(
        catalog.tools.firstWhere((t) => t.name == 'create_canvas').name,
        isNot(contains('unique')),
      );
      expect(names('zzz-no-match'), isEmpty);
    });

    test('keeps the returned order and drops the tools that do not match', () {
      final c = ToolCatalog.fromJson({
        'tools': [
          {'name': 'zeta_x', 'summary': 'q', 'group': 'notes', 'writes': false},
          {'name': 'mid', 'summary': 'none', 'group': 'notes', 'writes': false},
          {'name': 'alpha_x', 'summary': 'q', 'group': 'notes', 'writes': true},
        ],
        'prompts': [],
      });
      expect(c.matchingTools('X').map((t) => t.name), ['zeta_x', 'alpha_x']);
      expect(c.matchingTools('q').map((t) => t.name), ['zeta_x', 'alpha_x']);
    });
  });

  group('ToolsCli', () {
    ToolsCli over(FakeMemexCli cli) => ToolsCli(cli);

    test(
      'runs memex tools with no other argument and reads the list',
      () async {
        final raw = File(_fixturePath).readAsStringSync();
        final cli = FakeMemexCli()..on('tools', (_) => FakeMemexCli.ok(raw));
        final r = await over(cli).list();
        expect(r, isA<ToolCatalogOk>());
        expect(
          (r as ToolCatalogOk).catalog.tools.map((t) => t.name),
          ToolCatalog.fromJson(jsonDecode(raw)).tools.map((t) => t.name),
        );
        expect(r.catalog.tools, isNotEmpty);
        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, ['tools']);
      },
    );

    test('reads one compact JSON line like the binary prints', () async {
      final line = jsonEncode(_wire());
      expect(line.contains('\n'), isFalse);
      final cli = FakeMemexCli()
        ..on('tools', (_) => FakeMemexCli.ok('$line\n'));
      final r = await over(cli).list();
      expect(r, isA<ToolCatalogOk>());
    });

    test('exit 2 is too old whatever stderr says', () async {
      for (final stderr in [
        "error: unrecognized subcommand 'tools'",
        '',
        '{"error":{"code":"internal","message":"boom"}}',
      ]) {
        final cli = FakeMemexCli()
          ..on('tools', (_) => FakeMemexCli.failure(stderr, exitCode: 2));
        expect(
          await over(cli).list(),
          isA<ToolCatalogTooOld>(),
          reason: stderr,
        );
      }
    });

    test('a null cli is binary not found and runs nothing', () async {
      expect(
        await const ToolsCli(null).list(),
        isA<ToolCatalogBinaryNotFound>(),
      );
    });

    test('a ProcessException is binary not found', () async {
      final cli = FakeMemexCli()
        ..on('tools', (_) => throw const ProcessException('memex', ['tools']));
      expect(await over(cli).list(), isA<ToolCatalogBinaryNotFound>());
    });

    test(
      'a C1 failure is an error with the raw message and no prefix',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'tools',
            (_) => FakeMemexCli.error('internal', 'tool x has no row'),
          );
        final r = await over(cli).list();
        expect(r, isA<ToolCatalogError>());
        expect((r as ToolCatalogError).message, 'tool x has no row');
      },
    );

    test('a failure that is not a C1 line keeps its stderr text', () async {
      final cli = FakeMemexCli()
        ..on('tools', (_) => FakeMemexCli.failure('panicked at main.rs'));
      final r = await over(cli).list();
      expect(r, isA<ToolCatalogError>());
      expect((r as ToolCatalogError).message, contains('panicked at main.rs'));
    });

    test('exit 0 with output that is not the wire shape is an error', () async {
      for (final out in [
        '',
        'not json',
        '[]',
        '{"tools":[]}',
        _json([{}]),
      ]) {
        final cli = FakeMemexCli()..on('tools', (_) => FakeMemexCli.ok(out));
        final r = await over(cli).list();
        expect(r, isA<ToolCatalogError>(), reason: out);
        expect((r as ToolCatalogError).message, isNotEmpty, reason: out);
      }
    });
  });
}
