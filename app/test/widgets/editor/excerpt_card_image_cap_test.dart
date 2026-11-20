// WI #144 (Spec #123 V4, R39): the excerpt card's 240 px image cap reaches
// V3's shared image box. Kept apart from excerpt_card_attachments_test.dart so
// that file still compiles against the red-mode skeleton (`maxHeight` is new).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/editor/attachment_row.dart';

void main() {
  // -------------------------------------------------------------------------
  // The shared builders' height cap (R39): the card's 240 reaches the image
  // box, its intrinsics and a relayout on a change
  // -------------------------------------------------------------------------
  group('image box height cap (AC1)', () {
    Future<void> pumpBox(
      WidgetTester tester, {
      required double maxHeight,
      Size natural = const Size(300, 600),
    }) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: AttachmentImageBox(natural: natural, maxHeight: maxHeight),
          ),
        ),
      ),
    );

    testWidgets(
      'an image box and its intrinsic sizes honour a given height cap and relayout when it changes',
      (tester) async {
        await pumpBox(tester, maxHeight: 240);
        final box = tester.renderObject<RenderBox>(
          find.byType(AttachmentImageBox),
        );
        expect(
          tester.getSize(find.byType(AttachmentImageBox)),
          const Size(120, 240),
        );
        expect(box.getMaxIntrinsicWidth(double.infinity), 120);
        expect(box.getMinIntrinsicHeight(300), 240);
        expect(box.getMaxIntrinsicHeight(300), 240);
        expect(
          box.getDryLayout(const BoxConstraints(maxWidth: 300)),
          const Size(120, 240),
        );

        // A changed cap on the mounted box lays it out again.
        await pumpBox(tester, maxHeight: 480);
        expect(
          tester.getSize(find.byType(AttachmentImageBox)),
          const Size(240, 480),
        );
        await pumpBox(tester, maxHeight: 100);
        expect(
          tester.getSize(find.byType(AttachmentImageBox)),
          const Size(50, 100),
        );

        // Never upscaled, whatever the cap.
        await pumpBox(tester, maxHeight: 900, natural: const Size(100, 50));
        expect(
          tester.getSize(find.byType(AttachmentImageBox)),
          const Size(100, 50),
        );

        // The default cap is the editor's 480.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 300),
                child: AttachmentImageBox(natural: const Size(300, 600)),
              ),
            ),
          ),
        );
        expect(
          tester.getSize(find.byType(AttachmentImageBox)),
          const Size(240, 480),
        );
        expect(
          attachmentImageSize(const Size(300, 600), 300),
          const Size(240, 480),
        );
        expect(
          attachmentImageSize(const Size(300, 600), 300, maxHeight: 240),
          const Size(120, 240),
        );
      },
    );
  });
}
