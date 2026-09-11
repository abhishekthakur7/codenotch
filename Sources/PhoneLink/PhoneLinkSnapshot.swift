import Foundation

struct PhoneLinkSnapshot: Encodable {
    struct ServerInfo: Encodable {
        let name: String
        let version: String
        let generatedAt: String
        let demo: Bool
    }
    
    struct Provider: Encodable {
        let id: String
        let displayName: String
        let fidelity: String
        let status: Status
        let windows: [Window]
        let headlineId: String?
        let block: Block?
        let account: Account?
    }
    
    struct Status: Encodable {
        let kind: String
        let since: String?
        let why: String?
    }
    
    struct Window: Encodable {
        let id: String
        let label: String
        let usedFraction: Double?
        let remaining: Int?
        let used: Int?
        let resetsAt: String?
    }
    
    struct Block: Encodable {
        let reason: String
        let resetsAt: String?
    }
    
    struct Account: Encodable {
        let plan: String
        let source: String
    }
    
    struct Session: Encodable {
        let id: String
        let name: String
        let detail: String
        let state: String
        let waitingFor: String?
        let since: String?
    }
    
    let server: ServerInfo
    let providers: [Provider]
    let sessions: [Session]
}
