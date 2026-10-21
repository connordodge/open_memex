// WI #98 (H4, D20): the shared harness of the connect and edit-server dialog
// tests. The dialog probes the fake vault server (a MockClient, no network)
// through `connectServerHttpClientProvider`; settings use a mock
// SharedPreferences and a FakeTokenStore (never the real Keychain); time is a
// FakeClock (the 10 s probe timeout).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/token_store.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/hosted/connect_server_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';
import '../../support/token_store_fakes.dart';

const kWi98Dialog = Key('connect-server-dialog');
const kWi98Name = Key('connect-name');
const kWi98Url = Key('connect-url');
const kWi98Token = Key('connect-token');
const kWi98Toggle = Key('connect-token-toggle');
const kWi98Submit = Key('connect-submit');
const kWi98Cancel = Key('connect-cancel');
const kWi98SetupLink = Key('connect-setup-link');
const kWi98Error = Key('connect-error');

const _openKey = Key('wi98-open');

/// Board copy (A4 / A5) and Spec req 43 copy.
const kWi98ConnectHint =
    'from <vault root>/.memex/access-token on the server. '
    'kept in your keychain.';
const kWi98EditHint = 'saved in your keychain. paste a new one to replace it.';
const kWi98SchemeError = 'enter a url starting with http:// or https://';
const kWi98TokenRejected = 'access token rejected';
String wi98CantReach(String url) => "can't reach $url";
String wi98NotMemex(String url) => "$url isn't a memex vault server";
String wi98ApiMismatch(String server, String version) =>
    "$server runs memex $version, which this app can't use. update the app "
    'or memex on the server so both are the same release.';

/// The invalid-input border (A5 states 3 and 4).
final kWi98InvalidBorder = OmColors.danger.withAlpha(166);

/// A server to save before the dialog opens.
typedef Wi98Seed = ({String name, String url, String token});

/// The pumped host app: a button that opens the dialog, plus the fakes.
class Wi98Env {
  Wi98Env._(this.tester, this.server, this.tokens, this.clock, this.settings);

  final WidgetTester tester;
  final FakeVaultServer server;
  final FakeTokenStore tokens;
  final FakeClock clock;
  final SettingsController settings;
  late final ProviderContainer container;

  /// The server being edited, or null for "connect".
  SavedServer? edit;

  /// What `showConnectServerDialog` returned, once [returned].
  SavedServer? result;
  bool returned = false;
  int setUpCalls = 0;

  /// The saved servers right now.
  List<SavedServer> get saved => settings.state.savedServers;

  /// Opens the dialog (connect, or edit when [edit] is set).
  Future<void> open() async {
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kWi98Dialog), findsOneWidget);
  }

  /// Types into the dialog's fields; a null argument leaves that field as is.
  Future<void> fill({String? name, String? url, String? token}) async {
    if (url != null) await tester.enterText(wi98Editable(kWi98Url), url);
    if (name != null) await tester.enterText(wi98Editable(kWi98Name), name);
    if (token != null) {
      await tester.enterText(wi98Editable(kWi98Token), token);
    }
    await tester.pump();
  }

  /// Taps the primary button and lets the probe run as far as the fake
  /// server lets it (microtasks only; a held or never-answering request
  /// stays pending). Never settles: the connecting spinner animates.
  Future<void> submit() async {
    await tester.tap(find.byKey(kWi98Submit), warnIfMissed: false);
    await pumpFrames();
  }

  /// A few frames (async work through microtasks), without settling.
  Future<void> pumpFrames([int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// Every prefs entry that contains [needle].
  Future<List<String>> prefsWith(String needle) async =>
      (await tester.runAsync(() => prefsEntriesContaining(needle)))!;
}

/// The EditableText inside the dialog field keyed [key].
Finder wi98Editable(Key key) =>
    find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

/// The EditableText widget inside the field keyed [key].
EditableText wi98EditableOf(WidgetTester tester, Key key) =>
    tester.widget<EditableText>(wi98Editable(key));

/// Pumps the host app. [seed] servers are saved (through
/// `SettingsController.saveServer`) before it opens; [editIndex] makes the
/// dialog the edit-server dialog for that seeded server.
Future<Wi98Env> pumpWi98Host(
  WidgetTester tester, {
  List<Wi98Seed> seed = const [],
  int? editIndex,
  FakeVaultServer? server,
  FakeTokenStore? tokenStore,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({'memex.binary_path': 'fake-memex'});
  final tokens = tokenStore ?? FakeTokenStore();
  final settings = (await tester.runAsync(
    () => SettingsController.load(tokenStore: tokens),
  ))!;
  for (final s in seed) {
    await tester.runAsync(
      () => settings.saveServer(name: s.name, url: s.url, token: s.token),
    );
  }
  final env = Wi98Env._(
    tester,
    server ?? FakeVaultServer(),
    tokens,
    FakeClock(),
    settings,
  );
  if (editIndex != null) env.edit = settings.state.savedServers[editIndex];

  env.container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      tokenStoreProvider.overrideWithValue(tokens),
      clockProvider.overrideWithValue(env.clock),
      connectServerHttpClientProvider.overrideWithValue(env.server.client),
    ],
  );
  addTearDown(env.container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: env.container,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: _openKey,
                onPressed: () async {
                  final r = await showConnectServerDialog(
                    context,
                    edit: env.edit,
                    onSetUp: () => env.setUpCalls++,
                  );
                  env.result = r;
                  env.returned = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return env;
}

/// A [FakeTokenStore] whose writes wait while [hold] is on: a slow Keychain
/// write (or a Keychain access prompt) that is still pending when the user
/// taps cancel.
class Wi98GatedTokenStore extends FakeTokenStore {
  Completer<void>? _gate;

  /// Holds every later write until [release].
  void hold() => _gate ??= Completer<void>();

  /// Lets held writes through.
  void release() {
    _gate?.complete();
    _gate = null;
  }

  Completer<void>? _readGate;

  /// Holds every later read until [releaseReads]: a Keychain access prompt
  /// still open when the user taps cancel.
  void holdReads() => _readGate ??= Completer<void>();

  /// Lets held reads through.
  void releaseReads() {
    _readGate?.complete();
    _readGate = null;
  }

  /// While on, every later write call fails (decided when it is called, so a
  /// write already held by [hold] still lands): a Keychain error.
  bool failWrites = false;

  /// While on, every later delete call fails: a Keychain error.
  bool failDeletes = false;

  @override
  Future<String?> read(String serverId) async {
    final gate = _readGate;
    if (gate != null) await gate.future;
    return super.read(serverId);
  }

  @override
  Future<void> write(String serverId, String token) async {
    final fail = failWrites;
    final gate = _gate;
    if (gate != null) await gate.future;
    if (fail) {
      calls.add('write $serverId');
      throw StateError('wi98 keychain write failed');
    }
    await super.write(serverId, token);
  }

  @override
  Future<void> delete(String serverId) async {
    if (failDeletes) {
      calls.add('delete $serverId');
      throw StateError('wi98 keychain delete failed');
    }
    await super.delete(serverId);
  }
}

/// The input box decoration of the dialog field keyed [key] (the outermost
/// DecoratedBox inside it).
BoxDecoration wi98BoxOf(WidgetTester tester, Key key) =>
    tester
            .widget<DecoratedBox>(
              find
                  .descendant(
                    of: find.byKey(key),
                    matching: find.byType(DecoratedBox),
                  )
                  .first,
            )
            .decoration
        as BoxDecoration;

/// Whether the EditableText of the dialog field keyed [key] has focus.
bool wi98Focused(WidgetTester tester, Key key) =>
    wi98EditableOf(tester, key).focusNode.hasFocus;

/// The primary button reads "connecting…".
Finder wi98Connecting() => find.descendant(
  of: find.byKey(kWi98Submit),
  matching: find.text('connecting…'),
);

/// [f] sits below [below] and above [above] (an inline error "under" a
/// field).
void expectWi98Between(
  WidgetTester tester,
  Finder f, {
  required Finder below,
  required Finder above,
}) {
  final r = tester.getRect(f);
  expect(
    r.top,
    greaterThanOrEqualTo(tester.getRect(below).bottom - 0.5),
    reason: 'it sits under ${below.describeMatch(Plurality.one)}',
  );
  expect(
    r.bottom,
    lessThanOrEqualTo(tester.getRect(above).top + 0.5),
    reason: 'it sits above ${above.describeMatch(Plurality.one)}',
  );
}

/// The A5 inline error style: [message] in JetBrains Mono 11 `danger`, led
/// by a 12 px `alertTriangle` in `danger` on the same row.
void expectWi98A5Error(WidgetTester tester, String message) {
  final text = find.text(message);
  expect(text, findsOneWidget, reason: 'the inline error "$message"');
  final style = tester.widget<Text>(text).style;
  expect(style?.color, OmColors.danger, reason: 'error text is danger');
  expect(style?.fontSize, 11, reason: 'error text is 11 px');
  final textRect = tester.getRect(text);
  final icons = find.byWidgetPredicate(
    (w) =>
        w is Icon &&
        w.icon == LucideIcons.alertTriangle &&
        w.color == OmColors.danger,
  );
  final onRow = icons.evaluate().where((e) {
    final box = e.renderObject! as RenderBox;
    final r = box.localToGlobal(Offset.zero) & box.size;
    return r.right <= textRect.left + 0.5 &&
        r.center.dy >= textRect.top - 4 &&
        r.center.dy <= textRect.bottom + 4;
  });
  expect(onRow, isNotEmpty, reason: 'an alertTriangle leads the error row');
  final icon = onRow.first.widget as Icon;
  expect(icon.size, 12, reason: 'the error icon is 12 px');
}

/// The border colours drawn around the dialog field keyed [key]: every
/// BoxDecoration border of a 30–44 px tall DecoratedBox at, inside or around
/// the field, plus the borders of an InputDecorator inside it.
Set<Color> wi98BorderColorsOf(WidgetTester tester, Key key) {
  final field = find.byKey(key);
  final colors = <Color>{};
  void add(Element e) {
    final box = e.renderObject;
    if (box is! RenderBox || !box.hasSize) return;
    if (box.size.height < 30 || box.size.height > 44) return;
    final d = (e.widget as DecoratedBox).decoration;
    if (d is BoxDecoration && d.border is Border) {
      colors.add((d.border! as Border).top.color);
    }
  }

  for (final e
      in find
          .ancestor(of: field, matching: find.byType(DecoratedBox))
          .evaluate()) {
    add(e);
  }
  for (final e
      in find
          .descendant(of: field, matching: find.byType(DecoratedBox))
          .evaluate()) {
    add(e);
  }
  for (final e
      in find
          .descendant(of: field, matching: find.byType(InputDecorator))
          .evaluate()) {
    final d = (e.widget as InputDecorator).decoration;
    final active = d.errorText != null
        ? d.errorBorder
        : (d.enabled ? d.enabledBorder : d.disabledBorder);
    for (final b in [active, d.border]) {
      if (b != null && b.borderSide != BorderSide.none) {
        colors.add(b.borderSide.color);
      }
    }
  }
  return colors;
}

/// Every rendered Text / RichText string in the app (EditableText content is
/// not included: an obscured field renders bullets).
List<String> wi98RenderedStrings(WidgetTester tester) => [
  for (final e in find.byType(Text).evaluate())
    () {
      final w = e.widget as Text;
      return w.data ?? w.textSpan?.toPlainText() ?? '';
    }(),
  for (final e in find.byType(RichText).evaluate())
    (e.widget as RichText).text.toPlainText(),
];
