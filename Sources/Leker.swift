import AppKit

/// Vinduene som ligger på skjermen, sett som flater hunden kan hoppe opp på.
enum Vindusflater {

    struct Flate {
        let y: CGFloat          // toppkanten, i AppKit-koordinater
        let x0: CGFloat
        let x1: CGFloat
        var midt: CGFloat { (x0 + x1) / 2 }
        func under(_ x: CGFloat, slark: CGFloat = 10) -> Bool { x0 - slark <= x && x <= x1 + slark }
    }

    /// Toppkanten av hvert vanlige vindu. Geometrien er offentlig og krever
    /// ingen tillatelse. Det er bare vindustitlene som er bak skjermopptak,
    /// og dem trenger vi ikke.
    static func naa(utenomPid egen: Int) -> [Flate] {
        guard let primaer = NSScreen.screens.first?.frame.height,
              let liste = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var ut: [Flate] = []
        for v in liste {
            guard let lag = v[kCGWindowLayer as String] as? Int, lag == 0,
                  let pid = v[kCGWindowOwnerPID as String] as? Int, pid != egen,
                  let b = v[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
                  w >= 140, h >= 80
            else { continue }
            // Quartz måler nedover fra toppen av hovedskjermen, AppKit oppover
            // fra bunnen. Toppkanten blir derfor høyden minus y.
            ut.append(Flate(y: primaer - y, x0: x, x1: x + w))
        }
        return ut
    }
}

/// Et lite vindu som viser en ramme et sted på skjermen: ballen, hundehuset.
/// Klikk går alltid gjennom, så rekvisittene aldri kommer i veien.
final class Rekvisittvindu: NSWindow {

    private final class Flate: NSView {
        var bilde: NSImage?
        var alfa: CGFloat = 1
        override func draw(_ dirtyRect: NSRect) {
            guard let bilde else { return }
            NSGraphicsContext.current?.imageInterpolation = .none
            bilde.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: alfa,
                       respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.none])
        }
    }

    private let flate = Flate()
    private let ruter: CGFloat
    private(set) var rammenavn = ""

    init(piksler: Piksler, ramme: String, skala: CGFloat) {
        self.ruter = CGFloat(piksler.bredde)
        super.init(contentRect: NSRect(x: 0, y: 0, width: ruter * skala, height: ruter * skala),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.rammenavn = ramme
        flate.bilde = piksler.ramme(ramme)
        contentView = flate
        settSkala(skala)
    }

    override var canBecomeKey: Bool { false }

    var skala: CGFloat { frame.width / ruter }

    func settBilde(_ b: NSImage) {
        flate.bilde = b
        flate.needsDisplay = true
    }

    func settSkala(_ ny: CGFloat) {
        setContentSize(NSSize(width: ruter * ny, height: ruter * ny))
    }

    var alfa: CGFloat {
        get { flate.alfa }
        set { flate.alfa = newValue; flate.needsDisplay = true }
    }

    /// Plasserer midten av ruta i et punkt. Brukes til ballen.
    func settSenter(_ punkt: NSPoint) {
        setFrameOrigin(NSPoint(x: punkt.x - frame.width / 2, y: punkt.y - frame.height / 2))
    }

    /// Plasserer bunnen av ruta på et gulv. Brukes til hundehuset, som skal
    /// stå på bakken og ikke sveve.
    func settFot(x: CGFloat, gulv: CGFloat) {
        // Rad 30 er bakkelinja i tegningene, ikke nederste rad.
        setFrameOrigin(NSPoint(x: x - frame.width / 2, y: gulv - skala))
    }
}

/// Gjennomsiktig fullskjermsvindu som fanger ett klikk, så ballen kan kastes
/// hvor som helst. Høyreklikk avbryter, og den gir opp av seg selv.
final class Kastevindu: NSWindow {

    private final class Flate: NSView {
        var vedKlikk: ((NSPoint) -> Void)?
        var vedAvbrudd: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0, alpha: 0.07).setFill()
            dirtyRect.fill()
            let tekst = "Klikk der ballen skal lande. Høyreklikk avbryter."
            let stil: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
            let str = NSAttributedString(string: tekst, attributes: stil)
            let boks = str.size()
            let pute: CGFloat = 12
            let ramme = NSRect(x: bounds.midX - boks.width / 2 - pute,
                               y: bounds.maxY - boks.height - 3 * pute,
                               width: boks.width + 2 * pute,
                               height: boks.height + pute)
            NSColor(white: 0, alpha: 0.55).setFill()
            NSBezierPath(roundedRect: ramme, xRadius: 9, yRadius: 9).fill()
            str.draw(at: NSPoint(x: ramme.minX + pute, y: ramme.minY + pute / 2))
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        override func mouseDown(with event: NSEvent) {
            vedKlikk?(NSEvent.mouseLocation)
        }

        override func rightMouseDown(with event: NSEvent) {
            vedAvbrudd?()
        }
    }

    private let flate = Flate()
    private var frist: Timer?

    var vedKlikk: ((NSPoint) -> Void)? {
        get { flate.vedKlikk } set { flate.vedKlikk = newValue }
    }
    var vedAvbrudd: (() -> Void)? {
        get { flate.vedAvbrudd } set { flate.vedAvbrudd = newValue }
    }

    init() {
        // Dekker alle skjermer, så ballen kan kastes hvor som helst.
        let alle = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        super.init(contentRect: alle, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = flate
    }

    override var canBecomeKey: Bool { false }

    func vis() {
        let alle = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        setFrame(alle, display: false)
        orderFrontRegardless()
        invalidateCursorRects(for: flate)
        // Glemmer brukeren at siktemodus står på, gir den opp selv.
        frist?.invalidate()
        frist = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            self?.vedAvbrudd?()
        }
    }

    func skjul() {
        frist?.invalidate()
        frist = nil
        orderOut(nil)
    }
}
