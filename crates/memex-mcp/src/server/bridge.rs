//! `memex serve --remote <server-url>/vaults/<name>/mcp`: the stdio bridge
//! to a hosted vault's `/mcp` (req 27, 28, 59; D3, D6).
//!
//! `cli::serve` validates the URL, reads the token from
//! `MEMEX_ACCESS_TOKEN` and calls [`run`] with the process's stdin and
//! stdout and a `SystemClock`.

use tokio::io::{AsyncRead, AsyncWrite};

use super::request_clock::SharedClock;

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

/// Runs the startup preflight, then forwards every MCP message read from
/// `input` to the hosted vault and writes each reply to `output`, until
/// `input` ends (`Ok`) or the server answers 401 (`Err`, C1 `unauthorized`).
pub async fn run<R, W>(options: BridgeOptions, input: R, output: W) -> anyhow::Result<()>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let _ = (options, input, output);
    crate::cli::not_implemented("serve --remote")
}
