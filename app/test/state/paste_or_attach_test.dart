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

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart' show RowKind;
import 'package:open_memex_app/src/state/attach_controller.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/paste_or_attach.dart';
import 'package:open_memex_app/src/state/pasteboard_reader.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/editor/spelling_menu.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart'
    show hideRowTextMenu, showRowTextMenu;

import '../support/app_harness.dart' show pumpFrames;
import '../support/attachments_fakes.dart';
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
  FakePasteboardReader? reader,
}) async {
  reader ??= FakePasteboardReader(contents);
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

/// A [FakePasteboardReader] whose read fails.
class _Wi147ThrowingPasteboard extends FakePasteboardReader {
  @override
  Future<PasteboardContents> read() async {
    reads++;
    throw PlatformException(code: 'unavailable');
  }
}

/// A right click at [at] that pumps no time, so the menu's wait for the
/// clipboard is still running when it returns.
Future<void> _rightClickNoWait(Wi147Rig g, Offset at) async {
  final mouse = await g.tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await g.tester.pump();
  await mouse.up();
  await g.tester.pump();
  await mouse.removePointer();
}

/// A [FakePasteboardReader] that logs its read into [log] and answers from
/// its contents.
class _Wi147LoggingPasteboard extends FakePasteboardReader {
  _Wi147LoggingPasteboard(this.log, super.contents);

  final List<String> log;

  @override
  Future<PasteboardContents> read() {
    log.add('read');
    return super.read();
  }
}

/// A [FakePasteboardReader] whose read waits until [open] (answers from
/// `contents`) or [fail] (throws).
class _Wi147LateFailingPasteboard extends FakePasteboardReader {
  _Wi147LateFailingPasteboard();

  final Completer<void> _gate = Completer<void>();

  void fail() => _gate.completeError(PlatformException(code: 'unavailable'));

  @override
  Future<PasteboardContents> read() async {
    reads++;
    await _gate.future;
    return contents;
  }
}

/// Flutter's plain-text clipboard, whose text check (`Clipboard.hasStrings`)
/// is only answered by [answer]. Every platform call lands in [log].
class _Wi147HeldTextCheck {
  _Wi147HeldTextCheck(WidgetTester tester, this.log) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) {
        log.add(call.method);
        if (call.method != 'Clipboard.hasStrings') return Future.value(null);
        return _answer.future.then(
          (value) => <String, Object?>{'value': value},
        );
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  final List<String> log;
  final Completer<bool> _answer = Completer<bool>();

  void answer(bool value) => _answer.complete(value);
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

  group('canPasteOrAttach answers within pasteOfferWait (r3)', () {
    /// Starts [_Wi147Unit.offered] and returns what it has answered so far.
    ({bool? Function() answer, Future<void> Function() done}) ask(
      _Wi147Unit u,
    ) {
      bool? answer;
      final f = u.offered().then((v) => answer = v);
      return (answer: () => answer, done: () => f);
    }

    testWidgets(
      'a clipboard read that never answers gives no Paste once pasteOfferWait has passed and not before',
      (tester) async {
        final held = _Wi147HeldPasteboard(
          const PasteboardContents(hasText: true),
        );
        final u = await _unit(tester, const PasteboardContents(), reader: held);
        final asked = ask(u);

        await tester.pump(pasteOfferWait - const Duration(milliseconds: 1));
        expect(asked.answer(), isNull, reason: 'still inside the wait');
        await tester.pump(const Duration(milliseconds: 1));
        await asked.done();

        expect(asked.answer(), isFalse);
      },
    );

    for (final (name, text, offered) in <(String, String?, bool)>[
      (
        'a clipboard read that fails gives Paste when Flutter reports text',
        _text,
        true,
      ),
      (
        'a clipboard read that fails gives no Paste when Flutter reports no text',
        null,
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        MacClipboard.install(tester, initial: text);
        final throwing = _Wi147ThrowingPasteboard();
        final u = await _unit(
          tester,
          const PasteboardContents(),
          reader: throwing,
        );

        expect(await u.offered(), offered);
        expect(throwing.reads, 1, reason: 'asked the clipboard');
      });
    }

    testWidgets(
      'a clipboard read that fails and a text check that never answers give no Paste once pasteOfferWait has passed and not before',
      (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) => Completer<Object?>().future,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final u = await _unit(
          tester,
          const PasteboardContents(),
          reader: _Wi147ThrowingPasteboard(),
        );
        final asked = ask(u);

        await tester.pump(pasteOfferWait - const Duration(milliseconds: 1));
        expect(asked.answer(), isNull, reason: 'still inside the wait');
        await tester.pump(const Duration(milliseconds: 1));
        await asked.done();

        expect(asked.answer(), isFalse);
      },
    );

    testWidgets(
      'a clipboard read that fails and a text check that fails give no Paste',
      (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => throw PlatformException(code: 'unavailable'),
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final u = await _unit(
          tester,
          const PasteboardContents(),
          reader: _Wi147ThrowingPasteboard(),
        );

        expect(await u.offered(), isFalse);
      },
    );
  });

  group('canPasteOrAttach tells a late clipboard answer (r4)', () {
    /// Starts canPasteOrAttach with an `onLateOffer` that counts; returns what
    /// it has answered and how often it ran late.
    ({
      bool? Function() answer,
      int Function() late,
      Future<void> Function() done,
    })
    ask(_Wi147Unit u) {
      bool? answer;
      var late = 0;
      final f = canPasteOrAttach(
        u.context,
        onLateOffer: () => late++,
      ).then((v) => answer = v);
      return (answer: () => answer, late: () => late, done: () => f);
    }

    testWidgets('the text check is sent before the clipboard read', (
      tester,
    ) async {
      final log = <String>[];
      _Wi147HeldTextCheck(tester, log);
      final reader = _Wi147LoggingPasteboard(
        log,
        const PasteboardContents(hasText: true),
      );
      final u = await _unit(tester, const PasteboardContents(), reader: reader);

      expect(await u.offered(), isTrue);

      expect(log, ['Clipboard.hasStrings', 'read']);
    });

    testWidgets(
      'a clipboard read that never answers gives Paste once pasteOfferWait has passed while Flutter reports text',
      (tester) async {
        MacClipboard.install(tester, initial: _text);
        final held = _Wi147HeldPasteboard(
          const PasteboardContents(hasText: true),
        );
        final u = await _unit(tester, const PasteboardContents(), reader: held);
        final asked = ask(u);

        await tester.pump(pasteOfferWait - const Duration(milliseconds: 1));
        expect(asked.answer(), isNull, reason: 'still inside the wait');
        await tester.pump(const Duration(milliseconds: 1));
        await asked.done();

        expect(asked.answer(), isTrue, reason: 'the text check decides');
        held.open();
        await pumpFrames(tester);
        expect(asked.late(), 0, reason: 'the answer was already yes');
      },
    );

    testWidgets(
      'a clipboard read that never answers and a text check that never answers give no Paste',
      (tester) async {
        _Wi147HeldTextCheck(tester, []);
        final held = _Wi147HeldPasteboard(
          const PasteboardContents(hasText: true),
        );
        final u = await _unit(tester, const PasteboardContents(), reader: held);
        final asked = ask(u);

        await tester.pump(pasteOfferWait);
        await asked.done();

        expect(asked.answer(), isFalse);
      },
    );

    testWidgets(
      'a clipboard read that never answers gives no Paste while Flutter reports no text',
      (tester) async {
        MacClipboard.install(tester);
        final held = _Wi147HeldPasteboard(
          const PasteboardContents(hasText: true),
        );
        final u = await _unit(tester, const PasteboardContents(), reader: held);
        final asked = ask(u);

        await tester.pump(pasteOfferWait);
        await asked.done();

        expect(asked.answer(), isFalse);
      },
    );

    testWidgets(
      'a text check that answers yes after pasteOfferWait does not change a no that was given',
      (tester) async {
        final text = _Wi147HeldTextCheck(tester, []);
        final held = _Wi147HeldPasteboard(
          const PasteboardContents(hasText: true),
        );
        final u = await _unit(tester, const PasteboardContents(), reader: held);
        final asked = ask(u);

        await tester.pump(pasteOfferWait);
        await asked.done();
        text.answer(true);
        await pumpFrames(tester);

        expect(asked.answer(), isFalse);
        expect(asked.late(), 0, reason: 'the read has not answered');
      },
    );

    // What a read that answers after pasteOfferWait finds, with Flutter
    // reporting no text, and whether that is a late offer.
    for (final (name, contents, writable, vault, late)
        in <(String, PasteboardContents, bool, bool, int)>[
          (
            'a late clipboard read that finds an image on a writable vault runs onLateOffer once',
            PasteboardContents(png: fakePngBytes()),
            true,
            true,
            1,
          ),
          (
            'a late clipboard read that finds file URLs on a writable vault runs onLateOffer once',
            PasteboardContents(files: [wi147PdfPath]),
            true,
            true,
            1,
          ),
          (
            'a late clipboard read that finds text runs onLateOffer once',
            const PasteboardContents(hasText: true),
            true,
            true,
            1,
          ),
          (
            'a late clipboard read that finds text on a read only vault runs onLateOffer once',
            const PasteboardContents(hasText: true),
            false,
            true,
            1,
          ),
          (
            'a late clipboard read that finds nothing never runs onLateOffer',
            const PasteboardContents(),
            true,
            true,
            0,
          ),
          (
            'a late clipboard read that finds an image on a read only vault never runs onLateOffer',
            PasteboardContents(png: fakePngBytes()),
            false,
            true,
            0,
          ),
          (
            'a late clipboard read that finds file URLs on a read only vault never runs onLateOffer',
            PasteboardContents(files: [wi147PdfPath]),
            false,
            true,
            0,
          ),
          (
            'a late clipboard read that finds an image with no vault open never runs onLateOffer',
            PasteboardContents(png: fakePngBytes()),
            true,
            false,
            0,
          ),
        ]) {
      testWidgets(name, (tester) async {
        MacClipboard.install(tester);
        final held = _Wi147HeldPasteboard(contents);
        final u = await _unit(
          tester,
          const PasteboardContents(),
          reader: held,
          writable: writable,
          vault: vault,
        );
        final asked = ask(u);

        await tester.pump(pasteOfferWait);
        await asked.done();
        expect(asked.answer(), isFalse, reason: 'the read was late');
        expect(asked.late(), 0, reason: 'nothing found yet');
        held.open();
        await pumpFrames(tester);

        expect(asked.late(), late);
      });
    }

    for (final (name, contents) in <(String, PasteboardContents)>[
      (
        'a clipboard read that answers in time with an image gives Paste and never runs onLateOffer',
        PasteboardContents(png: fakePngBytes()),
      ),
      (
        'a clipboard read that answers in time with nothing gives no Paste and never runs onLateOffer',
        const PasteboardContents(),
      ),
    ]) {
      testWidgets(name, (tester) async {
        MacClipboard.install(tester);
        final u = await _unit(tester, contents);
        final asked = ask(u);

        await asked.done();
        await tester.pump(pasteOfferWait * 2);
        await pumpFrames(tester);

        expect(asked.answer(), contents.png != null);
        expect(asked.late(), 0);
      });
    }

    testWidgets('a clipboard read that fails in time never runs onLateOffer', (
      tester,
    ) async {
      MacClipboard.install(tester);
      final u = await _unit(
        tester,
        const PasteboardContents(),
        reader: _Wi147ThrowingPasteboard(),
      );
      final asked = ask(u);

      await asked.done();
      await pumpFrames(tester);

      expect(asked.answer(), isFalse);
      expect(asked.late(), 0);
    });

    // A read that fails after pasteOfferWait: the text check, which had not
    // answered by then, decides, whichever of the two answers first.
    for (final (name, readFirst, text, late) in <(String, bool, bool, int)>[
      (
        'a late clipboard read that fails runs onLateOffer when the text check then says yes',
        true,
        true,
        1,
      ),
      (
        'a late clipboard read that fails never runs onLateOffer when the text check then says no',
        true,
        false,
        0,
      ),
      (
        'a text check that says yes before the late clipboard read fails runs onLateOffer once the read fails',
        false,
        true,
        1,
      ),
      (
        'a text check that says no before the late clipboard read fails never runs onLateOffer',
        false,
        false,
        0,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final check = _Wi147HeldTextCheck(tester, []);
        final reader = _Wi147LateFailingPasteboard();
        final u = await _unit(
          tester,
          const PasteboardContents(),
          reader: reader,
        );
        final asked = ask(u);

        await tester.pump(pasteOfferWait);
        await asked.done();
        expect(asked.answer(), isFalse, reason: 'nothing had answered');
        if (readFirst) {
          reader.fail();
          await pumpFrames(tester);
          expect(asked.late(), 0, reason: 'waits for the text check');
          check.answer(text);
        } else {
          check.answer(text);
          await pumpFrames(tester);
          expect(asked.late(), 0, reason: 'waits for the read');
          reader.fail();
        }
        await pumpFrames(tester);

        expect(asked.late(), late);
      });
    }
  });

  group('canPasteOrAttach called from onLateOffer answers without a read (r5)', () {
    /// A held read of an image that answers only after pasteOfferWait, so the
    /// first answer is no and onLateOffer runs once [_Wi147HeldPasteboard.open]
    /// is called. [inside] runs as onLateOffer.
    Future<_Wi147HeldPasteboard> askLate(
      WidgetTester tester,
      void Function(_Wi147Unit u, _Wi147HeldPasteboard held) inside,
    ) async {
      MacClipboard.install(tester);
      final held = _Wi147HeldPasteboard(
        PasteboardContents(png: fakePngBytes()),
      );
      final u = await _unit(tester, const PasteboardContents(), reader: held);
      final first = canPasteOrAttach(
        u.context,
        onLateOffer: () => inside(u, held),
      );
      await tester.pump(pasteOfferWait);
      expect(await first, isFalse, reason: 'the read was late');
      held.open();
      await pumpFrames(tester);
      return held;
    }

    testWidgets(
      'a canPasteOrAttach called inside onLateOffer answers yes at once without reading the clipboard',
      (tester) async {
        final answers = <bool>[];
        var readsInside = -1;
        final held = await askLate(tester, (u, held) {
          canPasteOrAttach(u.context).then(answers.add);
          readsInside = held.reads;
        });

        expect(answers, [true]);
        expect(readsInside, 1, reason: 'only the read that was late');
        expect(held.reads, 1, reason: 'the inner call read nothing');
      },
    );

    testWidgets(
      'only the first canPasteOrAttach called inside onLateOffer gets the answer and the next one reads as usual',
      (tester) async {
        final answers = <bool>[];
        final held = await askLate(tester, (u, held) {
          canPasteOrAttach(u.context).then(answers.add);
          canPasteOrAttach(u.context).then(answers.add);
        });

        expect(answers, [true, true], reason: 'an image on a writable vault');
        expect(held.reads, 2, reason: 'the second inner call read');
      },
    );

    testWidgets(
      'a canPasteOrAttach called after onLateOffer returned reads the clipboard as usual',
      (tester) async {
        late _Wi147Unit unit;
        final held = await askLate(tester, (u, held) => unit = u);
        expect(held.reads, 1);

        final answer = await canPasteOrAttach(unit.context);

        expect(answer, isTrue);
        expect(held.reads, 2, reason: 'asked the clipboard again');
      },
    );

    testWidgets(
      'a canPasteOrAttach called after an onLateOffer that threw reads the clipboard as usual',
      (tester) async {
        late _Wi147Unit unit;
        final errors = <Object>[];
        final held = _Wi147HeldPasteboard(
          PasteboardContents(png: fakePngBytes()),
        );
        MacClipboard.install(tester);
        unit = await _unit(tester, const PasteboardContents(), reader: held);
        await runZonedGuarded(() async {
          final first = canPasteOrAttach(
            unit.context,
            onLateOffer: () => throw StateError('menu failed'),
          );
          await tester.pump(pasteOfferWait);
          await first;
          held.open();
          await pumpFrames(tester);
        }, (error, _) => errors.add(error));
        expect(held.reads, 1);

        final answer = await canPasteOrAttach(unit.context);

        expect(answer, isTrue);
        expect(held.reads, 2, reason: 'nothing was left handed over');
      },
    );
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

        g.r.bodyChanges.clear();

        await g.cmdV();

        expect(g.addedPaths, [wi147PdfPath]);
        expect(
          g.body,
          '$body\n\n$_s',
          reason:
              'the line goes after the caret row and the selected text stays',
        );
        expect(g.r.bodyChanges, ['$body\n\n$_s'], reason: 'one body change');
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
        g.r.bodyChanges.clear();

        await g.choosePaste();

        final name = wi147PastedName(g.r.h.clock.now());
        final expected = '$body\n\n${wi146Line(name)}';
        expect(g.addedNames, [name]);
        expect(
          g.body,
          expected,
          reason: 'after the caret row; the selected text stays',
        );
        expect(g.r.bodyChanges, [expected], reason: 'one body change');
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

  group('the cross row menu offers Paste only while canPasteOrAttach (AC7, AC8)', () {
    // Selection `al|pha` to `be|ta` over three rows; a right click on the
    // selected `b` of `beta` shows the cross-row menu.
    const body = 'Intro\n- alpha\n- beta';
    for (final (name, clipboard, writable, offered)
        in <(String, PasteboardContents, bool, bool)>[
          (
            'the cross row menu offers Paste for file URLs only',
            PasteboardContents(files: [wi147PdfPath]),
            true,
            true,
          ),
          (
            'the cross row menu offers Paste for an image only',
            PasteboardContents(png: fakePngBytes()),
            true,
            true,
          ),
          (
            'the cross row menu offers Paste for text only',
            const PasteboardContents(hasText: true),
            true,
            true,
          ),
          (
            'the cross row menu offers no Paste for an empty clipboard',
            const PasteboardContents(),
            true,
            false,
          ),
          (
            'the cross row menu offers no Paste for file URLs only on a read only vault',
            PasteboardContents(files: [wi147PdfPath]),
            false,
            false,
          ),
          (
            'the cross row menu offers no Paste for an image only on a read only vault',
            PasteboardContents(png: fakePngBytes()),
            false,
            false,
          ),
          (
            'the cross row menu still offers Paste for text on a read only vault',
            const PasteboardContents(hasText: true),
            false,
            true,
          ),
        ]) {
      testWidgets(name, (tester) async {
        final g = await wi147Pump(tester, body: body);
        await g.r.open();
        g.pasteboard.contents = clipboard;
        await g.setWritable(writable);
        await g.select(10, 18);
        final a = g.caretPoint(16);
        final b = g.caretPoint(17);

        await g.rightClick(Offset((a.dx + b.dx) / 2, a.dy));

        expect(g.menuItem('Copy'), findsOneWidget, reason: 'the menu shows');
        expect(g.menuItem('Cut'), findsOneWidget);
        expect(
          g.menuItem('Paste'),
          offered ? findsOneWidget : findsNothing,
          reason: 'Paste is offered only while canPasteOrAttach',
        );
        expect(g.pasteboard.reads, greaterThan(0));
      }, variant: macOnly);
    }

    testWidgets(
      'a press while the cross row right click still waits for the clipboard cancels its menu',
      (tester) async {
        final held = _Wi147HeldPasteboard(
          const PasteboardContents(hasText: true),
        );
        final g = await wi147Pump(tester, body: body, pasteboardReader: held);
        await g.r.open();
        await g.select(10, 18);
        final a = g.caretPoint(16);
        final b = g.caretPoint(17);

        // The right click and the press both land inside pasteOfferWait.
        await _rightClickNoWait(g, Offset((a.dx + b.dx) / 2, a.dy));
        expect(g.menuItem('Copy'), findsNothing, reason: 'still waiting');
        await tester.tapAt(g.caretPoint(2), kind: PointerDeviceKind.mouse);
        await pumpFrames(tester);
        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Copy'), findsNothing, reason: 'cancelled');
        expect(g.menuItem('Paste'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a cross row right click whose clipboard never answers still shows Copy and Cut but no Paste',
      (tester) async {
        // Never opened: the read of the clipboard never answers.
        final held = _Wi147HeldPasteboard(
          const PasteboardContents(hasText: true),
        );
        final g = await wi147Pump(tester, body: body, pasteboardReader: held);
        await g.r.open();
        await g.select(10, 18);
        final a = g.caretPoint(16);
        final b = g.caretPoint(17);

        await _rightClickNoWait(g, Offset((a.dx + b.dx) / 2, a.dy));
        expect(g.menuItem('Copy'), findsNothing, reason: 'within the wait');
        await tester.pump(pasteOfferWait);
        await pumpFrames(tester);

        expect(g.menuItem('Copy'), findsOneWidget);
        expect(g.menuItem('Cut'), findsOneWidget);
        expect(g.menuItem('Paste'), findsNothing);
      },
      variant: macOnly,
    );

    for (final (name, text, offered) in <(String, String?, bool)>[
      (
        'a cross row right click whose clipboard read fails offers Paste when Flutter reports text',
        _text,
        true,
      ),
      (
        'a cross row right click whose clipboard read fails offers no Paste when Flutter reports no text',
        null,
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final g = await wi147Pump(
          tester,
          body: body,
          pasteboardReader: _Wi147ThrowingPasteboard(),
        );
        await g.r.open();
        g.clip.text = text;
        await g.select(10, 18);
        final a = g.caretPoint(16);
        final b = g.caretPoint(17);

        await g.rightClick(Offset((a.dx + b.dx) / 2, a.dy));

        expect(g.menuItem('Copy'), findsOneWidget);
        expect(g.menuItem('Cut'), findsOneWidget);
        expect(g.menuItem('Paste'), offered ? findsOneWidget : findsNothing);
      }, variant: macOnly);
    }

    testWidgets(
      'the cross row right click Paste with a text only clipboard replaces the selection once and attaches nothing',
      (tester) async {
        final g = await wi147Pump(tester, body: body);
        await g.r.open();
        g.clipboard(text: _text);
        await g.select(10, 18);
        final a = g.caretPoint(16);
        final b = g.caretPoint(17);
        await g.rightClick(Offset((a.dx + b.dx) / 2, a.dy));
        g.r.bodyChanges.clear();

        await g.choosePaste();

        expect(g.body, 'Intro\n- al${_text}ta');
        expect(g.r.bodyChanges, ['Intro\n- al${_text}ta']);
        expect(g.attaches, 0);
      },
      variant: macOnly,
    );
  });

  group('the cross row menu gains Paste when the clipboard answers late (r4)', () {
    // Selection `al|pha` to `be|ta` over three rows; a right click on the
    // selected `b` of `beta` shows the cross-row menu.
    const body = 'Intro\n- alpha\n- beta';

    /// The point of that right click.
    Offset onSelection(Wi147Rig g) {
      final a = g.caretPoint(16);
      final b = g.caretPoint(17);
      return Offset((a.dx + b.dx) / 2, a.dy);
    }

    /// Opens the note, selects across rows and right clicks, then lets
    /// pasteOfferWait pass: the menu shows Copy and Cut, no Paste, while the
    /// clipboard read still waits.
    Future<Wi147Rig> shownWithoutPaste(
      WidgetTester tester,
      _Wi147HeldPasteboard held, {
      bool writable = true,
    }) async {
      final g = await wi147Pump(tester, body: body, pasteboardReader: held);
      await g.r.open();
      await g.setWritable(writable);
      await g.select(10, 18);
      await _rightClickNoWait(g, onSelection(g));
      expect(g.menuItem('Copy'), findsNothing, reason: 'within the wait');
      await tester.pump(pasteOfferWait);
      await pumpFrames(tester);
      expect(g.menuItem('Copy'), findsOneWidget);
      expect(g.menuItem('Cut'), findsOneWidget);
      expect(g.menuItem('Paste'), findsNothing, reason: 'the read is late');
      return g;
    }

    testWidgets(
      'a cross row menu shown without Paste gains Paste when the late read finds an image and its Paste attaches it',
      (tester) async {
        final png = fakePngBytes(12);
        final held = _Wi147HeldPasteboard(PasteboardContents(png: png));
        final g = await shownWithoutPaste(tester, held);

        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Paste'), findsOneWidget);
        expect(g.menuItem('Copy'), findsOneWidget);
        expect(g.menuItem('Cut'), findsOneWidget);
        await g.choosePaste();
        expect(g.attaches, 1);
        expect(g.r.attachments.addBytesCalls.single.bytes, png);
      },
      variant: macOnly,
    );

    testWidgets(
      'a cross row menu shown without Paste gains Paste when the late read finds file URLs',
      (tester) async {
        final held = _Wi147HeldPasteboard(
          PasteboardContents(files: [wi147PdfPath]),
        );
        final g = await shownWithoutPaste(tester, held);

        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Paste'), findsOneWidget);
        await g.choosePaste();
        expect(g.addedPaths, [wi147PdfPath]);
      },
      variant: macOnly,
    );

    testWidgets(
      'a cross row menu shown without Paste gains Paste when the late read finds text',
      (tester) async {
        final held = _Wi147HeldPasteboard(
          const PasteboardContents(hasText: true),
        );
        final g = await shownWithoutPaste(tester, held);

        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Paste'), findsOneWidget);
      },
      variant: macOnly,
    );

    testWidgets(
      'a cross row menu shown without Paste gains no Paste when the late read finds an image on a read only vault',
      (tester) async {
        final held = _Wi147HeldPasteboard(
          PasteboardContents(png: fakePngBytes()),
        );
        final g = await shownWithoutPaste(tester, held, writable: false);

        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Copy'), findsOneWidget, reason: 'the menu stays');
        expect(g.menuItem('Paste'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a cross row menu shown without Paste gains no Paste when the late read finds file URLs on a read only vault',
      (tester) async {
        final held = _Wi147HeldPasteboard(
          PasteboardContents(files: [wi147PdfPath]),
        );
        final g = await shownWithoutPaste(tester, held, writable: false);

        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Copy'), findsOneWidget, reason: 'the menu stays');
        expect(g.menuItem('Paste'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a cross row menu shown without Paste gains no Paste when the late read finds nothing',
      (tester) async {
        final held = _Wi147HeldPasteboard(const PasteboardContents());
        final g = await shownWithoutPaste(tester, held);

        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Copy'), findsOneWidget, reason: 'the menu stays');
        expect(g.menuItem('Paste'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a cross row menu gains no Paste after a new press even while its selection and menu stay',
      (tester) async {
        final held = _Wi147HeldPasteboard(
          PasteboardContents(png: fakePngBytes()),
        );
        final g = await shownWithoutPaste(tester, held);

        // A right button press with no release: a new press on the
        // selection, which keeps the selection and leaves the menu open.
        final mouse = await tester.startGesture(
          onSelection(g),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton,
        );
        await tester.pump();
        expect(g.menuItem('Copy'), findsOneWidget, reason: 'the menu stays');
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 10, extentOffset: 18),
          reason: 'the selection still spans rows',
        );
        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Copy'), findsOneWidget);
        expect(g.menuItem('Paste'), findsNothing);
        await mouse.cancel();
        await mouse.removePointer();
      },
      variant: macOnly,
    );

    testWidgets(
      'a cross row menu that was hidden gains no Paste while its selection still spans rows',
      (tester) async {
        final held = _Wi147HeldPasteboard(
          PasteboardContents(png: fakePngBytes()),
        );
        final g = await shownWithoutPaste(tester, held);

        // Another selection over the same rows hides the menu; no press.
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 9, extentOffset: 17));
        await tester.pump();
        expect(g.menuItem('Copy'), findsNothing, reason: 'the menu is hidden');
        held.open();
        await pumpFrames(tester);

        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection(baseOffset: 9, extentOffset: 17),
        );
        expect(g.menuItem('Copy'), findsNothing, reason: 'it stays hidden');
        expect(g.menuItem('Paste'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets('a cross row menu whose selection collapsed gains no Paste', (
      tester,
    ) async {
      final held = _Wi147HeldPasteboard(
        PasteboardContents(png: fakePngBytes()),
      );
      final g = await shownWithoutPaste(tester, held);

      segmentEditingAt(
        tester,
        0,
      ).select(const TextSelection.collapsed(offset: 12));
      await tester.pump();
      held.open();
      await pumpFrames(tester);

      expect(g.menuItem('Copy'), findsNothing);
      expect(g.menuItem('Paste'), findsNothing);
    }, variant: macOnly);

    testWidgets(
      'a late clipboard answer after the note closed shows nothing and throws nothing',
      (tester) async {
        final held = _Wi147HeldPasteboard(
          PasteboardContents(png: fakePngBytes()),
        );
        final g = await shownWithoutPaste(tester, held);

        await g.r.open(wi146OtherId);
        expect(find.text('Other body'), findsWidgets, reason: 'another note');
        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Copy'), findsNothing);
        expect(g.menuItem('Paste'), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: macOnly,
    );
  });

  group(
    'the text menu of a row without a field offers Paste while canPasteOrAttach (AC7, AC8)',
    () {
      // `showRowTextMenu` is the menu a right click on a row without a field
      // opens; it only needs the row's controller and focus node, so the real
      // app's focused row stands in for one.
      Future<Wi147Rig> pumpRow(
        WidgetTester tester, {
        required bool writable,
      }) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        await g.setWritable(writable);
        await g.r.caretAfter(_caret);
        return g;
      }

      Future<void> openMenu(Wi147Rig g) async {
        await showRowTextMenu(
          rowsHostOf(g.tester),
          0,
          anchor: const Offset(300, 300),
        );
        await pumpFrames(g.tester);
      }

      testWidgets(
        'the text menu of a row without a field offers Paste for an image only and its Paste attaches the image once',
        (tester) async {
          final g = await pumpRow(tester, writable: true);
          g.clipboard(png: _png());

          await openMenu(g);
          await g.choosePaste();

          expect(g.addedNames, [wi147PastedName(g.r.h.clock.now())]);
          expect(g.r.attachments.addCalls, isEmpty);
          expect(g.body, _plainAfter(wi146Line(g.addedNames.single)));
        },
        variant: macOnly,
      );

      testWidgets(
        'the text menu of a row without a field offers Paste for file URLs with the Finder name text and its Paste gives 1 attach and 0 text pastes',
        (tester) async {
          final g = await pumpRow(tester, writable: true);
          g.clipboard(files: const [wi147PdfPath], text: _finderText);

          await openMenu(g);
          await g.choosePaste();

          expect(g.addedPaths, [wi147PdfPath]);
          expect(g.body, _plainAfter(_s), reason: 'no Finder name text');
        },
        variant: macOnly,
      );

      testWidgets(
        'the text menu of a row without a field offers Paste for text only and its Paste pastes the text once',
        (tester) async {
          final g = await pumpRow(tester, writable: true);
          g.clipboard(text: _text);

          await openMenu(g);
          await g.choosePaste();

          expect(g.body, _plainAfter(''));
          expect(g.attaches, 0);
        },
        variant: macOnly,
      );

      testWidgets(
        'the text menu of a row without a field offers no Paste for an empty clipboard',
        (tester) async {
          final g = await pumpRow(tester, writable: true);
          g.clipboard();

          await openMenu(g);

          expect(g.menuItem('Paste'), findsNothing);
          expect(g.pasteboard.reads, greaterThan(0), reason: 'asked');
        },
        variant: macOnly,
      );

      testWidgets(
        'the text menu of a row without a field still shows Copy and Cut but no Paste when the clipboard never answers',
        (tester) async {
          // Never opened: the read of the clipboard never answers.
          final held = _Wi147HeldPasteboard(
            const PasteboardContents(hasText: true),
          );
          final g = await wi147Pump(tester, pasteboardReader: held);
          await g.r.open();
          await g.r.caretAfter(_caret);
          segmentEditingAt(
            tester,
            0,
          ).select(const TextSelection(baseOffset: 0, extentOffset: 6));
          await tester.pump();

          // Not awaited: the menu waits for fake time, which only a pump moves.
          final shown = showRowTextMenu(
            rowsHostOf(g.tester),
            0,
            anchor: const Offset(300, 300),
          );
          await tester.pump(pasteOfferWait);
          await shown;
          await pumpFrames(tester);

          expect(g.menuItem('Copy'), findsOneWidget);
          expect(g.menuItem('Cut'), findsOneWidget);
          expect(g.menuItem('Paste'), findsNothing);
        },
        variant: macOnly,
      );

      for (final (name, put) in <(String, void Function(Wi147Rig))>[
        (
          'the text menu of a row without a field offers no Paste for an image only on a read only vault',
          (g) => g.clipboard(png: _png()),
        ),
        (
          'the text menu of a row without a field offers no Paste for file URLs only on a read only vault',
          (g) => g.clipboard(files: const [wi147PdfPath]),
        ),
      ]) {
        testWidgets(name, (tester) async {
          final g = await pumpRow(tester, writable: false);
          put(g);

          await openMenu(g);

          expect(g.menuItem('Paste'), findsNothing);
          expect(g.attaches, 0);
        }, variant: macOnly);
      }

      testWidgets(
        'the text menu of a row without a field offers Paste for text on a read only vault',
        (tester) async {
          final g = await pumpRow(tester, writable: false);
          g.clipboard(text: _text);

          await openMenu(g);
          await g.choosePaste();

          expect(g.body, _plainAfter(''));
        },
        variant: macOnly,
      );
    },
  );

  group(
    'the text menu of a row without a field gains Paste when the clipboard answers late (r5)',
    () {
      // `showRowTextMenu` is what a right click on a row without a field
      // opens. Row 0 holds `_caret`; its first six characters are selected,
      // so the menu shows Copy and Cut.
      const first = Offset(300, 300);
      const second = Offset(520, 420);

      Future<Wi147Rig> pumpHeld(
        WidgetTester tester,
        _Wi147HeldPasteboard held, {
        bool writable = true,
      }) async {
        final g = await wi147Pump(tester, pasteboardReader: held);
        await g.r.open();
        await g.setWritable(writable);
        await g.r.caretAfter(_caret);
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection(baseOffset: 0, extentOffset: 6));
        await tester.pump();
        return g;
      }

      /// Asks for the menu without awaiting it (it waits for fake time, which
      /// only a pump moves) and lets pasteOfferWait pass: Copy and Cut show,
      /// no Paste, while the clipboard read still waits.
      Future<void> showWithoutPaste(Wi147Rig g, Offset anchor) async {
        final shown = showRowTextMenu(rowsHostOf(g.tester), 0, anchor: anchor);
        await g.tester.pump(pasteOfferWait);
        await shown;
        await pumpFrames(g.tester);
        expect(g.menuItem('Copy'), findsOneWidget);
        expect(g.menuItem('Cut'), findsOneWidget);
        expect(g.menuItem('Paste'), findsNothing, reason: 'the read is late');
      }

      testWidgets(
        'a row menu shown without Paste gains Paste when the late read finds an image with no second read and its Paste attaches the image once',
        (tester) async {
          final png = fakePngBytes(12);
          final held = _Wi147HeldPasteboard(PasteboardContents(png: png));
          final g = await pumpHeld(tester, held);
          await showWithoutPaste(g, first);

          held.open();
          await pumpFrames(tester);

          expect(g.menuItem('Paste'), findsOneWidget);
          expect(g.menuItem('Copy'), findsOneWidget);
          expect(g.menuItem('Cut'), findsOneWidget);
          expect(held.reads, 1, reason: 'the menu shows again without a read');
          await g.choosePaste();
          expect(g.attaches, 1);
          expect(g.r.attachments.addBytesCalls.single.bytes, png);
        },
        variant: macOnly,
      );

      testWidgets(
        'a row menu shown without Paste gains Paste when the late read finds file URLs with no second read',
        (tester) async {
          final held = _Wi147HeldPasteboard(
            PasteboardContents(files: [wi147PdfPath]),
          );
          final g = await pumpHeld(tester, held);
          await showWithoutPaste(g, first);

          held.open();
          await pumpFrames(tester);

          expect(g.menuItem('Paste'), findsOneWidget);
          expect(held.reads, 1);
          await g.choosePaste();
          expect(g.addedPaths, [wi147PdfPath]);
        },
        variant: macOnly,
      );

      for (final (name, contents) in <(String, PasteboardContents)>[
        (
          'a row menu shown without Paste gains no Paste when the late read finds an image on a read only vault',
          PasteboardContents(png: fakePngBytes()),
        ),
        (
          'a row menu shown without Paste gains no Paste when the late read finds file URLs on a read only vault',
          PasteboardContents(files: [wi147PdfPath]),
        ),
      ]) {
        testWidgets(name, (tester) async {
          final held = _Wi147HeldPasteboard(contents);
          final g = await pumpHeld(tester, held, writable: false);
          await showWithoutPaste(g, first);

          held.open();
          await pumpFrames(tester);

          expect(g.menuItem('Copy'), findsOneWidget, reason: 'the menu stays');
          expect(g.menuItem('Paste'), findsNothing);
          expect(g.attaches, 0);
        }, variant: macOnly);
      }

      testWidgets(
        'a row menu shown without Paste gains no Paste when the late read finds nothing',
        (tester) async {
          final held = _Wi147HeldPasteboard(const PasteboardContents());
          final g = await pumpHeld(tester, held);
          await showWithoutPaste(g, first);

          held.open();
          await pumpFrames(tester);

          expect(g.menuItem('Copy'), findsOneWidget, reason: 'the menu stays');
          expect(g.menuItem('Paste'), findsNothing);
        },
        variant: macOnly,
      );

      testWidgets(
        'a late read of an older row menu call does not move the menu of a newer call',
        (tester) async {
          final held = _Wi147HeldPasteboard(
            PasteboardContents(png: fakePngBytes()),
          );
          final g = await pumpHeld(tester, held);
          await showWithoutPaste(g, first);
          // A newer call shows its own menu at another point while the first
          // call's read still waits.
          await showWithoutPaste(g, second);
          final at = tester.getTopLeft(g.menuItem('Copy'));

          held.open();
          await pumpFrames(tester);

          expect(g.menuItem('Paste'), findsOneWidget);
          expect(
            tester.getTopLeft(g.menuItem('Copy')),
            at,
            reason: 'the newer call keeps the menu where it put it',
          );
          expect(held.reads, 2, reason: 'one read per call, none per re-show');
        },
        variant: macOnly,
      );

      testWidgets(
        'a row menu that was hidden gains no Paste when the late read finds an image',
        (tester) async {
          final held = _Wi147HeldPasteboard(
            PasteboardContents(png: fakePngBytes()),
          );
          final g = await pumpHeld(tester, held);
          await showWithoutPaste(g, first);

          hideRowTextMenu();
          await tester.pump();
          expect(g.menuItem('Copy'), findsNothing, reason: 'it is hidden');
          held.open();
          await pumpFrames(tester);

          expect(g.menuItem('Copy'), findsNothing, reason: 'it stays hidden');
          expect(g.menuItem('Paste'), findsNothing);
        },
        variant: macOnly,
      );

      testWidgets(
        'a row menu closed by a change of the segment text gains no Paste when the late read finds an image',
        (tester) async {
          final held = _Wi147HeldPasteboard(
            PasteboardContents(png: fakePngBytes()),
          );
          final g = await pumpHeld(tester, held);
          await showWithoutPaste(g, first);

          segmentEditingAt(tester, 0).replaceText('changed');
          await pumpFrames(tester);
          expect(g.menuItem('Copy'), findsNothing, reason: 'it is closed');
          held.open();
          await pumpFrames(tester);

          expect(g.menuItem('Copy'), findsNothing, reason: 'it stays closed');
          expect(g.menuItem('Paste'), findsNothing);
        },
        variant: macOnly,
      );

      testWidgets(
        'a late clipboard answer for a row menu after the note closed shows nothing and throws nothing',
        (tester) async {
          final held = _Wi147HeldPasteboard(
            PasteboardContents(png: fakePngBytes()),
          );
          final g = await pumpHeld(tester, held);
          await showWithoutPaste(g, first);

          await g.r.open(wi146OtherId);
          expect(find.text('Other body'), findsWidgets, reason: 'another note');
          // The menu of the closed note is left as it was (it is not this
          // change's to close); what the late answer must not do is add Paste.
          final before = g.menuItem('Copy').evaluate().length;
          held.open();
          await pumpFrames(tester);

          expect(g.menuItem('Copy').evaluate().length, before);
          expect(g.menuItem('Paste'), findsNothing);
          expect(tester.takeException(), isNull);
        },
        variant: macOnly,
      );
    },
  );

  group('the right click take over guards (Q3, D23)', () {
    testWidgets(
      'a right click on an attachment block while a text row has focus shows no Paste menu for an image clipboard while a right click on the focused row does',
      (tester) async {
        final vault = Wi147VaultAttachments();
        final path = testAttachmentPath(147010, 'mock.png');
        vault.putFile(path, testPngBytes(40, 20));
        final g = await wi147Pump(
          tester,
          attachments: vault,
          body: 'Review the draft\n![mock.png]($path)\nNext steps',
        );
        await g.r.open();
        await g.r.caretAfter(_caret);
        g.clipboard(png: _png());
        final host = rowsHostOf(tester);
        var block = -1;
        for (var i = 0; i < host.rowCount; i++) {
          if (host.rowSpec(i)!.kind == RowKind.attachment) block = i;
        }
        expect(block, isNonNegative, reason: 'the note has an attachment row');
        final card = find.byKey(ValueKey('editor-attachment-0-$block'));
        expect(card, findsOneWidget);
        final focused = g.focusedField();

        await g.rightClick(tester.getCenter(card));

        expect(g.menuItem('Paste'), findsNothing, reason: 'no menu there');
        expect(g.focusedField(), same(focused), reason: 'focus stayed');
        expect(g.attaches, 0);

        // The same clipboard on the focused row's own text does show it.
        await g.rightClickAtCaret();
        expect(g.menuItem('Paste'), findsOneWidget);
      },
      variant: macOnly,
    );

    testWidgets(
      'an image right click over a caret lists Paste and neither Cut nor Copy',
      (tester) async {
        final g = await wi147Pump(tester);
        await g.r.open();
        g.clipboard(png: _png());
        await g.r.caretAfter(_caret);

        await g.rightClickAtCaret();

        expect(g.menuItem('Paste'), findsOneWidget);
        expect(g.menuItem('Cut'), findsNothing);
        expect(g.menuItem('Copy'), findsNothing);
      },
      variant: macOnly,
    );

    testWidgets(
      'a press while the Source right click still waits for the clipboard cancels its take over menu',
      (tester) async {
        final held = _Wi147HeldPasteboard(PasteboardContents(png: _png()));
        final g = await wi147Pump(tester, pasteboardReader: held);
        await g.r.open();
        await g.r.sourceCaret(_caret.length);
        final field = g.focusedField();
        final rect = field.renderEditable.getLocalRectForCaret(
          const TextPosition(offset: 2),
        );
        final inField = field.renderEditable.localToGlobal(
          Offset(rect.left, rect.center.dy),
        );

        await g.rightClickAtCaret();
        expect(g.menuItem('Paste'), findsNothing, reason: 'still waiting');
        await tester.tapAt(inField, kind: PointerDeviceKind.mouse);
        await pumpFrames(tester);
        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Paste'), findsNothing, reason: 'cancelled');
        expect(g.attaches, 0);
      },
      variant: macOnly,
    );

    testWidgets(
      'a Source right click waiting for the clipboard shows its take over menu once the clipboard answers',
      (tester) async {
        final held = _Wi147HeldPasteboard(PasteboardContents(png: _png()));
        final g = await wi147Pump(tester, pasteboardReader: held);
        await g.r.open();
        await g.r.sourceCaret(_caret.length);

        await g.rightClickAtCaret();
        expect(g.menuItem('Paste'), findsNothing, reason: 'still waiting');
        held.open();
        await pumpFrames(tester);

        expect(g.menuItem('Paste'), findsOneWidget);
      },
      variant: macOnly,
    );

    testWidgets(
      'in Source mode a right click on a flagged word with an image clipboard shows the spelling menu and its Paste gives 1 attach',
      (tester) async {
        final g = await wi147Pump(
          tester,
          body: 'Good teh day.\nNext steps',
          spelling: FakeSpellingService()
            ..misspell('teh', corrections: const ['the'])
            ..scriptGuesses('teh', const ['the']),
        );
        await g.r.open();
        await g.settleSpelling();
        final png = _png();
        g.clipboard(png: png);
        await g.r.sourceCaret(6);
        await g.settleSpelling();

        await g.rightClickAtCaret();

        expect(find.byType(SpellingMenu), findsOneWidget, reason: 'spelling');
        await g.choosePaste();
        expect(g.addedNames, [wi147PastedName(g.r.h.clock.now())]);
        expect(g.r.attachments.addBytesCalls.single.bytes, png);
        expect(g.attaches, 1);
        expect(
          g.body,
          'Good teh day.\n\n${wi146Line(g.addedNames.single)}\n\nNext steps',
        );
      },
      variant: macOnly,
    );
  });
}
