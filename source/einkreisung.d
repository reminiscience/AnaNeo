module einkreisung;

// Die Einkreisung des ⓧ-Zweigs: lueckenlose Blockarithmetik ueber elf Reihen
// plus die zwei Einzelgaenger U+24EA und U+24FF (Spec 2.1 der Inhaltsrunde).
// Rein, kein Win32, kein Cairo, kein globaler Zustand - Muster
// schriftvarianten.d: eine Rechnung, zwei Verbraucher (der Unterbefehl
// compose gen-kreis schreibt die Datei, ein Waechtertest haelt sie fest).

/// Die sechs Formen. Vorgabeform ist der Kreis; die Spielartzeichen der
/// Grammatik sind ( fuer Klammer, [ fuer Quadrat, . fuer Punkt, ! fuer
/// negativ, [ ! fuer das negative Quadrat (Spec 4.1).
enum Form { KREIS, KLAMMER, QUADRAT, PUNKT, NEGATIV_KREIS, NEGATIV_QUADRAT }

/// Codepunkt fuer eine Basis in einer Form. 0, wenn Unicode die Kombination
/// nicht fuehrt (Quadrat und negative Formen nur gross, Punkt nur Ziffern,
/// Klammer- und Punktreihe beginnen bei Eins).
uint codepunkt(Form form, dchar basis) pure nothrow {
    final switch (form) {
        case Form.KREIS:
            if (basis >= 'a' && basis <= 'z') return 0x24D0 + (basis - 'a');
            if (basis >= 'A' && basis <= 'Z') return 0x24B6 + (basis - 'A');
            if (basis >= '1' && basis <= '9') return 0x2460 + (basis - '1');
            if (basis == '0') return 0x24EA;
            return 0;
        case Form.KLAMMER:
            if (basis >= 'a' && basis <= 'z') return 0x249C + (basis - 'a');
            if (basis >= 'A' && basis <= 'Z') return 0x1F110 + (basis - 'A');
            if (basis >= '1' && basis <= '9') return 0x2474 + (basis - '1');
            return 0;
        case Form.QUADRAT:
            if (basis >= 'A' && basis <= 'Z') return 0x1F130 + (basis - 'A');
            return 0;
        case Form.PUNKT:
            if (basis >= '1' && basis <= '9') return 0x2488 + (basis - '1');
            return 0;
        case Form.NEGATIV_KREIS:
            if (basis >= 'A' && basis <= 'Z') return 0x1F150 + (basis - 'A');
            if (basis >= '1' && basis <= '9') return 0x2776 + (basis - '1');
            if (basis == '0') return 0x24FF;
            return 0;
        case Form.NEGATIV_QUADRAT:
            if (basis >= 'A' && basis <= 'Z') return 0x1F170 + (basis - 'A');
            return 0;
    }
}

/// Codepunkt fuer eine zweistellige Zahl in einer Form, zehn bis zwanzig.
/// 0, wenn Unicode die Kombination nicht fuehrt - Quadrat und negatives
/// Quadrat fuehren ueberhaupt keine Ziffern.
uint codepunktZweistellig(Form form, uint zahl) pure nothrow {
    if (zahl < 10 || zahl > 20) return 0;

    final switch (form) {
        case Form.KREIS:           return 0x2469 + (zahl - 10);
        case Form.KLAMMER:         return 0x247D + (zahl - 10);
        case Form.PUNKT:           return 0x2491 + (zahl - 10);
        case Form.NEGATIV_KREIS:
            // Die Zehn schliesst die Dingbat-Reihe ab (❶..❿), elf bis zwanzig
            // stehen in einer eigenen Reihe (⓫..⓴).
            return zahl == 10 ? 0x277F : 0x24EB + (zahl - 11);
        case Form.QUADRAT:
        case Form.NEGATIV_QUADRAT: return 0;
    }
}

import std.array : appender;
import std.format : format;
import composer : COMPOSE_STICKY_DIRECTIVE;

/// Der vollstaendige Inhalt von compose/ananeo-kreis.module. Reine Funktion,
/// damit der Waechtertest dieselbe Zeichenkette bilden kann wie der Erzeuger.
string erzeugeKreisModul() {
    auto s = appender!string;
    s.put("#configinfo Einkreisung ueber den Wurzelmodifikator U+24E7 (eingekreistes x)\n");
    s.put("#\n");
    s.put("# ERZEUGT von ananeo-tool compose gen-kreis - nicht von Hand aendern.\n");
    s.put("# Die Rechnung steht in source/einkreisung.d, ein Waechtertest haelt\n");
    s.put("# Datei und Rechnung zusammen.\n");
    s.put("#\n");
    s.put("# Notation: <U24E7> [Form] [!] Basis. Ohne Formzeichen der Kreis;\n");
    s.put("#   ( Klammer, [ Quadrat, . Punkt, ! negativ, [ ! negatives Quadrat.\n");
    s.put("#\n");
    s.put("# Klebrig: nach einer Ausgabe geht es an diesen Knoten weiter,\n");
    s.put("# bis eine Taste ohne Eintrag, das Wurzelzeichen oder Escape kommt.\n");
    s.put(COMPOSE_STICKY_DIRECTIVE ~ " <U24E7>\n");
    s.put(COMPOSE_STICKY_DIRECTIVE ~ " <U24E7> <parenleft>\n");
    s.put(COMPOSE_STICKY_DIRECTIVE ~ " <U24E7> <bracketleft>\n");
    s.put(COMPOSE_STICKY_DIRECTIVE ~ " <U24E7> <period>\n");
    s.put(COMPOSE_STICKY_DIRECTIVE ~ " <U24E7> <exclam>\n");
    s.put(COMPOSE_STICKY_DIRECTIVE ~ " <U24E7> <bracketleft> <exclam>\n");

    // Basen in fester Reihenfolge: klein, gross, 1-9, 0 - die Rechnung
    // liefert 0 fuer alles, was eine Form nicht fuehrt.
    static immutable string BASEN = "abcdefghijklmnopqrstuvwxyz"
        ~ "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ~ "123456789" ~ "0";

    void reihe(Form form, string griff, string beschreibung) {
        s.put("\n# " ~ beschreibung ~ "\n");
        foreach (dchar b; BASEN) {
            auto cp = codepunkt(form, b);
            if (cp == 0) continue;
            s.put(format("<U24E7>%s <U%04X> : \"%s\" U%04X\n",
                griff, cast(uint) b, dcharAlsText(cp), cp));
        }
    }

    void zweistelligeReihe(Form form, string griff, string beschreibung) {
        bool kopfGeschrieben;
        foreach (zahl; 10 .. 21) {
            auto cp = codepunktZweistellig(form, cast(uint) zahl);
            if (cp == 0) continue;
            if (!kopfGeschrieben) {
                s.put("\n# " ~ beschreibung ~ "\n");
                kopfGeschrieben = true;
            }
            // Zweistellig: die Ziffern einzeln, in Leserichtung.
            s.put(format("<U24E7>%s <U%04X> <U%04X> : \"%s\" U%04X\n",
                griff, cast(uint)('0' + zahl / 10), cast(uint)('0' + zahl % 10),
                dcharAlsText(cp), cp));
        }
    }

    reihe(Form.KREIS, "", "Kreis (Basis direkt)");
    zweistelligeReihe(Form.KREIS, "", "Kreis, zweistellig");
    reihe(Form.KLAMMER, " <parenleft>", "Klammer");
    zweistelligeReihe(Form.KLAMMER, " <parenleft>", "Klammer, zweistellig");
    reihe(Form.QUADRAT, " <bracketleft>", "Quadrat");
    reihe(Form.PUNKT, " <period>", "Punkt");
    zweistelligeReihe(Form.PUNKT, " <period>", "Punkt, zweistellig");
    reihe(Form.NEGATIV_KREIS, " <exclam>", "negativer Kreis");
    zweistelligeReihe(Form.NEGATIV_KREIS, " <exclam>", "negativer Kreis, zweistellig");
    reihe(Form.NEGATIV_QUADRAT, " <bracketleft> <exclam>", "negatives Quadrat");

    return s.data;
}

private string dcharAlsText(uint cp) {
    import std.conv : to;
    return (cast(dchar) cp).to!string;
}

unittest {
    // Stichproben je Form - dieselben Faelle wie Abnahmeliste 8.2 der Spec.
    assert(codepunkt(Form.KREIS, 'a') == 0x24D0);
    assert(codepunkt(Form.KREIS, 'A') == 0x24B6);
    assert(codepunkt(Form.KREIS, '1') == 0x2460);
    assert(codepunkt(Form.KREIS, '0') == 0x24EA, "die Kreis-Null ist ein Einzelgaenger");
    assert(codepunkt(Form.KLAMMER, 'a') == 0x249C);
    assert(codepunkt(Form.KLAMMER, 'A') == 0x1F110);
    assert(codepunkt(Form.KLAMMER, '1') == 0x2474);
    assert(codepunkt(Form.QUADRAT, 'A') == 0x1F130);
    assert(codepunkt(Form.PUNKT, '5') == 0x248C);
    assert(codepunkt(Form.NEGATIV_KREIS, 'A') == 0x1F150);
    assert(codepunkt(Form.NEGATIV_KREIS, '1') == 0x2776);
    assert(codepunkt(Form.NEGATIV_KREIS, '0') == 0x24FF);
    assert(codepunkt(Form.NEGATIV_QUADRAT, 'A') == 0x1F170);
    assert(codepunkt(Form.NEGATIV_QUADRAT, 'Z') == 0x1F189);
}

unittest {
    // Die Reihengrenzen ausdruecklich als Gegenprobe (Spec 8.1): was Unicode
    // nicht fuehrt, liefert 0 - keine Klammer-Null, keine gepunktete Null,
    // kein Quadrat- oder Negativ-Kleinbuchstabe, keine Basis ausserhalb des
    // Alphabets.
    assert(codepunkt(Form.KLAMMER, '0') == 0, "keine geklammerte Null");
    assert(codepunkt(Form.PUNKT, '0') == 0, "keine gepunktete Null");
    assert(codepunkt(Form.PUNKT, 'a') == 0, "der Punkt fuehrt nur Ziffern");
    assert(codepunkt(Form.QUADRAT, 'a') == 0, "kein Quadrat-Kleinbuchstabe");
    assert(codepunkt(Form.QUADRAT, '1') == 0, "keine Quadrat-Ziffer");
    assert(codepunkt(Form.NEGATIV_KREIS, 'a') == 0, "kein negativer Kleinbuchstabe");
    assert(codepunkt(Form.NEGATIV_QUADRAT, 'a') == 0);
    assert(codepunkt(Form.NEGATIV_QUADRAT, '1') == 0);
    assert(codepunkt(Form.KREIS, 0x00E4) == 0, "keine Basis ausserhalb a-z/A-Z/0-9");
}

unittest {
    // Wachhund gegen UCD 17.0.0 samt festgenagelter Gesamtzahl (Spec 8.1) -
    // dasselbe Muster wie in schriftvarianten.d: jeder gelieferte Codepunkt
    // muss zugewiesen sein, sonst fiele ein Tippfehler in einer Blockbasis
    // erst als Tofu auf der Tastatur auf.
    import std.conv : to;
    import std.file : readText;
    import std.path : buildPath;
    import std.string : split, splitLines;

    bool[uint] zugewiesen;
    foreach (zeile; readText(buildPath(".", "data", "UnicodeData.txt")).splitLines) {
        auto felder = zeile.split(";");
        if (felder.length > 0) zugewiesen[to!uint(felder[0], 16)] = true;
    }

    uint gezaehlt;
    foreach (form; [Form.KREIS, Form.KLAMMER, Form.QUADRAT, Form.PUNKT,
                    Form.NEGATIV_KREIS, Form.NEGATIV_QUADRAT]) {
        foreach (dchar b; "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890") {
            auto cp = codepunkt(form, b);
            if (cp == 0) continue;
            assert(cp in zugewiesen, "unzugewiesener Codepunkt in der Einkreisung");
            gezaehlt++;
        }
        foreach (zahl; 10 .. 21) {
            auto cp = codepunktZweistellig(form, cast(uint) zahl);
            if (cp == 0) continue;
            assert(cp in zugewiesen, "unzugewiesener Codepunkt in der zweistelligen Einkreisung");
            gezaehlt++;
        }
    }
    assert(gezaehlt == 264, "die Tabelle hat 264 Eintraege, gezaehlt: " ~ gezaehlt.to!string);
}

unittest {
    // Der Erzeuger schreibt genau 264 Eintragszeilen, LF-getrennt, in der
    // Reihenfolge der Spec-Tabelle 4.1. Die Stichproben sind dieselben acht
    // Griffe wie in der manuellen Abnahme (Spec 8.2, Punkt 2).
    import std.algorithm : canFind;
    import std.string : lineSplitter, startsWith;

    auto inhalt = erzeugeKreisModul();

    uint eintraege;
    foreach (zeile; inhalt.lineSplitter) {
        if (zeile.startsWith("<U24E7>")) eintraege++;
    }
    assert(eintraege == 264);

    assert(inhalt.canFind("<U24E7> <U0061> : \"ⓐ\" U24D0"));
    assert(inhalt.canFind("<U24E7> <parenleft> <U0061> : \"⒜\" U249C"));
    assert(inhalt.canFind("<U24E7> <bracketleft> <U0041> : \"🄰\" U1F130"));
    assert(inhalt.canFind("<U24E7> <period> <U0035> : \"⒌\" U248C"));
    assert(inhalt.canFind("<U24E7> <exclam> <U0041> : \"🅐\" U1F150"));
    assert(inhalt.canFind("<U24E7> <bracketleft> <exclam> <U0041> : \"🅰\" U1F170"));
    assert(inhalt.canFind("<U24E7> <U0030> : \"⓪\" U24EA"));
    assert(inhalt.canFind("<U24E7> <exclam> <U0030> : \"⓿\" U24FF"));
    assert(!inhalt.canFind("\r"), "der Erzeuger schreibt LF");
}

unittest {
    // Die zweistelligen Reihen (Spec 6). Unicode fuehrt sie lueckenlos bis
    // zwanzig; Quadrat und negatives Quadrat fuehren keine Ziffern.
    assert(codepunktZweistellig(Form.KREIS, 10) == 0x2469);
    assert(codepunktZweistellig(Form.KREIS, 20) == 0x2473);
    assert(codepunktZweistellig(Form.KLAMMER, 10) == 0x247D);
    assert(codepunktZweistellig(Form.KLAMMER, 20) == 0x2487);
    assert(codepunktZweistellig(Form.PUNKT, 10) == 0x2491);
    assert(codepunktZweistellig(Form.PUNKT, 20) == 0x249B);

    // Der negative Kreis ist zweigeteilt: die Zehn steht am Ende der
    // Dingbat-Reihe, elf bis zwanzig in einer eigenen.
    assert(codepunktZweistellig(Form.NEGATIV_KREIS, 10) == 0x277F);
    assert(codepunktZweistellig(Form.NEGATIV_KREIS, 11) == 0x24EB);
    assert(codepunktZweistellig(Form.NEGATIV_KREIS, 20) == 0x24F4);

    // Gegenprobe: Reihengrenzen und die Formen ohne Ziffern.
    assert(codepunktZweistellig(Form.KREIS, 9) == 0);
    assert(codepunktZweistellig(Form.KREIS, 21) == 0);
    assert(codepunktZweistellig(Form.QUADRAT, 10) == 0);
    assert(codepunktZweistellig(Form.NEGATIV_QUADRAT, 10) == 0);
}

unittest {
    // Waechter: Die ausgelieferte Datei muss der Rechnung entsprechen -
    // dieselbe Rolle und derselbe Zeilenenden-Angleich wie beim
    // Schrift-Waechter in schriftvarianten.d (der Erzeuger schreibt LF,
    // git macht beim Auschecken CRLF daraus).
    import std.file : readText;
    import std.path : buildPath;
    import std.string : replace;

    auto datei = readText(buildPath(".", "compose", "ananeo-kreis.module"));
    assert(datei.replace("\r\n", "\n") == erzeugeKreisModul(),
        "compose/ananeo-kreis.module weicht von der Rechnung ab - " ~
        "neu erzeugen mit: ananeo-tool compose gen-kreis");
}
