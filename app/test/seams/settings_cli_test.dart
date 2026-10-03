import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/settings_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/fake_memex_cli.dart';

const _vault = '/tmp/om-fake-vault';

void main() {
  group('settings get wrapper (AC8)', () {
    test(
      'getSetting sends settings get --vault --key and parses the C2.11 value 2',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(
              // C2.11 sample, vault_id first.
              '{"vault_id":"01HV0000000000000000000000","key":"smart_folder_max_depth","value":2}\n',
            ),
          );

        final value = await cli.getSetting(_vault, 'smart_folder_max_depth');

        expect(value, 2);
        expect(cli.calls.single.args, [
          'settings',
          'get',
          '--vault',
          _vault,
          '--key',
          'smart_folder_max_depth',
        ]);
      },
    );

    test('getSetting reads the value field, not a fixed number', () async {
      final cli = FakeMemexCli()
        ..on(
          'settings get',
          (_) => FakeMemexCli.ok(
            '{"key":"smart_folder_max_depth","value":5,"vault_id":"01HV0000000000000000000000"}',
          ),
        );
      expect(await cli.getSetting(_vault, 'smart_folder_max_depth'), 5);
    });

    test(
      'a setting_invalid JSON error surfaces as MemexException code setting_invalid',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.failure(
              '{"error":{"code":"setting_invalid","message":"unknown setting: nope"}}\n',
            ),
          );

        await expectLater(
          cli.getSetting(_vault, 'nope'),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', 'setting_invalid')
                .having(
                  (e) => e.message,
                  'message',
                  contains('unknown setting: nope'),
                ),
          ),
        );
        expect(cli.calls.single.flag('key'), 'nope');
      },
    );

    test(
      'a non-JSON settings get failure (an older memex) is a MemexException with a null code',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.failure(
              "error: unrecognized subcommand 'settings'\n",
              exitCode: 2,
            ),
          );

        await expectLater(
          cli.getSetting(_vault, 'smart_folder_max_depth'),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', isNull)
                .having(
                  (e) => e.message,
                  'message',
                  "settings get failed: error: unrecognized subcommand 'settings'\n",
                ),
          ),
        );
      },
    );
  });
}
