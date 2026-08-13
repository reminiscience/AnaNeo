module mapping;

import core.sys.windows.windows;

import std.conv;
import std.json;
import std.algorithm;
import std.array;
import std.string;
import std.exception : assertThrown, assertNotThrown;

import debuglog;
import keysyms;
import layerlock : genericModifier, isNeoModifier;

NeoKey VOID_KEY = NeoKey(KEYSYM_VOID, NeoKeyType.VKEY, VKEY.VK_VOID);

NeoLayout[] layouts;
/// Zeigt in layouts. Wohnt hier und nicht in ananeo.d, weil layouts hier
/// wohnt: Ein Zeiger auf ein Array gehoert neben das Array, sonst kann das
/// Datenmodul seinen eigenen Zustand nicht abraeumen.
NeoLayout *activeLayout;

enum VKEY {
    VK_LBUTTON = 0x01,
    VK_RBUTTON = 0x02,
    VK_CANCEL = 0x03,
    VK_MBUTTON = 0x04,
    VK_XBUTTON1 = 0x05,
    VK_XBUTTON2 = 0x06,
    // undefined 0x07
    VK_BACK = 0x08,
    VK_TAB = 0x09,
    // reserved 0x0A-0x0B
    VK_CLEAR = 0x0C,
    VK_RETURN = 0x0D,
    // undefined 0x0E-0x0F
    VK_SHIFT = 0x10,
    VK_CONTROL = 0x11,
    VK_MENU = 0x12,
    VK_PAUSE = 0x13,
    VK_CAPITAL = 0x14,
    VK_KANA = 0x15,
    VK_HANGEUL = 0x15,
    VK_HANGUL = 0x15,
    VK_JUNJA = 0x17,
    VK_FINAL = 0x18,
    VK_HANJA = 0x19,
    VK_KANJI = 0x19,
    VK_ESCAPE = 0x1B,
    VK_CONVERT = 0x1C,
    VK_NONCONVERT = 0x1D,
    VK_ACCEPT = 0x1E,
    VK_MODECHANGE = 0x1F,
    VK_SPACE = 0x20,
    VK_PRIOR = 0x21,
    VK_NEXT = 0x22,
    VK_END = 0x23,
    VK_HOME = 0x24,
    VK_LEFT = 0x25,
    VK_UP = 0x26,
    VK_RIGHT = 0x27,
    VK_DOWN = 0x28,
    VK_SELECT = 0x29,
    VK_PRINT = 0x2A,
    VK_EXECUTE = 0x2B,
    VK_SNAPSHOT = 0x2C,
    VK_INSERT = 0x2D,
    VK_DELETE = 0x2E,
    VK_HELP = 0x2F,
    VK_KEY_0 = 0x30,
    VK_KEY_1,
    VK_KEY_2,
    VK_KEY_3,
    VK_KEY_4,
    VK_KEY_5,
    VK_KEY_6,
    VK_KEY_7,
    VK_KEY_8,
    VK_KEY_9,
    // undefined 0x3A-0x40
    VK_KEY_A = 0x41,
    VK_KEY_B,
    VK_KEY_C,
    VK_KEY_D,
    VK_KEY_E,
    VK_KEY_F,
    VK_KEY_G,
    VK_KEY_H,
    VK_KEY_I,
    VK_KEY_J,
    VK_KEY_K,
    VK_KEY_L,
    VK_KEY_M,
    VK_KEY_N,
    VK_KEY_O,
    VK_KEY_P,
    VK_KEY_Q,
    VK_KEY_R,
    VK_KEY_S,
    VK_KEY_T,
    VK_KEY_U,
    VK_KEY_V,
    VK_KEY_W,
    VK_KEY_X,
    VK_KEY_Y,
    VK_KEY_Z,
    VK_LWIN = 0x5B,
    VK_RWIN = 0x5C,
    VK_APPS = 0x5D,
    // reserved 0x5E
    VK_SLEEP = 0x5F,
    VK_NUMPAD0 = 0x60,
    VK_NUMPAD1 = 0x61,
    VK_NUMPAD2 = 0x62,
    VK_NUMPAD3 = 0x63,
    VK_NUMPAD4 = 0x64,
    VK_NUMPAD5 = 0x65,
    VK_NUMPAD6 = 0x66,
    VK_NUMPAD7 = 0x67,
    VK_NUMPAD8 = 0x68,
    VK_NUMPAD9 = 0x69,
    VK_MULTIPLY = 0x6A,
    VK_ADD = 0x6B,
    VK_SEPARATOR = 0x6C,
    VK_SUBTRACT = 0x6D,
    VK_DECIMAL = 0x6E,
    VK_DIVIDE = 0x6F,
    VK_F1 = 0x70,
    VK_F2 = 0x71,
    VK_F3 = 0x72,
    VK_F4 = 0x73,
    VK_F5 = 0x74,
    VK_F6 = 0x75,
    VK_F7 = 0x76,
    VK_F8 = 0x77,
    VK_F9 = 0x78,
    VK_F10 = 0x79,
    VK_F11 = 0x7A,
    VK_F12 = 0x7B,
    VK_F13 = 0x7C,
    VK_F14 = 0x7D,
    VK_F15 = 0x7E,
    VK_F16 = 0x7F,
    VK_F17 = 0x80,
    VK_F18 = 0x81,
    VK_F19 = 0x82,
    VK_F20 = 0x83,
    VK_F21 = 0x84,
    VK_F22 = 0x85,
    VK_F23 = 0x86,
    VK_F24 = 0x87,
    // unassigned 0x88-0x8F
    // Fake VK for Ctrl+Z combo
    VK_UNDO = 0x89,
    VK_NUMLOCK = 0x90,
    VK_SCROLL = 0x91,
    // OEM specific 0x92-0x96
    // unassigned 0x97-0x9F
    VK_LSHIFT = 0xA0,
    VK_RSHIFT = 0xA1,
    VK_LCONTROL = 0xA2,
    VK_RCONTROL = 0xA3,
    VK_LMENU = 0xA4,
    VK_RMENU = 0xA5,
    VK_BROWSER_BACK = 0xA6,
    VK_BROWSER_FORWARD = 0xA7,
    VK_BROWSER_REFRESH = 0xA8,
    VK_BROWSER_STOP = 0xA9,
    VK_BROWSER_SEARCH = 0xAA,
    VK_BROWSER_FAVORITES = 0xAB,
    VK_BROWSER_HOME = 0xAC,
    VK_VOLUME_MUTE = 0xAD,
    VK_VOLUME_DOWN = 0xAE,
    VK_VOLUME_UP = 0xAF,
    VK_MEDIA_NEXT_TRACK = 0xB0,
    VK_MEDIA_PREV_TRACK = 0xB1,
    VK_MEDIA_STOP = 0xB2,
    VK_MEDIA_PLAY_PAUSE = 0xB3,
    VK_LAUNCH_MAIL = 0xB4,
    VK_LAUNCH_MEDIA_SELECT = 0xB5,
    VK_LAUNCH_APP1 = 0xB6,
    VK_LAUNCH_APP2 = 0xB7,
    // reserved 0xB8-0xB9
    VK_OEM_1 = 0xBA,
    VK_OEM_PLUS = 0xBB,
    VK_OEM_COMMA = 0xBC,
    VK_OEM_MINUS = 0xBD,
    VK_OEM_PERIOD = 0xBE,
    VK_OEM_2 = 0xBF,
    VK_OEM_3 = 0xC0,
    // reserved 0xC1-0xD7
    // unassigned 0xD8-0xDA
    VK_OEM_4 = 0xDB,
    VK_OEM_5 = 0xDC,
    VK_OEM_6 = 0xDD,
    VK_OEM_7 = 0xDE,
    VK_OEM_8 = 0xDF,
    // reserved 0xE0
    // OEM specific 0xE1
    VK_OEM_102 = 0xE2,
    // OEM specific 0xE3-0xE4
    VK_PROCESSKEY = 0xE5,
    // OEM specific 0xE6
    VK_PACKET = 0xE7,
    // unassigned 0xE8
    // OEM specific 0xE9-0xF5
    VK_ATTN = 0xF6,
    VK_CRSEL = 0xF7,
    VK_EXSEL = 0xF8,
    VK_EREOF = 0xF9,
    VK_PLAY = 0xFA,
    VK_ZOOM = 0xFB,
    VK_NONAME = 0xFC,
    VK_PA1 = 0xFD,
    VK_OEM_CLEAR = 0xFE,
    VK_VOID = 0xFF
}

enum Modifier {
    SHIFT = 0xA0,
    LSHIFT = 0xA0,  // values for native modifiers correspond to VKs
    RSHIFT,
    CTRL = 0xA2,
    LCTRL = 0xA2,
    RCTRL,
    ALT = 0xA4,
    LALT = 0xA4,
    RALT,
    MOD3 = 0x100,
    LMOD3 = 0x100,
    RMOD3,
    MOD4 = 0x102,
    LMOD4 = 0x102,
    RMOD4,
    // There is no left and right variant for MOD5+, because there is no Mod5 lock
    // or a natural left and right position in the default layouts, so we don't need to differentiate
    MOD5 = 0x104,
    MOD6 = 0x106,
    MOD7 = 0x108,
    MOD8 = 0x10A,
    MOD9 = 0x10C
}

// Contains state (true=down) for *some* modifiers.
alias PartialModifierState = bool[Modifier];

struct Scancode {
    uint scan;
    bool extended;  // whether the extended bit is set for this physical key
}

enum NeoKeyType {
    VKEY,
    CHAR
}

struct NeoKey {
    uint keysym;
    NeoKeyType keytype;
    VKEY vkCode;
    /// Vollstaendige Zeichenkette in UTF-16. Bewusst KEIN wchar und bewusst
    /// nicht in einer Union mit vkCode: Zeichen jenseits der BMP brauchen zwei
    /// Codeeinheiten, und ein wstring ist ein Fat Pointer, der in einer Union
    /// mit einem Enum nichts zu suchen hat. Der Mehrverbrauch ist bei 66
    /// Tasten mal 20 Ebenen bedeutungslos.
    wstring chars;
    PartialModifierState modifiers;
    string label;
}

struct MapEntry {
    NeoKey[] layers;
    bool capslockable; // is this key affected by capslock
}

struct NeoLayout {
    wstring name;
    wstring dllName;
    Modifier[Scancode] modifiers;
    PartialModifierState[] layers;  // required modifier state for each layer
    // Je Ebene: nimmt sie sich von "Locked-not-don't-care" aus? Nur die
    // Modifikator-Ebene tut das, damit sie aus jedem gerasteten Block
    // erreichbar bleibt (siehe layerlock.determineLayer).
    bool[] layerIgnoresLocks;
    // je Ebene: verlangt sie mindestens einen Neo-Modifier? Daraus entscheidet
    // der Hook, ob er eine Taste essen und selbst ersetzen muss.
    bool[] layerNeedsNeoModifier;
    MapEntry[Scancode] map;  // map scancodes to an array (usually 6 entries) of keys for each layer and misc other info
}

void initLayouts(JSONValue jsonLayoutArray) {
    layouts = [];

    foreach (JSONValue jsonLayout; jsonLayoutArray.array) {
        NeoLayout layout;
        layout.name = jsonLayout["name"].str.to!wstring;
        if ("dllName" in jsonLayout) {
            // if there is no dllName this is a pure standalone layout
            layout.dllName = jsonLayout["dllName"].str.to!wstring;
        }

        // Parse modifier mappings
        foreach (string scancodeString, JSONValue jsonModifierName; jsonLayout["modifiers"]) {
            layout.modifiers[parseScancode(scancodeString)] = parseModifier(jsonModifierName.str);
        }

        // Parse layer definitions
        foreach (jsonPartialModifierState; jsonLayout["layers"].array) {
            PartialModifierState pms;
            bool ignoriertRastung;

            foreach (string modifierName, JSONValue modifierState; jsonPartialModifierState) {
                // "ignoreLocks" ist kein Modifier, sondern eine Eigenschaft der
                // Ebene. Ohne diesen Zweig liefe der Name in parseModifier und
                // wuerde dort werfen.
                if (modifierName == "ignoreLocks") {
                    ignoriertRastung = modifierState.boolean;
                    continue;
                }
                pms[parseModifier(modifierName)] = modifierState.boolean;
            }

            layout.layers ~= pms;
            layout.layerIgnoresLocks ~= ignoriertRastung;
        }

        // Fuer jede Ebene ableiten, ob sie ohne Neo-Modifier erreichbar ist.
        // Ersetzt die frueher hartkodierte Annahme "ab Ebene 3 braucht es Mod3
        // oder Mod4", die bei abweichenden Ebenenreihenfolgen falsch war.
        foreach (pms; layout.layers) {
            bool brauchtNeoModifier;
            foreach (mod; pms.byKey) {
                if (isNeoModifier(genericModifier(mod)) && pms[mod]) {
                    brauchtNeoModifier = true;
                    break;
                }
            }
            layout.layerNeedsNeoModifier ~= brauchtNeoModifier;
        }

        foreach (string scancodeString, JSONValue jsonLayersArray; jsonLayout["map"]) {
            MapEntry entry;
            auto jsonLayers = jsonLayersArray.array;

            if (jsonLayers.length < layout.layers.length) {
                // Tolerantes Laden: fehlende Ebenen bleiben leer, statt den Start
                // mit einem RangeError abzubrechen (der wird in app.d nicht gefangen)
                debugWriteln("Layout '", layout.name, "', Scancode ", scancodeString, ": nur ",
                    jsonLayers.length, " von ", layout.layers.length,
                    " Ebenen definiert, die fehlenden bleiben leer.");
            }

            for (int i = 0; i < layout.layers.length; i++) {
                entry.layers ~= i < jsonLayers.length ? parseNeoKey(jsonLayers[i]) : VOID_KEY;
            }

            layout.map[parseScancode(scancodeString)] = entry;
        }

        foreach (JSONValue scancodeJson; jsonLayout["capslockableKeys"].array) {
            auto scan = parseScancode(scancodeJson.str);

            if (scan !in layout.map) {
                debugWriteln("Layout '", layout.name, "': capslockableKeys nennt Scancode ",
                    scancodeJson.str, ", der in 'map' nicht vorkommt. Eintrag wird ignoriert.");
                continue;
            }

            layout.map[scan].capslockable = true;
        }

        layouts ~= layout;
    }
}

NeoKey parseNeoKey(JSONValue jsonKey) {
    NeoKey key;
    key.vkCode = VKEY.VK_VOID;
    
    if ("keysym" in jsonKey) {
        key.keysym = parseKeysym(jsonKey["keysym"].str);
    } else {
        key.keysym = KEYSYM_VOID;
    }

    if ("vk" in jsonKey) {
        key.keytype = NeoKeyType.VKEY;
        key.vkCode = jsonKey["vk"].str.to!VKEY;

        if ("mods" in jsonKey) {
            foreach (string modifierName, JSONValue modifierState; jsonKey["mods"]) {
                key.modifiers[parseModifier(modifierName)] = modifierState.boolean;
            }
        }
    } else if ("char" in jsonKey) {
        key.keytype = NeoKeyType.CHAR;
        wstring charStr = jsonKey["char"].str.to!wstring;
        if (charStr.length == 0) {
            throw new Exception("Ungueltiger Eintrag \"char\": \"\" - erwartet wird mindestens ein Zeichen.");
        }
        key.chars = charStr;
    }

    if ("label" in jsonKey) {
        key.label = jsonKey["label"].str;
    } else if ("char" in jsonKey) {
        key.label = jsonKey["char"].str;
    }

    return key;
}

Scancode parseScancode(string scancodeString) {
    // scancode is a byte in hex, a + after the code means the extended bit is set.
    // Gueltig sind genau zwei Hexziffern, optional gefolgt von '+'. Alles andere
    // (z.B. ein vertippter Schluessel in map/modifiers/capslockableKeys/mirrorMap)
    // wirft eine Exception statt eines RangeError, damit app.d sie fangen kann.
    if (scancodeString.length != 2 && scancodeString.length != 3) {
        throw new Exception("Ungueltiger Scancode '" ~ scancodeString ~ "': erwartet werden zwei Hexziffern, optional gefolgt von '+'.");
    }
    if (scancodeString.length == 3 && scancodeString[2] != '+') {
        throw new Exception("Ungueltiger Scancode '" ~ scancodeString ~ "': das dritte Zeichen muss '+' sein.");
    }

    bool extended = scancodeString.length == 3;
    uint scan;
    try {
        scan = scancodeString[0..2].to!uint(16);
    } catch (ConvException e) {
        throw new Exception("Ungueltiger Scancode '" ~ scancodeString ~ "': die ersten beiden Zeichen sind keine Hexziffern.");
    }
    return Scancode(scan, extended);
}

Modifier parseModifier(string modifierName) {
    return modifierName.toUpper.to!Modifier;
}

unittest {
    // parseScancode: zwei Hexziffern, optionales '+' setzt das Extended-Bit
    assert(parseScancode("2A") == Scancode(0x2A, false));
    assert(parseScancode("38+") == Scancode(0x38, true));
    assert(parseScancode("FF") == Scancode(0xFF, false));
}

unittest {
    // parseModifier ist case-insensitiv, weil es intern toUpper anwendet
    assert(parseModifier("Mod3") == Modifier.MOD3);
    assert(parseModifier("mod4") == Modifier.MOD4);
    assert(parseModifier("LShift") == Modifier.LSHIFT);
    assert(parseModifier("RMod3") == Modifier.RMOD3);
}

unittest {
    // parseScancode: ein zu kurzer String darf keinen RangeError werfen (Befund 4),
    // sondern eine verstaendliche Exception, die den fehlerhaften Wert nennt.
    // Gueltige Werte muessen weiterhin funktionieren.
    assertNotThrown!Exception(parseScancode("2A"));
    assertNotThrown!Exception(parseScancode("38+"));

    assertThrown!Exception(parseScancode(""));
    assertThrown!Exception(parseScancode("1"));
}

unittest {
    // parseNeoKey: "char": "" darf keinen RangeError werfen (Befund 4),
    // sondern eine verstaendliche Exception. Ein gueltiger char-Wert bleibt unveraendert.
    import std.json : parseJSON;

    assertNotThrown!Exception(parseNeoKey(parseJSON(`{"char": "a"}`)));
    assertThrown!Exception(parseNeoKey(parseJSON(`{"char": ""}`)));
}

unittest {
    // Zu kurze map-Zeile: fehlende Ebenen werden aufgefuellt statt RangeError zu werfen
    import std.json : parseJSON;

    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestKurzeZeile",
        "modifiers": {"2A": "LShift"},
        "layers": [{"Shift": false}, {"Shift": true}, {"Mod3": true}],
        "capslockableKeys": [],
        "map": {"10": [{"char": "a"}, {"char": "A"}]}
    }]`);

    initLayouts(json);

    assert(layouts.length == 1);
    auto entry = layouts[0].map[Scancode(0x10, false)];
    assert(entry.layers.length == 3);
    assert(entry.layers[0].keytype == NeoKeyType.CHAR);
    assert(entry.layers[0].chars == "a"w);
    assert(entry.layers[1].chars == "A"w);
    // Ebene 3 fehlt in den Daten und ist deshalb leer
    assert(entry.layers[2].keysym == KEYSYM_VOID);
    assert(entry.layers[2].keytype == NeoKeyType.VKEY);
    assert(entry.layers[2].vkCode == VKEY.VK_VOID);
}

unittest {
    // Ueberzaehlige Eintraege in einer map-Zeile werden ignoriert
    import std.json : parseJSON;

    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestLangeZeile",
        "modifiers": {},
        "layers": [{"Shift": false}],
        "capslockableKeys": [],
        "map": {"10": [{"char": "a"}, {"char": "A"}, {"char": "b"}]}
    }]`);

    initLayouts(json);

    assert(layouts[0].map[Scancode(0x10, false)].layers.length == 1);
}

unittest {
    // capslockableKeys darf Scancodes nennen, die in map fehlen
    import std.json : parseJSON;

    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestCapslockable",
        "modifiers": {},
        "layers": [{"Shift": false}],
        "capslockableKeys": ["10", "FF"],
        "map": {"10": [{"char": "a"}]}
    }]`);

    initLayouts(json);

    assert(layouts[0].map[Scancode(0x10, false)].capslockable);
    // Der unbekannte Scancode wurde ignoriert und nicht etwa leer angelegt
    assert(Scancode(0xFF, false) !in layouts[0].map);
}

unittest {
    // Die ausgelieferte layouts.json muss Noted als reines Standalone-Layout
    // enthalten; der Erweiterungsmodus gegen kbdnoted.dll wird seit Paket 6
    // von AnNoted getragen.
    import std.json : parseJSON;
    import std.file : readText;

    scope(exit) resetLayoutsForTest();

    // Ohne initKeysyms faellt parseKeysym (von initLayouts fuer jeden
    // "keysym"-Eintrag aufgerufen) still auf KEYSYM_VOID zurueck und meldet
    // "Keysym ... not found." fuer jeden benannten Keysym.
    initKeysyms(".");
    auto json = parseJSON(readText("layouts.json"));
    initLayouts(json["layouts"]);

    NeoLayout *noted;
    foreach (ref l; layouts) {
        if (l.name == "Noted"w) {
            noted = &l;
        }
    }

    assert(noted !is null, "Layout 'Noted' fehlt in layouts.json");
    assert(noted.dllName.length == 0, "Noted ist seit Paket 6 ein reines Standalone-Layout");
    assert(noted.layers.length == 6);
    // Stichproben aus dem Noted-Block: Scancode 13 traegt a/A auf den ersten Ebenen
    auto a = noted.map[Scancode(0x13, false)];
    assert(a.layers.length == 6);
    assert(a.capslockable);
    assert(a.layers[0].vkCode == VKEY.VK_KEY_A);
}

unittest {
    // Fixture: die Ebenendefinition des ausgemusterten Layouts 3l.
    // Aufbewahrt als Regressionsfall fuer Paket 1: 3l hat acht Ebenen in
    // anderer Reihenfolge, seine reine Mod4-Ebene ist Ebene 5 (Index 4).
    // Der heutige hartkodierte Mod4-Lock setzt stattdessen layer = 4, greift
    // also auf layers[layer - 1] = layers[3] zu und trifft damit die
    // Shift+Mod3-Variante.
    import std.json : parseJSON;

    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "3lFixture",
        "modifiers": {
            "2A": "LShift", "36+": "RShift", "1D": "LCtrl", "1D+": "RCtrl",
            "38": "LAlt", "38+": "LAlt", "28": "RMod3", "35": "RMod4"
        },
        "layers": [
            {"Shift": false, "Mod3": false, "Mod4": false},
            {"Shift": true,  "Mod3": false, "Mod4": false},
            {"Shift": false, "Mod3": true,  "Mod4": false},
            {"Shift": true,  "Mod3": true,  "Mod4": false},
            {"Shift": false, "Mod3": false, "Mod4": true},
            {"Shift": true,  "Mod3": false, "Mod4": true},
            {"Shift": false, "Mod3": true,  "Mod4": true},
            {"Shift": true,  "Mod3": true,  "Mod4": true}
        ],
        "capslockableKeys": [],
        "map": {}
    }]`);

    initLayouts(json);

    auto l = layouts[0];
    assert(l.layers.length == 8);
    // Index 4 ist die reine Mod4-Ebene, also Ebene 5 - nicht Ebene 4
    assert(l.layers[4][Modifier.SHIFT] == false);
    assert(l.layers[4][Modifier.MOD3] == false);
    assert(l.layers[4][Modifier.MOD4] == true);
    // Index 3 waere die Ebene, die der heutige Lock faelschlich trifft
    assert(l.layers[3][Modifier.MOD4] == false);
}

unittest {
    // Datenintegritaet der ausgelieferten layouts.json:
    // genau vier gepflegte Layouts, jede map-Zeile deckt alle Ebenen ab,
    // und jeder benannte Keysym ist ueber keysymdef.h auflösbar (Befund 5) -
    // ohne initKeysyms faellt parseKeysym still auf KEYSYM_VOID zurueck, und
    // ein Tippfehler wie "Greek_alpah" wuerde sonst von keinem Test bemerkt.
    import std.json : parseJSON;
    import std.file : readText;

    initKeysyms(".");
    auto json = parseJSON(readText("layouts.json"));
    assert(json["layouts"].array.length == 4);

    string[] namen;
    foreach (l; json["layouts"].array) {
        namen ~= l["name"].str;
    }
    assert(namen == ["Neo", "NeoQwertz", "Noted", "AnNoted"]);

    foreach (l; json["layouts"].array) {
        auto anzahlEbenen = l["layers"].array.length;
        foreach (string scancode, zeile; l["map"]) {
            assert(zeile.array.length == anzahlEbenen,
                l["name"].str ~ ", Scancode " ~ scancode ~ ": Ebenenzahl passt nicht");

            foreach (keyJson; zeile.array) {
                if ("keysym" !in keyJson) continue;
                string keysymName = keyJson["keysym"].str;
                // VoidSymbol ist in keysymdef.h absichtlich als 0xffffff definiert,
                // also identisch mit KEYSYM_VOID - kommt dreimal legitim vor
                // (je Layout einmal bei VK_LBUTTON) und ist von der Pruefung ausgenommen.
                if (keysymName == "VoidSymbol") continue;

                uint resolved = parseKeysym(keysymName);
                assert(resolved != KEYSYM_VOID,
                    l["name"].str ~ ", Scancode " ~ scancode ~ ": Keysym '" ~ keysymName ~ "' nicht aufloesbar");
            }
        }
    }
}

version (unittest) {
    // Tests teilen sich den globalen Layoutzustand. initLayouts alloziert das
    // layouts-Array um, activeLayout zeigt aber hinein - wer beides nicht
    // gemeinsam abraeumt, hinterlaesst dem naechsten Test einen baumelnden
    // Zeiger. Deshalb: scope(exit) resetLayoutsForTest(); in jedem Test, der
    // initLayouts aufruft.
    void resetLayoutsForTest() nothrow {
        layouts = [];
        activeLayout = null;
    }
}

unittest {
    // layerNeedsNeoModifier wird aus den layers-Eintraegen abgeleitet und
    // ersetzt spaeter die hartkodierte Bedingung "layer >= 3"
    import std.json : parseJSON;

    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestEbenenbedarf",
        "modifiers": {},
        "layers": [
            {"Shift": false, "Mod3": false, "Mod4": false},
            {"Shift": true,  "Mod3": false, "Mod4": false},
            {"Shift": false, "Mod3": true,  "Mod4": false},
            {"Mod3": false, "Mod4": true},
            {"Shift": true,  "Mod3": true,  "Mod4": false},
            {"Mod3": true,  "Mod4": true}
        ],
        "capslockableKeys": [],
        "map": {}
    }]`);

    initLayouts(json);

    assert(layouts[0].layerNeedsNeoModifier == [false, false, true, true, true, true]);
}

unittest {
    // Auch die ausgelieferten Layouts muessen das Feld tragen, sonst greift
    // die Eat-Bedingung im Hook ins Leere
    import std.json : parseJSON;
    import std.file : readText;

    scope(exit) resetLayoutsForTest();

    initKeysyms(".");
    auto json = parseJSON(readText("layouts.json"));
    initLayouts(json["layouts"]);

    foreach (ref l; layouts) {
        assert(l.layerNeedsNeoModifier.length == l.layers.length);
        // Ebenen 1 und 2 sind ueberall ohne Neo-Modifier erreichbar, alle
        // weiteren nicht; AnNoted hat seit der Grammatikrunde einundzwanzig
        // Ebenen, Noted ist seit Paket 7 auf dem 6-Ebenen-Originalstand
        if (l.name == "AnNoted"w) {
            bool[] erwartet = [false, false];
            foreach (i; 2 .. 21) erwartet ~= true;
            assert(l.layerNeedsNeoModifier == erwartet,
                "AnNoted: 21 Ebenen erwartet (Grammatikrunde)");
        } else {
            assert(l.layerNeedsNeoModifier == [false, false, true, true, true, true]);
        }
    }
}

unittest {
    // Die ausgelieferten Konfigurationen duerfen keine Rastung anbieten, die im
    // zugehoerigen Layout auf keiner Ebene landet. Geprueft wird der echte
    // Invariant ueber determineLayer, nicht bloss, ob der Modifier irgendwo
    // genannt wird: Ein Satz wie ["Mod5", "Mod6"] wird von jeder Noted-Ebene
    // genannt und trifft trotzdem keine - er faellt auf Ebene 1 zurueck,
    // waehrend der Tray-Tooltip einen Themenblock meldet.
    //
    // Der Test benutzt absichtlich die Produktionsparser initLayouts und
    // parseLockTriggers, damit auch die chord-Syntax der ausgelieferten
    // Konfigurationen mitgeprueft wird.
    //
    // Zwei Grenzen dieses Tests: Erstens behandelt er auch toggle-Trigger
    // (etwa Mod3+F7 -> ["Shift"]) als eigenstaendige Rastung, dabei ist ihr
    // lockSet eigentlich nur ein Delta zur laufenden Rastung. Das geht heute
    // gut, weil ["Shift"] zufaellig auch allein eine gueltige Ebene trifft
    // (Ebene 2) - ein kuenftiges Delta, das nur in Kombination Sinn ergibt,
    // wuerde hier faelschlich durchfallen. Zweitens prueft die Assertion nur
    // "irgendeine Ebene ungleich 1", nicht "die vorgesehene Ebene": ein
    // Rastsatz, der auf einer falschen, aber von 1 verschiedenen Ebene
    // landet, faellt nicht auf.
    import std.json : parseJSON;
    import std.file : readText;
    import layerlock : determineLayer, parseLockTriggers, LockAction;

    scope(exit) resetLayoutsForTest();

    initKeysyms(".");
    auto layoutsJson = parseJSON(readText("layouts.json"));
    initLayouts(layoutsJson["layouts"]);

    foreach (configDatei; ["config.default.json", "config.neo.json",
                           "config.neoqwertz.json", "config.noted.json",
                           "config.annoted.json"]) {
        auto config = parseJSON(readText(configDatei));
        const string layoutName = config["standaloneLayout"].str;

        NeoLayout *layout;
        foreach (ref l; layouts) {
            if (l.name == layoutName.to!wstring) {
                layout = &l;
            }
        }
        assert(layout !is null,
            configDatei ~ ": Layout '" ~ layoutName ~ "' fehlt in layouts.json");

        foreach (trigger; parseLockTriggers(config["locks"])) {
            if (trigger.action != LockAction.SET_LOCK) continue;

            // Nichts physisch gehalten, kein Passthrough, kein Capslock-Tausch:
            // der Zustand, in dem eine Rastung allein wirken muss.
            uint ebene = determineLayer(layout.layers,
                                        (Modifier m) nothrow => false,
                                        trigger.lockSet,
                                        false,
                                        false);
            assert(ebene != 1,
                configDatei ~ ", Rastung '" ~ trigger.name ~ "': trifft keine Ebene "
                ~ "von " ~ layoutName ~ " und faellt auf Ebene 1 zurueck");
        }
    }
}

unittest {
    // Regression zu Paket 5a: Zeichen jenseits der BMP duerfen nicht auf ihre
    // hohe Surrogathaelfte verkuerzt werden. 𝔄 ist U+1D504, in UTF-16 also
    // D835 DD04 - vor der Korrektur kam hier nur D835 an, ohne jede Meldung.
    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestNichtBMP",
        "modifiers": {},
        "layers": [{"Shift": false}],
        "capslockableKeys": [],
        "map": {"10": [{"char": "𝔄"}]}
    }]`);
    initLayouts(json);

    auto key = layouts[0].map[Scancode(0x10, false)].layers[0];
    assert(key.keytype == NeoKeyType.CHAR);
    assert(key.chars.length == 2, "Surrogatpaar wurde verkuerzt");
    assert(key.chars[0] == 0xD835);
    assert(key.chars[1] == 0xDD04);

    // Das Label bleibt die vollstaendige Zeichenkette - es war schon vorher
    // korrekt, und genau daraus entstand der Widerspruch zwischen Anzeige
    // und Verhalten.
    assert(key.label == "\U0001D504");
}

unittest {
    // Der gewoehnliche Fall bleibt unveraendert: ein BMP-Zeichen ergibt genau
    // eine Codeeinheit.
    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestBMP",
        "modifiers": {},
        "layers": [{"Shift": false}, {"Shift": true}],
        "capslockableKeys": [],
        "map": {"10": [{"char": "a"}, {"char": "∀"}]}
    }]`);
    initLayouts(json);

    auto entry = layouts[0].map[Scancode(0x10, false)];
    assert(entry.layers[0].chars == "a"w);
    assert(entry.layers[1].chars == "∀"w);
}

unittest {
    // AnNoted ist die eigene, veroeffentlichbare Variante von Noted: gleiche
    // Struktur, eigener Inhalt auf der Leertaste - und es traegt den dllName.
    // Wer im Erweiterungsmodus gegen kbdnoted tippt, bekommt AnNoted.
    import std.json : parseJSON;
    import std.file : readText;
    import keysyms : parseKeysym;
    scope(exit) resetLayoutsForTest();

    initKeysyms(".");
    initLayouts(parseJSON(readText("layouts.json"))["layouts"]);

    NeoLayout* annoted;
    NeoLayout* noted;
    foreach (ref l; layouts) {
        if (l.name == "AnNoted"w) annoted = &l;
        if (l.name == "Noted"w) noted = &l;
    }
    assert(annoted !is null, "Layout 'AnNoted' fehlt in layouts.json");
    assert(noted !is null);

    assert(annoted.dllName == "kbdnoted.dll"w);
    assert(annoted.layers.length == 21,
        "AnNoted: Extra-Block (17-20) plus Modifikator-Ebene 21");

    // Leerzeichen-Hierarchie der Leertaste, Ebenen 3-7, Ebene 8 normal (VK).
    // Unsichtbare Zeichen stehen auch im Testcode nur als \uXXXX-Escape.
    auto leer = annoted.map[Scancode(0x39, false)];
    assert(leer.layers[2].chars == "\u00a0"w, "Ebene 3: geschuetztes Leerzeichen");
    assert(leer.layers[3].chars == "\u202f"w, "Ebene 4: schmales geschuetztes Leerzeichen");
    assert(leer.layers[4].chars == "\u2009"w, "Ebene 5: duennes Leerzeichen");
    assert(leer.layers[5].chars == "\u200a"w, "Ebene 6: Haarleerzeichen");
    assert(leer.layers[6].chars == "\u200b"w, "Ebene 7: ZWSP");
    assert(leer.layers[7].keytype == NeoKeyType.VKEY,
        "Ebene 8: normales Leerzeichen als Ausweg im gerasteten Mathe");
    assert(leer.layers[7].vkCode == VKEY.VK_SPACE,
        "Ebene 8: der VK-Eintrag muss VK_SPACE sein, nicht irgendein VK");

    // Die verdraengte Numpad-0 liegt auf w, Ebene 4
    auto wTaste = annoted.map[Scancode(0x31, false)];
    assert(wTaste.layers[3].keytype == NeoKeyType.VKEY, "w Ebene 4: KP_0");
    assert(wTaste.layers[3].vkCode == VKEY.VK_NUMPAD0,
        "w Ebene 4: der VK-Eintrag muss VK_NUMPAD0 sein, nicht irgendein VK");

    // Mathe-Basis unveraendert, Hoch-/Tiefstellung auf 7/8
    auto aTaste = annoted.map[Scancode(0x13, false)];
    assert(aTaste.layers[4].chars == "∀"w, "a Ebene 5: Allquantor bleibt");
    auto zweiTaste = annoted.map[Scancode(0x03, false)];
    assert(zweiTaste.layers[6].chars == "²"w, "2 Ebene 7: hochgestellt");
    assert(zweiTaste.layers[7].chars == "₂"w, "2 Ebene 8: tiefgestellt");
    auto nTaste = annoted.map[Scancode(0x25, false)];
    assert(nTaste.layers[6].chars == "ⁿ"w);
    assert(nTaste.layers[7].chars == "ₙ"w);

    // Die Compose-Praefixe sind in der Grammatikrunde von der ^-Taste auf die
    // Modifikator-Ebene 21 umgezogen: je Modifikator genau ein Ort. Die alten
    // Zellen sind seitdem leer, die Zeichen liegen auf H bzw. T.
    auto praefix = annoted.map[Scancode(0x29, false)];
    assert(praefix.layers[6].chars.length == 0);
    assert(praefix.layers[7].chars.length == 0);
    assert(annoted.map[Scancode(0x27, false)].layers[20].chars == "ˣ"w);
    assert(annoted.map[Scancode(0x24, false)].layers[20].chars == "ₓ"w);

    // Griechisch ist von 9/10 auf 13/14 umgezogen; 11/12 bleiben Reserve,
    // 9/10 traegt seit der Typografie-Runde deren Belegung (a ist dort
    // bewusst Reserve), 15/16 seit der Kyrillisch-Runde Russisch, 17-20
    // seit der Extra-Runde Symbole, Emoji und Obskures
    assert(aTaste.layers[12].chars == "α"w, "a Ebene 13: alpha");
    assert(aTaste.layers[13].chars == "Α"w, "a Ebene 14: Alpha");
    assert(aTaste.layers[8].chars.length == 0, "a Ebene 9 bleibt Reserve");

    // Typografie-Runde: Stichproben auf den Ebenen 9/10 im Buchstabenfeld
    // und auf der Zahlenreihe. Unsichtbares nur als \uXXXX-Escape.
    auto bTaste = annoted.map[Scancode(0x16, false)];
    assert(bTaste.layers[8].chars == "‐"w, "b Ebene 9: Divis U+2010");
    assert(bTaste.layers[9].chars == "‑"w, "b Ebene 10: geschuetzter Bindestrich U+2011");
    auto tTaste = annoted.map[Scancode(0x24, false)];
    assert(tTaste.layers[8].chars == "\u00ad"w, "t Ebene 9: weiches Trennzeichen");
    auto mTaste = annoted.map[Scancode(0x17, false)];
    assert(mTaste.layers[8].chars == "\u2003"w, "m Ebene 9: Geviert");
    auto jTaste = annoted.map[Scancode(0x1A, false)];
    assert(jTaste.layers[8].chars == "\u200c"w, "j Ebene 9: ZWNJ");
    assert(jTaste.layers[9].chars == "\u200d"w, "j Ebene 10: ZWJ");
    auto kommaTaste = annoted.map[Scancode(0x33, false)];
    assert(kommaTaste.layers[8].chars == "⟨"w, "Komma Ebene 9: Winkelklammer");
    assert(kommaTaste.layers[9].chars == "⟪"w, "Komma Ebene 10: doppelte Winkelklammer");
    assert(zweiTaste.layers[8].chars == "½"w, "2 Ebene 9: einhalb");
    auto vierTaste = annoted.map[Scancode(0x05, false)];
    assert(vierTaste.layers[8].chars == "¼"w, "4 Ebene 9: einviertel");
    assert(vierTaste.layers[9].chars == "¾"w, "4 Ebene 10: dreiviertel");
    assert(leer.layers[8].keytype == NeoKeyType.VKEY,
        "Leertaste Ebene 9: normales Leerzeichen, gerastete Typografie bleibt schreibtauglich");
    assert(aTaste.layers[10].chars.length == 0, "a Ebene 11 bleibt Reserve");

    // Kyrillisch-Runde: Russisch auf 15/16, phonetisch-mnemonisch wie
    // Griechisch. Kyrillische Buchstaben stehen literal (sichtbare Glyphen);
    // gegen lateinische Homoglyphen (а е о р с у х к) sichert die
    // Bereichs-Assertion am Ende dieses Abschnitts.
    assert(aTaste.layers[14].chars == "а"w, "a Ebene 15: a-kyrillisch U+0430");
    assert(aTaste.layers[15].chars == "А"w, "a Ebene 16: A-kyrillisch U+0410");
    assert(wTaste.layers[14].chars == "в"w, "w Ebene 15: we U+0432");
    auto xTaste = annoted.map[Scancode(0x2D, false)];
    assert(xTaste.layers[14].chars == "х"w, "x Ebene 15: cha U+0445");
    auto aeTaste = annoted.map[Scancode(0x2F, false)];
    assert(aeTaste.layers[14].chars == "э"w, "ae Ebene 15: e-oborotnoje U+044D");
    auto oeTaste = annoted.map[Scancode(0x30, false)];
    assert(oeTaste.layers[14].chars == "ё"w, "oe Ebene 15: jo U+0451");
    auto ueTaste = annoted.map[Scancode(0x2E, false)];
    assert(ueTaste.layers[14].chars == "ю"w, "ue Ebene 15: ju U+044E");
    auto qTaste = annoted.map[Scancode(0x14, false)];
    assert(qTaste.layers[14].chars == "я"w, "q Ebene 15: ja U+044F");
    assert(qTaste.layers[15].chars == "Я"w, "q Ebene 16: Ja U+042F");
    auto vTaste = annoted.map[Scancode(0x2C, false)];
    assert(vTaste.layers[14].chars == "ж"w, "v Ebene 15: sche U+0436");
    auto hTaste = annoted.map[Scancode(0x27, false)];
    assert(hTaste.layers[14].chars == "ч"w, "h Ebene 15: tsche U+0447");
    auto eszettTaste = annoted.map[Scancode(0x1B, false)];
    assert(eszettTaste.layers[14].chars == "ш"w, "sz Ebene 15: scha U+0448");
    assert(praefix.layers[14].chars == "щ"w, "Zirkumflex-Position Ebene 15: schtscha U+0449");
    auto gravisTaste = annoted.map[Scancode(0x0D, false)];
    assert(gravisTaste.layers[14].chars == "ъ"w, "Gravis-Position Ebene 15: Haertezeichen U+044A");
    auto akutTaste = annoted.map[Scancode(0x2B, false)];
    assert(akutTaste.layers[14].chars == "ь"w, "Akut-Position Ebene 15: Weichheitszeichen U+044C");
    assert(akutTaste.layers[15].chars == "Ь"w, "Akut-Position Ebene 16: grosses Weichheitszeichen U+042C");
    assert(zweiTaste.layers[14].chars == "2"w, "2 Ebene 15: Ziffer bleibt");
    assert(zweiTaste.layers[15].chars == "2"w, "2 Ebene 16: Ziffer bleibt");
    assert(kommaTaste.layers[14].chars == ","w, "Komma Ebene 15: echtes Komma");
    assert(leer.layers[14].keytype == NeoKeyType.VKEY,
        "Leertaste Ebene 15: normales Leerzeichen, gerastetes Kyrillisch bleibt schreibtauglich");
    assert(leer.layers[14].vkCode == VKEY.VK_SPACE, "Leertaste Ebene 15: VK_SPACE");

    // Homoglyphen-Haertung: Jeder der 33 Buchstaben muss auf beiden Ebenen
    // ein einzelnes Zeichen im Unicode-Block Kyrillisch tragen. Ein
    // versehentlich lateinisch getipptes a/e/o/p/c/y/x/k faellt damit
    // maschinell auf, obwohl es im Schriftbild unsichtbar ist.
    import std.format : format;
    static immutable ubyte[33] kyrillischTasten = [
        0x13, 0x16, 0x31, 0x32, 0x23, 0x21, 0x30, 0x2C, 0x10, 0x20, 0x1A,
        0x35, 0x18, 0x17, 0x25, 0x22, 0x15, 0x26, 0x1F, 0x24, 0x12, 0x19,
        0x2D, 0x1E, 0x27, 0x1B, 0x29, 0x0D, 0x11, 0x2B, 0x2F, 0x2E, 0x14];
    foreach (sc; kyrillischTasten) {
        foreach (ebene; 14 .. 16) {
            auto taste = annoted.map[Scancode(sc, false)].layers[ebene];
            assert(taste.chars.length == 1,
                format("Scancode %02X Ebene %d: genau ein Zeichen erwartet", sc, ebene + 1));
            assert(taste.chars[0] >= 0x0400 && taste.chars[0] <= 0x04FF,
                format("Scancode %02X Ebene %d: U+%04X liegt nicht im Kyrillisch-Block",
                    sc, ebene + 1, cast(uint) taste.chars[0]));
        }
    }

    // Extra-Runde: der Extra-Block hat vier Ebenen - 17 Symbol-Zonen,
    // 18 die +Shift-Variante (gefuellt/doppelt/schwer), 19 Emoji (+Mod3),
    // 20 Wuerfel/Alchemie/Technik (+Mod4). Sichtbare Glyphen stehen literal;
    // der einzige Escape ist der unsichtbare Variation Selector U+FE0F.
    // Zahlenreihe: Kreiszahlen, 1-9 arithmetisch, die Null als Sonderfall
    foreach (i; 0 .. 9) {
        auto ziffernTaste = annoted.map[Scancode(cast(ubyte)(0x02 + i), false)];
        assert(ziffernTaste.layers[16].chars == [cast(wchar)(0x2460 + i)],
            format("Zahlenreihe %d Ebene 17: Kreiszahl U+%04X", i + 1, 0x2460 + i));
        assert(ziffernTaste.layers[17].chars == [cast(wchar)(0x2776 + i)],
            format("Zahlenreihe %d Ebene 18: gefuellte Kreiszahl U+%04X", i + 1, 0x2776 + i));
    }
    auto nullTaste = annoted.map[Scancode(0x0B, false)];
    assert(nullTaste.layers[16].chars == "⓪"w, "0 Ebene 17: Kreis-Null U+24EA");
    assert(nullTaste.layers[17].chars == "⓿"w, "0 Ebene 18: gefuellte Kreis-Null U+24FF");
    // Pfeile: Shift = Doppelpfeil
    auto zTaste = annoted.map[Scancode(0x10, false)];
    assert(zTaste.layers[16].chars == "←"w, "z Ebene 17: Linkspfeil U+2190");
    assert(zTaste.layers[17].chars == "⇐"w, "z Ebene 18: Doppelpfeil U+21D0");
    assert(aTaste.layers[16].chars == "→"w, "a Ebene 17: Rechtspfeil U+2192");
    // Spiele: die vier mnemonischen Anker Dame/Turm/Springer/Herz
    auto dTaste = annoted.map[Scancode(0x23, false)];
    assert(dTaste.layers[16].chars == "♕"w, "d Ebene 17: weisse Dame U+2655");
    assert(dTaste.layers[17].chars == "♛"w, "d Ebene 18: schwarze Dame U+265B");
    assert(tTaste.layers[16].chars == "♖"w, "t Ebene 17: weisser Turm U+2656");
    auto sTaste = annoted.map[Scancode(0x1F, false)];
    assert(sTaste.layers[16].chars == "♘"w, "s Ebene 17: weisser Springer U+2658");
    assert(hTaste.layers[16].chars == "♡"w, "h Ebene 17: hohles Herz U+2661");
    assert(hTaste.layers[17].chars == "♥"w, "h Ebene 18: gefuelltes Herz U+2665");
    // Musik
    assert(ueTaste.layers[16].chars == "♭"w, "ue Ebene 17: b U+266D");
    assert(ueTaste.layers[17].chars == "𝄫"w, "ue Ebene 18: Doppel-b U+1D12B (Surrogatpaar)");
    assert(oeTaste.layers[16].chars == "♮"w, "oe Ebene 17: Aufloesungszeichen U+266E");
    assert(oeTaste.layers[17].chars.length == 0, "oe Ebene 18 bleibt bewusst leer");
    assert(xTaste.layers[16].chars == "♫"w, "x Ebene 17: Balkennoten U+266B");
    // Alltag
    assert(gravisTaste.layers[16].chars == "✓"w, "Gravis-Position Ebene 17: Haken U+2713");
    assert(gravisTaste.layers[17].chars == "✔"w, "Gravis-Position Ebene 18: schwerer Haken U+2714");
    assert(kommaTaste.layers[16].chars == "□"w, "Komma Ebene 17: hohles Quadrat U+25A1");
    assert(praefix.layers[16].chars == "⚠"w, "Zirkumflex-Position Ebene 17: Warnzeichen U+26A0");
    // Ebene 19: Emoji, ein Zeichen je Taste, ohne Shift-Partner
    auto lTaste = annoted.map[Scancode(0x18, false)];
    assert(lTaste.layers[18].chars == "😂"w, "l Ebene 19: Lach-Emoji U+1F602");
    assert(lTaste.layers[18].chars.length == 2, "l Ebene 19: Surrogatpaar, nicht verkuerzt");
    assert(hTaste.layers[18].chars == "❤\uFE0F"w, "h Ebene 19: Herz mit Variation Selector");
    assert(hTaste.layers[18].chars.length == 2, "h Ebene 19: U+2764 plus U+FE0F, beide BMP");
    assert(hTaste.layers[18].label == "❤", "h Ebene 19: Beschriftung ohne den Selector");
    assert(vTaste.layers[18].chars == "✌\uFE0F"w, "v Ebene 19: Victory mit Variation Selector");
    assert(vTaste.layers[18].chars.length == 2, "v Ebene 19: U+270C plus U+FE0F, beide BMP");
    assert(vTaste.layers[18].label == "✌", "v Ebene 19: Beschriftung ohne den Selector");
    auto kTaste = annoted.map[Scancode(0x35, false)];
    assert(kTaste.layers[18].chars == "☕"w, "k Ebene 19: Kaffee U+2615");
    auto cTaste = annoted.map[Scancode(0x1E, false)];
    assert(cTaste.layers[18].chars.length == 0, "c Ebene 19 bleibt Reserve");
    // Ebene 20: Wuerfel auf der Zahlenreihe, Alchemie/Domino/Technik im Feld
    auto dreiTaste = annoted.map[Scancode(0x04, false)];
    assert(dreiTaste.layers[19].chars == "⚂"w, "3 Ebene 20: Wuerfel-Drei U+2682");
    auto fTaste = annoted.map[Scancode(0x19, false)];
    assert(fTaste.layers[19].chars == "🜂"w, "f Ebene 20: Alchemie-Feuer U+1F702");
    assert(qTaste.layers[19].chars == "☿"w, "q Ebene 20: Quecksilber U+263F");
    auto rTaste = annoted.map[Scancode(0x26, false)];
    assert(rTaste.layers[19].chars == "⏎"w, "r Ebene 20: Return-Zeichen U+23CE");
    assert(dTaste.layers[19].chars == "🁣"w, "d Ebene 20: Domino U+1F063");
    // Leertaste und Kopienregel auf den neuen Ebenen
    assert(leer.layers[16].keytype == NeoKeyType.VKEY && leer.layers[16].vkCode == VKEY.VK_SPACE,
        "Leertaste Ebene 17: VK_SPACE");
    assert(leer.layers[17].keytype == NeoKeyType.VKEY && leer.layers[17].vkCode == VKEY.VK_SPACE,
        "Leertaste Ebene 18: VK_SPACE");
    assert(leer.layers[18].keytype == NeoKeyType.VKEY && leer.layers[18].vkCode == VKEY.VK_SPACE,
        "Leertaste Ebene 19: VK_SPACE");
    assert(leer.layers[19].keytype == NeoKeyType.VKEY && leer.layers[19].vkCode == VKEY.VK_SPACE,
        "Leertaste Ebene 20: VK_SPACE");
    auto kpSieben = annoted.map[Scancode(0x47, false)];
    assert(kpSieben.layers[18].keytype == NeoKeyType.VKEY && kpSieben.layers[18].vkCode == VKEY.VK_NUMPAD7,
        "KP_7 Ebene 19: Ebene-1-Kopie");
    assert(kpSieben.layers[19].keytype == NeoKeyType.VKEY && kpSieben.layers[19].vkCode == VKEY.VK_NUMPAD7,
        "KP_7 Ebene 20: Ebene-1-Kopie");

    // Noted ist seit Paket 7 auf den veroeffentlichten 6-Ebenen-Originalstand
    // zurueckgebaut. Der Befund char U+0020 gegen keysym U200A auf Ebene 3
    // der Leertaste stammt entgegen der urspruenglichen Annahme nicht aus
    // diesem Originalstand: er wurde erst durch den 14-Ebenen-Ausbau
    // (e6cf7fb) eingefuehrt - vor Paket 2 (843fd04, 0f642a6) tragen char und
    // keysym uebereinstimmend das Haarleerzeichen U+200A. Der Rueckbau
    // bereinigt den Befund also, statt ihn zu konservieren.
    assert(noted.layers.length == 6);
    auto notedLeer = noted.map[Scancode(0x39, false)];
    assert(notedLeer.layers[2].chars == "\u200a"w);

    // Die vier Compose-Startzeichen, die Paket 7 beim Neubelegen der Ebenen
    // 5/6 ausgelassen hatte. Sie liegen seit der Ausduennungsrunde auf den
    // Reserve-Ebenen 11/12 des Typografieblocks, auf denselben physischen
    // Tasten wie zuvor. Ohne sie liessen sich 412 Compose-Sequenzen in
    // AnNoted gar nicht beginnen.
    // Der IPA-Haken hat 29/11 in der Grammatikrunde verlassen und liegt jetzt
    // als Modifikator auf Ebene 21 der R-Taste; die Tottasten daneben bleiben.
    assert(annoted.map[Scancode(0x29, false)].layers[10].chars.length == 0,
        "AnNoted 29/11: geraeumt, der Haken liegt auf Ebene 21");
    assert(annoted.map[Scancode(0x26, false)].layers[20].keysym == parseKeysym("U02DE"),
        "AnNoted 26/21: IPA-Haken U+02DE fehlt");
    assert(annoted.map[Scancode(0x26, false)].layers[20].chars == "\u02de"w);
    assert(annoted.map[Scancode(0x29, false)].layers[11].keysym == parseKeysym("dead_belowdot"),
        "AnNoted 29/12: dead_belowdot fehlt");
    assert(annoted.map[Scancode(0x29, false)].layers[11].chars == "."w);
    assert(annoted.map[Scancode(0x0D, false)].layers[11].keysym == parseKeysym("dead_macron"),
        "AnNoted 0D/12: dead_macron fehlt");
    assert(annoted.map[Scancode(0x0D, false)].layers[11].chars == "¯"w);
    assert(annoted.map[Scancode(0x2B, false)].layers[11].keysym == parseKeysym("dead_breve"),
        "AnNoted 2B/12: dead_breve fehlt");
    assert(annoted.map[Scancode(0x2B, false)].layers[11].chars == "˘"w);

    // Zwei Zellen der Mathematik-Ebene tragen bewusst den X11-Namen, nicht die
    // Offset-Form: Die Compose-Module benutzen als Zwischentaste <radical> und
    // <logicalor>, und ein Keysym-Vergleich geht ueber den Wert, nicht ueber
    // das Zeichen. Standen dort U221A/U2228, war das Zeichen zwar auf der
    // Taste, der Compose-Zweig aber tot - gemessen am 08.08.2026, 13 Blaetter
    // (docs/superpowers/specs/2026-08-08-untippbare-blaetter-messung.md).
    // Deshalb keysym UND char, wie bei den Tottasten oben.
    assert(annoted.map[Scancode(0x2C, false)].layers[4].keysym == parseKeysym("radical"),
        "AnNoted 2C/5: Wurzelzeichen muss <radical> heissen, nicht U221A");
    assert(annoted.map[Scancode(0x2C, false)].layers[4].chars == "√"w);
    assert(annoted.map[Scancode(0x22, false)].layers[4].keysym == parseKeysym("logicalor"),
        "AnNoted 22/5: Oder-Zeichen muss <logicalor> heissen, nicht U2228");
    assert(annoted.map[Scancode(0x22, false)].layers[4].chars == "∨"w);

    // ∧ und ∥ sind am 09.08.2026 dazugekommen - sie standen in keiner Zelle,
    // obwohl math.module sie als Zwischentaste benutzt. Platz ist die freie
    // Logik-Ecke neben der Junktoren-Taste x (⊻/⊼); die systematisch richtige
    // Stelle fuer ∧ waere a gewesen, dort liegt aber ∀.
    // Die Schreibweise ist je Zeichen verschieden und darf es nicht sein:
    // <logicaland> gibt es in keysymdef.h, einen Namen fuer ∥ nicht - die
    // Module benutzen dort <U2225>. Beides keysym UND char, wie oben.
    assert(annoted.map[Scancode(0x2E, false)].layers[4].keysym == parseKeysym("logicaland"),
        "AnNoted 2E/5: Und-Zeichen fehlt oder heisst falsch");
    assert(annoted.map[Scancode(0x2E, false)].layers[4].chars == "∧"w);
    assert(annoted.map[Scancode(0x2F, false)].layers[4].keysym == parseKeysym("U2225"),
        "AnNoted 2F/5: Parallel-Zeichen fehlt oder heisst falsch");
    assert(annoted.map[Scancode(0x2F, false)].layers[4].chars == "∥"w);
    // ∦ haengt an keinem Compose-Zweig - es steht als Ebene-6-Partner da,
    // wie ∤ ueber ∣ auf der t-Taste.
    assert(annoted.map[Scancode(0x2F, false)].layers[5].keysym == parseKeysym("U2226"),
        "AnNoted 2F/6: Nicht-parallel fehlt");
    assert(annoted.map[Scancode(0x2F, false)].layers[5].chars == "∦"w);

    // ⚥ ist am 10.08.2026 dazugekommen und ist derselbe Fall wie ∧ und ∥, nur
    // der letzte: Neo, NeoQwertz und Noted fuehren es auf 07/5 neben ♀ und ♂,
    // beim Umbau auf 21 Ebenen ist es als einziges Zeichen der drei Layouts
    // ohne Platz geblieben. base.module:317 benutzt es als Zwischentaste
    // (<dead_stroke> ⚥ -> ⚧), und ⚧ hat keine zweite Sequenz - das Blatt war
    // ersatzlos untippbar. Platz ist 32/11: dieselbe Taste wie ♀ (32/9) und
    // ♂ (32/10), derselbe Typografieblock, eine Modifier-Stufe weiter.
    // Wieder keysym UND char, aus demselben Grund wie bei den Tottasten.
    assert(annoted.map[Scancode(0x32, false)].layers[8].chars == "♀"w,
        "AnNoted 32/9: ♀ ist der Anker fuer die Zelle darunter");
    assert(annoted.map[Scancode(0x32, false)].layers[9].chars == "♂"w,
        "AnNoted 32/10: ♂ ist der Anker fuer die Zelle darunter");
    assert(annoted.map[Scancode(0x32, false)].layers[10].keysym == parseKeysym("U26A5"),
        "AnNoted 32/11: ⚥ fehlt oder heisst falsch");
    assert(annoted.map[Scancode(0x32, false)].layers[10].chars == "⚥"w);
}

unittest {
    // Je dllName hoechstens ein Layout: Die Erweiterungsmodus-Erkennung in
    // app.d waehlt das Layout allein ueber den dllName, und bei Duplikaten
    // gewinnt stillschweigend das letzte in der Datei. Das darf nie implizit
    // passieren - wer einen dllName doppelt vergibt, soll hier anschlagen.
    import std.json : parseJSON;
    import std.file : readText;

    auto json = parseJSON(readText("layouts.json"));
    bool[string] gesehen;
    foreach (l; json["layouts"].array) {
        if ("dllName" !in l) continue;
        string dll = l["dllName"].str;
        assert(dll !in gesehen, "dllName '" ~ dll ~ "' ist doppelt vergeben");
        gesehen[dll] = true;
    }
}

unittest {
    // Ebene 21 traegt die sechs Compose-Modifikatoren auf der Grundreihe, jeder
    // auf dem Anfangsbuchstaben seiner Kategorie. Geprueft werden char UND
    // keysym: Eine Zelle ohne "char" stuft describeKey (keyboardview.d:140) als
    // EMPTY ein und sie waere auf Blatt und Bildschirmtastatur unsichtbar -
    // genau der Fund aus der Ausduennungsrunde.
    import std.json : parseJSON;
    import std.file : readText;
    import keysyms : parseKeysym;
    scope(exit) resetLayoutsForTest();

    initKeysyms(".");
    initLayouts(parseJSON(readText("layouts.json"))["layouts"]);

    NeoLayout* an;
    foreach (ref l; layouts) {
        if (l.name == "AnNoted"w) an = &l;
    }
    assert(an !is null);
    assert(an.layers.length == 21, "AnNoted hat 21 Ebenen");
    assert(an.layerIgnoresLocks[20], "Ebene 21 nimmt sich von der Rastung aus");

    struct Erwartung { string scancode; wstring zeichen; string keysym; }
    immutable Erwartung[] modifikatoren = [
        Erwartung("1F", "𝔵"w, "U1D535"),   // S - Schriftvariante
        Erwartung("21", "ⓧ"w, "U24E7"),    // E - Einkreisung
        Erwartung("23", "↻"w, "U21BB"),    // D - Drehung
        Erwartung("24", "ₓ"w, "U2093"),    // T - Tiefstellung
        Erwartung("26", "˞"w, "U02DE"),    // R - Retroflex/Haken
        Erwartung("27", "ˣ"w, "U02E3"),    // H - Hochstellung
    ];

    foreach (e; modifikatoren) {
        auto taste = an.map[parseScancode(e.scancode)].layers[20];
        assert(taste.chars == e.zeichen, "Ebene 21, Scancode " ~ e.scancode);
        assert(taste.keysym == parseKeysym(e.keysym),
            "Keysym auf Ebene 21, Scancode " ~ e.scancode);
    }
}

unittest {
    // Nach dem Umzug auf Ebene 21 gibt es je Modifikator genau einen Ort. Die
    // vier alten Zellen der ^-Taste sind leer, die Tottasten daneben bleiben.
    // Eine leere Zelle traegt VK_VOID (0xFF), nicht 0 - parseNeoKey setzt das.
    import std.json : parseJSON;
    import std.file : readText;
    import keysyms : parseKeysym;
    scope(exit) resetLayoutsForTest();

    initKeysyms(".");
    initLayouts(parseJSON(readText("layouts.json"))["layouts"]);

    NeoLayout* an;
    foreach (ref l; layouts) {
        if (l.name == "AnNoted"w) an = &l;
    }
    assert(an !is null);
    auto caret = an.map[parseScancode("29")].layers;

    foreach (ebene; [3, 7, 8, 11]) {
        auto k = caret[ebene - 1];
        assert(k.chars.length == 0 && k.vkCode == VKEY.VK_VOID,
            "Ebene " ~ ebene.to!string ~ " der ^-Taste ist geraeumt");
    }

    // Tottasten bleiben, wo sie sind - sie gehoeren nicht zum Alphabet.
    assert(caret[11].keysym == parseKeysym("dead_belowdot"));
    assert(an.map[parseScancode("0D")].layers[11].keysym == parseKeysym("dead_macron"));
    assert(an.map[parseScancode("2B")].layers[11].keysym == parseKeysym("dead_breve"));

    // Die einzige Symbolzelle mit Compose-Wurzelzeichen ist entschaerft.
    auto j = an.map[parseScancode("1A")].layers;
    assert(j[16].chars == "⟲"w && j[16].keysym == parseKeysym("U27F2"));
    assert(j[17].chars == "⟳"w && j[17].keysym == parseKeysym("U27F3"));

    // Untere Mathematik-Reihe: um eins nach links, auf beiden Ebenen.
    struct Zelle { string sc; wstring e5; wstring e6; }
    immutable Zelle[] reihe = [
        Zelle("30", "∼"w, "≃"w), Zelle("31", "∠"w, "∡"w), Zelle("32", "⇐"w, "⟸"w),
        Zelle("33", "⇔"w, "⟺"w), Zelle("34", "⇒"w, "⟹"w),
    ];
    foreach (z; reihe) {
        auto k = an.map[parseScancode(z.sc)].layers;
        assert(k[4].chars == z.e5, "Ebene 5, Scancode " ~ z.sc);
        assert(k[5].chars == z.e6, "Ebene 6, Scancode " ~ z.sc);
    }

    // Die frei gewordene K-Taste traegt das doppelt gestrichene K.
    auto kTaste = an.map[parseScancode("35")].layers;
    assert(kTaste[4].chars.length == 0 && kTaste[4].vkCode == VKEY.VK_VOID,
        "Ebene 5 der K-Taste ist frei");
    assert(kTaste[5].chars == "\U0001D542"w,
        "Ebene 6 der K-Taste traegt das doppelt gestrichene K");
    assert(kTaste[5].keysym == parseKeysym("U1D542"));
}

unittest {
    // "ignoreLocks" ist keine Modifier-Angabe: Es muss beim Parsen erkannt und
    // aus der Modifierkarte herausgehalten werden - parseModifier wuerfe sonst.
    import std.json : parseJSON;

    auto json = parseJSON(`[{
        "name": "Fixture", "modifiers": {},
        "layers": [
            {"Shift": false, "Mod3": false, "Mod4": false},
            {"Mod3": true, "Mod4": true, "ignoreLocks": true}
        ],
        "map": { "10": [{"char": "a"}, {"char": "b"}] },
        "capslockableKeys": []
    }]`);

    initLayouts(json);
    scope(exit) resetLayoutsForTest();

    auto l = layouts[0];
    assert(l.layers.length == 2);
    assert(l.layerIgnoresLocks == [false, true]);
    assert(Modifier.MOD3 in l.layers[1] && l.layers[1][Modifier.MOD3]);
    foreach (mod; l.layers[1].byKey) {
        assert(mod == Modifier.MOD3 || mod == Modifier.MOD4,
            "ignoreLocks darf nicht als Modifier in der Karte landen");
    }
}
