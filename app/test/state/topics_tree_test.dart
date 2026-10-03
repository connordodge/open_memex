// WI #24 (A7): the pure Topics tree builder (Req 2, 35, 39, 52, 53; Spec TS3).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/topics_reads.dart';
import 'package:open_memex_app/src/state/topics_tree.dart';

SmartFolderRow _folder(
  String id,
  String name, {
  String? parent,
  bool pinned = false,
}) => SmartFolderRow(id: id, name: name, parentId: parent, pinned: pinned);

SmartFolderMemberRow _member(
  String folder,
  String note,
  String title, {
  bool pinned = false,
}) => SmartFolderMemberRow(
  folderId: folder,
  noteId: note,
  title: title,
  pinned: pinned,
);

UnsortedNoteRow _loose(String id, String title, {String? role}) =>
    UnsortedNoteRow(noteId: id, title: title, role: role);

List<String> _names(List<FolderNode> nodes) => [for (final n in nodes) n.name];
List<String> _titles(List<TopicNode> nodes) => [for (final n in nodes) n.title];
List<String> _unsortedTitles(TopicsTree t) => [
  for (final n in t.unsorted.notes) n.title,
];

void main() {
  group('folder nesting and ordering (AC2)', () {
    test(
      'nests folders under their parent with depth from the parent chain',
      () {
        // Children listed before their parents: the builder must not rely on
        // input order.
        final tree = buildTopicsTree(
          SmartFolderData(
            folders: [
              _folder('c', 'Grandchild', parent: 'b'),
              _folder('b', 'Child', parent: 'a'),
              _folder('a', 'Root'),
              _folder('d', 'Great', parent: 'c'),
            ],
            members: const [],
          ),
          const [],
        );

        expect(tree.folders.map((f) => f.id), ['a']);
        final a = tree.folders.single;
        expect(a.depth, 0);
        expect(a.children.map((f) => f.id), ['b']);
        final b = a.children.single;
        expect(b.depth, 1);
        expect(b.children.map((f) => f.id), ['c']);
        final c = b.children.single;
        expect(c.depth, 2);
        expect(c.children.map((f) => f.id), ['d']);
        expect(c.children.single.depth, 3);
        expect(c.children.single.children, isEmpty);
      },
    );

    test('a folder carries its pinned flag and its name', () {
      final tree = buildTopicsTree(
        SmartFolderData(
          folders: [
            _folder('p', 'Pinned', pinned: true),
            _folder('u', 'Unpinned'),
          ],
          members: const [],
        ),
        const [],
      );

      final byId = {for (final f in tree.folders) f.id: f};
      expect(byId['p']!.pinned, isTrue);
      expect(byId['u']!.pinned, isFalse);
      expect(byId['p']!.name, 'Pinned');
      expect(byId['p']!.children, isEmpty);
      expect(byId['p']!.topics, isEmpty);
    });

    test('sorts root folders and subfolders by name ignoring case', () {
      final tree = buildTopicsTree(
        SmartFolderData(
          folders: [
            _folder('r3', 'charlie'),
            _folder('r1', 'Alpha'),
            _folder('r2', 'bravo'),
            _folder('k3', 'zulu', parent: 'r1'),
            _folder('k1', 'Echo', parent: 'r1'),
            _folder('k2', 'foxtrot', parent: 'r1'),
          ],
          members: const [],
        ),
        const [],
      );

      expect(_names(tree.folders), ['Alpha', 'bravo', 'charlie']);
      expect(_names(tree.folders.first.children), ['Echo', 'foxtrot', 'zulu']);
    });

    test('sorts the topics of a folder by title ignoring case', () {
      final tree = buildTopicsTree(
        SmartFolderData(
          folders: [_folder('f', 'Folder')],
          members: [
            _member('f', 'n3', 'zeta'),
            _member('f', 'n1', 'Alpha'),
            _member('f', 'n4', 'Yankee'),
            _member('f', 'n2', 'beta'),
          ],
        ),
        const [],
      );

      expect(_titles(tree.folders.single.topics), [
        'Alpha',
        'beta',
        'Yankee',
        'zeta',
      ]);
    });

    test(
      'lists a topic under every folder it belongs to including a parent with subfolders',
      () {
        final tree = buildTopicsTree(
          SmartFolderData(
            folders: [
              _folder('parent', 'Parent'),
              _folder('kid', 'Kid', parent: 'parent'),
              _folder('other', 'Other'),
            ],
            members: [
              _member('parent', 'n1', 'Shared'),
              _member('kid', 'n1', 'Shared'),
              _member('other', 'n1', 'Shared'),
              _member('parent', 'n2', 'Only parent'),
              _member('kid', 'n3', 'Only kid'),
            ],
          ),
          const [],
        );

        final byId = {for (final f in tree.folders) f.id: f};
        final parent = byId['parent']!;
        final kid = parent.children.single;
        expect(_titles(parent.topics), ['Only parent', 'Shared']);
        expect(_titles(kid.topics), ['Only kid', 'Shared']);
        expect(_titles(byId['other']!.topics), ['Shared']);
        expect(parent.topics.map((t) => t.noteId), ['n2', 'n1']);
      },
    );

    test(
      'orders sibling folders and topics whose names are equal ignoring case by id',
      () {
        final tree = buildTopicsTree(
          SmartFolderData(
            folders: [
              _folder('f-3', 'notes'),
              _folder('f-1', 'Notes'),
              _folder('f-2', 'NOTES'),
              _folder('k-2', 'Kid', parent: 'f-1'),
              _folder('k-1', 'kid', parent: 'f-1'),
            ],
            members: [
              _member('f-1', 'n-3', 'topic'),
              _member('f-1', 'n-1', 'Topic'),
              _member('f-1', 'n-2', 'TOPIC'),
            ],
          ),
          const [],
        );

        expect(tree.folders.map((f) => f.id), ['f-1', 'f-2', 'f-3']);
        expect(tree.folders.first.children.map((f) => f.id), ['k-1', 'k-2']);
        expect(tree.folders.first.topics.map((t) => t.noteId), [
          'n-1',
          'n-2',
          'n-3',
        ]);
      },
    );

    test('a topic row carries its membership pinned flag per folder', () {
      final tree = buildTopicsTree(
        SmartFolderData(
          folders: [_folder('a', 'A'), _folder('b', 'B')],
          members: [
            _member('a', 'n1', 'Loop', pinned: true),
            _member('b', 'n1', 'Loop'),
            _member('a', 'n2', 'Plain'),
          ],
        ),
        const [],
      );

      final byId = {for (final f in tree.folders) f.id: f};
      final inA = {for (final t in byId['a']!.topics) t.noteId: t};
      expect(inA['n1']!.pinned, isTrue);
      expect(inA['n2']!.pinned, isFalse);
      expect(byId['b']!.topics.single.pinned, isFalse);
    });

    test('a folder with no members and no subfolders has empty lists', () {
      final tree = buildTopicsTree(
        SmartFolderData(folders: [_folder('e', 'Empty')], members: const []),
        const [],
      );

      expect(tree.folders.single.topics, isEmpty);
      expect(tree.folders.single.children, isEmpty);
    });
  });

  group('the Unsorted node (AC3)', () {
    test(
      'holds every non-daily note with no membership and sorts by title ignoring case',
      () {
        final tree =
            buildTopicsTree(const SmartFolderData(folders: [], members: []), [
              _loose('n2', 'zebra'),
              _loose('n1', 'Apple', role: 'topic'),
              _loose('n3', 'mango'),
            ]);

        expect(_unsortedTitles(tree), ['Apple', 'mango', 'zebra']);
        final byId = {for (final n in tree.unsorted.notes) n.noteId: n};
        expect(byId['n1']!.role, 'topic');
        expect(byId['n2']!.role, isNull);
      },
    );

    test('never lists daily notes', () {
      final tree =
          buildTopicsTree(const SmartFolderData(folders: [], members: []), [
            _loose('d1', '2026-10-02', role: 'daily'),
            _loose('n1', 'Plain'),
            _loose('d2', '2026-10-03', role: 'daily'),
          ]);

      expect(tree.unsorted.notes.map((n) => n.noteId), ['n1']);
    });

    test(
      'orders unsorted notes whose titles are equal ignoring case by id',
      () {
        final tree = buildTopicsTree(
          const SmartFolderData(folders: [], members: []),
          [_loose('u-2', 'same'), _loose('u-3', 'SAME'), _loose('u-1', 'Same')],
        );

        expect(tree.unsorted.notes.map((n) => n.noteId), ['u-1', 'u-2', 'u-3']);
      },
    );

    test('is present and empty when every note is in a folder', () {
      final tree = buildTopicsTree(
        SmartFolderData(
          folders: [_folder('f', 'F')],
          members: [_member('f', 'n1', 'In folder')],
        ),
        const [],
      );

      expect(tree.unsorted.notes, isEmpty);
    });

    test('keeps folder notes and unsorted notes apart', () {
      final tree = buildTopicsTree(
        SmartFolderData(
          folders: [_folder('f', 'F')],
          members: [_member('f', 'n1', 'In folder')],
        ),
        [_loose('n2', 'Free')],
      );

      expect(_titles(tree.folders.single.topics), ['In folder']);
      expect(_unsortedTitles(tree), ['Free']);
    });
  });

  group('the empty state flag (Req 53)', () {
    test('an empty vault is empty', () {
      final tree = buildTopicsTree(
        const SmartFolderData(folders: [], members: []),
        const [],
      );

      expect(tree.isEmpty, isTrue);
      expect(tree.folders, isEmpty);
    });

    test(
      'role-less notes alone leave the tree empty so the message shows above Unsorted',
      () {
        final tree = buildTopicsTree(
          const SmartFolderData(folders: [], members: []),
          [_loose('n1', 'Plain'), _loose('n2', 'Other')],
        );

        expect(tree.isEmpty, isTrue);
        expect(_unsortedTitles(tree), ['Other', 'Plain']);
      },
    );

    test('an unsorted topic note makes the tree non-empty', () {
      final tree = buildTopicsTree(
        const SmartFolderData(folders: [], members: []),
        [_loose('n1', 'A topic', role: 'topic')],
      );

      expect(tree.isEmpty, isFalse);
    });

    test('a Smart Folder with no notes makes the tree non-empty', () {
      final tree = buildTopicsTree(
        SmartFolderData(folders: [_folder('f', 'F')], members: const []),
        const [],
      );

      expect(tree.isEmpty, isFalse);
    });
  });
}
