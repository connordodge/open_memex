import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';

/// Robot for the sidebar Topics mode (WI #24). Finds widgets by the WI's
/// stable Keys: `topics-pane`, `topics-actions`, `topics-folder-<id>`,
/// `topics-folder-toggle-<id>`, `topics-topic-<folderId>-<noteId>`,
/// `topics-unsorted`, `topics-unsorted-<noteId>`, `pinned-glyph-folder-<id>`,
/// `pinned-glyph-member-<folderId>-<noteId>`, `topics-empty`,
/// `copy-review-prompt`, plus #23's `sidebar-mode-*`, `days-pane` and #19's
/// `notes-rail`.
class TopicsRobot {
  TopicsRobot(this.tester);

  final WidgetTester tester;
  late WorkspaceHarness h;

  /// Every `Clipboard.setData` text the app wrote, in order.
  final List<String> clipboardWrites = [];

  /// Launch the whole app on [db]. [reviewPrompt] answers `prompt review`
  /// with that stdout; pass [promptHandler] to script failures instead. The
  /// platform clipboard channel is mocked before the app starts.
  Future<WorkspaceHarness> launch({
    required FakeVaultDb db,
    String? reviewPrompt,
    FakeCliHandler? promptHandler,
  }) async {
    mockClipboard();
    final cli = FakeMemexCli()
      ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout));
    if (promptHandler != null) {
      cli.on('prompt review', promptHandler);
    } else if (reviewPrompt != null) {
      cli.on('prompt review', (_) => FakeMemexCli.ok(reviewPrompt));
    }
    // A taller window: the lazily built tree must hold every fixture row.
    h = await pumpWorkspace(
      tester,
      db: db,
      cli: cli,
      surfaceSize: const Size(1600, 1400),
    );
    return h;
  }

  /// Route `SystemChannels.platform` so `Clipboard.setData` lands in
  /// [clipboardWrites].
  void mockClipboard() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<Object?, Object?>;
          clipboardWrites.add(args['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  // ---------------------------------------------------------------- finders

  Finder get topicsSwitch => find.byKey(const Key('sidebar-mode-topics'));
  Finder get daysSwitch => find.byKey(const Key('sidebar-mode-days'));
  Finder get daysPane => find.byKey(const Key('days-pane'));
  Finder get notesRail => find.byKey(const Key('notes-rail'));
  Finder get pane => find.byKey(const Key('topics-pane'));
  Finder get actions => find.byKey(const Key('topics-actions'));
  Finder get empty => find.byKey(const Key('topics-empty'));
  Finder get copyButton => find.byKey(const Key('copy-review-prompt'));
  Finder get unsorted => find.byKey(const Key('topics-unsorted'));
  Finder folder(String id) => find.byKey(Key('topics-folder-$id'));
  Finder toggle(String id) => find.byKey(Key('topics-folder-toggle-$id'));
  Finder topic(String folderId, String noteId) =>
      find.byKey(Key('topics-topic-$folderId-$noteId'));
  Finder unsortedNote(String noteId) =>
      find.byKey(Key('topics-unsorted-$noteId'));
  Finder folderGlyph(String id) => find.byKey(Key('pinned-glyph-folder-$id'));
  Finder memberGlyph(String folderId, String noteId) =>
      find.byKey(Key('pinned-glyph-member-$folderId-$noteId'));

  /// Every widget whose Key is a string starting with [prefix].
  Finder keyedWithPrefix(String prefix) => find.byWidgetPredicate((w) {
    final k = w.key;
    return k is ValueKey<String> && k.value.startsWith(prefix);
  });

  /// Folder rows only (`topics-folder-<id>`, not the toggles).
  Finder get folderRows => find.byWidgetPredicate((w) {
    final k = w.key;
    return k is ValueKey<String> &&
        k.value.startsWith('topics-folder-') &&
        !k.value.startsWith('topics-folder-toggle-');
  });

  /// Topic rows under folders (`topics-topic-…`).
  Finder get topicRows => keyedWithPrefix('topics-topic-');

  /// Every `topics-unsorted-<noteId>` row (not the `topics-unsorted` group).
  Finder get unsortedRows => keyedWithPrefix('topics-unsorted-');

  /// Every string drawn by Text / RichText under [of] (and [of] itself).
  List<String> textsUnder(Finder of) {
    final out = <String>[];
    for (final e
        in find
            .descendant(
              of: of,
              matching: find.byType(RichText),
              matchRoot: true,
            )
            .evaluate()) {
      out.add((e.widget as RichText).text.toPlainText());
    }
    return out;
  }

  /// Whether a pin glyph (`LucideIcons.pin`) is drawn at or under [of].
  bool hasPinIcon(Finder of) => find
      .descendant(
        of: of,
        matching: find.byIcon(LucideIcons.pin),
        matchRoot: true,
      )
      .evaluate()
      .isNotEmpty;

  /// Whether a menu affordance sits at or under [of].
  bool hasMenu(Finder of) {
    bool under(Finder matching) => find
        .descendant(of: of, matching: matching, matchRoot: true)
        .evaluate()
        .isNotEmpty;
    return under(find.byType(MenuAnchor)) ||
        under(find.byType(PopupMenuButton)) ||
        under(find.byType(MenuItemButton)) ||
        under(find.byIcon(LucideIcons.ellipsis)) ||
        under(find.byIcon(LucideIcons.ellipsisVertical));
  }

  /// [of] draws a text containing [text].
  void expectShows(Finder of, String text) {
    expect(of, findsOneWidget);
    expect(
      textsUnder(of).any((t) => t.contains(text)),
      isTrue,
      reason: 'expected "$text" under $of, got ${textsUnder(of)}',
    );
  }

  /// Left edge of the label [text] drawn inside [row].
  double labelLeft(Finder row, String text) => tester
      .getTopLeft(
        find.descendant(of: row, matching: find.textContaining(text)).first,
      )
      .dx;

  double top(Finder f) => tester.getTopLeft(f).dy;

  // ------------------------------------------------------------------ state

  TabsState get tabs => h.read(tabsProvider);
  WorkspaceTab? get activeTab => tabs.activeTab;

  // ---------------------------------------------------------------- actions

  Future<void> tap(Finder f) async {
    expect(f, findsOneWidget);
    await tester.tap(f);
    await pumpFrames(tester);
  }

  Future<void> chooseTopics() => tap(topicsSwitch);
  Future<void> chooseDays() => tap(daysSwitch);
  Future<void> toggleFolder(String id) => tap(toggle(id));
  Future<void> openTopic(String folderId, String noteId) =>
      tap(topic(folderId, noteId));
  Future<void> openUnsorted(String noteId) => tap(unsortedNote(noteId));
  Future<void> copyReviewPrompt() => tap(copyButton);

  /// Bump `vaultRevisionProvider` as a save or the poller would, and pump.
  Future<void> bumpRevision() async {
    h.container.read(vaultRevisionProvider.notifier).state++;
    await pumpFrames(tester);
  }

  /// The text of `<vault>/.memex/ui_state.json`, or '' when absent.
  String uiStateJson() {
    final f = File('${h.vaultPath}/.memex/ui_state.json');
    return f.existsSync() ? f.readAsStringSync() : '';
  }

  /// The decoded `ui_state.json`, or an empty map when absent.
  Map<String, Object?> uiState() {
    final raw = uiStateJson();
    return raw.isEmpty ? {} : jsonDecode(raw) as Map<String, Object?>;
  }

  // ------------------------------------------------------------- assertions

  /// The exact empty-state copy (Req 53) is drawn inside `topics-empty`.
  void expectEmptyCopy() {
    expect(empty, findsOneWidget);
    expect(
      textsUnder(empty).map((t) => t.trim()),
      contains(
        "Your agent hasn't reviewed anything yet. "
        'Run the review prompt from your agent to build Topics.',
      ),
    );
  }
}
