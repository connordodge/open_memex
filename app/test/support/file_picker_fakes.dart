// WI #92: a fake `FilePicker.platform` for the picker's folder and binary
// pickers, so widget tests never open a native dialog. WI #146 adds
// multiple selection: [FakeFilePickerCall.allowMultiple] and
// [FakeFilePicker.fileLists].
import 'package:file_picker/file_picker.dart';

/// One recorded picker call: which method, its dialog title and (for
/// `pickFiles`) whether it allowed multiple selection.
class FakeFilePickerCall {
  FakeFilePickerCall(
    this.method,
    this.dialogTitle, {
    this.allowMultiple = false,
  });

  /// `getDirectoryPath` or `pickFiles`.
  final String method;
  final String? dialogTitle;

  /// `pickFiles(allowMultiple:)`; false for `getDirectoryPath`.
  final bool allowMultiple;

  @override
  String toString() =>
      'FakeFilePickerCall($method, $dialogTitle, allowMultiple: $allowMultiple)';
}

/// Answers `getDirectoryPath` and `pickFiles` from queues. An empty queue
/// answers null (the person cancelled the native dialog).
class FakeFilePicker extends FilePicker {
  /// Paths `getDirectoryPath` returns, in order.
  final List<String?> directories = [];

  /// Paths `pickFiles` returns (one file each), in order.
  final List<String?> files = [];

  /// Path lists `pickFiles` returns (several files each, in pick order), in
  /// order; answered before [files]. A null entry is a cancelled dialog.
  final List<List<String>?> fileLists = [];

  /// Every call in order.
  final List<FakeFilePickerCall> calls = [];

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    calls.add(FakeFilePickerCall('getDirectoryPath', dialogTitle));
    return directories.isEmpty ? null : directories.removeAt(0);
  }

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls.add(
      FakeFilePickerCall(
        'pickFiles',
        dialogTitle,
        allowMultiple: allowMultiple,
      ),
    );
    if (fileLists.isNotEmpty) {
      final paths = fileLists.removeAt(0);
      if (paths == null) return null;
      return FilePickerResult([
        for (final p in paths)
          PlatformFile(path: p, name: p.split('/').last, size: 0),
      ]);
    }
    final path = files.isEmpty ? null : files.removeAt(0);
    if (path == null) return null;
    return FilePickerResult([
      PlatformFile(path: path, name: path.split('/').last, size: 0),
    ]);
  }
}

/// Install a fresh [FakeFilePicker] as `FilePicker.platform` and return it.
FakeFilePicker installFakeFilePicker() {
  final fake = FakeFilePicker();
  FilePicker.platform = fake;
  return fake;
}
