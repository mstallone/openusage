# Copilot

Tracks your GitHub Copilot quota using a GitHub token that Copilot tooling already left on your machine. No login flow, no browser cookies.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Share of your monthly AI-credit allotment used (the headline meter) |
| Extra Usage | Premium interactions used beyond your included credits, once extra spend is enabled |
| AI Credits Used | Total AI credits your organization used this month, with included/additional breakdown |
| Additional Spend | Dollars your organization was billed beyond its included AI credits |
| Chat | Chat-message quota used |
| Completions | Code-completion quota used |

Runway adapts the card to the account instead of showing every possible Copilot metric as "No data":

- **Individual paid plans** show Credits and, when enabled, Extra Usage.
- **Individual free plans** show Chat and Completions.
- **Business and Enterprise seats** show AI Credits Used and Additional Spend.

Metrics that GitHub does not expose for the current account type are hidden. The applicable usage rows are Always Visible; none of the organization metrics are pinned to the menu bar by default. Percentage meters show percent used and, when the response includes one, a countdown to the next reset. The plan name (Pro, Business, Free, …) shows next to the provider.

Since June 2026 GitHub Copilot bills all plans by **AI credits**, so what each account shows differs by plan:

- **Paid plans** meter the credit pool — so you see Credits (and Extra Usage if you've turned on additional spend). Chat and completions are unlimited on paid plans, so those inapplicable rows are hidden.
- **Free plans** have no credits; instead you see the fixed Chat and Completions quotas GitHub reports.
  Both rows remain available if a refresh temporarily omits one bucket; the omitted metric shows No data
  until GitHub reports it again.
- **Org-managed seats (Copilot Business / Enterprise assigned by an organization)** return no per-seat quota, so the personal meters have nothing to show. Runway then looks the usage up at the seat's billing entity—its organization, or its enterprise when billing is consolidated—and shows **AI Credits Used** (total organization usage, broken into included and additional credits) and **Additional Spend** (dollars billed beyond the included pool). Caveats:
  - The numbers are **organization-wide**, not your personal share — GitHub doesn't expose per-seat usage.
  - Reading an org's billing requires you to be an **org owner or billing manager**. Regular members see a clear managed-account message instead of personal "No data" placeholders.
  - When Copilot identifies the seat's organization, Runway checks its enterprise before it accepts an
    empty organization report, because consolidated usage is billed at the enterprise level. If a
    proven enterprise association stays unreadable — or the seat is a Copilot **Enterprise** seat and
    the credential can't see enterprise associations at all — Runway keeps the managed-account state.
    For a **Business** seat, when no enterprise claims the organization (or associations can't be
    read), a readable empty organization report stands. At the start of a billing month the card shows
    zero credits used, not the managed-account message. As soon as usage happens under that login, the
    org report carries the real numbers on the next refresh. An unrelated empty report is never
    attributed to the seat.
- AI Credits Used is shown as a plain count, not a percentage. The API reports total, discounted/included, and additional usage, but not the organization's full available pool; Runway doesn't fabricate a denominator.

A dollar credit figure (e.g. "$12 of $15 used") is not shown: GitHub only exposes it through the logged-in web billing page, which requires browser cookies — the Copilot provider does not read browser cookies. Editors like VS Code show the same credit *percentage* from this endpoint, not a dollar amount.

## Where credentials come from

Checked in this order (prompt-free files first, Keychain last):

1. Copilot editor token: `~/.config/github-copilot/apps.json` (older `hosts.json`) — written by the VS Code / JetBrains / Neovim Copilot plugins.
2. GitHub CLI config: `~/.config/gh/hosts.yml` (`oauth_token`), when `gh` stores its token in a file.
3. GitHub CLI Keychain item (service `gh:github.com`), when `gh` stores its token in the system keyring.
   Automatic refreshes never request its secret. After launch or a credential change the card
   offers a neutral **Connect** action; Runway reuses that value in memory for the running app
   session while the item's non-secret metadata remains unchanged. Choose
   **Always Allow** to avoid a dialog on future manual reads.

The editor token stays preferred for the Copilot quota endpoint. For organization and enterprise
billing, Runway tries the GitHub CLI credential first when Copilot identifies the seat organization,
because it can carry the required organization or enterprise permissions, then falls back to the editor
token if necessary. An empty report remains provisional until both credentials have been tried, so a
credential with consolidated enterprise access can still supply the actual totals. When the seat
organization is unknown, Runway keeps membership discovery on the same credential that produced the
Copilot card so another local GitHub account cannot be mixed in.

### Setup

If usage doesn't appear, authenticate with the GitHub CLI:

```bash
brew install gh   # if needed
gh auth login     # choose GitHub.com and follow the prompts
```

Using Copilot in a supported editor is enough on its own — the editor writes the token to `apps.json`.

## Troubleshooting

- **"Sign in to GitHub Copilot…"** — no token was found. Sign in to Copilot in your editor, or run `gh auth login`.
- **"GitHub login found in Keychain"** (a neutral key glyph / **Connect** button, not a warning) — `gh` keeps its token in the system keyring and it hasn't been loaded this app session. Connect; choose **Always Allow** to avoid a dialog on future manual reads.
- **"Keychain access to the GitHub login was declined"** — a manual read was denied. Refresh and choose **Always Allow** when macOS asks.
- **"GitHub login couldn't be read"** — the login keychain itself is unavailable (locked, most often). Unlock it and refresh; approving nothing would fix this one.
- **"GitHub token invalid or expired"** — the token was rejected (401/403). Re-authenticate with `gh auth login`.
- **"Managed by Your Organization"** — GitHub doesn't expose a live per-seat quota for Business/Enterprise, and none of the locally available credentials could read the relevant organization or enterprise billing. Organization reporting requires organization billing access; consolidated reporting also requires enterprise read and billing access. Some editor-plugin and GitHub CLI tokens do not carry those scopes.

## Under the hood

`GET https://api.github.com/copilot_internal/user` with the standard Copilot client headers (API version `2025-04-01`). The response reports each bucket as percent *remaining*; the meters show percent *used*.

For org-managed seats (identified by the token-based-billing placeholder in that response), Runway first uses the Copilot account response's organization list to query `GET /organizations/{org}/settings/billing/ai_credit/usage?product=Copilot`. GitHub defaults that endpoint to the current year and month. If an associated organization returns 403, 404, or an empty report, Runway resolves all enterprises visible to the token through GitHub GraphQL, verifies which enterprise owns that seat organization, and queries the enterprise AI-credit endpoint filtered to that organization and Copilot. This lets an authorized enterprise billing manager see consolidated totals even when they do not administer the seat organization. Rate-limited and other retryable REST or GraphQL failures fail that refresh — the card keeps its last-good numbers with the usual staleness/warning treatment instead of replacing them; only explicit access errors show the managed-account state. If the Copilot response has no organization association, Runway falls back to `GET /user/orgs`, but only positive Copilot usage—not an empty current or cached report—can identify the seat's organization. Other AI products are excluded at the API boundary and ignored by the mapper. An org is remembered only after it reports Copilot usage.
