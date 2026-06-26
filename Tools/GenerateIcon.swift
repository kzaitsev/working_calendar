import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let icons: [(name: String, size: Int)] = [
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

for icon in icons {
    let image = drawIcon(size: CGFloat(icon.size))
    let url = outputDirectory.appendingPathComponent(icon.name)
    try pngData(from: image)?.write(to: url)
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let backgroundRect = rect.insetBy(dx: size * 0.035, dy: size * 0.035)
    let background = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: size * 0.22,
        yRadius: size * 0.22
    )
    NSGradient(colors: [
        NSColor(calibratedRed: 0.04, green: 0.12, blue: 0.15, alpha: 1),
        NSColor(calibratedRed: 0.03, green: 0.44, blue: 0.50, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.88, alpha: 1)
    ])?.draw(in: background, angle: -34)

    NSColor.white.withAlphaComponent(0.18).setStroke()
    background.lineWidth = max(1, size * 0.008)
    background.stroke()

    let calendarRect = rect.insetBy(dx: size * 0.15, dy: size * 0.17)
    let calendarPath = NSBezierPath(
        roundedRect: calendarRect,
        xRadius: size * 0.075,
        yRadius: size * 0.075
    )

    setShadow(
        color: NSColor.black.withAlphaComponent(0.16),
        offset: NSSize(width: 0, height: -size * 0.012),
        blurRadius: size * 0.04
    )
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    calendarPath.fill()
    NSShadow().set()

    let topBand = NSRect(
        x: calendarRect.minX,
        y: calendarRect.maxY - size * 0.145,
        width: calendarRect.width,
        height: size * 0.145
    )
    let bandPath = NSBezierPath(
        roundedRect: topBand,
        xRadius: size * 0.075,
        yRadius: size * 0.075
    )
    NSColor(calibratedRed: 0.00, green: 0.58, blue: 0.64, alpha: 1).setFill()
    bandPath.fill()

    NSColor(calibratedRed: 0.00, green: 0.58, blue: 0.64, alpha: 1).setFill()
    NSRect(
        x: topBand.minX,
        y: topBand.minY,
        width: topBand.width,
        height: topBand.height * 0.52
    ).fill()

    drawString(
        "WORK",
        in: NSRect(
            x: topBand.minX + size * 0.04,
            y: topBand.minY + size * 0.035,
            width: topBand.width - size * 0.08,
            height: topBand.height * 0.58
        ),
        font: .systemFont(ofSize: size * 0.075, weight: .bold),
        color: .white,
        alignment: .center
    )

    drawString(
        "31",
        in: NSRect(
            x: calendarRect.minX + size * 0.04,
            y: calendarRect.minY + size * 0.095,
            width: calendarRect.width - size * 0.08,
            height: size * 0.285
        ),
        font: .monospacedDigitSystemFont(ofSize: size * 0.25, weight: .heavy),
        color: NSColor(calibratedWhite: 0.11, alpha: 1),
        alignment: .center
    )

    drawString(
        "TODAY",
        in: NSRect(
            x: calendarRect.minX + size * 0.05,
            y: calendarRect.minY + size * 0.045,
            width: calendarRect.width - size * 0.1,
            height: size * 0.06
        ),
        font: .systemFont(ofSize: size * 0.045, weight: .semibold),
        color: NSColor(calibratedWhite: 0.38, alpha: 1),
        alignment: .center
    )

    drawUpcomingPill(in: rect, size: size)

    return image
}

func drawUpcomingPill(in rect: NSRect, size: CGFloat) {
    let pillRect = NSRect(
        x: rect.maxX - size * 0.29,
        y: rect.minY + size * 0.08,
        width: size * 0.22,
        height: size * 0.16
    )
    let pillPath = NSBezierPath(
        roundedRect: pillRect,
        xRadius: pillRect.height / 2,
        yRadius: pillRect.height / 2
    )

    setShadow(
        color: NSColor.black.withAlphaComponent(0.24),
        offset: NSSize(width: 0, height: -size * 0.01),
        blurRadius: size * 0.025
    )
    NSColor(calibratedRed: 0.00, green: 0.58, blue: 0.84, alpha: 1).setFill()
    pillPath.fill()
    NSShadow().set()

    NSColor.white.withAlphaComponent(0.28).setStroke()
    pillPath.lineWidth = max(1, size * 0.008)
    pillPath.stroke()

    drawString(
        "3",
        in: pillRect.insetBy(dx: size * 0.02, dy: size * 0.02),
        font: .monospacedDigitSystemFont(ofSize: size * 0.085, weight: .heavy),
        color: .white,
        alignment: .center
    )
}

func drawString(
    _ string: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
        .kern: 0
    ]

    let attributed = NSAttributedString(string: string, attributes: attributes)
    let measured = attributed.boundingRect(
        with: rect.size,
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let drawRect = NSRect(
        x: rect.minX,
        y: rect.minY + max(0, (rect.height - measured.height) / 2),
        width: rect.width,
        height: measured.height
    )
    attributed.draw(in: drawRect)
}

func setShadow(color: NSColor, offset: NSSize, blurRadius: CGFloat) {
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowOffset = offset
    shadow.shadowBlurRadius = blurRadius
    shadow.set()
}

func pngData(from image: NSImage) -> Data? {
    guard
        let tiff = image.tiffRepresentation,
        let representation = NSBitmapImageRep(data: tiff)
    else {
        return nil
    }

    return representation.representation(using: .png, properties: [:])
}
