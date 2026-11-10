// WI #321 (A0, D19): the stub A4 (#325) fills. A4 replaces it and deletes
// this whole file (a TEST-CHANGE in its PR). One file per filler, so no two
// fillers edit the same file or its imports.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/widgets/backups/backups_sheet.dart';

void main() {
  group('stubs filled by A4 (#325)', () {
    testWidgets('showBackupsSheet stub completes at once', (tester) async {
      var completed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await showBackupsSheet(context, const LocalVaultRef('/v'));
                completed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(completed, isTrue);
    });
  });
}
