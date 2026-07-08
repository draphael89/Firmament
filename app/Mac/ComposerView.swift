import FirmamentKit
import SwiftUI

/// The markdown-native text composer (SPEC §9.4). Entity autocomplete
/// (@ and [[) arrives with the Graph in M2 — at M0 this is a fast plain
/// editor whose only job is appending a capture.text event.
struct ComposerView: View {
    let pipeline: CapturePipeline
    @Environment(\.dismiss) private var dismiss

    @State private var body_ = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $body_)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .frame(minWidth: 440, minHeight: 220)
            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Text("⌘↩ to save").font(.caption).foregroundStyle(.tertiary)
                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }
        .padding(12)
    }

    private func save() {
        saving = true
        let text = body_
        Task {
            do {
                try await pipeline.captureText(body: text, sourcePlane: .composer)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    self.error = "save failed: \(error)"
                    self.saving = false
                }
            }
        }
    }
}
