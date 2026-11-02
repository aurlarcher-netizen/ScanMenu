import AppKit
let a = CommandLine.arguments
guard let img = NSImage(contentsOfFile: a[1]) else { print("SVG illisible"); exit(1) }
for size in a[3...].compactMap({ Int($0) }) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let out = "\(a[2])-\(size).png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print(out)
}
