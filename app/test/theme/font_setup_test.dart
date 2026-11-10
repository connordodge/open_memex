// WI #373 (Spec #367 requirement 18, TD 8, L13): the app's fonts ship as
// bundled assets, google_fonts never fetches at run time, and each family's
// OFL 1.1 text is in LicenseRegistry.
//
// This file deliberately does not call holdFontFetches(): the no-network
// tests install their own HttpOverrides counter instead.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/font_setup.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the bundled fonts and their OFL texts live.
const _wi373Dir = 'assets/google_fonts';

/// Every font file OmType can ask google_fonts for, under the name
/// google_fonts looks up in the asset manifest
/// (`<FamilyNoSpaces>-<VariantName>.ttf`):
/// - OmType.sans (Inter Tight): any FontWeight, normal style. Inter Tight has
///   all nine weights, so nine files.
/// - OmType.mono (JetBrains Mono): any FontWeight, normal style. Eight
///   weights (100-800); w900 resolves to ExtraBold.
/// - OmType.serif (Newsreader): any FontWeight, normal or italic. Seven
///   weights (200-800) in each style, so fourteen files; w100 resolves to
///   ExtraLight.
const List<String> wi373ExpectedFontFiles = [
  'InterTight-Thin.ttf',
  'InterTight-ExtraLight.ttf',
  'InterTight-Light.ttf',
  'InterTight-Regular.ttf',
  'InterTight-Medium.ttf',
  'InterTight-SemiBold.ttf',
  'InterTight-Bold.ttf',
  'InterTight-ExtraBold.ttf',
  'InterTight-Black.ttf',
  'JetBrainsMono-Thin.ttf',
  'JetBrainsMono-ExtraLight.ttf',
  'JetBrainsMono-Light.ttf',
  'JetBrainsMono-Regular.ttf',
  'JetBrainsMono-Medium.ttf',
  'JetBrainsMono-SemiBold.ttf',
  'JetBrainsMono-Bold.ttf',
  'JetBrainsMono-ExtraBold.ttf',
  'Newsreader-ExtraLight.ttf',
  'Newsreader-Light.ttf',
  'Newsreader-Regular.ttf',
  'Newsreader-Medium.ttf',
  'Newsreader-SemiBold.ttf',
  'Newsreader-Bold.ttf',
  'Newsreader-ExtraBold.ttf',
  'Newsreader-ExtraLightItalic.ttf',
  'Newsreader-LightItalic.ttf',
  'Newsreader-Italic.ttf',
  'Newsreader-MediumItalic.ttf',
  'Newsreader-SemiBoldItalic.ttf',
  'Newsreader-BoldItalic.ttf',
  'Newsreader-ExtraBoldItalic.ttf',
];

/// File-name family (as google_fonts spells it) to the family's display name.
const Map<String, String> _wi373Families = {
  'InterTight': 'Inter Tight',
  'JetBrainsMono': 'JetBrains Mono',
  'Newsreader': 'Newsreader',
};

/// google_fonts' file-name weight words.
const Map<String, int> _wi373WeightWords = {
  'Thin': 100,
  'ExtraLight': 200,
  'Light': 300,
  'Regular': 400,
  'Medium': 500,
  'SemiBold': 600,
  'Bold': 700,
  'ExtraBold': 800,
  'Black': 900,
};

/// What a bundled file's name says it is.
class _Wi373Face {
  _Wi373Face(this.file) {
    final dash = file.indexOf('-');
    familyKey = file.substring(0, dash);
    subfamily = file.substring(dash + 1, file.length - '.ttf'.length);
    var variant = subfamily;
    italic = variant.endsWith('Italic');
    if (italic) {
      variant = variant.substring(0, variant.length - 'Italic'.length);
    }
    weight = _wi373WeightWords[variant.isEmpty ? 'Regular' : variant]!;
  }

  final String file;
  late final String familyKey;

  /// The name's variant part, e.g. `ExtraLightItalic`, `Italic`, `Regular`.
  late final String subfamily;
  late final bool italic;
  late final int weight;

  String get displayFamily => _wi373Families[familyKey]!;
}

/// The parts of a TrueType file's table directory, OS/2 and name tables the
/// tests check.
class _Wi373Ttf {
  _Wi373Ttf(ByteData b) {
    sfntVersion = b.getUint32(0);
    final numTables = b.getUint16(4);
    final offsets = <String, int>{};
    for (var i = 0; i < numTables; i++) {
      final rec = 12 + 16 * i;
      final tag = String.fromCharCodes([
        for (var j = 0; j < 4; j++) b.getUint8(rec + j),
      ]);
      offsets[tag] = b.getUint32(rec + 8);
    }
    tables = offsets.keys.toSet();
    final os2 = offsets['OS/2'];
    weightClass = os2 == null ? -1 : b.getUint16(os2 + 4);
    os2Italic = os2 != null && (b.getUint16(os2 + 62) & 0x1) != 0;
    final name = offsets['name'];
    if (name != null) {
      final count = b.getUint16(name + 2);
      final strings = name + b.getUint16(name + 4);
      final names = <int, String>{};
      for (var i = 0; i < count; i++) {
        final rec = name + 6 + 12 * i;
        final platform = b.getUint16(rec);
        final nameId = b.getUint16(rec + 6);
        if (platform != 3 || !const {1, 2, 16, 17}.contains(nameId)) {
          continue;
        }
        final length = b.getUint16(rec + 8);
        final start = strings + b.getUint16(rec + 10);
        names[nameId] = String.fromCharCodes([
          for (var k = 0; k < length; k += 2) b.getUint16(start + k),
        ]);
      }
      // Typographic family/subfamily (IDs 16/17) when the font has them,
      // else the legacy ones (IDs 1/2).
      family = names[16] ?? names[1] ?? '';
      subfamily = (names[17] ?? names[2] ?? '').replaceAll(' ', '');
    }
  }

  late final int sfntVersion;
  late final Set<String> tables;
  late final int weightClass;
  late final bool os2Italic;
  String family = '';

  /// With spaces removed, e.g. `ExtraLightItalic`.
  String subfamily = '';
}

/// Every HTTP client and request made while a no-network test runs. Static so
/// a request through google_fonts' cached client (created once per isolate)
/// is still seen by a later test.
class _Wi373HttpLog {
  static int clientsCreated = 0;
  static final List<Uri> requests = [];

  static void reset() {
    clientsCreated = 0;
    requests.clear();
  }
}

class _Wi373CountingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    _Wi373HttpLog.clientsCreated++;
    return _Wi373RefusingHttpClient();
  }
}

/// An [HttpClient] that records each request and fails it at once, so a test
/// never reaches the network and never hangs on a fetch.
class _Wi373RefusingHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    _Wi373HttpLog.requests.add(url);
    return Future.error(const SocketException('no network in #373 tests'));
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Text in every weight and style each OmType function accepts.
List<TextStyle> _wi373EveryOmTypeStyle() => [
  for (final w in FontWeight.values) OmType.sans(weight: w),
  for (final w in FontWeight.values) OmType.mono(weight: w),
  for (final w in FontWeight.values)
    for (final s in FontStyle.values) OmType.serif(weight: w, style: s),
];

/// Waits for every google_fonts load started so far; returns its error, if
/// any, instead of throwing.
Future<Object?> _wi373SettleFontLoads() async {
  try {
    await GoogleFonts.pendingFonts();
    return null;
  } catch (e) {
    return e;
  }
}

/// [_wi373SettleFontLoads] for loads a testWidgets build started: their I/O
/// completes in real time but their continuations run in the fake-async zone,
/// so alternate a short real-time yield with a pump until they settle.
Future<Object?> _wi373SettleFontLoadsIn(WidgetTester tester) async {
  var settled = false;
  Object? error;
  _wi373SettleFontLoads().then((e) {
    error = e;
    settled = true;
  });
  for (var i = 0; i < 500 && !settled; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(settled, isTrue, reason: 'font loads did not settle');
  return error;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('configureFonts', () {
    setUp(() => GoogleFonts.config.allowRuntimeFetching = true);

    test('configureFonts sets GoogleFonts allowRuntimeFetching to false', () {
      expect(GoogleFonts.config.allowRuntimeFetching, isTrue);

      configureFonts();

      expect(GoogleFonts.config.allowRuntimeFetching, isFalse);
    });
  });

  group('bundled font files', () {
    test(
      'every OmType weight and style has a bundled font under its google_fonts lookup name',
      () async {
        // The list: 9 Inter Tight + 8 JetBrains Mono + 14 Newsreader, with
        // italics only for Newsreader (the one OmType function with a style).
        final faces = wi373ExpectedFontFiles.map(_Wi373Face.new).toList();
        int count(String family) =>
            faces.where((f) => f.familyKey == family).length;
        expect(wi373ExpectedFontFiles.toSet(), hasLength(31));
        expect(count('InterTight'), 9);
        expect(count('JetBrainsMono'), 8);
        expect(count('Newsreader'), 14);
        expect(faces.where((f) => f.italic).map((f) => f.familyKey).toSet(), {
          'Newsreader',
        });

        final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
        final assets = manifest.listAssets().toSet();
        final missing = [
          for (final f in wi373ExpectedFontFiles)
            if (!assets.contains('$_wi373Dir/$f')) f,
        ];
        expect(missing, isEmpty, reason: 'not in the asset bundle');
      },
    );

    test(
      'each bundled font is a static TrueType file of the family, weight and style its name gives',
      () async {
        final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
        final assets = manifest.listAssets().toSet();
        final problems = <String>[];
        for (final file in wi373ExpectedFontFiles) {
          final path = '$_wi373Dir/$file';
          if (!assets.contains(path)) {
            problems.add('$file: not bundled');
            continue;
          }
          final face = _Wi373Face(file);
          final ttf = _Wi373Ttf(await rootBundle.load(path));
          if (ttf.sfntVersion != 0x00010000) {
            problems.add('$file: not a TrueType outline font');
          }
          if (ttf.tables.contains('fvar')) {
            problems.add('$file: a variable font, not a static instance');
          }
          // Thin and ExtraLight static instances often carry usWeightClass
          // 250 (a GDI rendering convention); the subfamily check below still
          // tells them apart.
          final weightOk =
              ttf.weightClass == face.weight ||
              (face.weight < 300 && ttf.weightClass == 250);
          if (!weightOk) {
            problems.add('$file: OS/2 weight ${ttf.weightClass}');
          }
          if (ttf.os2Italic != face.italic) {
            problems.add('$file: OS/2 italic ${ttf.os2Italic}');
          }
          if (ttf.subfamily != face.subfamily) {
            problems.add('$file: subfamily ${ttf.subfamily}');
          }
          if (!ttf.family.startsWith(face.displayFamily)) {
            problems.add('$file: family ${ttf.family}');
          }
        }
        expect(problems, isEmpty);
      },
    );
  });

  group('font licences', () {
    setUp(LicenseRegistry.reset);
    tearDown(LicenseRegistry.reset);

    test(
      'LicenseRegistry holds an OFL 1.1 entry for each of Inter Tight, JetBrains Mono and Newsreader after setup',
      () async {
        configureFonts();
        final entries = await LicenseRegistry.licenses.toList();

        String squash(String s) => s.replaceAll(RegExp(r'\s+'), '');
        for (final MapEntry(key: fileFamily, value: family)
            in _wi373Families.entries) {
          final matching = entries
              .where((e) => e.packages.contains(family))
              .toList();
          expect(matching, hasLength(1), reason: '$family licence entries');
          final text = matching.single.paragraphs.map((p) => p.text).join('\n');
          expect(text, contains('SIL OPEN FONT LICENSE'), reason: family);
          expect(text, contains('Version 1.1'), reason: family);
          // The entry is that family's own OFL text, the file bundled next to
          // its fonts.
          final ofl = await rootBundle.loadString(
            '$_wi373Dir/OFL-$fileFamily.txt',
          );
          expect(squash(text), squash(ofl), reason: family);
        }
      },
    );

    test(
      'each family has its OFL 1.1 text bundled next to its fonts',
      () async {
        final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
        final assets = manifest.listAssets().toSet();
        final texts = <String>{};
        for (final fileFamily in _wi373Families.keys) {
          final path = '$_wi373Dir/OFL-$fileFamily.txt';
          expect(assets, contains(path));
          final ofl = await rootBundle.loadString(path);
          expect(ofl, contains('SIL OPEN FONT LICENSE Version 1.1'));
          texts.add(ofl);
        }
        // Each family carries its own copyright line, so three distinct texts.
        expect(texts, hasLength(3));
      },
    );
  });

  group('no runtime font fetch', () {
    HttpOverrides? previous;
    setUp(() {
      _Wi373HttpLog.reset();
      previous = HttpOverrides.current;
      HttpOverrides.global = _Wi373CountingHttpOverrides();
      GoogleFonts.config.allowRuntimeFetching = true;
    });
    tearDown(() => HttpOverrides.global = previous);

    testWidgets(
      'pumping a themed screen after configureFonts creates no HTTP client',
      (tester) async {
        configureFonts();
        SharedPreferences.setMockInitialValues({});
        final settings = await SettingsController.load();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith((_) => settings),
              memexCliProvider.overrideWithValue(null),
            ],
            child: MaterialApp(
              theme: buildOmTheme(),
              home: const VaultPickerScreen(),
            ),
          ),
        );
        // The loads started in the fake-async zone: let their real I/O run,
        // then flush the fake zone, until every load has settled.
        final loadError = await _wi373SettleFontLoadsIn(tester);

        expect(find.text('CHOOSE A VAULT'), findsOneWidget);
        expect(_Wi373HttpLog.clientsCreated, 0, reason: 'HTTP clients created');
        expect(_Wi373HttpLog.requests, isEmpty, reason: 'HTTP requests');
        expect(loadError, isNull, reason: 'a font failed to load');
      },
    );

    test(
      'every weight and style OmType accepts loads from the bundle with no HTTP client',
      () async {
        configureFonts();

        final styles = _wi373EveryOmTypeStyle();
        final loadError = await _wi373SettleFontLoads();

        // 9 sans + 9 mono + 18 serif requests, resolved to 31 files.
        expect(styles, hasLength(36));
        expect(_Wi373HttpLog.clientsCreated, 0, reason: 'HTTP clients created');
        expect(_Wi373HttpLog.requests, isEmpty, reason: 'HTTP requests');
        expect(loadError, isNull, reason: 'a font failed to load');
      },
    );
  });

  group('main', () {
    test('main calls configureFonts before runApp', () {
      // `flutter test` runs with the package root (`app/`) as cwd.
      final source = File('lib/main.dart').readAsStringSync();
      final start = source.indexOf('Future<void> main() async {');
      expect(start, isNonNegative, reason: 'main() not found');
      final end = source.indexOf('\n}\n', start);
      final body = source.substring(start, end);

      final setup = body.indexOf('configureFonts();');
      final run = body.indexOf('runApp(');
      expect(run, isNonNegative, reason: 'runApp not found in main()');
      expect(
        setup,
        isNonNegative,
        reason: 'main() does not call configureFonts',
      );
      expect(setup, lessThan(run));
    });
  });
}
