// WI #25 (A8): the `memex settings get|set` wrappers (C2.11, C1, D19, D21).
// Samples are copied verbatim from contracts-1.md.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/settings_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/fake_memex_cli.dart';

const _vault = '/tmp/om-fake-vault';

/// C2.11 `settings get` sample stdout.
const _c211GetSample =
    '{"vault_id":"01HV…","key":"smart_folder_max_depth","value":2}';

/// C2.11 `settings set --value 3` stdout: the same shape with the new value.
const _c211SetSample =
    '{"vault_id":"01HV…","key":"smart_folder_max_depth","value":3}';

void main() {
  group('settings get and set wrappers (AC16)', () {
    test(
      'getSetting then setSetting parse the verbatim C2.11 get and set samples',
      () async {
        var stored = 2;
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(
              stored == 2 ? '$_c211GetSample\n' : '$_c211SetSample\n',
            ),
          )
          ..on('settings set', (_) {
            stored = 3;
            return FakeMemexCli.ok('$_c211SetSample\n');
          });

        expect(await cli.getSetting(_vault, smartFolderMaxDepthKey), 2);
        expect(cli.calls.single.args, [
          'settings',
          'get',
          '--vault',
          _vault,
          '--key',
          'smart_folder_max_depth',
        ]);
        expect(await cli.setSetting(_vault, smartFolderMaxDepthKey, 3), 3);
        expect(await cli.getSetting(_vault, smartFolderMaxDepthKey), 3);
      },
    );

    test(
      'setSetting sends settings set --vault --key --value and parses the C2.11 set sample',
      () async {
        final cli = FakeMemexCli()
          ..on('settings set', (_) => FakeMemexCli.ok('$_c211SetSample\n'));

        final value = await cli.setSetting(_vault, smartFolderMaxDepthKey, 3);

        expect(value, 3);
        expect(cli.calls.single.args, [
          'settings',
          'set',
          '--vault',
          _vault,
          '--key',
          'smart_folder_max_depth',
          '--value',
          '3',
        ]);
      },
    );

    test(
      'setSetting returns the value printed on stdout, not the value sent',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'settings set',
            (_) => FakeMemexCli.ok(
              '{"key":"smart_folder_max_depth","value":5,"vault_id":"01HV…"}',
            ),
          );

        expect(await cli.setSetting(_vault, smartFolderMaxDepthKey, 4), 5);
        expect(cli.calls.single.flag('value'), '4');
      },
    );

    test(
      'a setting_invalid stderr from settings set yields MemexException code setting_invalid',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'settings set',
            (_) => FakeMemexCli.failure(
              '{"error":{"code":"setting_invalid","message":"smart_folder_max_depth must be an integer from 1 to 5"}}\n',
            ),
          );

        await expectLater(
          cli.setSetting(_vault, smartFolderMaxDepthKey, 9),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', 'setting_invalid')
                .having(
                  (e) => e.message,
                  'message',
                  contains('must be an integer from 1 to 5'),
                ),
          ),
        );
      },
    );

    test(
      'settings set stdout without an integer value throws with a null code',
      () async {
        for (final out in ['nope', '{"value":"3"}', '{}']) {
          final cli = FakeMemexCli()
            ..on('settings set', (_) => FakeMemexCli.ok(out));
          await expectLater(
            cli.setSetting(_vault, smartFolderMaxDepthKey, 3),
            throwsA(
              isA<MemexException>().having((e) => e.code, 'code', isNull),
            ),
            reason: out,
          );
        }
      },
    );

    test(
      'a non JSON settings set failure is a MemexException with a null code',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'settings set',
            (_) => FakeMemexCli.failure('boom\n', exitCode: 2),
          );
        await expectLater(
          cli.setSetting(_vault, smartFolderMaxDepthKey, 3),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', isNull)
                .having((e) => e.message, 'message', contains('boom')),
          ),
        );
      },
    );
  });
}
