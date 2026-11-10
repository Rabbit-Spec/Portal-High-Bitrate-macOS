import SwiftUI
import AppKit

/// 渲染高解析度 Portal-High-Bitrate 应用图标并导出 .iconset 供 iconutil 打包 .icns
public enum AppIconRenderer {
    public static func generateIconset(at directoryPath: String) throws {
        let fm = FileManager.default
        let iconsetDir = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

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
            if let data = renderPNGData(pixelSize: spec.px) {
                try data.write(to: iconsetDir.appendingPathComponent(spec.name))
            }
        }
    }

    public static func renderNSImage(pixelSize: Int = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        if let data = renderPNGData(pixelSize: pixelSize), let rep = NSBitmapImageRep(data: data) {
            image.addRepresentation(rep)
        }
        return image
    }

    private static func renderPNGData(pixelSize: Int) -> Data? {
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

        // macOS 圆角矩形容器外边距 (约 10% inset)
        let inset = s * 0.095
        let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let corner = rect.width * 0.225
        let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.018), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.32).cgColor)
        ctx.addPath(squircle)
        ctx.setFillColor(NSColor(calibratedRed: 0.07, green: 0.14, blue: 0.36, alpha: 1.0).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()

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

        // 顶部柔和液态高光
        let glowCenter = CGPoint(x: s * 0.36, y: s * 0.72)
        let glowColors = [
            NSColor(calibratedRed: 0.42, green: 0.85, blue: 1.0, alpha: 0.40).cgColor,
            NSColor(calibratedRed: 0.42, green: 0.85, blue: 1.0, alpha: 0.0).cgColor
        ] as CFArray
        if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
            ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: s * 0.45, options: [])
        }

        // 掌机宽屏外框 (Portal 剪影)
        let bodyW = rect.width * 0.68
        let bodyH = rect.height * 0.34
        let bodyRect = CGRect(x: s * 0.5 - bodyW * 0.5, y: s * 0.45 - bodyH * 0.5, width: bodyW, height: bodyH)
        let screenW = bodyW * 0.62
        let screenH = bodyH * 0.84
        let screenRect = CGRect(x: s * 0.5 - screenW * 0.5, y: bodyRect.midY - screenH * 0.5, width: screenW, height: screenH)

        // 左右手柄握把
        let handleW = bodyW * 0.23
        let leftHandle = CGRect(x: bodyRect.minX, y: bodyRect.minY - bodyH * 0.14, width: handleW, height: bodyH * 1.18)
        let rightHandle = CGRect(x: bodyRect.maxX - handleW, y: bodyRect.minY - bodyH * 0.14, width: handleW, height: bodyH * 1.18)

        ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.addPath(CGPath(roundedRect: leftHandle, cornerWidth: handleW * 0.48, cornerHeight: handleW * 0.48, transform: nil))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: rightHandle, cornerWidth: handleW * 0.48, cornerHeight: handleW * 0.48, transform: nil))
        ctx.fillPath()

        // 中央屏幕边框
        let bezelRect = screenRect.insetBy(dx: -s * 0.015, dy: -s * 0.015)
        ctx.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 1.0).cgColor)
        ctx.addPath(CGPath(roundedRect: bezelRect, cornerWidth: s * 0.025, cornerHeight: s * 0.025, transform: nil))
        ctx.fillPath()

        // 屏幕内部发光渐变
        ctx.saveGState()
        let screenPath = CGPath(roundedRect: screenRect, cornerWidth: s * 0.016, cornerHeight: s * 0.016, transform: nil)
        ctx.addPath(screenPath)
        ctx.clip()
        let scrColors = [
            NSColor(calibratedRed: 0.05, green: 0.14, blue: 0.35, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.06, green: 0.64, blue: 0.95, alpha: 1.0).cgColor
        ] as CFArray
        if let scrGrad = CGGradient(colorsSpace: colorSpace, colors: scrColors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                scrGrad,
                start: CGPoint(x: screenRect.minX, y: screenRect.minY),
                end: CGPoint(x: screenRect.maxX, y: screenRect.maxY),
                options: []
            )
        }
        ctx.restoreGState()

        // 顶部高速码率无线信号弧 (三道亮青色弧线)
        let arcCenter = CGPoint(x: s * 0.5, y: screenRect.maxY + s * 0.02)
        ctx.setLineCap(.round)
        for i in 1...3 {
            let r = s * (0.06 + CGFloat(i) * 0.045)
            ctx.setStrokeColor(NSColor(calibratedRed: 0.55, green: 0.94, blue: 1.0, alpha: 1.0 - CGFloat(i - 1) * 0.18).cgColor)
            ctx.setLineWidth(s * 0.026)
            ctx.beginPath()
            ctx.addArc(center: arcCenter, radius: r, startAngle: .pi * 0.24, endAngle: .pi * 0.76, clockwise: false)
            ctx.strokePath()
        }

        // 内边框微弱高光描边
        ctx.addPath(squircle)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(max(1.0, s * 0.012))
        ctx.strokePath()

        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

public struct PortalAppIconView: View {
    private static let sharedIcon: NSImage = AppIconRenderer.renderNSImage(pixelSize: 256)
    public let size: CGFloat

    public init(size: CGFloat = 64) {
        self.size = size
    }

    public var body: some View {
        Image(nsImage: Self.sharedIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
