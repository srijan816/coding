//
//  ToolCallView.swift
//  ClaudeDeck
//
//  Collapsible card showing tool name, input preview, and result.
//

import SwiftUI

struct ToolCallView: View {
    let toolCall: ToolCall

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusIndicator
                Text(toolCall.name)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Input:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(formatJSON(toolCall.input))
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .padding(.leading, 8)
            } else {
                // Collapsed: show one-line input summary
                Text(summaryPreview)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 8)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusIndicator: some View {
        Circle()
            .fill(Color.yellow)
            .frame(width: 8, height: 8)
    }

    private var summaryPreview: String {
        // Extract first key=value from input for collapsed preview
        if let first = toolCall.input.first {
            return "\(first.key): \(first.value)"
        }
        return ""
    }

    private func formatJSON(_ dict: [String: AnyCodable]) -> String {
        let data = dict.mapValues { $0.value }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted),
              let str = String(data: jsonData, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

#Preview {
    ToolCallView(toolCall: ToolCall(
        name: "Read",
        input: ["path": AnyCodable("/Users/test/file.txt")]
    ))
    .padding()
}