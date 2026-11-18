// #66 (54-R0, ruling D1, D3c): `locateInSegment` finds the editor row for a
// segment-local UTF-16 offset, and `locateEchoArrival` delegates to it with
// unchanged results. The daily `_sharedPrefix` limit applies to the byte
// mapping only: a daily person segment's stray text (moved from below the
// Topics marker) is found by segment offset. Pure functions; the editor
// landing that uses them is in `note_reveal_test.dart` (on the shared pump).
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/byte_offsets.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart' show RowKind;
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/widgets/editor/echo_arrival_highlight.dart';

const _wi66Card = '![[2026-09-05#^b7k2m9..^c3d4e5]]';

/// Segment 0: prose, bullet, indented prose, table, prose; segment 1: an
/// excerpt card; segment 2: prose, bullet.
const _wi66Seg0 =
    'intro\n- item one\n  more\n| a | b |\n|---|---|\n| 1 | 2 |\nafter\n';
const _wi66Seg2 = 'second seg line\n- second item\n';
const _wi66Normal = '$_wi66Seg0$_wi66Card\n$_wi66Seg2';

const _wi66Footed = 'body line\n$topicsMarker\n[[Alpha~about]]\n';

/// A daily note whose stray text below the marker joins the person segment:
/// `morning\n## Stray heading\nstray line\n`.
const _wi66Daily =
    'morning\n$topicsMarker\n[[Alpha~about]]\n## Stray heading\nstray line\n';
const _wi66DailyPerson = 'morning\n## Stray heading\nstray line\n';

const _wi66Emoji = '— intro 🙂\n- a 🙂 b\n  passage — c\n';

EchoArrival _wi66Located(
  String content,
  int segment,
  int local, {
  String? role,
}) {
  final found = locateInSegment(content, segment, local, role: role);
  expect(found, isNotNull, reason: 'segment $segment offset $local');
  return found!;
}

/// The fields of [a], for comparing two arrivals.
List<Object?> _wi66Fields(EchoArrival? a) => a == null
    ? const [null]
    : [a.key, a.fallbackKey, a.segment, a.kind, a.rowText, a.local];

/// The (segment, segment offset) [locateEchoArrival] maps body offset [at]
/// to: the segment walk it does, with a daily person segment at body offsets
/// only over its prefix shared with the body. Null inside the footer.
(int, int)? _wi66SegmentOffset(String content, int at, String? role) {
  final daily = role == 'daily';
  final segments = split(content, isDaily: daily, noteFooter: role != 'guide');
  var start = 0;
  for (var s = 0; s < segments.length; s++) {
    switch (segments[s]) {
      case TextSegment(:final text):
        var limit = text.length;
        if (daily) {
          final n = math.min(text.length, content.length);
          limit = 0;
          while (limit < n &&
              text.codeUnitAt(limit) == content.codeUnitAt(limit)) {
            limit++;
          }
        }
        if (at < start + limit) return (s, at - start);
        start += text.length;
      case TransclusionSegment(:final raw):
        if (at < start + raw.length) return (s, at - start);
        start += raw.length;
      case FooterSegment():
        return null;
    }
  }
  return null;
}

bool _wi66InsidePair(String text, int i) =>
    i > 0 &&
    i < text.length &&
    (text.codeUnitAt(i - 1) & 0xFC00) == 0xD800 &&
    (text.codeUnitAt(i) & 0xFC00) == 0xDC00;

void main() {
  group('locateInSegment', () {
    test(
      'locateInSegment finds the row for a segment local offset in a normal note',
      () {
        final intro = _wi66Located(_wi66Normal, 0, 2);
        expect(intro.key, const ValueKey('editor-row-0-0'));
        expect(intro.segment, 0);
        expect(intro.kind, RowKind.prose);
        expect(intro.rowText, 'intro');
        expect(intro.local, 2);

        final item = _wi66Located(_wi66Normal, 0, _wi66Seg0.indexOf('one'));
        expect(item.key, const ValueKey('editor-row-0-1'));
        expect(item.kind, RowKind.bullet);
        expect(item.rowText, 'item one');
        expect(item.local, 'item '.length);
        expect(item.fallbackKey, isNull);

        final table = _wi66Located(_wi66Normal, 0, _wi66Seg0.indexOf('| 1'));
        expect(table.key, const ValueKey('editor-table-0-3'));
        expect(table.fallbackKey, const ValueKey('editor-row-0-3'));
        expect(table.kind, RowKind.table);

        final after = _wi66Located(_wi66Normal, 0, _wi66Seg0.indexOf('after'));
        expect(after.key, const ValueKey('editor-row-0-4'));
        // A segment ending in a terminator ends in a prose row keeping it
        // (splitRows; locateEchoArrival on main returns the same text).
        expect(after.rowText, 'after\n');
        expect(after.local, 0);
      },
    );

    test(
      'locateInSegment takes the offset in the given segment after an excerpt card',
      () {
        final line = _wi66Located(_wi66Normal, 2, 'second '.length);
        expect(line.key, const ValueKey('editor-row-2-0'));
        expect(line.segment, 2);
        expect(line.rowText, 'second seg line');
        expect(line.local, 'second '.length);

        final item = _wi66Located(
          _wi66Normal,
          2,
          _wi66Seg2.indexOf('second item') + 'second '.length,
        );
        expect(item.key, const ValueKey('editor-row-2-1'));
        expect(item.kind, RowKind.bullet);
        expect(item.rowText, 'second item');
        expect(item.local, 'second '.length);
      },
    );

    test('locateInSegment on a card segment returns its excerpt card', () {
      for (final local in [0, 5, _wi66Card.length - 1]) {
        final card = _wi66Located(_wi66Normal, 1, local);
        expect(card.key, const Key('excerpt-card-1'));
        expect(card.segment, 1);
        expect(card.kind, isNull);
        expect(card.fallbackKey, isNull);
      }
    });

    test(
      'locateInSegment finds stray text past the shared prefix in a daily person segment',
      () {
        expect(
          split(_wi66Daily, isDaily: true).first,
          isA<TextSegment>().having((t) => t.text, 'text', _wi66DailyPerson),
        );
        final local = _wi66DailyPerson.indexOf('## Stray heading');
        expect(
          local,
          greaterThan('morning\n'.length - 1),
          reason: 'past the prefix the person segment shares with the body',
        );

        final stray = _wi66Located(_wi66Daily, 0, local, role: 'daily');

        expect(stray.key, const ValueKey('editor-row-0-0'));
        expect(stray.kind, RowKind.prose);
        expect(stray.rowText, 'morning\n## Stray heading\nstray line\n');
        expect(stray.local, local);
        final line = _wi66Located(
          _wi66Daily,
          0,
          _wi66DailyPerson.indexOf('stray line') + 3,
          role: 'daily',
        );
        expect(line.local, _wi66DailyPerson.indexOf('stray line') + 3);
      },
    );

    test('locateInSegment splits a guide note without a footer', () {
      final marker = _wi66Footed.indexOf(topicsMarker);

      final guide = _wi66Located(_wi66Footed, 0, marker, role: 'guide');

      expect(guide.key, const ValueKey('editor-row-0-0'));
      expect(guide.rowText, contains(topicsMarker));
      expect(guide.local, marker);
      expect(
        locateInSegment(_wi66Footed, 0, marker),
        isNull,
        reason: 'another note ends its text segment at the marker',
      );
      expect(
        locateInSegment(_wi66Footed, 1, 0),
        isNull,
        reason: 'the footer is no row',
      );
      expect(
        locateInSegment(_wi66Daily, 0, _wi66DailyPerson.indexOf('## Stray')),
        isNull,
        reason: 'without the daily role the marker starts a footer',
      );
    });

    test('locateInSegment returns null outside its segment text', () {
      expect(locateInSegment(_wi66Normal, 0, 2), isNotNull);
      expect(
        locateInSegment(_wi66Normal, 3, 0),
        isNull,
        reason: 'no segment 3',
      );
      expect(locateInSegment(_wi66Normal, -1, 0), isNull);
      expect(locateInSegment(_wi66Normal, 0, -1), isNull);
      expect(locateInSegment(_wi66Normal, 0, _wi66Seg0.length + 3), isNull);
      expect(locateInSegment('', 0, 4), isNull);
    });
  });

  group('locateEchoArrival delegates', () {
    test('locateEchoArrival agrees with locateInSegment at every offset', () {
      for (final (content, role) in [
        (_wi66Normal, null),
        (_wi66Footed, null),
        (_wi66Footed, 'guide'),
        (_wi66Daily, 'daily'),
        (_wi66Emoji, null),
      ]) {
        var compared = 0;
        for (var at = 0; at <= content.length; at++) {
          if (_wi66InsidePair(content, at)) continue;
          final mapped = _wi66SegmentOffset(content, at, role);
          final echo = locateEchoArrival(
            content,
            utf16ToUtf8(content, at),
            role: role,
          );
          if (mapped == null) {
            expect(echo, isNull, reason: '$role offset $at is in the footer');
            continue;
          }
          final (segment, local) = mapped;
          final inSegment = locateInSegment(
            content,
            segment,
            local,
            role: role,
          );
          expect(
            _wi66Fields(inSegment),
            _wi66Fields(echo),
            reason: '$role body offset $at = segment $segment offset $local',
          );
          if (echo != null) compared++;
        }
        // The fewest locatable offsets: a daily note's shared prefix
        // ('morning\n') has 8, a footed body ('body line\n') 10.
        expect(compared, greaterThanOrEqualTo(8), reason: 'role $role');
      }
    });
  });
}
