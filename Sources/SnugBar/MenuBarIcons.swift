import AppKit
import SnugBarCore

/// Draws one style's glyph for each icon state. Images are templates, so the menu bar tints them for light and dark
/// menu bars and for the pressed state.
@MainActor
protocol MenuBarGlyphProvider {
    func image(for state: MenuBarIconState) -> NSImage?
}

/// The glyphs of every `MenuBarIconStyle`. A new style needs a case here (the switch won't compile without it).
@MainActor
enum MenuBarIconRenderer {
    static func provider(for style: MenuBarIconStyle) -> MenuBarGlyphProvider {
        switch style {
        case .chevrons: return SymbolGlyphs(style: style)
        case .capsule: return CapsuleGlyphs()
        }
    }

    static func image(_ style: MenuBarIconStyle, _ state: MenuBarIconState) -> NSImage? {
        let image = provider(for: style).image(for: state)
        image?.isTemplate = true
        image?.accessibilityDescription = "SnugBar"
        return image
    }
}

/// Styles made of SF Symbols (`MenuBarIconStyle.symbolName(for:)`), drawn at the system's status item size.
private struct SymbolGlyphs: MenuBarGlyphProvider {
    let style: MenuBarIconStyle

    func image(for state: MenuBarIconState) -> NSImage? {
        guard let name = style.symbolName(for: state) else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: "SnugBar")
    }
}

/// The Capsule style: a 17×9 pt capsule outline (the menu bar) with dots (its items), drawn in code.
private struct CapsuleGlyphs: MenuBarGlyphProvider {
    func image(for state: MenuBarIconState) -> NSImage? {
        let g = CapsuleGlyphGeometry()
        return NSImage(size: CapsuleGlyphGeometry.canvas, flipped: false) { _ in
            NSColor.black.set()
            let outline = NSBezierPath(roundedRect: g.capsule, xRadius: g.corner, yRadius: g.corner)
            outline.lineWidth = CapsuleGlyphGeometry.strokeWidth
            switch state {
            case .collapsed:
                outline.stroke()
                Self.fillDots(g.dots(1))
            case .expanded:
                outline.stroke()
                Self.fillDots(g.dots(3))
            case .all:
                // Filled capsule with three knocked-out dots.
                let filled = NSBezierPath(roundedRect: g.outer, xRadius: g.outer.height / 2, yRadius: g.outer.height / 2)
                filled.fill()
                NSGraphicsContext.current?.compositingOperation = .clear
                Self.fillDots(g.dots(3))
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            case .swapped:
                // Left half filled: shown and hidden have traded places.
                outline.stroke()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: g.outer, xRadius: g.outer.height / 2, yRadius: g.outer.height / 2).addClip()
                g.swappedFill.fill()
                NSGraphicsContext.restoreGraphicsState()
            case .zen:
                outline.stroke()
                let slash = NSBezierPath()
                slash.move(to: g.slash.from)
                slash.line(to: g.slash.to)
                slash.lineWidth = CapsuleGlyphGeometry.strokeWidth
                slash.lineCapStyle = .round
                slash.stroke()
            case .warning:
                outline.stroke()
                Self.drawExclamation(in: g.outer)
            }
            return true
        }
    }

    private static func fillDots(_ rects: [CGRect]) {
        for r in rects { NSBezierPath(ovalIn: r).fill() }
    }

    /// A "!" drawn as a short bar and a dot, centred in the capsule (a font glyph is too soft at this size).
    private static func drawExclamation(in outer: CGRect) {
        let w: CGFloat = 1.6
        let bar = NSBezierPath()
        bar.move(to: CGPoint(x: outer.midX, y: outer.midY + 1.9))
        bar.line(to: CGPoint(x: outer.midX, y: outer.midY + 0.1))
        bar.lineWidth = w
        bar.lineCapStyle = .round
        bar.stroke()
        NSBezierPath(ovalIn: CGRect(x: outer.midX - w / 2, y: outer.midY - 2.9, width: w, height: w)).fill()
    }
}
