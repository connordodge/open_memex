// WI #77 (56-A3, Spec #59 reqs 4-11, 24-27, 40-42; D13, D17): the Command
// palette's shell. Skeleton: opens nothing yet.
import 'package:flutter/widgets.dart';

/// Opens the Command palette as a root-navigator dialog over [context] (the
/// Workspace's, or the Command bar's, context): the commands it runs run
/// after the palette pops, with [context]. Never stacks a second palette.
/// Completes when the palette closes.
Future<void> showCommandPalette(BuildContext context) => Future<void>.value();
