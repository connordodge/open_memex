import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../editor/outline.dart';

// The Outline's current section (#69, Spec #58 R22-R26, R41, TD6): the
// entry of the section the editor shows at its top, or none. The editor's
// section tracker (`widgets/outline/section_tracker.dart`) reports it; it
// runs only while something watches this provider.

/// Holds the current Outline entry of the note the editor shows, or null.
class OutlineSectionNotifier extends AutoDisposeNotifier<OutlineEntry?> {
  @override
  OutlineEntry? build() {
    // The hub lets the tracker see whether anything watches this provider
    // without watching it itself.
    final hub = ref.watch(outlineSectionHubProvider);
    hub._attach(this);
    ref.onCancel(() => hub._setWatched(this, false));
    ref.onResume(() => hub._setWatched(this, true));
    ref.onDispose(() => hub._detach(this));
    return null;
  }

  void _report(OutlineEntry? entry) {
    if (state != entry) state = entry;
  }
}

/// The current Outline entry, or null: none above the first heading, in
/// Source mode, or with no note shown.
final outlineSectionProvider =
    NotifierProvider.autoDispose<OutlineSectionNotifier, OutlineEntry?>(
      OutlineSectionNotifier.new,
    );

/// An Outline jump to [entry] of note [noteId], computed from [content],
/// made while `tabsProvider.arrivals` was [arrivals] (Spec #58 R22: the
/// jumped-to entry is current right after the jump).
@immutable
class OutlineJump {
  const OutlineJump({
    required this.noteId,
    required this.entry,
    required this.content,
    required this.arrivals,
  });

  final String noteId;
  final OutlineEntry entry;
  final String content;
  final int? arrivals;
}

/// What the editor's section tracker shares with the Outline side: whether
/// [outlineSectionProvider] is watched, where its reports go, and the last
/// Outline jump. Notifies when the provider gains or loses its listeners and
/// when a jump is made.
class OutlineSectionHub extends ChangeNotifier {
  OutlineSectionNotifier? _notifier;
  bool _watched = false;
  Object? _owner;
  OutlineJump? _jump;
  bool _jumpLanded = false;

  /// Something watches [outlineSectionProvider]: the tracker computes only
  /// then.
  bool get watched => _watched && _notifier != null;

  /// The last Outline jump, until the tracker drops it.
  OutlineJump? get jump => _jump;

  /// The page has sat where [jump] lands it since the tracker last looked.
  bool get jumpLanded => _jumpLanded;

  void _attach(OutlineSectionNotifier notifier) {
    _notifier = notifier;
    _setWatched(notifier, true);
  }

  void _detach(OutlineSectionNotifier notifier) {
    if (!identical(_notifier, notifier)) return;
    _notifier = null;
    _watched = false;
  }

  void _setWatched(OutlineSectionNotifier notifier, bool watched) {
    if (!identical(_notifier, notifier) || _watched == watched) return;
    _watched = watched;
    notifyListeners();
  }

  /// [owner] (a tracker) reports [entry] as the current section.
  void report(Object owner, OutlineEntry? entry) {
    _owner = owner;
    _notifier?._report(entry);
  }

  /// [owner] went away (the editor left the segmented view): when it made
  /// the last report, the current section becomes none, once the tree is
  /// no longer locked, unless another tracker reported in between.
  void leave(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    scheduleMicrotask(() {
      if (_owner == null) _notifier?._report(null);
    });
  }

  /// Records an Outline jump; it replaces any earlier one.
  void jumped(OutlineJump jump) {
    _jump = jump;
    _jumpLanded = false;
    notifyListeners();
  }

  /// The page sits where [jump] lands it.
  void markLanded() => _jumpLanded = true;

  /// Drops [jump]: the normal rule decides again.
  void dropJump() {
    _jump = null;
    _jumpLanded = false;
  }
}

/// The one [OutlineSectionHub] of the app.
final outlineSectionHubProvider = Provider<OutlineSectionHub>((ref) {
  final hub = OutlineSectionHub();
  ref.onDispose(hub.dispose);
  return hub;
});
