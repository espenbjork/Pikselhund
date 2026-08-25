import AppKit

/// Leser tegningen i Art/pikselhund.txt og gjør rammer om til bilder.
/// Ett tegn i fila er én piksel. Rammer legges oppå hverandre i den
/// rekkefølgen kalleren oppgir, og '.' slipper laget under gjennom.
struct Piksler {
    typealias Farge = (r: UInt8, g: UInt8, b: UInt8)

    let bredde: Int
    let hoyde: Int
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

    /// Setter sammen rammene til ett bilde. Bildet er like stort som én ramme,
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
