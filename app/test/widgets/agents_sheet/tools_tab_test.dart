// WI #412 (Spec #394 req 9, 13, 15-16, 32-35, 44, 47; user story 5; design
// pack design/394-agents-sheet/packs/412.md, RULINGS #5 and #18; lead
// rulings L412-1 and L412-2): the Agents sheet Tools tab. Every test opens
// the real sheet with `pumpAgentsSheet`; the tool list is the T1 wire
// fixture (`test/fixtures/api_v1/tools/tools.json`), never a list copied
// into Dart, served by a FakeMemexCli (local) or a FakeVaultServer (hosted).
//
// Keys the tab exposes (robot tests use them):
//   tools-intro, tools-filter (the field), tools-filter-box (its 30 px box),
//   tools-prompts-label, tools-group-<id> (a section label: notes, daily,
//   folders, tags, feedback, canvas, other), tool-row-<name>,
//   tool-name-<name>, tool-summary-<name>, prompt-row-<name>,
//   prompt-name-<name>, prompt-summary-<name>, tools-locate-memex.
//
// flutter_test draws every glyph one em wide (holdFontFetches keeps the
// fallback font), so the layout tests are stricter than the real fonts.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/agents_sheet/tools/tool_catalog.dart';
import 'package:open_memex_app/src/state/agents_sheet/agents_sheet_state.dart';
import 'package:open_memex_app/src/state/agents_sheet/tools_tab_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/agents_tab_loading.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/tools_tab.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';

import '../../support/agents_sheet_harness.dart';
import '../../support/api_fixtures.dart';
import '../../support/fake_memex_cli.dart';
import '../../support/fake_vault_server.dart';
import '../../support/file_picker_fakes.dart';
import '../../support/font_fetch_hold.dart';

// ------------------------------------------------------------------ fixtures

const _toolsDir = '$apiV1FixturesDir/tools';

/// Spec req 34: group ids and labels, in order.
const _groups = <(String, String)>[
  ('notes', 'Notes and search'),
  ('daily', 'Daily review'),
  ('folders', 'Smart Folders'),
  ('tags', 'Tags and Note footer'),
  ('feedback', 'Feedback and Vault Guide'),
  ('canvas', 'Canvases'),
];

const _introText =
    'What an agent connected to this vault can call. WRITES tools change the '
    'vault and show under Live.';
const _promptsLabel = 'PROMPTS · START A RUN FROM THE CLIENT’S PROMPT MENU';
const _tooOldText = 'Tool list unavailable: this memex is older than the app.';
const _serverTooOldText = 'Tool list unavailable on this vault server.';

/// The raw wire text of the T1 fixture.
String _raw() => File('$_toolsDir/tools.json').readAsStringSync();

Map<String, Object?> _wire() => jsonDecode(_raw()) as Map<String, Object?>;

List<Map<String, Object?>> _wireTools() =>
    (_wire()['tools']! as List).cast<Map<String, Object?>>();

List<Map<String, Object?>> _wirePrompts() =>
    (_wire()['prompts']! as List).cast<Map<String, Object?>>();

String _errorMessage(String file) =>
    ((jsonDecode(File(file).readAsStringSync())! as Map)['error']!
            as Map)['message']!
        as String;

/// The fixture's tool names in display order: groups in req 34 order, each in
/// the fixture's order.
List<String> _displayOrder(List<Map<String, Object?>> tools) => [
  for (final (id, _) in _groups)
    for (final t in tools)
      if (t['group'] == id) t['name']! as String,
];

String _catalog(List<Map<String, Object?>> tools, [List<Map>? prompts]) =>
    jsonEncode({'tools': tools, 'prompts': prompts ?? const <Object?>[]});

Map<String, Object?> _tool(
  String name,
  String group, {
  bool writes = false,
  String? summary,
}) => {
  'name': name,
  'summary': summary ?? 'does $name',
  'group': group,
  'writes': writes,
};

FakeMemexCli _cliWith(String stdout) =>
    FakeMemexCli()..on('tools', (_) => FakeMemexCli.ok(stdout));

// ------------------------------------------------------------------- finders

Finder _key(String k) => find.byKey(Key(k));

Finder _inRow(String name, Finder f) =>
    find.descendant(of: _key('tool-row-$name'), matching: f);

/// The names after [prefix] of every widget keyed `<prefix><name>`, in tree
/// (that is, display) order.
List<String> _named(WidgetTester tester, String prefix) => [
  for (final w in tester.widgetList(
    find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> && k.value.startsWith(prefix);
    }),
  ))
    (w.key! as ValueKey<String>).value.substring(prefix.length),
];

List<String> _shownTools(WidgetTester tester) => _named(tester, 'tool-row-');

List<String> _shownGroups(WidgetTester tester) =>
    _named(tester, 'tools-group-');

TextStyle _styleOf(WidgetTester tester, Finder f) {
  final text = _w<Text>(tester, f);
  return DefaultTextStyle.of(tester.element(f)).style.merge(text.style);
}

Rect _rect(WidgetTester tester, Finder f) {
  expect(f, findsOneWidget);
  return tester.getRect(f);
}

/// The one widget [f] finds (a failing expectation, not a StateError, when
/// the tab does not draw it).
T _w<T extends Widget>(WidgetTester tester, Finder f) {
  expect(f, findsOneWidget);
  return tester.widget<T>(f);
}

// ---------------------------------------------------------------------- pump

Future<AgentsSheetHarness> _pump(
  WidgetTester tester, {
  FakeMemexCli? cli,
  Size size = const Size(1000, 800),
  double textScale = 1.0,
  bool showTools = true,
  List<Override> overrides = const [],
}) async {
  final h = await pumpAgentsSheet(
    tester,
    cli: cli ?? _cliWith(_raw()),
    size: size,
    textScale: textScale,
    overrides: overrides,
  );
  if (showTools) await _showTools(tester, h);
  return h;
}

Future<void> _showTools(WidgetTester tester, AgentsSheetHarness h) async {
  await tester.tap(_key('agents-tab-tools'));
  await h.settle();
}

/// A hosted vault `seed` on a fake server serving [domains].
Future<(AgentsSheetHarness, FakeVaultServer)> _pumpHosted(
  WidgetTester tester, {
  List<String> domains = const ['tools'],
  String vault = seedVaultName,
  Size size = const Size(1000, 800),
  double textScale = 1.0,
  void Function(FakeVaultServer server)? prepare,
  bool showTools = true,
}) async {
  final server = FakeVaultServer();
  for (final d in domains) {
    server.serveDomain(d);
  }
  prepare?.call(server);
  final hostedVault = HostedVaultRef(fakeServerId, vault);
  final h = await pumpAgentsSheet(
    tester,
    vault: hostedVault,
    size: size,
    textScale: textScale,
    open: false,
  );
  h.container.read(hostedSessionProvider.notifier).state = HostedSession(
    hostedVault,
    server.connect(h.container, accessToken: fakeServerToken),
  );
  await h.open();
  if (showTools) await _showTools(tester, h);
  return (h, server);
}

int _serverReads(FakeVaultServer s) =>
    s.requests.where((r) => r.url.path.endsWith('/tools')).length;

void main() {
  holdFontFetches();

  // ------------------------------------------------------------- local list

  group('local list', () {
    testWidgets(
      'the six groups render in req 34 order with their labels and the tools in returned order',
      (tester) async {
        await _pump(tester);
        expect(find.byType(ToolsTab), findsOneWidget);
        expect(_shownGroups(tester), [for (final (id, _) in _groups) id]);
        for (final (id, label) in _groups) {
          expect(
            _w<Text>(tester, _key('tools-group-$id')).data,
            label.toUpperCase(),
          );
        }
        final tools = _wireTools();
        expect(tools, hasLength(37));
        expect(_shownTools(tester), _displayOrder(tools));
        // Labels sit above their own tools and below the previous group.
        var previousBottom = double.negativeInfinity;
        for (final (id, _) in _groups) {
          final label = _rect(tester, _key('tools-group-$id'));
          expect(label.top, greaterThanOrEqualTo(previousBottom), reason: id);
          final members = [
            for (final t in tools)
              if (t['group'] == id) t['name']! as String,
          ];
          for (final m in members) {
            expect(
              _rect(tester, _key('tool-row-$m')).top,
              greaterThanOrEqualTo(label.bottom),
              reason: m,
            );
          }
          previousBottom = _rect(
            tester,
            _key('tool-row-${members.last}'),
          ).bottom;
        }
      },
    );

    testWidgets(
      'a tool with an unknown group appears under a trailing Other and known groups keep their order',
      (tester) async {
        final tools = [
          _tool('zz_future_a', 'future'),
          _tool('c_one', 'canvas', writes: true),
          _tool('zz_future_b', 'beta'),
          _tool('n_one', 'notes'),
        ];
        await _pump(tester, cli: _cliWith(_catalog(tools)));
        expect(_shownGroups(tester), ['notes', 'canvas', 'other']);
        expect(_w<Text>(tester, _key('tools-group-other')).data, 'OTHER');
        expect(_shownTools(tester), [
          'n_one',
          'c_one',
          'zz_future_a',
          'zz_future_b',
        ]);
        final other = _rect(tester, _key('tools-group-other'));
        expect(
          _rect(tester, _key('tool-row-zz_future_a')).top,
          greaterThanOrEqualTo(other.bottom),
        );
        expect(
          other.top,
          greaterThanOrEqualTo(_rect(tester, _key('tool-row-c_one')).bottom),
        );
      },
    );

    testWidgets(
      'the fixture with no unknown group shows no Other and a group with no tools shows no label',
      (tester) async {
        await _pump(
          tester,
          cli: _cliWith(_catalog([_tool('only_note', 'notes')])),
        );
        expect(_shownGroups(tester), ['notes']);
        expect(find.text('OTHER'), findsNothing);
        expect(find.text('DAILY REVIEW'), findsNothing);
      },
    );

    testWidgets('tools keep the order the binary returns and are not sorted', (
      tester,
    ) async {
      final tools = [
        _tool('zeta', 'notes'),
        _tool('alpha', 'notes'),
        _tool('mid', 'notes'),
      ];
      await _pump(tester, cli: _cliWith(_catalog(tools)));
      expect(_shownTools(tester), ['zeta', 'alpha', 'mid']);
    });

    testWidgets('write tools carry the WRITES tag and read tools do not', (
      tester,
    ) async {
      await _pump(tester);
      final tools = _wireTools();
      expect(tools.where((t) => t['writes'] == true), hasLength(24));
      for (final t in tools) {
        final name = t['name']! as String;
        expect(
          _inRow(name, find.text('WRITES')),
          t['writes'] == true ? findsOneWidget : findsNothing,
          reason: name,
        );
      }
      expect(find.text('WRITES'), findsNWidgets(24));
    });

    testWidgets(
      'the WRITES tag is mono 9.5 w500 agent on the tag fill, radius 3, padding 3 and 5',
      (tester) async {
        await _pump(tester);
        final tag = _inRow('add_link', find.text('WRITES'));
        final style = _styleOf(tester, tag);
        expect(style.fontSize, 9.5);
        expect(style.fontWeight, FontWeight.w500);
        expect(style.letterSpacing, 0.8);
        expect(style.height, 1.0);
        expect(style.color, OmColors.agent);
        expect(
          style.fontFamily,
          OmType.mono(weight: FontWeight.w500).fontFamily,
        );
        final box = find
            .ancestor(of: tag, matching: find.byType(DecoratedBox))
            .first;
        final deco = _w<DecoratedBox>(tester, box).decoration as BoxDecoration;
        expect(deco.color, OmColors.writesTagBg);
        expect(deco.color, const Color(0xFF222431));
        expect(deco.borderRadius, BorderRadius.circular(3));
        final textRect = _rect(tester, tag);
        final boxRect = _rect(tester, box);
        expect(textRect.left - boxRect.left, 5);
        expect(boxRect.right - textRect.right, 5);
        expect(textRect.top - boxRect.top, 3);
        expect(boxRect.bottom - textRect.bottom, 3);
      },
    );

    testWidgets(
      'a tool name is mono 12 fg0 and its summary sans 12 fg2 in the binary text',
      (tester) async {
        await _pump(tester);
        final t = _wireTools().firstWhere((t) => t['name'] == 'search');
        final name = _styleOf(tester, _key('tool-name-search'));
        expect(_w<Text>(tester, _key('tool-name-search')).data, 'search');
        expect(name.fontSize, 12);
        expect(name.height, 1.5);
        expect(name.color, OmColors.fg0);
        expect(name.fontFamily, OmType.mono().fontFamily);
        final summary = _styleOf(tester, _key('tool-summary-search'));
        expect(
          _w<Text>(tester, _key('tool-summary-search')).data,
          t['summary'],
        );
        expect(summary.fontSize, 12);
        expect(summary.height, 1.5);
        expect(summary.color, OmColors.fg2);
        expect(summary.fontFamily, OmType.sans().fontFamily);
        expect(summary.fontFamily, isNot(name.fontFamily));
      },
    );

    testWidgets('a long summary wraps and is never ellipsized', (tester) async {
      final long = List.filled(40, 'wraps').join(' ');
      await _pump(
        tester,
        cli: _cliWith(_catalog([_tool('longy', 'notes', summary: long)])),
      );
      final summary = _w<Text>(tester, _key('tool-summary-longy'));
      expect(summary.data, long);
      expect(summary.overflow, isNot(TextOverflow.ellipsis));
      expect(summary.maxLines, isNull);
      expect(_rect(tester, _key('tool-summary-longy')).height, greaterThan(40));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'every row has a 1 px line1 bottom border and prompt rows too',
      (tester) async {
        await _pump(tester);
        for (final k in ['tool-row-search', 'tool-row-add_link']) {
          final names = k.replaceFirst('tool-row-', 'tool-name-');
          _expectBottomBorder(tester, names);
        }
        final prompt = _wirePrompts().first['name']! as String;
        _expectBottomBorder(tester, 'prompt-name-$prompt');
      },
    );
  });

  // ------------------------------------------------------------------ intro

  group('intro, field and prompts', () {
    testWidgets(
      'the intro reads the Spec text with WRITES in agent colour at the same size',
      (tester) async {
        await _pump(tester);
        expect(_key('tools-intro'), findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(
          find
              .descendant(
                of: _key('tools-intro'),
                matching: find.byType(RichText),
              )
              .first,
        );
        final root = paragraph.text as TextSpan;
        expect(root.toPlainText(), _introText);
        // Each text leaf with the style it inherits from its parents.
        final leaves = <(String, TextStyle)>[];
        void walk(InlineSpan span, TextStyle inherited) {
          if (span is! TextSpan) return;
          final style = inherited.merge(span.style);
          final text = span.text;
          if (text != null) leaves.add((text, style));
          for (final c in span.children ?? const <InlineSpan>[]) {
            walk(c, style);
          }
        }

        walk(root, const TextStyle());
        expect(leaves.map((l) => l.$1).join(), _introText);
        for (final (text, style) in leaves) {
          expect(style.fontSize, 12.5, reason: text);
          expect(style.height, 1.55, reason: text);
          expect(
            style.color,
            text == 'WRITES' ? OmColors.agent : OmColors.fg2,
            reason: text,
          );
        }
        expect(leaves.where((l) => l.$1 == 'WRITES'), hasLength(1));
        // The intro's WRITES is not a tool tag.
        expect(find.text('WRITES'), findsNWidgets(24));
      },
    );

    testWidgets(
      'the Filter tools field is a 30 px surface0 box with a search icon and a placeholder',
      (tester) async {
        await _pump(tester);
        final box = _key('tools-filter-box');
        expect(box, findsOneWidget);
        expect(tester.getSize(box).height, 30);
        final deco =
            _w<DecoratedBox>(
                  tester,
                  find
                      .descendant(of: box, matching: find.byType(DecoratedBox))
                      .first,
                ).decoration
                as BoxDecoration;
        expect(deco.color, OmColors.surface0);
        expect(deco.borderRadius, BorderRadius.circular(6));
        expect((deco.border! as Border).top.color, OmColors.line2);
        expect((deco.border! as Border).top.width, 1);
        final icon = _w<Icon>(
          tester,
          find.descendant(of: box, matching: find.byType(Icon)).first,
        );
        expect(icon.icon, LucideIcons.search);
        expect(icon.size, 13);
        expect(icon.color, OmColors.fg2);
        final hint = _w<Text>(tester, find.text('Filter tools'));
        expect(hint.style?.fontSize, 12.5);
        expect(hint.style?.color, OmColors.fg2);
        // The intro is above the field, with 12 px between them.
        expect(
          _rect(tester, box).top - _rect(tester, _key('tools-intro')).bottom,
          12,
        );
      },
    );

    testWidgets('typed filter text is sans 12.5 fg0', (tester) async {
      await _pump(tester);
      expect(_key('tools-filter'), findsOneWidget);
      await tester.enterText(_key('tools-filter'), 'tag');
      await tester.pump();
      final editable = _w<EditableText>(
        tester,
        find.descendant(
          of: _key('tools-filter'),
          matching: find.byType(EditableText),
          matchRoot: true,
        ),
      );
      expect(editable.style.fontSize, 12.5);
      expect(editable.style.color, OmColors.fg0);
    });

    testWidgets(
      'the Prompts section lists each prompt name and summary above the groups',
      (tester) async {
        await _pump(tester);
        expect(
          _w<Text>(tester, _key('tools-prompts-label')).data,
          _promptsLabel,
        );
        final label = _styleOf(tester, _key('tools-prompts-label'));
        expect(label.fontSize, 10.5);
        expect(label.fontWeight, FontWeight.w500);
        expect(label.letterSpacing, 0.8);
        expect(label.color, OmColors.fg2);
        final prompts = _wirePrompts();
        expect(prompts, isNotEmpty);
        expect(_named(tester, 'prompt-row-'), [
          for (final p in prompts) p['name'],
        ]);
        for (final p in prompts) {
          final name = p['name']! as String;
          expect(_w<Text>(tester, _key('prompt-name-$name')).data, name);
          expect(
            _w<Text>(tester, _key('prompt-summary-$name')).data,
            p['summary'],
          );
          final n = _styleOf(tester, _key('prompt-name-$name'));
          expect(n.fontSize, 12);
          expect(n.color, OmColors.fg0);
          expect(n.fontFamily, OmType.mono().fontFamily);
          final s = _styleOf(tester, _key('prompt-summary-$name'));
          expect(s.fontSize, 12);
          expect(s.color, OmColors.fg2);
          expect(
            find.descendant(
              of: _key('prompt-row-$name'),
              matching: find.text('WRITES'),
            ),
            findsNothing,
          );
        }
        final last = _rect(tester, _key('prompt-row-${prompts.last['name']}'));
        expect(
          _rect(tester, _key('tools-group-notes')).top,
          greaterThanOrEqualTo(last.bottom),
        );
        expect(
          _rect(tester, _key('tools-prompts-label')).top,
          greaterThanOrEqualTo(_rect(tester, _key('tools-filter-box')).bottom),
        );
      },
    );
  });

  // ----------------------------------------------------------------- filter

  group('filter', () {
    Future<void> type(WidgetTester tester, String q) async {
      expect(_key('tools-filter'), findsOneWidget);
      await tester.enterText(_key('tools-filter'), q);
      await tester.pump();
    }

    List<String> expected(String q) {
      final needle = q.toLowerCase();
      return _displayOrder([
        for (final t in _wireTools())
          if ((t['name']! as String).toLowerCase().contains(needle) ||
              (t['summary']! as String).toLowerCase().contains(needle))
            t,
      ]);
    }

    testWidgets('TAG finds tag_note whatever the case', (tester) async {
      await _pump(tester);
      for (final q in ['TAG', 'tag', 'tAg']) {
        await type(tester, q);
        expect(_shownTools(tester), contains('tag_note'), reason: q);
        expect(_shownTools(tester), expected('tag'), reason: q);
      }
      expect(_shownTools(tester), isNot(contains('search')));
    });

    testWidgets(
      'a word from a summary finds its tool and nothing it does not match',
      (tester) async {
        await _pump(tester);
        final create = _wireTools().firstWhere(
          (t) => t['name'] == 'create_canvas',
        );
        final word = ((create['summary']! as String).split(
          ' ',
        )..removeAt(0)).firstWhere((w) => w.toLowerCase() == 'unique');
        await type(tester, word.toUpperCase());
        expect(_shownTools(tester), contains('create_canvas'));
        expect(_shownTools(tester), expected('unique'));
        expect(
          (create['name']! as String).toLowerCase().contains('unique'),
          isFalse,
        );
      },
    );

    testWidgets(
      'groups with no matching tool are hidden and the others keep their order',
      (tester) async {
        await _pump(tester);
        await type(tester, 'canvas');
        final shown = _shownTools(tester);
        expect(shown, expected('canvas'));
        final groupsOfShown = {
          for (final t in _wireTools())
            if (shown.contains(t['name'])) t['group']! as String,
        };
        expect(_shownGroups(tester), [
          for (final (id, _) in _groups)
            if (groupsOfShown.contains(id)) id,
        ]);
        expect(_shownGroups(tester).length, lessThan(_groups.length));
        expect(_shownGroups(tester), contains('canvas'));
      },
    );

    testWidgets(
      'a query that matches nothing hides every tool row and group label',
      (tester) async {
        await _pump(tester);
        await type(tester, 'zzz-no-such-tool');
        expect(_shownTools(tester), isEmpty);
        expect(_shownGroups(tester), isEmpty);
        expect(find.text('WRITES'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('clearing the filter shows every group and tool again', (
      tester,
    ) async {
      await _pump(tester);
      await type(tester, 'tag');
      expect(_shownTools(tester).length, lessThan(37));
      await type(tester, '');
      expect(_shownTools(tester), _displayOrder(_wireTools()));
      expect(_shownGroups(tester), [for (final (id, _) in _groups) id]);
    });

    testWidgets(
      'the filter narrows by a tool name and a surviving row keeps its tag',
      (tester) async {
        await _pump(tester);
        await type(tester, 'ADD_');
        expect(_shownTools(tester), expected('add_'));
        expect(_inRow('add_link', find.text('WRITES')), findsOneWidget);
      },
    );
  });

  // ---------------------------------------------------------- shift cmd A

  group('shift cmd A in the filter field', () {
    testWidgets(
      'returns ignored: nothing handles it and nothing opens from Dart',
      (tester) async {
        final saved = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        try {
          final h = await _pump(tester);
          await tester.tap(_key('tools-filter'));
          await tester.pump();
          final field = _w<EditableText>(
            tester,
            find.descendant(
              of: _key('tools-filter'),
              matching: find.byType(EditableText),
              matchRoot: true,
            ),
          );
          expect(field.focusNode.hasPrimaryFocus, isTrue);
          final pushedBefore = h.routes.pushed.length;
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          final handled = await tester.sendKeyDownEvent(
            LogicalKeyboardKey.keyA,
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pump();
          expect(handled, isFalse);
          expect(h.routes.pushed.length, pushedBefore);
          expect(h.menuHost.openAgentsDelivered, 0);
          expect(agentsSheetFinder, findsOneWidget);
          expect(field.controller.text, isEmpty);
        } finally {
          debugDefaultTargetPlatformOverride = saved;
        }
      },
    );
  });

  // --------------------------------------------------------------- loading

  group('load once per sheet open', () {
    testWidgets(
      'memex tools runs once when the sheet opens, before the Tools tab is shown',
      (tester) async {
        final cli = _cliWith(_raw());
        final h = await _pump(tester, cli: cli, showTools: false);
        expect(h.read(agentsSheetTabProvider), isNot(AgentsTab.tools));
        expect(cli.callsFor('tools'), hasLength(1));
        expect(cli.callsFor('tools').single.args, ['tools']);
      },
    );

    testWidgets('tab switches never read again', (tester) async {
      final cli = _cliWith(_raw());
      final h = await _pump(tester, cli: cli, showTools: false);
      await _showTools(tester, h);
      for (final tab in ['connect', 'tools', 'recall', 'live', 'tools']) {
        await tester.tap(_key('agents-tab-$tab'));
        await h.settle();
      }
      expect(h.read(agentsSheetTabProvider), AgentsTab.tools);
      expect(cli.callsFor('tools'), hasLength(1));
      expect(_shownTools(tester), _displayOrder(_wireTools()));
    });

    testWidgets('closing and opening the sheet again reads once more', (
      tester,
    ) async {
      final cli = _cliWith(_raw());
      final h = await _pump(tester, cli: cli);
      expect(cli.callsFor('tools'), hasLength(1));
      await tester.tap(_key('agents-sheet-close'));
      await h.settle();
      await h.settle();
      expect(agentsSheetFinder, findsNothing);
      expect(cli.callsFor('tools'), hasLength(1));
      await h.open();
      expect(agentsSheetFinder, findsOneWidget);
      expect(cli.callsFor('tools'), hasLength(2));
      await _showTools(tester, h);
      expect(cli.callsFor('tools'), hasLength(2));
      expect(_shownTools(tester), _displayOrder(_wireTools()));
    });

    testWidgets(
      'a local vault reads the memex binary and sends no request to a server',
      (tester) async {
        final cli = _cliWith(_raw());
        await _pump(tester, cli: cli);
        expect(cli.callsFor('tools'), hasLength(1));
      },
    );

    testWidgets(
      'while the read is in flight the tab shows the shared loading state and no list',
      (tester) async {
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final cli = FakeMemexCli()
          ..on('tools', (_) async {
            await gate.future;
            return FakeMemexCli.ok(_raw());
          });
        final h = await _pump(tester, cli: cli);
        expect(find.byType(AgentsTabLoading), findsOneWidget);
        expect(_shownTools(tester), isEmpty);
        expect(_key('tools-intro'), findsNothing);
        expect(find.text('loading…'), findsNothing);
        h.clock.advance(AgentsTabLoading.delay);
        await h.settle();
        expect(find.text('loading…'), findsOneWidget);
        expect(h.read(toolsTabBadgeProvider), isNull);
        gate.complete();
        await h.settle();
        expect(find.byType(AgentsTabLoading), findsNothing);
        expect(_shownTools(tester), _displayOrder(_wireTools()));
      },
    );
  });

  // ----------------------------------------------------------------- hosted

  group('hosted', () {
    testWidgets('the fixture response renders the same list as the local one', (
      tester,
    ) async {
      final (h, server) = await _pumpHosted(tester);
      expect(_shownGroups(tester), [for (final (id, _) in _groups) id]);
      expect(_shownTools(tester), _displayOrder(_wireTools()));
      expect(_named(tester, 'prompt-row-'), [
        for (final p in _wirePrompts()) p['name'],
      ]);
      expect(find.text('WRITES'), findsNWidgets(24));
      expect(_serverReads(server), 1);
      expect(h.cli.calls, isEmpty);
      expect(h.read(toolsTabBadgeProvider), '37 tools');
    });

    testWidgets(
      'a hosted vault reads once per open and tab switches do not read again',
      (tester) async {
        final (h, server) = await _pumpHosted(tester, showTools: false);
        expect(_serverReads(server), 1);
        await _showTools(tester, h);
        await tester.tap(_key('agents-tab-connect'));
        await h.settle();
        await _showTools(tester, h);
        expect(_serverReads(server), 1);
      },
    );

    testWidgets(
      'compat tools_not_found shows the vault server unavailable copy and no error',
      (tester) async {
        final (h, server) = await _pumpHosted(tester, domains: ['compat']);
        expect(find.text(_serverTooOldText), findsOneWidget);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(_shownTools(tester), isEmpty);
        expect(find.text(_tooOldText), findsNothing);
        expect(_serverReads(server), 1);
        expect(h.read(toolsTabBadgeProvider), isNull);
        final heading = _styleOf(tester, find.text(_serverTooOldText));
        expect(heading.fontSize, 14);
        expect(heading.fontWeight, FontWeight.w600);
        expect(heading.color, OmColors.fg0);
      },
    );

    testWidgets(
      'vault_not_found shows an InlineError with the server message and Retry',
      (tester) async {
        final (h, _) = await _pumpHosted(tester, vault: 'nope');
        final message = _errorMessage('$_toolsDir/vault_not_found.json');
        expect(message, 'no vault named nope');
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
        expect(find.text(message), findsOneWidget);
        expect(find.byKey(const Key('inline-error-retry')), findsOneWidget);
        expect(find.text(_serverTooOldText), findsNothing);
        expect(h.read(toolsTabBadgeProvider), isNull);
      },
    );

    testWidgets(
      'unauthorized shows an InlineError with the server message and Retry',
      (tester) async {
        final (h, _) = await _pumpHosted(
          tester,
          prepare: (s) => s.token = 'rotated-token',
        );
        final message = _errorMessage('$_toolsDir/unauthorized.json');
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
        expect(find.text(message), findsOneWidget);
        expect(find.byKey(const Key('inline-error-retry')), findsOneWidget);
        expect(find.text(_serverTooOldText), findsNothing);
        expect(h.read(toolsTabBadgeProvider), isNull);
      },
    );

    testWidgets('an unreachable server shows an InlineError with Retry', (
      tester,
    ) async {
      final (h, _) = await _pumpHosted(
        tester,
        prepare: (s) => s.failure = FakeServerFailure.refused,
      );
      expect(find.byKey(const Key('inline-error')), findsOneWidget);
      expect(find.byKey(const Key('inline-error-retry')), findsOneWidget);
      expect(h.read(toolsTabBadgeProvider), isNull);
    });

    testWidgets(
      'Retry on a hosted error reads the server again once and shows the list when it answers',
      (tester) async {
        final (h, server) = await _pumpHosted(
          tester,
          prepare: (s) => s.token = 'rotated-token',
        );
        expect(_serverReads(server), 1);
        server.token = fakeServerToken;
        await tester.tap(_key('inline-error-retry'));
        await h.settle();
        expect(_serverReads(server), 2);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(_shownTools(tester), _displayOrder(_wireTools()));
      },
    );
  });

  // ------------------------------------------------------- binary and age

  group('local states', () {
    testWidgets(
      'no binary shows memex not found with Locate memex and no list',
      (tester) async {
        final h = await _pump(
          tester,
          overrides: [memexCliProvider.overrideWithValue(null)],
        );
        expect(find.text('memex not found'), findsOneWidget);
        expect(find.text('Locate memex…'), findsOneWidget);
        expect(_key('tools-locate-memex'), findsOneWidget);
        expect(
          _w<OmButton>(tester, _key('tools-locate-memex')).label,
          'Locate memex…',
        );
        expect(_shownTools(tester), isEmpty);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(h.read(toolsTabBadgeProvider), isNull);
        final heading = _styleOf(tester, find.text('memex not found'));
        expect(heading.fontSize, 14);
        expect(heading.fontWeight, FontWeight.w600);
        expect(heading.color, OmColors.fg0);
      },
    );

    testWidgets(
      'Locate memex opens the file picker and a picked binary is stored',
      (tester) async {
        final picker = installFakeFilePicker();
        final picked = Platform.resolvedExecutable;
        picker.files.add(picked);
        final h = await _pump(
          tester,
          overrides: [memexCliProvider.overrideWithValue(null)],
        );
        await tester.tap(_key('tools-locate-memex'));
        await h.settle();
        expect(picker.calls.map((c) => c.method), ['pickFiles']);
        expect(h.read(settingsProvider).memexBinaryPath, picked);
      },
    );

    testWidgets(
      'a binary that cannot start is the same memex not found state',
      (tester) async {
        final cli = FakeMemexCli()
          ..on(
            'tools',
            (_) => throw const ProcessException('memex', ['tools']),
          );
        final h = await _pump(tester, cli: cli);
        expect(find.text('memex not found'), findsOneWidget);
        expect(find.text('Locate memex…'), findsOneWidget);
        expect(h.read(toolsTabBadgeProvider), isNull);
      },
    );

    testWidgets('exit 2 shows the memex is older than the app and no error', (
      tester,
    ) async {
      final cli = FakeMemexCli()
        ..on(
          'tools',
          (_) => FakeMemexCli.failure(
            "error: unrecognized subcommand 'tools'",
            exitCode: 2,
          ),
        );
      final h = await _pump(tester, cli: cli);
      expect(find.text(_tooOldText), findsOneWidget);
      expect(find.byKey(const Key('inline-error')), findsNothing);
      expect(find.text('memex not found'), findsNothing);
      expect(find.text(_serverTooOldText), findsNothing);
      expect(_shownTools(tester), isEmpty);
      expect(h.read(toolsTabBadgeProvider), isNull);
      final heading = _styleOf(tester, find.text(_tooOldText));
      expect(heading.fontSize, 14);
      expect(heading.fontWeight, FontWeight.w600);
      expect(heading.color, OmColors.fg0);
    });

    testWidgets(
      'a failed run shows an InlineError with the CLI message and Retry',
      (tester) async {
        final cli = FakeMemexCli()
          ..on(
            'tools',
            (_) => FakeMemexCli.error('internal', 'tool x has no row'),
          );
        final h = await _pump(tester, cli: cli);
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
        expect(find.text('tool x has no row'), findsOneWidget);
        expect(find.byKey(const Key('inline-error-retry')), findsOneWidget);
        expect(find.text(_tooOldText), findsNothing);
        expect(h.read(toolsTabBadgeProvider), isNull);
      },
    );
  });

  // ------------------------------------------------------------------ retry

  group('retry', () {
    testWidgets('Retry reads again once and shows the list when it answers', (
      tester,
    ) async {
      var fail = true;
      final cli = FakeMemexCli()
        ..on(
          'tools',
          (_) => fail
              ? FakeMemexCli.error('internal', 'boom')
              : FakeMemexCli.ok(_raw()),
        );
      final h = await _pump(tester, cli: cli);
      expect(cli.callsFor('tools'), hasLength(1));
      expect(find.text('boom'), findsOneWidget);
      fail = false;
      await tester.tap(_key('inline-error-retry'));
      await h.settle();
      expect(cli.callsFor('tools'), hasLength(2));
      expect(find.byKey(const Key('inline-error')), findsNothing);
      expect(_shownTools(tester), _displayOrder(_wireTools()));
      expect(h.read(toolsTabBadgeProvider), '37 tools');
    });

    testWidgets('a retry that fails again shows the new message', (
      tester,
    ) async {
      var n = 0;
      final cli = FakeMemexCli()
        ..on('tools', (_) => FakeMemexCli.error('internal', 'boom ${++n}'));
      final h = await _pump(tester, cli: cli);
      expect(find.text('boom 1'), findsOneWidget);
      await tester.tap(_key('inline-error-retry'));
      await h.settle();
      expect(find.text('boom 2'), findsOneWidget);
      expect(find.text('boom 1'), findsNothing);
      expect(cli.callsFor('tools'), hasLength(2));
    });

    testWidgets('two Retry presses in one frame run one read', (tester) async {
      var held = false;
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final cli = FakeMemexCli()
        ..on('tools', (_) async {
          if (!held) return FakeMemexCli.error('internal', 'boom');
          await gate.future;
          return FakeMemexCli.ok(_raw());
        });
      final h = await _pump(tester, cli: cli);
      expect(cli.callsFor('tools'), hasLength(1));
      held = true;
      await tester.tap(_key('inline-error-retry'));
      await tester.tap(_key('inline-error-retry'));
      await h.settle();
      expect(cli.callsFor('tools'), hasLength(2));
      // While it is held the tab is loading, and no second read starts.
      expect(find.byType(AgentsTabLoading), findsOneWidget);
      expect(find.byKey(const Key('inline-error')), findsNothing);
      gate.complete();
      await h.settle();
      expect(cli.callsFor('tools'), hasLength(2));
      expect(_shownTools(tester), _displayOrder(_wireTools()));
    });

    testWidgets('at most one request is in flight on a hosted vault too', (
      tester,
    ) async {
      final (h, server) = await _pumpHosted(
        tester,
        prepare: (s) => s.token = 'rotated-token',
      );
      expect(_serverReads(server), 1);
      server
        ..token = fakeServerToken
        ..hold();
      await tester.tap(_key('inline-error-retry'));
      await tester.tap(_key('inline-error-retry'));
      await h.settle();
      expect(_serverReads(server), 2);
      server.release();
      await h.settle();
      expect(_serverReads(server), 2);
      expect(_shownTools(tester), _displayOrder(_wireTools()));
    });
  });

  // ------------------------------------------------------------------ badge

  group('badge', () {
    testWidgets('is n tools after the load and null while loading', (
      tester,
    ) async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final cli = FakeMemexCli()
        ..on('tools', (_) async {
          await gate.future;
          return FakeMemexCli.ok(_raw());
        });
      final h = await _pump(tester, cli: cli, showTools: false);
      expect(h.read(toolsTabBadgeProvider), isNull);
      expect(_chipText(tester), 'Tools');
      gate.complete();
      await h.settle();
      expect(h.read(toolsTabBadgeProvider), '37 tools');
      expect(_chipText(tester), 'Tools 37 tools');
    });

    testWidgets('counts tools and not prompts', (tester) async {
      final cli = _cliWith(
        _catalog(
          [_tool('a', 'notes'), _tool('b', 'canvas', writes: true)],
          [
            {'name': 'p1', 'summary': 's'},
            {'name': 'p2', 'summary': 's'},
            {'name': 'p3', 'summary': 's'},
          ],
        ),
      );
      final h = await _pump(tester, cli: cli, showTools: false);
      expect(h.read(toolsTabBadgeProvider), '2 tools');
    });

    testWidgets('is null when the memex is too old', (tester) async {
      final old = FakeMemexCli()
        ..on('tools', (_) => FakeMemexCli.failure('usage', exitCode: 2));
      final h = await _pump(tester, cli: old, showTools: false);
      expect(h.read(toolsTabProvider).value, isA<ToolCatalogTooOld>());
      expect(h.read(toolsTabBadgeProvider), isNull);
      expect(_chipText(tester), 'Tools');
    });

    testWidgets('is null when the read errored', (tester) async {
      final err = FakeMemexCli()
        ..on('tools', (_) => FakeMemexCli.error('internal', 'boom'));
      final h = await _pump(tester, cli: err, showTools: false);
      expect(h.read(toolsTabProvider).value, isA<ToolCatalogError>());
      expect(h.read(toolsTabBadgeProvider), isNull);
      expect(_chipText(tester), 'Tools');
    });

    testWidgets('is null when no memex binary is configured', (tester) async {
      final h = await _pump(
        tester,
        showTools: false,
        overrides: [memexCliProvider.overrideWithValue(null)],
      );
      expect(h.read(toolsTabProvider).value, isA<ToolCatalogBinaryNotFound>());
      expect(h.read(toolsTabBadgeProvider), isNull);
      expect(_chipText(tester), 'Tools');
    });
  });

  // ----------------------------------------------------------------- layout

  group('layout', () {
    const wide = <double>[1000, 752, 700, 672];
    for (final width in wide) {
      testWidgets(
        'a ${width.toInt()} px window lays a row out as a grid with a 186 px name column and 12 px gap',
        (tester) async {
          await _pump(tester, size: Size(width, 900));
          for (final name in ['search', 'add_link']) {
            final n = _rect(tester, _key('tool-name-$name'));
            final s = _rect(tester, _key('tool-summary-$name'));
            expect(s.left - n.left, 186 + 12, reason: name);
            expect(s.top, closeTo(n.top, 1), reason: name);
          }
          final row = _rect(tester, _key('tool-row-add_link'));
          final tag = _rect(tester, _inRow('add_link', find.text('WRITES')));
          final deco = _rect(
            tester,
            find
                .ancestor(
                  of: _inRow('add_link', find.text('WRITES')),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          );
          expect(tag.width, greaterThan(0));
          expect(deco.right, closeTo(row.right, 0.5));
          expect(
            _rect(tester, _key('tool-summary-add_link')).right,
            lessThanOrEqualTo(deco.left + 0.5),
          );
          // Prompt rows use the same grid with an empty third column.
          final p = (_wirePrompts().first['name']! as String);
          expect(
            _rect(tester, _key('prompt-summary-$p')).left -
                _rect(tester, _key('prompt-name-$p')).left,
            198,
          );
        },
      );
    }

    for (final width in <double>[671, 640, 480]) {
      testWidgets(
        'a ${width.toInt()} px window stacks the name above the summary with WRITES after the name',
        (tester) async {
          await _pump(tester, size: Size(width, 900));
          final n = _rect(tester, _key('tool-name-add_link'));
          final s = _rect(tester, _key('tool-summary-add_link'));
          final tagText = _inRow('add_link', find.text('WRITES'));
          final tag = _rect(
            tester,
            find
                .ancestor(of: tagText, matching: find.byType(DecoratedBox))
                .first,
          );
          expect(s.left, closeTo(n.left, 0.5));
          expect(s.top, greaterThanOrEqualTo(n.bottom - 0.5));
          expect(s.top - n.bottom, closeTo(2, 0.5));
          expect(tag.left, closeTo(n.right + 8, 1));
          expect(tag.bottom, lessThanOrEqualTo(s.top + 0.5));
          expect(tag.top, lessThan(s.top));
          // A read tool stacks the same way, without a tag.
          final rn = _rect(tester, _key('tool-name-search'));
          final rs = _rect(tester, _key('tool-summary-search'));
          expect(rs.left, closeTo(rn.left, 0.5));
          expect(rs.top, greaterThanOrEqualTo(rn.bottom - 0.5));
          // So do prompt rows.
          final p = (_wirePrompts().first['name']! as String);
          final pn = _rect(tester, _key('prompt-name-$p'));
          final ps = _rect(tester, _key('prompt-summary-$p'));
          expect(ps.left, closeTo(pn.left, 0.5));
          expect(ps.top, greaterThanOrEqualTo(pn.bottom - 0.5));
          expect(tester.takeException(), isNull);
        },
      );
    }

    final scales = <(String, double, double)>[
      ('1.5x text at 720 px', 720, 1.5),
      ('1.5x text at 640 px', 640, 1.5),
      ('1.0x text at 480 px', 480, 1.0),
      ('1.5x text at 480 px', 480, 1.5),
    ];
    for (final (label, width, scale) in scales) {
      testWidgets(
        '$label does not overflow with every tool and the filter shown',
        (tester) async {
          await _pump(tester, size: Size(width, 800), textScale: scale);
          expect(_shownTools(tester), _displayOrder(_wireTools()));
          expect(tester.takeException(), isNull);
          await tester.enterText(_key('tools-filter'), 'tag');
          await tester.pump();
          expect(tester.takeException(), isNull);
          // The rows stay inside the sheet's body.
          final sheet = _rect(tester, agentsSheetFinder);
          for (final name in _shownTools(tester)) {
            final r = _rect(tester, _key('tool-row-$name'));
            expect(r.left, greaterThanOrEqualTo(sheet.left), reason: name);
            expect(r.right, lessThanOrEqualTo(sheet.right), reason: name);
          }
        },
      );
    }

    testWidgets(
      'the states and an error also fit a 480 px window at 1.5x text',
      (tester) async {
        final cli = FakeMemexCli()
          ..on('tools', (_) => FakeMemexCli.error('internal', 'boom ' * 20));
        await _pump(
          tester,
          cli: cli,
          size: const Size(480, 800),
          textScale: 1.5,
        );
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  // ------------------------------------------- verify pins (412 contracts)

  group('no match and prompts', () {
    Future<void> type(WidgetTester tester, String q) async {
      await tester.enterText(_key('tools-filter'), q);
      await tester.pump();
    }

    List<String> promptNames() => [
      for (final p in _wirePrompts()) p['name']! as String,
    ];

    testWidgets(
      'a filter that matches no tool shows one No tools match line and keeps the Prompts and the intro',
      (tester) async {
        await _pump(tester);
        expect(_key('tools-filter-empty'), findsNothing);
        await type(tester, 'zzz-no-such-tool');
        expect(_shownTools(tester), isEmpty);
        expect(_key('tools-filter-empty'), findsOneWidget);
        expect(
          _w<Text>(tester, _key('tools-filter-empty')).data,
          'No tools match this filter.',
        );
        final style = _styleOf(tester, _key('tools-filter-empty'));
        expect(style.fontSize, 12.5);
        expect(style.color, OmColors.fg2);
        // The Prompts section is not filtered, and the intro stays.
        expect(_key('tools-prompts-label'), findsOneWidget);
        expect(_named(tester, 'prompt-row-'), promptNames());
        expect(_key('tools-intro'), findsOneWidget);
        // The line sits below the Prompts.
        expect(
          _rect(tester, _key('tools-filter-empty')).top,
          greaterThanOrEqualTo(
            _rect(tester, _key('prompt-row-${promptNames().last}')).bottom,
          ),
        );
        // It goes when the query matches again, or is cleared.
        await type(tester, 'tag');
        expect(_key('tools-filter-empty'), findsNothing);
        await type(tester, '');
        expect(_key('tools-filter-empty'), findsNothing);
      },
    );

    testWidgets('a filter that matches a tool never shows the No tools line', (
      tester,
    ) async {
      await _pump(tester);
      await type(tester, 'tag');
      expect(_shownTools(tester), isNotEmpty);
      expect(_key('tools-filter-empty'), findsNothing);
      // The Prompts stay whatever the filter matches.
      expect(_named(tester, 'prompt-row-'), promptNames());
      await type(tester, '   ');
      expect(_shownTools(tester), _displayOrder(_wireTools()));
      expect(_key('tools-filter-empty'), findsNothing);
    });

    testWidgets(
      'a binary that lists no tools shows no No tools line and no group',
      (tester) async {
        await _pump(tester, cli: _cliWith(_catalog(const [])));
        expect(_key('tools-intro'), findsOneWidget);
        expect(_shownTools(tester), isEmpty);
        expect(_shownGroups(tester), isEmpty);
        expect(_key('tools-filter-empty'), findsNothing);
        expect(_key('tools-prompts-label'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the Prompts section is left out when the binary lists no prompts',
      (tester) async {
        await _pump(tester, cli: _cliWith(_catalog([_tool('only', 'notes')])));
        expect(_key('tools-prompts-label'), findsNothing);
        expect(_named(tester, 'prompt-row-'), isEmpty);
        expect(_shownTools(tester), ['only']);
        expect(find.text(_promptsLabel), findsNothing);
      },
    );
  });

  group('error and unavailable states', () {
    testWidgets(
      'dismissing an error hides it and leaves no list and no Retry',
      (tester) async {
        final cli = FakeMemexCli()
          ..on('tools', (_) => FakeMemexCli.error('internal', 'boom'));
        final h = await _pump(tester, cli: cli);
        expect(find.text('boom'), findsOneWidget);
        await tester.tap(_key('inline-error-dismiss'));
        await h.settle();
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(find.byKey(const Key('inline-error-retry')), findsNothing);
        expect(find.text('boom'), findsNothing);
        expect(_shownTools(tester), isEmpty);
        expect(find.byType(AgentsTabLoading), findsNothing);
        expect(cli.callsFor('tools'), hasLength(1));
        expect(h.read(toolsTabBadgeProvider), isNull);
      },
    );

    testWidgets(
      'a read that throws shows its text in an InlineError with Retry',
      (tester) async {
        final cli = FakeMemexCli()
          ..on('tools', (_) => throw StateError('disk gone'));
        final h = await _pump(tester, cli: cli);
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
        expect(find.textContaining('disk gone'), findsOneWidget);
        expect(find.byKey(const Key('inline-error-retry')), findsOneWidget);
        expect(h.read(toolsTabBadgeProvider), isNull);
      },
    );

    testWidgets(
      'an unreachable server says it could not be reached and to try again',
      (tester) async {
        await _pumpHosted(
          tester,
          prepare: (s) => s.failure = FakeServerFailure.refused,
        );
        expect(
          find.descendant(
            of: _key('inline-error'),
            matching: find.text(
              "Couldn't reach ${agentsSheetServer.name}. Try again.",
            ),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('too old gives no Locate button and no Retry', (tester) async {
      final cli = FakeMemexCli()
        ..on('tools', (_) => FakeMemexCli.failure('usage', exitCode: 2));
      await _pump(tester, cli: cli);
      expect(find.text(_tooOldText), findsOneWidget);
      expect(_key('tools-locate-memex'), findsNothing);
      expect(find.byKey(const Key('inline-error-retry')), findsNothing);
    });

    testWidgets(
      'a hosted vault with no session is an error that reads again once the session is there',
      (tester) async {
        final server = FakeVaultServer()..serveDomain('tools');
        final hostedVault = HostedVaultRef(fakeServerId, seedVaultName);
        final h = await pumpAgentsSheet(
          tester,
          vault: hostedVault,
          open: false,
        );
        await h.open();
        await _showTools(tester, h);
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
        expect(
          find.text('The vault server is not connected. Try again.'),
          findsOneWidget,
        );
        expect(_serverReads(server), 0);
        h.container.read(hostedSessionProvider.notifier).state = HostedSession(
          hostedVault,
          server.connect(h.container, accessToken: fakeServerToken),
        );
        await h.settle();
        expect(_serverReads(server), 1);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(_shownTools(tester), _displayOrder(_wireTools()));
      },
    );
  });

  group('rebuilds and busy guards', () {
    testWidgets('a located binary reads the list again', (tester) async {
      final cli = _cliWith(_raw());
      final h = await _pump(tester, cli: cli);
      expect(cli.callsFor('tools'), hasLength(1));
      await h.container
          .read(settingsProvider.notifier)
          .setMemexBinary(Platform.resolvedExecutable);
      await h.settle();
      expect(cli.callsFor('tools'), hasLength(2));
      expect(_shownTools(tester), _displayOrder(_wireTools()));
    });

    testWidgets(
      'a switched vault reads the tool list again from the new vault',
      (tester) async {
        final cli = _cliWith(_raw());
        // The shell closes the sheet when the vault changes, so this pins
        // the read itself: held by a listener (no sheet is opened), it
        // follows the open vault and the vault's session.
        final h = await pumpAgentsSheet(tester, cli: cli, open: false);
        final sub = h.container.listen(toolsTabProvider, (_, _) {});
        addTearDown(sub.close);
        await h.settle();
        expect(cli.callsFor('tools'), hasLength(1));
        expect(h.read(toolsTabBadgeProvider), '37 tools');

        final server = FakeVaultServer()..serveDomain('tools');
        final hosted = HostedVaultRef(fakeServerId, seedVaultName);

        // A hosted vault with no session yet: the memex binary is not asked,
        // the previous vault's list is gone and the tab says not connected.
        h.container.read(currentVaultProvider.notifier).state = hosted;
        await h.settle();
        expect(cli.callsFor('tools'), hasLength(1));
        expect(_serverReads(server), 0);
        final unconnected = h.read(toolsTabProvider).valueOrNull;
        expect(unconnected, isA<ToolCatalogError>());
        expect(
          (unconnected! as ToolCatalogError).message,
          'The vault server is not connected. Try again.',
        );
        expect(h.read(toolsTabBadgeProvider), isNull);

        // The session for that vault arrives: the server is read, once.
        h.container.read(hostedSessionProvider.notifier).state = HostedSession(
          hosted,
          server.connect(h.container, accessToken: fakeServerToken),
        );
        await h.settle();
        expect(_serverReads(server), 1);
        expect(cli.callsFor('tools'), hasLength(1));
        expect(h.read(toolsTabProvider).valueOrNull, isA<ToolCatalogOk>());
        expect(h.read(toolsTabBadgeProvider), '37 tools');

        // Back to a local vault: the memex binary is read again, the server
        // is not.
        h.container.read(currentVaultProvider.notifier).state =
            agentsSheetLocalVault;
        await h.settle();
        expect(cli.callsFor('tools'), hasLength(2));
        expect(_serverReads(server), 1);
        expect(h.read(toolsTabProvider).valueOrNull, isA<ToolCatalogOk>());
        expect(h.read(toolsTabBadgeProvider), '37 tools');
      },
    );

    testWidgets(
      'Locate memex on the path already configured reads the list again',
      (tester) async {
        final picker = installFakeFilePicker();
        final path = Platform.resolvedExecutable;
        var missing = true;
        final cli = FakeMemexCli()
          ..on('tools', (_) {
            if (missing) throw const ProcessException('memex', ['tools']);
            return FakeMemexCli.ok(_raw());
          });
        final h = await _pump(tester, cli: cli);
        await h.container.read(settingsProvider.notifier).setMemexBinary(path);
        await h.settle();
        expect(cli.callsFor('tools'), hasLength(2));
        expect(find.text('memex not found'), findsOneWidget);

        // The binary is back at the same path and the person locates it.
        missing = false;
        picker.files.add(path);
        await tester.tap(_key('tools-locate-memex'));
        await h.settle();
        expect(picker.calls.map((c) => c.method), ['pickFiles']);
        expect(h.read(settingsProvider).memexBinaryPath, path);
        expect(cli.callsFor('tools'), hasLength(3));
        expect(find.text('memex not found'), findsNothing);
        expect(_shownTools(tester), _displayOrder(_wireTools()));
        expect(h.read(toolsTabBadgeProvider), '37 tools');
      },
    );

    testWidgets('Locate memex on a new path reads the list once, not twice', (
      tester,
    ) async {
      final picker = installFakeFilePicker();
      picker.files.add(Platform.resolvedExecutable);
      var missing = true;
      final cli = FakeMemexCli()
        ..on('tools', (_) {
          if (missing) throw const ProcessException('memex', ['tools']);
          return FakeMemexCli.ok(_raw());
        });
      final h = await _pump(tester, cli: cli);
      expect(cli.callsFor('tools'), hasLength(1));
      missing = false;
      await tester.tap(_key('tools-locate-memex'));
      await h.settle();
      expect(
        h.read(settingsProvider).memexBinaryPath,
        Platform.resolvedExecutable,
      );
      expect(cli.callsFor('tools'), hasLength(2));
      expect(_shownTools(tester), _displayOrder(_wireTools()));
    });

    testWidgets('a Retry after the read was rebuilt still shows its answer', (
      tester,
    ) async {
      var fail = true;
      final cli = FakeMemexCli()
        ..on(
          'tools',
          (_) => fail
              ? FakeMemexCli.error('internal', 'boom')
              : FakeMemexCli.ok(_raw()),
        );
      final h = await _pump(tester, cli: cli);
      await h.container
          .read(settingsProvider.notifier)
          .setMemexBinary(Platform.resolvedExecutable);
      await h.settle();
      expect(cli.callsFor('tools'), hasLength(2));
      expect(find.text('boom'), findsOneWidget);
      fail = false;
      await tester.tap(_key('inline-error-retry'));
      await h.settle();
      expect(cli.callsFor('tools'), hasLength(3));
      expect(_shownTools(tester), _displayOrder(_wireTools()));
    });

    testWidgets(
      'a Retry answer that arrives after the read was rebuilt is dropped',
      (tester) async {
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        var calls = 0;
        final cli = FakeMemexCli()
          ..on('tools', (_) async {
            final n = ++calls;
            if (n == 1) return FakeMemexCli.error('internal', 'boom');
            if (n == 2) {
              await gate.future;
              return FakeMemexCli.error('internal', 'stale answer');
            }
            return FakeMemexCli.ok(_raw());
          });
        final h = await _pump(tester, cli: cli);
        expect(find.text('boom'), findsOneWidget);
        await tester.tap(_key('inline-error-retry'));
        await h.settle();
        expect(calls, 2);
        // The inputs change while the retry is in flight: the rebuilt read
        // answers with the list.
        await h.container
            .read(settingsProvider.notifier)
            .setMemexBinary(Platform.resolvedExecutable);
        await h.settle();
        expect(calls, 3);
        expect(_shownTools(tester), _displayOrder(_wireTools()));
        gate.complete();
        await h.settle();
        expect(find.text('stale answer'), findsNothing);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(_shownTools(tester), _displayOrder(_wireTools()));
        expect(h.read(toolsTabBadgeProvider), '37 tools');
      },
    );

    testWidgets(
      'a Retry answer that arrives after the sheet closed throws nothing',
      (tester) async {
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        var calls = 0;
        final cli = FakeMemexCli()
          ..on('tools', (_) async {
            if (++calls == 1) return FakeMemexCli.error('internal', 'boom');
            await gate.future;
            return FakeMemexCli.ok(_raw());
          });
        final h = await _pump(tester, cli: cli);
        await tester.tap(_key('inline-error-retry'));
        await h.settle();
        expect(calls, 2);
        await tester.tap(_key('agents-sheet-close'));
        await h.settle();
        await h.settle();
        expect(agentsSheetFinder, findsNothing);
        gate.complete();
        await h.settle();
        expect(tester.takeException(), isNull);
        expect(calls, 2);
      },
    );

    testWidgets('two Locate memex presses in one frame open one file picker', (
      tester,
    ) async {
      final picker = _Gated412Picker();
      FilePicker.platform = picker;
      addTearDown(() {
        if (!picker.gate.isCompleted) picker.gate.complete();
      });
      final h = await _pump(
        tester,
        overrides: [memexCliProvider.overrideWithValue(null)],
      );
      await tester.tap(_key('tools-locate-memex'));
      await tester.tap(_key('tools-locate-memex'));
      await h.settle();
      expect(picker.calls.map((c) => c.method), ['pickFiles']);
      picker.gate.complete();
      await h.settle();
      // Once it answered, a later press opens the picker again.
      await tester.tap(_key('tools-locate-memex'));
      await h.settle();
      expect(picker.calls.map((c) => c.method), ['pickFiles', 'pickFiles']);
    });

    testWidgets('the filter field adds no focus stop of its own', (
      tester,
    ) async {
      await _pump(tester);
      final wrapper = Focus.of(tester.element(_key('tools-filter')));
      expect(wrapper.canRequestFocus, isFalse);
      expect(wrapper.skipTraversal, isTrue);
      expect(wrapper.hasFocus, isFalse);
    });
  });
}

// ------------------------------------------------------------------ helpers

/// 412: a picker that holds its answer until [gate] completes.
class _Gated412Picker extends FakeFilePicker {
  final gate = Completer<void>();

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    final r = await super.pickFiles(dialogTitle: dialogTitle);
    await gate.future;
    return r;
  }
}

/// The text of the Tools tab chip (label and badge).
String _chipText(WidgetTester tester) {
  final parts = [
    for (final e
        in find
            .descendant(
              of: _key('agents-tab-tools'),
              matching: find.byType(RichText),
            )
            .evaluate())
      (e.widget as RichText).text.toPlainText().trim(),
  ].where((t) => t.isNotEmpty);
  return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ');
}

/// The row holding the text keyed [textKey] draws a 1 px line1 bottom border.
void _expectBottomBorder(WidgetTester tester, String textKey) {
  final boxes = find.ancestor(
    of: _key(textKey),
    matching: find.byWidgetPredicate((w) {
      if (w is! DecoratedBox) return false;
      final d = w.decoration;
      if (d is! BoxDecoration || d.border is! Border) return false;
      final b = (d.border! as Border).bottom;
      return b.color == OmColors.line1 && b.width == 1;
    }),
  );
  expect(boxes, findsAtLeastNWidgets(1), reason: textKey);
}
