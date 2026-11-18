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

/// 局域网终端主动自报信息（来自 UPnP / mDNS / NetBIOS / 路由器 DNS PTR）
public struct LanPeerSelfReport: Sendable {
    public var hostname: String?
    public var friendlyName: String?
    public var manufacturer: String?
    public var model: String?
    public var iconHint: String?

    public init(
        hostname: String? = nil,
        friendlyName: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        iconHint: String? = nil
    ) {
        self.hostname = hostname
        self.friendlyName = friendlyName
        self.manufacturer = manufacturer
        self.model = model
        self.iconHint = iconHint
    }

    public mutating func merge(_ other: LanPeerSelfReport) {
        if friendlyName == nil || friendlyName?.isEmpty == true {
            friendlyName = other.friendlyName
        }
        if manufacturer == nil || manufacturer?.isEmpty == true {
            manufacturer = other.manufacturer
        }
        if model == nil || model?.isEmpty == true {
            model = other.model
        }
        if hostname == nil || hostname?.isEmpty == true {
            hostname = other.hostname
        }
        if iconHint == nil || iconHint?.isEmpty == true {
            iconHint = other.iconHint
        }
    }
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

    public struct PhysicalNetworkContext: Sendable {
        public let serviceID: String?
        public let interfaceName: String
        public let gateway: String
        public let localIPv4: String
        public let interfaceType: String?
        public let hasVPN: Bool
    }

    private nonisolated static let virtualInterfacePrefixes: [String] = [
        "utun", "tun", "tap", "ppp", "ipsec", "wg",
        "feth", "lo", "awdl", "llw", "anpi", "gif", "stf", "ap", "vnic", "vmnet"
    ]

    nonisolated public static func isVirtualInterfaceName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return true }
        return virtualInterfacePrefixes.contains { lower.hasPrefix($0) }
    }

    nonisolated public static func isCountablePhysicalInterfaceName(_ name: String) -> Bool {
        guard !isVirtualInterfaceName(name) else { return false }
        return name.hasPrefix("en") || name.hasPrefix("bridge")
    }

    nonisolated private static func isValidLANIPv4(_ ip: String) -> Bool {
        !ip.isEmpty && ip != "127.0.0.1" && !ip.hasPrefix("169.254.")
    }

    /// 原生 SCDynamicStore 物理链路解析（无子进程，兼容 VPN / utun 场景）
    nonisolated public static func resolvePhysicalInterface() -> PhysicalNetworkContext {
        var activeIPv4ByIface: [String: String] = [:]
        var hasVPN = false

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(first) }
            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let current = ptr {
                let ifa = current.pointee
                let flags = Int32(ifa.ifa_flags)
                let isUp = (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0
                let isRunning = (flags & IFF_RUNNING) != 0

                if isUp, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                    let name = String(cString: ifa.ifa_name)
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    let parsed = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)

                    if isValidLANIPv4(parsed) {
                        if name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec") || name.hasPrefix("wg") || name.hasPrefix("tun") || name.hasPrefix("tap") {
                            hasVPN = true
                        }
                        if isRunning && !isVirtualInterfaceName(name) && activeIPv4ByIface[name] == nil {
                            activeIPv4ByIface[name] = parsed
                        }
                    }
                }
                ptr = ifa.ifa_next
            }
        }

        var scTypeByBSD: [String: String] = [:]
        if let scInterfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in scInterfaces {
                if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
                   let type = SCNetworkInterfaceGetInterfaceType(iface) as String? {
                    scTypeByBSD[bsd] = type
                }
            }
        }

        guard let store = SCDynamicStoreCreate(nil, "PortalHighBitrate.GatewayDetect" as CFString, nil, nil) else {
            let fallbackIface = activeIPv4ByIface.keys.sorted().first ?? "en0"
            return PhysicalNetworkContext(
                serviceID: nil,
                interfaceName: fallbackIface,
                gateway: "",
                localIPv4: activeIPv4ByIface[fallbackIface] ?? "127.0.0.1",
                interfaceType: scTypeByBSD[fallbackIface],
                hasVPN: hasVPN
            )
        }

        if let globalDict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            let globalIface = (globalDict["PrimaryInterface"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let globalService = (globalDict["PrimaryService"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let globalGW = (globalDict["Router"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !globalIface.isEmpty,
               !isVirtualInterfaceName(globalIface),
               let activeIP = activeIPv4ByIface[globalIface] {
                var resolvedGW = globalGW
                if resolvedGW.isEmpty, let globalService,
                   let svcDict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(globalService)/IPv4" as CFString) as? [String: Any] {
                    resolvedGW = (svcDict["Router"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                return PhysicalNetworkContext(
                    serviceID: globalService,
                    interfaceName: globalIface,
                    gateway: resolvedGW,
                    localIPv4: activeIP,
                    interfaceType: scTypeByBSD[globalIface],
                    hasVPN: hasVPN
                )
            }
        }

        var orderedServiceIDs: [String] = []
        if let setupDict = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
           let order = setupDict["ServiceOrder"] as? [String] {
            orderedServiceIDs.append(contentsOf: order)
        }
        if let stateKeys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String] {
            for key in stateKeys {
                let parts = key.split(separator: "/")
                if parts.count == 5 {
                    let sid = String(parts[3])
                    if !orderedServiceIDs.contains(sid) {
                        orderedServiceIDs.append(sid)
                    }
                }
            }
        }

        var backupWithoutRouter: PhysicalNetworkContext?
        for sid in orderedServiceIDs {
            guard let svcDict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(sid)/IPv4" as CFString) as? [String: Any] else {
                continue
            }
            let rawIface = (svcDict["ConfirmedInterfaceName"] as? String)
                ?? (svcDict["InterfaceName"] as? String)
                ?? ""
            let iface = rawIface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !iface.isEmpty, !isVirtualInterfaceName(iface) else { continue }
            guard let activeIP = activeIPv4ByIface[iface] else { continue }

            let router = (svcDict["Router"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ctx = PhysicalNetworkContext(
                serviceID: sid,
                interfaceName: iface,
                gateway: router,
                localIPv4: activeIP,
                interfaceType: scTypeByBSD[iface],
                hasVPN: hasVPN
            )
            if !router.isEmpty {
                return ctx
            }
            if backupWithoutRouter == nil {
                backupWithoutRouter = ctx
            }
        }

        if let backupWithoutRouter {
            return backupWithoutRouter
        }

        let sortedIfaces = activeIPv4ByIface.keys.sorted { lhs, rhs in
            func rank(_ ifName: String) -> Int {
                let scType = scTypeByBSD[ifName]
                if scType == (kSCNetworkInterfaceTypeEthernet as String) { return 0 }
                if scType == (kSCNetworkInterfaceTypeIEEE80211 as String) { return 1 }
                if ifName.hasPrefix("en") { return 2 }
                return 3
            }
            let r1 = rank(lhs), r2 = rank(rhs)
            return r1 != r2 ? r1 < r2 : lhs < rhs
        }

        let bestIface = sortedIfaces.first ?? "en0"
        var bestGW = ""
        if let ifaceDict = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(bestIface)/IPv4" as CFString) as? [String: Any] {
            bestGW = (ifaceDict["Router"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return PhysicalNetworkContext(
            serviceID: nil,
            interfaceName: bestIface,
            gateway: bestGW,
            localIPv4: activeIPv4ByIface[bestIface] ?? "127.0.0.1",
            interfaceType: scTypeByBSD[bestIface],
            hasVPN: hasVPN
        )
    }

    /// 探测当前默认路由网关与出口网卡
    nonisolated public static func detectGatewayAndInterface() -> (gateway: String, iface: String) {
        let ctx = resolvePhysicalInterface()
        return (gateway: ctx.gateway, iface: ctx.interfaceName)
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
                if isCountablePhysicalInterfaceName(name) && !seenNames.contains(name) {
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
                        } else if name.hasPrefix("bridge") {
                            friendlyLabel = "雷雳网桥"
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

/// 局域网无子进程 ARP 探测、多协议自报与 PlayStation DDP (UDP 9302) 主机/掌机识别工具
public enum PortalLanDiscovery {
    /// 根据选中网卡的真实子网掩码推算待探测主机 IP 列表（超大子网自动收敛至所属 /24）
    nonisolated public static func resolveScanTargetHosts(
        interfaceName: String,
        fallbackGatewayIP: String,
        extraIPs: [String] = []
    ) -> (hosts: [String], broadcastIPs: [String]) {
        if let info = ActiveInterfaceInfo.ipv4SubnetInfo(for: interfaceName) {
            let network = info.ip & info.mask
            let broadcast = network | ~info.mask
            let totalRange = broadcast > network ? (broadcast - network) : 0
            var hostSet = Set<UInt32>()

            if totalRange > 1 && totalRange <= 1024 {
                hostSet.reserveCapacity(Int(totalRange))
                for cursor in (network + 1)...(broadcast - 1) where cursor != info.ip {
                    hostSet.insert(cursor)
                }
            } else {
                var anchors: [UInt32] = [info.ip]
                for extra in [fallbackGatewayIP] + extraIPs where !extra.isEmpty {
                    var inAddr = in_addr()
                    if inet_pton(AF_INET, extra, &inAddr) == 1 {
                        let ipHost = UInt32(bigEndian: inAddr.s_addr)
                        if (ipHost & info.mask) == network {
                            anchors.append(ipHost)
                        }
                    }
                }
                var slash24Nets: [UInt32] = []
                for a in anchors {
                    let net24 = a & 0xFFFFFF00
                    if !slash24Nets.contains(net24) {
                        slash24Nets.append(net24)
                        if slash24Nets.count >= 4 { break }
                    }
                }
                for net24 in slash24Nets {
                    let lo = max(network + 1, net24 + 1)
                    let hi = min(broadcast - 1, net24 + 254)
                    guard lo <= hi else { continue }
                    for cursor in lo...hi where cursor != info.ip {
                        hostSet.insert(cursor)
                    }
                }
            }

            let hosts = hostSet.sorted().map { ipv4String(fromHostOrder: $0) }
            return (hosts, Array(Set(["255.255.255.255", info.broadcast])))
        }

        let parts = fallbackGatewayIP.split(separator: ".")
        guard parts.count == 4 else { return ([], ["255.255.255.255"]) }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
        let hosts = (1...254).map { "\(prefix).\($0)" }
        return (hosts, ["255.255.255.255", "\(prefix).255"])
    }

    nonisolated private static func ipv4String(fromHostOrder ipHost: UInt32) -> String {
        var netAddr = in_addr(s_addr: ipHost.bigEndian)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &netAddr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(decoding: buf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    nonisolated private static func bindSocket(
        _ sock: Int32,
        toInterface interfaceName: String?,
        multicastLocalIP: String? = nil
    ) {
        if let interfaceName, !interfaceName.isEmpty {
            var ifIndex = if_nametoindex(interfaceName)
            if ifIndex != 0 {
                setsockopt(sock, IPPROTO_IP, IP_BOUND_IF, &ifIndex, socklen_t(MemoryLayout<UInt32>.size))
            }
        }
        if let multicastLocalIP, !multicastLocalIP.isEmpty {
            var localAddr = in_addr()
            if inet_pton(AF_INET, multicastLocalIP, &localAddr) == 1 {
                setsockopt(sock, IPPROTO_IP, IP_MULTICAST_IF, &localAddr, socklen_t(MemoryLayout<in_addr>.size))
            }
        }
    }

    nonisolated public static func sweepSubnetFast(basePrefix: String, interfaceName: String? = nil) {
        let targets = (1...254).map { "\(basePrefix).\($0)" }
        probeHostsViaUDP(
            ips: targets,
            ports: [5353],
            interfaceName: interfaceName,
            batchSize: 32,
            batchDelayUs: 6_000
        )
    }

    /// 分批限流发送轻量 UDP 探包，避免内核待解析 ARP 队列及 AP 广播队列溢出丢包
    nonisolated public static func probeHostsViaUDP(
        ips: [String],
        ports: [UInt16],
        interfaceName: String?,
        batchSize: Int = 32,
        batchDelayUs: useconds_t = 8_000,
        isCancelled: (() -> Bool)? = nil
    ) {
        guard !ips.isEmpty, !ports.isEmpty else { return }
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        let dummy: [UInt8] = [0]
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)

        for startIdx in stride(from: 0, to: ips.count, by: max(1, batchSize)) {
            if isCancelled?() == true { return }
            let endIdx = min(startIdx + max(1, batchSize), ips.count)
            for idx in startIdx..<endIdx {
                guard inet_pton(AF_INET, ips[idx], &addr.sin_addr) == 1 else { continue }
                for port in ports {
                    addr.sin_port = in_port_t(port).bigEndian
                    withUnsafePointer(to: &addr) { saPtr in
                        saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                            _ = sendto(sock, dummy, 1, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
            if endIdx < ips.count && batchDelayUs > 0 {
                usleep(batchDelayUs)
            }
        }
    }

    /// 非特权 ICMP Echo 分批探活，针对上一轮未入表主机触发 ARP 解析
    nonisolated public static func probeHostsViaICMP(
        ips: [String],
        interfaceName: String?,
        batchSize: Int = 32,
        batchDelayUs: useconds_t = 10_000,
        isCancelled: (() -> Bool)? = nil
    ) {
        guard !ips.isEmpty else { return }
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard sock >= 0 else { return }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        let pid = UInt16(getpid() & 0xFFFF)

        for startIdx in stride(from: 0, to: ips.count, by: max(1, batchSize)) {
            if isCancelled?() == true { return }
            let endIdx = min(startIdx + max(1, batchSize), ips.count)
            for idx in startIdx..<endIdx {
                guard inet_pton(AF_INET, ips[idx], &addr.sin_addr) == 1 else { continue }
                let seq = UInt16((idx + 1) & 0xFFFF)
                let packet = buildICMPEchoRequest(identifier: pid, sequence: seq)
                withUnsafePointer(to: &addr) { saPtr in
                    saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                        _ = sendto(sock, packet, packet.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if endIdx < ips.count && batchDelayUs > 0 {
                usleep(batchDelayUs)
            }
        }
    }

    nonisolated private static func buildICMPEchoRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            8, 0,
            0, 0,
            UInt8(identifier >> 8), UInt8(identifier & 0xFF),
            UInt8(sequence >> 8), UInt8(sequence & 0xFF)
        ]
        var sum: UInt32 = 0
        for i in stride(from: 0, to: packet.count, by: 2) {
            sum += (UInt32(packet[i]) << 8) | UInt32(packet[i + 1])
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        let checksum = ~UInt16(sum & 0xFFFF)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xFF)
        return packet
    }

    /// 并发检测指定 TCP 端口是否开放（用于识别 PS5 9295 Remote Play 与电视 AirPlay/Cast 端口）
    nonisolated public static func probeHostsViaTCPWithResults(
        ips: [String],
        port: UInt16,
        interfaceName: String?,
        timeoutMs: Int = 260,
        batchSize: Int = 32,
        isCancelled: (() -> Bool)? = nil
    ) -> Set<String> {
        guard !ips.isEmpty else { return [] }
        var reachable = Set<String>()
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian

        for startIdx in stride(from: 0, to: ips.count, by: max(1, batchSize)) {
            if isCancelled?() == true { break }
            let endIdx = min(startIdx + max(1, batchSize), ips.count)
            var pending: [(ip: String, fd: Int32)] = []
            pending.reserveCapacity(endIdx - startIdx)

            for idx in startIdx..<endIdx {
                let ip = ips[idx]
                guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { continue }
                let sock = socket(AF_INET, SOCK_STREAM, 0)
                guard sock >= 0 else { continue }
                bindSocket(sock, toInterface: interfaceName)
                _ = fcntl(sock, F_SETFL, O_NONBLOCK)
                let rc = withUnsafePointer(to: &addr) { saPtr in
                    saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                        connect(sock, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if rc == 0 {
                    reachable.insert(ip)
                    close(sock)
                } else if errno == EINPROGRESS {
                    pending.append((ip, sock))
                } else {
                    close(sock)
                }
            }

            if !pending.isEmpty {
                let deadlineNs = DispatchTime.now().uptimeNanoseconds + UInt64(max(60, timeoutMs)) * 1_000_000
                var remaining = pending
                while !remaining.isEmpty && DispatchTime.now().uptimeNanoseconds < deadlineNs {
                    if isCancelled?() == true { break }
                    var pfds = remaining.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
                    let waitMs = Int32(min(50, max(1, Int((deadlineNs - DispatchTime.now().uptimeNanoseconds) / 1_000_000))))
                    let ready = poll(&pfds, nfds_t(pfds.count), waitMs)
                    if ready <= 0 { continue }

                    var nextRemaining: [(ip: String, fd: Int32)] = []
                    for (i, item) in remaining.enumerated() {
                        let revents = pfds[i].revents
                        if revents == 0 {
                            nextRemaining.append(item)
                            continue
                        }
                        var sockErr: Int32 = -1
                        var errLen = socklen_t(MemoryLayout<Int32>.size)
                        _ = getsockopt(item.fd, SOL_SOCKET, SO_ERROR, &sockErr, &errLen)
                        if sockErr == 0 && (revents & Int16(POLLOUT)) != 0 {
                            reachable.insert(item.ip)
                        }
                        close(item.fd)
                    }
                    remaining = nextRemaining
                }
                for item in remaining {
                    close(item.fd)
                }
            }
        }
        return reachable
    }

    nonisolated public static func probeHostsViaTCP(
        ips: [String],
        ports: [UInt16],
        interfaceName: String?,
        batchSize: Int = 24,
        batchDelayUs: useconds_t = 15_000,
        isCancelled: (() -> Bool)? = nil
    ) {
        guard !ips.isEmpty, !ports.isEmpty else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)

        for port in ports {
            if isCancelled?() == true { return }
            addr.sin_port = in_port_t(port).bigEndian

            for startIdx in stride(from: 0, to: ips.count, by: max(1, batchSize)) {
                if isCancelled?() == true { return }
                let endIdx = min(startIdx + max(1, batchSize), ips.count)
                var openFds: [Int32] = []
                openFds.reserveCapacity(endIdx - startIdx)

                for idx in startIdx..<endIdx {
                    guard inet_pton(AF_INET, ips[idx], &addr.sin_addr) == 1 else { continue }
                    let sock = socket(AF_INET, SOCK_STREAM, 0)
                    guard sock >= 0 else { continue }
                    bindSocket(sock, toInterface: interfaceName)
                    _ = fcntl(sock, F_SETFL, O_NONBLOCK)
                    _ = withUnsafePointer(to: &addr) { saPtr in
                        saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                            connect(sock, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    openFds.append(sock)
                }

                if batchDelayUs > 0 {
                    usleep(batchDelayUs)
                }
                for fd in openFds {
                    close(fd)
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
        let rtmHeaderSize = MemoryLayout<rt_msghdr>.stride
        let sdlDataOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) ?? 8

        while ptr.advanced(by: rtmHeaderSize) <= end {
            let rtm = ptr.withMemoryRebound(to: rt_msghdr.self, capacity: 1) { $0.pointee }
            let rtmLen = Int(rtm.rtm_msglen)
            guard rtmLen >= rtmHeaderSize else { break }
            let msgEnd = ptr.advanced(by: rtmLen)
            guard msgEnd <= end else { break }

            defer { ptr = msgEnd }

            let addrsMask = rtm.rtm_addrs
            guard (addrsMask & RTA_DST) != 0, (addrsMask & RTA_GATEWAY) != 0 else { continue }

            var saPtr = ptr.advanced(by: rtmHeaderSize)
            guard saPtr.advanced(by: MemoryLayout<sockaddr_in>.size) <= msgEnd else { continue }

            let rtaxDst = saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0.pointee }
            guard rtaxDst.sa_family == UInt8(AF_INET) else { continue }

            let sin = saPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var ipAddr = sin.sin_addr
            var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &ipAddr, &ipStr, socklen_t(INET_ADDRSTRLEN))
            let ip = String(decoding: ipStr.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)

            let rawLen = Int(rtaxDst.sa_len)
            let roundedLen = rawLen > 0 ? ((rawLen + 3) & ~3) : MemoryLayout<UInt32>.size
            saPtr = saPtr.advanced(by: roundedLen)

            guard saPtr.advanced(by: sdlDataOffset) <= msgEnd else { continue }
            let sdl = saPtr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
            guard sdl.sdl_family == UInt8(AF_LINK) && sdl.sdl_alen == 6 else { continue }

            let sdlData = saPtr.advanced(by: sdlDataOffset)
            let nlen = Int(sdl.sdl_nlen)
            guard sdlData.advanced(by: nlen + 6) <= msgEnd else { continue }

            let macBytes = sdlData.advanced(by: nlen)
            let mac = (0..<6).map { String(format: "%02x", macBytes[$0]) }.joined(separator: ":")

            var ifNameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            if_indextoname(UInt32(sdl.sdl_index), &ifNameBuf)
            let ifName = String(decoding: ifNameBuf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)

            let isLocal = (rtm.rtm_flags & RTF_LOCAL) != 0
            results.append((ip: ip, mac: mac, ifName: ifName, isLocal: isLocal))
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

    /// 统一 Sony PlayStation / Portal IEEE OUI 判定（联动 5.4 万条权威 OUI 库）
    nonisolated public static func isSonyOUI(_ mac: String) -> Bool {
        let oui = String((LanOuiDatabase.normalizeMAC(mac) ?? mac).prefix(8)).lowercased()
        let sonyOUIs: Set<String> = [
            "00:04:1f", "00:13:15", "00:15:c1", "00:19:c5", "00:1d:0d",
            "00:1f:a7", "00:24:8d", "00:d9:d1", "00:e4:21", "28:0d:fc",
            "28:40:dd", "2c:cc:44", "40:16:7e", "70:9e:29", "78:c8:81",
            "84:20:96", "98:fa:2e", "a8:47:4a", "a8:e3:ee", "b4:0a:d8",
            "bc:60:a7", "c8:63:f1", "cc:de:80", "d4:4b:5e", "e8:9e:b4",
            "f8:46:1c", "fc:0f:e6"
        ]
        if sonyOUIs.contains(oui) { return true }
        if let match = LanOuiDatabase.shared.lookup(mac) {
            return match.shortVendor == "Sony" || match.fullOrg.lowercased().contains("sony")
        }
        return false
    }

    nonisolated public static func isPortalOUI(_ mac: String) -> Bool {
        let oui = String((LanOuiDatabase.normalizeMAC(mac) ?? mac).prefix(8)).lowercased()
        return oui == "98:fa:2e" || oui == "a8:47:4a" || oui == "d4:4b:5e"
    }

    /// 根据主机名 / 服务名排除非掌机类的 Sony 家电与外设（Bravia 电视 / Xperia 手机 / Soundbar 等）
    nonisolated public static func isNonHandheldSonyText(_ text: String) -> Bool {
        let low = text.lowercased()
        let blockedKeywords = [
            "bravia", "xperia", "walkman", "alpha", "ilce-",
            "soundbar", "ht-a", "ht-s", "ht-g", "ht-z", "str-",
            "wh-1000", "wf-1000", "xr-", "kd-", "kdl-", "psvr"
        ]
        return blockedKeywords.contains { low.contains($0) }
    }

    /// 识别 Sony Interactive Entertainment (SIE 互动娱乐) 专属游戏硬件号段（PS5 / PS Portal / PS4 等）
    nonisolated public static func isSonyInteractiveOUI(_ mac: String) -> Bool {
        if isPortalOUI(mac) { return true }
        if let match = LanOuiDatabase.shared.lookup(mac) {
            return match.fullOrg.lowercased().contains("sony interactive entertainment")
        }
        return false
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
        let sendBurst = {
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
        }
        sendBurst()

        var found: [String: PlayStationDDPInfo] = [:]
        var recvBuf = [UInt8](repeating: 0, count: 2048)
        let startNs = DispatchTime.now().uptimeNanoseconds
        let deadline = startNs + UInt64(max(50, timeoutMs)) * 1_000_000
        let retryAtNs = startNs + 180_000_000
        var retried = timeoutMs < 450

        while DispatchTime.now().uptimeNanoseconds < deadline {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if !retried && nowNs >= retryAtNs {
                retried = true
                sendBurst()
            }
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(min(50, max(1, Int((deadline - nowNs) / 1_000_000))))
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

    // MARK: - 多协议局域网设备主动自报探测 (DNS PTR / mDNS / SSDP+UPnP / NetBIOS)

    private final class ThreadSafeReportStore: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: LanPeerSelfReport] = [:]

        func merge(_ incoming: [String: LanPeerSelfReport]) {
            guard !incoming.isEmpty else { return }
            lock.lock()
            for (ip, rep) in incoming {
                if var existing = storage[ip] {
                    existing.merge(rep)
                    storage[ip] = existing
                } else {
                    storage[ip] = rep
                }
            }
            lock.unlock()
        }

        func snapshot() -> [String: LanPeerSelfReport] {
            lock.lock()
            let copy = storage
            lock.unlock()
            return copy
        }
    }

    private final class ThreadSafeXmlResultStore: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: LanPeerSelfReport] = [:]

        func set(_ ip: String, report: LanPeerSelfReport) {
            lock.lock()
            if var existing = storage[ip] {
                var fresh = report
                fresh.merge(existing)
                existing = fresh
                storage[ip] = existing
            } else {
                storage[ip] = report
            }
            lock.unlock()
        }

        func snapshot() -> [String: LanPeerSelfReport] {
            lock.lock()
            let copy = storage
            lock.unlock()
            return copy
        }
    }

    /// 并行执行 DNS PTR、mDNS、SSDP+UPnP、NetBIOS 自报探测，严格受限于 timeoutMs 内返回
    nonisolated public static func probePeerSelfReports(
        targetIPs: [String],
        gatewayIP: String,
        localIP: String,
        interfaceName: String?,
        timeoutMs: Int = 420
    ) -> [String: LanPeerSelfReport] {
        guard !targetIPs.isEmpty else { return [:] }

        let store = ThreadSafeReportStore()
        let group = DispatchGroup()
        let dnsTimeout = min(240, timeoutMs)
        let nbTimeout = min(220, timeoutMs)
        let mdnsTimeout = min(320, timeoutMs)

        let upnpStore = ThreadSafeReportStore()
        let mdnsStore = ThreadSafeReportStore()
        let nbStore = ThreadSafeReportStore()
        let ptrStore = ThreadSafeReportStore()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let res = probeSSDPAndUPnP(
                targetIPs: targetIPs,
                interfaceName: interfaceName,
                localIP: localIP,
                timeoutMs: timeoutMs
            )
            upnpStore.merge(res)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let res = probeMDNS(
                targetIPs: targetIPs,
                interfaceName: interfaceName,
                localIP: localIP,
                timeoutMs: mdnsTimeout
            )
            mdnsStore.merge(res)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let res = probeNetBIOSNames(
                targetIPs: targetIPs,
                interfaceName: interfaceName,
                timeoutMs: nbTimeout
            )
            nbStore.merge(res)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let res = probeDnsPTR(
                targetIPs: targetIPs,
                gatewayIP: gatewayIP,
                interfaceName: interfaceName,
                timeoutMs: dnsTimeout
            )
            ptrStore.merge(res)
            group.leave()
        }

        _ = group.wait(timeout: .now() + .milliseconds(max(200, timeoutMs + 120)))

        store.merge(upnpStore.snapshot())
        store.merge(mdnsStore.snapshot())
        store.merge(nbStore.snapshot())
        store.merge(ptrStore.snapshot())
        return store.snapshot()
    }

    nonisolated private static func probeDnsPTR(
        targetIPs: [String],
        gatewayIP: String,
        interfaceName: String?,
        timeoutMs: Int = 240
    ) -> [String: LanPeerSelfReport] {
        var dnsServers: [String] = []
        var resolvSuffixes: [String] = []
        if isValidIPv4(gatewayIP), !gatewayIP.hasPrefix("127.") {
            dnsServers.append(gatewayIP)
        }
        if let resolv = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) {
            for line in resolv.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                guard parts.count >= 2 else { continue }
                let directive = parts[0].lowercased()
                if directive == "nameserver" {
                    let ip = String(parts[1])
                    if isValidIPv4(ip), !ip.hasPrefix("127."), !dnsServers.contains(ip) {
                        dnsServers.append(ip)
                    }
                } else if directive == "domain" || directive == "search" {
                    for token in parts.dropFirst() {
                        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                        if !cleaned.isEmpty && cleaned.count >= 2 {
                            let dotSuffix = ".\(cleaned)"
                            if !resolvSuffixes.contains(dotSuffix) {
                                resolvSuffixes.append(dotSuffix)
                            }
                        }
                    }
                }
            }
        }
        let servers = Array(dnsServers.prefix(2))
        guard !servers.isEmpty else { return [:] }

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return [:] }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        var txToIP: [UInt16: String] = [:]
        var nextTx: UInt16 = UInt16.random(in: 1000...60000)

        for ip in targetIPs {
            guard let ptrDomain = reverseArpaDomain(for: ip) else { continue }
            for srv in servers {
                var srvAddr = sockaddr_in()
                srvAddr.sin_family = sa_family_t(AF_INET)
                srvAddr.sin_port = in_port_t(53).bigEndian
                guard inet_pton(AF_INET, srv, &srvAddr.sin_addr) == 1 else { continue }

                nextTx &+= 1
                if nextTx == 0 { nextTx = 1 }
                txToIP[nextTx] = ip
                let pkt = buildDnsQueryPacket(txID: nextTx, qnameLabels: ptrDomain, qtype: 12, qclass: 1)
                withUnsafePointer(to: &srvAddr) { saPtr in
                    saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                        _ = sendto(sock, pkt, pkt.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var rawHostByIP: [String: String] = [:]
        var recvBuf = [UInt8](repeating: 0, count: 2048)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(50, timeoutMs)) * 1_000_000

        while DispatchTime.now().uptimeNanoseconds < deadline && rawHostByIP.count < targetIPs.count {
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(min(40, max(1, Int((deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000))))
            if poll(&pfd, 1, remMs) <= 0 { continue }

            var senderAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &senderAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    recvfrom(sock, &recvBuf, recvBuf.count, 0, ptr, &addrLen)
                }
            }
            guard n > 12 else { continue }
            let packet = Array(recvBuf.prefix(n))
            let txID = (UInt16(packet[0]) << 8) | UInt16(packet[1])
            let flags = (UInt16(packet[2]) << 8) | UInt16(packet[3])
            let rcode = flags & 0x000F
            guard (flags & 0x8000) != 0, rcode == 0 else { continue }

            let parsed = parseDnsPacket(packet)
            let matchedIP = txToIP[txID]
            for rr in parsed.answers where rr.type == 12 {
                let targetIP = ipFromReverseArpa(rr.name) ?? matchedIP
                guard let ip = targetIP, let ptrHost = rr.ptrTarget else { continue }
                let trimmedRaw = ptrHost.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n"))
                guard !trimmedRaw.isEmpty else { continue }
                if rawHostByIP[ip] == nil {
                    rawHostByIP[ip] = trimmedRaw
                }
            }
        }

        var dynamicSuffixes = resolvSuffixes
        if let gwRaw = rawHostByIP[gatewayIP],
           let dotIdx = gwRaw.firstIndex(of: ".") {
            let suffix = String(gwRaw[dotIdx...]).lowercased()
            if suffix.count >= 2 && !dynamicSuffixes.contains(suffix) {
                dynamicSuffixes.append(suffix)
            }
        }
        var labelSuffixCounts: [String: Int] = [:]
        let excludedPublicTLDs: Set<String> = ["com", "net", "org", "cn", "edu", "gov", "io"]
        for rawHost in rawHostByIP.values {
            let parts = rawHost.split(separator: ".")
            if parts.count >= 2, let last = parts.last {
                let lowLast = last.lowercased()
                if !excludedPublicTLDs.contains(lowLast) {
                    labelSuffixCounts[".\(lowLast)", default: 0] += 1
                }
            }
        }
        for (suffix, count) in labelSuffixCounts where count >= 2 && !dynamicSuffixes.contains(suffix) {
            dynamicSuffixes.append(suffix)
        }

        var reports: [String: LanPeerSelfReport] = [:]
        for (ip, rawHost) in rawHostByIP {
            if let cleaned = cleanHostname(rawHost, extraSuffixes: dynamicSuffixes) {
                reports[ip] = LanPeerSelfReport(hostname: cleaned)
            }
        }
        return reports
    }

    nonisolated private static func probeMDNS(
        targetIPs: [String],
        interfaceName: String?,
        localIP: String?,
        timeoutMs: Int = 320
    ) -> [String: LanPeerSelfReport] {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return [:] }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName, multicastLocalIP: localIP)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        var mdnsMulticast = sockaddr_in()
        mdnsMulticast.sin_family = sa_family_t(AF_INET)
        mdnsMulticast.sin_port = in_port_t(5353).bigEndian
        inet_pton(AF_INET, "224.0.0.251", &mdnsMulticast.sin_addr)

        let serviceTypes = [
            ["_hap", "_tcp", "local"],
            ["_airplay", "_tcp", "local"],
            ["_companion-link", "_tcp", "local"],
            ["_miio", "_udp", "local"],
            ["_smb", "_tcp", "local"],
            ["_device-info", "_tcp", "local"],
            ["_googlecast", "_tcp", "local"],
            ["_ipp", "_tcp", "local"],
            ["_printer", "_tcp", "local"]
        ]
        for svc in serviceTypes {
            let pkt = buildDnsQueryPacket(txID: 0, qnameLabels: svc, qtype: 12, qclass: 0x8001)
            withUnsafePointer(to: &mdnsMulticast) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, pkt, pkt.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        for ip in targetIPs {
            guard let rev = reverseArpaDomain(for: ip) else { continue }
            var peerAddr = sockaddr_in()
            peerAddr.sin_family = sa_family_t(AF_INET)
            peerAddr.sin_port = in_port_t(5353).bigEndian
            guard inet_pton(AF_INET, ip, &peerAddr.sin_addr) == 1 else { continue }
            let pkt = buildDnsQueryPacket(txID: 0, qnameLabels: rev, qtype: 12, qclass: 0x8001)
            withUnsafePointer(to: &peerAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, pkt, pkt.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var reports: [String: LanPeerSelfReport] = [:]
        var hostToIP: [String: String] = [:]
        var recvBuf = [UInt8](repeating: 0, count: 4096)
        let targetSet = Set(targetIPs)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(60, timeoutMs)) * 1_000_000

        while DispatchTime.now().uptimeNanoseconds < deadline {
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(min(40, max(1, Int((deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000))))
            if poll(&pfd, 1, remMs) <= 0 { continue }

            var senderAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &senderAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    recvfrom(sock, &recvBuf, recvBuf.count, 0, ptr, &addrLen)
                }
            }
            guard n > 12 else { continue }

            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = senderAddr.sin_addr
            inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let senderIP = String(decoding: ipBuf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)

            let parsed = parseDnsPacket(Array(recvBuf.prefix(n)))
            let allRRs = parsed.answers + parsed.additionals

            var packetHosts: Set<String> = []
            for rr in allRRs where rr.type == 1 {
                if let ip = rr.ipv4, targetSet.contains(ip) {
                    let hostKey = rr.name.lowercased()
                    hostToIP[hostKey] = ip
                    packetHosts.insert(ip)
                    if let cleaned = cleanHostname(rr.name) {
                        var rep = reports[ip] ?? LanPeerSelfReport()
                        rep.merge(LanPeerSelfReport(hostname: cleaned))
                        reports[ip] = rep
                    }
                }
            }

            var serviceToHost: [String: String] = [:]
            for rr in allRRs where rr.type == 33 {
                if let target = rr.srvTarget {
                    serviceToHost[rr.name.lowercased()] = target.lowercased()
                }
            }

            for rr in allRRs where rr.type == 12 {
                if let revIP = ipFromReverseArpa(rr.name),
                   let ptrTarget = rr.ptrTarget,
                   let cleaned = cleanHostname(ptrTarget) {
                    var rep = reports[revIP] ?? LanPeerSelfReport()
                    rep.merge(LanPeerSelfReport(hostname: cleaned))
                    reports[revIP] = rep
                    hostToIP[ptrTarget.lowercased()] = revIP
                } else if let ptrTarget = rr.ptrTarget {
                    let instKey = ptrTarget.lowercased()
                    let srvHost = serviceToHost[instKey]
                    let resolvedIP = srvHost.flatMap { hostToIP[$0] }
                        ?? (packetHosts.count == 1 ? packetHosts.first : (packetHosts.isEmpty && targetSet.contains(senderIP) ? senderIP : nil))
                    if let ip = resolvedIP, let repFromSvc = extractReportFromServiceInstance(ptrTarget) {
                        var rep = reports[ip] ?? LanPeerSelfReport()
                        rep.merge(repFromSvc)
                        reports[ip] = rep
                    }
                }
            }

            for rr in allRRs where rr.type == 16 && !rr.txtPairs.isEmpty {
                let rrKey = rr.name.lowercased()
                let srvHost = serviceToHost[rrKey]
                let resolvedIP = srvHost.flatMap { hostToIP[$0] }
                    ?? hostToIP[rrKey]
                    ?? (packetHosts.count == 1 ? packetHosts.first : (packetHosts.isEmpty && targetSet.contains(senderIP) ? senderIP : nil))
                guard let ip = resolvedIP else { continue }

                var parsedRep = extractReportFromServiceInstance(rr.name) ?? LanPeerSelfReport()
                for (k, v) in rr.txtPairs {
                    let key = k.lowercased()
                    let val = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !val.isEmpty else { continue }
                    switch key {
                    case "fn", "n":
                        if val != "1" && val.count >= 2 {
                            parsedRep.friendlyName = parsedRep.friendlyName ?? val
                        }
                    case "md", "model", "mdl", "usb_mdl":
                        parsedRep.model = parsedRep.model ?? val
                    case "mf", "manufacturer", "mfg", "usb_mfg":
                        parsedRep.manufacturer = parsedRep.manufacturer ?? val
                    case "am":
                        parsedRep.model = parsedRep.model ?? readableAppleModel(val)
                        parsedRep.manufacturer = parsedRep.manufacturer ?? "Apple"
                    case "ty":
                        parsedRep.friendlyName = parsedRep.friendlyName ?? val
                    default:
                        break
                    }
                }
                var existing = reports[ip] ?? LanPeerSelfReport()
                existing.merge(parsedRep)
                reports[ip] = existing
            }
        }

        return reports
    }

    nonisolated private static func probeSSDPAndUPnP(
        targetIPs: [String],
        interfaceName: String?,
        localIP: String?,
        timeoutMs: Int = 420
    ) -> [String: LanPeerSelfReport] {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return [:] }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName, multicastLocalIP: localIP)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        let payloads: [[UInt8]] = [
            Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: upnp:rootdevice\r\n\r\n".utf8),
            Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n".utf8)
        ]

        var ssdpAddr = sockaddr_in()
        ssdpAddr.sin_family = sa_family_t(AF_INET)
        ssdpAddr.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &ssdpAddr.sin_addr)
        for pkt in payloads {
            withUnsafePointer(to: &ssdpAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, pkt, pkt.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        for ip in targetIPs.prefix(128) {
            var unicastAddr = sockaddr_in()
            unicastAddr.sin_family = sa_family_t(AF_INET)
            unicastAddr.sin_port = in_port_t(1900).bigEndian
            guard inet_pton(AF_INET, ip, &unicastAddr.sin_addr) == 1 else { continue }
            withUnsafePointer(to: &unicastAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, payloads[0], payloads[0].count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var locationByIP: [String: URL] = [:]
        var fallbackServerReport: [String: LanPeerSelfReport] = [:]
        var recvBuf = [UInt8](repeating: 0, count: 2048)
        let udpListenMs = min(210, max(100, timeoutMs / 2))
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(udpListenMs) * 1_000_000
        let targetSet = Set(targetIPs)

        while DispatchTime.now().uptimeNanoseconds < deadline {
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(min(35, max(1, Int((deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000))))
            if poll(&pfd, 1, remMs) <= 0 { continue }

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
            var locationRaw = ""
            var serverHeader = ""
            for line in text.components(separatedBy: .newlines) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if key == "location" { locationRaw = val }
                else if key == "server" { serverHeader = val }
            }

            if !locationRaw.isEmpty,
               let url = URL(string: locationRaw),
               url.scheme?.lowercased() == "http",
               let host = url.host,
               host == senderIP || targetSet.contains(host),
               locationByIP[senderIP] == nil {
                locationByIP[senderIP] = url
            }
            if !serverHeader.isEmpty, fallbackServerReport[senderIP] == nil {
                if let srvVendor = inferVendorFromText(serverHeader) {
                    fallbackServerReport[senderIP] = LanPeerSelfReport(manufacturer: srvVendor)
                }
            }
        }

        guard !locationByIP.isEmpty else { return fallbackServerReport }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.32
        cfg.timeoutIntervalForResource = 0.36
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        let xmlStore = ThreadSafeXmlResultStore()
        let fetchGroup = DispatchGroup()

        for (ip, url) in locationByIP.prefix(24) {
            fetchGroup.enter()
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 0.32)
            req.httpMethod = "GET"
            session.dataTask(with: req) { data, _, _ in
                defer { fetchGroup.leave() }
                guard let data, !data.isEmpty else { return }
                let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                guard !xml.isEmpty else { return }

                let friendly = extractXmlTag("friendlyName", from: xml)
                let manufacturer = extractXmlTag("manufacturer", from: xml)
                let modelName = extractXmlTag("modelName", from: xml)
                let deviceType = extractXmlTag("deviceType", from: xml)
                let iconHint = iconHintFromUpnpDeviceType(deviceType)

                let validFriendly = isMeaningfulDeviceName(friendly) ? friendly : nil
                let validModel = isMeaningfulDeviceName(modelName) ? modelName : nil
                let validMfg = isMeaningfulDeviceName(manufacturer) ? manufacturer : nil

                if validFriendly != nil || validModel != nil || validMfg != nil {
                    xmlStore.set(ip, report: LanPeerSelfReport(
                        friendlyName: validFriendly,
                        manufacturer: validMfg,
                        model: validModel,
                        iconHint: iconHint
                    ))
                }
            }.resume()
        }

        _ = fetchGroup.wait(timeout: .now() + .milliseconds(360))
        var merged = xmlStore.snapshot()
        for (ip, fallback) in fallbackServerReport {
            if var existing = merged[ip] {
                existing.merge(fallback)
                merged[ip] = existing
            } else {
                merged[ip] = fallback
            }
        }
        return merged
    }

    nonisolated private static func probeNetBIOSNames(
        targetIPs: [String],
        interfaceName: String?,
        timeoutMs: Int = 220
    ) -> [String: LanPeerSelfReport] {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return [:] }
        defer { close(sock) }

        bindSocket(sock, toInterface: interfaceName)
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        var nbQuery: [UInt8] = [
            0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x20, 0x43, 0x4b, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x00,
            0x00, 0x21, 0x00, 0x01
        ]

        var txToIP: [UInt16: String] = [:]
        var nextTx: UInt16 = UInt16.random(in: 100...30000)

        for ip in targetIPs {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(137).bigEndian
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { continue }
            nextTx &+= 1
            if nextTx == 0 { nextTx = 1 }
            txToIP[nextTx] = ip
            nbQuery[0] = UInt8(nextTx >> 8)
            nbQuery[1] = UInt8(nextTx & 0xFF)
            withUnsafePointer(to: &addr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    _ = sendto(sock, nbQuery, nbQuery.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var reports: [String: LanPeerSelfReport] = [:]
        var recvBuf = [UInt8](repeating: 0, count: 1500)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(50, timeoutMs)) * 1_000_000

        while DispatchTime.now().uptimeNanoseconds < deadline && reports.count < targetIPs.count {
            var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let remMs = Int32(min(35, max(1, Int((deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000))))
            if poll(&pfd, 1, remMs) <= 0 { continue }

            var senderAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &senderAddr) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    recvfrom(sock, &recvBuf, recvBuf.count, 0, ptr, &addrLen)
                }
            }
            guard n > 57 else { continue }

            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = senderAddr.sin_addr
            inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let senderIP = String(decoding: ipBuf.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
            let packet = Array(recvBuf.prefix(n))
            let txID = (UInt16(packet[0]) << 8) | UInt16(packet[1])
            let resolvedIP = senderIP.isEmpty ? (txToIP[txID] ?? "") : senderIP
            guard !resolvedIP.isEmpty else { continue }

            if let host = parseNetBIOSNodeStatusName(packet) {
                reports[resolvedIP] = LanPeerSelfReport(hostname: host)
            }
        }

        return reports
    }

    private struct ParsedDnsRR: Sendable {
        let name: String
        let type: UInt16
        let ptrTarget: String?
        let srvTarget: String?
        let ipv4: String?
        let txtPairs: [(String, String)]
    }

    nonisolated private static func isValidIPv4(_ ip: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, ip, &addr) == 1
    }

    nonisolated private static func reverseArpaDomain(for ip: String) -> [String]? {
        let parts = ip.split(separator: ".").map(String.init)
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return [parts[3], parts[2], parts[1], parts[0], "in-addr", "arpa"]
    }

    nonisolated private static func ipFromReverseArpa(_ domain: String) -> String? {
        let low = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard low.hasSuffix(".in-addr.arpa") else { return nil }
        let stem = String(low.dropLast(".in-addr.arpa".count))
        let octets = stem.split(separator: ".").map(String.init)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return "\(octets[3]).\(octets[2]).\(octets[1]).\(octets[0])"
    }

    nonisolated private static func buildDnsQueryPacket(
        txID: UInt16,
        qnameLabels: [String],
        qtype: UInt16,
        qclass: UInt16
    ) -> [UInt8] {
        var pkt: [UInt8] = [
            UInt8(txID >> 8), UInt8(txID & 0xFF),
            txID == 0 ? 0x00 : 0x01, 0x00,
            0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        for label in qnameLabels {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty && bytes.count <= 63 else { continue }
            pkt.append(UInt8(bytes.count))
            pkt.append(contentsOf: bytes)
        }
        pkt.append(0x00)
        pkt.append(contentsOf: [
            UInt8(qtype >> 8), UInt8(qtype & 0xFF),
            UInt8(qclass >> 8), UInt8(qclass & 0xFF)
        ])
        return pkt
    }

    nonisolated private static func readDnsName(from packet: [UInt8], offset startOffset: Int) -> (name: String, nextOffset: Int)? {
        var labels: [String] = []
        var offset = startOffset
        var jumped = false
        var endOffset = startOffset
        var jumps = 0

        while offset < packet.count {
            let lenByte = packet[offset]
            if lenByte == 0 {
                if !jumped { endOffset = offset + 1 }
                break
            }
            if (lenByte & 0xC0) == 0xC0 {
                guard offset + 1 < packet.count else { return nil }
                let ptr = (Int(lenByte & 0x3F) << 8) | Int(packet[offset + 1])
                if !jumped {
                    endOffset = offset + 2
                    jumped = true
                }
                jumps += 1
                guard jumps <= 16, ptr < packet.count else { return nil }
                offset = ptr
                continue
            }
            let len = Int(lenByte & 0x3F)
            offset += 1
            guard offset + len <= packet.count else { return nil }
            let label = String(decoding: packet[offset..<(offset + len)], as: UTF8.self)
            labels.append(label)
            offset += len
            if !jumped { endOffset = offset }
        }

        return (labels.joined(separator: "."), max(startOffset + 1, endOffset))
    }

    nonisolated private static func parseDnsPacket(_ packet: [UInt8]) -> (answers: [ParsedDnsRR], additionals: [ParsedDnsRR]) {
        guard packet.count >= 12 else { return ([], []) }
        let qdCount = Int((UInt16(packet[4]) << 8) | UInt16(packet[5]))
        let anCount = Int((UInt16(packet[6]) << 8) | UInt16(packet[7]))
        let nsCount = Int((UInt16(packet[8]) << 8) | UInt16(packet[9]))
        let arCount = Int((UInt16(packet[10]) << 8) | UInt16(packet[11]))

        var cursor = 12
        for _ in 0..<min(qdCount, 32) {
            guard let (_, next) = readDnsName(from: packet, offset: cursor), next + 4 <= packet.count else {
                return ([], [])
            }
            cursor = next + 4
        }

        var answers: [ParsedDnsRR] = []
        var additionals: [ParsedDnsRR] = []
        let totalRRs = min(anCount + nsCount + arCount, 128)

        for idx in 0..<totalRRs {
            guard let (rrName, next) = readDnsName(from: packet, offset: cursor), next + 10 <= packet.count else {
                break
            }
            let rtype = (UInt16(packet[next]) << 8) | UInt16(packet[next + 1])
            let rdlen = Int((UInt16(packet[next + 8]) << 8) | UInt16(packet[next + 9]))
            let rdataStart = next + 10
            let rdataEnd = rdataStart + rdlen
            guard rdataEnd <= packet.count else { break }

            var ptrTarget: String? = nil
            var srvTarget: String? = nil
            var ipv4: String? = nil
            var txtPairs: [(String, String)] = []

            switch rtype {
            case 1 where rdlen == 4:
                ipv4 = "\(packet[rdataStart]).\(packet[rdataStart + 1]).\(packet[rdataStart + 2]).\(packet[rdataStart + 3])"
            case 12:
                if let (target, _) = readDnsName(from: packet, offset: rdataStart) {
                    ptrTarget = target
                }
            case 33 where rdlen > 6:
                if let (target, _) = readDnsName(from: packet, offset: rdataStart + 6) {
                    srvTarget = target
                }
            case 16:
                var txtPos = rdataStart
                while txtPos < rdataEnd {
                    let slen = Int(packet[txtPos])
                    txtPos += 1
                    guard txtPos + slen <= rdataEnd else { break }
                    let s = String(decoding: packet[txtPos..<(txtPos + slen)], as: UTF8.self)
                    txtPos += slen
                    if let eqIdx = s.firstIndex(of: "=") {
                        let k = String(s[..<eqIdx])
                        let v = String(s[s.index(after: eqIdx)...])
                        txtPairs.append((k, v))
                    }
                }
            default:
                break
            }

            let rr = ParsedDnsRR(name: rrName, type: rtype, ptrTarget: ptrTarget, srvTarget: srvTarget, ipv4: ipv4, txtPairs: txtPairs)
            if idx < anCount {
                answers.append(rr)
            } else {
                additionals.append(rr)
            }
            cursor = rdataEnd
        }

        return (answers, additionals)
    }

    nonisolated private static func parseNetBIOSNodeStatusName(_ packet: [UInt8]) -> String? {
        guard packet.count > 12 else { return nil }
        let anCount = Int((UInt16(packet[6]) << 8) | UInt16(packet[7]))
        guard anCount >= 1 else { return nil }

        var cursor = 12
        let qdCount = Int((UInt16(packet[4]) << 8) | UInt16(packet[5]))
        for _ in 0..<qdCount {
            guard let (_, next) = readDnsName(from: packet, offset: cursor), next + 4 <= packet.count else { return nil }
            cursor = next + 4
        }

        guard let (_, afterName) = readDnsName(from: packet, offset: cursor), afterName + 10 < packet.count else { return nil }
        let rdlen = Int((UInt16(packet[afterName + 8]) << 8) | UInt16(packet[afterName + 9]))
        let rdataStart = afterName + 10
        guard rdataStart < packet.count, rdataStart + rdlen <= packet.count else { return nil }

        let numNames = Int(packet[rdataStart])
        var pos = rdataStart + 1
        var fallbackName: String? = nil

        for _ in 0..<min(numNames, 32) {
            guard pos + 18 <= packet.count else { break }
            let rawName = String(decoding: packet[pos..<(pos + 15)], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet.whitespaces.union(.controlCharacters))
            let suffix = packet[pos + 15]
            let flags = (UInt16(packet[pos + 16]) << 8) | UInt16(packet[pos + 17])
            pos += 18

            let isGroup = (flags & 0x8000) != 0
            guard !isGroup, !rawName.isEmpty, !rawName.hasPrefix("__MSBROWSE__") else { continue }
            if suffix == 0x00 { return rawName }
            if suffix == 0x20 && fallbackName == nil { fallbackName = rawName }
        }
        return fallbackName
    }

    nonisolated private static func cleanHostname(_ raw: String, extraSuffixes: [String] = []) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix(".") {
            host.removeLast()
        }
        let allSuffixes = ([".localdomain", ".local", ".lan", ".home", ".arpa"] + extraSuffixes)
            .sorted { $0.count > $1.count }
        for suffix in allSuffixes {
            let lowSuffix = suffix.lowercased()
            if !lowSuffix.isEmpty && host.lowercased().hasSuffix(lowSuffix) && host.count > lowSuffix.count {
                host = String(host.dropLast(lowSuffix.count))
                break
            }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 2 && !labels[0].isEmpty && labels[0].lowercased() == labels[1].lowercased() {
            host = String(labels[0])
        }
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count >= 2 else { return nil }
        if isValidIPv4(host) { return nil }
        let lower = host.lowercased()
        if lower == "localhost" || lower == "in-addr" || lower == "ip6" { return nil }
        return host
    }

    nonisolated private static func extractReportFromServiceInstance(_ full: String) -> LanPeerSelfReport? {
        guard let range = full.range(of: "._", options: .caseInsensitive) else { return nil }
        var instance = String(full[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let svcTail = String(full[range.lowerBound...]).lowercased()

        if let atIdx = instance.firstIndex(of: "@") {
            let prefixPart = instance[..<atIdx]
            if prefixPart.count == 12 && prefixPart.allSatisfy({ $0.isHexDigit }) {
                instance = String(instance[instance.index(after: atIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if svcTail.contains("._miio.") {
            let cleanModel = instance.components(separatedBy: "_miio").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let validName = (cleanModel?.isEmpty == false) ? cleanModel : nil
            return LanPeerSelfReport(
                friendlyName: validName,
                manufacturer: "Xiaomi",
                model: validName,
                iconHint: "sensor.tag.radiowaves.forward"
            )
        }

        let cleanInst = (instance.isEmpty || instance.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "-" }) ? nil : instance
        var manufacturer: String? = nil
        var icon: String? = nil
        if svcTail.contains("._airplay.") || svcTail.contains("._companion-link.") || svcTail.contains("._raop.") {
            icon = "apple.logo"
        } else if svcTail.contains("._ipp.") || svcTail.contains("._printer.") {
            icon = "printer.fill"
        } else if svcTail.contains("._smb.") {
            icon = "externaldrive.connected.to.line.below"
        } else if svcTail.contains("._googlecast.") {
            manufacturer = "Google"
            icon = "tv.fill"
        } else if svcTail.contains("._hap.") {
            icon = "house.fill"
        }

        guard cleanInst != nil || manufacturer != nil else { return nil }
        return LanPeerSelfReport(friendlyName: cleanInst, manufacturer: manufacturer, iconHint: icon)
    }

    nonisolated private static func readableAppleModel(_ model: String) -> String {
        let low = model.lowercased()
        if low.hasPrefix("audioaccessory") { return "HomePod" }
        if low.hasPrefix("appletv") { return "Apple TV" }
        if low.hasPrefix("macbookpro") { return "MacBook Pro" }
        if low.hasPrefix("macbookair") { return "MacBook Air" }
        if low.hasPrefix("macmini") { return "Mac mini" }
        if low.hasPrefix("macstudio") { return "Mac Studio" }
        if low.hasPrefix("imac") { return "iMac" }
        if low.hasPrefix("iphone") { return "iPhone" }
        if low.hasPrefix("ipad") { return "iPad" }
        return model
    }

    nonisolated private static func extractXmlTag(_ tag: String, from xml: String) -> String? {
        let token = "<\(tag)"
        var searchStart = xml.startIndex
        while searchStart < xml.endIndex,
              let openStart = xml.range(of: token, options: .caseInsensitive, range: searchStart..<xml.endIndex) {
            if openStart.upperBound < xml.endIndex {
                let nextChar = xml[openStart.upperBound]
                if nextChar != ">" && !nextChar.isWhitespace && nextChar != "/" {
                    searchStart = openStart.upperBound
                    continue
                }
            }
            guard let tagEnd = xml[openStart.upperBound...].firstIndex(of: ">") else {
                return nil
            }
            let valueStart = xml.index(after: tagEnd)
            guard let closeRange = xml.range(of: "</\(tag)>", options: .caseInsensitive, range: valueStart..<xml.endIndex) else {
                return nil
            }
            var raw = String(xml[valueStart..<closeRange.lowerBound])
            raw = raw
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        }
        return nil
    }

    nonisolated private static func isMeaningfulDeviceName(_ value: String?) -> Bool {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return false
        }
        let low = v.lowercased()
        let genericNames: Set<String> = [
            "linux", "unix", "upnp", "device", "unknown", "none", "null", "na", "n/a", "root", "localhost"
        ]
        return !genericNames.contains(low)
    }

    nonisolated private static func iconHintFromUpnpDeviceType(_ deviceType: String?) -> String? {
        guard let dt = deviceType?.lowercased() else { return nil }
        if dt.contains("internetgateway") || dt.contains("wandevice") || dt.contains("router") {
            return "wifi.router"
        }
        if dt.contains("mediarenderer") || dt.contains("tv") {
            return "tv.fill"
        }
        if dt.contains("mediaserver") {
            return "externaldrive.connected.to.line.below"
        }
        if dt.contains("printer") || dt.contains("scanner") {
            return "printer.fill"
        }
        return nil
    }

    nonisolated private static func inferVendorFromText(_ text: String) -> String? {
        let low = text.lowercased()
        let pairs: [(String, String)] = [
            ("apple", "Apple"), ("macbook", "Apple"), ("iphone", "Apple"), ("ipad", "Apple"), ("homepod", "Apple"),
            ("mac studio", "Apple"), ("mac mini", "Apple"), ("imac", "Apple"), ("mac1", "Apple"), ("bunnys-", "Apple"),
            ("sony", "Sony"), ("playstation", "Sony"),
            ("synology", "Synology"), ("qnap", "QNAP"),
            ("asus", "ASUS"), ("merlin", "ASUS"),
            ("xiaomi", "Xiaomi"), ("mijia", "Xiaomi"), ("redmi", "Xiaomi"), ("zhimi", "Xiaomi"),
            ("mismart", "Xiaomi"), ("midjd", "Xiaomi"), ("chunmi", "Xiaomi"), ("dmaker", "Xiaomi"),
            ("zimi", "Xiaomi"), ("cuco", "Xiaomi"), ("yeelink", "Xiaomi"), ("_mibt", "Xiaomi"),
            ("mjxdd", "Xiaomi"), ("mjtd", "Xiaomi"), ("roborock", "Roborock"),
            ("aqara", "Aqara"), ("lumi", "Aqara"), ("ktbl", "Aqara"), ("zhwg", "Aqara"), ("znsxj", "Aqara"),
            ("narwal", "Narwal"),
            ("huawei", "Huawei"), ("honor", "Honor"),
            ("tp-link", "TP-Link"), ("sonos", "Sonos"),
            ("nintendo", "Nintendo"), ("samsung", "Samsung"), ("lg ", "LG"), ("lgwebos", "LG"),
            ("google", "Google"), ("amazon", "Amazon"), ("microsoft", "Microsoft"), ("surface", "Microsoft"),
            ("hikvision", "Hikvision"), ("ezviz", "EZVIZ"), ("dahua", "Dahua"),
            ("hp ", "HP"), ("epson", "Epson"), ("brother", "Brother"), ("canon", "Canon"),
            ("ireader", "iReader"), ("zhangyue", "iReader"), ("ocean-", "iReader")
        ]
        for (needle, brand) in pairs where low.contains(needle) {
            return brand
        }
        return nil
    }
}

/// 运行环境信息（版本、CPU 架构、硬件型号与系统版本）
public enum AppEnvironmentInfo {
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.5"
    }

    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "5"
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
