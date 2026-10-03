import 'dart:async';
import 'dart:convert';

import 'package:open_memex_app/src/memex_cli.dart';

/// One recorded `run` call.
class FakeCliCall {
  FakeCliCall({
    required this.args,
    required this.stdinBody,
    required this.subcommand,
  });

  /// The full argument list passed to `run`.
  final List<String> args;

  /// What would have been written to stdin (null when none).
  final String? stdinBody;

  /// The registered subcommand path that handled the call (e.g. `add`,
  /// `settings get`, `canvas new`), or the leading non-flag words when no
  /// handler matched.
  final String subcommand;

  /// The value after `--<name>` in [args], or null when the flag is absent.
  String? flag(String name) {
    final i = args.indexOf('--$name');
    if (i < 0 || i + 1 >= args.length) return null;
    return args[i + 1];
  }

  /// True when the bare flag `--<name>` is present.
  bool hasFlag(String name) => args.contains('--$name');

  @override
  String toString() => 'FakeCliCall($args, stdin: $stdinBody)';
}

typedef FakeCliHandler = FutureOr<MemexResult> Function(FakeCliCall call);

/// In-memory stand-in for the `memex` binary (D20). Overrides
/// [MemexCli.run], so every wrapper (and every `lib/src/cli/<area>_cli.dart`
/// extension) runs against registered handlers and never spawns a process.
///
/// ```dart
/// final cli = FakeMemexCli()
///   ..on('settings get', (_) => FakeMemexCli.ok(
///       '{"vault_id":"01HV…","key":"smart_folder_max_depth","value":2}'));
/// ```
class FakeMemexCli extends MemexCli {
  FakeMemexCli() : super(binaryPath: 'fake-memex');

  final Map<String, FakeCliHandler> _handlers = {};

  /// Every `run` call in order, including unhandled ones.
  final List<FakeCliCall> calls = [];

  /// Register (or replace) the handler for a subcommand path such as `add`,
  /// `update`, `settings get` or `folder new`. Dispatch picks the longest
  /// registered path that equals the call's leading words.
  void on(String subcommand, FakeCliHandler handler) {
    _handlers[subcommand] = handler;
  }

  /// Calls handled by (or, if unhandled, starting with) [subcommand].
  List<FakeCliCall> callsFor(String subcommand) =>
      calls.where((c) => c.subcommand == subcommand).toList();

  /// A successful result (exit 0) with [stdout].
  static MemexResult ok([String stdout = '']) =>
      MemexResult(exitCode: 0, stdout: stdout, stderr: '');

  /// A C1 failure: exit 1 and one JSON line on stderr,
  /// `{"error":{"code":…,"message":…, ...fields}}`.
  static MemexResult error(
    String code,
    String message, [
    Map<String, Object?> fields = const {},
  ]) => MemexResult(
    exitCode: 1,
    stdout: '',
    stderr:
        '${jsonEncode({
          'error': {'code': code, 'message': message, ...fields},
        })}\n',
  );

  /// A failure with raw (non-JSON or hand-written JSON) [stderr].
  static MemexResult failure(String stderr, {int exitCode = 1}) =>
      MemexResult(exitCode: exitCode, stdout: '', stderr: stderr);

  @override
  Future<MemexResult> run(List<String> args, {String? stdinBody}) async {
    final words = <String>[];
    for (final a in args) {
      if (a.startsWith('-')) break;
      words.add(a);
    }
    String? matched;
    for (var n = words.length; n > 0; n--) {
      final candidate = words.take(n).join(' ');
      if (_handlers.containsKey(candidate)) {
        matched = candidate;
        break;
      }
    }
    final call = FakeCliCall(
      args: List.unmodifiable(args),
      stdinBody: stdinBody,
      subcommand: matched ?? words.join(' '),
    );
    calls.add(call);
    if (matched == null) {
      return error(
        'internal',
        'FakeMemexCli: no handler for ${args.join(' ')}',
      );
    }
    return await _handlers[matched]!(call);
  }
}
