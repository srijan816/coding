# ClaudeDeck — Complete Build Specification

> **This is your master instruction document.** You (Claude Code) are building a native macOS application that wraps the `claude` CLI into a Codex-like desktop experience, configured to route through **MiniMax M2.7** via its Anthropic-compatible endpoint. Read this entire document before writing any code. Do not skip sections. Do not guess at behavior — the verified facts are cited inline.

-----

## 0. How to use this document (read first)

### 0.1 Your operating rules for this build

1. **Work in phases.** The build is divided into 10 phases (§5–§14). Finish phase N fully — including its tests — before starting phase N+1. Do not interleave.
1. **Document as you go.** After every phase, append a section to `BUILD_LOG.md` in the repo root with: what you built, what you verified, exact commands you ran, any deviations from this spec and why. Another engineer must be able to audit your work from this log alone.
1. **Never guess CLI flags or file paths.** The verified ones are in §2.3 and §3.2. If you think you need something else, stop and re-read those sections first. If still unsure, add a `// TODO: verify` and flag it in `BUILD_LOG.md` instead of inventing.
1. **Ship a running build every phase.** The app must launch and not crash at the end of every phase, even if features are stubs. No “big bang” integration at the end.
1. **You are probably running on MiniMax M2.7 yourself.** That means: keep individual turns scoped. Don’t try to write the entire app in one turn. Break tasks into small, verifiable chunks. Prefer many small correct edits over one large speculative one.
1. **When a phase’s acceptance criteria fail, stop and fix before moving on.** Don’t paper over failures.

### 0.2 Mental model — what we are actually building

We are **not** reimplementing Claude Code. We are building a **GUI shell** around the existing `claude` CLI binary. The CLI does all the heavy lifting (agent loop, tool execution, context management, session persistence). Our app:

- Spawns `claude` as a child process per thread, using `--print` with `--output-format stream-json` and `--input-format stream-json`.
- Renders the streamed JSON events into a chat-like UI.
- Groups threads by **Project** (a directory on disk, matching how Codex and Claude Code already think about workspaces).
- Manages the `.env`-based configuration so the spawned `claude` process routes to MiniMax M2.7.
- Provides a diff viewer, a terminal panel, and Git integration — mimicking the Codex app shape.

**Everything Codex-like flows from this decomposition.** Threads are child processes. Projects are directories. Session resumption is `claude --resume <uuid>`. Context compaction is handled inside the CLI — we just display progress.

-----

## 1. Product overview

### 1.1 Product name

**ClaudeDeck** (working name; rename in `Info.plist` and `.xcodeproj` if user changes it).

### 1.2 One-line pitch

A native macOS command center for `claude` agents — with parallel threads organized by project, real-time streaming output, inline diffs, and a built-in terminal — configured out of the box to run against MiniMax M2.7 (or any Anthropic-compatible endpoint) via a `.env` file.

### 1.3 Primary user

A macOS developer who already uses `claude` (the CLI) and wants: (a) a window instead of a terminal, (b) multiple concurrent agents across multiple projects, (c) the ability to swap model providers cheaply by editing a `.env`.

### 1.4 Non-goals (do not build these)

- **Not** a reimplementation of the agent loop or tool system — we delegate to the CLI.
- **Not** a cloud-hosted product — local only.
- **Not** iOS/iPad — macOS 14+ (Sonoma) only, Apple Silicon and Intel.
- **Not** a generic AI chat client — it is tied to the `claude` CLI’s behavior.
- **Not** a replacement for the `/resume` picker inside the CLI — we parse session JSONL directly.

### 1.5 Success criteria

1. User clones repo → runs `./script/bootstrap.sh` → opens `.xcodeproj` in Xcode → hits Run → app launches.
1. User adds their MiniMax API key to `~/Library/Application Support/ClaudeDeck/.env` → opens Settings → sees “Provider: MiniMax M2.7 — Connected”.
1. User clicks “Add Project” → picks a folder → a new thread in that folder can be started and streams a response.
1. User starts two threads in two different projects → both run in parallel without blocking the UI.
1. Closing and reopening the app shows all prior threads with preserved history.
1. Running the test suite (`./script/test.sh`) passes with zero failures.

-----

## 2. Verified technical facts (do not second-guess)

These are facts I verified from primary sources before writing this spec. When the CLI behaves contrary to these, the CLI has changed — update this section, don’t silently adapt.

### 2.1 MiniMax M2.7 is an Anthropic-compatible endpoint

- Base URL (international): `https://api.minimax.io/anthropic`
- Base URL (China): `https://api.minimaxi.com/anthropic`
- Configuration is done via **environment variables** that `claude` reads: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and the `ANTHROPIC_*_MODEL` family.
- Model name to use: `MiniMax-M2.7`.
- Important: If `ANTHROPIC_API_KEY` is set in the user’s shell environment, it **takes precedence** over settings.json and can clash. The app must launch `claude` with a cleaned env — see §3.3.
- Recommended extra env: `API_TIMEOUT_MS=3000000`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`.
- **Known quirk:** Claude Code’s context-window detection for third-party providers defaults to 200K regardless of the real model window. Override with `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (e.g., `"MiniMax-M2.7:200000"`). We expose this in Settings (§8.4).

### 2.2 Claude Code session storage

- Location: `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`
- Encoding rule: replace every non-alphanumeric character in the absolute path with `-`. So `/Users/alice/proj` → `-Users-alice-proj`.
- Each line is one event: `user`, `assistant`, `tool_use`, `tool_result`, or a `summary` block.
- To resume: `claude --resume <session-uuid>` from the same cwd. The cwd **must match** — this is the #1 reason resume silently starts a fresh session.
- Global command index: `~/.claude/history.jsonl` (one line per slash-command invocation across all projects).

### 2.3 Claude CLI flags we rely on (verified)

|Flag                                 |Purpose                                                                                                        |
|-------------------------------------|---------------------------------------------------------------------------------------------------------------|
|`-p, --print`                        |Non-interactive mode (SDK-style) — we always use this.                                                         |
|`--output-format stream-json`        |Newline-delimited JSON events streamed to stdout.                                                              |
|`--input-format stream-json`         |Accept stream-json on stdin (for multi-turn within one process).                                               |
|`--resume <uuid>`                    |Resume a specific session.                                                                                     |
|`--continue`                         |Resume the most recent session in cwd.                                                                         |
|`--bare`                             |Skip OAuth/keychain reads; auth comes from env or `--settings`. **Required when setting env programmatically.**|
|`--allowedTools "Read,Edit,Bash,..."`|Whitelist tools.                                                                                               |
|`--settings <path-to-json>`          |Pass a settings file inline — lets us avoid mutating `~/.claude/settings.json`.                                |
|`--model <name>`                     |Override the model (we pass `MiniMax-M2.7`).                                                                   |
|`--cwd <path>`                       |Set the working directory.                                                                                     |

Invocation template we use everywhere (§6.3):

```bash
claude --bare -p \
  --output-format stream-json \
  --input-format stream-json \
  --settings /path/to/app-generated-settings.json \
  --cwd /path/to/project
```

### 2.4 stream-json event shape (what we parse)

Each line is a JSON object with a `type` field. The types we handle:

- `system` with `subtype: "init"` — first event, contains `session_id`, `model`, `tools`, `mcp_servers`.
- `system` with `subtype: "api_retry"` — emitted before retrying a failed API call.
- `user` — input message (echoed back when we stream input).
- `assistant` — model response, contains `content` array with `text` and `tool_use` blocks.
- `tool_use` — the agent is calling a tool. Contains `name`, `input`, `id`.
- `tool_result` — result of a tool call. Keyed by `tool_use_id`.
- `result` — final event of a turn. Contains the text result, `session_id`, `total_cost_usd`, `duration_ms`, `num_turns`, `is_error`.

We treat any line we don’t recognize as opaque and render it as a `system` note in the transcript. Do not crash on unknown types.

### 2.5 Xcode project starting point

The user says they will create a blank Xcode app. Assume:

- **Target platform:** macOS 14+
- **Interface:** SwiftUI
- **Language:** Swift
- **App lifecycle:** SwiftUI App
- **Project name:** `ClaudeDeck` (or whatever they named it — check `*.xcodeproj` in the repo and adapt)

-----

## 3. Architecture

### 3.1 High-level component diagram (as text)

```
┌─────────────────────────────────────────────────────────────────┐
│                     SwiftUI Scene (WindowGroup)                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                  NavigationSplitView                     │   │
│  │ ┌──────────┐ ┌───────────────────┐ ┌──────────────────┐  │   │
│  │ │ Sidebar  │ │   Detail: Thread  │ │ Inspector: Diff /│  │   │
│  │ │ Projects │ │   chat + input    │ │   Terminal       │  │   │
│  │ │ + Threads│ │   + status        │ │                  │  │   │
│  │ └──────────┘ └───────────────────┘ └──────────────────┘  │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
        ┌──────────────────────────────────────────────────┐
        │              AppState  (@Observable)             │
        │  projects[], activeThread, selection, settings   │
        └──────────────────────────────────────────────────┘
                │                       │
                ▼                       ▼
  ┌────────────────────────┐   ┌────────────────────────┐
  │   ThreadEngine         │   │   SessionStore         │
  │  (one per live thread) │   │  reads ~/.claude/...   │
  │   owns a child process │   │  JSONL transcripts     │
  └────────────────────────┘   └────────────────────────┘
                │
                ▼
  ┌─────────────────────────────────────────┐
  │  /usr/local/bin/claude  (child Process) │
  │  stdin: stream-json   stdout: stream-json │
  │  env:  MiniMax vars from .env             │
  └─────────────────────────────────────────┘
```

### 3.2 Directory layout

The Xcode project structure after all phases:

```
ClaudeDeck/
├── ClaudeDeck.xcodeproj/
├── ClaudeDeck/                          ← app source
│   ├── ClaudeDeckApp.swift              ← @main entry
│   ├── Info.plist
│   ├── ClaudeDeck.entitlements
│   ├── Assets.xcassets/
│   ├── Core/
│   │   ├── AppState.swift
│   │   ├── Models/
│   │   │   ├── Project.swift
│   │   │   ├── Thread.swift
│   │   │   ├── Message.swift
│   │   │   ├── ToolCall.swift
│   │   │   └── Settings.swift
│   │   ├── Config/
│   │   │   ├── EnvFileManager.swift     ← reads ~/Library/.../.env
│   │   │   ├── SettingsJSONBuilder.swift ← builds the --settings file
│   │   │   └── CLIDetector.swift         ← finds `claude` binary
│   │   ├── Process/
│   │   │   ├── ThreadEngine.swift       ← spawns & owns child process
│   │   │   ├── StreamJSONParser.swift   ← NDJSON line parser
│   │   │   └── ProcessOutputBuffer.swift
│   │   ├── Persistence/
│   │   │   ├── ProjectStore.swift       ← UserDefaults + JSON file
│   │   │   ├── SessionStore.swift       ← reads ~/.claude/projects/…
│   │   │   └── PathEncoder.swift        ← cwd→encoded-cwd logic
│   │   └── Git/
│   │       ├── GitRunner.swift
│   │       └── DiffParser.swift
│   ├── Views/
│   │   ├── Sidebar/
│   │   │   ├── SidebarView.swift
│   │   │   ├── ProjectRow.swift
│   │   │   └── ThreadRow.swift
│   │   ├── Thread/
│   │   │   ├── ThreadView.swift         ← chat transcript + composer
│   │   │   ├── MessageBubbleView.swift
│   │   │   ├── ToolCallView.swift
│   │   │   ├── ComposerView.swift
│   │   │   └── StatusBar.swift
│   │   ├── Inspector/
│   │   │   ├── InspectorView.swift
│   │   │   ├── DiffPaneView.swift
│   │   │   └── TerminalPaneView.swift
│   │   ├── Settings/
│   │   │   ├── SettingsScene.swift
│   │   │   └── ProviderSettingsView.swift
│   │   └── Onboarding/
│   │       └── FirstRunView.swift
│   └── Utilities/
│       ├── Logger.swift
│       └── Debouncer.swift
├── ClaudeDeckTests/                     ← unit tests
│   ├── StreamJSONParserTests.swift
│   ├── PathEncoderTests.swift
│   ├── EnvFileManagerTests.swift
│   ├── SettingsJSONBuilderTests.swift
│   └── SessionStoreTests.swift
├── ClaudeDeckUITests/                   ← headless smoke tests
│   └── ClaudeDeckUITests.swift
├── script/
│   ├── bootstrap.sh                     ← one-time setup
│   ├── build_and_run.sh                 ← CLI build + launch
│   ├── test.sh                          ← runs unit tests via xcodebuild
│   ├── integration_test.sh              ← spawns claude, sends a prompt
│   └── doctor.sh                        ← env + CLI sanity check
├── .env.example                         ← template user copies
├── BUILD_LOG.md                         ← you append to this every phase
├── README.md
└── PRD.md                               ← this document
```

### 3.3 Environment contract between the app and the `claude` child process

This is the single most important contract in the app. Get it wrong and nothing works.

**Rule 1.** The child process inherits a **cleaned** environment. We start from `ProcessInfo.processInfo.environment`, then:

- Remove: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, and all `CLAUDE_*` vars except those we explicitly set.
- Add from our `.env` file: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`, plus the `ANTHROPIC_*_MODEL` family all pointing at the chosen model.
- Add fixed: `API_TIMEOUT_MS=3000000`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`.
- Optionally add: `CLAUDE_CODE_MAX_CONTEXT_TOKENS=MiniMax-M2.7:200000` (from Settings).
- Preserve: `PATH`, `HOME`, `USER`, `SHELL`, `LANG`, `LC_ALL`, `TMPDIR`, `TERM=dumb`.

**Rule 2.** Pass `--bare` so the CLI does not read the OAuth keychain or `~/.claude/settings.json`. All config flows through `--settings` and env.

**Rule 3.** The `--settings` file is written to a temp path (not `~/.claude/settings.json`) so the user’s existing CLI setup is not disturbed. Delete the temp file when the process exits.

**Rule 4.** Working directory is set via both the `cwd` property on `Process` **and** the `--cwd` flag. Belt and suspenders — the CLI occasionally prefers one over the other depending on version.

### 3.4 Where the app stores its own state

- `~/Library/Application Support/ClaudeDeck/.env` — user’s provider credentials (chmod 600).
- `~/Library/Application Support/ClaudeDeck/projects.json` — list of known projects and their metadata.
- `~/Library/Application Support/ClaudeDeck/logs/claudedeck-<date>.log` — app log (rolled daily).
- Transcript data is **not** duplicated here — we read from `~/.claude/projects/<encoded>/` directly so the CLI remains the source of truth.

-----

## 4. Feature list (authoritative)

Each feature is labeled with the phase (§5–§14) that delivers it.

|#  |Feature                                                                           |Phase|
|---|----------------------------------------------------------------------------------|-----|
|F1 |App launches and shows empty state                                                |5    |
|F2 |CLI detection (finds `claude` on PATH or in `/usr/local/bin`, `/opt/homebrew/bin`)|5    |
|F3 |`.env` file loader + chmod 600 enforcement                                        |5    |
|F4 |Settings scene — provider, model, base URL, API key (masked), timeout             |6    |
|F5 |Doctor panel — verifies each env var, attempts a ping to the base URL             |6    |
|F6 |Sidebar with Projects, each containing Threads                                    |7    |
|F7 |“Add Project” via folder picker                                                   |7    |
|F8 |“New Thread” button per project                                                   |7    |
|F9 |ThreadEngine: spawns `claude`, streams NDJSON, renders into chat                  |8    |
|F10|Composer with multi-line input, ⌘⏎ to send, ⌘. to interrupt                       |8    |
|F11|Tool-call rendering (collapsed cards with name, input preview, result)            |8    |
|F12|Token + cost counters in status bar (parsed from `result` events)                 |8    |
|F13|Parallel threads — spawn N child processes without UI blocking                    |9    |
|F14|Thread resume — list prior sessions per project, tap to resume                    |9    |
|F15|Auto-resume on app relaunch (remembers last-open threads)                         |9    |
|F16|Inspector: Git diff pane showing uncommitted changes                              |10   |
|F17|Inspector: embedded terminal (PTY) scoped to project cwd                          |10   |
|F18|Context-usage bar with compaction warnings                                        |11   |
|F19|Stop / interrupt via signal to child process                                      |11   |
|F20|Permissions prompts (tool approval dialog)                                        |11   |
|F21|Crash recovery — child dies, thread shows retry button                            |12   |
|F22|`script/doctor.sh` + in-app Doctor view                                           |12   |
|F23|Full test suite (unit + integration)                                              |13   |
|F24|README + BUILD_LOG + code signing note                                            |14   |

-----

## 5. Phase 1 — Project scaffolding and the empty app

### 5.1 Goal

App launches, shows a three-pane NavigationSplitView with placeholder content, and the bootstrap script works from a fresh clone.

### 5.2 Steps (perform in order)

1. Confirm the Xcode project exists in the repo. If it does not, create one:
- `File → New → Project → macOS → App`, name `ClaudeDeck`, interface **SwiftUI**, language **Swift**, uncheck Core Data and Tests (we add tests manually).
- Minimum deployment target: **macOS 14.0**.
1. Add two test targets (unit + UI). In `File → New → Target → macOS → Unit Testing Bundle`, name `ClaudeDeckTests`. Repeat for `ClaudeDeckUITests`.
1. Create the folder structure from §3.2. You can create the on-disk folders with `mkdir -p` and then drag them into Xcode as groups (*not* file references) so the Project Navigator matches.
1. Replace `ContentView.swift` with a `NavigationSplitView` using three columns: sidebar (placeholder list), detail (placeholder text “No thread selected”), inspector (collapsed). Use `@SceneStorage` for the sidebar/inspector column widths.
1. Add a `Settings { }` scene to `ClaudeDeckApp.swift` with a single placeholder text view — we flesh it out in Phase 6.
1. Add entitlements:
- `com.apple.security.files.user-selected.read-write` (for the project picker).
- `com.apple.security.network.client` (for doctor pings).
- App sandbox: **disabled** for now (we spawn child processes and read arbitrary paths). Revisit in Phase 14.
1. Create `script/bootstrap.sh`:
   
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   # Verify Xcode and claude are installed
   command -v xcodebuild >/dev/null || { echo "Xcode CLT not found"; exit 1; }
   command -v claude >/dev/null || echo "WARN: claude CLI not on PATH — app will prompt later"
   # Create app support dir
   SUPPORT="$HOME/Library/Application Support/ClaudeDeck"
   mkdir -p "$SUPPORT"
   # Seed .env if missing
   if [ ! -f "$SUPPORT/.env" ]; then
     cp "$(dirname "$0")/../.env.example" "$SUPPORT/.env"
     chmod 600 "$SUPPORT/.env"
     echo "Created $SUPPORT/.env — edit to add your MiniMax API key"
   fi
   echo "Bootstrap complete. Open ClaudeDeck.xcodeproj in Xcode and press Run."
   ```
1. Create `.env.example`:
   
   ```
   # ClaudeDeck configuration — edit this file and restart the app
   ANTHROPIC_BASE_URL=https://api.minimax.io/anthropic
   ANTHROPIC_AUTH_TOKEN=sk-your-minimax-key-here
   ANTHROPIC_MODEL=MiniMax-M2.7
   ANTHROPIC_SMALL_FAST_MODEL=MiniMax-M2.7
   ANTHROPIC_DEFAULT_SONNET_MODEL=MiniMax-M2.7
   ANTHROPIC_DEFAULT_OPUS_MODEL=MiniMax-M2.7
   ANTHROPIC_DEFAULT_HAIKU_MODEL=MiniMax-M2.7
   API_TIMEOUT_MS=3000000
   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
   # Optional — force a context window size for third-party providers
   # CLAUDE_CODE_MAX_CONTEXT_TOKENS=MiniMax-M2.7:200000
   ```
1. Create `script/build_and_run.sh`:
   
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   cd "$(dirname "$0")/.."
   xcodebuild -scheme ClaudeDeck -configuration Debug \
     -destination 'platform=macOS' build \
     -derivedDataPath ./build | xcbeautify || true
   APP_PATH="./build/Build/Products/Debug/ClaudeDeck.app"
   pkill -f ClaudeDeck || true
   open "$APP_PATH"
   ```
1. Create `BUILD_LOG.md` with an H1 title and a “Phase 1” H2 section documenting what you did and the exact `xcodebuild` command output.

### 5.3 Acceptance for Phase 1

- [ ] `./script/bootstrap.sh` runs clean on a fresh machine.
- [ ] `./script/build_and_run.sh` compiles and launches the app.
- [ ] Window shows three panes with placeholder content.
- [ ] `$HOME/Library/Application Support/ClaudeDeck/.env` exists after bootstrap with mode `600`.
- [ ] `BUILD_LOG.md` has a Phase 1 entry.

-----

## 6. Phase 2 — Settings, env loading, and Doctor

### 6.1 Goal

A working Settings scene where the user sees their MiniMax configuration, and a Doctor check that verifies each piece.

### 6.2 Models

Create `Core/Models/Settings.swift`:

```swift
struct ProviderSettings: Codable, Equatable {
    var baseURL: String
    var authToken: String
    var model: String
    var smallFastModel: String
    var defaultSonnetModel: String
    var defaultOpusModel: String
    var defaultHaikuModel: String
    var apiTimeoutMs: Int
    var disableNonessentialTraffic: Bool
    var maxContextTokensOverride: String?  // e.g. "MiniMax-M2.7:200000"

    static var miniMaxDefault: ProviderSettings {
        ProviderSettings(
            baseURL: "https://api.minimax.io/anthropic",
            authToken: "",
            model: "MiniMax-M2.7",
            smallFastModel: "MiniMax-M2.7",
            defaultSonnetModel: "MiniMax-M2.7",
            defaultOpusModel: "MiniMax-M2.7",
            defaultHaikuModel: "MiniMax-M2.7",
            apiTimeoutMs: 3_000_000,
            disableNonessentialTraffic: true,
            maxContextTokensOverride: "MiniMax-M2.7:200000"
        )
    }
}
```

### 6.3 EnvFileManager

Create `Core/Config/EnvFileManager.swift`. Responsibilities:

- Locate the .env at `~/Library/Application Support/ClaudeDeck/.env`.
- Parse it as `KEY=VALUE` lines, ignoring blanks and `#` comments. No shell-style expansion.
- Expose `load() -> ProviderSettings`, `save(_ settings: ProviderSettings)` that writes atomically (temp file + rename) and re-applies `chmod 600`.
- Expose `buildChildEnv() -> [String: String]` that produces the env dict to pass to a child process, following §3.3 rules exactly. This is the single function every `Process.environment` assignment in the app calls.

Unit test (`EnvFileManagerTests`):

- Round-trip: write → read → compare.
- `buildChildEnv` strips conflicting vars even if planted in `ProcessInfo.processInfo.environment`.
- Invalid .env file (bad line) surfaces an error with the line number.

### 6.4 SettingsJSONBuilder

Create `Core/Config/SettingsJSONBuilder.swift`. Responsibilities:

- Given a `ProviderSettings`, write a temporary JSON file formatted for `claude --settings`. Minimum structure (from CLI docs):
  
  ```json
  {
    "env": {
      "ANTHROPIC_BASE_URL": "...",
      "ANTHROPIC_AUTH_TOKEN": "...",
      "ANTHROPIC_MODEL": "..."
      // etc.
    }
  }
  ```
- Return the temp file URL. Caller is responsible for deleting it.

Unit test: the written file parses as valid JSON and contains every expected key.

### 6.5 CLIDetector

Create `Core/Config/CLIDetector.swift`. Resolution order:

1. `CLAUDEDECK_CLI_PATH` env override.
1. `which claude` via `/usr/bin/env`.
1. Common Homebrew locations: `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`.
1. `~/.claude/local/bin/claude`.
   Return `URL?` plus a resolved `version` string by running `claude --version`.

Unit test: injectable `ShellRunner` protocol so we can fake `which` output.

### 6.6 Settings scene

In `SettingsScene.swift`, build a TabView with two tabs:

**Provider tab:**

- Text field for Base URL.
- Secure field for Auth Token (show/hide toggle).
- Text field for Model (default MiniMax-M2.7; show dropdown with M2.7, M2.5, custom).
- Disclosure group “Advanced”: timeout ms, context window override, non-essential traffic toggle.
- “Save” button → writes via `EnvFileManager.save`. Show a non-modal toast “Settings saved. New threads will use the new provider; running threads keep the old one.”

**Doctor tab:**

- Live checklist:
1. `claude` binary found at *path*.
1. `claude --version` returns *version*.
1. `.env` file readable at *path*, mode *0600*.
1. `ANTHROPIC_BASE_URL` is a well-formed URL.
1. `ANTHROPIC_AUTH_TOKEN` is non-empty (don’t print it).
1. Ping test: POST a tiny message to `<baseURL>/v1/messages` with the auth token, expect HTTP 200 or 400 (400 is fine — means the endpoint accepted auth and parsed).
- “Re-run checks” button.

### 6.7 Acceptance for Phase 2

- [ ] Settings scene opens via ⌘, and all fields load from `.env`.
- [ ] Saving updates `.env` in place (verified by `cat ~/Library/.../.env` in terminal).
- [ ] Doctor shows all green when a valid key is in place.
- [ ] Doctor correctly flags a missing or malformed key with a human-readable message.
- [ ] Unit tests for EnvFileManager, SettingsJSONBuilder, PathEncoder pass.
- [ ] BUILD_LOG has a Phase 2 entry with the unit test command + output.

-----

## 7. Phase 3 — Projects & threads data model

### 7.1 Goal

User can add projects (folders) and create thread records. Threads don’t run yet — we just store them.

### 7.2 Models

`Core/Models/Project.swift`:

```swift
struct Project: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var rootPath: URL          // absolute
    var createdAt: Date
    var color: String          // SF symbol-friendly tint
}
```

`Core/Models/Thread.swift`:

```swift
struct Thread: Codable, Identifiable, Equatable {
    var id: UUID
    var projectId: UUID
    var title: String          // user-editable; defaults to first prompt truncated
    var sessionId: String?     // populated once claude emits its first system/init event
    var createdAt: Date
    var lastActivityAt: Date
    var status: ThreadStatus   // idle | running | error(String)
}
```

`Core/Models/Message.swift` — discriminated union over `.user`, `.assistantText`, `.toolCall(ToolCall)`, `.toolResult(ToolResult)`, `.systemNote`, `.error`. Each carries a timestamp and a UUID.

### 7.3 PathEncoder

`Core/Persistence/PathEncoder.swift`:

```swift
enum PathEncoder {
    /// Mirrors ~/.claude/projects/<encoded> encoding: replace every non-alphanumeric char with '-'.
    static func encode(_ url: URL) -> String {
        let absolute = url.standardizedFileURL.path
        return String(absolute.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}
```

Unit test this with: `/Users/alice/my project` → `-Users-alice-my-project`, `/Users/alice/proj` → `-Users-alice-proj`, and a path containing unicode → all non-ascii-alphanumerics become `-`.

### 7.4 ProjectStore

`Core/Persistence/ProjectStore.swift`:

- Loads/saves `projects.json` in the app support dir.
- Publishes `[Project]` and `[Thread]` as `@Observable`.
- Methods: `addProject(at: URL) -> Project`, `removeProject(_: UUID)`, `createThread(in: UUID) -> Thread`, `updateThread(_: Thread)`.

### 7.5 Sidebar UI

`Views/Sidebar/SidebarView.swift`:

- `List { OutlineGroup(projects, children: \.threads) { ... } }` pattern.
- Toolbar button “+” with menu: “Add Project…”, “Import from Claude Code” (scans `~/.claude/projects/` and surfaces directories the user can adopt).
- Context menu on project: Rename, Remove, Show in Finder, New Thread.
- Context menu on thread: Rename, Duplicate (fork), Delete.

### 7.6 Acceptance for Phase 3

- [ ] “Add Project…” opens `NSOpenPanel` with directory-only + user-selected permissions.
- [ ] Selected directory appears in sidebar and persists across app restarts.
- [ ] “New Thread” creates a row under the project with status `idle`.
- [ ] Deleting a project prompts confirmation and removes all its threads.
- [ ] Unit tests for ProjectStore round-trip.
- [ ] BUILD_LOG phase entry.

-----

## 8. Phase 4 — ThreadEngine (the core)

### 8.1 Goal

Clicking a thread, typing a prompt, and hitting send actually spawns `claude`, streams the response, and renders it.

### 8.2 StreamJSONParser

`Core/Process/StreamJSONParser.swift`:

- Accepts `Data` chunks as they arrive from stdout. Buffers until a newline, then decodes each complete line as JSON.
- Decodes into a `ClaudeEvent` enum with associated values for the six types in §2.4, plus a `.unknown(rawJSON: String)` case.
- Publishes events via `AsyncStream<ClaudeEvent>`.
- Robust to partial UTF-8 sequences (buffer raw bytes, only decode to string on newline-complete chunk).

Unit tests — critical, most bugs live here:

- Single complete event in one chunk.
- Event split across two chunks.
- Multiple events in one chunk.
- Unicode that straddles a chunk boundary.
- Malformed JSON on one line doesn’t kill the stream — emit `.unknown` and continue.

### 8.3 ThreadEngine

`Core/Process/ThreadEngine.swift`. This class owns a single child process for the lifetime of one thread.

```swift
@Observable
final class ThreadEngine {
    let thread: Thread
    let project: Project

    private(set) var messages: [Message] = []
    private(set) var state: EngineState = .idle   // idle | starting | running | stopped | errored
    private(set) var currentTokens: Int = 0
    private(set) var lastCostUsd: Double = 0

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var parser: StreamJSONParser?
    private var settingsFileURL: URL?

    func send(_ userText: String) async throws { ... }
    func interrupt() { process?.interrupt() }  // SIGINT, graceful
    func terminate() { process?.terminate() }
    func resume(sessionId: String) async throws { ... }
}
```

### 8.4 Exact spawn sequence

```swift
func start() async throws {
    let cliURL = try CLIDetector.resolve()
    let settingsURL = try SettingsJSONBuilder.write(current: envManager.load())
    self.settingsFileURL = settingsURL

    let p = Process()
    p.executableURL = cliURL
    p.arguments = [
        "--bare",
        "-p",
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--settings", settingsURL.path,
        "--cwd", project.rootPath.path,
    ]
    if let sid = thread.sessionId {
        p.arguments?.append(contentsOf: ["--resume", sid])
    }
    p.environment = envManager.buildChildEnv()
    p.currentDirectoryURL = project.rootPath

    let inPipe  = Pipe()
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardInput  = inPipe
    p.standardOutput = outPipe
    p.standardError  = errPipe

    self.stdin  = inPipe.fileHandleForWriting
    self.stdout = outPipe.fileHandleForReading

    let parser = StreamJSONParser()
    self.parser = parser

    // Pipe stdout → parser on a background task
    Task.detached { [weak self] in
        for try await chunk in outPipe.fileHandleForReading.bytes {
            parser.feed(chunk)
        }
    }

    // Consume parsed events on the main actor
    Task { @MainActor [weak self] in
        for await event in parser.events {
            self?.handle(event)
        }
    }

    try p.run()
    self.process = p
    self.state = .running
}
```

### 8.5 Sending a user message

stream-json input format: a single JSON object per line with shape:

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}
```

```swift
func send(_ userText: String) async throws {
    let payload: [String: Any] = [
        "type": "user",
        "message": [
            "role": "user",
            "content": [["type": "text", "text": userText]]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload) + Data([0x0A])
    try stdin?.write(contentsOf: data)
    messages.append(.user(userText, Date()))
}
```

### 8.6 Handling events

```swift
@MainActor
private func handle(_ event: ClaudeEvent) {
    switch event {
    case .systemInit(let init):
        thread.sessionId = init.sessionId
        projectStore.updateThread(thread)
    case .assistantText(let text):
        appendOrCoalesceAssistantText(text)
    case .toolUse(let call):
        messages.append(.toolCall(call))
    case .toolResult(let result):
        attachResult(result, to: call(result.toolUseId))
    case .result(let r):
        currentTokens = r.totalTokens
        lastCostUsd += r.totalCostUsd
        state = .idle  // turn complete, ready for next prompt
    case .systemApiRetry:
        messages.append(.systemNote("API retry…"))
    case .unknown(let raw):
        logger.warn("Unknown stream-json event: \(raw)")
    }
}
```

### 8.7 Composer and rendering

`Views/Thread/ComposerView.swift`: a `TextEditor` that auto-resizes up to 8 lines, a Send button, and keyboard shortcut ⌘⏎.

`Views/Thread/MessageBubbleView.swift`: one view per message variant. Use `Text` with markdown for assistant text. Render code fences with a dark background.

`Views/Thread/ToolCallView.swift`: collapsed card, showing tool name + one-line input summary. Expanded shows full input JSON and result. Status dot (yellow running / green success / red error).

### 8.8 Acceptance for Phase 4

- [ ] Selecting a thread and typing “hi” + ⌘⏎ streams an assistant response.
- [ ] Session ID is captured and stored in the thread.
- [ ] Tool calls render as cards — confirmed by asking the agent to read a file.
- [ ] Cost counter increments after each turn.
- [ ] Closing the app mid-response terminates the child process cleanly (no zombie `claude` in Activity Monitor).
- [ ] Unit tests for StreamJSONParser pass all six edge cases.
- [ ] BUILD_LOG phase entry with a screenshot path placeholder.

-----

## 9. Phase 5 — Parallel threads + resume

### 9.1 Goal

Multiple threads run concurrently. Existing Claude Code sessions on disk are discoverable and resumable.

### 9.2 SessionStore (read-only view of ~/.claude)

`Core/Persistence/SessionStore.swift`:

- `func listSessions(for project: Project) -> [SessionSummary]`:
1. Compute encoded cwd via `PathEncoder.encode(project.rootPath)`.
1. List `~/.claude/projects/<encoded>/*.jsonl`.
1. For each file: read first and last lines, extract `sessionId`, created timestamp, and a title (first user message, truncated to 60 chars).
1. Return sorted by modified date, newest first.
- `func messages(for sessionId: String, in project: Project) -> AsyncThrowingStream<Message>`:
  - Streams the JSONL file line-by-line, decoding into `Message`. Used when a user clicks “Resume” — we replay history into the UI before starting the child process.

Unit test with a fixture JSONL file in `ClaudeDeckTests/Fixtures/sample-session.jsonl`.

### 9.3 “Import from Claude Code”

When the user clicks this in the sidebar add menu, we show a panel with every directory in `~/.claude/projects/` decoded back to a path. They can tick which ones to adopt; we create Project rows for each with all their sessions pre-listed as threads (status `idle`, sessionId set).

### 9.4 Parallelism

- Each `ThreadEngine` is independent. They live in `AppState.activeEngines: [UUID: ThreadEngine]`.
- UI never blocks on engine state. All mutations happen on `@MainActor`, but parser/stdout reads happen on a detached task.
- Cap concurrent running engines at 8 by default (configurable in Settings → Advanced). Beyond that, show a “queued” badge; the engine starts when a slot opens.

### 9.5 Acceptance for Phase 5

- [ ] Starting 3 threads in 3 different projects: all three stream in parallel, UI stays at 60fps.
- [ ] Clicking a historical session in the sidebar replays its transcript, then enables the composer, and sends new messages into the same session.
- [ ] Force-quitting the app and reopening: every previously-running thread shows status `errored (child died)` with a “Resume” button that restarts via `--resume`.
- [ ] Import from Claude Code works on a machine that has existing `~/.claude/projects/` entries.
- [ ] BUILD_LOG phase entry.

-----

## 10. Phase 6 — Inspector: Diff + Terminal

### 10.1 Goal

Right-pane inspector shows Git diff for the current project and provides a real PTY terminal rooted in the project.

### 10.2 Diff pane

`Core/Git/GitRunner.swift` wraps `git` CLI calls (`git diff`, `git status --porcelain=v2`, `git add`, `git reset HEAD`, `git commit`). Use `Process` with `/usr/bin/env git`.

`Views/Inspector/DiffPaneView.swift`:

- Auto-refresh via file-system observation (`DispatchSource.makeFileSystemObjectSource` on the project’s `.git/index`).
- Show a file tree with per-file “+/−” counts and a right-side unified diff view.
- Action buttons: Stage, Unstage, Revert (confirm), Commit (opens a sheet with message field).

### 10.3 Terminal pane

Use **SwiftTerm** (https://github.com/migueldeicaza/SwiftTerm) — mature, Apache-licensed Swift terminal emulator. Add via Swift Package Manager.

`Views/Inspector/TerminalPaneView.swift`:

- Wraps SwiftTerm’s `LocalProcessTerminalView`.
- Spawns the user’s `$SHELL` (default `/bin/zsh`) with `-l`.
- cwd = current project’s root.
- Env = same cleaned env we build for claude, so the user can invoke `claude` manually inside and get the same provider.
- ⌘J toggles the inspector; when focused, normal shell keystrokes work. Do not intercept ⌘⏎ etc. when the terminal has focus.

### 10.4 Acceptance for Phase 6

- [ ] Editing a file outside the app shows new diff within 1s.
- [ ] Terminal opens and executing `pwd` prints the project root.
- [ ] Running `env | grep ANTHROPIC` inside the terminal shows MiniMax values.
- [ ] Running `claude --version` inside the terminal succeeds.
- [ ] BUILD_LOG phase entry.

-----

## 11. Phase 7 — Context bar, interrupt, and permissions

### 11.1 Context usage bar

- StatusBar at the bottom of ThreadView shows: `tokens used / context window` as a bar, plus model name and cumulative cost.
- Context window defaults to the value from `CLAUDE_CODE_MAX_CONTEXT_TOKENS` override, or 200K.
- When used > 85% of window, show a yellow warning “Approaching context limit — agent will auto-compact soon”. Claude Code handles compaction itself; we just surface the progress.

### 11.2 Interrupt

- “Stop” button in StatusBar while running. Sends SIGINT to the child. If it does not exit within 3 seconds, escalate to SIGTERM, then SIGKILL.
- ⌘. keyboard shortcut equivalent.

### 11.3 Permissions prompts

- The CLI may emit `tool_use` events that pause awaiting approval when run without `--allowedTools` or with `permission_mode: manual`. Our default mode is `acceptEdits` for a Codex-like flow, but Settings exposes a dropdown:
  - **Accept all** (autonomous)
  - **Accept edits** (default — approve file edits, ask for shell)
  - **Manual** (ask for every tool)
- In Manual mode, when the parser sees a tool_use without a later tool_result, we show an inline sheet with Approve / Deny / Approve always for this tool.

### 11.4 Acceptance for Phase 7

- [ ] Context bar updates after each turn.
- [ ] Pressing ⌘. mid-stream cleanly stops the agent and the UI shows “Interrupted by user”.
- [ ] Changing permissions mode in Settings takes effect on new threads.
- [ ] BUILD_LOG phase entry.

-----

## 12. Phase 8 — Crash recovery, Doctor, polish

### 12.1 Crash recovery

- If a `ThreadEngine`’s child process exits with a non-zero code or a signal, the thread goes to `.errored`. UI shows the stderr tail in a collapsed group and offers **Retry** (same prompt, new session) or **Resume** (same session id, new child).
- If the child exits within the first 2 seconds of start, we assume auth/config failure and offer a shortcut to Settings → Provider.

### 12.2 `script/doctor.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
echo "== ClaudeDeck Doctor =="
command -v claude >/dev/null && echo "✓ claude CLI: $(which claude)" || { echo "✗ claude CLI not found"; exit 1; }
claude --version
[ -f "$HOME/Library/Application Support/ClaudeDeck/.env" ] && echo "✓ .env present" || echo "✗ .env missing — run script/bootstrap.sh"
perm=$(stat -f '%A' "$HOME/Library/Application Support/ClaudeDeck/.env" 2>/dev/null || echo "")
[ "$perm" = "600" ] && echo "✓ .env mode 600" || echo "⚠ .env mode is $perm — should be 600"
set -a; . "$HOME/Library/Application Support/ClaudeDeck/.env"; set +a
[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && echo "✓ ANTHROPIC_AUTH_TOKEN set (hidden)" || echo "✗ ANTHROPIC_AUTH_TOKEN missing"
[ -n "${ANTHROPIC_BASE_URL:-}" ] && echo "✓ ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL" || echo "✗ ANTHROPIC_BASE_URL missing"
echo "-- ping base URL --"
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "$ANTHROPIC_BASE_URL/v1/messages" \
  -H "x-api-key: $ANTHROPIC_AUTH_TOKEN" -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"'"$ANTHROPIC_MODEL"'","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' || echo "ping failed"
```

### 12.3 Polish

- App icon (placeholder — SF Symbol `rectangle.stack.badge.play` rendered at export sizes; user can replace).
- About panel with version, CLI version, links.
- Menu bar commands: New Thread (⌘N), New Project (⇧⌘N), Close Thread (⌘W), Settings (⌘,), Toggle Inspector (⌘⇧I), Toggle Terminal (⌘J).
- Dark mode support — use semantic colors only.

### 12.4 Acceptance for Phase 8

- [ ] `kill -9` on a child while running shows recovery UI.
- [ ] `./script/doctor.sh` exits 0 on a configured machine.
- [ ] All menu commands work and show in the Command Palette (⌘⇧P if you add one; otherwise just the menu bar).
- [ ] BUILD_LOG phase entry.

-----

## 13. Phase 9 — Testing

### 13.1 Unit tests (run via `script/test.sh`)

Target coverage: every class under `Core/` has tests. Minimum required:

- `StreamJSONParserTests` — 8+ cases (see §8.2).
- `PathEncoderTests` — 5+ cases including unicode and paths with spaces.
- `EnvFileManagerTests` — round-trip, env cleaning, bad file handling.
- `SettingsJSONBuilderTests` — valid JSON, all keys present.
- `SessionStoreTests` — uses fixture file at `ClaudeDeckTests/Fixtures/sample-session.jsonl` (you create this yourself — a 5-message transcript).
- `ProjectStoreTests` — CRUD round-trip.
- `CLIDetectorTests` — with a mock ShellRunner.

`script/test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild test \
  -scheme ClaudeDeck \
  -destination 'platform=macOS' \
  -only-testing:ClaudeDeckTests \
  -derivedDataPath ./build | xcbeautify
```

### 13.2 Integration test

`script/integration_test.sh` — end-to-end without the UI:

```bash
#!/usr/bin/env bash
set -euo pipefail
# 1. Ensure bootstrap has run.
# 2. Load .env.
set -a; . "$HOME/Library/Application Support/ClaudeDeck/.env"; set +a
# 3. Spawn claude in stream-json mode and send a single prompt.
TMPDIR=$(mktemp -d)
SETTINGS="$TMPDIR/settings.json"
cat > "$SETTINGS" <<EOF
{"env":{"ANTHROPIC_BASE_URL":"$ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN":"$ANTHROPIC_AUTH_TOKEN","ANTHROPIC_MODEL":"$ANTHROPIC_MODEL"}}
EOF
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Say only the word PONG and nothing else."}]}}' \
  | claude --bare -p --output-format stream-json --input-format stream-json --settings "$SETTINGS" --cwd "$TMPDIR" \
  | tee "$TMPDIR/out.jsonl"
grep -q '"PONG"' "$TMPDIR/out.jsonl" && echo "✓ integration pass" || { echo "✗ integration fail — see $TMPDIR/out.jsonl"; exit 1; }
```

This test validates the entire environment contract end-to-end without involving any Swift code.

### 13.3 UI smoke test

In `ClaudeDeckUITests`, one test: app launches, title bar reads “ClaudeDeck”, sidebar is present, Settings opens on ⌘,. That’s enough — UI tests are flaky and we don’t want to depend on them in CI.

### 13.4 Acceptance for Phase 9

- [ ] `./script/test.sh` — all unit tests pass.
- [ ] `./script/integration_test.sh` — passes on a configured machine.
- [ ] CI-style command `./script/test.sh && ./script/integration_test.sh` in the README as a self-check for new contributors.
- [ ] BUILD_LOG phase entry with test output summary.

-----

## 14. Phase 10 — Documentation & delivery

### 14.1 README.md

Write this last, after everything works. Sections:

1. **What is ClaudeDeck** (2 paragraphs).
1. **Requirements** — macOS 14+, Xcode 16+, `claude` CLI ≥ latest, a MiniMax API key.
1. **Install & first run** — `git clone`, `./script/bootstrap.sh`, open `.xcodeproj`, Run.
1. **Configure your provider** — explains the `.env` file, points at `.env.example`.
1. **Using the app** — Projects, threads, inspector, terminal, resume, shortcuts (as a table).
1. **Switching providers** — how to swap from MiniMax to official Anthropic or GLM or Novita by editing `.env`.
1. **Troubleshooting** — run `./script/doctor.sh`, common issues (context window, shell env pollution, codesign warnings).
1. **Architecture summary** — one paragraph + link to PRD.md.
1. **License** — MIT.

### 14.2 Code signing note

Document in README that for personal use, unsigned local builds work. For distribution, the user needs a Developer ID Application certificate and to notarize. Provide a one-liner:

```bash
codesign --deep --force --sign "Developer ID Application: YOUR NAME" ./build/.../ClaudeDeck.app
```

Mention that sandboxing is **disabled** intentionally because the app spawns arbitrary child processes and reads user-chosen directories.

### 14.3 BUILD_LOG.md final entry

- Table of every phase, start/end date, total commits (if git).
- List of deviations from this PRD.
- Open bugs / known limitations.
- Suggestions for v2 (MCP config editor, subagents, web search skill, etc.).

### 14.4 Final acceptance

- [ ] README complete and accurate — a new developer can follow it to a working build.
- [ ] All 10 phase entries in BUILD_LOG.
- [ ] Running `./script/bootstrap.sh && ./script/test.sh && ./script/integration_test.sh && ./script/build_and_run.sh` from a fresh clone produces a working app.
- [ ] At least one demonstration session recorded — start a thread, write a file, see it on disk, resume after closing the app.

-----

## 15. Known pitfalls (read before you trip over them)

1. **Environment leakage.** If the user has `ANTHROPIC_API_KEY` in their `~/.zshrc`, it wins over our `--settings` file. That is why §3.3 Rule 1 demands an explicit strip, and why we always pass `--bare`.
1. **Session resume from wrong cwd silently starts a new session.** Always set both `Process.currentDirectoryURL` **and** `--cwd`.
1. **Context window auto-detection is wrong for third-party providers.** We ship with `CLAUDE_CODE_MAX_CONTEXT_TOKENS` pre-set. If the user swaps providers, the override may be wrong — surface this in Settings.
1. **Path encoding uses non-alphanumeric → `-`, not just `/` → `-`.** The documentation in various places simplifies it; always use the full rule. Your test suite must lock this.
1. **`Pipe().fileHandleForReading.bytes` is Apple’s `AsyncBytes` on macOS 12+.** On older macOS, use a `DispatchSource` readable source. Your deployment target is 14, so you are fine.
1. **Tool-use events and result events may interleave across concurrent tool calls.** Match by `tool_use_id`, never by order.
1. **The CLI sometimes emits a partial line on exit without a trailing newline.** Your parser must flush on EOF.
1. **`claude --version` output has changed across releases.** Parse loosely — just grab the first semver-shaped string.
1. **SwiftTerm’s child process uses a PTY, not a Pipe.** Don’t try to re-use the `ThreadEngine` pipe wiring for the terminal pane.
1. **MiniMax endpoint returns streaming tokens with slightly different metadata than api.anthropic.com** — specifically `total_cost_usd` may be absent or zero. Treat it as optional.

-----

## 16. Prompt guide for running this build on MiniMax M2.7 itself

You, the Claude Code instance implementing this, may be running on MiniMax M2.7. That model is capable but benefits from the following constraints — apply them to your own workflow:

1. **One phase per “session” of work.** Don’t try to build Phase 4 and Phase 5 in one pass. Start a new session for each phase so the context stays focused on current goals.
1. **Read this PRD into context once, then reference section numbers.** Do not paste whole sections back and forth — cite them (e.g., “per §3.3 Rule 1”).
1. **Prefer many small `Edit` operations over giant `Write` replacements.** The model is more accurate on targeted changes.
1. **After every file you create, immediately compile.** `xcodebuild -scheme ClaudeDeck build` catches 90% of Swift issues within seconds.
1. **When writing unit tests, write the test first, watch it fail, then implement.** This is doubly important on a smaller model — the spec pressure keeps the implementation honest.
1. **If stuck on a compile error for more than 2 attempts, read the full surrounding file rather than trying more blind edits.** Context refresh beats guessing.
1. **Before declaring a phase complete, run every single checkbox in its “Acceptance” section and paste the output into BUILD_LOG.** No “I think this works” — only “I ran X, it output Y”.
1. **Use `TODO: verify against PRD §X.Y` comments liberally.** A human reviewer (or another Claude) can sweep these later.
1. **If the CLI behaves in a way §2 didn’t predict, stop and document the surprise in BUILD_LOG before proceeding.** The spec is wrong-ish more often than the CLI.
1. **Never weaken the environment contract (§3.3) to make something work.** If env cleaning causes a failure, the root cause is elsewhere.

-----

## 17. Quick-start checklist (the TL;DR you’ll want on your wall)

```
□ Phase 1: Scaffold + bootstrap.sh + empty 3-pane window
□ Phase 2: Settings scene + EnvFileManager + Doctor + unit tests
□ Phase 3: Project/Thread models + Sidebar + add/remove projects
□ Phase 4: ThreadEngine + StreamJSONParser + Composer + real spawn
□ Phase 5: SessionStore + parallel threads + resume + import from ~/.claude
□ Phase 6: GitRunner + DiffPane + SwiftTerm terminal
□ Phase 7: Context bar + interrupt + permissions modes
□ Phase 8: Crash recovery + doctor.sh + menu commands + polish
□ Phase 9: Full test suite + integration test
□ Phase 10: README + BUILD_LOG review + final acceptance run
```

End of specification. Begin with Phase 1.