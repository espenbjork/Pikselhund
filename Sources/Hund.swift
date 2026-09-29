import AppKit

/// Selve hunden: et gjennomsiktig vindu uten ramme med en pikselhund i, og
/// tilstandsmaskinen som får den til å logre, blunke, pese, mase og sove.
final class Hundevisning: NSView {

    enum Sinnstilstand: String {
        case sitter, tigger, sover, mage, gaar, snurrer, bukker, ball
        case henter, hundehus
    }

    private static let halerammer = ["hale-ned", "hale-midt", "hale-opp", "hale-midt"]
    private static let gangrammer = ["profil-gaa1", "profil", "profil-gaa2", "profil"]
    private static let snurrerammer = ["kropp", "bakfra"]
    /// Sekunder uten mus eller tastatur før hunden legger seg på ryggen.
    private static let sovegrense: Double = 90
    /// Hvor nær musepekeren må komme for å vekke den, i punkter.
    private static let vekkeavstand: CGFloat = 210
    /// Innenfor denne avstanden lener hunden seg mot pekeren.
    private static let lenegrense: CGFloat = 95
    /// Gangfart i punkter per sekund. Løpefart når den henter ball.
    private static let gangfart: CGFloat = 34
    private static let loepefart: CGFloat = 260
    private static let tyngde: CGFloat = 3000
    /// Vindustopper ligger typisk 250 til 800 punkter over skrivebordsgulvet,
    /// altså langt over det et fysisk troverdig hopp rekker. Hoppet beregnes
    /// derfor ut fra hvor høyt den faktisk skal, som i et plattformspill.
    private static let hoppehoyde: CGFloat = 620
    private static func fartForHopp(_ hoyde: CGFloat) -> CGFloat {
        sqrt(2 * tyngde * max(60, min(hoyde + 40, hoppehoyde)))
    }

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
    /// Låser posituren. Brukes av --vis for å fotografere bevegelsene.
    var laast = false

    private(set) var tilstand: Sinnstilstand = .sitter

    // Tid og humør
    private var tid: Double = 0
    private var spenning: Double = 0
    /// Systemets «reduser bevegelse». Da sitter hunden helt stille.
    private var rolig = false

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
    private var handlingTil: Double = 0

    // Slikking
    private var slikkeRest = 0
    private var slikkeTid: Double = 0
    private var slikkerNa = false

    // Søvn
    private var zListe: [(dy: Double, alder: Double)] = []
    private var nesteZ: Double = 0

    // Snurring
    private var snurrIndeks = 0
    private var snurrTid: Double = 0
    private var snurrRest = 0

    // Gåtur
    private var gaaFase = 0
    private var gaaHjem: CGFloat = 0
    private var gaaMaal: CGFloat = 0
    private var gaaIndeks = 0
    private var gaaTid: Double = 0
    private var snusTil: Double = 0

    // Ball
    private var ballPaaBakken = false

    // Løping over skjermen, med tyngdekraft og vinduer som plattformer
    private var maalPunkt: NSPoint?
    private var vedFramme: (() -> Void)?
    private var fartOpp: CGFloat = 0
    private var paaFlate: CGFloat?
    private var flater: [Vindusflater.Flate] = []
    private var flateTid: Double = 0
    private var harBall = false
    private var hentFrist: Double = 0
    private var hjemPunkt: NSPoint = .zero
    private var synlighet: CGFloat = 1
    private let sporer = CommandLine.arguments.contains("--spor")
    private var sporTid: Double = 0
    private var sisteSporetTilstand: Sinnstilstand?

    /// Vinduslaget under løpingen: sant når hunden skal ligge foran vinduene.
    var settNivaUnderveis: ((Bool) -> Void)?
    /// Kalles når ballen er nådd, så ballvinduet kan skjules.
    var vedBallTatt: (() -> Void)?

    // Retning og musepeker
    private var vendtSelv = false
    private var blikk = 0
    private var lening: CGFloat = 0
    private var sisteKlikk: Double = -10

    private var klokke: Timer?
    private var pauset = false
    private var vakter: [NSObjectProtocol] = []

    /// Kvota fra forbruksvakt. Hunden leser den, og humøret følger uka.
    let kvotevakt = Kvotevakt()

    init(piksler: Piksler) {
        self.piksler = piksler
        self.hjertebilde = piksler.bilde(["hjerte"])
        self.zbilde = piksler.bilde(["zzz"])
        super.init(frame: .zero)
        wantsLayer = true
        start()

        // Sover skjermen, er det ingen som ser hunden. Da er det ingen grunn
        // til å tegne 24 bilder i sekundet. Den tar fortsatt ingen strømsperre.
        let nc = NSWorkspace.shared.notificationCenter
        vakter.append(nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            self?.settPause(true)
        })
        vakter.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            self?.settPause(false)
        })
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let v = window else { return }
        vakter.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: v, queue: .main) { [weak self] _ in
                guard let self, let w = self.window else { return }
                self.settPause(!w.occlusionState.contains(.visible))
            })
    }

    /// Stopper klokka helt, i stedet for å la den gå og ikke tegne noe.
    /// En timer som fyrer 24 ganger i sekundet holder prosessoren våken selv
    /// om den ikke gjør noe.
    private func settPause(_ paa: Bool) {
        // En hund midt i et hopp eller en gåtur skal ikke fryse i lufta.
        if paa, [.henter, .gaar, .hundehus].contains(tilstand) { return }
        guard pauset != paa else { return }
        pauset = paa
        if paa {
            klokke?.invalidate()
            klokke = nil
        } else {
            start()
        }
    }

    required init?(coder: NSCoder) { fatalError("brukes ikke") }

    deinit {
        klokke?.invalidate()
        for v in vakter { NotificationCenter.default.removeObserver(v) }
    }

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
        kvotevakt.tikk()

        if sporer && sisteSporetTilstand != tilstand {
            sisteSporetTilstand = tilstand
            let k = kvotevakt.kvote
            print("spor tilstand=\(tilstand.rawValue) press=\(k.press) "
                  + "uke=\(k.claude?.uke.samlet.map { String(format: "%.0f", $0) } ?? "?") "
                  + "5t=\(k.claude?.femTimer.samlet.map { String(format: "%.0f", $0) } ?? "?")")
            fflush(stdout)
        }

        let varRolig = rolig
        rolig = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if rolig {
            // Systemet ber om mindre bevegelse. Da sitter hunden stille med
            // tunga inne. Den forsvinner ikke, den slutter bare å røre seg.
            if !varRolig { roNed(); needsDisplay = true }
            return
        }

        spenning = max(0, spenning - dt * 0.22)
        vedTikk?(dt)

        let mus = NSEvent.mouseLocation
        let ramme = window?.frame ?? .zero
        let senter = NSPoint(x: ramme.midX, y: ramme.minY + ramme.height * 0.4)
        let dx = mus.x - senter.x
        let avstand = hypot(dx, mus.y - senter.y)

        if !laast { styrTilstand(stille: sekunderStille(), avstand: avstand, dt: dt) }
        folgMusa(dx: dx, avstand: avstand)
        rullRammer(dt)
        needsDisplay = true
    }

    private func roNed() {
        tilstand = .sitter
        poteRest = 0; poteOppe = false
        slikkeRest = 0; slikkerNa = false
        snurrRest = 0; gaaFase = 3; ballPaaBakken = false
        hoppRest = 0
        hjerter.removeAll(); zListe.removeAll()
        vendtSelv = false; lening = 0; blikk = 0
        tungeUte = false
        haleIndeks = 1
    }

    // MARK: - Tilstand

    private func styrTilstand(stille: Double, avstand: CGFloat, dt: Double) {
        switch tilstand {
        case .sover:
            // Musepekeren kommer nærmere, og den beveger seg akkurat nå.
            if avstand < Hundevisning.vekkeavstand && stille < 1.0 { vaakne() }

        case .tigger, .bukker, .mage:
            if tid > handlingTil { tilstand = .sitter }

        case .ball:
            if tid > handlingTil {
                if ballPaaBakken {
                    ballPaaBakken = false
                    tilstand = .sitter
                } else {
                    // Legger ballen fra seg og venter på at noen kaster den.
                    ballPaaBakken = true
                    handlingTil = tid + 9
                }
            }

        case .snurrer:
            if snurrRest <= 0 { tilstand = .sitter; vendtSelv = false }

        case .gaar:
            gaaTur(dt)

        case .henter, .hundehus:
            loepMot(dt)

        case .sitter:
            // Er kvota brukt opp, er det ingenting å mase om. Da legger den
            // seg, men bare når du ikke akkurat har rørt noe.
            if kvotevakt.kvote.press == .tomt && stille > 20 { sovne(); return }
            if stille > Hundevisning.sovegrense { sovne(); return }
            if poteRest == 0 && slikkeRest == 0 && tid > nesteMas { mas() }
        }
    }

    /// Hunden maser. Rundt måltidene tigger den alltid, ellers trekker den
    /// tilfeldig blant tingene hunder maser om.
    private func mas() {
        switch kvotevakt.kvote.press {
        case .tomt:
            // Ikke mas om noe det ikke er dekning for.
            nesteMas = tid + 180
            return
        case .stramt:
            // Tigging er den bevegelsen som leser som «noe krever deg».
            tigg()
            handlingTil = tid + 4.5
            nesteMas = tid + Double.random(in: 150...300)
            return
        case .rolig:
            break
        }

        let time = Calendar.current.component(.hour, from: Date())
        let matklokke = [11, 12, 16, 17].contains(time)

        if matklokke {
            tigg()
            handlingTil = tid + 4.5
            nesteMas = tid + Double.random(in: 70...160)
            return
        }

        switch Int.random(in: 0..<6) {
        case 0: klappMedPoten()
        case 1: tigg(); handlingTil = tid + 4.5
        case 2: slikk()
        case 3: snurr()
        case 4: gaaTilfeldig()
        default: hentBallen()
        }
        nesteMas = tid + Double.random(in: 200...420)
    }

    private func sovne() {
        tilstand = .sover
        poteRest = 0; poteOppe = false; slikkeRest = 0
        zListe.removeAll()
        nesteZ = tid + 0.8
    }

    private func vaakne() {
        // Strekker seg først, slik hunder gjør når de har ligget lenge.
        tilstand = .bukker
        handlingTil = tid + 1.8
        zListe.removeAll()
        barGodbit?()
        bliGlad()
    }

    // MARK: - Enkeltbevegelser

    /// Tunga opp over nesa, tre svip.
    func slikk() {
        guard tilstand == .sitter || tilstand == .ball else { return }
        slikkeRest = 6
        slikkeTid = 0
    }

    /// Snurrer rundt på stedet, som når den vil ut.
    func snurr() {
        tilstand = .snurrer
        snurrRest = 10
        snurrTid = 0
        snurrIndeks = 0
    }

    /// Går bortover kanten, snuser der borte, og kommer tilbake dit den sto.
    func gaaTilfeldig() {
        guard let vindu = window else { return }
        let skjerm = NSScreen.screens.first { $0.frame.intersects(vindu.frame) } ?? NSScreen.main
        guard let synlig = skjerm?.visibleFrame else { return }
        let lengde = CGFloat.random(in: 90...220) * (Bool.random() ? 1 : -1)
        gaaHjem = vindu.frame.minX
        gaaMaal = min(max(gaaHjem + lengde, synlig.minX), synlig.maxX - vindu.frame.width)
        guard abs(gaaMaal - gaaHjem) > 20 else { return }
        tilstand = .gaar
        gaaFase = 0
        gaaIndeks = 0
        gaaTid = 0
    }

    private func gaaTur(_ dt: Double) {
        guard let vindu = window else { tilstand = .sitter; return }

        func gaaMot(_ maal: CGFloat) -> Bool {
            let na = vindu.frame.minX
            let igjen = maal - na
            if abs(igjen) < 2 { return true }
            vendtSelv = igjen < 0
            let steg = min(abs(igjen), Hundevisning.gangfart * CGFloat(dt)) * (igjen < 0 ? -1 : 1)
            vindu.setFrameOrigin(NSPoint(x: na + steg, y: vindu.frame.minY))
            return false
        }

        switch gaaFase {
        case 0:
            if gaaMot(gaaMaal) { gaaFase = 1; snusTil = tid + 2.2 }
        case 1:
            if tid > snusTil { gaaFase = 2 }
        case 2:
            if gaaMot(gaaHjem) {
                gaaFase = 3
                vendtSelv = false
                tilstand = .sitter
                (window as? Hundevindu)?.lagrePosisjon()
            }
        default:
            tilstand = .sitter
        }
    }

    /// Henter en ball som er kastet et sted på skjermen. Hunden løper dit,
    /// hopper opp på vinduer som er i veien, og kommer tilbake med den.
    func hentKastetBall(_ punkt: NSPoint) {
        guard let vindu = window else { return }
        // Sikrer at hunden starter på gulvet, ikke under det.
        let gulv = gulvet(vindu)
        if vindu.frame.minY < gulv {
            vindu.setFrameOrigin(NSPoint(x: vindu.frame.minX, y: gulv))
        }
        hjemPunkt = vindu.frame.origin
        maalPunkt = punkt
        harBall = false
        hentFrist = tid + 30
        vedFramme = { [weak self] in self?.tokBallen() }
        startLoep(.henter)
    }

    /// Går og legger seg i hundehuset. Når den er inne, er programmet ferdig.
    func gaaTilHuset(_ punkt: NSPoint, ferdig: @escaping () -> Void) {
        guard window != nil else { ferdig(); return }
        maalPunkt = punkt
        harBall = false
        hentFrist = tid + 30
        vedFramme = { [weak self] in
            guard let self else { return }
            self.vedFramme = nil
            self.maalPunkt = nil
            self.gaarInn = true
            self.innTil = self.tid + 0.9
            self.ferdigIHuset = ferdig
        }
        startLoep(.hundehus)
    }

    private var gaarInn = false
    private var innTil: Double = 0
    private var ferdigIHuset: (() -> Void)?

    private func startLoep(_ ny: Sinnstilstand) {
        tilstand = ny
        paaFlate = nil
        fartOpp = 0
        flateTid = 0
        synlighet = 1
        gaarInn = false
        zListe.removeAll()
    }

    private func gulvet(_ vindu: NSWindow) -> CGFloat {
        let skjerm = NSScreen.screens.first { $0.frame.intersects(vindu.frame) } ?? NSScreen.main
        return (skjerm?.visibleFrame.minY ?? 0) + 12
    }

    private func alleFlater(_ vindu: NSWindow) -> [Vindusflater.Flate] {
        let gulv = gulvet(vindu)
        let bredde = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        return flater + [Vindusflater.Flate(y: gulv, x0: bredde.minX - 50, x1: bredde.maxX + 50)]
    }

    private func loepMot(_ dt: Double) {
        guard let vindu = window else { tilstand = .sitter; return }

        if gaarInn {
            // Siste bit: hunden toner ut i døra, så avslutter programmet.
            synlighet = max(0, CGFloat((innTil - tid) / 0.9))
            if tid > innTil {
                let ferdig = ferdigIHuset
                ferdigIHuset = nil
                ferdig?()
            }
            return
        }

        if tid > flateTid {
            flater = Vindusflater.naa(utenomPid: Int(ProcessInfo.processInfo.processIdentifier))
            flateTid = tid + 0.4
        }

        if tid > hentFrist && !harBall {
            // Ga opp. Ballen blir liggende, hunden går hjem.
            vedBallTatt?()
            tokBallen()
        }

        let ramme = vindu.frame
        let midt = ramme.midX
        let fot = ramme.minY
        let mal = maalPunkt ?? NSPoint(x: hjemPunkt.x + ramme.width / 2, y: hjemPunkt.y)

        if sporer && tid > sporTid {
            sporTid = tid + 0.25
            print(String(format: "spor x=%.0f y=%.0f flate=%.0f mal=%.0f,%.0f ball=%@",
                         midt, fot, paaFlate ?? -1, mal.x, mal.y, harBall ? "ja" : "nei"))
            fflush(stdout)
        }
        let flateliste = alleFlater(vindu)

        // Er målet høyere enn der vi står, sikter vi mot en flate å hoppe opp på.
        var sikteX = mal.x
        var villHoppe = false
        var hoppTil: CGFloat = 0
        if let staar = paaFlate, mal.y > staar + 26 {
            // Flater innen rekkevidde, som også bringer oss nærmere målet.
            let mulige = flateliste.filter {
                $0.y > staar + 14 && $0.y <= staar + Hundevisning.hoppehoyde && $0.y <= mal.y + 40
            }
            let valgt = mulige.min { a, b in
                let da = abs(min(max(mal.x, a.x0), a.x1) - mal.x)
                let db = abs(min(max(mal.x, b.x0), b.x1) - mal.x)
                return da == db ? a.y > b.y : da < db
            }
            if let valgt {
                sikteX = min(max(mal.x, valgt.x0 + 24), valgt.x1 - 24)
                villHoppe = abs(midt - sikteX) < 26
                hoppTil = valgt.y - staar
            } else {
                // Ingen flate å lande på. Da hopper den rett opp etter ballen.
                sikteX = mal.x
                villHoppe = abs(midt - mal.x) < 26
                hoppTil = mal.y - staar
            }
        }

        // Vannrett
        let dx = sikteX - midt
        let fart: CGFloat = abs(dx) < 8 ? 0 : (dx < 0 ? -Hundevisning.loepefart : Hundevisning.loepefart)
        if fart != 0 { vendtSelv = fart < 0 }
        var nyX = ramme.minX + fart * CGFloat(dt)

        // Loddrett
        var nyY = fot
        if let staar = paaFlate {
            nyY = staar
            fartOpp = 0
            if villHoppe {
                fartOpp = Hundevisning.fartForHopp(hoppTil)
                paaFlate = nil
            } else if !flateliste.contains(where: { abs($0.y - staar) < 1.5 && $0.under(nyX + ramme.width / 2) }) {
                paaFlate = nil          // gikk utfor kanten
            }
        }
        if paaFlate == nil {
            fartOpp -= Hundevisning.tyngde * CGFloat(dt)
            nyY = fot + fartOpp * CGFloat(dt)
            if fartOpp <= 0 {
                let senter = nyX + ramme.width / 2
                let landing = flateliste
                    .filter { $0.under(senter) && fot >= $0.y - 1 && nyY <= $0.y }
                    .map(\.y).max()
                if let y = landing { nyY = y; fartOpp = 0; paaFlate = y }
            }
            // Gulvet er hardt. Uten dette faller hunden ut av skjermen hvis
            // den starter under gulvhøyden, for eksempel etter at en skjerm
            // er koblet til og den lagrede posisjonen ikke lenger gjelder.
            let gulvNa = gulvet(vindu)
            if nyY < gulvNa { nyY = gulvNa; fartOpp = 0; paaFlate = gulvNa }
        }

        let vidde = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        nyX = min(max(nyX, vidde.minX), vidde.maxX - ramme.width)
        vindu.setFrameOrigin(NSPoint(x: nyX, y: nyY))

        // Hunden ligger bak vinduene når den løper på gulvet, og foran når den
        // er i lufta eller står oppå et vindu. Det er slik den kommer seg
        // mellom, over og under dem.
        let gulv = gulvet(vindu)
        settNivaUnderveis?(paaFlate == nil || (paaFlate ?? gulv) > gulv + 4)

        if abs(vindu.frame.midX - mal.x) < 20 && abs(vindu.frame.minY - mal.y) < 70 {
            let naa = vedFramme
            if harBall || tilstand == .hundehus { vedFramme = nil }
            naa?()
        }
    }

    private func tokBallen() {
        if !harBall {
            harBall = true
            vedBallTatt?()
            hentFrist = tid + 30
            maalPunkt = nil                       // nå er målet hjem
            vedFramme = { [weak self] in self?.kommetHjem() }
        } else {
            kommetHjem()
        }
    }

    private func kommetHjem() {
        harBall = false
        vedFramme = nil
        maalPunkt = nil
        paaFlate = nil
        settNivaUnderveis?(true)
        (window as? Hundevindu)?.gjenopprettNiva()
        (window as? Hundevindu)?.lagrePosisjon()
        tilstand = .ball
        ballPaaBakken = true
        handlingTil = tid + 9
        bliGlad()
    }

    func leikebukk() {
        tilstand = .bukker
        handlingTil = tid + 2.2
    }

    func leggDegPaaRyggen() {
        tilstand = .mage
        handlingTil = tid + 6
        spenning = 1
    }

    func hentBallen() {
        tilstand = .ball
        handlingTil = tid + 3.5
        ballPaaBakken = false
    }

    func tigg() {
        tilstand = .tigger
        handlingTil = tid + 6
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
        if ny == .ball { ballPaaBakken = true }
        if ny == .snurrer { snurrRest = .max }
        if ny == .gaar { gaaFase = 0; gaaMaal = .greatestFiniteMagnitude }
    }

    // MARK: - Musepekeren

    private func folgMusa(dx: CGFloat, avstand: CGFloat) {
        // Positurer der hodet ikke er vendt mot skjermen har ikke blikk.
        let bortvendt: Set<Sinnstilstand> = [.sover, .gaar, .snurrer, .bukker, .mage, .henter, .hundehus]
        guard !bortvendt.contains(tilstand) else { blikk = 0; lening = 0; return }
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

        // Tellere som ruller hver ramme hører hjemme her, ikke i
        // tilstandsstyringen, ellers stopper de når posituren er låst.
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

        if slikkeRest > 0 {
            slikkeTid -= dt
            if slikkeTid <= 0 {
                slikkerNa.toggle()
                slikkeRest -= 1
                slikkeTid = 0.14
            }
            if slikkeRest == 0 { slikkerNa = false }
        }

        let gaar = (tilstand == .gaar && gaaFase != 1)
        if gaar || tilstand == .henter || tilstand == .hundehus {
            gaaTid += dt
            if gaaTid > (gaar ? 0.16 : 0.09) {
                gaaTid = 0
                gaaIndeks = (gaaIndeks + 1) % Hundevisning.gangrammer.count
            }
        }

        if snurrRest > 0 {
            snurrTid -= dt
            if snurrTid <= 0 {
                snurrIndeks += 1
                if snurrRest != .max { snurrRest -= 1 }
                snurrTid = 0.13
                // Annenhver halvrunde er speilvendt, så den ser ut til å snu seg.
                vendtSelv = (snurrIndeks / Hundevisning.snurrerammer.count) % 2 == 1
            }
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
    /// To klapp tett etter hverandre legger den på ryggen for magekos.
    func bliGlad() {
        if tilstand == .sover && !laast { vaakne(); return }
        if tid - sisteKlikk < 1.5 && tilstand == .sitter && !laast {
            sisteKlikk = -10
            leggDegPaaRyggen()
            return
        }
        sisteKlikk = tid
        if tilstand == .ball && ballPaaBakken {
            // Du kastet ballen. Da henter den den.
            ballPaaBakken = false
            handlingTil = tid + 3.5
        }
        spenning = 1
        hoppRest = hoppLengde
        tungeUte = true
        nesteTunge = tid + 0.5
        nesteMas = tid + Double.random(in: 200...420)
        hjerter.append((dy: 0, alder: 0))
        needsDisplay = true
    }

    // MARK: - Tegning

    private func lag() -> [String] {
        if rolig { return ["kropp", "hale-midt"] }

        switch tilstand {
        case .sover:
            return ["sover"]
        case .mage:
            return ["sover", "mage-vaken"]
        case .gaar:
            return [gaaFase == 1 ? "profil" : Hundevisning.gangrammer[gaaIndeks]]
        case .snurrer:
            return [Hundevisning.snurrerammer[snurrIndeks % Hundevisning.snurrerammer.count]]
        case .bukker:
            return ["leikebukk"]
        case .henter, .hundehus:
            var ut = [paaFlate == nil ? "profil-gaa1" : Hundevisning.gangrammer[gaaIndeks]]
            if harBall { ut.append("profil-ball") }
            return ut
        default:
            break
        }

        var lag = [tilstand == .tigger ? "tigger" : "kropp",
                   Hundevisning.halerammer[haleIndeks]]
        let harBallenIMunnen = tilstand == .ball && !ballPaaBakken
        if tilstand == .ball { lag.append(ballPaaBakken ? "ball" : "i-munnen") }
        if tilstand == .sitter && poteOppe { lag.append("pote-opp") }
        if tid < blunkerTil { lag.append("blunk") }
        if slikkerNa {
            lag.append("slikk")
        } else if tungeUte && !harBallenIMunnen {
            lag.append("tunge")
        }
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

    /// Hunden løftes i et hopp, nikker når den snuser, og puster ellers.
    private func loft() -> CGFloat {
        if hoppRest > 0 {
            let fremdrift = 1 - hoppRest / hoppLengde
            return CGFloat(sin(fremdrift * .pi) * 5)
        }
        if tilstand == .henter || tilstand == .hundehus { return 0 }
        if tilstand == .gaar && gaaFase == 1 { return sin(tid * 11) > 0 ? 1 : 0 }
        return sin(tid * 1.5) > 0.75 ? 1 : 0
    }

    /// Vrikking på ryggen, for den som vil ha magekos.
    private func vrikk() -> CGFloat {
        guard tilstand == .mage else { return 0 }
        return sin(tid * 9) > 0 ? 1 : 0
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current
        ctx?.imageInterpolation = .none
        ctx?.cgContext.interpolationQuality = .none

        // Profilrammene er tegnet mot høyre. Går hunden mot venstre, speiles
        // den, og det kommer i tillegg til brukerens egen speilvending.
        let flipp = speilvendt != vendtSelv
        if flipp, let cg = ctx?.cgContext {
            cg.saveGState()
            cg.translateBy(x: bounds.width, y: 0)
            cg.scaleBy(x: -1, y: 1)
        }

        let bredde = CGFloat(piksler.bredde) * skala
        let hoyde = CGFloat(piksler.hoyde) * skala
        let y = loft() * skala
        let x = (lening + vrikk()) * skala

        tegn(hundebilde(), x: x, y: y, bredde: bredde, hoyde: hoyde, alfa: synlighet)

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

        if flipp { ctx?.cgContext.restoreGState() }
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
        // Å ta tak i hunden avbryter en tur eller en snurring.
        if tilstand == .gaar || tilstand == .snurrer || tilstand == .henter {
            if tilstand == .henter { vedBallTatt?(); (window as? Hundevindu)?.gjenopprettNiva() }
            tilstand = .sitter
            vendtSelv = false
            harBall = false
            vedFramme = nil
        }
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
    private let ballen: Rekvisittvindu
    private let huset: Rekvisittvindu
    private let kastet = Kastevindu()
    private var klarTilAaLagre = false
    private var livvakt: Timer?

    init(piksler: Piksler) {
        self.piksler = piksler
        self.visning = Hundevisning(piksler: piksler)
        self.godbit = Godbitvindu(piksler: piksler, skala: Innstillinger.skala)
        self.ballen = Rekvisittvindu(piksler: piksler, ramme: "ball-alene", skala: Innstillinger.skala)
        self.huset = Rekvisittvindu(piksler: piksler, ramme: "hundehus", skala: Innstillinger.skala)
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
        visning.vedBallTatt = { [weak self] in self?.ballen.orderOut(nil) }
        visning.settNivaUnderveis = { [weak self] foran in
            guard let self else { return }
            self.level = foran
                ? .floating
                : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
        kastet.vedKlikk = { [weak self] punkt in
            self?.kastet.skjul()
            self?.kastTil(punkt)
        }
        kastet.vedAvbrudd = { [weak self] in self?.kastet.skjul() }

        // Rekkefølgen betyr noe: settSkala lagrer posisjon, og gjør den det
        // før plasser() har kjørt, arver hunden vindusrammens startpunkt i
        // nedre venstre hjørne i stedet for hjørnet den skal sitte i.
        visning.skala = Innstillinger.skala
        settNiva(Innstillinger.foran)
        visning.speilvendt = Innstillinger.speilvendt
        ignoresMouseEvents = Innstillinger.klikkGarGjennom

        plasser()
        klarTilAaLagre = true
        startLivvakt()
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
        ballen.settSkala(ny)
        huset.settSkala(ny)
        setContentSize(storrelse)
        setFrameOrigin(NSPoint(x: gammelMidt - storrelse.width / 2, y: gammelBunn))
        holdInnenforSkjerm()
        lagrePosisjon()
    }

    /// Ber om et klikk, og kaster ballen dit.
    func kastBallen() { kastet.vis() }

    /// Legger ballen i et punkt og sender hunden av gårde.
    func kastTil(_ punkt: NSPoint) {
        ballen.settSenter(punkt)
        ballen.alfa = 1
        ballen.orderFrontRegardless()
        visning.hentKastetBall(punkt)
    }

    /// Setter opp hundehuset og sender hunden inn i det. Når den er inne,
    /// avslutter appen.
    func sendIHuset(ferdig: @escaping () -> Void) {
        let skjerm = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let synlig = skjerm?.visibleFrame else { ferdig(); return }
        let gulv = synlig.minY + 12
        // Huset settes et stykke unna, så hunden faktisk går bort til det.
        var x = frame.midX + 150
        if x + huset.frame.width / 2 > synlig.maxX { x = frame.midX - 150 }
        x = min(max(x, synlig.minX + huset.frame.width / 2), synlig.maxX - huset.frame.width / 2)
        huset.settFot(x: x, gulv: gulv)
        huset.alfa = 1
        // Huset skal ligge foran hunden, ellers ser det ut som om den blir
        // stående utenfor i stedet for å gå inn.
        huset.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        huset.orderFrontRegardless()
        level = .floating
        visning.gaaTilHuset(NSPoint(x: x, y: gulv), ferdig: ferdig)
    }

    /// Setter vinduslaget tilbake til det brukeren har valgt.
    func gjenopprettNiva() { settNiva(Innstillinger.foran) }

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

    /// Går med lav frekvens og passer på at hunden er på en skjerm i det hele
    /// tatt. Den pauser aldri, i motsetning til animasjonsklokka, fordi en
    /// hund som havner utenfor skjermen blir usynlig, pauser seg selv, og
    /// dermed aldri kan redde seg ut igjen.
    private func startLivvakt() {
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.holdInnenforSkjerm()
        }
        RunLoop.main.add(t, forMode: .common)
        livvakt = t
    }

    /// Hindrer at hunden blir liggende utenfor kanten, for eksempel etter at
    /// en skjerm er koblet fra.
    func holdInnenforSkjerm() {
        // Krever at vinduet har reell overlapp, ikke bare berører en kant.
        // Et vindu på en frakoblet skjerm kan ellers se ut som om det er inne.
        let skjerm = NSScreen.screens.first {
            let felles = $0.frame.intersection(frame)
            return felles.width > 20 && felles.height > 20
        } ?? NSScreen.main
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
