import Foundation
import Darwin
import SystemConfiguration

/// 活跃物理网卡信息
public struct ActiveInterfaceInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let ip: String
    public let label: String

    public var displayName: String {
        ip.isEmpty ? "\(label) (\(name))" : "\(label) (\(name)) · \(ip)"
    }

    public var compactDisplayName: String {
        ip.isEmpty ? name : "\(name) · \(ip)"
    }

    /// 探测当前默认路由网关与出口网卡
    nonisolated public static func detectGatewayAndInterface() -> (gateway: String, iface: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-rn"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        if (try? task.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                var candidatePhysical: (gateway: String, iface: String)? = nil
                for line in output.components(separatedBy: .newlines) {
                    if line.hasPrefix("default") {
                        let parts = line.split(whereSeparator: { $0.isWhitespace })
                        if parts.count >= 4 {
                            let gw = String(parts[1])
                            let iface = String(parts.last ?? "")
                            if gw.contains(".") && iface.hasPrefix("en") {
                                return (gateway: gw, iface: iface)
                            }
                            if candidatePhysical == nil && gw.contains(".") && !iface.hasPrefix("utun") && !iface.hasPrefix("ppp") {
                                candidatePhysical = (gateway: gw, iface: iface)
                            }
                        }
                    }
                }
                if let cand = candidatePhysical {
                    return cand
                }
            }
        }
        return (gateway: "192.168.50.1", iface: "en0")
    }

    /// 统一探测当前真实活跃且已分配有效 IPv4 的物理网卡，并将系统默认网关出口置顶
    nonisolated public static func discoverActive() -> (interfaces: [ActiveInterfaceInfo], defaultInterface: String) {
        var bsdTypeMap: [String: String] = [:]
        if let scInterfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in scInterfaces {
                if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
                   let type = SCNetworkInterfaceGetInterfaceType(iface) as String? {
                    bsdTypeMap[bsd] = type
                }
            }
        }

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return ([], "") }
        defer { freeifaddrs(ifaddr) }

        var list: [ActiveInterfaceInfo] = []
        var seenNames = Set<String>()
        let (_, defaultIface) = detectGatewayAndInterface()

        var ptr = ifaddr
        while let current = ptr {
            let ifa = current.pointee
            let flags = Int32(ifa.ifa_flags)
            let isUpAndRunning = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 && (flags & IFF_LOOPBACK) == 0

            if isUpAndRunning, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if name.hasPrefix("en") && !name.contains("awdl") && !name.contains("llw") && !seenNames.contains(name) {
                    let sin = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee
                    var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var sinAddr = sin.sin_addr
                    inet_ntop(AF_INET, &sinAddr, &ipStr, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(decoding: ipStr.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)

                    if !ip.isEmpty && ip != "127.0.0.1" && !ip.hasPrefix("169.254.") {
                        seenNames.insert(name)
                        let scType = bsdTypeMap[name]
                        let friendlyLabel: String
                        if scType == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                            friendlyLabel = "无线局域网"
                        } else if scType == (kSCNetworkInterfaceTypeEthernet as String) {
                            friendlyLabel = "以太网"
                        } else if name == "en0" {
                            friendlyLabel = "无线局域网"
                        } else {
                            friendlyLabel = "以太网"
                        }
                        list.append(ActiveInterfaceInfo(name: name, ip: ip, label: friendlyLabel))
                    }
                }
            }
            ptr = ifa.ifa_next
        }

        list.sort { a1, a2 in
            if a1.name == defaultIface { return true }
            if a2.name == defaultIface { return false }
            return a1.name < a2.name
        }

        return (list, defaultIface)
    }
}

/// 运行环境信息（版本、CPU 架构、硬件型号与系统版本）
public enum AppEnvironmentInfo {
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    public static var architectureDescription: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        return "Intel (x86_64)"
        #else
        return "macOS Universal"
        #endif
    }

    public static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    public static var macOSVersionDescription: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
