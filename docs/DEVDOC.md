# Nomenklatur
- **VK**/**VKEY**: Ein **Virtual-Key Code** (`uint`), [hier](https://docs.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes) dokumentiert. Für Buchstaben und Zahlentasten gibt es keine Namen im Microsoft-Header, deshalb wurde in unserer Enum `VK_KEY_A` - `VK_KEY_Z` und `VK_KEY_0` - `VK_KEY_9` ergänzt
- **Scancode**: Code, der die physische Position der Taste auf der Tastatur angibt. [Referenz hier](https://kbdlayout.info/kbdgr/scancodes). Bestimmte Tasten werden zusätzlich durch das **Extended Bit** unterschieden, die Kombination aus Zahl und Extended Bit fassen wir in einem Struct `Scancode` zusammen. In `layouts.json` wird das Extended Bit mit einem `+` markiert.
- **Keysym**: Zahlencode (`uint`) aus `keysymdef.h`, der die Bedeutung einer Taste (Zeichen- oder Steuertaste) beschreibt. Teilweise wird im Code noch inkonsistent mit Keysym auch der *Name* (`str`) des Codes bezeichnet. Wird für Compose benutzt, da die Compose-Definitionen im XCompose-Format diese Tastenbezeichnungen verwenden.
- **Neo-Modifier**: Mod3, Mod4, ...
- **NeoKey**: Ein Eintrag in der Keymap in `layouts.json`. Ordnet einer Taste auf einer bestimmten Ebene eine gewünschte Funktion zu. Das kann entweder ein bestimmtes Zeichen sein (**Char-Mapping**) oder eine Steuertaste (**VK-Mapping**).

# Grundlegendes Prinzip
Kern des Programms ist die Logik in der Funktion `keyboardHook`. Grob zusammengefasst werden nacheinander folgende Schritte abgearbeitet.

## Ungewünschte Events filtern
Wir ignorieren Unicode-Events (`VK_PACKET`), sowie alle Events, bei denen die `injected`-Flag ersetzt ist. Vermutlich kommen diese sowieso von uns und sollen nicht in einer Schleife landen.

Außerdem filtern wir aktiv Fake-Events, die durch AltGr oder den Nummernblock vom Tastatur-Stack eingefügt werden.

## Modifier-Zustände aktualisieren
Durch das Senden von nativen Tastenkombinationen für Sonderzeichen, beliebig mappbare Modifier und VK-Mappings mit Modifiern auf beliebigen Ebenen ist deren Handhabung zunehmend kompliziert geworden. Die aktuelle Implementierung hat das Ziel, von einer komplexen Zustandsmaschine mit vielen einzelnen Flags und Sonderfällen wegzukommen und basiert auf folgendem gedanklichen Modell.

Welche **Modifier** es gibt und wo diese auf der Tastatur verortet sind ist in `"modifiers"` im Layout definiert. Das deckt sowohl die **nativen Modifier** Shift, Strg und Alt (in linker und rechter Variante) als auch die **Neo-Modifier** Mod3, Mod4 (links und rechts) und höhere (ohne links/rechts) ab.

Der **natürliche Modifier-Zustand** beschreibt, welche dieser Modifier gerade durch physische Tasten gedrückt sind. Das wird ein wenig dadurch verkompliziert, dass prinzipiell mehrere physische Tasten den gleichen Modifier drücken können. Wenn mehrere Tasten den gleichen Modifier halten, wollen wir den Modifier erst "loslassen", wenn die letzte physische Taste losgelassen wird.

Dazu wird für jeden Modifier-Typ gespeichert, welche Scancodes gerade diesen Modifier drücken. Bei einem *Modifier-Down-Event*, wird der entsprechende Scancodes in dieser Datenstruktur ergänzt und das korrekte Modifier-Event durchgelassen oder gesendet. Grundsätzlich sollen Programme nur *native Modifier* sehen, *Neo-Modifier* werden gefiltert und deren Zustand nur intern behandelt. Beim *Modifier-Up-Event* wird der Scancode wieder aus der Datenstruktur entfernt. Nur wenn diese Taste die letzte war, die diesen Modifier gehalten hat, wird auch ein Up-Event für Programme erzeugt (inklusive forcierter Modifier, siehe unten).

## Aktuelle Ebene ermitteln

Aus dem **natürlichen Modifier-Zustand** und dem **gerasteten Modifier-Satz** ergibt sich der *effektive* Zustand: Ein Modifier gilt als aktiv, wenn er gehalten **oder** gerastet ist, aber nicht beides – das erlaubt es, eine gerastete Ebene durch Halten der Taste kurzzeitig zu verlassen. Sehen Programme die Neo-Modifier selbst (Erweiterungsmodus mit `filterNeoModifiers: false`), gilt stattdessen ein einfaches Oder, weil der native Treiber die Ebene beim echten Tastenevent ohnehin mitschaltet. Auf dieser Grundlage werden die Ebenen in `"layers"` nacheinander getestet, und die erste passende wird übernommen. Ein Eintrag, der einen gerade gerasteten Modifier gar nicht erwähnt, wird dabei übersprungen – sonst würde Ebene 1 jede gerastete Zusatzebene wegschatten.

Capslock kommt danach und nur unter engen Bedingungen: Die Taste muss in `"capslockableKeys"` stehen, es darf keine Rastung aktiv sein und kein Neo-Modifier gehalten werden. Dann wird die Ebene mit umgedrehtem Shift-Zustand neu bestimmt. Für die ausgelieferten Layouts ist das der Tausch zwischen Ebene 1 und 2. Auf gerasteten Ebenen schweigt Capslock; die Groß/Klein-Umschaltung übernimmt dort ein Shift-Trigger mit `"mode": "toggle"`.

Die Logik steckt vollständig in `source/layerlock.d` und ist dort ohne Win32-Zustand unter Unittests gestellt. Welche Chords etwas rasten, steht in `"locks"` in der `config.json`.

Mit der aktuellen Ebene und dem gedrückten Scancode ergibt sich dann aus dem Mapping der NeoKey.

## Compose

Der Zugang zum Compose-Modul ist die Funktion `compose`, die bei jedem Tastendruck den aktuellen NeoKey übergeben bekommt. Kern des Moduls ist der **Compose-Baum**, dessen Verzweigungen dann während einer Compose-Sequenz geflogt werden. Je nach sich daraus ergebendem Compose-Zustand antwortet die Funktion mit einem Compose-Zustand. So wird der Tastendruck dann in der Hook-Funktion entweder unverändert durchgelassen, geschluckt (weil er Teil einer Compose-Sequenz ist) oder bei Abschluss einer Compose-Sequenz durch das Compose-Ergebnis ersetzt.

Welche Moduldateien den Baum füllen, steht als Positivliste `composeModules` in der Konfiguration; die Listenreihenfolge ist die Ladereihenfolge. Zuerst werden die `.remove`-Dateien eingelesen – die der ausgewählten Module und zusätzlich die, zu denen es gar kein Modul gibt, denn die gehören zu eingebauten Sonderroutinen wie der Unicode-Eingabe. Danach folgen die Module selbst. `addComposeEntry` meldet für jede Sequenz zurück, was mit ihr geschehen ist: neu eingetragen, als exaktes Duplikat überschrieben, oder als Verlängerung beziehungsweise Präfix einer bestehenden Sequenz verworfen. Daraus schreibt `initCompose` am Ende einen Bericht ins Debug-Log – Zähler je Moduldatei plus die Einzelfälle.

## Tastenevents senden

Je nach Mapping-Typ (VK oder Char) und Modus werden unterschiedliche Events erzeugt.

VK-Mappings werden immer als VK-Events umgesetzt. Der Scancode ergibt sich aus einem Lookup im nativen Layout.

Char-Mappings werden im Erweiterungsmodus als Unicode-Events realisiert. Im Standalone-Modus hingegen wird im nativen Layout nach einer Tastenkombination gesucht, die das gewünschte Zeichen erzeugt und dann diese Kombination gesendet. Falls das Zeichen nicht nativ existiert, wird auf ein Unicode-Event zurückgefallen.

VK-Mappings können mit `"mods"` einige oder alle der *nativen Modifier* an oder aus forcieren. Der **forcierte Modifier-Zustand** beschreibt, welche Modifier gerade auf welchen Wert gezwungen werden. Die nicht spezifizierten Modifier werden nicht verändert. Über den gleichen Mechanismus funktionieren auch native Tastenkombinationen für Sonderzeichen bei Char-Mappings.

Der forcierte Zustand wird in einer globalen Variable zwischen Tastendrücken gespeichert. Kommt jetzt ein Down-Event einer Taste, die möglicherweise neue Modifier-Zustände forciert, muss ermittelt werden, mit welcher minimalen Menge an Modifier-Events vom einen in den anderen Zustand überführt werden kann.

Zuerst wird der natürliche Zustand mit dem bisherigen (alten) forcierten Zustand verrechnet, um den bisherigen **resultierenden Modifier-Zustand** zu erhalten. Das ist der Zustand aus Sicht von anderen Programmen.

```
                        LShift         LCtrl          LAlt
  natürlicher           1              0              0
+ alter forcierter                                    1         (LShift und LCtrl waren egal)
= alter resultierender  1              0              1
```

Äquivalent erhält man mit dem (neuen) forcierten Zustand der gerade gedrückten Taste den neuen resultierenden Zustand.

```
                        LShift         LCtrl          LAlt
  natürlicher           1              0              0
+ neuer forcierter      1              1              0
= neuer resultierender  1              1              0
```

Vergleicht man die beiden resultierenden Zustände (alt und neu) wird klar, welche Modifier-Events gesendet werden müssen um von alt nach neu zu kommen.

```
                        LShift         LCtrl          LAlt
alter resultierender    1              0              1
neuer resultierender    1              1              0
-> Nötige Events                       Down           Up
```

Bei einem Up-Event wollen wir prinzipiell die forcierten Modifier wieder in den natürlichen Zustand zurücksetzen. Das gilt aber nur, wenn das Up-Event zu der Taste gehört, die der Urheber des aktuellen forcierten Zustands ist, ansonsten wird der Zustand beibehalten.


# Erkenntnisse und Workarounds
## Numpad
### Numlock-Zustand
Prinzipiell funktioniert Numlock ähnlich wie Capslock; mit `VK_NUMLOCK` lässt sich der Status abfragen und umschalten, die Tastatur-LED zeigt den aktuellen Status an. *Eigentlich* ist uns der Numlock-Zustand egal, da es Numlock als Konzept in Neo nicht gibt. Auch das Numpad ist ganz normal dem Ebenenprinzip unterworfen.

Praktisch verhalten sich Anwendungen aber unterschiedlich. Die meisten Programme erzeugen bei einem `VK_NUMPADx`-Event die entsprechende Zahl, egal welchen Zustand Numlock gerade hat. [WinUI-Anwendungen brauchen aber Numlock eingeschaltet und bewegen sonst nur den Textcursor](https://github.com/microsoft/microsoft-ui-xaml/issues/5008).

**Workaround**: Standardmäßig schalten wir Numlock automatisch aktiv ein.

Das stört aber bei manchen Laptops, die von Haus aus einen Nummernblock *im Hauptfeld* haben, der über Numlock aktiviert wird. Konkret ist das bei einem Gerät von Dell aufgetreten. Für diesen Fall lässt sich mit `"autoNumlock": false` das automatische Aktivieren von Numlock abstellen (mit den zu erwartenden Einschränkungen).


### Numlock-Taste
Seltsame Dinge passieren, wenn man die Numlock-Taste remappen will, indem man ihre Events wegfiltert. Die LED ändert sich dann nicht, der interne Zustand aber sehr wohl.

**Workaround**: [Inspiriert von AHK](https://github.com/Lexikos/AutoHotkey_L/blob/master/source/hook.cpp#L2027) drücken wir intern ein paar Mal Numlock, um den seltsamen Zustand wieder aufzulösen.

### Shift und das Numpad
Wenn Numlock aktiviert ist, gibt es Spezialverhalten, wenn man Shift *zusammen* mit einer „**dual state**“-Numpad-Taste drückt. Das betrifft konkret die Zahlentasten 0-9 sowie die Komma-Taste. In diesem Fall fügt der Treiber-Stack ein **Fake-Shift**-Event ein, um die aktuell gehaltene Shift-Taste loszulassen und danach wieder zu drücken. Diese Fake-Events haben die `injected`-Flag nicht gesetzt, und sind *nur manchmal* mit dem Fake-Scancode `0x22A` (LShift) oder `0x236` (RShift) markiert.

**Workaround**: Events mit den Fake-Scancodes filtern wir grundsätzlich. Für die betroffenen „dual state“-Numpad-Tasten setzen wir bei Tastenevents außerdem intern ein Flag, um als nächstes Event ein Shift-Event zu erwarten und entsprechend wegzufiltern. Kommt das nicht (weil Numlock deaktiviert oder das Event schon anhand des Fake-Scancodes weggefiltert wurde), wird die Flag wieder zurückgesetzt.

## AltGr
Die Taste „AltGr“ gibt es intern nicht wirlich, dort spricht man von „RAlt“. Bei europäischen Layouts ist der Treiber aber so konfiguriert, dass ein Druck auf die Taste zusätzlich zu „RAlt“ auch noch ein Event „LStrg“ sendet, falls LStrg nicht bereits gedrückt ist. Dieses **Fake-LStrg** ist mit dem *Fake-Scancode* `0x21D` markiert, aber nicht mit der `injected`-Flag.

Injiziert man selber ein RAlt, ergänzt der Windows-Stack automatisch ein Fake-LStrg. In dem Fall ist *unter Windows 10 das Fake-LStrg mit der `injected`-Flag versehen, unter Windows 7 jedoch nicht*.

Die meisten Anwendungen erzeugen die gewünschten Zeichen auch mit LStrg+LAlt. Manche akzeptieren aber nur LStrg+RAlt für Sonderzeichen (z. B. *PuTTY*).

**Workaround**: Für Mod4 filtern wir grundsätzlich RAlt, aber auch alle Fake-LStrg-Events, identifiziert am Fake-Scancode.

Um Sonderzeichen mit nativen Tastenkombinationen zu erzeugen, senden wir für AltGr-Zeichen sowohl RAlt- als auch LStrg-Events. Wir wollen verhindern, dass der Tastaturstack selbstständig Fake-LStrg-Events injiziert, deshalb kommt es hier auf die Reihenfolge an: LStrg↓ RAlt↓ Taste↓ Taste↑ RAlt↑ LStrg↑.

## Neo-Modifier
GTK- und Qt-Programme mögen keine Modifier außer Shift, Strg, Alt und verhalten sich komisch. Die Telegram-App eignet sich gut zum Testen. Wenn man dort reines *kbdneo* verwendet, [wird nach Mod3 das nächste Tastenevent komplett geschluckt](https://git.neo-layout.org/neo/neo-layout/issues/510).

**Workaround**: Im Erweiterungsmodus filtern wir Neo-Modifier-Events komplett weg und senden dann stattdessen auf den Ebenen 3 und höher direkt die gewünschten Tasten. Zeichen auf diesen höheren Ebenen sind dann immer Unicode-Pakete.

Falls man tatsächlich Neo-Modifier an Programme durchlassen will, lässt sich dieses Verhalten mit `"filterNeoModifiers"` in der Config einstellen.

## Capslock
### Capslock-Zustand
Mit `VK_CAPITAL` lässt sich der aktuelle Capslock-Zustand auslesen (`GetKeyState`) und mit Tastenevents auch setzen. Der aktuelle Zustand wird immer mit der Capslock-LED angezeigt.

Damit die Capslock-LED korrekt ist, schalten wir bei Doppel-Shift immer den tatsächlichen Capslock-Zustand um. Die Buchstabentasten sind als VK-Mapping umgesetzt und werden dann nativ als Großbuchstaben umgesetzt.

### Capslockable

Nicht alle Tasten sollen von Capslock beeinflusst werden. Auf Neo-Seite sind es nur die Buchstabentasten. Die Tasten, die mit Capslock in die zweite Ebene schalten sollen, bezeichnen wir als **capslockable** und definieren wir in `layouts.json`.

Umgekehrt werden im nativen Layout auch nicht alle Tasten von Capslock beeinflusst. Welche das sind, legt der native Treiber fest.

**Workaround**: In `sendUTF16OrKeyCombo` entlocken wir mit `ToUnicodeEx` dem nativen Treiber bei aktivem Capslock, ob die nächste Taste davon beeinflusst wird. Abhängig davon muss Shift zusätzlich gedrückt oder losgelassen werden.

## Tottasten
### Tottasten im nativen Treiber
Native Tastaturtreiber unterstützen prinzipiell beliebig lange Tottastensequenzen. Typischerweise sehen Programme diese Tasten als `WM_KEYDOWN` und `WM_KEYUP`, die Fensterprozedur macht daraus `WM_DEADCHAR`. Die meisten Programme verarbeiten diese Events aber nicht, sondern warten darauf, dass zum Schluss der Sequenz ein `WM_CHAR` mit dem fertig kombinierten Zeichen kommt.

In *kbdneo* ist nur ein kleiner Bruchteil der Compose-Sequenzen definiert. Außerdem [kommt die Compose-Taste `M3+Tab` trotzdem bei Programmen an](https://git.neo-layout.org/neo/neo-layout/issues/397).

**Workaround**: Sobald AnaNeo den Beginn einer Compose-Sequenz erkennt, werden entsprechende Tastenevents weggefiltert und intern dem Compose-Baum gefolgt, bis wir am Ende einer Sequenz ankommen. Dann wird nur das fertige / die fertigen Zeichen als (Sequenz von) Unicode-Paketen gesendet.

### Tottasten erkennen
Im Standalone-Modus versuchen wir, die gewünschten Zeichen mit `VkKeyScanEx` im nativen Layout zu finden und als native Tastenkombination umzusetzen. Problematisch sind dabei aber zum Beispiel der Backtick „`“ oder der Zirkumflex „^“ auf Ebene 3. Diese Tasten sollen sofort ein Zeichen erzeugen, liegen aber in nativen Layouts oft als Tottasten vor. Außnahme ist das Layout DE-CH, dort ist der Zirkumflex keine Tottaste.

**Workaround**: Mit `ToUnicodeEx` lässt sich überprüfen, ob die gefundene Taste tatsächlich sofort ein Zeichen erzeugt. Wenn nicht, wird das Zeichen mit einem Unicode-Paket realisiert. Der Aufruf dieser Funktion verändert den inneren Zustand des Windows-Treiberstacks, falls wir eine Tottaste finden müssen wir die Funktion noch einmal aufrufen, um den Zustand zurückzusetzen.

## Native Layouts
### Layoutwechsel erkennen
Wir wollen Layoutwechsel in Windows erkennen, um automatisch zwischen Erweiterungsmodus und Standalone-Modus umzuschalten, oder AnaNeo zu (de)aktivieren. Globale Events gibt es dafür aber leider nicht direkt.

**Workaround**: Wir registrieren einen Hook, um auf Fensterwechsel zu lauschen. Wurde das Fenster gewechselt, überprüfen wir *beim nächsten Tastendruck* das aktuelle Layout mit `GetKeyboardLayout`. Wechselt man das Layout mit Win+Leer, Strg+Shift oder Alt+Shift, passiert das sofort, da das Popup mit der Layoutauswahl ein Fensterwechsel ist. Nutzt man stattdessen Shift+Strg oder Shift+Alt wird der Hook nicht ausgelöst, und man muss manuell ein Fenster wechseln, damit der Hook anspringt.

### Die Konsole
In bestimmten Terminals, zum Beispiel der klassischen Konsole, liefert `GetKeyboardLayout` für den Konsolenthread `null` zurück. Auch Aufrufe wie `VkKeyScan` liefern in diesen Fenstern falsche Ergebnisse, da intern irgendein seltsames Legacy-Layout angenommen wird.

**Workaround**: Wir cachen das zuletzt gesehene „sinnvolle“ Layout und ignorieren Layoutwechsel, wenn das neue Layout `null` ist. Für Aufrufe wie `VkKeyScan` benutzen wir die Variante `VkKeyScanEx` und übergeben explizit das gecachete, sinnvolle Layout.

## Glyphausgabe (Bildschirmtastatur und Belegungsblatt)
Seit Paket 5b zeichnet die Bildschirmtastatur Beschriftungen über `cairo_show_glyphs` statt über `cairo_show_text`, weil Zeichen jenseits der Basic Multilingual Plane (BMP) sonst zerbrechen. Auf dem Weg dorthin lagen drei Fallstricke, jeder davon stillschweigend falsch – keiner meldet sich mit einem Fehler.

### UTF-16-Codeeinheiten statt Codepunkte
`GetGlyphIndices` und Cairos Win32-Textpfad (den `cairo_show_text` intern benutzt) arbeiten beide auf UTF-16-**Codeeinheiten**, nicht auf Codepunkten. Ein Zeichen jenseits der BMP besteht aus einem Surrogatpaar, also zwei Codeeinheiten; nachgeschlagen wird nur die erste, die hohe Hälfte – für sich genommen kein gültiges Zeichen. Das Ergebnis ist der Tofu-Kasten, und zwar ununterscheidbar von einem Zeichen, das die Schrift tatsächlich nicht führt.

**Workaround**: Glyph-Indizes selbst beschaffen, auf Codepunktebene, und mit `cairo_show_glyphs` zeichnen (`source/fontchain.d`, `source/osk.d`).

### GDI scheidet aus
Naheliegender Ausweg wäre GDI-Direktausgabe (`ExtTextOutW`) gewesen – GDI kennt Codepunkte, das Problem oben stellte sich dort nicht. Es scheitert an einer anderen Eigenschaft des Fensters: Die Bildschirmtastatur ist ein Layered Window, gezeichnet über `UpdateLayeredWindow` mit `ULW_ALPHA`. GDI schreibt den Alphakanal nicht mit; Text über GDI wäre unsichtbar oder zerfressen. Cairo rastert selbst und schreibt Alpha korrekt – deshalb bleibt Cairo im Spiel, trotz des Codeeinheiten-Problems oben.

### Uniscribe: `S_OK` ist kein Erfolg
Der naheliegende Weg zu Glyph-Indizes auf Codepunktebene ist Uniscribe (`usp10.dll`): `ScriptGetCMap` nimmt einen UTF-16-String **mit Länge** entgegen und kann deshalb Surrogatpaare korrekt behandeln. Er wurde zuerst gebaut – und dann gegen zehn installierte Schriften und zehn Codepunkte jenseits der BMP gemessen, mit einem Wegwerf-Konsolenprogramm. Ergebnis: **in keiner** der zehn Schriften liefert `ScriptGetCMap` für ein Zeichen jenseits der BMP einen echten Glyphen – entweder `S_FALSE`, oder `S_OK` mit dem Leerglyphen. Auch die eigens mitgelieferte Schrift antwortete für ihr eigenes Zielzeichen (Schach, U+1FA00) so. `S_OK` beweist hier also gar nichts; ein Aufrufer, der nur den Rückgabewert prüft, hält einen Fehlschlag für einen Erfolg.

Der Glyph liegt dabei durchaus in der Schrift – direkt nachgelesen führt die `cmap`-Tabelle von Segoe UI Symbol für U+1D504 zum Beispiel den Glyphen 7721. Der Uniscribe-Aufruf findet ihn nur nicht. Auch der zweite Uniscribe-Weg (`ScriptItemize` + `ScriptShape`) trägt nur mit abgeschaltetem Shaping (dokumentierter Rücklauf auf `eScript = SCRIPT_UNDEFINED`) und scheitert für die mitgelieferte Schrift sogar an einem BMP-Zeichen (`USP_E_SCRIPT_NOT_IN_FONT`).

**Entscheidung**: Uniscribe fliegt komplett raus. `source/cmap.d` liest die `cmap`-Tabelle einer Schrift (Format 12, sonst Format 4) direkt aus den Bytes, die `GetFontData` liefert – reine Byte-Arithmetik, kein Win32-Aufruf mit unklarer Auskunft. Gemessen: in allen 100 geprüften Kombinationen derselbe Glyph wie über Uniscribe, überall dort, wo Uniscribe überhaupt einen lieferte. Nebengewinn: Ein cmap-Leser lässt sich gegen eine Schriftdatei im Repo (`fonts/NotoSansSymbols2-Regular.ttf`) testen, auch dort, wo keine Windows-Schriften installiert sind (`tools/verify-linux.sh` unter Wine) – Uniscribe wäre dort gar nicht prüfbar gewesen.

### Hell/Dunkel ohne `prefers-color-scheme`
Ein Win32-Fenster kennt kein Äquivalent zu `prefers-color-scheme` – anders als das Belegungsblatt (eine HTML-Seite) kann die Bildschirmtastatur nicht einfach eine Media Query befragen. Das Farbschema `Sachlich` liest deshalb den Registry-Wert `AppsUseLightTheme` unter `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` einmal beim Start und danach erneut bei jedem `WM_SETTINGCHANGE` (darüber meldet Windows den Wechsel zwischen hellem und dunklem Apps-Modus) – das ist der einzige praktikable Weg, den laufenden Wechsel mitzubekommen, ohne bei jedem Zeichnen die Registry zu befragen.

## Grundebenen und Zeichentasten

Auf den Ebenen 1 und 2 liegen Buchstaben, Ziffern und die meisten Satzzeichen absichtlich als **VK-Mapping** vor, nicht als Char-Mapping. Der Grund ist nicht Bequemlichkeit, sondern Notwendigkeit: Ein VK-Mapping lässt Windows einen echten Tastendruck sehen (`VK_KEY_E` statt eines Unicode-Pakets für „e“). Nur so bleiben Tastenkürzel funktionsfähig, die auf dem *Drücken einer Taste* beruhen und nicht auf dem Zeichen, das dabei entsteht – Strg+C, Alt+Tab, praktisch jedes Spiel. Ein Char-Mapping sendet stattdessen ein Unicode-Paket; für ein Programm, das auf `VK_KEY_C` mit gehaltenem Strg lauscht, ist eine Taste, die nur „c“ tippt, unsichtbar. **Wer eine Taste der Grundebenen auf `"char"` umstellt, macht sie für genau diese Kürzel blind.** Das ist kein Detail der Darstellung, sondern eine Eigenschaft der Layoutdaten, und Paket 5c fasst sie deshalb an keiner Stelle an.

Für die *Darstellung* (Bildschirmtastatur, Belegungsblatt) ist die Unterscheidung VK- gegen Char-Mapping trotzdem die falsche Frage. Entscheidend ist, was beim Tippen tatsächlich herauskommt, nicht wie das Layout es intern kodiert. `keyboardview.describeKey` beantwortet das seit Paket 5c über den **Keysym**: Führt `keysymdef.h` für den Keysym eines VK-Mappings einen Unicode-Codepunkt (`keysyms.codepointsByKeysym`), erzeugt die Taste ein Zeichen und wird als solches gezeichnet, unabhängig vom Mapping-Typ. Eine VK-Taste mit erzwungenen Modifiern (`"mods"`) bleibt davon ausgenommen – sie sendet ein Tastenkürzel wie Strg+Z, egal was ihr Keysym sagt.

Der Nummernblock ist dabei ein eigener Fall: `keysymdef.h` ordnet den `KP_`-Keysyms keinen Codepunkt zu, obwohl die meisten dieser Tasten sehr wohl Zeichen erzeugen. `keyboardview.keypadChar` deckt das über eine kleine feste Tabelle ab – und liefert bewusst das **erzeugte** Zeichen, nicht die Beschriftung. Die Multiplikationstaste des Nummernblocks trägt „×“ (U+00D7), tippt aber „*“ (U+002A); die Divisionstaste trägt „÷“ (U+00F7), tippt aber „/“ (U+002F). Wer den Codepunkt aus dem Label ableitet statt aus der Tabelle, schreibt eine Unwahrheit aufs Blatt – optisch unauffällig, weil beide Zeichen demselben Zweck dienen, aber technisch falsch.

## Compose-Grammatik

Seit der Grammatikrunde folgt der eigene Compose-Bestand einer Regel: **Eine Sequenz beginnt mit einem Modifikator, dann folgt die Basis.** Der Modifikator sagt, *was* mit dem Zeichen geschieht, die Basis, *womit*. Daraus folgen zwei Bedingungen, die jede eigene Tabelle einhalten muss: (1) Ein Knoten auf dem Weg zur Basis trägt selbst **kein** Ergebnis – sonst wäre er Sackgasse und die Sequenz ließe sich nicht verlängern; (2) die Basis ist **einzeichig**, damit sich der Zweig gleichförmig lesen lässt.

Sechs Modifikatoren gibt es, jeder auf Ebene 21 von `AnNoted`, auf dem Anfangsbuchstaben seiner Kategorie:

| Zeichen | Codepunkt | Taste | Kategorie |
|---|---|---|---|
| `𝔵` | U+1D535 | S | Schriftvariante |
| `ⓧ` | U+24E7 | E | Einkreisung |
| `↻` | U+21BB | D | Drehung |
| `ₓ` | U+2093 | T | Tiefstellung |
| `˞` | U+02DE | R | Retroflex/Haken |
| `ˣ` | U+02E3 | H | Hochstellung |

Ebene 21 hängt an `Mod3+Mod4` und trägt in `layouts.json` die Marke `"ignoreLocks": true`. Ohne sie wäre sie in jedem gerasteten Block unerreichbar: `layerlock.determineLayer` verwirft eine Ebene, die einen gerade gerasteten Neo-Modifier gar nicht erwähnt (»Locked-not-don't-care«), und Ebene 21 erwähnt die Blockmodifier bewusst nicht. Sie schattet trotzdem nichts ab, weil sie als **letzter** Eintrag steht und `Mod3` und `Mod4` zugleich verlangt – eine Kombination, die keine frühere Ebene trifft. Aus demselben Grund gibt es den Auslöser `{"chord": "Mod3+Tab", "action": "compose"}`: Ein Auslöser läuft vor der Ebenenbestimmung, während `Multi_key` auf Ebene 3 der Tab-Taste bei jeder Rastung verloren ist.

**Die Schrifttabelle wird gerechnet.** `compose/ananeo-schrift.module` (1 016 Einträge unter `𝔵`) entsteht aus `source/schriftvarianten.d` über `ananeo-tool compose gen-schrift`; ein Wächtertest hält Datei und Rechnung zusammen. Die Notation jeder Zeile ist `<U1D535> <Familienbuchstabe> [<slash>] <Basis> : "Zeichen" UXXXX` – der Familienbuchstabe groß geschrieben heißt fett, ein `/` vor der Basis heißt kursiv (`a` Antiqua, `s` Schreibschrift, `r` Fraktur, `d` doppelt gestrichen, `l` serifenlos, `m` dicktengleich). Zeichen stehen als `<UXXXX>` statt als benannte Keysyms, damit die Datei nicht an `keysymdef.h` hängt und Latein, Griechisch und die Variantenformen dieselbe Form haben.

Zwei Eigenheiten des Unicode-Blocks stecken in der Rechnung und lassen sich nicht ableiten: **24 Plätze fehlen im Block**, weil das Zeichen in »Letterlike Symbols« liegt (`ℬ`, `ℭ`, `ℂ`, …, und U+210E heißt PLANCK CONSTANT) – sie stehen als Tabelle in `ausnahme()`. Und die **58 griechischen Basisplätze** haben eine feste Reihenfolge mit Fremdkörpern: das Theta-Symbol `ϴ` steht zwischen den Großbuchstaben, Nabla `∇` und das partielle Differential `∂` sitzen mitten in der Reihe. Wer die Reihenfolge rät, bekommt lauter zugewiesene, aber falsche Codepunkte – deshalb der Wachhund gegen UCD 17.0.0 im selben Modul.

## Rechteebenen
### Erhöhte Fenster
Windows lässt einen Low-Level-Keyboard-Hook aus einem nicht erhöhten Prozess nicht auf Fenster wirken, die zu einem erhöhten Prozess gehören (User Interface Privilege Isolation). Läuft AnaNeo ohne Administratorrechte, bleibt es in einem als Administrator gestarteten Terminal, Editor oder Installer also wirkungslos – ohne Fehlermeldung, ohne Eintrag im Log, und ohne dass sich das Tray-Icon ändert.

Im Erweiterungsmodus fällt das leicht zu spät auf: Dort erledigt der native Treiber (`kbdnoted.dll` und Verwandte) die Ebenenarbeit auf Treiberebene, und die kümmert UIPI nicht. In einem erhöhten Fenster erscheinen die gewohnten Zeichen also weiterhin, während alles, was AnaNeo selbst beisteuert – Compose, Capslock, Navigation auf Ebene 4, das Senden von Zeichen jenseits der BMP –, still ausfällt. Im Standalone-Modus gibt es keinen Treiber, der einspringt; dort passiert schlagartig gar nichts mehr.

**Workaround**: Keiner im Code. Wer erhöhte Fenster mit AnaNeo bedienen will, startet AnaNeo selbst erhöht. Wichtiger ist die Konsequenz fürs Prüfen: **manuelle Tests gehören in ein nicht erhöhtes Fenster.** Ein Ergebnis aus einem Administrator-Terminal ist wertlos, und zwar in beide Richtungen – ein unverändert durchgereichter Tastendruck sieht dort genauso aus wie ein korrekt verarbeiteter.
