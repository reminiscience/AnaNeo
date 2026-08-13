module fontchain;

import core.sys.windows.windows;

import std.utf : toUTF16z;
import std.file : exists, read;
import std.path : buildPath;

import cairo;
import cairo_win32;
import cmap;
import debuglog;

// Glyphbeschaffung fuer die Bildschirmtastatur.
//
// Warum nicht cairo_show_text: Cairos Win32-Pfad bildet Zeichen auf Glyphen
// ueber dieselbe Codeeinheiten-Zuordnung ab wie GetGlyphIndices und scheitert
// damit an Surrogatpaaren - ein Zeichen jenseits der BMP wird als seine hohe
// Haelfte nachgeschlagen und landet im Tofu-Kasten.
//
// Warum nicht GDI (ExtTextOutW): Das OSK-Fenster ist ein Layered Window und
// wird ueber UpdateLayeredWindow mit ULW_ALPHA gezeichnet. GDI schreibt den
// Alphakanal nicht; der Text waere unsichtbar oder zerfressen. Cairo rastert
// selbst und schreibt Alpha korrekt.
//
// Also: Glyph-Indizes selbst besorgen und an cairo_show_glyphs geben. Anfangs
// per Uniscribe (ScriptGetCMap), das nimmt einen UTF-16-String MIT Laenge und
// kann deshalb Surrogatpaare. Gemessen am 31.07.2026 (siehe Nachtrag zu
// Task 2) liefert ScriptGetCMap fuer Zeichen jenseits der BMP aber in KEINER
// der zehn gemessenen Schriften einen echten Glyphen, nur den Leerglyphen -
// die cmap-Tabelle derselben Schriften fuehrt den Glyphen sehr wohl. Deshalb
// liest cmap.d die Tabelle jetzt selbst, ohne Uniscribe.

/// Mitgeliefert, weil keine Windows-Schrift Schach (U+1FA00-1FA6F, Unicode 12)
/// und Alchemie (U+1F700-1F77F) kennt. Wird privat in den Prozess geladen -
/// ohne Installation, ohne Eingriff in die Schriftenliste des Nutzers.
/// Lizenz: SIL Open Font License 1.1, Text in fonts/OFL.txt.
enum BUNDLED_FONT_NAME = "Noto Sans Symbols 2";
enum BUNDLED_FONT_FILE = "NotoSansSymbols2-Regular.ttf";

/// Fuer den Notnagel (Codepunkt statt Glyph), nicht Teil der Abdeckungskette.
enum FALLBACK_MONO_FONT = "Consolas";

/// Gemessen am 31.07.2026 auf dem Zielrechner ueber
/// GlyphTypeface.CharacterToGlyphMap: 217 Familien mit Treffern, gierig
/// ausgewaehlt. Segoe UI steht bewusst VOR Segoe UI Symbol, obwohl es weniger
/// abdeckt - die gierige Auswahl optimiert Abdeckung, nicht Lesbarkeit.
immutable string[] FONT_CHAIN = [
    "Segoe UI",
    "Segoe UI Symbol",
    "Microsoft Sans Serif",
    "Malgun Gothic",
    "Yu Gothic UI",
    "Nirmala UI",
    "Microsoft Himalaya",
    "Myanmar Text",
    BUNDLED_FONT_NAME
];

private HFONT[] winFonts;
private cairo_font_face_t*[] cairoFonts;
private CmapTable[] fontCmaps;

/// Ergebnis eines Nachschlags: welche Schrift traegt den Text, und mit welchen
/// Glyphen.
struct GlyphLookup {
    /// Index in FONT_CHAIN - nur gueltig, wenn found
    size_t fontIndex;
    /// ein Eintrag je Codepunkt, Surrogatpaare zusammengefasst
    WORD[] glyphs;
    /// false: keine Schrift der Kette deckt den Text vollstaendig ab
    bool found;
}

// Die Schriftdaten bleiben absichtlich am Leben: Ob GDI den Speicher kopiert,
// ist nicht garantiert dokumentiert, und der GC gaebe ihn sonst frei.
private ubyte[] schriftDaten;
private HANDLE schriftHandle;

/// GDI-Tag der cmap-Tabelle. GetFontData erwartet die vier Zeichen in der
/// Byte-Reihenfolge des Rechners, "cmap" wird damit zu 0x70616D63.
private enum DWORD TAG_CMAP = 0x70616D63;

void initFontChain(string executableDir) {
    winFonts = [];
    cairoFonts = [];
    fontCmaps = [];

    ladeMitgelieferteSchrift(executableDir);

    auto hdc = GetDC(null);
    scope(exit) ReleaseDC(null, hdc);

    // Die Kette plus die Mono-Schrift fuer den Notnagel. Letztere haengt hinten
    // an und ist deshalb ueber monoFontIndex() erreichbar, ohne die Abdeckung
    // zu beeinflussen.
    foreach (name; FONT_CHAIN ~ [FALLBACK_MONO_FONT]) {
        // DEFAULT_CHARSET statt ANSI_CHARSET: Bei ANSI_CHARSET setzt Windows
        // stillschweigend eine andere Schrift ein, wenn die verlangte den
        // ANSI-Zeichensatz nicht fuehrt - man prueft dann die Abdeckung einer
        // Schrift, die man gar nicht angefordert hat.
        auto hFont = CreateFont(0, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, DEFAULT_PITCH,
            name.toUTF16z);
        winFonts ~= hFont;
        cairoFonts ~= cairo_win32_font_face_create_for_hfont(hFont);
        fontCmaps ~= leseCmap(hdc, hFont, name);
    }
}

/// Index der Mono-Schrift fuer den Notnagel.
size_t monoFontIndex() {
    return FONT_CHAIN.length;
}

private CmapTable leseCmap(HDC hdc, HFONT schrift, string name) {
    SelectObject(hdc, schrift);

    auto groesse = GetFontData(hdc, TAG_CMAP, 0, null, 0);
    if (groesse == GDI_ERROR || groesse == 0) {
        debugWriteln("Schrift '", name, "': keine cmap-Tabelle - Zeichen dieser Schrift ",
                     "werden nicht gefunden.");
        return CmapTable.init;
    }

    auto puffer = new ubyte[groesse];
    if (GetFontData(hdc, TAG_CMAP, 0, puffer.ptr, groesse) == GDI_ERROR) {
        debugWriteln("Schrift '", name, "': cmap-Tabelle nicht lesbar.");
        return CmapTable.init;
    }

    auto tabelle = parseCmap(puffer);
    if (!tabelle.valid) {
        debugWriteln("Schrift '", name, "': cmap-Tabelle in keinem bekannten Format ",
                     "(erwartet werden Format 12 oder 4).");
    }
    return tabelle;
}

private void ladeMitgelieferteSchrift(string executableDir) {
    auto pfad = buildPath(executableDir, "fonts", BUNDLED_FONT_FILE);

    if (!exists(pfad)) {
        debugWriteln("Schriftdatei ", pfad, " fehlt - Schach und Alchemie bleiben ohne Glyphen.");
        return;
    }

    try {
        schriftDaten = cast(ubyte[]) read(pfad);
        DWORD anzahl;
        schriftHandle = AddFontMemResourceEx(schriftDaten.ptr, cast(DWORD) schriftDaten.length,
                                             null, &anzahl);
        if (schriftHandle is null) {
            debugWriteln("AddFontMemResourceEx fehlgeschlagen fuer ", pfad);
        } else {
            debugWriteln("Schrift '", BUNDLED_FONT_NAME, "' privat geladen (", anzahl, " Schnitte).");
        }
    } catch (Exception e) {
        debugWriteln("Schriftdatei ", pfad, " nicht lesbar: ", e.msg);
    }
}

cairo_font_face_t* fontFaceAt(size_t index) {
    return cairoFonts[index];
}

/// Erste Schrift der Kette, die den GESAMTEN Text abdeckt. Der alte Weg
/// (getFontFaceForChar) pruefte nur die erste Codeeinheit - bei einem
/// Surrogatpaar also die hohe Haelfte, die fuer sich genommen kein Zeichen ist.
///
/// Alles-oder-nichts bewusst, nicht als Luecke: lookupInFont verlangt, dass
/// EINE Schrift JEDEN Codepunkt des Textes fuehrt. Verteilen sich die
/// Codepunkte einer mehrzeichigen Beschriftung ueber zwei Schriften der Kette
/// (seit Paket 5a moeglich, siehe parseNeoKey in mapping.d), findet keine
/// Schrift den ganzen Text, und der Aufrufer faellt auf den Notnagel zurueck
/// (osk.d: zeigeCodepunkt) statt stueckweise zu zeichnen. Betrifft derzeit
/// keines der drei ausgelieferten Layouts.
GlyphLookup lookupGlyphs(wstring text) {
    GlyphLookup ergebnis;
    if (text.length == 0) return ergebnis;

    foreach (i; 0 .. FONT_CHAIN.length) {
        auto versuch = lookupInFont(text, i);
        if (versuch.found) return versuch;
    }

    return ergebnis;
}

/// Nachschlag in genau einer Schrift der Kette. Ein Treffer verlangt, dass die
/// Schrift JEDEN Codepunkt des Textes fuehrt - Glyph 0 ist die Auskunft "kenne
/// ich nicht" und macht den ganzen Text zum Fehlschlag, damit die naechste
/// Schrift der Kette drankommt.
GlyphLookup lookupInFont(wstring text, size_t fontIndex) {
    GlyphLookup ergebnis;
    if (text.length == 0 || fontIndex >= fontCmaps.length) return ergebnis;
    if (!fontCmaps[fontIndex].valid) return ergebnis;

    WORD[] glyphen;
    try {
        foreach (dchar cp; text) {
            auto glyph = fontCmaps[fontIndex].glyphFor(cp);
            if (glyph == 0) return ergebnis;
            glyphen ~= glyph;
        }
    } catch (Exception e) {
        // Kaputte Surrogatfolge im Text - kein Treffer, kein Absturz.
        return ergebnis;
    }

    ergebnis.fontIndex = fontIndex;
    ergebnis.glyphs = glyphen;
    ergebnis.found = true;
    return ergebnis;
}

unittest {
    // Die Kette ist gemessen, nicht geraten (Befund 2.4 der Spec). Dieser Test
    // haelt Reihenfolge und Vollstaendigkeit fest - insbesondere, dass die
    // Primaerschrift Segoe UI bleibt und die mitgelieferte Schrift am Ende
    // steht (sie ist der Notnagel fuer Schach und Alchemie, nicht die erste
    // Wahl fuer gewoehnliche Zeichen).
    assert(FONT_CHAIN.length == 9);
    assert(FONT_CHAIN[0] == "Segoe UI");
    assert(FONT_CHAIN[1] == "Segoe UI Symbol");
    assert(FONT_CHAIN[$ - 1] == BUNDLED_FONT_NAME);

    bool[string] gesehen;
    foreach (name; FONT_CHAIN) {
        assert(name !in gesehen, "Schrift doppelt in der Kette: " ~ name);
        gesehen[name] = true;
    }
}

unittest {
    // Die mitgelieferte Schrift muss im Repo liegen und eine TrueType-Datei
    // sein. Ohne sie bleiben Schach und Alchemie ohne Glyphen - und zwar
    // stillschweigend, weil AddFontMemResourceEx dann gar nicht erst laeuft.
    import std.file : exists, read, readText;
    import std.algorithm : canFind;
    import std.path : buildPath;

    auto pfad = buildPath("fonts", BUNDLED_FONT_FILE);
    assert(exists(pfad), "Schriftdatei fehlt: " ~ pfad);

    auto daten = cast(ubyte[]) read(pfad);
    assert(daten.length > 100_000, "Schriftdatei ist verdaechtig klein");
    assert(daten[0 .. 4] == [0x00, 0x01, 0x00, 0x00], "keine TrueType-Datei (sfnt-Kennung)");

    auto lizenz = readText(buildPath("fonts", "OFL.txt"));
    assert(lizenz.canFind("SIL Open Font License"), "Lizenztext fehlt oder passt nicht");
}

version (unittest) {
    // Prueft, ob GDI wirklich die verlangte Schrift geliefert hat. Unter Wine
    // (tools/verify-linux.sh) gibt es "Segoe UI" nicht, GDI setzt still eine
    // Ersatzschrift ein - ein Abdeckungstest wuerde dort etwas anderes messen,
    // als er behauptet.
    private bool schriftVorhanden(HDC hdc, string name) {
        import std.conv : to;
        import std.string : fromStringz;

        auto hFont = CreateFont(0, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, DEFAULT_PITCH,
            name.toUTF16z);
        scope(exit) DeleteObject(hFont);

        auto alt = SelectObject(hdc, hFont);
        scope(exit) SelectObject(hdc, alt);

        wchar[LF_FACESIZE] puffer;
        // Ueber die Nullterminierung gehen, nicht ueber den Rueckgabewert: Ob
        // GetTextFace das Nullzeichen mitzaehlt, ist nicht eindeutig
        // dokumentiert, und ein um eins verschobener Name liesse den Test still
        // immer ueberspringen.
        if (GetTextFace(hdc, LF_FACESIZE, puffer.ptr) <= 0) return false;

        return puffer.ptr.fromStringz.to!string == name;
    }
}

unittest {
    // Stichprobe je Zielblock, damit eine kaputte Kette auffaellt, statt still
    // zu tofuen. Die Codepunkte sind am 31.07.2026 gegen die cmap der
    // mitgelieferten Schrift und gegen die Messung auf dem Zielrechner geprueft.
    import std.conv : to;

    auto hdc = GetDC(null);
    scope(exit) ReleaseDC(null, hdc);

    if (!schriftVorhanden(hdc, FONT_CHAIN[0])) {
        debugWriteln("Schriftketten-Test uebersprungen: '", FONT_CHAIN[0],
                     "' ist auf diesem System nicht vorhanden (Wine?).");
        return;
    }

    initFontChain(".");

    // ueberWindowsschrift: diese vier Bloecke deckt eine Windows-Schrift ab
    // (Segoe UI Symbol), muessen also darueber aufloesen - nicht ueber die
    // mitgelieferte Schrift. Ohne diese Pruefung waere der Test blind gegen
    // genau den Fehler, der diesen Nachtrag ausgeloest hat: einen
    // Platzhalter-Treffer, der wie Abdeckung aussieht.
    struct Probe { wstring text; string block; bool ueberWindowsschrift; }
    foreach (probe; [
        Probe("a"w,             "Latein", false),
        Probe("∀"w,        "Mathematische Operatoren", false),
        Probe("♞"w,        "Schachfiguren (BMP)", false),
        Probe("\U0001D504"w,    "Mathematical Alphanumeric Symbols", true),
        Probe("\U0001F063"w,    "Domino", true),
        Probe("\U0001F0A1"w,    "Spielkarten", true),
        Probe("\U0001F004"w,    "Mahjong", true)
    ]) {
        auto lookup = lookupGlyphs(probe.text);
        assert(lookup.found, "Kein Glyph fuer Block " ~ probe.block);
        assert(lookup.glyphs.length == 1, "Ein Codepunkt, ein Glyph: " ~ probe.block);
        if (probe.ueberWindowsschrift) {
            assert(lookup.fontIndex < FONT_CHAIN.length - 1,
                "Block " ~ probe.block ~ " loeste ueber die mitgelieferte Schrift auf " ~
                "statt ueber eine Windows-Schrift");
        }
    }

    // Schach und Alchemie kann keine mitgelieferte Windows-Schrift. Faellt die
    // private Ladung aus, faellt genau dieser Test - und nur er.
    auto schach = lookupGlyphs("\U0001FA00"w);
    assert(schach.found, "Schach (U+1FA00) ohne Glyph - mitgelieferte Schrift nicht geladen?");
    assert(FONT_CHAIN[schach.fontIndex] == BUNDLED_FONT_NAME);

    auto alchemie = lookupGlyphs("\U0001F774"w);
    assert(alchemie.found, "Alchemie (U+1F774) ohne Glyph");
    assert(FONT_CHAIN[alchemie.fontIndex] == BUNDLED_FONT_NAME);

    // Die zwei Marker der Compose-Vorschau (osk.d: zeichneEckMarker). Sie
    // haben keinen Codepunkt-Notnagel: Findet die Kette keinen Glyphen,
    // zeichnet die Taste gar nichts und der Fall sieht aus wie "nicht
    // umgesetzt" statt wie "keine Schrift". Genau so ist der Ausstiegsmarker
    // bei der Sichtpruefung am 08.08.2026 unsichtbar geblieben.
    auto weiter = lookupGlyphs("›"w);
    assert(weiter.found, "Fortsetzungsmarker (U+203A) ohne Glyph");

    auto ausstieg = lookupGlyphs("⏹"w);
    assert(ausstieg.found, "Ausstiegsmarker (U+23F9) ohne Glyph");
}
