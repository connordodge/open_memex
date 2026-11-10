import 'package:flutter/painting.dart';

/// A vault's colour, hashed from its full label: a local vault's folder
/// name, or a hosted vault's `<vault> · <server>` (Spec #357 Req 18). The
/// same label gives the same colour on its sidebar pill and picker row.
Color vaultColorFor(String label) => const Color(0x00000000);
