//
//  ComposerView.swift
//  ClaudeDeck
//
//  Multi-line text input with send and stop buttons.
//

import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    let isSending: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 40, maxHeight: 160)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .onSubmit {
                        onSend()
                    }

                Text("⌘⏎ to send, ⌘. to stop")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 8) {
                if isSending {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button(action: onSend) {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#Preview {
    ComposerView(
        text: .constant("Hello world"),
        isSending: false,
        onSend: {},
        onStop: {}
    )
    .padding()
}