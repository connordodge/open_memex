// WI #411 (Spec #394 req 15, 22-24, 28, 30, 46, 47; design pack
// design/394-agents-sheet/packs/411.md, RULINGS #15-#17): the Connect tab on
// a local vault. The client switch and its per-vault memory, Claude Desktop's
// three steps, the Claude Code line, the recall switch, the memex binary
// states (none, unstable, bundled), code blocks and narrow and large-text
// layouts. Snippet strings come from #404's builders, never rebuilt here.
//
// flutter_test draws every glyph one em wide (holdFontFetches keeps the
// fallback font), so the layout tests are stricter than the real fonts.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/connect/snippets.dart';
import 'package:open_memex_app/src/state/agents_sheet/connect_tab_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';

import '../../support/connect_tab_rig.dart';
import '../../support/file_picker_fakes.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/token_store_fakes.dart';

const _intro =
    'Give an MCP client this vault. The snippets already hold this vault’s '
    'path and the memex this app runs.';
const _bundledIntro =
    'Give an MCP client this vault. The snippets already hold this vault’s '
    'path and the memex that ships inside Open Memex.';
const _bundledPath = '/Applications/Open Memex.app/Contents/MacOS/memex';
const _translocatedPath =
    '/private/var/folders/x1/abc/T/AppTranslocation/9F2C-41D0/d/'
    'Open Memex.app/Contents/MacOS/memex';
const _volumesPath = '/Volumes/Open Memex/Open Memex.app/Contents/MacOS/memex';

String _desktop({String memex = connectMemexPath, bool recall = true}) =>
    localClaudeDesktopConfig(
      memexPath: memex,
      vaultPath: connectVaultPath,
      withEmbeddings: recall,
    );

String _code({String memex = connectMemexPath, bool recall = true}) =>
    localClaudeCodeCommand(
      memexPath: memex,
      vaultPath: connectVaultPath,
      withEmbeddings: recall,
    );

/// Laid-out lines of a code paragraph (mono 12, line height 1.6, text
/// scale 1).
int _lines(RenderParagraph paragraph) =>
    (paragraph.size.height / (12 * 1.6)).round();

double _top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

Color? _colorOf(WidgetTester tester, Finder f) {
  final rich = tester.widget<RichText>(
    find
        .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
        .first,
  );
  final runs = styledRuns(rich.text);
  return runs.isEmpty ? null : runs.first.style.color;
}

void main() {
  holdFontFetches();

  group('local Claude Desktop', () {
    testWidgets(
      'local Claude Desktop shows the intro three steps config path and snippet',
      (tester) async {
        final rig = await pumpConnect(tester);

        expect(inSheet(textShowing(_intro)), findsOneWidget);
        expect(inSheet(find.text('Claude Desktop')), findsOneWidget);
        expect(inSheet(find.text('Claude Code')), findsOneWidget);
        expect(inSheet(textShowing(connectStepOpenConfig)), findsOneWidget);
        expect(inSheet(textShowing(connectStepMerge)), findsOneWidget);
        expect(inSheet(textShowing(connectStepRestart)), findsOneWidget);
        expect(inSheet(textShowing(connectRestartNote)), findsOneWidget);
        expect(
          _top(tester, textShowing(connectStepOpenConfig)),
          lessThan(_top(tester, textShowing(connectStepMerge))),
        );
        expect(
          _top(tester, textShowing(connectStepMerge)),
          lessThan(_top(tester, textShowing(connectStepRestart))),
        );
        expect(
          codeBlockText(tester, copyConfigPathLabel),
          claudeDesktopConfigPath,
        );
        expect(codeBlockText(tester, copyDesktopConfigLabel), _desktop());
        expect(recallSwitch(), findsOne);
        // A stable path, a picked binary: no warning, not the bundled copy.
        expect(find.text(connectUnstableWarning), findsNothing);
        expect(textShowing(_bundledIntro), findsNothing);
        expect(find.text('memex wasn\'t found.'), findsNothing);
        expect(
          rig.harness.read(settingsProvider).memexBinaryPath,
          connectMemexPath,
        );
      },
    );

    testWidgets(
      'the recall switch is on by default and turning it off drops the flag from the snippet only',
      (tester) async {
        final rig = await pumpConnect(tester);
        expect(recallSwitch(), findsOne);
        expect(rig.recallOn, isTrue);
        expect(codeBlockText(tester, copyDesktopConfigLabel), _desktop());
        final pathBefore = codeBlockText(tester, copyConfigPathLabel);

        await rig.toggleRecall();

        expect(rig.recallOn, isFalse);
        expect(
          codeBlockText(tester, copyDesktopConfigLabel),
          _desktop(recall: false),
        );
        expect(
          codeBlockText(tester, copyDesktopConfigLabel),
          isNot(contains('--with-embeddings')),
        );
        // Everything else is unchanged.
        expect(codeBlockText(tester, copyConfigPathLabel), pathBefore);
        expect(inSheet(textShowing(_intro)), findsOneWidget);
        expect(inSheet(textShowing(connectStepOpenConfig)), findsOneWidget);
        expect(inSheet(textShowing(connectStepRestart)), findsOneWidget);
        expect(inSheet(textShowing(connectRestartNote)), findsOneWidget);

        await rig.toggleRecall();
        expect(codeBlockText(tester, copyDesktopConfigLabel), _desktop());
      },
    );

    testWidgets(
      'copying the local Claude Desktop config copies the snippet the switch shows',
      (tester) async {
        final rig = await pumpConnect(tester);

        await rig.copy(copyConfigPathLabel);
        expect(rig.clipboard, [claudeDesktopConfigPath]);

        await rig.copy(copyDesktopConfigLabel);
        expect(rig.clipboard.last, _desktop());

        await rig.toggleRecall();
        await rig.copy(copyDesktopConfigLabel);
        expect(rig.clipboard.last, _desktop(recall: false));
        expect(rig.sensitive, isEmpty, reason: 'no token: plain copies');
      },
    );
  });

  group('memex binary path states', () {
    test('unstable memex paths are translocated or on a mounted volume', () {
      expect(isUnstableMemexPath(_translocatedPath), isTrue);
      expect(isUnstableMemexPath(_volumesPath), isTrue);
      expect(isUnstableMemexPath('/Volumes/x/memex'), isTrue);
      expect(isUnstableMemexPath(_bundledPath), isFalse);
      expect(isUnstableMemexPath(connectMemexPath), isFalse);
      expect(isUnstableMemexPath('/opt/homebrew/bin/memex'), isFalse);
      // Only a leading /Volumes/ counts.
      expect(isUnstableMemexPath('/Users/tester/Volumes/memex'), isFalse);
      expect(isUnstableMemexPath('/Volumesx/memex'), isFalse);
    });

    test('bundled memex paths are the app bundle Contents MacOS memex', () {
      expect(isBundledMemexPath(_bundledPath), isTrue);
      expect(
        isBundledMemexPath(
          '/Users/tester/Applications/Open Memex.app/Contents/MacOS/memex',
        ),
        isTrue,
      );
      expect(isBundledMemexPath(connectMemexPath), isFalse);
      expect(isBundledMemexPath('/usr/local/bin/memex'), isFalse);
      expect(isBundledMemexPath('/opt/homebrew/bin/memex'), isFalse);
      expect(
        isBundledMemexPath('/Applications/Open Memex.app/Contents/MacOS/app'),
        isFalse,
      );
    });

    testWidgets('a bundled memex path gives the bundled intro sentence', (
      tester,
    ) async {
      await pumpConnect(tester, binaryPath: _bundledPath);

      expect(inSheet(textShowing(_bundledIntro)), findsOneWidget);
      expect(textShowing(_intro), findsNothing);
      expect(
        codeBlockText(tester, copyDesktopConfigLabel),
        _desktop(memex: _bundledPath),
      );
    });

    testWidgets(
      'with no memex binary the tab shows memex not found and Locate memex instead of the snippets',
      (tester) async {
        await pumpConnect(tester, binaryPath: null);

        expect(inSheet(find.text('memex wasn\'t found.')), findsOneWidget);
        expect(inSheet(labelIgnoringCase('Locate memex…')), findsOneWidget);
        expect(copyButton(copyDesktopConfigLabel), findsNothing);
        expect(copyButton(copyConfigPathLabel), findsNothing);
        expect(textShowing(connectStepMerge), findsNothing);
        expect(textContaining('--vault'), findsNothing);
      },
    );

    testWidgets(
      'Locate memex picks a binary and the snippets appear with its path',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('om411-memex-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final binary = File('${dir.path}/memex')..createSync();
        final picker = installFakeFilePicker()..files.add(binary.path);
        final rig = await pumpConnect(tester, binaryPath: null);

        await rig.tap(inSheet(labelIgnoringCase('Locate memex…')));
        await rig.settle();

        expect(picker.calls.map((c) => c.method), ['pickFiles']);
        expect(rig.harness.read(settingsProvider).memexBinaryPath, binary.path);
        expect(find.text('memex wasn\'t found.'), findsNothing);
        expect(
          codeBlockText(tester, copyDesktopConfigLabel),
          _desktop(memex: binary.path),
        );
      },
    );

    testWidgets(
      'a translocated memex path shows the warning above step 1 in fg1',
      (tester) async {
        final rig = await pumpConnect(tester, binaryPath: _translocatedPath);

        final warning = inSheet(find.text(connectUnstableWarning));
        expect(warning, findsOneWidget);
        expect(_colorOf(tester, warning), OmColors.fg1);
        expect(
          _top(tester, warning),
          lessThan(_top(tester, textShowing(connectStepOpenConfig))),
        );
        // The snippets still show, with that path.
        expect(
          codeBlockText(tester, copyDesktopConfigLabel),
          _desktop(memex: _translocatedPath),
        );

        await rig.chooseClient('Claude Code');
        expect(inSheet(find.text(connectUnstableWarning)), findsOneWidget);
        expect(
          _top(tester, find.text(connectUnstableWarning)),
          lessThan(_top(tester, textShowing(connectStepTerminal))),
        );
        expect(
          codeBlockText(tester, copyCodeCommandLabel),
          _code(memex: _translocatedPath),
        );
      },
    );

    testWidgets(
      'a memex path on a mounted volume shows the warning above step 1',
      (tester) async {
        await pumpConnect(tester, binaryPath: _volumesPath);

        final warning = inSheet(find.text(connectUnstableWarning));
        expect(warning, findsOneWidget);
        expect(_colorOf(tester, warning), OmColors.fg1);
        expect(
          _top(tester, warning),
          lessThan(_top(tester, textShowing(connectStepOpenConfig))),
        );
        expect(
          codeBlockText(tester, copyDesktopConfigLabel),
          _desktop(memex: _volumesPath),
        );
      },
    );
  });

  group('local Claude Code', () {
    testWidgets(
      'local Claude Code shows the claude mcp add line with single quoted values',
      (tester) async {
        final rig = await pumpConnect(tester);
        await rig.chooseClient('Claude Code');

        expect(inSheet(textShowing(connectStepTerminal)), findsOneWidget);
        final line = codeBlockText(tester, copyCodeCommandLabel);
        expect(line, _code());
        expect(line, contains("-- '$connectMemexPath' serve"));
        expect(line, contains("--vault '$connectVaultPath'"));
        expect(recallSwitch(), findsOne);
        // The Desktop pane is gone.
        expect(copyButton(copyDesktopConfigLabel), findsNothing);
        expect(textShowing(connectStepOpenConfig), findsNothing);

        await rig.copy(copyCodeCommandLabel);
        expect(rig.clipboard, [_code()]);
      },
    );

    testWidgets('the Claude Code line follows the recall switch', (
      tester,
    ) async {
      final rig = await pumpConnect(tester);
      await rig.chooseClient('Claude Code');
      expect(recallSwitch(), findsOne);
      expect(rig.recallOn, isTrue);
      expect(codeBlockText(tester, copyCodeCommandLabel), _code());

      await rig.toggleRecall();
      expect(codeBlockText(tester, copyCodeCommandLabel), _code(recall: false));
      await rig.copy(copyCodeCommandLabel);
      expect(rig.clipboard.last, _code(recall: false));

      await rig.toggleRecall();
      expect(codeBlockText(tester, copyCodeCommandLabel), _code());
    });
  });

  group('client choice', () {
    testWidgets(
      'the client choice survives closing and reopening the sheet for the same vault',
      (tester) async {
        final rig = await pumpConnect(tester);
        expect(textShowing(connectStepOpenConfig), findsOneWidget);

        await rig.chooseClient('Claude Code');
        expect(textShowing(connectStepTerminal), findsOneWidget);
        await rig.closeSheet();
        await rig.reopen();

        expect(inSheet(textShowing(connectStepTerminal)), findsOneWidget);
        expect(textShowing(connectStepOpenConfig), findsNothing);

        await rig.chooseClient('Claude Desktop');
        await rig.closeSheet();
        await rig.reopen();
        expect(inSheet(textShowing(connectStepOpenConfig)), findsOneWidget);
        expect(textShowing(connectStepTerminal), findsNothing);
      },
    );

    testWidgets(
      'the client choice is independent per vault and never reaches SharedPreferences',
      (tester) async {
        final rig = await pumpConnect(tester);
        final prefsBefore = await prefsEntries();

        await rig.chooseClient('Claude Code');
        await rig.closeSheet();

        rig.container.read(currentVaultProvider.notifier).state =
            const LocalVaultRef('/Users/tester/vaults/Other');
        await rig.settle();
        await rig.reopen();
        expect(
          inSheet(textShowing(connectStepOpenConfig)),
          findsOneWidget,
          reason: 'another vault starts on Claude Desktop',
        );
        await rig.closeSheet();

        rig.container.read(currentVaultProvider.notifier).state =
            agentsSheetLocalVault;
        await rig.settle();
        await rig.reopen();
        expect(
          inSheet(textShowing(connectStepTerminal)),
          findsOneWidget,
          reason: 'Studio keeps Claude Code',
        );

        expect(await prefsEntries(), prefsBefore);
      },
    );
  });

  group('code blocks', () {
    testWidgets(
      'code blocks do not wrap and scroll sideways with Copy pinned top right',
      (tester) async {
        final rig = await pumpConnect(tester);
        await rig.chooseClient('Claude Code');

        final block = codeBlock(copyCodeCommandLabel);
        final scroller = find
            .descendant(of: block, matching: find.byType(Scrollable))
            .first;
        expect(
          tester.widget<Scrollable>(scroller).axisDirection,
          AxisDirection.right,
        );
        final line = find
            .descendant(of: block, matching: textShowing(_code()))
            .first;
        final paragraph = tester.renderObject<RenderParagraph>(line);
        expect(_lines(paragraph), 1);
        expect(
          tester.getSize(line).width,
          greaterThan(tester.getSize(block).width),
          reason: 'the line is wider than the block: it scrolls',
        );

        Rect copyRect() => tester.getRect(copyButton(copyCodeCommandLabel));
        Rect blockRect() => tester.getRect(block);
        void expectPinned() {
          expect(blockRect().right - copyRect().right, inInclusiveRange(6, 7));
          expect(copyRect().top - blockRect().top, inInclusiveRange(6, 7));
        }

        expectPinned();
        final copyBefore = copyRect();
        final lineBefore = tester.getTopLeft(line).dx;

        await tester.drag(scroller, const Offset(-300, 0));
        await rig.settle();

        expect(tester.getTopLeft(line).dx, lessThan(lineBefore));
        expect(copyRect(), copyBefore, reason: 'Copy stays pinned');
        expectPinned();

        // The Claude Desktop JSON keeps its own lines, no more.
        await rig.chooseClient('Claude Desktop');
        final json = find
            .descendant(
              of: codeBlock(copyDesktopConfigLabel),
              matching: find.byType(RichText),
            )
            .evaluate()
            .map((e) => e.renderObject! as RenderParagraph)
            .where((r) => r.text.toPlainText().contains('mcpServers'))
            .single;
        expect(_lines(json), '\n'.allMatches(_desktop()).length + 1);
      },
    );

    testWidgets(
      'code blocks use the pack surface border radius and mono text colours',
      (tester) async {
        await pumpConnect(tester);

        expect(codeBlock(copyDesktopConfigLabel), findsOneWidget);
        final box = tester.widget<DecoratedBox>(
          codeBlock(copyDesktopConfigLabel),
        );
        final deco = box.decoration as BoxDecoration;
        expect(deco.color, OmColors.surface0);
        expect(deco.border, Border.all(color: OmColors.line2));
        expect(deco.borderRadius, BorderRadius.circular(6));

        final runs = codeBlockRuns(tester, copyDesktopConfigLabel);
        expect(runs, isNotEmpty);
        final mono = OmType.mono().fontFamily;
        for (final r in runs) {
          expect(r.style.fontSize, 12, reason: '"${r.text}" is 12 px');
          expect(
            r.style.height,
            1.6,
            reason: '"${r.text}" has line height 1.6',
          );
          expect(r.style.fontFamily, mono, reason: '"${r.text}" is mono');
        }
        StyledRun runWith(String part) => runs.firstWhere(
          (r) => r.text.contains(part),
          orElse: () => fail('no run contains $part'),
        );
        expect(runWith('mcpServers').style.color, OmColors.fg2, reason: 'keys');
        expect(runWith('command').style.color, OmColors.fg2, reason: 'keys');
        expect(runWith('--with-embeddings').style.color, OmColors.accent);
        expect(runWith(connectVaultPath).style.color, OmColors.fg1);
        expect(runWith(connectMemexPath).style.color, OmColors.fg1);
      },
    );
  });

  group('large text and narrow windows', () {
    testWidgets(
      'local Connect panes do not overflow at large text and narrow widths',
      (tester) async {
        const cases = <(Size, double)>[
          (Size(1000, 900), 1.5), // sheet 720
          (Size(672, 900), 1.5), // sheet 640
          (Size(480, 900), 1.0),
          (Size(480, 900), 1.5),
        ];
        for (final (size, scale) in cases) {
          for (final binary in [connectMemexPath, _translocatedPath, null]) {
            final rig = await pumpConnect(
              tester,
              size: size,
              textScale: scale,
              binaryPath: binary,
            );
            final at = '$size at ${scale}x, binary $binary';
            expect(tester.takeException(), isNull, reason: 'Desktop, $at');
            if (binary == null) {
              expect(
                find.text('memex wasn\'t found.'),
                findsOneWidget,
                reason: at,
              );
              continue;
            }
            expect(
              codeBlock(copyDesktopConfigLabel),
              findsOneWidget,
              reason: at,
            );
            await rig.chooseClient('Claude Code');
            expect(tester.takeException(), isNull, reason: 'Code, $at');
            expect(codeBlock(copyCodeCommandLabel), findsOneWidget, reason: at);
          }
        }
      },
    );
  });
}
