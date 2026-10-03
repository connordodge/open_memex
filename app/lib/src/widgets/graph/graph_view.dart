import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../graph/graph_scope.dart';

/// The read-only Graph view for [scope] (Req 63). Its root carries
/// Key `graph-view`; nodes are `graph-node-<noteId>`, hulls
/// `graph-hull-<folderId>`, the edge hover tooltip `graph-edge-tooltip`.
class GraphView extends ConsumerStatefulWidget {
  const GraphView({super.key, required this.scope});

  final GraphScope scope;

  @override
  ConsumerState<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends ConsumerState<GraphView> {
  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
