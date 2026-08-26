# Pikselhund

En NES-hund som sitter på skrivebordet og logrer. Native macOS-app, ingen
avhengigheter, bygget med `swiftc` uten Xcode-prosjekt.

![Pikselhund](forhandsvisning.png)

## Bygg og kjør

```bash
./build.sh && open build/Pikselhund.app
```

Appen har ikke ikon i Dock. Den bor i menylinja, under labben.

## Hva hunden gjør

Logrer, blunker, peser og puster av seg selv. Klikk på den, så hopper den og
får hjerter over hodet. Dra den dit du vil ha den, posisjonen huskes.

**Følger musepekeren.** Øynene flytter seg mot pekeren, og kommer den helt
inntil, dytter hunden snuten mot den. Pekerposisjonen leses av klokka, ikke av
en hendelseslytter, så appen trenger ingen tilgang å be om.

**Maser med poten.** Med noen minutters mellomrom løfter den den ene poten og
dulter borti deg. Klapper du den, nullstilles masetimeren.

**Tigger.** Setter seg opp med begge poter hengende. Skjer av seg selv
innimellom, og oftere mellom elleve og ett og mellom fire og seks, som er når
hunder flest mener det er mat.

**Sover.** Etter halvannet minutt uten mus eller tastatur legger den seg på
ryggen med potene rett opp og z-er over hodet. Kommer musepekeren nærmere enn
210 punkter mens den sover, kommer pekeren med en godbit, og hunden strekker
seg og våkner.

**Slikker seg om munnen.** Tunga opp over nesa, tre svip.

**Snurrer en runde.** Veksler mellom forfra og bakfra, som når den vil ut.

**Går en tur.** Reiser seg, går i profil bortover skjermkanten, snuser der
borte, og kommer tilbake dit den sto. Å ta tak i den avbryter turen.

**Henter ballen.** Kommer med en ball i munnen, legger den fra seg foran deg,
og venter. Klikker du på hunden mens ballen ligger der, henter den den igjen.

**Tar en leikebukk.** Framparten ned, bakparten i været.

**Ruller over på ryggen.** To klapp tett etter hverandre, så legger den seg
på ryggen og vrikker for magekos.

**«Reduser bevegelse».** Er den skrudd på i systeminnstillingene, sitter hunden
helt stille med tunga inne. Den forsvinner ikke, den slutter bare å røre seg.

Høyreklikk gir samme meny som labben i menylinja: be den tigge, be om
poteklapp, legge seg, størrelse, foran eller bak vinduene, speilvending, klikk
gjennom, og start ved pålogging.

«La klikk gå gjennom hunden» gjør den til ren dekorasjon. Da svarer den ikke
på høyreklikk heller, og menylinja er eneste vei tilbake.

## Tegningen

All grafikk ligger i `Art/pikselhund.txt` som ASCII, ett tegn per piksel.
Fila er fasit: både appen og forhåndsvisningsverktøyet leser den samme fila.
Paletten er hentet fra NES-paletten.

Rammene legges oppå hverandre, og `.` slipper laget under gjennom. Nederst
ligger `kropp`, eller `tigger` når den tigger, eller `sover` når den sover.
Oppå det kommer en av `hale-ned` / `hale-midt` / `hale-opp`, og så `pote-opp`,
`blunk`, `tunge` og `blikk-venstre` / `blikk-hoyre` etter behov. `hjerte`,
`zzz` og `godbit` tegnes for seg.

`tigger` og `sover` er **hele rammer**, ikke overlegg, fordi de endrer
silhuetten og et overlegg bare kan legge til piksler. Endrer du `kropp`
nedentil, må `tigger` etter. Alt annet er overlegg og følger med av seg selv.

**Krem på hvitt har nesten ingen kontrast.** En pote tegnet i `w` mot en kropp
i `W` forsvinner, og bare det svarte omrisset leser. Derfor har alle poter en
mørk pute i `N` nederst. Det er det eneste som gjør at de leser som poter.

Endre tegningen, se resultatet, bygg på nytt:

```bash
python3 tools/forhandsvis.py && open forhandsvisning.png
```

Rammene må være like store, ellers nekter appen å starte og sier hvilken ramme
som er skjev. `build.sh` sjekker det samme **før** den kompilerer, så en skjev
ramme stopper bygget i stedet for å gi en app som ikke starter.

For å fotografere en enkelt positur uten å vente på at den skal skje:

```bash
open build/Pikselhund.app --args --vis tigger
```

`--vis` tar `sitter`, `tigger`, `sover`, `mage`, `snurrer`, `bukker`, `ball`
eller `gaar`, og låser hunden der. `--vis tur`, `--vis vekking` og
`--vis godbit` låser ikke, de setter i gang den ekte bevegelsen så den kan
fotograferes.

**Tellere som ruller hver ramme må ligge i animasjonen, ikke i
tilstandsstyringen.** Låsen i `--vis` skrur av tilstandsstyringen, så en teller
som ligger der stopper, og posituren ser død ut. Feilen er gjort tre ganger i
dette prosjektet: poteklapp, z-er og gangrammer.

## Ikonet

```bash
python3 tools/lag-ikon.py
```

Lager `AppIcon.icns` av hunden selv mot Super Mario Bros.-himmel. `build.sh`
kopierer det inn hvis det finnes.

## Filer

| fil | hva |
|---|---|
| `Art/pikselhund.txt` | all grafikk, 23 rammer |
| `Sources/Piksler.swift` | leser tegningen, lager bilder |
| `Sources/Hund.swift` | vindu, animasjon, mus, innstillinger |
| `Sources/App.swift` | menylinje og meny |
| `tools/forhandsvis.py` | rammene som PNG |
| `tools/lag-ikon.py` | app-ikonet |
