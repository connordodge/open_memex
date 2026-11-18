// Shared harness for the release script tests under app/test/release/.
//
// Frozen contract (#369; #370, #375 and #376 build on it). These
// signatures never change; helpers may be added:
//   Future<ScriptResult> runScript(String repoRelativePath, List<String> args,
//       {Map<String, String> env, String? workingDirectory, String? stdin})
//   Future<IsolatedEnv> isolatedEnv()
//   String leakPath(String name)
//
// #35 adds the Sparkle fakes (a fake `curl`, a fake Sparkle tarball holding a
// fake `bin/sign_update`, a fake `security`) and an Ed25519 test key minted at
// run time. No private key is ever committed.
//
// Fixtures never hold a literal leak: build every failing home path or email
// at runtime (leakPath, List.join), so the repo's own files pass the Leak
// check.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

// ---------------------------------------------------------------------------
// Sparkle fakes (#35, Spec #31 requirements 5-7).
//
// The fakes log one line per call to `$FAKE_LOG` (the tool name, then each
// argument, tab-separated) and keep their state under `$FAKE_STATE`.

/// The Sparkle release build.sh pins for its `sign_update`.
const sparkleVersion = '2.10.1';

/// The SHA-256 of `Sparkle-2.10.1.tar.xz` (the GitHub Release asset).
const sparkleSha256 =
    '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27';

/// Where build.sh downloads the pinned Sparkle tarball from.
const sparkleTarballUrl =
    'https://github.com/sparkle-project/Sparkle/releases/download/'
    '$sparkleVersion/Sparkle-$sparkleVersion.tar.xz';

const _sparkleLogFn = r'''
_fake_log() {
  local n="$1" a
  shift
  {
    printf '%s' "$n"
    for a in "$@"; do printf '\t%s' "$a"; done
    printf '\n'
  } >>"$FAKE_LOG"
}
''';

/// Shell function: the fake EdDSA signature of file $2 with the base64 key
/// $1: base64 of SHA-512(key bytes, file bytes), 64 bytes like an Ed25519
/// signature. It depends on both the key and every byte of the file.
const _fakeSigFn = r'''
_fake_sig() {
  { printf '%s' "$1" | base64 -d; cat "$2"; } | shasum -a 512 | cut -d' ' -f1 |
    xxd -r -p | base64 | tr -d '\n'
}
''';

/// A fake Sparkle `sign_update` that logs as [logName].
///
/// Like the real tool (Sparkle 2): `-f`/`--ed-key-file <file>` names a
/// base64 private-key file (32-byte seed, or the legacy 96 bytes); `-p`
/// prints only the signature, otherwise it prints
/// `sparkle:edSignature="<sig>" length="<n>"`. Without a key file the real
/// tool reads the login Keychain: the fake records that in
/// `$FAKE_STATE/keychain` and fails. A bad key or file fails with exit 1.
/// `FAKE_SIGN_UPDATE_FAIL=1` makes it fail. `FAKE_SIGN_UPDATE_GARBAGE=1`
/// makes it exit 0 printing text that is not a base64 signature. Each signing appends
/// `<$0>\t<key path>\t<key base64>\t<key bytes>\t<file>\t<file sha256>\t<sig>`
/// to `$FAKE_STATE/sign_update.calls`.
String fakeSignUpdateScript(String logName) =>
    '#!/bin/bash\n$_sparkleLogFn\n$_fakeSigFn\n'
    '_fake_log $logName "\$@"\n'
    r'''
key=""
file=""
only=0
expect=""
for a in "$@"; do
  if [ -n "$expect" ]; then
    [ "$expect" = key ] && key="$a"
    expect=""
    continue
  fi
  case "$a" in
    -f | --ed-key-file) expect=key ;;
    --account | -s) expect=skip ;;
    -p) only=1 ;;
    -*) ;;
    *) file="$a" ;;
  esac
done
if [ "${FAKE_SIGN_UPDATE_FAIL:-}" = 1 ]; then
  echo "ERROR! fake sign_update: signing failed" >&2
  exit 1
fi
if [ "${FAKE_SIGN_UPDATE_GARBAGE:-}" = 1 ]; then
  echo "Signing complete, no signature to show"
  exit 0
fi
if [ -z "$key" ]; then
  printf '%s\n' "$*" >>"$FAKE_STATE/keychain"
  echo "ERROR! fake sign_update: no key file, so it read the login Keychain" >&2
  exit 1
fi
if [ -z "$file" ] || [ ! -f "$file" ]; then
  echo "ERROR! fake sign_update: the update file does not exist" >&2
  exit 1
fi
if [ ! -f "$key" ] || [ ! -r "$key" ]; then
  echo "ERROR! fake sign_update: unable to read the private key file" >&2
  exit 1
fi
b64=$(tr -d ' \n\r\t' <"$key")
case "$b64" in
  '' | *[!A-Za-z0-9+/=]*)
    echo "ERROR! fake sign_update: unable to decode the private EdDSA key" >&2
    exit 1
    ;;
esac
n=$(printf '%s' "$b64" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
if [ "$n" != 32 ] && [ "$n" != 96 ]; then
  echo "ERROR! fake sign_update: the private EdDSA key is $n bytes" >&2
  exit 1
fi
sha=$(shasum -a 256 "$file" | cut -d' ' -f1)
len=$(wc -c <"$file" | tr -d ' ')
sig=$(_fake_sig "$b64" "$file")
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$0" "$key" "$b64" "$n" "$file" "$sha" "$sig" \
  >>"$FAKE_STATE/sign_update.calls"
if [ "$only" = 1 ]; then
  printf '%s\n' "$sig"
else
  printf 'sparkle:edSignature="%s" length="%s"\n' "$sig" "$len"
fi
exit 0
''';

/// A fake Sparkle `generate_keys`: it logs and prints a placeholder. The
/// real one reads or writes the login Keychain.
const fakeGenerateKeysScript =
    '#!/bin/bash\n$_sparkleLogFn\n'
    r'''
_fake_log generate_keys "$@"
printf 'fake generate_keys: would use the login Keychain\n'
exit 0
''';

/// A fake `security` (the Keychain tool): it logs and fails like a missing
/// item (exit 44).
const fakeSecurityScript =
    '#!/bin/bash\n$_sparkleLogFn\n'
    r'''
_fake_log security "$@"
echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
exit 44
''';

/// A fake `curl`. For [sparkleTarballUrl] it serves the file at
/// `$FAKE_SPARKLE_TARBALL` (to `-o`/`--output <file>`, `-O`, or stdout).
/// Any other URL is a 404: exit 22 with `-f`/`--fail`, else a `Not Found`
/// body and exit 0, as the real curl does. `FAKE_CURL_NOT_FOUND=1` makes the
/// pinned URL a 404 too. `FAKE_CURL_FAIL=1` fails like a network error
/// (exit 6).
const fakeCurlScript =
    '#!/bin/bash\n$_sparkleLogFn\n'
    '_fake_log curl "\$@"\n'
    'want="$sparkleTarballUrl"\n'
    r'''
out=""
url=""
fail=0
remote=0
expect=""
for a in "$@"; do
  if [ -n "$expect" ]; then
    [ "$expect" = out ] && out="$a"
    expect=""
    continue
  fi
  case "$a" in
    --output) expect=out ;;
    --fail | --fail-with-body) fail=1 ;;
    --remote-name) remote=1 ;;
    http://* | https://*) url="$a" ;;
    --retry | --retry-delay | --retry-max-time | --max-time | --connect-timeout | \
      --header | --user-agent | --write-out | --proto | --proto-redir | \
      -m | -H | -A | -w | -e) expect=skip ;;
    --*) ;;
    -*)
      flags=${a#-}
      case "$flags" in *f*) fail=1 ;; esac
      case "$flags" in *O*) remote=1 ;; esac
      case "$flags" in *o) expect=out ;; esac
      ;;
  esac
done
if [ "${FAKE_CURL_FAIL:-}" = 1 ]; then
  echo "curl: (6) Could not resolve host: github.com" >&2
  exit 6
fi
if [ "$remote" = 1 ] && [ -z "$out" ]; then out="${url##*/}"; fi
if [ "$url" = "$want" ] && [ "${FAKE_CURL_NOT_FOUND:-}" != 1 ]; then
  if [ -n "$out" ]; then
    cp "$FAKE_SPARKLE_TARBALL" "$out" || exit 23
  else
    cat "$FAKE_SPARKLE_TARBALL" || exit 23
  fi
  exit 0
fi
if [ "$fail" = 1 ]; then
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
if [ -n "$out" ]; then printf 'Not Found' >"$out"; else printf 'Not Found'; fi
exit 0
''';

/// A fake Sparkle release tarball and its SHA-256.
class FakeSparkleTarball {
  FakeSparkleTarball(this.path, this.sha256);

  /// The `Sparkle-2.10.1.tar.xz` file.
  final String path;
  final String sha256;
}

/// Builds `<dir>/Sparkle-2.10.1.tar.xz` laid out like the real one
/// (`bin/sign_update`, `bin/generate_keys` and `LICENSE` at its top level).
/// Its fake `bin/sign_update` logs as `sign_update`. A different [variant]
/// gives a tarball with other bytes, so another SHA-256. [withSignUpdate]
/// false leaves `bin/sign_update` out; [signUpdateExecutable] false makes it
/// mode 644.
Future<FakeSparkleTarball> buildFakeSparkleTarball(
  String dir, {
  String variant = '',
  bool withSignUpdate = true,
  bool signUpdateExecutable = true,
}) async {
  final src = Directory('$dir/sparkle-src');
  Directory('${src.path}/bin').createSync(recursive: true);
  final tools = {
    'sign_update': fakeSignUpdateScript('sign_update'),
    'generate_keys': fakeGenerateKeysScript,
  };
  for (final e in tools.entries) {
    if (e.key == 'sign_update' && !withSignUpdate) continue;
    final f = File('${src.path}/bin/${e.key}')..writeAsStringSync(e.value);
    final mode = e.key == 'sign_update' && !signUpdateExecutable
        ? '644'
        : '755';
    final r = await Process.run('/bin/chmod', [mode, f.path]);
    if (r.exitCode != 0) throw StateError('chmod ${f.path}: ${r.stderr}');
  }
  File(
    '${src.path}/LICENSE',
  ).writeAsStringSync('Fake Sparkle LICENSE$variant\n');
  final tarball = '$dir/Sparkle-$sparkleVersion.tar.xz';
  final tar = await Process.run('/usr/bin/tar', [
    '-cJf',
    tarball,
    '-C',
    src.path,
    '.',
  ]);
  if (tar.exitCode != 0) throw StateError('tar: ${tar.stderr}');
  final sum = await Process.run('/usr/bin/shasum', ['-a', '256', tarball]);
  if (sum.exitCode != 0) throw StateError('shasum: ${sum.stderr}');
  return FakeSparkleTarball(
    tarball,
    (sum.stdout as String).split(RegExp(r'\s+')).first,
  );
}

/// A fresh Ed25519 private key in the `generate_keys -x` export format:
/// 32 random bytes (the seed), base64. Minted at test time, never committed.
String mintEdKeyBase64() {
  final rnd = Random.secure();
  return base64Encode(List<int>.generate(32, (_) => rnd.nextInt(256)));
}

/// The signature the fake `sign_update` makes for [file] with [keyBase64].
Future<String> fakeEdSignature(String keyBase64, String file) async {
  final r = await Process.run('/bin/bash', [
    '-c',
    '$_fakeSigFn\n_fake_sig "\$1" "\$2"',
    '_',
    keyBase64,
    file,
  ]);
  if (r.exitCode != 0) throw StateError('fake signature: ${r.stderr}');
  return (r.stdout as String).trim();
}

/// One signing the fake `sign_update` did.
class SignUpdateCall {
  SignUpdateCall(
    this.bin,
    this.keyPath,
    this.keyBase64,
    this.keyBytes,
    this.file,
    this.fileSha256,
    this.signature,
  );

  /// The `sign_update` that ran (its `$0`).
  final String bin;
  final String keyPath;

  /// The key file's contents as the tool read them (white space removed).
  final String keyBase64;
  final int keyBytes;
  final String file;

  /// The SHA-256 of [file] when it was signed.
  final String fileSha256;
  final String signature;

  @override
  String toString() => 'sign_update $bin -f $keyPath ($keyBytes bytes) $file';
}

/// The signings recorded under [stateDir] (`$FAKE_STATE`), in order.
List<SignUpdateCall> signUpdateCalls(String stateDir) {
  final f = File('$stateDir/sign_update.calls');
  if (!f.existsSync()) return [];
  return f.readAsLinesSync().where((l) => l.isNotEmpty).map((l) {
    final p = l.split('\t');
    return SignUpdateCall(p[0], p[1], p[2], int.parse(p[3]), p[4], p[5], p[6]);
  }).toList();
}

/// Whether any fake `sign_update` ran without a key file (so the real one
/// would have read the login Keychain), from [stateDir] (`$FAKE_STATE`).
bool signUpdateReadKeychain(String stateDir) =>
    File('$stateDir/keychain').existsSync();
