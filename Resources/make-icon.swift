import AppKit

// Usage: swift make-icon.swift <out.png> [night|paper]
let size: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: size - 200, height: size - 200)
let night = CommandLine.arguments.count < 3 || CommandLine.arguments[2] == "night"

let ground = night ? NSColor(red: 0.055, green: 0.067, blue: 0.094, alpha: 1) : NSColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1)
let ink = night ? NSColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1) : NSColor(white: 0.08, alpha: 1)
let flameColor = NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
ctx.setFillColor(ground.cgColor)
ctx.fill(tile)

srand48(7)
ctx.setLineWidth(1.2)
var y = tile.minY
while y < tile.maxY {
    ctx.setStrokeColor(NSColor(white: night ? 1 : 0, alpha: 0.02 + drand48() * 0.04).cgColor)
    ctx.move(to: CGPoint(x: tile.minX, y: y)); ctx.addLine(to: CGPoint(x: tile.maxX, y: y)); ctx.strokePath()
    y += 3 + drand48() * 2
}
for _ in 0..<9000 {
    ctx.setFillColor(NSColor(white: night ? 1 : 0, alpha: drand48() * 0.06).cgColor)
    ctx.fill(CGRect(x: tile.minX + drand48() * tile.width, y: tile.minY + drand48() * tile.height, width: 2, height: 2))
}
ctx.setFillColor(ink.withAlphaComponent(0.45).cgColor)
for (x, y, r) in [(230.0, 800.0, 7.0), (560.0, 860.0, 5.0), (860.0, 520.0, 6.0), (200.0, 470.0, 4.0), (680.0, 230.0, 5.0)] {
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

func star(center c: CGPoint, radius r: CGFloat) {
    ctx.beginPath()
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 + .pi / 2
        let d = i % 2 == 0 ? r : r * 0.28
        let p = CGPoint(x: c.x + cos(angle) * d, y: c.y + sin(angle) * d)
        i == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
    }
    ctx.closePath()
    ctx.fillPath()
}
ctx.setFillColor(ink.cgColor)
star(center: CGPoint(x: 770, y: 770), radius: 96)

// Same rocket as the menu bar glyph, drawn pointing up in glyph units and scaled up.
ctx.saveGState()
ctx.translateBy(x: 478, y: 478)
ctx.rotate(by: -.pi / 4)
ctx.scaleBy(x: 38, y: 38)

let flame = CGMutablePath()
flame.move(to: CGPoint(x: -1.5, y: -5.2))
flame.addCurve(to: CGPoint(x: 0, y: -9.6), control1: CGPoint(x: -1.5, y: -7.1), control2: CGPoint(x: -0.6, y: -8.3))
flame.addCurve(to: CGPoint(x: 1.5, y: -5.2), control1: CGPoint(x: 0.6, y: -8.3), control2: CGPoint(x: 1.5, y: -7.1))
flame.closeSubpath()
ctx.setFillColor(flameColor.cgColor)
ctx.addPath(flame)
ctx.fillPath()

let body = CGMutablePath()
body.move(to: CGPoint(x: 0, y: 7.2))
body.addCurve(to: CGPoint(x: 2.3, y: 1.8), control1: CGPoint(x: 1.6, y: 5.9), control2: CGPoint(x: 2.3, y: 4))
body.addLine(to: CGPoint(x: 2.3, y: -3.6))
body.addLine(to: CGPoint(x: -2.3, y: -3.6))
body.addLine(to: CGPoint(x: -2.3, y: 1.8))
body.addCurve(to: CGPoint(x: 0, y: 7.2), control1: CGPoint(x: -2.3, y: 4), control2: CGPoint(x: -1.6, y: 5.9))
body.closeSubpath()
for side: CGFloat in [-1, 1] {
    body.move(to: CGPoint(x: 2.3 * side, y: -0.4))
    body.addLine(to: CGPoint(x: 4.3 * side, y: -3.6))
    body.addLine(to: CGPoint(x: 4.3 * side, y: -5.2))
    body.addLine(to: CGPoint(x: 2.3 * side, y: -3.6))
    body.closeSubpath()
}
body.addRect(CGRect(x: -1.3, y: -4.6, width: 2.6, height: 1.2))
ctx.setFillColor(ink.cgColor)
ctx.addPath(body)
ctx.fillPath()
ctx.setFillColor(ground.cgColor)
ctx.fillEllipse(in: CGRect(x: -1.15, y: 0.6, width: 2.3, height: 2.3))
ctx.restoreGState()

image.unlockFocus()
let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
