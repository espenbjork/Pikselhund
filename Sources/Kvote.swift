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

    struct Vindu {
        var prosent: Double?
        var nullstillesOmSek: Double?
        var alderSek: Double?
        /// Bare uka for Claude: det lokale forbruket siden fasiten ble hentet.
        var tilleggLokalt: Double?

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

    /// Presset styres av uka, med femtimersvinduet som sperre for om det er
    /// lov å jobbe akkurat nå.
    var press: Press {
        var verst = 0.0
        for l in [claude, codex].compactMap({ $0 }) {
            verst = max(verst, l.uke.samlet ?? 0, l.femTimer.samlet ?? 0)
        }
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

    private(set) var kvote = Kvote()
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
        ny.codex = leverandor(rot["codex"], navn: "Codex")
        kvote = ny
        vedNyeTall?()
    }

    private func leverandor(_ rå: Any?, navn: String) -> Kvote.Leverandor? {
        guard let d = rå as? [String: Any] else { return nil }
        var l = Kvote.Leverandor(navn: navn)
        l.plan = (d["plan"] as? String)?.capitalized
        l.alderSek = d["alder_sek"] as? Double
        if let v = d["vinduer"] as? [String: Any] {
            l.femTimer = vindu(v["5t"])
            l.uke = vindu(v["uke"])
        }
        return (l.femTimer.prosent == nil && l.uke.prosent == nil) ? nil : l
    }

    private func vindu(_ rå: Any?) -> Kvote.Vindu {
        guard let d = rå as? [String: Any] else { return Kvote.Vindu() }
        return Kvote.Vindu(prosent: d["prosent"] as? Double,
                           nullstillesOmSek: d["nullstilles_om_sek"] as? Double,
                           alderSek: d["alder_sek"] as? Double,
                           tilleggLokalt: d["tillegg_lokalt_poeng"] as? Double)
    }
}

/// Tekstene i menylinja. Et tall står aldri alene: alderen hører med, fordi
/// Codex-tallet er så gammelt som siste Codex-kjøring og kan være dager
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
        guard let p = v.prosent else { return "?" }
        let grunn = "\(Int(p.rounded())) %"
        if let t = v.tilleggLokalt, t >= 0.1 {
            return grunn + String(format: " + %.1f lokalt", t)
        }
        return grunn
    }

    /// En linje per vindu, pluss en overskrift per leverandør.
    static func linjer(_ k: Kvote) -> [(tekst: String, overskrift: Bool)] {
        var ut: [(String, Bool)] = []
        for l in [k.claude, k.codex].compactMap({ $0 }) {
            let plan = l.plan.map { " \($0)" } ?? ""
            ut.append(("\(l.navn)\(plan), avlest \(alder(l.alderSek))", true))
            for (merke, v) in [("5 timer", l.femTimer), ("uke", l.uke)] {
                guard v.prosent != nil else { continue }
                ut.append(("   \(merke): \(prosent(v)), nullstilles om \(varighet(v.nullstillesOmSek))", false))
            }
        }
        if ut.isEmpty {
            ut.append(("Ingen kvotetall. Kjør forbruksvakt.py", true))
        }
        return ut
    }

    /// Det som står i selve menylinja, ved siden av labben. Uka, fordi det er
    /// den som binder.
    static func kort(_ k: Kvote) -> String {
        guard k.harTall else { return "" }
        let uker = [k.claude?.uke.samlet, k.codex?.uke.samlet].compactMap { $0 }
        guard let verst = uker.max() else { return "" }
        return " \(Int(verst.rounded())) %"
    }

    /// Kort oppsummering til toppen av menyen.
    static func sammendrag(_ k: Kvote) -> String {
        guard k.harTall else { return "Kvote: ukjent" }
        let uker = [k.claude?.uke.samlet, k.codex?.uke.samlet].compactMap { $0 }
        let verst = uker.max() ?? 0
        return "Uke: \(Int(verst.rounded())) % brukt, \(k.press.beskrivelse)"
    }
}
