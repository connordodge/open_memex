// WI #141 (Spec #123 V1, TD "App access"): `VaultAccess.attachments` on local
// and hosted vaults; `attachmentsProvider` derives from `vaultAccessProvider`;
// `FakeAttachmentsAccess` records calls and answers from queues, and a widget
// test overrides the provider with it. WI #140 (W3) replaced the V1 stub that
// the first two tests pinned: they now pin that each composite wires its
// domain to its own vault (local: the vault folder and its `memex`; hosted:
// its client and vault name).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/attachments.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

import '../support/attachments_fakes.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_server.dart';

const _vaultA = LocalVaultRef('/vaults/My Vault');
const _vaultB = LocalVaultRef('/vaults/Other Vault');
const _hash =
    '66bc7611813b7443f25c4af21004864b3975eb83fb7c74be572b9d6aa74bd462';
const _path = 'objects/66/$_hash/Q3 report.pdf';

/// [value] as a [T], failing the test by assertion when it is not one.
T _as<T extends Object>(Object? value) {
  expect(value, isA<T>());
  return value! as T;
}

/// A container whose open vault is [_vaultA] or [_vaultB], each with its own
/// attachments double.
ProviderContainer _switching(Map<VaultRef, FakeAttachmentsAccess> fakes) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => _vaultA),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(null),
      vaultAccessProvider.overrideWith((ref) {
        final vault = ref.watch(currentVaultProvider);
        final path = vault.localPath;
        if (path == null) return null;
        return LocalVaultAccess(vaultPath: path, attachments: fakes[vault]);
      }),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// A button that opens [_path] through `attachmentsProvider` and shows the
/// outcome.
class _OpenProbe extends ConsumerStatefulWidget {
  const _OpenProbe();

  @override
  ConsumerState<_OpenProbe> createState() => _OpenProbeState();
}

class _OpenProbeState extends ConsumerState<_OpenProbe> {
  String _shown = 'idle';

  Future<void> _open() async {
    final access = ref.read(attachmentsProvider);
    if (access == null) {
      setState(() => _shown = 'no vault');
      return;
    }
    final result = await access.open(_path);
    setState(
      () => _shown = switch (result) {
        AttachmentActionDone() => 'done',
        AttachmentActionFailed(:final failure) => failure.name,
      },
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Column(
      children: [
        TextButton(onPressed: _open, child: const Text('open')),
        Text(_shown),
      ],
    ),
  );
}

void main() {
  group('local vault attachments', () {
    test(
      'a local vault wires its attachments domain to the vault folder and its memex',
      () async {
        final dir = Directory.systemTemp.createTempSync('om-141-vault');
        addTearDown(() => dir.deleteSync(recursive: true));
        final source = File('${dir.path}/source.txt')..writeAsStringSync('hi');
        final vault = Directory('${dir.path}/vault')..createSync();
        final stored = File('${vault.path}/$_path')
          ..createSync(recursive: true)
          ..writeAsBytesSync([4, 5, 6]);
        final cli = FakeMemexCli()
          ..on('attach', (_) {
            final a = fakeAddedAttachment('Q3 report.pdf', size: 2);
            return FakeMemexCli.ok(
              '${jsonEncode({'markdown': a.markdown, 'path': a.path, 'name': a.name, 'size': a.size, 'type': a.type})}\n',
            );
          });

        final VaultAccess access = LocalVaultAccess(
          vaultPath: vault.path,
          cli: cli,
        );
        expect(access.attachments, isA<LocalAttachmentsAccess>());
        final attachments = access.attachments as LocalAttachmentsAccess;
        expect(attachments.vaultPath, vault.path);

        final read = await attachments.read(_path);
        expect(_as<AttachmentBytes>(read).bytes, [4, 5, 6]);
        final added = await attachments.add(source.path, 'Q3 report.pdf');
        expect(added, isA<AttachmentAdded>());
        final call = cli.callsFor('attach').single;
        expect(call.args, contains(vault.path), reason: 'its vault');
        expect(call.args.last, source.path);
        expect(stored.readAsBytesSync(), [4, 5, 6]);
        expect(source.readAsStringSync(), 'hi');
      },
    );

    test(
      'a local vault without a memex cannot add and makes nothing in the vault',
      () async {
        final dir = Directory.systemTemp.createTempSync('om-141-vault');
        addTearDown(() => dir.deleteSync(recursive: true));
        final source = File('${dir.path}/source.txt')..writeAsStringSync('hi');
        final vault = Directory('${dir.path}/vault')..createSync();

        final VaultAccess access = LocalVaultAccess(vaultPath: vault.path);
        final attachments = access.attachments;

        final added = await attachments.add(source.path, 'Q3 report.pdf');
        final addedBytes = await attachments.addBytes(
          Uint8List.fromList([1, 2]),
          'a.png',
        );
        for (final r in [added, addedBytes]) {
          expect(r, isA<AttachmentAddFailed>());
          expect(
            _as<AttachmentAddFailed>(r).reason,
            AttachmentAddFailureReason.unsupported,
          );
        }
        final read = await attachments.read(_path);
        expect(
          _as<AttachmentReadFailed>(read).failure,
          AttachmentLookupFailure.missing,
        );
        final info = await attachments.info(_path);
        expect(
          _as<AttachmentInfoFailed>(info).failure,
          AttachmentLookupFailure.missing,
        );
        expect(vault.listSync(), isEmpty, reason: 'no objects folder made');
        expect(source.readAsStringSync(), 'hi');
      },
    );

    test('LocalVaultAccess hands out the attachments double it is given', () {
      final fake = FakeAttachmentsAccess();
      final VaultAccess access = LocalVaultAccess(
        vaultPath: _vaultA.path,
        attachments: fake,
      );
      expect(identical(access.attachments, fake), isTrue);
    });
  });

  group('hosted vault attachments', () {
    test(
      'a hosted vault wires its attachments domain to its client and vault name',
      () async {
        final container = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(FakeClock()),
            utcOffsetProvider.overrideWithValue(() => Duration.zero),
          ],
        );
        addTearDown(container.dispose);
        final server = FakeVaultServer()..putAttachment('seed', _path, [7, 8]);
        final hosted = HostedVaultAccess(
          client: server.connect(container),
          vaultName: 'seed',
        );
        addTearDown(hosted.dispose);
        final VaultAccess access = hosted;

        expect(access.attachments, isA<HostedAttachmentsAccess>());
        expect(hosted.attachments.vaultName, 'seed');
        final read = await access.attachments.read(_path);
        expect(_as<AttachmentBytes>(read).bytes, [7, 8]);
        final info = await access.attachments.info(_path);
        expect(_as<AttachmentInfoFound>(info).info.size, 2);
        final added = await access.attachments.addBytes(
          Uint8List.fromList([1, 2, 3]),
          'a.png',
        );
        expect(added, isA<AttachmentAdded>());

        expect(server.requests.map((r) => r.method), [
          'GET',
          'POST',
        ], reason: 'the read answers the info; the add posts');
        for (final r in server.requests) {
          expect(r.url.path, startsWith('/vaults/seed/api/v1/attachments'));
        }
      },
    );

    test(
      'two hosted vaults of one client share the server route check',
      () async {
        final container = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(FakeClock()),
            utcOffsetProvider.overrideWithValue(() => Duration.zero),
          ],
        );
        addTearDown(container.dispose);
        final server = FakeVaultServer()
          ..serveAttachments('seed')
          ..serveAttachments('other');
        final client = server.connect(container);
        final a = HostedVaultAccess(client: client, vaultName: 'seed');
        final b = HostedVaultAccess(client: client, vaultName: 'other');
        addTearDown(a.dispose);
        addTearDown(b.dispose);

        final first = await a.attachments.addBytes(
          Uint8List(9 * 1024 * 1024),
          'a.bin',
        );
        final afterFirst = server.requests.length;
        final second = await b.attachments.addBytes(
          Uint8List.fromList(List.filled(9 * 1024 * 1024, 5)),
          'b.bin',
        );

        expect(first, isA<AttachmentAdded>());
        expect(second, isA<AttachmentAdded>());
        expect(afterFirst, 2, reason: 'one check, then the POST');
        expect(server.requests.length, 3, reason: 'the second only POSTs');
      },
    );

    test('a disposed hosted vault sends no attachment request', () async {
      final container = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(FakeClock()),
          utcOffsetProvider.overrideWithValue(() => Duration.zero),
        ],
      );
      addTearDown(container.dispose);
      final server = FakeVaultServer()..putAttachment('seed', _path, [7]);
      final hosted = HostedVaultAccess(
        client: server.connect(container),
        vaultName: 'seed',
      );
      hosted.dispose();

      await expectLater(hosted.attachments.read(_path), throwsStateError);
      await expectLater(hosted.attachments.info(_path), throwsStateError);
      await expectLater(
        hosted.attachments.addBytes(Uint8List(1), 'a.png'),
        throwsStateError,
      );
      expect(server.requests, isEmpty);
    });
  });

  group('attachmentsProvider', () {
    test(
      'attachmentsProvider is null with no open vault and the vault attachments domain with one',
      () {
        final c = ProviderContainer(
          overrides: [
            vaultDbProvider.overrideWithValue(null),
            memexCliProvider.overrideWithValue(null),
          ],
        );
        addTearDown(c.dispose);
        expect(c.read(currentVaultProvider), isNull);
        expect(c.read(attachmentsProvider), isNull);

        c.read(currentVaultProvider.notifier).state = _vaultA;
        final attachments = c.read(attachmentsProvider);
        expect(attachments, isA<LocalAttachmentsAccess>());
        expect(
          identical(attachments, c.read(vaultAccessProvider)!.attachments),
          isTrue,
        );
        expect(
          (attachments! as LocalAttachmentsAccess).vaultPath,
          _vaultA.path,
        );
      },
    );

    test('attachmentsProvider follows the open vault when it changes', () {
      final a = FakeAttachmentsAccess();
      final b = FakeAttachmentsAccess();
      final c = _switching({_vaultA: a, _vaultB: b});

      expect(identical(c.read(attachmentsProvider), a), isTrue);
      c.read(currentVaultProvider.notifier).state = _vaultB;
      expect(identical(c.read(attachmentsProvider), b), isTrue);
      c.read(currentVaultProvider.notifier).state = _vaultA;
      expect(identical(c.read(attachmentsProvider), a), isTrue);
    });
  });

  group('FakeAttachmentsAccess', () {
    test(
      'the fake records add and addBytes calls in order and answers from FIFO queues then a default',
      () async {
        final fake = FakeAttachmentsAccess();
        final VaultAccess access = LocalVaultAccess(
          vaultPath: _vaultA.path,
          attachments: fake,
        );
        final first = fakeAddedAttachment('one.pdf', size: 10);
        final second = fakeAddedAttachment('two.pdf', size: 20);
        fake.addResults
          ..add(AttachmentAdded(first))
          ..add(
            const AttachmentAddFailed(
              AttachmentAddFailureReason.tooLarge,
              'big.bin is larger than 100 MB and wasn\'t attached.',
            ),
          );
        fake.addBytesResults.add(AttachmentAdded(second));
        final bytes = Uint8List.fromList([7, 8, 9]);

        final r1 = await access.attachments.add('/tmp/one.pdf', 'one.pdf');
        final r2 = await access.attachments.add('/tmp/big.bin', null);
        final r3 = await access.attachments.add('/tmp/dir/third.txt', null);
        final b1 = await access.attachments.addBytes(bytes, 'two.pdf');
        final b2 = await access.attachments.addBytes(bytes, 'pasted.png');

        expect(identical(_as<AttachmentAdded>(r1).attachment, first), isTrue);
        expect(r2, isA<AttachmentAddFailed>());
        expect(
          _as<AttachmentAddFailed>(r2).reason,
          AttachmentAddFailureReason.tooLarge,
        );
        final defaulted = _as<AttachmentAdded>(r3).attachment;
        expect(defaulted.name, 'third.txt');
        expect(defaulted.size, 0);
        expect(defaulted.path, endsWith('/third.txt'));
        expect(identical(_as<AttachmentAdded>(b1).attachment, second), isTrue);
        final pasted = _as<AttachmentAdded>(b2).attachment;
        expect(pasted.name, 'pasted.png');
        expect(pasted.size, 3);

        expect(fake.addCalls, [
          (filePath: '/tmp/one.pdf', name: 'one.pdf'),
          (filePath: '/tmp/big.bin', name: null),
          (filePath: '/tmp/dir/third.txt', name: null),
        ]);
        expect(fake.addBytesCalls.map((c) => c.name), [
          'two.pdf',
          'pasted.png',
        ]);
        expect(fake.addBytesCalls.first.bytes, bytes);
        expect(fake.addResults, isEmpty);
        expect(fake.addBytesResults, isEmpty);
      },
    );

    test(
      'the fake records read and info calls in order and answers from FIFO queues then a default',
      () async {
        final fake = FakeAttachmentsAccess();
        final VaultAccess access = LocalVaultAccess(
          vaultPath: _vaultA.path,
          attachments: fake,
        );
        fake.readResults
          ..add(AttachmentBytes(Uint8List.fromList([1, 2, 3])))
          ..add(const AttachmentReadFailed(AttachmentLookupFailure.offline));
        fake.infoResults.add(
          const AttachmentInfoFound(
            AttachmentInfo(size: 831488, type: 'application/pdf'),
          ),
        );

        final r1 = await access.attachments.read('objects/a');
        final r2 = await access.attachments.read('objects/b');
        final r3 = await access.attachments.read('objects/c');
        final i1 = await access.attachments.info('objects/a');
        final i2 = await access.attachments.info('objects/b');

        expect(_as<AttachmentBytes>(r1).bytes, [1, 2, 3]);
        expect(
          _as<AttachmentReadFailed>(r2).failure,
          AttachmentLookupFailure.offline,
        );
        expect(_as<AttachmentBytes>(r3).bytes, isEmpty);
        final found = _as<AttachmentInfoFound>(i1).info;
        expect(found.size, 831488);
        expect(found.type, 'application/pdf');
        final defaulted = _as<AttachmentInfoFound>(i2).info;
        expect(defaulted.size, 0);
        expect(defaulted.type, 'application/octet-stream');
        expect(fake.readCalls, ['objects/a', 'objects/b', 'objects/c']);
        expect(fake.infoCalls, ['objects/a', 'objects/b']);
      },
    );

    test(
      'the fake records open and reveal calls in order and answers from FIFO queues then a default',
      () async {
        final fake = FakeAttachmentsAccess();
        final VaultAccess access = LocalVaultAccess(
          vaultPath: _vaultA.path,
          attachments: fake,
        );
        fake.openResults
          ..add(const AttachmentActionFailed(AttachmentLookupFailure.missing))
          ..add(const AttachmentActionFailed(AttachmentLookupFailure.offline));
        fake.revealResults.add(
          const AttachmentActionFailed(AttachmentLookupFailure.serverTooOld),
        );

        final o1 = await access.attachments.open('objects/a');
        final o2 = await access.attachments.open('objects/b');
        final o3 = await access.attachments.open('objects/c');
        final v1 = await access.attachments.reveal('objects/a');
        final v2 = await access.attachments.reveal('objects/b');

        expect(
          _as<AttachmentActionFailed>(o1).failure,
          AttachmentLookupFailure.missing,
        );
        expect(
          _as<AttachmentActionFailed>(o2).failure,
          AttachmentLookupFailure.offline,
        );
        expect(o3, isA<AttachmentActionDone>());
        expect(
          _as<AttachmentActionFailed>(v1).failure,
          AttachmentLookupFailure.serverTooOld,
        );
        expect(v2, isA<AttachmentActionDone>());
        expect(fake.openCalls, ['objects/a', 'objects/b', 'objects/c']);
        expect(fake.revealCalls, ['objects/a', 'objects/b']);
      },
    );
  });

  group('widget override', () {
    testWidgets(
      'a widget reading attachmentsProvider gets the fake the provider is overridden with',
      (tester) async {
        final fake = FakeAttachmentsAccess()
          ..openResults.add(
            const AttachmentActionFailed(AttachmentLookupFailure.offline),
          );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [attachmentsProvider.overrideWithValue(fake)],
            child: const _OpenProbe(),
          ),
        );
        expect(find.text('idle'), findsOneWidget);

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.text('offline'), findsOneWidget);
        expect(fake.openCalls, [_path]);
      },
    );

    testWidgets(
      'a widget reaches the fake through the vault access it is given',
      (tester) async {
        final fake = FakeAttachmentsAccess();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              vaultAccessProvider.overrideWithValue(
                LocalVaultAccess(vaultPath: _vaultA.path, attachments: fake),
              ),
            ],
            child: const _OpenProbe(),
          ),
        );

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.text('done'), findsOneWidget);
        expect(fake.openCalls, [_path]);
      },
    );
  });
}
