import Foundation
import AppKit
import Darwin

public enum BitrateProfile: String, CaseIterable, Identifiable, Sendable {
    case mbps65 = "65 Mbps"
    case mbps100 = "100 Mbps (推荐)"
    case mbps200 = "200 Mbps (极致)"

    public var id: String { rawValue }

    public var shortTag: String {
        switch self {
        case .mbps65: return "65M"
        case .mbps100: return "100M"
        case .mbps200: return "200M"
        }
    }

    public var description: String {
        switch self {
        case .mbps65: return "清晰度显著高于官方默认，对 Wi-Fi 稳定性要求均衡"
        case .mbps100: return "官方限制近 4 倍画质，极度细腻通透，强烈推荐"
        case .mbps200: return "极致无损级码率，需要极佳的 5GHz / 6GHz Wi-Fi 环境"
        }
    }
}

public struct DiscoveredDevice: Identifiable, Sendable, Codable, Hashable {
    public let id: String
    public let ip: String
    public let mac: String
    public let isLikelySony: Bool
    public let label: String
}

@MainActor
public final class PortalRelayManager: ObservableObject {
    public static let shared = PortalRelayManager()

    @Published public var isRunning: Bool = false
    @Published public var isListening: Bool = false
    @Published public var isStreamActive: Bool = false
    @Published public var targetBitrate: BitrateProfile = .mbps100
    @Published public var selectedInterface: String = "en0"
    @Published public var activeInterfaces: [ActiveInterfaceInfo] = []
    @Published public var ps5IP: String = ""
    @Published public var portalIP: String = ""
    @Published public var discoveredDevices: [DiscoveredDevice] = []
    @Published public var isScanningDevices: Bool = false
    @Published public var runWithAdmin: Bool = true
    @Published public var logs: [String] = []
    @Published public var lastError: String? = nil
    @Published public var listenRemainingSeconds: Int? = nil

    public var selectedInterfaceInfo: ActiveInterfaceInfo? {
        activeInterfaces.first(where: { $0.name == selectedInterface })
    }

    private var relayProcess: Process?
    private var outputPipe: Pipe?
    private var logWatchTimer: Timer?
    private var listenCountdownTimer: Timer?
    private var listenDeadline: Date?
    private var lastLogOffset: UInt64 = 0
    private var hasExplicitInterfaceConfig: Bool = false

    private let logFilePath = "/tmp/portal_high_bitrate.log"
    private let pidFilePath = "/tmp/portal_high_bitrate.pid"

    public var supportDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Portal-High-Bitrate", isDirectory: true)
    }

    private var configFileURL: URL {
        supportDirectoryURL.appendingPathComponent("config.json")
    }

    private var engineFileURL: URL {
        let appSupportEngine = supportDirectoryURL.appendingPathComponent("portal_engine")
        if FileManager.default.isExecutableFile(atPath: appSupportEngine.path) {
            return appSupportEngine
        }
        if let bundleEngine = Bundle.main.resourceURL?.appendingPathComponent("portal_engine"),
           FileManager.default.isExecutableFile(atPath: bundleEngine.path) {
            return bundleEngine
        }
        return appSupportEngine
    }

    private init() {
        bootstrapSupportDirectory()
        loadConfig()
        detectInterfaces()
        appendLog("[Portal-High-Bitrate] 已就绪 (v\(AppEnvironmentInfo.version) · \(AppEnvironmentInfo.architectureDescription))")
    }

    // MARK: - 启动与持久化

    private func bootstrapSupportDirectory() {
        let fm = FileManager.default
        let dir = supportDirectoryURL
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let bundleEngine = Bundle.main.resourceURL?.appendingPathComponent("portal_engine"),
           fm.fileExists(atPath: bundleEngine.path) {
            let dst = dir.appendingPathComponent("portal_engine")
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: bundleEngine, to: dst)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }
    }

    public func loadConfig() {
        guard let data = try? Data(contentsOf: configFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let b = json["targetBitrate"] as? String,
           let matched = BitrateProfile.allCases.first(where: { $0.shortTag == b || $0.rawValue.contains(b) }) {
            self.targetBitrate = matched
        }
        let isManualInterface = (json["interfaceManualSelection"] as? Bool) ?? false
        if isManualInterface, let iface = json["interface"] as? String, !iface.isEmpty {
            self.selectedInterface = iface
            self.hasExplicitInterfaceConfig = true
        } else {
            self.hasExplicitInterfaceConfig = false
        }
        if let ps5 = json["ps5IP"] as? String, !ps5.isEmpty {
            self.ps5IP = ps5
        }
        if let portal = json["portalIP"] as? String, !portal.isEmpty {
            self.portalIP = portal
        }
        if let adm = json["runWithAdmin"] as? Bool {
            self.runWithAdmin = adm
        }
    }

    public func saveConfig() {
        let dict: [String: Any] = [
            "targetBitrate": targetBitrate.shortTag,
            "interface": selectedInterface,
            "interfaceManualSelection": hasExplicitInterfaceConfig,
            "ps5IP": ps5IP,
            "portalIP": portalIP,
            "runWithAdmin": runWithAdmin
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: configFileURL)
        }
    }

    // MARK: - 网络接口与局域网设备探测

    public func selectInterface(_ name: String) {
        selectedInterface = name
        hasExplicitInterfaceConfig = true
        saveConfig()
    }

    public func detectInterfaces() {
        let (list, defaultIface) = ActiveInterfaceInfo.discoverActive()
        self.activeInterfaces = list.isEmpty
            ? [ActiveInterfaceInfo(name: defaultIface.isEmpty ? "en0" : defaultIface, ip: "", label: "未检测到活跃 IP")]
            : list

        let isSelectedActive = list.contains(where: { $0.name == selectedInterface })
        if !hasExplicitInterfaceConfig || !isSelectedActive {
            if !defaultIface.isEmpty && list.contains(where: { $0.name == defaultIface }) {
                selectedInterface = defaultIface
            } else if let firstActive = list.first {
                selectedInterface = firstActive.name
            } else {
                selectedInterface = defaultIface.isEmpty ? "en0" : defaultIface
            }
        }
    }

    public func scanLocalDevices() {
        guard !isScanningDevices else { return }
        detectInterfaces()
        self.isScanningDevices = true
        self.appendLog("[扫描] 正在探测局域网活动设备 (ARP 表与常见网段探活)...")

        let currentPS5 = self.ps5IP
        let currentPortal = self.portalIP
        let localIP = self.selectedInterfaceInfo?.ip ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var hostsToProbe: [String] = []
            if !currentPS5.isEmpty { hostsToProbe.append(currentPS5) }
            if !currentPortal.isEmpty { hostsToProbe.append(currentPortal) }

            let (gateway, _) = ActiveInterfaceInfo.detectGatewayAndInterface()
            if !gateway.isEmpty { hostsToProbe.append(gateway) }

            if !localIP.isEmpty {
                let parts = localIP.split(separator: ".")
                if parts.count == 4 {
                    let subnet = "\(parts[0]).\(parts[1]).\(parts[2])"
                    // 并发轻量探测当前网段常见地址段以刷新 ARP 表
                    for hostIdx in 1...254 {
                        let candidate = "\(subnet).\(hostIdx)"
                        if candidate != localIP {
                            hostsToProbe.append(candidate)
                        }
                    }
                }
            }

            let uniqueHosts = Array(Set(hostsToProbe))
            let group = DispatchGroup()
            let sem = DispatchSemaphore(value: 48)
            for host in uniqueHosts {
                group.enter()
                sem.wait()
                DispatchQueue.global(qos: .utility).async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/sbin/ping")
                    p.arguments = ["-c", "1", "-W", "120", host]
                    p.standardOutput = Pipe()
                    p.standardError = Pipe()
                    try? p.run()
                    p.waitUntilExit()
                    sem.signal()
                    group.leave()
                }
            }
            group.wait()

            var results: [DiscoveredDevice] = []
            var seen = Set<String>()
            let arpCommands = [
                ["/usr/sbin/arp", "-a", "-n"],
                ["/usr/sbin/arp", "-a"]
            ]
            for cmd in arpCommands {
                if !results.isEmpty { break }
                let task = Process()
                task.executableURL = URL(fileURLWithPath: cmd[0])
                task.arguments = Array(cmd.dropFirst())
                let p = Pipe()
                task.standardOutput = p
                task.standardError = Pipe()
                if (try? task.run()) != nil {
                    let d = p.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    if let text = String(data: d, encoding: .utf8), !text.isEmpty {
                        results.append(contentsOf: Self.parseARPOutput(text, gatewayIP: gateway, seen: &seen))
                    }
                }
            }

            results.sort { a, b in
                if a.isLikelySony != b.isLikelySony { return a.isLikelySony && !b.isLikelySony }
                return a.ip < b.ip
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isScanningDevices = false
                self.discoveredDevices = results
                self.appendLog("[扫描] 发现 \(results.count) 个活跃节点。")
                for dev in results where dev.isLikelySony {
                    self.appendLog("  • \(dev.label): \(dev.ip) [MAC: \(dev.mac)]")
                }
            }
        }
    }

    nonisolated private static func parseARPOutput(_ output: String, gatewayIP: String, seen: inout Set<String>) -> [DiscoveredDevice] {
        var found: [DiscoveredDevice] = []
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            guard let start = line.range(of: "("),
                  let end = line.range(of: ")"),
                  start.upperBound < end.lowerBound else { continue }
            let ip = String(line[start.upperBound..<end.lowerBound])
            guard !ip.isEmpty, ip != "127.0.0.1", ip != gatewayIP,
                  !ip.hasSuffix(".255"), !ip.hasPrefix("224."), !ip.hasPrefix("239."),
                  !seen.contains(ip) else { continue }

            var mac = ""
            if let atRange = line.range(of: " at ") {
                let sub = line[atRange.upperBound...]
                let parts = sub.split(separator: " ")
                if let first = parts.first {
                    let rawMac = String(first)
                    if rawMac != "(incomplete)" && rawMac != "ff:ff:ff:ff:ff:ff" {
                        mac = normalizeMAC(rawMac)
                    }
                }
            }
            guard !mac.isEmpty else { continue }
            seen.insert(ip)

            let isSony = isSonyOUI(mac)
            let label = isSony ? "Sony / PlayStation" : "局域网设备"
            found.append(DiscoveredDevice(id: ip, ip: ip, mac: mac, isLikelySony: isSony, label: label))
        }
        return found
    }

    nonisolated private static func normalizeMAC(_ raw: String) -> String {
        raw.split(separator: ":").map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":").lowercased()
    }

    nonisolated private static func isSonyOUI(_ mac: String) -> Bool {
        let oui = String(mac.prefix(8))
        let sonyOUIs: Set<String> = [
            "00:04:1f", "00:13:15", "00:15:c1", "00:19:c5", "00:1d:0d",
            "00:1f:a7", "00:24:8d", "00:d9:d1", "00:e4:21", "28:0d:fc",
            "2c:cc:44", "40:16:7e", "70:9e:29", "78:c8:81", "84:20:96",
            "a8:e3:ee", "bc:60:a7", "c8:63:f1", "d4:4b:5e", "e8:9e:b4",
            "f8:46:1c", "fc:0f:e6", "b4:0a:d8", "30:e1:71", "54:42:49"
        ]
        return sonyOUIs.contains(oui)
    }

    // MARK: - 倒计时与日志监听

    private func startListenCountdown(seconds: Int = 120) {
        listenCountdownTimer?.invalidate()
        listenDeadline = Date().addingTimeInterval(TimeInterval(seconds))
        listenRemainingSeconds = seconds

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isListening, let deadline = self.listenDeadline else {
                    self?.stopListenCountdown()
                    return
                }
                let rem = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                if rem != self.listenRemainingSeconds {
                    self.listenRemainingSeconds = rem
                }
                if rem <= 0 {
                    self.stopListenCountdown()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        listenCountdownTimer = timer
    }

    private func stopListenCountdown() {
        listenCountdownTimer?.invalidate()
        listenCountdownTimer = nil
        listenDeadline = nil
        listenRemainingSeconds = nil
    }

    // MARK: - 中继启停

    public func startRelay() {
        guard !isRunning else { return }
        lastError = nil

        let trimmedPS5 = ps5IP.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPortal = portalIP.trimmingCharacters(in: .whitespacesAndNewlines)
        ps5IP = trimmedPS5
        portalIP = trimmedPortal

        guard !trimmedPS5.isEmpty, !trimmedPortal.isEmpty else {
            lastError = "请先填写 PS5 IP 与 PS Portal IP（或点击上方“扫描局域网设备”快速填入）。"
            appendLog("[错误] \(lastError!)")
            return
        }
        saveConfig()

        let engine = engineFileURL.path
        guard FileManager.default.isExecutableFile(atPath: engine) else {
            lastError = "未找到原生中继引擎: portal_engine"
            appendLog("[错误] \(lastError!)")
            return
        }

        isRunning = true
        isListening = true
        isStreamActive = false

        appendLog("[Portal-High-Bitrate] 启动 PS Portal 串流画质增强 (Universal Native BPF)...")
        appendLog("[配置] 目标码率: \(targetBitrate.rawValue) | 网卡: \(selectedInterface)")
        appendLog("[配置] PS5: \(ps5IP) | PS Portal: \(portalIP)")

        if runWithAdmin {
            startPrivilegedRelay(engine: engine)
        } else {
            startStandardRelay(engine: engine)
        }
    }

    private func startPrivilegedRelay(engine: String) {
        try? "".write(toFile: logFilePath, atomically: true, encoding: .utf8)
        lastLogOffset = 0

        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        checkProcess.arguments = ["-n", engine, "--check-privilege"]
        let isPasswordless: Bool = (try? checkProcess.run()) != nil && {
            checkProcess.waitUntilExit()
            return checkProcess.terminationStatus == 0
        }()

        if isPasswordless {
            appendLog("[Portal-High-Bitrate] ⚡️ 检测到系统免密特权已激活，正在静默秒启原生 BPF 注入引擎...")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            proc.arguments = [
                "-n", engine,
                "--interface", selectedInterface,
                "--bitrate", targetBitrate.shortTag,
                "--ps5", ps5IP,
                "--portal", portalIP
            ]

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            self.outputPipe = pipe
            self.relayProcess = proc

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                let lines = str.components(separatedBy: .newlines).filter { !$0.isEmpty }
                DispatchQueue.main.async {
                    for line in lines {
                        self?.appendLog(line)
                        self?.evaluateProcessOutput(line)
                    }
                }
            }

            proc.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                    self.outputPipe = nil
                    if self.isRunning {
                        self.isRunning = false
                        self.isListening = false
                        self.stopListenCountdown()
                        self.appendLog("[Portal-High-Bitrate] 引擎进程已结束 (状态码: \(process.terminationStatus))。")
                    }
                }
            }

            do {
                try proc.run()
                return
            } catch {
                appendLog("[提示] 免密进程启动受限，尝试常规特权引导...")
            }
        }

        appendLog("[Portal-High-Bitrate] 正在申请 macOS 管理员特权并写入永久免密规则...")
        let cmd = "'\(engine)' --install-sudoers >/dev/null 2>&1 || true; '\(engine)' --interface '\(selectedInterface)' --bitrate '\(targetBitrate.shortTag)' --ps5 '\(ps5IP)' --portal '\(portalIP)' > '\(logFilePath)' 2>&1 & echo $! > '\(pidFilePath)'"
        let appleScript = "do shell script \"\(cmd)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var errorDict: NSDictionary?
            let scriptObj = NSAppleScript(source: appleScript)
            scriptObj?.executeAndReturnError(&errorDict)

            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = errorDict {
                    let errMsg = err[NSAppleScript.errorMessage] as? String ?? "用户取消授权"
                    self.appendLog("[提示] 特权授权未完成: \(errMsg)")
                    self.appendLog("[降级] 正在以非特权模式尝试启动...")
                    self.startStandardRelay(engine: engine)
                } else {
                    self.appendLog("[Portal-High-Bitrate] ✅ 管理员特权中继已在后台激活 (已建立免密通道)。")
                    self.startTailingLogFile()
                }
            }
        }
    }

    private func startStandardRelay(engine: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: engine)
        proc.arguments = [
            "--interface", selectedInterface,
            "--bitrate", targetBitrate.shortTag,
            "--ps5", ps5IP,
            "--portal", portalIP
        ]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        self.outputPipe = pipe
        self.relayProcess = proc

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let lines = str.components(separatedBy: .newlines).filter { !$0.isEmpty }
            DispatchQueue.main.async {
                for line in lines {
                    self?.appendLog(line)
                    self?.evaluateProcessOutput(line)
                }
            }
        }

        proc.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.outputPipe = nil
                if self.isRunning {
                    self.isRunning = false
                    self.isListening = false
                    self.stopListenCountdown()
                    self.appendLog("[Portal-High-Bitrate] 引擎进程已结束 (状态码: \(process.terminationStatus))。")
                }
            }
        }

        do {
            try proc.run()
        } catch {
            isRunning = false
            isListening = false
            stopListenCountdown()
            lastError = "启动原生引擎失败: \(error.localizedDescription)"
            appendLog("[错误] \(lastError!)")
        }
    }

    private func startTailingLogFile() {
        logWatchTimer?.invalidate()
        logWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.readNewLogBytes()
            }
        }
    }

    private func readNewLogBytes() {
        guard let handle = FileHandle(forReadingAtPath: logFilePath) else { return }
        defer { try? handle.close() }
        handle.seek(toFileOffset: lastLogOffset)
        let data = handle.readDataToEndOfFile()
        if !data.isEmpty {
            lastLogOffset += UInt64(data.count)
            if let str = String(data: data, encoding: .utf8) {
                let lines = str.components(separatedBy: .newlines).filter { !$0.isEmpty }
                for line in lines {
                    appendLog(line)
                    evaluateProcessOutput(line)
                }
            }
        }
    }

    public func stopRelay() {
        guard isRunning else { return }
        appendLog("[Portal-High-Bitrate] 正在停止监听与中继...")

        logWatchTimer?.invalidate()
        logWatchTimer = nil
        stopListenCountdown()

        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil

        let engine = engineFileURL.path
        if FileManager.default.isExecutableFile(atPath: engine) {
            DispatchQueue.global(qos: .userInitiated).async {
                let stopProc = Process()
                stopProc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                stopProc.arguments = ["-n", engine, "--stop"]
                stopProc.standardOutput = Pipe()
                stopProc.standardError = Pipe()
                try? stopProc.run()
                stopProc.waitUntilExit()
            }
        }
        if let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr), pid > 0 {
            kill(pid, SIGINT)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
                kill(pid, SIGTERM)
                try? FileManager.default.removeItem(atPath: self.pidFilePath)
            }
        }

        if let proc = relayProcess, proc.isRunning {
            proc.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
                if proc.isRunning { proc.terminate() }
            }
        }
        relayProcess = nil
        isRunning = false
        isListening = false
        appendLog("[Portal-High-Bitrate] 已停止，网络路由恢复直连。")
    }

    private func evaluateProcessOutput(_ line: String) {
        if line.contains("网络协商就绪") || line.contains("READY: connect Portal") {
            isListening = true
            isStreamActive = false
            startListenCountdown(seconds: 120)
        } else if line.contains("PS5 reported high target bitrate") || line.contains("Target confirmed") || line.contains("[ACCEPTED]") || line.contains("已确认并接受高码率协商") {
            isStreamActive = true
            isListening = false
            stopListenCountdown()
            scheduleRelayReset(after: 1.5)
        } else if line.contains("未生效") || line.contains("未检测到 PS Portal 握手请求") || line.contains("NOT APPLIED") {
            isListening = false
            isStreamActive = false
            stopListenCountdown()
            lastError = "未检测到 PS Portal 握手请求（120 秒内未收到连接，或 Portal 仍处于休眠状态）。"
            scheduleRelayReset(after: 0.8)
        } else if line.contains("未确认目标码率") || line.contains("UNCONFIRMED") {
            isListening = false
            isStreamActive = false
            stopListenCountdown()
            lastError = "握手修改已发送，但未能在规定时间内检测到 PS5 连续 3 次高码率遥测确认。"
            scheduleRelayReset(after: 0.8)
        } else if line.contains("RESTORATION FAILED") || line.contains("路由恢复异常") {
            isListening = false
            stopListenCountdown()
            lastError = "网络恢复异常，请检查网络配置。"
            scheduleRelayReset(after: 0.8)
        } else if line.contains("引擎模式:") {
            scheduleRelayReset(after: 1.0)
        }
    }

    private func scheduleRelayReset(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.isRunning = false
            self.isListening = false
            self.stopListenCountdown()
            self.relayProcess = nil
            self.logWatchTimer?.invalidate()
            self.logWatchTimer = nil
        }
    }

    public func appendLog(_ text: String) {
        logs.append(text)
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    public func clearLogs() {
        logs.removeAll()
    }

    public func copyLogs() {
        let content = logs.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }
}
