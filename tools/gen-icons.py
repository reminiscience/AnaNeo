#!/usr/bin/env python3
"""Erzeugt die drei Programm-Icons in res/ aus ihrer Beschreibung.

Die Marke ist die Taste aus der Bildschirmtastatur: Flaeche, links der
Akzentstreifen, den osk.d jeder zeichentragenden Taste gibt, mittig das
Quadrat U+25A0. Farben sind die Tokens des Design-Standards "Schweizer
Sachlichkeit" - dieselben, die osk.d unter OSKTheme.Sachlich benutzt.

Jede Groesse wird einzeln gezeichnet, nicht aus 256 px herunterskaliert:
Bei 16 px entscheiden drei Pixel Streifenbreite ueber die Lesbarkeit, und
ein Filter macht daraus Grau.

    python tools/gen-icons.py

Danach res/ananeo.res mit der x86-Variante von rc.exe neu erzeugen
(siehe CLAUDE.md, Abschnitt "Bauen").
"""

import os
import sys

from PIL import Image, ImageDraw

PAPIER = (0xF4, 0xF4, 0xF4)
TINTE = (0x0A, 0x0A, 0x0A)
AKZENT = (0x23, 0x23, 0xD6)   # Slot 1, Ultramarin
BRONZE = (0x8C, 0x50, 0x00)   # Slot 4, Bronze
MUTED = (0x57, 0x57, 0x57)
LINIE = (0xC6, 0xC6, 0xC6)

# Zustand -> (Grund, Zeichen, Streifen). "gerastet" kehrt Grund und Zeichen
# um, statt nur die Streifenfarbe zu wechseln: Der Streifen ist bei 16 px
# drei Pixel breit, ein blosser Farbwechsel dort waere nicht zu sehen.
ZUSTAENDE = {
    "ananeo_enabled":  (PAPIER, TINTE, AKZENT),
    "ananeo_locked":   (TINTE, PAPIER, BRONZE),
    "ananeo_disabled": (PAPIER, MUTED, LINIE),
}

GROESSEN = [16, 24, 32, 48, 256]

STREIFEN_BREITE = 0.16   # Anteil der Kantenlaenge
QUADRAT_HALB = 0.19      # halbe Kantenlaenge des Quadrats


def rechteck(zeichner, kante, x0, y0, x1, y1, farbe):
    zeichner.rectangle(
        [round(x0 * kante), round(y0 * kante),
         round(x1 * kante) - 1, round(y1 * kante) - 1],
        fill=farbe)


def zeichne(kante, zustand):
    grund, zeichen, streifen = ZUSTAENDE[zustand]
    bild = Image.new("RGBA", (kante, kante), grund + (255,))
    zeichner = ImageDraw.Draw(bild)

    rechteck(zeichner, kante, 0, 0, STREIFEN_BREITE, 1, streifen)

    # Das Quadrat sitzt mittig in der Restflaeche rechts des Streifens -
    # genau wie die Tastenbeschriftung in osk.d (zeigeTastenBeschriftung).
    mitte = (STREIFEN_BREITE + 1) / 2
    rechteck(zeichner, kante,
             mitte - QUADRAT_HALB, 0.5 - QUADRAT_HALB,
             mitte + QUADRAT_HALB, 0.5 + QUADRAT_HALB,
             zeichen)
    return bild


def schreibe(verzeichnis, zustand):
    bilder = [zeichne(k, zustand) for k in GROESSEN]
    pfad = os.path.join(verzeichnis, zustand + ".ico")
    bilder[-1].save(pfad, format="ICO",
                    sizes=[(k, k) for k in GROESSEN],
                    append_images=bilder[:-1])
    return pfad


def pruefe(pfad, zustand):
    """Liest die geschriebene Datei zurueck und vergleicht jede Groesse mit
    dem, was zeichne() liefert. Pillow darf beim Schreiben nicht selbst
    skaliert haben."""
    for kante in GROESSEN:
        mit_ico = Image.open(pfad)
        mit_ico.size = (kante, kante)
        ist = mit_ico.convert("RGBA").tobytes()
        soll = zeichne(kante, zustand).tobytes()
        if ist != soll:
            return f"{os.path.basename(pfad)}: {kante} px weicht ab"
    return None


def main():
    hier = os.path.dirname(os.path.abspath(__file__))
    res = os.path.join(os.path.dirname(hier), "res")
    if not os.path.isdir(res):
        sys.exit(f"Verzeichnis nicht gefunden: {res}")

    fehler = []
    for zustand in ZUSTAENDE:
        pfad = schreibe(res, zustand)
        problem = pruefe(pfad, zustand)
        groesse = os.path.getsize(pfad)
        print(f"{os.path.basename(pfad):24} {groesse:7d} Bytes  "
              f"{'ok' if problem is None else problem}")
        if problem:
            fehler.append(problem)

    if fehler:
        sys.exit(1)


if __name__ == "__main__":
    main()
