# Logging

Runway keeps a file log so you can capture what the app was doing and share it with support when
something misbehaves. Lines at or above your chosen level also go to the macOS unified log, so raising
the level to Debug surfaces the extra detail in both places (see [Debugging](debugging.md) for
`log stream`).

## Where the log file lives

```
~/Library/Logs/Runway/Runway.log
```

The easiest way to grab it: open Settings -> Advanced and use **Copy Log Path** (puts the path on the
clipboard) or **Reveal in Finder** (selects the file in a Finder window). No Terminal needed.

## Changing the log level (Settings -> Advanced)

The **Log Level** picker controls how much detail is written. Your choice persists across launches and
takes effect immediately — no restart.

| Level | What it captures |
|---|---|
| Error | Only failures. |
| Warning | Failures plus things that look wrong but recovered. |
| Info | The normal story: refresh start/end, per-provider results, cache and auth milestones. |
| Debug | Everything, including per-request and per-cache-check detail. |

The release default is **Info** — quiet but useful. **Debug** is opt-in; turn it on only while
reproducing a problem, since it is much noisier.

If a local usage log exists but cannot be read, Runway writes one warning and skips it for that
refresh. It does not repeat the warning every five minutes; it warns again only if the file recovers
and later becomes unreadable again.

Any provider refresh that takes 10 seconds or longer writes a Warning-level `[refresh]` line with the
provider ID, elapsed milliseconds, and threshold. This is visible at the default Info setting, so a
slow local-log scan or network call can be identified from a normal support log without reproducing it
with Debug enabled. The warning is diagnostic only: other provider cards still update independently,
and the slow provider is allowed to finish.

## Subsystem tags

Every line is prefixed with a bracketed tag so the log is easy to grep:

`[refresh]` `[cache]` `[http]` `[auth]` `[keychain]` `[menubar]` `[updates]` `[config]`
`[subprocess]` `[localapi]`, plus per-provider tags like `[plugin:claude]` and `[auth:claude]`.

For example, to follow just the refresh cycle:

```sh
grep '\[refresh\]' ~/Library/Logs/Runway/Runway.log
```

## What is never logged

Secrets never reach the log. The app redacts access/refresh tokens, cookies, session tokens, and API
keys before it writes any line. A sensitive value becomes `first4...last4`, or `[REDACTED]` when it is
too short to mask safely. Filesystem paths under your home directory become `[PATH]`. The app never
logs a response body in full. On an HTTP error, it can record a redacted, truncated (≤500 byte)
preview at Debug to aid diagnosis. The preview goes through the same redaction first. A test suite
guards the redaction rules.

## File size cap

The log is capped at ~10 MB. When it fills up, the app rotates the current file to `Runway.1.log` and
starts a fresh `Runway.log`. A long-running session uses at most ~20 MB across the live file and one
archive, so it can never fill your disk. If a previous session left an oversize file, the app rotates
it once at launch.

> Note: the dev build and a released build both write to the same `Runway.log`. Running them at the
> same time interleaves their lines — fine for normal use, worth knowing if you debug both at once.
