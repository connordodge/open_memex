import '../memex_cli.dart';

/// `memex prompt` wrapper (C2.13).
extension PromptCli on MemexCli {
  /// `memex prompt review` → the raw prompt text, byte for byte. A CLI
  /// failure throws [MemexException].
  Future<String> reviewPrompt() => throw UnimplementedError();
}
