module keyboardview;

import std.conv : to;

import mapping;
import layerlock : capslockSwapApplies, genericModifier;
import keysyms : codepointsByKeysym, KEYSYM_CODEPOINT_OFFSET;

// Reine Beschreibung der Tastatur - keine Win32-Zustaende, kein Cairo. Nach
// dem Muster von layerlock.d: Was gezeichnet wird, entsteht hier; WIE es
// gezeichnet wird, entscheiden osk.d und sheet.d.
//
// Der Grund fuer dieses Modul ist Doppelpflege: Bis Paket 5a rechnete osk.d
// die Capslock-Umschaltung selbst aus, mit hartkodierten Ebenen 1 und 2, und
// die Tastaturgeometrie existierte nur in dessen Zeichencode.

/// Was eine Taste auf einer bestimmten Ebene ist.
enum KeyKind {
    /// traegt ein Zeichen
    CHAR,
    /// traegt eine virtuelle Taste (Entf, Pfeile, Funktionstasten)
    VKEY,
    /// ist selbst ein Modifier und traegt keine Ebenenbelegung
    MODIFIER,
    /// ist auf dieser Ebene unbelegt
    EMPTY
}

/// Eine Taste, wie sie auf einer Ebene erscheint.
struct KeyView {
    Scancode scancode;
    KeyKind kind;
    /// Beschriftung wie in layouts.json ("label", sonst "char")
    string label;
    /// Codepunkte dessen, was diese Taste ERZEUGT - unabhaengig davon, ob das
    /// Layout sie als Zeichen oder als VK-Code abbildet. Leer bei Tasten, die
    /// kein Zeichen erzeugen (Tab, Eingabe, Pfeile, Tastenkuerzel) und bei
    /// Modifier- und unbelegten Tasten. Bewusst dchar und nicht wchar: Ein
    /// Zeichen jenseits der BMP ist EIN Codepunkt, auch wenn es aus zwei
    /// UTF-16-Codeeinheiten besteht.
    dchar[] codepoints;
    /// Steht der Scancode ueberhaupt im Layout (map oder modifiers)? EMPTY
    /// allein unterscheidet nicht zwischen "gemappt, aber auf dieser Ebene
    /// unbelegt" und "gar nicht Teil des Layouts" - die OSK zeichnet Ersteres
    /// als leere Taste, Letzteres gar nicht.
    bool inLayout;
    /// Nur bei KeyKind.VKEY gesetzt, sonst VK_VOID. Das Belegungsblatt zeigt
    /// bei VK-Tasten den Tastennamen statt eines Codepunkts; ohne dieses Feld
    /// muesste es ein zweites Mal in layout.map greifen.
    VKEY vkCode = VKEY.VK_VOID;
}

/// Zeichen, das eine Nummernblocktaste erzeugt. keysymdef.h ordnet den
/// KP_-Keysyms als einzigen Zeichentasten keinen Codepunkt zu, deshalb diese
/// kleine feste Tabelle.
///
/// Sie liefert bewusst das ERZEUGTE Zeichen und nicht die Beschriftung: Die
/// Multiplikationstaste traegt "×" (U+00D7), tippt aber "*" (U+002A), die
/// Divisionstaste traegt "÷" (U+00F7) und tippt "/" (U+002F). Wer den
/// Codepunkt aus dem Label ableitet, schreibt eine Unwahrheit aufs Blatt.
///
/// Nicht enthalten sind KP_Enter und KP_Tab (Funktionstasten) und die
/// Navigationsbelegung des Nummernblocks (KP_Up, KP_Home, KP_Delete ...), die
/// auf anderen Ebenen liegt.
dchar keypadChar(uint keysym) pure nothrow @nogc {
    switch (keysym) {
        case 0xFFB0: .. case 0xFFB9: return cast(dchar)('0' + (keysym - 0xFFB0));  // KP_0 .. KP_9
        case 0xFFAA: return '*';   // KP_Multiply
        case 0xFFAB: return '+';   // KP_Add
        case 0xFFAC: return ',';   // KP_Separator, auf deutschen Belegungen das Komma
        case 0xFFAD: return '-';   // KP_Subtract
        case 0xFFAE: return '.';   // KP_Decimal
        case 0xFFAF: return '/';   // KP_Divide
        case 0xFFBD: return '=';   // KP_Equal
        case 0xFF80: return ' ';   // KP_Space
        default:     return dchar.init;
    }
}

/// Beschreibt eine einzelne Taste auf einer Ebene.
///
/// Geteilt mit dem Verhaltenspfad ist die BEDINGUNG, unter der Capslock
/// umschaltet: layerlock.capslockSwapApplies, dieselbe Funktion wie in
/// ananeo.handleKeyEvent. Die WIRKUNG der Umschaltung bleibt zweimal
/// implementiert (siehe Kommentar beim Ebenentausch unten) - describeKey
/// bekommt nur eine Ebenennummer und kann strukturell nicht wie der
/// Verhaltenspfad ueber determineLayer gehen.
KeyView describeKey(const NeoLayout* layout, Scancode scan, uint layer,
                    bool capslockOn,
                    scope bool delegate(Modifier) nothrow isHeld,
                    bool anyLockActive) nothrow {
    KeyView view;
    view.scancode = scan;

    if (layout is null) {
        view.kind = KeyKind.EMPTY;
        return view;
    }

    // Modifier-Tasten tragen keine Ebenenbelegung
    if (scan in layout.modifiers) {
        view.kind = KeyKind.MODIFIER;
        view.inLayout = true;
        view.label = modifierLabel(layout.modifiers[scan]);
        return view;
    }

    if (scan !in layout.map) {
        view.kind = KeyKind.EMPTY;
        return view;
    }
    view.inLayout = true;

    const entry = layout.map[scan];

    uint effectiveLayer = layer;
    if (capslockSwapApplies(capslockOn, entry.capslockable, anyLockActive, isHeld)) {
        // Fest verdrahteter 1<->2-Tausch statt eines erneuten determineLayer-
        // Aufrufs: das setzt voraus, dass die ersten beiden Ebenen das
        // Shift-Paar sind. Stimmt fuer Neo, NeoQwertz und Noted, ist aber eine
        // Annahme dieser Funktion und nicht Teil von capslockSwapApplies. Der
        // Verhaltenspfad (ananeo.d: handleKeyEvent) geht stattdessen ueber
        // determineLayer(..., capslockShift: true) und braucht diese Annahme
        // nicht - wer hier etwas an der Ebenenreihenfolge aendert, bricht nur
        // die Anzeige, nicht das Verhalten.
        if (layer == 1) effectiveLayer = 2;
        else if (layer == 2) effectiveLayer = 1;
    }

    if (effectiveLayer == 0 || effectiveLayer > entry.layers.length) {
        view.kind = KeyKind.EMPTY;
        return view;
    }

    const key = entry.layers[effectiveLayer - 1];
    view.label = key.label;

    // Unbelegt: parseNeoKey setzt vkCode auf VK_VOID vor, ein leerer Eintrag
    // {} in layouts.json ist damit identisch mit VOID_KEY.
    if (key.keytype == NeoKeyType.VKEY && key.vkCode == VKEY.VK_VOID) {
        view.kind = KeyKind.EMPTY;
        view.label = "";
        return view;
    }

    if (key.keytype == NeoKeyType.CHAR) {
        view.kind = KeyKind.CHAR;
        try {
            view.codepoints = key.chars.to!(dchar[]);
        } catch (Exception e) {
            // Kaputte Surrogatfolge in layouts.json - die Taste bleibt
            // beschriftet, traegt aber keinen Codepunkt.
            //
            // Ungetestet: std.json weist eine einzelne hohe Ersatzzeichenhaelfte
            // schon beim Parsen zurueck ("Expected escaped low surrogate after
            // escaped high surrogate"), eine unpaarige Surrogathaelfte laesst
            // sich also nicht unversehrt durch parseJSON und to!wstring
            // schleusen, um diesen Zweig ueber ein Fixture zu erreichen.
            view.codepoints = [];
        }
        return view;
    }

    view.kind = KeyKind.VKEY;
    view.vkCode = key.vkCode;

    // Erzeugt diese VK-Taste ein Zeichen? Die Grundebenen bilden Buchstaben
    // absichtlich auf VK-Codes ab, damit Windows einen echten Tastendruck
    // sieht - sonst braechen Strg+C, Alt+Tab und Spiele. Fuer die Darstellung
    // zaehlt aber, was dabei herauskommt: Ohne diese Zuordnung stuenden 47 von
    // 66 Tasten der Grundebene als Funktionstasten da, darunter das ganze
    // Alphabet.
    //
    // Eine Taste mit erzwungenen Modifiern sendet ein Tastenkuerzel (Strg+Z)
    // und ist damit keine Zeichentaste, egal was ihr Keysym sagt.
    if (key.modifiers.length == 0) {
        if (key.keysym >= KEYSYM_CODEPOINT_OFFSET) {
            // Offset-Form (UXXXX): parseKeysym liefert Codepunkt + Offset.
            // Solche Keysyms stehen nie in codepointsByKeysym - ohne diesen
            // Zweig bliebe eine VK-Taste mit U-Form-Keysym faelschlich
            // Funktionstaste.
            view.codepoints = [cast(dchar)(key.keysym - KEYSYM_CODEPOINT_OFFSET)];
        } else if (auto codepunkt = key.keysym in codepointsByKeysym) {
            view.codepoints = [cast(dchar) *codepunkt];
        } else {
            auto ziffer = keypadChar(key.keysym);
            if (ziffer != dchar.init) view.codepoints = [ziffer];
        }
    }

    return view;
}

/// Beschriftungsersatz fuer Tasten, die weder in "map" noch in "modifiers"
/// stehen (Rueck- und Eingabetaste als Sinnbild, auch wenn kein Layout sie
/// fuehrt). Privat: keyLabel entscheidet, ob und wann er ueberhaupt greift.
private string fallbackLabel(Scancode scan) nothrow {
    if (scan == Scancode(0x0E, false)) return "⌫";
    if (scan == Scancode(0x1C, true) || scan == Scancode(0x1C, false)) return "↩";
    return "";
}

/// Beschriftung und Sichtbarkeit einer Taste in einer Darstellung.
struct KeyLabel {
    /// Wird die Taste ueberhaupt gezeichnet?
    bool draw;
    /// Beschriftung, wie sie dasteht - osk.d legt darauf noch seine
    /// Darstellungsuebersetzungen (Strg/Ctrl, M3/Sym), sheet.d nicht.
    string text;
}

/// Was von dieser Taste zu sehen ist. Beide Darstellungen (osk.d, sheet.d)
/// fragen hier, damit Blatt und Bildschirmtastatur nicht getrennt voneinander
/// entscheiden, was eine Taste ist - vor Paket 5b stand die Regel zweimal da
/// (einmal in osk.d, einmal nachgebaut in sheet.d) und beantwortete dieselbe
/// Frage schon unterschiedlich: osk.d liess eine unbeschriftete Modifier-Taste
/// aus, sheet.d zeichnete stattdessen einen grau gefuellten Kasten.
///
/// Die Regeln sind wortgetreu aus dem osk.d-Stand vor diesem Umzug uebernommen,
/// nicht neu erfunden.
KeyLabel keyLabel(const NeoLayout* layout, KeyView view) nothrow {
    if (view.inLayout) {
        // Eine Modifier-Taste ohne Beschriftung wurde vor Paket 5a gar nicht
        // gezeichnet. Eine gemappte, aber auf dieser Ebene unbelegte Taste
        // (KeyKind.EMPTY) dagegen schon - deshalb haengt die Ausnahme an
        // KeyKind.MODIFIER und nicht an der Leere der Beschriftung.
        if (view.kind == KeyKind.MODIFIER && view.label.length == 0) {
            return KeyLabel(false, "");
        }
        return KeyLabel(true, view.label);
    }

    // Nicht im Layout: Beschriftungsersatz - aber nur, wenn ueberhaupt ein
    // Layout geladen ist. Ohne Layout bleibt die Tastatur leer, so wie vor
    // Paket 5a (getKeyLabel lieferte damals fuer jeden Scancode "UNMAPPED",
    // solange kein Layout geladen war).
    if (layout is null) return KeyLabel(false, "");

    string ersatz = fallbackLabel(view.scancode);
    return KeyLabel(ersatz.length > 0, ersatz);
}

/// Beschriftung einer Modifier-Taste. Bewusst ohne die Konfigurationsoption
/// aus osk.d (M3/Sym) und ohne Lokalisierung (Strg/Ctrl aus
/// localization.controlKeyName): beides gehoert zur Darstellung, nicht zur
/// Beschreibung, und wird in osk.d angewandt. Hier steht die deutsche
/// Standardform "Strg".
string modifierLabel(Modifier mod) nothrow {
    // genericModifier statt (mod & 0xFFFE): Der Ausdruck ergaebe einen int und
    // liesse sich nicht gegen die Enumwerte schalten.
    switch (genericModifier(mod)) {
        case Modifier.LSHIFT: return "⇧";
        case Modifier.LCTRL:  return "Strg";
        case Modifier.LALT:   return "Alt";
        case Modifier.MOD3:   return "M3";
        case Modifier.MOD4:   return "M4";
        case Modifier.MOD5:   return "M5";
        case Modifier.MOD6:   return "M6";
        case Modifier.MOD7:   return "M7";
        case Modifier.MOD8:   return "M8";
        case Modifier.MOD9:   return "M9";
        default:              return "";
    }
}

/// Form einer Taste. Fast alle sind Rechtecke; die ISO-Return-Taste ist eine
/// L-Form ueber zwei Zeilen und braucht deshalb eine eigene Zeichenroutine.
enum KeyShape {
    RECT,
    ISO_RETURN
}

/// Eine Taste in Tasteneinheiten. Der Ursprung liegt oben links; eine Einheit
/// ist die Breite einer gewoehnlichen Buchstabentaste.
struct KeyGeometry {
    Scancode scancode;
    float x;
    float y;
    float width;
    float height;
    KeyShape shape = KeyShape.RECT;
}

enum BoardLayout {
    ISO,
    ANSI
}

/// Die Tastaturgeometrie, wie sie bis Paket 5a im Zeichencode von osk.d stand.
/// Bewusst eine Tabelle statt einer Rechnung: Die Werte sind gewachsen und
/// haben keine geschlossene Formel.
KeyGeometry[] boardGeometry(BoardLayout layout, bool numberRow, bool numpad) {
    KeyGeometry[] keys;

    void add(float x, float y, float w, float h, ubyte code, bool ext = false,
             KeyShape shape = KeyShape.RECT) {
        keys ~= KeyGeometry(Scancode(code, ext), x, y, w, h, shape);
    }

    if (numberRow) {
        add(0, 0, 1, 1, 0x29);
        foreach (i; 0 .. 12) {
            add(1 + i, 0, 1, 1, cast(ubyte)(0x02 + i));
        }
        add(13, 0, 2, 1, 0x0E);  // Backspace
    }

    // Zweite Reihe
    add(0, 1, 1.5, 1, 0x0F);     // Tab
    foreach (i; 0 .. 12) {
        add(1.5 + i, 1, 1, 1, cast(ubyte)(0x10 + i));
    }

    // Dritte Reihe
    add(0, 2, 1.75, 1, 0x3A);    // Capslock
    foreach (i; 0 .. 11) {
        add(1.75 + i, 2, 1, 1, cast(ubyte)(0x1E + i));
    }

    final switch (layout) {
        case BoardLayout.ISO:
            add(12.75, 2, 1, 1, 0x2B);                        // OEM in Reihe 3
            add(13.5, 1, 1.5, 2, 0x1C, false, KeyShape.ISO_RETURN);
            add(0, 3, 1.25, 1, 0x2A);                         // Shift links
            add(1.25, 3, 1, 1, 0x56);                         // ISO-Zusatztaste
            break;
        case BoardLayout.ANSI:
            add(13.5, 1, 1.5, 1, 0x2B);                       // OEM in Reihe 2
            add(12.75, 2, 2.25, 1, 0x1C);                     // Return
            add(0, 3, 2.25, 1, 0x2A);                         // Shift links
            break;
    }

    // Vierte Reihe
    foreach (i; 0 .. 10) {
        add(2.25 + i, 3, 1, 1, cast(ubyte)(0x2C + i));
    }
    add(12.25, 3, 2.75, 1, 0x36, true);   // Shift rechts

    // Fuenfte Reihe
    add(0, 4, 1.25, 1, 0x1D);             // Strg links
    add(1.25, 4, 1.25, 1, 0x5B, true);    // Win
    add(2.5, 4, 1.25, 1, 0x38);           // Alt
    add(3.75, 4, 6.25, 1, 0x39);          // Leertaste
    add(10, 4, 1.25, 1, 0x38, true);      // AltGr
    add(11.25, 4, 1.25, 1, 0x5C, true);   // Win
    add(13.75, 4, 1.25, 1, 0x1D, true);   // Strg rechts

    if (numpad) {
        add(16, 0, 1, 1, 0x45, true);     // Numlock
        add(17, 0, 1, 1, 0x35, true);
        add(18, 0, 1, 1, 0x37);
        add(19, 0, 1, 1, 0x4A);
        add(16, 1, 1, 1, 0x47);
        add(17, 1, 1, 1, 0x48);
        add(18, 1, 1, 1, 0x49);
        add(16, 2, 1, 1, 0x4B);
        add(17, 2, 1, 1, 0x4C);
        add(18, 2, 1, 1, 0x4D);
        add(16, 3, 1, 1, 0x4F);
        add(17, 3, 1, 1, 0x50);
        add(18, 3, 1, 1, 0x51);
        add(16, 4, 2, 1, 0x52);
        add(18, 4, 1, 1, 0x53);
        add(19, 1, 1, 2, 0x4E);           // Numpad-Plus, doppelt hoch
        add(19, 3, 1, 2, 0x1C, true);     // Numpad-Return, doppelt hoch
    }

    return keys;
}

version (unittest) {
    import std.json : parseJSON;
    import keysyms : initKeysyms;
}

unittest {
    // Ohne Layout (noch nicht geladen, z.B. vor dem ersten erkannten Fenster)
    // liefert describeKey EMPTY und "nicht im Layout" - kein Absturz auf
    // layout.modifiers/layout.map bei layout == null.
    bool nichtsGehalten(Modifier m) nothrow { return false; }
    auto ohneLayout = describeKey(null, Scancode(0x10, false), 1, false, &nichtsGehalten, false);
    assert(ohneLayout.kind == KeyKind.EMPTY);
    assert(!ohneLayout.inLayout);
}

unittest {
    // Die vier Tastenarten gegen ein Fixture-Layout.
    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestArten",
        "modifiers": {"2A": "LShift", "3A": "Mod3"},
        "layers": [{"Shift": false}, {"Shift": true}],
        "capslockableKeys": ["10"],
        "map": {
            "10": [{"char": "a", "label": "a"}, {"char": "A", "label": "A"}],
            "11": [{"vk": "VK_DELETE", "label": "⌦"}, {}],
            "12": [{}, {}]
        }
    }]`);
    initLayouts(json);
    auto layout = &layouts[0];

    bool nichtsGehalten(Modifier m) nothrow { return false; }

    // Zeichen
    auto a = describeKey(layout, Scancode(0x10, false), 1, false, &nichtsGehalten, false);
    assert(a.kind == KeyKind.CHAR);
    assert(a.label == "a");
    assert(a.codepoints == "a"d);

    // VK-Taste: kein Codepunkt, aber ein Label
    auto entf = describeKey(layout, Scancode(0x11, false), 1, false, &nichtsGehalten, false);
    assert(entf.kind == KeyKind.VKEY);
    assert(entf.label == "⌦");
    assert(entf.codepoints.length == 0);

    // Unbelegt: leerer Eintrag {} ist identisch mit VOID_KEY - aber die Taste
    // gehoert zum Layout und wird von der OSK weiterhin leer gezeichnet
    auto leer = describeKey(layout, Scancode(0x12, false), 1, false, &nichtsGehalten, false);
    assert(leer.kind == KeyKind.EMPTY);
    assert(leer.label == "");
    assert(leer.inLayout);

    // Ein Scancode, der weder in map noch in modifiers steht: ebenfalls EMPTY,
    // aber NICHT im Layout - den zeichnet die OSK gar nicht
    auto fremd = describeKey(layout, Scancode(0x3B, false), 1, false, &nichtsGehalten, false);
    assert(fremd.kind == KeyKind.EMPTY);
    assert(!fremd.inLayout);

    // Auf Ebene 2 ist Scancode 11 ebenfalls unbelegt
    auto entf2 = describeKey(layout, Scancode(0x11, false), 2, false, &nichtsGehalten, false);
    assert(entf2.kind == KeyKind.EMPTY);

    // Modifier-Taste: steht in "modifiers", nicht in "map"
    auto shift = describeKey(layout, Scancode(0x2A, false), 1, false, &nichtsGehalten, false);
    assert(shift.kind == KeyKind.MODIFIER);
    assert(shift.label == "⇧");

    // Ebene 0 gibt es nicht (Ebenen sind 1-basiert) - der Guard
    // "effectiveLayer == 0" in describeKey greift
    auto ebeneNull = describeKey(layout, Scancode(0x10, false), 0, false, &nichtsGehalten, false);
    assert(ebeneNull.kind == KeyKind.EMPTY);

    // Ebene 9 liegt jenseits der zwei Ebenen dieses Fixture-Layouts - der
    // Guard "effectiveLayer > entry.layers.length" greift
    auto ebeneZuHoch = describeKey(layout, Scancode(0x10, false), 9, false, &nichtsGehalten, false);
    assert(ebeneZuHoch.kind == KeyKind.EMPTY);

    // Der VK-Code selbst, nicht nur die Beschriftung: Das Belegungsblatt zeigt
    // bei VK-Tasten den Tastennamen statt eines Codepunkts.
    assert(entf.vkCode == VKEY.VK_DELETE);

    // Bei allem anderen bleibt er auf VK_VOID stehen
    assert(a.vkCode == VKEY.VK_VOID);
    assert(shift.vkCode == VKEY.VK_VOID);
    assert(leer.vkCode == VKEY.VK_VOID);
}

unittest {
    // Nicht-BMP: ein Zeichen, zwei UTF-16-Codeeinheiten, aber genau EIN Codepunkt.
    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestNichtBMPView",
        "modifiers": {},
        "layers": [{"Shift": false}],
        "capslockableKeys": [],
        "map": {"10": [{"char": "𝔄"}]}
    }]`);
    initLayouts(json);

    bool nichtsGehalten(Modifier m) nothrow { return false; }
    auto k = describeKey(&layouts[0], Scancode(0x10, false), 1, false, &nichtsGehalten, false);

    assert(k.kind == KeyKind.CHAR);
    assert(k.codepoints.length == 1, "Surrogatpaar muss ein Codepunkt sein");
    assert(k.codepoints[0] == 0x1D504);
}

unittest {
    // Capslock wird NICHT mehr selbst gerechnet, sondern an layerlock delegiert.
    // Der entscheidende Fall aus Paket 1: Caps + Mod3 bleibt Ebene 3, weil ein
    // gehaltener Neo-Modifier die Umschaltung unterdrueckt.
    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestCaps",
        "modifiers": {"3A": "Mod3"},
        "layers": [{"Shift": false}, {"Shift": true}, {"Mod3": true}],
        "capslockableKeys": ["10"],
        "map": {"10": [{"char": "a"}, {"char": "A"}, {"char": "x"}]}
    }]`);
    initLayouts(json);
    auto layout = &layouts[0];

    bool nichtsGehalten(Modifier m) nothrow { return false; }
    bool mod3Gehalten(Modifier m) nothrow { return m == Modifier.MOD3; }

    // Caps an, capslockable, nichts gehalten -> Ebene 1 zeigt die Ebene-2-Belegung
    auto caps = describeKey(layout, Scancode(0x10, false), 1, true, &nichtsGehalten, false);
    assert(caps.label == "A");

    // Caps an, aber Mod3 gehalten: Ebene 3 bleibt Ebene 3
    auto capsMod3 = describeKey(layout, Scancode(0x10, false), 3, true, &mod3Gehalten, false);
    assert(capsMod3.label == "x");

    // Caps an, aber eine Rastung aktiv: Capslock schweigt
    auto capsLock = describeKey(layout, Scancode(0x10, false), 1, true, &nichtsGehalten, true);
    assert(capsLock.label == "a");
}

unittest {
    // Die Geometrie wird beim Umzug aus osk.d nicht veraendert. Diese Werte
    // stammen wortwoertlich aus osk.d:355-472 und halten das fest.
    auto iso = boardGeometry(BoardLayout.ISO, true, false);

    KeyGeometry find(KeyGeometry[] g, Scancode s) {
        foreach (k; g) if (k.scancode == s) return k;
        assert(false, "Scancode nicht in der Geometrie");
    }

    // Zahlenreihe: Backspace ist doppelt breit
    auto backspace = find(iso, Scancode(0x0E, false));
    assert(backspace.x == 13 && backspace.y == 0);
    assert(backspace.width == 2 && backspace.height == 1);

    // Zweite Reihe beginnt mit Tab, Breite 1.5
    auto tab = find(iso, Scancode(0x0F, false));
    assert(tab.x == 0 && tab.y == 1 && tab.width == 1.5);

    // Grundstellung: Scancode 21 liegt auf 4.75
    auto home = find(iso, Scancode(0x21, false));
    assert(home.x == 4.75 && home.y == 2 && home.width == 1);

    // Leertaste
    auto space = find(iso, Scancode(0x39, false));
    assert(space.x == 3.75 && space.y == 4 && space.width == 6.25);

    // Die ISO-Return-Taste ist KEIN Rechteck, sondern eine L-Form ueber zwei
    // Zeilen (osk.d:394 zeichnet sie mit einer eigenen Routine).
    auto ret = find(iso, Scancode(0x1C, false));
    assert(ret.shape == KeyShape.ISO_RETURN);
    assert(ret.y == 1);

    // ISO hat die Zusatztaste 56 in der vierten Reihe, ANSI nicht
    auto oem56 = find(iso, Scancode(0x56, false));
    assert(oem56.x == 1.25 && oem56.y == 3);

    // OEM-Taste 2B sitzt bei ISO in der dritten Reihe, im Unterschied zu ANSI
    // (siehe ANSI-Test unten, wo dieselbe Taste in Reihe 2 liegt)
    auto oem2B = find(iso, Scancode(0x2B, false));
    assert(oem2B.x == 12.75 && oem2B.y == 2);
}

unittest {
    // ANSI unterscheidet sich an genau drei Stellen von ISO.
    auto ansi = boardGeometry(BoardLayout.ANSI, true, false);

    bool has(KeyGeometry[] g, Scancode s) {
        foreach (k; g) if (k.scancode == s) return true;
        return false;
    }
    KeyGeometry find(KeyGeometry[] g, Scancode s) {
        foreach (k; g) if (k.scancode == s) return k;
        assert(false, "Scancode nicht in der Geometrie");
    }

    // Die ISO-Zusatztaste 56 fehlt
    assert(!has(ansi, Scancode(0x56, false)));

    // Linkes Shift ist dafuer breiter
    assert(find(ansi, Scancode(0x2A, false)).width == 2.25);

    // Return ist ein Rechteck in der dritten Reihe
    auto ret = find(ansi, Scancode(0x1C, false));
    assert(ret.shape == KeyShape.RECT);
    assert(ret.x == 12.75 && ret.y == 2 && ret.width == 2.25);

    // Die OEM-Taste 2B sitzt in der zweiten Reihe statt in der dritten
    auto oem = find(ansi, Scancode(0x2B, false));
    assert(oem.y == 1 && oem.width == 1.5);
}

unittest {
    // Zahlenreihe und Nummernblock sind abschaltbar.
    auto ohneZahlen = boardGeometry(BoardLayout.ISO, false, false);
    foreach (k; ohneZahlen) {
        assert(k.scancode != Scancode(0x0E, false), "Backspace gehoert zur Zahlenreihe");
        assert(k.y != 0 || k.x >= 16, "Zeile 0 gehoert zur Zahlenreihe");
    }

    auto mitBlock = boardGeometry(BoardLayout.ISO, true, true);
    bool has(KeyGeometry[] g, Scancode s) {
        foreach (k; g) if (k.scancode == s) return true;
        return false;
    }
    assert(has(mitBlock, Scancode(0x45, true)), "Numlock fehlt");
    assert(!has(boardGeometry(BoardLayout.ISO, true, false), Scancode(0x45, true)));

    // Numpad-Plus und Numpad-Return sind doppelt hoch
    KeyGeometry find(KeyGeometry[] g, Scancode s) {
        foreach (k; g) if (k.scancode == s) return k;
        assert(false, "Scancode nicht in der Geometrie");
    }
    assert(find(mitBlock, Scancode(0x4E, false)).height == 2);
    assert(find(mitBlock, Scancode(0x1C, true)).height == 2);
}

unittest {
    // keyLabel: die vier Faelle aus dem Fund "Wichtig 4" der Abschlusspruefung
    // von Paket 5b - vorher stand die Regel getrennt in osk.d und sheet.d und
    // beantwortete sie schon unterschiedlich.
    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestKeyLabel",
        "modifiers": {"2A": "LShift"},
        "layers": [{"Shift": false}, {"Shift": true}],
        "capslockableKeys": [],
        "map": {
            "10": [{"char": "a", "label": "a"}, {"char": "A", "label": "A"}]
        }
    }]`);
    initLayouts(json);
    auto layout = &layouts[0];

    bool nichtsGehalten(Modifier m) nothrow { return false; }

    // 1. Im Layout: Beschriftung wird gezeichnet.
    auto zeichen = describeKey(layout, Scancode(0x10, false), 1, false, &nichtsGehalten, false);
    auto zeichenLabel = keyLabel(layout, zeichen);
    assert(zeichenLabel.draw);
    assert(zeichenLabel.text == "a");

    // 2. Modifier ohne Beschriftung: wird NICHT gezeichnet - weder als leere
    // noch als grau gefuellte Taste. modifierLabel deckt derzeit jeden
    // gueltigen Modifier-Wert ab (SHIFT/CTRL/ALT/MOD3..MOD9 ueber
    // genericModifier), die leere Beschriftung laesst sich also nicht ueber
    // describeKey erzeugen - der KeyView wird deshalb direkt gebaut, so wie
    // osk.d ihn vor Paket 5b als Randfall behandelte.
    KeyView unbeschrifteterModifier;
    unbeschrifteterModifier.kind = KeyKind.MODIFIER;
    unbeschrifteterModifier.inLayout = true;
    unbeschrifteterModifier.label = "";
    auto modLabel = keyLabel(layout, unbeschrifteterModifier);
    assert(!modLabel.draw);

    // 3. Nicht im Layout, aber ein Layout ist geladen: Beschriftungsersatz.
    auto rueck = describeKey(layout, Scancode(0x0E, false), 1, false, &nichtsGehalten, false);
    assert(!rueck.inLayout);
    auto rueckLabel = keyLabel(layout, rueck);
    assert(rueckLabel.draw);
    assert(rueckLabel.text == "⌫");

    // 4. Nicht im Layout UND kein Layout geladen: nicht zeichnen, auch wenn
    // derselbe Scancode sonst einen Ersatz bekaeme.
    auto ohneLayout = describeKey(null, Scancode(0x0E, false), 1, false, &nichtsGehalten, false);
    auto ohneLayoutLabel = keyLabel(null, ohneLayout);
    assert(!ohneLayoutLabel.draw);

    // Ein Scancode ohne Ersatz, nicht im Layout, aber Layout geladen: auch
    // dann nicht zeichnen.
    auto fremd = describeKey(layout, Scancode(0x3B, false), 1, false, &nichtsGehalten, false);
    auto fremdLabel = keyLabel(layout, fremd);
    assert(!fremdLabel.draw);
}

unittest {
    // Die Grundebenen bilden Buchstaben auf VK-Codes ab, damit Windows einen
    // echten Tastendruck sieht (Strg+C, Alt+Tab, Spiele). Fuer die Darstellung
    // zaehlt trotzdem, was dabei herauskommt: Ein VK-Mapping mit einem
    // Zeichen-Keysym ist eine Zeichentaste.
    scope(exit) resetLayoutsForTest();
    initKeysyms(".");

    auto json = parseJSON(`[{
        "name": "TestZeichentasten",
        "modifiers": {},
        "layers": [{"Shift": false}],
        "capslockableKeys": [],
        "map": {
            "21": [{"keysym": "e", "vk": "VK_KEY_E", "label": "e"}],
            "0C": [{"keysym": "minus", "vk": "VK_OEM_MINUS", "label": "-"}],
            "39": [{"keysym": "space", "vk": "VK_SPACE", "label": "␣"}],
            "0F": [{"keysym": "Tab", "vk": "VK_TAB", "label": "↹"}],
            "1C": [{"keysym": "Return", "vk": "VK_RETURN", "label": "↩"}],
            "4D": [{"keysym": "Right", "vk": "VK_RIGHT", "label": "→"}],
            "30": [{"vk": "VK_KEY_Z", "mods": {"Ctrl": true}, "label": "⎌"}]
        }
    }]`);
    initLayouts(json);
    auto layout = &layouts[0];

    bool nichtsGehalten(Modifier m) nothrow { return false; }
    KeyView sicht(string scancode) {
        return describeKey(layout, parseScancode(scancode), 1, false, &nichtsGehalten, false);
    }

    // Buchstabe: VK-Taste, aber sie erzeugt ein Zeichen
    auto e = sicht("21");
    assert(e.kind == KeyKind.VKEY, "die Art des Mappings bleibt VKEY");
    assert(e.vkCode == VKEY.VK_KEY_E);
    assert(e.codepoints == "e"d);

    // OEM-Taste mit Zeichen-Keysym
    assert(sicht("0C").codepoints == "-"d);

    // Leertaste erzeugt U+0020 - bewusst eine Zeichentaste
    assert(sicht("39").codepoints == " "d);

    // Echte Funktionstasten: kein Codepunkt, obwohl ihre Beschriftung ein
    // druckbares Zeichen ist. Genau daran darf die Regel nicht haengen.
    assert(sicht("0F").codepoints.length == 0, "Tab ist keine Zeichentaste");
    assert(sicht("1C").codepoints.length == 0, "Eingabe ist keine Zeichentaste");
    assert(sicht("4D").codepoints.length == 0, "Pfeiltaste ist keine Zeichentaste");

    // Erzwungene Modifier: Die Taste sendet Strg+Z, also ein Tastenkuerzel
    assert(sicht("30").codepoints.length == 0, "Tastenkuerzel ist keine Zeichentaste");
}

unittest {
    // Nummernblock: keysymdef.h ordnet den KP_-Keysyms keinen Codepunkt zu,
    // deshalb die kleine feste Tabelle. Entscheidend ist, dass sie das TATSAECHLICH
    // erzeugte Zeichen liefert und nicht die Beschriftung - die Taste traegt "×",
    // tippt aber "*".
    scope(exit) resetLayoutsForTest();
    initKeysyms(".");

    auto json = parseJSON(`[{
        "name": "TestNummernblock",
        "modifiers": {},
        "layers": [{"Shift": false}],
        "capslockableKeys": [],
        "map": {
            "47": [{"keysym": "KP_7", "vk": "VK_NUMPAD7", "label": "7"}],
            "37": [{"keysym": "KP_Multiply", "vk": "VK_MULTIPLY", "label": "×"}],
            "35+": [{"keysym": "KP_Divide", "vk": "VK_DIVIDE", "label": "÷"}],
            "4E": [{"keysym": "KP_Add", "vk": "VK_ADD", "label": "+"}],
            "53": [{"keysym": "KP_Separator", "vk": "VK_DECIMAL", "label": ","}],
            "48": [{"keysym": "KP_Up", "vk": "VK_UP", "label": "↑"}]
        }
    }]`);
    initLayouts(json);
    auto layout = &layouts[0];

    bool nichtsGehalten(Modifier m) nothrow { return false; }
    KeyView sicht(string scancode) {
        return describeKey(layout, parseScancode(scancode), 1, false, &nichtsGehalten, false);
    }

    assert(sicht("47").codepoints == "7"d);
    assert(sicht("37").codepoints == "*"d, "die Taste traegt × und tippt *");
    assert(sicht("35+").codepoints == "/"d, "die Taste traegt ÷ und tippt /");
    assert(sicht("4E").codepoints == "+"d);
    assert(sicht("53").codepoints == ","d);

    // Der Nummernblock traegt auf anderen Ebenen Navigationstasten - die
    // bleiben Funktionstasten, obwohl ihr Keysym ebenfalls mit KP_ anfaengt.
    assert(sicht("48").codepoints.length == 0, "KP_Up ist keine Zeichentaste");
}

unittest {
    // keypadChar allein, ohne Layout drumherum.
    assert(keypadChar(0xFFB0) == '0');
    assert(keypadChar(0xFFB9) == '9');
    assert(keypadChar(0xFFAA) == '*');
    assert(keypadChar(0xFFAB) == '+');
    assert(keypadChar(0xFFAC) == ',');
    assert(keypadChar(0xFFAD) == '-');
    assert(keypadChar(0xFFAE) == '.');
    assert(keypadChar(0xFFAF) == '/');
    assert(keypadChar(0xFFBD) == '=');
    assert(keypadChar(0xFF80) == ' ');

    // Nichts vom Nummernblock: KP_Enter, KP_Tab, KP_Up, und ein Keysym, das
    // gar keiner ist
    assert(keypadChar(0xFF8D) == dchar.init);
    assert(keypadChar(0xFF89) == dchar.init);
    assert(keypadChar(0xFF52) == dchar.init);
    assert(keypadChar(0x0065) == dchar.init);
}

unittest {
    // Regression gegen die ausgelieferten Daten: Auf der Grundebene von Noted
    // muss die Grundstellung Zeichen tragen. Faellt dieser Test, ist entweder
    // die Regel kaputt oder layouts.json hat sich grundlegend geaendert.
    import std.file : readText;
    scope(exit) resetLayoutsForTest();

    initKeysyms(".");
    initLayouts(parseJSON(readText("layouts.json"))["layouts"]);

    NeoLayout* noted;
    foreach (ref l; layouts) if (l.name == "Noted"w) noted = &l;
    assert(noted !is null);

    bool nichtsGehalten(Modifier m) nothrow { return false; }

    auto e = describeKey(noted, Scancode(0x21, false), 1, false, &nichtsGehalten, false);
    assert(e.codepoints == "e"d, "Grundstellung 'e' muss auf Ebene 1 ein Zeichen tragen");

    auto tab = describeKey(noted, Scancode(0x0F, false), 1, false, &nichtsGehalten, false);
    assert(tab.codepoints.length == 0, "Tab bleibt Funktionstaste");
}

unittest {
    // Offset-Keysyms: parseKeysym liefert fuer die UXXXX-Form
    // Codepunkt + 0x01000000, und solche Keysyms stehen nie in
    // codepointsByKeysym. Eine VK-Taste mit U-Form-Keysym ist trotzdem eine
    // Zeichentaste - ohne den Offset-Zweig bliebe sie faelschlich
    // Funktionstaste (geparkter Befund aus dem Paket-5c-Abschlussreview).
    // U1D56C (Codepunkt 0x1D56C) ist > 0x30FF, hat also kein Legacy-Keysym,
    // und wird damit zu einem echten Offset-Keysym (Wert >= 0x01000000).
    scope(exit) resetLayoutsForTest();
    initKeysyms(".");

    auto json = parseJSON(`[{
        "name": "TestOffsetKeysym",
        "modifiers": {},
        "layers": [{"Shift": false}],
        "capslockableKeys": [],
        "map": {
            "0C": [{"keysym": "U1D56C", "vk": "VK_OEM_MINUS", "label": "𝕬"}]
        }
    }]`);
    initLayouts(json);

    bool nichtsGehalten(Modifier m) nothrow { return false; }
    auto sicht = describeKey(&layouts[0], parseScancode("0C"), 1, false,
                             &nichtsGehalten, false);
    assert(sicht.kind == KeyKind.VKEY, "die Art des Mappings bleibt VKEY");
    assert(sicht.codepoints.length == 1 && sicht.codepoints[0] == cast(dchar) 0x1D56C,
        "U-Form-Keysym traegt seinen Codepunkt");
}
