import AppKit
import Combine
import Foundation

/// The small, stable part of a Codex rollout that is useful for activity.
///
/// `item_completed` is intentionally ignored: commands and other child items
/// emit it too. A turn is complete only after Codex writes `task_complete`.
struct CodexRolloutActivity {
    enum State: Equatable {
        case busy
        case success
    }

    static func state(from url: URL) -> State? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var state: State?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData),
                  let record = object as? [String: Any],
                  record["type"] as? String == "event_msg",
                  let payload = record["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }

            switch type {
            case "task_started":
                state = .busy
            case "task_complete":
                state = .success
            case "turn_aborted":
                // An aborted turn is not a successful completion. Returning
                // nil lets the activity monitor drop it without announcing.
                state = nil
            default:
                continue
            }
        }
        return state
    }
}

/// Reports whether Codex is mid-turn.
///
/// Codex does not publish a live status field, but its rollout includes
/// lifecycle events. `task_started` and `task_complete` are used when present;
/// the file's recent modification time remains the activity fallback.
///
/// **That is a heuristic, and it is labelled as one.** It cannot tell a turn
/// that is thinking from one that finished a second ago, so it errs short: the
/// ring stops spinning `staleAfter` seconds after the last write rather than
/// claiming activity it cannot see. A stale rollout is deliberately not
/// converted into `.success` or `.idle`, because inactivity is not evidence
/// that a Codex turn completed — a long-running command can be quiet too.
/// If Codex grows a real status field this should be replaced by it.
@MainActor
final class CodexActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let stateStore: URL
    private let desktopStore: URL
    private let profile: CodexProfile
    private let interval: TimeInterval
    /// How long after the last write a turn is still considered in flight.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(
        profile: CodexProfile = .default(),
        stateStore: URL? = nil,
        desktopStore: URL? = nil,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 8
    ) {
        self.profile = profile
        self.stateStore = stateStore ?? profile.stateURL
        self.desktopStore = desktopStore ?? profile.desktopStoreURL
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        rescan()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func rescan() {
        let found = Self.read(stateStore: stateStore, desktopStore: desktopStore,
                              staleAfter: staleAfter, profile: profile)
        guard found != sessions else { return }
        sessions = found
    }

    static func read(stateStore: URL, desktopStore: URL,
                     staleAfter: TimeInterval, now: Date = Date(),
                     profile: CodexProfile = .default()) -> [AgentSession] {
        // Both surfaces, because "Codex" is two programs that record their work
        // in different places: the CLI and the VS Code extension append to a
        // rollout, and the desktop app writes to its own catalogue. Whichever
        // moved last is the one that is working.
        var candidates: [(id: String, name: String, at: Date, state: AgentSession.State)] = []

        if let rollout = CodexStore.newestRollout(in: stateStore),
           let modified = (try? FileManager.default
               .attributesOfItem(atPath: rollout.path))?[.modificationDate] as? Date {
            let state: AgentSession.State
            switch CodexRolloutActivity.state(from: rollout) {
            case .success: state = .success
            case .busy, .none: state = .busy
            }
            candidates.append((id: "\(profile.id).\(rollout.lastPathComponent)",
                               name: profile.displayName, at: modified, state: state))
        }
        if let desktop = CodexStore.newestDesktopThread(in: desktopStore) {
            candidates.append((id: "\(profile.id).desktop", name: desktop.title,
                               at: desktop.updatedAt, state: .busy))
        }

        guard let newest = candidates.max(by: { $0.at < $1.at }),
              let session = session(id: newest.id, name: newest.name,
                                    modified: newest.at, state: newest.state,
                                    staleAfter: staleAfter, now: now)
        else { return [] }
        return [session]
    }

    /// Only work recorded within the window counts. Anything older is a
    /// finished turn, and reporting it as work in progress would be a guess
    /// dressed as a fact.
    static func session(
        id: String, name: String, modified: Date,
        state: AgentSession.State = .busy,
        staleAfter: TimeInterval, now: Date
    ) -> AgentSession? {
        guard now.timeIntervalSince(modified) <= staleAfter else { return nil }

        return AgentSession(
            id: id,
            name: name,
            detail: state == .success ? L10n.t("Complete") : L10n.t("Working"),
            state: state,
            waitingFor: nil,
            since: modified
        )
    }
}
