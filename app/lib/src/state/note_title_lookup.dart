// WI #129 (Spec #122 Requirement 22): the note-titles lookup the editor's
// link regions share, built once per note-titles reload.

/// Test-only work counter: how many title-to-note-id lookups were built from
/// a note-titles load (one per reload once the lookup is shared; one per
/// link region before). A plain top-level int, never read by production
/// code.
int debugNoteTitleLookupBuilds = 0;
