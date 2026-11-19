//! Hybrid search: FTS5 (BM25) + optional vector (`vec0`) fused via
//! Reciprocal Rank Fusion.
//!
//! After fusion, every hit on a daily note is expanded into the topic notes
//! that transclude one of the hit chunk's blocks (D25, Spec TD5). Transcluded
//! text is never indexed into the topic, so this is the only way a topic is
//! found through the day's words.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::embedder::Embedder;
use crate::link_extractor::{parse_transclusions, TransclusionToken};
use crate::links::{daily_note_id_for_title, LinkKind};
use crate::transclusion::{render, resolve_span};
use crate::Result;

const RRF_K: f32 = 60.0;
const FTS_OVERSAMPLE: i64 = 5;
const VEC_OVERSAMPLE: i64 = 5;
/// The characters of a chunk a snippet keeps.
const SNIPPET_CHARS: usize = 280;
/// Between an attachment's name and its matching text in a hit's snippet
/// (R46): U+00B7 with a space on each side.
const NAME_SEP: &str = " \u{b7} ";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SearchMode {
    #[default]
    Hybrid,
    Fts,
    Vector,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchFilters {
    /// All listed tags must be present on a note for its chunks to be returned.
    pub tags_all: Vec<String>,
    /// Restrict to a specific note id (useful for "search within a note").
    pub note_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchHit {
    pub chunk_id: String,
    pub note_id: String,
    pub note_title: String,
    pub snippet: String,
    pub score: f32,
    pub ord: i64,
    /// The daily-note date a hit came through, set only on hits expanded
    /// through a transclusion (D25). Absent from JSON when `None`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via: Option<String>,
    /// The attachment a hit came from (Spec #123 R46, R48), set only on a
    /// hit for a note that references a matching attachment. Absent from
    /// JSON when `None`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachment: Option<HitAttachment>,
    /// The byte offset of the attachment's reference line in the note's
    /// stored body (`note_attachments.line_start_byte`), on a direct
    /// attachment hit only. `note_search` answers it as `start_byte`.
    #[serde(skip)]
    pub(crate) line_start: Option<usize>,
    /// The lower-ranked hits of the same note folded into this one before
    /// the cap: its own chunk hits (R46) and other attachment hits on the
    /// same chunk. A daily-note hit also expands through each of them.
    #[serde(skip)]
    pub(crate) merged: Vec<SearchHit>,
}

/// `attachment` of a passage hit (R48): the attachment's stored name and
/// vault-relative path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HitAttachment {
    pub name: String,
    pub path: String,
}

/// One entry of the results' `attachments` list (R47, R48): a matching
/// attachment that at least one note (passing the filters) references.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentMatch {
    pub name: String,
    pub path: String,
    /// The MIME type (`attachments.type`).
    #[serde(rename = "type")]
    pub mime: String,
    pub size: i64,
    /// The first 280 characters of the best-matching attachment chunk; `None`
    /// (absent from JSON) for a name-only match.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snippet: Option<String>,
    /// The referencing notes, in title then id order.
    pub notes: Vec<AttachmentNote>,
}

/// A note that references a listed attachment.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentNote {
    pub id: String,
    pub title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResults {
    pub hits: Vec<SearchHit>,
    pub truncated: bool,
    /// The matching attachments, best first, at most `k` (R47, R48). Absent
    /// from JSON when empty.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<AttachmentMatch>,
}

pub struct SearchOptions<'a> {
    pub query: &'a str,
    pub k: usize,
    pub mode: SearchMode,
    pub filters: SearchFilters,
    pub embedder: Option<&'a dyn Embedder>,
}

pub fn search(conn: &Connection, opts: SearchOptions<'_>) -> Result<SearchResults> {
    let q = opts.query.trim();
    if q.is_empty() {
        return Ok(SearchResults {
            hits: Vec::new(),
            truncated: false,
            attachments: Vec::new(),
        });
    }

    let q_vec = match opts.embedder {
        Some(embedder) if wants_vec(opts.mode) => embed_query(embedder, q)?,
        _ => None,
    };
    search_with_query_vec(conn, &opts, q_vec.as_deref()).map(|(found, _)| found)
}

/// The largest kNN `k` sqlite-vec accepts.
const VEC_K_MAX: i64 = 4096;

fn wants_vec(mode: SearchMode) -> bool {
    matches!(mode, SearchMode::Hybrid | SearchMode::Vector)
}

/// Embeds the trimmed query text `q` in one batch. `None` when the embedder
/// answers no vector or an empty one.
pub(crate) fn embed_query(embedder: &dyn Embedder, q: &str) -> Result<Option<Vec<f32>>> {
    Ok(embedder
        .embed_batch(&[q.to_string()])?
        .into_iter()
        .next()
        .filter(|v| !v.is_empty()))
}

/// The connection half of [`search`]: FTS, kNN with the query vector `q_vec`
/// computed beforehand, fusion, enrichment and transclusion expansion. It
/// never calls an embedder (`opts.embedder` is ignored). The vector arm runs
/// when `opts.mode` wants it and `q_vec` is `Some`; a kNN error (no
/// `chunk_vec` table, say) leaves it empty. The `bool` is whether the kNN
/// query over `chunk_vec` ran and answered.
///
/// Attachments (Spec #123 R46-R49, TD "Search fusion"): the keyword arm also
/// ranks `attachment_chunk_fts` chunks and attachment names, and the vector
/// arm `attachment_chunk_vec` chunks, each its own RRF list. Only attachments
/// some note references (`note_attachments`) take part. An attachment's
/// score is its name score plus its best chunk's score; it becomes one hit
/// per referencing note passing the filters, on that note's chunk holding its
/// first reference line (see [`attachment_hits`]). Attachment hits landing
/// on the same chunk of a note keep only the best one, so no two hits share
/// a (note, chunk). A note's own chunk hits merge into its best attachment
/// hit, so a note shows at most one hit per attachment; a daily note's
/// merged hits still expand (see [`expand_transclusions`]). Hits sort by score, then note title, note id, ord, line and
/// chunk id, so equal scores come in the same order on every search. `k`
/// caps the hits (attachment hits count) and, separately, the attachments
/// list; `truncated` says more hits matched.
pub(crate) fn search_with_query_vec(
    conn: &Connection,
    opts: &SearchOptions<'_>,
    q_vec: Option<&[f32]>,
) -> Result<(SearchResults, bool)> {
    let q = opts.query.trim();
    if q.is_empty() {
        let found = SearchResults {
            hits: Vec::new(),
            truncated: false,
            attachments: Vec::new(),
        };
        return Ok((found, false));
    }

    let want_fts = matches!(opts.mode, SearchMode::Hybrid | SearchMode::Fts);

    let oversample = i64::try_from(opts.k)
        .unwrap_or(i64::MAX)
        .saturating_mul(FTS_OVERSAMPLE.max(VEC_OVERSAMPLE));

    // RRF scores: note chunks, attachment chunks, attachment names (by path).
    let mut note_scores: HashMap<String, f32> = HashMap::new();
    let mut chunk_scores: HashMap<String, f32> = HashMap::new();
    let mut name_scores: HashMap<String, f32> = HashMap::new();

    if want_fts {
        add_ranks(&mut note_scores, fts_search(conn, q, oversample)?);
        add_ranks(
            &mut chunk_scores,
            attachment_fts_search(conn, q, oversample)?,
        );
        add_ranks(&mut name_scores, name_search(conn, q, oversample)?);
    }

    let mut vec_ran = false;
    if let Some(q_vec) = q_vec.filter(|_| wants_vec(opts.mode)) {
        let k = oversample.min(VEC_K_MAX);
        if let Ok(ranked) = vec_search(conn, "chunk_vec", q_vec, k) {
            vec_ran = true;
            add_ranks(&mut note_scores, ranked);
        }
        // No `attachment_chunk_vec` yet (no attachment chunk embedded) is an
        // empty list.
        if let Ok(ranked) = vec_search(conn, "attachment_chunk_vec", q_vec, k) {
            add_ranks(&mut chunk_scores, referenced_only(conn, ranked)?);
        }
    }

    let found = fuse(conn, opts, note_scores, chunk_scores, name_scores)?;
    Ok((found, vec_ran))
}

/// Adds `1 / (RRF_K + rank)` for each ranked key to `scores`.
fn add_ranks(scores: &mut HashMap<String, f32>, ranked: Vec<(String, i64)>) {
    for (key, rank) in ranked {
        *scores.entry(key).or_insert(0.0) += 1.0 / (RRF_K + (rank as f32));
    }
}

/// A matching attachment before it becomes hits and a list entry.
struct Matched {
    path: String,
    name: String,
    mime: String,
    size: i64,
    score: f32,
    /// The best-matching chunk's content; `None` for a name-only match.
    chunk_text: Option<String>,
    /// Referencing notes passing the filters: `(id, title, first reference
    /// line start)`, in title then id order.
    notes: Vec<(String, String, usize)>,
}

/// Turns the three score maps into ranked, capped, expanded hits and the
/// attachments list (see [`search_with_query_vec`]).
fn fuse(
    conn: &Connection,
    opts: &SearchOptions<'_>,
    note_scores: HashMap<String, f32>,
    chunk_scores: HashMap<String, f32>,
    name_scores: HashMap<String, f32>,
) -> Result<SearchResults> {
    let matched = matched_attachments(conn, &opts.filters, chunk_scores, name_scores)?;

    let mut own: Vec<SearchHit> = Vec::new();
    for (chunk_id, score) in note_scores {
        if let Some(hit) = enrich_hit(conn, &chunk_id, score, &opts.filters)? {
            own.push(hit);
        }
    }
    own.sort_by(hit_order);
    let mut found = attachment_hits(conn, &matched)?;
    found.sort_by(hit_order);

    // One hit per (note, chunk): clients key passage rows by `chunk_id`, so
    // two matching attachments referenced in one chunk of a note give one
    // hit, the best one; the others fold into it.
    let mut hits: Vec<SearchHit> = Vec::new();
    let mut on_chunk: HashMap<(String, String), usize> = HashMap::new();
    for hit in found {
        match on_chunk.get(&(hit.note_id.clone(), hit.chunk_id.clone())) {
            Some(&i) => hits[i].merged.push(hit),
            None => {
                on_chunk.insert((hit.note_id.clone(), hit.chunk_id.clone()), hits.len());
                hits.push(hit);
            }
        }
    }

    // A note's own hits merge into its best attachment hit (R46), which
    // keeps the higher score.
    let mut best: HashMap<String, usize> = HashMap::new();
    for (i, h) in hits.iter().enumerate() {
        best.entry(h.note_id.clone()).or_insert(i);
    }
    for hit in own {
        match best.get(&hit.note_id) {
            Some(&i) => {
                hits[i].score = hits[i].score.max(hit.score);
                hits[i].merged.push(hit);
            }
            None => hits.push(hit),
        }
    }
    hits.sort_by(hit_order);

    let truncated = hits.len() > opts.k;
    hits.truncate(opts.k);
    let (hits, dropped) = expand_transclusions(conn, hits, opts.k, &opts.filters)?;

    let attachments = matched
        .into_iter()
        .take(opts.k)
        .map(|m| AttachmentMatch {
            name: m.name,
            path: m.path,
            mime: m.mime,
            size: m.size,
            snippet: m.chunk_text.map(|t| snippet(&t, SNIPPET_CHARS)),
            notes: m
                .notes
                .into_iter()
                .map(|(id, title, _)| AttachmentNote { id, title })
                .collect(),
        })
        .collect();
    Ok(SearchResults {
        hits,
        truncated: truncated || dropped,
        attachments,
    })
}

/// The order of fused hits: score (best first), then note title, note id,
/// ord, reference line, chunk id and attachment path, so ties never depend
/// on map order.
fn hit_order(a: &SearchHit, b: &SearchHit) -> Ordering {
    b.score
        .total_cmp(&a.score)
        .then_with(|| a.note_title.cmp(&b.note_title))
        .then_with(|| a.note_id.cmp(&b.note_id))
        .then_with(|| a.ord.cmp(&b.ord))
        .then_with(|| a.line_start.cmp(&b.line_start))
        .then_with(|| a.chunk_id.cmp(&b.chunk_id))
        .then_with(|| {
            let path = |h: &SearchHit| h.attachment.as_ref().map(|x| x.path.clone());
            path(a).cmp(&path(b))
        })
}

/// The matching attachments with at least one referencing note passing
/// `filters`, best first (then name, then path). An attachment's score is
/// its name score plus its best chunk's score (ties: lower ord, then id).
fn matched_attachments(
    conn: &Connection,
    filters: &SearchFilters,
    chunk_scores: HashMap<String, f32>,
    name_scores: HashMap<String, f32>,
) -> Result<Vec<Matched>> {
    // path → (best chunk score, ord, id, content)
    let mut best_chunk: HashMap<String, (f32, i64, String, String)> = HashMap::new();
    for (id, score) in chunk_scores {
        let row: Option<(String, i64, String)> = conn
            .query_row(
                "SELECT path, ord, content FROM attachment_chunks WHERE id = ?",
                params![id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        let Some((path, ord, content)) = row else {
            continue;
        };
        let better = match best_chunk.get(&path) {
            None => true,
            Some((s, o, i, _)) => score
                .total_cmp(s)
                .then_with(|| o.cmp(&ord))
                .then_with(|| i.as_str().cmp(id.as_str()))
                .is_gt(),
        };
        if better {
            best_chunk.insert(path, (score, ord, id, content));
        }
    }

    let paths: HashSet<String> = best_chunk
        .keys()
        .chain(name_scores.keys())
        .cloned()
        .collect();
    let mut out = Vec::new();
    for path in paths {
        let row: Option<(String, String, i64)> = conn
            .query_row(
                "SELECT name, type, size FROM attachments WHERE path = ?",
                params![path],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        let Some((name, mime, size)) = row else {
            continue;
        };
        let notes = referencing_notes(conn, &path, filters)?;
        if notes.is_empty() {
            continue;
        }
        let chunk = best_chunk.remove(&path);
        let score = name_scores.get(&path).copied().unwrap_or(0.0)
            + chunk.as_ref().map_or(0.0, |(s, ..)| *s);
        out.push(Matched {
            path,
            name,
            mime,
            size,
            score,
            chunk_text: chunk.map(|(_, _, _, content)| content),
            notes,
        });
    }
    out.sort_by(|a, b| {
        b.score
            .total_cmp(&a.score)
            .then_with(|| a.name.cmp(&b.name))
            .then_with(|| a.path.cmp(&b.path))
    });
    Ok(out)
}

/// The notes passing `filters` that reference attachment `path`: `(id,
/// title, first reference line start)`, in title then id order.
fn referencing_notes(
    conn: &Connection,
    path: &str,
    filters: &SearchFilters,
) -> Result<Vec<(String, String, usize)>> {
    let mut stmt = conn.prepare_cached(
        "SELECT n.id, n.title, MIN(na.line_start_byte)
           FROM note_attachments na JOIN notes n ON n.id = na.note_id
          WHERE na.path = ?
          GROUP BY n.id, n.title
          ORDER BY n.title, n.id",
    )?;
    let rows = stmt
        .query_map(params![path], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows
        .into_iter()
        .filter(|(id, ..)| passes_filters(conn, id, filters))
        .map(|(id, title, at)| (id, title, usize::try_from(at).unwrap_or(0)))
        .collect())
}

/// One hit per (referencing note, matched attachment), R46: on the note's
/// chunk holding the reference line (else the nearest chunk before it, else
/// the nearest after it), with the attachment's score, `attachment`, and the
/// snippet `<name> · <first 280 characters of the best chunk>` (`<name>` for
/// a name-only match). A note with no chunks gets no hit.
fn attachment_hits(conn: &Connection, matched: &[Matched]) -> Result<Vec<SearchHit>> {
    let mut out = Vec::new();
    for m in matched {
        let text = match &m.chunk_text {
            Some(t) => format!("{}{NAME_SEP}{}", m.name, snippet(t, SNIPPET_CHARS)),
            None => m.name.clone(),
        };
        for (note_id, note_title, line) in &m.notes {
            let chunk: Option<(String, i64)> = conn
                .query_row(
                    "SELECT id, ord FROM chunks WHERE note_id = ?1
                      ORDER BY (start_byte <= ?2 AND ?2 < end_byte) DESC,
                               (start_byte <= ?2) DESC, abs(start_byte - ?2), ord
                      LIMIT 1",
                    params![note_id, *line as i64],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            let Some((chunk_id, ord)) = chunk else {
                continue;
            };
            out.push(SearchHit {
                chunk_id,
                note_id: note_id.clone(),
                note_title: note_title.clone(),
                snippet: text.clone(),
                score: m.score,
                ord,
                via: None,
                attachment: Some(HitAttachment {
                    name: m.name.clone(),
                    path: m.path.clone(),
                }),
                line_start: Some(*line),
                merged: Vec::new(),
            });
        }
    }
    Ok(out)
}

/// A topic note found through a transclusion of a daily-note hit's blocks.
/// `chunk_id`, `ord` and `snippet` are the topic's own chunk that holds the
/// covering `![[…]]` token; for a topic with no chunks they are `""`, 0 and
/// the token's transcluded text (D36).
struct Expansion {
    note_id: String,
    note_title: String,
    chunk_id: String,
    ord: i64,
    snippet: String,
}

/// Expands each daily-note hit in `direct` (already filtered, ranked and
/// capped at `k`) into the topic notes that transclude one of its blocks
/// (D25). Each expanded hit sits right after its source hit (after earlier
/// expansions of the same source), with the source's score and
/// `via: <date>`. A (topic, date) pair is expanded once, after its first
/// source hit. A topic appears as a direct hit or as expanded hits, never
/// both: a topic already shown as a direct hit above the source is not
/// expanded, and a topic already shown as an expanded hit drops its own
/// lower-ranked direct hit. The total is capped at `k`. Returns the hits and
/// whether the cap dropped any.
///
/// A source hit expands through itself first, then through each hit merged
/// into it ([`SearchHit::merged`]), so a day's own text hit merged into its
/// attachment hit still brings the topics that transclude that text. An
/// expansion through an attachment hit keeps that hit's attachment and
/// snippet (R46); one through a note text hit has neither, and the topic
/// chunk's snippet.
fn expand_transclusions(
    conn: &Connection,
    direct: Vec<SearchHit>,
    k: usize,
    filters: &SearchFilters,
) -> Result<(Vec<SearchHit>, bool)> {
    let mut hits: Vec<SearchHit> = Vec::new();
    let mut shown_direct: HashSet<String> = HashSet::new();
    let mut shown_expanded: HashSet<String> = HashSet::new();
    let mut pairs: HashSet<(String, String)> = HashSet::new();
    for mut source in direct {
        if shown_expanded.contains(&source.note_id) {
            continue;
        }
        let merged = std::mem::take(&mut source.merged);
        let mut topics: Vec<(Expansion, Option<(HitAttachment, String)>)> = Vec::new();
        for from in std::iter::once(&source).chain(&merged) {
            let carried = from.attachment.clone().map(|a| (a, from.snippet.clone()));
            for t in transcluding_topics(conn, from, filters)? {
                topics.push((t, carried.clone()));
            }
        }
        shown_direct.insert(source.note_id.clone());
        let date = source.note_title.clone();
        let score = source.score;
        hits.push(source);
        for (t, carried) in topics {
            if shown_direct.contains(&t.note_id) || !pairs.insert((t.note_id.clone(), date.clone()))
            {
                continue;
            }
            shown_expanded.insert(t.note_id.clone());
            let (attachment, snippet) = match carried {
                Some((a, s)) => (Some(a), s),
                None => (None, t.snippet),
            };
            hits.push(SearchHit {
                chunk_id: t.chunk_id,
                note_id: t.note_id,
                note_title: t.note_title,
                snippet,
                score,
                ord: t.ord,
                via: Some(date.clone()),
                attachment,
                line_start: None,
                merged: Vec::new(),
            });
        }
    }
    let dropped = hits.len() > k;
    hits.truncate(k);
    Ok((hits, dropped))
}

/// The topic notes (passing `filters`) with a transclusion covering a block
/// of `hit`'s daily note that overlaps the hit's byte range, in title order:
/// an attachment hit's reference line, else the hit chunk's range. Empty
/// unless `hit` is on the daily note of its title's date and that range is
/// known (a chunk's NULL range never expands).
fn transcluding_topics(
    conn: &Connection,
    hit: &SearchHit,
    filters: &SearchFilters,
) -> Result<Vec<Expansion>> {
    let date = hit.note_title.as_str();
    if daily_note_id_for_title(conn, date)?.as_deref() != Some(hit.note_id.as_str()) {
        return Ok(Vec::new());
    }
    let Some((cs, ce)) = expansion_range(conn, hit)? else {
        return Ok(Vec::new());
    };

    // The ords of the day's blocks that overlap the chunk: block [s, e)
    // overlaps chunk [cs, ce) iff s < ce && cs < e.
    let mut hit_ords: Vec<i64> = Vec::new();
    let mut stmt =
        conn.prepare_cached("SELECT ord, start_byte, end_byte FROM blocks WHERE note_id = ?")?;
    let mut rows = stmt.query(params![hit.note_id])?;
    while let Some(r) = rows.next()? {
        let (ord, s, e): (i64, i64, i64) = (r.get(0)?, r.get(1)?, r.get(2)?);
        if s < ce && cs < e {
            hit_ords.push(ord);
        }
    }
    if hit_ords.is_empty() {
        return Ok(Vec::new());
    }

    let mut stmt = conn.prepare_cached(
        "SELECT DISTINCT n.id, n.title, n.content_md
           FROM links l JOIN notes n ON n.id = l.from_note_id
          WHERE l.link_kind = ? AND l.link_text = ?
          ORDER BY n.title, n.id",
    )?;
    let topics = stmt
        .query_map(params![LinkKind::FROM_DAY, date], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let mut out = Vec::new();
    for (note_id, note_title, body) in topics {
        let mut covering = None;
        for token in parse_transclusions(&body) {
            if token.date == date && covers(conn, &hit.note_id, &token, &hit_ords)? {
                covering = Some(token);
                break;
            }
        }
        let Some(token) = covering else {
            continue;
        };
        if !passes_filters(conn, &note_id, filters) {
            continue;
        }
        // The topic chunk holding the token, else the nearest chunk before
        // it, else the nearest after it, else its first chunk (a topic whose
        // chunks have no stored range yet). A token in a transclusion-only
        // block is in no chunk (Spec #391 req 2), so its hit points at the
        // nearest chunk and shows the transcluded text as its snippet. A
        // topic with no chunks still expands, with `chunk_id ""`, ord 0 and
        // the transcluded text as its snippet (D36).
        let chunk: Option<(String, i64, String, bool)> = conn
            .query_row(
                "SELECT id, ord, content, start_byte IS NULL OR end_byte IS NULL
                         OR (start_byte <= ?2 AND ?2 < end_byte)
                   FROM chunks WHERE note_id = ?1
                  ORDER BY (start_byte <= ?2 AND ?2 < end_byte) DESC,
                           (start_byte <= ?2) DESC, abs(start_byte - ?2), ord
                  LIMIT 1",
                params![note_id, token.start as i64],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()?;
        let (chunk_id, ord, content) = match chunk {
            Some((id, ord, content, true)) => (id, ord, content),
            Some((id, ord, _, false)) => (id, ord, render(conn, &token)?.text),
            None => (String::new(), 0, render(conn, &token)?.text),
        };
        out.push(Expansion {
            note_id,
            note_title,
            chunk_id,
            ord,
            snippet: snippet(&content, SNIPPET_CHARS),
        });
    }
    Ok(out)
}

/// The byte range `[start, end)` of `hit`'s note a transclusion must cover
/// a block of for `hit` to expand: an attachment hit's reference line
/// (`line_start` to the end of its line, R46), else the hit chunk's stored
/// range (`None` when NULL).
fn expansion_range(conn: &Connection, hit: &SearchHit) -> Result<Option<(i64, i64)>> {
    if let Some(at) = hit.line_start {
        let body: Option<String> = conn
            .query_row(
                "SELECT content_md FROM notes WHERE id = ?",
                params![hit.note_id],
                |r| r.get(0),
            )
            .optional()?;
        let Some(body) = body else {
            return Ok(None);
        };
        let end = body
            .get(at..)
            .and_then(|rest| rest.find('\n'))
            .map_or(body.len(), |n| at + n);
        let end = std::cmp::max(end, at + 1);
        let to_i64 = |n: usize| i64::try_from(n).unwrap_or(i64::MAX);
        return Ok(Some((to_i64(at), to_i64(end))));
    }
    let (cs, ce): (Option<i64>, Option<i64>) = conn.query_row(
        "SELECT start_byte, end_byte FROM chunks WHERE id = ?",
        params![hit.chunk_id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    Ok(cs.zip(ce))
}

/// Whether `token` transcludes one of `hit_ords` of daily note
/// `daily_note_id`. Its block span comes from the one C4 resolver
/// ([`resolve_span`], D28); a token whose endpoint block no longer exists
/// covers nothing.
fn covers(
    conn: &Connection,
    daily_note_id: &str,
    token: &TransclusionToken,
    hit_ords: &[i64],
) -> Result<bool> {
    let span = resolve_span(conn, daily_note_id, &token.from, token.to.as_deref())?;
    Ok(span.is_some_and(|(lo, hi)| hit_ords.iter().any(|&ord| lo <= ord && ord <= hi)))
}

fn fts_search(conn: &Connection, q: &str, k: i64) -> Result<Vec<(String, i64)>> {
    // FTS5 MATCH, ranked by bm25.
    let mut stmt = conn.prepare(
        "SELECT chunk_id FROM chunk_fts WHERE chunk_fts MATCH ? ORDER BY bm25(chunk_fts) LIMIT ?",
    )?;
    let mut rows = stmt.query(params![sanitize_match(q), k])?;
    let mut out = Vec::new();
    let mut rank: i64 = 1;
    while let Some(r) = rows.next()? {
        out.push((r.get::<_, String>(0)?, rank));
        rank += 1;
    }
    Ok(out)
}

/// The kNN of `q_vec` over vector table `table` (`chunk_vec` or
/// `attachment_chunk_vec`): chunk ids with ranks from 1.
fn vec_search(conn: &Connection, table: &str, q_vec: &[f32], k: i64) -> Result<Vec<(String, i64)>> {
    let mut bytes = Vec::with_capacity(q_vec.len() * 4);
    for f in q_vec {
        bytes.extend_from_slice(&f.to_le_bytes());
    }
    let mut stmt = conn.prepare(&format!(
        "SELECT chunk_id FROM {table} WHERE embedding MATCH ? AND k = ? ORDER BY distance"
    ))?;
    let mut rows = stmt.query(params![bytes, k])?;
    let mut out = Vec::new();
    let mut rank: i64 = 1;
    while let Some(r) = rows.next()? {
        out.push((r.get::<_, String>(0)?, rank));
        rank += 1;
    }
    Ok(out)
}

/// `ranked` attachment chunk ids, keeping only those of an attachment some
/// note references (R49), re-ranked from 1.
fn referenced_only(conn: &Connection, ranked: Vec<(String, i64)>) -> Result<Vec<(String, i64)>> {
    let mut stmt = conn.prepare_cached(
        "SELECT EXISTS (SELECT 1 FROM attachment_chunks c JOIN note_attachments na
                         ON na.path = c.path WHERE c.id = ?)",
    )?;
    let mut out = Vec::new();
    for (id, _) in ranked {
        if stmt.query_row(params![id], |r| r.get::<_, bool>(0))? {
            let rank = out.len() as i64 + 1;
            out.push((id, rank));
        }
    }
    Ok(out)
}

/// Keyword matches over attachment chunks (`attachment_chunk_fts`, bm25) of
/// attachments some note references (R43, R49): chunk ids with ranks from 1.
fn attachment_fts_search(conn: &Connection, q: &str, k: i64) -> Result<Vec<(String, i64)>> {
    let mut stmt = conn.prepare(
        "SELECT chunk_id FROM attachment_chunk_fts
          WHERE attachment_chunk_fts MATCH ?1
            AND path IN (SELECT path FROM note_attachments)
          ORDER BY bm25(attachment_chunk_fts), chunk_id
          LIMIT ?2",
    )?;
    let mut rows = stmt.query(params![sanitize_match(q), k])?;
    let mut out = Vec::new();
    let mut rank: i64 = 1;
    while let Some(r) = rows.next()? {
        out.push((r.get::<_, String>(0)?, rank));
        rank += 1;
    }
    Ok(out)
}

/// Keyword matches on attachment names (R43): referenced attachments whose
/// name holds every word of `q` (a word is a run of letters and numbers,
/// compared lowercased), by name then path, as paths with ranks from 1, at
/// most `k`.
fn name_search(conn: &Connection, q: &str, k: i64) -> Result<Vec<(String, i64)>> {
    let wanted = words(q);
    if wanted.is_empty() {
        return Ok(Vec::new());
    }
    let mut stmt = conn.prepare(
        "SELECT a.path, a.name FROM attachments a
          WHERE a.path IN (SELECT path FROM note_attachments)
          ORDER BY a.name, a.path",
    )?;
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let cap = usize::try_from(k).unwrap_or(usize::MAX);
    let mut out = Vec::new();
    for (path, name) in rows {
        if out.len() >= cap {
            break;
        }
        let have = words(&name);
        if wanted.iter().all(|w| have.contains(w)) {
            let rank = out.len() as i64 + 1;
            out.push((path, rank));
        }
    }
    Ok(out)
}

/// The lowercased runs of letters and numbers of `s`.
fn words(s: &str) -> HashSet<String> {
    s.split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_lowercase)
        .collect()
}

fn enrich_hit(
    conn: &Connection,
    chunk_id: &str,
    score: f32,
    filters: &SearchFilters,
) -> Result<Option<SearchHit>> {
    let row: Option<(String, String, i64, String, String)> = conn
        .query_row(
            "SELECT c.id, c.note_id, c.ord, c.content, n.title
             FROM chunks c JOIN notes n ON n.id = c.note_id
             WHERE c.id = ?",
            params![chunk_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .ok();

    let Some((cid, nid, ord, content, title)) = row else {
        return Ok(None);
    };

    if !passes_filters(conn, &nid, filters) {
        return Ok(None);
    }

    Ok(Some(SearchHit {
        chunk_id: cid,
        note_id: nid,
        note_title: title,
        snippet: snippet(&content, SNIPPET_CHARS),
        score,
        ord,
        via: None,
        attachment: None,
        line_start: None,
        merged: Vec::new(),
    }))
}

/// Whether note `nid` satisfies `filters` (direct and expanded hits alike).
fn passes_filters(conn: &Connection, nid: &str, filters: &SearchFilters) -> bool {
    if let Some(req) = &filters.note_id {
        if nid != req {
            return false;
        }
    }
    if !filters.tags_all.is_empty() {
        for tag in &filters.tags_all {
            let has: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM tags WHERE note_id = ? AND tag = ?",
                    params![nid, tag],
                    |r| r.get(0),
                )
                .unwrap_or(0);
            if has == 0 {
                return false;
            }
        }
    }
    true
}

fn snippet(content: &str, max_chars: usize) -> String {
    if content.chars().count() <= max_chars {
        return content.to_string();
    }
    let mut out = String::new();
    for (i, c) in content.chars().enumerate() {
        if i >= max_chars {
            out.push('…');
            break;
        }
        out.push(c);
    }
    out
}

/// Escape FTS5 query special characters for MATCH safety. We accept plain
/// keyword input from agents/users; we don't expose FTS5's column / phrase
/// operators directly.
fn sanitize_match(q: &str) -> String {
    // Quote each whitespace-separated token to avoid syntax errors on ',
    // -, etc., and join with spaces (implicit AND).
    q.split_whitespace()
        .filter(|t| !t.is_empty())
        .map(|t| {
            let mut s = String::from("\"");
            for ch in t.chars() {
                if ch == '"' {
                    s.push_str("\"\"");
                } else {
                    s.push(ch);
                }
            }
            s.push('"');
            s
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// WI #71 mutation follow-up. `search` and `note_search` both return on a
    /// blank query before they call `search_with_query_vec`, so its own
    /// blank-query return is reachable only here. It answers no hits, not
    /// truncated, and the kNN query did not run, whatever the mode or vector.
    #[test]
    fn blank_query_answers_no_hits_not_truncated_and_no_knn_run() {
        // A blank query returns before the connection is touched.
        let conn = Connection::open_in_memory().unwrap();
        let q_vec = [0.5_f32, 0.25, 0.125, 0.0625];
        for query in ["", " ", "   ", "\t", "\n \t "] {
            for mode in [SearchMode::Hybrid, SearchMode::Fts, SearchMode::Vector] {
                for vec in [None, Some(&q_vec[..])] {
                    let opts = SearchOptions {
                        query,
                        k: 8,
                        mode,
                        filters: SearchFilters::default(),
                        embedder: None,
                    };
                    let (found, ran) = search_with_query_vec(&conn, &opts, vec).unwrap();
                    assert!(found.hits.is_empty(), "{query:?} {mode:?}: no hits");
                    assert!(!found.truncated, "{query:?} {mode:?}: not truncated");
                    assert!(!ran, "{query:?} {mode:?}: the kNN query did not run");
                }
            }
        }
    }
}
