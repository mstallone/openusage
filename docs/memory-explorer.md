# Memory Explorer

AI coding agents keep persistent memory and instruction files on disk — Claude Code's per-project memories, Codex's `AGENTS.md`, Gemini's `GEMINI.md`, and so on — with no single place to see or change them. The Memory window is that place: it finds every memory home on your Mac, shows what's inside, and lets you read, edit, create, and delete the files directly. Everything happens on your Mac; nothing is sent anywhere.

Open it from the popover footer's **gear** menu (**Memory**) or by right-clicking the menu bar icon and choosing **Memory**. It opens in its own resizable window, remembers its size and position, and closes with the red close button, Esc, ⌘W, or ⌘Q — ⌘Q closes only this window; Runway keeps running in the menu bar. Like Settings, the window only exists while it's open.

Discovery is not tied to which providers you have turned on in Runway — if a harness left memory files on disk, they appear, even if you're logged out of that tool. Harnesses with nothing on disk simply don't show up. The **Refresh** button re-scans at any time. If a scan runs out of time or some folders can't be read, the sidebar says so instead of presenting a partial list as complete.

If you renamed a Claude or Codex account card (right-click the card in the popover → **Rename…**), the sidebar shows that custom name for the matching home, and it updates live when you rename again.

## What each harness supports

| Harness | What appears | Editing |
|---|---|---|
| Claude Code | `CLAUDE.md` plus each project's memory folder — its `MEMORY.md` index and individual memory files — across every config home (`~/.claude`, `~/.claude-personal`, any `CLAUDE_CONFIG_DIR`, …) | Full: edit, create, and delete memories |
| Codex | `AGENTS.md` and legacy `memories/*.md` files, plus rows from its memory database (`memories_1.sqlite`) | Files are editable; database rows are read-only |
| Gemini | `GEMINI.md` | Editable |
| Grok | Its `memory/` folder (global and per-project `MEMORY.md`), when the memory feature is enabled | Editable |

Project folders show a decoded project path where possible (e.g. `/Users/you/Developer/myapp`); when the path can't be verified on disk, the raw folder name shows instead. This is display-only — the files underneath are always the real ones.

## The four states

Each source is in one of four states, and the sidebar ranks them: sources with content first, then homes with nothing in them yet, then harnesses whose memory feature is off. Within each group the usual provider order applies (Claude, Codex, then alphabetical). Every section collapses by clicking its header. Sources with content start expanded; so does any source with a problem to show (an unreadable file, a scan failure note), because a collapsed section would hide its explanation. The rest start collapsed — their badge already says what's going on.

- **Ready** — memory files exist and have content. This is the normal state, so it shows no badge.
- **Empty** — the file exists but is blank (common for a fresh `GEMINI.md`). You can start writing right away.
- **No File** — the harness's home is there but its instruction file isn't, and there are no other memory files either.
- **Memory Disabled** — the harness is installed but its memory feature is off (for example, Codex with `use_memories = false` in its config, or Grok without a `[memory]` section in its config). The sidebar says which switch is off and where it lives. Runway shows the state; it never flips the feature on for you. A Grok home with memory turned on but no files yet shows **No File** instead, with the usual create option.

An expected instruction file that doesn't exist yet can be created in place from the window — the **Create Instruction File** row appears whenever the file is absent, whether the source shows **No File** or is **Ready** off other memory files.

## Editing and saving

Nothing saves automatically. These files are shared with live agent processes, so changes only land when you press **Save** (⌘S) — the button lights up when you have unsaved edits, and closing the window, switching documents, pressing **Refresh**, or quitting Runway with unsaved edits asks first (Save / Discard / Cancel). Every save — including one chosen from those prompts — first checks whether the file changed (or disappeared) on disk; if it did, the editor shows the Reload / Overwrite banner instead of writing, and only the banner's **Overwrite** writes over a moved file.

Because an agent can write the same file while you have it open, Runway checks the file on disk before saving and whenever the window comes back to the front:

- **File changed on disk, you haven't edited** — your view silently reloads to the new content.
- **File changed on disk, you have unsaved edits** — a banner offers **Reload** (drop your edits, load the disk version) or **Overwrite** (save your version anyway).

Saving preserves the file's existing permissions.

## Creating and deleting memories

Claude Code keeps a `MEMORY.md` index alongside its memory files, and Runway keeps the two in sync:

- **New Memory…** on a project asks for a title, description, and type, then writes the new file *and* adds its line to the index (creating `MEMORY.md` first if the project doesn't have one).
- **Delete** on a memory (with confirmation) removes the file *and* drops its line from the index.

Editing a memory's text doesn't rewrite its index line — if you change a title by hand, update the index line too, just as you would when editing outside Runway.

## The read-only database view

Codex also distills memories into a local database. Runway lists those entries and shows each one's content — the raw memory and its session summary — but never writes to the database. Rows carry a Read-Only badge and have no Save or Delete.

## Heads-up: agents write these files too

A running agent session can rewrite memory files at any moment. The changed-on-disk protection above is best-effort — it catches changes on save and window focus, not the instant they happen. When an agent is actively working in a project, prefer reading over editing until it's done.
