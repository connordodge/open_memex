import '../../editor/editor_rows.dart';

/// The undo recorder of one text segment (D8, D9): the rows host calls
/// [record] once for every [SegmentEdit] it applies to the segment's text
/// (typing, a replaced text, an autocomplete insert, a checkbox toggle) and
/// [reset] when the segment is rebuilt from outside (another note, a Source
/// edit, a server write). C1 ships it as a no-op; C4 owns its body.
class SegmentUndoRecorder {
  SegmentUndoRecorder();

  /// [edit] was applied to the segment text [before].
  void record(SegmentEdit edit, {required String before}) =>
      throw UnimplementedError();

  /// Forgets every recorded edit.
  void reset() => throw UnimplementedError();
}

/// Makes the recorder of each text segment the rows host builds. Tests
/// replace it to observe the edits a segment applies.
SegmentUndoRecorder Function() segmentUndoRecorderFactory =
    SegmentUndoRecorder.new;
