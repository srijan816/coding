# ClaudeDeck — Phase 2 Build Prompt (Fix, Wire, and Polish)

> You are continuing the ClaudeDeck build. Phase 1 finished the scaffolding but left compile errors, broken import flows, a minimal UI, and the wrong default launch command. This prompt is your full instruction set for finishing the app. **Read the entire document before writing code.** Every change you make gets logged to `BUILD_LOG.md`. Work in order; do not skip tasks.

## 0. Ground rules for this round

1. **No more stubs.** If a file says “TODO” or “placeholder,” you finish it in this round. The user should not see any “coming soon” text anywhere in the UI.
1. **Every task ends with a build + manual-verification step.** After every numbered task, run `xcodebuild -scheme Claudex -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -40` and paste the tail into `BUILD_LOG.md`. If it errors, fix before moving on.
1. **Log everything.** Append to `BUILD_LOG.md` under a new heading `## Round 2 — <task name>`. Every task gets its own subsection with: (a) files changed, (b) what you did, (c) build result, (d) manual test result.
1. **Do not regress what works.** If you touch a file, re-run the acceptance from the relevant PRD phase afterward.
1. **You are probably running on MiniMax M2.7.** Keep turns small and focused. Prefer targeted `Edit` over full-file rewrites. Compile after every file.

## 1. Architectural change: new default launch command

Original PRD had us routing through MiniMax’s Anthropic-compatible endpoint via `.env` (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`). We’re adding a second — and now **default** — mode: delegate to the `claude` CLI’s own cloud auth.

The canonical spawn command for a new thread is now:

```
claude --model minimax-m2.7:cloud --dangerously-skip-permissions \
  -p --output-format stream-json --input-format stream-json \
  --cwd <project path>
```

Note what’s **gone**: no `--bare`, no `--settings`, no injected `ANTHROPIC_*` env. The `:cloud` suffix tells `claude` to use its own OAuth-backed cloud routing; `--bare` would skip that auth and break this mode.

Note what’s **still there**: the `-p` / `--output-format stream-json` / `--input-format stream-json` / `--cwd` flags that make our stream-json parser work.

### 1.1 Add a launch mode enum

Create `Core/Models/LaunchMode.swift`:

```swift
enum LaunchMode: String, Codable, CaseIterable, Identifiable {
    case cloudManaged        // claude --model <model>:cloud --dangerously-skip-permissions
    case envProvider         // claude --bare --settings <file>  (original mode, for MiniMax API-key users)

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cloudManaged: return "Cloud (delegated to claude login)"
        case .envProvider:  return "API key via .env"
        }
    }
}
```

Default is `.cloudManaged`. Store on `AppSettings` (persist in UserDefaults).

### 1.2 Add a model-selection list

Create `Core/Models/ClaudeModel.swift`:

```swift
struct ClaudeModel: Codable, Identifiable, Hashable {
    var id: String        // the exact string passed to --model
    var displayName: String
    var provider: String  // "minimax", "anthropic", "glm", etc.
}

enum ClaudeModelCatalog {
    static let defaults: [ClaudeModel] = [
        .init(id: "minimax-m2.7:cloud",  displayName: "MiniMax M2.7 (cloud)",  provider: "minimax"),
        .init(id: "minimax-m2.5:cloud",  displayName: "MiniMax M2.5 (cloud)",  provider: "minimax"),
        .init(id: "sonnet",              displayName: "Claude Sonnet (latest)", provider: "anthropic"),
        .init(id: "opus",                displayName: "Claude Opus (latest)",   provider: "anthropic"),
        .init(id: "haiku",               displayName: "Claude Haiku (latest)",  provider: "anthropic"),
        .init(id: "glm-4.6:cloud",       displayName: "GLM 4.6 (cloud)",        provider: "glm"),
    ]
}
```

Surface as a dropdown both in Settings and as a per-thread override (Phase 2.7).

### 1.3 Update ThreadEngine spawn

`Core/Process/ThreadEngine.swift`’s `start()` method: branch on `AppSettings.launchMode`.

```swift
var args: [String] = []
switch settings.launchMode {
case .cloudManaged:
    args = [
        "--model", thread.modelOverride ?? settings.defaultModelId,
        "--dangerously-skip-permissions",
        "-p",
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--cwd", project.rootPath.path,
    ]
    if let sid = thread.sessionId { args.append(contentsOf: ["--resume", sid]) }

case .envProvider:
    let settingsURL = try SettingsJSONBuilder.write(current: envManager.load())
    self.settingsFileURL = settingsURL
    args = [
        "--bare",
        "-p",
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--settings", settingsURL.path,
        "--cwd", project.rootPath.path,
    ]
    if let sid = thread.sessionId { args.append(contentsOf: ["--resume", sid]) }
}
```

In `.cloudManaged` mode, the child inherits the user’s normal environment **minus** any stray `ANTHROPIC_BASE_URL` (which would hijack the cloud endpoint). Add a helper `buildCloudChildEnv()` to `EnvFileManager`:

```swift
func buildCloudChildEnv() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    // Strip anything that would override cloud routing
    for key in ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"] {
        env.removeValue(forKey: key)
    }
    // But keep HOME, PATH, SHELL, etc. — claude needs them for OAuth keychain reads.
    return env
}
```

Pick the right env based on `launchMode` in `ThreadEngine.start()`.

### 1.4 First-run gate

If the user picks `.cloudManaged` and hasn’t run `claude login` yet, the spawn will fail with an auth error. Add a FirstRunView (see §4) that runs `claude /status` (or `claude --print "hi"` with a 3-second timeout) on launch and, if that fails with an auth-style error, shows a blocking card: “You need to log into `claude` first. Open Terminal and run `claude login`, then click Retry.”

Do this in a new `Core/Config/AuthProbe.swift`:

```swift
enum AuthProbeResult { case ok, needsLogin, cliMissing, other(String) }

enum AuthProbe {
    static func probe() async -> AuthProbeResult {
        guard let cli = CLIDetector.resolve() else { return .cliMissing }
        let p = Process()
        p.executableURL = cli
        p.arguments = ["--print", "--output-format", "json", "hi"]
        p.environment = EnvFileManager.shared.buildCloudChildEnv()
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        do {
            try p.run()
            // 5s timeout
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            if p.isRunning { p.terminate(); return .other("probe timed out") }
            let errStr = String(data: err.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            if p.terminationStatus == 0 { return .ok }
            if errStr.lowercased().contains("login") || errStr.lowercased().contains("unauthorized") || errStr.lowercased().contains("authenticate") {
                return .needsLogin
            }
            return .other(errStr.isEmpty ? "exit \(p.terminationStatus)" : errStr)
        } catch {
            return .other(error.localizedDescription)
        }
    }
}
```

## 2. Fix the four compile errors first

Do these before anything else.

### 2.1 `Thread: Hashable` failure (Thread.swift:24)

The auto-synthesized `Hashable` conformance broke, meaning one of `Thread`‘s stored properties isn’t `Hashable`. Most likely culprits: a custom `Message` enum with associated values, or `ThreadStatus` with an `errored(String)` case that wasn’t made Hashable.

Fix: open `Core/Models/Thread.swift`. Read every property. For any type that isn’t trivially Hashable, either mark it Hashable at its definition or implement `hash(into:)` and `==` manually on Thread:

```swift
extension Thread {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    static func == (lhs: Thread, rhs: Thread) -> Bool {
        lhs.id == rhs.id
    }
}
```

Identity-based hashing by `id` is correct here — two threads are “the same thread” iff they share UUID.

While you’re in `Thread.swift`, add `var modelOverride: String?` for §1.2 per-thread model selection.

### 2.2 `DoctorCheckItem.passed` is a `let` (SettingsView.swift:114, 116, 117)

The view is trying to mutate `passed` on array elements, but the model has `let passed`. Two coupled bugs:

- The array binding `$doctorResults` is needed if you want ForEach with bindings; otherwise you pass the array and re-build it.
- `let passed` means results are immutable after creation — so *never* mutate in-place. Instead, build a fresh `[DoctorCheckItem]` each time the user hits “Re-run”.

Fix the model to use `var` and separate the concerns:

```swift
struct DoctorCheckItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    var passed: Bool          // var, not let
    var detail: String
}
```

Fix the view to re-run from scratch instead of mutating in place:

```swift
@State private var doctorResults: [DoctorCheckItem] = []
@State private var running = false

func runDoctor() {
    running = true
    Task {
        var results: [DoctorCheckItem] = []
        // 1. CLI
        if let cli = CLIDetector.resolve() {
            results.append(.init(name: "claude CLI found", passed: true, detail: cli.path))
        } else {
            results.append(.init(name: "claude CLI found", passed: false, detail: "Not on PATH or common locations"))
        }
        // 2. .env present
        let envURL = EnvFileManager.shared.envFileURL
        results.append(.init(name: ".env present", passed: FileManager.default.fileExists(atPath: envURL.path), detail: envURL.path))
        // 3. Auth probe
        switch await AuthProbe.probe() {
        case .ok:            results.append(.init(name: "claude auth works", passed: true,  detail: "probe succeeded"))
        case .needsLogin:    results.append(.init(name: "claude auth works", passed: false, detail: "Run `claude login` in Terminal"))
        case .cliMissing:    results.append(.init(name: "claude auth works", passed: false, detail: "CLI missing"))
        case .other(let m):  results.append(.init(name: "claude auth works", passed: false, detail: m))
        }
        await MainActor.run {
            self.doctorResults = results
            self.running = false
        }
    }
}

// In body:
ForEach(doctorResults) { item in
    HStack {
        Image(systemName: item.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .foregroundStyle(item.passed ? .green : .red)
        VStack(alignment: .leading) {
            Text(item.name).bold()
            Text(item.detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

No bindings, no `$doctorResults`, no mutation. That fixes all three errors at once.

### 2.3 `always succeeds` cast (EnvFileManager.swift:139)

A `[String: String] as? [String: String]` cast snuck in. Open line 139 and remove the `as?` — it’s a leftover from an earlier generic version. If the compiler still needs disambiguation, write the literal type once at the declaration and drop the cast entirely.

### 2.4 Verify

After all four fixes, run:

```bash
xcodebuild -scheme Claudex -configuration Debug -destination 'platform=macOS' clean build 2>&1 | grep -E "(error|warning):" | head -30
```

Must return **zero errors**. Warnings are OK but record the count.

## 3. Fix project import and “Add Folder”

Both paths need to work reliably. The current implementation almost certainly has one or more of these bugs:

1. Missing security-scoped bookmark — even with sandbox off, SwiftUI’s fileImporter returns URLs that need `startAccessingSecurityScopedResource()` calls on some Ventura+ builds.
1. Path storage uses relative URLs or `URL.absoluteString` (with `file://` prefix) which doesn’t match what the `claude` CLI expects for `--cwd`.
1. Import-from-Claude-Code uses encoded paths but doesn’t decode them back to real filesystem paths.

### 3.1 Add Folder flow

Rewrite the “Add Project” flow. Use `NSOpenPanel` directly (not SwiftUI `fileImporter` — it’s more predictable on macOS):

```swift
// In SidebarView or an AppStateCommand:
func addProjectFromFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Add Project"
    panel.message = "Pick the root folder of your project. ClaudeDeck will run `claude` with this folder as its working directory."

    guard panel.runModal() == .OK, let url = panel.url else { return }

    // Resolve to canonical absolute path — no symlinks, no /private prefix weirdness.
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    let path = resolved.path

    guard FileManager.default.fileExists(atPath: path) else {
        Logger.shared.warn("Selected folder does not exist after resolution: \(path)")
        return
    }

    let project = Project(
        id: UUID(),
        name: resolved.lastPathComponent,
        rootPath: resolved,
        createdAt: Date(),
        color: "blue"
    )
    projectStore.add(project)
    appState.selectedProjectId = project.id
}
```

Key details:

- `NSOpenPanel` only — reliable on macOS 14.
- `resolvingSymlinksInPath().standardizedFileURL` gives a canonical path that matches what the CLI’s cwd logic expects.
- Store the `URL` in the model, but when passing to the CLI use `.path` (not `.absoluteString` — that has `file://` prefix).

### 3.2 Persistence of project paths

In `ProjectStore`, URLs must serialize as plain paths. Check your Project Codable implementation — if you’re using the default `URL` Codable, it writes `file:///Users/...`. Custom encode:

```swift
struct Project: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var rootPath: URL
    var createdAt: Date
    var color: String

    enum CodingKeys: String, CodingKey { case id, name, rootPathString, createdAt, color }

    init(id: UUID, name: String, rootPath: URL, createdAt: Date, color: String) {
        self.id = id; self.name = name; self.rootPath = rootPath; self.createdAt = createdAt; self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        let path = try c.decode(String.self, forKey: .rootPathString)
        self.rootPath = URL(fileURLWithPath: path)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.color = try c.decode(String.self, forKey: .color)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(rootPath.path, forKey: .rootPathString)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(color, forKey: .color)
    }
}
```

Also remove the old `projects.json` on first run of this version so stale `file://` entries don’t crash the migration. Do this by version-stamping the JSON: wrap in `{"version": 2, "projects": [...]}`, bail to empty on mismatch.

### 3.3 Import from Claude Code

This reads `~/.claude/projects/*` and reverses the path encoding. But the encoding is lossy — `-Users-alice-my-project` could be `/Users/alice/my-project` **or** `/Users/alice/my/project`. You cannot reliably reverse it.

Correct strategy: don’t try to reverse. Instead, read the first line of each `*.jsonl` inside the encoded folder — it has `"cwd": "/Users/alice/..."` as a field. Use that as the ground truth.

```swift
func discoverClaudeCodeProjects() -> [DiscoveredProject] {
    let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)
    guard let entries = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }

    var results: [DiscoveredProject] = []
    for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        guard let jsonlFiles = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
        let jsonls = jsonlFiles.filter { $0.pathExtension == "jsonl" }
        guard let newest = jsonls.max(by: { (a, b) in
            (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
              < (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
        }) else { continue }

        // Read first line
        guard let handle = try? FileHandle(forReadingFrom: newest) else { continue }
        defer { try? handle.close() }
        let firstChunk = handle.readData(ofLength: 64 * 1024)
        guard let text = String(data: firstChunk, encoding: .utf8),
              let firstLine = text.split(separator: "\n").first,
              let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cwd = obj["cwd"] as? String else { continue }

        let url = URL(fileURLWithPath: cwd)
        if FileManager.default.fileExists(atPath: cwd) {
            results.append(.init(name: url.lastPathComponent, rootPath: url, sessionCount: jsonls.count))
        }
    }
    return results.sorted { $0.name < $1.name }
}
```

In the import sheet, show a list of discovered projects with checkboxes, a count of sessions each has, and an “Import selected” button that adds them as real Projects.

## 4. Real UI — stop being minimalistic

Here is the entire visual spec. Treat it as a design contract, not suggestions.

### 4.1 Window chrome

- Single-window app, restorable size, min 1100 × 720.
- Title bar merges into toolbar (`.windowStyle(.hiddenTitleBar)` or use `.toolbarBackground(.ultraThinMaterial, for: .windowToolbar)`).
- Three-column `NavigationSplitView`:
  - Sidebar: 260 min, 320 default, 400 max.
  - Detail (thread): flex, 520 min.
  - Inspector: 320 min, 380 default, 520 max, collapsible via toolbar button and ⌘⇧I.

### 4.2 Sidebar

Visual structure (top to bottom):

1. **App header** — small app icon (SF Symbol `rectangle.stack.badge.play.fill`), “ClaudeDeck” bold, current `LaunchMode` and model as a subtitle (e.g., “Cloud · MiniMax M2.7”). Tapping opens Settings.
1. **Search bar** — filters projects and threads by name.
1. **Projects section** — `DisclosureGroup` per project, auto-expanded when selected. Row layout:
- Left: colored dot (project.color → SwiftUI Color).
- Middle: project name (bold), last-activity relative time underneath (`"updated 5m ago"`).
- Right: thread count badge and a hover-revealed `+` to quick-add a thread.
- Context menu: New Thread, Rename, Show in Finder, Open in Terminal, Open in VS Code (if installed), Remove.
1. **Threads under each project** — indented rows:
- Left: status dot — gray idle, blue pulsing running, green success after last turn, red error.
- Middle: thread title (first prompt, truncated to 48 chars), model badge (small pill with model name) when overriding, timestamp.
- Right: cost chip (`$0.02`) if cost > 0, otherwise token count.
- Context menu: Rename, Duplicate (fork), Stop, Delete.
- Double-click opens in a new window (see §4.7).
1. **Bottom bar** — pinned:
- “New Project” button with folder-plus icon.
- “Import from Claude Code” button with download icon.
- Overflow menu: Doctor, Settings.

### 4.3 Thread view (center pane)

Top to bottom:

1. **Thread header bar** (50 px):
- Title (editable inline on double-click).
- Right side: model picker (`Picker` styled as a pill), “Stop” button when running, Fork button, ⋯ overflow with Export Transcript, Copy Session ID.
1. **Transcript scroll view** — dominated by `MessageBubbleView`s:
- User messages: right-aligned, accent color bubble, max width 680.
- Assistant text: left-aligned, no bubble, just markdown-rendered text with proper spacing and monospace code blocks using `AttributedString` from markdown.
- Tool calls: collapsed card, icon matching tool name (Read → `doc.text`, Edit → `pencil`, Bash → `terminal`, Write → `square.and.pencil`, Grep → `magnifyingglass`, Glob → `doc.on.doc`, WebFetch → `globe`, WebSearch → `magnifyingglass.circle`). Shows `<tool>(<one-line summary of args>)`. Click to expand full JSON input + result. Running state shows a spinner.
- System notes: small centered pill, gray.
- Errors: red-bordered card with the stderr tail.
- Auto-scroll on new messages *only if* the user was already at the bottom (measure scroll offset before new message, preserve if not at bottom, show a “↓ new messages” floating button).
1. **Context bar** (28 px, above composer):
- Left: `Gauge` showing `usedTokens / contextWindow`, with color transitioning to yellow at 70% and red at 90%.
- Middle: `"<used> / <total> tokens"` text.
- Right: cumulative cost and turn count.
1. **Composer**:
- Rounded rect container with subtle border (`.secondary.opacity(0.3)`).
- `TextEditor` inside, auto-growing from 40 px to 180 px max, scrolls beyond.
- Placeholder: “Ask claude to do something in `<project name>`…”
- Bottom-left: attachment button (future — disabled for now, tooltip “coming soon” is OK here and only here).
- Bottom-right: Send button (prominent, blue), changes to Stop (red) when running.
- Keyboard: ⌘⏎ send, ⇧⏎ newline, ⌘. stop, Esc stop.
- Shows a small secondary text when running: “Running with `<model>` — press ⌘. to stop”.

### 4.4 Inspector (right pane)

Tabbed `SegmentedPicker` at top: **Diff**, **Terminal**, **Session**.

- **Diff** — file tree of modified files with `+n/-n` counts, right side shows unified diff with syntax highlighting. Top toolbar: `All`, `Staged`, `Unstaged` filter. Action buttons per file: Stage, Unstage, Revert (with confirmation), Open in Editor. Below the file list: a commit bar with a message field and “Commit” button, plus a “Push” button.
- **Terminal** — embedded PTY. See §5 for the implementation approach (switch from SwiftTerm to a simpler working solution).
- **Session** — metadata about the current thread:
  - Session ID (with copy button).
  - cwd.
  - Model + launch mode.
  - Token budget breakdown.
  - “Show JSONL on disk” button that opens Finder at the session file.
  - “Export Transcript…” button that writes a Markdown version.

### 4.5 Settings window (⌘,)

Tabs:

- **General** — launch mode picker, default model dropdown, theme (System/Light/Dark), font size (S/M/L), show hidden files in diff pane, telemetry off (disabled for now).
- **Provider (.env mode)** — visible only when launch mode is `.envProvider`. All the MiniMax fields from the original PRD.
- **Cloud (default)** — visible only when launch mode is `.cloudManaged`. Shows: current claude CLI path and version, “Run `claude login` in Terminal” with a one-click “Open Terminal with command prefilled” button (uses `osascript` to tell Terminal.app to run the command), current logged-in status from AuthProbe.
- **Advanced** — max concurrent threads (2–16, default 8), `CLAUDE_CODE_MAX_CONTEXT_TOKENS` override, extra env vars (key-value list).
- **Doctor** — the checklist from §2.2.
- **About** — version, PRD link, build log path, credits.

### 4.6 Visual polish

Apply these everywhere:

- Use `.background(.ultraThinMaterial)` on the sidebar, `.background(Color(NSColor.textBackgroundColor))` on the thread view, `.background(.regularMaterial)` on the inspector. This gives the native Codex/Xcode look.
- Use `Color.accentColor` consistently for interactive elements. Set the project’s accent color in Assets.xcassets to a blue-violet (#5E6AD2-ish).
- Use SF Symbols throughout. No emoji.
- Standard macOS typography: system font, 13pt body, 11pt caption, semibold for headers.
- Every state change has a transition: `withAnimation(.easeInOut(duration: 0.15))` for UI state, `.spring(response: 0.35, dampingFraction: 0.8)` for structural changes.
- Empty states everywhere — when no project is selected show a centered SF Symbol + helpful text + primary action button. When a project has no threads, same pattern.
- Loading states — skeleton rows while ProjectStore is loading, `ProgressView` where waiting on async work.
- Keyboard shortcuts surfaced in menu bar *and* tooltips on every button (⌘N, ⌘⇧N, ⌘W, ⌘⏎, ⌘., ⌘J, ⌘⇧I, ⌘,).

### 4.7 Multi-window (thread in its own window)

Double-clicking a thread opens it in a dedicated window. Use `WindowGroup(id: "thread", for: UUID.self) { ... }` keyed by thread ID. The new window has only the center pane + inspector — no sidebar. This is how Codex-style parallel work feels natural.

## 5. Terminal pane — switch away from SwiftTerm if it wasn’t added

If the current terminal pane is a placeholder, implement it one of two ways. Pick the simpler path that works:

### 5.1 Preferred: SwiftTerm via SPM

1. In Xcode: File → Add Package Dependencies → `https://github.com/migueldeicaza/SwiftTerm`, rule “Up to Next Major” from 1.2.0.
1. Wrap `LocalProcessTerminalView` in an `NSViewRepresentable`:

```swift
import SwiftTerm
struct TerminalViewRepresentable: NSViewRepresentable {
    let cwd: URL
    let env: [String: String]

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let v = LocalProcessTerminalView(frame: .zero)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let envArray = env.map { "\($0.key)=\($0.value)" }
        v.startProcess(executable: shell, args: ["-l"], environment: envArray, execName: nil)
        // Set cwd by sending a cd command (the PTY is already started)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let cd = "cd \"\(cwd.path)\"\r"
            v.send(txt: cd)
        }
        return v
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
```

### 5.2 Fallback: plain NSTextView + Process

If SwiftTerm can’t be added (sandbox, dependency resolution issues), build a minimal read-only terminal:

- Spawn `zsh -il` with a pseudo-TTY via `openpty` wrapped in a helper.
- Capture stdout and render in a monospace `NSTextView`.
- Input from a `NSTextField` at the bottom sends lines to the PTY stdin.

This is worse UX but works without an external dependency. Only use as last resort and note in BUILD_LOG.

## 6. Resume flow — actually wire it up

Resume currently doesn’t work end-to-end. Fix:

1. When the user clicks a thread that has a `sessionId` set, and the thread is `idle`, don’t spawn a fresh process yet. Instead:
- Render the transcript from `SessionStore.messages(for: sessionId, in: project)`.
- Composer is enabled but “primed” — the first user send spawns a new child with `--resume <sessionId>`.
1. Discovery: in the sidebar, under each project, show an optional “History” disclosure group that lists all past sessions on disk for that project. Clicking one creates a lightweight Thread record referencing that sessionId and switches to it.
1. Fork: context menu “Duplicate” calls `claude --resume <sid> --fork` (check current CLI for the exact flag name — it might be exposed via `/fork` slash command instead; if so, document in BUILD_LOG and make Duplicate just start a new thread that reads the transcript and replays the last prompt).

## 7. Menu bar

Wire real commands:

```swift
.commands {
    CommandGroup(replacing: .newItem) {
        Button("New Project…") { appState.addProjectFromFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
        Button("New Thread") { appState.newThreadInSelectedProject() }.keyboardShortcut("n", modifiers: .command)
    }
    CommandMenu("Thread") {
        Button("Send")      { appState.sendActive() }.keyboardShortcut(.return, modifiers: .command)
        Button("Stop")      { appState.stopActive() }.keyboardShortcut(".", modifiers: .command)
        Button("Fork")      { appState.forkActive() }.keyboardShortcut("f", modifiers: [.command, .shift])
        Divider()
        Button("Export Transcript…") { appState.exportActiveTranscript() }
    }
    CommandMenu("View") {
        Button("Toggle Inspector") { appState.inspectorVisible.toggle() }.keyboardShortcut("i", modifiers: [.command, .shift])
        Button("Toggle Terminal")  { appState.inspectorTab = .terminal; appState.inspectorVisible = true }.keyboardShortcut("j", modifiers: .command)
    }
}
```

Every menu item must have a working handler. No `// TODO` handlers.

## 8. Logging and diagnostics (this is how I help you next time)

Improve logging so the next round can be debugged from BUILD_LOG alone.

### 8.1 In-app log

Create `Utilities/Logger.swift`:

```swift
final class Logger {
    static let shared = Logger()
    private let fileURL: URL
    private let queue = DispatchQueue(label: "claudedeck.logger")

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeDeck/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        self.fileURL = dir.appendingPathComponent("claudedeck-\(stamp).log")
    }

    func log(_ level: String, _ message: String, file: String = #file, line: Int = #line) {
        let entry = "[\(Date().ISO8601Format())] [\(level)] \(URL(fileURLWithPath: file).lastPathComponent):\(line) — \(message)\n"
        queue.async {
            if let data = entry.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.fileURL.path) {
                    if let h = try? FileHandle(forWritingTo: self.fileURL) {
                        try? h.seekToEnd()
                        try? h.write(contentsOf: data)
                        try? h.close()
                    }
                } else {
                    try? data.write(to: self.fileURL)
                }
            }
        }
        #if DEBUG
        print(entry, terminator: "")
        #endif
    }
    func info(_ m: String, file: String = #file, line: Int = #line)  { log("INFO",  m, file: file, line: line) }
    func warn(_ m: String, file: String = #file, line: Int = #line)  { log("WARN",  m, file: file, line: line) }
    func error(_ m: String, file: String = #file, line: Int = #line) { log("ERROR", m, file: file, line: line) }
}
```

Call `Logger.shared.info/warn/error` at every meaningful event: app launch, CLI detection result, project add, thread spawn (log full argv minus auth tokens), stream-json parse errors, child exit codes, auth probe results.

### 8.2 Debug panel

In the About tab or as a menu item “Help → Show Logs”, open Finder at the log directory.

### 8.3 BUILD_LOG format this round

Use this exact template per task, so I can grep it next time:

```
## Round 2 — Task <N>: <title>

**Date:** 2026-04-20
**Files changed:** path/A, path/B
**What I did:** one paragraph

**Build result:**
\`\`\`
<last 20 lines of xcodebuild output>
\`\`\`

**Manual verification:**
- [x] Step 1 — observed X
- [x] Step 2 — observed Y
- [ ] Step 3 — FAILED because Z  ← explain

**Log excerpt (if relevant):**
\`\`\`
<paste ~20 lines of claudedeck-YYYY-MM-DD.log that pertain to this task>
\`\`\`

**Deviations from prompt:** none / or listed

**Next:** moves to Task <N+1>
```

If something fails you can’t fix, leave the task `[ ]` and add a `## KNOWN ISSUE:` section at the end with full context. Do **not** silently skip.

## 9. Tests — actually run them

Phase 1 said “test target needs setup in Xcode” — finish that now.

1. In Xcode: File → New → Target → Unit Testing Bundle, name `ClaudexTests`. Link against `Claudex`.
1. Add tests listed below. Skip any test that requires a live API; mark those as integration and gate on env var.

Minimum required tests:

- `PathEncoderTests` — 5 cases including unicode and paths with spaces.
- `StreamJSONParserTests` — 8 cases: complete event, split across chunks, multiple events in one chunk, unicode on boundary, malformed line doesn’t crash parser, EOF flush, unknown type → `.unknown`, very large tool_result.
- `EnvFileManagerTests` — write→read round trip, strips ANTHROPIC_* from parent env, malformed .env yields readable error.
- `ProjectStoreTests` — add/remove/persist, URL stored as path string, migration from v1 schema.
- `SessionStoreTests` — against a fixture jsonl at `ClaudexTests/Fixtures/sample-session.jsonl` (5 events; you create this).
- `CLIDetectorTests` — with mock `ShellRunner`.
- `AuthProbeTests` — mocked Process; check that “login” in stderr maps to `.needsLogin`.

`script/test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild test \
  -scheme Claudex \
  -destination 'platform=macOS' \
  -derivedDataPath ./build \
  2>&1 | tee build/test-output.log | tail -50
exit ${PIPESTATUS[0]}
```

`script/integration_test.sh` — new, validates the `:cloud` default path:

```bash
#!/usr/bin/env bash
set -uo pipefail
echo "== ClaudeDeck integration (cloud mode) =="
command -v claude >/dev/null || { echo "✗ claude CLI missing"; exit 1; }
TMPDIR=$(mktemp -d)
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Reply with only the single word PONG."}]}}' \
  | claude --model minimax-m2.7:cloud --dangerously-skip-permissions \
    -p --output-format stream-json --input-format stream-json --cwd "$TMPDIR" \
  | tee "$TMPDIR/out.jsonl"
grep -q 'PONG' "$TMPDIR/out.jsonl" && echo "✓ cloud integration pass" || { echo "✗ cloud integration fail — see $TMPDIR/out.jsonl"; exit 1; }
```

Run both. Paste summary into BUILD_LOG.

## 10. Final acceptance

This round is done when **every** box is checked:

- [ ] Zero compile errors on clean build.
- [ ] Zero warnings about conformance or casts.
- [ ] Launching the app shows the redesigned UI (materials, proper sidebar, proper composer).
- [ ] Add Project → folder picker → project appears with canonical path.
- [ ] Import from Claude Code lists real projects with session counts.
- [ ] New Thread in a project spawns `claude --model minimax-m2.7:cloud --dangerously-skip-permissions -p --output-format stream-json --input-format stream-json --cwd <path>` (verify by `ps aux | grep claude` while a thread is running).
- [ ] Sending “say PONG” returns “PONG” in the transcript.
- [ ] Tool calls render as cards, click to expand.
- [ ] Context bar updates; cost chip updates.
- [ ] Stop button kills the child; thread returns to idle.
- [ ] Resume a historical session replays transcript and continues it.
- [ ] Terminal pane opens a real zsh shell in the project cwd.
- [ ] Diff pane shows real git output after editing a file in that project.
- [ ] Settings → Cloud shows CLI version and auth status.
- [ ] Doctor passes on your machine.
- [ ] `./script/test.sh` — all unit tests pass.
- [ ] `./script/integration_test.sh` — passes.
- [ ] BUILD_LOG has a “Round 2” entry for every numbered section (§1–§9).
- [ ] A fresh clone + `./script/bootstrap.sh` + open Xcode + Run → working app in under 5 minutes.

## 11. Order of operations

1. §2 — fix the four compile errors.
1. §1 — wire the new launch mode + model catalog.
1. §3 — fix project import and add-folder.
1. §6 — resume flow.
1. §5 — terminal pane.
1. §4 — UI polish. (Do this after plumbing works — otherwise you’ll redo it.)
1. §7 — menu bar wiring.
1. §8 — logging.
1. §9 — tests.
1. §10 — final acceptance walkthrough.

Log after each step. Build after each step. Don’t batch.

Begin with §2 Task 1.