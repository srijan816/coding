# ClaudeDeck — Round 4 Prompt (Make it actually work)

> **The app compiles and runs. Projects persist. The sidebar renders. But sending a prompt produces nothing visible.** That is a real, specific bug with a specific cause. This round you fix the spawn, surface what the child process is actually saying, and make the window feel like a real desktop app. Read the entire document before touching code.

-----

## 0. Ground rules

1. **This round has one non-negotiable: the app must successfully send a prompt and show a response by the end of §2.** If §2 isn’t working, you do not proceed to UI polish. Everything downstream depends on this working.
1. **When a child process fails, you must now show the failure in the UI.** The user is flying blind because stderr is being swallowed. Fix this in §2.3 and it stays fixed.
1. **Log every tool invocation at `Logger.shared.info` level with the full argv array.** I need to be able to read BUILD_LOG and know the exact command that was run, character for character.
1. **Format every BUILD_LOG entry with the Round 3 template** (files changed, what changed, build result, runtime verification, log excerpt). No summary tables without evidence.

-----

## 1. What is actually broken, and why

I did the research. Here are the facts, verified from the `claude` CLI source reports and real user repros:

### 1.1 The CLI requires `--verbose` when using `--output-format stream-json` in print mode

This is the primary bug. From Claude Code’s own error message:

> `Error: When using --print, --verbose must be used together with --json`

And from every working example across SDKs and community projects, the pattern is:

```
claude -p --output-format stream-json --verbose [--input-format stream-json]
```

**Your current spawn in ThreadEngine is missing `--verbose`.** The child either errors immediately and exits, or produces only the initial system/init event and then silently terminates. The user sees nothing because:

1. `stdin?.write(...)` writes to a closed pipe (child is dead).
1. The parser’s event stream closes with no events beyond `system/init`.
1. The UI shows an empty transcript.
1. stderr is captured by `errPipe` but never displayed.

### 1.2 `minimax-m2.7:cloud` is probably not accepted by `--model` in headless mode

The `:cloud` suffix convention is used by some third-party routing layers but is not a standard Claude Code `--model` value. In interactive mode the CLI is lenient, but in `-p` mode it validates the model identifier and fails hard on unknown strings.

**What to do:** make the model string configurable per-thread and per-settings, default to a known-good Anthropic alias (`sonnet`), and expose a “Custom model string” field in Settings so you can type `minimax-m2.7:cloud` or any other value and test it directly. If the spawn fails, stderr will now be displayed (§2.3) and you’ll see the actual error.

The user’s interactive command `claude --model minimax-m2.7:cloud --dangerously-skip-permissions` works because Claude Code routes the string through whatever extension or cloud adapter they have configured in their CLI setup. That adapter is invoked the same way in `-p` mode as in interactive mode, **provided the argv is otherwise correct**. So the fix is: get the invocation right (§1.1), make the model string configurable (§1.3), and surface stderr (§2.3) so the user can debug any model-string issues visually.

### 1.3 The complete correct argv, for reference

```
claude
  -p
  --output-format stream-json
  --input-format stream-json
  --verbose                              ← MISSING in current code
  --dangerously-skip-permissions         ← when launchMode is .cloudManaged
  --model <user-configured string>       ← default to "sonnet", let user override
  --cwd <project absolute path>
  [--resume <session-uuid>]              ← when resuming
```

No `--bare` in cloudManaged mode. No `--settings` in cloudManaged mode.

### 1.4 Why stderr is critical

Four different bugs at the CLI level all present as “silence in the UI”:

- Auth not set up → stderr says “Please run `claude login`”.
- Model string invalid → stderr says “Unknown model: minimax-m2.7:cloud”.
- `cwd` not a valid directory → stderr says “Invalid working directory”.
- Missing `--verbose` with `--output-format json`/`stream-json` → stderr says the error above.

Until stderr is visible, debugging is guessing. §2.3 makes it visible.

-----

## 2. Fix the spawn (this is the whole round’s success criterion)

### 2.1 Update ThreadEngine argv

Open `Claudex/Core/Process/ThreadEngine.swift`. Find the `start()` method (or whatever sets up `p.arguments`). In the `.cloudManaged` branch, the arguments must be:

```swift
var args: [String] = [
    "-p",
    "--output-format", "stream-json",
    "--input-format", "stream-json",
    "--verbose",                                // critical — without this, stream-json fails
    "--dangerously-skip-permissions",
]
// Model — read from settings (default "sonnet" if empty)
let modelString = settings.selectedModelId.isEmpty ? "sonnet" : settings.selectedModelId
args.append(contentsOf: ["--model", modelString])
args.append(contentsOf: ["--cwd", project.rootPath.path])
if let sid = thread.sessionId {
    args.append(contentsOf: ["--resume", sid])
}
```

In the `.envProvider` branch, keep `--bare` and `--settings`, but **add `--verbose`** there too:

```swift
var args: [String] = [
    "--bare",
    "-p",
    "--output-format", "stream-json",
    "--input-format", "stream-json",
    "--verbose",                                // add here also
    "--settings", settingsURL.path,
    "--cwd", project.rootPath.path,
]
if let sid = thread.sessionId { args.append(contentsOf: ["--resume", sid]) }
```

### 2.2 Log the full argv immediately before spawning

Right before `try p.run()`:

```swift
let argvJoined = ([p.executableURL?.path ?? "claude"] + (p.arguments ?? []))
    .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
    .joined(separator: " ")
Logger.shared.info("ThreadEngine.start: spawning: \(argvJoined)")
Logger.shared.info("ThreadEngine.start: cwd=\(p.currentDirectoryURL?.path ?? "nil") launchMode=\(settings.launchMode.rawValue) model=\(modelString)")
```

This line is what I’ll grep in BUILD_LOG next time to verify the spawn is correct.

### 2.3 Capture and display stderr

Currently stderr is attached to a pipe but never read. Fix that.

In `ThreadEngine`:

```swift
private var stderrBuffer = ""
private var stderrHandle: FileHandle?
```

After setting up `errPipe`:

```swift
self.stderrHandle = errPipe.fileHandleForReading
Task.detached { [weak self] in
    guard let handle = self?.stderrHandle else { return }
    for try await line in handle.bytes.lines {
        await MainActor.run {
            self?.appendStderr(line)
        }
    }
}
```

`appendStderr` implementation:

```swift
@MainActor
private func appendStderr(_ line: String) {
    stderrBuffer += line + "\n"
    Logger.shared.warn("claude stderr: \(line)")
    // Only surface to UI if it looks like an error, not noise.
    let lower = line.lowercased()
    let looksLikeError = lower.contains("error") || lower.contains("fatal") ||
                         lower.contains("must be") || lower.contains("invalid") ||
                         lower.contains("unknown") || lower.contains("failed") ||
                         lower.contains("login") || lower.contains("unauthorized")
    if looksLikeError {
        messages.append(.error(line))
    }
}
```

Also handle the child terminating unexpectedly:

```swift
p.terminationHandler = { [weak self] process in
    Task { @MainActor in
        guard let self else { return }
        let code = process.terminationStatus
        let reason = process.terminationReason
        Logger.shared.info("ThreadEngine: child terminated code=\(code) reason=\(reason.rawValue)")
        if code != 0 && self.state == .running {
            let tail = String(self.stderrBuffer.suffix(2000))
            self.messages.append(.error("claude exited with code \(code).\n\nstderr:\n\(tail.isEmpty ? "(none)" : tail)"))
            self.state = .errored(reason: "exit \(code)")
        } else {
            self.state = .idle
        }
    }
}
```

### 2.4 Ensure `.error(String)` is a case on Message

If `Message` doesn’t have an `.error(String, Date)` case yet, add it and render it in `MessageBubbleView` with a red border/background. Every message variant gets rendered; this is the one that saves you when spawning fails.

```swift
// In Message.swift
case error(String, Date = Date())

// In MessageBubbleView.swift
case .error(let text, _):
    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text("Error").font(.caption).bold().foregroundStyle(.red)
        }
        Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 1))
    .frame(maxWidth: .infinity, alignment: .leading)
```

### 2.5 Also show user messages immediately

You reported “the message I sent disappeared.” That means `send(_:)` isn’t appending to `messages` before writing to stdin, OR it appends but the view doesn’t re-render because `messages` isn’t `@Observable` or isn’t published.

In `ThreadEngine.send`:

```swift
func send(_ userText: String) async throws {
    let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    // 1. Show immediately in UI — do this BEFORE any writes that could fail.
    await MainActor.run {
        self.messages.append(.user(trimmed, Date()))
    }
    Logger.shared.info("ThreadEngine.send: user text (\(trimmed.count) chars) appended to transcript")

    // 2. Ensure we have a running child.
    if state == .idle || process == nil || !(process?.isRunning ?? false) {
        Logger.shared.info("ThreadEngine.send: no running child, starting one")
        try await start()
    }

    // 3. Encode and write.
    let payload: [String: Any] = [
        "type": "user",
        "message": [
            "role": "user",
            "content": [["type": "text", "text": trimmed]]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: []) + Data([0x0A])
    Logger.shared.info("ThreadEngine.send: writing \(data.count) bytes to stdin")
    do {
        try stdin?.write(contentsOf: data)
    } catch {
        Logger.shared.error("ThreadEngine.send: stdin write failed: \(error)")
        await MainActor.run {
            self.messages.append(.error("Failed to send: \(error.localizedDescription)", Date()))
        }
        throw error
    }

    await MainActor.run {
        self.state = .running
    }
}
```

Verify `messages` is observed: in `ThreadEngine` declaration use `@Observable` class with `var messages: [Message] = []` (no `@Published` — `@Observable` tracks property access automatically). In `ThreadView`:

```swift
@Bindable var engine: ThreadEngine  // or pass via @Environment
// In body:
ForEach(engine.messages) { message in
    MessageBubbleView(message: message)
        .id(message.id)
}
```

Make sure `Message` conforms to `Identifiable` with a `UUID id`.

### 2.6 Runtime verification — this is the gate

After applying §2.1–§2.5, manually test and paste all output into BUILD_LOG:

```bash
xcodebuild -scheme Claudex -configuration Debug -destination 'platform=macOS' clean build 2>&1 | tail -10
# (should say BUILD SUCCEEDED)

pkill -f Claudex || true
open ./build/Build/Products/Debug/Claudex.app

# Wait for app to open, then in a new terminal:
sleep 5
tail -f "$HOME/Library/Application Support/ClaudeDeck/logs/claudedeck-$(date +%Y-%m-%d).log" &
TAIL_PID=$!
```

In the app:

1. Click the project (music).
1. Click New Thread.
1. Type “hello” and press ⌘⏎.
1. Wait 20 seconds.

Then:

```bash
kill $TAIL_PID
```

Paste the last 80 lines of the log into BUILD_LOG. **The log must show:**

- `ThreadEngine.start: spawning: /usr/local/bin/claude -p --output-format stream-json --input-format stream-json --verbose --dangerously-skip-permissions --model sonnet --cwd /Volumes/SrijanExt/Code/music`
- `ThreadEngine.send: user text (5 chars) appended to transcript`
- `ThreadEngine.send: writing X bytes to stdin`
- At least one `parsed event: system init ...` or equivalent.
- Either `parsed event: assistant message ...` (success) or `claude stderr: ...` lines followed by `ThreadEngine: child terminated code=<non-zero>` (failure).

**If you see stderr lines saying “–verbose must be used”**, something didn’t save — re-check §2.1.

**If you see “Unknown model: sonnet”** (extremely unlikely, but possible if the CLI is unusual), the user’s `claude` CLI isn’t routing to Anthropic — ask them to run `claude --model sonnet -p "hi"` in Terminal.app first to verify.

**If you see auth errors**, the user needs to run `claude login` in Terminal. Display this instruction in the error card.

**If you see the assistant reply rendered in the transcript**, §2 is done. Log it.

-----

## 3. The UI the user actually wants

The user’s three specific requests:

### 3.1 Open in nearly full-screen width

Default window size should be wide — roughly 1600×900 or “almost the user’s screen width”. In `ClaudeDeckApp.swift`:

```swift
WindowGroup {
    ContentView()
        .environment(appState)
        .frame(minWidth: 1100, minHeight: 700)
}
.defaultSize(width: 1600, height: 950)
.windowResizability(.contentMinSize)
.commands { /* ... */ }
```

Also add a “Zoom” window menu item that maximizes to the screen size (which macOS has built-in — verify it works via the green traffic light’s option-click “Zoom” action).

### 3.2 Inspector hidden by default, toggled on demand

Two changes:

1. Inspector column starts collapsed. Use `NavigationSplitViewColumn.detail` with `.detailColumnMode(.detailOnly)` **no** — actually the proper macOS 14 way is:

```swift
@State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
// .all = sidebar + content + inspector
// .doubleColumn = sidebar + content only
// .detailOnly = content only

NavigationSplitView(columnVisibility: $columnVisibility) {
    SidebarView()
} content: {
    ThreadView()
} detail: {
    InspectorView()
}
```

Start with `.doubleColumn` so the inspector is hidden. The ⌘⇧I keyboard shortcut toggles between `.all` and `.doubleColumn`.

1. Inspector toolbar button: add a persistent toolbar item in the thread toolbar (right side) that shows an icon reflecting the current state (`sidebar.right` / `sidebar.right.fill`) and toggles visibility.

### 3.3 “Open in Antigravity” instead of Terminal

Antigravity is Google’s AI-assisted editor. Its macOS app bundle identifier is `com.google.Antigravity` and its CLI helper is typically `antigravity` on PATH (similar to how VS Code ships `code`).

Replace the “Open in Terminal” context-menu item on project rows and the Terminal fallback pane’s primary button with “Open in Antigravity”. Keep Terminal as a secondary option so nothing regresses.

Implementation — try three paths in order:

```swift
enum ExternalEditor {
    static func openInAntigravity(_ url: URL) {
        let path = url.path

        // 1. Try the antigravity CLI if installed
        let candidatePaths = [
            "/usr/local/bin/antigravity",
            "/opt/homebrew/bin/antigravity",
            "\(NSHomeDirectory())/.local/bin/antigravity"
        ]
        for cli in candidatePaths where FileManager.default.isExecutableFile(atPath: cli) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = [path]
            do { try p.run(); Logger.shared.info("Opened in Antigravity via \(cli)"); return }
            catch { Logger.shared.warn("antigravity CLI at \(cli) failed: \(error)") }
        }

        // 2. Try Launch Services with bundle identifier
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Antigravity") {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, error in
                if let error { Logger.shared.error("Antigravity open failed: \(error)") }
            }
            return
        }

        // 3. Fallback: NSWorkspace.open (user's default for this directory)
        Logger.shared.warn("Antigravity not found; falling back to NSWorkspace.open")
        NSWorkspace.shared.open(url)
    }

    static func openInTerminal(_ url: URL) {
        let script = "tell application \"Terminal\" to do script \"cd \\\"\(url.path)\\\"\""
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", script]
        try? p.run()
    }
}
```

Add a Settings → General toggle “Default external editor” with Antigravity / VS Code / Terminal, store as an enum, and route the project-row action accordingly. Default to Antigravity.

Wire it into the sidebar project context menu:

```swift
.contextMenu {
    Button("Open in Antigravity") { ExternalEditor.openInAntigravity(project.rootPath) }
    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.rootPath]) }
    Divider()
    Button("Open in Terminal") { ExternalEditor.openInTerminal(project.rootPath) }
    Divider()
    Button("New Thread") { appState.newThread(in: project.id) }
    Button("Rename…") { appState.renameProject(project.id) }
    Divider()
    Button("Remove", role: .destructive) { appState.removeProject(project.id) }
}
```

Also on the project header and TerminalPaneView’s primary button — replace “Open in Terminal.app” with “Open in Antigravity” (keep an overflow with “Open in Terminal”).

-----

## 4. Thread view must actually be usable

The user’s core complaint — “nothing visible” — is going to become “it works but looks empty/wrong” once §2 is fixed. Pre-empt that by making the thread view properly laid out.

### 4.1 Structure

```
┌─────────────────────────────────────────────────────────┐
│  Thread header: title ▸ model pill ▸ ⋯                 │  44pt
├─────────────────────────────────────────────────────────┤
│                                                          │
│  transcript (ScrollView)                                │  flex
│                                                          │
│                                                          │
├─────────────────────────────────────────────────────────┤
│  context bar: ▓▓▓▓░░░░░░  12k/200k · $0.02 · 1 turn    │  28pt
├─────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────┐  ┌───────┐         │
│  │ Ask claude to do something…     │  │ Send  │         │  60-200pt
│  └─────────────────────────────────┘  └───────┘         │
└─────────────────────────────────────────────────────────┘
```

Concrete SwiftUI (skeleton — fill in details):

```swift
struct ThreadView: View {
    @Environment(AppState.self) private var appState
    let thread: Thread

    var engine: ThreadEngine? {
        appState.activeEngines[thread.id]
    }

    var body: some View {
        VStack(spacing: 0) {
            ThreadHeaderBar(thread: thread, engine: engine)
                .frame(height: 44)
                .padding(.horizontal, 16)
                .background(Color(NSColor.windowBackgroundColor))
            Divider()
            ThreadTranscriptView(engine: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ContextStatusBar(engine: engine)
                .frame(height: 28)
                .padding(.horizontal, 16)
                .background(.thinMaterial)
            Divider()
            ComposerView(thread: thread)
                .padding(12)
                .background(Color(NSColor.windowBackgroundColor))
        }
    }
}
```

### 4.2 Empty-state for the transcript

Before any messages exist, show a centered empty state (not a blank view — blank looks broken):

```swift
if (engine?.messages ?? []).isEmpty {
    VStack(spacing: 12) {
        Image(systemName: "sparkles.rectangle.stack")
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(.secondary)
        Text("Start a new conversation")
            .font(.title3).foregroundStyle(.secondary)
        Text("Type a message below. ClaudeDeck will spawn `claude` in \(thread.projectName) using `\(settings.selectedModelId)`.")
            .font(.caption).foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
} else {
    // ScrollView with messages
}
```

### 4.3 Message rendering

- **User message:** right-aligned, max width 640, rounded `.background(Color.accentColor.opacity(0.12))`, padding 12, textSelection enabled.
- **Assistant text:** left-aligned, full width to ~720 max, rendered as markdown via `Text(try? AttributedString(markdown: text))`. Monospace code blocks, rendered inline.
- **Tool call:** collapsible card (§4.4 below).
- **Tool result:** shown nested inside the corresponding tool call card (same id), NOT as a separate bubble.
- **System note:** small centered pill, secondary color.
- **Error:** red card (already defined in §2.4).

### 4.4 Tool call cards

```swift
struct ToolCallCard: View {
    let call: ToolCall
    let result: ToolResult?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed row
            HStack(spacing: 8) {
                Image(systemName: icon(for: call.name))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(call.name).font(.system(.body, design: .monospaced)).bold()
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if call.isRunning { ProgressView().controlSize(.small) }
                else if result?.isError == true { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
                else if result != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Input").font(.caption2).foregroundStyle(.secondary)
                    Text(formatJSON(call.input)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let result {
                        Divider()
                        Text("Result").font(.caption2).foregroundStyle(.secondary)
                        Text(result.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .padding(10)
                .background(Color(NSColor.textBackgroundColor))
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    private func icon(for tool: String) -> String {
        switch tool {
        case "Read": return "doc.text"
        case "Edit": return "pencil"
        case "Write": return "square.and.pencil"
        case "Bash": return "terminal"
        case "Grep": return "magnifyingglass"
        case "Glob": return "doc.on.doc"
        case "WebFetch": return "globe"
        case "WebSearch": return "magnifyingglass.circle"
        case "TodoWrite": return "checklist"
        default: return "hammer"
        }
    }

    private var summary: String {
        if let path = call.input["file_path"] as? String { return URL(fileURLWithPath: path).lastPathComponent }
        if let cmd = call.input["command"] as? String { return String(cmd.prefix(60)) }
        if let pattern = call.input["pattern"] as? String { return pattern }
        return ""
    }
}
```

### 4.5 Composer

```swift
struct ComposerView: View {
    let thread: Thread
    @Environment(AppState.self) private var appState
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var engine: ThreadEngine? { appState.activeEngines[thread.id] }
    var isRunning: Bool { engine?.state.isRunning ?? false }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Ask claude to do something in \(thread.projectName)…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    TextEditor(text: $text)
                        .focused($focused)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .frame(minHeight: 44, maxHeight: 200)
                        .onSubmit { send() }   // shift+enter inserts newline, enter alone handled below
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3), lineWidth: 1))

                if isRunning {
                    Button(action: stop) {
                        Image(systemName: "stop.fill").font(.system(size: 14))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop (⌘.)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (⌘⏎)")
                }
            }

            if isRunning, let model = engine?.currentModel {
                HStack {
                    Text("Running with \(model) — press ⌘. to stop")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .onAppear { focused = true }
    }

    private func send() {
        let payload = text
        text = ""
        Task {
            do {
                try await engine?.send(payload)
            } catch {
                Logger.shared.error("ComposerView.send failed: \(error)")
            }
        }
    }

    private func stop() {
        engine?.interrupt()
    }
}
```

### 4.6 Auto-scroll

```swift
struct ThreadTranscriptView: View {
    let engine: ThreadEngine?
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(engine?.messages ?? []) { message in
                        MessageBubbleView(message: message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
            .onChange(of: engine?.messages.count ?? 0) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}
```

-----

## 5. Sidebar: thread must be creatable and selectable

You reported the thread where you typed went nowhere. Verify this chain works end-to-end:

### 5.1 Sidebar create-thread action

Every project row should have a visible `+` button on hover (not just context menu). When clicked:

```swift
func newThread(in projectId: UUID) {
    guard let project = projectStore.project(for: projectId) else {
        Logger.shared.warn("newThread: project \(projectId) not found")
        return
    }
    let thread = Thread(
        id: UUID(),
        projectId: projectId,
        title: "New thread",
        sessionId: nil,
        createdAt: Date(),
        lastActivityAt: Date(),
        status: .idle
    )
    projectStore.addThread(thread)
    selectedThreadId = thread.id
    selectedProjectId = projectId
    Logger.shared.info("newThread: created \(thread.id) in project \(project.name); selectedThreadId=\(thread.id)")
}
```

### 5.2 Selection must trigger view

In `ContentView` or wherever the center pane is chosen:

```swift
if let threadId = appState.selectedThreadId,
   let thread = appState.threadStore.thread(for: threadId) {
    ThreadView(thread: thread)
} else if let projectId = appState.selectedProjectId,
          let project = appState.projectStore.project(for: projectId) {
    ProjectEmptyState(project: project)  // "no thread selected, click + to start"
} else {
    AppEmptyState()  // "add a project to begin"
}
```

### 5.3 Engine lifecycle

When the user sends their first message in a thread, `AppState` creates a `ThreadEngine` and stores it in `activeEngines[thread.id]`. Ensure:

- If `activeEngines[thread.id]` already exists, reuse it.
- If the engine’s child has died, `send()` starts a new child (we handle this in §2.5).

```swift
@MainActor
func engine(for thread: Thread) -> ThreadEngine {
    if let existing = activeEngines[thread.id] { return existing }
    guard let project = projectStore.project(for: thread.projectId) else {
        fatalError("engine(for:): project \(thread.projectId) not found — this is a bug")
    }
    let engine = ThreadEngine(thread: thread, project: project, settings: settings, envManager: envManager)
    activeEngines[thread.id] = engine
    return engine
}
```

`ComposerView.send()` and `ThreadView.engine` should call this helper so the engine exists before `send()` is invoked.

-----

## 6. Settings updates

### 6.1 Model field — make it obviously editable

Settings → General (or Provider):

- **Launch mode:** picker (Cloud / .env provider)
- **Model:** a combo (Picker with `.pickerStyle(.menu)` pre-populated from `ClaudeModelCatalog.defaults`, plus a “Custom…” option that reveals a text field below).
- When user picks Custom, text field reads “Enter model string, e.g. `minimax-m2.7:cloud` or `sonnet`”.
- Show live help text: “This is passed to `claude --model`. For Anthropic cloud, use `sonnet`, `opus`, or `haiku`. For custom routers, use their documented identifier.”

### 6.2 Doctor enhancements

Add a new check: **“Test spawn”** — runs the actual argv the app would use with a trivial prompt and reports PASS/FAIL with the stderr tail.

```swift
static func testSpawn() async -> (passed: Bool, detail: String) {
    guard let cli = CLIDetector.resolve() else { return (false, "CLI not found") }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claudedeck-probe-\(UUID())", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let settings = AppSettings.load()
    let model = settings.selectedModelId.isEmpty ? "sonnet" : settings.selectedModelId

    let p = Process()
    p.executableURL = cli
    p.arguments = [
        "-p", "--output-format", "stream-json", "--input-format", "stream-json",
        "--verbose", "--dangerously-skip-permissions",
        "--model", model, "--cwd", tmp.path
    ]
    p.environment = EnvFileManager.shared.buildCloudChildEnv()
    let outPipe = Pipe(); let errPipe = Pipe()
    p.standardOutput = outPipe; p.standardError = errPipe
    p.standardInput = Pipe()

    do { try p.run() } catch { return (false, "spawn failed: \(error)") }

    // Send prompt
    let prompt = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Reply with only PONG.\"}]}}\n"
    try? (p.standardInput as? Pipe)?.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
    try? (p.standardInput as? Pipe)?.fileHandleForWriting.close()

    // Wait up to 30s
    let deadline = Date().addingTimeInterval(30)
    while p.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
    if p.isRunning { p.terminate(); return (false, "timed out after 30s") }

    let out = String(data: outPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""

    if out.contains("PONG") { return (true, "got PONG from \(model)") }
    if p.terminationStatus == 0 { return (false, "exit 0 but no PONG; stdout tail: \(String(out.suffix(300)))") }
    return (false, "exit \(p.terminationStatus); stderr: \(String(err.suffix(500)))")
}
```

Add a “Test Spawn” button in Doctor that runs this and shows the result.

-----

## 7. Logging improvements for the next round

This round, log extra detail so I can diagnose issues from BUILD_LOG alone:

1. **In ThreadEngine**, log every stream-json event received at info level, up to 200 chars per line:
   
   ```swift
   private func handle(_ event: ClaudeEvent) {
       let preview = String(describing: event).prefix(200)
       Logger.shared.info("ThreadEngine event: \(preview)")
       // existing switch
   }
   ```
1. **Add a launch-time banner** in `ClaudeDeckApp`:
   
   ```swift
   init() {
       Logger.shared.info("========== ClaudeDeck launched ==========")
       Logger.shared.info("version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
       Logger.shared.info("pid: \(ProcessInfo.processInfo.processIdentifier)")
       Logger.shared.info("cli detection: \(CLIDetector.resolve()?.path ?? "NOT FOUND")")
       Logger.shared.info("settings: launchMode=\(AppSettings.load().launchMode.rawValue) model=\(AppSettings.load().selectedModelId)")
   }
   ```
1. **Add a “Copy diagnostics” button in Settings → Doctor.** When clicked, copies the last 500 lines of the log file to the clipboard. Next time the user reports an issue, they hit this button and paste — gives us everything.

-----

## 8. Verification checklist (gates for “done”)

Only mark Round 4 complete when **every** checkbox is ticked, with log-excerpt evidence pasted into BUILD_LOG:

- [ ] `xcodebuild clean build` → zero errors.
- [ ] App launches at 1600×950 size.
- [ ] Inspector is hidden by default; ⌘⇧I toggles it.
- [ ] Sidebar shows at least one project.
- [ ] Click “New Thread” — thread row appears under the project and gets selected.
- [ ] Type “hello” in composer — user bubble appears immediately (before any stdin write).
- [ ] Log shows the exact argv with `--verbose` and `--dangerously-skip-permissions` and the chosen `--model`.
- [ ] Within 30s, either an assistant reply renders in the transcript, OR a red error card shows stderr output.
- [ ] If stderr is shown, it is human-readable, copy-selectable, and actionable.
- [ ] Right-click a project → “Open in Antigravity” → either opens Antigravity or shows a log warning about fallback.
- [ ] Settings → Doctor → “Test Spawn” runs and reports PASS or a specific FAIL reason.
- [ ] Persistence: quit, reopen, project + thread + transcript all still visible.
- [ ] Log file exists at `~/Library/Application Support/ClaudeDeck/logs/claudedeck-<date>.log` and contains the launch banner + the spawn argv.

-----

## 9. Order of operations

Strict. Do not parallelize.

1. §2.1–§2.3: fix argv, log argv, surface stderr. **Build. Manual test. Check log.**
1. §2.4–§2.5: Message.error case, user bubble appears immediately. **Build. Manual test.**
1. §2.6: the end-to-end “hello” smoke test. **This gates everything else.** If it doesn’t work, fix it before §3.
1. §3.1: window size default.
1. §3.2: inspector hidden by default.
1. §3.3: Antigravity integration + fallback.
1. §4: thread view polish — header, transcript empty state, tool cards, composer, auto-scroll.
1. §5: sidebar thread-create + engine lifecycle (probably mostly working; just verify).
1. §6: Settings model picker + Test Spawn button.
1. §7: logging improvements.
1. §8: checklist pass, BUILD_LOG entry.

Each step ends with: (a) build, (b) run, (c) verify the specific behavior, (d) log to BUILD_LOG with log excerpt.

-----

## 10. What to send me back

In your reply after this round, paste into BUILD_LOG:

1. **The full `Round 4 — §2.6` section with the log tail** (the 80 lines after you did the “hello” test). This is the most diagnostic single piece of evidence.
1. The exact argv the app uses now, copy-pasted from the log.
1. The `Test Spawn` Doctor result.
1. A screenshot description of the UI at rest (what you see when app is open with a project selected, no thread).
1. Any `## ROUND 4 — KNOWN ISSUE:` sections for things you couldn’t fix.

Begin with §2.1. No UI work until §2 is green.