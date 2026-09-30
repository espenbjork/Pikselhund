import AppKit

/// Leser tegningen i Art/pikselhund.txt og gjør rammer om til bilder.
/// Ett tegn i fila er en piksel. Rammer legges oppå hverandre i den
/// rekkefølgen kalleren oppgir, og '.' slipper laget under gjennom.
final class Piksler {
    typealias Farge = (r: UInt8, g: UInt8, b: UInt8)

    let bredde: Int
    let hoyde: Int

    /// Det nye tegnesettet: hele figurer som PNG, klippet av
    /// tools/klipp-sprites.py og lagt i appen under «sprites». Alle ligger på
    /// samme lerret, så de beholder størrelsen i forhold til hverandre, og
    /// tegnes derfor inn i nøyaktig samme rute som de gamle 32x32-rammene.
    private lazy var spritemappe: URL? = Bundle.main.url(forResource: "sprites", withExtension: nil)
    private var spritebuffer: [String: NSImage] = [:]

    var harSprites: Bool { spritemappe != nil }

    func sprite(_ navn: String) -> NSImage? {
        if let ferdig = spritebuffer[navn] { return ferdig }
        guard let mappe = spritemappe,
              let bilde = NSImage(contentsOf: mappe.appendingPathComponent(navn + ".png"))
        else { return nil }
        spritebuffer[navn] = bilde
        return bilde
    }

    private var lagbuffer: [String: NSImage] = [:]

    /// Flere sprite-lag oppå hverandre, samme idé som `bilde(_:)` for
    /// 32x32-rammene. Alle lagene ligger på samme lerret, så de legges rett
    /// oppå hverandre. Mangler ett av lagene, blir svaret nil, og kalleren
    /// faller tilbake til den gamle tegningen.
    func spritebilde(_ lag: [String]) -> NSImage? {
        let nokkel = lag.joined(separator: "+")
        if let ferdig = lagbuffer[nokkel] { return ferdig }
        let bilder = lag.compactMap { sprite($0) }
        guard bilder.count == lag.count, let forste = bilder.first else { return nil }
        if bilder.count == 1 { lagbuffer[nokkel] = forste; return forste }

        // Tegnes en gang inn i et punktbilde, ikke på nytt for hver ramme.
        let px = forste.representations.first?.pixelsWide ?? 384
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let flate = NSRect(x: 0, y: 0, width: px, height: px)
        for b in bilder { b.draw(in: flate, from: .zero, operation: .sourceOver, fraction: 1) }
        NSGraphicsContext.restoreGraphicsState()
        let ut = NSImage(size: flate.size)
        ut.addRepresentation(rep)
        lagbuffer[nokkel] = ut
        return ut
    }

    /// Ett bilde etter rammenavn, fra det tegnesettet som er valgt. Sprite-fila
    /// heter det samme som den gamle ramma, så kallerne slipper å vite hvilket
    /// sett som er i bruk.
    func ramme(_ navn: String) -> NSImage {
        if Innstillinger.nyTegning, let s = sprite(navn) { return s }
        return bilde([navn])
    }
    private let palett: [Character: Farge]
    private let rammer: [String: [[Character]]]

    enum Feil: LocalizedError {
        case fantIkkeFil
        case tom
        case skjevRamme(String)

        var errorDescription: String? {
            switch self {
            case .fantIkkeFil: return "Fant ikke pikselhund.txt i appen."
            case .tom: return "pikselhund.txt inneholder ingen rammer."
            case .skjevRamme(let navn): return "Rammen «\(navn)» har rader av ulik lengde."
            }
        }
    }

    init(fil: URL) throws {
        guard let tekst = try? String(contentsOf: fil, encoding: .utf8) else { throw Feil.fantIkkeFil }

        var palett: [Character: Farge] = [:]
        var rammer: [String: [[Character]]] = [:]
        var modus = ""
        var navn = ""

        for linje in tekst.split(separator: "\n", omittingEmptySubsequences: false) {
            if linje.hasPrefix("palett") { modus = "palett"; continue }
            if linje.hasPrefix("ramme ") {
                modus = "ramme"
                navn = linje.dropFirst("ramme ".count).trimmingCharacters(in: .whitespaces)
                rammer[navn] = []
                continue
            }
            guard linje.hasPrefix("  ") else { continue }
            let innhold = linje.trimmingCharacters(in: .whitespaces)
            if innhold.isEmpty || innhold.hasPrefix(";") { continue }

            switch modus {
            case "palett":
                let deler = innhold.split(separator: " ", omittingEmptySubsequences: true)
                guard deler.count >= 2, let tegn = deler.first?.first else { continue }
                palett[tegn] = Piksler.farge(hex: String(deler[1]))
            case "ramme":
                rammer[navn]?.append(Array(innhold.prefix(while: { $0 != ";" })
                                              .trimmingCharacters(in: .whitespaces)))
            default:
                continue
            }
        }

        guard let forste = rammer.values.first(where: { !$0.isEmpty }) else { throw Feil.tom }
        let h = forste.count
        let b = forste[0].count
        for (navn, rader) in rammer where rader.count != h || rader.contains(where: { $0.count != b }) {
            throw Feil.skjevRamme(navn)
        }
        self.hoyde = h
        self.bredde = b
        self.palett = palett
        self.rammer = rammer
    }

    private static func farge(hex: String) -> Farge {
        let tall = UInt32(hex, radix: 16) ?? 0
        return (UInt8((tall >> 16) & 0xFF), UInt8((tall >> 8) & 0xFF), UInt8(tall & 0xFF))
    }

    /// Setter sammen rammene til ett bilde. Bildet er like stort som en ramme,
    /// og skal alltid tegnes uten interpolering, ellers smøres pikslene ut.
    func bilde(_ lagnavn: [String]) -> NSImage {
        var bytes = [UInt8](repeating: 0, count: bredde * hoyde * 4)
        for lag in lagnavn {
            guard let rader = rammer[lag] else { continue }
            for y in 0..<hoyde {
                for x in 0..<bredde {
                    let tegn = rader[y][x]
                    guard tegn != ".", let farge = palett[tegn] else { continue }
                    let i = (y * bredde + x) * 4
                    bytes[i] = farge.r
                    bytes[i + 1] = farge.g
                    bytes[i + 2] = farge.b
                    bytes[i + 3] = 255
                }
            }
        }

        let data = Data(bytes)
        guard let kilde = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: bredde, height: hoyde,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: bredde * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: kilde, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return NSImage(size: NSSize(width: bredde, height: hoyde)) }

        return NSImage(cgImage: cg, size: NSSize(width: bredde, height: hoyde))
    }
}
