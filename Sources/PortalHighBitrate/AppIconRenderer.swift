import SwiftUI
import AppKit

/// 渲染高解析度 Portal-High-Bitrate（同步 SysPulse PS Portal 串流插件浅/深色图标）并支持运行时 Dock 主题自适应
public enum AppIconRenderer {
    private static func framingPreset(isDark: Bool) -> (scale: CGFloat, offsetYFraction: CGFloat) {
        isDark ? (1.40, -0.022) : (1.44, -0.028)
    }

    public static func loadArtworkCGImage(isDark: Bool) -> CGImage? {
        let resourceName = "PSPortalIcon-\(isDark ? "Dark" : "Light")-1024"
        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/\(resourceName).png")
            .path

        let candidates: [String?] = [
            Bundle.main.url(forResource: resourceName, withExtension: "png")?.path,
            Bundle.main.resourceURL?.appendingPathComponent("\(resourceName).png").path,
            sourceRelative
        ]

        for path in candidates.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path),
               let nsImg = NSImage(contentsOfFile: path),
               let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cg
            }
        }
        return nil
    }

    public static func generateIconset(at directoryPath: String) throws {
        let fm = FileManager.default
        let baseDir = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let lightDir = baseDir.appendingPathComponent("AppIcon-Light.iconset", isDirectory: true)
        let darkDir = baseDir.appendingPathComponent("AppIcon-Dark.iconset", isDirectory: true)

        try? fm.removeItem(at: lightDir)
        try? fm.removeItem(at: darkDir)
        try fm.createDirectory(at: lightDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: darkDir, withIntermediateDirectories: true)

        let specs: [(name: String, px: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024)
        ]

        for spec in specs {
            if let lightData = renderPNGData(pixelSize: spec.px, isDark: false) {
                try lightData.write(to: lightDir.appendingPathComponent(spec.name))
            }
            if let darkData = renderPNGData(pixelSize: spec.px, isDark: true) {
                try darkData.write(to: darkDir.appendingPathComponent(spec.name))
            }
        }
    }

    public static func exportAppIconPNG(to filePath: String, pixelSize: Int = 1024, isDark: Bool = false) throws {
        guard let data = renderPNGData(pixelSize: pixelSize, isDark: isDark) else {
            throw NSError(domain: "AppIconRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render PNG"])
        }
        try data.write(to: URL(fileURLWithPath: filePath))
    }

    public static func renderNSImage(pixelSize: Int = 512, isDark: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        if let data = renderPNGData(pixelSize: pixelSize, isDark: isDark), let rep = NSBitmapImageRep(data: data) {
            image.addRepresentation(rep)
        }
        return image
    }

    private static func renderPNGData(pixelSize: Int, isDark: Bool) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        rep.size = NSSize(width: pixelSize, height: pixelSize)
        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        let ctx = nsCtx.cgContext
        let s = CGFloat(pixelSize)

        let inset = s * 0.098
        let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let corner = rect.width * 0.225
        let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

        // macOS 标准 Dock 图标外阴影
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -rect.width * 0.025),
            blur: rect.width * 0.045,
            color: NSColor.black.withAlphaComponent(isDark ? 0.65 : 0.22).cgColor
        )
        ctx.addPath(squircle)
        ctx.setFillColor(isDark ? NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor : NSColor(calibratedWhite: 0.96, alpha: 1.0).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()

        if let artwork = loadArtworkCGImage(isDark: isDark) {
            let framing = framingPreset(isDark: isDark)
            let scaledW = rect.width * framing.scale
            let scaledH = rect.height * framing.scale
            // CoreGraphics Y 轴向上，SwiftUI offset(y: negative) 对应此处正向向上偏移
            let drawX = rect.midX - scaledW * 0.5
            let drawY = rect.midY - scaledH * 0.5 - (rect.height * framing.offsetYFraction)
            ctx.interpolationQuality = .high
            ctx.draw(artwork, in: CGRect(x: drawX, y: drawY, width: scaledW, height: scaledH))
        } else {
            drawVectorFallback(in: ctx, rect: rect, s: s)
        }

        // 内边框柔和描边
        ctx.addPath(squircle)
        ctx.setStrokeColor(isDark ? NSColor.white.withAlphaComponent(0.16).cgColor : NSColor.black.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(max(1.0, s * 0.01))
        ctx.strokePath()

        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func drawVectorFallback(in ctx: CGContext, rect: CGRect, s: CGFloat) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bgColors = [
            NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.28, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.11, green: 0.26, blue: 0.66, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.23, green: 0.45, blue: 0.96, alpha: 1.0).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )
        }
        let bodyW = rect.width * 0.68
        let bodyH = rect.height * 0.34
        let bodyRect = CGRect(x: s * 0.5 - bodyW * 0.5, y: s * 0.45 - bodyH * 0.5, width: bodyW, height: bodyH)
        let screenW = bodyW * 0.62
        let screenH = bodyH * 0.84
        let screenRect = CGRect(x: s * 0.5 - screenW * 0.5, y: bodyRect.midY - screenH * 0.5, width: screenW, height: screenH)
        let handleW = bodyW * 0.23
        let leftHandle = CGRect(x: bodyRect.minX, y: bodyRect.minY - bodyH * 0.14, width: handleW, height: bodyH * 1.18)
        let rightHandle = CGRect(x: bodyRect.maxX - handleW, y: bodyRect.minY - bodyH * 0.14, width: handleW, height: bodyH * 1.18)

        ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.addPath(CGPath(roundedRect: leftHandle, cornerWidth: handleW * 0.48, cornerHeight: handleW * 0.48, transform: nil))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: rightHandle, cornerWidth: handleW * 0.48, cornerHeight: handleW * 0.48, transform: nil))
        ctx.fillPath()

        let bezelRect = screenRect.insetBy(dx: -s * 0.015, dy: -s * 0.015)
        ctx.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 1.0).cgColor)
        ctx.addPath(CGPath(roundedRect: bezelRect, cornerWidth: s * 0.025, cornerHeight: s * 0.025, transform: nil))
        ctx.fillPath()
    }
}

/// 同步 SysPulse PS Portal 插件艺术插画的自适应 SwiftUI 图标组件
public struct PortalAppIconView: View {
    @Environment(\.colorScheme) private var envColorScheme
    public let size: CGFloat
    public var forcedColorScheme: ColorScheme? = nil
    public var isCircle: Bool = false

    private static var cachedImages: [String: NSImage] = [:]

    public init(size: CGFloat = 64, forcedColorScheme: ColorScheme? = nil, isCircle: Bool = false) {
        self.size = size
        self.forcedColorScheme = forcedColorScheme
        self.isCircle = isCircle
    }

    private var activeScheme: ColorScheme {
        forcedColorScheme ?? envColorScheme
    }

    public var body: some View {
        let isDark = (activeScheme == .dark)
        let cornerRadius = size * 0.225
        let squircle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if let image = Self.loadDownsampledArtwork(isDark: isDark) {
                let scale: CGFloat = isDark ? 1.40 : 1.44
                let offsetYFraction: CGFloat = isDark ? -0.022 : -0.028
                let img = Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(scale)
                    .offset(y: size * offsetYFraction)
                    .frame(width: size, height: size)

                if isCircle {
                    img.clipShape(Circle())
                } else {
                    img
                        .clipShape(squircle)
                        .overlay(
                            squircle
                                .strokeBorder(
                                    isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.06),
                                    lineWidth: 0.8
                                )
                        )
                }
            } else {
                Image(nsImage: Self.fallbackIcon(isDark: isDark))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(isCircle ? AnyShape(Circle()) : AnyShape(squircle))
            }
        }
        .frame(width: size, height: size)
    }

    private static func loadDownsampledArtwork(isDark: Bool) -> NSImage? {
        let key = isDark ? "PSPortalIcon-Dark-1024" : "PSPortalIcon-Light-1024"
        if let cached = cachedImages[key] {
            return cached
        }
        guard let cgImage = AppIconRenderer.loadArtworkCGImage(isDark: isDark) else {
            return nil
        }
        let maxPixelSize: CGFloat = 256
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let scale = max(w, h) > maxPixelSize ? (maxPixelSize / max(w, h)) : 1.0
        let targetW = max(1, Int(round(w * scale)))
        let targetH = max(1, Int(round(h * scale)))

        let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: srgbSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let scaledCG = ctx.makeImage() else {
            return NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
        }
        let img = NSImage(cgImage: scaledCG, size: NSSize(width: targetW, height: targetH))
        cachedImages[key] = img
        return img
    }

    private static func fallbackIcon(isDark: Bool) -> NSImage {
        let key = isDark ? "fallback-dark" : "fallback-light"
        if let cached = cachedImages[key] {
            return cached
        }
        let img = AppIconRenderer.renderNSImage(pixelSize: 256, isDark: isDark)
        cachedImages[key] = img
        return img
    }
}

/// 运行时跟随系统浅色 / 深色外观切换 Dock 图标
@MainActor
public final class PortalAppIconManager {
    public static let shared = PortalAppIconManager()

    private var appearanceObservation: NSKeyValueObservation?
    private var currentModeIsDark: Bool? = nil

    private init() {}

    public static var isSystemInDarkMode: Bool {
        if let val = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication as CFString) as? String {
            return val.caseInsensitiveCompare("dark") == .orderedSame
        }
        return false
    }

    public func startObservingSystemAppearance() {
        applyCurrentAppearanceIcon(force: true)

        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyCurrentAppearanceIcon(force: false)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyCurrentAppearanceIcon(force: true)
            }
        }
    }

    public func applyCurrentAppearanceIcon(force: Bool = false) {
        let isDark = Self.isSystemInDarkMode
        if !force, let current = currentModeIsDark, current == isDark {
            return
        }
        currentModeIsDark = isDark

        let iconResourceName = isDark ? "AppIcon-Dark" : "AppIcon-Light"
        if let iconURL = Bundle.main.url(forResource: iconResourceName, withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = image
        } else {
            NSApp.applicationIconImage = AppIconRenderer.renderNSImage(pixelSize: 512, isDark: isDark)
        }
        NSApp.dockTile.display()
    }
}
