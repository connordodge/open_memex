import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_ports.dart';

// Stub (A0 #32). A2 #34 fills this file and keeps each `defaultX(Ref)`.

/// The production [FailureMarkerStore] behind `failureMarkerStoreProvider`.
FailureMarkerStore defaultFailureMarkerStore(Ref ref) =>
    throw UnimplementedError();

/// The production marker path behind `failureMarkerFileProvider`
/// (`<appSupportDir>/self_update_failure`). Computing it must not touch the
/// file system.
String defaultFailureMarkerFile(Ref ref) => '';
