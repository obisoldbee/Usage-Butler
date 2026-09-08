import AppKit
import UsageButlerCore
import UsageButlerDomain

/// Small native glyph, rendered at the display scale instead of downscaling a mockup.
public enum MemoryStatusIcon {
    // Three background sample intervals, matching the chart's continuity bound.
    public static let maximumAge: TimeInterval = 30

    public static func pressure(
        for snapshot: Stage3MemoryProjection,
        now: Date
    ) -> MemoryPressureState {
        let age = now.timeIntervalSince(snapshot.capturedAt)
        guard age.isFinite, age >= 0, age < maximumAge else { return .unknown }
        return snapshot.pressure
    }

    public static func label(for pressure: MemoryPressureState) -> String {
        switch pressure {
        case .normal: String(localized: "内存压力：正常")
        case .warning: String(localized: "内存压力：警告")
        case .critical: String(localized: "内存压力：严重")
        case .unknown: String(localized: "内存压力：未知")
        }
    }

    public static func image(for pressure: MemoryPressureState, dark: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let outline = dark ? NSColor.white : NSColor(white: 0.15, alpha: 1)
            outline.setStroke()
            let pins = NSBezierPath()
            pins.lineWidth = 2
            pins.lineCapStyle = .round
            for y: CGFloat in [6, 12] {
                pins.move(to: NSPoint(x: 1, y: y))
                pins.line(to: NSPoint(x: 4, y: y))
                pins.move(to: NSPoint(x: 16, y: y))
                pins.line(to: NSPoint(x: 19, y: y))
            }
            pins.stroke()

            let body = NSBezierPath(
                roundedRect: NSRect(x: 4, y: 2, width: 12, height: 14),
                xRadius: 3, yRadius: 3
            )
            // Neutral separator keeps the colored center distinct on any wallpaper.
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor.white).setFill()
            body.fill()
            outline.setStroke()
            body.lineWidth = 2
            body.stroke()

            let color: NSColor
            switch pressure {
            case .normal: color = NSColor(srgbRed: 0.16, green: 0.80, blue: 0.25, alpha: 1)
            case .warning: color = NSColor(srgbRed: 0.94, green: 0.68, blue: 0, alpha: 1)
            case .critical: color = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
            case .unknown: color = .systemGray
            }
            color.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 7, y: 5, width: 6, height: 8),
                xRadius: 1.5, yRadius: 1.5
            ).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = label(for: pressure)
        return image
    }
}
