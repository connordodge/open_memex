// The Outline's Cmd+Shift+O chord (#70, Spec #58 R27, TD7; rulings D12,
// D13).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/right_panel_tab.dart';
import '../../state/vault_state.dart' show rightPanelOpenProvider;
import 'editor_focus_memory.dart';

/// Asks the Outline tab to take keyboard focus: [request] marks a request
/// pending (the state counts them, so every request notifies), and the
/// Outline tab [take]s it once its entries and current section are known.
class OutlineFocusRequests extends Notifier<int> {
  bool _pending = false;

  @override
  int build() => 0;

  /// The Outline should focus its current entry, else its first.
  void request() {
    _pending = true;
    state++;
  }

  /// Whether a request is pending; clears it.
  bool take() {
    final pending = _pending;
    _pending = false;
    return pending;
  }

  /// Whether a request is pending.
  bool get pending => _pending;
}

/// The Outline's pending focus request (see [OutlineFocusRequests]).
final outlineFocusRequestProvider = NotifierProvider<OutlineFocusRequests, int>(
  OutlineFocusRequests.new,
);

/// Registers Cmd+Shift+O on [HardwareKeyboard] for as long as the workspace
/// is mounted, so it fires whatever has focus, or nothing (TD8): it opens
/// the right panel on the `outline` tab and focuses the current entry, else
/// the first; with no entries the tab opens and focus stays put.
///
/// Exactly Cmd (either) + Shift + O: any other modifier, or another key, is
/// not handled. A key repeat is claimed (so macOS does not beep) and does
/// nothing. While a modal route is over the workspace nothing is handled.
///
/// It also keeps the [editorFocusMemoryProvider] tracking, for Esc in the
/// Outline. Builds nothing.
class OutlineKeys extends ConsumerStatefulWidget {
  const OutlineKeys({super.key});

  @override
  ConsumerState<OutlineKeys> createState() => _OutlineKeysState();
}

class _OutlineKeysState extends ConsumerState<OutlineKeys> {
  late final EditorFocusMemory _memory;

  @override
  void initState() {
    super.initState();
    _memory = ref.read(editorFocusMemoryProvider)..attach();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _memory.detach();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyO) return false;
    final keys = HardwareKeyboard.instance;
    if (!keys.isMetaPressed ||
        !keys.isShiftPressed ||
        keys.isControlPressed ||
        keys.isAltPressed) {
      return false;
    }
    // A modal over the workspace owns the keyboard.
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    // A held chord is claimed but acts only once.
    if (event is! KeyDownEvent) return true;
    ref.read(rightPanelOpenProvider.notifier).state = true;
    ref.read(rightPanelTabProvider.notifier).state = RightPanelTab.outline;
    ref.read(outlineFocusRequestProvider.notifier).request();
    return true;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
