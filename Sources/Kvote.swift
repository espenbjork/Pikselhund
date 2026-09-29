import AppKit

/// Kvota fra forbruksvakt, oversatt til noe hunden og menylinja kan vise.
///
/// Tallene kommer fra `~/.forbruksvakt/status.json`, som skrives av
/// `forbruksvakt.py`. Hunden kjører det skriptet selv med noen minutters
/// mellomrom, siden det tar under et sekund og ellers ville stått stille.
///
/// Uka er den bindende grensa, ikke femtimersvinduet. Se notatet
/// ukeskvota-rommer-ni-femtimersvinduer-ikke-trettitre: et fullt femtimersvindu
/// koster rundt ti prosent av uka, så uka rommer bare ni eller ti av dem.
/// Derfor følger hundens humør uka.
/// At et vindu som var trangt har rullet rundt, og det er plass igjen.
struct Nyperiode {
    let hvem: Kvote.Anbefaling
    let vindu: String
    let aapnet: Date
    var alder: TimeInterval { -aapnet.timeIntervalSinceNow }
}

struct Kvote {

    enum Press {
        case rolig      // god plass
        case stramt     // et vindu over 75 prosent
        case tomt       // et vindu over 90 prosent

        var beskrivelse: String {
            switch self {
            case .rolig: return "god plass"
            case .stramt: return "det begynner å bli stramt"
            case .tomt: return "kvota er brukt opp"
            }
        }
    }

    /// Hvem det er billigst å bruke nå. `ingen` betyr enten at begge er fulle,
    /// eller at vi ikke har tall nok til å si det. Hunden bærer ingen leke da.
    enum Anbefaling {
        case claude, codex, ingen

        var navn: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "ChatGPT"
            case .ingen: return "ingen"
            }
        }

        /// Rammenavnet på leka hunden holder i munnen.
        var leke: String? {
            switch self {
            case .claude: return "lek-claude"
            case .codex: return "lek-codex"
            case .ingen: return nil
            }
        }

        var andre: Anbefaling {
            switch self {
            case .claude: return .codex
            case .codex: return .claude
            case .ingen: return .ingen
            }
        }
    }

    struct Vindu {
        var prosent: Double?
        /// Selve øyeblikket vinduet nullstilles, ikke sekunder til det.
        /// Sekunder regnet ut da fila ble skrevet drar med seg filas alder, og
        /// da kan et vindu som står stille se ut som om det flytter seg.
        var nullstillesKl: Date?
        var alderSek: Double?
        /// Bare uka for Claude: det lokale forbruket siden fasiten ble hentet.
        var tilleggLokalt: Double?
        /// «fasit», «anslag», «nullstilt» eller «for gammel».
        var kilde: String?

        var nullstillesOmSek: Double? { nullstillesKl?.timeIntervalSinceNow }

        /// Er nullstillinga passert, er vinduet for lengst rullet rundt, og
        /// tallet gjelder et vindu som ikke finnes lenger.
        var utloept: Bool { (nullstillesOmSek ?? 1) <= 0 }

        /// Fasit pluss det vi selv har sett siden. Aldri over hundre.
        var samlet: Double? {
            guard let p = prosent else { return nil }
            return min(100, p + (tilleggLokalt ?? 0))
        }
    }

    struct Leverandor {
        var navn: String
        var plan: String?
        var alderSek: Double?
        var femTimer = Vindu()
        var uke = Vindu()
    }

    var claude: Leverandor?
    var codex: Leverandor?
    var lest: Date?

    /// Hvor trangt det er hos en leverandør: det verste av de to vinduene.
    func rom(_ hvem: Anbefaling) -> Double? {
        let l: Leverandor?
        switch hvem {
        case .claude: l = claude
        case .codex: l = codex
        case .ingen: l = nil
        }
        guard let l else { return nil }
        return [l.uke.samlet, l.femTimer.samlet].compactMap { $0 }.max()
    }

    /// Presset styres av det verste vinduet hos begge, fordi hunden bare har
    /// ett humør. Selve valget av leverandør ligger i `Kvotevakt.anbefaling`.
    var press: Press {
        let verst = [rom(.claude), rom(.codex)].compactMap { $0 }.max() ?? 0
        if verst >= 90 { return .tomt }
        if verst >= 75 { return .stramt }
        return .rolig
    }

    var harTall: Bool { claude != nil || codex != nil }
}

/// Holder kvota fersk. Kjører forbruksvakt.py i bakgrunnen og leser resultatet.
final class Kvotevakt {

    private static let mappe = (NSString(string: "~/.forbruksvakt").expandingTildeInPath)
    private static let statusfil = mappe + "/status.json"
    private static let skript = NSString(string: "~/Documents/Claude/forbruksvakt/forbruksvakt.py")
        .expandingTildeInPath

    /// Hvor ofte skriptet kjøres. Det tar under et sekund, men det er ingen
    /// grunn til å skanne transkripsjonene oftere enn tallene endrer seg.
    private static let oppfriskning: TimeInterval = 150

    /// Hunden bytter ikke leke for et par poengs forskjell. Uten dødsone ville
    /// den skiftet fram og tilbake hver gang tallene rikket seg.
    private static let vippegrense: Double = 8

    /// Over dette er en leverandør uaktuell, uansett hva den andre står på.
    private static let full: Double = 90

    /// Hvor trangt et vindu må ha vært, og hvor mye det må falle, for at det
    /// å rulle rundt skal være verdt å si fra om.
    private static let varTrangt: Double = 40
    private static let maaFalle: Double = 15

    /// Hvor lenge hunden maser om en ny periode, og hvor lenge menyen husker.
    static let feiringstid: TimeInterval = 240
    static let nyhetstid: TimeInterval = 3600

    private(set) var kvote = Kvote()
    private(set) var anbefaling: Kvote.Anbefaling = .ingen
    private(set) var nyperiode: Nyperiode?
    private var sistSett: [String: (prosent: Double, nullstilles: Date)] = [:]
    /// Kalles når nye tall er lest, så menylinja slipper å vente på neste tikk.
    var vedNyeTall: (() -> Void)?
    private var sistKjort = Date.distantPast
    private var sistLest = Date.distantPast
    private var kjorerNa = false

    /// Kalles fritt fra klokka. Gjør bare noe når det er på tide.
    func tikk() {
        let na = Date()
        if na.timeIntervalSince(sistKjort) > Kvotevakt.oppfriskning && !kjorerNa {
            sistKjort = na
            kjorSkript()
        }
        if na.timeIntervalSince(sistLest) > 20 {
            sistLest = na
            les()
        }
    }

    private func kjorSkript() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
              FileManager.default.fileExists(atPath: Kvotevakt.skript) else { return }
        kjorerNa = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [Kvotevakt.skript]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async { self?.kjorerNa = false; self?.les() }
        }
    }

    private func les() {
        guard let data = FileManager.default.contents(atPath: Kvotevakt.statusfil),
              let rot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        var ny = Kvote()
        ny.lest = (try? FileManager.default.attributesOfItem(atPath: Kvotevakt.statusfil))?[.modificationDate] as? Date
        // Sekundene i fila ble regnet ut da den ble skrevet, så de måles fra
        // filas tid og ikke fra nå.
        let grunnlag = ny.lest ?? Date()
        ny.claude = leverandor(rot["claude"], navn: "Claude", grunnlag: grunnlag)
        ny.codex = leverandor(rot["codex"], navn: "ChatGPT", grunnlag: grunnlag)
        kvote = ny
        velgLeverandor()
        sporPerioder()
        vedNyeTall?()
    }

    /// Den med mest plass vinner. Er begge fulle, vinner ingen.
    private func velgLeverandor() {
        let c = kvote.rom(.claude)
        let g = kvote.rom(.codex)
        switch (c, g) {
        case (nil, nil):
            anbefaling = .ingen
        case (let a?, nil):
            anbefaling = a >= Kvotevakt.full ? .ingen : .claude
        case (nil, let b?):
            anbefaling = b >= Kvotevakt.full ? .ingen : .codex
        case (let a?, let b?):
            if a >= Kvotevakt.full && b >= Kvotevakt.full { anbefaling = .ingen; return }
            if a >= Kvotevakt.full { anbefaling = .codex; return }
            if b >= Kvotevakt.full { anbefaling = .claude; return }
            let onsket: Kvote.Anbefaling = a <= b ? .claude : .codex
            let liten = abs(a - b) < Kvotevakt.vippegrense
            if anbefaling != .ingen && onsket != anbefaling && liten { return }
            anbefaling = onsket
        }
    }

    /// Kjenner igjen at et vindu har rullet rundt.
    ///
    /// To ting må stemme samtidig. **Nullstillingsøyeblikket må ha flyttet seg
    /// minst et halvt vindu framover**, som skiller en ekte rulling fra en ny
    /// fasit som bare retter tallet midt i vinduet. **Og prosenten må ha falt
    /// merkbart fra et tall som var trangt**, som skiller en rulling fra et
    /// anslag som kryper framover uten fasit i bunn.
    ///
    /// At et vindu ruller fra 11 prosent er ingen nyhet, og da tier hunden.
    private func sporPerioder() {
        let vinduer: [(Kvote.Anbefaling, Kvote.Leverandor?)] = [(.claude, kvote.claude), (.codex, kvote.codex)]
        for (hvem, l) in vinduer {
            guard let l else { continue }
            for (merke, v, lengde) in [("femtimersvindu", l.femTimer, 5.0 * 3600),
                                       ("ukesvindu", l.uke, 7.0 * 86400)] {
                let nokkel = "\(hvem.navn)-\(merke)"
                guard let p = v.samlet, let kl = v.nullstillesKl else { continue }
                // Merk at et vindu uten tall hopper over uten å røre
                // grunnlinja. Da overlever den at ukesfasiten går ut på dato,
                // og rullinga meldes når den nye fasiten kommer.
                let forrige = sistSett[nokkel]
                sistSett[nokkel] = (p, kl)
                guard let f = forrige else { continue }
                let rullet = kl.timeIntervalSince(f.nullstilles) > lengde / 2
                let falt = f.prosent >= Kvotevakt.varTrangt && p <= f.prosent - Kvotevakt.maaFalle
                if rullet && falt {
                    nyperiode = Nyperiode(hvem: hvem, vindu: merke, aapnet: Date())
                }
            }
        }
    }

    private func leverandor(_ rå: Any?, navn: String, grunnlag: Date) -> Kvote.Leverandor? {
        guard let d = rå as? [String: Any] else { return nil }
        var l = Kvote.Leverandor(navn: navn)
        l.plan = (d["plan"] as? String)?.capitalized
        // Claude oppgir alderen på fasiten, Codex på sin egen avlesning.
        l.alderSek = (d["alder_sek"] as? Double) ?? (d["fasit_alder_sek"] as? Double)
        if let v = d["vinduer"] as? [String: Any] {
            l.femTimer = vindu(v["5t"], kilde: "fasit", grunnlag: grunnlag)
            l.uke = vindu(v["uke"], kilde: "fasit", grunnlag: grunnlag)
        }

        // En fasit har to tall med ulik holdbarhet. Femtimerstallet dør etter
        // fem timer, ukestallet lever en uke. Et femtimerstall fra i forgårs
        // sier ingenting om vinduet vi står i nå, og må ikke få bestemme hvem
        // som anbefales.
        if l.femTimer.utloept {
            let est = ((d["estimat"] as? [String: Any])?["5t"] as? [String: Any])
            let anslag = est?["prosent"] as? Double
            // Vindusstarten står stille gjennom hele vinduet og hopper fem
            // timer når det ruller, så nullstillinga kan regnes ut av den.
            let slutt = (est?["vindu_startet"] as? Double).map {
                Date(timeIntervalSince1970: $0 + 5 * 3600)
            }
            l.femTimer = Kvote.Vindu(prosent: anslag ?? 0, nullstillesKl: slutt, alderSek: 0,
                                     tilleggLokalt: nil,
                                     kilde: anslag == nil ? "nullstilt" : "anslag")
        }
        // Uka kan ikke anslås lokalt, se cloud-okter-gjor-ukeskvota-umulig-a-
        // telle-lokalt. Er ukesfasiten utløpt, vet vi rett og slett ikke.
        if l.uke.utloept {
            l.uke = Kvote.Vindu(kilde: "for gammel")
        }
        return (l.femTimer.prosent == nil && l.uke.prosent == nil) ? nil : l
    }

    private func vindu(_ rå: Any?, kilde: String, grunnlag: Date) -> Kvote.Vindu {
        guard let d = rå as? [String: Any] else { return Kvote.Vindu() }
        return Kvote.Vindu(prosent: d["prosent"] as? Double,
                           nullstillesKl: (d["nullstilles_om_sek"] as? Double)
                               .map { grunnlag.addingTimeInterval($0) },
                           alderSek: d["alder_sek"] as? Double,
                           tilleggLokalt: d["tillegg_lokalt_poeng"] as? Double,
                           kilde: d["kilde"] as? String ?? kilde)
    }
}

/// Tekstene i menylinja. Et tall står aldri alene: alderen hører med, fordi
/// ChatGPT-tallet er så gammelt som siste Codex-kjøring og kan være dager
/// gammelt uten å se rart ut.
enum Kvotetekst {

    static func varighet(_ sekunder: Double?) -> String {
        guard let s = sekunder, s.isFinite else { return "?" }
        if s < 0 { return "nå" }
        let t = Int(s) / 3600, m = (Int(s) % 3600) / 60
        if t >= 24 { return "\(t / 24) d \(t % 24) t" }
        if t > 0 { return "\(t) t \(m) m" }
        return "\(m) m"
    }

    static func alder(_ sekunder: Double?) -> String {
        guard let s = sekunder else { return "ukjent alder" }
        if s < 90 { return "nå nettopp" }
        return varighet(s) + " gammel"
    }

    static func prosent(_ v: Kvote.Vindu) -> String {
        guard let p = v.prosent else { return v.kilde ?? "?" }
        let grunn = "\(Int(p.rounded())) %"
        if let t = v.tilleggLokalt, t >= 0.1 {
            let tall = String(format: "%.1f", t).replacingOccurrences(of: ".", with: ",")
            return grunn + " + \(tall) lokalt"
        }
        return grunn
    }

    /// «Nytt femtimersvindu hos ChatGPT, åpnet for 12 m siden», så lenge det
    /// er nytt nok til å være en nyhet.
    static func nyhet(_ v: Kvotevakt) -> String? {
        guard let n = v.nyperiode, n.alder < Kvotevakt.nyhetstid else { return nil }
        let naar = n.alder < 90 ? "akkurat nå" : "for \(varighet(n.alder)) siden"
        return "Nytt \(n.vindu) hos \(n.hvem.navn), åpnet \(naar)"
    }

    /// Det som står i menyen over undermenyen. Er det en fersk nyhet, står
    /// den der, ellers står rådet.
    static func toppLinje(_ vakt: Kvotevakt) -> String {
        nyhet(vakt) ?? raad(vakt.kvote, vakt.anbefaling)
    }

    /// En linje per vindu, pluss en overskrift per leverandør.
    static func linjer(_ vakt: Kvotevakt) -> [(tekst: String, overskrift: Bool)] {
        let k = vakt.kvote
        let a = vakt.anbefaling
        var ut: [(String, Bool)] = []
        if let n = nyhet(vakt) { ut.append((n, true)) }
        ut.append((raad(k, a), true))
        for l in [k.claude, k.codex].compactMap({ $0 }) {
            let plan = l.plan.map { " \($0)" } ?? ""
            let via = l.navn == "ChatGPT" ? ", målt via Codex" : ""
            ut.append(("\(l.navn)\(plan)\(via), avlest \(alder(l.alderSek))", true))
            for (merke, v) in [("5 timer", l.femTimer), ("uke", l.uke)] {
                var linje = "   \(merke): \(prosent(v))"
                if v.prosent != nil, let n = v.nullstillesOmSek {
                    linje += ", nullstilles om \(varighet(n))"
                }
                if let kilde = v.kilde, kilde != "fasit", v.prosent != nil {
                    linje += " (\(kilde))"
                }
                ut.append((linje, false))
            }
        }
        if !k.harTall {
            ut.append(("Ingen kvotetall. Kjør forbruksvakt.py", true))
        }
        return ut
    }

    /// Setningen hunden illustrerer med leka i munnen.
    static func raad(_ k: Kvote, _ a: Kvote.Anbefaling) -> String {
        guard k.harTall else { return "Kvote: ukjent" }
        switch a {
        case .ingen:
            if k.press == .tomt { return "Begge kvotene er brukt opp" }
            return "Vet ikke nok til å anbefale noen"
        case .claude, .codex:
            let min = k.rom(a).map { "\(Int($0.rounded())) %" } ?? "?"
            let andre = k.rom(a.andre).map { "\(Int($0.rounded())) %" }
            let hale = andre.map { ", \(a.andre.navn) står på \($0)" } ?? ""
            return "Bruk \(a.navn) nå: \(min) brukt\(hale)"
        }
    }

    /// Det som står i selve menylinja, ved siden av labben: hvem du bør bruke,
    /// og hvor mye av den som er brukt opp.
    static func kort(_ vakt: Kvotevakt) -> String {
        let k = vakt.kvote
        let a = vakt.anbefaling
        guard k.harTall else { return "" }
        // Mens nyheten er fersk står den i selve linja, ikke bare i menyen.
        let fersk = (vakt.nyperiode?.alder ?? .infinity) < Kvotevakt.feiringstid
        let merke = fersk ? " nytt vindu" : ""
        switch a {
        case .ingen:
            let verst = [k.rom(.claude), k.rom(.codex)].compactMap { $0 }.max() ?? 0
            return " tomt \(Int(verst.rounded())) %\(merke)"
        case .claude, .codex:
            guard let p = k.rom(a) else { return " \(a.navn)\(merke)" }
            return " \(a.navn) \(Int(p.rounded())) %\(merke)"
        }
    }
}
