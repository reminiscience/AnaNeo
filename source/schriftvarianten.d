module schriftvarianten;

/// Die sechs Schriftfamilien des Blocks "Mathematical Alphanumeric Symbols".
/// ANTIQUA hat keine schlichte Reihe - das waere gewoehnlicher Text.
enum Familie { ANTIQUA, SCHREIBSCHRIFT, FRAKTUR, DOPPELT, SERIFENLOS, DICKTENGLEICH }

/// Eine der 13 in Unicode belegten Reihen. Die Basen sind die Codepunkte von
/// 'A', 'a', '0' und dem ersten griechischen Platz; 0 heisst "diese Reihe
/// fuehrt das nicht".
struct Reihe {
    Familie familie;
    bool fett;
    bool kursiv;
    dchar familienZeichen;  // klein; gross geschrieben heisst fett
    uint grossBasis;
    uint kleinBasis;
    uint ziffernBasis;
    uint griechischBasis;
}

immutable(Reihe)[] reihen() pure nothrow {
    static immutable Reihe[] tabelle = [
        Reihe(Familie.ANTIQUA,        true,  false, 'a', 0x1D400, 0x1D41A, 0x1D7CE, 0x1D6A8),
        Reihe(Familie.ANTIQUA,        false, true,  'a', 0x1D434, 0x1D44E, 0,       0x1D6E2),
        Reihe(Familie.ANTIQUA,        true,  true,  'a', 0x1D468, 0x1D482, 0,       0x1D71C),
        Reihe(Familie.SCHREIBSCHRIFT, false, false, 's', 0x1D49C, 0x1D4B6, 0,       0),
        Reihe(Familie.SCHREIBSCHRIFT, true,  false, 's', 0x1D4D0, 0x1D4EA, 0,       0),
        Reihe(Familie.FRAKTUR,        false, false, 'r', 0x1D504, 0x1D51E, 0,       0),
        Reihe(Familie.FRAKTUR,        true,  false, 'r', 0x1D56C, 0x1D586, 0,       0),
        Reihe(Familie.DOPPELT,        false, false, 'd', 0x1D538, 0x1D552, 0x1D7D8, 0),
        // Die kursive Doppelt-Reihe fuehrt der Block nicht - ihre fuenf
        // Zeichen liegen als Ausnahmen in "Letterlike Symbols" (Spec 6 der
        // Inhaltsrunde). Alle Basen 0: die Rechnung liefert hier
        // ausschliesslich Ausnahmen.
        Reihe(Familie.DOPPELT,        false, true,  'd', 0, 0, 0, 0),
        Reihe(Familie.SERIFENLOS,     false, false, 'l', 0x1D5A0, 0x1D5BA, 0x1D7E2, 0),
        Reihe(Familie.SERIFENLOS,     true,  false, 'l', 0x1D5D4, 0x1D5EE, 0x1D7EC, 0x1D756),
        Reihe(Familie.SERIFENLOS,     false, true,  'l', 0x1D608, 0x1D622, 0,       0),
        Reihe(Familie.SERIFENLOS,     true,  true,  'l', 0x1D63C, 0x1D656, 0,       0x1D790),
        Reihe(Familie.DICKTENGLEICH,  false, false, 'm', 0x1D670, 0x1D68A, 0x1D7F6, 0),
    ];
    return tabelle;
}

/// Die 58 griechischen Basisplaetze in genau der Reihenfolge, in der der Block
/// sie fuehrt. Gemessen am 03.08.2026 gegen UCD 17.0.0: 17 Grossbuchstaben,
/// das Theta-Symbol, sieben weitere Grossbuchstaben, Nabla, 25 Kleinbuchstaben,
/// das partielle Differential und sechs Variantenformen.
immutable(dchar)[] griechischeBasen() pure nothrow {
    static immutable dchar[] basen = [
        'Α','Β','Γ','Δ','Ε','Ζ','Η','Θ','Ι','Κ','Λ','Μ','Ν','Ξ','Ο','Π','Ρ',
        'ϴ',
        'Σ','Τ','Υ','Φ','Χ','Ψ','Ω',
        '∇',
        'α','β','γ','δ','ε','ζ','η','θ','ι','κ','λ','μ','ν','ξ','ο','π','ρ','ς',
        'σ','τ','υ','φ','χ','ψ','ω',
        '∂',
        'ϵ','ϑ','ϰ','ϕ','ϱ','ϖ',
    ];
    return basen;
}

/// Die 24 Plaetze, die der Block nicht fuehrt, weil das Zeichen im Block
/// "Letterlike Symbols" liegt. Sie lassen sich NICHT aus dem Namen ableiten -
/// drei Namensfamilien treffen aufeinander (SCRIPT, BLACK-LETTER,
/// DOUBLE-STRUCK), und U+210E heisst PLANCK CONSTANT. Von Hand gefuehrt,
/// gegen UCD 17.0.0 geprueft.
///
/// Dazu seit der Inhaltsrunde die fuenf doppelt-gestrichen-kursiven
/// U+2145-2149: anders als die 24 stopfen sie keine Loecher einer
/// vorhandenen Reihe, sondern sind ihre ganze Reihe.
uint ausnahme(Familie familie, bool fett, bool kursiv, dchar basis) pure nothrow {
    if (fett) return 0;   // keine der 24 liegt in einer fetten Reihe

    if (familie == Familie.ANTIQUA && kursiv && basis == 'h') return 0x210E;

    if (familie == Familie.SCHREIBSCHRIFT && !kursiv) switch (basis) {
        case 'B': return 0x212C; case 'E': return 0x2130; case 'F': return 0x2131;
        case 'H': return 0x210B; case 'I': return 0x2110; case 'L': return 0x2112;
        case 'M': return 0x2133; case 'R': return 0x211B; case 'e': return 0x212F;
        case 'g': return 0x210A; case 'o': return 0x2134; default: return 0;
    }

    if (familie == Familie.FRAKTUR && !kursiv) switch (basis) {
        case 'C': return 0x212D; case 'H': return 0x210C; case 'I': return 0x2111;
        case 'R': return 0x211C; case 'Z': return 0x2128; default: return 0;
    }

    if (familie == Familie.DOPPELT && kursiv) switch (basis) {
        case 'D': return 0x2145; case 'd': return 0x2146; case 'e': return 0x2147;
        case 'i': return 0x2148; case 'j': return 0x2149; default: return 0;
    }

    if (familie == Familie.DOPPELT && !kursiv) switch (basis) {
        case 'C': return 0x2102; case 'H': return 0x210D; case 'N': return 0x2115;
        case 'P': return 0x2119; case 'Q': return 0x211A; case 'R': return 0x211D;
        case 'Z': return 0x2124; default: return 0;
    }

    return 0;
}

/// Codepunkt fuer eine Basis in einer Reihe. 0, wenn die Reihe diese Basis
/// nicht fuehrt (etwa Ziffern in der Schreibschrift).
uint codepunkt(in Reihe r, dchar basis) pure nothrow {
    if (auto a = ausnahme(r.familie, r.fett, r.kursiv, basis)) return a;

    if (basis >= 'A' && basis <= 'Z') return r.grossBasis == 0 ? 0 : r.grossBasis + (basis - 'A');
    if (basis >= 'a' && basis <= 'z') return r.kleinBasis == 0 ? 0 : r.kleinBasis + (basis - 'a');
    if (basis >= '0' && basis <= '9') return r.ziffernBasis == 0 ? 0 : r.ziffernBasis + (basis - '0');

    if (r.griechischBasis != 0) {
        foreach (i, g; griechischeBasen) {
            if (g == basis) return r.griechischBasis + cast(uint) i;
        }
    }

    return 0;
}

import std.format : format;
import std.array : appender;
import composer : COMPOSE_STICKY_DIRECTIVE;

/// Der vollstaendige Inhalt von compose/ananeo-schrift.module. Reine Funktion,
/// damit der Waechtertest dieselbe Zeichenkette bilden kann wie der Erzeuger -
/// eine Rechnung, zwei Verbraucher (Muster keyboardview.d gegen osk.d/sheet.d).
string erzeugeSchriftModul() {
    auto s = appender!string;
    s.put("#configinfo Schriftvarianten ueber den Wurzelmodifikator U+1D535 (x in Fraktur)\n");
    s.put("#\n");
    s.put("# ERZEUGT von ananeo-tool compose gen-schrift - nicht von Hand aendern.\n");
    s.put("# Die Rechnung steht in source/schriftvarianten.d, ein Waechtertest haelt\n");
    s.put("# Datei und Rechnung zusammen.\n");
    s.put("#\n");
    s.put("# Notation: <U1D535> Familienbuchstabe [/] Basis. Familienbuchstabe gross\n");
    s.put("# geschrieben heisst fett, ein / vor der Basis heisst kursiv.\n");
    s.put("#   a Antiqua, s Schreibschrift, r Fraktur, d doppelt gestrichen,\n");
    s.put("#   l serifenlos, m dicktengleich\n");
    s.put("#\n");
    s.put("# Klebrig je Reihe: nach einer Ausgabe geht es am Familien- bzw.\n");
    s.put("# Kursivknoten weiter - ganze Woerter in einer Schrift.\n");
    foreach (r; reihen) {
        dchar famDir = r.fett ? cast(dchar)(r.familienZeichen - 32) : r.familienZeichen;
        s.put(format("%s <U1D535> <U%04X>%s\n", COMPOSE_STICKY_DIRECTIVE,
            cast(uint) famDir, r.kursiv ? " <slash>" : ""));
    }

    foreach (r; reihen) {
        s.put(format("\n# %s%s%s\n", familienName(r.familie),
            r.fett ? " fett" : "", r.kursiv ? " kursiv" : ""));

        dchar fam = r.fett ? cast(dchar)(r.familienZeichen - 32) : r.familienZeichen;
        string kursivTeil = r.kursiv ? " <slash>" : "";

        void zeile(dchar basis) {
            auto cp = codepunkt(r, basis);
            if (cp == 0) return;
            s.put(format("<U1D535> <U%04X>%s <U%04X> : \"%s\" U%04X\n",
                cast(uint) fam, kursivTeil, cast(uint) basis, dcharAlsText(cp), cp));
        }

        foreach (dchar b; "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") zeile(b);
        if (r.ziffernBasis) foreach (dchar b; "0123456789") zeile(b);
        if (r.griechischBasis) foreach (b; griechischeBasen) zeile(b);
    }

    return s.data;
}

private string familienName(Familie f) pure nothrow {
    final switch (f) {
        case Familie.ANTIQUA: return "Antiqua";
        case Familie.SCHREIBSCHRIFT: return "Schreibschrift";
        case Familie.FRAKTUR: return "Fraktur";
        case Familie.DOPPELT: return "doppelt gestrichen";
        case Familie.SERIFENLOS: return "serifenlos";
        case Familie.DICKTENGLEICH: return "dicktengleich";
    }
}

private string dcharAlsText(uint cp) {
    import std.conv : to;
    return (cast(dchar) cp).to!string;
}

version (unittest) {
    import std.file : readText;
    import std.path : buildPath;
    import std.conv : to;
    import std.string : splitLines, split;
}

unittest {
    // Vierzehn Reihen, und die Familienzeichen decken die sechs Familien ab.
    assert(reihen.length == 14);
    assert(griechischeBasen.length == 58);

    bool[dchar] zeichen;
    foreach (r; reihen) zeichen[r.familienZeichen] = true;
    assert(zeichen.length == 6);
}

unittest {
    // Stichproben je Familie und Stil, alle gegen die Spec-Tabelle.
    immutable(Reihe)* finde(Familie f, bool fett, bool kursiv) {
        foreach (ref r; reihen)
            if (r.familie == f && r.fett == fett && r.kursiv == kursiv) return &r;
        return null;
    }

    assert(codepunkt(*finde(Familie.ANTIQUA, true, false), 'B') == 0x1D401);
    assert(codepunkt(*finde(Familie.ANTIQUA, false, true), 'B') == 0x1D435);
    assert(codepunkt(*finde(Familie.ANTIQUA, true, true), 'B') == 0x1D469);
    assert(codepunkt(*finde(Familie.SCHREIBSCHRIFT, true, false), 'B') == 0x1D4D1);
    assert(codepunkt(*finde(Familie.FRAKTUR, false, false), 'B') == 0x1D505);
    assert(codepunkt(*finde(Familie.DOPPELT, false, false), 'B') == 0x1D539);
    assert(codepunkt(*finde(Familie.SERIFENLOS, false, false), 'B') == 0x1D5A1);
    assert(codepunkt(*finde(Familie.DICKTENGLEICH, false, false), 'B') == 0x1D671);

    // Das doppelt gestrichene K - dasselbe Zeichen, das seit dieser Runde auch
    // auf Ebene 6 der Mathematik liegt.
    assert(codepunkt(*finde(Familie.DOPPELT, false, false), 'K') == 0x1D542);

    // Ziffern gibt es nur in fuenf Reihen.
    assert(codepunkt(*finde(Familie.ANTIQUA, true, false), '5') == 0x1D7D3);
    assert(codepunkt(*finde(Familie.SCHREIBSCHRIFT, false, false), '5') == 0);

    // Griechisch: erster Platz, das Theta-Symbol an Position 17, Nabla an 25.
    auto fett = finde(Familie.ANTIQUA, true, false);
    assert(codepunkt(*fett, 'Α') == 0x1D6A8);
    assert(codepunkt(*fett, 'ϴ') == 0x1D6B9);
    assert(codepunkt(*fett, '∇') == 0x1D6C1);
    assert(codepunkt(*fett, 'ω') == 0x1D6DA);
    assert(codepunkt(*fett, 'ϖ') == 0x1D6E1);
    assert(codepunkt(*finde(Familie.FRAKTUR, false, false), 'Α') == 0,
        "Fraktur fuehrt kein Griechisch");
}

unittest {
    // Die 24 Ausnahmen namentlich - und die Gegenprobe, dass die Rechnung ohne
    // sie auf einen unbelegten Codepunkt zeigen wuerde.
    immutable(Reihe)* finde(Familie f, bool fett, bool kursiv) {
        foreach (ref r; reihen)
            if (r.familie == f && r.fett == fett && r.kursiv == kursiv) return &r;
        return null;
    }

    assert(codepunkt(*finde(Familie.ANTIQUA, false, true), 'h') == 0x210E);
    assert(codepunkt(*finde(Familie.SCHREIBSCHRIFT, false, false), 'B') == 0x212C);
    assert(codepunkt(*finde(Familie.SCHREIBSCHRIFT, false, false), 'o') == 0x2134);
    assert(codepunkt(*finde(Familie.FRAKTUR, false, false), 'C') == 0x212D);
    assert(codepunkt(*finde(Familie.DOPPELT, false, false), 'Z') == 0x2124);

    // Und die fette Schreibschrift hat KEINE Luecken - dort rechnet die Formel.
    assert(codepunkt(*finde(Familie.SCHREIBSCHRIFT, true, false), 'B') == 0x1D4D1);
}

unittest {
    // Die fuenf doppelt-gestrichen-kursiven (Spec 6 der Inhaltsrunde): eine
    // Reihe, die der Block gar nicht fuehrt - sie besteht ausschliesslich aus
    // Ausnahmen in "Letterlike Symbols". Anders als die 24 bestehenden
    // stopfen sie keine Loecher, sie SIND ihre Reihe.
    immutable(Reihe)* finde(Familie f, bool fett, bool kursiv) {
        foreach (ref r; reihen)
            if (r.familie == f && r.fett == fett && r.kursiv == kursiv) return &r;
        return null;
    }

    auto reihe = finde(Familie.DOPPELT, false, true);
    assert(reihe !is null, "die kursive Doppelt-Reihe existiert");
    assert(codepunkt(*reihe, 'D') == 0x2145);
    assert(codepunkt(*reihe, 'd') == 0x2146);
    assert(codepunkt(*reihe, 'e') == 0x2147);
    assert(codepunkt(*reihe, 'i') == 0x2148);
    assert(codepunkt(*reihe, 'j') == 0x2149);

    // Gegenproben: alles andere fuehrt die Reihe nicht - und die
    // nicht-kursiven Doppelt-Ausnahmen duerfen NICHT hereinbluten.
    assert(codepunkt(*reihe, 'a') == 0);
    assert(codepunkt(*reihe, 'C') == 0, "das doppelt gestrichene C ist nicht kursiv");
    assert(codepunkt(*reihe, 'Z') == 0);
    assert(codepunkt(*reihe, '5') == 0);
    assert(codepunkt(*reihe, 'Α') == 0);
}

unittest {
    // Wachhund gegen UCD 17.0.0: Jeder von der Rechnung gelieferte Codepunkt
    // muss dort zugewiesen sein. Das faengt einen Tippfehler in den Basen ab,
    // der sonst erst als Tofu auf der Tastatur auffiele.
    bool[uint] zugewiesen;
    foreach (zeile; readText(buildPath(".", "data", "UnicodeData.txt")).splitLines) {
        auto felder = zeile.split(";");
        if (felder.length > 0) zugewiesen[to!uint(felder[0], 16)] = true;
    }

    uint gezaehlt;
    foreach (r; reihen) {
        foreach (dchar b; "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") {
            auto cp = codepunkt(r, b);
            if (r.grossBasis == 0 && r.kleinBasis == 0) {
                // die doppelt-gestrichen-kursive Reihe: nur die fuenf Ausnahmen
                if (cp == 0) continue;
            } else {
                assert(cp != 0, "jede volle Reihe fuehrt alle 52 Buchstaben");
            }
            assert(cp in zugewiesen, "unzugewiesener Codepunkt in einer Buchstabenreihe");
            gezaehlt++;
        }
        if (r.ziffernBasis) foreach (dchar b; "0123456789") {
            auto cp = codepunkt(r, b);
            assert(cp in zugewiesen); gezaehlt++;
        }
        if (r.griechischBasis) foreach (b; griechischeBasen) {
            auto cp = codepunkt(r, b);
            assert(cp in zugewiesen); gezaehlt++;
        }
    }
    assert(gezaehlt == 1021, "die Tabelle hat 1 021 Eintraege, gezaehlt: " ~ gezaehlt.to!string);
}

unittest {
    // Waechter: Die ausgelieferte Datei muss der Rechnung entsprechen. Driftet
    // eines von beidem, wird die Suite rot - dieselbe Rolle, die der Anti-Drift-
    // Test in composer.d fuer die Auskunft spielt.
    //
    // Zeilenenden werden vorher angeglichen: Der Erzeuger schreibt LF, git
    // wandelt beim Auschecken nach CRLF (siehe "LF will be replaced by CRLF").
    import std.string : replace;

    auto datei = readText(buildPath(".", "compose", "ananeo-schrift.module"));
    assert(datei.replace("\r\n", "\n") == erzeugeSchriftModul(),
        "compose/ananeo-schrift.module weicht von der Rechnung ab - " ~
        "neu erzeugen mit: ananeo-tool compose gen-schrift");
}
