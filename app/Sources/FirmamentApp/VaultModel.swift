import FirmamentCore
import Foundation
import Observation

/// Read model for the app: browses the vault via a read-only WAL connection
/// (safe alongside the service's writer) and routes every mutation through
/// the service socket. Polls, but gates rebuilds on SQLite's data_version so
/// idle ticks do no work.
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
    private(set) var selectedDetail: EntryDetail?
    private(set) var serviceError: String?
    var scope: Scope = .all { didSet { refresh(force: true) } }
    var query: String = "" { didSet { refresh(force: true) } }
    var selection: String? { didSet { reloadDetail() } }

    private var vault: VaultStore?
    private var lastDataVersion: Int = -1
    private let service: ServiceSocketClient
    private let home: URL

    init() {
        home = ProcessInfo.processInfo.environment["FIRMAMENT_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Firmament")
        service = ServiceSocketClient(path: ServicePaths.socketPath(home: home))
        refresh(force: true)
    }

    func startPolling() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self.refresh(force: false)
            }
        }
    }

    // MARK: - Reads

    func refresh(force: Bool) {
        do {
            if vault == nil {
                vault = try VaultStore(directoryURL: home, readOnly: true)
            }
            guard let vault else { return }

            let version = try vault.dataVersion()
            if !force && version == lastDataVersion { return }
            lastDataVersion = version

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
            reloadDetail()
        } catch {
            rows = []
            questions = []
            serviceError = "Vault unavailable — is firmament-service running? (\(error))"
        }
    }

    private func reloadDetail() {
        guard let vault, let selection else {
            selectedDetail = nil
            return
        }
        selectedDetail = try? vault.entryDetail(id: selection)
    }

    // MARK: - Writes (all through the service, off the main actor)

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

    private func callService(_ method: String, _ params: [String: any Sendable]) {
        let service = self.service
        Task { [weak self] in
            // Socket I/O stays off the main actor; only the outcome returns.
            let outcome: String? = await Task.detached { () -> String? in
                do {
                    _ = try service.call(method: method, params: params as [String: Any])
                    return nil
                } catch let error as ServiceClientError {
                    return error.message
                } catch {
                    return "\(error)"
                }
            }.value
            guard let self else { return }
            self.serviceError = outcome
            self.refresh(force: true)
        }
    }
}
