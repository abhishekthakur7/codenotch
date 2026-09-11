import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import CryptoKit

enum PhoneLinkServerState: Equatable {
    case off
    case starting
    case ready(port: Int)
    case failed(String)
}

@MainActor
final class PhoneLinkServerStatus: ObservableObject {
    @Published var state: PhoneLinkServerState = .off
}

final class PhoneLinkServer: @unchecked Sendable {
    private var group: MultiThreadedEventLoopGroup?
    private var listener: Channel?
    private var stopped = false
    
    let pairing: PhoneLinkPairing
    let registry: PhoneLinkRegistry
    let getSnapshot: @Sendable () async -> Data?
    let refreshAndGetSnapshot: @Sendable () async -> Data?
    
    init(pairing: PhoneLinkPairing, registry: PhoneLinkRegistry, getSnapshot: @escaping @Sendable () async -> Data?, refreshAndGetSnapshot: @escaping @Sendable () async -> Data?) {
        self.pairing = pairing
        self.registry = registry
        self.getSnapshot = getSnapshot
        self.refreshAndGetSnapshot = refreshAndGetSnapshot
    }
    
    func start(port: Int = 8788) async throws -> Int {
        var boundPort: Int?
        var lastError: Error?
        
        if group == nil {
            group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        guard let group = group else { throw NSError(domain: "PhoneLinkServer", code: -1, userInfo: nil) }
        
        let ports = port == 0 ? [0] : [port] + Array(8789...8798)
        
        let pairing = self.pairing
        let registry = self.registry
        let getSnapshot = self.getSnapshot
        let refreshAndGetSnapshot = self.refreshAndGetSnapshot
        
        for p in ports {
            do {
                let channel = try await ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { @Sendable channel in
                        channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                            .flatMap { @Sendable () -> EventLoopFuture<Void> in
                                channel.pipeline.addHandler(PhoneLinkRequestHandler(
                                    pairing: pairing,
                                    registry: registry,
                                    getSnapshot: getSnapshot,
                                    refreshAndGetSnapshot: refreshAndGetSnapshot
                                ))
                            }
                    }
                    .bind(host: "0.0.0.0", port: p).get()
                
                listener = channel
                boundPort = channel.localAddress?.port
                break
            } catch {
                lastError = error
            }
        }
        
        if let p = boundPort {
            return p
        }
        throw lastError ?? NSError(domain: "PhoneLinkServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Couldn't listen on ports 8788–8798"])
    }
    
    func stop() async {
        if let channel = listener {
            try? await channel.close().get()
            listener = nil
        }
        if let g = group {
            try? await g.shutdownGracefully()
            group = nil
        }
    }
}
