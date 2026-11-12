// WI #411 (Spec #394 req 13, 15, 22-30, 46; design pack
// design/394-agents-sheet/packs/411.md): the Connect tab contracts the four
// feature test files leave open. The client segments and the recall switch
// (Semantics flags, mouse hover, keyboard focus ring, Enter / Space / key
// repeats), the shell syntax accent, the `Locate memex…` busy guard, the
// detection line's dot and failure paths, and the hosted token row's
// Semantics, Keychain and offset reads.
//
// flutter_test draws every glyph one em wide (holdFontFetches keeps the
// fallback font), so sizes here are the layout's, not the real fonts'.
import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/connect/claude_config_reader.dart';
import 'package:open_memex_app/src/agents_sheet/connect/snippets.dart';
import 'package:open_memex_app/src/agents_sheet/connect/token_text.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/agents_sheet/connect_tab_state.dart';
import 'package:open_memex_app/src/state/token_store.dart';
import 'package:open_memex_app/src/theme/colors.dart';

import '../../support/connect_tab_rig.dart';
import '../../support/file_picker_fakes.dart';
import '../../support/font_fetch_hold.dart';

const _token = 'om411-contract-token-Q7zP-Wx2Lm9Rv-7f3a';
const _thrown = 'boom-secret-411-keychain';
const _unreadable = 'Couldn’t read Claude Desktop’s config file.';
const _missing = 'Claude Desktop’s config file wasn’t found.';

const _flag = '--with-embeddings';

String _desktop({bool recall = true}) => localClaudeDesktopConfig(
  memexPath: connectMemexPath,
  vaultPath: connectVaultPath,
  withEmbeddings: recall,
);

String _hostedEntry(TokenText token) => hostedClaudeDesktopEntry(
  memexPath: connectMemexPath,
  vaultName: 'studio',
  mcpAddress: connectMcpAddress,
  token: token,
);

String _hostedCode(TokenText token, [Duration offset = connectUtcOffset]) =>
    hostedClaudeCodeCommand(
      vaultName: 'studio',
      mcpAddress: connectMcpAddress,
      token: token,
      utcOffset: offset,
    );

/// A picker whose `pickFiles` waits for [release].
class _Wi411HeldPicker extends FakeFilePicker {
  final _held = <Completer<void>>[];

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
    final gate = Completer<void>();
    _held.add(gate);
    calls.add(FakeFilePickerCall('pickFiles', dialogTitle));
    await gate.future;
    return null;
  }

  void release() {
    for (final g in List.of(_held)) {
      g.complete();
    }
    _held.clear();
  }
}

/// A config reader that fails with a message that must never be shown.
class _Wi411ThrowingReader implements ClaudeConfigReader {
  int reads = 0;

  @override
  Future<ClaudeConfigRead> read() async {
    reads++;
    throw StateError(_thrown);
  }
}

/// A Keychain whose reads fail with a message that must never be shown.
class _Wi411ThrowingTokenStore implements TokenStore {
  @override
  Future<String?> read(String serverId) async => throw StateError(_thrown);

  @override
  Future<void> write(String serverId, String token) async {}

  @override
  Future<void> delete(String serverId) async {}
}

SemanticsNode _node(String label) {
  final f = find.semantics.byPredicate(
    (n) => n.getSemanticsData().label == label,
    describeMatch: (_) => 'the node labelled $label',
  );
  expect(f, findsOne, reason: 'one Semantics node labelled $label');
  return f.evaluate().single;
}

Finder _segment(String label) => inSheet(find.text(label));

/// The segment's pill: the Container with the 24 px minimum height.
Container _pill(WidgetTester tester, String label) => tester.widget<Container>(
  find
      .ancestor(
        of: _segment(label),
        matching: find.byWidgetPredicate(
          (w) => w is Container && w.constraints?.minHeight == 24,
          description: 'segment pill',
        ),
      )
      .first,
);

Color? _fill(WidgetTester tester, String label) =>
    (_pill(tester, label).decoration! as BoxDecoration).color;

FocusNode _focusOf(WidgetTester tester, Finder f) =>
    Focus.of(tester.element(f));

/// Shows the focus ring whenever something is focused (a keyboard user).
void _keyboardHighlights() {
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;
  addTearDown(
    () => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic,
  );
}

/// The recall switch's `Include semantic recall` text.
Finder _recallLabel() => inSheet(textContaining('Include semantic recall'));

/// The switch track (30 x 18) and its thumb (14 x 14).
Finder _track() => inSheet(
  find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.constraints == const BoxConstraints.tightFor(width: 30, height: 18),
    description: 'switch track',
  ),
);

Finder _thumb() => inSheet(
  find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.constraints == const BoxConstraints.tightFor(width: 14, height: 14),
    description: 'switch thumb',
  ),
);

Color? _color(Container c) => (c.decoration! as BoxDecoration).color;

Future<TestGesture> _mouse(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(1, 1));
  addTearDown(mouse.removePointer);
  return mouse;
}

void main() {
  holdFontFetches();

  group('client segments', () {
    testWidgets(
      'the client segments are exclusive button leaves with selected state',
      (tester) async {
        await pumpConnect(tester);

        final desktop = _node('Claude Desktop');
        final code = _node('Claude Code');
        expect(
          desktop,
          isSemantics(
            isButton: true,
            isFocusable: true,
            hasSelectedState: true,
            isSelected: true,
            isInMutuallyExclusiveGroup: true,
            hasTapAction: true,
          ),
        );
        expect(
          code,
          isSemantics(
            isButton: true,
            isFocusable: true,
            hasSelectedState: true,
            isSelected: false,
            isInMutuallyExclusiveGroup: true,
            hasTapAction: true,
          ),
        );
        expect(desktop.childrenCount, 0);
        expect(code.childrenCount, 0);

        tester.semantics.tap(
          find.semantics.byPredicate(
            (n) => n.getSemanticsData().label == 'Claude Code',
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          _node('Claude Code').getSemanticsData().flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(
          _node('Claude Desktop').getSemanticsData().flagsCollection.isSelected,
          Tristate.isFalse,
        );
        expect(copyButton(copyCodeCommandLabel), findsOneWidget);
      },
    );

    testWidgets('a mouse over a segment fills it and leaving clears it', (
      tester,
    ) async {
      await pumpConnect(tester);
      final mouse = await _mouse(tester);
      const clear = Color(0x00000000);
      expect(_fill(tester, 'Claude Desktop'), OmColors.surface4);
      expect(_fill(tester, 'Claude Code'), clear);

      await mouse.moveTo(tester.getCenter(_segment('Claude Code')));
      await tester.pump();
      expect(_fill(tester, 'Claude Code'), OmColors.surface3);
      expect(_fill(tester, 'Claude Desktop'), OmColors.surface4);

      await mouse.moveTo(tester.getCenter(_segment('Claude Desktop')));
      await tester.pump();
      expect(_fill(tester, 'Claude Code'), clear);
      expect(
        _fill(tester, 'Claude Desktop'),
        OmColors.surface4,
        reason: 'the selected segment keeps its fill under the mouse',
      );

      await mouse.moveTo(const Offset(1, 1));
      await tester.pump();
      expect(_fill(tester, 'Claude Code'), clear);
      expect(_fill(tester, 'Claude Desktop'), OmColors.surface4);
    });

    testWidgets('a keyboard focused segment draws the accent ring', (
      tester,
    ) async {
      _keyboardHighlights();
      await pumpConnect(tester);
      expect(_pill(tester, 'Claude Code').foregroundDecoration, isNull);

      _focusOf(tester, _segment('Claude Code')).requestFocus();
      await tester.pump();
      await tester.pump();
      final ring = _pill(tester, 'Claude Code').foregroundDecoration;
      expect(ring, isA<BoxDecoration>());
      final border = (ring! as BoxDecoration).border! as Border;
      expect(border.top.color, OmColors.accent);
      expect(border.top.width, 2);
      expect(_fill(tester, 'Claude Code'), OmColors.surface3);
      expect(
        _pill(tester, 'Claude Desktop').foregroundDecoration,
        isNull,
        reason: 'only the focused segment',
      );
      expect(
        _node('Claude Code').getSemanticsData().flagsCollection.isFocused,
        Tristate.isTrue,
      );

      _focusOf(tester, _segment('Claude Code')).unfocus();
      await tester.pump();
      await tester.pump();
      expect(_pill(tester, 'Claude Code').foregroundDecoration, isNull);
      expect(_fill(tester, 'Claude Code'), const Color(0x00000000));
    });

    testWidgets(
      'Enter numpad Enter and Space select a focused segment and repeats do not',
      (tester) async {
        final rig = await pumpConnect(tester);
        final code = _focusOf(tester, _segment('Claude Code'));
        final desktop = _focusOf(tester, _segment('Claude Desktop'));

        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.numpadEnter,
        ]) {
          desktop.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await rig.settle();
          expect(copyButton(copyCodeCommandLabel), findsNothing);
          expect(copyButton(copyDesktopConfigLabel), findsOneWidget);

          code.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(key);
          await rig.settle();
          expect(
            copyButton(copyCodeCommandLabel),
            findsOneWidget,
            reason: '$key selects Claude Code',
          );
          expect(copyButton(copyDesktopConfigLabel), findsNothing);
        }

        // A key held down: its repeats and its release choose nothing.
        desktop.requestFocus();
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await rig.settle();
        expect(copyButton(copyDesktopConfigLabel), findsOneWidget);
        code.requestFocus();
        await tester.pump();
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await rig.settle();
        expect(copyButton(copyDesktopConfigLabel), findsOneWidget);
        expect(copyButton(copyCodeCommandLabel), findsNothing);

        // Another key is not handled.
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await rig.settle();
        expect(copyButton(copyDesktopConfigLabel), findsOneWidget);
      },
    );
  });

  group('recall switch', () {
    testWidgets('the recall switch is a leaf toggle that tells its state', (
      tester,
    ) async {
      final rig = await pumpConnect(tester);
      final node = recallSwitch().evaluate().single;
      expect(
        node,
        isSemantics(
          label: 'Include semantic recall',
          hasToggledState: true,
          isToggled: true,
          isFocusable: true,
          hasTapAction: true,
        ),
      );
      expect(node.childrenCount, 0);
      expect(find.bySemanticsLabel('--with-embeddings'), findsNothing);

      await rig.toggleRecall();
      expect(
        recallSwitch().evaluate().single,
        isSemantics(hasToggledState: true, isToggled: false),
      );
    });

    testWidgets('clicking the row and Enter or Space flip the switch', (
      tester,
    ) async {
      final rig = await pumpConnect(tester);
      expect(rig.recallOn, isTrue);

      await rig.tap(_recallLabel());
      expect(rig.recallOn, isFalse);
      expect(
        inSheet(find.text('Claude Desktop')),
        findsOneWidget,
        reason: 'the client choice is untouched',
      );
      await rig.tap(_recallLabel());
      expect(rig.recallOn, isTrue);

      final focus = _focusOf(tester, _recallLabel());
      var expected = true;
      for (final key in [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.space,
      ]) {
        focus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(key);
        await rig.settle();
        expected = !expected;
        expect(rig.recallOn, expected, reason: '$key flips the switch');
        expect(
          codeBlockText(tester, copyDesktopConfigLabel),
          _desktop(recall: expected),
        );
      }

      // A repeat and a release of a held key flip nothing.
      final before = rig.recallOn;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await rig.settle();
      expect(rig.recallOn, !before);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await rig.settle();
      expect(rig.recallOn, !before, reason: 'one press, one flip');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await rig.settle();
      expect(rig.recallOn, !before);
    });

    testWidgets('the switch track and thumb show on and off', (tester) async {
      _keyboardHighlights();
      final rig = await pumpConnect(tester);
      Container track() => tester.widget<Container>(_track());
      Container thumb() => tester.widget<Container>(_thumb());
      double thumbLeft() =>
          tester.getTopLeft(_thumb()).dx - tester.getTopLeft(_track()).dx;

      expect(_color(track()), OmColors.accentDeep);
      expect(_color(thumb()), OmColors.accent);
      expect(thumbLeft(), 14);
      expect(track().foregroundDecoration, isNull);

      await rig.toggleRecall();
      expect(_color(track()), OmColors.surface5);
      expect(_color(thumb()), OmColors.fg2);
      expect(thumbLeft(), 2);

      _focusOf(tester, _recallLabel()).requestFocus();
      await tester.pump();
      await tester.pump();
      final ring = track().foregroundDecoration! as BoxDecoration;
      final border = ring.border! as Border;
      expect(border.top.color, OmColors.accent);
      expect(border.top.width, 2);
      expect(
        recallSwitch().evaluate().single.getSemanticsData().flagsCollection,
        isNotNull,
      );

      _focusOf(tester, _recallLabel()).unfocus();
      await tester.pump();
      await tester.pump();
      expect(track().foregroundDecoration, isNull);
    });
  });

  group('code block syntax', () {
    testWidgets('the Claude Code line colours only a trailing flag accent', (
      tester,
    ) async {
      final rig = await pumpConnect(tester);
      await rig.chooseClient('Claude Code');

      var runs = codeBlockRuns(tester, copyCodeCommandLabel);
      final flag = runs.where((r) => r.text.contains(_flag)).toList();
      expect(flag, hasLength(1));
      expect(flag.single.text, _flag);
      expect(flag.single.style.color, OmColors.accent);
      for (final r in runs.where((r) => !r.text.contains(_flag))) {
        expect(r.style.color, OmColors.fg1, reason: '"${r.text}"');
      }

      await rig.toggleRecall();
      runs = codeBlockRuns(tester, copyCodeCommandLabel);
      expect(runs.where((r) => r.text.contains(_flag)), isEmpty);
      for (final r in runs) {
        expect(r.style.color, OmColors.fg1, reason: '"${r.text}"');
      }
    });

    testWidgets('a plain block such as the config path is all fg1', (
      tester,
    ) async {
      await pumpConnect(tester);
      final runs = codeBlockRuns(tester, copyConfigPathLabel);
      expect(runs.map((r) => r.text).join(), claudeDesktopConfigPath);
      for (final r in runs) {
        expect(r.style.color, OmColors.fg1);
      }
    });
  });

  group('step layout', () {
    testWidgets('a step with content sits its content 6 px under its title', (
      tester,
    ) async {
      await pumpConnect(tester);
      final title = tester.getRect(textShowing(connectStepOpenConfig));
      final block = tester.getRect(codeBlock(copyConfigPathLabel));
      expect(block.top - title.bottom, 6);

      // The numbered circle is 18 px, surface4, and holds its number.
      final circle = find
          .ancestor(
            of: inSheet(find.text('1')),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Container &&
                  w.constraints ==
                      const BoxConstraints.tightFor(width: 18, height: 18),
            ),
          )
          .first;
      expect(
        (tester.widget<Container>(circle).decoration! as BoxDecoration).color,
        OmColors.surface4,
      );
    });
  });

  group('locate memex', () {
    testWidgets('two presses on Locate memex open one picker', (tester) async {
      final picker = _Wi411HeldPicker();
      FilePicker.platform = picker;
      final rig = await pumpConnect(tester, binaryPath: null);
      final locate = inSheet(labelIgnoringCase('Locate memex…'));

      await tester.tap(locate);
      await tester.pump();
      await tester.tap(locate);
      await tester.pump();
      expect(picker.calls, hasLength(1), reason: 'one picker is open');

      picker.release();
      await rig.settle();
      expect(inSheet(find.text('memex wasn\'t found.')), findsOneWidget);

      await rig.tap(locate);
      expect(picker.calls, hasLength(2), reason: 'free again once closed');
      picker.release();
      await rig.settle();
    });
  });

  group('detection details', () {
    testWidgets(
      'a config read that throws shows the fixed unreadable line only',
      (tester) async {
        final reader = _Wi411ThrowingReader();
        final rig = await pumpConnect(
          tester,
          overrides: [claudeConfigReaderProvider.overrideWithValue(reader)],
        );
        expect(reader.reads, 1);
        expect(inSheet(textShowing(_unreadable)), findsOneWidget);
        expect(textContaining(_thrown), findsNothing);
        expect(find.bySemanticsLabel(RegExp(_thrown)), findsNothing);

        await rig.tap(inSheet(find.text('Check again')));
        expect(reader.reads, 2, reason: 'a failed read can be retried');
        expect(inSheet(textShowing(_unreadable)), findsOneWidget);
      },
    );

    testWidgets('the status dot is accent when set up and fg2 otherwise', (
      tester,
    ) async {
      Finder dot() => find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.constraints == const BoxConstraints.tightFor(width: 7, height: 7),
        description: 'status dot',
      );
      Color? dotColor() => _color(tester.widget<Container>(dot()));

      final rig = await pumpConnect(tester);
      expect(inSheet(textShowing(_missing)), findsOneWidget);
      expect(dotColor(), OmColors.fg2);
      expect(
        (tester.widget<Container>(dot()).decoration! as BoxDecoration).shape,
        BoxShape.circle,
      );

      rig.reader!.result = ClaudeConfigContents(
        '{"mcpServers":{"memex":{"command":"$connectMemexPath",'
        '"args":["serve","--vault","$connectVaultPath"]}}}',
      );
      await rig.tap(inSheet(find.text('Check again')));
      expect(dotColor(), OmColors.accent, reason: 'local match');

      rig.reader!.result = ClaudeConfigContents(
        '{"mcpServers":{"memex":{"command":"$connectMemexPath",'
        '"args":["serve","--vault","/vaults/Other"]}}}',
      );
      await rig.tap(inSheet(find.text('Check again')));
      expect(dotColor(), OmColors.fg2, reason: 'not set up');

      final hosted = await pumpConnect(
        tester,
        vault: agentsSheetHostedVault,
        tokens: {agentsSheetServer.id: _token},
        reader: FakeClaudeConfigReader.contents(
          '{"mcpServers":{"memex-studio":{"command":"$connectMemexPath",'
          '"args":["serve","--remote","$connectMcpAddress"]}}}',
        ),
      );
      expect(hosted.reader!.reads, 1);
      expect(dotColor(), OmColors.accent, reason: 'hosted match');
    });

    testWidgets('a read that finishes after the sheet closed is dropped', (
      tester,
    ) async {
      final reader = HeldClaudeConfigReader(const ClaudeConfigMissing());
      final rig = await pumpConnect(
        tester,
        overrides: [claudeConfigReaderProvider.overrideWithValue(reader)],
      );
      expect(reader.reads, 1);
      await rig.closeSheet();
      reader.holding = false;
      reader.release();
      await rig.settle();
      expect(tester.takeException(), isNull);
      expect(textShowing(_missing), findsNothing);
    });
  });

  group('hosted details', () {
    Future<ConnectRig> pumpHosted(
      WidgetTester tester, {
      Map<String, String>? tokens,
      String? binaryPath = connectMemexPath,
      List<Override> overrides = const [],
    }) => pumpConnect(
      tester,
      vault: agentsSheetHostedVault,
      binaryPath: binaryPath,
      tokens: tokens ?? {agentsSheetServer.id: _token},
      overrides: overrides,
    );

    testWidgets(
      'token bearing code blocks tell Semantics the mask label and never the token',
      (tester) async {
        final masked = MaskedTokenText(_token);
        String spoken(String snippet) =>
            snippet.replaceAll(masked.text, masked.semanticsLabel);
        final rig = await pumpHosted(tester);

        final desktopLabel = spoken(_hostedEntry(masked));
        expect(_node(desktopLabel).childrenCount, 0);
        expect(find.bySemanticsLabel(RegExp(_token)), findsNothing);

        await rig.chooseClient('Claude Code');
        final codeLabel = spoken(_hostedCode(masked));
        expect(_node(codeLabel).childrenCount, 0);
        expect(
          codeLabel,
          contains(
            'access token ending ${_token.substring(_token.length - 4)}',
          ),
        );

        // Revealing shows the token, not to Semantics.
        await rig.tap(inSheet(find.text('Reveal')));
        expect(textContaining(_token), findsWidgets);
        expect(_node(codeLabel).childrenCount, 0);
        expect(find.bySemanticsLabel(RegExp(_token)), findsNothing);
        await rig.chooseClient('Claude Desktop');
        expect(_node(desktopLabel).childrenCount, 0);
        expect(find.bySemanticsLabel(RegExp(_token)), findsNothing);
      },
    );

    testWidgets(
      'with no token the code blocks tell Semantics the placeholder',
      (tester) async {
        final rig = await pumpHosted(tester, tokens: const {});
        const placeholder = PlaceholderTokenText();
        expect(_node(_hostedEntry(placeholder)).childrenCount, 0);
        await rig.chooseClient('Claude Code');
        expect(_node(_hostedCode(placeholder)).childrenCount, 0);
      },
    );

    testWidgets('the token row is one leaf node and the reveal toggle shows', (
      tester,
    ) async {
      final masked = MaskedTokenText(_token);
      final rig = await pumpHosted(tester);
      final row = _node(masked.semanticsLabel);
      expect(row.childrenCount, 0);
      expect(row, isSemantics(label: masked.semanticsLabel, isButton: false));
      expect(find.bySemanticsLabel(maskToken(_token)), findsNothing);

      await rig.tap(inSheet(find.text('Reveal')));
      expect(
        _node(masked.semanticsLabel).childrenCount,
        0,
        reason: 'revealed: still the label, never the token',
      );
      expect(textShowing(_token), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(_token)), findsNothing);
    });

    testWidgets('Claude Code Copy reads the UTC offset when it is pressed', (
      tester,
    ) async {
      var offset = connectUtcOffset;
      final rig = await pumpHosted(
        tester,
        overrides: [utcOffsetProvider.overrideWithValue(() => offset)],
      );
      await rig.chooseClient('Claude Code');
      offset = const Duration(hours: 1);

      await rig.copy(copyCodeCommandLabel);

      expect(rig.sensitive, [
        _hostedCode(RealTokenText(_token), const Duration(hours: 1)),
      ]);
    });

    testWidgets('a token deleted before Reveal turns the row into No token', (
      tester,
    ) async {
      final rig = await pumpHosted(tester);
      expect(inSheet(find.text('Reveal')), findsOneWidget);
      rig.harness.tokens.tokens.clear();

      await rig.tap(inSheet(find.text('Reveal')));

      expect(
        inSheet(textShowing('No token in this Mac’s Keychain for this server')),
        findsOneWidget,
      );
      expect(inSheet(find.text('Update token')), findsOneWidget);
      expect(textContaining(_token), findsNothing);
      expect(
        codeBlockText(tester, copyDesktopConfigLabel),
        _hostedEntry(const PlaceholderTokenText()),
      );
    });

    testWidgets('hosted with no memex binary offers Locate on Claude Desktop', (
      tester,
    ) async {
      final rig = await pumpHosted(tester, binaryPath: null);

      expect(inSheet(find.text('memex wasn\'t found.')), findsOneWidget);
      expect(inSheet(labelIgnoringCase('Locate memex…')), findsOneWidget);
      expect(copyButton(copyDesktopConfigLabel), findsNothing);
      expect(textShowing(connectStepHostedMerge), findsNothing);
      expect(textShowing(connectStepRestart), findsNothing);
      // The address and token rows still show, and detection still runs.
      expect(codeBlockText(tester, copyMcpAddressLabel), connectMcpAddress);
      expect(inSheet(find.text('Reveal')), findsOneWidget);
      expect(rig.reader!.reads, 1);
      expect(inSheet(textShowing(_missing)), findsOneWidget);

      // Claude Code needs no local binary.
      await rig.chooseClient('Claude Code');
      expect(find.text('memex wasn\'t found.'), findsNothing);
      expect(copyButton(copyCodeCommandLabel), findsOneWidget);
      expect(
        codeBlockText(tester, copyCodeCommandLabel),
        _hostedCode(MaskedTokenText(_token)),
      );
    });

    testWidgets('a Keychain read that throws shows the no token row', (
      tester,
    ) async {
      final rig = await pumpHosted(
        tester,
        overrides: [
          tokenStoreProvider.overrideWithValue(_Wi411ThrowingTokenStore()),
        ],
      );
      expect(
        inSheet(textShowing('No token in this Mac’s Keychain for this server')),
        findsOneWidget,
      );
      expect(textContaining(_thrown), findsNothing);
      expect(tester.takeException(), isNull);
      expect(rig.sensitive, isEmpty);
    });

    testWidgets(
      'a hosted vault whose server is no longer saved shows only the intro',
      (tester) async {
        final rig = await pumpConnect(
          tester,
          vault: agentsSheetHostedVault,
          servers: const [],
        );
        expect(
          inSheet(
            textShowing(
              'Agents reach this vault through its vault server. Every '
              'client needs the MCP address and the access token.',
            ),
          ),
          findsOneWidget,
        );
        expect(textShowing('MCP address'), findsNothing);
        expect(copyButton(copyMcpAddressLabel), findsNothing);
        expect(copyButton(copyDesktopConfigLabel), findsNothing);
        expect(find.text('Reveal'), findsNothing);
        expect(find.text('Check again'), findsNothing);
        expect(rig.reader!.reads, 0, reason: 'no target, nothing to detect');
      },
    );
  });
}
