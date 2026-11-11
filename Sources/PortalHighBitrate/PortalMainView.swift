import SwiftUI
import AppKit

public enum AppTab: String, CaseIterable, Identifiable {
    case booster = "串流增强"
    case about = "关于应用"

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

    @Namespace private var tabAnimation

    public init(selectedTab: Binding<AppTab>) {
        self._selectedTab = selectedTab
    }

    public var body: some View {
        GeometryReader { geo in
            let logicalW = max(1200, geo.size.width)
            let logicalH = max(822, geo.size.height)
            let contentW = max(1152, logicalW - 48)
            let contentH = max(684, logicalH - 79 - 59)

            VStack(spacing: 0) {
                // 顶部导航栏 (对齐 SysPulse 44pt + top 35pt = 79pt 无标题栏居中流体玻璃胶囊)
                topNavigationBar

                ZStack(alignment: .top) {
                    if selectedTab == .about {
                        AboutPortalView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        boosterWorkstation(contentW: contentW, contentH: contentH)
                            .padding(.horizontal, 24)
                            .padding(.top, 35)
                            .padding(.bottom, 24)
                    }
                }
                .frame(width: logicalW, height: logicalH - 79, alignment: .top)
            }
            .frame(width: logicalW, height: logicalH, alignment: .top)
            .ignoresSafeArea(edges: .top)
        }
        .ignoresSafeArea()
        .background(
            colorScheme == .dark
                ? Color(red: 0.08, green: 0.09, blue: 0.12)
                : Color(red: 0.96, green: 0.97, blue: 0.985)
        )
        .onAppear {
            DispatchQueue.main.async {
                manager.detectInterfaces()
                if manager.discoveredDevices.isEmpty && !manager.isScanningDevices {
                    manager.scanLocalDevices()
                }
            }
        }
    }

    private var topNavigationBar: some View {
        ZStack {
            HStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
                    PortalAppIconView(size: 28)
                }
                .frame(width: 32, height: 32)
                .padding(.leading, 3)

                Spacer().frame(width: 14)

                HStack(spacing: 6) {
                    ForEach(AppTab.allCases) { tab in
                        let isActive = selectedTab == tab
                        Button {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                                selectedTab = tab
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 14, weight: isActive ? .bold : .medium, design: .rounded))
                                .foregroundStyle(
                                    isActive
                                        ? (colorScheme == .dark ? Color.white : Color.black.opacity(0.88))
                                        : primaryText.opacity(0.78)
                                )
                                .frame(width: 92, height: 36)
                                .background {
                                    if isActive {
                                        Capsule(style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        Color.white.opacity(colorScheme == .dark ? 0.28 : 0.92),
                                                        Color.white.opacity(colorScheme == .dark ? 0.12 : 0.72)
                                                    ],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                            .overlay(
                                                Capsule(style: .continuous)
                                                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.42 : 0.85), lineWidth: 0.8)
                                            )
                                            .matchedGeometryEffect(id: "portal_selected_tab", in: tabAnimation)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
                .padding(.trailing, 2)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.24 : 0.65), lineWidth: 0.8)
                    )
                    .shadow(
                        color: colorScheme == .dark ? Color.black.opacity(0.35) : Color.black.opacity(0.08),
                        radius: 12,
                        x: 0,
                        y: 4
                    )
            )

            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("v\(manager.pluginVersion) · \(AppEnvironmentInfo.architectureDescription)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(cardFill)
                        .overlay(Capsule().strokeBorder(cardBorder, lineWidth: 0.6))
                )
                .padding(.trailing, 24)
            }
        }
        .frame(height: 44)
        .padding(.top, 35)
        .padding(.horizontal, 8)
    }

    private func boosterWorkstation(contentW: CGFloat, contentH: CGFloat) -> some View {
        VStack(spacing: 12) {
            pluginActionToolbar
                .frame(width: contentW)

            VStack(spacing: 14) {
                mainControlCard
                    .frame(width: contentW)
                liveLogCard
                    .frame(width: contentW)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: contentW, height: contentH)
    }

    private var pluginActionToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(manager.isStreamActive ? Color.green : (manager.isListening ? Color.orange : Color.blue))
                    .frame(width: 7, height: 7)
                if let updateMsg = manager.updateStatusMessage, !updateMsg.isEmpty {
                    Text(updateMsg)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(secondaryText)
                } else {
                    Text("本地已验证基线 [\(manager.installedCommitSHA)] · \(manager.installedCommitDate)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(secondaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(cardFill)
                    .overlay(Capsule().strokeBorder(cardBorder, lineWidth: 0.8))
            )

            Spacer()

            toolbarActionButton(
                icon: manager.isCheckingForUpdates ? "arrow.triangle.2.circlepath" : "arrow.down.circle",
                title: manager.isCheckingForUpdates ? "检查中..." : "检查插件更新",
                helpText: "检查 atameric/ps5-portal-high-bitrate 远端最新提交与更新",
                disabled: manager.isCheckingForUpdates
            ) {
                manager.checkForPluginUpdates()
            }

            toolbarActionButton(
                icon: "folder.fill",
                title: "打开插件目录",
                helpText: "打开 ~/Library/Application Support/Portal-High-Bitrate"
            ) {
                manager.openPluginFolder()
            }

            toolbarActionButton(
                icon: "arrow.clockwise",
                title: "重新载入插件",
                helpText: "重新读取 manifest.json 与 config.json"
            ) {
                manager.reloadPlugin()
            }
        }
    }

    private func toolbarActionButton(
        icon: String,
        title: String,
        helpText: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(cardFill)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(cardBorder, lineWidth: 0.8))
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(disabled)
        .help(helpText)
    }

    private var mainControlCard: some View {
        VStack(spacing: 16) {
            // 顶部信息与启停按钮
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.85), Color.indigo.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 54, height: 54)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                        )

                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("PS Portal 串流画质增强")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(primaryText)

                        Text("v\(manager.pluginVersion)")
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
                        Text("开源项目:")
                            .font(.system(size: 12))
                            .foregroundStyle(secondaryText)

                        Button {
                            if let url = URL(string: manager.pluginRepo) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("atameric/ps5-portal-high-bitrate")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.cyan)
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.cyan)
                            }
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()

                        Text("· 无需硬改与越狱，动态协议修改提升比特率")
                            .font(.system(size: 12))
                            .foregroundStyle(secondaryText)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.blue)
                        Text("管理员特权注入 (真实 ARP 伪装与比特率修改，首次授权后自动免密)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(primaryText.opacity(0.9))
                    }
                    .padding(.top, 2)
                }

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        manager.restoreNetworkDirect()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.uturn.backward.circle")
                                .font(.system(size: 12))
                            Text("恢复直连")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(cardFill)
                                .overlay(Capsule().strokeBorder(cardBorder, lineWidth: 0.8))
                        )
                        .foregroundStyle(secondaryText)
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    .disabled(manager.isRunning || manager.isStopping)
                    .help("异常退出后若设备无法连接，点此立即清理 ARP 缓存并恢复直连")

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
                            Text(manager.isStopping ? "停止中..." : (manager.isRunning ? "停止增强" : "启动画质增强"))
                                .font(.system(size: 14, weight: .bold))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(
                                    manager.isRunning
                                        ? Color.red.opacity(manager.isStopping ? 0.5 : 0.88)
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
                    .disabled(manager.isStopping)
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
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("目标比特率 (Target Bitrate)")
                        .font(.system(size: 13, weight: .semibold))
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
                                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
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
                                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : secondaryText)
                                        .lineLimit(2)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(isSelected ? Color.blue.opacity(0.85) : cardFill)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(isSelected ? Color.blue : cardBorder, lineWidth: 0.8)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .disabled(manager.isRunning)
                        }
                    }

                    // 中继模式切换 (方案 A 单向直连 vs 方案 B 双向遥测)
                    HStack(spacing: 8) {
                        Text("中继模式:")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(secondaryText)

                        HStack(spacing: 4) {
                            ForEach(PortalRelayMode.allCases) { mode in
                                let isModeActive = manager.relayMode == mode
                                Button {
                                    manager.relayMode = mode
                                    manager.saveConfig()
                                } label: {
                                    Text(mode.title)
                                        .font(.system(size: 11, weight: isModeActive ? .semibold : .medium))
                                        .foregroundStyle(isModeActive ? Color.white : secondaryText)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule()
                                                .fill(isModeActive ? Color.blue.opacity(0.85) : Color.clear)
                                        )
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                .help(mode.subtitle)
                            }
                        }
                        .padding(3)
                        .background(
                            Capsule()
                                .fill(cardFill)
                                .overlay(Capsule().strokeBorder(cardBorder, lineWidth: 0.8))
                        )
                        .disabled(manager.isRunning)

                        Text(manager.relayMode.subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(secondaryText.opacity(0.85))
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("网络参数与设备 IP")
                            .font(.system(size: 13, weight: .semibold))
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
                        .pointingHandCursor()
                        .disabled(manager.isScanningDevices)
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("网卡接口")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(secondaryText)
                            interfaceMenu
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "tv.fill")
                                    .font(.system(size: 11))
                                Text("PS5 IP (必填)")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.blue)

                            TextField("例如 192.168.50.50", text: $manager.ps5IP)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.blue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8.5)
                                .frame(minHeight: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.blue.opacity(colorScheme == .dark ? 0.12 : 0.08))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue.opacity(0.35), lineWidth: 0.8))
                                )
                                .disabled(manager.isRunning)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.system(size: 11))
                                Text("PS Portal IP (必填)")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.indigo)

                            TextField("例如 192.168.50.107", text: $manager.portalIP)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.indigo)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8.5)
                                .frame(minHeight: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.indigo.opacity(colorScheme == .dark ? 0.12 : 0.08))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.indigo.opacity(0.35), lineWidth: 0.8))
                                )
                                .disabled(manager.isRunning)
                        }
                    }

                    // 扫描到的 Sony 设备快捷填入条（保持固定最低高度，确保与左侧底部间距一致）
                    let sonyDevices = manager.discoveredDevices.filter { $0.isLikelySony }
                    Group {
                        if !sonyDevices.isEmpty {
                            HStack(spacing: 8) {
                                Text("检测到 Sony 设备:")
                                    .font(.system(size: 11.5, weight: .medium))
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
                                                let isPS5Role = dev.role == .ps5Host
                                                let roleTag = isPS5Role ? "PS5" : (dev.role == .portalClient ? "Portal" : "Sony")
                                                let iconName = isPS5Role ? "tv.fill" : "gamecontroller.fill"
                                                let tintColor: Color = isPS5Role ? .blue : .indigo
                                                HStack(spacing: 4.5) {
                                                    Image(systemName: iconName)
                                                        .font(.system(size: 10.5))
                                                    Text("\(roleTag) · \(dev.ip)")
                                                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                                }
                                                .foregroundStyle(tintColor)
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 4)
                                                .background(
                                                    Capsule()
                                                        .fill(tintColor.opacity(0.12))
                                                        .overlay(Capsule().strokeBorder(tintColor.opacity(0.3), lineWidth: 0.8))
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(manager.isRunning || manager.isStopping)
                                        }
                                    }
                                }
                            }
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 11))
                                Text("点击右上角「扫描局域网设备」可自动识别 PS5 / Portal IP")
                                    .font(.system(size: 11.5))
                            }
                            .foregroundStyle(secondaryText.opacity(0.75))
                        }
                    }
                    .frame(minHeight: 28, alignment: .leading)
                    .padding(.top, 2)
                }
                .frame(width: 530)
            }
        }
        .padding(18)
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
                    .frame(width: 7, height: 7)
                Text(currentInfo?.compactDisplayName ?? manager.selectedInterface)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(secondaryText)
            }
            .foregroundStyle(primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8.5)
            .frame(width: 190)
            .frame(minHeight: 38)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(cardFill)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(cardBorder, lineWidth: 0.8))
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
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

                HStack(spacing: 8) {
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
                    .pointingHandCursor()

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
                    .pointingHandCursor()
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        if manager.logs.isEmpty {
                            Text("等待插件执行，日志输出将实时显示于此...")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .padding(.vertical, 8)
                        } else {
                            let activeReadyId = manager.logs.last(where: { $0.text.hasPrefix("[准备] ⚡️ 网络协商就绪") })?.id
                            ForEach(manager.logs) { entry in
                                let displayLine: String = {
                                    if manager.isListening,
                                       entry.id == activeReadyId,
                                       let remaining = manager.listenRemainingSeconds {
                                        return "[准备] ⚡️ 网络协商就绪！请在 \(remaining) 秒内在 PS Portal 上点击连接 PS5..."
                                    }
                                    return entry.text
                                }()
                                Text(displayLine)
                                    .font(.system(size: 12, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(logColor(for: displayLine))
                                    .textSelection(.enabled)
                                    .id(entry.id)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                }
                .onChange(of: manager.logs.last?.id) { lastId in
                    if let lastId {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
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
        if line.contains("[成功]") || line.contains("[ACCEPTED]") || line.contains("[ACTIVE]") || line.contains("[SUCCESS]") || line.contains("🎉") || line.contains("✅") || line.contains("Quality Confirmed") {
            return Color.green
        }
        if line.contains("[注入]") || line.contains("[响应]") || line.contains("[路由]") || line.contains("[识别]") || line.contains("[说明]") || line.contains("[PATCH]") || line.contains("[FORWARD]") || line.contains("🚀") || line.contains("🎯") {
            return Color.cyan
        }
        if line.contains("[警告]") || line.contains("[准备]") || line.contains("[诊断]") || line.contains("[提示]") || line.contains("[更新]") || line.contains("[WARNING]") || line.contains("[WAITING]") || line.contains("⚡️") || line.contains("⚠️") || line.contains("💡") {
            return Color.yellow
        }
        if line.contains("[错误]") || line.contains("[失败]") || line.contains("[ERROR]") || line.contains("❌") || line.contains("UNCONFIRMED") || line.contains("NOT APPLIED") {
            return Color.red
        }
        return Color.white.opacity(0.92)
    }
}

private extension View {
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
