#!/usr/bin/env python3
"""Lager AppIcon.icns av selve pikselhunden, mot en Mario-blå himmel.

    python3 tools/lag-ikon.py

Krever Pillow og iconutil (følger med Command Line Tools).
"""
import pathlib, shutil, subprocess, sys
from PIL import Image, ImageDraw

HER = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HER / "tools"))
from forhandsvis import les, tegn  # noqa: E402

HIMMEL = (92, 148, 252)   # NES $22, himmelen i Super Mario Bros.
BAKKE = (0, 168, 0)       # NES $1A
GRESS = (0, 216, 0)       # NES $2A


def ikonflate(px):
    """En kvadratisk ikonflate: himmel, bakke og hund, med runde hjørner."""
    palett, rammer = les(HER / "Art" / "pikselhund.txt")
    hund = tegn(["kropp", "hale-opp", "tunge"], palett, rammer)

    # Tegn i 32 ruter, samme rutenett som hunden, og skaler opp helt til slutt.
    rute = 32
    flate = Image.new("RGBA", (rute, rute), HIMMEL + (255,))
    tegner = ImageDraw.Draw(flate)
    tegner.rectangle([0, 27, rute - 1, rute - 1], fill=BAKKE + (255,))
    tegner.rectangle([0, 27, rute - 1, 27], fill=GRESS + (255,))
    flate.alpha_composite(hund, (0, -1))

    stor = flate.resize((px, px), Image.NEAREST)

    # Runde hjørner som resten av macOS-ikonene, og litt luft rundt.
    luft = max(1, round(px * 0.06))
    innmat = stor.resize((px - 2 * luft, px - 2 * luft), Image.NEAREST)
    maske = Image.new("L", innmat.size, 0)
    ImageDraw.Draw(maske).rounded_rectangle(
        [0, 0, innmat.size[0] - 1, innmat.size[1] - 1],
        radius=round(innmat.size[0] * 0.2237), fill=255)
    innmat.putalpha(maske)

    ferdig = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    ferdig.alpha_composite(innmat, (luft, luft))
    return ferdig


def main():
    sett = HER / "build" / "AppIcon.iconset"
    if sett.exists():
        shutil.rmtree(sett)
    sett.mkdir(parents=True)

    for storrelse in (16, 32, 128, 256, 512):
        ikonflate(storrelse).save(sett / f"icon_{storrelse}x{storrelse}.png")
        ikonflate(storrelse * 2).save(sett / f"icon_{storrelse}x{storrelse}@2x.png")

    ut = HER / "AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(sett), "-o", str(ut)], check=True)
    print(f"Skrev {ut}")


if __name__ == "__main__":
    main()
