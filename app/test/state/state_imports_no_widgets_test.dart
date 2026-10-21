// WI #92 orchestrator ruling: state/ imports no widgets. The refusal dialogs
// are shown by `showVaultOpenRefusal` in widgets/vault_open_refusal.dart;
// the vault open controller returns data-only outcomes. A source scan, so a
// later import of a widget or screen file from state/ fails here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _directive = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// The import, export and part URIs in [source] that name a file under a
/// `widgets/` or `screens/` directory (relative or `package:` form).
List<String> _widgetUris(String source) => [
  for (final m in _directive.allMatches(source))
    if (p.posix
        .split(m.group(1)!)
        .any((segment) => segment == 'widgets' || segment == 'screens'))
      m.group(1)!,
];

void main() {
  test('the widget import scan flags relative and package widget imports', () {
    expect(
      _widgetUris('''
import 'dart:io';
import '../widgets/vault_open_refusal.dart';
import "package:open_memex_app/src/screens/vault_picker.dart";
export '../widgets/atoms.dart' show OmButton;
import 'package:flutter/widgets.dart';
import 'settings.dart';
'''),
      [
        '../widgets/vault_open_refusal.dart',
        'package:open_memex_app/src/screens/vault_picker.dart',
        '../widgets/atoms.dart',
      ],
    );
  });

  test('state imports no widget file', () {
    final files =
        Directory(p.join('lib', 'src', 'state'))
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(
      files.map((f) => p.basename(f.path)),
      contains('vault_open_controller.dart'),
      reason: 'the scan reads the state sources',
    );

    final offenders = <String, List<String>>{
      for (final f in files)
        if (_widgetUris(f.readAsStringSync()) case final uris
            when uris.isNotEmpty)
          f.path: uris,
    };

    expect(offenders, isEmpty);
  });
}
