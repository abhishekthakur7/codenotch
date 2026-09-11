import Foundation
import SystemConfiguration

enum PhoneLinkNetwork {
    static func getHosts() -> [String] {
        var hosts: [String] = []
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        
        var defaultInterface: String?
        // To find default route interface, we could parse routing table, but a simple heuristic
        // on macOS is en0 is usually primary WiFi/Ethernet.
        // Or we can just prioritize en0, then en*.
        var en0IP: String?
        var otherEnIPs: [String] = []
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee else { continue }
            
            let addrFamily = interface.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) else { continue }
            
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, 0, NI_NUMERICHOST)
            
            let ip = String(cString: hostname)
            if isPrivateIPv4(ip) {
                if name == "en0" {
                    en0IP = ip
                } else {
                    otherEnIPs.append(ip)
                }
            }
        }
        
        if let en0 = en0IP { hosts.append(en0) }
        hosts.append(contentsOf: otherEnIPs)
        
        if let localHostName = SCDynamicStoreCopyLocalHostName(nil) as String? {
            hosts.append("\(localHostName).local")
        }
        
        return Array(hosts.prefix(4))
    }
    
    static func getComputerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            return name
        }
        return Host.current().localizedName ?? "Mac"
    }
    
    static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        
        if parts[0] == 10 { return true }
        if parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true } // link-local
        return false
    }
    
    static func isPrivateIP(_ ip: String) -> Bool {
        if isPrivateIPv4(ip) { return true }
        if ip == "127.0.0.1" || ip == "::1" { return true }
        
        // IPv6 ULA (fc00::/7) or link-local (fe80::/10)
        let lower = ip.lowercased()
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") {
            return true
        }
        return false
    }
}
