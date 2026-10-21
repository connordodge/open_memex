// WI #102 (H8) test doubles: a hosted vault's notes domain. It extends
// `LocalNotesAccess` (D21) over a FakeVaultDb / FakeMemexCli, and can make
// every write fail the way the hosted client does (L17, D17):
// `VaultUnreachableException` (refused, or timed out after the request was
// sent and maybe committed) or `MemexException(code: unauthorized)` for a
// 401. Like `HostedClient`'s response hook it records each write's outcome in
// `hostedConnectionStatusProvider` before the caller sees it.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'today_cli_fakes.dart';

/// The saved vault server's id the hosted test vault lives on.
const hostedServerId = 'srv-1';

/// The hosted test vault: `plan` on [hostedServerId].
const hostedPlanVault = HostedVaultRef(hostedServerId, 'plan');

/// The server's name as `VaultUnreachableException` carries it.
const hostedServerName = 'nas';

/// The editor label for a save that couldn't reach `nas` (Req 50, L16).
const pendingLabelNas = 'not saved yet · will save when nas is back';

/// The error a hosted write throws when `nas` can't be reached:
/// [mayHaveCommitted] false for a refused connection, true for a timeout
/// after the request was sent.
VaultUnreachableException nasUnreachable({bool mayHaveCommitted = false}) =>
    VaultUnreachableException(
      serverName: hostedServerName,
      mayHaveCommitted: mayHaveCommitted,
    );

/// The error a hosted `update` throws on a `401` (D17: code `unauthorized`).
MemexException unauthorized401() =>
    MemexException.fromC1('update', {'code': 'unauthorized'});

/// A hosted notes domain over [vault] / [cli] that records writes
/// (`updateNote:<id>@<expected>`, `addNote:<title>:<role>`) and reads
/// (`getNote:<id>`).
class HostedNotesAccess extends LocalNotesAccess {
  HostedNotesAccess({required super.vaultPath, required this.vault, super.cli})
    : super(db: vault);

  final FakeVaultDb vault;

  final reads = <String>[];
  final writes = <String>[];

  /// The bodies sent with each `updateNote`, in order.
  final updateBodies = <String>[];

  /// When set, every write records itself and then throws this.
  Object? writeError;

  /// With [writeError] set: the write commits on the server first (the
  /// request timed out after the server wrote it, L17), then throws.
  bool commitBeforeError = false;

  /// How the server stores a committed `update` body (a daily note's
  /// canonical form); the body as sent when null.
  String Function(String body)? storedForm;

  /// When set, every write waits for it before doing anything else.
  Completer<void>? writeGate;

  /// The response hook: called with each write's connection outcome before
  /// the write returns or throws.
  void Function(HostedConnectionStatus status)? onOutcome;

  @override
  Future<Note?> getNote(String id) async {
    reads.add('getNote:$id');
    return super.getNote(id);
  }

  void _record(Object? error) {
    final status = switch (error) {
      null => HostedConnectionStatus.connected,
      VaultUnreachableException() => HostedConnectionStatus.unreachable,
      MemexException(code: 'unauthorized') =>
        HostedConnectionStatus.tokenRejected,
      _ => HostedConnectionStatus.connected,
    };
    onOutcome?.call(status);
  }

  Future<T> _write<T>(Future<T> Function() send) async {
    final gate = writeGate;
    if (gate != null) await gate.future;
    final error = writeError;
    if (error != null) {
      if (commitBeforeError) await send();
      _record(error);
      throw error;
    }
    try {
      final result = await send();
      _record(null);
      return result;
    } catch (e) {
      _record(e);
      rethrow;
    }
  }

  @override
  Future<NoteUpdateResult> updateNote({
    required String noteId,
    required int expectedVersion,
    String? title,
    required String contentMd,
    bool noRenameLinks = false,
  }) {
    writes.add('updateNote:$noteId@$expectedVersion');
    updateBodies.add(contentMd);
    return _write(
      () => super.updateNote(
        noteId: noteId,
        expectedVersion: expectedVersion,
        title: title,
        contentMd: storedForm?.call(contentMd) ?? contentMd,
        noRenameLinks: noRenameLinks,
      ),
    );
  }

  @override
  Future<String> addNote({
    String? title,
    List<String> tags = const [],
    required String contentMd,
    String? role,
  }) {
    writes.add('addNote:$title:$role');
    return _write(
      () => super.addNote(
        title: title,
        tags: tags,
        contentMd: contentMd,
        role: role,
      ),
    );
  }

  /// The `updateNote` calls for [noteId] so far.
  List<String> updatesOf(String noteId) =>
      writes.where((w) => w.startsWith('updateNote:$noteId@')).toList();
}

/// One hosted notes double per vault, built when `vaultAccessProvider`
/// first builds for that vault.
class HostedVaultDoubles {
  HostedVaultDoubles({required this.db, required this.cli, this.vaultPath});

  final FakeVaultDb db;
  final FakeMemexCli cli;

  /// The folder the doubles' CLI writes name; any string works.
  final String? vaultPath;

  final Map<VaultRef, HostedNotesAccess> _notes = {};

  /// Called with each write's connection outcome (see
  /// [HostedNotesAccess.onOutcome]).
  void Function(VaultRef vault, HostedConnectionStatus status)? onOutcome;

  /// The notes double of [vault] (built on first use).
  HostedNotesAccess notesFor(VaultRef vault) => _notes.putIfAbsent(
    vault,
    () => HostedNotesAccess(
      vaultPath: vaultPath ?? '/hosted/$vault',
      vault: db,
      cli: cli,
    )..onOutcome = (s) => onOutcome?.call(vault, s),
  );

  LocalVaultAccess build(VaultRef vault) => LocalVaultAccess(
    vaultPath: vaultPath ?? '/hosted/$vault',
    db: db,
    cli: cli,
    notes: notesFor(vault),
  );
}

/// `vaultAccessProvider` over [doubles] for any open vault, local or hosted
/// (null with no vault).
Override hostedAccessOverride(HostedVaultDoubles doubles) =>
    vaultAccessProvider.overrideWith((ref) {
      final vault = ref.watch(currentVaultProvider);
      if (vault == null) return null;
      return doubles.build(vault);
    });

/// Wires [doubles]' outcomes into [container]'s
/// `hostedConnectionStatusProvider`, as `HostedClient`'s response hook does.
void recordHostedOutcomes(
  HostedVaultDoubles doubles,
  ProviderContainer container,
) {
  doubles.onOutcome = (vault, status) {
    if (vault is! HostedVaultRef) return;
    container
            .read(hostedConnectionStatusProvider(vault.serverId).notifier)
            .state =
        status;
  };
}

/// Sets the hosted test server's connection status (the revision poll's
/// outcome, D17).
void setHostedStatus(ProviderContainer c, HostedConnectionStatus status) {
  c.read(hostedConnectionStatusProvider(hostedServerId).notifier).state =
      status;
}

extension HostedTodayCliFakes on FakeMemexCli {
  /// `memex add --role daily` on a server: creates the daily note [id] for
  /// `--title` (canonical body, version 1) when that date has none, else
  /// answers C1 `daily_note_exists` with the existing note's `existing_id`.
  void onAddDailyCreatesOnce(FakeVaultDb db, {String id = createdDailyId}) {
    on('add', (call) {
      final date = call.flag('title')!;
      final existing = db.db.select(
        "SELECT id FROM notes WHERE title = ? AND frontmatter LIKE '%daily%'",
        [date],
      );
      if (existing.isNotEmpty) {
        return FakeMemexCli.error(
          'daily_note_exists',
          'daily note for $date already exists',
          {'existing_id': existing.first['id'] as String},
        );
      }
      final person = splitDailyBody(call.stdinBody ?? '').person;
      db.seedNote(
        id: id,
        title: date,
        content: assembleDailyBody(person, const []),
        role: 'daily',
        version: 1,
        createdAt: 1759474800000,
      );
      return FakeMemexCli.ok(addDailyStdout(id, date));
    });
  }
}
