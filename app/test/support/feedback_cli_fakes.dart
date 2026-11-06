// WI #259 (F7): a FakeMemexCli that answers every filing, feedback, guide and
// block-filing command of the #256 Contract with a sample object.
import 'dart:convert';

import 'fake_memex_cli.dart';
import 'feedback_seeds.dart';

String _out(Object? json) => '${jsonEncode(json)}\n';

/// A fake `memex` answering `filing`, `excerpt add|remove-block|move`,
/// `feedback add|edit|rm` and `guide get|restore` with sample objects.
FakeMemexCli feedbackSampleCli() => FakeMemexCli()
  ..on('filing', (_) => FakeMemexCli.ok(_out(filingJson())))
  ..on(
    'excerpt add',
    (_) => FakeMemexCli.ok(
      _out({'vault_id': 'V', 'topic_note_id': 'T1', 'version': 4}),
    ),
  )
  ..on(
    'excerpt remove-block',
    (_) => FakeMemexCli.ok(
      _out({'vault_id': 'V', 'topic_note_id': 'T1', 'version': 5}),
    ),
  )
  ..on(
    'excerpt move',
    (_) => FakeMemexCli.ok(
      _out({
        'vault_id': 'V',
        'from_topic_note_id': 'A1',
        'from_version': 2,
        'to_topic_note_id': 'C1',
        'to_version': 3,
      }),
    ),
  )
  ..on('feedback add', (_) => FakeMemexCli.ok(_out(feedbackJson(id: 'FA'))))
  ..on('feedback edit', (_) => FakeMemexCli.ok(_out(feedbackJson(id: 'FE'))))
  ..on(
    'feedback rm',
    (_) => FakeMemexCli.ok(_out({'vault_id': 'V', 'id': 'FR'})),
  )
  ..on(
    'guide get',
    (_) => FakeMemexCli.ok(
      _out({
        'vault_id': 'V',
        'note_id': 'G',
        'version': 3,
        'content_md': '# G',
      }),
    ),
  )
  ..on(
    'guide restore',
    (_) =>
        FakeMemexCli.ok(_out({'vault_id': 'V', 'note_id': 'G', 'version': 9})),
  );
