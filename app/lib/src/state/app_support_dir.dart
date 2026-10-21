import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The app's application-support directory (Req 35, D19). A hosted vault
/// keeps its UI state (tabs, sidebar mode) under
/// `<app support>/hosted/<serverId>/<vaultName>`. `main()` overrides it with
/// the platform directory; tests point it at a temp dir.
final appSupportDirProvider = Provider<String>(
  (_) => throw UnimplementedError('#96: overridden in main()'),
);
