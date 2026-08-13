module unicodedata;

import std.algorithm : sort, startsWith, endsWith;
import std.array : appender;
import std.conv : to;
import std.file : readText;
import std.path : buildPath;
import std.range : assumeSorted;
import std.string : indexOf, lineSplitter, split, strip;

struct UnicodeBlock {
    dchar first, last;
    string name;
}

/// Ein <..., First>/<..., Last>-Paar aus UnicodeData.txt. Bewusst nicht in
/// Einzelzeichen aufgeloest: CJK und Hangul haetten sonst Hunderttausende
/// Eintraege in der Namenstabelle, von denen keiner fuer die Kuratierung
/// interessant ist.
struct CodepointRange {
    dchar first, last;
    string name;
}

struct UnicodeData {
    UnicodeBlock[] blocks;
    string[dchar] names;      /// einzeln aufgefuehrte, typbare Zeichen
    dchar[] assignedSorted;   /// dieselben Codepunkte, aufsteigend
    CodepointRange[] ranges;  /// First/Last-Paare, bewusst nicht expandiert
    dchar[][dchar] superscripts; /// Basis -> Hochstellungen (Feld 5, <super>), als Liste
    dchar[][dchar] subscripts;   /// Basis -> Tiefstellungen (Feld 5, <sub>), als Liste
}

/// Allgemeine Kategorien, die nicht als "zugewiesen" zaehlen: Steuerzeichen,
/// Surrogathaelften und Privatbereich. Keines davon ist ein Zeichen, das ein
/// Compose-Bestand abdecken koennte.
private bool zaehltAlsZugewiesen(string kategorie) {
    return kategorie != "Cc" && kategorie != "Cs" && kategorie != "Co";
}

UnicodeData parseUnicodeData(string unicodeDataText, string blocksText) {
    UnicodeData ucd;

    foreach (zeile; blocksText.lineSplitter) {
        auto s = zeile.strip;
        if (s.length == 0 || s.startsWith("#")) continue;

        auto trenner = s.indexOf(';');
        if (trenner < 0) continue;

        auto grenzen = s[0 .. trenner].split("..");
        if (grenzen.length != 2) continue;

        ucd.blocks ~= UnicodeBlock(
            cast(dchar) to!uint(grenzen[0], 16),
            cast(dchar) to!uint(grenzen[1], 16),
            s[trenner + 1 .. $].strip);
    }

    auto einzeln = appender!(dchar[]);
    dchar offenerBereich;
    string offenerName;
    bool bereichOffen;

    foreach (zeile; unicodeDataText.lineSplitter) {
        auto felder = zeile.split(";");
        if (felder.length < 3) continue;

        const cp = cast(dchar) to!uint(felder[0], 16);
        const name = felder[1];
        const kategorie = felder[2];

        if (name.endsWith(", First>")) {
            if (zaehltAlsZugewiesen(kategorie)) {
                // UCD-Formatinvariante: auf eine "First>"-Zeile folgt vor der
                // naechsten "First>"-Zeile immer erst ihre passende "Last>"-
                // Zeile, Bereiche schachteln oder ueberlappen sich nicht. Bricht
                // das je in einer kuenftigen UCD-Version, soll das laut
                // scheitern statt die vorige offene Grenze stillschweigend zu
                // ueberschreiben und "Last>" mit dem falschen Anfang zu paaren.
                // Eine Datenformat-Pruefung ueber Eingabedaten, deshalb wie in
                // composer.d (parseLine) eine geworfene Exception statt assert:
                // --build=release entfernt Asserts ersatzlos.
                if (bereichOffen) {
                    throw new Exception("zwei offene First>-Zeilen ohne Last> dazwischen");
                }
                bereichOffen = true;
                offenerBereich = cp;
                offenerName = name[1 .. $ - ", First>".length];
            }
            continue;
        }

        if (name.endsWith(", Last>")) {
            if (bereichOffen) {
                ucd.ranges ~= CodepointRange(offenerBereich, cp, offenerName);
                bereichOffen = false;
            }
            continue;
        }

        if (!zaehltAlsZugewiesen(kategorie)) continue;

        // Zerlegungsfeld (Feld 5): nur einteilige <super>/<sub>-Zerlegungen
        // tragen die Beziehung "Basis -> hoch-/tiefgestelltes Zeichen".
        // Als Listen, nicht als Einzelwert: der a/o-Doppelfall (U+00AA neben
        // U+1D43) muss in den Daten stehen (Spec 5.3 der Inhaltsrunde).
        if (felder.length > 5) {
            const zerlegung = felder[5];
            if (zerlegung.startsWith("<super> ")) {
                auto teile = zerlegung["<super> ".length .. $].split(" ");
                if (teile.length == 1) {
                    ucd.superscripts[cast(dchar) to!uint(teile[0], 16)] ~= cp;
                }
            } else if (zerlegung.startsWith("<sub> ")) {
                auto teile = zerlegung["<sub> ".length .. $].split(" ");
                if (teile.length == 1) {
                    ucd.subscripts[cast(dchar) to!uint(teile[0], 16)] ~= cp;
                }
            }
        }

        ucd.names[cp] = name;
        einzeln.put(cp);
    }

    ucd.assignedSorted = einzeln.data;
    ucd.assignedSorted.sort();

    return ucd;
}

UnicodeData loadUnicodeData(string dataDir) {
    return parseUnicodeData(
        readText(buildPath(dataDir, "UnicodeData.txt")),
        readText(buildPath(dataDir, "Blocks.txt")));
}

/// Wie viele zugewiesene Zeichen liegen in [first, last]? Einzelzeichen per
/// Binaersuche, Bereiche per Ueberlappung.
uint assignedIn(ref UnicodeData ucd, dchar first, dchar last)
in (first <= last, "umgedrehter Bereich: first darf last nicht ueberschreiten")
{
    auto sortiert = ucd.assignedSorted.assumeSorted;
    const kleiner = sortiert.lowerBound(first).length;   // Codepunkte < first
    const groesser = sortiert.upperBound(last).length;   // Codepunkte > last
    uint summe = cast(uint)(ucd.assignedSorted.length - kleiner - groesser);

    foreach (bereich; ucd.ranges) {
        const von = bereich.first > first ? bereich.first : first;
        const bis = bereich.last < last ? bereich.last : last;
        if (von <= bis) summe += cast(uint)(bis - von + 1);
    }

    return summe;
}

/// Name eines Codepunkts; bei Zeichen aus einem First/Last-Bereich der
/// Bereichsname mit angehaengtem Codepunkt, wie es die UCD-Konvention vorsieht.
string nameOf(ref UnicodeData ucd, dchar cp) {
    if (auto name = cp in ucd.names) return *name;

    foreach (bereich; ucd.ranges) {
        if (cp >= bereich.first && cp <= bereich.last) {
            import std.format : format;
            return format("%s-%04X", bereich.name, cast(uint) cp);
        }
    }

    return "";
}

unittest {
    // Ein synthetischer Auszug, damit der Parser ohne die grossen Dateien
    // geprueft werden kann. Feldreihenfolge wie in UnicodeData.txt:
    // Codepunkt;Name;Kategorie;...
    auto ucdText =
        "0041;LATIN CAPITAL LETTER A;Lu;0;L;;;;;N;;;;0061;\n" ~
        "0042;LATIN CAPITAL LETTER B;Lu;0;L;;;;;N;;;;0062;\n" ~
        "0009;<control>;Cc;0;S;;;;;N;CHARACTER TABULATION;;;;\n" ~
        "D800;<Non Private Use High Surrogate, First>;Cs;0;L;;;;;N;;;;;\n" ~
        "DB7F;<Non Private Use High Surrogate, Last>;Cs;0;L;;;;;N;;;;;\n" ~
        "E000;<Private Use, First>;Co;0;L;;;;;N;;;;;\n" ~
        "F8FF;<Private Use, Last>;Co;0;L;;;;;N;;;;;\n" ~
        "4E00;<CJK Ideograph, First>;Lo;0;L;;;;;N;;;;;\n" ~
        "9FFF;<CJK Ideograph, Last>;Lo;0;L;;;;;N;;;;;\n";

    auto blocksText =
        "# Blocks-17.0.0.txt\n" ~
        "0000..007F; Basic Latin\n" ~
        "4E00..9FFF; CJK Unified Ideographs\n";

    auto ucd = parseUnicodeData(ucdText, blocksText);

    // Bloecke, Kommentarzeilen ignoriert
    assert(ucd.blocks.length == 2);
    assert(ucd.blocks[0].name == "Basic Latin");
    assert(ucd.blocks[0].first == 0x0000 && ucd.blocks[0].last == 0x007F);

    // Namen der einzeln aufgefuehrten Zeichen
    assert(nameOf(ucd, 'A') == "LATIN CAPITAL LETTER A");

    // Steuerzeichen, Surrogate und Privatbereich zaehlen nicht als zugewiesen
    assert(assignedIn(ucd, 0x0000, 0x007F) == 2, "nur A und B, nicht das Cc-Zeichen");
    assert(assignedIn(ucd, 0xD800, 0xDB7F) == 0, "Surrogate zaehlen nicht");
    assert(assignedIn(ucd, 0xE000, 0xF8FF) == 0, "Privatbereich zaehlt nicht");

    // Der First/Last-Bereich wird ueberlagert gezaehlt, nicht expandiert
    assert(ucd.ranges.length == 1, "nur der CJK-Bereich bleibt als Bereich stehen");
    assert(assignedIn(ucd, 0x4E00, 0x9FFF) == 0x9FFF - 0x4E00 + 1);
    // Teilueberlappung
    assert(assignedIn(ucd, 0x4E00, 0x4E09) == 10);

    // nameOf, Bereichspfad: ein Codepunkt innerhalb des CJK-Bereichs traegt
    // keinen Einzelnamen, sondern den Bereichsnamen mit angehaengtem Codepunkt.
    assert(nameOf(ucd, 0x4E05) == "CJK Ideograph-4E05");
    // nameOf, Fallback: weder einzeln benannt noch in einem Bereich.
    assert(nameOf(ucd, 0x0043) == "", "C ist in diesem Auszug nirgends benannt");
}

unittest {
    // Zwei offene "First>"-Zeilen ohne dazwischenliegendes "Last>" verletzen
    // die UCD-Formatinvariante und muessen laut scheitern - nicht per assert,
    // den --build=release ersatzlos entfernt (dieselbe Regel wie composer.d:
    // parseLine wirft aus demselben Grund, statt sich auf assert zu
    // verlassen), sondern per Exception.
    import std.exception : assertThrown;

    // Beide "First>"-Zeilen tragen eine Kategorie, die als zugewiesen zaehlt
    // (Lo) - sonst wuerde zaehltAlsZugewiesen die zweite Zeile schon vorher
    // aussortieren und der Fehlerfall bliebe ungetestet.
    auto kaputterText =
        "4E00;<CJK Ideograph, First>;Lo;0;L;;;;;N;;;;;\n" ~
        "AC00;<Hangul Syllable, First>;Lo;0;L;;;;;N;;;;;\n" ~
        "D7A3;<Hangul Syllable, Last>;Lo;0;L;;;;;N;;;;;\n";

    assertThrown!Exception(parseUnicodeData(kaputterText, ""));
}

unittest {
    // Die ausgelieferten Dateien muessen sich lesen lassen und plausible
    // Groessenordnungen liefern. Absolute Werte stehen bewusst nicht hier -
    // sie aendern sich mit jeder UCD-Version, die Groessenordnung nicht.
    auto ucd = loadUnicodeData("data");

    assert(ucd.blocks.length > 300, "UCD 17 fuehrt ueber 300 Bloecke");
    assert(ucd.names.length > 30_000);
    assert(nameOf(ucd, 'A') == "LATIN CAPITAL LETTER A");
    assert(nameOf(ucd, '∀') == "FOR ALL");

    // Basic Latin ohne Steuerzeichen: 0x20 bis 0x7E, also 95 Zeichen.
    assert(assignedIn(ucd, 0x0000, 0x007F) == 95);
}

unittest {
    // Zerlegungsfeld (Feld 5): <super>/<sub> fuellen die zwei Tabellen,
    // bewusst als Listen - nur so steht der a/o-Doppelfall in den Daten und
    // der Waechter in composeaudit.d kann die Wahl pruefen, statt sie beim
    // Einlesen still zu treffen (Spec 5.3). Andere Zerlegungs-Tags
    // (<fraction>, kanonisch, ...) gehoeren nicht hinein.
    auto ucdText =
        "0061;LATIN SMALL LETTER A;Ll;0;L;;;;;N;;;0041;;0041\n" ~
        "00AA;FEMININE ORDINAL INDICATOR;Lo;0;L;<super> 0061;;;;N;;;;;\n" ~
        "1D43;MODIFIER LETTER SMALL A;Lm;0;L;<super> 0061;;;;N;;;;;\n" ~
        "2090;LATIN SUBSCRIPT SMALL LETTER A;Lm;0;L;<sub> 0061;;;;N;;;;;\n" ~
        "00BD;VULGAR FRACTION ONE HALF;No;0;ON;<fraction> 0031 2044 0032;;;;N;;;;;\n";

    auto ucd = parseUnicodeData(ucdText, "");

    assert(ucd.superscripts[cast(dchar) 0x0061] == [cast(dchar) 0x00AA, cast(dchar) 0x1D43],
        "beide Kandidaten, in Dateireihenfolge");
    assert(ucd.subscripts[cast(dchar) 0x0061] == [cast(dchar) 0x2090]);
    assert((cast(dchar) 0x0031) !in ucd.superscripts, "<fraction> ist weder super noch sub");
    assert((cast(dchar) 0x0031) !in ucd.subscripts);
}

unittest {
    // Gegen die ausgelieferte UCD 17.0.0: Der a/o-Doppelfall (Spec 2.4) muss
    // BEIDE Kandidaten fuehren. Steht dort nur einer, kann der Waechter aus
    // Spec 5.3 die Wahl nicht mehr pruefen und waere stillschweigend
    // wirkungslos (Spec 8.1).
    import std.algorithm : canFind;

    auto ucd = loadUnicodeData("data");

    assert(ucd.superscripts['a'].canFind(cast(dchar) 0x00AA));
    assert(ucd.superscripts['a'].canFind(cast(dchar) 0x1D43));
    assert(ucd.superscripts['o'].canFind(cast(dchar) 0x00BA));
    assert(ucd.superscripts['o'].canFind(cast(dchar) 0x1D52));

    // Gegenprobe: tief-a ist eindeutig.
    assert(ucd.subscripts['a'] == [cast(dchar) 0x2090]);
}
