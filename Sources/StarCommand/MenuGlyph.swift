import AppKit

// A rocket heading for the star: it fires when connected and tips over when a connection failed.
enum MenuGlyph {
    enum State { case idle, connected, failed }

    static func image(for state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            star(center: NSPoint(x: 17, y: 13), radius: 2.7).fill()

            let transform = NSAffineTransform()
            transform.translateX(by: 8, yBy: 7.4)
            transform.rotate(byDegrees: state == .failed ? -135 : -45)
            transform.scale(by: 0.92)
            transform.concat()

            rocket().fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: -1.15, y: 0.6, width: 2.3, height: 2.3)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            if state == .connected { flame().fill() }
            return true
        }
        image.isTemplate = true
        return image
    }

    // Drawn pointing up along +y, centred on the origin.
    private static func rocket() -> NSBezierPath {
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 0, y: 7.2))
        body.curve(to: NSPoint(x: 2.3, y: 1.8), controlPoint1: NSPoint(x: 1.6, y: 5.9), controlPoint2: NSPoint(x: 2.3, y: 4))
        body.line(to: NSPoint(x: 2.3, y: -3.6))
        body.line(to: NSPoint(x: -2.3, y: -3.6))
        body.line(to: NSPoint(x: -2.3, y: 1.8))
        body.curve(to: NSPoint(x: 0, y: 7.2), controlPoint1: NSPoint(x: -2.3, y: 4), controlPoint2: NSPoint(x: -1.6, y: 5.9))
        body.close()
        for side: CGFloat in [-1, 1] {
            let fin = NSBezierPath()
            fin.move(to: NSPoint(x: 2.3 * side, y: -0.4))
            fin.line(to: NSPoint(x: 4.3 * side, y: -3.6))
            fin.line(to: NSPoint(x: 4.3 * side, y: -5.2))
            fin.line(to: NSPoint(x: 2.3 * side, y: -3.6))
            fin.close()
            body.append(fin)
        }
        body.append(NSBezierPath(rect: NSRect(x: -1.3, y: -4.6, width: 2.6, height: 1.2)))
        return body
    }

    private static func flame() -> NSBezierPath {
        let flame = NSBezierPath()
        flame.move(to: NSPoint(x: -1.5, y: -5.2))
        flame.curve(to: NSPoint(x: 0, y: -9.4), controlPoint1: NSPoint(x: -1.5, y: -7), controlPoint2: NSPoint(x: -0.6, y: -8.2))
        flame.curve(to: NSPoint(x: 1.5, y: -5.2), controlPoint1: NSPoint(x: 0.6, y: -8.2), controlPoint2: NSPoint(x: 1.5, y: -7))
        flame.close()
        return flame
    }

    private static func star(center c: NSPoint, radius r: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4 + .pi / 2
            let d = i % 2 == 0 ? r : r * 0.3
            let point = NSPoint(x: c.x + cos(angle) * d, y: c.y + sin(angle) * d)
            i == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.close()
        return path
    }
}
