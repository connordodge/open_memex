import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The app's `CFBundleShortVersionString` (e.g. `0.2.0`), shown as `v<version>`
/// in the vault picker and the sidebar. Empty (the default, never a throw)
/// until `main()` overrides it, so tests that do not care keep passing.
final appVersionProvider = Provider<String>((_) => '');
