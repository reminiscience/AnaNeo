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
4. *Optional*: [`config.json` anpassen](#Allgemeine-Konfiguration) (wird beim ersten Start generiert)

*Update*

Neuen Release herunterladen und vorhandene Dateien mit den neuen überschreiben. Da `config.json` nicht im Release enthalten ist, bleiben Nutzereinstellungen erhalten.

*Deinstallation*

1. *Optional*: kbdneo nach Wiki-Anleitung deinstallieren
2. AnaNeo-Verzeichnis löschen und aus Autostart entfernen

## Funktionen

Allgemein:

- Unterstützt die Layouts *Neo*, *NeoQwertz*, *Noted* und *AnNoted* – AnNoted ist die eigene Variante von Noted mit besonderen Leerzeichen auf der Leertaste; im Erweiterungsmodus gegen `kbdnoted.dll` ist AnNoted aktiv, Noted selbst nur noch im Standalone-Modus wählbar
- Im Traymenü kann zwischen Layouts gewechselt werden
- Rastbare Ebenen: Capslock (beide Shift-Tasten), Mod3-Lock (beide Mod3-Tasten), Mod4-Lock (beide Mod4-Tasten) und weitere frei konfigurierbare Rastungen über `"locks"` in der `config.json`. `M3+Esc` löst alle Rastungen. Ist eine Ebene gerastet, wechselt das Tray-Icon die Farbe und der Tooltip nennt die Rastung.
- Themenebenen: Über die Ebenen 1 bis 4 hinaus gibt es fünf Themenblöcke, jeder mit einem eigenen Block-Modifier (Mod5 bis Mod9). Ein Block wird gerastet (`M3+F2` bis `M3+F6`); bei gerasteter Basis erreichen gehaltenes Shift, Mod3 und Mod4 die weiteren Ebenen des Blocks. Physische Tasten haben Mod5 bis Mod9 nicht – alle Blöcke sind ausschließlich über Rastung erreichbar.

    | Ebenen | Auslöser | Block |
    |---|---|---|
    | 1–4 | – / Shift / Mod3 / Mod4 | wie gewohnt |
    | 5–8 | Mod5 / +Shift / +Mod3 / +Mod4 | Mathematik und Logik (7 = Hochstellung, 8 = Tiefstellung) |
    | 9–12 | Mod6 / +Shift / +Mod3 / +Mod4 | Typografie (11/12 tragen drei Compose-Tottasten, Rest weiter Reserve) |
    | 13–14 | Mod7 / +Shift | Altgriechisch, klein/groß |
    | 15–16 | Mod8 / +Shift | Kyrillisch (Russisch) |
    | 17–20 | Mod9 / +Shift / +Mod3 / +Mod4 | Extra: Symbol-Zonen, Emoji (19), Würfel/Alchemie/Technik (20) |
    | 21 | Mod3+Mod4 | Compose-Modifikatoren, aus **jedem** Rastzustand erreichbar |

    Ebene 21 trägt auf der Grundreihe die sechs Startzeichen der Compose-Grammatik, jedes auf dem Anfangsbuchstaben seiner Kategorie: `𝔵` Schriftvariante (S), `ⓧ` Einkreisung (E), `↻` Drehung (D), `ₓ` Tiefstellung (T), `˞` Retroflex/Haken (R), `ˣ` Hochstellung (H). Sie ist die einzige Ebene, die sich von der Rastung ausnimmt – wer in einem gerasteten Block `Mod3+Mod4` greift, landet dort statt auf Ebene 1. Beispiel: `Mod3+Mod4`, `S` loslassen, dann `d K` gibt `𝕂`.

    Vorgabe-Auslöser: `M3+F2` Mathematik, `M3+F3` Typografie, `M3+F4` Griechisch, `M3+F5` Kyrillisch, `M3+F6` Extra. `M3+F7` schaltet Shift zu oder weg und bleibt damit auf der zweiten Ebene des jeweiligen Blocks.

    Die Leertaste trägt ihre eigene Hierarchie: Ebene 3 geschütztes Leerzeichen, Ebene 4 schmales geschütztes Leerzeichen, Ebene 5 dünnes Leerzeichen, Ebene 6 Haarleerzeichen, Ebene 7 Nullbreiten-Leerzeichen; ab Ebene 8 tippt sie normal. Die Numpad-0 der Ebene 4 liegt dafür auf `w`. Die Compose-Präfixe für Hoch- und Tiefstellung lagen bis zur Grammatikrunde auf der `^`-Taste; sie stehen jetzt zusammen mit den übrigen Modifikatoren auf Ebene 21, und `Mod3`+`^` gibt seitdem nichts mehr aus – die eine Stelle, an der AnNoted bewusst vom Neo-Standard abweicht.

    **Diese Ebenen hat nur das Layout *AnNoted*.** *Neo*, *NeoQwertz* und *Noted* bleiben bei ihren sechs veröffentlichten Ebenen; von den Themen-Auslösern liefern sie nur `M3+F2` aus, und dort heißt die Rastung `Mod3+Mod4`, weil sie die vorhandene Ebene 6 trifft.

    Zwei Folgen dieses Ebenenschnitts in AnNoted: `Shift+Mod3` hat keine eigene Ebene und fällt auf Ebene 1 zurück (`Mod3+Mod4` trifft seit der Grammatikrunde die Modifikator-Ebene 21). Und innerhalb eines gerasteten Blocks führen nur die definierten Erweiterungen (+Shift, bei Mathematik, Typografie und Extra auch +Mod3/+Mod4) auf eine Ebene – alles andere fällt ebenfalls auf Ebene 1 zurück; wer zwischendurch Sonderzeichen oder Navigation braucht, löst die Rastung kurz mit `M3+Esc`.
- **Bildschirmtastatur**: Wird über Tray-Menü ein- und ausgeschaltet oder per Shortcut `M3+F1`. Wechselt zwischen Ebenen, wenn Modifier gedrückt werden. Solange eine Ebene gerastet ist, steht oben ein Streifen mit der aktuellen Ebene, ihrem Blocknamen und dem Modifier-Satz (»Ebene 13 · Griechisch · Mod7«); läuft zugleich eine Compose-Sequenz, teilt sie sich den Streifen mit ihr. Zeichnet auch Zeichen jenseits der Basic Multilingual Plane vollständig (Schach, Alchemie, Mathematical Alphanumeric Symbols); dafür wird beim Start eine mitgelieferte Symbolschrift (*Noto Sans Symbols 2*, Verzeichnis `fonts/`, Lizenz SIL Open Font License 1.1 in `fonts/OFL.txt`) privat in den Prozess geladen, ohne sie zu installieren. Findet keine Schrift einen passenden Glyphen, zeigt die Taste ersatzweise klein ihren Codepunkt statt eines leeren Kastens. Fünf Farbschemata stehen zur Wahl; Vorgabe ist seit Paket 5b `Sachlich` (hell/dunkel folgt automatisch der Windows-Einstellung) – wer bisher `ColorClassic` (den alten Vorgabewert) eingestellt hatte, bekommt beim nächsten Start automatisch `Sachlich`, ein ausdrücklich gewähltes `ColorGreen` bleibt unangetastet.
- *Alle* tote Tasten und Compose-Kombinationen. Diese sind auch durch den Nutzer erweiterbar; welche `.module`-Dateien aus dem Verzeichnis `compose/` geladen werden und in welcher Reihenfolge, bestimmt die Liste `composeModules` in der `config.json`.
- Spezial-Compose-Sequenzen
    - Unicode-Eingabe: `♫uu[codepoint hex]<space>` fügt Unicode-Zeichen ein. Beispiel: `♫uu1f574<space>` → 🕴
    - Römische Zahlen: `♫rn[zahl]<space>` für kleine Zahlen, `♫RN[zahl]<space>` für große Zahlen zwischen 1 und 3999. Beispiel: `♫rn1970<space>` → ⅿⅽⅿⅼⅹⅹ, `♫RN1970<space>` → ⅯⅭⅯⅬⅩⅩ
- Klebrige Modifikatoren: Einige Compose-Modifikatoren (etwa `ˣ` Hochstellung, `ₓ` Tiefstellung, `ⓧ` Einkreisung, `𝔵` Schriftvariante) halten die Sequenz nach der Ausgabe eines Zeichens offen, statt sie zu beenden – der nächste Tastendruck läuft am Modifikator weiter. Beispiel: `ˣ 1 2 3` gibt ¹²³. Man verlässt den Modifikator entweder mit einer Taste ohne Compose-Eintrag (tippt normal weiter), mit `Escape` (verwirft die ganze Sequenz) oder mit dem Modifikator selbst (stummer Ausstieg, tippt sich nicht). **Fallstrick:** `x ˣ 2 y` ergibt `x²ʸ`, nicht `x²y` – das `y` folgt noch im Hochstell-Modus. Der Ausweg ist ein zusätzlicher Anschlag des Modifikators: `x ˣ 2 ˣ y` → `x²y`.
- `Shift+Pause` (de)aktiviert die Anwendung
- Einhandmodus: Wenn Modus aktiv ist und Leertaste (Standard) gehalten wird, wird die gesamte Tastatur „gespiegelt“. Umschalten über Tray-Menü oder per Shortcut `M3+F10`.
- Weitere Layouts können in `layouts.json` hinzugefügt und angepasst werden

## Belegungsblatt

Zwei Wege, die aktuelle Tastenbelegung als druckbares HTML-Dokument zu erzeugen:

- Traymenü → »Belegungsblatt erzeugen«: zeigt genau das, was das laufende Programm gerade geladen hat, und öffnet die Datei im Standardbrowser.
- Kommandozeile: `ananeo-tool sheet [Layoutname]` erzeugt dasselbe Blatt ohne laufendes AnaNeo, direkt aus den Dateien im EXE-Verzeichnis. Ohne Layoutnamen entsteht ein Blatt je Layout. `ananeo-tool.exe` ist ein eigenes Kompilat, das weder Cairo noch den Tastaturhook linkt.

Das Blatt ist eine einzige, in sich geschlossene HTML-Datei – ohne externe Verweise, auch ohne Netzverbindung nutzbar: eine Tastatur, ein Reiter je Ebene, Wechsel per Klick über etwas JavaScript. Beim Drucken (Druckvorschau genügt) oder mit abgeschaltetem JavaScript zeigt es stattdessen alle Ebenen untereinander – die Druckform.

Zur Lesart: Ein Akzentbalken markiert eine Taste, die ein Zeichen erzeugt, darunter steht ihr Codepunkt (`U+…`); ohne Balken und gedämpft dargestellt sind Funktionstasten (mit ihrem Tastennamen), flächig hinterlegt die Modifier, gestrichelt die unbelegten Positionen – Letztere sind beim Umbelegen die Arbeitsliste. Dieselbe Lesart gilt für die Bildschirmtastatur unter dem Farbschema `Sachlich`.

Als Erweiterung zum nativen Treiber:

- Steuertasten auf Ebene 4
- Wird das native Layout als Neo-verwandt erkannt (`kbdneo2.dll`, `kbdgr2.dll`, `kbdnoted.dll`), schaltet AnaNeo automatisch in den Erweiterungs-Modus. Umschalten zwischen Layouts ist ganz normal möglich.
- Verbesserte Kompatibilität mit Qt- und GTK-Anwendungen. Workaround für [diesen Bug](https://git.neo-layout.org/neo/neo-layout/issues/510).
- Compose-Taste `M3+Tab` sendet keinen Tab mehr an Anwendung. Workaround für [diesen Bug](https://git.neo-layout.org/neo/neo-layout/issues/397).

## Konfiguration

AnaNeo kann mit zwei Konfigurationsdateien angepasst werden. Es folgt die Referenz; das [Wiki](https://github.com/reminiscience/AnaNeo/wiki/Configuration) behandelt dasselbe ausführlicher und mit den Fallstricken.

### Allgemeine Konfiguration

`config.json` hat folgende Optionen:

- `"standaloneMode"`:
    - `true` (Standard): Das native Layout (z. B. QWERTZ) wird von AnaNeo mit dem ausgewählten Neo-Layout ersetzt. Hinweis: ist das native Layout bereits Neo-verwandt, verändert AnaNeo das Layout nicht und schaltet stattdessen automatisch in den Erweiterungsmodus.
    - `false`: Ist das native Layout Neo-verwandt, schaltet AnaNeo in den Erweiterungsmodus. Bei allen anderen Layouts deaktiviert sich AnaNeo automatisch.
- `"standaloneLayout"`: Layout, das für den Standalone-Modus genutzt werden soll. Auch übers Traymenü auswählbar.
- `"language"`: Programmsprache, `"german"` oder `"english"`.
- `"osk"`:
    - `"numpad"`: Soll Numpad in Bildschirmtastatur angezeigt werden?
    - `"numberRow"`: Soll die Zahlenreihe angezeigt werden?
    - `"theme"`: Farbschema für Bildschirmtastatur. Mögliche Werte: `"Grey"`, `"NeoBlue"`, `"ColorClassic"`, `"ColorGreen"`, `"Sachlich"` (Vorgabe seit Paket 5b, hell/dunkel folgt der Windows-Einstellung)
    - `"layout"`: `"iso"` oder `"ansi"`
    - `"modifierNames"`: `"standard"` (M3, M4, ...) oder `"three"` (Sym, Cur)
- `"hotkeys"`: Hotkeys für verschiedene Funktionen. Beispiel: `"Ctrl+Alt+F5"` oder `"Shift+Alt+Key_A"`. Erlaubte Modifier sind `Shift`, `Ctrl`, `Alt`, `Win`. Die Haupttaste ist ein beliebiger VK aus [dieser Enum](https://github.com/reminiscience/AnaNeo/blob/develop/source/mapping.d), die auf der [Win32-Doku](https://docs.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes) basiert. Ist ein Wert `null`, wird kein globaler Hotkey angelegt.
    - `"toggleActivation"`: AnaNeo aktivieren/deaktivieren
    - `"toggleOSK"`: Bildschirmtastatur öffnen/schließen. Zusätzlich ist `M3+F1` als Auslöser unter `"locks"` vorkonfiguriert.
    - `"toggleOneHandedMode"`: Einhandmodus (de)aktivieren. Zusätzlich ist `M3+F10` als Auslöser unter `"locks"` vorkonfiguriert.
- `"blacklist"`: Liste von Programmen, für die AnaNeo automatisch deaktiviert werden soll (zum Beispiel X-Server, Remote-Clients oder Spiele, bei denen es sonst Konflikte gibt). Momentan wird nach dem Fenstertitel entschieden, für den man eine *RegEx* definieren kann. *Beispiel*: Für Fenster, die "emacs" oder "Virtual Machine Manager" im Titel enthalten, soll AnaNeo sich deaktivieren. Die Config enthält dann
```
"blacklist": [
    {
        "windowTitle": "emacs"
    },
    {
        "windowTitle": "Virtual Machine Manager"
    }
]
```
- `"autoNumlock"`: Soll Numlock automatisch angeschaltet werden? Wenn die Tastatur einen echten Nummernblock besitzt, sollte diese Option für beste Kompatibilität immer auf `true` gesetzt sein. Bei Laptops mit nativer Numpad-Ebene auf dem Hauptfeld kann dieses Verhalten aber mit `false` deaktiviert werden.
- `"composeModules"`: Liste der Compose-Module, die geladen werden – und zwar in genau dieser Reihenfolge. Notiert wird der Dateiname ohne Endung; die Datei liegt in `compose/`. Bei einer Kollision zweier Sequenzen gilt: Eine Sequenz, die eine bestehende verlängert oder vorzeitig in ihr endet, wird verworfen; ein exaktes Duplikat überschreibt das frühere Ergebnis. Der Debug-Build schreibt darüber am Ende des Ladens einen Bericht ins Log. Zu jedem Modul kann eine gleichnamige `.remove`-Datei Einträge wieder entfernen. Gelesen wird sie, wenn ihr Modul in der Liste steht, sowie zusätzlich jede `.remove`-Datei ohne zugehöriges Modul – die gehört zu einer eingebauten Sonderroutine wie der Unicode-Eingabe (`unicode.remove`). Die Vorgabe lässt `klingon` und `klingon-kp` weg (zusammen zwei Drittel der Ladezeit).
- `"locks"`: Rastbare Ebenen und ihre Auslöser.
    - `"oskAutoShow"`: Soll sich die Bildschirmtastatur automatisch öffnen, solange eine Ebene gerastet ist? Sie schließt sich wieder, wenn die Rastung gelöst wird – es sei denn, sie war vorher schon offen.
    - `"triggers"`: Liste der Auslöser. Jeder Eintrag hat einen `"chord"` und entweder `"lock"` oder `"action"`.
        - `"chord"`: Zweimal derselbe Modifier (`"Shift+Shift"`, `"Mod4+Mod4"`) bedeutet »linke und rechte Taste zusammen«. Sonst sind alle Teile bis auf den letzten gehaltene Modifier und der letzte ist die Haupttaste, zum Beispiel `"Mod3+Escape"` oder `"Mod3+F2"`. Die Haupttaste ist ein VK-Name ohne das Präfix `VK_`.
        - `"lock"`: Liste der Modifier, die gerastet werden sollen, zum Beispiel `["Mod4"]` oder `["Mod3", "Mod4"]`. Erlaubt sind `Shift` und die Neo-Modifier `Mod3` bis `Mod9`. `Strg` und `Alt` lassen sich nicht rasten – eine dauerhaft gerastete Strg-Taste würde jedes Programm-Shortcut kapern. Damit ist jede Ebene ab der zweiten rastbar.
        - `"mode"`: `"replace"` (Vorgabe) ersetzt die laufende Rastung; derselbe Auslöser noch einmal löst sie. `"toggle"` schaltet die genannten Modifier stattdessen in die laufende Rastung hinein oder heraus – so rastet ein einziger Shift-Auslöser in jeder Themenebene deren zweite Ebene.
        - `"name"`: Anzeigename im Tooltip. Ohne Angabe wird der gerastete Modifier-Satz genommen, etwa `Mod7+Shift`.
        - `"action"`: Statt einer Rastung eine feste Funktion – `"capslock"` (Capslock des Betriebssystems umschalten), `"clearLocks"` (alle Rastungen lösen), `"osk"` (Bildschirmtastatur), `"oneHandedMode"` (Einhandmodus) oder `"compose"` (Compose-Sequenz beginnen). Die Vorgabe legt `"compose"` auf `Mod3+Tab`: Als Auslöser wirkt es in **jedem** Rastzustand, während das `Multi_key` auf Ebene 3 der Tab-Taste bei jeder Rastung verloren ist.
    - Ein gerasteter Neo-Modifier gilt als gedrückt, solange die zugehörige Taste **nicht** gehalten wird. Wer die Taste zusätzlich hält, kommt kurzzeitig auf die ungerastete Ebene zurück. **Ausnahme Shift:** Gehaltenes Shift hebt eine Shift-Rastung nicht auf – Shift bleibt für Programme sichtbar, damit Shift-Shortcuts und Shift+Klick weiter funktionieren. Shift wirkt neben fremden Rastungen ganz normal weiter und erreicht so die zweite Ebene des gerasteten Blocks.
    - Die frühere Option `"enableMod4Lock"` gibt es nicht mehr. Beim ersten Start wird sie entfernt; stand sie auf `false`, entsteht eine `"locks"`-Sektion ohne den Mod4-Auslöser.
    - **Nach einem Update:** Der Abgleich mit `config.default.json` ersetzt Arrays als Ganzes, nicht feldweise. Wer schon eine `config.json` hat, bekommt neu hinzugekommene Auslöser deshalb nicht automatisch. Dazu einmal den `"triggers"`-Eintrag – oder gleich den ganzen `"locks"`-Block – aus der `config.json` löschen und AnaNeo neu starten. **Dasselbe gilt für `"composeModules"`:** Auch das ist ein Array, auch dort ergänzt der Abgleich nichts. Wer von einer Fassung vor der Grammatikrunde kommt, löscht den Eintrag ebenfalls einmal – sonst wird weiterhin das entfernte `math-font` gesucht und die neue Schrifttabelle `ananeo-schrift` gar nicht geladen.
- `"filterNeoModifiers"`:
    - `true` (Standard): Die Tastenevents für M3 und M4 werden im Erweiterungsmodus von AnaNeo weggefiltert, Anwendungen bekommen von diesen Tasten also nichts mit. Workaround für [diesen Bug](https://git.neo-layout.org/neo/neo-layout/issues/510).
    - `false`: Anwendungen sehen M3/M4. Notwendig, wenn man in den Anwendungen mit diesen Tasten Optionen verknüpfen will.
- `"oneHandedMode"`:
    - "`mirrorKey"`: Scancode der Taste zum Spiegeln, standardmäßig ist die Leertaste (`44`) eingestellt.
    - "`mirrorMap"`: Zuordnung der gespiegelten Tasten nach Scancode in der Form `"[Originaltaste]": "[Spiegeltaste]"`. Muss für ergonomische oder Matrixtastaturen evtl. angepasst werden.

### Layouts anpassen

In `layouts.json` können Layouts angepasst und hinzugefügt werden. Jeder Eintrag besitzt folgende Parameter:

- `"name"`: Name des Layouts, so wie er im Menü angezeigt wird.
- `"dllName"` (Optional): Name der zugehörigen nativen Treiber-DLL. Existiert diese nicht, kann der Parameter weggelassen werden.
- `"modifiers"`: Scancodes aller Modifier, auch alle nativen Modifier müssen hier gemappt werden. Mit `+` am Ende des Scancodes wird das Extended-Bit gesetzt, zum Beispiel `36+` für die rechte Shift-Taste. Mögliche Modifier sind `LShift`, `LCtrl`, `LAlt`, `LMod3`, `LMod4` (jeweils auch rechte Variante) sowie weitere Mod-Tasten `Mod5` bis `Mod9`.
- `"layers"`: Modifier-Kombinationen für jede Ebene. Die Ebenen werden zur Laufzeit nacheinander getestet und die erste Ebene übernommen, deren Modifier die spezifizierten Werte haben.
- `"capslockableKeys"`: Array von Scancodes, die von Capslock beeinflusst werden sollen. Typischerweise sind das alle Buchstaben, inklusive „äöüß“.
- `"map"`: Das tatsächliche Layout in Form von Arrays für jeden Scancode. Jeder Eintrag enthält so viele Einträge, wie Ebenen in `"layers"` definiert wurden – wer eine Ebene hinzufügt, braucht also in jeder Zeile einen Eintrag mehr. Fehlende Einträge werden beim Laden als leere Taste ergänzt und im Debug-Log gemeldet; das Layout startet also, die Ebene bleibt dort aber stumm. Inhalt eines Eintrags:
    - `"keysym"`: X11-Keysym der Taste, entweder aus `keysymdef.h` oder in der Form `U1234` für Unicode-Zeichen. Wird für Compose benutzt.
    - **Entweder** `"vk"`: Windows Virtual Key aus dem Enum `VKEY` in `mapping.d`. Nur genutzt für Steuertasten.
    - **Oder** `"char"`: Unicode-Zeichen, das mit der Taste erzeugt werden soll.
    - `"label"`: (Optional) Beschriftung für Bildschirmtastatur. Als Fallback wird der Wert von `"char"` genutzt.
    - `"mods"`: (Optional, nur für VK-Mappings) Modifier, die gedrückt (`true`) oder losgelassen (`false`) werden sollen. Beispiel: `"mods": {"LCtrl": true, "LAlt": true}`. Mögliche Modifier sind `LShift`, `RShift`, `LCtrl`, `RCtrl`, `LAlt`.

Zum Erstellen neuer Layouts hat sich folgender Arbeitsablauf bewährt:

1. Bestehendes Layout kopieren und neuen Namen eintragen
2. Die Zeilen der Buchstabentasten (also ab Scancode `0C`) neu ordnen, sodass diese auf der Tastatur von oben links nach unten rechts gelesen in der richtigen Reihenfolge sind.
3. Mit Blockauswahl die Scancodes eines bestehenden Layouts kopieren, und die (jetzt falsch geordneten) Scancodes des neuen Layouts überschreiben.
4. Mit Blockauswahl Ebenen 3 und 4 eines bestehenden Layouts kopieren, und Ebenen 3 und 4 des neuen Layouts überschreiben.
5. `modifiers` und `capslockableKeys` ggf. anpassen

So bleiben Ebenen 3 und 4 an der richtigen Stelle, und die anderen Ebenen werden nach der neuen Buchstabenanordnung permutiert.

Folgende Regex kann beim Ausrichten der Spalten eines Layouts mit sechs Ebenen helfen: `"[\dA-Fa-f]+\+?": *\[(\{.*?\}, *){5}\{`. Bei Layouts mit mehr Ebenen die Wiederholungszahl anpassen – `{20}` für die 21 Ebenen von *AnNoted*.

# Virtuelle Maschinen und Remote Desktop
Sobald mehrere „ineinander“ laufende Betriebssysteme ins Spiel kommen, wird es mit alternativen Tastaturlayouts fast immer haarig.
Da sich die verschiedenen VM-Programme und Remote Desktop Clients unterschiedlich verhalten, gibt es leider keine universelle Lösung, sondern nur eine grundsätzliche Empfehlung und ein paar erprobte Konfigurationen.

Für beste Kompatibilität sollte im Allgemeinen das *innerste* System das Alternativlayout übernehmen, und in allen äußeren Systeme QWERTZ eingestellt sein.
Bei VMs bedeutet das QWERTZ im Wirt und den passenden Neo-Treiber im Gast.
Im Fall von Remote-Desktop-Verbindungen heißt es QWERTZ lokal und einen Neo-Treiber im Remote-System.

Wenn sich herausstellt, dass es ohne AnaNeo besser funktioniert, können die entsprechenden Programme auch auf die *Blacklist* gesetzt werden, sodass sich AnaNeo automatisch deaktiviert. Siehe dazu [Konfiguration](#allgemeine-konfiguration).

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