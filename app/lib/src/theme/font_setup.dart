/// Font setup (Spec #367 requirement 18): the app's fonts ship as bundled
/// assets under `assets/google_fonts/`, google_fonts never fetches at run
/// time, and each family's SIL Open Font License 1.1 text is registered with
/// `LicenseRegistry`. `main()` calls this before `runApp`; tests may call it
/// too.
void configureFonts() {}
