# ClaudeDeck — Round 3 Prompt (Audit, Verify, Complete)

> **Before you write a single line of Swift, you are going to do a filesystem and project audit.** Two rounds of work have claimed to fix the same three compile errors, yet Xcode still reports all three at the same line numbers. That is not possible unless either (a) you have been editing files that the Xcode project does not include, (b) the `.xcodeproj` is pointing at stale references, or (c) there are duplicate copies of these files in the tree. Ignoring this any longer makes the whole project unsalvageable. Fix the root cause in §1 before anything else.

-----

## Ground rules (stricter this round)

1. **“BUILD SUCCEEDED” from `xcodebuild` does NOT mean the build is clean.** Xcode’s live diagnostics run the full Swift type-checker including SwiftUI macros, and Xcode reports errors that `xcodebuild` silently passes. From now on, after every change you must run **both** of these and paste both outputs into BUILD_LOG:
   
   ```bash
   xcodebuild -scheme Claudex -configuration Debug -destination 'platform=macOS' clean build 2>&1 | tail -60
   xcodebuild -scheme Claudex -configuration Debug -destination 'platform=macOS' -dry-run build 2>&1 | grep -iE "error|warning" | head -30
   ```
   
   If neither shows the Hashable error but Xcode does, the Xcode project is referencing a different file than the one you’re editing. Stop and re-audit §1.
1. **Do not mark a task “✅ done in earlier session.”** If you touch it this round, re-verify it this round with a current build excerpt in BUILD_LOG. Historical checkmarks do not count.
1. **Every task in this document ends with an explicit verification.** The verification text in the task tells you exactly what to run and what output proves the fix worked. You paste that output. No summary tables this round — I want raw evidence.
1. **Log format — strict:**
   
   ```
   ## Round 3 — Task <N>: <title>
   **Date:** <ISO date>
   **Files actually edited (with absolute paths):**
     - /Volumes/…/Thread.swift  (mtime: <stat output>)
   **What changed (diff-style summary, not prose):**
     - Thread.swift line 24: added explicit Hashable conformance via hash(into:) and ==
   **Clean build output (last 40 lines):**
   \`\`\`
   <paste>
   \`\`\`
   **Error grep:**
   \`\`\`
   <output of `xcodebuild … | grep -iE "error:"`>
   \`\`\`
   **Xcode live check:**
     - Opened Xcode, file navigated to, errors shown in gutter: NONE / [list them]
   **Runtime verification:**
     - Launched app via `open build/Build/Products/Debug/Claudex.app`
     - [specific action I did and what happened]
   ```
1. **This round, you are probably still running on MiniMax M2.7.** Do not trust your own memory of what files exist. Use `ls`, `find`, `stat`, `cat` to verify before editing. Edit → compile → verify → log, one file at a time.

-----

## §1 — Filesystem and project audit (do this first, no exceptions)

The error paths in Xcode read:

```
/Volumes/SrijanExt/Code/MacOs/Claudex/Claudex/Claudex/Core/Models/Thread.swift
                                      ^^^^^^^^^^^^^^^^ triple-nested suspicious
```

The root directory is `Claudex`, containing another `Claudex`, containing another `Claudex`. Something is wrong. Possibilities:

- Outer `Claudex/` = repo root, middle `Claudex/` = Xcode project folder, inner `Claudex/` = app target source folder. **Normal.**
- OR one of those is a stale mirror with duplicate .swift files that Xcode is compiling instead of yours.

You will now determine which.

### §1.1 Map the entire tree

Run and paste output verbatim to BUILD_LOG:

```bash
cd /Volumes/SrijanExt/Code/MacOs/Claudex
pwd
ls -la
find . -name "*.xcodeproj" -not -path "*/build/*" -not -path "*/DerivedData/*"
find . -name "Thread.swift" -not -path "*/build/*" -not -path "*/DerivedData/*" -not -path "*/.build/*"
find . -name "EnvFileManager.swift" -not -path "*/build/*" -not -path "*/DerivedData/*" -not -path "*/.build/*"
find . -name "SettingsView.swift" -not -path "*/build/*" -not -path "*/DerivedData/*" -not -path "*/.build/*"
find . -name "BUILD_LOG.md" -not -path "*/build/*" -not -path "*/DerivedData/*"
```

### §1.2 Verify which files Xcode actually compiles

The `.pbxproj` is where Xcode records file references. Find it and dump its Swift source paths:

```bash
XCODEPROJ=$(find . -name "*.xcodeproj" -not -path "*/build/*" | head -1)
echo "Project: $XCODEPROJ"
PBXPROJ="$XCODEPROJ/project.pbxproj"
grep -E "path = .*\.swift" "$PBXPROJ" | sort -u
```

Paste this output. Every `.swift` file Xcode compiles will appear here. If you see **duplicates** (same filename with different paths), that is your problem.

### §1.3 Verify file mtimes

For each of the three bugged files, show which copy has been edited recently:

```bash
for f in Thread.swift EnvFileManager.swift SettingsView.swift; do
  echo "=== $f ==="
  find . -name "$f" -not -path "*/build/*" -not -path "*/DerivedData/*" -exec stat -f "%Sm  %z bytes  %N" {} \;
done
```

### §1.4 Resolution

After the three commands above, you have a complete picture. Apply whichever applies:

- **Case A — Only one copy of each file exists, and it is inside the `Claudex/Claudex/` target directory referenced by `.pbxproj`:** the files you have been editing are correct. Rounds 1 and 2 simply didn’t successfully edit them or the edits were reverted. Proceed to §2 — actually fix the bugs now with `view` + `str_replace` (not `create_file` which would overwrite any manual edits).
- **Case B — Multiple copies exist:** identify the canonical one (the one inside the Xcode project target’s folder, matching `.pbxproj` paths). Delete or move the stale copy out of the tree to `/tmp/claudex-stale-<date>/`. Then proceed to §2.
- **Case C — The `.pbxproj` references files at a path that doesn’t match where files actually live:** this means someone moved source files without updating the Xcode project. Open `.xcodeproj` in Xcode and fix the references, OR add the correct files to the project target via drag-in. Record which you did.

**Write the conclusion (A / B / C) and the evidence that led to it in BUILD_LOG §1.4 before moving on.** No proceeding until this is in the log.

-----

## §2 — Fix the three errors, for real this time

You now know which file on disk Xcode actually compiles. Use `view` to read its current contents first — don’t assume.

### §2.1 Thread.swift:24 — Hashable conformance

```bash
# Before editing, view the current state:
view /Volumes/SrijanExt/Code/MacOs/Claudex/<CORRECT_PATH_FROM_§1>/Thread.swift
```

The fix is deterministic. At the bottom of `Thread.swift`, add (or replace any existing broken conformance with):

```swift
extension Thread: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    static func == (lhs: Thread, rhs: Thread) -> Bool {
        lhs.id == rhs.id
    }
}
```

Remove any `: Hashable` from the `struct Thread` declaration itself — we are providing conformance via the extension.

**Root cause you need to diagnose and log:** before applying the fix, find *which property* on `Thread` is not Hashable. Look for:

- `ThreadStatus` with an `.errored(String)` case where `String` is fine but something else isn’t.
- `[Message]` or similar where `Message` has an associated-value case not declared Hashable.
- A custom type that has `let someDict: [String: Any]` (Any is not Hashable).

Write the root cause in the task log: “Thread had property `<name>` of type `<T>` which does not conform to Hashable. Fixed by providing identity-based conformance keyed on UUID.” If you don’t diagnose the actual cause, you will hit it again elsewhere.

**Verify:**

```bash
xcodebuild -scheme Claudex -configuration Debug -destination 'platform=macOS' clean build 2>&1 | grep -iE "Thread.*Hashable" || echo "OK: Hashable error gone"
```

Expected: `OK: Hashable error gone`.

### §2.2 SettingsView.swift:180 — “Argument ‘passed’ must precede argument ‘detail’”

This is a **different** error than Round 2 saw. Round 2 had `let passed` mutation errors; now the error is about **argument order** in a `DoctorCheckItem` initializer call.

View the file:

```bash
view /Volumes/…/SettingsView.swift
```

Look at line 180 in context. Swift struct memberwise initializers require arguments in the order properties are declared in the struct. Either:

- The struct declares properties in order `id, name, passed, detail`, and line 180 passes them in order `id, name, detail, passed` — reorder the call-site arguments.
- OR the struct declares `id, name, detail, passed` but you want `passed` to come first — reorder the **struct’s** property declarations.

Pick the canonical order `id, name, passed, detail` (matching Round 2’s PRD). Make sure both the struct definition and every call site use this order. `grep -n "DoctorCheckItem(" path/to/*.swift` will find every call site.

**Verify:**

```bash
xcodebuild -scheme Claudex -configuration Debug -destination 'platform=macOS' clean build 2>&1 | grep -iE "passed.*precede|DoctorCheck" || echo "OK: DoctorCheckItem error gone"
```

### §2.3 EnvFileManager.swift:139 — “always-succeeds cast”

Round 2 said it fixed this but Xcode still shows it. Means either the fix was on the wrong file (§1 should have caught this) or the fix introduced the same pattern again.

View the file at line 139:

```bash
view /Volumes/…/EnvFileManager.swift  # look at lines 130-150
```

The line contains something like:

```swift
let currentEnv = ProcessInfo.processInfo.environment as? [String: String] ?? [:]
```

or

```swift
let x = someDict as? [String: String]
```

`ProcessInfo.processInfo.environment` returns a non-optional `[String: String]`. Write:

```swift
let currentEnv: [String: String] = ProcessInfo.processInfo.environment
```

Zero cast, fully typed. If the original author wanted defensive behavior, it’s unnecessary — the API guarantees the type.

**Verify:**

```bash
xcodebuild -scheme Claudex -configuration Debug -destination 'platform=macOS' clean build 2>&1 | grep -iE "always succeeds" || echo "OK: cast warning gone"
```

### §2.4 Final verification for §2

All three must return their “OK” messages. Additionally:

```bash
xcodebuild -scheme Claudex -configuration Debug -destination 'platform=macOS' clean build 2>&1 | grep -iE "error:" | head -20
```

This must print **nothing**. If it prints anything, address each error before moving on. Paste the full output (even if empty) into BUILD_LOG.

Then **open Xcode**, select `Product → Clean Build Folder` (⌘⇧K), then `Product → Build` (⌘B). Wait for it to finish. Check the Issue Navigator (⌘5). Screenshot or list: zero errors, zero warnings (warnings are acceptable but list them).

-----

## §3 — Why “Add Project” and “Import from Claude Code” silently do nothing

You reported that adding a folder does nothing visible in the sidebar, and Claude Code project import also does nothing. Round 2 claimed to wire both. The most likely causes, in order of probability:

1. **The action executes but the new `Project` isn’t published.** `ProjectStore` updates its own `@Published`/`@Observable` array, but the `SidebarView` is reading from a stale binding or a different instance of `ProjectStore`.
1. **The action adds the Project, but the sidebar’s `List` uses a filter/predicate that excludes it** (e.g., search field state not reset).
1. **The NSOpenPanel call path is blocked by sandbox or App Sandbox’s file-access rules,** and `panel.runModal()` returns `.cancel` silently. You said you’re willing to grant permissions — we’ll verify and disable sandbox properly.
1. **An exception is thrown in the handler but swallowed.** SwiftUI’s Task blocks with no do/catch swallow throws.

### §3.1 Add observability first

Before “fixing”, add aggressive logging so we can see exactly what happens when the user clicks “Add Project”. Touch these call sites:

**In the “Add Project” button handler (probably `SidebarView` or `AppState.addProjectFromFolder`):**

```swift
Logger.shared.info("addProjectFromFolder: invoked")
let panel = NSOpenPanel()
// … configure …
let response = panel.runModal()
Logger.shared.info("addProjectFromFolder: panel returned \(response.rawValue) url=\(panel.url?.path ?? "nil")")
guard response == .OK, let url = panel.url else {
    Logger.shared.warn("addProjectFromFolder: user cancelled or no URL")
    return
}
let resolved = url.resolvingSymlinksInPath().standardizedFileURL
Logger.shared.info("addProjectFromFolder: resolved=\(resolved.path) exists=\(FileManager.default.fileExists(atPath: resolved.path))")
let project = Project(id: UUID(), name: resolved.lastPathComponent, rootPath: resolved, createdAt: Date(), color: "blue")
Logger.shared.info("addProjectFromFolder: creating project id=\(project.id) name=\(project.name)")
projectStore.add(project)
Logger.shared.info("addProjectFromFolder: projectStore.projects.count=\(projectStore.projects.count)")
```

**In `ProjectStore.add(_:)`:**

```swift
func add(_ project: Project) {
    Logger.shared.info("ProjectStore.add: before count=\(projects.count) instance=\(ObjectIdentifier(self).debugDescription)")
    projects.append(project)
    save()
    Logger.shared.info("ProjectStore.add: after count=\(projects.count)")
}
```

**In `SidebarView.body`:**

```swift
var body: some View {
    let _ = Logger.shared.info("SidebarView render: project count = \(projectStore.projects.count)")
    // … existing body …
}
```

### §3.2 Verify ProjectStore is a single shared instance

If `SidebarView` creates its own `@StateObject private var projectStore = ProjectStore()`, it holds a **different** instance than the one the Add action mutates. Check this.

Correct pattern for this app: `ProjectStore` lives on `AppState`, and every view gets it via `@EnvironmentObject` or a shared `@Observable` reference.

```swift
// In ClaudeDeckApp.swift:
@main
struct ClaudeDeckApp: App {
    @State private var appState = AppState()  // @Observable

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        Settings {
            SettingsScene().environment(appState)
        }
    }
}

// In SidebarView:
@Environment(AppState.self) private var appState
// Use: appState.projectStore.projects
```

If the current code has `@StateObject` or re-instantiates ProjectStore anywhere, fix it. Use the `ObjectIdentifier` log from §3.1 to confirm — if `Add` and `SidebarView render` print the **same** ObjectIdentifier, you have a single instance. Different identifiers = the bug.

### §3.3 Re-test the flow with logs

Run the app, click Add Project, select a folder. Then:

```bash
tail -50 "$HOME/Library/Application Support/ClaudeDeck/logs/claudedeck-$(date +%Y-%m-%d).log"
```

Paste into BUILD_LOG. The log must show:

1. `addProjectFromFolder: invoked`
1. `addProjectFromFolder: panel returned 1 url=/some/path`
1. `ProjectStore.add: before count=0 instance=0x...`
1. `ProjectStore.add: after count=1`
1. `SidebarView render: project count = 1`

If (5) doesn’t appear or prints `0`, the sidebar isn’t observing the store. Fix the observation mechanism.

### §3.4 Persistence round-trip

After adding a project and seeing it in sidebar, **quit the app and restart it**. The project must still be there. If it’s not:

```bash
cat "$HOME/Library/Application Support/ClaudeDeck/projects.json"
```

If this file is missing or empty, `ProjectStore.save()` isn’t being called. If it’s present but malformed, decoding fails on next load. Paste the file contents into BUILD_LOG either way.

### §3.5 Import from Claude Code

Same pattern. Add logging at every step:

```swift
Logger.shared.info("importFromClaudeCode: scanning ~/.claude/projects/")
let discovered = discoverClaudeCodeProjects()
Logger.shared.info("importFromClaudeCode: discovered=\(discovered.count) projects: \(discovered.map(\.name))")
```

Then run it with actual data. If `discovered.count == 0` but you have sessions in `~/.claude/projects/`, the reason is almost always one of:

- The directory doesn’t exist (you’ve never run `claude` on this Mac).
- The JSONL first-line parse returns nil because `cwd` isn’t the first key — JSON order is not guaranteed. Fix: parse the entire first line as JSON, then look up `cwd` by key.
- Permissions: even with sandbox off, `~/.claude/` might require a one-time read grant.

To rule out permissions:

```bash
ls ~/.claude/projects/ | head
cat ~/.claude/projects/*/[a-f0-9]*.jsonl 2>/dev/null | head -1 | python3 -m json.tool
```

If this works in Terminal but not in the app, grant Full Disk Access (System Settings → Privacy & Security → Full Disk Access → add Claudex.app). **You mentioned you’re OK granting this.** Document which permissions you granted in BUILD_LOG.

### §3.6 Import sheet UX

If discovery works but the user can’t see the results: the import UI is a sheet presented via `.sheet(isPresented:)`. Verify the sheet binding is actually flipping to true. Add `.onChange(of: showingImportSheet) { Logger.shared.info("import sheet: \($0)") }` to confirm.

-----

## §4 — Actually launch the app and drive it

Round 2 never did runtime verification. This round you do. After §2 and §3 are logged green, run:

```bash
# 1. Clean-build and launch
xcodebuild -scheme Claudex -configuration Debug -destination 'platform=macOS' clean build -derivedDataPath ./build 2>&1 | tail -20
pkill -f Claudex || true
open ./build/Build/Products/Debug/Claudex.app
```

Then drive these flows and record in BUILD_LOG what you observed (not what you expected):

1. **App launches.** Window appears. Log the first 10 lines of the app log.
1. **Doctor tab.** Open Settings → Doctor. Click Re-run. Paste each check result.
1. **Add Project.** Pick `/tmp/claudex-test-project` (create this directory first). Verify it appears in sidebar. Quit, reopen, verify it’s still there.
1. **New Thread.** Click the project, click New Thread. Paste the log’s ThreadEngine spawn line, which should include the full argv.
1. **Send a prompt.** Type “Reply with only the single word PONG.” and ⌘⏎. Paste the transcript result (or the error if it failed).
1. **Stop mid-stream.** Send “Count from 1 to 100 slowly, one number per line.” Hit ⌘. after 3 seconds. Confirm child dies (`pgrep -f "claude --model" || echo "no claude children"`).
1. **Resume.** Quit the app. Reopen. Click the thread from step 5. It should show the transcript. Send “What number did you say last?” — it must reference a prior number (proves –resume worked).
1. **Import from Claude Code.** Click Import. Paste the list of discovered projects.

Any of these that don’t work → open a `## ROUND 3 — ISSUE:` section at the bottom of BUILD_LOG with: steps to reproduce, expected, actual, log tail.

-----

## §5 — Minimum viable terminal (stop blocking on SwiftTerm)

If SwiftTerm hasn’t been added yet, skip it entirely this round. The terminal pane is a nice-to-have. Instead, make the pane display a useful fallback:

```swift
struct TerminalPaneView: View {
    let project: Project
    @State private var output: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Terminal not yet available in-app").font(.headline)
                Spacer()
                Button("Open in Terminal.app") { openExternalTerminal() }
                Button("Copy `cd` command") { copyCd() }
            }
            .padding(.horizontal)

            ScrollView {
                Text(output.isEmpty ? "Click 'Open in Terminal.app' to launch an external zsh in this project's folder." : output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }

    private func openExternalTerminal() {
        let script = "tell application \"Terminal\" to do script \"cd \\\"\(project.rootPath.path)\\\"\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }

    private func copyCd() {
        let s = "cd \"\(project.rootPath.path)\""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
```

This is an honest “we don’t have a terminal yet, here’s the next-best thing” surface. Add a TODO comment pointing to the PRD’s §6 SwiftTerm integration for Round 4.

-----

## §6 — Visual baseline (UI should look like a real app)

You said Round 2 made the UI “very very minimalistic.” You applied a SegmentedPicker and 3-column split view — that’s structural but not visual. Apply these specific polish passes:

### §6.1 Sidebar

Replace a plain `List` with this layout:

```swift
struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack.badge.play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ClaudeDeck").font(.headline)
                    Text(appState.settings.launchMode.displayName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search", text: $searchQuery).textFieldStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.unemphasizedSelectedContentBackgroundColor)))
            .padding(.horizontal, 10).padding(.top, 8)

            // Projects
            List(selection: $appState.selection) {
                ForEach(filteredProjects) { project in
                    ProjectSection(project: project, search: searchQuery)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            Divider()

            // Bottom bar
            HStack {
                Button(action: { appState.addProjectFromFolder() }) {
                    Label("New Project", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button(action: { appState.showImportSheet = true }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Import from Claude Code")
                Menu {
                    Button("Doctor") { appState.showDoctor = true }
                    Button("Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                .buttonStyle(.borderless)
            }
            .padding(10)
        }
        .background(.ultraThinMaterial)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
    }

    private var filteredProjects: [Project] {
        if searchQuery.isEmpty { return appState.projectStore.projects }
        return appState.projectStore.projects.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }
}
```

### §6.2 Project & thread rows

```swift
struct ProjectSection: View {
    let project: Project
    let search: String
    @Environment(AppState.self) private var appState
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(threadsForProject) { thread in
                ThreadRow(thread: thread)
                    .tag(SidebarSelection.thread(thread.id))
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(project.color)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(project.name).font(.system(size: 13, weight: .semibold))
                    if let last = lastActivity {
                        Text(last, style: .relative)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(threadsForProject.count)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .tag(SidebarSelection.project(project.id))
            .contextMenu {
                Button("New Thread") { appState.newThread(in: project.id) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.rootPath]) }
                Button("Open in Terminal") { openInTerminal(project.rootPath) }
                Divider()
                Button("Remove", role: .destructive) { appState.removeProject(project.id) }
            }
        }
    }
    // threadsForProject, lastActivity, openInTerminal — implement
}
```

### §6.3 Thread view

Header bar, transcript, context bar, composer — minimum styling:

- Transcript: user messages in right-aligned bubbles (`.background(Color.accentColor.opacity(0.15))`, rounded, max width 640), assistant messages as plain markdown text with left padding, monospace code fences with dark background.
- Tool calls: rounded card, 1px border, collapsed row = `<icon> <toolname>(<one-line arg summary>)`, expanded = full JSON.
- Context bar: horizontal `Gauge` or custom bar: filled proportion = usedTokens / contextWindow, yellow at 70%, red at 90%. Label `"<used> / <total> tokens · $<cost>"`.
- Composer: rounded rect, 1px border, TextEditor inside, Send button (blue) that becomes Stop button (red) while running. ⌘⏎ / ⌘. bindings.

Get this shipped with reasonable padding (`.padding(.horizontal, 16).padding(.vertical, 10)`) and semantic colors. Perfection is not the goal — looking like a real macOS app is.

-----

## §7 — Test target (final)

You said “test target needs setup in Xcode” for two rounds. Do it this round.

### §7.1 Create the target

Open Xcode → File → New → Target → macOS → Unit Testing Bundle. Name: `ClaudexTests`. Host Application: `Claudex`. Close Xcode, reopen to make sure it saved.

### §7.2 Add tests

Create the following test files under `ClaudexTests/` (both on disk and added to the `ClaudexTests` target):

- `PathEncoderTests.swift` — 5 cases (see PRD §13.1).
- `StreamJSONParserTests.swift` — 8 cases (see PRD §8.2).
- `EnvFileManagerTests.swift` — write→read round trip, strip-env test, bad-file test.
- `ProjectStoreTests.swift` — add/remove/persist, URL→path serialization.
- `SessionStoreTests.swift` — requires `ClaudexTests/Fixtures/sample-session.jsonl` which you create manually with 5 events (1 user, 1 assistant with a tool_use, 1 tool_result, 1 more assistant, 1 result).

### §7.3 Run

```bash
./script/test.sh 2>&1 | tail -60
```

Paste the tail into BUILD_LOG. All tests green before you call §7 done.

-----

## §8 — Closing deliverable

After everything above:

1. **Run the full acceptance script.** Append to BUILD_LOG:

```bash
echo "=== CLEAN BUILD ==="
xcodebuild -scheme Claudex -configuration Debug -destination 'platform=macOS' clean build 2>&1 | grep -iE "error:|warning:" | head -30
echo "=== TESTS ==="
./script/test.sh 2>&1 | tail -20
echo "=== INTEGRATION ==="
./script/integration_test.sh 2>&1 | tail -20
echo "=== PROCESS CHECK ==="
pgrep -f "claude --model" || echo "(no claude children — good when app is idle)"
```

1. **Update README.md** with:
- What works today (every box checked in §4 runtime verification).
- Known limitations (terminal is external-only for now; etc.).
- Permissions the app needs and how to grant them on macOS 14+.
- “How to diagnose issues” pointing at the log directory.
1. **Append a Round 3 summary** at the end of BUILD_LOG with the pattern:

```
## Round 3 — Summary

**Start state (Xcode errors at round start):**
- Thread.swift:24 Hashable
- SettingsView.swift:180 passed/detail order
- EnvFileManager.swift:139 cast
- Add Project: non-functional
- Import from Claude Code: non-functional

**Root causes discovered (from §1 audit):**
- <write it here>

**Fixes applied:**
- <one line per fix with file:line>

**End state (Xcode errors after clean build):**
- [paste output of `xcodebuild … | grep error:`]

**Runtime verification results:**
- [each of §4's 8 flows: PASS or FAIL with details]

**Known issues / deferred to Round 4:**
- <anything>
```

-----

## §9 — Order of operations (follow exactly)

1. §1 audit — filesystem and pbxproj. Log. **Do not proceed until Case A/B/C is declared.**
1. §2.1 Thread.swift — fix, verify, log.
1. §2.2 SettingsView.swift — fix, verify, log.
1. §2.3 EnvFileManager.swift — fix, verify, log.
1. §2.4 final compile check — log.
1. §3 Add Project / Import — instrument with logs, fix, runtime-verify, log.
1. §4 drive the app through 8 flows — log observations.
1. §5 terminal fallback — ship the osascript version.
1. §6 UI polish — sidebar, rows, thread view.
1. §7 tests.
1. §8 deliverable.

If you get stuck on any task for more than 3 attempts, stop and write `## ROUND 3 — STUCK: Task <N>` with full context (what you tried, what happened, current state). Do not keep guessing.

-----

## §10 — Things that will go wrong (read before you hit them)

- **The audit in §1 will likely reveal that files have been edited in the wrong directory.** Round 2’s log says it fixed `SettingsView.swift` but the error is still there — that is the smoking gun. Expect Case B or C. Don’t be surprised when you find it; document it clearly.
- **`Process.environment` typing has changed between Swift versions.** On current toolchains it’s `[String: String]?`. If it’s non-optional in this project due to SDK differences, just assign directly. The point is: no `as?` cast.
- **`.environment(appState)` vs `.environmentObject(appState)`** — the former is for `@Observable`, the latter for `ObservableObject`. Using the wrong one means views silently don’t update. If the sidebar doesn’t re-render after adding a project, this is the first thing to check.
- **`projects.json` decoding can fail silently if you changed the Project schema.** Always wrap in do/catch and log. If decode fails, rename the bad file to `projects.json.bak-<date>` and start fresh rather than crashing.
- **NSOpenPanel on sandboxed apps returns URLs you must resolve with security scopes.** With sandbox off (confirmed in entitlements) this isn’t needed, but verify by grepping `Claudex.entitlements` for `com.apple.security.app-sandbox` — value should be `false` or absent.
- **Full Disk Access is granted per-build-binary path.** Every time you rebuild, macOS might re-prompt. If reading `~/.claude/projects/` fails after you granted FDA, the app binary path changed — re-grant.
- **`xcodebuild` caches aggressively.** If a fix “doesn’t take,” `rm -rf build DerivedData` and try again.

Begin with §1. No code yet.