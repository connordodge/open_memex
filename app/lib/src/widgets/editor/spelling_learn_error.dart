// WI #438 (Spec #392 req 12, 13b): the error a failed Learn Spelling shows
// above the editor body, beside NoteDeleteError (ruling D15).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../inline_error.dart';

/// The word whose Learn Spelling failed last, and the note it was learned
/// from; null when there is none (or it was dismissed).
final spellingLearnErrorProvider =
    StateProvider<({String noteId, String word})?>((_) => null);

/// `Could not learn "<word>".` as a dismissible [InlineError] while the
/// last Learn Spelling in [noteId] failed; empty otherwise.
class SpellingLearnError extends ConsumerWidget {
  const SpellingLearnError({super.key, required this.noteId});

  final String noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(spellingLearnErrorProvider);
    if (error == null || error.noteId != noteId) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: InlineError(
        message: 'Could not learn "${error.word}".',
        onDismiss: () =>
            ref.read(spellingLearnErrorProvider.notifier).state = null,
      ),
    );
  }
}
