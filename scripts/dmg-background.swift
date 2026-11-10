import AppKit

// Finder uses the image's logical size for layout; include both display scales.
let image = NSImage(size: NSSize(width: 680, height: 420))
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 680 * scale, pixelsHigh: 420 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
    NSRect(origin: .zero, size: image.size).fill()

    func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (value as NSString).draw(
            in: NSRect(x: 24, y: y, width: 632, height: 75),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
                .paragraphStyle: paragraph,
            ]
        )
    }

    text("Drag WesomeCloud into\nApplications to install", y: 300, size: 27, weight: .semibold)
    text("Then open WesomeCloud from Applications", y: 0, size: 17, weight: .regular)

    NSColor(calibratedRed: 0.07, green: 0.35, blue: 0.22, alpha: 1).setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 7
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 307, y: 213))
    arrow.line(to: NSPoint(x: 373, y: 213))
    arrow.move(to: NSPoint(x: 352, y: 234))
    arrow.line(to: NSPoint(x: 373, y: 213))
    arrow.line(to: NSPoint(x: 352, y: 192))
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(bitmap)
}
try image.tiffRepresentation!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
