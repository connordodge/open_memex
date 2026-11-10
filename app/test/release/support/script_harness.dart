// Shared harness for the release script tests under app/test/release/.
//
// Frozen contract (#369; #370, #375 and #376 build on it). These
// signatures never change; helpers may be added:
//   Future<ScriptResult> runScript(String repoRelativePath, List<String> args,
//       {Map<String, String> env, String? workingDirectory, String? stdin})
//   Future<IsolatedEnv> isolatedEnv()
//   String leakPath(String name)
//
// Fixtures never hold a literal leak: build every failing home path or email
// at runtime (leakPath, List.join), so the repo's own files pass the Leak
// check.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The exit code, stdout and stderr of one script run.
class ScriptResult {
  ScriptResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  /// stdout followed by stderr.
  String get output => '$stdout\n$stderr';

  @override
  String toString() =>
      'ScriptResult(exit $exitCode)\n--- stdout ---\n$stdout\n--- stderr ---\n$stderr';
}

/// A temp HOME plus an isolated git configuration.
///
/// [env] holds `HOME`, `XDG_CONFIG_HOME`, `GIT_CONFIG_GLOBAL` (a temp file
/// with placeholder `user.name`/`user.email`, `commit.gpgsign=false` and
/// `tag.gpgsign=false`) and `GIT_CONFIG_NOSYSTEM=1`. Nothing reads the
/// developer's own git config or triggers SSH signing.
class IsolatedEnv {
  IsolatedEnv._(this.root, this.home, this.work, this.env);

  /// The temp directory that holds [home] and [work].
  final Directory root;

  /// The temp HOME directory (absolute path, as the script sees `$HOME`).
  /// It is named `fixture-home`, never `home`: a `/home/` segment would make
  /// every path under it look like a home-directory path to rule (c).
  final String home;

  /// A scratch directory for fixtures, outside [home].
  final Directory work;

  /// Environment for [runScript] and [runGit].
  final Map<String, String> env;

  bool _disposed = false;

  /// Removes the temp directories. Registered as a tear-down by
  /// [isolatedEnv]; safe to call twice.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

/// Creates an [IsolatedEnv] and registers its clean-up with `addTearDown`,
/// so call it inside a test, `setUp` or `setUpAll`.
Future<IsolatedEnv> isolatedEnv() async {
  final root = await Directory.systemTemp.createTemp('release_script_');
  final home = Directory('${root.path}/fixture-home')..createSync();
  final work = Directory('${root.path}/work')..createSync();
  final xdg = Directory('${root.path}/xdg')..createSync();
  final gitconfig = File('${root.path}/gitconfig');
  gitconfig.writeAsStringSync(
    [
      '[user]',
      '\tname = Test Person',
      '\temail = test@example.invalid',
      '[commit]',
      '\tgpgsign = false',
      '[tag]',
      '\tgpgsign = false',
      '[init]',
      '\tdefaultBranch = main',
      '',
    ].join('\n'),
  );
  final iso = IsolatedEnv._(root, home.path, work, {
    'HOME': home.path,
    'XDG_CONFIG_HOME': xdg.path,
    'GIT_CONFIG_GLOBAL': gitconfig.path,
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_TERMINAL_PROMPT': '0',
  });
  addTearDown(iso.dispose);
  return iso;
}

/// A macOS home-directory path for [name] (with leading and trailing
/// slashes), built at runtime so no source file holds one.
String leakPath(String name) => ['', 'Users', name, ''].join('/');

/// The repo root: the nearest ancestor of the current directory that holds
/// `app/pubspec.yaml` (`flutter test` runs with cwd `app/`).
String repoRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    if (File('${dir.path}/app/pubspec.yaml').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('no repo root above ${Directory.current.path}');
    }
    dir = parent;
  }
}

/// The child-process environment: the parent's, minus every `GIT_*` variable
/// and `LEAK_PATTERNS` (so a developer's or hook's settings never leak in),
/// overlaid with [env].
Map<String, String> _childEnv(Map<String, String> env) {
  final out = <String, String>{};
  Platform.environment.forEach((k, v) {
    if (k.startsWith('GIT_') || k == 'LEAK_PATTERNS') return;
    out[k] = v;
  });
  out.addAll(env);
  return out;
}

Future<ScriptResult> _run(
  String executable,
  List<String> args, {
  required Map<String, String> env,
  required String workingDirectory,
  String? stdin,
  Duration timeout = const Duration(minutes: 3),
}) async {
  final proc = await Process.start(
    executable,
    args,
    environment: _childEnv(env),
    includeParentEnvironment: false,
    workingDirectory: workingDirectory,
  );
  const decoder = Utf8Decoder(allowMalformed: true);
  final out = proc.stdout.transform(decoder).join();
  final err = proc.stderr.transform(decoder).join();
  if (stdin != null) proc.stdin.write(stdin);
  await proc.stdin.close().catchError((_) {});
  final code = await proc.exitCode.timeout(
    timeout,
    onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -9;
    },
  );
  return ScriptResult(code, await out, await err);
}

/// Runs the script at [repoRelativePath] (from the repo root) directly, so
/// its shebang and executable bit count, with [args].
///
/// [workingDirectory] defaults to the repo root. A missing script returns
/// exit 127, as a shell would.
Future<ScriptResult> runScript(
  String repoRelativePath,
  List<String> args, {
  Map<String, String> env = const {},
  String? workingDirectory,
  String? stdin,
}) async {
  final root = repoRoot();
  final path = '$root/$repoRelativePath';
  if (!File(path).existsSync()) {
    return ScriptResult(127, '', 'script not found: $repoRelativePath');
  }
  return _run(
    path,
    args,
    env: env,
    workingDirectory: workingDirectory ?? root,
    stdin: stdin,
  );
}

/// Runs `git` in [dir] with [iso]'s isolated config plus [env] (for example
/// `GIT_AUTHOR_EMAIL`). Throws when git fails.
Future<ScriptResult> runGit(
  IsolatedEnv iso,
  String dir,
  List<String> args, {
  Map<String, String> env = const {},
}) async {
  final r = await _run(
    'git',
    args,
    env: {...iso.env, ...env},
    workingDirectory: dir,
  );
  if (r.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: $r');
  }
  return r;
}

/// Runs any fixture tool ([executable] on PATH) with [iso]'s environment.
/// Throws when it fails.
Future<ScriptResult> runTool(
  IsolatedEnv iso,
  String executable,
  List<String> args, {
  required String workingDirectory,
}) async {
  final r = await _run(
    executable,
    args,
    env: iso.env,
    workingDirectory: workingDirectory,
  );
  if (r.exitCode != 0) {
    throw StateError('$executable ${args.join(' ')} failed: $r');
  }
  return r;
}
