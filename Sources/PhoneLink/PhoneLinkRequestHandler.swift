import Foundation
import NIOCore
import NIOHTTP1
import CryptoKit

// Using a dictionary to track nonces per IP for rate limiting/replay protection.
actor SecurityStore {
    // ip -> [nonce: expiry]
    private var nonces: [String: [String: Date]] = [:]
    // ip -> [time]
    private var pairRequests: [String: [Date]] = [:]
    // ip -> [time]
    private var apiRequests: [String: [Date]] = [:]
    
    func checkAndStoreNonce(ip: String, nonce: String, timestamp: Int) -> Bool {
        cleanup()
        var ipNonces = nonces[ip] ?? [:]
        if ipNonces[nonce] != nil { return false }
        ipNonces[nonce] = Date(timeIntervalSince1970: TimeInterval(timestamp)).addingTimeInterval(300)
        nonces[ip] = ipNonces
        return true
    }
    
    func checkPairRateLimit(ip: String) -> Bool {
        cleanup()
        var reqs = pairRequests[ip] ?? []
        reqs.append(Date())
        pairRequests[ip] = reqs
        return reqs.count <= 10
    }
    
    func checkAPIRateLimit(ip: String) -> Bool {
        cleanup()
        var reqs = apiRequests[ip] ?? []
        reqs.append(Date())
        apiRequests[ip] = reqs
        return reqs.count <= 120
    }
    
    private func cleanup() {
        let now = Date()
        for ip in nonces.keys {
            nonces[ip] = nonces[ip]?.filter { $0.value > now }
            if nonces[ip]?.isEmpty == true { nonces.removeValue(forKey: ip) }
        }
        for ip in pairRequests.keys {
            pairRequests[ip] = pairRequests[ip]?.filter { now.timeIntervalSince($0) < 60 }
            if pairRequests[ip]?.isEmpty == true { pairRequests.removeValue(forKey: ip) }
        }
        for ip in apiRequests.keys {
            apiRequests[ip] = apiRequests[ip]?.filter { now.timeIntervalSince($0) < 60 }
            if apiRequests[ip]?.isEmpty == true { apiRequests.removeValue(forKey: ip) }
        }
    }
}

let sharedSecurityStore = SecurityStore()

final class PhoneLinkRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    
    private let pairing: PhoneLinkPairing
    private let registry: PhoneLinkRegistry
    private let getSnapshot: @Sendable () async -> Data?
    private let refreshAndGetSnapshot: @Sendable () async -> Data?
    
    private var head: HTTPRequestHead?
    private var body = Data()
    
    init(pairing: PhoneLinkPairing, registry: PhoneLinkRegistry, getSnapshot: @escaping @Sendable () async -> Data?, refreshAndGetSnapshot: @escaping @Sendable () async -> Data?) {
        self.pairing = pairing
        self.registry = registry
        self.getSnapshot = getSnapshot
        self.refreshAndGetSnapshot = refreshAndGetSnapshot
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)
        switch reqPart {
        case .head(let request):
            self.head = request
        case .body(var buffer):
            guard body.count + buffer.readableBytes <= 64 * 1024 else {
                fail(context.channel, status: .payloadTooLarge)
                return
            }
            let bytes = buffer.readBytes(length: buffer.readableBytes)!
            body.append(contentsOf: bytes)

        case .end:
            let requestHead = self.head!
            handleRequest(channel: context.channel, head: requestHead, bodyData: body)
            self.head = nil
            self.body = Data()
        }
    }
    
    private func fail(_ channel: Channel, status: HTTPResponseStatus, jsonBody: Data? = nil) {
        channel.eventLoop.execute {
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: HTTPHeaders([("content-type", "application/json"), ("connection", "close")]))
            channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            if let json = jsonBody {
                var buffer = channel.allocator.buffer(capacity: json.count)
                buffer.writeBytes(json)
                channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            }
            channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }
    
    private func respond(_ channel: Channel, status: HTTPResponseStatus = .ok, jsonBody: Data) {
        channel.eventLoop.execute {
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: HTTPHeaders([("content-type", "application/json"), ("connection", "close")]))
            channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            var buffer = channel.allocator.buffer(capacity: jsonBody.count)
            buffer.writeBytes(jsonBody)
            channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }
    
    private func extractIP(_ address: SocketAddress?) -> String? {
        guard let addr = address else { return nil }
        switch addr {
        case .v4(let v4):
            return v4.host
        case .v6(let v6):
            return v6.host
        case .unixDomainSocket:
            return nil
        }
    }
    
    private func handleRequest(channel: Channel, head: HTTPRequestHead, bodyData: Data) {
        guard let ip = extractIP(channel.remoteAddress) else {
            fail(channel, status: .forbidden)
            return
        }
        
        if !PhoneLinkNetwork.isPrivateIP(ip) {
            fail(channel, status: .forbidden, jsonBody: Data("{\"error\":\"local-network-only\"}".utf8))
            return
        }
        
        let path = head.uri.components(separatedBy: "?").first ?? "/"
        
        if head.method == .GET && path == "/health" {
            let info = Bundle.main.infoDictionary
            let version = (info?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
            let json = "{\"ok\":true,\"app\":\"codenotch\",\"api\":2,\"version\":\"\(version)\"}".data(using: .utf8)!
            respond(channel, jsonBody: json)
            return
        }
        
        // Auth common checks
        guard let tsString = head.headers["x-cn-timestamp"].first,
              let ts = Int(tsString),
              let nonce = head.headers["x-cn-nonce"].first,
              let signatureHeader = head.headers["x-cn-signature"].first else {
            fail(channel, status: .unauthorized)
            return
        }
        
        let now = Int(Date().timeIntervalSince1970)
        if abs(now - ts) > 120 {
            fail(channel, status: .unauthorized, jsonBody: Data("{\"error\":\"clock-skew\",\"serverTime\":\(now)}".utf8))
            return
        }
        
        Task {
            let isNonceFresh = await sharedSecurityStore.checkAndStoreNonce(ip: ip, nonce: nonce, timestamp: ts)
            if !isNonceFresh {
                self.fail(channel, status: .unauthorized, jsonBody: Data("{\"error\":\"replayed-nonce\"}".utf8))
                return
            }
            
            if path == "/api/v2/pair" && head.method == .POST {
                let allowed = await sharedSecurityStore.checkPairRateLimit(ip: ip)
                if !allowed {
                    self.fail(channel, status: .tooManyRequests, jsonBody: Data("{\"error\":\"rate-limited\"}".utf8))
                    return
                }
                await self.handlePair(channel: channel, head: head, bodyData: bodyData, ts: tsString, nonce: nonce, signatureHeader: signatureHeader, ip: ip)
            } else if path.hasPrefix("/api/v1/") {
                let allowed = await sharedSecurityStore.checkAPIRateLimit(ip: ip)
                if !allowed {
                    self.fail(channel, status: .tooManyRequests, jsonBody: Data("{\"error\":\"rate-limited\"}".utf8))
                    return
                }
                guard let deviceId = head.headers["x-cn-device"].first else {
                    self.fail(channel, status: .unauthorized, jsonBody: Data("{\"error\":\"unknown-device\"}".utf8))
                    return
                }
                guard let device = self.registry.getDevice(id: deviceId) else {
                    self.fail(channel, status: .unauthorized, jsonBody: Data("{\"error\":\"unknown-device\"}".utf8))
                    return
                }
                
                let bodyHash = SHA256.hash(data: bodyData)
                let bodyHashHex = bodyHash.compactMap { String(format: "%02x", $0) }.joined()
                let payload = "\(tsString).\(nonce).\(head.method.rawValue).\(head.uri).\(bodyHashHex)"
                
                let symKey = SymmetricKey(data: Data(device.secret.utf8))
                let expectedSig = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: symKey)
                let expectedSigHex = expectedSig.compactMap { String(format: "%02x", $0) }.joined()
                
                if !constantTimeCompare(signatureHeader, expectedSigHex) {
                    self.fail(channel, status: .unauthorized, jsonBody: Data("{\"error\":\"bad-signature\"}".utf8))
                    return
                }
                
                var updatedDevice = device
                updatedDevice.lastSeenAt = Date()
                updatedDevice.lastSeenIP = ip
                self.registry.addOrUpdate(device: updatedDevice, immediate: false)
                
                if head.method == .GET && path == "/api/v1/snapshot" {
                    if let snap = await self.getSnapshot() {
                        self.respond(channel, jsonBody: snap)
                    } else {
                        self.fail(channel, status: .internalServerError)
                    }
                } else if head.method == .POST && path == "/api/v1/refresh" {
                    if let snap = await self.refreshAndGetSnapshot() {
                        self.respond(channel, jsonBody: snap)
                    } else {
                        self.fail(channel, status: .internalServerError)
                    }
                } else {
                    self.fail(channel, status: .notFound)
                }
            } else {
                self.fail(channel, status: .notFound)
            }
        }
    }
    
    private func constantTimeCompare(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var result: UInt8 = 0
        for i in 0..<aBytes.count {
            result |= aBytes[i] ^ bBytes[i]
        }
        return result == 0
    }
    
    private func handlePair(channel: Channel, head: HTTPRequestHead, bodyData: Data, ts: String, nonce: String, signatureHeader: String, ip: String) async {
        struct PairReq: Decodable { let deviceId: String; let name: String; let platform: String }
        guard let req = try? JSONDecoder().decode(PairReq.self, from: bodyData) else {
            fail(channel, status: .badRequest)
            return
        }
        
        let bodyHash = SHA256.hash(data: bodyData)
        let bodyHashHex = bodyHash.compactMap { String(format: "%02x", $0) }.joined()
        let payload = "\(ts).\(nonce).\(head.method.rawValue).\(head.uri).\(bodyHashHex)"
        
        func calcSig(_ codeString: String) -> String {
            let key = SymmetricKey(data: Data(codeString.utf8))
            return HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
                .compactMap { String(format: "%02x", $0) }.joined()
        }
        
        let consumedCode = await pairing.consume(matching: { expected in
            constantTimeCompare(signatureHeader, calcSig(expected))
        })
        
        if let validCode = consumedCode {
            let key = SymmetricKey(data: Data(validCode.utf8))
            let devSecretBytes = HMAC<SHA256>.authenticationCode(for: Data("codenotch-device-v2:\(req.deviceId)".utf8), using: key)
            let devSecret = devSecretBytes.compactMap { String(format: "%02x", $0) }.joined()
            
            let device = PairedDevice(
                deviceId: req.deviceId,
                name: req.name,
                platform: req.platform,
                pairedAt: Date(),
                lastSeenAt: Date(),
                lastSeenIP: ip,
                secret: devSecret
            )
            
            self.registry.addOrUpdate(device: device)
            
            await MainActor.run {
                self.pairing.lastPaired = device
            }
            
            let respObj: [String: Any] = [
                "ok": true,
                "serverName": Host.current().localizedName ?? "Mac",
                "secret": devSecret,
                "api": 2
            ]
            let respData = try! JSONSerialization.data(withJSONObject: respObj)
            self.respond(channel, jsonBody: respData)
            return
        }
        
        let retired = await pairing.retiredCodes
        for (code, _) in retired {
            if constantTimeCompare(signatureHeader, calcSig(code)) {
                fail(channel, status: .unauthorized, jsonBody: Data("{\"error\":\"code-expired\"}".utf8))
                return
            }
        }
        
        fail(channel, status: .unauthorized, jsonBody: Data("{\"error\":\"bad-code\"}".utf8))
    }
}
