// WI #129 (Spec #122 Requirement 22): the note-titles lookup the editor's
// link regions share, built once per note-titles reload.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../vault_access/vault_scoped.dart';
import 'vault_state.dart';

/// Test-only work counter: how many title-to-note-id lookups were built from
/// a note-titles load (one per reload once the lookup is shared; one per
/// link region before). A plain top-level int, never read by production
/// code.
int debugNoteTitleLookupBuilds = 0;

/// The most titles `noteTitlesAsyncProvider` loads: a list this long may be
/// cut short, so no wikilink renders as a ghost (D14).
const int noteTitlesCap = 1000;

/// Note ids by title from one note-titles load.
@immutable
class NoteTitleLookup {
  const NoteTitleLookup._(this.titles, this.ids);

  /// Before the titles load: every target resolves.
  static const NoteTitleLookup unloaded = NoteTitleLookup._(null, null);

  /// The lookup of [titles] (the first of equal titles wins), or one that
  /// resolves every target while the list is at [noteTitlesCap].
  factory NoteTitleLookup.of(List<NoteTitle> titles) {
    if (titles.length >= noteTitlesCap) return NoteTitleLookup._(titles, null);
    debugNoteTitleLookupBuilds++;
    return NoteTitleLookup._(titles, {
      for (final t in titles.reversed) t.title: t.id,
    });
  }

  /// The load this lookup was built from; null before the titles load.
  final List<NoteTitle>? titles;

  /// Note id by title, or null while every target resolves (titles not
  /// loaded, or the list at its cap).
  final Map<String, String>? ids;

  /// Whether a wikilink or transclusion [target] resolves: a note's title
  /// equals it; always true while [ids] is null.
  bool resolves(String target) => ids?.containsKey(target) ?? true;
}

/// One link region's subscription to [NoteTitleResolver]: [onChanged] runs
/// when one of [targets] resolves differently after a reload.
class NoteTitleSubscription {
  NoteTitleSubscription._(this._resolver, this.targets, this.onChanged);

  final NoteTitleResolver _resolver;

  /// The region's link targets now (wikilink titles and transclusion
  /// dates), read at each reload.
  final Iterable<String> Function() targets;

  final VoidCallback onChanged;

  /// Stops [onChanged].
  void cancel() => _resolver._subscriptions.remove(this);
}

/// The one note-titles lookup every link region reads (Spec #122 R22): it
/// is rebuilt once per note-titles reload. The first load (after none, or
/// after another vault's) calls back every subscription; a later reload
/// only those with a link target that resolves differently under it.
class NoteTitleResolver {
  NoteTitleLookup _lookup = NoteTitleLookup.unloaded;

  final Set<NoteTitleSubscription> _subscriptions = {};

  /// The lookup of the latest titles load.
  NoteTitleLookup get lookup => _lookup;

  /// Calls [onChanged] after the first titles load and after each reload in
  /// which one of [targets] resolves differently, until the subscription is
  /// cancelled.
  NoteTitleSubscription subscribe(
    Iterable<String> Function() targets,
    VoidCallback onChanged,
  ) {
    final subscription = NoteTitleSubscription._(this, targets, onChanged);
    _subscriptions.add(subscription);
    return subscription;
  }

  /// Takes the titles of a load ([titles], null while none is loaded for
  /// the current vault). The same list again changes nothing.
  @visibleForTesting
  void update(List<NoteTitle>? titles) {
    if (identical(titles, _lookup.titles)) return;
    final before = _lookup;
    final after = titles == null
        ? NoteTitleLookup.unloaded
        : NoteTitleLookup.of(titles);
    _lookup = after;
    final firstLoad = before.titles == null;
    for (final subscription in [..._subscriptions]) {
      if (!_subscriptions.contains(subscription)) continue;
      final changed =
          firstLoad ||
          subscription.targets().any(
            (target) => before.resolves(target) != after.resolves(target),
          );
      if (changed) subscription.onChanged();
    }
  }
}

/// The current vault's [NoteTitleResolver], fed from
/// `noteTitlesAsyncProvider`. Watched by every link region: its value never
/// changes, so watching it rebuilds nothing.
final noteTitleResolverProvider = Provider.autoDispose<NoteTitleResolver>((
  ref,
) {
  final resolver = NoteTitleResolver();
  void sync() => resolver.update(
    currentVaultData(
      ref.read(noteTitlesAsyncProvider),
      ref.read(currentVaultProvider),
    )?.value,
  );
  ref.listen(noteTitlesAsyncProvider, (_, _) => sync());
  ref.listen(currentVaultProvider, (_, _) => sync());
  sync();
  return resolver;
});
