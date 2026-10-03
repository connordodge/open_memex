import '../memex_cli.dart';

/// `memex prompt` wrapper (C2.13).
extension PromptCli on MemexCli {
  /// `memex prompt review` → the raw prompt text, byte for byte. A CLI
  /// failure throws [MemexException].
  Future<String> reviewPrompt() async {
    final r = await run(['prompt', 'review']);
    if (r.exitCode != 0) {
      throw MemexException.fromCliFailure('prompt review', r);
    }
    return r.stdout;
  }
}
