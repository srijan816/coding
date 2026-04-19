//
//  ThreadView.swift
//  ClaudeDeck
//
//  Chat transcript with composer for a thread.
//

import SwiftUI

struct ThreadView: View {
    let thread: Thread
    var engine: ThreadEngineProtocol?

    @State private var composerText: String = ""
    @State private var isSending: Bool = false
    @State private var historicalMessages: [Message] = []

    var body: some View {
        VStack(spacing: 0) {
            // Thread header
            threadHeader
                .frame(height: 44)
                .padding(.horizontal, 16)
                .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Transcript
            if allMessages.isEmpty {
                emptyState
            } else {
                transcriptView
            }

            Divider()

            // Context status bar
            if engine != nil {
                contextStatusBar
                    .frame(height: 28)
                    .padding(.horizontal, 16)
                    .background(.thinMaterial)
                Divider()
            }

            // Composer
            ComposerView(
                text: $composerText,
                isSending: isSending,
                onSend: sendMessage,
                onStop: { engine?.interrupt() }
            )
            .padding(12)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onAppear { loadMessages() }
    }

    private var threadHeader: some View {
        HStack(spacing: 12) {
            Text(thread.title.isEmpty ? "New Thread" : thread.title)
                .font(.headline)
            if let model = engine?.currentModel, !model.isEmpty {
                Text(model)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }

    private var contextStatusBar: some View {
        HStack(spacing: 16) {
            if let tokens = engine?.currentTokens, tokens > 0 {
                Text("\(tokens.formatted()) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let cost = engine?.lastCostUsd, cost > 0 {
                Text(String(format: "$%.4f", cost))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Start a new conversation")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Type a message below. ClaudeDeck will spawn `claude` in \(thread.projectName) using `\(AppSettings.load().selectedModelId)`.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(allMessages, id: \.id) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: allMessages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var allMessages: [Message] {
        (engine?.messages ?? []) + historicalMessages
    }

    private func loadMessages() {
        guard let sessionId = thread.sessionId,
              let project = AppState.shared.project(for: thread.id) else {
            return
        }

        Task {
            do {
                var loaded: [Message] = []
                let stream = try SessionStore.shared.messages(for: sessionId, in: project)
                for try await message in stream {
                    loaded.append(message)
                }
                await MainActor.run {
                    self.historicalMessages = loaded
                }
            } catch {
                Logger.shared.warn("Failed to load session messages: \(error.localizedDescription)")
            }
        }
    }

    private func sendMessage() {
        guard !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task {
            isSending = true
            defer { isSending = false }

            let text = composerText
            composerText = ""

            do {
                if engine == nil {
                    guard let project = AppState.shared.project(for: thread.id) else {
                        Logger.shared.error("No project for thread \(thread.id)")
                        return
                    }
                    try await AppState.shared.startEngine(for: thread, in: project)
                }

                try await engine?.send(text)
            } catch {
                Logger.shared.error("Failed to send: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Thread Extension

extension Thread {
    var projectName: String {
        if let project = AppState.shared.project(for: id) {
            return project.name
        }
        return "this project"
    }
}

// MARK: - Message Bubble

struct MessageBubbleView: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch message {
            case .user(let text, _):
                HStack {
                    Spacer()
                    Text(text)
                        .padding(8)
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

            case .assistantText(let text, _):
                Text(text)
                    .textSelection(.enabled)

            case .toolCall(let toolCall, _):
                ToolCallView(toolCall: toolCall)

            case .toolResult(let result, _):
                HStack {
                    Spacer()
                    Text(result.content)
                        .font(.caption)
                        .foregroundStyle(result.isError ? .red : .secondary)
                        .padding(4)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

            case .systemNote(let text, _):
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()

            case .error(let text, _):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text("Error").font(.caption).bold().foregroundStyle(.red)
                    }
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 1))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ThreadView(
        thread: Thread(projectId: UUID(), title: "Test Thread"),
        engine: nil
    )
}