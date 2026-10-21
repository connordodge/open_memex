// WI #89 (W5): the canvas view reads its detail and runs its four writes
// (move node, place note, add link, edit link) through VaultAccess (D13,
// D14a, Req 33, Req 50). Doubles extend the local domain classes (D21):
// Wi89Canvas serves, holds and records the canvas calls, Wi89Notes records the
// two link writes. The view is pumped bare (not in the workspace).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/canvas_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/vault_async_view.dart';

import '../support/canvas_robot.dart';
import '../support/canvas_seeds.dart';
import '../support/fake_vault_db.dart';

const _a = LocalVaultRef('/tmp/om-89-vault-a');
const _b = LocalVaultRef('/tmp/om-89-vault-b');
const _hostedA = HostedVaultRef('srv-89', 'hosted-a');
const _hostedB = HostedVaultRef('srv-89', 'hosted-b');
const _id = 'cv-89-board';

/// A canvas domain serving the board: Alpha at (10, 20), Beta at (300, 40)
/// and one labelled edge between them.
Wi89Canvas _board() => Wi89Canvas(details: {_id: wi89BoardDetail(_id)});

/// A canvas domain serving only Gamma, as another vault would.
Wi89Canvas _otherBoard() => Wi89Canvas(
  details: {
    _id: wi89Detail(_id, nodes: [wi89Node(C89.gamma, 'Gamma', 50, 60)]),
  },
);

/// A canvas domain whose every read waits for the test.
Wi89Canvas _held() => Wi89Canvas()..hold = true;

const _unreachable = VaultUnreachableException(
  serverName: 'nas',
  mayHaveCommitted: false,
);
const _unconfirmed = VaultUnreachableException(
  serverName: 'nas',
  mayHaveCommitted: true,
);
const _unreachableText = "couldn't reach nas. try again.";
const _unconfirmedText =
    "couldn't confirm with nas — check before trying again";

/// One of the view's four writes: how to trigger it, how many times the
/// double saw it, how to make it fail, and the local failure snackbar.
class _Write {
  const _Write(this.run, this.calls, this.failWith, this.failurePrefix);

  final Future<void> Function(WidgetTester tester, CanvasHarness h) run;
  final int Function(CanvasHarness h) calls;
  final void Function(CanvasHarness h, Object error) failWith;
  final String failurePrefix;
}

Future<void> _runMove(WidgetTester tester, CanvasHarness h) async {
  await CanvasRobot(tester, _id).dragNode(C89.alpha, const Offset(100, 80));
  await tester.pump(wi89Debounce);
  await tester.pump();
  await tester.pump();
}

Future<void> _runDrop(WidgetTester tester, CanvasHarness h) async {
  await CanvasRobot(tester, _id).dropNote(const Offset(500, 250));
}

Future<void> _runLink(WidgetTester tester, CanvasHarness h) async {
  await CanvasRobot(
    tester,
    _id,
  ).linkNodes(C89.alpha, C89.beta, kind: 'extends', label: 'why');
}

Future<void> _runEdit(WidgetTester tester, CanvasHarness h) async {
  final robot = CanvasRobot(tester, _id);
  await robot.selectEdge(h.container, C89.link);
  await robot.saveEdge(h.container, label: 'changed');
}

final _move = _Write(
  _runMove,
  (h) => h.canvas.moves.length,
  (h, e) => h.canvas.writeError = e,
  'Move failed: ',
);
final _drop = _Write(
  _runDrop,
  (h) => h.canvas.adds.length,
  (h, e) => h.canvas.writeError = e,
  'Could not place note: ',
);
final _link = _Write(
  _runLink,
  (h) => h.notesA.addedLinks.length,
  (h, e) => h.notesA.writeError = e,
  'Could not add link: ',
);
final _edit = _Write(
  _runEdit,
  (h) => h.notesA.updatedLinks.length,
  (h, e) => h.notesA.writeError = e,
  'Update failed: ',
);

Future<CanvasHarness> _pumpBoard(
  WidgetTester tester, {
  Wi89Canvas? canvas,
  VaultRef vault = _a,
  bool canWrite = true,
}) => CanvasHarness.pump(
  tester,
  _id,
  canvases: {vault: canvas ?? _board()},
  canWrite: canWrite,
);

void main() {
  group('reads', () {
    testWidgets(
      'canvas view hydrates the nodes and edges of a canvas from the vault database through VaultAccess',
      (tester) async {
        final db = seedCanvasFixture(FakeVaultDb.v5());
        addTearDown(db.close);
        await pumpWi89Host(
          tester,
          C89.newer,
          overrides: [
            currentVaultProvider.overrideWith((_) => _a),
            vaultDbProvider.overrideWithValue(db),
            memexCliProvider.overrideWithValue(null),
          ],
        );
        final robot = CanvasRobot(tester, C89.newer);

        expect(robot.nodeIds, {C89.alpha, C89.beta});
        expect(robot.edgeIds, [C89.link]);
        expect(robot.nodePosition(C89.alpha), const Offset(10.5, 20));
        expect(robot.nodePosition(C89.beta), const Offset(300, 40.25));
        expect(find.text('Alpha'), findsOneWidget);
        expect(find.text('Beta'), findsOneWidget);
        expect(robot.loadingText, findsNothing);
      },
    );

    testWidgets(
      'canvas view paints the detail the canvas domain of VaultAccess returns',
      (tester) async {
        final h = await _pumpBoard(tester);
        final robot = CanvasRobot(tester, _id);

        expect(h.canvas.detailCalls, [_id]);
        expect(robot.nodeIds, {C89.alpha, C89.beta});
        expect(robot.edgeIds, [C89.link]);
        expect(robot.nodePosition(C89.alpha), const Offset(10, 20));
        expect(robot.nodePosition(C89.beta), const Offset(300, 40));
      },
    );

    testWidgets('canvas view shows Loading canvas for an unknown canvas id', (
      tester,
    ) async {
      final db = seedCanvasFixture(FakeVaultDb.v5());
      addTearDown(db.close);
      await pumpWi89Host(
        tester,
        'no-such-canvas',
        overrides: [
          currentVaultProvider.overrideWith((_) => _a),
          vaultDbProvider.overrideWithValue(db),
          memexCliProvider.overrideWithValue(null),
        ],
      );
      final robot = CanvasRobot(tester, 'no-such-canvas');

      expect(robot.view, findsOneWidget);
      expect(robot.loadingText, findsOneWidget);
      expect(robot.nodeIds, isEmpty);
      expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
    });

    testWidgets(
      'canvas view shows Loading canvas and no hosted spinner on a local first load',
      (tester) async {
        final h = await _pumpBoard(tester, canvas: _held());
        final robot = CanvasRobot(tester, _id);

        expect(h.canvas.heldDetails, hasLength(1));
        expect(robot.loadingText, findsOneWidget);
        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);

        h.canvas.heldDetails.single.complete(wi89BoardDetail(_id));
        await tester.pump();
        await tester.pump();

        expect(robot.loadingText, findsNothing);
        expect(robot.nodeIds, {C89.alpha, C89.beta});
      },
    );

    testWidgets(
      'canvas view shows the hosted loading state on a hosted first load',
      (tester) async {
        final h = await _pumpBoard(tester, canvas: _held(), vault: _hostedA);
        final robot = CanvasRobot(tester, _id);

        expect(h.canvas.heldDetails, hasLength(1));
        expect(find.byKey(vaultAsyncLoadingKey), findsOneWidget);
        expect(robot.loadingText, findsNothing);
        expect(robot.nodeIds, isEmpty);

        h.canvas.heldDetails.single.complete(wi89BoardDetail(_id));
        await tester.pump();
        await tester.pump();

        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
        expect(robot.nodeIds, {C89.alpha, C89.beta});
      },
    );

    for (final (name, vault) in [
      (
        'canvas view keeps the previous nodes and edges on screen during a reload',
        _a,
      ),
      (
        'canvas view keeps the previous nodes and edges on screen during a hosted reload',
        _hostedA,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final h = await _pumpBoard(tester, vault: vault);
        final robot = CanvasRobot(tester, _id);
        expect(robot.nodeIds, {C89.alpha, C89.beta});

        h.canvas.hold = true;
        h.container.read(vaultRevisionProvider.notifier).state++;
        await tester.pump();
        await tester.pump();

        expect(h.canvas.heldDetails, hasLength(1));
        expect(robot.nodeIds, {C89.alpha, C89.beta});
        expect(robot.edgeIds, [C89.link]);
        expect(robot.loadingText, findsNothing);
        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);

        h.canvas.heldDetails.single.complete(
          wi89Detail(_id, nodes: [wi89Node(C89.gamma, 'Gamma', 50, 60)]),
        );
        await tester.pump();
        await tester.pump();

        expect(robot.nodeIds, {C89.gamma});
        expect(robot.edgeIds, isEmpty);
        expect(find.text('Gamma'), findsOneWidget);
      });
    }

    testWidgets(
      'switching vaults never shows the previous vault rows in the canvas view',
      (tester) async {
        final h = await CanvasHarness.pump(
          tester,
          _id,
          canvases: {_a: _board(), _b: _held()},
          first: _a,
        );
        final robot = CanvasRobot(tester, _id);
        expect(robot.nodeIds, {C89.alpha, C89.beta});

        h.switchTo(_b);
        await tester.pump();
        await tester.pump();

        expect(robot.nodeIds, isEmpty);
        expect(robot.edgeIds, isEmpty);
        expect(find.text('Alpha'), findsNothing);
        expect(robot.loadingText, findsOneWidget);
        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);

        h.canvases[_b]!.heldDetails.single.complete(
          wi89Detail(_id, nodes: [wi89Node(C89.gamma, 'Gamma', 50, 60)]),
        );
        await tester.pump();
        await tester.pump();

        expect(robot.nodeIds, {C89.gamma});
      },
    );

    testWidgets(
      'switching hosted vaults never shows the previous vault rows in the canvas view',
      (tester) async {
        final h = await CanvasHarness.pump(
          tester,
          _id,
          canvases: {_hostedA: _board(), _hostedB: _held()},
          first: _hostedA,
        );
        final robot = CanvasRobot(tester, _id);
        expect(robot.nodeIds, {C89.alpha, C89.beta});

        h.switchTo(_hostedB);
        await tester.pump();
        await tester.pump();

        expect(robot.nodeIds, isEmpty);
        expect(robot.edgeIds, isEmpty);
        expect(find.text('Alpha'), findsNothing);
        expect(find.byKey(vaultAsyncLoadingKey), findsOneWidget);
        expect(robot.loadingText, findsNothing);

        h.canvases[_hostedB]!.heldDetails.single.complete(
          _otherBoard().details[_id],
        );
        await tester.pump();
        await tester.pump();

        expect(robot.nodeIds, {C89.gamma});
        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
      },
    );

    testWidgets(
      'a late response from the previous vault never reaches the canvas view after a switch',
      (tester) async {
        final a = _board()..hold = true;
        final h = await CanvasHarness.pump(
          tester,
          _id,
          canvases: {_a: a, _b: _held()},
          first: _a,
        );
        final robot = CanvasRobot(tester, _id);
        expect(a.heldDetails, hasLength(1));

        h.switchTo(_b);
        await tester.pump();
        a.heldDetails.single.complete(wi89BoardDetail(_id));
        await tester.pump();
        await tester.pump();

        expect(robot.nodeIds, isEmpty);
        expect(robot.loadingText, findsOneWidget);
      },
    );
  });

  group('node moves', () {
    testWidgets(
      'dragging a node persists its position through VaultAccess once after the debounce and bumps the revision',
      (tester) async {
        final h = await _pumpBoard(tester);
        final robot = CanvasRobot(tester, _id);
        expect(robot.nodePosition(C89.alpha), const Offset(10, 20));

        // The second drag lands inside the debounce of the first, so the two
        // collapse into one write at the final position.
        await robot.dragNode(C89.alpha, const Offset(100, 80));
        await tester.pump(const Duration(milliseconds: 50));
        await robot.dragNode(C89.alpha, const Offset(100, 80));
        final end = robot.nodePosition(C89.alpha);
        expect(end.dx, greaterThan(100));
        expect(end.dy, greaterThan(80));

        await tester.pump(const Duration(milliseconds: 100));
        expect(h.canvas.moves, isEmpty);
        expect(h.revision, 0);

        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump();
        await tester.pump();

        expect(h.canvas.moves, hasLength(1));
        final move = h.canvas.moves.single;
        expect(move.canvasId, _id);
        expect(move.noteId, C89.alpha);
        expect(move.x, closeTo(end.dx, 0.01));
        expect(move.y, closeTo(end.dy, 0.01));
        expect(move.zOrder, isNull);
        expect(h.revision, 1);
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    testWidgets(
      'a failed node move shows Move failed with the error and bumps nothing',
      (tester) async {
        final h = await _pumpBoard(tester);
        final error = Exception('disk full');
        h.canvas.writeError = error;

        await _runMove(tester, h);

        expect(h.canvas.moves, hasLength(1));
        expect(find.text('Move failed: $error'), findsOneWidget);
        expect(h.revision, 0);
      },
    );
  });

  group('note drops', () {
    testWidgets(
      'dropping a note onto the canvas places it through VaultAccess at the drop position and bumps the revision',
      (tester) async {
        final h = await _pumpBoard(tester);

        final at = await CanvasRobot(
          tester,
          _id,
        ).dropNote(const Offset(500, 250));

        expect(h.canvas.adds, hasLength(1));
        final add = h.canvas.adds.single;
        expect(add.canvasId, _id);
        expect(add.noteId, wi89DroppedNoteId);
        expect(add.x, closeTo(at.dx, 0.01));
        expect(add.y, closeTo(at.dy, 0.01));
        expect(add.x, greaterThan(400));
        expect(add.y, greaterThan(150));
        expect(h.revision, 1);
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    testWidgets(
      'a failed note drop shows Could not place note with the error and bumps nothing',
      (tester) async {
        final h = await _pumpBoard(tester);
        final error = Exception('no such note');
        h.canvas.writeError = error;

        await _runDrop(tester, h);

        expect(h.canvas.adds, hasLength(1));
        expect(find.text('Could not place note: $error'), findsOneWidget);
        expect(h.revision, 0);
      },
    );
  });

  group('links', () {
    testWidgets(
      'linking two nodes adds the link with its kind and label through VaultAccess and bumps the revision',
      (tester) async {
        final h = await _pumpBoard(tester);

        await _runLink(tester, h);

        expect(h.notesA.addedLinks, [
          (from: C89.alpha, to: C89.beta, kind: 'extends', label: 'why'),
        ]);
        expect(h.revision, 1);
        expect(find.byType(SnackBar), findsNothing);
        expect(find.byKey(const Key('link-popover')), findsNothing);
      },
    );

    testWidgets(
      'linking two nodes with the popover defaults adds a references link with no label',
      (tester) async {
        final h = await _pumpBoard(tester);

        await CanvasRobot(tester, _id).linkNodes(C89.beta, C89.alpha);

        expect(h.notesA.addedLinks, [
          (from: C89.beta, to: C89.alpha, kind: 'references', label: null),
        ]);
        expect(h.revision, 1);
      },
    );

    testWidgets('cancelling the link popover adds no link and bumps nothing', (
      tester,
    ) async {
      final h = await _pumpBoard(tester);
      final robot = CanvasRobot(tester, _id);
      await robot.startLink(C89.alpha, C89.beta);
      expect(find.byKey(const Key('link-popover')), findsOneWidget);

      await tester.tap(find.byKey(const Key('link-popover-cancel')));
      await robot.settle();

      expect(h.notesA.addedLinks, isEmpty);
      expect(h.revision, 0);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets(
      'a failed link add shows Could not add link with the error and bumps nothing',
      (tester) async {
        final h = await _pumpBoard(tester);
        final error = Exception('link refused');
        h.notesA.writeError = error;

        await _runLink(tester, h);

        expect(h.notesA.addedLinks, hasLength(1));
        expect(find.text('Could not add link: $error'), findsOneWidget);
        expect(h.revision, 0);
      },
    );
  });

  group('edge edits', () {
    testWidgets(
      'editing an edge updates its kind and label through VaultAccess, bumps the revision and clears the selection',
      (tester) async {
        final h = await _pumpBoard(tester);
        final robot = CanvasRobot(tester, _id);
        await robot.selectEdge(h.container, C89.link);
        expect(find.byKey(const Key('edge-inspector')), findsOneWidget);

        await robot.saveEdge(h.container, kind: 'extends', label: 'new label');

        expect(h.notesA.updatedLinks, [
          (
            linkId: C89.link,
            kind: 'extends',
            label: 'new label',
            clearLabel: false,
          ),
        ]);
        expect(h.revision, 1);
        expect(
          h.container.read(canvasSelectionProvider(_id)).selectedEdgeId,
          isNull,
        );
        expect(find.byKey(const Key('edge-inspector')), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    testWidgets(
      'emptying the label of a labelled edge sends clearLabel and leaves the kind unchanged',
      (tester) async {
        final h = await _pumpBoard(tester);
        final robot = CanvasRobot(tester, _id);
        await robot.selectEdge(h.container, C89.link);

        await robot.saveEdge(h.container, label: '');

        expect(h.notesA.updatedLinks, [
          (linkId: C89.link, kind: null, label: null, clearLabel: true),
        ]);
        expect(h.revision, 1);
      },
    );

    testWidgets('saving an edge without edits sends its label and no kind', (
      tester,
    ) async {
      final h = await _pumpBoard(tester);
      final robot = CanvasRobot(tester, _id);
      await robot.selectEdge(h.container, C89.link);

      await robot.saveEdge(h.container);

      expect(h.notesA.updatedLinks, [
        (linkId: C89.link, kind: null, label: 'ties', clearLabel: false),
      ]);
    });

    testWidgets(
      'saving an unlabelled edge with an empty label does not send clearLabel',
      (tester) async {
        final canvas = Wi89Canvas(
          details: {
            _id: wi89Detail(
              _id,
              nodes: [
                wi89Node(C89.alpha, 'Alpha', 10, 20),
                wi89Node(C89.beta, 'Beta', 300, 40),
              ],
              edges: [wi89Edge(C89.link, C89.alpha, C89.beta)],
            ),
          },
        );
        final h = await _pumpBoard(tester, canvas: canvas);
        final robot = CanvasRobot(tester, _id);
        await robot.selectEdge(h.container, C89.link);

        await robot.saveEdge(h.container, kind: 'contradicts');

        expect(h.notesA.updatedLinks, [
          (
            linkId: C89.link,
            kind: 'contradicts',
            label: null,
            clearLabel: false,
          ),
        ]);
      },
    );

    testWidgets(
      'a failed edge update shows Update failed with the error, keeps the selection and bumps nothing',
      (tester) async {
        final h = await _pumpBoard(tester);
        final error = Exception('update refused');
        h.notesA.writeError = error;

        await _runEdit(tester, h);

        expect(h.notesA.updatedLinks, hasLength(1));
        expect(find.text('Update failed: $error'), findsOneWidget);
        expect(h.revision, 0);
        expect(
          h.container.read(canvasSelectionProvider(_id)).selectedEdgeId,
          C89.link,
        );
      },
    );
  });

  group('unreachable hosted writes', () {
    for (final (name, write) in [
      (
        'an unreachable vault on a node move shows the guard snackbar and bumps nothing',
        _move,
      ),
      (
        'an unreachable vault on a note drop shows the guard snackbar and bumps nothing',
        _drop,
      ),
      (
        'an unreachable vault on a link add shows the guard snackbar and bumps nothing',
        _link,
      ),
      (
        'an unreachable vault on an edge update shows the guard snackbar and bumps nothing',
        _edit,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final h = await _pumpBoard(tester);
        write.failWith(h, _unreachable);

        await write.run(tester, h);

        expect(write.calls(h), 1);
        expect(find.text(_unreachableText), findsOneWidget);
        expect(find.textContaining(write.failurePrefix), findsNothing);
        expect(h.revision, 0);
      });
    }

    testWidgets(
      'a node move that may have committed shows the confirm snackbar and bumps nothing',
      (tester) async {
        final h = await _pumpBoard(tester);
        h.canvas.writeError = _unconfirmed;

        await _runMove(tester, h);

        expect(h.canvas.moves, hasLength(1));
        expect(find.text(_unconfirmedText), findsOneWidget);
        expect(find.textContaining('Move failed: '), findsNothing);
        expect(h.revision, 0);
      },
    );

    testWidgets(
      'an unreachable vault on an edge update keeps the edge selected',
      (tester) async {
        final h = await _pumpBoard(tester);
        h.notesA.writeError = _unreachable;

        await _runEdit(tester, h);

        expect(
          h.container.read(canvasSelectionProvider(_id)).selectedEdgeId,
          C89.link,
        );
      },
    );
  });

  group('without a memex CLI', () {
    for (final (name, write) in [
      ('without a memex CLI a node move is a silent no-op', _move),
      ('without a memex CLI a note drop is a silent no-op', _drop),
      ('without a memex CLI a link add is a silent no-op', _link),
      ('without a memex CLI an edge update is a silent no-op', _edit),
    ]) {
      testWidgets(name, (tester) async {
        final h = await _pumpBoard(tester, canWrite: false);

        await write.run(tester, h);

        expect(write.calls(h), 0);
        expect(find.byType(SnackBar), findsNothing);
        expect(h.revision, 0);
      });
    }
  });
}
