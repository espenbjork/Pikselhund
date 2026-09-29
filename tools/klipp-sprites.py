#!/usr/bin/env python3
"""Klipper figurene ut av arkene i Art/kilde og skriver dem til Art/sprites.

    python3 tools/klipp-sprites.py

Arkene er sannheten, akkurat som Art/pikselhund.txt er det for den gamle
tegningen. De utklipte filene er avledet og skal ikke redigeres for hånd.

To ting er verdt å vite om ark som dette:

**De røde og gule pikslene er ikke en frans.** De ligger på alfa null, altså i
den usynlige delen av bildet, og synes bare hvis du ser på fargekanalen uten
alfa. Ingenting skal renses bort. Se notatet
en-generert-sprite-har-soppel-under-alfa-null.

**Rutenettet kan ikke finnes ved å lete etter tomme kolonner**, fordi figurene
renner over cellegrensene og berører hverandre. Cellene ligger på et fast
rutenett, og figuren plukkes ut som den sammenhengende flata nærmest midten av
cella.
"""
import json, pathlib, sys
from PIL import Image, ImageDraw

HER = pathlib.Path(__file__).resolve().parent.parent
KILDE = HER / "Art" / "kilde"
UT = HER / "Art" / "sprites"
# Hunden vises som mest 192 punkter bred, altså 384 piksler på en Retina-skjerm.
MAAL = 384


def komponenter(mask, w, h):
    """Sammenhengende flater, funnet med union-find linje for linje."""
    far = {}
    def finn(a):
        while far[a] != a:
            far[a] = far[far[a]]; a = far[a]
        return a
    merke = [0] * (w * h); neste = 1
    for y in range(h):
        rad = y * w
        for x in range(w):
            if not mask[rad + x]: continue
            v = merke[rad + x - 1] if x and mask[rad + x - 1] else 0
            o = merke[rad - w + x] if y and mask[rad - w + x] else 0
            if v and o:
                merke[rad + x] = v
                ra, rb = finn(v), finn(o)
                if ra != rb: far[rb] = ra
            elif v or o:
                merke[rad + x] = v or o
            else:
                merke[rad + x] = neste; far[neste] = neste; neste += 1
    bokser = {}
    for y in range(h):
        for x in range(w):
            m = merke[y * w + x]
            if not m: continue
            r = finn(m); b = bokser.get(r)
            bokser[r] = ((min(b[0], x), min(b[1], y), max(b[2], x), max(b[3], y), b[4] + 1)
                         if b else (x, y, x, y, 1))
    return list(bokser.values())


def figur(im, kol, rad, k, r, ned=2):
    """Figuren i celle (k, r), klippet med margin og plukket fra midten."""
    cw, ch = im.width / kol, im.height / rad
    mx, my = cw * 0.35, ch * 0.35
    x0, y0 = max(0, int(k * cw - mx)), max(0, int(r * ch - my))
    x1, y1 = min(im.width, int((k + 1) * cw + mx)), min(im.height, int((r + 1) * ch + my))
    bit = im.crop((x0, y0, x1, y1))
    liten = bit.getchannel("A").resize((bit.width // ned, bit.height // ned))
    w, h = liten.size
    mask = [1 if v > 30 else 0 for v in liten.getdata()]
    komp = [c for c in komponenter(mask, w, h) if c[4] > 40]
    if not komp: return None
    mxc, myc = (k * cw + cw / 2 - x0) / ned, (r * ch + ch / 2 - y0) / ned
    hoved = min(komp, key=lambda c: abs((c[0] + c[2]) / 2 - mxc) + abs((c[1] + c[3]) / 2 - myc))
    hx0, hy0, hx1, hy1 = hoved[0], hoved[1], hoved[2], hoved[3]
    # Løse biter inni figurens boks hører til, typisk z-ene over en sovende hund.
    for c in komp:
        if c is hoved: continue
        if hx0 - 8 <= c[0] and c[2] <= hx1 + 8 and hy0 - 8 <= c[1] and c[3] <= hy1 + 8:
            hx0, hy0 = min(hx0, c[0]), min(hy0, c[1])
            hx1, hy1 = max(hx1, c[2]), max(hy1, c[3])
    boks = (x0 + hx0 * ned, y0 + hy0 * ned, x0 + (hx1 + 1) * ned, y0 + (hy1 + 1) * ned)
    bb = im.crop(boks).getbbox()
    if not bb: return None
    return (boks[0] + bb[0], boks[1] + bb[1], boks[0] + bb[2], boks[1] + bb[3])


def juster_mot_kropp(im, bokser, base_i, andel_hode=0.55, rekkevidde=4):
    """Legger alle rammene i samme koordinatsystem som basen, målt på kroppen.

    En bildemodell tegner hver rute på nytt, så figurene ligger en piksel
    eller to forskjøvet. Kroppen er det som skal stå stille, så det er den
    som bestemmer plasseringen.
    """
    from PIL import ImageChops
    b0 = bokser[base_i]
    W, H = b0[2] - b0[0], b0[3] - b0[1]
    halvt = int(H * andel_hode)
    ref = im.crop(b0).crop((0, halvt, W, H)).convert("L")
    ut = []
    for b in bokser:
        cx, bunn = (b[0] + b[2]) // 2, b[3]
        best = None
        for dx in range(-rekkevidde, rekkevidde + 1):
            for dy in range(-rekkevidde, rekkevidde + 1):
                x0, y1 = cx - W // 2 + dx, bunn + dy
                u = sum(1 for v in ImageChops.difference(
                    im.crop((x0, y1 - H + halvt, x0 + W, y1)).convert("L"), ref).getdata() if v > 40)
                if best is None or u < best[0]:
                    best = (u, x0, y1)
        ut.append(im.crop((best[1], best[2] - H, best[1] + W, best[2])))
    return ut


def ansiktslag(navn, a, lerret_side, sprites_json):
    """Lager kropp, øyne, munn og leker som lag fra et ark der bare ansiktet
    endrer seg.

    Hver rute er tegnet på nytt av bildemodellen, så pelsen er litt ulik fra
    ramme til ramme. Å bla gjennom hele rammer ville derfor få hele hunden
    til å skjelve. I stedet tas kroppen fra én ramme, og bare øyne og munn
    hentes fra de andre, gjennom en maske. Masken ligger ferdig i Art/kilde
    og ble laget av hvor rammene varierer mest: to flekker ved øynene, én ved
    snute og munn. Se notatet en-generert-animasjon-trenger-en-kropp.
    """
    L = a["lag"]
    im = Image.open(KILDE / a["fil"]).convert("RGBA")
    kol, rad = 4, 4
    bokser, ruter = [], []
    for r in range(rad):
        for k in range(kol):
            bokser.append(figur(im, kol, rad, k, r)); ruter.append(f"r{r+1}c{k+1}")
    # Kroppen justeres mot den samme ramma som masken ble laget mot.
    rammer = dict(zip(ruter, juster_mot_kropp(im, bokser, ruter.index("r2c1"))))
    base = rammer[L["base"]]
    W, H = base.size
    maske = Image.open(KILDE / L["maske"]).convert("L")
    grense = L["oyne_over_y"]
    oynemaske = maske.copy(); oynemaske.paste(0, (0, grense, W, H))
    munnmaske = maske.copy(); munnmaske.paste(0, (0, 0, W, grense))

    # Samme høyde som den sittende hunden i resten av settet, så den verken
    # vokser eller krymper når den reiser seg.
    maalhoyde = sprites_json[L["hoyde_som"]]["storrelse"][1]
    s = maalhoyde / H

    def plasser(lag):
        """Skalerer et lag i hundens koordinater og legger det på lerretet,
        nederst og midtstilt, akkurat som figurene i resten av settet."""
        stor = lag.resize((round(W * s), round(H * s)), Image.LANCZOS)
        l = Image.new("RGBA", (lerret_side, lerret_side), (0, 0, 0, 0))
        l.alpha_composite(stor, ((lerret_side - stor.width) // 2, lerret_side - stor.height))
        return l.resize((MAAL, MAAL), Image.LANCZOS)

    def utsnitt(ramme, m):
        """Ramma, men bare der masken slipper gjennom."""
        from PIL import ImageChops
        lag = ramme.copy()
        lag.putalpha(ImageChops.multiply(ramme.getchannel("A"), m))
        return lag

    ut = {L["kropp"]: plasser(base)}
    for rute, n in L["oyne"].items():
        ut[n] = plasser(utsnitt(rammer[rute], oynemaske))
    for rute, n in L["munn"].items():
        ut[n] = plasser(utsnitt(rammer[rute], munnmaske))

    # Lekene er rekvisitter fra et annet ark. De skaleres til snutebredde og
    # legges midt på munnen, i hundens koordinater.
    for kilde, n in L["leker"].items():
        fil = UT / f"_raa-{kilde}.png"
        if not fil.exists(): continue
        leke = Image.open(fil).convert("RGBA")
        bredde = L["leke_bredde"]; hoyde = round(leke.height * bredde / leke.width)
        leke = leke.resize((bredde, hoyde), Image.LANCZOS)
        lag = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        mx, my = L["leke_midt"]
        lag.alpha_composite(leke, (round(mx - bredde / 2), round(my - hoyde / 2)))
        ut[n] = plasser(lag)

    # Ting som ligger på bakken ved siden av hunden, som ballen den har sluppet.
    for kilde, spes in L.get("bakke", {}).items():
        fil = UT / f"_raa-{kilde}.png"
        if not fil.exists(): continue
        ting = Image.open(fil).convert("RGBA")
        bredde = spes["bredde"]; hoyde = round(ting.height * bredde / ting.width)
        ting = ting.resize((bredde, hoyde), Image.LANCZOS)
        lag = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        mx, my = spes["midt"]
        lag.alpha_composite(ting, (round(mx - bredde / 2), round(my - hoyde / 2)))
        ut[spes["navn"]] = plasser(lag)
    return ut


def main():
    ark = json.loads((KILDE / "ark.json").read_text(encoding="utf-8"))
    UT.mkdir(exist_ok=True)
    for gammel in list(UT.glob("*.png")) + list(UT.glob("unavngitt/*.png")): gammel.unlink()
    fasit, kontakt, raa = {}, [], []
    for navn, a in ark.items():
        if not a.get("rutenett") or "lag" in a: continue
        kol, rad = (int(v) for v in a["rutenett"].split("x"))
        im = Image.open(KILDE / a["fil"]).convert("RGBA")
        for r in range(rad):
            for k in range(kol):
                boks = figur(im, kol, rad, k, r)
                if not boks: continue
                rute = f"r{r+1}c{k+1}"
                id = a.get("navn", {}).get(rute) or f"{navn}-{rute}"
                bit = im.crop(boks)
                navngitt = rute in a.get("navn", {})
                raa.append((id, bit, navngitt))
                fasit[id] = {"ark": navn, "rute": rute, "boks": list(boks),
                             "storrelse": [bit.width, bit.height], "navngitt": navngitt}
                kontakt.append((id, bit))
    # Alle figurene skal inn på samme lerret, ellers mister de størrelsen sin
    # i forhold til hverandre. Hunden forankres nederst og midtstilt, så føttene
    # står på samme linje enten den sitter eller går. Hjerter og z-er svever
    # over hodet, og forankres øverst.
    side = max(max(b.width, b.height) for _, b, _ in raa)
    OVER = {"hjerte", "zzz", "zzz-2"}
    for id, bit, navngitt in raa:
        if id in ("leke-claude", "leke-codex", "ball-alene"):
            bit.save(UT / f"_raa-{id}.png")
        if not navngitt:
            (UT / "unavngitt").mkdir(exist_ok=True)
            bit.save(UT / "unavngitt" / f"{id}.png")
            continue
        lerret = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        x = (side - bit.width) // 2
        y = 0 if id in OVER else side - bit.height
        lerret.paste(bit, (x, y))
        lerret.resize((MAAL, MAAL), Image.LANCZOS).save(UT / f"{id}.png")
        fasit[id]["lerret"] = [x, y, side]
    fasit["_lerret"] = {"side": side, "maal": MAAL}
    for navn, a in ark.items():
        if "lag" not in a: continue
        for id, lag in ansiktslag(navn, a, side, fasit).items():
            lag.save(UT / f"{id}.png")
            fasit[id] = {"ark": navn, "lag": True}
    for raa in UT.glob("_raa-*.png"): raa.unlink()
    (UT / "sprites.json").write_text(json.dumps(fasit, indent=1, ensure_ascii=False), encoding="utf-8")

    B, KOL = 160, 12
    lerret = Image.new("RGBA", (KOL * B, ((len(kontakt) + KOL - 1) // KOL) * (B + 14)), (250, 250, 250, 255))
    d = ImageDraw.Draw(lerret)
    for i, (merke, bit) in enumerate(kontakt):
        x, y = (i % KOL) * B, (i // KOL) * (B + 14)
        s = min((B - 10) / bit.width, (B - 10) / bit.height)
        liten = bit.resize((max(1, int(bit.width * s)), max(1, int(bit.height * s))), Image.LANCZOS)
        lerret.alpha_composite(liten, (x + (B - liten.width) // 2, y + 14 + (B - 10 - liten.height) // 2))
        d.text((x + 3, y + 2), merke[:24], fill=(0, 0, 0, 255))
        d.rectangle([x, y, x + B - 1, y + B + 13], outline=(210, 210, 210, 255))
    lerret.save(UT / "oversikt.png")
    print(f"{len(kontakt)} figurer til {UT}")
    print(f"oversikt: {UT / 'oversikt.png'}")


if __name__ == "__main__":
    main()
