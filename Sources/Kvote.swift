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
        var nullstillesOmSek: Double?
        var alderSek: Double?
        /// Bare uka for Claude: det lokale forbruket siden fasiten ble hentet.
        var tilleggLokalt: Double?
        /// «fasit», «anslag», «nullstilt» eller «for gammel».
        var kilde: String?

        /// Nullstillingstida regnes ut i det fila skrives. Er den negativ, er
        /// vinduet for lengst rullet rundt, og tallet gjelder et vindu som
        /// ikke finnes lenger.
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

    private(set) var kvote = Kvote()
    private(set) var anbefaling: Kvote.Anbefaling = .ingen
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
        ny.claude = leverandor(rot["claude"], navn: "Claude")
        ny.codex = leverandor(rot["codex"], navn: "ChatGPT")
        kvote = ny
        velgLeverandor()
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

    private func leverandor(_ rå: Any?, navn: String) -> Kvote.Leverandor? {
        guard let d = rå as? [String: Any] else { return nil }
        var l = Kvote.Leverandor(navn: navn)
        l.plan = (d["plan"] as? String)?.capitalized
        // Claude oppgir alderen på fasiten, Codex på sin egen avlesning.
        l.alderSek = (d["alder_sek"] as? Double) ?? (d["fasit_alder_sek"] as? Double)
        if let v = d["vinduer"] as? [String: Any] {
            l.femTimer = vindu(v["5t"], kilde: "fasit")
            l.uke = vindu(v["uke"], kilde: "fasit")
        }

        // En fasit har to tall med ulik holdbarhet. Femtimerstallet dør etter
        // fem timer, ukestallet lever en uke. Et femtimerstall fra i forgårs
        // sier ingenting om vinduet vi står i nå, og må ikke få bestemme hvem
        // som anbefales.
        if l.femTimer.utloept {
            let est = ((d["estimat"] as? [String: Any])?["5t"] as? [String: Any])
            let anslag = est?["prosent"] as? Double
            // Anslaget teller sitt eget rullende vindu, så nullstillinga kan
            // regnes ut av når vinduet startet.
            let igjen = (est?["vindu_startet"] as? Double).map {
                $0 + 5 * 3600 - Date().timeIntervalSince1970
            }
            l.femTimer = Kvote.Vindu(prosent: anslag ?? 0, nullstillesOmSek: igjen, alderSek: 0,
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

    private func vindu(_ rå: Any?, kilde: String) -> Kvote.Vindu {
        guard let d = rå as? [String: Any] else { return Kvote.Vindu() }
        return Kvote.Vindu(prosent: d["prosent"] as? Double,
                           nullstillesOmSek: d["nullstilles_om_sek"] as? Double,
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

    /// En linje per vindu, pluss en overskrift per leverandør.
    static func linjer(_ k: Kvote, _ a: Kvote.Anbefaling) -> [(tekst: String, overskrift: Bool)] {
        var ut: [(String, Bool)] = []
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
    static func kort(_ k: Kvote, _ a: Kvote.Anbefaling) -> String {
        guard k.harTall else { return "" }
        switch a {
        case .ingen:
            let verst = [k.rom(.claude), k.rom(.codex)].compactMap { $0 }.max() ?? 0
            return " tomt \(Int(verst.rounded())) %"
        case .claude, .codex:
            guard let p = k.rom(a) else { return " \(a.navn)" }
            return " \(a.navn) \(Int(p.rounded())) %"
        }
    }
}
