module keysyms;

import std.conv;
import std.path;
import std.regex;
import std.stdio;

import debuglog;

// X11-Keysyms, zur Laufzeit aus keysymdef.h geparst. Eigenes Modul, damit
// mapping.d und composer.d nicht das Anwendungsmodul ananeo.d brauchen.

/// Keysym fuer "keine Taste". Wohnte bis Paket 5a in mapping.d, gehoert aber
/// hierher - sonst braeuchte dieses Modul eine Rueckabhaengigkeit dorthin.
const uint KEYSYM_VOID = 0xFFFFFF;

uint[string] keysymsByName;
uint[uint] keysymsByCodepoint;
uint[uint] codepointsByKeysym;
const KEYSYM_CODEPOINT_OFFSET = 0x01000000;

// Initializes list of keysyms by a given keysymdef.h from X.org project,
// see https://cgit.freedesktop.org/xorg/proto/x11proto/tree/keysymdef.h
void initKeysyms(string exeDir) {
    auto keysymfile = buildPath(exeDir, "keysymdef.h");
    debugWriteln("Initializing keysyms from ", keysymfile);
    // group 1: name, group 2: hex, group 3: unicode codepoint
    auto unicodePattern = r"^\#define XK_([a-zA-Z_0-9]+)\s+0x([0-9a-fA-F]+)\s*\/\*[ \(]U\+([0-9a-fA-F]{4,6}) (.*)[ \)]\*\/\s*$";
    // group 1: name, group 2: hex, group 3 and 4: comment stuff
    auto noUnicodePattern = r"^\#define XK_([a-zA-Z_0-9]+)\s+0x([0-9a-fA-F]+)\s*(\/\*\s*(.*)\s*\*\/)?\s*$";
    keysymsByName.clear();
    keysymsByCodepoint.clear();
    codepointsByKeysym.clear();

    File f = File(keysymfile, "r");
	while(!f.eof()) {
		string l = f.readln();
        try {
            if (auto m = matchFirst(l, unicodePattern)) {
                string keysymName = m[1];
                uint keyCode = to!uint(m[2], 16);
                uint codepoint = to!uint(m[3], 16);
                keysymsByName[keysymName] = keyCode;
                keysymsByCodepoint[codepoint] = keyCode;
                // for quick reverse search
                codepointsByKeysym[keyCode] = codepoint;
            } else if (auto m = matchFirst(l, noUnicodePattern)) {
                string keysymName = m[1];
                uint keyCode = to!uint(m[2], 16);
                keysymsByName[keysymName] = keyCode;
            }
        } catch (Exception e) {
            debugWriteln("Could not parse line '", l, "', skipping. Error: ", e.msg);
        }
	}
}

auto UNICODE_REGEX = regex(r"^U([0-9a-fA-F]+)$");

// Parse a string by a lookup in the initialized keysym tables, either by name
// or by codepoint. The latter works also for algorithmically defined strings
// in the form "U00A0" to "U10FFFF" which represent any possible Unicode
// character as hex value.
uint parseKeysym(string keysymStr) {
    if (uint *keysym = keysymStr in keysymsByName) {
        // The corresponding keysym is explicitly defined by the given name
        return *keysym;
    } else if (auto m = matchFirst(keysymStr, UNICODE_REGEX)) {
        uint codepoint = to!uint(m[1], 16);

        // Legacy keysyms for some Unicode values between 0x0100 and 0x30FF
        if (codepoint <= 0x30FF) {
            if (uint *keysym = codepoint in keysymsByCodepoint) {
                // If defined, return the legacy keysym value
                return *keysym;
            }
        }

        // Otherwise just return the keysym matching the codepoint with an offset
        return codepoint + KEYSYM_CODEPOINT_OFFSET;
    }

    debugWriteln("Keysym ", keysymStr, " not found.");

    return KEYSYM_VOID;
}

unittest {
    // parseKeysym ohne geladene Tabellen: benannte Keysyms sind unbekannt,
    // U-Schreibweisen funktionieren trotzdem ueber den Offset.
    // Andere Module (mapping.d, composer.d) laden in ihren Tests initKeysyms(".")
    // und raeumen nicht immer ab - fuer Reihenfolge-Unabhaengigkeit hier leeren.
    keysymsByName.clear();
    keysymsByCodepoint.clear();
    codepointsByKeysym.clear();

    assert(parseKeysym("Multi_key") == KEYSYM_VOID);
    assert(parseKeysym("U1D56C") == 0x1D56C + KEYSYM_CODEPOINT_OFFSET);
    assert(parseKeysym("U2200") == 0x2200 + KEYSYM_CODEPOINT_OFFSET);

    // Voelliger Unsinn ergibt KEYSYM_VOID, keine Exception
    assert(parseKeysym("kein_keysym_dieser_welt") == KEYSYM_VOID);
    assert(parseKeysym("") == KEYSYM_VOID);
}

unittest {
    // Mit geladenen Tabellen greift die Legacy-Zuordnung unterhalb 0x3100:
    // fuer diese Codepunkte gewinnt der alte Keysym-Wert gegen den Offset.
    keysymsByName["Multi_key"] = 0xFF20;
    keysymsByCodepoint[0x00E4] = 0x00E4;
    scope(exit) { keysymsByName.clear(); keysymsByCodepoint.clear(); }

    assert(parseKeysym("Multi_key") == 0xFF20);
    assert(parseKeysym("U00E4") == 0x00E4);

    // Oberhalb 0x30FF gilt immer der Offset, auch wenn ein Eintrag existierte
    assert(parseKeysym("U1D56C") == 0x1D56C + KEYSYM_CODEPOINT_OFFSET);
}
