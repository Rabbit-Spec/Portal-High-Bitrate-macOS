import Foundation
import Darwin
import SystemConfiguration

/// PlayStation 设备发现协议 (DDP UDP 9302) 返回信息
public struct PlayStationDDPInfo: Sendable {
    public let ip: String
    public let hostType: String
    public let hostName: String
    public let systemVersion: String
    public let isStandby: Bool
}

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

    /// 获取指定物理网卡的真实子网掩码与子网广播 IPv4（避免多网段下写死 .255）
    nonisolated public static func ipv4SubnetInfo(for interfaceName: String) -> (ip: UInt32, mask: UInt32, broadcast: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            let ifa = current.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               let maskAddr = ifa.ifa_netmask, maskAddr.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == interfaceName {
                let ipHost = UInt32(bigEndian: UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
                let maskHost = UInt32(bigEndian: UnsafeRawPointer(maskAddr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
                let bcastHost = (ipHost & maskHost) | ~maskHost
                var bcastNet = in_addr(s_addr: bcastHost.bigEndian)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &bcastNet, &buf, socklen_t(INET_ADDRSTRLEN))
                let bcastStr = String(decoding: buf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
                return (ip: ipHost, mask: maskHost, broadcast: bcastStr)
            }
            ptr = ifa.ifa_next
        }
        return nil
    }
}

/// 局域网无子进程 ARP 探测与 PlayStation DDP (UDP 9302) 主机/掌机识别工具
public enum PortalLanDiscovery {
    nonisolated public static func sweepSubnetFast(basePrefix: String, interfaceName: String? = nil) {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }
        defer { close(sock) }

        if let interfaceName, !interfaceName.isEmpty {
            var ifIndex = if_nametoindex(interfaceName)
            if ifIndex != 0 {
                setsockopt(sock, IPPROTO_IP, IP_BOUND_IF, &ifIndex, socklen_t(MemoryLayout<UInt32>.size))
            }
        }

        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        let dummy: [UInt8] = [0]
        for i in 1...254 {
            let ip = "\(basePrefix).\(i)"
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(5353).bigEndian
            inet_pton(AF_INET, ip, &addr.sin_addr)

            withUnsafePointer(to: &addr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, dummy, 1, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    nonisolated public static func readArpTableViaKernelSysctl() -> [(ip: String, mac: String, ifName: String, isLocal: Bool)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var len: size_t = 0
        if sysctl(&mib, 6, nil, &len, nil, 0) < 0 || len == 0 {
            return []
        }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: len)
        defer { buffer.deallocate() }

        if sysctl(&mib, 6, buffer, &len, nil, 0) < 0 {
            return []
        }

        var results: [(ip: String, mac: String, ifName: String, isLocal: Bool)] = []
        var ptr = buffer
        let end = buffer.advanced(by: len)

        while ptr < end {
            let rtm = ptr.withMemoryRebound(to: rt_msghdr.self, capacity: 1) { $0.pointee }
            let rtmLen = Int(rtm.rtm_msglen)
            guard rtmLen > 0 else { break }

            var saPtr = ptr.advanced(by: MemoryLayout<rt_msghdr>.stride)
            let rtaxDst = saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0.pointee }

            if rtaxDst.sa_family == UInt8(AF_INET) {
                let sin = saPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var ipAddr = sin.sin_addr
                var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &ipAddr, &ipStr, socklen_t(INET_ADDRSTRLEN))
                let ip = String(decoding: ipStr.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)

                let saLen = Int(rtaxDst.sa_len > 0 ? rtaxDst.sa_len : UInt8(MemoryLayout<sockaddr>.size))
                let roundedLen = (saLen + 3) & ~3
                saPtr = saPtr.advanced(by: roundedLen)

                let sdl = saPtr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
                if sdl.sdl_family == UInt8(AF_LINK) && sdl.sdl_alen == 6 {
                    let sdlData = saPtr.advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)!)
                    let macBytes = sdlData.advanced(by: Int(sdl.sdl_nlen))
                    let mac = (0..<6).map { String(format: "%02x", macBytes[$0]) }.joined(separator: ":")

                    var ifNameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if_indextoname(UInt32(sdl.sdl_index), &ifNameBuf)
                    let ifName = String(decoding: ifNameBuf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)

                    let isLocal = (rtm.rtm_flags & RTF_LOCAL) != 0
                    results.append((ip: ip, mac: mac, ifName: ifName, isLocal: isLocal))
                }
            }

            ptr = ptr.advanced(by: rtmLen)
        }
        return results
    }

    nonisolated public static func readArpTableViaCli() -> [(ip: String, mac: String, ifName: String, isLocal: Bool)] {
        var rawLines: [String] = []
        let arpTask = Process()
        arpTask.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        arpTask.arguments = ["-n", "-a"]
        let p = Pipe()
        arpTask.standardOutput = p
        arpTask.standardError = Pipe()

        if (try? arpTask.run()) != nil {
            let data = p.fileHandleForReading.readDataToEndOfFile()
            arpTask.waitUntilExit()
            if let text = String(data: data, encoding: .utf8) {
                rawLines = text.components(separatedBy: .newlines)
            }
        }

        var results: [(ip: String, mac: String, ifName: String, isLocal: Bool)] = []
        for line in rawLines {
            guard line.contains(" at ") && line.contains("(") && line.contains(")") else { continue }
            let parts = line.components(separatedBy: " at ")
            guard parts.count >= 2 else { continue }

            let left = parts[0]
            let right = parts[1]

            guard let startIdx = left.firstIndex(of: "("),
                  let endIdx = left.firstIndex(of: ")") else { continue }
            let ip = String(left[left.index(after: startIdx)..<endIdx]).trimmingCharacters(in: .whitespaces)

            let macRaw = (right.components(separatedBy: " on ").first ?? right).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !macRaw.contains("incomplete") && !macRaw.contains("ff:ff:ff:ff:ff:ff") && !macRaw.isEmpty else { continue }

            let macParts = macRaw.split(separator: ":").map { part -> String in
                part.count == 1 ? "0\(part)" : String(part)
            }
            guard macParts.count == 6 else { continue }
            let formattedMAC = macParts.joined(separator: ":")

            var ifName = ""
            if let onIdx = right.range(of: " on ") {
                let sub = right[onIdx.upperBound...]
                ifName = sub.components(separatedBy: " ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            let isLocal = line.contains("permanent")
            results.append((ip: ip, mac: formattedMAC, ifName: ifName, isLocal: isLocal))
        }
        return results
    }

    nonisolated public static func ipToComparable(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    nonisolated public static func isSonyOUI(_ mac: String) -> Bool {
        let oui = String(mac.prefix(8)).lowercased()
        let sonyOUIs: Set<String> = [
            "00:04:1f", "00:13:15", "00:15:c1", "00:19:c5", "00:1d:0d",
            "00:1f:a7", "00:24:8d", "00:d9:d1", "00:e4:21", "28:0d:fc",
            "28:40:dd", "2c:cc:44", "40:16:7e", "70:9e:29", "78:c8:81",
            "84:20:96", "98:fa:2e", "a8:47:4a", "a8:e3:ee", "b4:0a:d8",
            "bc:60:a7", "c8:63:f1", "cc:de:80", "d4:4b:5e", "e8:9e:b4",
            "f8:46:1c", "fc:0f:e6"
        ]
        return sonyOUIs.contains(oui)
    }

    nonisolated public static func isPortalOUI(_ mac: String) -> Bool {
        let oui = String(mac.prefix(8)).lowercased()
        return oui == "98:fa:2e" || oui == "a8:47:4a"
    }

    nonisolated public static func probePlayStationDDP(
        targetIPs: [String],
        broadcastIPs: [String] = ["255.255.255.255"],
        interfaceName: String? = nil,
        timeoutMs: Int = 280
    ) -> [String: PlayStationDDPInfo] {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return [:] }
        defer { close(sock) }

        if let interfaceName, !interfaceName.isEmpty {
            var ifIndex = if_nametoindex(interfaceName)
            if ifIndex != 0 {
                setsockopt(sock, IPPROTO_IP, IP_BOUND_IF, &ifIndex, socklen_t(MemoryLayout<UInt32>.size))
            }
        }

        var broadcastEnable: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        let payload = Array("SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n".utf8)
        let allTargets = Array(Set(targetIPs + broadcastIPs))
        for ip in allTargets {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(9302).bigEndian
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { continue }
            withUnsafePointer(to: &addr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, payload, payload.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var found: [String: PlayStationDDPInfo] = [:]
        var recvBuf = [UInt8](repeating: 0, count: 2048)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(50, timeoutMs)) * 1_000_000

        while DispatchTime.now().uptimeNanoseconds < deadline {
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(min(50, max(1, Int((deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000))))
            let ready = poll(&pfd, 1, remMs)
            if ready <= 0 { continue }

            var senderAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &senderAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    recvfrom(sock, &recvBuf, recvBuf.count, 0, ptr, &addrLen)
                }
            }
            guard n > 0 else { continue }

            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = senderAddr.sin_addr
            inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let senderIP = String(decoding: ipBuf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
            guard !senderIP.isEmpty else { continue }

            let text = String(decoding: recvBuf.prefix(n), as: UTF8.self)
            let lines = text.components(separatedBy: .newlines)
            let statusLine = lines.first ?? ""
            let isStandby = statusLine.contains("620")

            var hostType = ""
            var hostName = ""
            var sysVer = ""
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if key == "host-type" { hostType = val }
                else if key == "host-name" { hostName = val }
                else if key == "system-version" { sysVer = val }
            }

            if !hostType.isEmpty {
                found[senderIP] = PlayStationDDPInfo(
                    ip: senderIP,
                    hostType: hostType,
                    hostName: hostName,
                    systemVersion: sysVer,
                    isStandby: isStandby
                )
            }
        }
        return found
    }
}

/// 运行环境信息（版本、CPU 架构、硬件型号与系统版本）
public enum AppEnvironmentInfo {
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.2"
    }

    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2"
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
