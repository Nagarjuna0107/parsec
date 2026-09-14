//! `parsec login` — the loopback browser handoff that turns "get a key from
//! the dashboard, then paste it into a terminal" into one click.
//!
//! The shape is the gcloud / Vercel CLI pattern:
//!
//! 1. Bind an ephemeral listener on 127.0.0.1 and mint a random `state`.
//! 2. Open `<dashboard>/connect?port=…&state=…&host=…` in the browser. The
//!    user signs in there (GitHub via Supabase — nothing new server-side),
//!    confirms the machine name, and the page mints a `psc_` key through the
//!    same BFF route the account page uses.
//! 3. The page POSTs `{state, key}` as a plain HTML form to
//!    `http://127.0.0.1:<port>/callback`. A top-level form navigation is the
//!    one browser mechanism that needs no CORS, no private-network-access
//!    preflight, and — because loopback is a potentially-trustworthy origin —
//!    no mixed-content warning. The key rides in the body, not the URL, so it
//!    never lands in browser history.
//! 4. We check `state`, store the key exactly the way `parsec key set` does,
//!    answer the form POST with a `303 See Other` to
//!    `<dashboard>/?connected=<host>&login=<state>` so the browser lands in
//!    the app with the machine already linked, and exit. Only the failure
//!    branches (bad state, store failed) render a local page — there is
//!    nothing in the app to show for those (docs/install-first-signup.md).
//!
//! The key crosses browser → loopback on the user's own machine; nothing
//! here routes through our cloud beyond the mint the dashboard already does
//! (DIRECTION: data plane local, control plane ours).
//!
//! Threat model. Any web page can navigate the user's browser to a loopback
//! URL, so an attacker who could guess `state` could plant *their* key and
//! silently redirect this machine's savings to their account. `state` is 256
//! random bits, checked once, consumed on success. `Host` must be loopback
//! (DNS-rebinding guard) and `Origin`, when the browser sends a concrete
//! one, must be the dashboard — an https → http navigation serialises it as
//! `null` under the default referrer policy, so `null` is not a refusal
//! (see `origin_ok`). The listener lives only for the length of one login.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::{any, post};
use axum::{Form, Router};
use serde::Deserialize;
use tokio::sync::{oneshot, Notify};

/// How long the listener stays up after a successful handoff, answering a
/// duplicate submit from the same tab with the same redirect (see `run_async`).
const REPLAY_GRACE: Duration = Duration::from_secs(3);

/// `parsec login` options (clap-populated in main.rs).
pub struct Options {
    /// Print the URL instead of opening a browser (SSH, WSL without a
    /// browser bridge, containers — the URL still works from any browser on
    /// the same machine, since the callback is loopback).
    pub no_browser: bool,
    /// Give up after this long with no callback.
    pub timeout: Duration,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            no_browser: false,
            timeout: Duration::from_secs(300),
        }
    }
}

/// What the dashboard posts back. Field names are the contract with
/// `packages/frontend/src/components/connect-machine.tsx`.
#[derive(Debug, Deserialize)]
pub struct Callback {
    pub state: String,
    pub key: String,
}

/// Outcome delivered to the waiting CLI once the callback has been handled.
#[derive(Debug)]
pub enum Outcome {
    /// Key stored; carries the masked key for the confirmation line.
    Saved { masked: String },
    /// Callback arrived and matched, but the credentials write failed.
    StoreFailed(String),
}

/// Per-login listener state. `done` is a one-shot: the first matching
/// callback takes the sender, so a replayed POST can never re-store.
pub struct Handoff {
    state: String,
    dashboard: String,
    host: String,
    done: Mutex<Option<oneshot::Sender<Outcome>>>,
    shutdown: Arc<Notify>,
}

/// 32 bytes from the OS CSPRNG, hex — the CSRF token for one login.
pub fn new_state() -> anyhow::Result<String> {
    let mut buf = [0u8; 32];
    getrandom::fill(&mut buf).map_err(|e| anyhow::anyhow!("os rng unavailable: {e}"))?;
    Ok(buf.iter().map(|b| format!("{b:02x}")).collect())
}

/// This machine's name as the dashboard shows it ("connect `studio`?").
/// macOS appends `.local`; that is noise to a human, so it is trimmed.
pub fn machine_name() -> String {
    let raw = gethostname::gethostname().to_string_lossy().into_owned();
    let name = raw.trim().trim_end_matches(".local").to_string();
    if name.is_empty() {
        "this machine".to_string()
    } else {
        name
    }
}

/// The URL the browser opens. Query-encoded by hand: the three values are
/// already URL-safe except `host`, which is percent-encoded minimally.
pub fn connect_url(dashboard: &str, port: u16, state: &str, host: &str) -> String {
    format!(
        "{}/connect?port={port}&state={state}&host={}",
        dashboard.trim_end_matches('/'),
        percent_encode(host)
    )
}

/// Where the browser goes once the key is stored: the dashboard root, which
/// greets the just-connected machine. `connected` is only a hint for that
/// first greeting (later visits read the installs table); `login` is the
/// consumed `state`, which the dashboard uses to drop the key the connect
/// page parked in sessionStorage so a Back navigation cannot re-submit it
/// to a listener that has already shut down. Neither value is secret at
/// this point: `state` is single-use and already spent.
pub fn landing_url(dashboard: &str, host: &str, state: &str) -> String {
    format!(
        "{}/?connected={}&login={state}",
        dashboard.trim_end_matches('/'),
        percent_encode(host)
    )
}

fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Build the one-login router. Exposed so tests drive it in-process.
pub fn router(handoff: Arc<Handoff>) -> Router {
    Router::new()
        .route("/callback", post(callback))
        .fallback(any(not_found))
        .with_state(handoff)
}

pub fn handoff(
    state: String,
    dashboard: String,
    host: String,
) -> (Arc<Handoff>, oneshot::Receiver<Outcome>, Arc<Notify>) {
    let (tx, rx) = oneshot::channel();
    let shutdown = Arc::new(Notify::new());
    let h = Arc::new(Handoff {
        state,
        dashboard,
        host,
        done: Mutex::new(Some(tx)),
        shutdown: shutdown.clone(),
    });
    (h, rx, shutdown)
}

/// Loopback-only `Host` (the listener binds 127.0.0.1, but a DNS-rebound
/// name resolving there would carry a foreign Host — refuse it).
fn host_is_loopback(headers: &HeaderMap) -> bool {
    let Some(host) = headers.get(header::HOST).and_then(|v| v.to_str().ok()) else {
        return false;
    };
    let name = host.rsplit_once(':').map_or(host, |(h, _)| h);
    matches!(name, "127.0.0.1" | "localhost" | "[::1]")
}

/// When the browser sends a concrete `Origin`, it must be the dashboard.
/// Absent is tolerated (curl, the tests), and so is the literal `null`: the
/// Fetch spec serialises the origin of an https → http form navigation as
/// `null` under the default `strict-origin-when-cross-origin` policy — the
/// target's *scheme* is what counts, loopback or not — so a handoff from
/// https://app.getparsec.ai arrives as `Origin: null` unless the page opts
/// into a sending policy (the connect page sets `referrer: origin`; seen on
/// Chrome 153, 2026-09-12, where refusing `null` broke every real login).
/// `state` is what authenticates the callback; this check only turns away a
/// page that announces a foreign origin.
fn origin_ok(headers: &HeaderMap, dashboard: &str) -> bool {
    match headers.get(header::ORIGIN).and_then(|v| v.to_str().ok()) {
        None => true,
        Some(o) => {
            let o = o.trim();
            o == "null" || o.trim_end_matches('/') == dashboard.trim_end_matches('/')
        }
    }
}

async fn callback(
    State(h): State<Arc<Handoff>>,
    headers: HeaderMap,
    Form(cb): Form<Callback>,
) -> Response {
    if !host_is_loopback(&headers) {
        return page(
            StatusCode::FORBIDDEN,
            "Refused",
            "Callback must arrive over loopback.",
            &h,
        );
    }
    if !origin_ok(&headers, &h.dashboard) {
        return page(
            StatusCode::FORBIDDEN,
            "Refused",
            "This callback did not come from the parsec dashboard.",
            &h,
        );
    }
    if cb.state != h.state {
        return page(
            StatusCode::FORBIDDEN,
            "Refused",
            "Sign-in state did not match. Run <code>parsec login</code> again and use the tab it opens.",
            &h,
        );
    }
    let key = cb.key.trim().to_string();
    if key.is_empty() || !key.starts_with("psc_") {
        return page(
            StatusCode::BAD_REQUEST,
            "Refused",
            "No API key in the callback. Run <code>parsec login</code> again.",
            &h,
        );
    }
    // One-shot: take the sender under the lock so two racing callbacks
    // cannot both store. A second POST with the *right* state is the same
    // browser submitting twice (the connect page auto-submits, and a human
    // can click too — seen on the first real-machine run, where the second
    // POST met a closed port and Chrome showed "site cannot be reached").
    // Nothing is stored again; it just goes where the first one went.
    let Some(tx) = h.done.lock().ok().and_then(|mut g| g.take()) else {
        return signed_in(&h);
    };
    // Credentials write + install re-report use blocking I/O (reqwest's
    // blocking client), which must not run on the async worker.
    let stored = tokio::task::spawn_blocking(move || crate::setup::save_account_key(&key, None))
        .await
        .map_err(|e| anyhow::anyhow!("save task panicked: {e}"))
        .and_then(|r| r);
    match &stored {
        Ok(masked) => {
            let _ = tx.send(Outcome::Saved {
                masked: masked.clone(),
            });
            // No shutdown from here: the CLI keeps the listener up for a
            // short grace period (run_async) so a duplicate submit from the
            // same tab gets this same redirect instead of a closed port.
            signed_in(&h)
        }
        Err(e) => {
            let _ = tx.send(Outcome::StoreFailed(e.to_string()));
            // Let axum flush this response first; graceful shutdown waits.
            h.shutdown.notify_one();
            page(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Could not save the key",
                &format!(
                    "parsec received the key but could not write it: {}. \
                     Run <code>parsec key set &lt;key&gt;</code> from the account page instead.",
                    escape(&e.to_string())
                ),
                &h,
            )
        }
    }
}

/// The success response: a top-level navigation from the loopback origin to
/// the dashboard (`303 See Other`, so the browser re-requests with GET and
/// the form body is not replayed). Pure — tests check the redirect without
/// touching credentials.
fn signed_in(h: &Handoff) -> Response {
    Redirect::to(&landing_url(&h.dashboard, &h.host, &h.state)).into_response()
}

async fn not_found(State(h): State<Arc<Handoff>>) -> Response {
    page(
        StatusCode::NOT_FOUND,
        "parsec login",
        "This is the local sign-in listener for <code>parsec login</code>. Nothing to see here.",
        &h,
    )
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// The tiny page the browser lands on. Self-contained (no assets — the
/// listener is gone a moment later) with a link back to the dashboard.
fn page(status: StatusCode, title: &str, body_html: &str, h: &Handoff) -> Response {
    let html = format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
         <title>parsec · {title}</title>\
         <style>\
         :root{{color-scheme:light dark}}\
         body{{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;\
         font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;\
         background:#0f1115;color:#e6e8eb;padding:24px}}\
         @media (prefers-color-scheme:light){{body{{background:#f7f7f5;color:#1a1c1f}}}}\
         main{{max-width:28rem}}h1{{font-size:1.25rem;margin:0 0 .5rem}}\
         h1 span{{color:#39ff88}}p{{margin:0 0 1rem}}a{{color:#39ff88}}\
         code{{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em}}\
         </style></head><body><main>\
         <h1><span>❯</span> {title}</h1><p>{body_html}</p>\
         <p><a href=\"{dash}\">Open your dashboard</a></p>\
         </main></body></html>",
        dash = escape(&h.dashboard),
    );
    (status, Html(html)).into_response()
}

/// Open `url` in the user's default browser. Best-effort and silent: the
/// URL is always printed, so a failure here costs the user one paste.
pub fn open_browser(url: &str) -> bool {
    use std::process::{Command, Stdio};
    let quiet = |mut c: Command| {
        c.stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    };
    if cfg!(target_os = "macos") {
        let mut c = Command::new("open");
        c.arg(url);
        return quiet(c);
    }
    if cfg!(windows) {
        // rundll32 takes the URL as one argument, so `&` in the query string
        // survives — `cmd /c start` would need cmd-level quoting.
        let mut c = Command::new("rundll32");
        c.arg("url.dll,FileProtocolHandler").arg(url);
        return quiet(c);
    }
    // Linux / WSL: wslview bridges to the Windows browser when present.
    for bin in ["wslview", "xdg-open"] {
        let mut c = Command::new(bin);
        c.arg(url);
        if quiet(c) {
            return true;
        }
    }
    false
}

/// `parsec login` entry point: blocks until the browser hands a key back,
/// the timeout elapses, or Ctrl-C.
pub fn run(opts: Options) -> anyhow::Result<()> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    rt.block_on(run_async(opts))
}

async fn run_async(opts: Options) -> anyhow::Result<()> {
    let dashboard = crate::apikey::dashboard_url();
    let state = new_state()?;
    let host = machine_name();
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await?;
    let port = listener.local_addr()?.port();
    let url = connect_url(&dashboard, port, &state, &host);

    let (h, rx, shutdown) = handoff(state, dashboard.clone(), host.clone());
    let serve = axum::serve(listener, router(h)).with_graceful_shutdown({
        let shutdown = shutdown.clone();
        async move { shutdown.notified().await }
    });
    // `with_graceful_shutdown` is IntoFuture, not Future — wrap for spawn.
    let server = tokio::spawn(async move { serve.await });

    if let Some(existing) = crate::apikey::account_key() {
        println!(
            "note: an API key is already configured ({}); signing in will replace it.",
            crate::credentials::mask(&existing)
        );
    }
    let opened = !opts.no_browser && open_browser(&url);
    if opened {
        println!("Opening your browser to sign in to parsec…");
        println!("If it did not open, visit:\n\n  {url}\n");
    } else {
        println!("Open this URL in a browser on this machine to sign in:\n\n  {url}\n");
    }
    println!(
        "Waiting for the dashboard to hand back your key (up to {}s; Ctrl-C to cancel)…",
        opts.timeout.as_secs()
    );

    let outcome = tokio::select! {
        r = tokio::time::timeout(opts.timeout, rx) => Some(r),
        _ = tokio::signal::ctrl_c() => None,
    };
    // Success: stay up a moment. The tab that just posted may post again
    // (auto-submit plus a click), and a closed port turns a finished login
    // into a browser error page; the callback answers a replay with the
    // same redirect and stores nothing.
    if matches!(outcome, Some(Ok(Ok(Outcome::Saved { .. })))) {
        tokio::time::sleep(REPLAY_GRACE).await;
    }
    // Whatever happened, stop listening (the store-failed path already asked
    // for shutdown; the other paths ask here) and let the server
    // flush its last response.
    shutdown.notify_one();
    let _ = server.await;

    match outcome {
        Some(Ok(Ok(Outcome::Saved { masked }))) => {
            println!(
                "✓ signed in — API key {masked} saved to {}. The browser tab has moved on \
                 to your dashboard; savings report there from the next request (no \
                 restart needed).",
                crate::credentials::path().display()
            );
            if std::env::var("PARSEC_API_KEY").is_ok_and(|v| !v.is_empty()) {
                println!(
                    "note: PARSEC_API_KEY is set in the environment and OVERRIDES this file — \
                     unset it to use the stored key."
                );
            }
            Ok(())
        }
        Some(Ok(Ok(Outcome::StoreFailed(e)))) => {
            anyhow::bail!("received a key but could not store it: {e}")
        }
        Some(Ok(Err(_))) => anyhow::bail!("login listener stopped before a key arrived"),
        Some(Err(_)) => anyhow::bail!(
            "timed out waiting for the browser. Run `parsec login` again, or mint a key at \
             {dashboard}/account and run `parsec key set <psc_…>`."
        ),
        None => anyhow::bail!("cancelled"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_is_64_hex_and_fresh() {
        let a = new_state().unwrap();
        let b = new_state().unwrap();
        assert_eq!(a.len(), 64);
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, b);
    }

    #[test]
    fn connect_url_encodes_host_and_trims_slash() {
        let u = connect_url("https://app.getparsec.ai/", 4321, "abc", "Surya's Mac");
        assert_eq!(
            u,
            "https://app.getparsec.ai/connect?port=4321&state=abc&host=Surya%27s%20Mac"
        );
    }

    #[test]
    fn landing_url_points_at_dashboard_root_with_host_and_state() {
        let u = landing_url("https://app.getparsec.ai/", "Surya's Mac", "abc");
        assert_eq!(
            u,
            "https://app.getparsec.ai/?connected=Surya%27s%20Mac&login=abc"
        );
    }

    #[test]
    fn signed_in_is_a_303_to_the_dashboard() {
        let (h, _rx, _sd) = handoff(
            "f".repeat(64),
            "https://app.getparsec.ai".into(),
            "studio".into(),
        );
        let resp = signed_in(&h);
        assert_eq!(resp.status(), StatusCode::SEE_OTHER);
        assert_eq!(
            resp.headers()[header::LOCATION],
            "https://app.getparsec.ai/?connected=studio&login=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        );
    }

    /// The refused branches still answer with the local page, not a redirect
    /// — there is nothing in the app to show for a failed handoff. Driven
    /// through the real router over a raw TCP request so the Host / state
    /// checks run as they do in production.
    #[tokio::test]
    async fn bad_state_gets_local_page_not_redirect() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let (h, _rx, shutdown) = handoff(
            "a".repeat(64),
            "https://app.getparsec.ai".into(),
            "studio".into(),
        );
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let serve = axum::serve(listener, router(h)).with_graceful_shutdown({
            let shutdown = shutdown.clone();
            async move { shutdown.notified().await }
        });
        let server = tokio::spawn(async move { serve.await });

        let body = format!("state={}&key=psc_test", "b".repeat(64));
        let req = format!(
            "POST /callback HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\
             Origin: https://app.getparsec.ai\r\n\
             Content-Type: application/x-www-form-urlencoded\r\n\
             Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .unwrap();
        stream.write_all(req.as_bytes()).await.unwrap();
        let mut out = String::new();
        stream.read_to_string(&mut out).await.unwrap();
        shutdown.notify_one();
        let _ = server.await;

        assert!(out.starts_with("HTTP/1.1 403"), "{out}");
        assert!(!out.to_ascii_lowercase().contains("\nlocation:"), "{out}");
        assert!(out.contains("Sign-in state did not match"), "{out}");
    }

    #[test]
    fn loopback_host_check() {
        let mut h = HeaderMap::new();
        assert!(!host_is_loopback(&h));
        h.insert(header::HOST, "127.0.0.1:5000".parse().unwrap());
        assert!(host_is_loopback(&h));
        h.insert(header::HOST, "localhost:5000".parse().unwrap());
        assert!(host_is_loopback(&h));
        h.insert(header::HOST, "evil.example:5000".parse().unwrap());
        assert!(!host_is_loopback(&h));
    }

    #[test]
    fn origin_check_tolerates_absent_null_and_trailing_slash() {
        let mut h = HeaderMap::new();
        assert!(origin_ok(&h, "https://app.getparsec.ai"));
        h.insert(header::ORIGIN, "https://app.getparsec.ai".parse().unwrap());
        assert!(origin_ok(&h, "https://app.getparsec.ai/"));
        // What a browser actually sends on an https → http form navigation
        // under the default referrer policy (Chrome 153, 2026-09-12).
        h.insert(header::ORIGIN, "null".parse().unwrap());
        assert!(origin_ok(&h, "https://app.getparsec.ai"));
        h.insert(header::ORIGIN, "https://evil.example".parse().unwrap());
        assert!(!origin_ok(&h, "https://app.getparsec.ai"));
        // A look-alike is still a foreign origin.
        h.insert(
            header::ORIGIN,
            "https://app.getparsec.ai.evil".parse().unwrap(),
        );
        assert!(!origin_ok(&h, "https://app.getparsec.ai"));
    }
}
