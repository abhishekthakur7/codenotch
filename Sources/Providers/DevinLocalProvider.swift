import Foundation
import SQLite3

/// Reads Devin usage using the session owned by Devin Desktop or Devin CLI.
///
/// Devin Desktop (formerly Windsurf) keeps its authentication in
/// `~/Library/Application Support/Devin/User/globalStorage/state.vscdb`. Devin
/// CLI keeps its credentials in `~/.local/share/devin/credentials.toml`. Both
/// hold the same kind of session token, and both are read by the same
/// GetUserStatus call. The Desktop database is tried first; the CLI file is the
/// fallback so the notch works on a machine that has only the CLI installed.
/// The session is read-only: whichever tool owns sign-in and token rotation,
/// Codenotch never refreshes or writes its token.
actor DevinLocalProvider: UsageProvider {
    nonisolated let id = "devin"
    nonisolated let displayName = "Devin"
    nonisolated let glyph = ProviderGlyph.devin

    static let storeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")

    static let cliCredentialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/devin/credentials.toml")

    nonisolated private let database: URL
    nonisolated private let cliCredentials: URL
    private let session: URLSession
    private var retryNoEarlierThan: Date?

    init(database: URL = DevinLocalProvider.storeURL,
         cliCredentials: URL = DevinLocalProvider.cliCredentialsURL,
         session: URLSession = URLSession(configuration: .ephemeral,
                                          delegate: DevinRedirectPolicy(), delegateQueue: nil)) {
        self.database = database
        self.cliCredentials = cliCredentials
        self.session = session
    }

    /// True when either the Desktop database or the CLI credentials file exists.
    nonisolated var isVisibleWhenAbsent: Bool {
        FileManager.default.fileExists(atPath: database.path)
            || FileManager.default.fileExists(atPath: cliCredentials.path)
    }

    nonisolated var signInRoute: SignInRoute {
        if FileManager.default.fileExists(atPath: database.path) {
            return .openApp(bundleID: "com.exafunction.windsurf", name: "Devin")
        }
        return .guidance(L10n.t("Run `devin auth login` in a terminal to sign in."))
    }

    nonisolated func account() -> ProviderAccount? {
        guard let auth = try? Self.readAuth(database: database, fallbackCLI: cliCredentials) else { return nil }
        let source = FileManager.default.fileExists(atPath: database.path) ? "Devin Desktop" : "Devin CLI"
        return ProviderAccount(label: auth.email, plan: nil, source: source,
                               manageURL: URL(string: "https://app.devin.ai"))
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            throw UsageProviderError.rateLimited(retryAfter: retryNoEarlierThan.timeIntervalSinceNow)
        }
        let auth = try Self.readAuth(database: database, fallbackCLI: cliCredentials)
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

    private static nonisolated func readAuth(database: URL, fallbackCLI cli: URL) throws -> Auth {
        // Try the Desktop database first, then fall back to the CLI credentials
        // file. Re-read on every refresh so a sign-in or rotation takes effect.
        if let db = SQLiteStore.open(database) {
            defer { sqlite3_close(db) }
            if let json = SQLiteStore.rows(
                in: db, sql: "SELECT value FROM ItemTable WHERE key = ?", bind: "windsurfAuthStatus"
            ).first {
                if let auth = try? JSONDecoder().decode(Auth.self, from: Data(json.utf8)),
                   !auth.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return auth
                }
            }
        }
        return try readAuthFromCLI(cli)
    }

    /// Reads the CLI's `credentials.toml`. The file is simple enough that a TOML
    /// parser is not warranted — only `windsurf_api_key` is needed.
    private static nonisolated func readAuthFromCLI(_ url: URL) throws -> Auth {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw UsageProviderError.needsAuth
        }
        guard let line = content.split(separator: "\n").first(where: { $0.hasPrefix("windsurf_api_key") }),
              let value = line.split(separator: "\"").dropFirst().first
        else { throw UsageProviderError.needsAuth }
        let apiKey = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw UsageProviderError.needsAuth }
        return Auth(apiKey: apiKey, email: nil)
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
