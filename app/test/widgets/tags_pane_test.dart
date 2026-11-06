// WI #251 (A4): the sidebar's Tags mode (`TagsPane`, Key `tags-pane`) and
// `revealTag` (state/tags_browse_state.dart). Design pack 251: dense 24 px
// mono tag rows, note rows 36 px with a first line and 22 px without, a
// collapsed `SYSTEM` group last. Reads come from doubles that extend
// `LocalTagsAccess` (D21) or from a FakeVaultDb; clicks are asserted on
// `TabsRecorder.followed`, never on tab counts.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/tags_browse_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/vault_async_view.dart';

import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/tags_pane_harness.dart';
import '../support/tags_seed.dart';

const _emptyCopy = 'No tags yet. Type #name in any note to tag it.';
const _longTag = 'pricing-and-renewals-2027-planning-draft';

Finder _row(String tag) => find.byKey(Key('tag-row-$tag'));
Finder _note(String tag, String id) => find.byKey(Key('tag-note-row-$tag-$id'));
Finder _inRow(String tag, Finder what) =>
    find.descendant(of: _row(tag), matching: what);
Finder _inNote(String tag, String id, Finder what) =>
    find.descendant(of: _note(tag, id), matching: what);
Finder _system() => find.text('SYSTEM');

bool _isOpen(String tag) =>
    _inRow(tag, find.byIcon(LucideIcons.chevronDown)).evaluate().isNotEmpty;

Color? _color(WidgetTester tester, Finder text) =>
    tester.widget<Text>(text).style?.color;

Future<void> _tap(WidgetTester tester, TagsEnv env, Finder what) async {
  expect(what, findsOneWidget);
  await tester.tap(what);
  await env.settle(tester);
}

/// Whether [row] lies fully inside the viewport of its nearest scrollable.
bool _inView(WidgetTester tester, Finder row) {
  final scrollable = find.ancestor(of: row, matching: find.byType(Scrollable));
  if (row.evaluate().isEmpty || scrollable.evaluate().isEmpty) return false;
  final view = tester.getRect(scrollable.first);
  final r = tester.getRect(row);
  return r.top >= view.top - 0.5 && r.bottom <= view.bottom + 0.5;
}

/// Whether a text [other] sits on the same line as the [anchor] text.
bool _sameLine(WidgetTester tester, Finder anchor, String other) {
  final y = tester.getCenter(anchor).dy;
  for (final e in find.text(other).evaluate()) {
    if ((tester.getCenter(find.byElementPredicate((x) => x == e)).dy - y)
            .abs() <
        2) {
      return true;
    }
  }
  return false;
}

void main() {
  holdFontFetches();

  group('the list', () {
    testWidgets(
      'lists non-system tags alphabetically with counts reading hash name',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());

        expect(find.byKey(const Key('tags-pane')), findsOneWidget);
        final order = ['health', 'memex', 'pricing', 'reading', 'work'];
        final counts = {
          'health': '2',
          'memex': '12',
          'pricing': '3',
          'reading': '5',
          'work': '7',
        };
        var previous = -1.0;
        for (final tag in order) {
          expect(_row(tag), findsOneWidget, reason: tag);
          expect(_inRow(tag, find.text('#$tag')), findsOneWidget);
          expect(_inRow(tag, find.text(counts[tag]!)), findsOneWidget);
          final dy = tester.getTopLeft(_row(tag)).dy;
          expect(dy, greaterThan(previous), reason: 'alphabetical: $tag');
          previous = dy;
        }
        // No notes until a tag is expanded, and nothing read for them yet.
        expect(find.byKey(const Key('tags-empty')), findsNothing);
        // System tags are not in the top-level list.
        expect(_row('inbox'), findsNothing);
        expect(find.text('#inbox'), findsNothing);
        expect(find.text('#agent-authored'), findsNothing);
        // Tag text carries no icon besides the chevron.
        expect(
          find.descendant(
            of: find.byKey(const Key('tags-pane')),
            matching: find.byType(Icon),
          ),
          findsNWidgets(order.length + 1),
          reason: 'one chevron per tag row and one for SYSTEM',
        );
        expect(env.tabs.followed, isEmpty);
      },
    );

    testWidgets(
      'a tag row is a full width 24 px row and clicking its edges expands and collapses its notes',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());

        final rect = tester.getRect(_row('work'));
        expect(rect.height, 24);
        expect(rect.width, 268 - 12);
        expect(rect.left, 6);
        expect(_note('work', 'w-1'), findsNothing);

        // Left padding, then the gap between name and count, then the right edge.
        await tester.tapAt(rect.centerLeft + const Offset(2, 0));
        await env.settle(tester);
        expect(_note('work', 'w-1'), findsOneWidget);
        expect(_note('work', 'w-2'), findsOneWidget);

        await tester.tapAt(rect.centerRight - const Offset(2, 0));
        await env.settle(tester);
        expect(_note('work', 'w-1'), findsNothing);

        await tester.tapAt(rect.center + const Offset(40, 0));
        await env.settle(tester);
        expect(_note('work', 'w-1'), findsOneWidget);

        await _tap(tester, env, _inRow('work', find.text('#work')));
        expect(_note('work', 'w-1'), findsNothing);
        expect(env.tabs.followed, isEmpty);
      },
    );

    testWidgets(
      'an expanded tag shows a chevron down and a green name and a collapsed one a chevron right and a plain name',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());

        expect(
          _inRow('work', find.byIcon(LucideIcons.chevronRight)),
          findsOneWidget,
        );
        expect(
          _inRow('work', find.byIcon(LucideIcons.chevronDown)),
          findsNothing,
        );
        expect(
          _color(tester, _inRow('work', find.text('#work'))),
          OmColors.fg1,
        );
        final chevron = tester.widget<Icon>(
          _inRow('work', find.byIcon(LucideIcons.chevronRight)),
        );
        expect(chevron.size, 11);
        expect(chevron.color, OmColors.fg2);
        expect(_color(tester, _inRow('work', find.text('7'))), OmColors.fg2);

        await _tap(tester, env, _row('work'));

        expect(
          _inRow('work', find.byIcon(LucideIcons.chevronDown)),
          findsOneWidget,
        );
        expect(
          _inRow('work', find.byIcon(LucideIcons.chevronRight)),
          findsNothing,
        );
        expect(
          _color(tester, _inRow('work', find.text('#work'))),
          OmColors.accentSoft,
        );
        // The chevron stays grey; the other tags are untouched.
        expect(
          tester
              .widget<Icon>(
                _inRow('work', find.byIcon(LucideIcons.chevronDown)),
              )
              .color,
          OmColors.fg2,
        );
        expect(
          _color(tester, _inRow('memex', find.text('#memex'))),
          OmColors.fg1,
        );

        await _tap(tester, env, _row('work'));
        expect(
          _color(tester, _inRow('work', find.text('#work'))),
          OmColors.fg1,
        );
      },
    );

    testWidgets('expanding a tag collapses the tag that was open before', (
      tester,
    ) async {
      final env = await pumpTagsPane(tester, tags: TagsDouble());

      await _tap(tester, env, _row('work'));
      expect(_note('work', 'w-1'), findsOneWidget);
      expect(_isOpen('work'), isTrue);

      await _tap(tester, env, _row('pricing'));

      expect(_note('pricing', 'p-1'), findsOneWidget);
      expect(_isOpen('pricing'), isTrue);
      expect(_note('work', 'w-1'), findsNothing);
      expect(_note('work', 'w-2'), findsNothing);
      expect(_isOpen('work'), isFalse);

      await _tap(tester, env, _row('pricing'));
      expect(_note('pricing', 'p-1'), findsNothing);
      expect(_isOpen('pricing'), isFalse);
      expect(_isOpen('work'), isFalse);
    });

    testWidgets(
      'an expanded tag lists its notes newest first directly under its row and pushes the rest down',
      (tester) async {
        final tags = TagsDouble();
        final env = await pumpTagsPane(tester, tags: tags);

        await _tap(tester, env, _row('pricing'));

        expect(tags.notesCalls, contains('pricing'));
        final ys = [
          tester.getTopLeft(_row('pricing')).dy,
          tester.getTopLeft(_note('pricing', 'd-today')).dy,
          tester.getTopLeft(_note('pricing', 'p-1')).dy,
          tester.getTopLeft(_note('pricing', 'd-old')).dy,
          tester.getTopLeft(_row('reading')).dy,
          tester.getTopLeft(_row('work')).dy,
          tester.getTopLeft(_system()).dy,
        ];
        for (var i = 1; i < ys.length; i++) {
          expect(ys[i], greaterThan(ys[i - 1]), reason: 'row $i');
        }
        // Directly under: no gap between the tag row and its first note.
        expect(
          tester.getTopLeft(_note('pricing', 'd-today')).dy,
          tester.getRect(_row('pricing')).bottom,
        );
        expect(
          tester.getRect(_row('reading')).top,
          tester.getRect(_note('pricing', 'd-old')).bottom,
        );
      },
    );
  });

  group('note rows', () {
    testWidgets(
      'a note shows its title and first line and a footer only note shows only its title',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());
        await _tap(tester, env, _row('pricing'));

        // Title only: 22 px, left padding 26.
        expect(tester.getSize(_note('pricing', 'p-1')).height, 22);
        expect(tester.getSize(_note('pricing', 'd-today')).height, 22);
        expect(_inNote('pricing', 'p-1', find.text('Pricing')), findsOneWidget);
        expect(_inNote('pricing', 'p-1', find.byType(Text)), findsOneWidget);
        expect(
          _inNote('pricing', 'd-today', find.byType(Text)),
          findsOneWidget,
        );

        // Title and first line: 36 px, the tag text shown literally.
        final withLine = _note('pricing', 'd-old');
        expect(tester.getSize(withLine).height, 36);
        expect(tester.getSize(withLine).width, 268 - 12);
        expect(
          _inNote('pricing', 'd-old', find.text('2026-11-02')),
          findsOneWidget,
        );
        expect(
          _inNote(
            'pricing',
            'd-old',
            find.text('renewal tiers feel wrong #pricing'),
          ),
          findsOneWidget,
        );
        final title = tester.getTopLeft(
          _inNote('pricing', 'd-old', find.text('2026-11-02')),
        );
        final line = tester.getTopLeft(
          _inNote(
            'pricing',
            'd-old',
            find.text('renewal tiers feel wrong #pricing'),
          ),
        );
        expect(title.dx - tester.getTopLeft(withLine).dx, 26);
        expect(line.dx, title.dx);
        expect(
          line.dy,
          greaterThan(title.dy),
          reason: 'first line under title',
        );
      },
    );

    testWidgets('note rows read in the type of the design', (tester) async {
      final env = await pumpTagsPane(tester, tags: TagsDouble());
      await _tap(tester, env, _row('work'));

      final title = tester.widget<Text>(
        _inNote('work', 'w-1', find.text('Call notes')),
      );
      final line = tester.widget<Text>(
        _inNote('work', 'w-1', find.text('call with Sam about pricing #work')),
      );
      expect(title.style?.fontSize, 11.5);
      expect(title.style?.color, OmColors.fg1);
      expect(line.style?.fontSize, 10.5);
      expect(line.style?.color, OmColors.fg2);
      final name = tester.widget<Text>(_inRow('work', find.text('#work')));
      expect(name.style?.fontSize, 12);
      final count = tester.widget<Text>(_inRow('work', find.text('7')));
      expect(count.style?.fontSize, 11);
    });

    testWidgets('the open note row reads as active and the others do not', (
      tester,
    ) async {
      final env = await pumpTagsPane(tester, tags: TagsDouble());
      env.container
          .read(tabsProvider.notifier)
          .navigate(const NoteTab('d-old'));
      await env.settle(tester);
      await _tap(tester, env, _row('pricing'));

      // Active: surface4 fill, title fg0, first line stays fg2.
      final active = _note('pricing', 'd-old');
      expect(hasFill(tester, active, OmColors.surface4), isTrue);
      expect(
        _color(tester, _inNote('pricing', 'd-old', find.text('2026-11-02'))),
        OmColors.fg0,
      );
      expect(
        _color(
          tester,
          _inNote(
            'pricing',
            'd-old',
            find.text('renewal tiers feel wrong #pricing'),
          ),
        ),
        OmColors.fg2,
      );
      // The others: no fill, title fg1.
      for (final id in ['d-today', 'p-1']) {
        expect(
          hasFill(tester, _note('pricing', id), OmColors.surface4),
          isFalse,
          reason: id,
        );
      }
      expect(
        _color(tester, _inNote('pricing', 'p-1', find.text('Pricing'))),
        OmColors.fg1,
      );
      // A tag row is never filled like an active note.
      expect(hasFill(tester, _row('pricing'), OmColors.surface4), isFalse);
    });

    testWidgets('a note that is not open anywhere has no active row', (
      tester,
    ) async {
      final env = await pumpTagsPane(tester, tags: TagsDouble());
      env.container.read(tabsProvider.notifier).navigate(const NoteTab('zzz'));
      await _tap(tester, env, _row('pricing'));

      for (final id in ['d-today', 'p-1', 'd-old']) {
        expect(
          hasFill(tester, _note('pricing', id), OmColors.surface4),
          isFalse,
          reason: id,
        );
      }
    });

    testWidgets(
      'the active row follows the active tab when another kind of tab is active',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());
        final tabs = env.container.read(tabsProvider.notifier);
        tabs.navigate(const NoteTab('p-1'));
        await _tap(tester, env, _row('pricing'));
        expect(
          hasFill(tester, _note('pricing', 'p-1'), OmColors.surface4),
          isTrue,
        );

        // A canvas tab is active now: no note row reads as active.
        tabs.navigate(const CanvasTab('c-1'));
        await env.settle(tester);
        expect(
          hasFill(tester, _note('pricing', 'p-1'), OmColors.surface4),
          isFalse,
        );

        tabs.navigate(const NoteTab('d-today'));
        await env.settle(tester);
        expect(
          hasFill(tester, _note('pricing', 'd-today'), OmColors.surface4),
          isTrue,
        );
        expect(
          hasFill(tester, _note('pricing', 'p-1'), OmColors.surface4),
          isFalse,
        );
      },
    );

    testWidgets(
      'clicking a note row records follow of its note once and the row becomes active',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());
        await _tap(tester, env, _row('pricing'));
        expect(env.tabs.followed, isEmpty);

        await _tap(tester, env, _note('pricing', 'p-1'));

        expect(env.tabs.followed, [const NoteTab('p-1')]);
        expect(env.tabs.navigated, [const NoteTab('p-1')]);
        expect(env.container.read(activeTabProvider), const NoteTab('p-1'));
        expect(
          hasFill(tester, _note('pricing', 'p-1'), OmColors.surface4),
          isTrue,
        );
        // The list stays as it was.
        expect(_isOpen('pricing'), isTrue);

        await _tap(tester, env, _note('pricing', 'd-old'));

        expect(env.tabs.followed, [
          const NoteTab('p-1'),
          const NoteTab('d-old'),
        ]);
        expect(
          hasFill(tester, _note('pricing', 'd-old'), OmColors.surface4),
          isTrue,
        );
        expect(
          hasFill(tester, _note('pricing', 'p-1'), OmColors.surface4),
          isFalse,
        );
      },
    );

    testWidgets(
      'clicking the title or the first line or the row edge of a note follows that note',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());
        await _tap(tester, env, _row('work'));

        await _tap(
          tester,
          env,
          _inNote('work', 'w-1', find.text('Call notes')),
        );
        await _tap(
          tester,
          env,
          _inNote(
            'work',
            'w-1',
            find.text('call with Sam about pricing #work'),
          ),
        );
        final rect = tester.getRect(_note('work', 'w-2'));
        await tester.tapAt(rect.centerRight - const Offset(2, 0));
        await env.settle(tester);

        expect(env.tabs.followed, [
          const NoteTab('w-1'),
          const NoteTab('w-1'),
          const NoteTab('w-2'),
        ]);
      },
    );

    testWidgets('a tag row click never follows a note', (tester) async {
      final env = await pumpTagsPane(tester, tags: TagsDouble());

      await _tap(tester, env, _row('work'));
      await _tap(tester, env, _row('work'));

      expect(env.tabs.followed, isEmpty);
      expect(env.tabs.navigated, isEmpty);
    });

    testWidgets('notes are read with the tag that was expanded', (
      tester,
    ) async {
      final tags = TagsDouble();
      final env = await pumpTagsPane(tester, tags: tags);
      expect(tags.notesCalls, isEmpty);

      await _tap(tester, env, _row('work'));
      expect(tags.notesCalls.toSet(), {'work'});
      await _tap(tester, env, _row('pricing'));
      expect(tags.notesCalls.toSet(), {'work', 'pricing'});
    });
  });

  group('the System group', () {
    testWidgets(
      'System is collapsed at the bottom with the number of system tags and expands to its tags with counts',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());

        expect(_system(), findsOneWidget);
        final lastTag = tester.getRect(_row('work'));
        final system = tester.getCenter(_system());
        expect(system.dy, greaterThan(lastTag.bottom));
        // 8 px gap above a 24 px row.
        expect(system.dy - lastTag.bottom, closeTo(8 + 12, 1.5));
        expect(_sameLine(tester, _system(), '2'), isTrue);
        expect(_row('inbox'), findsNothing);
        expect(_row('agent-authored'), findsNothing);
        expect(_color(tester, _system()), OmColors.fg2);

        await _tap(tester, env, _system());

        expect(_row('agent-authored'), findsOneWidget);
        expect(_row('inbox'), findsOneWidget);
        expect(
          _inRow('agent-authored', find.text('#agent-authored')),
          findsOneWidget,
        );
        expect(_inRow('agent-authored', find.text('87')), findsOneWidget);
        expect(_inRow('inbox', find.text('#inbox')), findsOneWidget);
        expect(_inRow('inbox', find.text('87')), findsOneWidget);
        // Alphabetical, below SYSTEM, indented 16 more than a top level tag.
        expect(
          tester.getTopLeft(_row('agent-authored')).dy,
          lessThan(tester.getTopLeft(_row('inbox')).dy),
        );
        expect(
          tester.getTopLeft(_row('agent-authored')).dy,
          greaterThan(tester.getCenter(_system()).dy),
        );
        expect(
          tester.getTopLeft(_inRow('inbox', find.text('#inbox'))).dx -
              tester.getTopLeft(_inRow('work', find.text('#work'))).dx,
          16,
        );
        // Still a fully clickable 24 px row.
        expect(tester.getSize(_row('inbox')).height, 24);
        expect(tester.getSize(_row('inbox')).width, 268 - 12);

        await _tap(tester, env, _system());
        expect(_row('inbox'), findsNothing);
        expect(_row('agent-authored'), findsNothing);
      },
    );

    testWidgets(
      'a system tag expands to its notes indented further and clicking one follows it',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());
        await _tap(tester, env, _system());
        expect(_note('inbox', 'i-1'), findsNothing);

        await _tap(tester, env, _row('inbox'));

        expect(_note('inbox', 'i-1'), findsOneWidget);
        expect(_isOpen('inbox'), isTrue);
        expect(tester.getSize(_note('inbox', 'i-1')).height, 22);
        expect(
          tester
                  .getTopLeft(_inNote('inbox', 'i-1', find.text('Inbox one')))
                  .dx -
              tester.getTopLeft(_note('inbox', 'i-1')).dx,
          42,
        );

        await _tap(tester, env, _note('inbox', 'i-1'));
        expect(env.tabs.followed, [const NoteTab('i-1')]);
        expect(
          hasFill(tester, _note('inbox', 'i-1'), OmColors.surface4),
          isTrue,
        );

        // One child open at a time.
        await _tap(tester, env, _row('agent-authored'));
        expect(_note('agent-authored', 'a-1'), findsOneWidget);
        expect(_note('inbox', 'i-1'), findsNothing);
      },
    );

    testWidgets(
      'the System group opens and closes independently of the expanded tag',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());
        await _tap(tester, env, _row('work'));
        expect(_isOpen('work'), isTrue);

        // Opening System leaves the expanded tag alone.
        await _tap(tester, env, _system());
        expect(_row('inbox'), findsOneWidget);
        expect(_note('work', 'w-1'), findsOneWidget);
        expect(_isOpen('work'), isTrue);

        // Expanding another tag leaves System open.
        await _tap(tester, env, _row('pricing'));
        expect(_row('inbox'), findsOneWidget);
        expect(_note('pricing', 'p-1'), findsOneWidget);
        expect(_note('work', 'w-1'), findsNothing);

        // Closing System leaves the expanded tag alone.
        await _tap(tester, env, _system());
        expect(_row('inbox'), findsNothing);
        expect(_note('pricing', 'p-1'), findsOneWidget);
      },
    );
  });

  group('states', () {
    testWidgets(
      'with no tags the empty state shows and there is no System row',
      (tester) async {
        await pumpTagsPane(tester, tags: TagsDouble(rows: const []));

        expect(find.byKey(const Key('tags-pane')), findsOneWidget);
        expect(find.byKey(const Key('tags-empty')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('tags-empty')),
            matching: find.text(_emptyCopy),
          ),
          findsOneWidget,
        );
        expect(_system(), findsNothing);
        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
        final text = tester.widget<Text>(find.text(_emptyCopy));
        expect(text.style?.color, OmColors.fg2);
        expect(text.style?.fontSize, 11);
      },
    );

    testWidgets(
      'with only system tags the empty state shows above a collapsed System',
      (tester) async {
        final env = await pumpTagsPane(
          tester,
          tags: TagsDouble(
            rows: [
              tagRow('agent-authored', 4, system: true),
              tagRow('inbox', 9, system: true),
            ],
          ),
        );

        expect(find.byKey(const Key('tags-empty')), findsOneWidget);
        expect(find.text(_emptyCopy), findsOneWidget);
        expect(_system(), findsOneWidget);
        expect(_sameLine(tester, _system(), '2'), isTrue);
        final empty = tester.getRect(find.byKey(const Key('tags-empty')));
        // Right below the copy, with no gap before the 24 px row.
        expect(tester.getCenter(_system()).dy - empty.bottom, closeTo(12, 1.5));
        expect(_row('inbox'), findsNothing);

        await _tap(tester, env, _system());
        expect(_inRow('inbox', find.text('9')), findsOneWidget);
        expect(_inRow('agent-authored', find.text('4')), findsOneWidget);
        expect(find.byKey(const Key('tags-empty')), findsOneWidget);
      },
    );

    testWidgets('the empty state is gone once a tag exists', (tester) async {
      final tags = TagsDouble(rows: const []);
      final env = await pumpTagsPane(tester, tags: tags);
      expect(find.byKey(const Key('tags-empty')), findsOneWidget);

      tags.rows = [tagRow('work', 1)];
      env.container.read(vaultRevisionProvider.notifier).state++;
      await env.settle(tester);

      expect(find.byKey(const Key('tags-empty')), findsNothing);
      expect(_row('work'), findsOneWidget);
    });

    testWidgets(
      'a hosted vault shows the loading state while its first read is pending',
      (tester) async {
        final tags = TagsDouble()..gateTags = true;
        final env = await pumpTagsPane(tester, tags: tags, hosted: true);

        expect(tags.tagGates, hasLength(1));
        expect(find.byKey(vaultAsyncLoadingKey), findsOneWidget);
        expect(find.text('loading…'), findsOneWidget);
        expect(find.byKey(const Key('tags-empty')), findsNothing);
        expect(_row('work'), findsNothing);

        tags.tagGates.single.complete();
        await env.settle(tester);

        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
        expect(_row('work'), findsOneWidget);
      },
    );

    testWidgets(
      'a local vault goes straight to the empty state while its first read is pending',
      (tester) async {
        final tags = TagsDouble()..gateTags = true;
        final env = await pumpTagsPane(tester, tags: tags);

        expect(tags.tagGates, hasLength(1));
        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
        expect(find.byKey(const Key('tags-empty')), findsOneWidget);

        tags.tagGates.single.complete();
        await env.settle(tester);
        expect(find.byKey(const Key('tags-empty')), findsNothing);
        expect(_row('work'), findsOneWidget);
      },
    );

    for (final (name, hosted) in [
      (
        'a failed first load shows the empty state with no spinner on a local vault',
        false,
      ),
      (
        'a failed first load shows the empty state with no spinner on a hosted vault',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final tags = TagsDouble()..failTags = StateError('boom');
        await pumpTagsPane(tester, tags: tags, hosted: hosted);

        expect(tags.allTagsCalls, 1);
        expect(find.byKey(const Key('tags-empty')), findsOneWidget);
        expect(find.text(_emptyCopy), findsOneWidget);
        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
        expect(_system(), findsNothing);
        expect(_row('work'), findsNothing);
      });
    }

    testWidgets('a reload keeps the old rows until the new read lands', (
      tester,
    ) async {
      final tags = TagsDouble();
      final env = await pumpTagsPane(tester, tags: tags);
      await _tap(tester, env, _row('work'));
      expect(_note('work', 'w-1'), findsOneWidget);

      tags.gateTags = true;
      env.container.read(vaultRevisionProvider.notifier).state++;
      await env.settle(tester);

      expect(tags.tagGates, hasLength(1), reason: 'the bump started a read');
      expect(find.byKey(const Key('tags-empty')), findsNothing);
      expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
      expect(_row('work'), findsOneWidget);
      expect(_row('health'), findsOneWidget);
      expect(_note('work', 'w-1'), findsOneWidget, reason: 'stays expanded');

      tags.rows = [tagRow('work', 8), tagRow('zebra', 1)];
      tags.tagGates.single.complete();
      await env.settle(tester);

      expect(_row('health'), findsNothing);
      expect(_row('zebra'), findsOneWidget);
      expect(_inRow('work', find.text('8')), findsOneWidget);
      expect(_note('work', 'w-1'), findsOneWidget);
    });

    testWidgets(
      'a vault write adding a tag updates the list and an expanded tag without reopening the mode',
      (tester) async {
        final db = FakeVaultDb.v6();
        addTearDown(db.close);
        db.seedNote(id: 'n1', title: 'First', updatedAt: 1000);
        db.seedTag('n1', 'work', origin: 'body', firstLine: 'a #work line');
        final env = await pumpTagsPane(tester, db: db);
        await _tap(tester, env, _row('work'));
        expect(_row('later'), findsNothing);
        expect(_inRow('work', find.text('1')), findsOneWidget);
        expect(_note('work', 'n2'), findsNothing);

        // A write by someone else: a new tag, and a second note under work.
        db.seedNote(id: 'n2', title: 'Second', updatedAt: 2000);
        db.seedTag('n2', 'work', origin: 'person');
        db.seedTag('n2', 'later', origin: 'body', firstLine: 'a #later line');
        env.container.read(vaultRevisionProvider.notifier).state++;
        await env.settle(tester);

        expect(_row('later'), findsOneWidget);
        expect(_inRow('later', find.text('1')), findsOneWidget);
        expect(_inRow('work', find.text('2')), findsOneWidget);
        expect(find.byKey(const Key('tags-pane')), findsOneWidget);
        expect(_note('work', 'n2'), findsOneWidget);
        expect(
          tester.getTopLeft(_note('work', 'n2')).dy,
          lessThan(tester.getTopLeft(_note('work', 'n1')).dy),
          reason: 'newest first',
        );
      },
    );

    testWidgets(
      'the pane reads alphabetical tags and newest first notes from the vault database',
      (tester) async {
        final db = FakeVaultDb.v6();
        addTearDown(db.close);
        db.seedNote(id: 'old', title: 'Old note', updatedAt: 1000);
        db.seedNote(id: 'mid', title: 'Footer only', updatedAt: 2000);
        db.seedNote(id: 'new', title: 'New note', updatedAt: 3000);
        db.seedTag('old', 'work', origin: 'body', firstLine: 'old #work line');
        db.seedTag('mid', 'work', origin: 'person');
        db.seedTag('new', 'work', origin: 'body', firstLine: 'new #work line');
        db.seedTag(
          'old',
          'health',
          origin: 'body',
          firstLine: 'a #health line',
        );
        db.seedTag('new', 'memex', origin: 'body', firstLine: 'a #memex line');
        db.seedTag('mid', 'inbox', origin: 'agent');
        final env = await pumpTagsPane(tester, db: db);

        final order = ['health', 'memex', 'work'];
        for (var i = 1; i < order.length; i++) {
          expect(
            tester.getTopLeft(_row(order[i])).dy,
            greaterThan(tester.getTopLeft(_row(order[i - 1])).dy),
          );
        }
        expect(_inRow('work', find.text('3')), findsOneWidget);
        expect(_inRow('health', find.text('1')), findsOneWidget);
        expect(_row('inbox'), findsNothing);
        expect(_sameLine(tester, _system(), '1'), isTrue);

        await _tap(tester, env, _row('work'));

        final ys = [
          for (final id in ['new', 'mid', 'old'])
            tester.getTopLeft(_note('work', id)).dy,
        ];
        expect(ys[0], lessThan(ys[1]));
        expect(ys[1], lessThan(ys[2]));
        expect(
          _inNote('work', 'new', find.text('new #work line')),
          findsOneWidget,
        );
        expect(
          _inNote('work', 'old', find.text('old #work line')),
          findsOneWidget,
        );
        expect(tester.getSize(_note('work', 'mid')).height, 22);
        expect(tester.getSize(_note('work', 'new')).height, 36);

        await _tap(tester, env, _system());
        await _tap(tester, env, _row('inbox'));
        expect(
          _inNote('inbox', 'mid', find.text('Footer only')),
          findsOneWidget,
        );
      },
    );
  });

  group('long content', () {
    for (final (name, scale) in [
      (
        'a long tag name and a long first line truncate at 268 px with no overflow at normal text scale',
        1.0,
      ),
      (
        'a long tag name and a long first line truncate at 268 px with no overflow at large text scale',
        2.0,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await pumpTagsPane(
          tester,
          textScale: scale,
          tags: TagsDouble(
            rows: [tagRow(_longTag, 128), tagRow('work', 7)],
            notes: {
              _longTag: [
                tagNote(
                  'long-1',
                  'Notes on the renewal conversation with the whole team',
                  firstLine:
                      'long call with Sam and Ana about the pricing and renewal tiers #$_longTag',
                ),
                tagNote(
                  'long-2',
                  'Title only but also a very long title indeed',
                ),
              ],
            },
          ),
        );
        await _tap(tester, env, _row(_longTag));

        // The text is all there (ellipsised on screen), the count is whole,
        // and nothing spills out of its row.
        final name = _inRow(_longTag, find.text('#$_longTag'));
        final count = _inRow(_longTag, find.text('128'));
        expect(name, findsOneWidget);
        expect(count, findsOneWidget);
        expect(tester.takeException(), isNull);
        final row = tester.getRect(_row(_longTag));
        expect(row.width, 268 - 12);
        expect(tester.getRect(count).right, lessThanOrEqualTo(row.right));
        expect(
          tester.getRect(name).right,
          lessThanOrEqualTo(tester.getRect(count).left),
        );
        expect(tester.getRect(name).left, greaterThanOrEqualTo(row.left));
        final nameText = tester.widget<Text>(name);
        expect(nameText.overflow, TextOverflow.ellipsis);
        expect(nameText.maxLines, 1);

        final note = _note(_longTag, 'long-1');
        final noteRect = tester.getRect(note);
        for (final text in [
          'Notes on the renewal conversation with the whole team',
          'long call with Sam and Ana about the pricing and renewal tiers #$_longTag',
          'Title only but also a very long title indeed',
        ]) {
          final f = find.text(text);
          expect(f, findsOneWidget, reason: text);
          final t = tester.widget<Text>(f);
          expect(t.overflow, TextOverflow.ellipsis, reason: text);
          expect(t.maxLines, 1, reason: text);
          expect(tester.getRect(f).right, lessThanOrEqualTo(noteRect.right));
        }
        expect(tester.getRect(note).width, 268 - 12);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the pane stays inside a short window and scrolls', (
      tester,
    ) async {
      final rows = [for (var i = 0; i < 30; i++) tagRow('t$i', i + 1)];
      final env = await pumpTagsPane(
        tester,
        tags: TagsDouble(rows: rows, notes: const {}),
        height: 200,
      );

      final host = tester.getRect(find.byKey(const Key('tags-host')));
      expect(find.byType(Scrollable), findsWidgets);
      expect(_row('t0'), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('tags-pane')),
        const Offset(0, -2000),
      );
      await env.settle(tester);
      expect(_row('t0'), findsNothing, reason: 'scrolled away');
      expect(_row('t29'), findsOneWidget);
      expect(
        tester.getRect(_row('t29')).bottom,
        lessThanOrEqualTo(host.bottom),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('revealTag', () {
    final many = [
      for (var i = 0; i < 60; i++)
        tagRow('t${i.toString().padLeft(2, '0')}', i + 1),
    ];
    final manyNotes = {
      't59': [tagNote('x-1', 'Far one'), tagNote('x-2', 'Far two')],
      't30': [tagNote('m-1', 'Middle one')],
    };

    testWidgets(
      'revealTag from another mode switches to Tags and expands the tag',
      (tester) async {
        final env = await pumpTagsSidebar(tester, tags: TagsDouble());
        expect(find.byKey(const Key('days-pane')), findsOneWidget);

        revealTag(env.ref, 'pricing');
        await env.settle(tester);

        expect(env.container.read(sidebarModeProvider), SidebarMode.tags);
        expect(find.byKey(const Key('tags-pane')), findsOneWidget);
        expect(find.byKey(const Key('days-pane')), findsNothing);
        expect(_isOpen('pricing'), isTrue);
        expect(_note('pricing', 'p-1'), findsOneWidget);
        expect(_note('pricing', 'd-old'), findsOneWidget);
        expect(_isOpen('work'), isFalse);
        expect(env.tabs.followed, isEmpty);
      },
    );

    testWidgets(
      'revealTag keeps one expanded tag and collapses the one that was open',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());
        await _tap(tester, env, _row('work'));
        expect(_note('work', 'w-1'), findsOneWidget);

        revealTag(env.ref, 'pricing');
        await env.settle(tester);

        expect(_isOpen('pricing'), isTrue);
        expect(_note('pricing', 'p-1'), findsOneWidget);
        expect(_isOpen('work'), isFalse);
        expect(_note('work', 'w-1'), findsNothing);
        expect(_note('work', 'w-2'), findsNothing);
      },
    );

    testWidgets(
      'revealTag of the tag that is already expanded leaves it expanded',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());
        await _tap(tester, env, _row('work'));

        revealTag(env.ref, 'work');
        await env.settle(tester);
        expect(_isOpen('work'), isTrue);
        expect(_note('work', 'w-1'), findsOneWidget);

        revealTag(env.ref, 'work');
        await env.settle(tester);
        expect(_isOpen('work'), isTrue);
        expect(_note('work', 'w-1'), findsOneWidget);
      },
    );

    testWidgets('revealTag of a system tag opens System and expands that tag', (
      tester,
    ) async {
      final env = await pumpTagsSidebar(tester, tags: TagsDouble());
      await env.settle(tester);
      expect(_system(), findsNothing);

      revealTag(env.ref, 'inbox');
      await env.settle(tester);

      expect(env.container.read(sidebarModeProvider), SidebarMode.tags);
      expect(_row('inbox'), findsOneWidget);
      expect(_row('agent-authored'), findsOneWidget);
      expect(_isOpen('inbox'), isTrue);
      expect(_note('inbox', 'i-1'), findsOneWidget);
      expect(_isOpen('agent-authored'), isFalse);
      expect(
        _inRow('work', find.byIcon(LucideIcons.chevronRight)),
        findsOneWidget,
      );
      expect(
        tester.getRect(_row('inbox')).top,
        greaterThan(tester.getCenter(_system()).dy),
      );
    });

    testWidgets(
      'revealTag of a system tag collapses the expanded tag and the other way round',
      (tester) async {
        final env = await pumpTagsPane(tester, tags: TagsDouble());
        await _tap(tester, env, _row('work'));

        revealTag(env.ref, 'agent-authored');
        await env.settle(tester);
        expect(_note('agent-authored', 'a-1'), findsOneWidget);
        expect(_note('work', 'w-1'), findsNothing);

        revealTag(env.ref, 'work');
        await env.settle(tester);
        expect(_note('work', 'w-1'), findsOneWidget);
        expect(_note('agent-authored', 'a-1'), findsNothing);
        // System stays open: it was opened by the reveal, not by the tag.
        expect(_row('agent-authored'), findsOneWidget);
      },
    );

    testWidgets('revealTag scrolls a tag far down the list into view', (
      tester,
    ) async {
      final env = await pumpTagsPane(
        tester,
        tags: TagsDouble(rows: many, notes: manyNotes),
        height: 300,
      );
      expect(_row('t59'), findsNothing, reason: 'below the fold');

      revealTag(env.ref, 't59');
      await env.settle(tester);

      expect(_row('t59'), findsOneWidget);
      expect(_inView(tester, _row('t59')), isTrue);
      expect(_isOpen('t59'), isTrue);
      expect(_row('t00'), findsNothing, reason: 'scrolled away from the top');
    });

    testWidgets(
      'revealTag from another mode scrolls the tag into view once the pane has built',
      (tester) async {
        final env = await pumpTagsSidebar(
          tester,
          tags: TagsDouble(rows: many, notes: manyNotes),
        );
        expect(find.byKey(const Key('tags-pane')), findsNothing);

        revealTag(env.ref, 't59');
        await env.settle(tester);

        expect(find.byKey(const Key('tags-pane')), findsOneWidget);
        expect(_row('t59'), findsOneWidget);
        expect(_inView(tester, _row('t59')), isTrue);
        expect(_note('t59', 'x-1'), findsOneWidget);
      },
    );

    testWidgets(
      'revealTag before the first read lands expands and shows the tag once the rows arrive',
      (tester) async {
        final tags = TagsDouble(rows: many, notes: manyNotes)..gateTags = true;
        final env = await pumpTagsPane(tester, tags: tags, height: 300);
        expect(tags.tagGates, hasLength(1));

        revealTag(env.ref, 't59');
        await env.settle(tester);
        expect(_row('t59'), findsNothing);

        tags.tagGates.single.complete();
        await env.settle(tester);

        expect(_row('t59'), findsOneWidget);
        expect(_isOpen('t59'), isTrue);
        expect(_inView(tester, _row('t59')), isTrue);
      },
    );

    testWidgets(
      'revealTag again after scrolling away and collapsing expands and scrolls to the tag again',
      (tester) async {
        final env = await pumpTagsPane(
          tester,
          tags: TagsDouble(rows: many, notes: manyNotes),
          height: 300,
        );
        revealTag(env.ref, 't59');
        await env.settle(tester);
        expect(_inView(tester, _row('t59')), isTrue);

        // The person collapses it and scrolls back to the top.
        await _tap(tester, env, _row('t59'));
        expect(_isOpen('t59'), isFalse);
        await tester.drag(
          find.byKey(const Key('tags-pane')),
          const Offset(0, 5000),
        );
        await env.settle(tester);
        expect(_row('t59'), findsNothing);

        revealTag(env.ref, 't59');
        await env.settle(tester);

        expect(_row('t59'), findsOneWidget);
        expect(_isOpen('t59'), isTrue);
        expect(_inView(tester, _row('t59')), isTrue);
      },
    );

    testWidgets(
      'revealTag of a tag in the middle of the list brings it into view',
      (tester) async {
        final env = await pumpTagsPane(
          tester,
          tags: TagsDouble(rows: many, notes: manyNotes),
          height: 300,
        );

        revealTag(env.ref, 't30');
        await env.settle(tester);

        expect(_row('t30'), findsOneWidget);
        expect(_inView(tester, _row('t30')), isTrue);
        expect(_note('t30', 'm-1'), findsOneWidget);
      },
    );

    testWidgets(
      'revealTag of a tag with no row switches the mode and throws nothing',
      (tester) async {
        final env = await pumpTagsSidebar(tester, tags: TagsDouble());

        revealTag(env.ref, 'ghost');
        await env.settle(tester);

        expect(tester.takeException(), isNull);
        expect(env.container.read(sidebarModeProvider), SidebarMode.tags);
        expect(find.byKey(const Key('tags-pane')), findsOneWidget);
        expect(_row('ghost'), findsNothing);
        expect(_row('work'), findsOneWidget);
        expect(find.byKey(const Key('tags-empty')), findsNothing);
      },
    );
  });
}
