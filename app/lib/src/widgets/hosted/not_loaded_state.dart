import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// The body of a tab whose content never loaded while its vault server can't
/// be reached (A11 state 3).
class NotLoadedState extends StatelessWidget {
  const NotLoadedState({
    super.key,
    required this.title,
    required this.serverName,
  });

  final String title;
  final String serverName;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('tab-not-loaded'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.wifiOff, size: 16, color: OmColors.fg2),
          const SizedBox(height: 10),
          Text(
            '$title isn\'t loaded and $serverName can\'t be reached.',
            textAlign: TextAlign.center,
            style: OmType.sans(
              size: 13,
              color: OmColors.fg1,
              height: 19.5 / 13,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'it opens as soon as $serverName answers.',
            textAlign: TextAlign.center,
            style: OmType.mono(
              size: 11,
              color: OmColors.fg2,
              height: 16.5 / 11,
            ),
          ),
        ],
      ),
    );
  }
}
