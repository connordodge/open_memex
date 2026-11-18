// The right panel's Outline tab (Spec #58, WI #68): design B "Mono tree".
// Wired to the editor and the keyboard by WI #70.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/outline.dart';
import '../../state/outline_section.dart';
import '../../state/outline_state.dart';
import '../../theme/colors.dart';
import '../../vault_access/vault_async_view.dart';
import '../atoms.dart';
import '../panel_placeholder_tab.dart';
import 'editor_focus_memory.dart';
import 'outline_jump.dart';
import 'outline_keys.dart';
import 'outline_row.dart';

const _eyebrow = 'outline · this note';
const _noNote = 'open a note to see its outline.';
const _noHeadings = 'no headings yet — start a line with # to add one.';

/// What the tab shows while the editor's note is still loading on a local
/// vault (or failed to load): the header alone, never another state's copy.
const _pending = NoteOutline(noteId: '', content: '', entries: []);

/// The list's padding above its first row.
const double _listPadTop = 6;

/// How far past the list's edge a row still counts as shown.
const double _edge = 1e-6;

/// The `outline` tab body: the editor's note's entries, or a placeholder.
///
/// - No note open: the header and `open a note to see its outline.`
/// - A note with no headings: the header and the no headings copy (Key
///   `outline-empty`).
/// - Otherwise the header with the entry count and the [OutlineList].
/// - A hosted note still loading: the shared loading state.
///
/// The header always carries the `⌘⇧O` keycap.
///
/// The row of the current section (`outlineSectionProvider`) shows the
/// current marks, and the list scrolls the least needed to show it whole
/// when it changes. A row click jumps the editor to its heading
/// ([jumpToOutlineEntry], with the live text the entries came from) and
/// leaves the caret and the focused node as they are.
///
/// With keyboard focus (Cmd+Shift+O, `OutlineKeys`) one row has the focus
/// ring: Up and Down move it one row, stopping at the first and the last
/// (no wrap) and keeping it in view the same way; Enter or Space jumps to
/// its heading and keeps focus on it; Esc gives focus back to the editor
/// field that last had it ([EditorFocusMemory]), and the ring goes.
class OutlineTab extends ConsumerStatefulWidget {
  const OutlineTab({super.key});

  @override
  ConsumerState<OutlineTab> createState() => _OutlineTabState();
}

class _OutlineTabState extends ConsumerState<OutlineTab> {
  final _focus = FocusNode(debugLabel: 'outline-list');
  final _scroll = ScrollController();

  /// The row with the focus ring while the list has focus.
  int? _focusedIndex;

  /// The current row last kept in view: the list follows only a change.
  int? _keptCurrent;

  /// The Outline the last build showed entries of, else null; and whether
  /// that build knew what to show (no load in flight).
  NoteOutline? _shown;
  bool _resolved = false;

  bool _requestScheduled = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocusChange)
      ..dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<OutlineEntry> get _entries => _shown?.entries ?? const [];

  void _onFocusChange() {
    if (!mounted) return;
    setState(() {
      if (_focus.hasFocus && _focusedIndex == null && _entries.isNotEmpty) {
        _focusedIndex = _currentIndex() ?? 0;
      }
    });
  }

  /// The row of [current] (default: the current section) in the shown
  /// entries, or null.
  int? _currentIndex([OutlineEntry? current]) {
    final entry = current ?? ref.read(outlineSectionProvider);
    if (entry == null) return null;
    final i = _entries.indexOf(entry);
    return i < 0 ? null : i;
  }

  void _afterLayout(VoidCallback fn) {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (mounted) fn();
      })
      ..ensureVisualUpdate();
  }

  /// Takes a pending focus request (Cmd+Shift+O) once the tab knows what it
  /// shows. It runs after the section tracker's pass, so the current
  /// section is known: focus goes to its row, else the first; with no
  /// entries focus stays where it is.
  void _takeRequest() {
    _requestScheduled = false;
    if (!_resolved) return;
    if (!ref.read(outlineFocusRequestProvider.notifier).take()) return;
    if (_entries.isEmpty) return;
    final i = _currentIndex() ?? 0;
    setState(() => _focusedIndex = i);
    _focus.requestFocus();
    _afterLayout(() => _reveal(i));
  }

  /// Scrolls the list the least needed to show row [i] whole.
  void _reveal(int i) {
    if (!_scroll.hasClients || i >= _entries.length) return;
    final position = _scroll.position;
    if (!position.hasPixels || !position.hasContentDimensions) return;
    final extent = OutlineRow.heightFor(MediaQuery.textScalerOf(context));
    final top = _listPadTop + i * extent;
    final bottom = top + extent;
    final double to;
    if (top < position.pixels - _edge) {
      to = top;
    } else if (bottom > position.pixels + position.viewportDimension + _edge) {
      to = bottom - position.viewportDimension;
    } else {
      return;
    }
    position.jumpTo(
      to.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  void _move(int i) {
    setState(() => _focusedIndex = i);
    _afterLayout(() => _reveal(i));
  }

  void _activate(OutlineEntry entry) {
    final outline = _shown;
    if (outline == null) return;
    jumpToOutlineEntry(ref, outline.noteId, entry, outline.content);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final entries = _entries;
    if (entries.isEmpty) return KeyEventResult.ignored;
    final last = entries.length - 1;
    final at = math.min(_focusedIndex ?? 0, last);
    final down = event is KeyDownEvent;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(math.max(0, at - 1));
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _move(math.min(last, at + 1));
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      // A held key jumps once.
      if (down) _activate(entries[at]);
    } else if (key == LogicalKeyboardKey.escape) {
      if (down && !ref.read(editorFocusMemoryProvider).restore()) {
        _focus.unfocus();
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(outlineSectionProvider);
    ref.watch(outlineFocusRequestProvider);
    if (!_requestScheduled &&
        ref.read(outlineFocusRequestProvider.notifier).pending) {
      // After the section tracker's pass, which watching the current
      // section above has just scheduled if nothing watched it before.
      _requestScheduled = true;
      _afterLayout(_takeRequest);
    }
    _shown = null;
    _resolved = false;
    return VaultAsyncView<NoteOutline?>(
      value: ref.watch(outlineProvider),
      empty: _pending,
      builder: (context, outline) {
        if (identical(outline, _pending)) {
          return const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PanelHeader(eyebrow: _eyebrow, trailing: _Keycap()),
              OmHairline(),
            ],
          );
        }
        _resolved = true;
        if (outline == null) {
          _keptCurrent = null;
          return const PanelPlaceholderTab(
            eyebrow: _eyebrow,
            subtitle: '',
            empty: _noNote,
            headerTrailing: _Keycap(),
          );
        }
        if (outline.entries.isEmpty) {
          _keptCurrent = null;
          return const PanelPlaceholderTab(
            eyebrow: _eyebrow,
            subtitle: '',
            empty: _noHeadings,
            emptyKey: Key('outline-empty'),
            headerTrailing: _Keycap(),
          );
        }
        _shown = outline;
        final entries = outline.entries;
        final currentIndex = _currentIndex(current);
        if (currentIndex != _keptCurrent) {
          _keptCurrent = currentIndex;
          if (currentIndex != null) _afterLayout(() => _reveal(currentIndex));
        }
        if ((_focusedIndex ?? 0) > entries.length - 1) {
          _focusedIndex = entries.length - 1;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PanelHeader(
              eyebrow: _eyebrow,
              count: entries.length,
              trailing: const _Keycap(),
            ),
            const OmHairline(),
            Expanded(
              child: Focus(
                focusNode: _focus,
                onKeyEvent: _onKey,
                // A row click leaves a focused text field focused.
                child: TextFieldTapRegion(
                  child: OutlineList(
                    entries: entries,
                    currentIndex: currentIndex,
                    focusedIndex: _focus.hasFocus ? _focusedIndex : null,
                    onActivate: _activate,
                    controller: _scroll,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The header's `⌘⇧O` keycap: [OmKbd] in a 1 px line2 box.
class _Keycap extends StatelessWidget {
  const _Keycap();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(3),
      ),
      child: const OmKbd('⌘⇧O'),
    );
  }
}

/// The Outline's scrolling list of entries (Key `outline-list`), one row per
/// entry (Key `outline-entry-<index>`, the whole row's click target), each
/// [OutlineRow.heightFor] tall.
///
/// [currentIndex] is the current section's row, [focusedIndex] the row with
/// keyboard focus; [onActivate] runs with a row's entry when it is tapped.
class OutlineList extends StatelessWidget {
  const OutlineList({
    super.key,
    required this.entries,
    this.currentIndex,
    this.focusedIndex,
    this.onActivate,
    this.controller,
  });

  final List<OutlineEntry> entries;
  final int? currentIndex;
  final int? focusedIndex;
  final void Function(OutlineEntry entry)? onActivate;

  /// The list's scroll.
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: const Key('outline-list'),
      controller: controller,
      padding: const EdgeInsets.only(top: _listPadTop, bottom: 12),
      itemExtent: OutlineRow.heightFor(MediaQuery.textScalerOf(context)),
      itemCount: entries.length,
      itemBuilder: (context, i) => OutlineRow(
        key: Key('outline-entry-$i'),
        entry: entries[i],
        current: i == currentIndex,
        focused: i == focusedIndex,
        onActivate: onActivate,
      ),
    );
  }
}
