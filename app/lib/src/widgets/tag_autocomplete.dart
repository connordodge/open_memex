import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Caret-anchored popover triggered by typing `#` in a markdown editor
/// (WI #246). Skeleton: it never opens.
class TagAutocomplete extends ConsumerStatefulWidget {
  const TagAutocomplete({
    super.key,
    required this.controller,
    required this.caretLocator,
  });

  final TextEditingController controller;

  /// Returns the **global** screen offset where the popover anchors.
  final Offset Function() caretLocator;

  @override
  ConsumerState<TagAutocomplete> createState() => TagAutocompleteState();
}

class TagAutocompleteState extends ConsumerState<TagAutocomplete> {
  bool get isOpen => false;

  /// Called by the host's `FocusNode.onKeyEvent` while the popover is open.
  KeyEventResult handleKeyEvent(KeyEvent event) => KeyEventResult.ignored;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
