# Command-Line Interface

Runway ships a one-shot `runway` command for agents and scripts. It prints the documented
[`/v1/limits`](local-http-api.md#get-v1limits) JSON and exits; it never launches or leaves the menu-bar
app running. The output contains stable scalar limits and balances, not UI rows, colors, subtitles,
charts, or spend-history tiles.

```sh
runway                 # every enabled provider, refreshing stale cache entries
runway codex           # one provider, refreshing when its cache is stale
runway codex --force   # refresh through the shared provider engine, cache, print, exit
```

The command and app import the same providers, authentication stores, pricing, refresh coordinator, and
snapshot cache. A normal read reuses snapshots less than five minutes old and refreshes missing or stale
ones. `--force` bypasses that freshness gate and
writes successful results to the same cache. It is not a full substitute for the app's manual
refresh: nobody is watching a terminal command, so `--force` never opens a macOS Keychain approval
dialog. It also cannot inherit one — `runway` is a separate executable with its own signature, and
macOS grants Keychain access per binary, so approving an item inside the Runway app does not
authorize the command. A provider whose credential lives only in a protected Keychain item
therefore keeps working here through the shared snapshot the app writes (within its five-minute
freshness window), while a forced or stale read of that provider reports it as unavailable. The command uses credentials only on your machine; they
never appear in the output.

A provider argument names providers by plain string matching, exactly like the
[local HTTP API](local-http-api.md). An exact provider ID names that provider. A family ID
(`claude`, `codex`) names every account card of that family. With one account, the family ID names
exactly that one card, so existing usage keeps working unchanged as multi-account support arrives.
The output envelope contains every matched provider; an ID that names nothing exits with an error.
There is no aliasing or account-picking logic.

## Install on `PATH`

In Runway, open **Settings → Advanced → Command Line** and click **Install…**. After the standard macOS
administrator prompt, `runway` is available globally in new terminal sessions. The installed symlink
points to the signed helper inside Runway, so in-place app updates also update the command.

Exit codes are `0` for success, `2` for invalid arguments or an unknown provider, and `4` when a
refresh or local read fails.
