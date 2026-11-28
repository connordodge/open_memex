// WI #147 (Spec #123 A2: R7, R8, R11; rulings D11, D12, D17): the drop and
// paste test harness, shared by #147's drop target, paste routing and
// journey tests. Owned by #147.
//
// It pumps the whole app (`pumpWorkspace`) as #146's harness does
// (`seedSegmentedVault` plus `Planning notes` and a second plain note), with:
// - A1's seams faked: `attachmentDropSourceProvider` a
//   `FakeAttachmentDropSource`, `pasteboardReaderProvider` a
//   `FakePasteboardReader`, and Flutter's plain-text clipboard a
//   `MacClipboard` (what a field's own paste reads);
// - `attachmentsProvider` and the vault access's attachments domain both on
//   one `Wi146HeldAttachments` (or a [Wi147VaultAttachments], whose files
//   lie on disk so #143's image rows and file cards can show them);
// - `vaultAccessProvider` a `LocalVaultAccess` whose CLI follows
//   `wi146WritableProvider` (`VaultAccess.canWrite`);
// - optionally a `FakeSpellingService`, for the spelling menu's Paste.
//
// Drops are fired through the fake seam at a global point converted to the
// drop target's local frame: the seam reports positions relative to the
// `AttachmentDropTarget` box.
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_exit.dart' show appWindowChannel;
import 'package:open_memex_app/src/state/attachment_drop_source.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/learned_words_seam.dart';
import 'package:open_memex_app/src/state/pasteboard_reader.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/attachments_access.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/command_palette/command_palette.dart'
    show paletteShellOverrides;
import 'package:open_memex_app/src/widgets/editor/attachment_drop_target.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/source_surface.dart'
    show sourceFieldLineBoxes;
import 'package:open_memex_app/src/widgets/find/find_keys.dart';

import '../robots/segmented_editor_robot.dart';
import 'app_harness.dart';
import 'attachment_input_fakes.dart';
import 'editor_rows_probe.dart';
import 'fake_clock.dart';
import 'fake_spelling_service.dart';
import 'file_picker_fakes.dart';
import 'mac_editing.dart';
import 'segment_editing_finder.dart';
import 'wi146_attach_harness.dart';

/// The fake clock's time in every #147 test: a pasted image is named
/// `Pasted image 2026-11-18 14.03.22.png` (R9).
DateTime get wi147Now => DateTime(2026, 11, 18, 14, 3, 22);

/// The R9 name of an image pasted at local time [t].
String wi147PastedName(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'Pasted image ${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}.${two(t.minute)}.${two(t.second)}.png';
}

/// Invented absolute paths of dropped or copied files.
const wi147PngPath = '/vaults/My Vault/Inbox/mock.png';
const wi147PdfPath = '/vaults/My Vault/Inbox/spec.pdf';

/// How often [needle] occurs in [haystack].
int wi147Count(String haystack, String needle) =>
    needle.allMatches(haystack).length;

/// A `Wi146HeldAttachments` whose vault is a fresh temporary folder (deleted
/// when the test ends): [putFile] writes a file there, and `read` / `info`
/// answer from what was written, so #143's rows probe real files (D7).
class Wi147VaultAttachments extends Wi146HeldAttachments {
  Wi147VaultAttachments() : _dir = Directory.systemTemp.createTempSync('w147') {
    addTearDown(() {
      if (_dir.existsSync()) _dir.deleteSync(recursive: true);
    });
  }

  final Directory _dir;

  @override
  String get vaultPath => _dir.path;

  /// The bytes of each file [putFile] wrote, by vault-relative path.
  final Map<String, Uint8List> files = {};

  /// Writes [bytes] at the vault-relative [path].
  void putFile(String path, Uint8List bytes) {
    final file = File('$vaultPath/$path');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    files[path] = bytes;
  }

  @override
  Future<AttachmentReadResult> read(String path) async {
    readCalls.add(path);
    final bytes = files[path];
    return bytes == null
        ? const AttachmentReadFailed(AttachmentLookupFailure.missing)
        : AttachmentBytes(bytes);
  }

  @override
  Future<AttachmentInfoResult> info(String path) async {
    infoCalls.add(path);
    final bytes = files[path];
    return bytes == null
        ? const AttachmentInfoFailed(AttachmentLookupFailure.missing)
        : AttachmentInfoFound(
            AttachmentInfo(size: bytes.length, type: 'application/pdf'),
          );
  }
}

/// Everything a #147 test needs.
class Wi147Rig {
  Wi147Rig(this.r, this.drop, this.pasteboard, this.clip);

  /// #146's harness over the same app (editor, domain, canWrite, palette).
  final Wi146Harness r;
  final FakeAttachmentDropSource drop;
  final FakePasteboardReader pasteboard;
  final MacClipboard clip;

  WidgetTester get tester => r.tester;

  /// The editor's whole markdown.
  String get body => r.body;

  /// Every `add` path the domain received, in order.
  List<String> get addedPaths => [
    for (final c in r.attachments.addCalls) c.filePath,
  ];

  /// Every `addBytes` name the domain received, in order.
  List<String> get addedNames => [
    for (final c in r.attachments.addBytesCalls) c.name,
  ];

  /// Attaches of either kind.
  int get attaches =>
      r.attachments.addCalls.length + r.attachments.addBytesCalls.length;

  /// Sets the vault's `VaultAccess.canWrite`.
  Future<void> setWritable(bool writable) async {
    r.h.read(wi146WritableProvider.notifier).state = writable;
    await pumpFrames(tester);
  }

  // ------------------------------------------------------------ clipboard

  /// What the clipboard holds: [files] (file URLs), [text] (plain text) and
  /// [png] (an image). As on macOS, the native reader sends no image while
  /// text is present; Flutter's own clipboard holds [text] alone.
  void clipboard({
    List<String> files = const [],
    String? text,
    Uint8List? png,
  }) {
    pasteboard.contents = PasteboardContents(
      files: files,
      hasText: text != null,
      png: text == null ? png : null,
    );
    clip.text = text;
  }

  // ------------------------------------------------------------ drop

  /// The editor's drop target.
  Finder get target => find.byType(AttachmentDropTarget);

  /// The drop target's global rect.
  Rect targetRect() {
    expect(
      target,
      findsOneWidget,
      reason: 'the note editor body is wrapped in its drop target',
    );
    return tester.getRect(target);
  }

  /// Global [at] in the drop target's local frame.
  Offset local(Offset at) => at - targetRect().topLeft;

  /// A file drag enters the editor at global [at] and moves there.
  Future<void> dragOver(Offset at) async {
    final p = local(at);
    drop.enter(p);
    await tester.pump();
    drop.update(p);
    await tester.pump();
  }

  /// [paths] are dragged to global [at] and dropped there; the action runs
  /// to its end.
  Future<void> dropAt(Offset at, List<String> paths) async {
    await dragOver(at);
    drop.drop(paths, localPosition: local(at));
    await tester.pump();
    await r.releaseAll();
  }

  /// A global point on markdown line [line] of live preview text segment
  /// [segment] (counted in the segment's text): just right of the line's
  /// start, at its first visual line's centre. Consecutive prose lines share
  /// one editor row, so this goes by text offset, not by row.
  Offset lineCenter(int line, {int segment = 0}) {
    final handle = segmentEditingAt(tester, segment);
    final text = handle.text;
    var start = 0;
    for (var i = 0; i < line; i++) {
      final next = text.indexOf('\n', start);
      if (next < 0) {
        throw TestFailure('text segment $segment has no line $line');
      }
      start = next + 1;
    }
    final rect = handle.rectForOffset(start);
    return Offset(rect.left + 3, rect.center.dy);
  }

  /// The global centre of Source mode's body line [line] (a visual line of
  /// the field, which for short lines is the markdown line).
  Offset sourceLineCenter(int line) {
    final LineBoxSource boxes =
        sourceFieldLineBoxes(tester.renderObject(r.robot.sourceBody)) ??
        (throw TestFailure('the Source field is not laid out'));
    final box = boxes.lines[line];
    final mid = Offset(boxes.box.size.width / 2, (box.top + box.bottom) / 2);
    return boxes.box.localToGlobal(mid);
  }

  /// A point inside the drop target, [above] px over its bottom edge,
  /// horizontally at its centre: below every line of a short note.
  Offset belowLastLine({double above = 12}) {
    final rect = targetRect();
    return Offset(rect.center.dx, rect.bottom - above);
  }

  /// The global centre of the note header (Key `note-header`).
  Offset headerCenter() {
    final header = find.byKey(const Key('note-header'));
    expect(header, findsOneWidget);
    return tester.getCenter(header);
  }

  // ------------------------------------------------------------ paste

  /// Cmd+V in the focused field, then lets any action end.
  Future<void> cmdV() async {
    await tester.macCmdChord(LogicalKeyboardKey.keyV);
    await pumpFrames(tester);
    await r.releaseAll();
  }

  /// The global point of the live preview caret at segment [offset] (its
  /// left edge, line centre): a right click there keeps a collapsed
  /// selection on macOS.
  Offset caretPoint(int offset, {int segment = 0}) {
    final rect = segmentEditingAt(tester, segment).rectForOffset(offset);
    return Offset(rect.left, rect.center.dy);
  }

  /// The focused text field (a live preview row, Source mode's body).
  EditableTextState focusedField() {
    final context = FocusManager.instance.primaryFocus?.context;
    final state =
        context is StatefulElement && context.state is EditableTextState
        ? context.state as EditableTextState
        : context?.findAncestorStateOfType<EditableTextState>();
    return state ?? (throw TestFailure('no text field has focus'));
  }

  /// A right click exactly at the focused field's caret, as a person does
  /// after clicking there: the platform first reports that click's caret
  /// (a caret set only through the editor's handle has no selection overlay
  /// yet, so the field would show no menu), then the right click lands on
  /// the caret, which keeps it collapsed on macOS.
  Future<void> rightClickAtCaret() async {
    final field = focusedField();
    final value = field.textEditingValue;
    final caret = value.selection.extentOffset;
    tester.testTextInput.updateEditingValue(
      value.copyWith(
        selection: TextSelection.collapsed(offset: caret == 0 ? 1 : 0),
      ),
    );
    await tester.pump();
    tester.testTextInput.updateEditingValue(value);
    await tester.pump();
    final editable = field.renderEditable;
    final rect = editable.getLocalRectForCaret(TextPosition(offset: caret));
    await rightClick(editable.localToGlobal(Offset(rect.left, rect.center.dy)));
  }

  /// A right click (secondary mouse button) at global [at]; the mouse is
  /// removed afterwards.
  Future<void> rightClick(Offset at) async {
    final mouse = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump();
    await mouse.up();
    await tester.pump();
    await mouse.removePointer();
    await pumpFrames(tester);
  }

  /// A context-menu item labelled [label] (any menu: the field's own, the
  /// cross-row menu, SpellingMenu).
  Finder menuItem(String label) => find.byWidgetPredicate(
    (w) =>
        w is Text &&
        (w.data ?? w.textSpan?.toPlainText() ?? '').toLowerCase() ==
            label.toLowerCase(),
    description: 'menu item "$label"',
  );

  /// Taps the menu's Paste item and lets any action end.
  Future<void> choosePaste() async {
    expect(menuItem('Paste'), findsOneWidget, reason: 'Paste is offered');
    await tester.tap(menuItem('Paste'));
    await pumpFrames(tester);
    await r.releaseAll();
  }

  /// Selects segment offsets [base]..[extent] of text segment 0 (a
  /// selection that may span rows), with focus in the row holding
  /// [extent].
  Future<void> select(int base, int extent) async {
    final host = rowsHostOf(tester);
    var row = -1;
    for (var i = 0; i < host.rowCount; i++) {
      final spec = host.rowSpec(i)!;
      if (extent >= spec.textStart && extent <= spec.textEnd) row = i;
    }
    expect(row, isNonNegative, reason: 'a row holds offset $extent');
    await activateRow(
      tester,
      0,
      row,
      offset: extent - host.rowSpec(row)!.textStart,
    );
    final selection = TextSelection(baseOffset: base, extentOffset: extent);
    segmentEditingAt(tester, 0).select(selection);
    await tester.pump();
    expect(segmentEditingAt(tester, 0).selection, selection);
    expect(segmentEditingAt(tester, 0).focusedRow, row);
  }

  /// Plays the native `find show` call: the Find bar opens with focus in
  /// its query field.
  Future<void> openFindBar() async {
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      appWindowChannel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('find', 'show')),
      (_) {},
    );
    await pumpFrames(tester);
    expect(find.byKey(findBarKey), findsOneWidget, reason: 'Find bar open');
  }

  /// Lets the fake spelling checks of the open note come back.
  Future<void> settleSpelling() async {
    for (var i = 0; i < 2; i++) {
      r.h.clock.advance(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await pumpFrames(tester);
    }
  }
}

/// Pumps the app as `wi146Pump` does, with A1's seams faked. [attachments]
/// defaults to a fresh `Wi146HeldAttachments`; [spelling], when given, is
/// `spellingServiceProvider`. Opens nothing; call `r.open`.
Future<Wi147Rig> wi147Pump(
  WidgetTester tester, {
  String body = wi146Example,
  String? topicBody,
  Wi146HeldAttachments? attachments,
  FakeSpellingService? spelling,
  FakePasteboardReader? pasteboardReader,
}) async {
  final clip = MacClipboard.install(tester);
  final vault = topicBody == null
      ? seedSegmentedVault()
      : seedSegmentedVault(topicBody: topicBody);
  vault.db.seedNote(id: wi146NoteId, title: wi146NoteTitle, content: body);
  vault.db.seedNote(
    id: wi146OtherId,
    title: 'Other plans',
    content: wi146OtherBody,
  );
  final domain = attachments ?? Wi146HeldAttachments();
  final picker = installFakeFilePicker();
  final drop = FakeAttachmentDropSource();
  final pasteboard = pasteboardReader ?? FakePasteboardReader();
  final h = await pumpWorkspace(
    tester,
    db: vault.db,
    cli: vault.cli,
    clock: FakeClock(wi147Now),
    overrides: [
      attachmentsProvider.overrideWithValue(domain),
      attachmentDropSourceProvider.overrideWithValue(drop),
      pasteboardReaderProvider.overrideWithValue(pasteboard),
      if (spelling != null) ...[
        spellingServiceProvider.overrideWithValue(spelling),
        learnedWordKeysProvider.overrideWithValue(const <String>{}),
      ],
      vaultAccessProvider.overrideWith((ref) {
        final path = ref.watch(currentVaultProvider).localPath;
        if (path == null) return null;
        return LocalVaultAccess(
          vaultPath: path,
          db: ref.watch(vaultDbProvider),
          cli: ref.watch(wi146WritableProvider)
              ? ref.watch(memexCliProvider)
              : null,
          attachments: domain,
        );
      }),
      ...paletteShellOverrides,
    ],
  );
  final r = Wi146Harness(
    tester,
    h,
    SegmentedEditorRobot(tester, h),
    domain,
    picker,
  );
  h.container.listen<String>(
    editorControllerProvider.select((s) => s.contentMd),
    (_, next) => r.bodyChanges.add(next),
  );
  return Wi147Rig(r, drop, pasteboard, clip);
}
