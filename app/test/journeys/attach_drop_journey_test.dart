// WI #147 (Spec #123 A2, Testing Strategy robot journey; V3 rows from
// #143): open a note, drop a PNG and a PDF from Finder on its first line,
// see both lines appear separated by blank lines, see #143's image row and
// file card show them, then undo with Cmd+Z while the vault keeps both
// files.
//
// Stable Keys only: the editor's `text-segment-<i>` (read through its
// handle and `editor_rows_probe.dart`), #143's blocks
// `editor-attachment-<segment>-<row>` (D6) and the note header. The drop
// goes through A1's fake drop seam; the files are stored by a fake domain
// (`Wi147VaultAttachments`) whose vault folder holds them on disk, so #143's
// rows probe them as they would a real vault's.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/vault_access/attachments_access.dart';
import 'package:open_memex_app/src/widgets/editor/attachment_row.dart';

import '../support/app_harness.dart' show pumpFrames;
import '../support/attachments_fakes.dart';
import '../support/editor_rows_probe.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';
import '../support/wi146_attach_harness.dart';
import '../support/wi147_drop_paste_harness.dart';

/// One stored attachment: its vault path and reference line.
typedef _Stored = ({String path, String line});

/// The domain stores [name] (bytes [bytes]) at a content path and answers
/// [markdown]'s form: an image reference for the PNG, a link for the PDF.
_Stored _store(
  Wi147VaultAttachments vault,
  int n,
  String name,
  Uint8List bytes, {
  required bool image,
}) {
  final path = 'objects/5e/${testAttachmentHash(n)}/$name';
  vault.putFile(path, bytes);
  final line = '${image ? '!' : ''}[$name]($path)';
  vault.addResults.add(
    AttachmentAdded(
      AddedAttachment(
        markdown: line,
        path: path,
        name: name,
        size: bytes.length,
        type: image ? 'image/png' : 'application/pdf',
      ),
    ),
  );
  return (path: path, line: line);
}

/// The drop journey's robot: one method per step a person takes.
class _Wi147DropRobot {
  _Wi147DropRobot(this.g);

  final Wi147Rig g;
  WidgetTester get tester => g.tester;

  Future<void> openNote() async {
    await g.r.open();
    expect(g.r.robot.textSegment(0), findsOneWidget);
  }

  /// Drags [paths] from Finder over the note's line [row] and drops them.
  Future<void> dropOnLine(int row, List<String> paths) =>
      g.dropAt(g.lineCenter(row), paths);

  /// The body text the editor shows.
  String get bodyText => editorBodyText(tester);

  /// The index of the attachment row of the first text segment whose line
  /// names [name] (consecutive prose lines share a row, so rows are found
  /// by kind and text, not by line).
  int attachmentRow(String name) {
    final host = rowsHostOf(tester);
    for (var i = 0; i < host.rowCount; i++) {
      final spec = host.rowSpec(i)!;
      if (spec.kind == RowKind.attachment &&
          host.text.substring(spec.textStart, spec.textEnd).contains(name)) {
        return i;
      }
    }
    throw TestFailure('no attachment row names $name');
  }

  /// #143's block of editor row [row] of the first text segment.
  Finder block(int row) => find.byKey(ValueKey('editor-attachment-0-$row'));

  Future<void> undo() async {
    rowsHostOf(tester).widget.focusNode.requestFocus();
    await tester.pump(const Duration(seconds: 1));
    await tester.macCmdChord(LogicalKeyboardKey.keyZ);
    await pumpFrames(tester);
  }
}

void main() {
  holdFontFetches();

  testWidgets(
    'drop a PNG and a PDF on a note line then both lines appear separated by blank lines with the image row and file card and Cmd Z removes both while the files stay stored',
    (tester) async {
      final vault = Wi147VaultAttachments();
      final png = _store(
        vault,
        147001,
        'mock.png',
        testPngBytes(40, 20),
        image: true,
      );
      final pdf = _store(
        vault,
        147002,
        'spec.pdf',
        Uint8List.fromList('%PDF-1.4 wi147'.codeUnits),
        image: false,
      );
      final g = await wi147Pump(tester, attachments: vault);
      final robot = _Wi147DropRobot(g);

      await robot.openNote();
      expect(robot.bodyText, wi146Example);

      await robot.dropOnLine(0, const [wi147PngPath, wi147PdfPath]);

      expect(g.addedPaths, [wi147PngPath, wi147PdfPath], reason: 'drop order');
      final after =
          'Review the draft\n\n${png.line}\n${pdf.line}\n\nNext steps';
      expect(
        robot.bodyText,
        after,
        reason: 'two lines, in drop order, with a blank line on each side',
      );
      expect(g.body, after, reason: 'the note body holds them');

      // V3 (#143): the PNG shows as an image row, the PDF as a file card.
      final imageRow = robot.attachmentRow('mock.png');
      final fileRow = robot.attachmentRow('spec.pdf');
      expect(fileRow, imageRow + 1, reason: 'one row each, in drop order');
      expect(
        find.descendant(
          of: robot.block(imageRow),
          matching: find.byType(AttachmentImageBox),
        ),
        findsOneWidget,
        reason: 'the image row shows',
      );
      final card = find.descendant(
        of: robot.block(fileRow),
        matching: find.byType(AttachmentFileCard),
      );
      expect(card, findsOneWidget, reason: 'the file card shows');
      expect(tester.widget<AttachmentFileCard>(card).name, 'spec.pdf');
      expect(tester.widget<AttachmentFileCard>(card).missing, isFalse);

      await robot.undo();
      expect(robot.bodyText, wi146Example, reason: 'one Cmd+Z removes both');
      expect(g.body, wi146Example);
      expect(robot.block(imageRow), findsNothing);
      expect(robot.block(fileRow), findsNothing);
      expect(
        find.byType(AttachmentBlock),
        findsNothing,
        reason: 'no attachment row is left',
      );

      // The vault still holds both files: nothing removed them.
      for (final stored in [png, pdf]) {
        expect(vault.files, contains(stored.path));
        expect(File('${vault.vaultPath}/${stored.path}').existsSync(), isTrue);
      }
      expect(g.addedPaths, [wi147PngPath, wi147PdfPath]);
      expect(vault.openCalls, isEmpty);
      expect(vault.revealCalls, isEmpty);
    },
    variant: macOnly,
  );
}
