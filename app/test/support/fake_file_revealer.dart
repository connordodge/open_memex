// WI #361 (Spec #357 TD4): a fake "show in Finder" seam. Records every path
// it is asked to reveal and launches nothing.
import 'package:open_memex_app/src/state/file_revealer.dart';

class FakeFileRevealer implements FileRevealer {
  /// Every path passed to [reveal], in order.
  final List<String> paths = [];

  @override
  Future<void> reveal(String path) async {
    paths.add(path);
  }
}
