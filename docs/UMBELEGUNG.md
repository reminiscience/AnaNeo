# Umbelegung – Ablauf für Änderungen an Tastenbelegungen

Paket 6 hat diesen Ablauf an einer echten Änderung erprobt: die Leertaste von
`AnNoted` trug seit diesem Paket auf Ebene 3 das geschützte Leerzeichen
U+00A0 und auf Ebene 5 das schmale geschützte Leerzeichen U+202F. Paket 7 hat
diese Hierarchie im Zuge der Ebenen-Neuordnung auf die Ebenen 3–7 ausgeweitet
(geschütztes Leerzeichen, schmales geschütztes Leerzeichen, dünnes
Leerzeichen, Haarleerzeichen, Nullbreiten-Leerzeichen; Details in
`README_DE.md`). Dieses Dokument hält fest, wie künftige Umbelegungen ablaufen
sollen – die Themenblöcke sind seit der Extra-Runde alle gefüllt
(offen bleibt nur der Rest der Reserve-Ebenen 11/12 der Typografie – seit
der Compose-Ausdünnungsrunde tragen sie die Compose-Startzeichen
`dead_belowdot`, `dead_macron` und `dead_breve` auf den Scancodes 29/12,
0D/12 und 2B/12 (`˞` ist in der Grammatikrunde auf Ebene 21 umgezogen), seit
dem 10.08.2026 dazu `⚥` auf 32/11, der übrige Platz bleibt frei – sowie die
Reservezellen der Ebenen 19/20), es geht also um alle
späteren Einzeländerungen.

## 1. Wo Änderungen hingehören

Eigene Umbelegungen landen ausschließlich in `AnNoted`. `Neo`, `NeoQwertz`
und `Noted` bleiben standardtreu – sie bilden die veröffentlichten Layouts
nach, an denen nicht eigenmächtig geändert wird.

`AnNoted` trägt seit Paket 6 den `dllName` `kbdnoted.dll`, den zuvor `Noted`
führte. Die Erweiterungsmodus-Erkennung in `app.d` wählt das aktive Layout
allein über den `dllName` des erkannten nativen Treibers – wer im
Erweiterungsmodus gegen den Noted-Treiber tippt, landet also automatisch in
`AnNoted`, nicht mehr in `Noted`. `Noted` bleibt daneben als reines
Standalone-Layout wählbar, ohne eigenen `dllName` und unverändert gegenüber
dem Ursprungsstand.

Je `dllName` ist nur ein Layout erlaubt: Trägt eine `layouts.json` zwei
Layouts mit demselben `dllName`, gewinnt beim Nachschlag in `app.d`
stillschweigend das letzte in der Datei – ein Fehler, der sich nicht von
selbst meldet, sondern erst am falschen Layout im Erweiterungsmodus auffällt.
Ein Unittest in `source/mapping.d` erzwingt deshalb Eindeutigkeit je
`dllName` und schlägt fehl, sobald zwei Layouts denselben Wert tragen.

## 2. Eintragskonventionen

**`char` oder `vk`?** Tasten, die Windows als echten Tastendruck sehen muss –
Tastenkürzel, Spiele, alles, was auf virtuelle Tastencodes statt auf Text
reagiert – bleiben VK-Mappings (`"vk": "VK_..."`). Reine Zeicheneingaben sind
Char-Mappings (`"char": "..."`). Die Grundebenen bleiben deshalb bewusst
VK-Mappings, obwohl sie Buchstaben zeigen: Ohne diesen Umweg sähen Programme
keinen echten Tastendruck mehr, und Tastenkürzel wie Strg+C oder Alt+Tab
bekämen Zeichen statt Codes.

**`keysym`**: Jeder Eintrag trägt einen Keysym, benannt aus `keysymdef.h`
(z. B. `"period"`) oder – für Zeichen ohne benanntes Legacy-Keysym – in der
Offset-Form `UXXXX` (z. B. `"U1D56C"`). Für die Darstellung entscheidet
`describeKey` in `source/keyboardview.d` allein über den Keysym, ob eine
Taste als Zeichentaste gilt, unabhängig davon, ob der Eintrag `char` oder
`vk` nutzt: Führt der Keysym einen Codepunkt – benannt über
`keysyms.codepointsByKeysym` oder über die Offset-Form –, trägt die Taste
einen Codepunkt in ihrer `KeyView` und erscheint auf Bildschirmtastatur und
Belegungsblatt entsprechend ausgezeichnet.

**`label`**: Das Sinnbild, nicht zwingend das erzeugte Zeichen. Präzedenzfall
ist der Nummernblock: Die Multiplikationstaste trägt das Label `×`
(U+00D7), tippt aber `*` (U+002A) – wer den Codepunkt aus dem Label ableitet
statt aus `keypadChar`, schreibt eine Unwahrheit aufs Blatt.

**Unsichtbare Zeichen**: immer als JSON-Escape (`\u00a0`), nie literal in
die Datei getippt. Ein literales U+00A0 im Text ist im Diff nicht von einem
gewöhnlichen Leerzeichen zu unterscheiden – genau dieser Fallstrick hat sich
einmal bewahrheitet: Der `"char"`-Wert der Leertaste auf Ebene 3 von `Noted`
trug nach dem 14-Ebenen-Ausbau in Paket 2 ein gewöhnliches Leerzeichen
(U+0020), obwohl der `"keysym"`-Eintrag `U200A` ein Haarleerzeichen (U+200A)
versprach – im ursprünglichen, veröffentlichten `Noted` stimmten beide noch
überein, char und keysym trugen dort übereinstimmend U+200A. Paket 7 hat
`Noted` auf diesen Originalstand zurückgebaut und den Widerspruch damit
beseitigt (siehe `STATUS.md`, Punkt 15). Der Befund bleibt trotzdem ein Beleg
dafür, warum diese Konvention gilt.

**Neue Ebene**: Ein Eintrag mehr in `layers` verlangt in jeder Zeile von
`map` einen weiteren `NeoKey` – der Integritätstest in `source/mapping.d`
verlangt für die ausgelieferten Layouts vollständige Zeilen und schlägt an,
wenn eine vergessen wurde.

## 3. Checkliste je Änderung

1. **Wunsch notieren**: Zeichen, Ebene, Taste. Den Scancode über das
   Belegungsblatt ermitteln (`ananeo-tool sheet AnNoted` oder der
   Tray-Eintrag »Belegungsblatt erzeugen« am laufenden Programm).
2. **`layouts.json` als Text ändern** – nie per Skript neu serialisieren,
   das zerstört Formatierung und macht Diffs unlesbar. Bei neuen Zeichen den
   AnNoted-Regressionstest in `source/mapping.d` erweitern (Vorbild ist der
   seit Paket 7 vorliegende Test, der die Leerzeichen-Hierarchie der Ebenen
   3–7 gegen den Scancode `39` prüft und zugleich `Noted` als eigene
   Gegenprobe gegen den 6-Ebenen-Originalstand absichert).
3. **`dub test`** – die Integritätstests fangen Strukturfehler ab (fehlende
   Ebenenzeilen, doppelte `dllName`, unvollständige `map`-Zeilen), bevor
   überhaupt gebaut wird.
4. **`dub build --config=tool && .\ananeo-tool.exe sheet AnNoted`** – das
   Blatt sichten. Der Codepunkt unter der Taste ist die Wahrheit, das Label
   nur das Sinnbild.
5. **Debug-Build starten, Übereinstimmungsprobe in einem nicht erhöhten
   Fenster**: tippen und mit der Anzeige vergleichen – sowohl im
   Erweiterungsmodus gegen `kbdnoted` als auch im Standalone-Modus, weil
   beide Sendepfade unterschiedlich sind (`sendNeoKey` unterscheidet
   zwischen Unicode-Paketen und nativer Tastenkombination).
6. **Commit nach Konvention.**

## Die Gegenrichtung: eine neue Ebenenzelle kann eine Doppelung erzeugen

Wer eine Zelle neu belegt, kann damit ein Zeichen auf eine Ebene holen, das im Compose-Baum schon steht – ohne Compose überhaupt anzufassen. Das ist meistens richtig so: Die Regel der Aufgabenteilung erlaubt die Doppelung ausdrücklich, solange die Compose-Sequenz Glied einer Systematik ist (die Ebene ist dann der schnelle Griff, der Baum die Herleitung).

Prüfen lässt es sich nach der Umbelegung mit:

```
ananeo-tool compose spiegel --layout AnNoted
```

Taucht die neue Zelle dort als `Einzelfall` auf, steht ihre Compose-Sequenz allein und ist damit ein Kandidat für den Schnitt. Taucht sie als `Reihe` oder `Muster` auf oder gar nicht, ist nichts zu tun. Die Regel entscheidet dabei **nie** über die Ebene – sie kann eine Compose-Zeile zum Schnitt vorschlagen, aber niemals verlangen, dass eine Ebenenzelle geräumt wird.
