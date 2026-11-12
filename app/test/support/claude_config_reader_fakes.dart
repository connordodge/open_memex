// WI #404 (Spec #394 Testing Strategy): a [ClaudeConfigReader] that answers
// with a set outcome, so no test reads the real Claude Desktop config.
import 'package:open_memex_app/src/agents_sheet/connect/claude_config_reader.dart';

/// Answers every [read] with [result] (the last one set) and counts reads.
class FakeClaudeConfigReader implements ClaudeConfigReader {
  FakeClaudeConfigReader(this.result);

  /// The file holds [contents].
  FakeClaudeConfigReader.contents(String contents)
    : result = ClaudeConfigContents(contents);

  /// No file at the path.
  FakeClaudeConfigReader.missing() : result = const ClaudeConfigMissing();

  /// The file can't be read.
  FakeClaudeConfigReader.unreadable() : result = const ClaudeConfigUnreadable();

  /// The file is over 1 MB.
  FakeClaudeConfigReader.oversized() : result = const ClaudeConfigOversized();

  /// What the next [read] answers; a test may change it between reads.
  ClaudeConfigRead result;

  /// How many times [read] ran.
  int reads = 0;

  @override
  Future<ClaudeConfigRead> read() async {
    reads++;
    return result;
  }
}
