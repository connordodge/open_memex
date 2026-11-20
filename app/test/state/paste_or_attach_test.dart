// WI #147 (Spec #123 A2: R8, R9, R11; ruling D11): the one Paste route.
//
// Two levels:
// - `pasteOrAttach` / `canPasteOrAttach` alone, under a ProviderScope with a
//   `FakePasteboardReader`, a recording `AttachController` and a
//   `LocalVaultAccess` whose CLI decides `canWrite`: R8's order (files,
//   text, image, nothing) and R11.
// - Every Paste entry of the real note editor (wi147_drop_paste_harness):
//   Cmd+V in a single row, the right-click Paste in a single row, the
//   spelling menu's Paste, Cmd+V and the right-click Paste in Source mode,
//   and over a cross-row selection. Each counts text pastes (the clipboard
//   text in the body) and attaches (the held `FakeAttachmentsAccess`'s
//   `add` / `addBytes` calls) through A4's real controller.
//
// The clipboard is two fakes kept in step (`Wi147Rig.clipboard`): A1's
// native reader (files, text flag, PNG) and Flutter's plain-text clipboard
// (`MacClipboard`), which a field's own paste reads. As on macOS, no PNG is
// reported while text is present.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/attach_controller.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/paste_or_attach.dart';
import 'package:open_memex_app/src/state/pasteboard_reader.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/editor/spelling_menu.dart';

import '../support/app_harness.dart' show pumpFrames;
import '../support/attachment_input_fakes.dart';
import '../support/editor_rows_probe.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_spelling_service.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';
import '../support/wi146_attach_harness.dart';
import '../support/wi147_drop_paste_harness.dart';

// ---------------------------------------------------------------- unit rig

/// An [AttachController] that records what it is asked to attach and
/// attaches nothing.
class _Wi147RecordingController extends AttachController {
  _Wi147RecordingController(super.ref);

  final List<({List<String> paths, int? anchorLine})> pathCalls = [];
  final List<({Uint8List bytes, String name, int? anchorLine})> byteCalls = [];

  int get calls => pathCalls.length + byteCalls.length;

  @override
  Future<void> attachPaths(
    BuildContext context,
    List<String> paths, {
    int? anchorLine,
  }) async {
    pathCalls.add((paths: List.of(paths), anchorLine: anchorLine));
  }

  @override
  Future<void> attachBytes(
    BuildContext context,
    Uint8List bytes,
    String name, {
    int? anchorLine,
  }) async {
    byteCalls.add((bytes: bytes, name: name, anchorLine: anchorLine));
  }
}

class _Wi147Unit {
  _Wi147Unit(this.context, this.reader);

  final BuildContext context;
  final FakePasteboardReader reader;

  /// How often the entry's own text paste ran.
  int textPastes = 0;

  _Wi147RecordingController get controller =>
      ProviderScope.containerOf(
            context,
            listen: false,
          ).read(attachControllerProvider)
          as _Wi147RecordingController;

  Future<PasteOutcome> paste() =>
      pasteOrAttach(context, pasteText: () => textPastes++);

  Future<bool> offered() => canPasteOrAttach(context);
}

/// Pumps a bare ProviderScope whose clipboard holds [contents]. [writable]
/// is `VaultAccess.canWrite`; [vault] false means no vault is open.
Future<_Wi147Unit> _unit(
  WidgetTester tester,
  PasteboardContents contents, {
  bool writable = true,
  bool vault = true,
}) async {
  final reader = FakePasteboardReader(contents);
  late BuildContext context;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pasteboardReaderProvider.overrideWithValue(reader),
        attachControllerProvider.overrideWith(_Wi147RecordingController.new),
        clockProvider.overrideWithValue(FakeClock(wi147Now)),
        vaultAccessProvider.overrideWithValue(
          vault
              ? LocalVaultAccess(
                  vaultPath: '/vaults/My Vault',
                  cli: writable ? FakeMemexCli() : null,
                )
              : null,
        ),
      ],
      child: Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    ),
  );
  return _Wi147Unit(context, reader);
}

// ---------------------------------------------------------------- app rig

const _caret = 'Review the draft';
const _text = 'Hello';
const _finderText = 'spec.pdf';

final _s = wi146Line('spec.pdf');

/// One clipboard of the count ACs: how to put it there, and the body and
/// attaches one Paste at the end of `Review the draft` gives.
typedef _Clip = ({
  String label,
  void Function(Wi147Rig g, Uint8List png) put,
  void Function(Wi147Rig g, Uint8List png, String Function(String) after)
  expect,
});

/// The image a test pastes.
Uint8List _png() => fakePngBytes(12);

void _expectTextPaste(Wi147Rig g, String expected) {
  expect(g.body, expected);
  expect(wi147Count(g.body, _text), 1, reason: '1 text paste');
  expect(g.attaches, 0, reason: '0 attaches');
  expect(
    g.pasteboard.reads,
    greaterThan(0),
    reason: 'the paste went through pasteOrAttach',
  );
}

void _expectFileAttach(Wi147Rig g, String expected) {
  expect(g.addedPaths, [wi147PdfPath], reason: '1 attach');
  expect(g.r.attachments.addBytesCalls, isEmpty);
  expect(g.body, expected, reason: 'no Finder name text is pasted');
  expect(
    wi147Count(g.body, _finderText),
    wi147Count(_s, _finderText),
    reason: 'the file name occurs only in the attachment line',
  );
}

void _expectImageAttach(Wi147Rig g, Uint8List png, String expected) {
  final name = wi147PastedName(g.r.h.clock.now());
  expect(g.addedNames, [name], reason: '1 attach named per R9');
  expect(g.r.attachments.addBytesCalls.single.bytes, png);
  expect(g.r.attachments.addCalls, isEmpty);
  expect(g.body, expected);
}

/// The three clipboards of the D11 count ACs. `after(line)` is the body
/// with [line] attached at the caret line.
final List<_Clip> _clips = [
  (
    label: 'text',
    put: (g, _) => g.clipboard(text: _text),
    expect: (g, _, after) => _expectTextPaste(g, after('')),
  ),
  (
    label: 'files',
    put: (g, _) => g.clipboard(files: const [wi147PdfPath], text: _finderText),
    expect: (g, _, after) => _expectFileAttach(g, after(_s)),
  ),
  (
    label: 'image',
    put: (g, png) => g.clipboard(png: png),
    expect: (g, png, after) => _expectImageAttach(
      g,
      png,
      after(wi146Line(wi147PastedName(g.r.h.clock.now()))),
    ),
  ),
];

/// The plain note's body after one Paste at the end of its first line:
/// [line] attached there, or the text pasted when [line] is empty.
String _plainAfter(String line) => line.isEmpty
    ? 'Review the draft$_text\nNext steps'
    : 'Review the draft\n\n$line\n\nNext steps';

/// One Paste entry over the plain note, with the caret at the end of its
/// first line.
typedef _Entry = Future<void> Function(Wi147Rig g);

Future<void> _rowCmdV(Wi147Rig g) async {
  await g.r.caretAfter(_caret);
  await g.cmdV();
}

Future<void> _rowRightClick(Wi147Rig g) async {
  await g.r.caretAfter(_caret);
  await g.rightClickAtCaret();
  await g.choosePaste();
}

Future<void> _sourceCmdV(Wi147Rig g) async {
  await g.r.sourceCaret(_caret.length);
  await g.cmdV();
}

Future<void> _sourceRightClick(Wi147Rig g) async {
  await g.r.sourceCaret(_caret.length);
  await g.rightClickAtCaret();
  await g.choosePaste();
}

/// A [FakePasteboardReader] whose read waits until [open] is called: a right
/// click's menu is then still waiting for the clipboard.
class _Wi147HeldPasteboard extends FakePasteboardReader {
  _Wi147HeldPasteboard(super.contents);

  final Completer<void> _gate = Completer<void>();

  /// Lets every waiting and later read answer.
  void open() => _gate.complete();

  @override
  Future<PasteboardContents> read() async {
    await _gate.future;
    return super.read();
  }
}

void main() {
  holdFontFetches();

  // ------------------------------------------------------------ the route

  group('the routing order of pasteOrAttach (AC5)', () {
    testWidgets(
      'a text only clipboard pastes the text once and attaches nothing',
      (tester) async {
        final u = await _unit(tester, const PasteboardContents(hasText: true));
        expect(await u.paste(), PasteOutcome.text);
        expect(u.textPastes, 1);
        expect(u.controller.calls, 0);
        expect(u.reader.reads, 1);
      },
    );

    testWidgets(
      'file URLs with the Finder name text attach the files in clipboard order at the caret line and paste no text',
      (tester) async {
        final u = await _unit(
          tester,
          PasteboardContents(
            files: [wi147PngPath, wi147PdfPath],
            hasText: true,
          ),
        );
        expect(await u.paste(), PasteOutcome.files);
        expect(u.textPastes, 0, reason: 'no Finder name text');
        expect(u.controller.pathCalls, hasLength(1));
        expect(u.controller.pathCalls.single.paths, [
          wi147PngPath,
          wi147PdfPath,
        ]);
        expect(u.controller.pathCalls.single.anchorLine, isNull);
        expect(u.controller.byteCalls, isEmpty);
      },
    );

    testWidgets(
      'an image only clipboard attaches one PNG named per R9 from the injected clock and pastes no text',
      (tester) async {
        final png = fakePngBytes(16);
        final u = await _unit(tester, PasteboardContents(png: png));
        expect(await u.paste(), PasteOutcome.image);
        expect(u.textPastes, 0);
        expect(u.controller.pathCalls, isEmpty);
        expect(u.controller.byteCalls, hasLength(1));
        final call = u.controller.byteCalls.single;
        expect(call.bytes, png);
        expect(call.name, 'Pasted image 2026-11-18 14.03.22.png');
        expect(call.anchorLine, isNull, reason: 'at the caret line');
      },
    );

    testWidgets('file URLs win over an image on the same clipboard', (
      tester,
    ) async {
      final u = await _unit(
        tester,
        PasteboardContents(files: [wi147PdfPath], png: fakePngBytes()),
      );
      expect(await u.paste(), PasteOutcome.files);
      expect(u.controller.pathCalls.single.paths, [wi147PdfPath]);
      expect(u.controller.byteCalls, isEmpty);
      expect(u.textPastes, 0);
    });

    testWidgets('text wins over an image when both are reported', (
      tester,
    ) async {
      final u = await _unit(
        tester,
        PasteboardContents(hasText: true, png: fakePngBytes()),
      );
      expect(await u.paste(), PasteOutcome.text);
      expect(u.textPastes, 1);
      expect(u.controller.calls, 0);
    });

    testWidgets(
      'an empty clipboard reads the clipboard once and does nothing',
      (tester) async {
        final u = await _unit(tester, const PasteboardContents());
        expect(await u.paste(), PasteOutcome.nothing);
        expect(u.reader.reads, 1, reason: 'the route asked the clipboard');
        expect(u.textPastes, 0);
        expect(u.controller.calls, 0);
      },
    );

    testWidgets(
      'a folder path on the clipboard goes to the controller unchanged so the domain can refuse it',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('w147-clip');
        addTearDown(() => dir.deleteSync(recursive: true));
        final u = await _unit(tester, PasteboardContents(files: [dir.path]));
        expect(await u.paste(), PasteOutcome.files);
        expect(u.controller.pathCalls.single.paths, [dir.path]);
      },
    );
  });

  group('pasteOrAttach on a vault that cannot be written (AC8)', () {
    testWidgets(
      'with canWrite false file URLs and an image attach nothing while text on the same vault still pastes',
      (tester) async {
        final u = await _unit(
          tester,
          PasteboardContents(files: [wi147PdfPath]),
          writable: false,
        );
        await u.paste();
        expect(u.controller.calls, 0, reason: 'file URLs attach nothing');
        u.reader.contents = PasteboardContents(png: fakePngBytes());
        await u.paste();
        expect(u.controller.calls, 0, reason: 'an image attaches nothing');
        u.reader.contents = const PasteboardContents(hasText: true);
        expect(await u.paste(), PasteOutcome.text);
        expect(u.textPastes, greaterThan(0));
        expect(u.controller.calls, 0);
      },
    );

    testWidgets('with canWrite false text still pastes once', (tester) async {
      final u = await _unit(
        tester,
        const PasteboardContents(hasText: true),
        writable: false,
      );
      expect(await u.paste(), PasteOutcome.text);
      expect(u.textPastes, 1);
      expect(u.controller.calls, 0);
    });

    testWidgets(
      'with no vault open file URLs and images attach nothing and text still pastes',
      (tester) async {
        final u = await _unit(
          tester,
          PasteboardContents(files: [wi147PdfPath], png: fakePngBytes()),
          vault: false,
        );
        await u.paste();
        expect(u.controller.calls, 0);
        u.reader.contents = const PasteboardContents(hasText: true);
        expect(await u.paste(), PasteOutcome.text);
        expect(u.textPastes, 1);
      },
    );
  });

  group('when Paste is offered (AC7)', () {
    for (final (name, contents, writable, offered) in [
      (
        'Paste is offered for file URLs only',
        PasteboardContents(files: [wi147PdfPath]),
        true,
        true,
      ),
      (
        'Paste is offered for an image only',
        PasteboardContents(png: fakePngBytes()),
        true,
        true,
      ),
      (
        'Paste is offered for text only',
        const PasteboardContents(hasText: true),
        true,
        true,
      ),
      (
        'Paste is not offered for an empty clipboard',
        const PasteboardContents(),
        true,
        false,
      ),
      (
        'with canWrite false Paste is not offered for file URLs only',
        PasteboardContents(files: [wi147PdfPath]),
        false,
        false,
      ),
      (
        'with canWrite false Paste is not offered for an image only',
        PasteboardContents(png: fakePngBytes()),
        false,
        false,
      ),
      (
        'with canWrite false Paste is still offered for text',
        const PasteboardContents(hasText: true),
        false,
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final u = await _unit(tester, contents, writable: writable);
        expect(await u.offered(), offered);
        expect(u.reader.reads, greaterThan(0), reason: 'asked the clipboard');
      });
    }
  });

  // ------------------------------------------------------------ the entries

  group('paste counts at every entry of the note editor (AC5)', () {
    for (final (name, entry, clipLabel) in <(String, _Entry, String)>[
      (
        'Cmd V in a single row with a text only clipboard gives 1 text paste and 0 attaches',
        _rowCmdV,
        'text',
      ),
      (
        'Cmd V in a single row with file URLs and the Finder name text gives 1 attach and 0 text pastes',
        _rowCmdV,
        'files',
      ),
      (
        'Cmd V in a single row with an image only gives 1 attach named per R9',
        _rowCmdV,
        'image',
      ),
      (
        'the right click Paste in a single row with a text only clipboard gives 1 text paste and 0 attaches',
        _rowRightClick,
        'text',
      ),
      (
        'the right click Paste in a single row with file URLs and the Finder name text gives 1 attach and 0 text pastes',
        _rowRightClick,
        'files',
      ),
      (
        'the right click Paste in a single row with an image only gives 1 attach named per R9',
        _rowRightClick,
        'image',
      ),
      (
        'Cmd V in Source mode with a text only clipboard gives 1 text paste and 0 attaches',
        _sourceCmdV,
        'text',
      ),
      (
        'Cmd V in Source mode with file URLs and the Finder name text gives 1 attach and 0 text pastes',
        _sourceCmdV,
        'files',
      ),
      (
        'Cmd V in Source mode with an image only gives 1 attach named per R9',
        _sourceCmdV,
        'image',
      ),
      (
        'the right click Paste in Source mode with a text only clipboard gives 1 text paste and 0 attaches',
        _sourceRightClick,
        'text',
      ),
      (
        'the right click Paste in Source mode with file URLs and the Finder name text gives 1 attach and 0 text pastes',
        _sourceRightClick,
        'files',
      ),
      (
        'the right click Paste in Source mode with an image only gives 1 attach named per R9',
        _sourceRightClick,
        'image',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final clip = _clips.firstWhere((c) => c.label == clipLabel);
        final png = _png();
        final g = await wi147Pump(tester);
        await g.r.open();
        clip.put(g, png);

        await entry(g);

        clip.expect(g, png, _plainAfter);
      }, variant: macOnly);
    }
  });

  group('the spelling menu Paste (AC5)', () {
    const body = 'Good teh day.\nNext steps';
    String after(String line) => line.isEmpty
        ? 'Good t${_text}eh day.\nNext steps'
        : 'Good teh day.\n\n$line\n\nNext steps';

    for (final (name, clipLabel) in [
      (
        'the spelling menu Paste with a text only clipboard gives 1 text paste and 0 attaches',
        'text',
      ),
      (
        'the spelling menu Paste with file URLs and the Finder name text gives 1 attach and 0 text pastes',
        'files',
      ),
      (
        'the spelling menu Paste with an image only gives 1 attach named per R9',
        'image',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final clip = _clips.firstWhere((c) => c.label == clipLabel);
        final png = _png();
        final g = await wi147Pump(
          tester,
          body: body,
          spelling: FakeSpellingService()
            ..misspell('teh', corrections: const ['the'])
            ..scriptGuesses('teh', const ['the']),
        );
        await g.r.open();
        await g.settleSpelling();
        clip.put(g, png);
        await g.r.caretAfter('Good t');
        await g.rightClickAtCaret();
        expect(find.byType(SpellingMenu), findsOneWidget, reason: 'menu');

        await g.choosePaste();

        clip.expect(g, png, after);
      }, variant: macOnly);
    }
  });

  group('a cross row selection (AC5)', () {
    // Three editor rows (a prose line and two list items); the selection
    // runs from `al|pha` to `be|ta`, with focus in the `beta` row.
    const body = 'Intro\n- alpha\n- beta';
    const base = 10;
    const extent = 18;
    Future<Wi147Rig> pump(WidgetTester tester) async {
      final g = await wi147Pump(tester, body: body);
      await g.r.open();
      expect(rowsHostOf(tester).rowCount, 3, reason: 'three rows');
      return g;
    }

    testWidgets(
      'a cross row text paste gives exactly 1 replaceRange edit and 0 attaches',
      (tester) async {
        final g = await pump(tester);
        g.clipboard(text: _text);
        await g.select(base, extent);
        g.r.bodyChanges.clear();

        await g.cmdV();

        expect(g.body, 'Intro\n- al${_text}ta');
        expect(g.r.bodyChanges, [
          'Intro\n- al${_text}ta',
        ], reason: 'one replaceRange edit');
        expect(g.attaches, 0);
        expect(g.pasteboard.reads, greaterThan(0));
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd V over a cross row selection with file URLs and the Finder name text gives 1 attach and 0 text pastes',
      (tester) async {
        final g = await pump(tester);
        g.clipboard(files: const [wi147PdfPath], text: _finderText);
        await g.select(base, extent);

        await g.cmdV();

        expect(g.addedPaths, [wi147PdfPath]);
        expect(wi147Count(g.body, _s), 1, reason: 'the line is inserted');
        expect(
          wi147Count(g.body, _finderText),
          wi147Count(_s, _finderText),
          reason: 'no Finder name text is pasted',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'the cross row right click Paste with an image only gives 1 attach named per R9',
      (tester) async {
        final png = _png();
        final g = await pump(tester);
        g.clipboard(png: png);
        await g.select(base, extent);
        // On the selected `b` of `beta`, in the focused row.
        final a = g.caretPoint(16);
        final b = g.caretPoint(17);
        await g.rightClick(Offset((a.dx + b.dx) / 2, a.dy));
        expect(g.body, body, reason: 'the right click edits nothing');

        await g.choosePaste();

        final name = wi147PastedName(g.r.h.clock.now());
        expect(g.addedNames, [name]);
        expect(wi147Count(g.body, wi146Line(name)), 1);
      },
      variant: macOnly,
    );
  });

  group('fields that never attach (AC6)', () {
    testWidgets(
      'Cmd V with an image in the Find bar gives 0 attaches while the same paste in a note row gives 1',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        await g.r.caretAfter(_caret);
        g.clipboard(png: _png());
        await g.openFindBar();

        await g.cmdV();
        expect(g.attaches, 0, reason: 'the Find bar never attaches');
        expect(g.body, wi146Example);

        await g.r.caretAfter(_caret);
        await g.cmdV();
        expect(g.r.attachments.addBytesCalls, hasLength(1));
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd V with an image in the note title field gives 0 attaches while the same paste in a note row gives 1',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        g.clipboard(png: _png());
        await tester.showKeyboard(find.byKey(const Key('editor-title')));
        await tester.pump();

        await g.cmdV();
        expect(g.attaches, 0, reason: 'the title field never attaches');
        expect(g.body, wi146Example);

        await g.r.caretAfter(_caret);
        await g.cmdV();
        expect(g.r.attachments.addBytesCalls, hasLength(1));
      },
      variant: macOnly,
    );

    testWidgets(
      'in Source mode Cmd V with an image in the note title field gives 0 attaches while the same paste in the body gives 1',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        await g.r.sourceCaret(_caret.length);
        g.clipboard(png: _png());
        await tester.showKeyboard(find.byKey(const Key('editor-title')));
        await tester.pump();

        await g.cmdV();
        expect(g.attaches, 0, reason: 'the title field never attaches');

        await g.r.sourceCaret(_caret.length);
        await g.cmdV();
        expect(g.r.attachments.addBytesCalls, hasLength(1));
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd V with an image in the Command palette autocomplete field gives 0 attaches while the same paste in a note row gives 1',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        await g.r.caretAfter(_caret);
        g.clipboard(png: _png());
        await g.r.openPalette();

        await g.cmdV();
        expect(g.attaches, 0, reason: 'the palette field never attaches');

        g.r.closePalette();
        await pumpFrames(tester);
        await g.r.caretAfter(_caret);
        await g.cmdV();
        expect(g.r.attachments.addBytesCalls, hasLength(1));
      },
      variant: macOnly,
    );
  });

  group('the right click Paste is offered (AC7)', () {
    testWidgets(
      'the right click menu of a single row offers Paste when the clipboard holds only an image',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        g.clipboard(png: _png());
        await g.r.caretAfter(_caret);
        await g.rightClickAtCaret();

        expect(g.menuItem('Paste'), findsOneWidget);
        await g.choosePaste();
        expect(g.r.attachments.addBytesCalls, hasLength(1));
      },
      variant: macOnly,
    );

    testWidgets(
      'the right click menu of a single row offers Paste when the clipboard holds only file URLs',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        g.clipboard(files: const [wi147PdfPath]);
        await g.r.caretAfter(_caret);
        await g.rightClickAtCaret();

        expect(g.menuItem('Paste'), findsOneWidget);
        await g.choosePaste();
        expect(g.addedPaths, [wi147PdfPath]);
        expect(g.body, _plainAfter(_s));
      },
      variant: macOnly,
    );

    testWidgets(
      'the right click menu in Source mode offers Paste when the clipboard holds only file URLs',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        g.clipboard(files: const [wi147PdfPath]);
        await g.r.sourceCaret(_caret.length);
        await g.rightClickAtCaret();

        expect(g.menuItem('Paste'), findsOneWidget);
        await g.choosePaste();
        expect(g.addedPaths, [wi147PdfPath]);
      },
      variant: macOnly,
    );
  });

  group('a vault that cannot be written (AC8)', () {
    testWidgets(
      'with canWrite false Cmd V with files or an image does nothing and Cmd V with text pastes text',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        await g.setWritable(false);
        await g.r.caretAfter(_caret);

        g.clipboard(files: const [wi147PdfPath]);
        await g.cmdV();
        g.clipboard(png: _png());
        await g.cmdV();
        expect(g.attaches, 0, reason: 'files and images do nothing');
        expect(g.body, wi146Example);

        g.clipboard(text: _text);
        await g.cmdV();
        expect(g.body, _plainAfter(''), reason: 'text pastes as today');
        expect(g.attaches, 0);

        await g.setWritable(true);
        await g.r.caretAfter('Review the draft$_text');
        g.clipboard(png: _png());
        await g.cmdV();
        expect(
          g.r.attachments.addBytesCalls,
          hasLength(1),
          reason: 'with canWrite true the same image attaches',
        );
      },
      variant: macOnly,
    );

    testWidgets(
      'in Source mode with canWrite false Cmd V with an image does nothing and Cmd V with text pastes text',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        await g.setWritable(false);
        await g.r.sourceCaret(_caret.length);

        g.clipboard(png: _png());
        await g.cmdV();
        expect(g.attaches, 0);
        expect(g.body, wi146Example);

        g.clipboard(text: _text);
        await g.cmdV();
        expect(g.body, _plainAfter(''));

        await g.setWritable(true);
        await g.r.sourceCaret(_caret.length);
        g.clipboard(png: _png());
        await g.cmdV();
        expect(g.r.attachments.addBytesCalls, hasLength(1));
      },
      variant: macOnly,
    );

    testWidgets(
      'with canWrite false the right click menu of a single row offers no Paste for an image only clipboard',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        await g.setWritable(false);
        g.clipboard(png: _png());
        await g.r.caretAfter(_caret);
        await g.rightClickAtCaret();
        expect(g.menuItem('Paste'), findsNothing);
        expect(g.attaches, 0);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await pumpFrames(tester);
        await g.setWritable(true);
        await g.r.caretAfter(_caret);
        await g.rightClickAtCaret();
        expect(
          g.menuItem('Paste'),
          findsOneWidget,
          reason: 'with canWrite true the image is offered',
        );
      },
      variant: macOnly,
    );
  });

  group('files on a vault that cannot be written (Q1, AC8)', () {
    testWidgets(
      'with canWrite false file URLs with the Finder name text paste the text and attach nothing',
      (tester) async {
        final u = await _unit(
          tester,
          PasteboardContents(files: [wi147PdfPath], hasText: true),
          writable: false,
        );
        expect(await u.paste(), PasteOutcome.text);
        expect(u.textPastes, 1, reason: 'the text pastes once');
        expect(u.controller.calls, 0, reason: 'nothing attaches');

        final w = await _unit(
          tester,
          PasteboardContents(files: [wi147PdfPath], hasText: true),
        );
        expect(await w.paste(), PasteOutcome.files);
        expect(w.textPastes, 0, reason: 'with canWrite true the files win');
        expect(w.controller.pathCalls.single.paths, [wi147PdfPath]);
      },
    );

    testWidgets(
      'with canWrite false Cmd V with file URLs and the Finder name text pastes the text and attaches nothing',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        await g.setWritable(false);
        await g.r.caretAfter(_caret);
        g.clipboard(files: const [wi147PdfPath], text: _finderText);

        await g.cmdV();

        expect(g.attaches, 0);
        expect(g.body, 'Review the draft$_finderText\nNext steps');
        expect(g.pasteboard.reads, greaterThan(0));
      },
      variant: macOnly,
    );

    testWidgets(
      'in Source mode with canWrite false Cmd V with file URLs and the Finder name text pastes the text and attaches nothing',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        await g.setWritable(false);
        await g.r.sourceCaret(_caret.length);
        g.clipboard(files: const [wi147PdfPath], text: _finderText);

        await g.cmdV();

        expect(g.attaches, 0);
        expect(g.body, 'Review the draft$_finderText\nNext steps');
      },
      variant: macOnly,
    );
  });

  group('pasteAttachesFiles decides the right click take over (Q3)', () {
    for (final (name, contents, writable, expected) in [
      (
        'the right click take over applies to file URLs on a writable vault',
        PasteboardContents(files: [wi147PdfPath], hasText: true),
        true,
        true,
      ),
      (
        'the right click take over applies to an image on a writable vault',
        PasteboardContents(png: fakePngBytes()),
        true,
        true,
      ),
      (
        'the right click take over does not apply to text only',
        const PasteboardContents(hasText: true),
        true,
        false,
      ),
      (
        'the right click take over does not apply to an empty clipboard',
        const PasteboardContents(),
        true,
        false,
      ),
      (
        'the right click take over does not apply to an image on a read only vault',
        PasteboardContents(png: fakePngBytes()),
        false,
        false,
      ),
      (
        'the right click take over does not apply to file URLs on a read only vault',
        PasteboardContents(files: [wi147PdfPath]),
        false,
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final u = await _unit(tester, contents, writable: writable);
        expect(await pasteAttachesFiles(u.context), expected);
        expect(u.reader.reads, 1);
      });
    }
  });

  group('the right click menu with Paste enabled (Q3)', () {
    testWidgets(
      'a text only right click shows the stock menu and its Paste pastes the text once',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        g.clipboard(text: _text);
        await g.r.caretAfter(_caret);
        await g.rightClickAtCaret();
        expect(g.menuItem('Paste'), findsOneWidget);
        expect(
          find.byType(AdaptiveTextSelectionToolbar),
          findsOneWidget,
          reason: 'one menu: the take over does not stack on the stock menu',
        );

        await g.choosePaste();

        expect(g.body, _plainAfter(''));
        expect(g.attaches, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'an image right click over a selection keeps Cut and Copy beside Paste',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        g.clipboard(png: _png());
        await g.r.caretAfter(_caret);
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 0, extentOffset: 6));
        await tester.pump();

        await g.rightClick(g.caretPoint(3));

        expect(g.menuItem('Paste'), findsOneWidget);
        expect(g.menuItem('Cut'), findsOneWidget);
        expect(g.menuItem('Copy'), findsOneWidget);
        await tester.tap(g.menuItem('Cut'));
        await pumpFrames(tester);
        expect(g.clip.text, 'Review', reason: 'Cut put the selection there');
        expect(g.body, startsWith(' the draft'));
        expect(g.attaches, 0);
        expect(g.menuItem('Paste'), findsNothing, reason: 'the menu closed');
      },
      variant: macOnly,
    );

    testWidgets(
      'an image right click in Source mode over a selection keeps Cut and Copy beside Paste',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        g.clipboard(png: _png());
        await g.r.sourceCaret(_caret.length);
        final field = g.focusedField();
        field.userUpdateTextEditingValue(
          field.textEditingValue.copyWith(
            selection: const TextSelection(baseOffset: 0, extentOffset: 6),
          ),
          SelectionChangedCause.tap,
        );
        await tester.pump();
        final rect = field.renderEditable.getLocalRectForCaret(
          const TextPosition(offset: 3),
        );
        await g.rightClick(
          field.renderEditable.localToGlobal(Offset(rect.left, rect.center.dy)),
        );

        expect(g.menuItem('Paste'), findsOneWidget);
        expect(g.menuItem('Cut'), findsOneWidget);
        expect(g.menuItem('Copy'), findsOneWidget);
      },
      variant: macOnly,
    );

    testWidgets('a take over menu closes when the row text changes', (
      tester,
    ) async {
      final g = await wi147Pump(tester);
      await g.r.open();
      g.clipboard(png: _png());
      await g.r.caretAfter(_caret);
      await g.rightClickAtCaret();
      expect(g.menuItem('Paste'), findsOneWidget);

      final field = g.focusedField();
      tester.testTextInput.updateEditingValue(
        field.textEditingValue.copyWith(
          text: '${field.textEditingValue.text}!',
        ),
      );
      await pumpFrames(tester);

      expect(g.menuItem('Paste'), findsNothing);
      expect(g.attaches, 0);
    }, variant: macOnly);

    testWidgets('a take over menu closes when the row loses focus', (
      tester,
    ) async {
      final g = await wi147Pump(tester);
      await g.r.open();
      g.clipboard(png: _png());
      await g.r.caretAfter(_caret);
      await g.rightClickAtCaret();
      expect(g.menuItem('Paste'), findsOneWidget);

      await tester.showKeyboard(find.byKey(const Key('editor-title')));
      await pumpFrames(tester);

      expect(g.menuItem('Paste'), findsNothing);
    }, variant: macOnly);

    testWidgets(
      'a take over menu in Source mode closes when the body text changes',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        g.clipboard(png: _png());
        await g.r.sourceCaret(_caret.length);
        await g.rightClickAtCaret();
        expect(g.menuItem('Paste'), findsOneWidget);

        final field = g.focusedField();
        tester.testTextInput.updateEditingValue(
          field.textEditingValue.copyWith(
            text: '${field.textEditingValue.text}!',
          ),
        );
        await pumpFrames(tester);

        expect(g.menuItem('Paste'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a take over menu in Source mode closes when the body loses focus',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        g.clipboard(png: _png());
        await g.r.sourceCaret(_caret.length);
        await g.rightClickAtCaret();
        expect(g.menuItem('Paste'), findsOneWidget);

        await tester.showKeyboard(find.byKey(const Key('editor-title')));
        await pumpFrames(tester);

        expect(g.menuItem('Paste'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a press while the right click still waits for the clipboard cancels its take over menu',
      (tester) async {
        final held = _Wi147HeldPasteboard(PasteboardContents(png: _png()));
        final g = await wi147Pump(tester, pasteboardReader: held);
        await g.r.open();
        await g.r.caretAfter(_caret);
        final at = g.caretPoint(_caret.length);

        await g.rightClickAtCaret();
        expect(g.menuItem('Paste'), findsNothing, reason: 'still waiting');
        await tester.tapAt(at, kind: PointerDeviceKind.mouse);
        await pumpFrames(tester);
        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Paste'), findsNothing, reason: 'cancelled');
      },
      variant: macOnly,
    );

    testWidgets(
      'a right click waiting for the clipboard shows its take over menu once the clipboard answers',
      (tester) async {
        final held = _Wi147HeldPasteboard(PasteboardContents(png: _png()));
        final g = await wi147Pump(tester, pasteboardReader: held);
        await g.r.open();
        await g.r.caretAfter(_caret);

        await g.rightClickAtCaret();
        expect(g.menuItem('Paste'), findsNothing, reason: 'still waiting');
        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Paste'), findsOneWidget);
      },
      variant: macOnly,
    );
  });
}
