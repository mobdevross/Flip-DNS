import AppKit

enum StatusIcon {
    enum Style: CaseIterable {
        case automatic, bypass, timed, busy, attention, unknown

        var badgeSymbol: String? {
            switch self {
            case .automatic: return nil
            case .bypass: return "arrow.up.right"
            case .timed: return "clock"
            case .busy: return "ellipsis"
            case .attention: return "exclamationmark"
            case .unknown: return "questionmark"
            }
        }
    }

    static func image(for style: Style) -> NSImage {
        let network = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        let badge = style.badgeSymbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        }
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            network?.draw(in: fittedRect(for: network, inside: NSRect(x: 1, y: 1, width: 18, height: 16)))
            if let badge {
                let circle = NSRect(x: 10.5, y: 0, width: 9.5, height: 9.5)
                NSGraphicsContext.saveGraphicsState()
                // A transparent halo and glyph keep the template legible in
                // both light and dark menu bars, without hard-coded white ink.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSColor.black.setFill()
                NSBezierPath(ovalIn: circle.insetBy(dx: -0.8, dy: -0.8)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: circle).fill()
                if style == .timed {
                    // At menu-bar size, just the two hands read more clearly
                    // than a second clock outline inside the circular badge.
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                    let hands = NSBezierPath()
                    hands.move(to: NSPoint(x: circle.midX, y: circle.midY + 2.6))
                    hands.line(to: NSPoint(x: circle.midX, y: circle.midY))
                    hands.line(to: NSPoint(x: circle.midX + 2.1, y: circle.midY))
                    hands.lineWidth = 1.1
                    hands.lineCapStyle = .round
                    hands.stroke()
                } else {
                    badge.draw(in: fittedRect(for: badge, inside: circle.insetBy(dx: 1.6, dy: 1.6)),
                               from: .zero, operation: .destinationOut, fraction: 1)
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func fittedRect(for image: NSImage?, inside bounds: NSRect) -> NSRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return bounds }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
