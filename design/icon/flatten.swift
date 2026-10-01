// Re-encodes a PNG without an alpha channel (the App Store rejects icons that have one).
import AppKit
for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("can't read \(path)") }
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let out = path.replacingOccurrences(of: "-rgba.png", with: ".png")
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print(out, rep.pixelsWide, "x", rep.pixelsHigh, "alpha:", rep.hasAlpha)
}
