use memex_core::embedder::FakeEmbedder;
use memex_core::indexer;
use memex_core::notes::{create_note, CreateNote};
use memex_core::search::{search, SearchFilters, SearchMode, SearchOptions};
use memex_core::Vault;

fn seed_vault(vault: &mut Vault, embedder: Option<&dyn memex_core::embedder::Embedder>) {
    let notes = [
        ("Storage decisions",
         "We chose SQLite over Postgres because the app is local-first. Postgres would force users to run a server."),
        ("Vector search vs FTS",
         "Hybrid search combines BM25 lexical matching with cosine similarity over embeddings via Reciprocal Rank Fusion."),
        ("Founder mental health",
         "Anxiety in early-stage startups is common. Sleep, exercise, and not isolating from peers help."),
        ("Local first principles",
         "Local-first software keeps the user in control of their data. Sync is an enhancement, not a requirement."),
        ("Random non-relevant note",
         "I had a sandwich for lunch. The bread was sourdough."),
    ];
    for (title, body) in notes {
        let n = create_note(
            vault,
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                ..Default::default()
            },
        )
        .unwrap();
        indexer::reindex_note(vault.connection_mut(), n.id.as_str(), body, embedder).unwrap();
    }
}

#[test]
fn fts_search_finds_keyword_matches() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    seed_vault(&mut vault, None);

    let res = search(
        vault.connection_ref(),
        SearchOptions {
            query: "Postgres",
            k: 5,
            mode: SearchMode::Fts,
            filters: SearchFilters::default(),
            embedder: None,
        },
    )
    .unwrap();
    assert!(!res.hits.is_empty(), "expected hits for 'Postgres'");
    assert_eq!(res.hits[0].note_title, "Storage decisions");
}

#[test]
fn hybrid_search_with_fake_embedder_returns_results() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    let emb = FakeEmbedder::new(64);
    seed_vault(&mut vault, Some(&emb));

    let res = search(
        vault.connection_ref(),
        SearchOptions {
            query: "founder anxiety",
            k: 5,
            mode: SearchMode::Hybrid,
            filters: SearchFilters::default(),
            embedder: Some(&emb),
        },
    )
    .unwrap();
    assert!(!res.hits.is_empty());
    let top_titles: Vec<_> = res.hits.iter().map(|h| h.note_title.as_str()).collect();
    assert!(top_titles.contains(&"Founder mental health"),
            "expected 'Founder mental health' in top hits, got {top_titles:?}");
}

#[test]
fn empty_query_returns_no_hits() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    seed_vault(&mut vault, None);

    let res = search(
        vault.connection_ref(),
        SearchOptions {
            query: "",
            k: 5,
            mode: SearchMode::Fts,
            filters: SearchFilters::default(),
            embedder: None,
        },
    )
    .unwrap();
    assert_eq!(res.hits.len(), 0);
    assert!(!res.truncated);
}

#[test]
fn fts_handles_special_characters_in_query() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path()).unwrap();
    seed_vault(&mut vault, None);

    let res = search(
        vault.connection_ref(),
        SearchOptions {
            query: "user's data + sync!",
            k: 5,
            mode: SearchMode::Fts,
            filters: SearchFilters::default(),
            embedder: None,
        },
    )
    .unwrap();
    // Should not panic, should not error. May or may not return hits.
    let _ = res.hits.len();
}
