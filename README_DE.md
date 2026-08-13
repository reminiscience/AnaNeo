# AnaNeo – Die Neo-Tastaturlayouts für Windows

[**This page in English**](README.md) – die englische Fassung ist die Hauptfassung, diese hier wird mitgeführt.

> **AnaNeo ist ein Fork von [ReNeo](https://github.com/Rojetto/ReNeo)** von Rojetto und qwertfisch. Der überwiegende Teil des Codes stammt aus ReNeo und steht wie dort unter GPL-3.0. AnaNeo ist ein privates Projekt, das öffentlich gemacht wurde – vor dem Verlassen auf das Programm bitte [Über diesen Fork](#über-diesen-fork) lesen.

📖 **[Das Wiki](https://github.com/reminiscience/AnaNeo/wiki)** dokumentiert alle 21 Ebenen – eine Seite je Themenblock, mit einem Bild je Ebene – und den vollständigen Konfigurationsraum. Es ist englisch.

AnaNeo implementiert das [Neo-Tastaturlayout](http://neo-layout.org/) und seine Verwandten für Windows. Dabei kann man sich für eine von zwei Varianten entscheiden:
1. Im *Standalone-Modus* ersetzt AnaNeo alle Tastendrücke des nativen Layouts (meistens QWERTZ) durch das gewünschte Neo-Layout. Dafür muss zum Systemstart nur die AnaNeo-EXE ausgeführt werden.
2. Im *Erweiterungsmodus* installiert man einen nativen Neo-Treiber wie [kbdneo](https://neo-layout.org/Einrichtung/kbdneo/). AnaNeo ergänzt dann alle Funktionen, die nativ nicht umsetzbar sind (Capslock, Steuertasten auf Ebene 4, Compose, ...).

![AnaNeo Bildschirmtastatur Ebene 1](docs/osk_screenshot.png "AnaNeo Bildschirmtastatur")

## Über diesen Fork

AnaNeo tritt nicht gegen ReNeo an, es führt ein Layout weiter. ReNeo trägt die ganze Neo-Familie und bleibt nah an den veröffentlichten Standards; AnaNeo behält vier dieser Layouts – *Neo*, *NeoQwertz*, *Noted* und *AnNoted* (Bone, AdNW, Mine, KOY, VOU und 3l sind entfallen) – und steckt die Arbeit in **AnNoted**, die eigene Variante von *Noted*.

- **Noted auffrischen.** *AnNoted* behält die Buchstabenanordnung von Noted und dessen nativen Treiber (`kbdnoted.dll`), darf aber vom veröffentlichten Standard abweichen, wo die Erweiterung einen Grund dafür hat. *Noted* selbst bleibt unverändert im Paket, als standardtreues Standalone-Layout – es wird also nichts weggenommen.
- **Mehr Ebenen.** *AnNoted* hat 21 Ebenen statt 6: die Ebenen 1 bis 4 wie gewohnt, dann fünf Themenblöcke – Mathematik, Typografie, Altgriechisch, Kyrillisch, Extra – und Ebene 21 für die Compose-Modifikatoren. Keine physische Taste trägt die Blockmodifier; ein Block wird gerastet. Genau deshalb musste das Rastmodell ein tragender Teil des Programms werden statt eines Schalters für Ebene 4.
- **Die Funktionalität anders systematisieren.** Jede Modifier-Menge lässt sich rasten, und eine Rastung steht in der `config.json`, statt fest im Code. Der Compose-Baum folgt einer ausgesprochenen Grammatik – *die Ebene trägt den Griff, der Baum trägt die Herleitung* –, und zwei der Compose-Module (Schriftvarianten, Einkreisungen) werden aus Code erzeugt statt von Hand gepflegt; Tests halten Datei und Rechnung zusammen. Ein eigenes Konsolenprogramm, `ananeo-tool`, gibt Auskunft über den Compose-Bestand: Herkunft, Abdeckung, Lücken, Doppelungen, und auf welcher Ebene eine Fortsetzung liegt.
- **Die Darstellung ist umgebaut, nicht erfunden.** Die Bildschirmtastatur stammt aus ReNeo. Was sie *zeigt*, wird inzwischen in einem eigenen, testbaren Modul gerechnet; sie zeichnet über die `cmap`-Tabelle der Schrift und stellt damit auch Zeichen jenseits der Basic Multilingual Plane dar (Schach, Alchemie, mathematische Alphanumerik) statt leerer Kästchen; sie hat einen Ebenenstreifen und eine laufende Vorschau der Compose-Sequenz. Neu daneben ist ein druckbares, in sich geschlossenes **Belegungsblatt** als HTML.

Unverändert aus ReNeo stammt der Teil, der am schwersten richtig und am leichtesten kaputt zu bekommen ist: der Low-Level-Tastaturhook, die Modifier-Buchführung und der erzwungene Modifier-Zustand. Diese Arbeit ist die von Rojetto und qwertfisch – und der Grund, warum sich dieser Fork auf Layouts und Compose konzentrieren konnte.

### Wie dieses Repo entstanden ist

**AnaNeo ist gevibecoded.** Fast der gesamte Code, die Tests und die Dokumentation, die in diesem Fork dazugekommen sind, stammen von Claude (Anthropics Agent Claude Code) unter menschlicher Anleitung. Menschlich sind die Entscheidungen, die Durchsicht und die manuelle Abnahme: Alles, was den Tastaturhook, den Modifier-Zustand oder das Zeichnen berührt, lässt sich nicht per Unittest belegen und muss auf einem echten Windows-Rechner ausprobiert werden. Jede Entwicklungsrunde endet deshalb mit einem geschriebenen Abnahmeprotokoll.

Zwei Folgen, die man vor dem Installieren kennen sollte:

- Die automatische Testsuite ist umfangreich und deckt die reinen Daten- und Logikmodule ab – Layout-Parser, Ebenen- und Rastlogik, Compose-Baum, Tastenbeschreibung, den `cmap`-Leser, die Berichterzeuger. Sie deckt **nicht** den Hook ab, nicht das Senden von Tastenereignissen und nicht das Zeichnen selbst.
- Die Entwicklung fand in einer privaten Arbeitskopie statt. Projektlog, Spezifikationen, Pläne und Abnahmeprotokolle sind deutschsprachige Arbeitsdokumente und **nicht Teil dieses Repos** – für Leser von außen gedacht sind diese Datei und `README.md`.

## Installation

1. *Optional*: [kbdneo](https://neo-layout.org/Einrichtung/kbdneo/) normal installieren
2. [Neuesten AnaNeo-Release](https://github.com/reminiscience/AnaNeo/releases/latest) herunterladen und in ein Verzeichnis mit Schreibrechten entpacken (z. B. `C:\Users\[USER]\AnaNeo`)
3. `ananeo.exe` starten oder [zu Autostart hinzufügen](docs/autostart.md). Über das Trayicon kann das Programm deaktiviert und beendet werden.
4. *Optional*: [`config.json` anpassen](#konfiguration) (wird beim ersten Start generiert)

*Update*

Neuen Release herunterladen und vorhandene Dateien mit den neuen überschreiben. Da `config.json` nicht im Release enthalten ist, bleiben Nutzereinstellungen erhalten.

*Deinstallation*

1. *Optional*: kbdneo nach Wiki-Anleitung deinstallieren
2. AnaNeo-Verzeichnis löschen und aus Autostart entfernen

## Funktionen

- Unterstützt die Layouts *Neo*, *NeoQwertz*, *Noted* und *AnNoted*, umschaltbar über das Traymenü. AnNoted ist die eigene Variante von Noted; im Erweiterungsmodus gegen `kbdnoted.dll` ist sie die aktive, Noted selbst nur im Standalone-Modus wählbar.
- **Rastbare Ebenen**: Capslock (beide Shift-Tasten), Mod3-Lock, Mod4-Lock und jede weitere Rastung, die man über `"locks"` in der `config.json` einrichtet. `M3+Esc` löst alles. Ist eine Ebene gerastet, wechselt das Tray-Icon die Farbe und der Tooltip nennt die Rastung.
- **Themenebenen**: Über die Ebenen 1 bis 4 hinaus hat *AnNoted* fünf Themenblöcke und eine Modifikator-Ebene – 21 insgesamt. Jeder Block hat einen eigenen Modifier (Mod5 bis Mod9); weil keine physische Taste diese trägt, betritt man einen Block durch Rasten, und gehaltenes Shift, Mod3 oder Mod4 erreichen dann seine weiteren Ebenen.

    | Ebenen | Auslöser | Block |
    |---|---|---|
    | 1–4 | – / Shift / Mod3 / Mod4 | wie gewohnt |
    | 5–8 | `M3+F2` / +Shift / +Mod3 / +Mod4 | Mathematik und Logik (7 = Hochstellung, 8 = Tiefstellung) |
    | 9–12 | `M3+F3` / +Shift / +Mod3 / +Mod4 | Typografie |
    | 13–14 | `M3+F4` / +Shift | Altgriechisch, klein/groß |
    | 15–16 | `M3+F5` / +Shift | Kyrillisch (Russisch) |
    | 17–20 | `M3+F6` / +Shift / +Mod3 / +Mod4 | Extra: Symbole, Emoji (19), Würfel und Alchemie (20) |
    | 21 | `Mod3+Mod4` halten | die sechs Compose-Modifikatoren, aus **jedem** Rastzustand erreichbar |

    **Diese Ebenen hat nur *AnNoted*** – *Neo*, *NeoQwertz* und *Noted* bleiben bei ihren sechs veröffentlichten. Die Leertaste trägt auf den Ebenen 3 bis 7 ihre eigene Hierarchie immer schmalerer Leerzeichen.

    👉 **[Das Wiki dokumentiert jede Ebene](https://github.com/reminiscience/AnaNeo/wiki/Layers)**, eine Seite je Block, mit einem Bild je Ebene.

- **Bildschirmtastatur**, über das Traymenü oder `M3+F1`. Folgt den gedrückten Modifiern, nennt bei gerasteter Ebene deren Nummer und Blocknamen und zeigt eine laufende Compose-Sequenz in der Vorschau. Zeichnet auch Zeichen jenseits der Basic Multilingual Plane vollständig – Schach, Alchemie, Mathematical Alphanumeric Symbols – über eine mitgelieferte Symbolschrift (*Noto Sans Symbols 2*, in `fonts/`, SIL Open Font License 1.1), die privat in den Prozess geladen und nicht installiert wird. Fünf Farbschemata; Vorgabe ist `Sachlich`, hell/dunkel folgt der Windows-Einstellung. Siehe [Wiki](https://github.com/reminiscience/AnaNeo/wiki/Configuration-OSK).
- *Alle* toten Tasten und Compose-Kombinationen, durch Nutzer erweiterbar: Die Liste `composeModules` in der `config.json` bestimmt, welche Dateien aus `compose/` geladen werden und in welcher Reihenfolge. AnaNeo legt eine eigene Grammatik darüber – Hoch- und Tiefstellung, Einkreisung und 1021 Schriftvarianten, hergeleitet statt gespeichert. Siehe [Wiki](https://github.com/reminiscience/AnaNeo/wiki/Compose).
    - Unicode-Eingabe: `♫uu[Codepunkt hex]<space>`, Beispiel `♫uu1f574<space>` → 🕴
    - Römische Zahlen: `♫rn[Zahl]<space>` klein, `♫RN[Zahl]<space>` groß, 1 bis 3999. `♫rn1970<space>` → ⅿⅽⅿⅼⅹⅹ
    - Klebrige Modifikatoren halten die Sequenz offen: `ˣ 1 2 3` gibt ¹²³
- `Shift+Pause` (de)aktiviert die Anwendung.
- **Einhandmodus**: Ist er aktiv und wird die Spiegeltaste (standardmäßig die Leertaste) gehalten, spiegelt sich die ganze Tastatur. Traymenü oder `M3+F10`.
- Weitere Layouts können in `layouts.json` hinzugefügt und angepasst werden.

Als Erweiterung zum nativen Treiber:

- Steuertasten auf Ebene 4
- Wird das native Layout als Neo-verwandt erkannt (`kbdneo2.dll`, `kbdgr2.dll`, `kbdnoted.dll`), schaltet AnaNeo automatisch in den Erweiterungs-Modus. Umschalten zwischen Layouts ist ganz normal möglich.
- Verbesserte Kompatibilität mit Qt- und GTK-Anwendungen. Workaround für [diesen Bug](https://git.neo-layout.org/neo/neo-layout/issues/510).
- Compose-Taste `M3+Tab` sendet keinen Tab mehr an Anwendung. Workaround für [diesen Bug](https://git.neo-layout.org/neo/neo-layout/issues/397).

## Belegungsblatt

Ein druckbares, in sich geschlossenes HTML-Blatt der aktuellen Belegung – eine Tastatur, ein Reiter je Ebene, beim Drucken alle Ebenen untereinander. Zwei Wege dorthin: der Traymenü-Eintrag »Belegungsblatt erzeugen« zeigt, was das laufende Programm geladen hat, und `ananeo-tool sheet [Layoutname]` erzeugt es ohne laufendes AnaNeo aus den Dateien auf der Platte.

Ein Akzentbalken markiert eine Taste, die ein Zeichen erzeugt, darunter steht ihr Codepunkt; gedämpfte Tasten sind Funktionstasten, flächige die Modifier, gestrichelte die unbelegten Positionen. Das [Wiki](https://github.com/reminiscience/AnaNeo/wiki/Layout-Sheet) erklärt es vollständig.

## Konfiguration

Zwei Dateien, beide neben der EXE: `config.json` enthält die eigenen Einstellungen und entsteht beim ersten Start, `layouts.json` die Layouts selbst. Für beide reicht Ändern und Neustarten, kein Neubau.

**Die vollständige Referenz steht im Wiki** (englisch), mit den Herleitungen und den Fallstricken:

| Wiki-Seite | Inhalt |
|---|---|
| [Configuration](https://github.com/reminiscience/AnaNeo/wiki/Configuration) | wie eigene Einstellungen und Vorgaben zusammengeführt werden, und die Optionen der obersten Ebene |
| [Locks and triggers](https://github.com/reminiscience/AnaNeo/wiki/Configuration-Locks) | `locks` – was womit gerastet wird, und die festen Funktionen |
| [On-screen keyboard](https://github.com/reminiscience/AnaNeo/wiki/Configuration-OSK) | `osk` – Farbschema, ISO/ANSI, Nummernblock, Zahlenreihe, Modifier-Namen |
| [Compose modules](https://github.com/reminiscience/AnaNeo/wiki/Configuration-Compose-Modules) | `composeModules`, `compose` – welche Sequenzdateien laden, in welcher Reihenfolge |
| [Hotkeys and blacklist](https://github.com/reminiscience/AnaNeo/wiki/Configuration-Hotkeys-and-Blacklist) | `hotkeys`, `blacklist` |
| [One-handed mode](https://github.com/reminiscience/AnaNeo/wiki/Configuration-One-Handed-Mode) | `oneHandedMode` – Spiegeltaste und Spiegelzuordnung |
| [Editing layouts](https://github.com/reminiscience/AnaNeo/wiki/Editing-Layouts) | `layouts.json` – Ebenen, Tasten, Keysyms, erzwungene Modifier |

### Die Optionen im Überblick

| Option | Werte | Bedeutung |
|---|---|---|
| `standaloneMode` | `true` (Vorgabe) / `false` | das native Layout ersetzen, oder einen Neo-Treiber nur ergänzen und sich sonst deaktivieren |
| `standaloneLayout` | `"AnNoted"`, `"Noted"`, `"Neo"`, `"NeoQwertz"` | Layout für den Standalone-Modus; auch im Traymenü |
| `language` | `"german"` / `"english"` | Programmsprache |
| `filterNeoModifiers` | `true` (Vorgabe) / `false` | M3/M4-Events im Erweiterungsmodus vor Programmen verbergen ([Bug](https://git.neo-layout.org/neo/neo-layout/issues/510)); `false`, wenn man sie in Anwendungen belegen will |
| `autoNumlock` | `true` (Vorgabe) / `false` | Numlock automatisch anschalten; `false` bei Laptops mit Nummernblock auf dem Buchstabenfeld |
| `blacklist` | Liste von `{"windowTitle": "…"}` | AnaNeo deaktivieren, wo der Fenstertitel auf die RegEx passt |
| `composeModules` | Liste von Dateinamen ohne Endung | welche Dateien aus `compose/` geladen werden, **in dieser Reihenfolge** |
| `compose.oskAutoShow` | `false` (Vorgabe) / `true` | Bildschirmtastatur während einer Compose-Sequenz öffnen |
| `locks.oskAutoShow` | `false` (Vorgabe) / `true` | Bildschirmtastatur öffnen, solange eine Ebene gerastet ist |
| `locks.triggers` | Liste von `{"chord": …, "lock"/"action": …}` | welcher Griff was rastet oder auslöst |
| `osk.theme` | `"Sachlich"` (Vorgabe), `"Grey"`, `"NeoBlue"`, `"ColorClassic"`, `"ColorGreen"` | Farbschema; `Sachlich` folgt der Hell/Dunkel-Einstellung von Windows |
| `osk.layout` | `"iso"` / `"ansi"` | Bauform der Tastatur |
| `osk.numpad`, `osk.numberRow` | `true` / `false` | Nummernblock zeigen, Zahlenreihe zeigen |
| `osk.modifierNames` | `"standard"` / `"three"` | Modifier als `M3`, `M4` oder als `Sym`, `Cur` beschriften |
| `hotkeys.toggleActivation` | z. B. `"Shift+Pause"`, oder `null` | globales Kürzel zum An- und Abschalten von AnaNeo |
| `hotkeys.toggleOSK`, `hotkeys.toggleOneHandedMode` | Kürzel oder `null` (Vorgabe) | ohnehin über `M3+F1` und `M3+F10` erreichbar |
| `oneHandedMode.mirrorKey` | Scancode, Vorgabe `"39"` (Leertaste) | Taste, die die Tastatur spiegelt, solange sie gehalten wird |
| `oneHandedMode.mirrorMap` | Scancodes `"Original": "Spiegel"` | welche Taste welche wird; bei ergonomischen und Matrixtastaturen anzupassen |
| `configVersion` | Zahl, wird selbst gepflegt | hält fest, welche Migrationsschritte diese Konfiguration schon gesehen hat |

Hotkey-Syntax: die Modifier `Shift`, `Ctrl`, `Alt`, `Win` plus eine Haupttaste aus dem Enum `VKEY` in [`source/mapping.d`](https://github.com/reminiscience/AnaNeo/blob/develop/source/mapping.d), das auf der [Win32-Doku](https://docs.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes) beruht. Bei `null` wird kein globaler Hotkey angelegt.

Auslöser-Syntax: `"chord"` plus entweder `"lock"` oder `"action"`. Zweimal derselbe Modifier (`"Shift+Shift"`) heißt »linke und rechte Taste zusammen«, sonst sind alle Teile bis auf den letzten gehaltene Modifier. Rastbar sind `Shift` und `Mod3` bis `Mod9` – nicht Strg und Alt, die jedes Programm-Kürzel kapern würden. Als Funktion stehen `"capslock"`, `"clearLocks"`, `"osk"`, `"oneHandedMode"` und `"compose"` bereit. Die vollständige Grammatik steht im [Wiki](https://github.com/reminiscience/AnaNeo/wiki/Configuration-Locks).

### Nach einem Update

**Beim Abgleich mit den Vorgaben werden Arrays als Ganzes ersetzt, nicht feldweise.** Wer schon einen `"triggers"`-Eintrag in seiner `config.json` hat, bekommt neu hinzugekommene Auslöser deshalb nicht. Einmal den Eintrag – oder gleich den ganzen `"locks"`-Block – löschen und neu starten.

Für `"composeModules"` galt dasselbe; umbenannte und neu ausgelieferte Module werden inzwischen automatisch nachgezogen. Fehlt trotzdem etwas, hilft auch dort einmaliges Löschen des Eintrags.

### Layouts anpassen

`layouts.json` definiert jedes Layout: `modifiers` (Scancode → Modifier), `layers` (der Modifier-Zustand je Ebene, der Reihe nach geprüft), `capslockableKeys` und `map` (Scancode → ein Eintrag je Ebene). Ein Eintrag trägt einen `keysym` und entweder `char` oder `vk`, dazu wahlweise `label` und erzwungene `mods`.

Eigene Änderungen gehören in *AnNoted* – die anderen drei Layouts bilden veröffentlichte Standards nach. Eine Ebene mehr heißt: ein Eintrag mehr in jeder Zeile von `map`.

Die [Wiki-Seite](https://github.com/reminiscience/AnaNeo/wiki/Editing-Layouts) enthält die Feldreferenz, den Ablauf für ein neues Layout und die Fallstricke – leere Zellen werden `VK_VOID`, unsichtbare Zeichen brauchen `\uXXXX`-Escapes, eine Zelle braucht `keysym` **und** `char`, und die Datei darf nie mit einer JSON-Bibliothek neu serialisiert werden.

# Virtuelle Maschinen und Remote Desktop
Sobald mehrere „ineinander“ laufende Betriebssysteme ins Spiel kommen, wird es mit alternativen Tastaturlayouts fast immer haarig.
Da sich die verschiedenen VM-Programme und Remote Desktop Clients unterschiedlich verhalten, gibt es leider keine universelle Lösung, sondern nur eine grundsätzliche Empfehlung und ein paar erprobte Konfigurationen.

Für beste Kompatibilität sollte im Allgemeinen das *innerste* System das Alternativlayout übernehmen, und in allen äußeren Systeme QWERTZ eingestellt sein.
Bei VMs bedeutet das QWERTZ im Wirt und den passenden Neo-Treiber im Gast.
Im Fall von Remote-Desktop-Verbindungen heißt es QWERTZ lokal und einen Neo-Treiber im Remote-System.

Wenn sich herausstellt, dass es ohne AnaNeo besser funktioniert, können die entsprechenden Programme auch auf die *Blacklist* gesetzt werden, sodass sich AnaNeo automatisch deaktiviert. Siehe dazu [Konfiguration](#konfiguration).

## WSL mit VcXsrv als X-Server

In Windows QWERTZ (ohne AnaNeo), dann das Neo-Layout in X11 einstellen. Für Neo lautet der Befehl `setxkbmap de neo`, für andere Layouts muss eventuell noch eine passende xkbmap installiert werden.

## VirtualBox

Im Wirtsystem QWERTZ einstellen, dann Neo-Treiber (z. B. AnaNeo) im Gastsystem installieren.

## [Remote Desktop Manager](https://remotedesktopmanager.com/)

Es geht offenbar auch AnaNeo im Standalone-Modus auf dem lokalen System mit QWERTZ auf dem Remote-System. Zumindest Buchstaben und (nicht-Unicode)-Sonderzeichen werden dann auf die Remote-Systeme korrekt weitergeleitet.

# Für Entwickler
## Kompilieren
AnaNeo ist in D geschrieben und nutzt `dub` für Projektkonfiguration und Kompilation.
Es gibt drei wichtige Kompilationsvarianten:

1. Debug mit `dub build`: Neben Debuggingsymbolen öffnet die generierte EXE eine Konsole um Informationen ausgeben zu können.
2. Debug und Log mit `dub build --build=debug-log`: Wie debug, nur dass zusätzlich in `ananeo_log.txt` alle Konsolenausgaben abgespeichert werden. Achtung: Hier können potentiell sensible Daten landen.
3. Release mit `dub build --build=release`: Optimierungen sind aktiviert und es wird keine Konsole geöffnet.

Die Ressourcendatei `res/ananeo.res` wird mit `rc.exe` aus dem Windows SDK erstellt (x86-Version, die generierte res-Datei funktioniert sonst nicht). Dazu reicht der Befehl `rc.exe ananeo.rc`.

Cairo-DLL stammt von https://github.com/preshing/cairo-windows. Die zugehörigen D-Header wurden mit [DStep](https://github.com/jacob-carlborg/dstep) aus den C-Headern generiert und manuell angepasst.

## Release
Wenn ein Tag nach dem Schema `v*` im Repo ankommt, löst eine GitHub Action den Release aus. Auf Basis der `config.[layout].json` Dateien werden verschiedene vorkonfigurierte ZIP-Archive erstellt und ein Release-Draft angelegt. Der kann dann manuell bearbeitet und freigeschaltet werden.

# Bibliotheken
Nutzt [Cairo](https://www.cairographics.org/), lizensiert unter der GNU Lesser General Public License (LGPL) Version 2.1.