//! `memex serve --remote <server-url>/vaults/<name>/mcp`: the stdio bridge
//! to a hosted vault's `/mcp` (req 27, 28, 59; D3, D6).
//!
//! `cli::serve` validates the URL, reads the token from
//! `MEMEX_ACCESS_TOKEN` and calls [`run`] with the process's stdin and
//! stdout and a `SystemClock`.
//!
//! The vault server's `/mcp` is stateless and answers each POST with one
//! JSON body (#80), so the bridge is a plain forwarder: every
//! newline-delimited JSON-RPC message read from the client is POSTed on its
//! own, and every message in the reply is written back as one line. Each
//! POST builds its headers afresh, so `X-Memex-UTC-Offset` follows the
//! machine's offset across daylight saving and time-zone moves (D6).
//!
//! Each run makes one ULID session id, sent as `X-Memex-Agent-Session` on
//! every request; once the client's `initialize` names its `clientInfo`,
//! `X-Memex-Agent-Client: <name>/<version>` goes with every request too.
//! After that `initialize`, and while the input is open, the bridge `ping`s
//! the vault every [`Heartbeat::interval`] to keep its agent presence alive
//! (#390 req 2a). Ping replies and failures never reach the output.
//!
//! Nothing here logs, and no message names the token.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use reqwest::header::{HeaderValue, ACCEPT, AUTHORIZATION, CONTENT_TYPE};
use reqwest::{RequestBuilder, Response, StatusCode, Url};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tokio::task::JoinSet;
use tokio::time::{Instant, MissedTickBehavior};
use ulid::Ulid;

use memex_core::agents::presence::HEARTBEAT_MS;

use super::registry::validate_vault_name;
use super::request_clock::SharedClock;
use crate::caller_tz::format_utc_offset;
use crate::cli::{CodedError, InvalidArgument};

/// The header carrying this machine's current UTC offset (D5).
const OFFSET_HEADER: &str = "x-memex-utc-offset";

/// The header carrying this bridge run's ULID session id (#390 P3).
const SESSION_HEADER: &str = "x-memex-agent-session";

/// The header carrying the client's `<name>/<version>` (#390 P3).
const CLIENT_HEADER: &str = "x-memex-agent-client";

/// The prefix of every heartbeat `ping` id. Ping ids are JSON strings the
/// bridge makes itself, and their replies are consumed by the heartbeat, so
/// a client's id never meets one on the output.
const PING_ID_PREFIX: &str = "memex-bridge-ping-";

/// What an MCP streamable-HTTP client accepts on a POST.
const MCP_ACCEPT: &str = "application/json, text/event-stream";

/// How long the bridge waits to connect to the vault server.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// JSON-RPC: the line from the client is not JSON.
const PARSE_ERROR: i64 = -32700;

/// JSON-RPC: the vault server could not be reached for this message.
const UNREACHABLE_ERROR: i64 = -32000;

/// JSON-RPC: the vault server answered with something that is not a reply.
const INTERNAL_ERROR: i64 = -32603;

/// What the bridge runs with.
pub struct BridgeOptions {
    /// The hosted vault's MCP URL, `<server-url>/vaults/<name>/mcp`.
    pub url: String,
    /// The access token sent as `Authorization: Bearer <token>`.
    pub token: String,
    /// The clock whose current UTC offset each request's
    /// `X-Memex-UTC-Offset` carries, read again for every request.
    pub clock: SharedClock,
}

/// How often the bridge pings the vault server to keep its agent presence
/// alive (#390 req 2a). Kept apart from [`BridgeOptions`] so that struct's
/// existing literals keep compiling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Heartbeat {
    /// The time between two `ping` requests.
    pub interval: Duration,
}

impl Default for Heartbeat {
    /// One `ping` every `HEARTBEAT_MS` (5 s).
    fn default() -> Self {
        Self {
            interval: Duration::from_millis(HEARTBEAT_MS as u64),
        }
    }
}

/// Where the bridge sends its requests, from a checked `--remote` URL.
#[derive(Debug, Clone)]
struct Target {
    /// `<server-url>/vaults/<name>/mcp`.
    mcp: Url,
    /// `<server-url>/vaults/<name>/api/v1/info`, the preflight.
    info: Url,
    /// `<scheme>://<host>[:<port>]`, for messages.
    origin: String,
    /// The vault name.
    vault: String,
}

/// Checks a `--remote` URL: `http` or `https`, a host, no credentials,
/// query or fragment, and a path of exactly `/vaults/<name>/mcp` with a
/// valid vault name. The error says what is wrong (clap shows it).
pub fn check_remote_url(raw: &str) -> Result<(), String> {
    target(raw).map(|_| ())
}

fn target(raw: &str) -> Result<Target, String> {
    const SHAPE: &str = "expected <server-url>/vaults/<name>/mcp";
    let url = Url::parse(raw).map_err(|e| format!("not a URL ({e}); {SHAPE}"))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(format!("the URL must be http or https; {SHAPE}"));
    }
    if url.host_str().is_none_or(str::is_empty) {
        return Err(format!("the URL has no host; {SHAPE}"));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err("the URL must not carry credentials; set MEMEX_ACCESS_TOKEN instead".into());
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err(format!(
            "the URL must not have a query or fragment; {SHAPE}"
        ));
    }
    let vault = url
        .path()
        .strip_prefix("/vaults/")
        .and_then(|rest| rest.strip_suffix("/mcp"))
        .filter(|name| validate_vault_name(name).is_ok())
        .ok_or_else(|| format!("the path must be exactly /vaults/<name>/mcp; {SHAPE}"))?
        .to_string();
    let mut info = url.clone();
    info.set_path(&format!("/vaults/{vault}/api/v1/info"));
    Ok(Target {
        origin: url.origin().ascii_serialization(),
        mcp: url,
        info,
        vault,
    })
}

/// The HTTP side of the bridge: one client, the target, the token header,
/// the clock and the agent identity headers.
struct Upstream {
    http: reqwest::Client,
    target: Target,
    authorization: HeaderValue,
    clock: SharedClock,
    /// This run's ULID, the `X-Memex-Agent-Session` value.
    session: HeaderValue,
    /// The `X-Memex-Agent-Client` value from the client's latest
    /// `initialize`; none before it, or when it names no valid one.
    client: RwLock<Option<HeaderValue>>,
}

impl Upstream {
    /// `builder` with `Authorization`, this instant's `X-Memex-UTC-Offset`,
    /// read from the clock now, and the agent identity headers.
    fn headers(&self, builder: RequestBuilder) -> RequestBuilder {
        let offset = format_utc_offset(self.clock.utc_offset_at(self.clock.now_ms()));
        let builder = builder
            .header(AUTHORIZATION, self.authorization.clone())
            .header(OFFSET_HEADER, offset)
            .header(SESSION_HEADER, self.session.clone());
        let client = self
            .client
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        match client {
            Some(client) => builder.header(CLIENT_HEADER, client),
            None => builder,
        }
    }

    /// Records the client identity of `message` when it is (or a batch
    /// holding) an `initialize` request. True when it is one.
    fn note_initialize(&self, message: &Value) -> bool {
        let init = match message {
            Value::Array(batch) => batch.iter().find(|m| is_initialize(m)),
            m => Some(m).filter(|m| is_initialize(m)),
        };
        let Some(init) = init else {
            return false;
        };
        let client = client_header(&init["params"]["clientInfo"]);
        *self.client.write().unwrap_or_else(|e| e.into_inner()) = client;
        true
    }

    /// The startup preflight: `GET /vaults/<name>/api/v1/info`.
    async fn preflight(&self) -> anyhow::Result<()> {
        let resp = self
            .headers(self.http.get(self.target.info.clone()))
            .send()
            .await
            .map_err(|_| self.unreachable())?;
        match resp.status() {
            s if s.is_success() => Ok(()),
            StatusCode::UNAUTHORIZED => Err(self.unauthorized()),
            StatusCode::NOT_FOUND => Err(CodedError::new(
                "vault_not_found",
                format!(
                    "the vault server at {} has no vault named {}",
                    self.target.origin, self.target.vault
                ),
            )
            .into()),
            status => {
                let body = resp.bytes().await.unwrap_or_default();
                let c1 = serde_json::from_slice::<Value>(&body).ok();
                let code = c1
                    .as_ref()
                    .and_then(|v| v["error"]["code"].as_str())
                    .unwrap_or("internal")
                    .to_string();
                Err(CodedError::new(
                    code,
                    format!(
                        "the vault server at {} answered the preflight with HTTP {}",
                        self.target.origin,
                        status.as_u16()
                    ),
                )
                .into())
            }
        }
    }

    /// POSTs one client line to `/mcp`.
    async fn post(&self, line: String) -> reqwest::Result<Response> {
        self.headers(self.http.post(self.target.mcp.clone()))
            .header(CONTENT_TYPE, "application/json")
            .header(ACCEPT, MCP_ACCEPT)
            .body(line)
            .send()
            .await
    }

    /// One heartbeat: POSTs a `ping` with the bridge-private id `id` and
    /// reads its reply, which goes nowhere. Every failure is ignored.
    async fn ping(&self, id: u64) {
        let body = json!({
            "jsonrpc": "2.0",
            "method": "ping",
            "id": format!("{PING_ID_PREFIX}{id}"),
        });
        if let Ok(resp) = self.post(body.to_string()).await {
            let _ = resp.bytes().await;
        }
    }

    fn unreachable(&self) -> anyhow::Error {
        CodedError::new(
            "server_unreachable",
            format!("can't reach the vault server at {}", self.target.origin),
        )
        .into()
    }

    fn unauthorized(&self) -> anyhow::Error {
        CodedError::new(
            "unauthorized",
            format!(
                "the vault server at {} rejected the access token in MEMEX_ACCESS_TOKEN",
                self.target.origin
            ),
        )
        .into()
    }
}

/// Runs the startup preflight, then forwards every MCP message read from
/// `input` to the hosted vault and writes each reply to `output`, until
/// `input` ends (`Ok`) or the server answers 401 (`Err`, C1 `unauthorized`).
///
/// A message the server can't be reached for is answered with a JSON-RPC
/// error carrying the same `id`, and the bridge keeps running.
pub async fn run<R, W>(options: BridgeOptions, input: R, output: W) -> anyhow::Result<()>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    run_with(options, Heartbeat::default(), input, output).await
}

/// [`run`] with the heartbeat `heartbeat` instead of the default one.
pub async fn run_with<R, W>(
    options: BridgeOptions,
    heartbeat: Heartbeat,
    input: R,
    output: W,
) -> anyhow::Result<()>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let target = target(&options.url).map_err(InvalidArgument)?;
    let mut authorization = HeaderValue::try_from(format!("Bearer {}", options.token))
        .map_err(|_| InvalidArgument("MEMEX_ACCESS_TOKEN is not a valid header value".into()))?;
    authorization.set_sensitive(true);
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(CONNECT_TIMEOUT)
        .build()?;
    let upstream = Arc::new(Upstream {
        http,
        target,
        authorization,
        clock: options.clock,
        session: HeaderValue::try_from(Ulid::new().to_string())?,
        client: RwLock::new(None),
    });
    upstream.preflight().await?;

    let (out_tx, out_rx) = mpsc::unbounded_channel::<String>();
    let writer = tokio::spawn(write_lines(output, out_rx));
    let (fatal_tx, mut fatal_rx) = mpsc::channel::<anyhow::Error>(1);
    let mut tasks = JoinSet::new();
    let mut lines = BufReader::new(input).lines();
    let mut pinger: Option<tokio::task::JoinHandle<()>> = None;

    let ended = loop {
        tokio::select! {
            biased;
            Some(err) = fatal_rx.recv() => break Err(err),
            Some(_) = tasks.join_next(), if !tasks.is_empty() => {}
            line = lines.next_line() => match line {
                Ok(Some(line)) => {
                    if line.trim().is_empty() {
                        continue;
                    }
                    // Read the client's identity before forwarding, so the
                    // `initialize` and every line behind it carry it.
                    let message = serde_json::from_str::<Value>(&line).ok();
                    let initialize = message
                        .as_ref()
                        .is_some_and(|m| upstream.note_initialize(m));
                    tasks.spawn(forward(
                        upstream.clone(),
                        line,
                        message,
                        out_tx.clone(),
                        fatal_tx.clone(),
                    ));
                    if initialize && pinger.is_none() {
                        pinger = Some(tokio::spawn(heartbeat_loop(
                            upstream.clone(),
                            heartbeat.interval,
                        )));
                    }
                }
                Ok(None) => break Ok(()),
                Err(e) => break Err(anyhow::Error::new(e).context("read MCP input")),
            },
        }
    };

    // Input ended (or the bridge is stopping): no further ping.
    if let Some(pinger) = pinger {
        pinger.abort();
        let _ = pinger.await;
    }

    if let Err(err) = ended {
        // A 401 or a broken input: stop now, with what is already written.
        tasks.abort_all();
        writer.abort();
        return Err(err);
    }

    // Input ended: let the messages in flight be answered first.
    drop(fatal_tx);
    while tasks.join_next().await.is_some() {}
    if let Ok(err) = fatal_rx.try_recv() {
        writer.abort();
        return Err(err);
    }
    drop(out_tx);
    match writer.await {
        Ok(written) => written.map_err(|e| anyhow::Error::new(e).context("write MCP output")),
        Err(e) => Err(anyhow::Error::new(e).context("write MCP output")),
    }
}

/// Pings the vault every `interval`, the first one `interval` from now,
/// until aborted. Each ping runs on its own, so a slow one never delays
/// the next; one still unanswered after `interval` is dropped.
async fn heartbeat_loop(upstream: Arc<Upstream>, interval: Duration) {
    let mut ticks = tokio::time::interval_at(Instant::now() + interval, interval);
    ticks.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let next_id = AtomicU64::new(1);
    let mut pings = JoinSet::new();
    loop {
        tokio::select! {
            Some(_) = pings.join_next(), if !pings.is_empty() => {}
            _ = ticks.tick() => {
                let upstream = upstream.clone();
                let id = next_id.fetch_add(1, Ordering::Relaxed);
                pings.spawn(async move {
                    let _ = tokio::time::timeout(interval, upstream.ping(id)).await;
                });
            }
        }
    }
}

/// An `initialize` request.
fn is_initialize(message: &Value) -> bool {
    message.get("method").and_then(Value::as_str) == Some("initialize")
        && message.get("id").is_some()
}

/// The `X-Memex-Agent-Client` value for `client_info`: `<name>/<version>`
/// when both are strings and the result is visible ASCII (`0x20..=0x7E`);
/// otherwise none, and the server names the client from its User-Agent.
fn client_header(client_info: &Value) -> Option<HeaderValue> {
    let name = client_info.get("name")?.as_str()?;
    let version = client_info.get("version")?.as_str()?;
    let value = format!("{name}/{version}");
    if !value.bytes().all(|b| (0x20..=0x7e).contains(&b)) {
        return None;
    }
    HeaderValue::from_str(&value).ok()
}

/// Writes each line to `output`, flushed, until every sender is gone.
async fn write_lines<W>(
    mut output: W,
    mut lines: mpsc::UnboundedReceiver<String>,
) -> std::io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    while let Some(line) = lines.recv().await {
        output.write_all(line.as_bytes()).await?;
        output.write_all(b"\n").await?;
        output.flush().await?;
    }
    output.flush().await
}

/// Forwards one client line (`message` is it parsed, none when it is not
/// JSON) and writes the reply's messages to `out`. A 401
/// goes to `fatal`; an unreachable server or an answer that is no reply
/// becomes a JSON-RPC error for each request `id` in the line.
async fn forward(
    upstream: Arc<Upstream>,
    line: String,
    message: Option<Value>,
    out: mpsc::UnboundedSender<String>,
    fatal: mpsc::Sender<anyhow::Error>,
) {
    let Some(message) = message else {
        let _ = out.send(rpc_error(
            &Value::Null,
            PARSE_ERROR,
            "parse error: not JSON",
            None,
        ));
        return;
    };
    let ids = request_ids(&message);
    let fail = |code: i64, text: &str, c1: Option<&str>| {
        for id in &ids {
            let _ = out.send(rpc_error(id, code, text, c1));
        }
    };

    let unreachable = format!("can't reach the vault server at {}", upstream.target.origin);
    let resp = match upstream.post(line).await {
        Ok(resp) => resp,
        Err(_) => return fail(UNREACHABLE_ERROR, &unreachable, Some("server_unreachable")),
    };
    let status = resp.status();
    if status == StatusCode::UNAUTHORIZED {
        let _ = fatal.send(upstream.unauthorized()).await;
        return;
    }
    let event_stream = resp
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.starts_with("text/event-stream"));
    let Ok(body) = resp.bytes().await else {
        return fail(UNREACHABLE_ERROR, &unreachable, Some("server_unreachable"));
    };

    let replies = if event_stream {
        sse_messages(&body)
    } else {
        serde_json::from_slice::<Value>(&body)
            .ok()
            .filter(is_rpc)
            .into_iter()
            .collect()
    };
    if !replies.is_empty() {
        for reply in replies {
            let _ = out.send(reply.to_string());
        }
        return;
    }
    if status.is_success() {
        // A notification or a client response is answered 202 with no body;
        // a request needs a reply.
        return fail(
            INTERNAL_ERROR,
            "the vault server sent no JSON-RPC reply",
            None,
        );
    }
    let c1 = serde_json::from_slice::<Value>(&body).ok();
    let c1_code = c1.as_ref().and_then(|v| v["error"]["code"].as_str());
    let text = match c1.as_ref().and_then(|v| v["error"]["message"].as_str()) {
        Some(message) => format!(
            "the vault server answered HTTP {}: {message}",
            status.as_u16()
        ),
        None => format!("the vault server answered HTTP {}", status.as_u16()),
    };
    fail(INTERNAL_ERROR, &text, c1_code);
}

/// The `id` of every request in `message` (one object or a batch).
/// Notifications and responses have none to answer.
fn request_ids(message: &Value) -> Vec<Value> {
    let one = |m: &Value| match (m.get("method"), m.get("id")) {
        (Some(_), Some(id)) => Some(id.clone()),
        _ => None,
    };
    match message {
        Value::Array(batch) => batch.iter().filter_map(one).collect(),
        m => one(m).into_iter().collect(),
    }
}

/// A JSON-RPC message or batch.
fn is_rpc(v: &Value) -> bool {
    match v {
        Value::Array(batch) => {
            !batch.is_empty() && batch.iter().all(|m| m.get("jsonrpc").is_some())
        }
        m => m.get("jsonrpc").is_some(),
    }
}

/// The JSON-RPC messages in an SSE body: each event's `data` lines.
fn sse_messages(body: &[u8]) -> Vec<Value> {
    let text = String::from_utf8_lossy(body);
    let mut messages = Vec::new();
    let mut data = String::new();
    let mut flush = |data: &mut String| {
        if let Ok(v) = serde_json::from_str::<Value>(data) {
            if is_rpc(&v) {
                messages.push(v);
            }
        }
        data.clear();
    };
    for line in text.lines() {
        if line.is_empty() {
            flush(&mut data);
        } else if let Some(rest) = line.strip_prefix("data:") {
            if !data.is_empty() {
                data.push('\n');
            }
            data.push_str(rest.strip_prefix(' ').unwrap_or(rest));
        }
    }
    flush(&mut data);
    messages
}

/// A JSON-RPC error response to `id`, as one line. `c1` is the C1 code,
/// when there is one, in `error.data.code`.
fn rpc_error(id: &Value, code: i64, message: &str, c1: Option<&str>) -> String {
    let mut error = json!({ "code": code, "message": message });
    if let Some(c1) = c1 {
        error["data"] = json!({ "code": c1 });
    }
    json!({ "jsonrpc": "2.0", "id": id, "error": error }).to_string()
}
