import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Display name of a saved vault server, by server id. Defaults to the id; #105 binds it to the saved server's name.
final hostedServerNameProvider = Provider.family<String, String>(
  (ref, serverId) => serverId,
);
