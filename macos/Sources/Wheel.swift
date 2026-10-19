import AppKit

// MARK: - Thème AikoRoue (noir / blanc + bleu clair)

struct Theme {
    let disc: NSColor
    let line: NSColor
    let text: NSColor
    let subtext: NSColor
    let center: NSColor
    let accent: NSColor
    let onAccent: NSColor

    static let accentBlue = NSColor(srgbRed: 0.49, green: 0.78, blue: 1.0, alpha: 1)   // #7DC8FF

    static let dark = Theme(
        disc: NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 0.97),
        line: NSColor(white: 1, alpha: 0.09),
        text: NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1),
        subtext: NSColor(srgbRed: 0.55, green: 0.58, blue: 0.62, alpha: 1),
        center: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1),
        accent: accentBlue,
        onAccent: NSColor(srgbRed: 0.02, green: 0.07, blue: 0.11, alpha: 1))

    static let light = Theme(
        disc: NSColor(white: 1, alpha: 0.98),
        line: NSColor(white: 0, alpha: 0.08),
        text: NSColor(srgbRed: 0.04, green: 0.05, blue: 0.06, alpha: 1),
        subtext: NSColor(srgbRed: 0.42, green: 0.45, blue: 0.50, alpha: 1),
        center: NSColor(srgbRed: 0.95, green: 0.97, blue: 0.99, alpha: 1),
        accent: accentBlue,
        onAccent: NSColor(srgbRed: 0.02, green: 0.07, blue: 0.11, alpha: 1))

    @MainActor
    static func current(for view: NSView) -> Theme {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
}

/// Petite icône de la barre des menus (roue), en image « modèle » pour suivre le thème.
@MainActor
func statusBarIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        let c = NSPoint(x: rect.midX, y: rect.midY)
        NSColor.black.setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 1.6
        ring.stroke()
        let hub = NSBezierPath(ovalIn: NSRect(x: c.x - 2.6, y: c.y - 2.6, width: 5.2, height: 5.2))
        hub.lineWidth = 1.4
        hub.stroke()
        for k in 0..<6 {
            let a = CGFloat(k) * .pi / 3 + .pi / 2
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x + cos(a) * 3.6, y: c.y + sin(a) * 3.6))
            p.line(to: NSPoint(x: c.x + cos(a) * 7.2, y: c.y + sin(a) * 7.2))
            p.lineWidth = 1.2
            p.stroke()
        }
        return true
    }
    image.isTemplate = true
    return image
}

struct Slot: Equatable {
    let ring: Int
    let index: Int
}

@MainActor
func clampToScreen(_ rect: NSRect, around point: NSPoint) -> NSRect {
    let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return rect }
    var origin = rect.origin
    origin.x = min(max(origin.x, visible.minX), visible.maxX - rect.width)
    origin.y = min(max(origin.y, visible.minY), visible.maxY - rect.height)
    return NSRect(origin: origin, size: rect.size)
}

// MARK: - Fenêtre flottante de la roue

@MainActor
final class RadialPanel {
    static let side: CGFloat = 420

    var onPick: ((FileAction, [URL]) -> Void)?

    private let panel: NSPanel
    private let radial: RadialView
    private var generation = 0

    init() {
        let frame = NSRect(x: 0, y: 0, width: RadialPanel.side, height: RadialPanel.side)

        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = RadialView(frame: frame)
        view.autoresizingMask = [.width, .height]
        p.contentView = view

        panel = p
        radial = view

        radial.onDrop = { [weak self] action, urls in
            self?.dismiss(after: 0)
            self?.onPick?(action, urls)
        }
    }

    func present(actions: [FileAction], badge: String, count: Int, at point: NSPoint) {
        generation += 1

        let formats = actions.filter { $0.ring == .formats }
        let tools = actions.filter { $0.ring == .tools }
        radial.configure(rings: [formats, tools].filter { !$0.isEmpty },
                         badge: badge,
                         countText: count == 1 ? "1 fichier" : "\(count) fichiers")

        let s = RadialPanel.side
        let frame = clampToScreen(NSRect(x: point.x - s / 2, y: point.y - s / 2, width: s, height: s), around: point)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0.1
        panel.animator().alphaValue = 1
        NSAnimationContext.endGrouping()
    }

    func dismiss(after delay: TimeInterval) {
        generation += 1
        let g = generation
        if delay <= 0 {
            panel.orderOut(nil)
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.generation == g else { return }
            self.panel.orderOut(nil)
        }
    }
}

// MARK: - Dessin et dépôt

@MainActor
final class RadialView: NSView {
    var onDrop: ((FileAction, [URL]) -> Void)?

    private(set) var rings: [[FileAction]] = []
    private var badge = ""
    private var countText = ""

    private var hovered: Slot? {
        didSet {
            guard hovered != oldValue else { return }
            needsDisplay = true
            if hovered != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }
    private var inCenter = false {
        didSet { if inCenter != oldValue { needsDisplay = true } }
    }

    // Géométrie (identique à la version Windows/Linux)
    private let centerRadius: CGFloat = 46
    private let ringRadii: [(CGFloat, CGFloat)] = [(46, 118), (118, 186)]

    var outerRadius: CGFloat {
        let n = max(1, min(rings.count, ringRadii.count))
        return ringRadii[n - 1].1
    }

    private var mid: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non pris en charge") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(rings: [[FileAction]], badge: String, countText: String) {
        self.rings = rings
        self.badge = badge
        self.countText = countText
        hovered = nil
        inCenter = false
        needsDisplay = true
    }

    // MARK: Géométrie

    private func circle(_ r: CGFloat) -> NSRect {
        NSRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2)
    }

    /// Angle central (degrés, sens trigo) du quartier i sur n, en partant du haut, sens horaire.
    private func midAngle(_ i: Int, _ n: Int) -> CGFloat {
        90 - CGFloat(i) * 360 / CGFloat(n)
    }

    private func wedgePath(ring k: Int, index i: Int, count n: Int, inset: CGFloat) -> NSBezierPath {
        let (ra0, rb0) = ringRadii[k]
        let ra = ra0 + inset, rb = rb0 - inset
        let path = NSBezierPath()
        if n == 1 {
            path.appendOval(in: circle(rb))
            path.appendOval(in: circle(ra))
            path.windingRule = .evenOdd
            return path
        }
        let step = 360 / CGFloat(n)
        let m = midAngle(i, n)
        let gapOuter = inset / rb * 180 / .pi
        let gapInner = inset / ra * 180 / .pi
        path.appendArc(withCenter: mid, radius: rb,
                       startAngle: m + step / 2 - gapOuter, endAngle: m - step / 2 + gapOuter, clockwise: true)
        path.appendArc(withCenter: mid, radius: ra,
                       startAngle: m - step / 2 + gapInner, endAngle: m + step / 2 - gapInner, clockwise: false)
        path.close()
        return path
    }

    private func hit(_ p: NSPoint) -> Slot? {
        let dx = p.x - mid.x, dy = p.y - mid.y
        let d = hypot(dx, dy)
        for (k, ring) in rings.enumerated() where k < ringRadii.count {
            let (ra, rb) = ringRadii[k]
            let isLast = k == rings.count - 1
            guard d >= ra, d <= (isLast ? rb + 30 : rb) else { continue }
            let n = ring.count
            if n == 1 { return Slot(ring: k, index: 0) }
            let angle = atan2(dy, dx) * 180 / .pi
            var rel = (90 - angle).truncatingRemainder(dividingBy: 360)
            if rel < 0 { rel += 360 }
            let step = 360 / CGFloat(n)
            let i = Int((rel + step / 2) / step) % n
            return Slot(ring: k, index: i)
        }
        return nil
    }

    private func isInCenter(_ p: NSPoint) -> Bool {
        hypot(p.x - mid.x, p.y - mid.y) < centerRadius
    }

    // MARK: Dessin

    override func draw(_ dirtyRect: NSRect) {
        guard !rings.isEmpty else { return }
        let t = Theme.current(for: self)
        let outer = outerRadius

        // Disque
        let disc = NSBezierPath(ovalIn: circle(outer))
        t.disc.setFill()
        disc.fill()
        t.line.setStroke()
        disc.lineWidth = 1
        disc.stroke()

        // Séparations : cercles entre anneaux + rayons entre quartiers
        for (k, ring) in rings.enumerated() where k < ringRadii.count {
            let (ra, rb) = ringRadii[k]
            if k > 0 {
                let c = NSBezierPath(ovalIn: circle(ra))
                c.lineWidth = 1
                c.stroke()
            }
            guard ring.count > 1 else { continue }
            let step = 360 / CGFloat(ring.count)
            for i in 0..<ring.count {
                let a = (midAngle(i, ring.count) + step / 2) * .pi / 180
                let line = NSBezierPath()
                line.move(to: NSPoint(x: mid.x + cos(a) * (ra + 10), y: mid.y + sin(a) * (ra + 10)))
                line.line(to: NSPoint(x: mid.x + cos(a) * (rb - 10), y: mid.y + sin(a) * (rb - 10)))
                line.lineWidth = 1
                line.stroke()
            }
        }

        // Quartier survolé : aplat bleu clair aux coins adoucis
        if let h = hovered, h.ring < rings.count, h.index < rings[h.ring].count {
            let path = wedgePath(ring: h.ring, index: h.index, count: rings[h.ring].count, inset: 5)
            t.accent.setFill()
            path.fill()
            path.lineJoinStyle = .round
            path.lineWidth = 6
            t.accent.setStroke()
            path.stroke()
        }

        // Libellés
        for (k, ring) in rings.enumerated() where k < ringRadii.count {
            for (i, action) in ring.enumerated() {
                let hot = hovered == Slot(ring: k, index: i)
                let (ra, rb) = ringRadii[k]
                let a = midAngle(i, ring.count) * .pi / 180
                let r = k == 0 ? (ra + rb) / 2 + 6 : (ra + rb) / 2
                let p = NSPoint(x: mid.x + cos(a) * r, y: mid.y + sin(a) * r)
                let color = hot ? t.onAccent : t.text
                if action.ring == .formats {
                    drawText(action.title, size: 13, weight: .semibold, color: color, at: p, kern: 0.4)
                } else {
                    drawText(action.title, size: 11, weight: .medium, color: color, at: p)
                }
            }
        }

        // Centre
        let hub = NSBezierPath(ovalIn: circle(centerRadius - 6))
        (inCenter ? t.line : t.center).setFill()
        hub.fill()
        t.accent.setStroke()
        hub.lineWidth = 1.5
        hub.stroke()

        var title = badge
        var subtitle = countText
        var size: CGFloat = badge.count > 5 ? 11 : 14
        if inCenter {
            title = "✕"
            subtitle = "annuler"
            size = 15
        } else if let h = hovered, h.ring < rings.count, h.index < rings[h.ring].count {
            let action = rings[h.ring][h.index]
            title = action.title
            subtitle = "lâcher"
            size = action.title.count > 7 ? 10 : 13
        }
        drawText(title, size: size, weight: .bold, color: t.text, at: NSPoint(x: mid.x, y: mid.y + 6))
        drawText(subtitle, size: 9, weight: .regular, color: t.subtext, at: NSPoint(x: mid.x, y: mid.y - 10))
    }

    private func drawText(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                          at p: NSPoint, kern: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .kern: kern,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
    }

    // MARK: Glisser-déposer

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        track(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        track(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hovered = nil
        inCenter = false
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        inCenter = isInCenter(p)
        hovered = inCenter ? nil : hit(p)
        return hovered == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovered != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        guard !isInCenter(p), let slot = hit(p),
              slot.ring < rings.count, slot.index < rings[slot.ring].count else { return false }
        let action = rings[slot.ring][slot.index]
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        hovered = nil
        guard !urls.isEmpty else { return false }
        onDrop?(action, urls)
        return true
    }
}

// MARK: - Bulle de progression

@MainActor
final class ToastBackground: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = Theme.current(for: self)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        t.disc.setFill()
        path.fill()
        t.line.setStroke()
        path.lineWidth = 1
        path.stroke()
        // Petit trait bleu clair à gauche
        let bar = NSBezierPath(roundedRect: NSRect(x: 8, y: bounds.midY - 8, width: 3, height: 16), xRadius: 1.5, yRadius: 1.5)
        t.accent.setFill()
        bar.fill()
    }
}

@MainActor
final class Toast {
    private let panel: NSPanel
    private let label: NSTextField
    private let spinner: NSProgressIndicator
    private let stack: NSStackView
    private var generation = 0

    init() {
        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.isDisplayedWhenStopped = false

        let text = NSTextField(wrappingLabelWithString: "")
        text.font = .systemFont(ofSize: 12.5, weight: .medium)
        text.textColor = .labelColor
        text.preferredMaxLayoutWidth = 320
        text.maximumNumberOfLines = 4

        let st = NSStackView(views: [spin, text])
        st.orientation = .horizontal
        st.alignment = .centerY
        st.spacing = 8
        st.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 16)
        st.translatesAutoresizingMaskIntoConstraints = false

        let bg = ToastBackground()
        bg.addSubview(st)
        NSLayoutConstraint.activate([
            st.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            st.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            st.topAnchor.constraint(equalTo: bg.topAnchor),
            st.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = bg

        panel = p
        label = text
        spinner = spin
        stack = st
    }

    func show(_ text: String, spinning: Bool, near point: NSPoint, hideAfter: TimeInterval? = nil) {
        generation += 1
        let g = generation

        label.stringValue = text
        spinner.isHidden = !spinning
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let rect = NSRect(x: point.x - size.width / 2, y: point.y + 28, width: size.width, height: size.height)
        panel.setFrame(clampToScreen(rect, around: point), display: true)
        panel.contentView?.needsDisplay = true
        panel.invalidateShadow()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        if let delay = hideAfter {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.generation == g else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}
