#!/usr/bin/env python3
"""Rendrer Art/pikselhund.txt til en PNG så rammene kan sees mens de tegnes.

    python3 tools/forhandsvis.py [ut.png]

Appen leser den samme tekstfila, så det du ser her er det appen viser.
"""
import sys, pathlib
from PIL import Image

HER = pathlib.Path(__file__).resolve().parent.parent
KILDE = HER / "Art" / "pikselhund.txt"
SKALA = 8


def les(sti):
    palett, rammer, modus, navn = {}, {}, None, None
    for linje in sti.read_text(encoding="utf-8").splitlines():
        if not linje.strip() or linje.lstrip().startswith("#") and not linje.startswith("  "):
            continue
        if linje.startswith("palett"):
            modus, navn = "palett", None
        elif linje.startswith("ramme "):
            modus, navn = "ramme", linje.split(None, 1)[1].strip()
            rammer[navn] = []
        elif linje.startswith("  "):
            innhold = linje.strip()
            if modus == "palett":
                tegn, hex_ = innhold.split()[0], innhold.split()[1]
                palett[tegn] = tuple(int(hex_[i:i + 2], 16) for i in (0, 2, 4)) + (255,)
            elif modus == "ramme":
                rammer[navn].append(innhold)
    return palett, rammer


def tegn(rammer_valgt, palett, rammer):
    bilde = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    piksler = bilde.load()
    for navn in rammer_valgt:
        for y, rad in enumerate(rammer[navn]):
            for x, tegn_ in enumerate(rad):
                if tegn_ != ".":
                    piksler[x, y] = palett[tegn_]
    return bilde


def main():
    palett, rammer = les(KILDE)
    for navn, rader in rammer.items():
        feil = [i for i, r in enumerate(rader) if len(r) != 32]
        if len(rader) != 32 or feil:
            sys.exit(f"Ramme '{navn}' har feil mål: {len(rader)} rader, skjeve rader {feil}")

    visninger = [
        ("sitter", ["kropp", "hale-midt", "tunge"]),
        ("blikk", ["kropp", "hale-midt", "blikk-venstre"]),
        ("poteklapp", ["kropp", "hale-opp", "pote-opp", "tunge"]),
        ("slikker", ["kropp", "hale-opp", "slikk"]),
        ("tigger", ["tigger", "hale-midt", "tunge"]),
        ("ballen", ["kropp", "hale-opp", "i-munnen"]),
        ("ballen ligger", ["kropp", "hale-midt", "ball", "tunge"]),
        ("bakfra", ["bakfra"]),
        ("profil", ["profil"]),
        ("gaar", ["profil-gaa1"]),
        ("leikebukk", ["leikebukk"]),
        ("sover", ["sover", "zzz"]),
        ("magekos", ["sover", "mage-vaken"]),
        ("godbit", ["godbit"]),
    ]

    marg = 4
    bredde = len(visninger) * (32 + marg) * SKALA
    ark = Image.new("RGBA", (bredde, (32 + marg) * SKALA), (60, 70, 90, 255))
    for i, (_, lag) in enumerate(visninger):
        rute = tegn(lag, palett, rammer).resize((32 * SKALA, 32 * SKALA), Image.NEAREST)
        ark.alpha_composite(rute, (i * (32 + marg) * SKALA + marg * SKALA // 2, marg * SKALA // 2))

    ut = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else HER / "forhandsvisning.png"
    ut.parent.mkdir(parents=True, exist_ok=True)
    ark.save(ut)
    print(f"Skrev {ut} ({', '.join(n for n, _ in visninger)})")


if __name__ == "__main__":
    main()
