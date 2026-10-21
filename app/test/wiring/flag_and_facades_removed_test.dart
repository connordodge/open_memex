// WI #105 (F1) hygiene: the rollout flag and the D14a synchronous facades are
// deleted, not just unused (L15, D18, D20, D14a).
// - The flag: `state/hosted_vaults_flag.dart`, its provider and its
//   `MEMEX_HOSTED_VAULTS` build define are gone from app/lib and app/test.
// - The facades: W1 to W6 kept each migrated provider's old name as a
//   synchronous facade over its `...AsyncProvider`. No source in app/lib or
//   app/test names one of them any more; readers read the async provider.
// A source scan: a later reintroduction fails here. Names are built from
// parts so this file never matches itself.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// This file, which names what it scans for.
final _self = p.join('test', 'wiring', 'flag_and_facades_removed_test.dart');

/// Every `.dart` source under app/lib and app/test but this file, sorted.
List<File> _sources() => <File>[
  for (final dir in ['lib', 'test'])
    ...Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && f.path != _self),
]..sort((a, b) => a.path.compareTo(b.path));

/// `file:line: text` of every line in [files] where [pattern] matches.
List<String> _hits(List<File> files, RegExp pattern) => [
  for (final f in files)
    for (final (i, line) in f.readAsLinesSync().indexed)
      if (pattern.hasMatch(line)) '${f.path}:${i + 1}: ${line.trim()}',
];

/// The 17 D14a facades W1 to W6 left, as (test name, stem). Each one's
/// async provider is the same stem with `AsyncProvider`.
const _facades = [
  (
    'no source reads or defines the dailyNotes synchronous facade',
    'dailyNotes',
  ),
  ('no source reads or defines the todayNote synchronous facade', 'todayNote'),
  (
    'no source reads or defines the reviewState synchronous facade',
    'reviewState',
  ),
  (
    'no source reads or defines the blocksForNote synchronous facade',
    'blocksForNote',
  ),
  (
    'no source reads or defines the footerChips synchronous facade',
    'footerChips',
  ),
  (
    'no source reads or defines the agentChanges synchronous facade',
    'agentChanges',
  ),
  ('no source reads or defines the notesList synchronous facade', 'notesList'),
  ('no source reads or defines the canvases synchronous facade', 'canvases'),
  (
    'no source reads or defines the canvasDetail synchronous facade',
    'canvasDetail',
  ),
  (
    'no source reads or defines the editorNote synchronous facade',
    'editorNote',
  ),
  (
    'no source reads or defines the selectedNote synchronous facade',
    'selectedNote',
  ),
  (
    'no source reads or defines the noteTitles synchronous facade',
    'noteTitles',
  ),
  ('no source reads or defines the linkKinds synchronous facade', 'linkKinds'),
  ('no source reads or defines the linksOut synchronous facade', 'linksOut'),
  ('no source reads or defines the backlinks synchronous facade', 'backlinks'),
  ('no source reads or defines the graphData synchronous facade', 'graphData'),
  (
    'no source reads or defines the smartFolderTree synchronous facade',
    'smartFolderTree',
  ),
];

/// Matches the facade `<stem>Provider` as a whole identifier, never
/// `<stem>AsyncProvider`.
RegExp _facade(String stem) => RegExp(r'\b' + stem + r'Provider\b');

void main() {
  test('the source scan reads app lib and app test', () {
    final files = _sources();
    expect(files.map((f) => p.split(f.path).first).toSet(), {'lib', 'test'});
    expect(
      files.map((f) => p.basename(f.path)),
      containsAll(['vault_picker.dart', 'daily_state.dart', 'main.dart']),
    );
  });

  test('the hosted vaults flag file is deleted', () {
    expect(
      File(
        p.join('lib', 'src', 'state', ['hosted_vaults', 'flag.dart'].join('_')),
      ).existsSync(),
      isFalse,
    );
  });

  test('no source names the hosted vaults flag provider or its define', () {
    final files = _sources();
    final provider = ['hostedVaults', 'Enabled', 'Provider'].join();
    final define = ['MEMEX', 'HOSTED', 'VAULTS'].join('_');
    final file = ['hosted_vaults', 'flag'].join('_');

    expect(_hits(files, RegExp(RegExp.escape(provider))), isEmpty);
    expect(_hits(files, RegExp(RegExp.escape(define))), isEmpty);
    expect(_hits(files, RegExp(RegExp.escape(file))), isEmpty);
  });

  test(
    'the facade scan matches a facade name and never its async provider',
    () {
      final pattern = _facade('canvases');
      final facade = ['canvases', 'Provider'].join();
      final async = ['canvases', 'Async', 'Provider'].join();
      expect(pattern.hasMatch('ref.watch($facade);'), isTrue);
      expect(pattern.hasMatch('c.read(canvas.$facade)'), isTrue);
      expect(pattern.hasMatch('ref.watch($async);'), isFalse);
      expect(pattern.hasMatch('ref.watch(my${facade}X);'), isFalse);
    },
  );

  for (final (name, stem) in _facades) {
    test(name, () {
      expect(_hits(_sources(), _facade(stem)), isEmpty);
    });
  }
}
