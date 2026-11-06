import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../editor/tag_grammar.dart';
import 'sidebar_mode_state.dart';

/// The one tag (system or not) whose notes the Tags pane shows (WI #251; null
/// when none). Single-select: expanding a tag collapses the one that was
/// open, and `revealTag` follows the same rule (F1.4). In memory only, like
/// `expandedTopicFoldersProvider`.
final expandedTagProvider = NotifierProvider<ExpandedTag, String?>(
  ExpandedTag.new,
);

class ExpandedTag extends Notifier<String?> {
  @override
  String? build() => null;

  /// Expands [tag] (collapsing the tag that was open), or collapses it when
  /// it is the open one.
  void toggle(String tag) => state = state == tag ? null : tag;

  /// Expands [tag], collapsing the tag that was open. Stays expanded when it
  /// already is.
  void expand(String tag) => state = tag;
}

/// Whether the Tags pane's `System` group is open. Independent of
/// [expandedTagProvider]. In memory only.
final tagsSystemOpenProvider = StateProvider<bool>((ref) => false);

/// A pending request to scroll a tag's row into view. Each request is its own
/// object, so asking again for the same tag is a new request.
class TagScrollRequest {
  TagScrollRequest(this.tag);

  final String tag;
}

/// The scroll request `revealTag` leaves for the Tags pane. The pane takes it
/// (sets it back to null) once the row can be found, or once the tags are
/// loaded and the tag has no row.
final tagsScrollRequestProvider = StateProvider<TagScrollRequest?>(
  (ref) => null,
);

/// Switches the sidebar to Tags mode, expands [tag] (or `System` and that tag
/// for a system tag) and scrolls it into view (WI #251).
///
/// Expansion is single-select across all tags, so the tag that was open
/// collapses. The scroll happens in the pane once its row exists, which can
/// be after this returns: the pane may not be mounted yet, or its first read
/// may be pending.
void revealTag(WidgetRef ref, String tag) {
  ref.read(sidebarModeProvider.notifier).select(SidebarMode.tags).ignore();
  if (isSystemTag(tag)) {
    ref.read(tagsSystemOpenProvider.notifier).state = true;
  }
  ref.read(expandedTagProvider.notifier).expand(tag);
  ref.read(tagsScrollRequestProvider.notifier).state = TagScrollRequest(tag);
}
