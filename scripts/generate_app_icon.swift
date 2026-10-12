import AppKit
import CoreGraphics

let size = CGSize(width: 1024, height: 1024)
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: 1024,
    height: 1024,
    bitsPerComponent: 8,
    bytesPerRow: 1024 * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("Failed to create CGContext")
}

// 1. Clean light blue/cream background (100% opaque)
context.setFillColor(CGColor(red: 0.92, green: 0.95, blue: 0.98, alpha: 1.0))
context.fill(CGRect(origin: .zero, size: size))

// 2. Leaf & Stem on top of blueberry
context.saveGState()
// Stem
context.setStrokeColor(CGColor(red: 0.28, green: 0.45, blue: 0.22, alpha: 1.0))
context.setLineWidth(16)
context.setLineCap(.round)
context.move(to: CGPoint(x: 512, y: 720))
context.addCurve(to: CGPoint(x: 530, y: 810), control1: CGPoint(x: 512, y: 760), control2: CGPoint(x: 520, y: 790))
context.strokePath()

// Leaf
let leafPath = CGMutablePath()
leafPath.move(to: CGPoint(x: 525, y: 760))
leafPath.addCurve(to: CGPoint(x: 680, y: 840), control1: CGPoint(x: 570, y: 820), control2: CGPoint(x: 640, y: 850))
leafPath.addCurve(to: CGPoint(x: 525, y: 760), control1: CGPoint(x: 640, y: 780), control2: CGPoint(x: 570, y: 760))
context.addPath(leafPath)
context.setFillColor(CGColor(red: 0.30, green: 0.76, blue: 0.42, alpha: 1.0))
context.fillPath()

// Leaf highlight/vein
context.setStrokeColor(CGColor(red: 0.22, green: 0.62, blue: 0.33, alpha: 1.0))
context.setLineWidth(6)
context.move(to: CGPoint(x: 535, y: 768))
context.addCurve(to: CGPoint(x: 650, y: 825), control1: CGPoint(x: 570, y: 790), control2: CGPoint(x: 610, y: 810))
context.strokePath()
context.restoreGState()

// 3. Rounded blueberry body (friendly plump organic berry)
context.saveGState()
let berryRect = CGRect(x: 212, y: 190, width: 600, height: 560)
let berryPath = CGMutablePath()
berryPath.addEllipse(in: berryRect)

context.addPath(berryPath)
context.clip()

// Blueberry gradient fill
let berryColors = [
    CGColor(red: 0.38, green: 0.52, blue: 0.94, alpha: 1.0),
    CGColor(red: 0.18, green: 0.32, blue: 0.78, alpha: 1.0)
] as CFArray
let locations: [CGFloat] = [0.0, 1.0]
if let gradient = CGGradient(colorsSpace: colorSpace, colors: berryColors, locations: locations) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 512, y: 750),
        end: CGPoint(x: 512, y: 190),
        options: []
    )
}
context.restoreGState()

// 4. Soft rosy cheeks
context.setFillColor(CGColor(red: 0.98, green: 0.55, blue: 0.72, alpha: 0.35))
context.fillEllipse(in: CGRect(x: 320, y: 390, width: 85, height: 45))
context.fillEllipse(in: CGRect(x: 619, y: 390, width: 85, height: 45))

// 5. Expressive googly eyes
// Left Eye white
let leftEyeRect = CGRect(x: 360, y: 440, width: 130, height: 130)
context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
context.fillEllipse(in: leftEyeRect)

// Right Eye white
let rightEyeRect = CGRect(x: 534, y: 440, width: 130, height: 130)
context.fillEllipse(in: rightEyeRect)

// Left Pupil
let leftPupilRect = CGRect(x: 410, y: 480, width: 66, height: 66)
context.setFillColor(CGColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 1.0))
context.fillEllipse(in: leftPupilRect)

// Right Pupil
let rightPupilRect = CGRect(x: 584, y: 480, width: 66, height: 66)
context.fillEllipse(in: rightPupilRect)

// Catchlights (sparkles in pupils)
context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
context.fillEllipse(in: CGRect(x: 445, y: 518, width: 20, height: 20))
context.fillEllipse(in: CGRect(x: 430, y: 495, width: 10, height: 10))

context.fillEllipse(in: CGRect(x: 619, y: 518, width: 20, height: 20))
context.fillEllipse(in: CGRect(x: 604, y: 495, width: 10, height: 10))

// 6. Cute smile
context.saveGState()
context.setStrokeColor(CGColor(red: 0.12, green: 0.16, blue: 0.28, alpha: 1.0))
context.setLineWidth(12)
context.setLineCap(.round)
context.move(to: CGPoint(x: 480, y: 390))
context.addCurve(to: CGPoint(x: 544, y: 390), control1: CGPoint(x: 495, y: 360), control2: CGPoint(x: 529, y: 360))
context.strokePath()
context.restoreGState()

// 7. Export PNG
guard let cgImage = context.makeImage() else {
    fatalError("Failed to make CGImage")
}

let rep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to make PNG data")
}

let outputDir = URL(fileURLWithPath: "iOS/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let outputFile = outputDir.appendingPathComponent("AppIcon-1024.png")
try pngData.write(to: outputFile)

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
try appIconContents.write(to: outputDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

let rootContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try rootContents.write(to: URL(fileURLWithPath: "iOS/Assets.xcassets/Contents.json"), atomically: true, encoding: .utf8)

print("✅ AppIcon-1024.png generated successfully at \(outputFile.path)")
