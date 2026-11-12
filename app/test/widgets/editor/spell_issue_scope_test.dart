// WI #434 (Spec #392): the per-field spelling issue registry, the scope that
// hands one note editor's registry to its fields (inserted at the root of
// SegmentedBody and SourceSurface), and the shared `pumpSpellingEditor`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';
import 'package:open_memex_app/src/widgets/editor/source_surface.dart';
import 'package:open_memex_app/src/widgets/editor/spell_issue_scope.dart';

import '../../robots/segmented_editor_robot.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/spelling_editor_pump.dart';

SpellIssue _issue(int start, int length) => SpellIssue(
  kind: SpellIssueKind.spelling,
  start: start,
  length: length,
  corrections: ['x$start'],
);

/// Records the registry it finds on every build. Const, so it rebuilds only
/// when the scope notifies it.
class _Wi434Probe extends StatelessWidget {
  const _Wi434Probe(this.seen);

  final List<SpellIssueRegistry?> seen;

  @override
  Widget build(BuildContext context) {
    seen.add(SpellIssueScope.maybeOf(context));
    return const SizedBox();
  }
}

/// The registry the field at [field] finds.
SpellIssueRegistry? _registryAt(WidgetTester tester, Finder field) =>
    SpellIssueScope.maybeOf(tester.element(field));

void main() {
  holdFontFetches();

  group('SpellIssueRegistry (AC12)', () {
    test(
      'setIssues notifies only the listenable of that field and keeps its issues',
      () {
        final registry = SpellIssueRegistry();
        final a = TextEditingController(text: 'teh cat');
        final b = TextEditingController(text: 'dgo');
        addTearDown(a.dispose);
        addTearDown(b.dispose);

        final la = registry.issuesFor(a);
        final lb = registry.issuesFor(b);
        expect(la.value, isEmpty);
        expect(lb.value, isEmpty);
        var aNotes = 0;
        var bNotes = 0;
        la.addListener(() => aNotes++);
        lb.addListener(() => bNotes++);

        final issues = [_issue(0, 3)];
        registry.setIssues(a, issues);
        expect(aNotes, 1);
        expect(bNotes, 0);
        expect(la.value, issues);
        expect(registry.issuesFor(a).value, issues);
        expect(lb.value, isEmpty);

        registry.setIssues(b, [_issue(0, 3)]);
        expect(aNotes, 1);
        expect(bNotes, 1);
        expect(lb.value, [_issue(0, 3)]);
        expect(la.value, issues);
      },
    );

    test('issuesFor answers the same listenable for the same field', () {
      final registry = SpellIssueRegistry();
      final a = TextEditingController();
      addTearDown(a.dispose);
      expect(identical(registry.issuesFor(a), registry.issuesFor(a)), isTrue);
      registry.setIssues(a, [_issue(1, 2)]);
      expect(identical(registry.issuesFor(a), registry.issuesFor(a)), isTrue);
    });

    test('a field first seen through setIssues reads back its issues', () {
      final registry = SpellIssueRegistry();
      final a = TextEditingController();
      addTearDown(a.dispose);
      registry.setIssues(a, [_issue(2, 4)]);
      expect(registry.issuesFor(a).value, [_issue(2, 4)]);
    });

    test(
      'clear empties every field and notifies the fields that had issues',
      () {
        final registry = SpellIssueRegistry();
        final a = TextEditingController();
        final b = TextEditingController();
        addTearDown(a.dispose);
        addTearDown(b.dispose);
        registry.setIssues(a, [_issue(0, 1)]);
        registry.setIssues(b, [_issue(1, 1)]);
        final la = registry.issuesFor(a);
        final lb = registry.issuesFor(b);
        var notes = 0;
        la.addListener(() => notes++);
        lb.addListener(() => notes++);

        registry.clear();
        expect(la.value, isEmpty);
        expect(lb.value, isEmpty);
        expect(registry.issuesFor(a).value, isEmpty);
        expect(notes, 2);

        // Still live after a clear.
        registry.setIssues(a, [_issue(3, 1)]);
        expect(la.value, [_issue(3, 1)]);
      },
    );
  });

  group('SpellIssueRegistry forget (review r1)', () {
    test(
      'forget drops a field so a later issuesFor starts empty and fresh',
      () {
        final registry = SpellIssueRegistry();
        final a = TextEditingController();
        final b = TextEditingController();
        addTearDown(a.dispose);
        addTearDown(b.dispose);
        registry.setIssues(a, [_issue(0, 1)]);
        registry.setIssues(b, [_issue(1, 1)]);
        final before = registry.issuesFor(a);

        registry.forget(a);

        final after = registry.issuesFor(a);
        expect(identical(before, after), isFalse);
        expect(after.value, isEmpty);
        // The other field is untouched.
        expect(registry.issuesFor(b).value, [_issue(1, 1)]);
      },
    );

    test('forget disposes the dropped listenable', () {
      final registry = SpellIssueRegistry();
      final a = TextEditingController();
      addTearDown(a.dispose);
      final notifier = registry.issuesFor(a);
      registry.forget(a);
      // A disposed ValueNotifier refuses new listeners.
      expect(() => notifier.addListener(() {}), throwsFlutterError);
    });

    test('forget of a field the registry never saw does nothing', () {
      final registry = SpellIssueRegistry();
      final a = TextEditingController();
      final b = TextEditingController();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      registry.setIssues(a, [_issue(0, 1)]);
      registry.forget(b);
      expect(registry.issuesFor(a).value, [_issue(0, 1)]);
    });

    test('clear after forget notifies only the fields still held', () {
      final registry = SpellIssueRegistry();
      final a = TextEditingController();
      final b = TextEditingController();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      registry.setIssues(a, [_issue(0, 1)]);
      registry.setIssues(b, [_issue(1, 1)]);
      registry.forget(a);
      final lb = registry.issuesFor(b);
      var notes = 0;
      lb.addListener(() => notes++);
      registry.clear();
      expect(notes, 1);
      expect(lb.value, isEmpty);
    });
  });

  group('SpellIssueScope (AC12)', () {
    testWidgets('maybeOf finds the registry of the nearest scope', (
      tester,
    ) async {
      final registry = SpellIssueRegistry();
      final seen = <SpellIssueRegistry?>[];
      await tester.pumpWidget(
        SpellIssueScope(registry: registry, child: _Wi434Probe(seen)),
      );
      expect(seen.last, same(registry));

      final inner = SpellIssueRegistry();
      await tester.pumpWidget(
        SpellIssueScope(
          registry: registry,
          child: SpellIssueScope(registry: inner, child: _Wi434Probe(seen)),
        ),
      );
      expect(seen.last, same(inner));
    });

    testWidgets('maybeOf answers null with no scope above', (tester) async {
      final seen = <SpellIssueRegistry?>[];
      await tester.pumpWidget(_Wi434Probe(seen));
      expect(seen.single, isNull);
    });

    testWidgets(
      'a dependent rebuilds when the registry changes and not when it stays',
      (tester) async {
        final first = SpellIssueRegistry();
        final second = SpellIssueRegistry();
        final seen = <SpellIssueRegistry?>[];
        final probe = _Wi434Probe(seen);
        await tester.pumpWidget(SpellIssueScope(registry: first, child: probe));
        expect(seen, [same(first)]);

        await tester.pumpWidget(SpellIssueScope(registry: first, child: probe));
        expect(seen, hasLength(1));

        await tester.pumpWidget(
          SpellIssueScope(registry: second, child: probe),
        );
        expect(seen, hasLength(2));
        expect(seen.last, same(second));
      },
    );

    testWidgets(
      'maybeOf finds one registry for every field under SegmentedBody and it survives typing',
      (tester) async {
        // The default topic body: text, an excerpt card, text (two text
        // segments, one note editor).
        final e = await pumpSpellingEditor(tester, body: fixtureTopicBody);
        expect(find.byType(SegmentedBody), findsOneWidget);
        final first = e.rowFields(0).first;
        final second = e.rowFields(2).first;
        final registry = _registryAt(tester, first);
        expect(registry, isNotNull);
        expect(_registryAt(tester, second), same(registry));
        expect(
          find.ancestor(of: first, matching: find.byType(SpellIssueScope)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(SegmentedBody),
            matching: find.byType(SpellIssueScope),
          ),
          findsOneWidget,
        );

        await e.typeAtEnd('more');
        expect(e.robot.segmentText(0), endsWith('more'));
        expect(_registryAt(tester, e.rowFields(0).first), same(registry));
      },
    );

    testWidgets(
      'maybeOf finds the registry under SourceSurface and Source mode has its own registry',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: 'Intro line\n');
        final live = _registryAt(tester, e.rowFields(0).first);
        expect(live, isNotNull);

        await e.toggleSource();
        expect(find.byType(SourceSurface), findsOneWidget);
        final source = _registryAt(tester, e.sourceField);
        expect(source, isNotNull);
        expect(source, isNot(same(live)));
        expect(
          find.descendant(
            of: find.byType(SourceSurface),
            matching: find.byType(SpellIssueScope),
          ),
          findsOneWidget,
        );

        await e.typeAtEnd('x');
        expect(_registryAt(tester, e.sourceField), same(source));
      },
    );
  });

  group('pumpSpellingEditor (AC13)', () {
    testWidgets(
      'pumpSpellingEditor pumps a body in live preview with the fake service and typing reaches the body',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: 'Teh cat sat');
        expect(e.textSegment(0), findsOneWidget);
        expect(e.sourceSurface, findsNothing);
        expect(e.bodyText, 'Teh cat sat');
        // The fake is the app's spelling service: the menu sync reached it.
        expect(e.spelling.count('setMenuState'), 1);
        expect(_registryAt(tester, e.rowFields(0).first), isNotNull);

        await e.typeAtEnd(' down');
        expect(e.bodyText, 'Teh cat sat down');
      },
    );

    testWidgets(
      'pumpSpellingEditor pumps a body in Source mode with the fake service and typing reaches the body',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Teh cat sat',
          source: true,
        );
        expect(e.sourceSurface, findsOneWidget);
        expect(e.bodyText, 'Teh cat sat');
        expect(e.spelling.count('setMenuState'), 1);
        expect(_registryAt(tester, e.sourceField), isNotNull);

        await e.typeAtEnd('!');
        expect(e.bodyText, 'Teh cat sat!');
      },
    );
  });
}
