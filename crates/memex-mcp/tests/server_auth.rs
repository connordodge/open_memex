//! WI #71 (R0a): the vault server's outer shell, in-process (req 3, 14, 18,
//! 19; D7, D17).
//!
//! - AC 6: one bearer layer guards every route class; the token is read
//!   only from `Authorization: Bearer` (scheme case-insensitive).
//! - AC 7: `GET /api/v1/info`.
//! - AC 8: an unknown path is 404 `not_found`.
//! - AC 9: the C1 code → HTTP status table, `ApiError`, and the
//!   `ApiJson` / `ApiPath` / `ApiQuery` extractors (400 `invalid_argument`).
//! - AC 10: the 8 MiB body limit (413 `payload_too_large`), behind auth.
//! - AC 11: no CORS headers.

#[path = "support/server.rs"]
mod server;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use axum::response::IntoResponse;
use axum::routing::{get as get_route, post as post_route};
use axum::Router;
use memex_core::MemexError;
use memex_mcp::cli::{error_json, InvalidArgument};
use memex_mcp::server::error::{status_for_code, ApiError, ApiJson, ApiPath, ApiQuery};
use memex_mcp::server::API_VERSION;
use reqwest::Method;
use serde::Deserialize;
use serde_json::{json, Value};

use server::{client, get, raw_request, Reply, TestServer, BODY_LIMIT, TEST_TOKEN};

/// One request per route class (D7 risk list): server API, vault list and
/// create, per-vault API, per-vault MCP, an unknown path, the root, and a
/// CORS-style preflight.
fn route_classes() -> Vec<(Method, &'static str, Option<Value>)> {
    vec![
        (Method::GET, "/api/v1/info", None),
        (Method::GET, "/api/v1/vaults", None),
        (
            Method::POST,
            "/api/v1/vaults",
            Some(json!({ "name": "work" })),
        ),
        (Method::GET, "/vaults/x/api/v1/info", None),
        (
            Method::POST,
            "/vaults/x/mcp",
            Some(json!({
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": { "name": "wi71", "version": "0" },
                },
            })),
        ),
        (Method::GET, "/no/such/path", None),
        (Method::GET, "/", None),
        (Method::OPTIONS, "/api/v1/info", None),
    ]
}

/// A way of presenting (or not presenting) credentials that must be refused.
struct BadCredential {
    name: &'static str,
    /// The `Authorization` header value, if any.
    authorization: Option<String>,
    /// Other headers.
    headers: Vec<(&'static str, String)>,
    /// Appended to the path.
    query: String,
    /// The secret this request presented, which no 401 body may echo.
    presented: Option<String>,
}

fn bad_credentials() -> Vec<BadCredential> {
    let short = &TEST_TOKEN[..TEST_TOKEN.len() - 1];
    let long = format!("{TEST_TOKEN}x");
    let c = |name, authorization: Option<String>, presented: Option<String>| BadCredential {
        name,
        authorization,
        headers: vec![],
        query: String::new(),
        presented,
    };
    vec![
        c("no Authorization header", None, None),
        c(
            "wrong token",
            Some("Bearer wrong-token-5e6f7a8b".into()),
            Some("wrong-token-5e6f7a8b".into()),
        ),
        c(
            "a prefix of the token",
            Some(format!("Bearer {short}")),
            Some(short.to_string()),
        ),
        c(
            "the token plus one character",
            Some(format!("Bearer {long}")),
            Some(long.clone()),
        ),
        c("empty Bearer", Some("Bearer ".into()), None),
        c("Bearer with no credentials", Some("Bearer".into()), None),
        c(
            "Basic scheme carrying the token",
            Some(format!("Basic {TEST_TOKEN}")),
            Some(TEST_TOKEN.into()),
        ),
        c(
            "Basic user:token",
            Some(format!("Basic {}", base64(&format!("memex:{TEST_TOKEN}")))),
            Some(TEST_TOKEN.into()),
        ),
        c(
            "token with no scheme",
            Some(TEST_TOKEN.into()),
            Some(TEST_TOKEN.into()),
        ),
        c(
            "Token scheme",
            Some(format!("Token {TEST_TOKEN}")),
            Some(TEST_TOKEN.into()),
        ),
        BadCredential {
            name: "token only in ?access_token=",
            authorization: None,
            headers: vec![],
            query: format!("?access_token={TEST_TOKEN}"),
            presented: Some(TEST_TOKEN.into()),
        },
        BadCredential {
            name: "token only in ?token=",
            authorization: None,
            headers: vec![],
            query: format!("?token={TEST_TOKEN}"),
            presented: Some(TEST_TOKEN.into()),
        },
        BadCredential {
            name: "token only in a Cookie",
            authorization: None,
            headers: vec![(
                "cookie",
                format!("access_token={TEST_TOKEN}; token={TEST_TOKEN}; memex_token={TEST_TOKEN}"),
            )],
            query: String::new(),
            presented: Some(TEST_TOKEN.into()),
        },
        BadCredential {
            name: "token only in X-Access-Token",
            authorization: None,
            headers: vec![("x-access-token", TEST_TOKEN.into())],
            query: String::new(),
            presented: Some(TEST_TOKEN.into()),
        },
    ]
}

/// Standard base64 (for the `Basic` case only).
fn base64(input: &str) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes = input.as_bytes();
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

async fn send(
    srv: &TestServer,
    method: &Method,
    path_and_query: &str,
    body: &Option<Value>,
    authorization: Option<&str>,
    headers: &[(&str, String)],
) -> Reply {
    let mut req = client().request(method.clone(), srv.url(path_and_query));
    if let Some(value) = authorization {
        req = req.header("authorization", value);
    }
    for (k, v) in headers {
        req = req.header(*k, v);
    }
    if let Some(body) = body {
        req = req.json(body);
    }
    Reply::read(req.send().await.expect("send")).await
}

// ---------- AC 6: auth on every route class ----------

#[tokio::test]
async fn every_route_class_answers_401_unauthorized_to_bad_credentials() {
    let srv = TestServer::start().await;
    for (method, path, body) in route_classes() {
        for cred in bad_credentials() {
            let what = format!("{method} {path} with {}", cred.name);
            let r = send(
                &srv,
                &method,
                &format!("{path}{}", cred.query),
                &body,
                cred.authorization.as_deref(),
                &cred.headers,
            )
            .await;
            assert_eq!(r.status, 401, "{what}: body {:?}", r.body);
            assert_eq!(r.c1_code(), "unauthorized", "{what}");
            assert!(
                !r.body.contains(TEST_TOKEN),
                "{what}: 401 body never echoes the token: {}",
                r.body
            );
            if let Some(secret) = &cred.presented {
                assert!(
                    !r.body.contains(secret.as_str()),
                    "{what}: 401 body never echoes the presented token: {}",
                    r.body
                );
            }
            for (k, v) in &r.headers {
                assert!(
                    !v.contains(TEST_TOKEN),
                    "{what}: header {k} never echoes the token"
                );
            }
        }
    }
}

#[tokio::test]
async fn bearer_scheme_is_case_insensitive_with_the_right_token() {
    let srv = TestServer::start().await;
    for scheme in ["Bearer", "bearer", "BEARER", "bEaReR"] {
        let r = get(
            &srv.url("/api/v1/info"),
            Some(&format!("{scheme} {TEST_TOKEN}")),
        )
        .await;
        assert_eq!(r.status, 200, "{scheme} scheme is accepted: {:?}", r.body);
    }
}

// ---------- AC 7: GET /api/v1/info ----------

#[tokio::test]
async fn info_returns_exactly_server_version_and_api_version() {
    assert_eq!(API_VERSION, 1, "the app's kApiVersion");
    let srv = TestServer::start().await;
    let r = get(&srv.url("/api/v1/info"), Some(&srv.bearer())).await;
    assert_eq!(r.status, 200, "{:?}", r.body);
    assert_eq!(
        r.json(),
        json!({ "server_version": env!("CARGO_PKG_VERSION"), "api_version": 1 })
    );
    assert!(
        r.header("content-type")
            .is_some_and(|ct| ct.starts_with("application/json")),
        "JSON content type: {:?}",
        r.header("content-type")
    );
}

// ---------- AC 8: unknown path ----------

#[tokio::test]
async fn unknown_path_with_the_token_is_404_not_found() {
    let srv = TestServer::start().await;
    let bearer = srv.bearer();
    for (method, path) in [
        (Method::GET, "/no/such/path"),
        (Method::GET, "/api/v2/info"),
        (Method::GET, "/api/v1/info/extra"),
        (Method::GET, "/api/v1/nope"),
        (Method::POST, "/no/such/path"),
        (Method::DELETE, "/nope"),
    ] {
        let r = send(&srv, &method, path, &None, Some(&bearer), &[]).await;
        assert_eq!(r.status, 404, "{method} {path}: {:?}", r.body);
        assert_eq!(r.c1_code(), "not_found", "{method} {path}");
    }
}

// ---------- AC 9: the status table, ApiError and the extractors ----------

#[test]
fn status_table_maps_every_c1_code_and_unlisted_codes_to_500() {
    let table: &[(&str, u16)] = &[
        ("not_found", 404),
        ("vault_not_found", 404),
        ("version_conflict", 409),
        ("title_conflict", 409),
        ("daily_note_exists", 409),
        ("name_conflict", 409),
        ("vault_exists", 409),
        ("invalid_argument", 400),
        ("invalid_vault_name", 400),
        ("invalid_utc_offset", 400),
        ("invalid_id", 400),
        ("invalid_date", 400),
        ("setting_invalid", 400),
        ("marker_rule", 422),
        ("role_rule", 422),
        ("pinned_rule", 422),
        ("depth_exceeded", 422),
        ("folder_cycle", 422),
        ("change_entries_invalid", 422),
        ("review_stale", 422),
        ("block_not_found", 422),
        ("unauthorized", 401),
        ("payload_too_large", 413),
        ("internal", 500),
        // Unlisted codes are 500; codes match exactly.
        ("bogus_code", 500),
        ("", 500),
        ("Not_Found", 500),
        (" not_found", 500),
        ("NOT_FOUND", 500),
    ];
    for (code, status) in table {
        assert_eq!(status_for_code(code).as_u16(), *status, "code {code:?}");
    }
}

async fn api_error_reply(err: ApiError) -> (u16, Option<String>, Value) {
    let resp = err.into_response();
    let status = resp.status().as_u16();
    let content_type = resp
        .headers()
        .get("content-type")
        .map(|v| v.to_str().unwrap().to_string());
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let body = serde_json::from_slice(&bytes)
        .unwrap_or_else(|e| panic!("ApiError body is JSON ({e}): {bytes:?}"));
    (status, content_type, body)
}

#[tokio::test]
async fn api_error_answers_the_c1_body_with_the_table_status() {
    let cases: Vec<(anyhow::Error, u16)> = vec![
        (
            MemexError::VersionConflict {
                expected: 3,
                current: 4,
            }
            .into(),
            409,
        ),
        (MemexError::NotFound("note 01J9".into()).into(), 404),
        (
            MemexError::PinnedRule {
                item: "folder".into(),
                name: "Inbox".into(),
            }
            .into(),
            422,
        ),
        (MemexError::InvalidDate("2026-13-01".into()).into(), 400),
        (
            anyhow::Error::new(MemexError::TitleConflict {
                existing_id: "01J9Z8Y7X6W5V4T3S2R1Q0P9N8".into(),
                attempted_title: "Dup".into(),
            })
            .context("save note"),
            409,
        ),
        (
            anyhow::Error::new(InvalidArgument("stdin was empty".into())),
            400,
        ),
        (anyhow::anyhow!("disk on fire").context("open vault"), 500),
    ];
    for (err, status) in cases {
        let want = error_json(&err);
        let label = format!("{err:#}");
        let (got_status, content_type, body) = api_error_reply(ApiError::from(err)).await;
        assert_eq!(got_status, status, "{label}");
        assert_eq!(body, want, "{label}: the body is cli::error_json's C1 body");
        assert!(
            content_type.is_some_and(|ct| ct.starts_with("application/json")),
            "{label}: JSON content type"
        );
    }
}

#[derive(Deserialize)]
struct WidgetBody {
    name: String,
    count: u32,
}

#[derive(Deserialize)]
struct LimitQuery {
    limit: u32,
}

/// A router built only from the extractors; every handler bumps `hits`.
fn extractor_router(hits: Arc<AtomicUsize>) -> Router {
    let (h1, h2, h3) = (hits.clone(), hits.clone(), hits);
    Router::new()
        .route(
            "/json",
            post_route(move |ApiJson(body): ApiJson<WidgetBody>| {
                let hits = h1.clone();
                async move {
                    hits.fetch_add(1, Ordering::SeqCst);
                    format!("{}:{}", body.name, body.count)
                }
            }),
        )
        .route(
            "/items/{n}",
            get_route(move |ApiPath(n): ApiPath<u32>| {
                let hits = h2.clone();
                async move {
                    hits.fetch_add(1, Ordering::SeqCst);
                    format!("item {n}")
                }
            }),
        )
        .route(
            "/query",
            get_route(move |ApiQuery(q): ApiQuery<LimitQuery>| {
                let hits = h3.clone();
                async move {
                    hits.fetch_add(1, Ordering::SeqCst);
                    format!("limit {}", q.limit)
                }
            }),
        )
}

#[tokio::test]
async fn extractor_rejections_are_400_invalid_argument_and_skip_the_handler() {
    let hits = Arc::new(AtomicUsize::new(0));
    let app = extractor_router(hits.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let url = |p: &str| format!("http://{addr}{p}");
    let http = client();

    let json_cases: Vec<(&str, Option<&str>, &str)> = vec![
        ("malformed JSON", Some("application/json"), "{not json"),
        (
            "wrong field type",
            Some("application/json"),
            r#"{"name": 3, "count": 1}"#,
        ),
        (
            "missing field",
            Some("application/json"),
            r#"{"name": "a"}"#,
        ),
        ("empty body", Some("application/json"), ""),
        ("no content type", None, r#"{"name": "a", "count": 1}"#),
        (
            "wrong content type",
            Some("text/plain"),
            r#"{"name": "a", "count": 1}"#,
        ),
    ];
    for (case, content_type, body) in json_cases {
        let mut req = http.post(url("/json")).body(body.to_string());
        if let Some(ct) = content_type {
            req = req.header("content-type", ct);
        }
        let r = Reply::read(req.send().await.unwrap()).await;
        assert_eq!(r.status, 400, "ApiJson {case}: {:?}", r.body);
        assert_eq!(r.c1_code(), "invalid_argument", "ApiJson {case}");
    }
    for path in [
        "/items/abc",
        "/items/-1",
        "/items/99999999999",
        "/items/1.5",
    ] {
        let r = Reply::read(http.get(url(path)).send().await.unwrap()).await;
        assert_eq!(r.status, 400, "ApiPath {path}: {:?}", r.body);
        assert_eq!(r.c1_code(), "invalid_argument", "ApiPath {path}");
    }
    for path in [
        "/query?limit=abc",
        "/query",
        "/query?limit=",
        "/query?limit=-3",
    ] {
        let r = Reply::read(http.get(url(path)).send().await.unwrap()).await;
        assert_eq!(r.status, 400, "ApiQuery {path}: {:?}", r.body);
        assert_eq!(r.c1_code(), "invalid_argument", "ApiQuery {path}");
    }
    assert_eq!(hits.load(Ordering::SeqCst), 0, "no handler ran");

    // Well-formed requests reach their handlers.
    let r = Reply::read(
        http.post(url("/json"))
            .json(&json!({ "name": "a", "count": 2 }))
            .send()
            .await
            .unwrap(),
    )
    .await;
    assert_eq!((r.status, r.body.as_str()), (200, "a:2"));
    let r = Reply::read(http.get(url("/items/7")).send().await.unwrap()).await;
    assert_eq!((r.status, r.body.as_str()), (200, "item 7"));
    let r = Reply::read(http.get(url("/query?limit=5")).send().await.unwrap()).await;
    assert_eq!((r.status, r.body.as_str()), (200, "limit 5"));
    assert_eq!(hits.load(Ordering::SeqCst), 3);
    task.abort();
}

// ---------- AC 10: body limit ----------

fn post_head(path: &str, authorization: Option<&str>, content_length: usize) -> String {
    let mut head = format!(
        "POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n\
         Content-Length: {content_length}\r\nConnection: close\r\n"
    );
    if let Some(value) = authorization {
        head.push_str(&format!("Authorization: {value}\r\n"));
    }
    head
}

#[tokio::test]
async fn body_over_8_mib_is_413_payload_too_large() {
    let srv = TestServer::start().await;
    let bearer = srv.bearer();
    for path in [
        "/no/such/path",
        "/api/v1/info",
        "/api/v1/vaults",
        "/vaults/x/mcp",
    ] {
        // Only the header is sent: the limit rejects on Content-Length.
        let r = raw_request(
            srv.addr(),
            &post_head(path, Some(&bearer), BODY_LIMIT + 1),
            b"",
        )
        .await;
        assert_eq!(r.status, 413, "POST {path} over the limit: {:?}", r.body);
        assert_eq!(r.c1_code(), "payload_too_large", "POST {path}");
    }
}

#[tokio::test]
async fn body_of_exactly_8_mib_is_not_rejected_by_the_limit() {
    assert_eq!(BODY_LIMIT, 8 * 1024 * 1024);
    let srv = TestServer::start().await;
    let body = vec![b' '; BODY_LIMIT];
    let r = raw_request(
        srv.addr(),
        &post_head("/no/such/path", Some(&srv.bearer()), BODY_LIMIT),
        &body,
    )
    .await;
    assert_eq!(r.status, 404, "reaches the fallback: {:?}", r.body);
    assert_eq!(r.c1_code(), "not_found");
}

#[tokio::test]
async fn tokenless_oversized_request_is_401_because_auth_runs_first() {
    let srv = TestServer::start().await;
    for (path, authorization) in [
        ("/no/such/path", None),
        ("/api/v1/vaults", None),
        ("/vaults/x/mcp", Some("Bearer wrong-token-5e6f7a8b")),
    ] {
        let r = raw_request(
            srv.addr(),
            &post_head(path, authorization, BODY_LIMIT + 1),
            b"",
        )
        .await;
        assert_eq!(r.status, 401, "POST {path}: {:?}", r.body);
        assert_eq!(r.c1_code(), "unauthorized", "POST {path}");
    }
}

// ---------- AC 11: no CORS ----------

#[tokio::test]
async fn no_response_carries_cors_headers() {
    let srv = TestServer::start().await;
    let bearer = srv.bearer();
    let origin = vec![
        ("origin", "http://evil.example".to_string()),
        ("access-control-request-method", "GET".to_string()),
        (
            "access-control-request-headers",
            "authorization".to_string(),
        ),
    ];
    let cases: Vec<(&str, Method, &str, Option<&str>, u16)> = vec![
        (
            "authenticated GET info",
            Method::GET,
            "/api/v1/info",
            Some(&bearer),
            200,
        ),
        ("tokenless GET info", Method::GET, "/api/v1/info", None, 401),
        (
            "tokenless preflight",
            Method::OPTIONS,
            "/api/v1/info",
            None,
            401,
        ),
        (
            "tokenless preflight, vault MCP",
            Method::OPTIONS,
            "/vaults/x/mcp",
            None,
            401,
        ),
        (
            "authenticated unknown path",
            Method::GET,
            "/nope",
            Some(&bearer),
            404,
        ),
    ];
    for (case, method, path, authorization, status) in cases {
        let r = send(&srv, &method, path, &None, authorization, &origin).await;
        assert_eq!(r.status, status, "{case}: {:?}", r.body);
        let cors: Vec<&(String, String)> = r
            .headers
            .iter()
            .filter(|(k, _)| k.starts_with("access-control-"))
            .collect();
        assert!(cors.is_empty(), "{case}: no CORS headers, got {cors:?}");
    }

    // An authenticated preflight is never approved.
    let r = send(
        &srv,
        &Method::OPTIONS,
        "/api/v1/info",
        &None,
        Some(&bearer),
        &origin,
    )
    .await;
    assert!(
        !(200..300).contains(&r.status),
        "authenticated preflight is not a CORS success: {}",
        r.status
    );
    let cors: Vec<&(String, String)> = r
        .headers
        .iter()
        .filter(|(k, _)| k.starts_with("access-control-"))
        .collect();
    assert!(cors.is_empty(), "authenticated preflight: {cors:?}");
    // The probe above really reached the server.
    assert_eq!(
        get(&srv.url("/api/v1/info"), Some(&bearer)).await.status,
        200
    );
}
