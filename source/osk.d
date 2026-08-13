module osk;

import core.sys.windows.windows;
import core.sys.windows.winreg;

import std.string;
import std.path;
import std.utf;
import std.json;
import std.conv;

import mapping;
import keyboardview;
import composeview : ComposeDisplay, ComposeKeyKind, ComposeKeyView;
import fontchain;
import debuglog;
import app : updateOSK, toggleOSK, executableDir;
import localization : AppString, appString, controlKeyName;

import cairo;
import cairo_win32;

const WM_DPICHANGED = 0x02E0;
const WM_DRAWOSK = WM_APP + 1;

const UINT OSK_WIDTH_WITH_NUMPAD_96DPI = 1000;
const UINT OSK_WIDTH_NO_NUMPAD_96DPI = 750;
const UINT OSK_HEIGHT_96DPI = 250;
const UINT OSK_BOTTOM_OFFSET_96DPI = 5;
const UINT OSK_MIN_WIDTH_96DPI = 250;

uint dpi = 96;

bool configOskNumpad;
OSKTheme configOskTheme;
OSKLayout configOskLayout;
bool configOskNumberRow;
OSKModifierNames configOskModifierNames;

// Anders als eine HTML-Seite kennt ein Win32-Fenster kein prefers-color-scheme.
// "Sachlich" liest deshalb die Windows-Einstellung und waehlt danach den hellen
// oder den dunklen Tokensatz. Gepuffert, weil drawOsk bei jedem Ebenenwechsel
// laeuft; aufgefrischt wird bei WM_SETTINGCHANGE (app.d).
private bool oskLightTheme = true;

void refreshOskTheme() nothrow {
    oskLightTheme = windowsAppsUseLightTheme();
}

/// HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize,
/// AppsUseLightTheme: 1 = hell, 0 = dunkel. Fehlt der Wert, gilt hell.
private bool windowsAppsUseLightTheme() nothrow {
    DWORD wert = 1;
    DWORD groesse = wert.sizeof;

    auto rc = RegGetValue(HKEY_CURRENT_USER,
        `Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`w.ptr,
        "AppsUseLightTheme"w.ptr,
        RRF_RT_REG_DWORD, null, &wert, &groesse);

    if (rc != ERROR_SUCCESS) return true;
    return wert != 0;
}


enum OSKTheme {
    Grey,
    NeoBlue,
    ColorClassic,
    ColorGreen,
    Sachlich
}

enum OSKLayout {
    ISO,
    ANSI
}

enum OSKModifierNames {
    STANDARD,  // M3, M4, ...
    THREE      // Sym, Cur
}

enum OSKKeyType {
    OTHER,
    POINTER,
    MIDDLE,
    RING,
    PINKY,
    HOME
}

const float KEYBOARD_WIDTH_WITH_NUMPAD = 20;
const float KEYBOARD_WIDTH_NO_NUMPAD = 15;
const float KEYBOARD_HEIGHT = 5;

const float M_PI = 3.14159265358979323846;

OSKKeyType[Scancode] KEY_TYPES;


void initOsk(JSONValue oskJson) {
    // Read config
    configOskNumpad = oskJson["numpad"].boolean;
    configOskTheme = oskJson["theme"].str.to!OSKTheme;
    configOskLayout = oskJson["layout"].str.toUpper.to!OSKLayout;
    configOskNumberRow = oskJson["numberRow"].boolean;
    configOskModifierNames = oskJson["modifierNames"].str.toUpper.to!OSKModifierNames;

    refreshOskTheme();

    // Schriften und Glyphbeschaffung stehen in fontchain.d
    initFontChain(executableDir);

    // Define key types
    KEY_TYPES[Scancode(0x29, false)] = OSKKeyType.PINKY;
    KEY_TYPES[Scancode(0x02, false)] = OSKKeyType.PINKY;
    KEY_TYPES[Scancode(0x03, false)] = OSKKeyType.PINKY;
    KEY_TYPES[Scancode(0x04, false)] = OSKKeyType.RING;
    KEY_TYPES[Scancode(0x05, false)] = OSKKeyType.MIDDLE;
    KEY_TYPES[Scancode(0x06, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x07, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x08, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x09, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x0A, false)] = OSKKeyType.MIDDLE;
    KEY_TYPES[Scancode(0x0B, false)] = OSKKeyType.RING;
    KEY_TYPES[Scancode(0x0C, false)] = OSKKeyType.PINKY;
    KEY_TYPES[Scancode(0x0D, false)] = OSKKeyType.PINKY;

    KEY_TYPES[Scancode(0x10, false)] = OSKKeyType.PINKY;
    KEY_TYPES[Scancode(0x11, false)] = OSKKeyType.RING;
    KEY_TYPES[Scancode(0x12, false)] = OSKKeyType.MIDDLE;
    KEY_TYPES[Scancode(0x13, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x14, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x15, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x16, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x17, false)] = OSKKeyType.MIDDLE;
    KEY_TYPES[Scancode(0x18, false)] = OSKKeyType.RING;
    KEY_TYPES[Scancode(0x19, false)] = OSKKeyType.PINKY;
    KEY_TYPES[Scancode(0x1A, false)] = OSKKeyType.PINKY;
    KEY_TYPES[Scancode(0x1B, false)] = OSKKeyType.PINKY;

    KEY_TYPES[Scancode(0x1E, false)] = OSKKeyType.PINKY;
    KEY_TYPES[Scancode(0x1F, false)] = OSKKeyType.RING;
    KEY_TYPES[Scancode(0x20, false)] = OSKKeyType.MIDDLE;
    KEY_TYPES[Scancode(0x21, false)] = OSKKeyType.HOME;
    KEY_TYPES[Scancode(0x22, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x23, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x24, false)] = OSKKeyType.HOME;
    KEY_TYPES[Scancode(0x25, false)] = OSKKeyType.MIDDLE;
    KEY_TYPES[Scancode(0x26, false)] = OSKKeyType.RING;
    KEY_TYPES[Scancode(0x27, false)] = OSKKeyType.PINKY;
    KEY_TYPES[Scancode(0x28, false)] = OSKKeyType.PINKY;

    KEY_TYPES[Scancode(0x2C, false)] = OSKKeyType.PINKY;
    KEY_TYPES[Scancode(0x2D, false)] = OSKKeyType.RING;
    KEY_TYPES[Scancode(0x2E, false)] = OSKKeyType.MIDDLE;
    KEY_TYPES[Scancode(0x2F, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x30, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x31, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x32, false)] = OSKKeyType.POINTER;
    KEY_TYPES[Scancode(0x33, false)] = OSKKeyType.MIDDLE;
    KEY_TYPES[Scancode(0x34, false)] = OSKKeyType.RING;
    KEY_TYPES[Scancode(0x35, false)] = OSKKeyType.PINKY;
}

void drawOsk(HWND hwnd, NeoLayout *layout, uint layer, bool capslock,
             scope bool delegate(Modifier) nothrow isHeld, bool anyLockActive,
             const(ComposeDisplay)* composeAnzeige = null,
             wstring ebenenText = null) {

    RECT winRect;
    GetWindowRect(hwnd, &winRect);
    const uint winWidth = winRect.right - winRect.left;
    const uint winHeight = winRect.bottom - winRect.top;

    // window is unsuitable for drawing
    if (winWidth == 0 || winHeight == 0) {
        return;
    }
    
    HDC hdcScreen = GetDC(NULL);

    // Offscreen hdc for painting
    HDC hdcMem = CreateCompatibleDC(hdcScreen);
    HBITMAP hbmMem = CreateCompatibleBitmap(hdcScreen, winWidth, winHeight);
    auto hOld = SelectObject(hdcMem, hbmMem);

    // Draw using offscreen hdc
    auto surface = cairo_win32_surface_create(hdcMem);
    auto cr = cairo_create(surface);

    // There seems to be a Cairo bug where the first draw calls alpha value can't be exactly 0 or 1
    // If it is, alpha behaves strangely on later drawcalls, i.e. opaque regions disappear or are blended weirdly.
    // https://gitlab.freedesktop.org/cairo/cairo/-/issues/494
    // Workaround: draw a very faint 1px by 1px rectangle in the upper left corner
    // All following draw calls should then work correctly.
    cairo_rectangle(cr, 0, 0, 1, 1);
    cairo_set_source_rgba(cr, 0, 0, 0, 0.01);
    cairo_fill(cr);

    // Move coordinate system to keyboard coords
    // normal keys are 1 unit wide and high, (0, 0) is upper left,
    // with whole keyboard proportionally centered in window
    float keyboardWidthPx, keyboardHeightPx;
    const float KEYBOARD_WIDTH = configOskNumpad ? KEYBOARD_WIDTH_WITH_NUMPAD : KEYBOARD_WIDTH_NO_NUMPAD;

    // Kopfstreifen: Waehrend einer Compose-Sequenz und bei aktiver Rastung
    // waechst der logische Raum um KOPF; die Letterbox skaliert die Tastatur
    // entsprechend kleiner. Das Fenster behaelt Groesse und Position - der
    // erscheinende Streifen ist das Signal "Compose laeuft" bzw. "eine Ebene
    // ist gerastet", sein Verschwinden zeigt das Ende (Spec 5.1).
    //
    // Beim blossen Halten von Mod3/Mod4 bleibt er bewusst weg: Er wuerde bei
    // jedem Modifier-Griff auf- und zuklappen. Gerastet ist der Fall, in dem
    // man nicht mehr weiss, welche Ebene man vor sich hat.
    const bool zeigeEbene = ebenenText.length > 0;
    const float KOPF = (composeAnzeige !is null || zeigeEbene) ? 0.7 : 0;
    const float GESAMT_HOEHE = KEYBOARD_HEIGHT + KOPF;

    // should we letterbox left and right or on top and bottom?
    if (winWidth / winHeight > KEYBOARD_WIDTH / GESAMT_HOEHE) {
        // letterbox left and right
        keyboardHeightPx = winHeight;
        keyboardWidthPx = keyboardHeightPx * KEYBOARD_WIDTH / GESAMT_HOEHE;
    } else {
        // letterbox top and bottom
        keyboardWidthPx = winWidth;
        keyboardHeightPx = keyboardWidthPx * GESAMT_HOEHE / KEYBOARD_WIDTH;
    }
    cairo_translate(cr, (winWidth - keyboardWidthPx) / 2, (winHeight - keyboardHeightPx) / 2);
    cairo_scale(cr, keyboardWidthPx / KEYBOARD_WIDTH, keyboardHeightPx / GESAMT_HOEHE);

    // Draw keys
    const float PADDING = 0.05;
    const float CORNER_RADIUS = configOskTheme == OSKTheme.Sachlich ? 0 : 0.1;
    const float HAIRLINE = 0.02;
    const float AKZENT_BREITE = 0.06;

    const float FONT_SIZE = 0.45;
    const float BASE_LINE = 0.7;

    cairo_pattern_t *COLOR_GREY = cairo_pattern_create_rgba(0.4, 0.4, 0.4, 0.9);

    cairo_pattern_t *COLOR_NEO_BLUE = cairo_pattern_create_rgba(0.024, 0.533, 0.612, 0.95);

    cairo_pattern_t *COLOR_NEOVARS_GREY = cairo_pattern_create_rgba(200.0/255.0, 200.0/255.0, 200.0/255.0, 0.95);
    cairo_pattern_t *COLOR_NEOVARS_YELLOW = cairo_pattern_create_rgba(235.0/255.0, 230.0/255.0, 150.0/255.0, 0.95);
    cairo_pattern_t *COLOR_NEOVARS_RED = cairo_pattern_create_rgba(231.0/255.0, 150.0/255.0, 153.0/255.0, 0.95);
    cairo_pattern_t *COLOR_NEOVARS_GREEN = cairo_pattern_create_rgba(117.0/255.0, 216.0/255.0, 157.0/255.0, 0.95);
    cairo_pattern_t *COLOR_NEOVARS_BLUE = cairo_pattern_create_rgba(134.0/255.0, 138.0/255.0, 223.0/255.0, 0.95);
    cairo_pattern_t *COLOR_NEOVARS_LIGHT_BLUE = cairo_pattern_create_rgba(197.0/255.0, 203.0/255.0, 255.0/255.0, 0.95);

    cairo_pattern_t *COLOR_GREEN_LIGHT_BLUE = cairo_pattern_create_rgba(147.0/255.0, 204.0/255.0, 234.0/255.0, 0.95);
    cairo_pattern_t *COLOR_GREEN_GREENISH_BLUE = cairo_pattern_create_rgba(122.0/255.0, 190.0/255.0, 179.0/255.0, 0.95);
    cairo_pattern_t *COLOR_GREEN_BLUEISH_GREEN = cairo_pattern_create_rgba(99.0/255.0, 178.0/255.0, 128.0/255.0, 0.95);
    cairo_pattern_t *COLOR_GREEN_GREEN = cairo_pattern_create_rgba(74.0/255.0, 164.0/255.0, 74.0/255.0, 0.95);
    cairo_pattern_t *COLOR_GREEN_LIGHT_GREEN = cairo_pattern_create_rgba(139.0/255.0, 189.0/255.0, 139.0/255.0, 0.95);

    // Design-Standard "Schweizer Sachlichkeit", ein Akzent-Slot (Ultramarin).
    // Hell und dunkel als zwei Tokensaetze, ausgewaehlt ueber die
    // Windows-Einstellung.
    cairo_pattern_t *SACHLICH_PAPIER = oskLightTheme
        ? cairo_pattern_create_rgba(0xF4/255.0, 0xF4/255.0, 0xF4/255.0, 0.97)
        : cairo_pattern_create_rgba(0x1C/255.0, 0x1A/255.0, 0x1D/255.0, 0.97);
    cairo_pattern_t *SACHLICH_TINTE = oskLightTheme
        ? cairo_pattern_create_rgba(0x0A/255.0, 0x0A/255.0, 0x0A/255.0, 1.0)
        : cairo_pattern_create_rgba(0xE0/255.0, 0xDC/255.0, 0xDF/255.0, 1.0);
    cairo_pattern_t *SACHLICH_MUTED = oskLightTheme
        ? cairo_pattern_create_rgba(0x57/255.0, 0x57/255.0, 0x57/255.0, 1.0)
        : cairo_pattern_create_rgba(0x9A/255.0, 0x92/255.0, 0x98/255.0, 1.0);
    cairo_pattern_t *SACHLICH_LINIE = oskLightTheme
        ? cairo_pattern_create_rgba(0xC6/255.0, 0xC6/255.0, 0xC6/255.0, 1.0)
        : cairo_pattern_create_rgba(0x38/255.0, 0x33/255.0, 0x37/255.0, 1.0);
    cairo_pattern_t *SACHLICH_AKZENT = oskLightTheme
        ? cairo_pattern_create_rgba(0x23/255.0, 0x23/255.0, 0xD6/255.0, 1.0)
        : cairo_pattern_create_rgba(0xA9/255.0, 0xC9/255.0, 0xE8/255.0, 1.0);

    cairo_pattern_t *TEXT_COLOR;

    switch (configOskTheme) {
        case OSKTheme.ColorClassic: TEXT_COLOR = cairo_pattern_create_rgba(0.05, 0.05, 0.05, 1.0); break;
        case OSKTheme.ColorGreen: TEXT_COLOR = cairo_pattern_create_rgba(0.05, 0.05, 0.05, 1.0); break;
        case OSKTheme.Sachlich: TEXT_COLOR = SACHLICH_TINTE; break;
        default: TEXT_COLOR = cairo_pattern_create_rgba(0.95, 0.95, 0.95, 1.0);
    }

    cairo_set_font_size(cr, FONT_SIZE);

    // Was eine Taste ist, entscheidet keyboardview.d - hier wird nur gezeichnet.
    KeyView viewFor(Scancode scan) {
        return describeKey(layout, scan, layer, capslock, isHeld, anyLockActive);
    }

    // Die zwei Uebersetzungen, die zur Darstellung gehoeren und deshalb hier
    // bleiben: die Konfigurationsoption fuer die Modifier-Namen (M3 gegen Sym)
    // und die Lokalisierung der Strg-Taste. keyboardview.modifierLabel liefert
    // nur die deutsche Standardform. Wirkt auf KeyLabel.text, nicht mehr auf
    // KeyView.label direkt - ob und was ueberhaupt zu sehen ist, entscheidet
    // seit Paket 5b keyboardview.keyLabel.
    string labelFor(KeyKind kind, string text) {
        if (kind != KeyKind.MODIFIER) return text;
        if (text == "Strg") return controlKeyName();
        if (configOskModifierNames == OSKModifierNames.THREE) {
            if (text == "M3") return "Sym";
            if (text == "M4") return "Cur";
        }
        return text;
    }

    cairo_pattern_t *getKeyColor(Scancode scan) {
        switch (configOskTheme) {
            case OSKTheme.Grey: return COLOR_GREY;
            case OSKTheme.NeoBlue: return COLOR_NEO_BLUE;
            case OSKTheme.ColorClassic:
            {
                auto keyType = KEY_TYPES.get(scan, OSKKeyType.OTHER);
            
                switch (keyType) {
                    case OSKKeyType.OTHER: return COLOR_NEOVARS_GREY;
                    case OSKKeyType.HOME: return COLOR_NEOVARS_LIGHT_BLUE;
                    case OSKKeyType.POINTER: return COLOR_NEOVARS_BLUE;
                    case OSKKeyType.MIDDLE: return COLOR_NEOVARS_GREEN;
                    case OSKKeyType.RING: return COLOR_NEOVARS_RED;
                    case OSKKeyType.PINKY: return COLOR_NEOVARS_YELLOW;
                    default: return COLOR_NEOVARS_GREY;
                }
            }
            case OSKTheme.ColorGreen:
            {
                auto keyType = KEY_TYPES.get(scan, OSKKeyType.OTHER);
            
                switch (keyType) {
                    case OSKKeyType.OTHER: return COLOR_NEOVARS_GREY;
                    case OSKKeyType.HOME: return COLOR_GREEN_LIGHT_GREEN;
                    case OSKKeyType.POINTER: return COLOR_GREEN_GREEN;
                    case OSKKeyType.MIDDLE: return COLOR_GREEN_BLUEISH_GREEN;
                    case OSKKeyType.RING: return COLOR_GREEN_GREENISH_BLUE;
                    case OSKKeyType.PINKY: return COLOR_GREEN_LIGHT_BLUE;
                    default: return COLOR_NEOVARS_GREY;
                }
            }
            default: return COLOR_GREY;
        }
    }
    
    void zeichneLauf(GlyphLookup lookup, float keyX, float keyWidth, float baseline) {
        cairo_set_font_face(cr, fontFaceAt(lookup.fontIndex));

        // cairo_show_glyphs verlangt eine ABSOLUTE Position je Glyph;
        // cairo_show_text hat den Vorschub selbst gerechnet. Also erst relativ
        // setzen und messen, dann um den Startpunkt verschieben.
        cairo_glyph_t[] glyphs;
        cairo_text_extents_t gesamt;

        void vermesse() {
            glyphs = [];
            double x = 0;
            foreach (g; lookup.glyphs) {
                auto einzeln = cairo_glyph_t(g, x, 0);
                cairo_text_extents_t vorschub;
                cairo_glyph_extents(cr, &einzeln, 1, &vorschub);
                glyphs ~= einzeln;
                x += vorschub.x_advance;
            }
            cairo_glyph_extents(cr, glyphs.ptr, cast(int) glyphs.length, &gesamt);
        }

        vermesse();

        // Einpassung: Nur wenn der Lauf breiter ist als die Taste minus Rand,
        // wird die Schrift um genau den Fehlbetrag verkleinert. Einbuchstabige
        // Beschriftungen (die grosse Mehrheit) bleiben unveraendert; ZWNJ und
        // Geschwister schrumpfen auf Passmass, statt in die Nachbartaste zu
        // laufen (Befund vom 02.08.2026, Typografie-Ebene).
        const double verfuegbar = keyWidth - 2 * PADDING - 0.04;
        cairo_matrix_t alteMatrix;
        cairo_get_font_matrix(cr, &alteMatrix);
        bool eingepasst = false;
        if (gesamt.width > verfuegbar && verfuegbar > 0) {
            const double faktor = verfuegbar / gesamt.width;
            cairo_matrix_t neu = alteMatrix;
            neu.xx *= faktor; neu.yy *= faktor;
            neu.xy *= faktor; neu.yx *= faktor;
            cairo_set_font_matrix(cr, &neu);
            eingepasst = true;
            vermesse();
        }

        double startX = keyX + (keyWidth - gesamt.width) / 2;
        foreach (ref g; glyphs) {
            g.x += startX;
            g.y = baseline;
        }

        cairo_show_glyphs(cr, glyphs.ptr, cast(int) glyphs.length);

        if (eingepasst) {
            cairo_set_font_matrix(cr, &alteMatrix);
        }
    }

    // Breite eines Laufs bei aktueller Schriftgroesse - fuer links- und
    // rechtsbuendige Platzierung im Kopfstreifen. zeichneLauf zentriert
    // innerhalb keyWidth; Zentrierung ueber die EXAKTE Laufbreite ist
    // Linksbuendigkeit.
    double messeLaufBreite(GlyphLookup lookup) {
        cairo_set_font_face(cr, fontFaceAt(lookup.fontIndex));
        double x = 0;
        foreach (g; lookup.glyphs) {
            auto einzeln = cairo_glyph_t(g, x, 0);
            cairo_text_extents_t vorschub;
            cairo_glyph_extents(cr, &einzeln, 1, &vorschub);
            x += vorschub.x_advance;
        }
        return x;
    }

    // Einen Lauf linksbuendig an 'links' setzen, ohne dass die Einpassung
    // zuschlaegt.
    //
    // zeichneLauf verkleinert jeden Lauf, der breiter ist als
    // keyWidth - 2*PADDING - 0.04. Wer die nackte Laufbreite als keyWidth
    // uebergibt - was nach exakter Platzierung aussieht -, liegt damit IMMER
    // um 0.14 zu knapp, und der Lauf schrumpft. Bei einem langen Lauf faellt
    // das kaum auf, bei einem kurzen frisst 0.14 fast die ganze Breite:
    // einstellige Blattzahlen landeten so bei rund einem Drittel ihrer
    // Groesse, waehrend zweistellige daneben fast richtig aussahen - und der
    // Ausstiegsmarker blieb duenn und klein trotz Anteil 0.95 (Sichtpruefung
    // 08.08.2026, beides in derselben Ansicht nebeneinander zu sehen).
    //
    // Deshalb den Rand aufschlagen und den Startpunkt um seine Haelfte nach
    // links ziehen - zeichneLauf zentriert innerhalb keyWidth, das ergibt
    // wieder genau 'links'.
    void zeichneLaufBei(GlyphLookup lookup, double links, double breite,
                        float baseline) {
        const double rand = 2 * PADDING + 0.04;
        zeichneLauf(lookup, cast(float)(links - rand / 2),
                    cast(float)(breite + rand), baseline);
    }

    // Notnagel: Findet keine Schrift der Kette den Glyphen, steht der Codepunkt
    // klein in Mono auf der Taste (1D56C) statt eines leeren Kastens. Das ist
    // ausdruecklich NICHT die geplante Antwort auf exotische Zeichen, sondern
    // die ehrliche Auskunft fuer den Fall, dass die Kette versagt.
    void zeigeCodepunkt(wstring text, float keyX, float keyWidth, float baseline) {
        import std.format : format;

        dstring codepunkte;
        try {
            codepunkte = text.to!dstring;
        } catch (Exception e) {
            return;
        }
        if (codepunkte.length == 0) return;

        // codepunkte[0]: Seit Paket 5a kann eine Taste eine mehrzeichige
        // Beschriftung tragen, der Notnagel meldet dann nur den ERSTEN
        // Codepunkt, als waere er die ganze Taste. Vertretbar - der Notnagel
        // ist ohnehin die Ausnahme, keine mehrzeichige Beschriftung nutzt ihn
        // heute -, aber bewusst keine Verhaltensaenderung an dieser Stelle.
        wstring hex;
        try {
            hex = format("%X", cast(uint) codepunkte[0]).to!wstring;
        } catch (Exception e) {
            return;
        }

        auto lookup = lookupInFont(hex, monoFontIndex());
        if (!lookup.found) return;

        cairo_set_font_size(cr, FONT_SIZE * 0.45);
        scope(exit) cairo_set_font_size(cr, FONT_SIZE);
        zeichneLauf(lookup, keyX, keyWidth, baseline);
    }

    void showKeyLabelCentered(string label, float keyX, float keyWidth, float baseline) {
        wstring text;
        try {
            text = label.to!wstring;
        } catch (Exception e) {
            return;
        }

        // TEXT_COLOR gilt fuer die alten Schemata; Sachlich hat die Farbe
        // schon nach Tastenart gesetzt.
        if (configOskTheme != OSKTheme.Sachlich) {
            cairo_set_source(cr, TEXT_COLOR);
        }

        auto lookup = lookupGlyphs(text);
        if (lookup.found) {
            zeichneLauf(lookup, keyX, keyWidth, baseline);
        } else {
            zeigeCodepunkt(text, keyX, keyWidth, baseline);
        }
    }

    // Der Akzentbalken einer Zeichentaste nimmt links Platz weg. Zentriert
    // wird deshalb in der Restflaeche und nicht ueber der ganzen Taste - sonst
    // rueckt jede mehrbuchstabige Beschriftung sichtbar an den Balken heran,
    // und die Einpassung aus zeichneLauf rechnet mit einer Breite, die es gar
    // nicht gibt (Befund aus der Abnahme der OSK-Vorschau).
    void zeigeTastenBeschriftung(string label, KeyGeometry geo, KeyView view) {
        const bool akzent = configOskTheme == OSKTheme.Sachlich
                            && view.codepoints.length > 0;
        showKeyLabelCentered(label,
                             akzent ? geo.x + AKZENT_BREITE : geo.x,
                             akzent ? geo.width - AKZENT_BREITE : geo.width,
                             geo.y + (geo.height - 1) / 2 + BASE_LINE);
    }

    // Kleiner Marker unten rechts in der Taste. Gemeinsame Stelle fuer den
    // Blattzahl-Marker und den Ausstiegsmarker, damit die zwei eine Familie
    // bilden statt in zwei Groessen nebeneinanderzustehen.
    //
    // Groesse und Farbe sind Nacharbeit aus der Sichtpruefung vom 08.08.2026
    // (STATUS.md Punkt 30, Befund b): 0.5 in MUTED war kaum lesbar.
    void zeichneEckMarker(wstring marker, KeyGeometry geo, float anteil) {
        if (marker.length == 0) return;
        auto lookupM = lookupGlyphs(marker);
        if (!lookupM.found) return;
        cairo_set_font_size(cr, FONT_SIZE * anteil);
        cairo_set_source(cr, TEXT_COLOR);
        // Tief in die Ecke. Der frueherere Abstand (0.05/0.1) stammt aus der
        // Zeit, als der Marker halb so gross war; mit der groesseren Zahl
        // schob er sich sichtbar unter die Beschriftung (Sichtpruefung
        // 08.08.2026). Gerechnet: Beschriftungs-Grundlinie liegt bei
        // geo.y + BASE_LINE, die Oberkante des Markers bei 0.8 Anteil rund
        // 0.25 ueber seiner eigenen Grundlinie - erst ab 0.02 Abstand bleibt
        // sie unterhalb.
        auto breite = messeLaufBreite(lookupM);
        zeichneLaufBei(lookupM, geo.x + geo.width - PADDING - 0.02 - breite,
                       breite, geo.y + geo.height - PADDING - 0.02);
        cairo_set_font_size(cr, FONT_SIZE);
    }

    // Marker "geht weiter". Gibt es eine Blattzahl, steht sie allein da -
    // ohne den Winkel, der frueher davorstand. Der Winkel kostete fast die
    // halbe Markerbreite, und die blieb den Ziffern dann nicht: Auf einer
    // Taste mit einem eingekreisten Zeichen war ">10" nicht mehr zu lesen
    // (Sichtpruefung 08.08.2026). Ohne ihn passt dieselbe Zahl in derselben
    // Ecke fast doppelt so gross.
    //
    // leaves 0 heisst Sondermodus-Einstieg - dahinter liegt keine zaehlbare
    // Blattmenge. Dort bleibt der Winkel allein stehen, denn eine Zahl gibt
    // es nicht und gar kein Marker waere eine andere Aussage.
    void zeichneBlattzahlMarker(ComposeKeyView vorschau, KeyGeometry geo) {
        if (vorschau.leaves == 0) {
            zeichneEckMarker("›"w, geo, 0.55);
            return;
        }
        wstring marker;
        try {
            marker = vorschau.leaves.to!wstring;
        } catch (Exception e) {}
        zeichneEckMarker(marker, geo, 0.55);
    }

    // Marker "verlaesst den Modus". Die Taste behaelt ihre gewoehnliche
    // Fuellung und ihr Wurzelzeichen als Beschriftung - sie ist keine
    // Ergebnistaste, sie beendet nur. Findet keine Schrift der Kette einen
    // Glyphen fuer U+23CE, bleibt der Marker weg; das faellt in der
    // Sichtpruefung auf, es geht nichts still verloren.
    // U+23F9, eine gefuellte Flaeche. Der erste Versuch war U+23CE, das
    // Return-Symbol - als Umriss auf Markergroesse war es kaum zu erkennen,
    // und Vergroessern half nicht, weil der Glyph sich innerhalb seiner Zeile
    // klein zeichnet (Sichtpruefung 08.08.2026). Eine geschlossene Flaeche
    // traegt auf diesem Raum, ein Umriss nicht.
    //
    // Etwas groesser als die Blattzahl, weil er ohne Nachbarn dasteht und
    // eine Zustandsaussage macht statt einer Menge.
    void zeichneAusstiegMarker(KeyGeometry geo) {
        zeichneEckMarker("⏹"w, geo, 0.6);
    }

    // Sachlich unterscheidet die vier Tastenarten genau wie das Blatt:
    // Akzentbalken bei CHAR, muted bei VKEY, flaechig line-soft bei MODIFIER,
    // gestrichelt bei EMPTY. Keine Fingerfaerbung - sie wuerde die Flaeche
    // fluten, was der Design-Standard ausschliesst.
    void fuelleTaste(KeyGeometry geo, KeyView view, float radius) {
        float x = geo.x + PADDING;
        float y = geo.y + PADDING;
        float w = geo.width - 2*PADDING;
        float h = geo.height - 2*PADDING;

        if (configOskTheme != OSKTheme.Sachlich) {
            roundRectangle(cr, x, y, w, h, radius);
            cairo_set_source(cr, getKeyColor(geo.scancode));
            cairo_fill(cr);
            return;
        }

        roundRectangle(cr, x, y, w, h, radius);
        cairo_set_source(cr, view.kind == KeyKind.MODIFIER ? SACHLICH_LINIE : SACHLICH_PAPIER);
        cairo_fill(cr);

        roundRectangle(cr, x, y, w, h, radius);
        cairo_set_source(cr, SACHLICH_LINIE);
        cairo_set_line_width(cr, HAIRLINE);
        if (view.kind == KeyKind.EMPTY) {
            double[2] strich = [0.06, 0.06];
            cairo_set_dash(cr, strich.ptr, 2, 0);
        }
        cairo_stroke(cr);
        cairo_set_dash(cr, null, 0, 0);

        // Zeichentaste heisst: Sie erzeugt ein Zeichen. Ob das Layout sie als
        // "char" oder als VK-Code abbildet, ist eine technische Frage und
        // keine, die der Nutzer auf der Tastatur beantwortet sehen will.
        bool traegtZeichen = view.codepoints.length > 0;

        if (traegtZeichen) {
            cairo_rectangle(cr, x, y, AKZENT_BREITE, h);
            cairo_set_source(cr, SACHLICH_AKZENT);
            cairo_fill(cr);
        }

        cairo_set_source(cr, traegtZeichen ? SACHLICH_TINTE : SACHLICH_MUTED);
    }

    void fuelleReturn(KeyView view, KeyGeometry geo) {
        void pfad() {
            returnKey(cr, geo.x + PADDING, geo.y + PADDING,
                      1.5 - 2*PADDING, 1.25 - 2*PADDING, 1 - 2*PADDING, 1, CORNER_RADIUS);
        }

        if (configOskTheme != OSKTheme.Sachlich) {
            pfad();
            cairo_set_source(cr, getKeyColor(geo.scancode));
            cairo_fill(cr);
            return;
        }

        pfad();
        cairo_set_source(cr, SACHLICH_PAPIER);
        cairo_fill(cr);

        pfad();
        cairo_set_source(cr, SACHLICH_LINIE);
        cairo_set_line_width(cr, HAIRLINE);
        cairo_stroke(cr);

        // Return ist eine VK-Taste (oder ohne Layout ein blosses Sinnbild) -
        // in beiden Faellen zurueckhaltend, nie mit Akzentbalken.
        cairo_set_source(cr, view.codepoints.length > 0 ? SACHLICH_TINTE : SACHLICH_MUTED);
    }

    if (KOPF > 0) {
        // Eigene Flaeche, kein blosser Text: Das OSK-Fenster ist zwischen den
        // Tasten durchsichtig, ohne Fuellung stuende der Streifen im
        // Vordergrundfenster und waere dort teils unlesbar (Befund aus der
        // Abnahme). getKeyColor mit einem Scancode ohne Fingerzuordnung
        // liefert je Altschema dessen neutralen Tastenton - derselbe
        // Untergrund, auf dem TEXT_COLOR ohnehin schon gelesen wird.
        cairo_rectangle(cr, 0, 0, KEYBOARD_WIDTH, KOPF);
        cairo_set_source(cr, configOskTheme == OSKTheme.Sachlich
                         ? SACHLICH_PAPIER : getKeyColor(Scancode(0, false)));
        cairo_fill(cr);

        // Trennlinie unten, in der Linienfarbe des Schemas
        cairo_set_source(cr, configOskTheme == OSKTheme.Sachlich ? SACHLICH_LINIE : TEXT_COLOR);
        cairo_set_line_width(cr, HAIRLINE);
        cairo_move_to(cr, 0, KOPF - HAIRLINE);
        cairo_line_to(cr, KEYBOARD_WIDTH, KOPF - HAIRLINE);
        cairo_stroke(cr);

        cairo_set_font_size(cr, FONT_SIZE * 0.8);
        cairo_set_source(cr, configOskTheme == OSKTheme.Sachlich ? SACHLICH_TINTE : TEXT_COLOR);

        // Ganz links: welche Ebene gerade gilt, mit Blockname und
        // Modifier-Satz. Sie steht vor der Sequenz, weil sie auch ohne
        // Compose da ist und ihre Breite deshalb den Anfang bestimmt.
        float textAnfang = 0.15;
        if (zeigeEbene) {
            auto lookupEbene = lookupGlyphs(ebenenText);
            if (lookupEbene.found) {
                auto breite = messeLaufBreite(lookupEbene);
                zeichneLaufBei(lookupEbene, textAnfang, breite, KOPF - 0.22);
                textAnfang += breite + 0.4;
            }
        }

        // Daneben: die getippte Sequenz in Werkzeugnotation bzw. der
        // Sondermodus-Puffer.
        if (composeAnzeige !is null && composeAnzeige.sequenz.length > 0) {
            auto lookupSeq = lookupGlyphs(composeAnzeige.sequenz);
            if (lookupSeq.found) {
                auto breite = messeLaufBreite(lookupSeq);
                zeichneLaufBei(lookupSeq, textAnfang, breite, KOPF - 0.22);
            }
        }

        // Rechts: die Bilanz - nur im Baummodus, im Sondermodus gibt es
        // keinen Knoten und keine Bilanz.
        if (composeAnzeige !is null && !composeAnzeige.sonderModus) {
            auto o = composeAnzeige.overlay;
            wstring bilanz;
            try {
                bilanz = format("%s %s · %s %s", o.here,
                                appString(AppString.OSK_COMPOSE_HERE), o.elsewhere,
                                appString(AppString.OSK_COMPOSE_ELSEWHERE)).to!wstring;
            } catch (Exception e) {}
            if (bilanz.length > 0) {
                auto lookupBilanz = lookupGlyphs(bilanz);
                if (lookupBilanz.found) {
                    auto breite = messeLaufBreite(lookupBilanz);
                    zeichneLaufBei(lookupBilanz, KEYBOARD_WIDTH - 0.15 - breite, breite, KOPF - 0.22);
                }
            }
        }

        cairo_set_font_size(cr, FONT_SIZE);
        cairo_translate(cr, 0, KOPF);
    }

    // Die Tastaturgeometrie steht in keyboardview.d, nicht mehr in einer Folge
    // einzelner Zeichenaufrufe.
    auto boardKeys = boardGeometry(
        configOskLayout == OSKLayout.ISO ? BoardLayout.ISO : BoardLayout.ANSI,
        configOskNumberRow,
        configOskNumpad);

    foreach (geo; boardKeys) {
        auto view = viewFor(geo.scancode);

        // Ob und wie eine Taste beschriftet ist, entscheidet
        // keyboardview.keyLabel - dieselbe Funktion, die auch sheet.d fragt.
        // Die zwei Darstellungsuebersetzungen (Strg/Ctrl, M3/Sym) bleiben
        // hier, sie wirken auf das Ergebnis von keyLabel.
        auto beschriftung = keyLabel(layout, view);
        if (!beschriftung.draw) continue;
        string label = labelFor(view.kind, beschriftung.text);

        // Compose-Vorschau: Waehrend einer Sequenz (nicht im Sondermodus)
        // bedeutet jede Nicht-Modifier-Taste einen der drei Faelle RESULT/
        // BRANCH/NONE. Modifier bleiben normal - sie gehen nicht durch
        // compose() und wechseln waehrend der Sequenz weiter die Ebene.
        const(ComposeKeyView)* vorschau = null;
        bool vorschauAktiv = composeAnzeige !is null && !composeAnzeige.sonderModus
                             && view.kind != KeyKind.MODIFIER;
        if (vorschauAktiv) {
            vorschau = geo.scancode in composeAnzeige.overlay.keys;

            if (vorschau is null) {
                // NONE: Taste braeche die Sequenz ab - gestrichelt leer,
                // ohne Beschriftung (Spec 5.2). Return behaelt seine
                // Kontur, laesst aber ebenfalls die Beschriftung weg.
                KeyView leer = view;
                leer.kind = KeyKind.EMPTY;
                leer.codepoints = [];
                if (geo.shape == KeyShape.ISO_RETURN) {
                    fuelleReturn(leer, geo);
                } else {
                    fuelleTaste(geo, leer, CORNER_RADIUS);
                }
                continue;
            }

            if (vorschau.kind == ComposeKeyKind.RESULT
                || vorschau.kind == ComposeKeyKind.RESULT_BRANCH) {
                // Das Ergebniszeichen ersetzt die Beschriftung; der
                // Akzentbalken sagt wortwoertlich "erzeugt ein Zeichen".
                // RESULT_BRANCH zeigt zusaetzlich den Blattzahl-Marker von
                // BRANCH - die Taste liefert beides, also zeigt sie beides.
                label = vorschau.result.toUTF8;
                KeyView ergebnis = view;
                ergebnis.codepoints = [dchar(0x20)];  // nur Akzent-Flag
                if (geo.shape == KeyShape.ISO_RETURN) {
                    fuelleReturn(ergebnis, geo);
                    showKeyLabelCentered(label, geo.x + 0.25, 1.25, geo.y + 0.5 + BASE_LINE);
                } else {
                    fuelleTaste(geo, ergebnis, CORNER_RADIUS);
                    zeigeTastenBeschriftung(label, geo, ergebnis);
                }
                if (vorschau.kind == ComposeKeyKind.RESULT_BRANCH) {
                    zeichneBlattzahlMarker(*vorschau, geo);
                }
                continue;
            }
            // BRANCH und EXIT fallen durch: normale Fuellung und
            // Beschriftung, danach der jeweilige Marker. EXIT braucht keine
            // Ersatzbeschriftung - die Taste traegt ohnehin schon ihr
            // Wurzelzeichen, und genau das ist die richtige Auskunft.
        }

        if (geo.shape == KeyShape.ISO_RETURN) {
            fuelleReturn(view, geo);
            showKeyLabelCentered(label, geo.x + 0.25, 1.25, geo.y + 0.5 + BASE_LINE);
        } else {
            fuelleTaste(geo, view, CORNER_RADIUS);
            zeigeTastenBeschriftung(label, geo, view);
        }

        if (vorschau !is null && vorschau.kind == ComposeKeyKind.BRANCH) {
            zeichneBlattzahlMarker(*vorschau, geo);
        } else if (vorschau !is null && vorschau.kind == ComposeKeyKind.EXIT) {
            zeichneAusstiegMarker(geo);
        }
    }

    // Cairo cleanup    
    cairo_destroy(cr);
    cairo_surface_destroy(surface);

    // Show on screen
    BLENDFUNCTION blend = { 0 };
    blend.BlendOp = AC_SRC_OVER;
    blend.SourceConstantAlpha = 255;
    blend.AlphaFormat = AC_SRC_ALPHA;

    POINT ptZero = POINT(0, 0);
    POINT winPos = POINT(winRect.left, winRect.top);
    SIZE winDims = SIZE(winWidth, winHeight);

    UpdateLayeredWindow(hwnd, hdcScreen, &winPos, &winDims, hdcMem, &ptZero, RGB(0, 0, 0), &blend, ULW_ALPHA);

    // Reset offscreen hdc to default bitmap
    SelectObject(hdcMem, hOld);

    // Cleanup
    DeleteObject(hbmMem);
    DeleteDC(hdcMem);
    ReleaseDC(NULL, hdcScreen);
}

void roundRectangle(cairo_t *cr, float x, float y, float w, float h, float r) {
    if (r <= 0) {
        // Sachlich zeichnet ohne Rundung (border-radius: 0). Ein cairo_arc mit
        // Radius 0 waere zwar geometrisch richtig, aber unnoetig.
        cairo_rectangle(cr, x, y, w, h);
        return;
    }

    const float QR = M_PI / 2;

    cairo_save(cr);

    cairo_translate(cr, x, y);

    cairo_new_sub_path(cr);
    cairo_arc(cr, w - r, h - r, r, 0*QR, 1*QR);
    cairo_arc(cr, r, h - r, r, 1*QR, 2*QR);
    cairo_arc(cr, r, r, r, 2*QR, 3*QR);
    cairo_arc(cr, w - r, r, r, 3*QR, 4*QR);
    cairo_close_path(cr);

    cairo_restore(cr);
}

void returnKey(cairo_t *cr, float x, float y, float wU, float wL, float hU, float hL, float r) {
    const float QR = M_PI / 2;

    cairo_save(cr);

    cairo_translate(cr, x, y);

    cairo_new_sub_path(cr);
    cairo_arc(cr, wU - r, hU + hL - r, r, 0*QR, 1*QR);
    cairo_arc(cr, wU - wL + r, hU + hL - r, r, 1*QR, 2*QR);
    cairo_arc_negative(cr, wU - wL - r, hU + r, r, 0*QR, -1*QR);
    cairo_arc(cr, r, hU - r, r, 1*QR, 2*QR);
    cairo_arc(cr, r, r, r, 2*QR, 3*QR);
    cairo_arc(cr, wU - r, r, r, 3*QR, 4*QR);
    cairo_close_path(cr);

    cairo_restore(cr);
}

LRESULT oskWndProc(HWND hwnd, uint msg, WPARAM wParam, LPARAM lParam) {
    RECT winRect;
    GetWindowRect(hwnd, &winRect);

    uint calculateHeightWithAspectRatio(uint width) {
        return width * OSK_HEIGHT_96DPI / (configOskNumpad ? OSK_WIDTH_WITH_NUMPAD_96DPI : OSK_WIDTH_NO_NUMPAD_96DPI);
    }

    switch (msg) {
        case WM_NCHITTEST:
        // Manually implement left and right resize handles, all other points drag the window
        // Nur die x-Koordinate wird ausgewertet, senkrecht gibt es keine Griffe
        short x = cast(short) (lParam & 0xFFFF);

        const GRAB_WIDTH = 20;
        
        if (x < winRect.left + GRAB_WIDTH) {
            return HTLEFT;
        } else if (x > winRect.right - GRAB_WIDTH) {
            return HTRIGHT;
        } else {
            return HTCAPTION;
        }

        case WM_WINDOWPOSCHANGING:
        // Preserve aspect ratio when resizing
        WINDOWPOS *newWindowPos = cast(WINDOWPOS*) lParam;
        newWindowPos.cy = calculateHeightWithAspectRatio(newWindowPos.cx);
        break;

        case WM_GETMINMAXINFO:
        // // Preserve a minimal OSK width
        uint oskMinWidth = (OSK_MIN_WIDTH_96DPI * dpi) / 96;
        MINMAXINFO *minmaxinfo = cast(MINMAXINFO*) lParam;
        minmaxinfo.ptMinTrackSize = POINT(oskMinWidth, calculateHeightWithAspectRatio(oskMinWidth));
        break;

        case WM_SIZE:
        updateOSK();
        break;

        case WM_DRAWOSK:
        updateOSK();
        break;

        case WM_DPICHANGED:
        dpi = LOWORD(wParam);  // Update cached DPI
        // Accept new window size suggestion
        RECT* suggestedRect = cast(RECT*) lParam;
        SetWindowPos(hwnd, cast(HWND) 0, suggestedRect.left, suggestedRect.top,
            suggestedRect.right - suggestedRect.left, suggestedRect.bottom - suggestedRect.top,
            SWP_NOZORDER);
        break;

        default: break;
    }

    return DefWindowProc(hwnd, msg, wParam, lParam);
}

void centerOskOnScreen(HWND hwnd) {
    auto wndMonitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO monitorInfo;
    GetMonitorInfo(wndMonitor, &monitorInfo);
    RECT workArea = monitorInfo.rcWork;

    HMODULE user32Lib = GetModuleHandle("User32.dll".toUTF16z);
    auto ptrGetDpiForWindow = cast(UINT function(HWND)) GetProcAddress(user32Lib, "GetDpiForWindow".toStringz);
    if (ptrGetDpiForWindow) {
        dpi = ptrGetDpiForWindow(hwnd);  // Only available for Win 10 1607 and up
        debugWriteln("Running with PerMonitorV2 DPI scaling");
    } else {
        HDC screen = GetDC(NULL);  // Get system DPI on older versions of windows
        dpi = GetDeviceCaps(screen, LOGPIXELSX);
        ReleaseDC(NULL, screen);
        debugWriteln("Running with system DPI scaling");
    }

    uint winWidth = ((configOskNumpad ? OSK_WIDTH_WITH_NUMPAD_96DPI : OSK_WIDTH_NO_NUMPAD_96DPI) * dpi) / 96;
    uint winHeight = (OSK_HEIGHT_96DPI * dpi) / 96;
    uint winBottomOffset = (OSK_BOTTOM_OFFSET_96DPI * dpi) / 96;
    SetWindowPos(hwnd, cast(HWND) 0,
        workArea.left + (workArea.right - workArea.left - winWidth) / 2,
        workArea.bottom - winHeight - winBottomOffset,
        winWidth, winHeight, SWP_NOZORDER);
}

unittest {
    // Die ausgelieferten Konfigurationen muessen ein Schema nennen, das es
    // gibt - ein Tippfehler wuerde erst beim Start des Nutzers auffallen,
    // dort aber als Ausnahme beim Laden der Konfiguration.
    import std.json : parseJSON;
    import std.file : readText;

    foreach (datei; ["config.default.json", "config.neo.json",
                     "config.neoqwertz.json", "config.noted.json"]) {
        auto config = parseJSON(readText(datei));
        auto schema = config["osk"]["theme"].str.to!OSKTheme;
        assert(schema == OSKTheme.Sachlich,
               datei ~ ": Vorgabe ist seit Paket 5b 'Sachlich'");
    }
}