# `parsec login` — the loopback browser handoff

**Status:** implemented 2026-09-11 (client `packages/proxy/src/login.rs`,
dashboard `packages/frontend/src/app/connect/`); wired into every install
surface and the tray 2026-09-12 (*Where it runs*). The paste-a-key flow is no
longer presented anywhere; `parsec key set` remains only as the browserless
escape hatch.

## Why

Before this, linking a machine to an account was two hops across two
surfaces: open the dashboard, mint a key, copy it, come back to a terminal,
run `parsec key set`. The curl one-liner hides that when the user starts
from the dashboard (the key is baked into the command), but the native
`.pkg` / `.exe` installers cannot carry a key, so their finish screens sent
users on exactly that round trip. `parsec login` collapses it to: run one
command, click one button in the browser.

## Flow

```
terminal                              browser                        dashboard (BFF)
────────                              ───────                        ───────────────
parsec login
  bind 127.0.0.1:<ephemeral>
  state = 32 random bytes (hex)
  open <dash>/connect?port&state&host ─▶ /connect
                                        (signed out → /login?next=…
                                         → GitHub → /auth/callback → back)
                                        "parsec login on <host> is asking
                                         to connect to this account"
                                        [Connect <host>] ───────────▶ POST /api/keys
                                                          ◀─────────── { key: psc_… }
                                        <form method=post
                                          action=http://127.0.0.1:<port>/callback>
                                          state, key
  POST /callback ◀───────────────────── (top-level form navigation)
  check Host ∈ loopback
  check Origin ∈ {<dash>, null, absent}
  check state (one-shot)
  setup::save_account_key(key)   ← same write path as `parsec key set`
  303 → <dash>/?connected=<host>&login=<state> ─▶ dashboard greets the machine
  graceful shutdown, exit 0        (failure branches still render a local page)
```

Since 2026-09-12 the success response is a redirect into the app rather than
a local "close this tab" page (docs/install-first-signup.md gap 1): the
dashboard reads the account's linked machines from `GET /installs/mine` and
shows "Connected: *host* … start a session" instead of the install steps.
`?connected=` names the machine for that first greeting only (the install
report carries no hostname), and `?login=<state>` lets the dashboard mark
the connect page's parked key as done so Back cannot re-submit it.

`save_account_key` is the single write path for both `parsec key set` and
`parsec login`: the key lands in `~/.parsec/credentials.json` (0600), the
install re-reports so the machine is attributed to the account, and the
proxy picks it up on the next request without a restart.

## Why a form POST and not fetch / a GET redirect

- **A top-level form navigation needs no CORS and no private-network-access
  preflight.** A `fetch` from `https://app.getparsec.ai` to `http://127.0.0.1`
  would need the listener to answer CORS preflights *and* Chrome's
  private/local-network-access handshake, which is moving toward a
  permission prompt. Navigations are outside that policy.
- **Loopback is a potentially-trustworthy origin** in Chrome, Firefox and
  WebKit, so an `https → http://127.0.0.1` form submit raises no
  mixed-content interstitial.
- **The key rides in the body, not the URL.** A GET redirect (the gcloud
  shape) puts the key in browser history; the form keeps it out.

## Threat model

Any web page can navigate a visitor's browser to `http://127.0.0.1:<port>/…`.
Without a guard, a page could plant *its* key on a machine mid-login and
quietly route that machine's savings to a stranger's account.

- `state` is 256 bits from the OS CSPRNG, minted per login, compared once,
  consumed on success. The listener then stays up for three seconds
  (`REPLAY_GRACE`) and answers a replay carrying the same state with the
  same redirect, storing nothing — the connect page auto-submits and a
  human can click too, and on the first real-machine run that second POST
  met a closed port and Chrome showed "site cannot be reached" over a
  login that had in fact succeeded. A wrong state is still refused.
- `Host` must be a loopback name (DNS-rebinding guard).
- `Origin`, when the browser sends a concrete one, must equal the dashboard
  origin (`PARSEC_DASHBOARD_URL`, default `https://app.getparsec.ai`). The
  literal `null` is accepted: under the default referrer policy
  (`strict-origin-when-cross-origin`) the Fetch spec serialises the Origin
  of an https → http navigation as `null` — the target's *scheme* decides,
  loopback or not — so that is what every real handoff carried until the
  connect page opted into `referrer: origin` (verified on Chrome 153,
  2026-09-12: the first real-machine login was refused for exactly this).
  `state` is the guard; the Origin check only turns away a page that
  announces a foreign origin.
- Minting on `/connect` waits for a click and names the machine, so a
  stray link cannot mint keys in a signed-in session without a human
  reading "connect *studio*?".
- The listener lives only for one login (default 300 s timeout, Ctrl-C
  cancels) and only on 127.0.0.1.
- The success page never echoes the key; the terminal prints it masked.

The data-plane rule holds: the key crosses browser → loopback on the user's
own machine. Nothing new touches our cloud beyond the mint that the account
page already performs.

## Where it runs

Nobody should have to type `parsec login`; every install path ends in it:

| surface | how | opt-out |
|---|---|---|
| `install.sh` | runs `parsec login` at the end when stdout is a terminal, a binary was installed, and no key was baked with `--key` | `--no-login` / `PARSEC_NO_LOGIN=1` |
| `install.ps1` | same, gated on `[Environment]::UserInteractive` | `-NoLogin` / `PARSEC_NO_LOGIN=1` |
| Windows `.exe` (Inno) | Finished-page checkbox "Sign in to parsec", a `[Run] postinstall` entry; hidden when `credentials.json` exists (upgrade) and in silent installs | untick it |
| macOS `.pkg` | `core/postinstall` spawns `parsec login` detached as the console user (`spawn_as_user`, log in `~/.parsec/login.log`) when there is a GUI session and no key | `PARSEC_NO_LOGIN=1` |
| tray / menu bar | "Sign in to parsec…" is the first menu item while no key resolves; becomes a passive "Signed in" line after | — |
| Claude Code | `/parsec:login` skill runs it with a timeout that fits the tool call | — |

## Fallbacks

- `parsec login --no-browser` prints the URL for SSH / WSL / containers.
  The callback is loopback on the machine running the command, so the URL
  must be opened by a browser *on that machine* (WSL: `wslview` is tried
  first, then `xdg-open`).
- If the submit lands on a dead listener (CLI timed out, wrong machine),
  `/connect` parks the minted key in `sessionStorage` under that login's
  `state`, and a back-navigation shows the manual `parsec key set psc_…`
  line instead of minting again.
- `parsec key set` stays as the browserless escape hatch (SSH, CI). The
  dashboard account page keeps a mint button for exactly that case, labelled
  as such; nothing else points at it.
- A device-code flow (RFC 8628) would remove even that paste; it is the
  natural next step if SSH-only users turn out to matter.

## Follow-ups

- **Per-machine keys**: `/connect` knows the hostname but the keys table has
  no label column; adding one would make the account page list "studio",
  "work-laptop" and allow per-machine revocation.
- **Windows sign-in window**: the Inno checkbox and the tray launch
  `parsec.exe login`, a console-subsystem process. From the tray it runs
  windowless (log only); from the installer it shows a console with the
  URL, which closes on completion. A quieter launcher (the tray's wscript
  pattern) is possible if that reads as a flash.
