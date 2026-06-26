import AppKit
import Foundation

@MainActor
final class DockIconService {
    private let iconSize = NSSize(width: 512, height: 512)
    private var lastRenderedState: State?

    func update(date: Date, upcomingCount: Int) {
        let state = State(
            day: Calendar.current.component(.day, from: date),
            weekday: weekdayTitle(for: date),
            upcomingCount: upcomingCount
        )

        guard state != lastRenderedState else { return }
        lastRenderedState = state

        guard let app = NSApp else { return }
        app.dockTile.badgeLabel = nil
        app.applicationIconImage = drawIcon(state: state)
        app.dockTile.display()
    }

    private func weekdayTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).uppercased()
    }

    private func drawIcon(state: State) -> NSImage {
        let image = NSImage(size: iconSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        let size = iconSize.width
        let rect = NSRect(origin: .zero, size: iconSize)
        NSColor.clear.setFill()
        rect.fill()

        drawBackground(in: rect, size: size)
        drawCalendarPage(in: rect, size: size, state: state)

        if state.upcomingCount > 0 {
            drawUpcomingPill(in: rect, size: size, count: state.upcomingCount)
        }

        return image
    }

    private func drawBackground(in rect: NSRect, size: CGFloat) {
        let backgroundRect = rect.insetBy(dx: size * 0.035, dy: size * 0.035)
        let backgroundPath = NSBezierPath(
            roundedRect: backgroundRect,
            xRadius: size * 0.22,
            yRadius: size * 0.22
        )

        NSGradient(colors: [
            NSColor(calibratedRed: 0.04, green: 0.12, blue: 0.15, alpha: 1),
            NSColor(calibratedRed: 0.03, green: 0.44, blue: 0.50, alpha: 1),
            NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.88, alpha: 1)
        ])?.draw(in: backgroundPath, angle: -34)

        NSColor.white.withAlphaComponent(0.18).setStroke()
        backgroundPath.lineWidth = max(1, size * 0.008)
        backgroundPath.stroke()
    }

    private func drawCalendarPage(in rect: NSRect, size: CGFloat, state: State) {
        let pageRect = rect.insetBy(dx: size * 0.15, dy: size * 0.17)
        let pagePath = NSBezierPath(
            roundedRect: pageRect,
            xRadius: size * 0.075,
            yRadius: size * 0.075
        )

        NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
        pagePath.fill()

        setShadow(
            color: NSColor.black.withAlphaComponent(0.16),
            offset: NSSize(width: 0, height: -size * 0.012),
            blurRadius: size * 0.04
        )
        pagePath.fill()
        NSShadow().set()

        let bandRect = NSRect(
            x: pageRect.minX,
            y: pageRect.maxY - size * 0.145,
            width: pageRect.width,
            height: size * 0.145
        )
        let bandPath = NSBezierPath(
            roundedRect: bandRect,
            xRadius: size * 0.075,
            yRadius: size * 0.075
        )
        NSColor(calibratedRed: 0.98, green: 0.34, blue: 0.27, alpha: 1).setFill()
        bandPath.fill()

        let coverRect = NSRect(
            x: bandRect.minX,
            y: bandRect.minY,
            width: bandRect.width,
            height: bandRect.height * 0.52
        )
        NSColor(calibratedRed: 0.98, green: 0.34, blue: 0.27, alpha: 1).setFill()
        coverRect.fill()

        drawString(
            state.weekday,
            in: NSRect(
                x: bandRect.minX + size * 0.04,
                y: bandRect.minY + size * 0.035,
                width: bandRect.width - size * 0.08,
                height: bandRect.height * 0.58
            ),
            font: .systemFont(ofSize: size * 0.08, weight: .bold),
            color: .white,
            alignment: .center
        )

        drawString(
            "\(state.day)",
            in: NSRect(
                x: pageRect.minX + size * 0.04,
                y: pageRect.minY + size * 0.095,
                width: pageRect.width - size * 0.08,
                height: size * 0.285
            ),
            font: .monospacedDigitSystemFont(ofSize: size * 0.25, weight: .heavy),
            color: NSColor(calibratedWhite: 0.11, alpha: 1),
            alignment: .center
        )

        drawString(
            "TODAY",
            in: NSRect(
                x: pageRect.minX + size * 0.05,
                y: pageRect.minY + size * 0.045,
                width: pageRect.width - size * 0.1,
                height: size * 0.06
            ),
            font: .systemFont(ofSize: size * 0.045, weight: .semibold),
            color: NSColor(calibratedWhite: 0.38, alpha: 1),
            alignment: .center
        )
    }

    private func drawUpcomingPill(in rect: NSRect, size: CGFloat, count: Int) {
        let text = count > 99 ? "99+" : "\(count)"
        let pillWidth = text.count > 2 ? size * 0.27 : size * 0.22
        let pillRect = NSRect(
            x: rect.maxX - pillWidth - size * 0.07,
            y: rect.minY + size * 0.08,
            width: pillWidth,
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
            text,
            in: pillRect.insetBy(dx: size * 0.02, dy: size * 0.02),
            font: .monospacedDigitSystemFont(ofSize: size * 0.085, weight: .heavy),
            color: .white,
            alignment: .center
        )
    }

    private func drawString(
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

    private func setShadow(color: NSColor, offset: NSSize, blurRadius: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowOffset = offset
        shadow.shadowBlurRadius = blurRadius
        shadow.set()
    }

    private struct State: Equatable {
        let day: Int
        let weekday: String
        let upcomingCount: Int
    }
}
