import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../cli/note_cli.dart';
import '../../db.dart';
import '../../editor/attachment_insert.dart';
import '../../editor/editor_rows.dart' show SegmentEdit, SegmentSelection;
import '../../editor/segments.dart';
import '../../graph/graph_scope.dart';
import '../../memex_cli.dart';
import '../../state/attach_controller.dart';
import '../../state/editor_controller.dart';
import '../../state/graph_state.dart';
import '../../state/note_edits_state.dart';
import '../../state/tabs_state.dart';
import '../../state/vault_access_state.dart';
import '../../state/vault_state.dart';
import '../../vault_access/errors.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../agent_edits_keys.dart';
import '../atoms.dart';
import '../find/find_in_note_host.dart' show FindBodyField, FindEditorLink;
import 'segment_view.dart' show SegmentViewState;

/// The editor toolbar's ellipsis button (Key `note-menu-button`). It opens
/// [NoteMenu] for the open note, and is disabled when no note is open.
class NoteMenuButton extends ConsumerWidget {
  const NoteMenuButton({super.key, required this.note});
  final Note? note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = this.note;
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(OmColors.surface3),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(color: OmColors.line3),
          ),
        ),
      ),
      menuChildren: [
        if (note != null)
          NoteMenu(note: note, hostContext: context, hostRef: ref),
      ],
      builder: (context, controller, _) => OmButton(
        key: const Key('note-menu-button'),
        kind: OmButtonKind.ghost,
        size: 26,
        icon: LucideIcons.ellipsis,
        onPressed: note == null
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
        tooltip: 'more',
      ),
    );
  }
}

/// The note menu for [note] (Key `note-menu`), shown by [NoteMenuButton].
/// Items are [MenuItemButton]s in the column; selecting one closes the menu.
/// To add an item, append a [MenuItemButton] to the column's children.
class NoteMenu extends StatelessWidget {
  const NoteMenu({
    super.key,
    required this.note,
    required this.hostContext,
    this.hostRef,
  });
  final Note note;

  /// The context of the widget that hosts the menu ([NoteMenuButton]). Item
  /// actions that outlive the menu (dialogs) use it, since the menu's own
  /// context is deactivated once an item closes the menu.
  final BuildContext hostContext;

  /// The host's [WidgetRef], for item actions that open tabs after the menu
  /// has closed (`Open graph`). Without one that item is disabled.
  final WidgetRef? hostRef;

  /// The Graph scope `Open graph` opens: the topic scope for a topic note,
  /// the day scope for a daily note, none otherwise. The unsaved virtual
  /// Today note (#22) is in no graph yet, so it has none either.
  static GraphScope? graphScopeFor(Note note) {
    if (VirtualTodayTab.dateOf(note.id) case _?) return null;
    return switch (note.role) {
      'topic' => GraphScope.topic(note.id),
      'daily' => GraphScope.day(note.id),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final ref = hostRef;
    return Column(
      key: const Key('note-menu'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AttachFileItem(hostContext: hostContext),
        // The Vault Guide cannot be deleted.
        if (note.role != 'guide')
          MenuItemButton(
            key: const Key('note-menu-delete'),
            leadingIcon: const Icon(LucideIcons.trash2, size: 14),
            // The unsaved virtual Today note (#22) has nothing to delete.
            onPressed: VirtualTodayTab.dateOf(note.id) != null
                ? null
                : () => confirmAndDeleteNote(
                    hostContext,
                    ProviderScope.containerOf(hostContext),
                    note,
                  ),
            child: const Text('Delete note'),
          ),
        if (graphScopeFor(note) case final scope?)
          MenuItemButton(
            key: const Key('note-menu-open-graph'),
            leadingIcon: const Icon(LucideIcons.network, size: 14),
            onPressed: switch (ref) {
              final ref? => () => openGraph(ref, scope),
              null => null,
            },
            child: const Text('Open graph'),
          ),
        // Spec #7 Req 7 and 31: the flag can't be set on a daily note or the
        // Vault Guide. The unsaved virtual Today note is a `role: daily` note.
        if (note.role != 'daily' && note.role != 'guide')
          _AgentReadOnlyItem(note: note, hostContext: hostContext),
      ],
    );
  }
}

/// The checkable `Read-only for agents` item (Key
/// [noteMenuAgentReadOnlyKey], Spec #7 Req 31), shown only while
/// [agentEditsAvailableProvider] is true (D17). Its check is [note]'s stored
/// flag, the re-read note the editor shows (D18).
class _AgentReadOnlyItem extends ConsumerWidget {
  const _AgentReadOnlyItem({required this.note, required this.hostContext});
  final Note note;
  final BuildContext hostContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(agentEditsAvailableProvider)) return const SizedBox.shrink();
    final on = note.agentReadOnly;
    final container = ProviderScope.containerOf(context, listen: false);
    return MenuItemButton(
      key: noteMenuAgentReadOnlyKey,
      leadingIcon: Icon(
        on ? LucideIcons.squareCheck : LucideIcons.square,
        size: 14,
      ),
      onPressed: () => _toggleAgentReadOnly(hostContext, container, note),
      child: Semantics(checked: on, child: const Text('Read-only for agents')),
    );
  }
}

/// The note ids whose Agent read-only toggle is in flight: the busy guard
/// of [_toggleAgentReadOnly]. It lives in the container, not the menu, since
/// the menu closes when the item is chosen.
final _agentReadOnlyBusyProvider = Provider<Set<String>>((_) => <String>{});

/// The toggle's inline error when the vault can't be written (no `memex`
/// CLI): the app's existing copy for that case (smart folders, topics).
const _noCliMessage = 'The memex CLI is not available.';

/// Sets [note]'s Agent read-only flag to the opposite of its stored value
/// through [NoteEditsActions.setAgentReadOnly], inside `guardVaultWrite`.
/// While one toggle of [note] is in flight, another starts nothing. No
/// optimistic state: the check and the title icon change when the bump's
/// re-read note does (D18). On failure nothing changes except
/// [noteDeleteErrorProvider], which shows the CLI or server message (Req 33);
/// a later successful toggle of [note] clears that message. An unreachable
/// vault server shows the guard's snackbar instead.
///
/// With no vault open or no `memex` CLI (`VaultAccess.canWrite` false) it
/// makes no call and shows [_noCliMessage]. Any other failure (a
/// [StateError], a [MemexCliTimeout]) shows its message in the same slot
/// rather than escaping as an uncaught async error.
Future<void> _toggleAgentReadOnly(
  BuildContext context,
  ProviderContainer container,
  Note note,
) async {
  final busy = container.read(_agentReadOnlyBusyProvider);
  if (!busy.add(note.id)) return;
  try {
    if (!context.mounted) return;
    final errors = container.read(noteDeleteErrorProvider.notifier);
    final access = container.read(vaultAccessProvider);
    if (access == null || !access.canWrite) {
      errors.state = (noteId: note.id, message: _noCliMessage);
      return;
    }
    final bool? done;
    try {
      done = await guardVaultWrite(context, () async {
        await container
            .read(noteEditsActionsProvider)
            .setAgentReadOnly(note.id, !note.agentReadOnly);
        return true;
      });
    } on MemexException catch (e) {
      errors.state = (noteId: note.id, message: e.message);
      return;
    } on StateError catch (e) {
      errors.state = (noteId: note.id, message: e.message);
      return;
    } on Exception catch (e) {
      errors.state = (noteId: note.id, message: e.toString());
      return;
    }
    if (done == null) return;
    if (errors.state?.noteId == note.id) errors.state = null;
  } finally {
    busy.remove(note.id);
  }
}

/// The inline error left by a failed note delete or Agent read-only toggle:
/// the id of the note it belongs to and the CLI message. Null when there is
/// none.
final noteDeleteErrorProvider =
    StateProvider<({String noteId, String message})?>((_) => null);

/// Asks for confirmation, then deletes [note] through `VaultAccess.notes`
/// (`memex rm` on a local vault) with the editor's last saved version, inside
/// `guardVaultWrite`. On success the note's tab closes and the vault reads
/// refresh. On failure nothing changes except [noteDeleteErrorProvider]; an
/// unreachable vault server shows the guard's snackbar instead.
///
/// Takes the [container] rather than a `WidgetRef`: the note menu is gone by
/// the time the person answers the dialog.
Future<void> confirmAndDeleteNote(
  BuildContext context,
  ProviderContainer container,
  Note note,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => _DeleteNoteDialog(title: note.title),
  );
  if (confirmed != true || !context.mounted) return;

  final access = container.read(vaultAccessProvider);
  if (access == null || !access.canWrite) return;
  final errors = container.read(noteDeleteErrorProvider.notifier);
  final version =
      container.read(editorControllerProvider).lastSavedVersion ?? note.version;
  final NoteDeleteResult? deleted;
  try {
    deleted = await guardVaultWrite(
      context,
      () => access.notes.deleteNote(noteId: note.id, expectedVersion: version),
    );
  } on MemexException catch (e) {
    errors.state = (noteId: note.id, message: e.message);
    return;
  }
  if (deleted == null) return;
  errors.state = null;
  container.read(tabsProvider.notifier).close(NoteTab(note.id));
  container.read(vaultRevisionProvider.notifier).state++;
}

class _DeleteNoteDialog extends StatelessWidget {
  const _DeleteNoteDialog({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('delete-note-dialog'),
      title: const Text('Delete note?'),
      content: Text('"$title" will be deleted. This can\'t be undone.'),
      actions: [
        TextButton(
          key: const Key('delete-note-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('delete-note-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Delete', style: TextStyle(color: OmColors.danger)),
        ),
      ],
    );
  }
}

/// The dismissible inline error (Key `inline-error`) for a failed delete of
/// [noteId]; empty when the open note has none.
class NoteDeleteError extends ConsumerWidget {
  const NoteDeleteError({super.key, required this.noteId});
  final String noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(noteDeleteErrorProvider);
    if (error == null || error.noteId != noteId) {
      return const SizedBox.shrink();
    }
    return Container(
      key: const Key('inline-error'),
      color: OmColors.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              error.message,
              style: OmType.mono(size: 11, color: OmColors.danger),
            ),
          ),
          OmButton(
            key: const Key('inline-error-dismiss'),
            kind: OmButtonKind.ghost,
            size: 22,
            icon: LucideIcons.x,
            tooltip: 'dismiss',
            onPressed: () =>
                ref.read(noteDeleteErrorProvider.notifier).state = null,
          ),
        ],
      ),
    );
  }
}

/// `Attach file…` (Key `note-menu-attach-file`, Spec #123 R10, R11): opens
/// the file picker through [AttachController.attachFromPicker]. Shown only
/// while `VaultAccess.canWrite` (the menu itself exists only with a note
/// open).
class _AttachFileItem extends ConsumerWidget {
  const _AttachFileItem({required this.hostContext});
  final BuildContext hostContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(ref.watch(vaultAccessProvider)?.canWrite ?? false)) {
      return const SizedBox.shrink();
    }
    final container = ProviderScope.containerOf(context, listen: false);
    return MenuItemButton(
      key: const Key('note-menu-attach-file'),
      leadingIcon: const Icon(LucideIcons.paperclip, size: 14),
      // The menu's own context goes with the menu: toasts use the host's.
      onPressed: () => unawaited(
        container.read(attachControllerProvider).attachFromPicker(hostContext),
      ),
      child: const Text('Attach file…'),
    );
  }
}

/// The attach action's link to the note editor showing [note] (WI #146):
/// registers itself as [attachEditorProvider]'s [AttachEditor] while
/// [active], and draws nothing. The editor places it beside its body, as it
/// does Find in note's host. "Attach file…" and #147's drop and paste reach
/// the editor only through it, via [AttachController].
///
/// It remembers the editor's last caret: the text segment (or, in Source
/// mode, the Source field) that last had focus since [note] was shown, so
/// the ⋯ menu or the palette taking focus keeps the caret line. Inserts go
/// through the segment's `SegmentEditing.applyEdit` in live preview, and in
/// Source mode as one value of [sourceController] reported to the editor
/// controller, so one undo removes the group in either mode.
class NoteAttachHost extends ConsumerStatefulWidget {
  const NoteAttachHost({
    super.key,
    required this.note,
    required this.sourceMode,
    required this.sourceController,
    required this.bodyFocus,
    required this.active,
  });

  /// The note the editor shows.
  final Note note;

  /// Whether the editor shows the Source field rather than the segmented
  /// body.
  final bool sourceMode;

  /// The Source field's controller.
  final TextEditingController sourceController;

  /// The editor's primary body focus node: the Source field's, and the
  /// first text segment's.
  final FocusNode bodyFocus;

  /// False for an editor on its way out (a canvas zoom's outgoing editor).
  final bool active;

  @override
  ConsumerState<NoteAttachHost> createState() => _NoteAttachHostState();
}

class _NoteAttachHostState extends ConsumerState<NoteAttachHost>
    implements AttachEditor {
  late final ProviderContainer _container;

  /// The open-editor registry, read once while the scope is alive so
  /// [dispose] never reads a container that may already be disposed.
  late final StateController<AttachEditor?> _registry;
  Object _session = Object();

  /// The text segment that last had focus since the note was shown: its
  /// controller and index. Null with none.
  TextEditingController? _caretField;
  int? _caretSegment;

  /// Whether the Source field had focus since Source mode started.
  bool _sourceCaret = false;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _registry = _container.read(attachEditorProvider.notifier);
    FocusManager.instance.addListener(_onFocus);
    _register(widget.active);
    _recheckFocus();
  }

  @override
  void didUpdateWidget(NoteAttachHost old) {
    super.didUpdateWidget(old);
    final noteChanged = old.note.id != widget.note.id;
    if (noteChanged) _session = Object();
    if (noteChanged || old.sourceMode != widget.sourceMode) {
      _caretField = null;
      _caretSegment = null;
      _sourceCaret = false;
      _recheckFocus();
    }
    if (old.active != widget.active) _register(widget.active);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocus);
    _register(false);
    super.dispose();
  }

  /// Registers this editor (or withdraws it, when it is the registered
  /// one) once the current frame's work is done: providers can't change
  /// while widgets build. The change is dropped when the scope's container,
  /// and so [_registry], is disposed before the microtask runs (a test or
  /// scope tearing down with this host still mounted).
  void _register(bool on) => scheduleMicrotask(() {
    final registry = _registry;
    if (!registry.mounted) return;
    if (on && mounted) {
      registry.state = this;
    } else if (identical(registry.state, this)) {
      registry.state = null;
    }
  });

  /// Records the field focused once the frame settles: focus a note keeps
  /// from the previous one is no change the focus listener would hear.
  void _recheckFocus() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _onFocus();
  });

  List<FindBodyField> _fields() =>
      FindEditorLink.of(widget.bodyFocus).fields?.call() ?? const [];

  /// Remembers the field holding focus now, if any.
  void _onFocus() {
    if (widget.sourceMode) {
      if (widget.bodyFocus.hasFocus) _sourceCaret = true;
      return;
    }
    for (final field in _fields()) {
      if (field.focus.hasFocus) {
        _caretField = field.controller;
        _caretSegment = field.segment;
        return;
      }
    }
  }

  @override
  Object get session => _session;

  @override
  String get noteTitle => widget.note.title;

  bool get _daily => widget.note.role == 'daily';

  @override
  int? get caretLine {
    _onFocus();
    if (widget.sourceMode) {
      if (!_sourceCaret) return null;
      final text = widget.sourceController.text;
      return _lineAt(text, widget.sourceController.selection, text.length);
    }
    final fields = _fields();
    final field =
        fields.where((f) => identical(f.controller, _caretField)).firstOrNull ??
        fields.where((f) => f.segment == _caretSegment).firstOrNull;
    if (field == null) return null;
    final layout = _layout();
    final start = layout.starts[field.segment];
    if (start == null) return null;
    final ctrl = field.controller;
    final line = _lineAt(
      layout.body,
      ctrl.selection,
      ctrl.text.length,
      start: start,
    );
    // A text segment right before an excerpt card ends in an empty row
    // (its last `\n`, or nothing at all) that the body has no line for:
    // the offset is the card line's start. Text typed there goes above the
    // card, so a caret there anchors after the line above the card.
    final text = ctrl.text;
    final atEnd =
        !ctrl.selection.isValid || ctrl.selection.extentOffset >= text.length;
    if (layout.beforeCard.contains(field.segment) &&
        atEnd &&
        (text.isEmpty || text.endsWith('\n'))) {
      return line > 0 ? line - 1 : 0;
    }
    return line;
  }

  /// The line of [body] holding [selection]'s extent, an offset into a
  /// field of [length] that starts at [start] of [body]; an invalid
  /// selection counts as the field's end.
  static int _lineAt(
    String body,
    TextSelection selection,
    int length, {
    int start = 0,
  }) {
    final local = selection.isValid
        ? selection.extentOffset.clamp(0, length)
        : length;
    final at = (start + local).clamp(0, body.length);
    return '\n'.allMatches(body.substring(0, at)).length;
  }

  /// The body the segmented view shows, as `SegmentedBody` joins it, and
  /// where each text segment (by index) starts in it, with its text, and
  /// which text segments come right before an excerpt card.
  ({
    String body,
    Map<int, int> starts,
    Map<int, String> texts,
    Set<int> beforeCard,
  })
  _layout() {
    final content = _container.read(editorControllerProvider).contentMd;
    final segments = split(
      content,
      isDaily: _daily,
      noteFooter: widget.note.role != 'guide',
    );
    // A daily note without a Topics marker saves its person text alone.
    final withFooter = !_daily || splitDailyBody(content).person != content;
    final parts = [
      for (final s in segments)
        if (withFooter || s is! FooterSegment) s,
    ];
    final starts = <int, int>{};
    final texts = <int, String>{};
    final beforeCard = <int>{};
    var at = 0;
    for (final (i, s) in parts.indexed) {
      switch (s) {
        case TextSegment(:final text):
          starts[i] = at;
          texts[i] = text;
          at += text.length;
          if (i + 1 < parts.length && parts[i + 1] is TransclusionSegment) {
            beforeCard.add(i);
          }
        case TransclusionSegment(:final raw):
          at += raw.length;
        case FooterSegment():
          break;
      }
    }
    return (
      body: join(parts),
      starts: starts,
      texts: texts,
      beforeCard: beforeCard,
    );
  }

  /// [plan] moved out of an excerpt card's line into the text segment after
  /// the card, when it adds the group after that line (an anchor on the
  /// card: a drop on it, R7, or the person section's last line, R10). Only
  /// a text segment takes an edit: inserting `\n` + rest at the card line's
  /// end and inserting rest + `\n` after its `\n` give the same body.
  static AttachmentInsertPlan _pastCardLine(
    String body,
    Iterable<({int start, int end})> fields,
    AttachmentInsertPlan plan,
  ) {
    final inField = fields.any(
      (f) => plan.start >= f.start && plan.end <= f.end,
    );
    if (inField ||
        plan.start != plan.end ||
        plan.start >= body.length ||
        body[plan.start] != '\n' ||
        !plan.replacement.startsWith('\n')) {
      return plan;
    }
    return AttachmentInsertPlan(
      start: plan.start + 1,
      end: plan.start + 1,
      replacement: '${plan.replacement.substring(1)}\n',
      caret: plan.caret,
    );
  }

  @override
  bool insert(List<String> lines, int? anchorLine) {
    if (widget.sourceMode) {
      final ctrl = widget.sourceController;
      final plan = planAttachmentInsert(
        body: ctrl.text,
        anchorLine: anchorLine,
        lines: lines,
        daily: _daily,
      );
      final text = ctrl.text.replaceRange(
        plan.start,
        plan.end,
        plan.replacement,
      );
      // One value change: the field's undo history records it once.
      ctrl.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: plan.caret),
      );
      _container.read(editorControllerProvider.notifier).onContentChanged(text);
      return true;
    }
    final layout = _layout();
    final plan = _pastCardLine(
      layout.body,
      [
        for (final MapEntry(key: i, value: start) in layout.starts.entries)
          (start: start, end: start + layout.texts[i]!.length),
      ],
      planAttachmentInsert(
        body: layout.body,
        anchorLine: anchorLine,
        lines: lines,
        daily: _daily,
      ),
    );
    for (final field in _fields()) {
      final start = layout.starts[field.segment];
      final text = layout.texts[field.segment];
      if (start == null || text == null) continue;
      if (plan.start < start || plan.end > start + text.length) continue;
      final handle = field.focus.context
          ?.findAncestorStateOfType<SegmentViewState>();
      if (handle == null) return false;
      // The field may lack the `\n` the save adds to a text ending right
      // before a card or the Note footer (`SegmentedBody`, `join`).
      final shown = handle.text;
      final saveAddsNewline = shown != text;
      if (saveAddsNewline && '$shown\n' != text) return false;
      final end = plan.end - start;
      if (end > shown.length) return false;
      handle.applyEdit(
        SegmentEdit(
          start: plan.start - start,
          end: end,
          // An edit at the field's end keeps that `\n` in the field.
          replacement: saveAddsNewline && end == shown.length
              ? '${plan.replacement}\n'
              : plan.replacement,
          selection: SegmentSelection.collapsed(plan.caret - start),
        ),
      );
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
