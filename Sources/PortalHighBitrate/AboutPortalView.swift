import SwiftUI
import AppKit

public struct AboutPortalView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var cardFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.035)
    }

    private var cardBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
    }

    private var primaryText: Color {
        colorScheme == .dark ? .white : Color(white: 0.12)
    }

    private var secondaryText: Color {
        colorScheme == .dark ? Color.white.opacity(0.68) : Color(white: 0.42)
    }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PortalAppIconView(size: 88)
                    .padding(.top, 14)

                VStack(spacing: 6) {
                    Text("Portal-High-Bitrate")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(primaryText)

                    Text("专为 macOS 打造的 PS Portal 局域网高码率串流增强独立工具")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(secondaryText)

                    HStack(spacing: 8) {
                        Text("版本 \(AppEnvironmentInfo.version) (Build \(AppEnvironmentInfo.build))")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(secondaryText)

                        Text("Universal · Apple Silicon & Intel")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.blue.opacity(0.14)))
                    }
                    .padding(.top, 2)
                }

                VStack(spacing: 11) {
                    aboutRow(
                        label: "作者",
                        value: "Rabbit-Spec",
                        link: "https://github.com/Rabbit-Spec"
                    )
                    Divider().opacity(0.45)
                    aboutRow(
                        label: "Bilibili 频道",
                        value: "汤圆_Lyric",
                        link: "https://space.bilibili.com/7135720"
                    )
                    Divider().opacity(0.45)
                    aboutRow(
                        label: "SysPulse 主项目",
                        value: "Rabbit-Spec/macOS-SysPulse",
                        link: "https://github.com/Rabbit-Spec/macOS-SysPulse"
                    )
                    Divider().opacity(0.45)
                    aboutRow(
                        label: "核心协议致敬",
                        value: "atameric/ps5-portal-high-bitrate",
                        link: "https://github.com/atameric/ps5-portal-high-bitrate"
                    )
                    Divider().opacity(0.45)
                    aboutRow(
                        label: "当前运行架构",
                        value: "\(AppEnvironmentInfo.architectureDescription) · \(AppEnvironmentInfo.hardwareModel)"
                    )
                    Divider().opacity(0.45)
                    aboutRow(
                        label: "系统版本",
                        value: AppEnvironmentInfo.macOSVersionDescription
                    )
                }
                .padding(18)
                .frame(maxWidth: 540)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(cardBorder, lineWidth: 0.9)
                        )
                )

                Text("© 2026 Rabbit-Spec. All rights reserved.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(secondaryText.opacity(0.85))
                    .padding(.top, 4)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }

    private func aboutRow(label: String, value: String, link: String? = nil) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(secondaryText)
            Spacer()
            if let link, let url = URL(string: link) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Text(value)
                            .underline()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.cyan : Color.blue)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .help("在浏览器中打开 \(link)")
            } else {
                Text(value)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(primaryText)
            }
        }
    }
}
