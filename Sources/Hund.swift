import AppKit

/// Selve hunden: et gjennomsiktig vindu uten ramme med en pikselhund i, og
/// tilstandsmaskinen som får den til å logre, blunke, pese, mase og sove.
final class Hundevisning: NSView {

    enum Sinnstilstand: String { case sitter, tigger, sover }

    private static let halerammer = ["hale-ned", "hale-midt", "hale-opp", "hale-midt"]
    /// Sekunder uten mus eller tastatur før hunden legger seg på ryggen.
    private static let sovegrense: Double = 90
    /// Hvor nær musepekeren må komme for å vekke den, i punkter.
    private static let vekkeavstand: CGFloat = 210
    /// Innenfor denne avstanden lener hunden seg mot pekeren.
    private static let lenegrense: CGFloat = 95

    private let piksler: Piksler
    private var bildebuffer: [String: NSImage] = [:]
    private let hjertebilde: NSImage
    private let zbilde: NSImage

    /// Rader med luft over hunden, så hopp, hjerter og z-er får plass.
    static let hodeplass = 10

    var skala: CGFloat = 3 { didSet { needsDisplay = true } }
    var speilvendt = false { didSet { needsDisplay = true } }
    /// Kalles hver ramme, så vinduet kan flytte godbiten etter musepekeren.
    var vedTikk: ((Double) -> Void)?
    /// Kalles når hunden våkner, og musepekeren skal komme med en godbit.
    var barGodbit: (() -> Void)?
    /// Låser posituten. Brukes av --vis for å ta bilder av bevegelsene.
    var laast = false

    private(set) var tilstand: Sinnstilstand = .sitter

    // Tid og humør
    private var tid: Double = 0
    private var spenning: Double = 0

    // Hale, øyne, tunge, pust
    private var haleIndeks = 0
    private var haleTid: Double = 0
    private var blunkerTil: Double = -1
    private var nesteBlunk: Double = 3
    private var tungeUte = true
    private var nesteTunge: Double = 2

    // Hopp og hjerter
    private var hoppRest: Double = 0
    private let hoppLengde: Double = 0.45
    private var hjerter: [(dy: Double, alder: Double)] = []

    // Masing
    private var nesteMas: Double = 200
    private var poteRest = 0
    private var poteOppe = false
    private var poteTid: Double = 0
    private var tiggerTil: Double = 0

    // Søvn
    private var zListe: [(dy: Double, alder: Double)] = []
    private var nesteZ: Double = 0

    // Musepekeren
    private var blikk = 0
    private var lening: CGFloat = 0

    private var klokke: Timer?

    init(piksler: Piksler) {
        self.piksler = piksler
        self.hjertebilde = piksler.bilde(["hjerte"])
        self.zbilde = piksler.bilde(["zzz"])
        super.init(frame: .zero)
        wantsLayer = true
        start()
    }

    required init?(coder: NSCoder) { fatalError("brukes ikke") }

    deinit { klokke?.invalidate() }

    // MARK: - Klokka

    private func start() {
        let steg = 1.0 / 24.0
        let t = Timer(timeInterval: steg, repeats: true) { [weak self] _ in self?.tikk(steg) }
        // .common gjør at hunden logrer videre mens en meny står åpen eller
        // vinduet dras. Uten dette fryser den midt i draget.
        RunLoop.main.add(t, forMode: .common)
        klokke = t
    }

    /// Sekunder siden brukeren sist rørte mus eller tastatur. Trenger ingen
    /// tilgang å be om, i motsetning til en hendelseslytter.
    private func sekunderStille() -> Double {
        let typer: [CGEventType] = [.mouseMoved, .keyDown, .scrollWheel,
                                    .leftMouseDown, .rightMouseDown, .flagsChanged]
        return typer
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    private func tikk(_ dt: Double) {
        tid += dt
        spenning = max(0, spenning - dt * 0.22)
        vedTikk?(dt)

        let mus = NSEvent.mouseLocation
        let ramme = window?.frame ?? .zero
        let senter = NSPoint(x: ramme.midX, y: ramme.minY + ramme.height * 0.4)
        let dx = mus.x - senter.x
        let avstand = hypot(dx, mus.y - senter.y)
        let stille = sekunderStille()

        if !laast { styrTilstand(stille: stille, avstand: avstand, dt: dt) }
        folgMusa(dx: dx, avstand: avstand)
        rullRammer(dt)
        needsDisplay = true
    }

    // MARK: - Tilstand

    private func styrTilstand(stille: Double, avstand: CGFloat, dt: Double) {
        switch tilstand {
        case .sover:
            // Musepekeren kommer nærmere, og den beveger seg akkurat nå.
            if avstand < Hundevisning.vekkeavstand && stille < 1.0 { vaakne() }

        case .tigger:
            if tid > tiggerTil { tilstand = .sitter }

        case .sitter:
            if stille > Hundevisning.sovegrense { sovne(); return }
            if poteRest == 0 && tid > nesteMas { mas() }
        }
    }

    /// Hunden maser: enten dulter den borti deg med poten, eller så tigger den.
    /// Rundt måltidene tigger den alltid, og oftere.
    private func mas() {
        let time = Calendar.current.component(.hour, from: Date())
        let matklokke = [11, 12, 16, 17].contains(time)

        if matklokke || Bool.random() {
            tilstand = .tigger
            tiggerTil = tid + 4.5
            tungeUte = true
        } else {
            poteRest = 6
            poteTid = 0
        }
        nesteMas = tid + (matklokke ? Double.random(in: 70...160) : Double.random(in: 240...480))
    }

    private func sovne() {
        tilstand = .sover
        poteRest = 0
        poteOppe = false
        zListe.removeAll()
        nesteZ = tid + 0.8
    }

    private func vaakne() {
        tilstand = .tigger
        tiggerTil = tid + 5
        zListe.removeAll()
        barGodbit?()
        bliGlad()
    }

    /// Menyvalgene, som ber om en bevegelse uten å låse den.
    func tigg() {
        tilstand = .tigger
        tiggerTil = tid + 6
        tungeUte = true
        nesteTunge = tid + 1
    }

    func klappMedPoten() {
        guard tilstand != .sover else { vaakne(); return }
        tilstand = .sitter
        poteRest = 6
        poteTid = 0
    }

    func leggDeg() { sovne() }

    /// Låser hunden i én positur, for skjermbilder og feilsøking.
    func lasTil(_ ny: Sinnstilstand) {
        tilstand = ny
        laast = true
        if ny == .sover { nesteZ = tid + 0.4 }
        if ny == .sitter { poteRest = .max; poteTid = 0 }
    }

    // MARK: - Musepekeren

    private func folgMusa(dx: CGFloat, avstand: CGFloat) {
        guard tilstand != .sover else { blikk = 0; lening = 0; return }
        let retning: CGFloat = speilvendt ? -1 : 1
        blikk = abs(dx) < 30 ? 0 : (dx * retning < 0 ? -1 : 1)
        // Kommer pekeren helt inntil, dytter hunden snuten mot den.
        lening = avstand < Hundevisning.lenegrense
            ? max(-2, min(2, dx * retning / 45))
            : 0
    }

    // MARK: - Løpende animasjon

    private func rullRammer(_ dt: Double) {
        haleTid -= dt
        if haleTid <= 0 {
            haleIndeks = (haleIndeks + 1) % Hundevisning.halerammer.count
            haleTid = 0.19 - 0.12 * spenning
        }

        if tid > nesteBlunk {
            blunkerTil = tid + 0.13
            nesteBlunk = tid + Double.random(in: 2.5...6.5)
        }

        if tid > nesteTunge {
            tungeUte.toggle()
            nesteTunge = tid + (spenning > 0.4
                                ? Double.random(in: 0.18...0.3)
                                : Double.random(in: 1.2...2.8))
        }

        if hoppRest > 0 { hoppRest = max(0, hoppRest - dt) }

        if tilstand == .sover && tid > nesteZ {
            zListe.append((dy: 0, alder: 0))
            nesteZ = tid + 1.7
        }

        if poteRest > 0 {
            poteTid -= dt
            if poteTid <= 0 {
                poteOppe.toggle()
                poteRest -= 1
                poteTid = 0.16
            }
            if poteRest == 0 { poteOppe = false }
        }

        hjerter = hjerter.compactMap { h in
            let alder = h.alder + dt
            return alder > 1.4 ? nil : (dy: h.dy + dt * 7.5, alder: alder)
        }
        zListe = zListe.compactMap { z in
            let alder = z.alder + dt
            return alder > 2.4 ? nil : (dy: z.dy + dt * 3.2, alder: alder)
        }
    }

    /// Hunden blir glad: hopper, logrer fort og får hjerter over hodet.
    func bliGlad() {
        if tilstand == .sover && !laast { vaakne(); return }
        spenning = 1
        hoppRest = hoppLengde
        tungeUte = true
        nesteTunge = tid + 0.5
        nesteMas = tid + Double.random(in: 240...480)
        hjerter.append((dy: 0, alder: 0))
        needsDisplay = true
    }

    // MARK: - Tegning

    private func lag() -> [String] {
        if tilstand == .sover { return ["sover"] }

        var lag = [tilstand == .tigger ? "tigger" : "kropp",
                   Hundevisning.halerammer[haleIndeks]]
        if tilstand == .sitter && poteOppe { lag.append("pote-opp") }
        if tid < blunkerTil { lag.append("blunk") }
        if tungeUte { lag.append("tunge") }
        if blikk < 0 { lag.append("blikk-venstre") } else if blikk > 0 { lag.append("blikk-hoyre") }
        return lag
    }

    private func hundebilde() -> NSImage {
        let lagnavn = lag()
        let nokkel = lagnavn.joined(separator: "+")
        if let ferdig = bildebuffer[nokkel] { return ferdig }
        let nytt = piksler.bilde(lagnavn)
        bildebuffer[nokkel] = nytt
        return nytt
    }

    /// Hunden løftes i et hopp, og puster rolig ellers.
    private func loft() -> CGFloat {
        if hoppRest > 0 {
            let fremdrift = 1 - hoppRest / hoppLengde
            return CGFloat(sin(fremdrift * .pi) * 5)
        }
        return sin(tid * 1.5) > 0.75 ? 1 : 0
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current
        ctx?.imageInterpolation = .none
        ctx?.cgContext.interpolationQuality = .none

        if speilvendt, let cg = ctx?.cgContext {
            cg.saveGState()
            cg.translateBy(x: bounds.width, y: 0)
            cg.scaleBy(x: -1, y: 1)
        }

        let bredde = CGFloat(piksler.bredde) * skala
        let hoyde = CGFloat(piksler.hoyde) * skala
        let y = loft() * skala
        let x = lening * skala

        tegn(hundebilde(), x: x, y: y, bredde: bredde, hoyde: hoyde, alfa: 1)

        for h in hjerter {
            let alfa = h.alder < 0.2 ? h.alder / 0.2 : max(0, 1 - (h.alder - 0.2) / 1.2)
            tegn(hjertebilde, x: x, y: y + CGFloat(h.dy) * skala,
                 bredde: bredde, hoyde: hoyde, alfa: CGFloat(alfa))
        }
        for z in zListe {
            let alfa = z.alder < 0.3 ? z.alder / 0.3 : max(0, 1 - (z.alder - 0.3) / 2.1)
            tegn(zbilde, x: 0, y: CGFloat(z.dy) * skala,
                 bredde: bredde, hoyde: hoyde, alfa: CGFloat(alfa))
        }

        if speilvendt { ctx?.cgContext.restoreGState() }
    }

    private func tegn(_ bilde: NSImage, x: CGFloat, y: CGFloat,
                      bredde: CGFloat, hoyde: CGFloat, alfa: CGFloat) {
        bilde.draw(in: NSRect(x: x, y: y, width: bredde, height: hoyde),
                   from: .zero, operation: .sourceOver, fraction: alfa,
                   respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.none])
    }

    // MARK: - Mus

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var dragStart: NSPoint?
    private var vindusStart: NSPoint?

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        vindusStart = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let opprinnelig = vindusStart, let vindu = window else { return }
        let na = NSEvent.mouseLocation
        vindu.setFrameOrigin(NSPoint(x: opprinnelig.x + (na.x - start.x),
                                     y: opprinnelig.y + (na.y - start.y)))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; vindusStart = nil }
        guard let start = dragStart else { return }
        let na = NSEvent.mouseLocation
        if hypot(na.x - start.x, na.y - start.y) < 4 {
            bliGlad()
        } else {
            (window as? Hundevindu)?.lagrePosisjon()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let meny = (window as? Hundevindu)?.meny else { return }
        NSMenu.popUpContextMenu(meny, with: event, for: self)
    }
}

/// Godbiten musepekeren kommer med. Eget vindu, fordi pekeren kan være hvor
/// som helst på skjermen, langt utenfor hundens eget vindu.
final class Godbitvindu: NSWindow {

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
    private var restTid: Double = 0

    init(piksler: Piksler, skala: CGFloat) {
        self.ruter = CGFloat(piksler.bredde)
        super.init(contentRect: NSRect(x: 0, y: 0, width: ruter * skala, height: ruter * skala),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Godbiten skal aldri komme i veien for et klikk.
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        flate.bilde = piksler.bilde(["godbit"])
        contentView = flate
        settSkala(skala)
    }

    override var canBecomeKey: Bool { false }

    func settSkala(_ skala: CGFloat) {
        setContentSize(NSSize(width: ruter * skala, height: ruter * skala))
    }

    func vis(sekunder: Double = 2.8) {
        restTid = sekunder
        flytt()
        orderFrontRegardless()
    }

    func tikk(_ dt: Double) {
        guard restTid > 0 else { return }
        restTid -= dt
        flate.alfa = min(1, CGFloat(restTid) / 0.5)
        flytt()
        flate.needsDisplay = true
        if restTid <= 0 { orderOut(nil) }
    }

    /// Beinet ligger midt i ruta si, forskjøvet ned til høyre for pilspissen.
    private func flytt() {
        let skala = frame.width / ruter
        let mus = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: mus.x + 20 - 14.5 * skala,
                               y: mus.y - 16 - 16.5 * skala))
    }
}

/// Vinduet hunden sitter i: uten ramme, gjennomsiktig, uten skygge,
/// og med på alle skrivebord.
final class Hundevindu: NSWindow {

    let visning: Hundevisning
    var meny: NSMenu?

    private let piksler: Piksler
    private let godbit: Godbitvindu
    private var klarTilAaLagre = false

    init(piksler: Piksler) {
        self.piksler = piksler
        self.visning = Hundevisning(piksler: piksler)
        self.godbit = Godbitvindu(piksler: piksler, skala: Innstillinger.skala)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
        // Hunden skal følge med til alle skrivebord og ikke gli med når
        // Mission Control flytter vinduer.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = visning

        visning.vedTikk = { [weak self] dt in self?.godbit.tikk(dt) }
        visning.barGodbit = { [weak self] in self?.godbit.vis() }

        // Rekkefølgen betyr noe: settSkala lagrer posisjon, og gjør den det
        // før plasser() har kjørt, arver hunden vindusrammens startpunkt i
        // nedre venstre hjørne i stedet for hjørnet den skal sitte i.
        visning.skala = Innstillinger.skala
        settNiva(Innstillinger.foran)
        visning.speilvendt = Innstillinger.speilvendt
        ignoresMouseEvents = Innstillinger.klikkGarGjennom

        plasser()
        klarTilAaLagre = true
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var storrelse: NSSize {
        NSSize(width: CGFloat(piksler.bredde) * visning.skala,
               height: CGFloat(piksler.hoyde + Hundevisning.hodeplass) * visning.skala)
    }

    func settSkala(_ ny: CGFloat) {
        let gammelMidt = frame.midX
        let gammelBunn = frame.minY
        visning.skala = ny
        Innstillinger.skala = ny
        godbit.settSkala(ny)
        setContentSize(storrelse)
        setFrameOrigin(NSPoint(x: gammelMidt - storrelse.width / 2, y: gammelBunn))
        holdInnenforSkjerm()
        lagrePosisjon()
    }

    func settNiva(_ foran: Bool) {
        Innstillinger.foran = foran
        level = foran
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        orderFrontRegardless()
    }

    private func plasser() {
        setContentSize(storrelse)
        if let lagret = Innstillinger.posisjon {
            setFrameOrigin(lagret)
        } else if let skjerm = NSScreen.main {
            let synlig = skjerm.visibleFrame
            setFrameOrigin(NSPoint(x: synlig.maxX - storrelse.width - 40, y: synlig.minY + 12))
        }
        holdInnenforSkjerm()
    }

    /// Hindrer at hunden blir liggende utenfor kanten, for eksempel etter at
    /// en skjerm er koblet fra.
    func holdInnenforSkjerm() {
        let skjerm = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let synlig = skjerm?.visibleFrame else { return }
        var punkt = frame.origin
        punkt.x = min(max(punkt.x, synlig.minX), synlig.maxX - frame.width)
        punkt.y = min(max(punkt.y, synlig.minY), synlig.maxY - frame.height)
        setFrameOrigin(punkt)
    }

    func lagrePosisjon() {
        guard klarTilAaLagre else { return }
        Innstillinger.posisjon = frame.origin
    }

    /// Lar godbiten bli stående, så den kan fotograferes. Brukes av --vis.
    func visGodbitLenge() { godbit.vis(sekunder: 600) }
}

/// Alt som skal huskes mellom kjøringer.
enum Innstillinger {
    private static let d = UserDefaults.standard

    static var skala: CGFloat {
        get { d.object(forKey: "skala") as? CGFloat ?? 3 }
        set { d.set(newValue, forKey: "skala") }
    }
    static var foran: Bool {
        get { d.object(forKey: "foran") as? Bool ?? true }
        set { d.set(newValue, forKey: "foran") }
    }
    static var speilvendt: Bool {
        get { d.bool(forKey: "speilvendt") }
        set { d.set(newValue, forKey: "speilvendt") }
    }
    static var klikkGarGjennom: Bool {
        get { d.bool(forKey: "klikkGarGjennom") }
        set { d.set(newValue, forKey: "klikkGarGjennom") }
    }
    static var posisjon: NSPoint? {
        get {
            guard d.object(forKey: "x") != nil else { return nil }
            return NSPoint(x: d.double(forKey: "x"), y: d.double(forKey: "y"))
        }
        set {
            guard let p = newValue else { return }
            d.set(Double(p.x), forKey: "x")
            d.set(Double(p.y), forKey: "y")
        }
    }
}
