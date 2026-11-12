/// One agent presence record (#390 req 3, D14): an MCP client connected to
/// the vault, one per `memex serve` session, bridge or HTTP client. All times
/// are ms epoch. Frozen (D14): #394 and A2-A5 build on these fields.
class AgentPresence {
  const AgentPresence({
    required this.sessionId,
    required this.clientName,
    this.clientVersion,
    required this.transport,
    required this.startedAt,
    required this.lastSeenAt,
    required this.lastRequestAt,
    this.lastToolAt,
    required this.expiresAt,
    required this.embeddings,
  });

  /// A presence record from its snake_case JSON (req 3), shared by the
  /// presence files and the hosted wire. Throws [FormatException] on a missing
  /// required key or a wrong type; ignores unknown keys.
  factory AgentPresence.fromJson(Map<String, Object?> json) => AgentPresence(
    sessionId: _required<String>(json, 'session_id'),
    clientName: _required<String>(json, 'client_name'),
    clientVersion: _optional<String>(json, 'client_version'),
    transport: _required<String>(json, 'transport'),
    startedAt: _required<int>(json, 'started_at'),
    lastSeenAt: _required<int>(json, 'last_seen_at'),
    lastRequestAt: _required<int>(json, 'last_request_at'),
    lastToolAt: _optional<int>(json, 'last_tool_at'),
    expiresAt: _required<int>(json, 'expires_at'),
    embeddings: _required<bool>(json, 'embeddings'),
  );

  final String sessionId;
  final String clientName;
  final String? clientVersion;

  /// `stdio`, `bridge` or `http`; an unknown value is kept as-is.
  final String transport;
  final int startedAt;
  final int lastSeenAt;
  final int lastRequestAt;
  final int? lastToolAt;
  final int expiresAt;
  final bool embeddings;
}

/// One agent activity log entry (#390 req 9, D14). `createdAt` is ms epoch.
class AgentActivityEntry {
  const AgentActivityEntry({
    required this.id,
    required this.sessionId,
    required this.clientName,
    required this.tool,
    required this.summary,
    this.noteId,
    required this.createdAt,
  });

  /// An entry from its snake_case JSON (req 9). Throws [FormatException] on a
  /// missing required key or a wrong type; ignores unknown keys.
  factory AgentActivityEntry.fromJson(Map<String, Object?> json) =>
      AgentActivityEntry(
        id: _required<String>(json, 'id'),
        sessionId: _required<String>(json, 'session_id'),
        clientName: _required<String>(json, 'client_name'),
        tool: _required<String>(json, 'tool'),
        summary: _required<String>(json, 'summary'),
        noteId: _optional<String>(json, 'note_id'),
        createdAt: _required<int>(json, 'created_at'),
      );

  final String id;
  final String sessionId;
  final String clientName;
  final String tool;
  final String summary;
  final String? noteId;
  final int createdAt;
}

/// What `AgentsAccess.activity` returns (#390 req 14, D14).
class AgentActivity {
  const AgentActivity({
    required this.agents,
    required this.recent,
    required this.available,
    this.serverNow,
  });

  /// The hosted wire (`agents`, `recent`, `available`, `server_now`).
  /// Throws [FormatException] on a missing required key or a wrong type.
  factory AgentActivity.fromJson(Map<String, Object?> json) => AgentActivity(
    agents: [
      for (final item in _required<List<Object?>>(json, 'agents'))
        AgentPresence.fromJson(_object(item, 'agents')),
    ],
    recent: [
      for (final item in _required<List<Object?>>(json, 'recent'))
        AgentActivityEntry.fromJson(_object(item, 'recent')),
    ],
    available: _required<bool>(json, 'available'),
    serverNow: _optional<int>(json, 'server_now'),
  );

  /// Every parsed presence record, expired or not, by `lastRequestAt`
  /// descending.
  final List<AgentPresence> agents;

  /// The newest agent activity entries (up to 20), newest first.
  final List<AgentActivityEntry> recent;

  /// False when the vault server has no agents route (an older server).
  final bool available;

  /// The server's clock (ms epoch) when it answered; hosted vaults only.
  final int? serverNow;
}

/// The open vault's agents (#390 req 14, D14): read-only, one read. Test
/// doubles `extends LocalAgentsAccess` (D21).
abstract interface class AgentsAccess {
  Future<AgentActivity> activity();
}

/// The value at [key] as a [T]; [FormatException] when it is missing, null
/// or of another type.
T _required<T extends Object>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw FormatException(
    value == null && !json.containsKey(key)
        ? 'missing required key "$key"'
        : 'expected $T for "$key", got ${value.runtimeType}',
  );
}

/// The value at [key] as a [T], or null when it is null or absent;
/// [FormatException] when it is of another type.
T? _optional<T extends Object>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is T) return value as T?;
  throw FormatException(
    'expected $T or null for "$key", got ${value.runtimeType}',
  );
}

/// One element of the list at [key] as a JSON object; [FormatException] when
/// it is not one.
Map<String, Object?> _object(Object? item, String key) {
  if (item is Map<String, Object?>) return item;
  if (item is Map && item.keys.every((k) => k is String)) {
    return item.cast<String, Object?>();
  }
  throw FormatException(
    'expected an object in "$key", got ${item.runtimeType}',
  );
}
