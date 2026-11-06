// WI #245 (A1): the Dart port of the inline `#tag` grammar (Spec #234 R4-R6,
// R20; rulings D17, TD4). The contract is `test/fixtures/tags/grammar.json`,
// shared with the Rust reference, `crates/memex-core/src/tags.rs`.
//
// The app never derives tags from a note: this is for styling and type-ahead
// only. Pure Dart, no Flutter imports. Every offset is a UTF-16 code-unit
// index, and no range boundary falls inside a surrogate pair.
//
// SKELETON (red mode): signatures only, neutral stubs, no behavior.

/// A tag found in one line: the half-open UTF-16 range `[start, end)` of the
/// `#` and the name as written (no trailing `-` or `_`), and its lowercase
/// [name] without the `#`.
final class TagRange {
  const TagRange(this.start, this.end, this.name);

  /// Offset of the `#`.
  final int start;

  /// One past the last code unit of the name as written.
  final int end;

  /// The lowercase name, without the `#`.
  final String name;
}

/// True only for the system tags `inbox` and `agent-authored` (R20, D17):
/// the one list in `grammar.json`'s `system_tags`. Case-sensitive, as the
/// Rust predicate is.
bool isSystemTag(String name) => false;

/// Whether a `#` right after the code unit [previous] (null at the start of
/// a line) can start a tag: line start, Unicode whitespace, or one of
/// `( [ { " '`. The one `#` start test; type-ahead (#246) calls it too.
bool opensTag(int? previous) => false;

/// The tags in [line], one line of prose (no `\n`), in order of position,
/// outside code spans, transclusions, wikilinks, markdown links and URLs.
/// Never call it on a fenced line: fences are the caller's.
List<TagRange> findTagsInLine(String line) => const [];

/// The lowercase names of the tags in [personText] (any number of lines,
/// split on `\n`), sorted by name, one per name, nothing inside fenced code.
List<String> extractTagNames(String personText) => const [];

/// `Some(lowercase)` only when the whole [input] is one valid tag name.
String? normalizeTagName(String input) => null;
