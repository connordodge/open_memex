// WI #434 (Spec #392): the per-field spelling issue registry and the scope a
// note editor hands it down with.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../editor/spell_issues.dart';

/// The spelling issues of each row field of one note editor. Offsets are
/// field-local (into that field's text).
///
/// [issuesFor] answers the same listenable for a field every time, and
/// [setIssues] notifies only that field's listenable. [clear] empties every
/// field through those same listenables, which keep working afterwards.
/// [forget] drops a field that is gone (a retired or replaced row).
class SpellIssueRegistry {
  final _byField = <TextEditingController, ValueNotifier<List<SpellIssue>>>{};

  ValueNotifier<List<SpellIssue>> _notifierFor(TextEditingController field) =>
      _byField.putIfAbsent(field, () => ValueNotifier(const []));

  ValueListenable<List<SpellIssue>> issuesFor(TextEditingController field) =>
      _notifierFor(field);

  void setIssues(TextEditingController field, List<SpellIssue> issues) =>
      _notifierFor(field).value = List.unmodifiable(issues);

  /// Drops [field]'s entry and disposes its listenable. A later [issuesFor]
  /// or [setIssues] for [field] starts a fresh, empty one. Call it once
  /// nothing listens to [field]'s listenable any more.
  void forget(TextEditingController field) => _byField.remove(field)?.dispose();

  void clear() {
    for (final n in _byField.values) {
      n.value = const [];
    }
  }
}

/// Hands one note editor's [SpellIssueRegistry] to the fields below it.
class SpellIssueScope extends InheritedWidget {
  const SpellIssueScope({
    super.key,
    required this.registry,
    required super.child,
  });

  final SpellIssueRegistry registry;

  /// The nearest scope's registry, or null with none above [context].
  /// Registers [context] as a dependent.
  static SpellIssueRegistry? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SpellIssueScope>()?.registry;

  @override
  bool updateShouldNotify(SpellIssueScope oldWidget) =>
      !identical(registry, oldWidget.registry);
}
