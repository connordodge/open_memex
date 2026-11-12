// #424 (391-A0): the echoes seam's state contracts: the one-shot scroll
// target (req 27), the link plan (req 29) and the echoes tab's view model
// (req 34). Stub-neutral tests live in `echoes_seam_stubs_a*_test.dart`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/echo_link_actions.dart';
import 'package:open_memex_app/src/state/echo_scroll_target.dart';
import 'package:open_memex_app/src/state/echoes_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

/// A target built from run-time values (a const one is canonicalised).
EchoScrollTarget _target(String noteId, [int? startByte = 42]) =>
    EchoScrollTarget(noteId, startByte);

EchoesReady _ready({String noteId = 'n1', int pending = 0}) => EchoesReady(
  [
    Echo(
      noteId: noteId,
      noteTitle: 'Title',
      passage: 'passage',
      noteUpdatedAt: int.parse('1000'),
    ),
  ],
  emptyNote: false,
  pending: pending,
);

void _expectSame(Object a, Object b) {
  expect(identical(a, b), isFalse, reason: 'compare two instances');
  expect(a, equals(b));
  expect(a.hashCode, b.hashCode);
}

const _roles = <String?>[null, 'topic', 'daily'];

void main() {
  group('echoScrollTargetProvider', () {
    test('echoScrollTargetProvider starts empty', () {
      final c = _container();
      expect(c.read(echoScrollTargetProvider), isNull);
      expect(c.read(echoScrollTargetProvider.notifier).take('n1'), isNull);
    });

    test(
      'echoScrollTargetProvider take returns a set target once then null',
      () {
        final c = _container();
        final target = _target('n1', 1207);
        c.read(echoScrollTargetProvider.notifier).set(target);
        expect(c.read(echoScrollTargetProvider), target);

        final notifier = c.read(echoScrollTargetProvider.notifier);
        expect(notifier.take('n1'), target);
        expect(c.read(echoScrollTargetProvider), isNull);
        expect(notifier.take('n1'), isNull);
      },
    );

    test(
      'echoScrollTargetProvider take for another note id returns null and clears the target',
      () {
        final c = _container();
        final notifier = c.read(echoScrollTargetProvider.notifier);
        notifier.set(_target('n1'));
        expect(c.read(echoScrollTargetProvider), _target('n1'));

        expect(notifier.take('n2'), isNull);
        expect(c.read(echoScrollTargetProvider), isNull);
        expect(notifier.take('n1'), isNull);
      },
    );

    test('echoScrollTargetProvider keeps a null start byte target', () {
      final c = _container();
      final notifier = c.read(echoScrollTargetProvider.notifier);
      notifier.set(_target('n1', null));

      final taken = notifier.take('n1');
      expect(taken, isNotNull);
      expect(taken!.noteId, 'n1');
      expect(taken.startByte, isNull);
    });

    test('echoScrollTargetProvider set replaces an earlier target', () {
      final c = _container();
      final notifier = c.read(echoScrollTargetProvider.notifier);
      notifier.set(_target('n1', 1));
      notifier.set(_target('n2', 2));
      expect(c.read(echoScrollTargetProvider), _target('n2', 2));

      expect(notifier.take('n1'), isNull);
      expect(c.read(echoScrollTargetProvider), isNull);
    });

    test('echoScrollTargetProvider notifies listeners on set and take', () {
      final c = _container();
      final seen = <EchoScrollTarget?>[];
      c.listen(echoScrollTargetProvider, (_, next) => seen.add(next));
      final notifier = c.read(echoScrollTargetProvider.notifier);

      notifier.set(_target('n1'));
      notifier.take('n1');
      notifier.set(_target('n3'));
      notifier.take('other');

      expect(seen, [_target('n1'), null, _target('n3'), null]);
    });

    test('EchoScrollTarget compares by note id and start byte', () {
      _expectSame(_target('n1', 5), _target('n1', 5));
      _expectSame(_target('n1', null), _target('n1', null));
      expect(_target('n1', 5), isNot(equals(_target('n2', 5))));
      expect(_target('n1', 5), isNot(equals(_target('n1', 6))));
      expect(_target('n1', 5), isNot(equals(_target('n1', null))));
      expect(_target('n1', null), isNot(equals(_target('n1', 0))));
    });
  });

  group('echoLinkPlan', () {
    test(
      'echoLinkPlan links from an open topic or plain note for any echo role',
      () {
        for (final open in const <String?>[null, 'topic', 'unknown']) {
          for (final echo in _roles) {
            expect(
              echoLinkPlan(openRole: open, echoRole: echo),
              EchoLinkPlan.fromOpen,
              reason: 'open $open, echo $echo',
            );
          }
        }
      },
    );

    test(
      'echoLinkPlan files a topic echo on an open daily note as a footer chip',
      () {
        expect(
          echoLinkPlan(openRole: 'daily', echoRole: 'topic'),
          EchoLinkPlan.footerChip,
        );
        expect(
          echoLinkPlan(openRole: 'topic', echoRole: 'topic'),
          isNot(EchoLinkPlan.footerChip),
        );
      },
    );

    test(
      'echoLinkPlan links a plain echo to an open daily note from the echo',
      () {
        expect(
          echoLinkPlan(openRole: 'daily', echoRole: null),
          EchoLinkPlan.fromEcho,
        );
        expect(
          echoLinkPlan(openRole: null, echoRole: null),
          isNot(EchoLinkPlan.fromEcho),
        );
      },
    );

    test(
      'echoLinkPlan returns none only for an open daily note and a daily echo',
      () {
        expect(
          echoLinkPlan(openRole: 'daily', echoRole: 'daily'),
          EchoLinkPlan.none,
        );
        for (final open in _roles) {
          for (final echo in _roles) {
            if (open == 'daily' && echo == 'daily') continue;
            expect(
              echoLinkPlan(openRole: open, echoRole: echo),
              isNot(EchoLinkPlan.none),
              reason: 'open $open, echo $echo',
            );
          }
        }
      },
    );

    test(
      'echoLinkPlan treats an unknown echo role on an open daily note as plain',
      () {
        expect(
          echoLinkPlan(openRole: 'daily', echoRole: 'canvas'),
          EchoLinkPlan.fromEcho,
        );
        expect(
          echoLinkPlan(openRole: 'canvas', echoRole: 'canvas'),
          EchoLinkPlan.fromOpen,
        );
      },
    );

    test('echoLinkPlan covers every pair of note roles', () {
      final expected = <(String?, String?), EchoLinkPlan>{
        (null, null): EchoLinkPlan.fromOpen,
        (null, 'topic'): EchoLinkPlan.fromOpen,
        (null, 'daily'): EchoLinkPlan.fromOpen,
        ('topic', null): EchoLinkPlan.fromOpen,
        ('topic', 'topic'): EchoLinkPlan.fromOpen,
        ('topic', 'daily'): EchoLinkPlan.fromOpen,
        ('daily', null): EchoLinkPlan.fromEcho,
        ('daily', 'topic'): EchoLinkPlan.footerChip,
        ('daily', 'daily'): EchoLinkPlan.none,
      };
      for (final MapEntry(key: (open, echo), value: plan) in expected.entries) {
        expect(
          echoLinkPlan(openRole: open, echoRole: echo),
          plan,
          reason: 'open $open, echo $echo',
        );
      }
    });
  });

  group('echoes view state', () {
    test('EchoesViewState variants compare by value on every field', () {
      final makers = <EchoesViewState Function()>[
        EchoesNoNote.new,
        EchoesNothingWritten.new,
        EchoesFirstLoad.new,
        () => EchoesShown(_ready()),
        () => EchoesShown(_ready(), refreshing: true),
        () => EchoesUnavailableView(EmbedderUnavailable('offline')),
        EchoesDownloading.new,
        () => EchoesError(StateError('x').message, lastGood: _ready()),
      ];
      for (var i = 0; i < makers.length; i++) {
        _expectSame(makers[i](), makers[i]());
        for (var j = 0; j < makers.length; j++) {
          if (i == j) continue;
          expect(makers[i](), isNot(equals(makers[j]())), reason: '$i vs $j');
        }
      }

      expect(EchoesShown(_ready()).refreshing, isFalse);
      expect(
        EchoesShown(_ready()),
        isNot(equals(EchoesShown(_ready(pending: 1)))),
      );
      expect(
        EchoesUnavailableView(EmbedderUnavailable('offline')),
        isNot(equals(EchoesUnavailableView(EmbedderUnavailable('timed out')))),
      );
      expect(
        EchoesUnavailableView(NoCli()),
        isNot(equals(EchoesUnavailableView(Outdated()))),
      );
      expect(EchoesError('boom').lastGood, isNull);
      _expectSame(EchoesError('boom'), EchoesError(['bo', 'om'].join()));
      expect(EchoesError('boom'), isNot(equals(EchoesError('bang'))));
      expect(
        EchoesError('boom'),
        isNot(equals(EchoesError('boom', lastGood: _ready()))),
      );
      expect(
        EchoesError('boom', lastGood: _ready()),
        isNot(equals(EchoesError('boom', lastGood: _ready(noteId: 'n2')))),
      );
    });

    test('EchoesViewState expresses every echoes tab state', () {
      final states = <EchoesViewState>[
        EchoesNoNote(),
        EchoesNothingWritten(),
        EchoesFirstLoad(),
        EchoesShown(EchoesReady(<Echo>[], emptyNote: false, pending: 0)),
        EchoesShown(_ready(pending: 3)),
        EchoesShown(_ready(), refreshing: true),
        for (final reason in <EchoesUnavailableReason>[
          EmbeddingsOff(),
          ModelNotDownloaded(),
          EmbedderUnavailable('offline'),
          NoCli(),
          Outdated(),
        ])
          EchoesUnavailableView(reason),
        EchoesDownloading(),
        EchoesError('boom'),
        EchoesError('boom', lastGood: _ready()),
      ];
      expect(states.toSet(), hasLength(states.length));
    });

    test('echoesAsyncProvider shows no note when nothing is selected', () {
      final c = _container();
      expect(c.read(echoesAsyncProvider), isA<EchoesNoNote>());
    });

    test(
      'echoesAsyncProvider shows nothing written for the virtual Today note',
      () {
        final c = _container();
        c.read(selectedNoteIdProvider.notifier).state =
            'virtual-today:2026-10-03';
        expect(c.read(echoesAsyncProvider), isA<EchoesNothingWritten>());
      },
    );

    test('echoesAsyncProvider starts a selected note on first load', () {
      final c = _container();
      c.read(selectedNoteIdProvider.notifier).state = 'n1';
      expect(c.read(echoesAsyncProvider), isA<EchoesFirstLoad>());
    });

    test('echoesAsyncProvider follows the selected note', () {
      final c = _container();
      final seen = <Type>[];
      c.listen(
        echoesAsyncProvider,
        (_, next) => seen.add(next.runtimeType),
        fireImmediately: true,
      );
      c.read(selectedNoteIdProvider.notifier).state = 'n1';
      c.read(echoesAsyncProvider);
      c.read(selectedNoteIdProvider.notifier).state =
          'virtual-today:2026-10-03';
      c.read(echoesAsyncProvider);
      c.read(selectedNoteIdProvider.notifier).state = null;
      c.read(echoesAsyncProvider);

      expect(seen, [
        EchoesNoNote,
        EchoesFirstLoad,
        EchoesNothingWritten,
        EchoesNoNote,
      ]);
    });
  });
}
