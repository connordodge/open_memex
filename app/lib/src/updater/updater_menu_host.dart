import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../widgets/hosted/leave_confirm_dialog.dart' show ProviderReader;
import 'update_controller.dart';
import 'update_modal.dart';
import 'update_seams.dart';
import 'update_state.dart';

/// The updater's method channel (macOS `MainFlutterWindow.swift`, TD4).
///
/// - native → Dart `checkForUpdatesFromMenu` (no arguments): Open Memex ▸
///   Check for Updates… was picked.
///
/// It has no Dart → native methods, and one Dart handler: the
/// [UpdaterMenuHost] the app root attaches.
const updaterChannel = MethodChannel('open_memex/updater');

/// The Dart side of Open Memex ▸ Check for Updates… (req 13, D5, D20).
///
/// The app root attaches it once, so the menu works from the vault picker
/// and from an open vault. `checkForUpdatesFromMenu` opens the update modal
/// over [navigatorKey]'s navigator:
/// - with updates disabled, at Off (no check);
/// - while Ready, Downloading or Verifying, at that state (no check);
/// - otherwise at Checking, running a manual check.
///
/// A request while the modal is open opens no second one (req 18).
class UpdaterMenuHost {
  UpdaterMenuHost({
    required this.navigatorKey,
    required this.read,
    this.channel = updaterChannel,
  });

  /// The navigator the modal opens over.
  final GlobalKey<NavigatorState> navigatorKey;

  /// Reads providers (the app root's `ref.read`).
  final ProviderReader read;

  /// The channel the menu event arrives on.
  final MethodChannel channel;

  /// Starts handling [channel]'s calls.
  void attach() => channel.setMethodCallHandler(_handle);

  /// Stops handling [channel]'s calls.
  void detach() => channel.setMethodCallHandler(null);

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'checkForUpdatesFromMenu') {
      throw MissingPluginException('${channel.name}: ${call.method}');
    }
    final context = navigatorKey.currentContext;
    if (context == null) return null;
    if (read(updatesEnabledProvider) &&
        !_keepsState(read(updateControllerProvider))) {
      // The check enters Checking before its first await, so the modal
      // below opens at Checking.
      unawaited(read(updateControllerProvider.notifier).check(manual: true));
    }
    await openUpdateModal(context, read);
    return null;
  }

  /// Whether the menu opens the modal at [state] and runs no check: an
  /// update staged Ready (req 17) or one downloading or verifying (D20).
  static bool _keepsState(UpdateState state) => switch (state) {
    UpdateReady() || UpdateDownloading() || UpdateVerifying() => true,
    _ => false,
  };
}
