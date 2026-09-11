import XCTest
import CryptoKit
@testable import Codenotch

final class PhoneLinkTests: XCTestCase {
    func testVectors() throws {
        let code = "00112233445566778899aabbccddeeff"
        let deviceId = "0123456789abcdef0123456789abcdef"
        
        let pairBody = "{\"deviceId\":\"0123456789abcdef0123456789abcdef\",\"name\":\"Test Phone\",\"platform\":\"ios\"}"
        let bodyHash = SHA256.hash(data: pairBody.data(using: .utf8)!).compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(bodyHash, "c10cd76b19c15b55848593dd55b34a478fa9114253db57fa5ed013f44c445423")
        
        let ts = "1757600000"
        let nonce = "n-test"
        let payload = "\(ts).\(nonce).POST./api/v2/pair.\(bodyHash)"
        
        let symmetricKey = SymmetricKey(data: Data(code.utf8))
        let sig = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: symmetricKey).compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sig, "e3e36469c8001024f222c9c1042b575e5653361dbc38de2227de717975031e6c")
        
        let derivPayload = "codenotch-device-v2:\(deviceId)"
        let devSecret = HMAC<SHA256>.authenticationCode(for: Data(derivPayload.utf8), using: symmetricKey).compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(devSecret, "d56d1f0bfbfff57f6042d9e196373fa64e9c57dd7005a3496ce2046be6c8daf8")
        
        let nonce2 = "n-test2"
        let emptyBodyHash = SHA256.hash(data: Data()).compactMap { String(format: "%02x", $0) }.joined()
        let payload2 = "\(ts).\(nonce2).GET./api/v1/snapshot.\(emptyBodyHash)"
        let symKey2 = SymmetricKey(data: Data(devSecret.utf8))
        let sig2 = HMAC<SHA256>.authenticationCode(for: Data(payload2.utf8), using: symKey2).compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sig2, "eabdc2cf6ddb995110487fea5b42585f2e137bd80260406dffabb476df0c8c3d")
        
        let name = "Sam's MacBook Pro"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed)!
        let link = "codenotch://pair?v=2&h=192.168.1.20,Mac.local&p=8788&c=\(code)&n=\(encodedName)"
        XCTAssertEqual(link, "codenotch://pair?v=2&h=192.168.1.20,Mac.local&p=8788&c=00112233445566778899aabbccddeeff&n=Sam%27s%20MacBook%20Pro")
    }

    @MainActor
    func testIntegration() async throws {
        let registry = PhoneLinkRegistry()
        let pairing = PhoneLinkPairing()
        
        let server = PhoneLinkServer(
            pairing: pairing, registry: registry,
            getSnapshot: {
                let snap = PhoneLinkSnapshotBuilder.build(
                    snapshots: [],
                    sessions: [],
                    disconnected: [],
                    order: [],
                    serverName: "Mac",
                    serverVersion: "1.0",
                    now: Date()
                )
                return try? JSONEncoder().encode(snap)
            },
            refreshAndGetSnapshot: {
                let snap = PhoneLinkSnapshotBuilder.build(
                    snapshots: [],
                    sessions: [],
                    disconnected: [],
                    order: [],
                    serverName: "Mac",
                    serverVersion: "1.0",
                    now: Date()
                )
                return try? JSONEncoder().encode(snap)
            }
        )
        
        let port = try await server.start(port: 0)
        
        let deviceId = "test-device-id"
        let pairBody = "{\"deviceId\":\"\(deviceId)\",\"name\":\"Test\",\"platform\":\"ios\"}"
        
        let url = URL(string: "http://127.0.0.1:\(port)/api/v2/pair")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = pairBody.data(using: .utf8)!
        
        let code = await pairing.currentCode
        let ts = String(Int(Date().timeIntervalSince1970))
        let nonce = "integration-nonce-1"
        let payload = "\(ts).\(nonce).POST./api/v2/pair.\(SHA256.hash(data: req.httpBody!).compactMap { String(format: "%02x", $0) }.joined())"
        
        let symKey = SymmetricKey(data: Data(code.utf8))
        let sig = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: symKey).compactMap { String(format: "%02x", $0) }.joined()
        
        req.setValue(ts, forHTTPHeaderField: "X-CN-Timestamp")
        req.setValue(nonce, forHTTPHeaderField: "X-CN-Nonce")
        req.setValue(sig, forHTTPHeaderField: "X-CN-Signature")
        
        let (data, response) = try await URLSession.shared.data(for: req)
        let httpResp = response as! HTTPURLResponse
        XCTAssertEqual(httpResp.statusCode, 200, "Pairing should succeed: \(String(data: data, encoding: .utf8) ?? "")")
        
        let devSecret = HMAC<SHA256>.authenticationCode(for: Data("codenotch-device-v2:\(deviceId)".utf8), using: symKey).compactMap { String(format: "%02x", $0) }.joined()
        
        let snapUrl = URL(string: "http://127.0.0.1:\(port)/api/v1/snapshot")!
        var snapReq = URLRequest(url: snapUrl)
        snapReq.httpMethod = "GET"
        
        let ts2 = String(Int(Date().timeIntervalSince1970))
        let nonce2 = "integration-nonce-2"
        let emptyHash = SHA256.hash(data: Data()).compactMap { String(format: "%02x", $0) }.joined()
        let payload2 = "\(ts2).\(nonce2).GET./api/v1/snapshot.\(emptyHash)"
        
        let symKey2 = SymmetricKey(data: Data(devSecret.utf8))
        let sig2 = HMAC<SHA256>.authenticationCode(for: Data(payload2.utf8), using: symKey2).compactMap { String(format: "%02x", $0) }.joined()
        
        snapReq.setValue(ts2, forHTTPHeaderField: "X-CN-Timestamp")
        snapReq.setValue(nonce2, forHTTPHeaderField: "X-CN-Nonce")
        snapReq.setValue(sig2, forHTTPHeaderField: "X-CN-Signature")
        snapReq.setValue(deviceId, forHTTPHeaderField: "X-CN-Device")
        
        let (snapData, snapResponse) = try await URLSession.shared.data(for: snapReq)
        let snapHttpResp = snapResponse as! HTTPURLResponse
        XCTAssertEqual(snapHttpResp.statusCode, 200, "Snapshot should succeed")
        
        await server.stop()
        
        // test server restartability
        let port2 = try await server.start(port: 0)
        let healthUrl = URL(string: "http://127.0.0.1:\(port2)/health")!
        let (_, hResp) = try await URLSession.shared.data(from: healthUrl)
        XCTAssertEqual((hResp as! HTTPURLResponse).statusCode, 200)
        await server.stop()
    }
    
    @MainActor
    func testConcurrentPairing() async throws {
        let registry = PhoneLinkRegistry()
        let pairing = PhoneLinkPairing()
        let server = PhoneLinkServer(pairing: pairing, registry: registry, getSnapshot: { nil }, refreshAndGetSnapshot: { nil })
        let port = try await server.start(port: 0)
        
        let deviceId = "test-device-id-concurrent"
        let pairBody = "{\"deviceId\":\"\(deviceId)\",\"name\":\"Test\",\"platform\":\"ios\"}"
        
        let url = URL(string: "http://127.0.0.1:\(port)/api/v2/pair")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = pairBody.data(using: .utf8)!
        
        let code = await pairing.currentCode
        let ts = String(Int(Date().timeIntervalSince1970))
        
        let payload1 = "\(ts).nonce-c1.POST./api/v2/pair.\(SHA256.hash(data: req.httpBody!).compactMap { String(format: "%02x", $0) }.joined())"
        let sig1 = HMAC<SHA256>.authenticationCode(for: Data(payload1.utf8), using: SymmetricKey(data: Data(code.utf8))).compactMap { String(format: "%02x", $0) }.joined()
        var req1 = req
        req1.setValue(ts, forHTTPHeaderField: "X-CN-Timestamp")
        req1.setValue("nonce-c1", forHTTPHeaderField: "X-CN-Nonce")
        req1.setValue(sig1, forHTTPHeaderField: "X-CN-Signature")
        
        let payload2 = "\(ts).nonce-c2.POST./api/v2/pair.\(SHA256.hash(data: req.httpBody!).compactMap { String(format: "%02x", $0) }.joined())"
        let sig2 = HMAC<SHA256>.authenticationCode(for: Data(payload2.utf8), using: SymmetricKey(data: Data(code.utf8))).compactMap { String(format: "%02x", $0) }.joined()
        var req2 = req
        req2.setValue(ts, forHTTPHeaderField: "X-CN-Timestamp")
        req2.setValue("nonce-c2", forHTTPHeaderField: "X-CN-Nonce")
        req2.setValue(sig2, forHTTPHeaderField: "X-CN-Signature")
        
        async let res1 = URLSession.shared.data(for: req1)
        async let res2 = URLSession.shared.data(for: req2)
        
        let (d1, r1) = try await res1
        let (d2, r2) = try await res2
        
        let status1 = (r1 as! HTTPURLResponse).statusCode
        let status2 = (r2 as! HTTPURLResponse).statusCode
        
        XCTAssertTrue((status1 == 200 && status2 == 401) || (status1 == 401 && status2 == 200), "Exactly one request should succeed")
        
        if status1 == 401 {
            let json = try JSONDecoder().decode([String: String].self, from: d1)
            XCTAssertEqual(json["error"], "code-expired")
        } else {
            let json = try JSONDecoder().decode([String: String].self, from: d2)
            XCTAssertEqual(json["error"], "code-expired")
        }
        
        await server.stop()
    }
    
    func testRegistryPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let reg = PhoneLinkRegistry(directory: dir)
        let deviceA = PairedDevice(deviceId: "A", name: "A", platform: "ios", pairedAt: Date(), lastSeenAt: Date(), lastSeenIP: "127.0.0.1", secret: "secret")
        let deviceB = PairedDevice(deviceId: "B", name: "B", platform: "ios", pairedAt: Date(), lastSeenAt: Date(), lastSeenIP: "127.0.0.1", secret: "secret")
        
        reg.addOrUpdate(device: deviceA)
        reg.addOrUpdate(device: deviceB)
        reg.remove(deviceId: "B")
        
        // Let background queue finish
        let exp = expectation(description: "wait for queue")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        
        let reg2 = PhoneLinkRegistry(directory: dir)
        XCTAssertNotNil(reg2.getDevice(id: "A"))
        XCTAssertNil(reg2.getDevice(id: "B"))
    }
}
