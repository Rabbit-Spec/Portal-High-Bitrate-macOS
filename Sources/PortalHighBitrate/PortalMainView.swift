import SwiftUI
import AppKit

public enum AppTab: String, CaseIterable, Identifiable {
    case booster = "串流增强"
    case about = "关于 Portal-High-Bitrate"

    public var id: String { rawValue }
}

public struct PortalMainView: View {
    @ObservedObject private var manager = PortalRelayManager.shared
    @Binding var selectedTab: AppTab
    @Environment(\.colorScheme) private var colorScheme

    private var primaryText: Color {
        colorScheme == .dark ? .white : Color(white: 0.12)
    }

    private var secondaryText: Color {
        colorScheme == .dark ? Color.white.opacity(0.68) : Color(white: 0.42)
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.03)
    }

    private var cardBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.10)
    }

    public init(selectedTab: Binding<AppTab>) {
        self._selectedTab = selectedTab
    }

    public var body: some View {
        VStack(spacing: 14) {
            // 顶部导航栏
            HStack {
                HStack(spacing: 10) {
                    PortalAppIconView(size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Portal-High-Bitrate")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(primaryText)
                        Text("PS Portal 高码率局域网注入独立版 · \(AppEnvironmentInfo.architectureDescription)")
                            .font(.system(size: 11))
                            .foregroundStyle(secondaryText)
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    ForEach(AppTab.allCases) { tab in
                        let isActive = selectedTab == tab
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                selectedTab = tab
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                                .foregroundStyle(isActive ? Color.white : secondaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(isActive ? Color.blue : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                }
                .padding(3)
                .background(
                    Capsule()
                        .fill(cardFill)
                        .overlay(Capsule().strokeBorder(cardBorder, lineWidth: 0.8))
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            if selectedTab == .about {
                AboutPortalView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                boosterWorkstation
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }
        }
        .background(
            colorScheme == .dark
                ? Color(red: 0.08, green: 0.09, blue: 0.12)
                : Color(red: 0.96, green: 0.97, blue: 0.985)
        )
        .onAppear {
            manager.detectInterfaces()
        }
    }

    private var boosterWorkstation: some View {
        VStack(spacing: 14) {
            mainControlCard
            liveLogCard
        }
    }

    private var mainControlCard: some View {
        VStack(spacing: 14) {
            // 顶部信息与启停按钮
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("PS Portal 串流画质增强")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(primaryText)

                        Text("v\(AppEnvironmentInfo.version)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.14)))

                        if manager.isListening {
                            statusBadgeView
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.blue)
                        Toggle("使用管理员权限启动 /dev/bpf 原生中继（首次授权后后续自动免密）", isOn: $manager.runWithAdmin)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11.5))
                            .foregroundStyle(secondaryText)
                            .disabled(manager.isRunning)
                    }
                }

                Spacer()

                Button {
                    if manager.isRunning {
                        manager.stopRelay()
                    } else {
                        manager.startRelay()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: manager.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text(manager.isRunning ? "停止增强" : "启动画质增强")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(
                                manager.isRunning
                                    ? Color.red.opacity(0.88)
                                    : (colorScheme == .dark ? Color.white : Color(white: 0.14))
                            )
                    )
                    .foregroundStyle(
                        manager.isRunning
                            ? Color.white
                            : (colorScheme == .dark ? Color.black : Color.white)
                    )
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }

            if let errorText = manager.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                    Text(errorText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(primaryText)
                    Spacer()
                    Button {
                        manager.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(secondaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(colorScheme == .dark ? 0.14 : 0.10))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.8))
                )
            }

            Divider().opacity(0.25)

            // 码率与网络参数
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("目标比特率 (Target Bitrate)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(primaryText)

                    HStack(spacing: 8) {
                        ForEach(BitrateProfile.allCases) { profile in
                            let isSelected = manager.targetBitrate == profile
                            Button {
                                manager.targetBitrate = profile
                                manager.saveConfig()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(profile.rawValue)
                                            .font(.system(size: 12.5, weight: isSelected ? .bold : .medium))
                                            .foregroundStyle(isSelected ? Color.white : primaryText)
                                        Spacer()
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 12))
                                                .foregroundStyle(Color.white)
                                        }
                                    }
                                    Text(profile.description)
                                        .font(.system(size: 10))
                                        .foregroundStyle(isSelected ? Color.white.opacity(0.86) : secondaryText)
                                        .lineLimit(2)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(isSelected ? Color.blue.opacity(0.88) : cardFill)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(isSelected ? Color.blue : cardBorder, lineWidth: 0.8)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(manager.isRunning)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("网络参数与设备 IP")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(primaryText)
                        Spacer()
                        Button {
                            manager.scanLocalDevices()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: manager.isScanningDevices ? "arrow.triangle.2.circlepath" : "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 11))
                                Text(manager.isScanningDevices ? "扫描中..." : "扫描局域网设备")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Color.blue)
                        }
                        .buttonStyle(.plain)
                        .disabled(manager.isScanningDevices)
                    }

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("网卡接口")
                                .font(.system(size: 11))
                                .foregroundStyle(secondaryText)
                            interfaceMenu
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "tv.fill")
                                    .font(.system(size: 10))
                                Text("PS5 IP (必填)")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(Color.blue)

                            TextField("例如 192.168.50.50", text: $manager.ps5IP)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.blue)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.blue.opacity(colorScheme == .dark ? 0.12 : 0.08))
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.blue.opacity(0.35), lineWidth: 0.8))
                                )
                                .disabled(manager.isRunning)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.system(size: 10))
                                Text("PS Portal IP (必填)")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(Color.indigo)

                            TextField("例如 192.168.50.107", text: $manager.portalIP)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.indigo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.indigo.opacity(colorScheme == .dark ? 0.12 : 0.08))
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.indigo.opacity(0.35), lineWidth: 0.8))
                                )
                                .disabled(manager.isRunning)
                        }
                    }
                }
                .frame(width: 490)
            }

            // 如果扫描到了索尼设备，展示快捷一键填入条
            let sonyDevices = manager.discoveredDevices.filter { $0.isLikelySony }
            if !sonyDevices.isEmpty {
                HStack(spacing: 8) {
                    Text("检测到 Sony 设备（点击填入）：")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryText)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(sonyDevices) { dev in
                                Menu {
                                    Button("设为 PS5 IP (\(dev.ip))") {
                                        manager.ps5IP = dev.ip
                                        manager.saveConfig()
                                    }
                                    Button("设为 PS Portal IP (\(dev.ip))") {
                                        manager.portalIP = dev.ip
                                        manager.saveConfig()
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "playstation.logo")
                                            .font(.system(size: 10))
                                        Text("\(dev.ip)")
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    }
                                    .foregroundStyle(Color.blue)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(Color.blue.opacity(0.12))
                                            .overlay(Capsule().strokeBorder(Color.blue.opacity(0.3), lineWidth: 0.8))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardFill)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(cardBorder, lineWidth: 0.8))
        )
    }

    private var interfaceMenu: some View {
        let currentInfo = manager.selectedInterfaceInfo
        let hasIP = !(currentInfo?.ip ?? "").isEmpty
        return Menu {
            ForEach(manager.activeInterfaces) { iface in
                Button {
                    manager.selectInterface(iface.name)
                } label: {
                    if manager.selectedInterface == iface.name {
                        Label(iface.displayName, systemImage: "checkmark")
                    } else {
                        Text(iface.displayName)
                    }
                }
            }
            Divider()
            Button {
                manager.detectInterfaces()
            } label: {
                Label("重新检测活跃网卡", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(hasIP ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(currentInfo?.compactDisplayName ?? manager.selectedInterface)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(secondaryText)
            }
            .foregroundStyle(primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .frame(width: 170)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(cardFill)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(cardBorder, lineWidth: 0.8))
            )
        }
        .buttonStyle(.plain)
        .disabled(manager.isRunning)
    }

    private var statusBadgeView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
            if let remaining = manager.listenRemainingSeconds {
                Text("正在监听握手 · \(remaining)s")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.orange)
            } else {
                Text("正在准备路径...")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.orange.opacity(0.14)))
    }

    private var liveLogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.green)
                    Text("实时通信与握手遥测")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(primaryText)

                    if manager.isListening {
                        statusBadgeView
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        manager.copyLogs()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                            Text("复制日志")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(secondaryText)
                    }
                    .buttonStyle(.plain)

                    Button {
                        manager.clearLogs()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text("清空")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        if manager.logs.isEmpty {
                            Text("点击「启动画质增强」后，实时握手与流量报告将显示在此处...")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .padding(.vertical, 8)
                        } else {
                            let activeReadyIdx = manager.logs.lastIndex(where: { $0.hasPrefix("[准备] ⚡️ 网络协商就绪") })
                            ForEach(Array(manager.logs.enumerated()), id: \.offset) { idx, line in
                                let displayLine: String = {
                                    if manager.isListening,
                                       idx == activeReadyIdx,
                                       let remaining = manager.listenRemainingSeconds {
                                        return "[准备] ⚡️ 网络协商就绪！请在 \(remaining) 秒内在 PS Portal 上点击连接 PS5..."
                                    }
                                    return line
                                }()
                                Text(displayLine)
                                    .font(.system(size: 12, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(logColor(for: displayLine))
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                }
                .onChange(of: manager.logs.count) { newCount in
                    if newCount > 0 {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(newCount - 1, anchor: .bottom)
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.45 : 0.86))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(cardBorder, lineWidth: 0.8))
            )
        }
        .padding(16)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardFill)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(cardBorder, lineWidth: 0.8))
        )
    }

    private func logColor(for line: String) -> Color {
        if line.contains("[成功]") || line.contains("[ACCEPTED]") || line.contains("🎉") || line.contains("Quality Confirmed") {
            return Color.green
        }
        if line.contains("[注入]") || line.contains("[响应]") || line.contains("🚀") || line.contains("🎯") {
            return Color.cyan
        }
        if line.contains("[警告]") || line.contains("[准备]") || line.contains("⚡️") || line.contains("⚠️") {
            return Color.yellow
        }
        if line.contains("[错误]") || line.contains("[失败]") || line.contains("❌") || line.contains("UNCONFIRMED") || line.contains("NOT APPLIED") {
            return Color.red
        }
        return Color.white.opacity(0.92)
    }
}
