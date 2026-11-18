import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_ports.dart';

// Skeleton (#34 red): A2 #34 fills this file and keeps each `defaultX(Ref)`.

/// The production [FailureMarkerStore] behind `failureMarkerStoreProvider`:
/// reads and clears the file at `failureMarkerFileProvider` (D8).
FailureMarkerStore defaultFailureMarkerStore(Ref ref) =>
    const _FailureMarkerStore();

/// The production marker path behind `failureMarkerFileProvider`
/// (`<appSupportDir>/self_update_failure`). Computing it must not touch the
/// file system.
String defaultFailureMarkerFile(Ref ref) => '';

class _FailureMarkerStore implements FailureMarkerStore {
  const _FailureMarkerStore();

  @override
  Future<String?> take() async => null;
}
