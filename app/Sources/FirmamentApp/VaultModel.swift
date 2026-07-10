import FirmamentCore
import Foundation
import Observation

/// Read model for the app: browses the vault via a read-only WAL connection
/// (safe alongside the service's writer) and routes every mutation through
/// the service socket. Polls for freshness — cross-process change
/// notification isn't worth its complexity at vault scale.
@MainActor
@Observable
final class VaultModel {
    enum Scope: Hashable {
        case all
        case facet(Facet)
        case questions
        case trash
    }

    private(set) var rows: [BrowseRow] = []
    private(set) var questions: [QuestionSummary] = []
    private(set) var serviceError: String?
    var scope: Scope = .all { didSet { refresh() } }
    var query: String = "" { didSet { refresh() } }

    private var vault: VaultStore?
    private let service: ServiceSocketClient
    private let home: URL

    init() {
        home = ProcessInfo.processInfo.environment["FIRMAMENT_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Firmament")
        service = ServiceSocketClient(path: ServicePaths.socketPath(home: home))
        refresh()
    }

    func startPolling() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self.refresh()
            }
        }
    }

    // MARK: - Reads

    func refresh() {
        do {
            if vault == nil {
                vault = try VaultStore(directoryURL: home, readOnly: true)
            }
            guard let vault else { return }
            let browseScope: BrowseScope = switch scope {
            case .all, .questions: .all
            case .facet(let facet): .facet(facet)
            case .trash: .trash
            }
            rows = try vault.browse(
                scope: browseScope, matching: query.isEmpty ? nil : query)
            questions = try vault.openQuestions()
            if case .questions = scope {
                let entryIDs = Set(questions.map(\.entryID))
                rows = rows.filter { entryIDs.contains($0.id) }
            }
        } catch {
            rows = []
            questions = []
            serviceError = "Vault unavailable — is firmament-service running? (\(error))"
        }
    }

    func detail(for id: String) -> EntryDetail? {
        guard let vault else { return nil }
        return try? vault.entryDetail(id: id)
    }

    // MARK: - Writes (all through the service)

    func capture(text: String, localOnly: Bool) {
        callService("capture_note", ["text": text, "localOnly": localOnly])
    }

    func trash(id: String) { callService("trash_entry", ["entryID": id]) }
    func untrash(id: String) { callService("untrash_entry", ["entryID": id]) }
    func deleteNow(id: String) { callService("purge_entry", ["entryID": id]) }

    func answer(questionID: String, text: String) {
        callService("answer_question", ["questionID": questionID, "answer": text])
    }

    func dismiss(questionID: String) {
        callService("dismiss_question", ["questionID": questionID])
    }

    private func callService(_ method: String, _ params: [String: Any]) {
        do {
            _ = try service.call(method: method, params: params)
            serviceError = nil
        } catch let error as ServiceClientError {
            serviceError = error.message
        } catch {
            serviceError = "\(error)"
        }
        refresh()
    }
}
