# Debugging and Capturing Logs

How to run a local build and watch what the app is doing — useful when a provider misbehaves or you're
chasing a startup or refresh problem.

## Run a local build

The project script owns the build/run loop. From the repo root:

```sh
./script/build_and_run.sh          # build and launch the dev app from dist/
./script/build_and_run.sh build    # build and stage only, don't launch
./script/build_and_run.sh verify   # launch and confirm the process is running
```

The script builds a signed app bundle under `dist/` and launches it in place — nothing is installed to
`/Applications`. The dev build uses its own bundle id (`com.mattstallone.runway.dev`), so it keeps its
own settings and keychain and never disturbs a released Runway. It ships no update feed, so it never
checks for updates — test updates with a real signed, notarized release build.

## Stream logs

To watch the app's logs live while you reproduce an issue:

```sh
./script/build_and_run.sh logs
```

This launches the dev app and then streams its unified logs. Under the hood it filters the system log to
the app's process, equivalent to:

```sh
log stream --info --style compact --predicate 'process == "Runway"'
```

To read logs *after the fact* instead of live, use `log show` with a time window:

```sh
log show --last 10m --info --predicate 'process == "Runway"'
```

## Log file

In addition to the unified log above, the app writes a file log to
`~/Library/Logs/Runway/Runway.log` — this is what to send with a support report. It is capped at
~10 MB with one `.1` archive. Raise the detail in **Settings -> Advanced -> Log Level** (use **Debug**
for full detail), then grab the file with **Copy Log Path** or **Reveal in Finder** in that same
section. See [Logging](logging.md) for the levels, subsystem tags, and the never-log-secrets guarantee.

## Account log lines

The launch-time account pass (which account is signed in at the Claude/Codex default home) leaves a
short trail in the log file:

- `accounts: claude default identity resolved (claude@<hash>)` — the default login named its account.
  The hash is derived from the account id, so two launches by the same account always match.
- `accounts: codex default identity unresolved — …` — a login exists but its account can't be named
  with certainty this launch (for example, an auth file without an account id or an unbound
  account-scoped keyring credential). The legacy card still works; that source can't participate in
  account-aware features until its identity is verified.
- `discovery: codex candidate ~/.codex-work: accepted (<hash>, auth.json)` — a custom Codex home
  supplied a usable, account-named OAuth login and participates in an account card.
- `discovery: codex candidate ~/.codex-work: keyring identity unverified → hidden until its exact
  item is bound` — the home uses account-scoped keyring storage, but launch discovery has not safely
  associated that item with its provider account yet.
- `discovery: warmed Codex keyring identity for home <hash>` — the post-launch task read that one
  exact item and recorded a fingerprint-bound account association; its card can appear next launch.
- `discovery: codex candidate ~/.codex-work: accepted (<hash>, verified keyring)` — the keyring item
  still matches the verified binding and now participates in an account card.
- `discovery: codex candidate ~/.codex-work: OAuth credential names no account → skipped` — the
  home has a token but no provider-owned account identity, so Runway refuses to guess from its
  path and can't safely turn it into a separate card.
- `accounts: codex card codex@<hash> from 2 home(s)` — the account card was assembled, and the
  number says how many same-account Codex homes contribute local session logs to it.
- `stale account cache discarded for claude` — the account at the default home changed between
  launches, so the previous account's cached snapshot was dropped instead of painting under the new
  login.
- `account identity read skipped for claude, codex: login shell cold and no shell-environment
  snapshot exists yet` — the bounded login-shell capture failed on a launch with no persisted
  snapshot, so the named families were safely left unread rather than assembled from the wrong home.

## Profile the UI

`script/profile_ui.sh` measures popover performance end to end. It builds and stages the dev app,
relaunches it with `RUNWAY_UI_PROFILE=1`, and an in-app driver walks the popover through scripted
phases — a cold open, twelve warm open/close cycles, ten screen switches, ten caret toggles, a
forced refresh with the panel open, and an idle soak. The script then prints per-phase stats from
the log: open latency broken into layout and order-front, close cost, and main-queue stalls.

Run it before and after any change that touches the popover render path, and compare. Reference
numbers from this machine class (Apple Silicon, August 2026): warm open should stay in the low tens
of milliseconds to first frame, and the warm-cycles phase should report few or no stalls.

The `RUNWAY_UI_PROFILE` gate is inert in normal use — no timing code runs without it. The stall
watchdog measures how long async main-actor work waits (main-queue latency), which is a proxy for
responsiveness, not a literal dropped-frame count.

## Tips

- **A provider shows an error.** Reproduce with `logs` running, then check that provider's page in
  `docs/providers/` for what its error states mean and where it reads credentials from.
- **Nothing updates.** Refresh runs on a timer and respects the cache; see
  [Refreshing & caching](refreshing.md) for when a network call actually happens. Use the per-provider
  "Refresh" in the row's context menu to force one.
- **Permissions / keychain prompts on every rebuild.** The script signs with a stable Apple Development
  identity so the permission ACLs stick. If you see repeated prompts, make sure such an identity exists in
  your keychain (the script warns when it falls back to ad-hoc signing).
- **Inspect the local API.** With the app running, `curl 127.0.0.1:6736/v1/usage` shows the same usage
  snapshots the UI uses — handy to confirm whether a problem is in fetching/mapping or in the UI.
