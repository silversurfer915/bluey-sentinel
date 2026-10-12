import AppKit
import CoreGraphics

/// Master Icon Generation Pipeline for Bluey Sentinel
/// Reads `Shared/Assets/bluey-logo-1024.png` and generates:
/// 1. iOS AppIcon: `iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
/// 2. macOS Squircle Tile: `Shared/Assets/bluey-mac-1024.png`
/// 3. macOS Iconset & Compiled `.icns`: `Mac/Resources/AppIcon.icns`
/// 4. Circular Avatar: `Shared/Assets/bluey-avatar-256.png` and `docs/assets/bluey-logo.png`

func main() {
    let sourceURL = URL(fileURLWithPath: "Shared/Assets/bluey-logo-1024.png")
    guard FileManager.default.fileExists(atPath: sourceURL.path),
          let sourceImage = NSImage(contentsOf: sourceURL),
          let sourceCG = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("Master artwork missing at \(sourceURL.path)")
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // 1. Export iOS Icon (1024x1024 full bleed)
    let iosDir = URL(fileURLWithPath: "iOS/Assets.xcassets/AppIcon.appiconset")
    try? FileManager.default.createDirectory(at: iosDir, withIntermediateDirectories: true)
    let iosTarget = iosDir.appendingPathComponent("AppIcon-1024.png")
    if let data = try? Data(contentsOf: sourceURL) {
        try? data.write(to: iosTarget)
        print("✅ Updated iOS AppIcon at \(iosTarget.path)")
    }

    let appIconContents = """
    {
      "images" : [
        {
          "filename" : "AppIcon-1024.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
    try? appIconContents.write(to: iosDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

    // 2. Render macOS Squircle Tile (1024x1024 canvas, 824x824 squircle centered, with drop shadow)
    let canvasSize = 1024
    guard let ctx = CGContext(
        data: nil,
        width: canvasSize,
        height: canvasSize,
        bitsPerComponent: 8,
        bytesPerRow: canvasSize * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext creation failed") }

    ctx.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 185.0
    let squirclePath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Multi-layer drop shadow for macOS Dock/Finder depth
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 32, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 14, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.1))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip & draw artwork
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()
    ctx.draw(sourceCG, in: iconRect)

    // Inner gloss highlight
    let highlightColors = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.22),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: highlightColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: iconRect.maxY), end: CGPoint(x: 512, y: iconRect.maxY - 110), options: [])
    }
    ctx.restoreGState()

    // Subtle rim stroke
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.setLineWidth(2.5)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.2))
    ctx.strokePath()
    ctx.restoreGState()

    guard let macIconCG = ctx.makeImage() else { fatalError("Master mac icon image creation failed") }

    let masterRep = NSBitmapImageRep(cgImage: macIconCG)
    if let masterPNG = masterRep.representation(using: .png, properties: [:]) {
        let macFile = URL(fileURLWithPath: "Shared/Assets/bluey-mac-1024.png")
        try? masterPNG.write(to: macFile)
        print("✅ Saved macOS master icon at \(macFile.path)")
    }

    // 3. Compile AppIcon.iconset -> Mac/Resources/AppIcon.icns
    let iconsetURL = URL(fileURLWithPath: "build/AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconsetURL)
    try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

    let sizes: [(name: String, px: Int)] = [
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

    for item in sizes {
        guard let resizedCtx = CGContext(
            data: nil,
            width: item.px,
            height: item.px,
            bitsPerComponent: 8,
            bytesPerRow: item.px * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { continue }

        resizedCtx.interpolationQuality = .high
        resizedCtx.draw(macIconCG, in: CGRect(x: 0, y: 0, width: item.px, height: item.px))

        if let resizedCG = resizedCtx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: resizedCG)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: iconsetURL.appendingPathComponent(item.name))
            }
        }
    }

    let resourcesURL = URL(fileURLWithPath: "Mac/Resources")
    try? FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
    try? proc.run()
    proc.waitUntilExit()

    if proc.terminationStatus == 0 {
        print("✅ Successfully compiled Mac/Resources/AppIcon.icns")
    }

    // 4. Circular Avatar for UI / Web
    let avatarSize = 256
    guard let avCtx = CGContext(
        data: nil,
        width: avatarSize,
        height: avatarSize,
        bitsPerComponent: 8,
        bytesPerRow: avatarSize * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }

    avCtx.clear(CGRect(x: 0, y: 0, width: avatarSize, height: avatarSize))
    let circle = CGPath(ellipseIn: CGRect(x: 8, y: 8, width: avatarSize - 16, height: avatarSize - 16), transform: nil)

    avCtx.saveGState()
    avCtx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: CGColor(red: 0.26, green: 0.33, blue: 0.84, alpha: 0.4))
    avCtx.addPath(circle)
    avCtx.setFillColor(CGColor(red: 0.26, green: 0.33, blue: 0.84, alpha: 0.1))
    avCtx.fillPath()
    avCtx.restoreGState()

    avCtx.saveGState()
    avCtx.addPath(circle)
    avCtx.clip()
    avCtx.draw(sourceCG, in: CGRect(x: 8, y: 8, width: avatarSize - 16, height: avatarSize - 16))
    avCtx.restoreGState()

    avCtx.saveGState()
    avCtx.addPath(circle)
    avCtx.setLineWidth(3)
    avCtx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.3))
    avCtx.strokePath()
    avCtx.restoreGState()

    if let circleCG = avCtx.makeImage() {
        let rep = NSBitmapImageRep(cgImage: circleCG)
        if let data = rep.representation(using: .png, properties: [:]) {
            let avatarURL = URL(fileURLWithPath: "Shared/Assets/bluey-avatar-256.png")
            try? data.write(to: avatarURL)
            let docsURL = URL(fileURLWithPath: "docs/assets/bluey-logo.png")
            try? FileManager.default.createDirectory(at: docsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: docsURL)
            print("✅ Saved avatar at \(avatarURL.path) and \(docsURL.path)")
        }
    }
}

main()
