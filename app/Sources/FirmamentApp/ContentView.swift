import FirmamentCore
import SwiftUI

struct ContentView: View {
    @Environment(VaultModel.self) private var model
    @State private var selection: String?
    @State private var showCapture = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(
                get: { model.scope },
                set: { model.scope = $0 ?? .all })) {
                Section("Vault") {
                    scopeRow(.all, label: "All", symbol: "tray.full")
                    scopeRow(.facet(.selfFacet), label: "Self", symbol: "person.crop.circle")
                    scopeRow(.facet(.others), label: "Others", symbol: "person.2")
                    scopeRow(.facet(.agents), label: "Agents", symbol: "sparkles")
                }
                Section("Deepen") {
                    HStack {
                        Label("Questions", systemImage: "questionmark.bubble")
                        Spacer()
                        if !model.questions.isEmpty {
                            Text("\(model.questions.count)")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.violet.opacity(0.35), in: Capsule())
                        }
                    }
                    .tag(VaultModel.Scope.questions)
                }
                Section("System") {
                    scopeRow(.trash, label: "Trash", symbol: "trash")
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            entryList
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            if let selection, let detail = model.detail(for: selection) {
                InspectorView(detail: detail)
            } else {
                ContentUnavailableView(
                    "Nothing selected", systemImage: "circle.dotted",
                    description: Text("Pick an entry, or capture a thought."))
            }
        }
        .background(Theme.field)
        .searchable(text: $model.query, placement: .sidebar, prompt: "Search the vault")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCapture = true
                } label: {
                    Label("Capture", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showCapture) { CaptureSheet() }
        .overlay(alignment: .bottom) {
            if let error = model.serviceError {
                Text(error)
                    .font(.callout)
                    .padding(10)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom))
            }
        }
    }

    private func scopeRow(
        _ scope: VaultModel.Scope, label: String, symbol: String
    ) -> some View {
        Label(label, systemImage: symbol).tag(scope)
    }

    @ViewBuilder
    private var entryList: some View {
        if case .questions = model.scope {
            QuestionListView()
        } else if model.rows.isEmpty {
            ContentUnavailableView(
                "Empty", systemImage: "moon.stars",
                description: Text("Entries appear here as they are captured and imported."))
        } else {
            List(model.rows, selection: $selection) { row in
                EntryRowView(row: row).tag(row.id)
            }
            .listStyle(.inset)
        }
    }
}

struct EntryRowView: View {
    let row: BrowseRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.violet)
                    .font(.caption)
                Text(row.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if row.localOnly {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.faint)
                        .help("Local only — never leaves this Mac")
                }
                if row.hasOpenQuestion {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.violet)
                        .help("Glia has a question about this")
                }
            }
            if !row.summary.isEmpty {
                Text(row.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(row.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch row.facet {
        case .selfFacet: "person.crop.circle"
        case .others: "person.2"
        case .agents: "sparkles"
        }
    }
}

struct QuestionListView: View {
    @Environment(VaultModel.self) private var model
    @State private var answers: [String: String] = [:]

    var body: some View {
        if model.questions.isEmpty {
            ContentUnavailableView(
                "No open questions", systemImage: "checkmark.seal",
                description: Text("When an entry invites a question worth asking, it lands here."))
        } else {
            List(model.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.text)
                        .font(.headline)
                    if let rationale = question.rationale {
                        Text(rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("From: \(question.entryTitle)")
                        .font(.caption2)
                        .foregroundStyle(Theme.faint)
                    HStack {
                        TextField("Answer…", text: Binding(
                            get: { answers[question.id] ?? "" },
                            set: { answers[question.id] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { submit(question) }
                        Button("Answer") { submit(question) }
                            .disabled((answers[question.id] ?? "").isEmpty)
                        Button("Dismiss", role: .destructive) {
                            model.dismiss(questionID: question.id)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .listStyle(.inset)
        }
    }

    private func submit(_ question: QuestionSummary) {
        guard let text = answers[question.id], !text.isEmpty else { return }
        model.answer(questionID: question.id, text: text)
        answers[question.id] = nil
    }
}

struct InspectorView: View {
    @Environment(VaultModel.self) private var model
    let detail: EntryDetail
    @State private var answerText = ""
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.row.title).font(.title2.bold())
                    HStack(spacing: 8) {
                        chip(detail.row.facet.rawValue)
                        if detail.row.localOnly { chip("local only", symbol: "lock.fill") }
                        chip("\(detail.revisionCount) revision\(detail.revisionCount == 1 ? "" : "s")")
                        Text(detail.row.createdAt.formatted(
                            date: .abbreviated, time: .shortened))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.faint)
                    }
                }
                if !detail.row.summary.isEmpty {
                    Text(detail.row.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                tagsSection
                if let question = detail.question {
                    questionCard(question)
                }
                if let raw = detail.rawText {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Raw").font(.caption.smallCaps()).foregroundStyle(Theme.faint)
                        Text(raw)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    Label(detail.mime, systemImage: "waveform")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Theme.field)
        .toolbar {
            ToolbarItemGroup(placement: .destructiveAction) {
                if detail.row.trashed {
                    Button("Restore") { model.untrash(id: detail.row.id) }
                } else {
                    Button { model.trash(id: detail.row.id) } label: {
                        Label("Trash", systemImage: "trash")
                    }
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete Now", systemImage: "trash.slash")
                }
            }
        }
        .confirmationDialog(
            "Delete Now permanently removes the raw content, every revision, and all derived data. There is no undo.",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) {
                model.deleteNow(id: detail.row.id)
            }
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        let tags = detail.people.map { ("person", $0) }
            + detail.projects.map { ("folder", $0) }
            + detail.topics.map { ("number", $0) }
        if !tags.isEmpty {
            FlowChips(tags: tags)
        }
    }

    private func questionCard(_ question: QuestionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Glia asks", systemImage: "questionmark.bubble.fill")
                .font(.caption.smallCaps())
                .foregroundStyle(Theme.violet)
            Text(question.text).font(.headline)
            if let rationale = question.rationale {
                Text(rationale).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Answer…", text: $answerText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitAnswer(question) }
                Button("Answer") { submitAnswer(question) }
                    .disabled(answerText.isEmpty)
                Button("Dismiss", role: .destructive) {
                    model.dismiss(questionID: question.id)
                }
            }
        }
        .padding(12)
        .background(Theme.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Theme.violet.opacity(0.4)))
    }

    private func submitAnswer(_ question: QuestionSummary) {
        guard !answerText.isEmpty else { return }
        model.answer(questionID: question.id, text: answerText)
        answerText = ""
    }

    private func chip(_ text: String, symbol: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.caption2) }
            Text(text).font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.panel, in: Capsule())
        .foregroundStyle(.secondary)
    }
}

/// Simple wrapping chip row for people/projects/topics.
struct FlowChips: View {
    let tags: [(symbol: String, text: String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                HStack(spacing: 4) {
                    Image(systemName: tag.symbol).font(.caption2)
                    Text(tag.text).font(.caption).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.panel, in: Capsule())
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct CaptureSheet: View {
    @Environment(VaultModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var localOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture a thought").font(.title3.bold())
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 420, minHeight: 180)
                .padding(6)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            Toggle(isOn: $localOnly) {
                Label("Local only — never processed in the cloud, never enters packets",
                      systemImage: "lock")
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save to vault") {
                    model.capture(text: text, localOnly: localOnly)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .background(Theme.field)
    }
}
