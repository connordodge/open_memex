// Tests for scripts/release/build.sh (#375, Spec #367 requirements 13, 19,
// 21-23).
//
// Every run uses a fixture checkout: a temp git repo holding copies of the
// release scripts, the Leak check and the files the build reads. Fake
// `cargo`, `flutter`, `codesign`, `xcrun`, `hdiutil`, `ditto`, `lipo` and
// `gh` sit first on a minimal PATH (fake bin, /usr/bin, /bin, /usr/sbin,
// /sbin). Each fake appends one line per call to a shared log: the tool name,
// then each argument, tab-separated. Nothing real is built, signed,
// notarized, stapled or uploaded, and the developer's own checkout is never
// written to.
//
// The fakes' contract (build.sh must find each tool on PATH, never by an
// absolute path):
//   cargo build    writes <target-dir>/<triple>/<profile>/memex, where
//                  <target-dir> is --target-dir, else $CARGO_TARGET_DIR, else
//                  ./target; it records MACOSX_DEPLOYMENT_TARGET and
//                  RUSTFLAGS. cargo metadata prints the fixture metadata.
//   flutter build macos  (run in the Flutter project dir) writes
//                  build/macos/Build/Products/<Mode>/Open Memex.app with
//                  four versioned frameworks and one dylib.
//   codesign       appends `FAKE-CODESIGN <identity>` to each signed file
//                  (a bundle gets _CodeSignature/CodeResources); --verify
//                  passes unless FAKE_CODESIGN_VERIFY_FAIL=1.
//   xcrun notarytool submit  prints a submission id and a status (JSON with
//                  --output-format json); `notarytool log <id>` prints the
//                  notarization log. xcrun stapler staple marks its target.
//   hdiutil create -srcfolder <dir> ... <image>  writes a tar of <dir> as the
//                  image; attach extracts it to -mountpoint; detach of a
//                  read-write attach writes it back; convert copies.
//   ditto          runs the real /usr/bin/ditto; lipo -archs prints arm64.
//
// Fixtures never hold a literal leak: planted home paths and emails are
// built at runtime.
@Timeout(Duration(minutes: 8))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/script_harness.dart';

const _build = 'scripts/release/build.sh';
const _version = '0.1.0';
const _dmgName = 'Open-Memex-0.1.0-arm64.dmg';
const _zipName = 'memex-0.1.0-macos-arm64.zip';
const _notices = 'THIRD_PARTY_NOTICES.txt';
const _sums = 'SHA256SUMS.txt';
const _volume = 'Open Memex 0.1.0';
const _appName = 'Open Memex.app';
const _identity = 'Developer ID Application: Test Person (TEAM123456)';
const _keyId = 'FAKEKEY123';
const _issuer = '00000000-1111-4222-8333-444444444444';
const _warn = 'LEAK WARN: no deny-list';
const _firstSubmissionId = '00000000-0000-4000-8000-000000000001';

const _memexMarker = 'FAKE-MEMEX-BINARY';
const _crateMarker = 'BUILD-FIXTURE serde licence text';
const _oflMarker = 'BUILD-FIXTURE Inter Tight OFL text';
const _stapleMarker = 'FAKE-STAPLED-TICKET';
const _notaryLogMarker = 'FAKE-NOTARY-LOG';

/// The nested code the fake app holds: build.sh signs each one.
const _nestedExpected = [
  'App.framework',
  'FlutterMacOS.framework',
  'CSQLite.framework',
  'objective_c.framework',
  'libfake_plugin.dylib',
];

// Runtime-built leaks (never literal in the source).
final _strangerRoot = leakPath('stranger');
final _stranger = '${_strangerRoot}work/src/main.rs';
final _denyEmail = ['planted.person', 'example.org'].join('@');
final _unusedDeny = ['nobody.here', 'example.net'].join('@');

/// Files copied from the real checkout into each fixture checkout. Missing
/// ones are skipped (on main the release scripts do not exist yet).
const _copied = [
  'scripts/release',
  'scripts/leak-check.sh',
  'scripts/leak-allow.txt',
  'LICENSE',
  '.gitignore',
  'Cargo.toml',
  'Cargo.lock',
  'crates/memex-mcp/Cargo.toml',
  'crates/memex-core/Cargo.toml',
  'app/pubspec.yaml',
  'app/pubspec.lock',
  'app/macos/Runner/Release.entitlements',
  'app/macos/Runner/Configs',
];

// ---------------------------------------------------------------------------
// Fake tools.

const _logFn = r'''
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

const _fakeCargo = r'''
_fake_log cargo "$@"
case "${1:-}" in
  metadata)
    cat "$FAKE_CARGO_METADATA"
    exit 0
    ;;
  build)
    {
      printf 'MACOSX_DEPLOYMENT_TARGET=%s\n' "${MACOSX_DEPLOYMENT_TARGET-<unset>}"
      printf 'RUSTFLAGS=%s\n' "${RUSTFLAGS-<unset>}"
    } >>"$FAKE_ENV_LOG"
    td="${CARGO_TARGET_DIR:-$PWD/target}"
    triple=""
    profile=debug
    prev=""
    for a in "$@"; do
      case "$prev" in
        --target-dir) td="$a" ;;
        --target) triple="$a" ;;
      esac
      case "$a" in
        --target-dir=*) td="${a#--target-dir=}" ;;
        --target=*) triple="${a#--target=}" ;;
        --release) profile=release ;;
      esac
      prev="$a"
    done
    if [ -n "$triple" ]; then d="$td/$triple/$profile"; else d="$td/$profile"; fi
    mkdir -p "$d" || exit 1
    printf 'FAKE-MEMEX-BINARY\000\001\002%s\000end\n' "${FAKE_MEMEX_PLANT:-}" >"$d/memex"
    chmod +x "$d/memex"
    exit 0
    ;;
esac
exit 0
''';

const _fakeFlutter = r'''
_fake_log flutter "$@"
if [ "${1:-}" = build ] && [ "${2:-}" = macos ]; then
  mode=Debug
  for a in "$@"; do [ "$a" = --release ] && mode=Release; done
  if [ ! -f pubspec.yaml ]; then
    echo "fake flutter: no pubspec.yaml in the working directory" >&2
    exit 1
  fi
  app="$PWD/build/macos/Build/Products/$mode/Open Memex.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" || exit 1
  cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Open Memex</string>
	<key>CFBundleIdentifier</key>
	<string>dev.openmemex.openMemexApp</string>
	<key>CFBundleName</key>
	<string>Open Memex</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
PLIST
  printf 'APPL????' >"$app/Contents/PkgInfo"
  printf 'FAKE-RUNNER\000\001%s\000end\n' "${FAKE_RUNNER_PLANT:-}" >"$app/Contents/MacOS/Open Memex"
  chmod +x "$app/Contents/MacOS/Open Memex"
  printf 'fake icon\n' >"$app/Contents/Resources/AppIcon.icns"
  for f in App FlutterMacOS CSQLite objective_c; do
    fw="$app/Contents/Frameworks/$f.framework"
    mkdir -p "$fw/Versions/A/Resources"
    printf 'FAKE-FRAMEWORK %s\000end\n' "$f" >"$fw/Versions/A/$f"
    printf '<plist version="1.0"><dict/></plist>\n' >"$fw/Versions/A/Resources/Info.plist"
    ln -s A "$fw/Versions/Current"
    ln -s "Versions/Current/$f" "$fw/$f"
    ln -s Versions/Current/Resources "$fw/Resources"
  done
  printf 'FAKE-DYLIB\000end\n' >"$app/Contents/Frameworks/libfake_plugin.dylib"
fi
exit 0
''';

const _fakeCodesign = r'''
_fake_log codesign "$@"
for a in "$@"; do
  case "$a" in
    --verify | -v | -vv | -vvv | -vvvv)
      if [ "${FAKE_CODESIGN_VERIFY_FAIL:-}" = 1 ]; then
        echo "fake codesign: a sealed resource is missing or invalid" >&2
        exit 1
      fi
      exit 0
      ;;
  esac
done
ident=""
signing=0
prev=""
for a in "$@"; do
  case "$prev" in
    --sign | -s | -[A-Za-z]s | -[A-Za-z][A-Za-z]s) ident="$a"; signing=1 ;;
  esac
  case "$a" in
    --sign=*) ident="${a#--sign=}"; signing=1 ;;
  esac
  prev="$a"
done
[ "$signing" = 1 ] || exit 0
prev=""
for a in "$@"; do
  skip=0
  case "$prev" in
    --sign | -s | -[A-Za-z]s | -[A-Za-z][A-Za-z]s | --entitlements | --options | -o | \
      --identifier | -i | --keychain | --requirements | -r | --prefix) skip=1 ;;
  esac
  case "$a" in -*) skip=1 ;; esac
  if [ "$skip" = 0 ]; then
    if [ -d "$a/Contents" ]; then
      mkdir -p "$a/Contents/_CodeSignature"
      printf 'FAKE-CODESIGN %s\n' "$ident" >"$a/Contents/_CodeSignature/CodeResources"
    elif [ -d "$a" ]; then
      mkdir -p "$a/_CodeSignature"
      printf 'FAKE-CODESIGN %s\n' "$ident" >"$a/_CodeSignature/CodeResources"
    elif [ -f "$a" ]; then
      printf '\nFAKE-CODESIGN %s\n' "$ident" >>"$a"
    fi
  fi
  prev="$a"
done
exit 0
''';

const _fakeXcrun = r'''
_fake_log xcrun "$@"
tool="${1:-}"
[ $# -gt 0 ] && shift
case "$tool" in
  notarytool)
    sub="${1:-}"
    [ $# -gt 0 ] && shift
    json=0
    prev=""
    for a in "$@"; do
      if [ "$a" = json ] && { [ "$prev" = --output-format ] || [ "$prev" = -f ]; }; then json=1; fi
      [ "$a" = --output-format=json ] && json=1
      prev="$a"
    done
    case "$sub" in
      submit)
        n=$(cat "$FAKE_STATE/notary-n" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" >"$FAKE_STATE/notary-n"
        id="00000000-0000-4000-8000-00000000000$n"
        if [ "${FAKE_NOTARY_FAIL:-}" = 1 ]; then
          status=Invalid
          code="${FAKE_NOTARY_INVALID_EXIT:-1}"
        else
          status=Accepted
          code=0
        fi
        if [ "$json" = 1 ]; then
          printf '{"id":"%s","message":"Processing complete","status":"%s"}\n' "$id" "$status"
        else
          printf 'Conducting pre-submission checks and initiating connection to the Apple notary service...\n'
          printf 'Submission ID received\n  id: %s\n' "$id"
          printf 'Successfully uploaded file\nWaiting for processing to complete.\n'
          printf 'Current status: %s\nProcessing complete\n  id: %s\n  status: %s\n' "$status" "$id" "$status"
        fi
        exit "$code"
        ;;
      log)
        printf '{"jobId":"%s","status":"Invalid","statusSummary":"Archive contains critical validation errors","issues":[{"severity":"error","message":"FAKE-NOTARY-LOG: The binary is not signed with a valid Developer ID certificate."}]}\n' "${1:-}"
        exit 0
        ;;
    esac
    exit 0
    ;;
  stapler)
    sub="${1:-}"
    [ $# -gt 0 ] && shift
    if [ "$sub" = staple ]; then
      p=""
      for a in "$@"; do p="$a"; done
      if [ -d "$p/Contents" ]; then
        printf 'FAKE-STAPLED-TICKET\n' >"$p/Contents/CodeResources"
      elif [ -f "$p" ]; then
        printf '\nFAKE-STAPLED-TICKET\n' >>"$p"
      else
        echo "fake stapler: nothing to staple at the given path" >&2
        exit 1
      fi
      echo "The staple and validate action worked!"
    fi
    exit 0
    ;;
esac
exit 0
''';

const _fakeHdiutil = r'''
_fake_log hdiutil "$@"
sub="${1:-}"
[ $# -gt 0 ] && shift
last=""
for a in "$@"; do last="$a"; done
case "$sub" in
  create)
    src=""
    prev=""
    for a in "$@"; do
      [ "$prev" = -srcfolder ] && src="$a"
      prev="$a"
    done
    out="$last"
    case "$out" in *.dmg) ;; *) out="$out.dmg" ;; esac
    mkdir -p "$(dirname "$out")" || exit 1
    if [ -z "$src" ]; then
      src=$(mktemp -d "${TMPDIR:-/tmp}/fakeimg.XXXXXX") || exit 1
    fi
    tar -cf "$out" -C "$src" . || exit 1
    if [ -n "${FAKE_DMG_PLANT:-}" ]; then
      p=$(mktemp -d "${TMPDIR:-/tmp}/fakeplant.XXXXXX") || exit 1
      printf 'planted %s\n' "$FAKE_DMG_PLANT" >"$p/planted.txt"
      tar -rf "$out" -C "$p" planted.txt || exit 1
    fi
    echo "created: $out"
    exit 0
    ;;
  attach)
    mp=""
    ro=0
    img=""
    prev=""
    for a in "$@"; do
      [ "$prev" = -mountpoint ] && mp="$a"
      [ "$a" = -readonly ] && ro=1
      if [ "$prev" != -mountpoint ] && [ -f "$a" ]; then img="$a"; fi
      prev="$a"
    done
    if [ -z "$img" ]; then
      echo "fake hdiutil: attach needs an image" >&2
      exit 1
    fi
    [ -n "$mp" ] || mp=$(mktemp -d "${TMPDIR:-/tmp}/fakevol.XXXXXX") || exit 1
    mkdir -p "$mp" || exit 1
    tar -xf "$img" -C "$mp" 2>/dev/null
    printf '%s\t%s\t%s\n' "$mp" "$img" "$ro" >>"$FAKE_STATE/mounts"
    printf '/dev/disk99\tGUID_partition_scheme\t\n/dev/disk99s1\tApple_HFS\t%s\n' "$mp"
    exit 0
    ;;
  detach | eject)
    m="${1:-}"
    if [ -f "$FAKE_STATE/mounts" ]; then
      while IFS="$(printf '\t')" read -r mp img ro; do
        if [ "$mp" = "$m" ] && [ "$ro" = 0 ]; then tar -cf "$img" -C "$mp" .; fi
      done <"$FAKE_STATE/mounts"
    fi
    exit 0
    ;;
  convert)
    in="${1:-}"
    out=""
    prev=""
    for a in "$@"; do
      [ "$prev" = -o ] && out="$a"
      prev="$a"
    done
    case "$out" in *.dmg) ;; *) out="$out.dmg" ;; esac
    cp "$in" "$out" || exit 1
    exit 0
    ;;
esac
exit 0
''';

const _fakeDitto = r'''
_fake_log ditto "$@"
exec /usr/bin/ditto "$@"
''';

const _fakeLipo = r'''
_fake_log lipo "$@"
last=""
for a in "$@"; do last="$a"; done
for a in "$@"; do
  case "$a" in
    -archs) echo arm64; exit 0 ;;
    -info) echo "Non-fat file: $last is architecture: arm64"; exit 0 ;;
  esac
done
exit 0
''';

const _fakeGh = r'''
_fake_log gh "$@"
exit 0
''';

const _fakes = {
  'cargo': _fakeCargo,
  'flutter': _fakeFlutter,
  'codesign': _fakeCodesign,
  'xcrun': _fakeXcrun,
  'hdiutil': _fakeHdiutil,
  'ditto': _fakeDitto,
  'lipo': _fakeLipo,
  'gh': _fakeGh,
};

// ---------------------------------------------------------------------------
// Fixture checkout.

class _Fx {
  _Fx(this.iso, this.root, this.bin, this.state, this.out);

  final IsolatedEnv iso;

  /// The fixture checkout (a committed git repo).
  final String root;
  final String bin;
  final String state;

  /// The --out directory the tests pass (not created up front).
  final String out;

  String get log => '$state/tools.log';
  String get envLog => '$state/cargo-env.log';
  String get metadata => '$state/metadata.json';
  String get p8 => '$state/AuthKey_$_keyId.p8';
}

Future<void> _sh(List<String> argv, {String? cwd}) async {
  final r = await Process.run(
    argv.first,
    argv.sublist(1),
    workingDirectory: cwd,
  );
  if (r.exitCode != 0) {
    throw StateError('${argv.join(' ')} failed: ${r.stdout}\n${r.stderr}');
  }
}

/// A fixture checkout with fake tools. [licenseExtra] is appended to the
/// fixture's LICENSE (which only the memex zip carries).
Future<_Fx> _fixture({String licenseExtra = ''}) async {
  final iso = await isolatedEnv();
  final w = iso.work.path;
  final root = '$w/checkout';
  final bin = '$w/fakebin';
  final state = '$w/state';
  for (final d in [root, bin, state]) {
    Directory(d).createSync(recursive: true);
  }
  final fx = _Fx(iso, root, bin, state, '$w/out');

  final src = repoRoot();
  for (final rel in _copied) {
    final from = '$src/$rel';
    if (!File(from).existsSync() && !Directory(from).existsSync()) continue;
    final to = '$root/$rel';
    Directory(File(to).parent.path).createSync(recursive: true);
    await _sh(['/bin/cp', '-Rp', from, to]);
  }
  final license = File('$root/LICENSE');
  if (!license.existsSync()) license.writeAsStringSync('MIT License\n');
  if (licenseExtra.isNotEmpty) {
    license.writeAsStringSync('\n$licenseExtra\n', mode: FileMode.append);
  }

  // The OFL texts in the notices generator's default fonts directory.
  final fonts = Directory('$root/app/assets/google_fonts')
    ..createSync(recursive: true);
  File(
    '${fonts.path}/OFL-InterTight.txt',
  ).writeAsStringSync('SIL OPEN FONT LICENSE Version 1.1\n$_oflMarker\n');
  File('${fonts.path}/OFL-JetBrainsMono.txt').writeAsStringSync(
    'SIL OPEN FONT LICENSE Version 1.1\nBUILD-FIXTURE JetBrains Mono OFL text\n',
  );
  File('${fonts.path}/OFL-Newsreader.txt').writeAsStringSync(
    'SIL OPEN FONT LICENSE Version 1.1\nBUILD-FIXTURE Newsreader OFL text\n',
  );
  File('${fonts.path}/InterTight-Regular.ttf').writeAsStringSync('fake font');

  // cargo metadata: memex-mcp (a workspace member) links serde.
  final serdeDir = Directory('$w/registry/serde-1.0.228')
    ..createSync(recursive: true);
  File('${serdeDir.path}/Cargo.toml').writeAsStringSync('[package]\n');
  File('${serdeDir.path}/LICENSE-MIT').writeAsStringSync('$_crateMarker\n');
  final mcpId = 'path+file://$root/crates/memex-mcp#0.1.0';
  const serdeId =
      'registry+https://github.com/rust-lang/crates.io-index#serde@1.0.228';
  File(fx.metadata).writeAsStringSync(
    jsonEncode({
      'packages': [
        {
          'name': 'memex-mcp',
          'version': '0.1.0',
          'id': mcpId,
          'license': 'MIT',
          'license_file': null,
          'source': null,
          'manifest_path': '$root/crates/memex-mcp/Cargo.toml',
          'dependencies': [],
          'targets': [],
          'features': {},
        },
        {
          'name': 'serde',
          'version': '1.0.228',
          'id': serdeId,
          'license': 'MIT OR Apache-2.0',
          'license_file': null,
          'source': 'registry+https://github.com/rust-lang/crates.io-index',
          'manifest_path': '${serdeDir.path}/Cargo.toml',
          'dependencies': [],
          'targets': [],
          'features': {},
        },
      ],
      'workspace_members': [mcpId],
      'workspace_default_members': [mcpId],
      'resolve': {
        'nodes': [
          {
            'id': mcpId,
            'dependencies': [serdeId],
            'deps': [
              {
                'name': 'serde',
                'pkg': serdeId,
                'dep_kinds': [
                  {'kind': null, 'target': null},
                ],
              },
            ],
            'features': [],
          },
          {'id': serdeId, 'dependencies': [], 'deps': [], 'features': []},
        ],
        'root': null,
      },
      'target_directory': '$root/target',
      'version': 1,
      'workspace_root': root,
      'metadata': null,
    }),
  );

  File(fx.p8).writeAsStringSync(
    '-----BEGIN PRIVATE KEY-----\nZmFrZQ==\n-----END PRIVATE KEY-----\n',
  );

  for (final e in _fakes.entries) {
    final f = File('$bin/${e.key}');
    f.writeAsStringSync('#!/bin/bash\n$_logFn\n${e.value}');
    await _sh(['/bin/chmod', '755', f.path]);
  }

  await runGit(iso, root, ['init', '-q']);
  await runGit(iso, root, ['add', '-A']);
  await runGit(iso, root, ['commit', '-q', '-m', 'fixture checkout']);
  return fx;
}

/// Runs the fixture's build.sh with a from-scratch environment: the fake
/// PATH, the isolated HOME and git config, the fake-tool settings and [env].
Future<ScriptResult> _runBuild(
  _Fx fx,
  List<String> args, {
  Map<String, String> env = const {},
}) async {
  final script = '${fx.root}/$_build';
  if (!File(script).existsSync()) {
    return ScriptResult(127, '', 'script not found: $_build');
  }
  final environment = <String, String>{
    'PATH': '${fx.bin}:/usr/bin:/bin:/usr/sbin:/sbin',
    'TMPDIR': Platform.environment['TMPDIR'] ?? '/tmp',
    'LANG': 'en_US.UTF-8',
    'USER': 'test',
    'LOGNAME': 'test',
    ...fx.iso.env,
    'FAKE_LOG': fx.log,
    'FAKE_ENV_LOG': fx.envLog,
    'FAKE_STATE': fx.state,
    'FAKE_CARGO_METADATA': fx.metadata,
    ...env,
  };
  final proc = await Process.start(
    script,
    args,
    environment: environment,
    includeParentEnvironment: false,
    workingDirectory: fx.root,
  );
  const decoder = Utf8Decoder(allowMalformed: true);
  final out = proc.stdout.transform(decoder).join();
  final err = proc.stderr.transform(decoder).join();
  await proc.stdin.close().catchError((_) {});
  final code = await proc.exitCode.timeout(
    const Duration(minutes: 3),
    onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -9;
    },
  );
  return ScriptResult(code, await out, await err);
}

List<String> _dryArgs(_Fx fx) => [
  '--dry-run',
  '--version',
  _version,
  '--out',
  fx.out,
];

List<String> _signedArgs(_Fx fx) => ['--version', _version, '--out', fx.out];

Map<String, String> _signedEnv(_Fx fx) => {
  'MACOS_SIGN_IDENTITY': _identity,
  'NOTARY_KEY_P8_PATH': fx.p8,
  'NOTARY_KEY_ID': _keyId,
  'NOTARY_ISSUER_ID': _issuer,
  'LEAK_PATTERNS': _unusedDeny,
};

// ---------------------------------------------------------------------------
// Reading the results.

class _Call {
  _Call(this.tool, this.args);

  final String tool;
  final List<String> args;

  @override
  String toString() => '$tool ${args.join(' ')}';
}

List<_Call> _calls(_Fx fx) {
  final f = File(fx.log);
  if (!f.existsSync()) return [];
  return f.readAsLinesSync().where((l) => l.isNotEmpty).map((l) {
    final p = l.split('\t');
    return _Call(p.first, p.sublist(1));
  }).toList();
}

String _callList(List<_Call> calls) =>
    calls.asMap().entries.map((e) => '${e.key}: ${e.value}').join('\n');

final _stepLine = RegExp(r'^STEP (\d+)\b', multiLine: true);
final _failedLine = RegExp(r'^FAILED (\d+) \S', multiLine: true);
final _leakLine = RegExp(r'^LEAK \S.*:\d+ (\S+)', multiLine: true);

/// The STEP numbers in print order, from whichever stream carries them.
List<int> _steps(ScriptResult r) {
  final text = _stepLine.hasMatch(r.stdout) ? r.stdout : r.stderr;
  return _stepLine.allMatches(text).map((m) => int.parse(m.group(1)!)).toList();
}

List<int> _failed(ScriptResult r) => _failedLine
    .allMatches(r.output)
    .map((m) => int.parse(m.group(1)!))
    .toList();

List<String> _leakRules(ScriptResult r) =>
    _leakLine.allMatches(r.output).map((m) => m.group(1)!).toList();

const _codesignValueOpts = {
  '-s',
  '--sign',
  '--entitlements',
  '-o',
  '--options',
  '-i',
  '--identifier',
  '--keychain',
  '-r',
  '--requirements',
  '--prefix',
};
final _combinedSign = RegExp(r'^-[A-Za-z]{0,2}s$');

bool _isSign(_Call c) =>
    c.tool == 'codesign' &&
    !c.args.contains('--verify') &&
    c.args.any(
      (a) =>
          a == '--sign' ||
          a.startsWith('--sign=') ||
          (!a.startsWith('--') && _combinedSign.hasMatch(a)),
    );

bool _isVerify(_Call c) => c.tool == 'codesign' && c.args.contains('--verify');

String? _identityOf(_Call c) {
  for (var i = 0; i < c.args.length; i++) {
    final a = c.args[i];
    if (a.startsWith('--sign=')) return a.substring('--sign='.length);
    if ((a == '--sign' || (!a.startsWith('--') && _combinedSign.hasMatch(a))) &&
        i + 1 < c.args.length) {
      return c.args[i + 1];
    }
  }
  return null;
}

/// The paths a codesign call acts on.
List<String> _targets(_Call c) {
  final out = <String>[];
  for (var i = 0; i < c.args.length; i++) {
    final a = c.args[i];
    if (a.startsWith('-')) {
      if (!a.contains('=') &&
          (_codesignValueOpts.contains(a) ||
              (!a.startsWith('--') && _combinedSign.hasMatch(a)))) {
        i++;
      }
      continue;
    }
    out.add(a);
  }
  return out;
}

String? _optValue(_Call c, String name) {
  for (var i = 0; i < c.args.length; i++) {
    final a = c.args[i];
    if (a == name && i + 1 < c.args.length) return c.args[i + 1];
    if (a.startsWith('$name=')) return a.substring(name.length + 1);
  }
  return null;
}

/// `memex`, `nested:<name>`, `app`, `dmg` or `other`.
String _kind(String path) {
  var s = path;
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('/Contents/MacOS/memex')) return 'memex';
  if (s.endsWith('.dmg')) return 'dmg';
  final fw = RegExp(r'([^/]+\.framework)(/|$)').firstMatch(s);
  if (fw != null) return 'nested:${fw.group(1)}';
  if (s.endsWith('.dylib')) return 'nested:${s.split('/').last}';
  if (s.endsWith('.app')) return 'app';
  return 'other';
}

class _Signing {
  _Signing(this.index, this.call, this.kind);

  final int index;
  final _Call call;
  final String kind;
}

/// Every signing of memex, nested code or the app, in call order.
List<_Signing> _inAppSignings(List<_Call> calls) {
  final out = <_Signing>[];
  for (var i = 0; i < calls.length; i++) {
    final c = calls[i];
    if (!_isSign(c)) continue;
    for (final t in _targets(c)) {
      final k = _kind(t);
      if (k == 'memex' || k == 'app' || k.startsWith('nested:')) {
        out.add(_Signing(i, c, k));
      }
    }
  }
  return out;
}

/// Asserts memex, then every nested framework and dylib, then the app.
void _expectInsideOut(List<_Call> calls) {
  final s = _inAppSignings(calls);
  final kinds = s.map((e) => e.kind).toList();
  final why = 'signing order: $kinds\n${_callList(calls)}';
  expect(kinds, isNotEmpty, reason: why);
  expect(kinds.first, 'memex', reason: why);
  expect(kinds.last, 'app', reason: why);
  final lastMemex = kinds.lastIndexOf('memex');
  final firstApp = kinds.indexOf('app');
  final nested = <String>{};
  for (var i = 0; i < kinds.length; i++) {
    if (!kinds[i].startsWith('nested:')) continue;
    nested.add(kinds[i].substring('nested:'.length));
    expect(i, greaterThan(lastMemex), reason: 'nested before memex: $why');
    expect(i, lessThan(firstApp), reason: 'nested after the app: $why');
  }
  expect(nested, containsAll(_nestedExpected), reason: why);
}

/// The file a notarytool submit call sends.
String? _submitPath(_Call c) {
  const valueOpts = {
    '--key',
    '--key-id',
    '--issuer',
    '--keychain-profile',
    '-p',
    '--apple-id',
    '--team-id',
    '--password',
    '--output-format',
    '-f',
    '--timeout',
    '--webhook',
    '--keychain',
  };
  final i = c.args.indexOf('submit');
  for (var j = i + 1; j < c.args.length; j++) {
    final a = c.args[j];
    if (a.startsWith('-')) {
      if (!a.contains('=') && valueOpts.contains(a)) j++;
      continue;
    }
    return a;
  }
  return null;
}

bool _isSubmit(_Call c) =>
    c.tool == 'xcrun' &&
    c.args.isNotEmpty &&
    c.args.first == 'notarytool' &&
    c.args.contains('submit');

bool _isNotary(_Call c) =>
    c.tool == 'xcrun' && c.args.isNotEmpty && c.args.first == 'notarytool';

bool _isStaple(_Call c) =>
    c.tool == 'xcrun' &&
    c.args.length >= 2 &&
    c.args[0] == 'stapler' &&
    c.args[1] == 'staple';

bool _isStapler(_Call c) =>
    c.tool == 'xcrun' && c.args.isNotEmpty && c.args.first == 'stapler';

bool _isHdiCreate(_Call c) =>
    c.tool == 'hdiutil' && c.args.isNotEmpty && c.args.first == 'create';

int _indexWhere(List<_Call> calls, bool Function(_Call) test) {
  for (var i = 0; i < calls.length; i++) {
    if (test(calls[i])) return i;
  }
  return -1;
}

Future<String> _sha256(String path) async {
  final r = await Process.run('/usr/bin/shasum', ['-a', '256', path]);
  expect(r.exitCode, 0, reason: 'shasum $path: ${r.stderr}');
  return (r.stdout as String).split(RegExp(r'\s+')).first;
}

/// SHA256SUMS.txt lines as name -> hash.
Map<String, String> _readSums(String path) {
  final out = <String, String>{};
  final line = RegExp(r'^([0-9a-f]{64})\s+\*?(\S.*)$');
  for (final l in File(path).readAsLinesSync()) {
    if (l.trim().isEmpty) continue;
    final m = line.firstMatch(l);
    expect(m, isNotNull, reason: 'malformed SHA256SUMS line: $l');
    out[m!.group(2)!] = m.group(1)!;
  }
  return out;
}

Future<void> _expectSumsMatch(String out) async {
  final sums = _readSums('$out/$_sums');
  expect(sums.keys.toSet(), {_dmgName, _zipName, _notices});
  for (final e in sums.entries) {
    expect(
      await _sha256('$out/${e.key}'),
      e.value,
      reason: 'hash of ${e.key} in $_sums',
    );
  }
}

/// The fake DMG (a tar of the volume) extracted to a temp dir.
Future<String> _openDmg(_Fx fx, String dmg) async {
  final d = Directory('${fx.iso.work.path}/dmg-view')
    ..createSync(recursive: true);
  await Process.run('/usr/bin/tar', ['-xf', dmg, '-C', d.path]);
  return d.path;
}

/// The file entries of a zip (directories and AppleDouble entries left out).
Future<List<String>> _zipEntries(String zip) async {
  final r = await Process.run('/usr/bin/unzip', ['-Z1', zip]);
  expect(r.exitCode, 0, reason: 'unzip -Z1 $zip: ${r.stderr}');
  return (r.stdout as String)
      .split('\n')
      .where((l) => l.isNotEmpty && !l.endsWith('/'))
      .where(
        (l) =>
            !l.startsWith('__MACOSX/') && !l.split('/').last.startsWith('._'),
      )
      .toList();
}

Future<String> _unzipEntry(String zip, String entry) async {
  final r = await Process.run('/usr/bin/unzip', [
    '-p',
    zip,
    entry,
  ], stdoutEncoding: const Utf8Codec(allowMalformed: true));
  expect(r.exitCode, 0, reason: 'unzip -p $zip $entry: ${r.stderr}');
  return r.stdout as String;
}

String _readLoose(String path) => const Utf8Decoder(
  allowMalformed: true,
).convert(File(path).readAsBytesSync());

void _expectRefused(ScriptResult r, _Fx fx, String mention) {
  expect(r.exitCode, 2, reason: '$r');
  expect(_steps(r), isEmpty, reason: 'a STEP line before the refusal\n$r');
  expect(
    _calls(fx),
    isEmpty,
    reason: 'a tool ran before the refusal\n${_callList(_calls(fx))}',
  );
  expect(r.output, contains(mention), reason: 'the refusal names $mention\n$r');
}

void main() {
  group('dry run with fake tools', () {
    late _Fx fx;
    late ScriptResult r;
    late List<_Call> calls;

    setUpAll(() async {
      fx = await _fixture();
      r = await _runBuild(fx, _dryArgs(fx));
      calls = _calls(fx);
    });

    test(
      'dry run prints STEP 1 to STEP 10 in order and exits 0 with leaks 0',
      () {
        expect(r.exitCode, 0, reason: '$r');
        expect(_steps(r), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], reason: '$r');
        expect(_failed(r), isEmpty, reason: '$r');
        expect(r.output, contains('leaks: 0'), reason: '$r');
        // No deny-list is set, so the dry run lets the Leak check run without
        // one, and the check says so.
        expect(r.output, contains(_warn), reason: '$r');
        // The tools run in step order.
        final cargoBuild = _indexWhere(
          calls,
          (c) => c.tool == 'cargo' && c.args.contains('build'),
        );
        final flutterBuild = _indexWhere(
          calls,
          (c) =>
              c.tool == 'flutter' && c.args.take(2).join(' ') == 'build macos',
        );
        final firstSign = _indexWhere(calls, _isSign);
        final dmg = _indexWhere(calls, _isHdiCreate);
        final why = _callList(calls);
        expect(cargoBuild, greaterThanOrEqualTo(0), reason: why);
        expect(flutterBuild, greaterThan(cargoBuild), reason: why);
        expect(firstSign, greaterThan(flutterBuild), reason: why);
        expect(dmg, greaterThan(firstSign), reason: why);
      },
    );

    test(
      'dry run signs memex then every framework and dylib then the app with an ad hoc identity',
      () {
        expect(r.exitCode, 0, reason: '$r');
        _expectInsideOut(calls);
        for (final s in _inAppSignings(calls)) {
          expect(_identityOf(s.call), '-', reason: 'identity in ${s.call}');
          expect(
            s.call.args.contains('--timestamp'),
            isFalse,
            reason: 'a dry run signs without a timestamp: ${s.call}',
          );
          final ts = s.call.args.where((a) => a.startsWith('--timestamp='));
          expect(
            ts.every((a) => a == '--timestamp=none'),
            isTrue,
            reason: 'a dry run signs without a timestamp: ${s.call}',
          );
        }
        // codesign --verify --deep --strict checks the app after it is signed.
        final appSigned = _inAppSignings(
          calls,
        ).lastWhere((s) => s.kind == 'app').index;
        final verify = _indexWhere(
          calls,
          (c) =>
              _isVerify(c) &&
              c.args.contains('--deep') &&
              c.args.contains('--strict') &&
              _targets(c).any((t) => _kind(t) == 'app'),
        );
        expect(verify, greaterThan(appSigned), reason: _callList(calls));
      },
    );

    test('dry run never calls notarytool or stapler and never uploads', () {
      expect(r.exitCode, 0, reason: '$r');
      expect(_steps(r), contains(6), reason: '$r');
      expect(calls.where(_isHdiCreate), isNotEmpty, reason: _callList(calls));
      expect(calls.where(_isNotary), isEmpty, reason: _callList(calls));
      expect(calls.where(_isStapler), isEmpty, reason: _callList(calls));
      expect(
        calls.where((c) => c.tool == 'gh'),
        isEmpty,
        reason: _callList(calls),
      );
    });

    test(
      'dry run gets packages with the lockfile enforced before building the macOS app in release mode',
      () {
        expect(r.exitCode, 0, reason: '$r');
        final pubGet = _indexWhere(
          calls,
          (c) =>
              c.tool == 'flutter' &&
              c.args.take(2).join(' ') == 'pub get' &&
              c.args.contains('--enforce-lockfile'),
        );
        final build = _indexWhere(
          calls,
          (c) =>
              c.tool == 'flutter' &&
              c.args.take(2).join(' ') == 'build macos' &&
              c.args.contains('--release'),
        );
        expect(pubGet, greaterThanOrEqualTo(0), reason: _callList(calls));
        expect(build, greaterThan(pubGet), reason: _callList(calls));
      },
    );

    test(
      'dry run builds memex with cargo release locked for aarch64 with deployment target 14.0 and HOME remapped',
      () {
        expect(r.exitCode, 0, reason: '$r');
        final builds = calls
            .where((c) => c.tool == 'cargo' && c.args.contains('build'))
            .toList();
        expect(builds, hasLength(1), reason: _callList(calls));
        final a = builds.single.args;
        expect(a, containsAll(['build', '--release', '--locked']));
        expect(
          _optValue(builds.single, '-p') ??
              _optValue(builds.single, '--package'),
          'memex-mcp',
          reason: '$a',
        );
        expect(
          _optValue(builds.single, '--target'),
          'aarch64-apple-darwin',
          reason: '$a',
        );
        final env = File(fx.envLog).readAsLinesSync();
        expect(env, contains('MACOSX_DEPLOYMENT_TARGET=14.0'));
        final rustflags = env.firstWhere((l) => l.startsWith('RUSTFLAGS='));
        final homes = {
          fx.iso.home,
          Directory(fx.iso.home).resolveSymbolicLinksSync(),
        };
        expect(
          homes.any(
            (h) => RegExp(
              '--remap-path-prefix[= ]${RegExp.escape(h)}/?=',
            ).hasMatch(rustflags),
          ),
          isTrue,
          reason: 'no --remap-path-prefix for HOME ($homes) in $rustflags',
        );
      },
    );

    test('the memex build also remaps the checkout root', () {
      expect(r.exitCode, 0, reason: '$r');
      final env = File(fx.envLog).readAsLinesSync();
      final rustflags = env.firstWhere((l) => l.startsWith('RUSTFLAGS='));
      final roots = {fx.root, Directory(fx.root).resolveSymbolicLinksSync()};
      expect(
        roots.any(
          (h) => RegExp(
            '--remap-path-prefix[= ]${RegExp.escape(h)}/?=',
          ).hasMatch(rustflags),
        ),
        isTrue,
        reason:
            'no --remap-path-prefix for the checkout ($roots) in $rustflags',
      );
    });

    test(
      'the DMG holds the app with the embedded memex and the notices and an Applications link',
      () async {
        expect(r.exitCode, 0, reason: '$r');
        final dmg = '${fx.out}/$_dmgName';
        expect(File(dmg).existsSync(), isTrue, reason: '$_dmgName in --out');
        final create = calls.firstWhere(_isHdiCreate);
        expect(_optValue(create, '-volname'), _volume, reason: '$create');

        final vol = await _openDmg(fx, dmg);
        final memex = File('$vol/$_appName/Contents/MacOS/memex');
        expect(memex.existsSync(), isTrue, reason: 'Contents/MacOS/memex');
        expect(_readLoose(memex.path), contains(_memexMarker));
        final notices = File('$vol/$_appName/Contents/Resources/$_notices');
        expect(
          notices.existsSync(),
          isTrue,
          reason: 'Contents/Resources notices',
        );
        final text = notices.readAsStringSync();
        expect(text, contains(_crateMarker));
        expect(text, contains(_oflMarker));
        final link = Link('$vol/Applications');
        expect(link.existsSync(), isTrue, reason: 'Applications symlink');
        expect(link.targetSync(), '/Applications');
      },
    );

    test('the memex zip holds memex LICENSE and the notices', () async {
      expect(r.exitCode, 0, reason: '$r');
      final zip = '${fx.out}/$_zipName';
      expect(File(zip).existsSync(), isTrue, reason: '$_zipName in --out');
      final entries = await _zipEntries(zip);
      expect(entries.map((e) => e.split('/').last).toSet(), {
        'memex',
        'LICENSE',
        _notices,
      }, reason: '$entries');
      final memex = entries.firstWhere((e) => e.split('/').last == 'memex');
      expect(await _unzipEntry(zip, memex), contains(_memexMarker));
      final lic = entries.firstWhere((e) => e.split('/').last == 'LICENSE');
      expect(
        await _unzipEntry(zip, lic),
        File('${fx.root}/LICENSE').readAsStringSync(),
      );
      final n = entries.firstWhere((e) => e.split('/').last == _notices);
      expect(await _unzipEntry(zip, n), contains(_crateMarker));
    });

    test('the memex in the zip is the signed binary', () async {
      expect(r.exitCode, 0, reason: '$r');
      final zip = '${fx.out}/$_zipName';
      final entries = await _zipEntries(zip);
      final memex = entries.firstWhere((e) => e.split('/').last == 'memex');
      expect(await _unzipEntry(zip, memex), contains('FAKE-CODESIGN -'));
    });

    test(
      'SHA256SUMS lists the DMG the zip and the notices with matching hashes',
      () async {
        expect(r.exitCode, 0, reason: '$r');
        expect(File('${fx.out}/$_notices').existsSync(), isTrue);
        await _expectSumsMatch(fx.out);
        final vol = await _openDmg(fx, '${fx.out}/$_dmgName');
        expect(
          File('${fx.out}/$_notices').readAsStringSync(),
          File(
            '$vol/$_appName/Contents/Resources/$_notices',
          ).readAsStringSync(),
        );
      },
    );
  });

  group('dry run outputs and usage', () {
    test(
      'without --out the artifacts land in dist under the checkout',
      () async {
        final fx = await _fixture();
        final r = await _runBuild(fx, ['--dry-run', '--version', _version]);
        expect(r.exitCode, 0, reason: '$r');
        expect(File('${fx.root}/dist/$_dmgName').existsSync(), isTrue);
        expect(File('${fx.root}/dist/$_zipName').existsSync(), isTrue);
        expect(File('${fx.root}/dist/$_sums').existsSync(), isTrue);
        expect(Directory(fx.out).existsSync(), isFalse);
      },
    );

    test('the repo gitignore ignores dist', () async {
      final iso = await isolatedEnv();
      final r = await Process.run(
        'git',
        ['check-ignore', '-q', 'dist/$_dmgName'],
        workingDirectory: repoRoot(),
        environment: iso.env,
      );
      expect(r.exitCode, 0, reason: 'dist/ is not gitignored');
      final ok = await Process.run(
        'git',
        ['check-ignore', '-q', 'scripts/release/build.sh'],
        workingDirectory: repoRoot(),
        environment: iso.env,
      );
      expect(ok.exitCode, 1, reason: 'build.sh must stay tracked');
    });

    test('build.sh without --version exits 2 before STEP 1', () async {
      final fx = await _fixture();
      final r = await _runBuild(fx, ['--dry-run', '--out', fx.out]);
      expect(r.exitCode, 2, reason: '$r');
      expect(_steps(r), isEmpty, reason: '$r');
      expect(_calls(fx), isEmpty, reason: _callList(_calls(fx)));
      expect(r.output, contains('--version'), reason: '$r');
    });

    test('build.sh with an unknown option exits 2 before STEP 1', () async {
      final fx = await _fixture();
      final r = await _runBuild(fx, [..._dryArgs(fx), '--bogus-option']);
      expect(r.exitCode, 2, reason: '$r');
      expect(_steps(r), isEmpty, reason: '$r');
      expect(_calls(fx), isEmpty, reason: _callList(_calls(fx)));
      expect(r.output, contains('--bogus-option'), reason: '$r');
    });

    test('build.sh is an executable bash script', () {
      final f = File('${repoRoot()}/$_build');
      expect(f.existsSync(), isTrue, reason: '$_build is missing');
      expect(f.statSync().mode & 0x49, 0x49, reason: 'not executable');
      final first = f.readAsLinesSync().first;
      expect(first.startsWith('#!'), isTrue);
      expect(first, contains('bash'));
    });
  });

  group('step failures', () {
    // (test name, fixture LICENSE extra, env) for a leak in one output.
    final plantCases = <(String, String, Map<String, String>)>[
      (
        'a leak planted in the app executable fails step 9 and writes no checksums',
        '',
        {'FAKE_RUNNER_PLANT': _stranger},
      ),
      (
        'a leak planted in memex fails step 9 and writes no checksums',
        '',
        {'FAKE_MEMEX_PLANT': _stranger},
      ),
      (
        'a leak planted only in the DMG fails step 9 and writes no checksums',
        '',
        {'FAKE_DMG_PLANT': _stranger},
      ),
      (
        'a leak planted only in the memex zip fails step 9 and writes no checksums',
        'Notice: $_stranger',
        <String, String>{},
      ),
    ];
    for (final (name, licenseExtra, env) in plantCases) {
      test(name, () async {
        final fx = await _fixture(licenseExtra: licenseExtra);
        final r = await _runBuild(fx, _dryArgs(fx), env: env);
        expect(r.exitCode, 1, reason: '$r');
        expect(_failed(r), [9], reason: '$r');
        expect(_leakRules(r), contains('home-path'), reason: '$r');
        final steps = _steps(r);
        expect(steps, containsAllInOrder([1, 2, 3, 4, 5, 6, 7, 8, 9]));
        expect(steps, isNot(contains(10)), reason: '$r');
        expect(File('${fx.out}/$_sums').existsSync(), isFalse);
        expect(
          r.output.contains(_strangerRoot),
          isFalse,
          reason: 'the leaked path shows in the output',
        );
      });
    }

    test(
      'dry run passes the LEAK_PATTERNS deny-list to the leak check',
      () async {
        final fx = await _fixture();
        final r = await _runBuild(
          fx,
          _dryArgs(fx),
          env: {'LEAK_PATTERNS': _denyEmail, 'FAKE_MEMEX_PLANT': _denyEmail},
        );
        expect(r.exitCode, 1, reason: '$r');
        expect(_failed(r), [9], reason: '$r');
        expect(_leakRules(r), contains('deny-list'), reason: '$r');
        expect(r.output, isNot(contains(_warn)), reason: '$r');
        expect(File('${fx.out}/$_sums').existsSync(), isFalse);
        expect(r.output.contains(_denyEmail), isFalse, reason: 'unredacted');
      },
    );

    test('a failing codesign verify fails step 5', () async {
      final fx = await _fixture();
      final r = await _runBuild(
        fx,
        _dryArgs(fx),
        env: {'FAKE_CODESIGN_VERIFY_FAIL': '1'},
      );
      final calls = _calls(fx);
      expect(r.exitCode, 1, reason: '$r');
      expect(_failed(r), [5], reason: '$r');
      expect(
        calls.where(
          (c) =>
              _isVerify(c) &&
              c.args.contains('--deep') &&
              c.args.contains('--strict'),
        ),
        isNotEmpty,
        reason: _callList(calls),
      );
      expect(_steps(r), isNot(contains(6)), reason: '$r');
      expect(calls.where(_isHdiCreate), isEmpty, reason: _callList(calls));
      expect(File('${fx.out}/$_sums').existsSync(), isFalse);
    });
  });

  group('signed mode refusals', () {
    // (test name, env change, extra args, what the refusal names)
    final cases = <(String, Map<String, String?>, List<String>, String)>[
      (
        'signed mode without MACOS_SIGN_IDENTITY exits 2 before STEP 1',
        {'MACOS_SIGN_IDENTITY': null},
        [],
        'MACOS_SIGN_IDENTITY',
      ),
      (
        'signed mode with an empty MACOS_SIGN_IDENTITY exits 2 before STEP 1',
        {'MACOS_SIGN_IDENTITY': ''},
        [],
        'MACOS_SIGN_IDENTITY',
      ),
      (
        'signed mode without NOTARY_KEY_P8_PATH exits 2 before STEP 1',
        {'NOTARY_KEY_P8_PATH': null},
        [],
        'NOTARY_KEY_P8_PATH',
      ),
      (
        'signed mode without NOTARY_KEY_ID exits 2 before STEP 1',
        {'NOTARY_KEY_ID': null},
        [],
        'NOTARY_KEY_ID',
      ),
      (
        'signed mode without NOTARY_ISSUER_ID exits 2 before STEP 1',
        {'NOTARY_ISSUER_ID': null},
        [],
        'NOTARY_ISSUER_ID',
      ),
      (
        'signed mode without a deny-list exits 2 before STEP 1',
        {'LEAK_PATTERNS': null},
        [],
        'LEAK_PATTERNS',
      ),
      (
        'signed mode with a blank LEAK_PATTERNS exits 2 before STEP 1',
        {'LEAK_PATTERNS': '  \n\n \n'},
        [],
        'LEAK_PATTERNS',
      ),
      (
        'signed mode with an empty patterns file exits 2 before STEP 1',
        {'LEAK_PATTERNS': null},
        ['--patterns', '<empty>'],
        'LEAK_PATTERNS',
      ),
    ];
    for (final (name, change, extra, mention) in cases) {
      test(name, () async {
        final fx = await _fixture();
        final env = _signedEnv(fx);
        change.forEach((k, v) {
          if (v == null) {
            env.remove(k);
          } else {
            env[k] = v;
          }
        });
        final empty = File('${fx.state}/empty-patterns.txt')
          ..writeAsStringSync('');
        final args = [
          ..._signedArgs(fx),
          ...extra.map((a) => a == '<empty>' ? empty.path : a),
        ];
        final r = await _runBuild(fx, args, env: env);
        _expectRefused(r, fx, mention);
      });
    }

    test(
      'signed mode with a deny-list only from --patterns runs every step',
      () async {
        final fx = await _fixture();
        final patterns = File('${fx.state}/patterns.txt')
          ..writeAsStringSync('$_unusedDeny\n');
        final env = _signedEnv(fx)..remove('LEAK_PATTERNS');
        final r = await _runBuild(fx, [
          ..._signedArgs(fx),
          '--patterns',
          patterns.path,
        ], env: env);
        expect(r.exitCode, 0, reason: '$r');
        expect(_steps(r), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], reason: '$r');
        expect(r.output, contains('leaks: 0'), reason: '$r');
      },
    );

    test(
      'signed mode passes the --patterns deny-list to the leak check',
      () async {
        final fx = await _fixture();
        final patterns = File('${fx.state}/patterns.txt')
          ..writeAsStringSync('$_denyEmail\n');
        final env = _signedEnv(fx)
          ..remove('LEAK_PATTERNS')
          ..['FAKE_MEMEX_PLANT'] = _denyEmail;
        final r = await _runBuild(fx, [
          ..._signedArgs(fx),
          '--patterns',
          patterns.path,
        ], env: env);
        expect(r.exitCode, 1, reason: '$r');
        expect(_failed(r), [9], reason: '$r');
        expect(_leakRules(r), contains('deny-list'), reason: '$r');
        expect(File('${fx.out}/$_sums').existsSync(), isFalse);
        expect(r.output.contains(_denyEmail), isFalse, reason: 'unredacted');
      },
    );
  });

  group('signed mode with fake tools', () {
    late _Fx fx;
    late ScriptResult r;
    late List<_Call> calls;

    setUpAll(() async {
      fx = await _fixture();
      r = await _runBuild(fx, _signedArgs(fx), env: _signedEnv(fx));
      calls = _calls(fx);
    });

    test(
      'signed mode exits 0 after STEP 1 to STEP 10 with leaks 0 and no empty deny-list warning',
      () {
        expect(r.exitCode, 0, reason: '$r');
        expect(_steps(r), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], reason: '$r');
        expect(r.output, contains('leaks: 0'), reason: '$r');
        expect(r.output, isNot(contains(_warn)), reason: '$r');
      },
    );

    test(
      'signed mode signs notarizes and staples in order and writes SHA256SUMS last',
      () async {
        expect(r.exitCode, 0, reason: '$r');
        final why = _callList(calls);
        final signings = _inAppSignings(calls);
        _expectInsideOut(calls);
        final appSigned = signings.lastWhere((s) => s.kind == 'app').index;

        final dittoAt = _indexWhere(
          calls,
          (c) =>
              c.tool == 'ditto' &&
              c.args.contains('-c') &&
              c.args.contains('-k') &&
              c.args.contains('--keepParent') &&
              c.args.any((a) => _kind(a) == 'app'),
        );
        expect(dittoAt, greaterThan(appSigned), reason: why);
        final appZip = calls[dittoAt].args.last;
        final submitApp = _indexWhere(
          calls,
          (c) => _isSubmit(c) && _submitPath(c) == appZip,
        );
        final stapleApp = _indexWhere(
          calls,
          (c) => _isStaple(c) && _kind(c.args.last) == 'app',
        );
        final create = _indexWhere(calls, _isHdiCreate);
        final signDmg = _indexWhere(
          calls,
          (c) => _isSign(c) && _targets(c).any((t) => t.endsWith(_dmgName)),
        );
        final submitDmg = _indexWhere(
          calls,
          (c) => _isSubmit(c) && (_submitPath(c) ?? '').endsWith(_dmgName),
        );
        final stapleDmg = _indexWhere(
          calls,
          (c) => _isStaple(c) && c.args.last.endsWith(_dmgName),
        );
        final submitZip = _indexWhere(
          calls,
          (c) => _isSubmit(c) && (_submitPath(c) ?? '').endsWith(_zipName),
        );
        final order = [
          dittoAt,
          submitApp,
          stapleApp,
          create,
          signDmg,
          submitDmg,
          stapleDmg,
          submitZip,
        ];
        for (var i = 1; i < order.length; i++) {
          expect(
            order[i],
            greaterThan(order[i - 1]),
            reason: 'order $order\n$why',
          );
        }
        // A bare binary cannot be stapled: nothing staples the zip or memex.
        expect(
          calls.where(
            (c) =>
                _isStaple(c) &&
                (c.args.last.endsWith('.zip') || c.args.last.endsWith('memex')),
          ),
          isEmpty,
          reason: why,
        );
        // The DMG is signed with the identity and a timestamp.
        expect(_identityOf(calls[signDmg]), _identity);
        expect(calls[signDmg].args, contains('--timestamp'));

        // SHA256SUMS.txt comes last: it hashes the stapled DMG and is newer
        // than every file it lists.
        await _expectSumsMatch(fx.out);
        final sumsTime = File('${fx.out}/$_sums').lastModifiedSync();
        for (final n in [_dmgName, _zipName, _notices]) {
          expect(
            File('${fx.out}/$n').lastModifiedSync().isAfter(sumsTime),
            isFalse,
            reason: '$n changed after $_sums was written',
          );
        }
      },
    );

    test(
      'signed mode signs memex the frameworks and the app with the hardened runtime a timestamp and the identity',
      () {
        expect(r.exitCode, 0, reason: '$r');
        final signings = _inAppSignings(calls);
        expect(signings, isNotEmpty, reason: _callList(calls));
        for (final s in signings) {
          final a = s.call.args;
          expect(_identityOf(s.call), _identity, reason: '${s.call}');
          expect(a, contains('--timestamp'), reason: '${s.call}');
          expect(
            _optValue(s.call, '--options') ?? _optValue(s.call, '-o'),
            contains('runtime'),
            reason: '${s.call}',
          );
        }
      },
    );

    test(
      'signed mode signs the app with Release.entitlements and memex with none',
      () {
        expect(r.exitCode, 0, reason: '$r');
        final signings = _inAppSignings(calls);
        final app = signings.lastWhere((s) => s.kind == 'app').call;
        expect(
          _optValue(app, '--entitlements'),
          endsWith('app/macos/Runner/Release.entitlements'),
          reason: '$app',
        );
        for (final s in signings.where((s) => s.kind == 'memex')) {
          expect(
            _optValue(s.call, '--entitlements'),
            isNull,
            reason: '${s.call}',
          );
        }
      },
    );

    test('signed mode notarizes with the API key from the environment', () {
      expect(r.exitCode, 0, reason: '$r');
      final submits = calls.where(_isSubmit).toList();
      expect(submits, hasLength(3), reason: _callList(calls));
      for (final c in submits) {
        expect(c.args, contains('--wait'), reason: '$c');
        expect(_optValue(c, '--key'), fx.p8, reason: '$c');
        expect(_optValue(c, '--key-id'), _keyId, reason: '$c');
        expect(_optValue(c, '--issuer'), _issuer, reason: '$c');
      }
    });

    test(
      'signed mode staples the app before building the DMG and sums the stapled DMG',
      () async {
        expect(r.exitCode, 0, reason: '$r');
        final dmg = '${fx.out}/$_dmgName';
        expect(_readLoose(dmg), contains(_stapleMarker));
        final vol = await _openDmg(fx, dmg);
        final ticket = File('$vol/$_appName/Contents/CodeResources');
        expect(
          ticket.existsSync(),
          isTrue,
          reason: 'the DMG app is not stapled',
        );
        expect(ticket.readAsStringSync(), contains(_stapleMarker));
        final zip = '${fx.out}/$_zipName';
        final entries = await _zipEntries(zip);
        final memex = entries.firstWhere((e) => e.split('/').last == 'memex');
        expect(
          await _unzipEntry(zip, memex),
          contains('FAKE-CODESIGN $_identity'),
        );
      },
    );
  });

  group('notarization failures', () {
    // (test name, the fake submit exit status for an Invalid result)
    final cases = <(String, String)>[
      ('a failing notarytool fails step 6 and prints its log', '1'),
      ('a rejected notarization that exits 0 still fails step 6', '0'),
    ];
    for (final (name, exit) in cases) {
      test(name, () async {
        final fx = await _fixture();
        final r = await _runBuild(
          fx,
          _signedArgs(fx),
          env: {
            ..._signedEnv(fx),
            'FAKE_NOTARY_FAIL': '1',
            'FAKE_NOTARY_INVALID_EXIT': exit,
          },
        );
        final calls = _calls(fx);
        expect(r.exitCode, 1, reason: '$r');
        expect(_failed(r), [6], reason: '$r');
        expect(r.output, contains(_notaryLogMarker), reason: '$r');
        expect(
          calls.where(
            (c) =>
                _isNotary(c) &&
                c.args.contains('log') &&
                c.args.contains(_firstSubmissionId),
          ),
          isNotEmpty,
          reason: _callList(calls),
        );
        expect(_steps(r), isNot(contains(7)), reason: '$r');
        expect(calls.where(_isHdiCreate), isEmpty, reason: _callList(calls));
        expect(File('${fx.out}/$_sums').existsSync(), isFalse);
      });
    }
  });
}
