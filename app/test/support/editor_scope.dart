// Shared test seam (#166, merged-tree fix vs #181): the ProviderScope an
// editor tree needs. Every `LivePreviewFrame` composes a `LinkRegion` (B3),
// which reads `noteTitlesAsyncProvider` and `currentVaultProvider` on build
// and `urlOpenerProvider` on Cmd+click, so a `SegmentView`, `EditorRow`,
// `LivePreviewFrame` or `SegmentedBody` pumped without a scope throws
// "No ProviderScope found". Widget tests that pump those bare wrap them with
// [editorScope] or [pumpEditorScoped]; full-app harnesses already have one.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';

/// A [UrlOpener] that records every URL and opens nothing (no test launches
/// `/usr/bin/open`).
class RecordingUrlOpener implements UrlOpener {
  final List<String> opened = [];

  @override
  Future<void> open(String url) async => opened.add(url);
}

/// [child] under a [ProviderScope] whose `urlOpenerProvider` is [opener]
/// (a fresh [RecordingUrlOpener] by default) and whose
/// `noteTitlesAsyncProvider` loads [titles] for the current vault (none by
/// default, as the real provider loads with no vault open), followed by
/// [overrides].
Widget editorScope(
  Widget child, {
  UrlOpener? opener,
  List<NoteTitle> titles = const [],
  List<Override> overrides = const [],
}) => ProviderScope(
  overrides: [
    urlOpenerProvider.overrideWithValue(opener ?? RecordingUrlOpener()),
    noteTitlesAsyncProvider.overrideWith(
      (ref) async => VaultScoped(ref.watch(currentVaultProvider), titles),
    ),
    ...overrides,
  ],
  child: child,
);

/// Pumps [child] wrapped in [editorScope].
Future<void> pumpEditorScoped(
  WidgetTester tester,
  Widget child, {
  UrlOpener? opener,
  List<NoteTitle> titles = const [],
  List<Override> overrides = const [],
}) => tester.pumpWidget(
  editorScope(child, opener: opener, titles: titles, overrides: overrides),
);
