//
//  SettingsView.swift
//  ClaudeDeck
//
//  General settings tab + Provider settings tab + Doctor diagnostics tab.
//

import SwiftUI

struct SettingsView: View {
    @State private var appSettings: AppSettings = .load()
    @State private var providerSettings: ProviderSettings = .miniMaxDefault
    @State private var authTokenVisible: Bool = false
    @State private var toastMessage: String?
    @State private var showToast: Bool = false
    @State private var doctorResults: [DoctorCheckItem] = []
    @State private var doctorRunning: Bool = false
    @State private var selectedModelId: String = AppSettings.load().selectedModelId
    @State private var customModelString: String = ""
    @State private var useCustomModel: Bool = false

    private let envManager = EnvFileManager.shared

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            providerTab
                .tabItem { Label("Provider", systemImage: "cloud") }

            doctorTab
                .tabItem { Label("Doctor", systemImage: "stethoscope") }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            loadSettings()
            loadAppSettings()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Launch Mode") {
                Picker("Mode", selection: $appSettings.launchMode) {
                    ForEach(LaunchMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(appSettings.launchMode == .cloudManaged
                     ? "Uses your claude login credentials. Configure via `claude auth` in Terminal."
                     : "Uses ANTHROPIC_AUTH_TOKEN from .env file in project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                Picker("Preset", selection: $selectedModelId) {
                    Text("Select a model...").tag("")
                    ForEach(ClaudeModelCatalog.defaults) { model in
                        Text(model.displayName).tag(model.id)
                    }
                    Text("Custom...").tag("__custom__")
                }
                .pickerStyle(.menu)
                .onChange(of: selectedModelId) { _, newValue in
                    useCustomModel = newValue == "__custom__"
                    if !useCustomModel && !newValue.isEmpty {
                        appSettings.selectedModelId = newValue
                    }
                }

                if selectedModelId == "__custom__" || (useCustomModel && !customModelString.isEmpty) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Custom model string", text: $customModelString)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: customModelString) { _, newValue in
                                appSettings.selectedModelId = newValue
                            }
                        Text("This is passed to `claude --model`. For Anthropic cloud, use `sonnet`, `opus`, or `haiku`. For custom routers, use their documented identifier.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if selectedModelId != "__custom__" && !selectedModelId.isEmpty {
                    Text("Currently using: `\(selectedModelId)`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Save") { saveAppSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .overlay(alignment: .top) {
            if showToast, let message = toastMessage {
                Text(message)
                    .padding()
                    .background(.green.opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { showToast = false }
                        }
                    }
            }
        }
    }

    // MARK: - Provider Tab

    private var providerTab: some View {
        Form {
            Section("Endpoint") {
                TextField("Base URL", text: $providerSettings.baseURL)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    SecureField("Auth Token", text: $providerSettings.authToken)
                    Button {
                        authTokenVisible.toggle()
                    } label: {
                        Image(systemName: authTokenVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section("Model") {
                TextField("Model", text: $providerSettings.model)
                    .textFieldStyle(.roundedBorder)

                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("API Timeout (ms)")
                            Spacer()
                            TextField("", value: $providerSettings.apiTimeoutMs, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }

                        Toggle("Disable non-essential traffic", isOn: $providerSettings.disableNonessentialTraffic)

                        HStack {
                            Text("Context window override")
                            Spacer()
                            TextField("e.g. MiniMax-M2.7:200000", text: Binding(
                                get: { providerSettings.maxContextTokensOverride ?? "" },
                                set: { providerSettings.maxContextTokensOverride = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            Section {
                Button("Save") { saveProviderSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - Doctor Tab

    private var doctorTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Diagnostic Checks")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(doctorResults) { item in
                        doctorRow(item)
                    }
                }
            }

            if doctorResults.isEmpty && !doctorRunning {
                Text("Click 'Run Checks' to diagnose your setup")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(doctorRunning ? "Running…" : "Run Checks") {
                    runDoctorChecks()
                }
                .buttonStyle(.borderedProminent)
                .disabled(doctorRunning)

                Button("Test Spawn") {
                    testSpawn()
                }
                .buttonStyle(.bordered)
                .disabled(doctorRunning)
            }

            if !doctorResults.isEmpty {
                Button("Copy Diagnostics") {
                    copyDiagnostics()
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
        .padding()
    }

    private func doctorRow(_ item: DoctorCheckItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(item.passed ? Color.green : Color.red)
            VStack(alignment: .leading) {
                Text(item.name).bold()
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func loadAppSettings() {
        appSettings = AppSettings.load()
        selectedModelId = appSettings.selectedModelId
        if !ClaudeModelCatalog.defaults.contains(where: { $0.id == selectedModelId }) {
            useCustomModel = true
            customModelString = selectedModelId
            selectedModelId = "__custom__"
        }
    }

    private func loadSettings() {
        if let loaded = try? envManager.load() {
            providerSettings = loaded
        }
    }

    private func saveAppSettings() {
        appSettings.selectedModelId = selectedModelId == "__custom__" ? customModelString : selectedModelId
        appSettings.save()
        toastMessage = "Settings saved."
        withAnimation { showToast = true }
    }

    private func saveProviderSettings() {
        do {
            try envManager.save(providerSettings)
            toastMessage = "Provider settings saved."
            withAnimation { showToast = true }
        } catch {
            toastMessage = "Failed to save: \(error.localizedDescription)"
            withAnimation { showToast = true }
        }
    }

    private func runDoctorChecks() {
        doctorRunning = true
        doctorResults = []

        Task {
            var results: [DoctorCheckItem] = []

            // 1. CLI detection
            do {
                let result = try CLIDetector.shared.resolve()
                results.append(DoctorCheckItem(name: "claude binary found", passed: true, detail: result.url.path))
                results.append(DoctorCheckItem(name: "claude --version", passed: true, detail: result.version))
            } catch {
                results.append(DoctorCheckItem(name: "claude CLI not found", passed: false, detail: error.localizedDescription))
            }

            // 2. .env file
            let envURL = envManager.envFileURL
            if FileManager.default.fileExists(atPath: envURL.path) {
                results.append(DoctorCheckItem(name: ".env file found", passed: true, detail: envURL.path))

                if let attrs = try? FileManager.default.attributesOfItem(atPath: envURL.path),
                   let mode = attrs[.posixPermissions] as? Int {
                    let modeOctal = String(format: "%o", mode)
                    results.append(DoctorCheckItem(name: ".env mode",
                        passed: mode == 0o600 || mode == 384,
                        detail: modeOctal))
                }
            } else {
                results.append(DoctorCheckItem(name: ".env file not found", passed: false, detail: envURL.path))
            }

            // 3. Parse .env
            if let parsed = try? envManager.load() {
                if !parsed.baseURL.isEmpty, let url = URL(string: parsed.baseURL), url.scheme != nil {
                    results.append(DoctorCheckItem(name: "ANTHROPIC_BASE_URL is well-formed", passed: true, detail: ""))
                } else {
                    results.append(DoctorCheckItem(name: "ANTHROPIC_BASE_URL is invalid", passed: false, detail: ""))
                }

                if !parsed.authToken.isEmpty {
                    results.append(DoctorCheckItem(name: "ANTHROPIC_AUTH_TOKEN is set", passed: true, detail: ""))
                } else {
                    results.append(DoctorCheckItem(name: "ANTHROPIC_AUTH_TOKEN is empty", passed: false, detail: ""))
                }
            }

            // 4. Ping test
            if let parsed = try? envManager.load(),
               !parsed.authToken.isEmpty {
                let pingResult = await pingEndpoint(baseURL: parsed.baseURL, authToken: parsed.authToken, model: parsed.model)
                results.append(pingResult)
            }

            await MainActor.run {
                doctorResults = results
                doctorRunning = false
            }
        }
    }

    private func testSpawn() {
        doctorRunning = true
        doctorResults = [DoctorCheckItem(name: "Test Spawn", passed: false, detail: "Running...")]

        Task {
            let result = await Self.testSpawnAsync()
            await MainActor.run {
                doctorResults = [result]
                doctorRunning = false
            }
        }
    }

    private static func testSpawnAsync() async -> DoctorCheckItem {
        guard let cli = try? CLIDetector.shared.resolve() else {
            return DoctorCheckItem(name: "Test Spawn", passed: false, detail: "claude CLI not found")
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claudedeck-probe-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let appSettings = AppSettings.load()
        let model = appSettings.selectedModelId.isEmpty ? "sonnet" : appSettings.selectedModelId

        let p = Process()
        p.executableURL = cli.url
        var args = [
            "-p", "--output-format", "stream-json", "--input-format", "stream-json",
            "--verbose", "--dangerously-skip-permissions",
            "--model", model, "--cwd", tmp.path
        ]
        if appSettings.launchMode == .envProvider {
            if let settings = try? EnvFileManager.shared.load(),
               let settingsURL = try? SettingsJSONBuilder.write(settings: settings) {
                args.append("--settings")
                args.append(settingsURL.path)
            }
        }
        p.arguments = args
        p.environment = EnvFileManager.shared.buildCloudChildEnv()
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        p.standardInput = Pipe()

        do { try p.run() } catch { return DoctorCheckItem(name: "Test Spawn", passed: false, detail: "spawn failed: \(error)") }

        // Send prompt
        let prompt = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Reply with only PONG.\"}]}}\n"
        try? (p.standardInput as? Pipe)?.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try? (p.standardInput as? Pipe)?.fileHandleForWriting.close()

        // Wait up to 30s
        let deadline = Date().addingTimeInterval(30)
        while p.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        if p.isRunning { p.terminate(); return DoctorCheckItem(name: "Test Spawn", passed: false, detail: "timed out after 30s") }

        let out = String(data: outPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""

        if out.contains("PONG") { return DoctorCheckItem(name: "Test Spawn", passed: true, detail: "got PONG from \(model)") }
        if p.terminationStatus == 0 { return DoctorCheckItem(name: "Test Spawn", passed: false, detail: "exit 0 but no PONG; stdout tail: \(String(out.suffix(300)))") }
        return DoctorCheckItem(name: "Test Spawn", passed: false, detail: "exit \(p.terminationStatus); stderr: \(String(err.suffix(500)))")
    }

    private func copyDiagnostics() {
        let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Claudex/logs")
        var logContent = "Claudex Diagnostics\n"
        logContent += "===================\n"
        logContent += "App Settings: launchMode=\(appSettings.launchMode.rawValue) model=\(appSettings.selectedModelId)\n"

        if let logs = try? FileManager.default.contentsOfDirectory(at: logDir!, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let sorted = logs.sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA > dateB
            }
            for log in sorted.prefix(2) {
                if let content = try? String(contentsOf: log, encoding: .utf8) {
                    logContent += "\n--- \(log.lastPathComponent) ---\n"
                    logContent += String(content.suffix(2000))
                }
            }
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logContent, forType: .string)
        toastMessage = "Diagnostics copied to clipboard"
        withAnimation { showToast = true }
    }

    private func pingEndpoint(baseURL: String, authToken: String, model: String) async -> DoctorCheckItem {
        guard let url = URL(string: "\(baseURL)/v1/messages") else {
            return DoctorCheckItem(name: "Invalid base URL", passed: false, detail: "Could not parse URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(authToken, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                let code = httpResponse.statusCode
                return DoctorCheckItem(
                    name: "Ping to \(baseURL)",
                    passed: code == 200 || code == 400,
                    detail: "HTTP \(code)"
                )
            }
            return DoctorCheckItem(name: "Ping result unclear", passed: false, detail: "Unexpected response")
        } catch {
            return DoctorCheckItem(name: "Ping failed", passed: false, detail: error.localizedDescription)
        }
    }
}

// MARK: - Doctor Check Item

struct DoctorCheckItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    var passed: Bool
    var detail: String

    init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

#Preview {
    SettingsView()
}