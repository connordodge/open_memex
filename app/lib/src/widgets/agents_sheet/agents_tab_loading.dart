import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/clock.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// A tab's loading state (Spec #394 req 44): an empty body, then `loading…`
/// in fg2 once 400 ms have passed on the injected clock (`clockProvider`).
/// Every tab shows it while its data loads.
class AgentsTabLoading extends ConsumerStatefulWidget {
  const AgentsTabLoading({super.key});

  /// How long the body stays empty before `loading…` shows.
  static const delay = Duration(milliseconds: 400);

  @override
  ConsumerState<AgentsTabLoading> createState() => _AgentsTabLoadingState();
}

class _AgentsTabLoadingState extends ConsumerState<AgentsTabLoading> {
  Timer? _timer;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _timer = ref.read(clockProvider).after(AgentsTabLoading.delay, () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_shown) return const SizedBox.shrink();
    return Text(
      'loading…',
      style: OmType.sans(size: 12.5, color: OmColors.fg2),
    );
  }
}
