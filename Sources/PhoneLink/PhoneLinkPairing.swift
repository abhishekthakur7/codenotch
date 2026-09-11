import Foundation
import Combine
import Security

@MainActor
final class PhoneLinkPairing: ObservableObject {
    @Published private(set) var currentCode: String = ""
    @Published private(set) var expiresAt: Date = Date()
    private(set) var retiredCodes: [String: Date] = [:]

    
    private var timer: Timer?

    init() {
        rotateCode()
    }
    
    func rotateCode() {
        if !currentCode.isEmpty {
            retiredCodes[currentCode] = Date()
        }
        cleanRetiredCodes()
        
        var bytes = [UInt8](repeating: 0, count: 16)
        let _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        currentCode = bytes.map { String(format: "%02x", $0) }.joined()
        expiresAt = Date().addingTimeInterval(300) // 5 minutes
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rotateCode()
            }
        }
    }
    
    func checkCode(_ code: String) -> CodeStatus {
        if code == currentCode {
            if Date() < expiresAt {
                return .valid
            }
        }
        
        cleanRetiredCodes()
        if retiredCodes.keys.contains(code) {
            return .expired
        }
        return .invalid
    }
    
    private func cleanRetiredCodes() {
        let now = Date()
        // 10 minutes limit according to protocol
        retiredCodes = retiredCodes.filter { now.timeIntervalSince($0.value) < 600 }
        
        // At most 8 codes
        if retiredCodes.count > 8 {
            let sorted = retiredCodes.sorted { $0.value > $1.value }
            retiredCodes = Dictionary(uniqueKeysWithValues: sorted.prefix(8).map { ($0.key, $0.value) })
        }
    }
    
    @Published var lastPaired: PairedDevice?
    
    func consume(matching: (String) -> Bool) -> String? {
        if Date() < expiresAt && matching(currentCode) {
            let matched = currentCode
            rotateCode()
            return matched
        }
        return nil
    }
}

enum CodeStatus {
    case valid
    case expired
    case invalid
}
