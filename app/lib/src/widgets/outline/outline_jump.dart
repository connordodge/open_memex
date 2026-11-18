import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/outline.dart';

// The Outline's jump (#69, Spec #58 R17-R21, R34, TD4): one request on the
// note reveal seam.

/// Jumps the editor showing note [noteId] to [entry]'s heading, 16 px below
/// the top of the visible body, with the arrival highlight. [content] is the
/// live text [entry] came from.
void jumpToOutlineEntry(
  WidgetRef ref,
  String noteId,
  OutlineEntry entry,
  String content,
) {}
