import 'package:flutter/widgets.dart';

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
  Widget build(BuildContext context) => throw UnimplementedError();
}
