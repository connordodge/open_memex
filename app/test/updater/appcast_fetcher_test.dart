// WI #33 (Spec #31 req 1, 15, D1, D6, D18): the production Appcast fetcher.
// HTTP is a MockClient behind updateHttpClientFactoryProvider; no test
// touches the network.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_memex_app/src/updater/appcast_fetcher.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import '../support/updater_fakes.dart' show updaterFixture;

const _wi33Permanent = 'https://connordodge.github.io/open_memex/appcast.xml';

/// A client that records whether it was closed.
class _Wi33ClosingClient extends http.BaseClient {
  _Wi33ClosingClient(this._inner);

  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    closed = true;
    _inner.close();
  }
}

/// Records every request and every client a factory made.
class _Wi33Http {
  _Wi33Http(this._handler);

  final MockClientHandler _handler;
  final List<http.BaseRequest> requests = [];
  final List<_Wi33ClosingClient> clients = [];

  http.Client call() {
    final client = _Wi33ClosingClient(
      MockClient((request) {
        requests.add(request);
        return _handler(request);
      }),
    );
    clients.add(client);
    return client;
  }
}

/// A handler that answers [body] with [status].
MockClientHandler _wi33Answer(String body, {int status = 200}) =>
    (_) async => http.Response(body, status);

/// The production fetcher (`defaultAppcastFetcher` through
/// `appcastFetcherProvider`) over [net].
AppcastFetcher _wi33Fetcher(_Wi33Http net) {
  final container = ProviderContainer(
    overrides: [updateHttpClientFactoryProvider.overrideWithValue(net.call)],
  );
  addTearDown(container.dispose);
  return container.read(appcastFetcherProvider);
}

Matcher _wi33FailsWith(UpdateErrorCause cause) =>
    throwsA(isA<UpdateFailure>().having((f) => f.cause, 'cause', cause));

void main() {
  test(
    'with no override the fetcher requests the permanent Appcast URL',
    () async {
      // flutter test defines no SELF_UPDATE_APPCAST_URL.
      expect(const bool.hasEnvironment('SELF_UPDATE_APPCAST_URL'), isFalse);
      expect(permanentAppcastUrl, _wi33Permanent);
      final net = _Wi33Http(_wi33Answer(updaterFixture('appcast_valid.xml')));

      await _wi33Fetcher(net).fetch();

      expect(net.requests, hasLength(1));
      expect(net.requests.single.method, 'GET');
      expect(net.requests.single.url.toString(), _wi33Permanent);
    },
  );

  test(
    'a non-empty SELF_UPDATE_APPCAST_URL value is requested instead of the permanent URL',
    () async {
      const override = 'http://127.0.0.1:8765/rehearsal/appcast.xml';
      expect(appcastUrlFor('').toString(), _wi33Permanent);
      expect(appcastUrlFor(override).toString(), override);

      final net = _Wi33Http(_wi33Answer(updaterFixture('appcast_valid.xml')));
      await HttpAppcastFetcher(
        clientFactory: net.call,
        url: appcastUrlFor(override),
      ).fetch();
      expect(net.requests.single.url.toString(), override);

      // The production fetcher resolves its URL from the define (a
      // compile-time constant, so the wiring is pinned on the source).
      final source = File(
        'lib/src/updater/appcast_fetcher.dart',
      ).readAsStringSync();
      expect(
        source,
        matches(
          RegExp(r"String\.fromEnvironment\(\s*'SELF_UPDATE_APPCAST_URL'"),
        ),
      );
      expect(
        source,
        contains("'https://connordodge.github.io/open_memex/appcast.xml'"),
      );
    },
  );

  test(
    'a 2xx response with a valid Appcast returns its parsed items',
    () async {
      final net = _Wi33Http(_wi33Answer(updaterFixture('appcast_valid.xml')));

      final items = await _wi33Fetcher(net).fetch();

      expect(items.map((i) => i.shortVersionString), ['1.2.4', '1.3.0']);
      expect(items.map((i) => i.version), ['8', '9']);
      expect(items[1].edSignature, 'c2lnbmF0dXJlLWZvci0xLjMuMA==');
      expect(items[1].length, 38765432);
      expect(items[1].minimumSystemVersion, '14.0');
    },
  );

  test('every 2xx status returns the parsed items', () async {
    for (final status in [200, 201, 203, 299]) {
      final net = _Wi33Http(
        _wi33Answer(updaterFixture('appcast_valid.xml'), status: status),
      );

      final items = await _wi33Fetcher(net).fetch();

      expect(items, hasLength(2), reason: 'HTTP $status');
    }
  });

  test(
    'an Appcast body is decoded as UTF-8 when the response names no charset',
    () async {
      const notes = 'Café notes — naïve · ✓';
      final xml = updaterFixture(
        'appcast_valid.xml',
      ).replaceFirst('- Faster search', notes);
      final net = _Wi33Http(
        (_) async => http.Response.bytes(
          utf8.encode(xml),
          200,
          headers: {'content-type': 'application/xml'},
        ),
      );

      final items = await _wi33Fetcher(net).fetch();

      expect(items, hasLength(2));
      expect(items[1].notes, '## v1.3.0\n- Self-update\n$notes');
    },
  );

  test('an empty channel reads as no items', () async {
    final net = _Wi33Http(
      _wi33Answer(updaterFixture('appcast_empty_channel.xml')),
    );

    expect(await _wi33Fetcher(net).fetch(), isEmpty);
    expect(net.requests, hasLength(1));
  });

  test('a connection failure fails with the offline cause', () async {
    final errors = <Object>[
      const SocketException('Connection refused'),
      http.ClientException('Connection refused'),
      const SocketException(
        'Connection reset by peer',
        osError: OSError('Connection reset by peer', 54),
      ),
    ];
    for (final error in errors) {
      final client = _Wi33Http((_) async => throw error);

      await expectLater(
        _wi33Fetcher(client).fetch(),
        _wi33FailsWith(UpdateErrorCause.offline),
        reason: '$error',
      );
    }
  });

  test('a DNS failure fails with the offline cause', () async {
    final errors = <Object>[
      const SocketException(
        'Failed host lookup: connordodge.github.io',
        osError: OSError('nodename nor servname provided, or not known', 8),
      ),
      http.ClientException(
        'Failed host lookup: connordodge.github.io',
        Uri.parse(_wi33Permanent),
      ),
    ];
    for (final error in errors) {
      final client = _Wi33Http((_) async => throw error);

      await expectLater(
        _wi33Fetcher(client).fetch(),
        _wi33FailsWith(UpdateErrorCause.offline),
        reason: '$error',
      );
    }
  });

  test('a timeout fails with the offline cause', () async {
    final client = _Wi33Http(
      (_) async =>
          throw TimeoutException('No answer', const Duration(seconds: 30)),
    );

    await expectLater(
      _wi33Fetcher(client).fetch(),
      _wi33FailsWith(UpdateErrorCause.offline),
    );
  });

  testWidgets(
    'a fetch the server never answers times out with the offline cause',
    (tester) async {
      final client = _Wi33Http((_) => Completer<http.Response>().future);
      Object? error;
      var done = false;
      unawaited(
        _wi33Fetcher(client).fetch().then(
          (_) => done = true,
          onError: (Object e) {
            error = e;
            done = true;
          },
        ),
      );

      // Fake time: the fetch gives up well within five minutes.
      await tester.pump(const Duration(minutes: 5));

      expect(done, isTrue, reason: 'the fetch must time out');
      expect(
        error,
        isA<UpdateFailure>().having(
          (f) => f.cause,
          'cause',
          UpdateErrorCause.offline,
        ),
      );
    },
  );

  testWidgets(
    'the production fetcher gives a fetch 30 seconds to answer before it fails offline',
    (tester) async {
      final client = _Wi33Http((_) => Completer<http.Response>().future);
      Object? error;
      var done = false;
      final fetcher = _wi33Fetcher(client);
      expect(fetcher, isA<HttpAppcastFetcher>());
      expect(
        (fetcher as HttpAppcastFetcher).timeout,
        const Duration(seconds: 30),
      );
      expect(fetcher.url.toString(), _wi33Permanent);
      unawaited(
        fetcher.fetch().then(
          (_) => done = true,
          onError: (Object e) {
            error = e;
            done = true;
          },
        ),
      );

      await tester.pump(const Duration(seconds: 29));
      expect(done, isFalse, reason: 'still waiting at 29 seconds');

      await tester.pump(const Duration(seconds: 2));
      expect(done, isTrue, reason: 'gave up after 30 seconds');
      expect(
        error,
        isA<UpdateFailure>().having(
          (f) => f.cause,
          'cause',
          UpdateErrorCause.offline,
        ),
      );
      expect(client.clients.single.closed, isTrue);
    },
  );

  testWidgets('a fetch uses the timeout it was built with', (tester) async {
    final net = _Wi33Http((_) => Completer<http.Response>().future);
    Object? error;
    var done = false;
    unawaited(
      HttpAppcastFetcher(
        clientFactory: net.call,
        url: appcastUrlFor(''),
        timeout: const Duration(seconds: 5),
      ).fetch().then(
        (_) => done = true,
        onError: (Object e) {
          error = e;
          done = true;
        },
      ),
    );

    await tester.pump(const Duration(seconds: 4));
    expect(done, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(done, isTrue);
    expect(
      error,
      isA<UpdateFailure>().having(
        (f) => f.cause,
        'cause',
        UpdateErrorCause.offline,
      ),
    );
  });

  test(
    'a body that is not valid UTF-8 fails with the feed-unreadable cause',
    () async {
      final valid = utf8.encode(updaterFixture('appcast_valid.xml'));
      final bodies = {
        'lone continuation byte': [...valid, 0x80],
        'truncated multibyte sequence': [...valid, 0xe2, 0x82],
        'invalid bytes only': [0xff, 0xfe, 0xfd],
      };
      for (final entry in bodies.entries) {
        final net = _Wi33Http(
          (_) async => http.Response.bytes(entry.value, 200),
        );

        await expectLater(
          _wi33Fetcher(net).fetch(),
          _wi33FailsWith(UpdateErrorCause.feedUnreadable),
          reason: entry.key,
        );
        expect(net.clients.single.closed, isTrue, reason: entry.key);
      }
    },
  );

  test('HTTP 404 fails with the no-Appcast cause', () async {
    final net = _Wi33Http(_wi33Answer('Not Found', status: 404));

    await expectLater(
      _wi33Fetcher(net).fetch(),
      _wi33FailsWith(UpdateErrorCause.noAppcast),
    );
  });

  test(
    'any other non-2xx status fails with the feed-unreadable cause',
    () async {
      for (final status in [
        199,
        300,
        301,
        304,
        400,
        401,
        403,
        410,
        429,
        500,
        503,
      ]) {
        // Even with a valid Appcast in the body.
        final net = _Wi33Http(
          _wi33Answer(updaterFixture('appcast_valid.xml'), status: status),
        );

        await expectLater(
          _wi33Fetcher(net).fetch(),
          _wi33FailsWith(UpdateErrorCause.feedUnreadable),
          reason: 'HTTP $status',
        );
      }
    },
  );

  test(
    'a malformed Appcast body fails with the feed-unreadable cause',
    () async {
      final bodies = {
        'bad XML': updaterFixture('appcast_bad_xml.xml'),
        'no channel': updaterFixture('appcast_no_channel.xml'),
        'no valid item': updaterFixture('appcast_all_invalid.xml'),
        'empty body': '',
        'HTML page': '<!DOCTYPE html><html><body>Site not found</body></html>',
      };
      for (final entry in bodies.entries) {
        final net = _Wi33Http(_wi33Answer(entry.value));

        await expectLater(
          _wi33Fetcher(net).fetch(),
          _wi33FailsWith(UpdateErrorCause.feedUnreadable),
          reason: entry.key,
        );
      }
    },
  );

  test(
    'each fetch makes a client from the factory and closes it after a success and after a failure',
    () async {
      var status = 200;
      final client = _Wi33Http(
        (_) async => http.Response(updaterFixture('appcast_valid.xml'), status),
      );
      final fetcher = _wi33Fetcher(client);

      await fetcher.fetch();
      status = 500;
      await expectLater(fetcher.fetch(), throwsA(isA<UpdateFailure>()));

      expect(client.clients, hasLength(2));
      expect(client.clients.map((c) => c.closed), [true, true]);
    },
  );

  test(
    'the production HTTP client factory makes a new client on each call',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final factory = container.read(updateHttpClientFactoryProvider);

      final first = factory();
      final second = factory();
      addTearDown(first.close);
      addTearDown(second.close);

      expect(first, isA<http.Client>());
      expect(identical(first, second), isFalse);
    },
  );
}
