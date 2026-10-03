import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'topics_tree.dart';

/// The Topics tree, re-read on every `vaultRevisionProvider` bump. Empty on a
/// vault below V5 or with no database.
final smartFolderTreeProvider = Provider<TopicsTree>(
  (ref) => throw UnimplementedError(),
);
