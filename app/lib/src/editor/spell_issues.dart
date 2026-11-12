// WI #434 (Spec #392 req 22): the spelling and grammar issue models. Pure
// Dart: no Flutter imports.

/// What kind of issue the checker found.
enum SpellIssueKind { spelling, grammar }

/// One issue the checker found in a checked text. [start] and [length] are
/// UTF-16 code units into that text. Value equality.
class SpellIssue {
  const SpellIssue({
    required this.kind,
    required this.start,
    required this.length,
    this.description,
    this.corrections = const [],
  });

  final SpellIssueKind kind;
  final int start;
  final int length;

  /// The checker's explanation (grammar), or null.
  final String? description;

  /// The checker's corrections, best first; empty when it has none.
  final List<String> corrections;

  @override
  bool operator ==(Object other) =>
      other is SpellIssue &&
      other.kind == kind &&
      other.start == start &&
      other.length == length &&
      other.description == description &&
      _sameList(other.corrections, corrections);

  @override
  int get hashCode => Object.hash(
    kind,
    start,
    length,
    description,
    Object.hashAll(corrections),
  );
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
