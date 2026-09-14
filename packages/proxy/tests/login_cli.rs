//! `parsec login` end to end, minus the browser: the loopback listener is
//! driven in-process with the same form POST the dashboard's /connect page
//! sends, against an isolated HOME. Asserts the contract the frontend relies
//! on — a matching `state` stores the key exactly where `parsec key set`
//! would, everything else is refused and stores nothing, and the handoff is
//! one-shot.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use parsec_proxy::login::{handoff, router, Outcome};

struct TempHome(PathBuf);

impl TempHome {
    fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("parsec-login-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        TempHome(dir)
    }
    fn path(&self) -> &Path {
        &self.0
    }
    fn creds(&self) -> PathBuf {
        self.0.join(".parsec").join("credentials.json")
    }
}

impl Drop for TempHome {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const DASH: &str = "https://app.getparsec.ai";
const STATE: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

/// One listener on an ephemeral loopback port; returns its base URL plus
/// the outcome receiver the CLI would block on.
async fn listener() -> (
    String,
    tokio::sync::oneshot::Receiver<Outcome>,
    Arc<tokio::sync::Notify>,
) {
    let (h, rx, shutdown) = handoff(STATE.to_string(), DASH.to_string(), "studio".to_string());
    let l = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let port = l.local_addr().unwrap().port();
    let serve = axum::serve(l, router(h)).with_graceful_shutdown({
        let s = shutdown.clone();
        async move { s.notified().await }
    });
    tokio::spawn(async move { serve.await });
    (format!("http://127.0.0.1:{port}"), rx, shutdown)
}

/// (status, Location header if any, body). Redirects are NOT followed: the
/// success branch answers 303 to the dashboard, and following it would take
/// the test onto the real network.
async fn post(
    base: &str,
    form: &[(&str, &str)],
    origin: Option<&str>,
) -> (u16, Option<String>, String) {
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let mut req = client.post(format!("{base}/callback")).form(form);
    if let Some(o) = origin {
        req = req.header("Origin", o);
    }
    let resp = req.send().await.unwrap();
    let status = resp.status().as_u16();
    let location = resp
        .headers()
        .get("location")
        .map(|v| v.to_str().unwrap().to_string());
    (status, location, resp.text().await.unwrap())
}

/// The whole test binary shares one process, so HOME is pinned once and
/// every test gets its own key to look for. Tests run serially on that
/// shared HOME via a mutex rather than racing on env.
static HOME_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn pin_home(home: &TempHome) -> tokio::sync::MutexGuard<'static, ()> {
    let g = HOME_LOCK.lock().await;
    // Single-threaded at this point (guarded), and no other test binary
    // shares the process — the documented caveat on set_var does not bite.
    std::env::set_var("HOME", home.path());
    std::env::set_var("USERPROFILE", home.path());
    std::env::remove_var("PARSEC_API_KEY");
    std::env::remove_var("PARSEC_PLATFORM_URL");
    g
}

#[tokio::test(flavor = "multi_thread")]
async fn matching_state_stores_key_and_completes() {
    let home = TempHome::new("ok");
    let _g = pin_home(&home).await;
    let (base, rx, _shutdown) = listener().await;

    // `Origin: null` is what a browser sends on the https → http form
    // navigation under its default referrer policy (Chrome 153, 2026-09-12);
    // a listener that only accepted the dashboard's concrete origin refused
    // every real login. The connect page now opts into `referrer: origin`,
    // but the listener must not depend on that.
    let (status, location, body) = post(
        &base,
        &[("state", STATE), ("key", "psc_test_key_1234")],
        Some("null"),
    )
    .await;
    // Success is a top-level navigation into the app, not a local page
    // (docs/install-first-signup.md gap 1): the dashboard greets the machine
    // by the `connected` hint and retires the parked key by `login` state.
    assert_eq!(status, 303, "{body}");
    assert_eq!(
        location.as_deref(),
        Some(format!("{DASH}/?connected=studio&login={STATE}").as_str())
    );
    assert!(
        !body.contains("psc_test_key_1234") && !location.unwrap().contains("psc_"),
        "the key must never be echoed"
    );

    match tokio::time::timeout(Duration::from_secs(5), rx).await {
        Ok(Ok(Outcome::Saved { masked })) => assert_eq!(masked, "psc_…1234"),
        other => panic!("expected Saved, got {other:?}"),
    }
    let creds: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(home.creds()).unwrap()).unwrap();
    assert_eq!(creds["api_key"], "psc_test_key_1234");

    // One-shot: the listener stays up for a grace period after success (the
    // CLI decides when to stop), and a replay with the right state — the
    // same tab submitting twice — gets the same redirect and stores nothing,
    // even with a different key in the body.
    let (status, location, _) = post(
        &base,
        &[("state", STATE), ("key", "psc_replayed_key")],
        Some(DASH),
    )
    .await;
    assert_eq!(status, 303, "a replay goes where the first submit went");
    assert_eq!(
        location.as_deref(),
        Some(format!("{DASH}/?connected=studio&login={STATE}").as_str())
    );
    let creds: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(home.creds()).unwrap()).unwrap();
    assert_eq!(creds["api_key"], "psc_test_key_1234");
    // A wrong state after success is still a refusal, not a redirect.
    let (status, location, _) = post(
        &base,
        &[("state", "deadbeef"), ("key", "psc_x")],
        Some(DASH),
    )
    .await;
    assert_eq!(status, 403);
    assert!(location.is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn wrong_state_or_origin_stores_nothing() {
    let home = TempHome::new("refused");
    let _g = pin_home(&home).await;
    let (base, mut rx, _shutdown) = listener().await;

    // Guessed state.
    let (status, location, _) = post(
        &base,
        &[("state", "deadbeef"), ("key", "psc_attacker")],
        Some(DASH),
    )
    .await;
    assert_eq!(status, 403);
    assert!(
        location.is_none(),
        "refusals render locally, never redirect"
    );
    // Right state, foreign origin (a page that is not the dashboard).
    let (status, _, _) = post(
        &base,
        &[("state", STATE), ("key", "psc_attacker")],
        Some("https://evil.example"),
    )
    .await;
    assert_eq!(status, 403);
    // Right state, no key.
    let (status, _, _) = post(&base, &[("state", STATE), ("key", "")], Some(DASH)).await;
    assert_eq!(status, 400);
    // Missing form field entirely → axum's rejection, still no store.
    let (status, _, _) = post(&base, &[("state", STATE)], Some(DASH)).await;
    assert!(status >= 400, "status {status}");

    assert!(
        !home.creds().exists(),
        "nothing may be written on a refused callback"
    );
    assert!(rx.try_recv().is_err(), "the CLI must still be waiting");

    // Unknown paths are a polite 404, not a store.
    let resp = reqwest::get(format!("{base}/anything")).await.unwrap();
    assert_eq!(resp.status().as_u16(), 404);
    // GET on the callback is not a handoff.
    let resp = reqwest::get(format!("{base}/callback?state={STATE}&key=psc_get"))
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 405);
    assert!(!home.creds().exists());
}

/// The real binary: `--no-browser` prints a /connect URL carrying a fresh
/// state and this machine's port, then times out cleanly (exit 1, a
/// pointer to `parsec key set`) when nothing calls back.
#[test]
fn binary_prints_connect_url_and_times_out() {
    let home = TempHome::new("bin");
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_parsec"))
        .args(["login", "--no-browser", "--timeout", "1"])
        .env("HOME", home.path())
        .env("USERPROFILE", home.path())
        .env("PARSEC_DASHBOARD_URL", "http://localhost:3000/")
        .env_remove("PARSEC_API_KEY")
        .output()
        .expect("run parsec login");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(
        out.status.code(),
        Some(1),
        "stdout: {stdout}\nstderr: {stderr}"
    );
    let url_line = stdout
        .lines()
        .find(|l| l.trim().starts_with("http://localhost:3000/connect?"))
        .unwrap_or_else(|| panic!("no connect URL in:\n{stdout}"));
    assert!(url_line.contains("&state="), "{url_line}");
    assert!(url_line.contains("port="), "{url_line}");
    assert!(url_line.contains("&host="), "{url_line}");
    assert!(stderr.contains("timed out"), "{stderr}");
    assert!(stderr.contains("parsec key set"), "{stderr}");
    assert!(!home.creds().exists());
}
