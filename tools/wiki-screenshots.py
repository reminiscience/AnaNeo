#!/usr/bin/env python3
"""Erzeugt die Ebenen-Screenshots fuer das GitHub-Wiki.

Quelle ist das Belegungsblatt, das `ananeo-tool sheet` ohnehin erzeugt: eine
in sich geschlossene HTML-Datei mit einem `.brett` je Ebene. Das Skript
schaltet die Datei je Ebene um, blendet alles ausser dem Brett aus und laesst
headless Chrome ein PNG davon machen.

Zwei Eingriffe gehoeren dazu, beide aus demselben Grund -- das Wiki ist
englisch, das Belegungsblatt deutsch:

* Der Kopf ("AnaNeo - Belegung", "Ebene 13", "Ausloeser: Mod3+F4") faellt weg.
  Dieselbe Angabe steht im Wiki-Text, dort auf Englisch.
* Die Tastenkappe `Strg` wird zu `Ctrl`. Das ist die einzige deutsche
  Beschriftung, die aus `keyboardview.d` in die Zeichnung kommt.

Aufruf (aus dem Repo-Wurzelverzeichnis):

    python tools/wiki-screenshots.py ../AnaNeo.wiki/images

Optional eine einzelne Ebene zum Nachziehen:

    python tools/wiki-screenshots.py ../AnaNeo.wiki/images --layer 13

Voraussetzung ist ein gebautes `ananeo-tool.exe` (`dub build --config=tool
--build=plain`) und ein installiertes Chrome. Das Skript ist ein Werkzeug,
kein Teil des Programms: `dub test` sieht es nicht, und einen Waechtertest
wie fuer `ananeo-schrift.module` kann es nicht geben -- das Wiki liegt in
einem anderen Repo, die Testsuite kann es nicht erreichen. Wer eine Ebene
umbelegt, ruft das Skript deshalb von Hand nach.
"""

import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

CHROME_KANDIDATEN = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
]

# Nur das Brett zeigen: Kopf und Ebenen-Ueberschrift raus, Reiter raus,
# Rand knapp. Der Rest der Seite bleibt unberuehrt.
STYLE = """
<style>
  .kopf, .reiter, .ebene header { display: none !important; }
  body { padding: 0.5rem !important; }
  .ebene { margin: 0 !important; }
</style>
"""

# Die eine deutsche Tastenkappe. Laeuft nach dem Aufbau der Seite, damit auch
# die Kappen erwischt werden, die erst beim Umschalten sichtbar werden.
PATCH = """
<script>
  document.querySelectorAll('.glyph').forEach(function (g) {
    if (g.textContent === 'Strg') { g.textContent = 'Ctrl'; }
  });
</script>
</body>
"""


def finde_chrome():
    for pfad in CHROME_KANDIDATEN:
        if pathlib.Path(pfad).exists():
            return pfad
    gefunden = shutil.which("chrome") or shutil.which("msedge")
    if gefunden:
        return gefunden
    sys.exit("Kein Chrome und kein Edge gefunden.")


def erzeuge_blatt(werkzeug, layout, ziel):
    """Ruft `ananeo-tool sheet` auf. Das Werkzeug schreibt nach cwd."""
    subprocess.run([str(werkzeug), "sheet", layout], cwd=ziel, check=True,
                   capture_output=True)
    blatt = ziel / f"ananeo-belegung-{layout}.html"
    if not blatt.exists():
        sys.exit(f"Belegungsblatt nicht entstanden: {blatt}")
    return blatt


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("ziel", help="Verzeichnis fuer die PNGs (images/ im Wiki-Repo)")
    p.add_argument("--layout", default="AnNoted", help="Layoutname (Vorgabe: AnNoted)")
    p.add_argument("--praefix", default=None,
                   help="Dateinamen-Praefix (Vorgabe: Layoutname klein)")
    p.add_argument("--layer", type=int, default=None,
                   help="nur diese eine Ebene erzeugen")
    p.add_argument("--tool", default=None,
                   help="Pfad zu ananeo-tool.exe (Vorgabe: neben diesem Repo)")
    args = p.parse_args()

    repo = pathlib.Path(__file__).resolve().parent.parent
    werkzeug = pathlib.Path(args.tool) if args.tool else repo / "ananeo-tool.exe"
    if not werkzeug.exists():
        sys.exit(f"ananeo-tool.exe fehlt: {werkzeug}\n"
                 "Bauen mit: dub build --config=tool --build=plain")

    ziel = pathlib.Path(args.ziel).resolve()
    ziel.mkdir(parents=True, exist_ok=True)
    praefix = args.praefix or args.layout.lower()
    chrome = finde_chrome()

    with tempfile.TemporaryDirectory() as tmpname:
        tmp = pathlib.Path(tmpname)
        blatt = erzeuge_blatt(werkzeug, args.layout, tmp)
        html = blatt.read_text(encoding="utf-8")

        anzahl = len(re.findall(r'class="ebene"', html))
        if anzahl == 0:
            sys.exit("Keine Ebenen im Belegungsblatt gefunden.")

        # Helles Schema erzwingen: sonst entscheidet die Systemeinstellung des
        # Rechners, auf dem das Skript laeuft, wie die Bilder aussehen.
        html = html.replace('<html lang="de">', '<html lang="de" data-theme="light">')
        html = html.replace("</head>", STYLE + "</head>")
        html = html.replace("</body>", PATCH)

        for nr in range(1, anzahl + 1):
            if args.layer is not None and nr != args.layer:
                continue
            seite = tmp / f"ebene-{nr:02d}.html"
            seite.write_text(html.replace("zeige('1');", f"zeige('{nr}');"),
                             encoding="utf-8")
            png = ziel / f"{praefix}-layer-{nr:02d}.png"
            subprocess.run(
                [chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                 "--force-device-scale-factor=2", "--window-size=1080,300",
                 f"--screenshot={png}", seite.as_uri()],
                check=True, capture_output=True)
            if not png.exists():
                sys.exit(f"Chrome hat nichts geschrieben: {png}")
            print(f"{png.name}  {png.stat().st_size // 1024} KiB")


if __name__ == "__main__":
    main()
