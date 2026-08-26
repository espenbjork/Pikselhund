import AppKit
import ServiceManagement

@main
enum Pikselhund {
    static func main() {
        let app = NSApplication.shared
        let delegat = Delegat()
        app.delegate = delegat
        // Ingen ikon i Dock. Hunden bor på skrivebordet og i menylinja.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class Delegat: NSObject, NSApplicationDelegate {

    private var vindu: Hundevindu?
    private var menylinje: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let fil = Bundle.main.url(forResource: "pikselhund", withExtension: "txt") else {
            klag(Piksler.Feil.fantIkkeFil)
            return
        }

        do {
            let piksler = try Piksler(fil: fil)
            let v = Hundevindu(piksler: piksler)
            v.meny = byggMeny()
            vindu = v
            // --vis <positur> låser hunden, så bevegelsene kan fotograferes.
            let onsket = CommandLine.arguments.firstIndex(of: "--vis")
                .flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
            if let onsket, let positur = Hundevisning.Sinnstilstand(rawValue: onsket) {
                v.visning.lasTil(positur)
            } else if onsket == "godbit" {
                v.visGodbitLenge()
            } else if onsket == "tur" {
                // Går en tur uten å låses, så gangen kan fotograferes.
                v.visning.gaaTilfeldig()
            } else if onsket == "vekking" {
                // Legger den til å sove uten å låse den, så den ekte
                // vekkeutløseren fortsatt gjelder.
                v.visning.leggDeg()
            } else {
                // Hunden er glad for å se deg.
                v.visning.bliGlad()
            }
        } catch {
            klag(error)
            return
        }

        let element = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        element.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Pikselhund")
        element.button?.image?.isTemplate = true
        element.menu = byggMeny()
        menylinje = element

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.vindu?.holdInnenforSkjerm()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func klag(_ feil: Error) {
        let varsel = NSAlert()
        varsel.messageText = "Pikselhund fikk ikke tegnet hunden"
        varsel.informativeText = feil.localizedDescription
        varsel.alertStyle = .critical
        varsel.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Meny

    private func byggMeny() -> NSMenu {
        let meny = NSMenu()
        meny.autoenablesItems = false

        meny.addItem(punkt("Klapp hunden", #selector(klapp), nokkel: ""))

        let bevegelser = NSMenu()
        for (navn, handling) in [("Klappe med poten", #selector(poteklapp)),
                                 ("Tigge", #selector(tigg)),
                                 ("Slikke seg om munnen", #selector(slikke)),
                                 ("Snurre en runde", #selector(snurre)),
                                 ("Gå en tur langs kanten", #selector(gaaTur)),
                                 ("Hente ballen", #selector(ball)),
                                 ("Ta en leikebukk", #selector(bukk)),
                                 ("Legge seg på ryggen", #selector(paaRyggen)),
                                 ("Legge seg til å sove", #selector(leggDeg))] {
            bevegelser.addItem(punkt(navn, handling, nokkel: ""))
        }
        let bevegelsesvalg = NSMenuItem(title: "Be den om noe", action: nil, keyEquivalent: "")
        bevegelsesvalg.submenu = bevegelser
        meny.addItem(bevegelsesvalg)

        meny.addItem(punkt("Hent hunden hit", #selector(hentHit), nokkel: ""))
        meny.addItem(.separator())

        let storrelse = NSMenu()
        for (navn, verdi) in [("Liten", CGFloat(2)), ("Middels", 3), ("Stor", 4), ("Kjempe", 6)] {
            let p = punkt(navn, #selector(byttStorrelse), nokkel: "")
            p.representedObject = verdi
            p.state = Innstillinger.skala == verdi ? .on : .off
            storrelse.addItem(p)
        }
        let storrelsesvalg = NSMenuItem(title: "Størrelse", action: nil, keyEquivalent: "")
        storrelsesvalg.submenu = storrelse
        meny.addItem(storrelsesvalg)

        let bak = punkt("Ligg bak vinduene", #selector(byttNiva), nokkel: "")
        bak.state = Innstillinger.foran ? .off : .on
        meny.addItem(bak)

        let speil = punkt("Speilvend", #selector(byttSpeil), nokkel: "")
        speil.state = Innstillinger.speilvendt ? .on : .off
        meny.addItem(speil)

        let gjennom = punkt("La klikk gå gjennom hunden", #selector(byttGjennomklikk), nokkel: "")
        gjennom.state = Innstillinger.klikkGarGjennom ? .on : .off
        meny.addItem(gjennom)

        meny.addItem(.separator())

        let paalogging = punkt("Start ved pålogging", #selector(byttPaalogging), nokkel: "")
        paalogging.state = SMAppService.mainApp.status == .enabled ? .on : .off
        meny.addItem(paalogging)

        meny.addItem(.separator())
        meny.addItem(punkt("Avslutt Pikselhund", #selector(avslutt), nokkel: "q"))
        return meny
    }

    private func punkt(_ tittel: String, _ handling: Selector, nokkel: String) -> NSMenuItem {
        let p = NSMenuItem(title: tittel, action: handling, keyEquivalent: nokkel)
        p.target = self
        p.isEnabled = true
        return p
    }

    private func byggMenyerPaaNytt() {
        menylinje?.menu = byggMeny()
        vindu?.meny = byggMeny()
    }

    // MARK: - Handlinger

    @objc private func klapp() { vindu?.visning.bliGlad() }

    @objc private func tigg() { vindu?.visning.tigg() }

    @objc private func poteklapp() { vindu?.visning.klappMedPoten() }

    @objc private func slikke() { vindu?.visning.slikk() }

    @objc private func snurre() { vindu?.visning.snurr() }

    @objc private func gaaTur() { vindu?.visning.gaaTilfeldig() }

    @objc private func ball() { vindu?.visning.hentBallen() }

    @objc private func bukk() { vindu?.visning.leikebukk() }

    @objc private func paaRyggen() { vindu?.visning.leggDegPaaRyggen() }

    @objc private func leggDeg() { vindu?.visning.leggDeg() }

    @objc private func hentHit() {
        guard let vindu, let skjerm = NSScreen.main else { return }
        let synlig = skjerm.visibleFrame
        vindu.setFrameOrigin(NSPoint(x: synlig.midX - vindu.frame.width / 2, y: synlig.minY + 12))
        vindu.lagrePosisjon()
        vindu.visning.bliGlad()
    }

    @objc private func byttStorrelse(_ avsender: NSMenuItem) {
        guard let verdi = avsender.representedObject as? CGFloat else { return }
        vindu?.settSkala(verdi)
        byggMenyerPaaNytt()
    }

    @objc private func byttNiva() {
        vindu?.settNiva(!Innstillinger.foran)
        byggMenyerPaaNytt()
    }

    @objc private func byttSpeil() {
        Innstillinger.speilvendt.toggle()
        vindu?.visning.speilvendt = Innstillinger.speilvendt
        byggMenyerPaaNytt()
    }

    @objc private func byttGjennomklikk() {
        Innstillinger.klikkGarGjennom.toggle()
        vindu?.ignoresMouseEvents = Innstillinger.klikkGarGjennom
        byggMenyerPaaNytt()
    }

    @objc private func byttPaalogging() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let varsel = NSAlert()
            varsel.messageText = "Fikk ikke endret oppstart ved pålogging"
            // Ad-hoc signerte apper utenfor /Applications blir ofte avvist her.
            varsel.informativeText = error.localizedDescription
            varsel.runModal()
        }
        byggMenyerPaaNytt()
    }

    @objc private func avslutt() {
        vindu?.lagrePosisjon()
        NSApp.terminate(nil)
    }
}
