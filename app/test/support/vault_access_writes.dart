// WI #70 (W0a): one case per VaultAccess write pairing it with today's
// MemexCli wrapper call, and canned C2 stdout for every subcommand they run.
import 'package:open_memex_app/src/cli/excerpt_cli.dart';
import 'package:open_memex_app/src/cli/folder_cli.dart';
import 'package:open_memex_app/src/cli/footer_cli.dart';
import 'package:open_memex_app/src/cli/note_cli.dart';
import 'package:open_memex_app/src/cli/prompt_cli.dart';
import 'package:open_memex_app/src/cli/settings_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

import 'fake_memex_cli.dart';

const _vid = '01HV0000000000000000000070';

/// Canned successful stdout per subcommand (C2 shapes).
const vaultAccessCliSamples = <String, String>{
  'add': 'Created note "Title"\nnote_id: 01J9Z8Y7X6W5V4T3S2R1Q0AB70\n',
  'update': '{"note_id":"n-70","version":8,"updated_at":1759600000070}',
  'rm': '{"vault_id":"$_vid","note_id":"n-70","deleted":true}',
  'add-link':
      '{"link_id":"l-70","from":"a-70","to":"b-70","kind":"extends",'
      '"source":"inline_body","was_existing":false,"note_version":5}',
  'update-link':
      '{"link_id":"l-70","from_note_id":"a-70","to_note_id":"b-70",'
      '"kind":"contradicts","label":"why","source":"inline_body","position":2}',
  'footer add':
      '{"vault_id":"$_vid","daily_note_id":"d-70","topic_note_id":"t-70",'
      '"origin":"person","version":4}',
  'excerpt rm': '{"vault_id":"$_vid","topic_note_id":"t-70","version":6}',
  'folder new':
      '{"vault_id":"$_vid","id":"f-70","name":"Games","parent_id":"p-70",'
      '"pinned":false,"depth":2,"created_at":1759600000001,'
      '"updated_at":1759600000002}',
  'folder update':
      '{"vault_id":"$_vid","id":"f-70","name":"Renamed","parent_id":null,'
      '"pinned":true,"depth":1,"created_at":1759600000001,'
      '"updated_at":1759600000003}',
  'folder rm': '{"vault_id":"$_vid","id":"f-70","deleted":true}',
  'folder add':
      '{"vault_id":"$_vid","smart_folder_id":"f-70","note_id":"n-70",'
      '"pinned":false,"role_set":true}',
  'settings get':
      '{"vault_id":"$_vid","key":"smart_folder_max_depth","value":3}',
  'settings set':
      '{"vault_id":"$_vid","key":"smart_folder_max_depth","value":4}',
  'prompt review': 'Review the day.\n\nLine two, verbatim.  \n',
  'canvas new':
      '{"canvas_id":"c-70","title":"Board","version":1,'
      '"created_at":1759600000004,"updated_at":1759600000005}',
  'canvas add':
      '{"canvas_id":"c-70","note_id":"n-70","note_title":"Alpha","x":12.5,'
      '"y":-3.0,"z_order":2,"placed_at":1759600000006}',
  'canvas move':
      '{"canvas_id":"c-70","note_id":"n-70","note_title":"Alpha","x":40.0,'
      '"y":50.5,"z_order":7,"placed_at":1759600000006}',
};

/// A [FakeMemexCli] answering every subcommand in [vaultAccessCliSamples].
FakeMemexCli vaultAccessSampleCli() {
  final cli = FakeMemexCli();
  for (final e in vaultAccessCliSamples.entries) {
    cli.on(e.key, (_) => FakeMemexCli.ok(e.value));
  }
  return cli;
}

/// One VaultAccess write and the MemexCli wrapper call it replaces. [viaCli]
/// passes [vaultPath] where today's wrapper takes one.
class VaultAccessWriteCase {
  const VaultAccessWriteCase(
    this.name,
    this.subcommand,
    this.viaAccess,
    this.viaCli,
  );

  final String name;

  /// The FakeMemexCli subcommand path the call runs (e.g. `folder new`).
  final String subcommand;
  final Future<Object?> Function(VaultAccess a) viaAccess;
  final Future<Object?> Function(MemexCli cli, String vaultPath) viaCli;
}

/// Every write of the notes, daily, topics and canvas domains, with each
/// optional flag both set and unset somewhere.
final vaultAccessWriteCases = <VaultAccessWriteCase>[
  // ---------- notes ----------
  VaultAccessWriteCase(
    'notes.addNote with title tags and role',
    'add',
    (a) => a.notes.addNote(
      title: 'Player Loop',
      tags: const ['games', 'design'],
      contentMd: 'body\n',
      role: 'topic',
    ),
    (cli, v) => cli.addNote(
      vaultPath: v,
      title: 'Player Loop',
      tags: const ['games', 'design'],
      contentMd: 'body\n',
      role: 'topic',
    ),
  ),
  VaultAccessWriteCase(
    'notes.addNote with content only',
    'add',
    (a) => a.notes.addNote(contentMd: 'just text'),
    (cli, v) => cli.addNote(vaultPath: v, contentMd: 'just text'),
  ),
  VaultAccessWriteCase(
    'notes.addNote with an empty title and role daily',
    'add',
    (a) => a.notes.addNote(title: '', contentMd: '', role: 'daily'),
    (cli, v) =>
        cli.addNote(vaultPath: v, title: '', contentMd: '', role: 'daily'),
  ),
  VaultAccessWriteCase(
    'notes.updateNote with title and no rename links',
    'update',
    (a) => a.notes.updateNote(
      noteId: 'n-70',
      expectedVersion: 7,
      title: 'Renamed',
      contentMd: 'new body',
      noRenameLinks: true,
    ),
    (cli, v) => cli.updateNote(
      vaultPath: v,
      noteId: 'n-70',
      expectedVersion: 7,
      title: 'Renamed',
      contentMd: 'new body',
      noRenameLinks: true,
    ),
  ),
  VaultAccessWriteCase(
    'notes.updateNote with body only',
    'update',
    (a) =>
        a.notes.updateNote(noteId: 'n-70', expectedVersion: 1, contentMd: ''),
    (cli, v) => cli.updateNote(
      vaultPath: v,
      noteId: 'n-70',
      expectedVersion: 1,
      contentMd: '',
    ),
  ),
  VaultAccessWriteCase(
    'notes.deleteNote',
    'rm',
    (a) => a.notes.deleteNote(noteId: 'n-70', expectedVersion: 3),
    (cli, v) =>
        cli.deleteNote(vaultPath: v, noteId: 'n-70', expectedVersion: 3),
  ),
  VaultAccessWriteCase(
    'notes.addLink with kind and label',
    'add-link',
    (a) => a.notes.addLink(
      fromNoteId: 'a-70',
      toNoteId: 'b-70',
      kind: 'extends',
      label: 'builds on',
    ),
    (cli, v) => cli.addLink(
      vaultPath: v,
      fromNoteId: 'a-70',
      toNoteId: 'b-70',
      kind: 'extends',
      label: 'builds on',
    ),
  ),
  VaultAccessWriteCase(
    'notes.addLink with defaults',
    'add-link',
    (a) => a.notes.addLink(fromNoteId: 'a-70', toNoteId: 'b-70'),
    (cli, v) => cli.addLink(vaultPath: v, fromNoteId: 'a-70', toNoteId: 'b-70'),
  ),
  VaultAccessWriteCase(
    'notes.updateLink with kind and label',
    'update-link',
    (a) =>
        a.notes.updateLink(linkId: 'l-70', kind: 'contradicts', label: 'why'),
    (cli, v) => cli.updateLink(
      vaultPath: v,
      linkId: 'l-70',
      kind: 'contradicts',
      label: 'why',
    ),
  ),
  VaultAccessWriteCase(
    'notes.updateLink clearing the label',
    'update-link',
    (a) =>
        a.notes.updateLink(linkId: 'l-70', label: 'ignored', clearLabel: true),
    (cli, v) => cli.updateLink(
      vaultPath: v,
      linkId: 'l-70',
      label: 'ignored',
      clearLabel: true,
    ),
  ),
  // ---------- daily ----------
  VaultAccessWriteCase(
    'daily.addFooterChip',
    'footer add',
    (a) => a.daily.addFooterChip(dailyNoteId: 'd-70', topicNoteId: 't-70'),
    (cli, v) => cli.addFooterChip(
      vaultPath: v,
      dailyNoteId: 'd-70',
      topicNoteId: 't-70',
    ),
  ),
  VaultAccessWriteCase(
    'daily.removeExcerpt with a block range',
    'excerpt rm',
    (a) => a.daily.removeExcerpt(
      topicNoteId: 't-70',
      date: '2026-09-05',
      fromBlockId: 'b1',
      toBlockId: 'b3',
    ),
    (cli, v) => cli.removeExcerpt(
      vaultPath: v,
      topicNoteId: 't-70',
      date: '2026-09-05',
      fromBlockId: 'b1',
      toBlockId: 'b3',
    ),
  ),
  VaultAccessWriteCase(
    'daily.removeExcerpt with one block',
    'excerpt rm',
    (a) => a.daily.removeExcerpt(
      topicNoteId: 't-70',
      date: '2026-09-05',
      fromBlockId: 'b1',
    ),
    (cli, v) => cli.removeExcerpt(
      vaultPath: v,
      topicNoteId: 't-70',
      date: '2026-09-05',
      fromBlockId: 'b1',
    ),
  ),
  // ---------- topics ----------
  VaultAccessWriteCase(
    'topics.createFolder with a parent',
    'folder new',
    (a) => a.topics.createFolder(name: 'Games', parentId: 'p-70'),
    (cli, v) => cli.createFolder(vaultPath: v, name: 'Games', parentId: 'p-70'),
  ),
  VaultAccessWriteCase(
    'topics.createFolder at the root',
    'folder new',
    (a) => a.topics.createFolder(name: 'Games'),
    (cli, v) => cli.createFolder(vaultPath: v, name: 'Games'),
  ),
  VaultAccessWriteCase(
    'topics.updateFolder rename and pin',
    'folder update',
    (a) => a.topics.updateFolder(id: 'f-70', name: 'Renamed', pinned: true),
    (cli, v) => cli.updateFolder(
      vaultPath: v,
      id: 'f-70',
      name: 'Renamed',
      pinned: true,
    ),
  ),
  VaultAccessWriteCase(
    'topics.updateFolder to root wins over parent',
    'folder update',
    (a) => a.topics.updateFolder(
      id: 'f-70',
      parentId: 'p-70',
      toRoot: true,
      pinned: false,
    ),
    (cli, v) => cli.updateFolder(
      vaultPath: v,
      id: 'f-70',
      parentId: 'p-70',
      toRoot: true,
      pinned: false,
    ),
  ),
  VaultAccessWriteCase(
    'topics.updateFolder reparent',
    'folder update',
    (a) => a.topics.updateFolder(id: 'f-70', parentId: 'p-70'),
    (cli, v) => cli.updateFolder(vaultPath: v, id: 'f-70', parentId: 'p-70'),
  ),
  VaultAccessWriteCase(
    'topics.deleteFolder',
    'folder rm',
    (a) => a.topics.deleteFolder(id: 'f-70'),
    (cli, v) => cli.deleteFolder(vaultPath: v, id: 'f-70'),
  ),
  VaultAccessWriteCase(
    'topics.addToFolder unpinned',
    'folder add',
    (a) =>
        a.topics.addToFolder(folderId: 'f-70', noteId: 'n-70', pinned: false),
    (cli, v) => cli.addToFolder(
      vaultPath: v,
      folderId: 'f-70',
      noteId: 'n-70',
      pinned: false,
    ),
  ),
  VaultAccessWriteCase(
    'topics.addToFolder with the CLI default pin',
    'folder add',
    (a) => a.topics.addToFolder(folderId: 'f-70', noteId: 'n-70'),
    (cli, v) => cli.addToFolder(vaultPath: v, folderId: 'f-70', noteId: 'n-70'),
  ),
  VaultAccessWriteCase(
    'topics.getSetting',
    'settings get',
    (a) => a.topics.getSetting(smartFolderMaxDepthKey),
    (cli, v) => cli.getSetting(v, smartFolderMaxDepthKey),
  ),
  VaultAccessWriteCase(
    'topics.setSetting',
    'settings set',
    (a) => a.topics.setSetting(smartFolderMaxDepthKey, 4),
    (cli, v) => cli.setSetting(v, smartFolderMaxDepthKey, 4),
  ),
  VaultAccessWriteCase(
    'topics.reviewPrompt',
    'prompt review',
    (a) => a.topics.reviewPrompt(),
    (cli, v) => cli.reviewPrompt(),
  ),
  // ---------- canvas ----------
  VaultAccessWriteCase(
    'canvas.createCanvas',
    'canvas new',
    (a) => a.canvas.createCanvas(title: 'Board'),
    (cli, v) => cli.createCanvas(vaultPath: v, title: 'Board'),
  ),
  VaultAccessWriteCase(
    'canvas.addToCanvas at a point',
    'canvas add',
    (a) =>
        a.canvas.addToCanvas(canvasId: 'c-70', noteId: 'n-70', x: 12.5, y: -3),
    (cli, v) => cli.addToCanvas(
      vaultPath: v,
      canvasId: 'c-70',
      noteId: 'n-70',
      x: 12.5,
      y: -3,
    ),
  ),
  VaultAccessWriteCase(
    'canvas.addToCanvas at the origin',
    'canvas add',
    (a) => a.canvas.addToCanvas(canvasId: 'c-70', noteId: 'n-70'),
    (cli, v) => cli.addToCanvas(vaultPath: v, canvasId: 'c-70', noteId: 'n-70'),
  ),
  VaultAccessWriteCase(
    'canvas.moveNode with z order',
    'canvas move',
    (a) => a.canvas.moveNode(
      canvasId: 'c-70',
      noteId: 'n-70',
      x: 40,
      y: 50.5,
      zOrder: 7,
    ),
    (cli, v) => cli.moveNode(
      vaultPath: v,
      canvasId: 'c-70',
      noteId: 'n-70',
      x: 40,
      y: 50.5,
      zOrder: 7,
    ),
  ),
  VaultAccessWriteCase(
    'canvas.moveNode without z order',
    'canvas move',
    (a) => a.canvas.moveNode(canvasId: 'c-70', noteId: 'n-70', x: 1, y: 2),
    (cli, v) => cli.moveNode(
      vaultPath: v,
      canvasId: 'c-70',
      noteId: 'n-70',
      x: 1,
      y: 2,
    ),
  ),
];
