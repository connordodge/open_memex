import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether hosted vault UI is shown. OFF unless the build passes
/// `--dart-define=MEMEX_HOSTED_VAULTS=true`. Deleted by #105.
final hostedVaultsEnabledProvider = Provider<bool>(
  (_) => throw UnimplementedError(),
);
