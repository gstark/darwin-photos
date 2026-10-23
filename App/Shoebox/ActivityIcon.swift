import AppKit

/// The menu bar icon: an open shoebox with a photo on its side.
///
/// During a backup, a band of warm light, like a light leak on film, crosses
/// the box, then the icon rests. A MenuBarExtra label does not play symbol
/// effects, so the app swaps these frames on a timer.
@MainActor
enum ActivityIcon {
    static let interval = Duration.milliseconds(60)
    /// Frames with the band. The rest frames that follow show the plain icon.
    static let sweepFrames = 20
    static let frameCount = 30
    static let frames: [NSImage] = (0..<frameCount).map { index in
        makeFrame(sweep: index < sweepFrames ? Double(index) / Double(sweepFrames - 1) : nil)
    }
    /// The frame for Reduce Motion: the band rests in the middle of the icon.
    static let still = makeFrame(sweep: 0.5)

    /// The icon when no backup runs. A warning triangle replaces the box
    /// when the app needs attention.
    static func idle(needsAttention: Bool) -> NSImage {
        guard needsAttention else { return box }
        let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Shoebox needs attention")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))!
        image.isTemplate = true
        return image
    }

    /// The glyph is drawn on a grid of 32 units. These bounds include half
    /// the stroke width.
    private static let bounds = CGRect(x: 2.5, y: 4.5, width: 27, height: 24)
    /// Points for each grid unit.
    private static let scale = 0.75

    private static let box: NSImage = {
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = NSImage(size: size, flipped: true) { _ in
            drawBox()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Shoebox"
        return image
    }()

    /// Draws the box in black, in a flipped context.
    private static func drawBox() {
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.translateX(by: -bounds.minX, yBy: -bounds.minY)
        transform.concat()
        NSColor.black.setStroke()

        let body = NSBezierPath(roundedRect: NSRect(x: 5, y: 13, width: 22, height: 14), xRadius: 2, yRadius: 2)
        body.lineWidth = 2.2
        body.stroke()

        let lid = NSBezierPath()
        lid.move(to: NSPoint(x: 4, y: 9.5))
        lid.line(to: NSPoint(x: 27, y: 6))
        lid.line(to: NSPoint(x: 28, y: 10))
        lid.line(to: NSPoint(x: 5, y: 13.5))
        lid.close()
        lid.lineWidth = 2.2
        lid.lineJoinStyle = .round
        lid.stroke()

        // The photo on the side of the box: two hills.
        let hills = NSBezierPath()
        for (index, point) in [(11, 23), (15, 19), (18, 22), (20, 20), (23, 23)].enumerated() {
            let point = NSPoint(x: point.0, y: point.1)
            index == 0 ? hills.move(to: point) : hills.line(to: point)
        }
        hills.lineWidth = 1.8
        hills.lineJoinStyle = .round
        hills.lineCapStyle = .round
        hills.stroke()
    }

    private static let amber = NSColor(srgbRed: 1.0, green: 0.71, blue: 0.28, alpha: 1)
    private static let pink = NSColor(srgbRed: 1.0, green: 0.37, blue: 0.64, alpha: 1)

    /// `sweep` runs from 0 (band before the left edge) to 1 (band past the
    /// right edge). Nil draws the plain icon.
    private static func makeFrame(sweep: Double?) -> NSImage {
        // The handler runs at draw time, so labelColor follows the menu bar
        // appearance.
        let image = NSImage(size: box.size, flipped: false) { rect in
            var proposed = rect
            guard let context = NSGraphicsContext.current?.cgContext,
                  let mask = box.cgImage(forProposedRect: &proposed, context: NSGraphicsContext.current, hints: nil)
            else { return false }
            context.saveGState()
            context.clip(to: rect, mask: mask)
            NSColor.labelColor.setFill()
            rect.fill()
            if let sweep {
                drawBand(in: rect, at: sweep)
            }
            context.restoreGState()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Backing up"
        return image
    }

    /// A diagonal band, about as wide as the icon.
    private static func drawBand(in rect: NSRect, at sweep: Double) {
        let width = rect.width
        let centerX = rect.minX - width + sweep * (rect.width + 2 * width)
        let center = NSPoint(x: centerX, y: rect.midY)
        // The gradient runs along this vector, so the band is perpendicular to it.
        let dx = width * 0.55
        let dy = width * 0.3
        let gradient = NSGradient(colorsAndLocations:
            (amber.withAlphaComponent(0), 0),
            (amber, 0.3),
            (pink, 0.5),
            (amber, 0.7),
            (amber.withAlphaComponent(0), 1)
        )
        gradient?.draw(from: NSPoint(x: center.x - dx, y: center.y - dy), to: NSPoint(x: center.x + dx, y: center.y + dy), options: [])
    }
}
