import 'package:flutter/painting.dart';

import '../theme/colors.dart';

/// The vault colours, in hash order (the sidebar pills' palette, pack 96).
const _vaultPalette = [
  OmColors.accent,
  OmColors.info,
  OmColors.warn,
  OmColors.agent,
  OmColors.fg2,
];

/// A vault's colour, hashed from its full label: a local vault's folder
/// name, or a hosted vault's `<vault> · <server>` (Spec #357 Req 18). The
/// same label gives the same colour on its sidebar pill and picker row.
Color vaultColorFor(String label) =>
    _vaultPalette[label.hashCode.abs() % _vaultPalette.length];
