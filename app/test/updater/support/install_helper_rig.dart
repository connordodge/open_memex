// WI #34 (D13): a temp-dir rig for running the real install helper script
// under /bin/sh. Fake `hdiutil`, `codesign`, `ditto`, `xattr`, `open` and
// `sleep` go first on the PATH the script is given; each records its call
// (one line, tab-separated arguments) in a log so tests can assert order.
// Nothing here touches /Applications, /Volumes or a real app: the fakes
// call real tools only by absolute path, inside the rig's temp root, and a
// guard fake stands in for every tool that could reach a real process or
// the session (killall, pkill, osascript, launchctl, diskutil, sudo).
//
// The rig's root, folders and bundle names all contain spaces.
import 'dart:io';

/// The installed and mounted bundle's name.
const rigAppName = 'Open Memex.app';

/// One recorded tool call.
class RigCall {
  RigCall(this.tool, this.args);

  final String tool;
  final List<String> args;

  /// The last argument (the target path for ditto, codesign, xattr, open).
  String get last => args.isEmpty ? '' : args.last;

  /// The value after [flag], or null.
  String? after(String flag) {
    final i = args.indexOf(flag);
    return i < 0 || i + 1 >= args.length ? null : args[i + 1];
  }

  @override
  String toString() => '$tool ${args.join(' | ')}';
}

String _sq(String value) => "'${value.replaceAll("'", r"'\''")}'";

class InstallHelperRig {
  InstallHelperRig._(this.root);

  final Directory root;

  String get appsDir => '${root.path}/My Apps';
  String get bundlePath => '$appsDir/$rigAppName';
  String get newPath => '$appsDir/$rigAppName.new';
  String get oldPath => '$appsDir/$rigAppName.old';
  String get dmgPath => '${root.path}/Update Downloads/Open-Memex 1.3.0.dmg';
  String get markerPath =>
      '${root.path}/Application Support/self_update_failure';
  String get tmpDir => '${root.path}/tmp dir';
  String get logPath => '${root.path}/tool calls.log';
  String get _fakeBin => '${root.path}/fake bin';
  String get _trapBin => '${root.path}/trap bin';
  String get _dmgSource => '${root.path}/dmg source';

  /// The PATH handed to the script as its sixth argument: fakes first.
  String get toolPath => '$_fakeBin:/usr/bin:/bin:/usr/sbin:/sbin';

  /// The PATH in the script's inherited environment: trap fakes first, so a
  /// script that ignored its PATH argument would be caught, never reach a
  /// real tool.
  String get inheritedPath => '$_trapBin:/usr/bin:/bin';

  /// Builds the rig. The installed app's `Contents/version.txt` reads `old`;
  /// the DMG's reads `new`.
  ///
  /// - [mountFails]: `hdiutil attach` exits 1 and mounts nothing.
  /// - [appAtMountRoot]: false mounts the app only under a sub-folder
  ///   (`<mount>/Open Memex/Open Memex.app`), none at the root.
  /// - [copyFails]: `ditto` leaves a partial destination and exits 1.
  /// - [lockCopy]: `ditto` succeeds, then makes the copy immutable, so the
  ///   rename into place fails.
  /// - [verifyFails]: `codesign` exits 1.
  /// - [staleNew]: an `Open Memex.app.new` holding `stale.txt` already exists.
  /// - [lockFileInOld]: an immutable file inside the installed app, so
  ///   deleting `Open Memex.app.old` after the swap fails.
  /// - [lockInstalled]: the installed app's folder is immutable, so renaming
  ///   it to `.old` fails.
  /// - [staleOld]: an `Open Memex.app.old` holding `stale-old.txt` already
  ///   exists.
  /// - [lockStaleOld]: like [staleOld], with the file immutable so it cannot
  ///   be deleted.
  /// - [detachNeedsForce]: `hdiutil detach` fails unless given `-force`.
  /// - [killOnFirstSleep]: the first fake `sleep` kills this pid.
  static Future<InstallHelperRig> create({
    bool mountFails = false,
    bool appAtMountRoot = true,
    bool copyFails = false,
    bool lockCopy = false,
    bool verifyFails = false,
    bool staleNew = false,
    bool lockFileInOld = false,
    bool lockInstalled = false,
    bool staleOld = false,
    bool lockStaleOld = false,
    bool detachNeedsForce = false,
    int? killOnFirstSleep,
  }) async {
    final root = await Directory.systemTemp.createTemp('open memex helper ');
    final rig = InstallHelperRig._(root);
    await rig._build(
      mountFails: mountFails,
      appAtMountRoot: appAtMountRoot,
      copyFails: copyFails,
      lockCopy: lockCopy,
      verifyFails: verifyFails,
      staleNew: staleNew,
      lockFileInOld: lockFileInOld,
      lockInstalled: lockInstalled,
      staleOld: staleOld,
      lockStaleOld: lockStaleOld,
      detachNeedsForce: detachNeedsForce,
      killOnFirstSleep: killOnFirstSleep,
    );
    return rig;
  }

  Future<void> _build({
    required bool mountFails,
    required bool appAtMountRoot,
    required bool copyFails,
    required bool lockCopy,
    required bool verifyFails,
    required bool staleNew,
    required bool lockFileInOld,
    required bool lockInstalled,
    required bool staleOld,
    required bool lockStaleOld,
    required bool detachNeedsForce,
    required int? killOnFirstSleep,
  }) async {
    _writeApp(bundlePath, 'old');
    _writeApp('$_dmgSource/$rigAppName', 'new');
    File(dmgPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('not a real disk image');
    Directory('${root.path}/Application Support').createSync();
    Directory(tmpDir).createSync();
    if (staleNew) {
      File('$newPath/stale.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('from an earlier attempt');
    }

    if (staleOld || lockStaleOld) {
      final stale = File('$oldPath/stale-old.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('from an earlier attempt');
      if (lockStaleOld) await _chflags(['uchg', stale.path]);
    }

    final log = _sq(logPath);
    final record =
        'LOG=$log\n'
        '{ printf \'%s\' "\$(/usr/bin/basename "\$0")"; '
        'for a in "\$@"; do printf \'\\t%s\' "\$a"; done; printf \'\\n\'; } '
        '>> "\$LOG"\n';
    final src = _sq('$_dmgSource/$rigAppName');

    _tool(_fakeBin, 'hdiutil', '''
$record
case "\$1" in
attach)
  ${mountFails ? 'exit 1' : ':'}
  mnt=''; prev=''
  for a in "\$@"; do
    if [ "\$prev" = -mountpoint ]; then mnt=\$a; fi
    prev=\$a
  done
  [ -n "\$mnt" ] || exit 2
  /bin/mkdir -p "\$mnt" || exit 1
  : > "\$mnt/.fake-mounted"
  ${appAtMountRoot ? '/bin/cp -R $src "\$mnt/"' : '/bin/mkdir -p "\$mnt/Open Memex" && /bin/cp -R $src "\$mnt/Open Memex/"'}
  exit 0 ;;
detach)
  ${detachNeedsForce ? 'forced=no; for a in "\$@"; do if [ "\$a" = -force ]; then forced=yes; fi; done; [ "\$forced" = yes ] || exit 1' : ':'}
  for a in "\$@"; do
    if [ -e "\$a/.fake-mounted" ]; then
      /bin/rm -rf "\$a"/* "\$a/.fake-mounted"
    fi
  done
  exit 0 ;;
esac
exit 1
''');

    _tool(_fakeBin, 'ditto', '''
$record
src=''; dst=''
for a in "\$@"; do src=\$dst; dst=\$a; done
if [ -e "\$dst" ]; then existed=yes; else existed=no; fi
printf 'note\\tditto-dest-existed\\t%s\\n' "\$existed" >> "\$LOG"
${copyFails ? '/bin/mkdir -p "\$dst"; : > "\$dst/partial"; exit 1' : ':'}
[ -d "\$src" ] || exit 1
/bin/mkdir -p "\$dst" && /bin/cp -R "\$src/." "\$dst/" || exit 1
${lockCopy ? '/usr/bin/chflags uchg "\$dst"' : ':'}
exit 0
''');

    _tool(_fakeBin, 'codesign', '''
$record
${verifyFails ? 'echo "a sealed resource is missing or invalid" >&2; exit 1' : 'exit 0'}
''');

    _tool(_fakeBin, 'xattr', '''
$record
exit 0
''');

    _tool(_fakeBin, 'open', '''
$record
t=''
for a in "\$@"; do t=\$a; done
printf 'note\\topened-version\\t%s\\n' "\$(/bin/cat "\$t/Contents/version.txt" 2>/dev/null)" >> "\$LOG"
exit 0
''');

    final killed = _sq('${root.path}/sleep killed');
    _tool(_fakeBin, 'sleep', '''
$record
${killOnFirstSleep == null ? ':' : 'if [ ! -e $killed ]; then : > $killed; kill $killOnFirstSleep; fi'}
exec /bin/sleep "\$@"
''');

    for (final guard in [
      'killall',
      'pkill',
      'osascript',
      'launchctl',
      'diskutil',
      'sudo',
    ]) {
      _tool(_fakeBin, guard, '$record\nexit 97\n');
    }
    for (final trapped in [
      'hdiutil',
      'ditto',
      'codesign',
      'xattr',
      'open',
      'sleep',
    ]) {
      _tool(_trapBin, trapped, '''
printf 'trap\\t%s\\n' $trapped >> $log
exit 97
''');
    }

    if (lockFileInOld) {
      final locked = File('$bundlePath/Contents/locked.txt')
        ..writeAsStringSync('cannot be deleted');
      await _chflags(['uchg', locked.path]);
    }
    if (lockInstalled) await _chflags(['uchg', bundlePath]);
  }

  static void _writeApp(String bundle, String version) {
    File('$bundle/Contents/MacOS/Open Memex')
      ..createSync(recursive: true)
      ..writeAsStringSync('$version binary');
    File('$bundle/Contents/version.txt').writeAsStringSync(version);
  }

  static void _tool(String dir, String name, String body) {
    final file = File('$dir/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n$body');
    final r = Process.runSync('/bin/chmod', ['0755', file.path]);
    if (r.exitCode != 0) throw StateError('chmod: ${r.stderr}');
  }

  static Future<void> _chflags(List<String> args) async {
    final r = await Process.run('/usr/bin/chflags', args);
    if (r.exitCode != 0) throw StateError('chflags $args: ${r.stderr}');
  }

  /// Every recorded call, oldest first (`note` lines included, with the
  /// note's name as the first argument; `trap` lines for trapped tools).
  List<RigCall> calls() {
    final log = File(logPath);
    if (!log.existsSync()) return [];
    return [
      for (final line in log.readAsLinesSync())
        if (line.isNotEmpty)
          RigCall(line.split('\t').first, line.split('\t').sublist(1)),
    ];
  }

  /// The calls to [tool] (`hdiutil`, `ditto`, …), oldest first.
  List<RigCall> callsTo(String tool) =>
      calls().where((c) => c.tool == tool).toList();

  /// The index in [calls] of the first call to [tool] whose first argument
  /// is [arg] (when given); -1 when there is none.
  int indexOf(String tool, [String? arg]) => calls().indexWhere(
    (c) => c.tool == tool && (arg == null || c.args.firstOrNull == arg),
  );

  /// The value of note [name], or null.
  String? note(String name) {
    for (final c in calls()) {
      if (c.tool == 'note' && c.args.firstOrNull == name) {
        return c.args.length > 1 ? c.args[1] : '';
      }
    }
    return null;
  }

  /// The entries left in the rig's TMPDIR (a leftover mount point shows up
  /// here).
  List<String> tmpEntries() => [
    for (final e in Directory(tmpDir).listSync()) e.path.split('/').last,
  ];

  /// The tool names that hit the trap PATH.
  List<String> trapped() => [
    for (final c in calls())
      if (c.tool == 'trap') c.args.firstOrNull ?? '',
  ];

  /// The `Contents/version.txt` of the bundle at [path] (the installed path
  /// by default), or null when there is no bundle there.
  String? versionAt([String? path]) {
    final f = File('${path ?? bundlePath}/Contents/version.txt');
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  /// The marker's text, trimmed, or null when there is no marker.
  String? marker() {
    final f = File(markerPath);
    return f.existsSync() ? f.readAsStringSync().trim() : null;
  }

  Future<void> dispose() async {
    await Process.run('/usr/bin/chflags', ['-R', 'nouchg', root.path]);
    await Process.run('/bin/chmod', ['-R', 'u+rwx', root.path]);
    await root.delete(recursive: true);
  }
}
