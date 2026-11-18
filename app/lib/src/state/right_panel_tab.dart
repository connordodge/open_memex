import 'package:flutter_riverpod/flutter_riverpod.dart';

enum RightPanelTab { connections, echoes, outline, activity }

final rightPanelTabProvider = StateProvider<RightPanelTab>(
  (_) => RightPanelTab.connections,
);
