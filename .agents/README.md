# Build macOS Apps — Skills Bundle

Local skills bundle ported from OpenAI's Codex plugin
[`openai/plugins/build-macos-apps`](https://github.com/openai/plugins/tree/main/plugins/build-macos-apps).
Packages macOS-first development workflows (Xcode, Swift, SwiftPM, SwiftUI,
AppKit, signing, telemetry) as agent skills.

## Layout

```text
.agents/
├── README.md              # this file
└── skills/
    ├── appkit-interop/SKILL.md            (+ references/*.md)
    ├── build-run-debug/SKILL.md           (+ references/build-script.md)
    ├── liquid-glass/SKILL.md
    ├── packaging-notarization/SKILL.md
    ├── signing-entitlements/SKILL.md
    ├── swiftpm-macos/SKILL.md
    ├── swiftui-patterns/SKILL.md          (+ references/*.md)
    ├── telemetry/SKILL.md
    ├── test-triage/SKILL.md
    ├── view-refactor/SKILL.md
    ├── window-management/SKILL.md
    ├── macos-*/SKILL.md                   # macos-prefixed variants of the skills above
    │
    ├── pricing-update/SKILL.md            # Runway project skill, not from the plugin
    ├── release-swift/SKILL.md             # Runway project skill, not from the plugin
    │
    ├── build-and-run-macos-app/SKILL.md   # ex-slash-command
    ├── fix-codesign-error/SKILL.md        # ex-slash-command
    └── test-macos-app/SKILL.md            # ex-slash-command

.claude -> .agents                          # symlink so Claude Code finds them
```

## Conversion notes (vs the source plugin)

| Source (Codex plugin)            | This bundle                                       |
| -------------------------------- | ------------------------------------------------- |
| `.codex-plugin/plugin.json`      | Not needed — flat `.agents/` layout, no manifest. |
| `agents/openai.yaml`             | Skipped — Codex-surface-specific agent metadata, no analog elsewhere. |
| `skills/<name>/SKILL.md`         | Copied 1:1 (frontmatter is already compatible).   |
| `skills/<name>/references/*`     | Copied 1:1.                                       |
| `commands/<name>.md`             | Re-shaped as `skills/<name>/SKILL.md` with `disable-model-invocation: true`. |
| `assets/` (icon, svg)            | Skipped — no manifest references them.            |
| `.codex/environments/environment.toml` wiring | Stripped — that wired up Codex's project Run button, which doesn't exist in Cursor or Claude Code. The `script/build_and_run.sh` entrypoint stayed; the env file did not. |

### Run entrypoint

The `build-run-debug` and `build-and-run-macos-app` skills create a project-local
`script/build_and_run.sh` as the single kill + build + run entrypoint. Invoke
it directly from a terminal. If you want a one-click Run, wrap it in your
editor's task system (`.vscode/tasks.json`, an Xcode scheme run action, a
`Makefile` target, etc.).

## Scope

Inherited from the source plugin — these skills cover:

- discovering local Xcode workspaces, projects, and Swift packages
- building/running macOS apps with shell-first Xcode/Swift workflows
- one project-local `script/build_and_run.sh` entrypoint
- native macOS SwiftUI scenes, menus, settings, toolbars, multiwindow flows
- modern Liquid Glass design-system patterns
- bridging into AppKit for representables, responder-chain, panels
- refactoring large macOS view files
- lightweight `os.Logger` instrumentation + `log stream` verification
- triaging failing unit / integration / UI-hosted macOS tests
- signing, entitlements, hardened runtime, Gatekeeper diagnosis
- packaging and notarization prep

Not covered: iOS / watchOS / tvOS, desktop UI automation, App Store Connect
releases, pixel-perfect visual design.

## Source attribution

- Original Codex plugin: <https://github.com/openai/plugins/tree/main/plugins/build-macos-apps>
- Upstream author: OpenAI (`support@openai.com`)
- License: MIT (inherited from the source plugin)
