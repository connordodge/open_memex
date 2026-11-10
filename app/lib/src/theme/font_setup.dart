import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// Where the bundled fonts and their OFL texts live (declared in
/// `pubspec.yaml` `flutter: assets:`).
const _fontAssetDir = 'assets/google_fonts';

/// Each bundled family's display name to its file-name spelling, as in
/// `OFL-<FileName>.txt` and `<FileName>-<Variant>.ttf`.
const _fontFamilies = {
  'Inter Tight': 'InterTight',
  'JetBrains Mono': 'JetBrainsMono',
  'Newsreader': 'Newsreader',
};

/// Font setup (Spec #367 requirement 18): the app's fonts ship as bundled
/// assets under `assets/google_fonts/`, google_fonts never fetches at run
/// time, and each family's SIL Open Font License 1.1 text is registered with
/// `LicenseRegistry`. `main()` calls this before `runApp`; tests may call it
/// too.
///
/// Each call adds one licence entry per family, so call it once per
/// `LicenseRegistry` lifetime.
void configureFonts() {
  GoogleFonts.config.allowRuntimeFetching = false;
  LicenseRegistry.addLicense(_fontLicenses);
}

/// One OFL entry per bundled family, read from the asset bundle when the
/// licence page asks for it.
Stream<LicenseEntry> _fontLicenses() async* {
  for (final MapEntry(key: family, value: fileName) in _fontFamilies.entries) {
    final text = await rootBundle.loadString(
      '$_fontAssetDir/OFL-$fileName.txt',
    );
    yield LicenseEntryWithLineBreaks([family], text);
  }
}
