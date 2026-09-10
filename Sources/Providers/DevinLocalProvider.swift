import Foundation
import SQLite3

/// Reads Devin usage using the session owned by Devin Desktop.
///
/// Devin Desktop (formerly Windsurf) keeps its authentication in
/// `~/Library/Application Support/Devin/User/globalStorage/state.vscdb`. The
/// cached quota in that database can lag behind the account, so each refresh
/// asks GetUserStatus instead. The session is read-only: Devin Desktop owns
/// sign-in and token rotation; Codenotch never refreshes or writes its token.
actor DevinLocalProvider: UsageProvider {
    nonisolated let id = "devin"
    nonisolated let displayName = "Devin"
    nonisolated let glyph = ProviderGlyph.devin

    static let storeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")

    nonisolated private let database: URL
    private let session: URLSession
    private var retryNoEarlierThan: Date?

    init(database: URL = DevinLocalProvider.storeURL,
         session: URLSession = URLSession(configuration: .ephemeral,
                                          delegate: DevinRedirectPolicy(), delegateQueue: nil)) {
        self.database = database
        self.session = session
    }

    nonisolated var isVisibleWhenAbsent: Bool {
        FileManager.default.fileExists(atPath: database.path)
    }

    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: "com.exafunction.windsurf", name: "Devin")
    }

    nonisolated func account() -> ProviderAccount? {
        guard let auth = try? Self.readAuth(from: database) else { return nil }
        return ProviderAccount(label: auth.email, plan: nil, source: "Devin Desktop",
                               manageURL: URL(string: "https://app.devin.ai"))
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            throw UsageProviderError.rateLimited(retryAfter: retryNoEarlierThan.timeIntervalSinceNow)
        }
        let auth = try Self.readAuth(from: database)
        var request = URLRequest(
            url: URL(string: "https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus")!,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": ["apiKey": auth.apiKey, "ideName": "windsurf", "ideVersion": "1.108.2",
                         "extensionName": "windsurf", "extensionVersion": "1.108.2", "locale": "en"]
        ])
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 { throw UsageProviderError.needsAuth }
        if status == 403 { throw UsageProviderError.accessDenied }
        if status == 429 {
            let hint = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
            let delay = hint.isFinite ? max(60, hint) : 60
            retryNoEarlierThan = Date().addingTimeInterval(delay)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        guard (200..<300).contains(status) else { throw UsageProviderError.badResponse(status: status) }
        let windows = try DevinUsage.windows(fromJSON: String(decoding: data, as: UTF8.self))
        retryNoEarlierThan = nil
        return ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: .ok, windows: windows,
            headlineID: windows.first?.id, weeklyID: "weekly"
        )
    }

    struct Auth: Decodable {
        let apiKey: String
        let email: String?
    }

    private static nonisolated func readAuth(from url: URL) throws -> Auth {
        // Read only the owning app's session, never the per-account quota cache.
        guard let db = SQLiteStore.open(url) else { throw UsageProviderError.needsAuth }
        defer { sqlite3_close(db) }
        guard let json = SQLiteStore.rows(
            in: db, sql: "SELECT value FROM ItemTable WHERE key = ?", bind: "windsurfAuthStatus"
        ).first else { throw UsageProviderError.needsAuth }

        // Re-read on every refresh so a Desktop sign-in or rotation takes effect.
        guard let auth = try? JSONDecoder().decode(Auth.self, from: Data(json.utf8)),
              !auth.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw UsageProviderError.needsAuth }
        return auth
    }
}

final class DevinRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
