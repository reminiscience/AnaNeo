module composereport;

import std.algorithm : max;
import std.array : appender, array;
import std.conv : to;
import std.format : format;
import std.range : repeat;
import std.utf : count;

import composeaudit;
import composeview : lowestLayerFor;
import html : htmlEscape;
import mapping : NeoLayout;

/// Eine Tabelle, unabhaengig von der Darstellung. Beide Ausgaben - Konsole und
/// HTML - bauen ausschliesslich hierauf auf; die Auskunftsmodule kennen keine
/// Darstellung.
struct ReportTable {
    string title;
    string[] headers;
    string[][] rows;
    string note;
}

/// Spaltenbreite in Zeichen, nicht in Bytes: Eine Sequenz wie "♫ a e" ist
/// sonst rechnerisch breiter als sie erscheint.
private size_t breite(string s) {
    return s.count;
}

string renderConsole(const ReportTable[] tables) {
    auto aus = appender!string;

    foreach (i, tabelle; tables) {
        if (i > 0) aus.put("\n");
        aus.put(tabelle.title);
        aus.put("\n");

        size_t[] spalten;
        foreach (kopf; tabelle.headers) spalten ~= breite(kopf);
        foreach (zeile; tabelle.rows) {
            foreach (j, zelle; zeile) {
                if (j < spalten.length) spalten[j] = max(spalten[j], breite(zelle));
            }
        }

        void schreibeZeile(const string[] zellen) {
            foreach (j, zelle; zellen) {
                aus.put(zelle);
                if (j + 1 < zellen.length) {
                    // Eine Zeile kann breiter sein als die Kopfzeile (spalten
                    // ist an dieser Stelle nicht gewachsen) - dann faellt j aus
                    // spalten heraus. max() haelt die Differenz ausserdem immer
                    // nichtnegativ: ohne sie waere spalten[j] - breite(zelle)
                    // bei einer zufaellig breiteren Zelle eine
                    // size_t-Unterlauf-Katastrophe (astronomisches repeat-Mass).
                    const spalte = j < spalten.length ? spalten[j] : breite(zelle);
                    aus.put(' '.repeat(max(spalte, breite(zelle)) - breite(zelle) + 2).array);
                }
            }
            aus.put("\n");
        }

        schreibeZeile(tabelle.headers);
        foreach (zeile; tabelle.rows) schreibeZeile(zeile);

        if (tabelle.note.length > 0) {
            aus.put("\n");
            aus.put(tabelle.note);
            aus.put("\n");
        }
    }

    return aus.data;
}

/// Der Bericht als in sich geschlossene Seite. Gestaltung nach demselben
/// Design-Standard wie das Belegungsblatt (Papier/Tinte, Hairlines,
/// border-radius 0, EIN Akzent, Druck immer hell); die Stilangaben stehen
/// hier eigens, weil die beiden Dokumente strukturell nichts gemeinsam haben -
/// Tastaturraster gegen Tabellen.
string renderHtml(string documentTitle, const ReportTable[] tables) {
    auto aus = appender!string;

    aus.put(`<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>` ~ htmlEscape(documentTitle) ~ `</title>
<style>
:root { --papier: #F4F4F4; --tinte: #1C1A1D; --linie: #C9C7CA; --akzent: #2B4CD8; }
@media (prefers-color-scheme: dark) {
  :root { --papier: #1C1A1D; --tinte: #F4F4F4; --linie: #3A383C; --akzent: #7C93F0; }
}
@media print { :root { --papier: #FFF; --tinte: #000; --linie: #999; --akzent: #000; } }
body { background: var(--papier); color: var(--tinte);
       font-family: Archivo, "Segoe UI", system-ui, sans-serif;
       margin: 0; padding: 2rem; font-size: 14px; line-height: 1.45; }
h1 { font-size: 1.4rem; font-weight: 600; margin: 0 0 2rem; }
h2 { font-size: 1rem; font-weight: 600; margin: 2.5rem 0 .75rem;
     border-bottom: 1px solid var(--akzent); padding-bottom: .25rem; }
.umbruch { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: .3rem .75rem .3rem 0;
         border-bottom: 1px solid var(--linie); vertical-align: top;
         font-variant-numeric: tabular-nums; }
th { font-weight: 600; border-bottom: 1px solid var(--tinte); }
.hinweis { font-size: .85rem; margin: .5rem 0 0; opacity: .75; max-width: 60ch; }
</style>
</head>
<body>
<h1>` ~ htmlEscape(documentTitle) ~ `</h1>
`);

    foreach (tabelle; tables) {
        aus.put("<h2>" ~ htmlEscape(tabelle.title) ~ "</h2>\n");
        aus.put("<div class=\"umbruch\">\n<table>\n<tr>");
        foreach (kopf; tabelle.headers) {
            aus.put("<th>" ~ htmlEscape(kopf) ~ "</th>");
        }
        aus.put("</tr>\n");

        foreach (zeile; tabelle.rows) {
            aus.put("<tr>");
            foreach (zelle; zeile) aus.put("<td>" ~ htmlEscape(zelle) ~ "</td>");
            aus.put("</tr>\n");
        }

        aus.put("</table>\n</div>\n");

        if (tabelle.note.length > 0) {
            aus.put("<p class=\"hinweis\">" ~ htmlEscape(tabelle.note) ~ "</p>\n");
        }
    }

    aus.put("</body>\n</html>\n");
    return aus.data;
}

/// Herkunftstabelle: eine Zeile je Datei, in Ladereihenfolge.
ReportTable originTable(const ModuleOrigin[] rows) {
    ReportTable tabelle;
    tabelle.title = "Herkunft je Datei";
    tabelle.headers = ["Datei", "neu", "ueberschr.", "Doppelrolle", "abgelehnt",
                       "entfernt", "unparsbar"];

    foreach (zeile; rows) {
        tabelle.rows ~= [zeile.name, zeile.added.to!string, zeile.overwritten.to!string,
                         zeile.dual.to!string, zeile.rejected.to!string,
                         zeile.removed.to!string, zeile.unparsed.to!string];
    }

    tabelle.note = "»ueberschr.« zaehlt Sequenzen, die diese Datei einer frueher "
                 ~ "geladenen weggenommen hat. Reihenfolge = Ladereihenfolge.";
    return tabelle;
}

/// Einzelfaelle zu "ueberschr." aus originTable: welche Sequenzen eine Datei
/// einer frueher geladenen weggenommen hat, und welche ihrer eigenen eine
/// spaeter geladene wieder wegnahm. auditOrigin berechnet und deckelt beide
/// Listen bereits (ORIGIN_CASE_LIMIT) - hier wird nur gerendert, nicht neu
/// gerechnet.
ReportTable originCasesTable(const ModuleOrigin[] rows) {
    ReportTable tabelle;
    tabelle.title = "Einzelfaelle je Datei";
    tabelle.headers = ["Datei", "Richtung", "Sequenz"];

    foreach (zeile; rows) {
        foreach (sequenz; zeile.overwrote) {
            tabelle.rows ~= [zeile.name, "nahm", sequenz];
        }
        foreach (sequenz; zeile.overwrittenBy) {
            tabelle.rows ~= [zeile.name, "verlor an spaeter geladene Datei", sequenz];
        }
    }

    tabelle.note = format("»nahm« zaehlt Sequenzen, die diese Datei einer frueher geladenen "
                        ~ "weggenommen hat; »verlor ...« Sequenzen, die eine spaeter geladene "
                        ~ "Datei dieser wieder abgenommen hat. Je Datei und Richtung gedeckelt "
                        ~ "auf %s Faelle (ORIGIN_CASE_LIMIT).", ORIGIN_CASE_LIMIT);
    return tabelle;
}

ReportTable deadRemovesTable(const RemoveGap[] rows) {
    ReportTable tabelle;
    tabelle.title = format("Tote .remove-Zeilen (%s)", rows.length);
    tabelle.headers = ["Datei", "Zeile", "Sequenz"];
    foreach (zeile; rows) {
        tabelle.rows ~= [zeile.file, zeile.line.to!string, zeile.sequence];
    }
    tabelle.note = "Diese Zeilen haben im ganzen Ladevorgang nichts abgefangen: "
                 ~ "entweder Ballast oder ein Hinweis, dass sich ihr Modul geaendert hat.";
    return tabelle;
}

ReportTable voidKeysymsTable(const VoidSequence[] rows) {
    ReportTable tabelle;
    tabelle.title = format("Sequenzen mit unbekanntem Keysym (%s)", rows.length);
    tabelle.headers = ["Datei", "Zeile", "Sequenz"];
    foreach (zeile; rows) {
        tabelle.rows ~= [zeile.file, zeile.line.to!string, zeile.raw];
    }
    tabelle.note = "parseKeysym liefert bei unbekanntem Namen KEYSYM_VOID statt zu werfen. "
                 ~ "Solche Sequenzen werden eingetragen - zwei verschiedene Tippfehler "
                 ~ "landen dabei auf demselben Knoten.";
    return tabelle;
}

ReportTable namespaceTable(const NamespaceEntry[] rows, string prefixLabel,
                           const(NeoLayout)* layout = null, string layoutName = "") {
    ReportTable tabelle;
    tabelle.title = prefixLabel.length > 0
        ? format("Namensraum unter %s (%s Fortsetzungen)", prefixLabel, rows.length)
        : format("Startzeichen des Compose-Baums (%s)", rows.length);
    tabelle.headers = ["Sequenz", "Fortsetzungen", "Blaetter", "Sackgasse"];
    if (layout !is null) tabelle.headers ~= "Ebene";

    uint tippbar = 0;
    foreach (zeile; rows) {
        auto reihe = [zeile.prefix, zeile.children.to!string, zeile.leaves.to!string,
                      zeile.terminal ? "ja" : ""];
        if (layout !is null) {
            auto ebene = lowestLayerFor(layout, zeile.keysym);
            reihe ~= ebene == 0 ? "–" : ebene.to!string;
            if (ebene > 0) tippbar++;
        }
        tabelle.rows ~= reihe;
    }

    tabelle.note = "»Sackgasse« heisst: Der Knoten traegt selbst ein Ergebnis und laesst "
                 ~ "sich deshalb nicht verlaengern. Fortsetzungen 0 und Sackgasse leer "
                 ~ "gibt es nicht - das waere ein Knoten ohne Zweck.";

    if (layout !is null) {
        // Die Aufteilung hier/anderswo braucht eine aktuelle Ebene, die das
        // Werkzeug nicht hat - die Spalte liefert stattdessen die
        // vollstaendige Verteilung, die Summe nennt drei Zahlen.
        tabelle.note = format("Layout %s: %s von %s Fortsetzungen tippbar, "
            ~ "%s auf keiner Ebene.", layoutName, tippbar, rows.length,
            rows.length - tippbar) ~ "\n\n" ~ tabelle.note;
    }

    return tabelle;
}

/// Abdeckungstabelle: eine Zeile je Block mit zugewiesenen Zeichen.
ReportTable coverageTable(const BlockCoverage[] rows) {
    ReportTable tabelle;
    tabelle.title = format("Abdeckung je Unicode-Block (%s Bloecke)", rows.length);
    tabelle.headers = ["Block", "Bereich", "zugewiesen", "abgedeckt", "Prozent"];

    foreach (zeile; rows) {
        const prozent = zeile.assigned == 0
            ? 0.0
            : 100.0 * zeile.covered / zeile.assigned;
        tabelle.rows ~= [
            zeile.block,
            format("%04X-%04X", cast(uint) zeile.first, cast(uint) zeile.last),
            zeile.assigned.to!string,
            zeile.covered.to!string,
            format("%.1f", prozent)
        ];
    }

    tabelle.note = "Nenner sind die laut UCD zugewiesenen Zeichen ohne Steuerzeichen, "
                 ~ "Surrogate und Privatbereich - NICHT die Blockgroesse. Die Prozentwerte "
                 ~ "sind deshalb nicht mit der Tabelle der 3b-Vorarbeit vergleichbar.";
    return tabelle;
}

/// Fundtabelle der Rueckwaertssuche: eine Zeile je Sequenz, die das gesuchte
/// Zeichen enthaelt.
ReportTable findTable(const FoundSequence[] rows, string needle) {
    ReportTable tabelle;
    tabelle.title = format("Sequenzen fuer %s (%s)", needle, rows.length);
    tabelle.headers = ["Sequenz", "Ergebnis", "Datei", "Zeile"];
    foreach (zeile; rows) {
        tabelle.rows ~= [zeile.sequence, zeile.result, zeile.file, zeile.line.to!string];
    }
    return tabelle;
}

/// Luecken eines einzelnen Blocks, namentlich.
ReportTable gapsTable(const GapEntry[] rows, string blockName) {
    ReportTable tabelle;
    tabelle.title = format("Fehlend in %s (%s)", blockName, rows.length);
    tabelle.headers = ["Codepunkt", "Zeichen", "Name"];

    foreach (zeile; rows) {
        tabelle.rows ~= [
            format("U+%04X", cast(uint) zeile.codepoint),
            [zeile.codepoint].to!string,
            zeile.name
        ];
    }

    tabelle.note = "Zeichen aus First/Last-Bereichen (CJK, Hangul) sind bewusst nicht "
                 ~ "aufgefuehrt.";
    return tabelle;
}

/// Pruefungstabelle: eine Zeile je Kandidatenzeile, in Dateireihenfolge.
ReportTable checkTable(const CheckFinding[] rows, string candidateFile) {
    ReportTable tabelle;
    tabelle.title = format("Pruefung von %s (%s Eintragszeilen)", candidateFile, rows.length);
    tabelle.headers = ["Zeile", "Befund", "Sequenz", "Ergebnis", "betrifft"];

    foreach (zeile; rows) {
        tabelle.rows ~= [zeile.line.to!string, zeile.kind.to!string, zeile.sequence,
                         zeile.result, zeile.collidesWith];
    }

    tabelle.note = "DUAL traegt ein und macht dabei einen Knoten doppelrollig; "
        ~ "REJECTED wuerde verworfen (Kombination mit einem Sondermodus); "
        ~ "OVERWRITE wuerde "
        ~ "einen fremden Eintrag verdraengen. Nur FREE ist folgenlos.";
    return tabelle;
}

ReportTable diffTable(const DiffEntry[] rows, string labelA, string labelB) {
    import std.algorithm : count;

    ReportTable tabelle;
    tabelle.title = format("Differenz %s gegen %s (%s Unterschiede)", labelA, labelB, rows.length);
    tabelle.headers = ["Sequenz", "Seite", "A", "B"];

    foreach (zeile; rows) {
        tabelle.rows ~= [zeile.sequence, zeile.side.to!string, zeile.resultA, zeile.resultB];
    }

    tabelle.note = format("nur A: %s, nur B: %s, unterschiedlich: %s",
        rows.count!(r => r.side == DiffSide.ONLY_A),
        rows.count!(r => r.side == DiffSide.ONLY_B),
        rows.count!(r => r.side == DiffSide.DIFFERENT));
    return tabelle;
}

/// Ebenentabelle: eine Zeile je Ebene, mit Beispielen der Zeichen, die nur
/// auf der Ebene liegen und nicht auch per Compose erreichbar sind.
ReportTable layersTable(const LayerReach[] rows, string layoutName, uint composeOnly) {
    ReportTable tabelle;
    tabelle.title = format("Ebenen von %s gegen den Compose-Bestand", layoutName);
    tabelle.headers = ["Ebene", "Codepunkte", "auch Compose", "nur Ebene"];

    foreach (zeile; rows) {
        string beispiele;
        foreach (i, cp; zeile.layerOnly) {
            if (i >= 12) { beispiele ~= " …"; break; }
            if (i > 0) beispiele ~= " ";
            beispiele ~= [cp].to!string;
        }
        tabelle.rows ~= [zeile.layer.to!string, zeile.codepoints.to!string,
                         zeile.alsoCompose.to!string, beispiele];
    }

    tabelle.note = format("Nur ueber Compose erreichbar, auf keiner Ebene: %s Codepunkte. "
                        ~ "Die Spalte »nur Ebene« zeigt hoechstens zwoelf Beispiele.", composeOnly);
    return tabelle;
}

/// Die Doppelungen je Sequenz, eingestuft nach Spec 4. Standardmaessig nur
/// die Einzelfaelle: Ohne diesen Deckel waeren es ueber achthundert Zeilen,
/// und niemand liest achthundert Zeilen.
ReportTable spiegelTable(const SpiegelEintrag[] eintraege, string layoutName, bool alle) {
    ReportTable tabelle;
    tabelle.title = format("Doppelungen zwischen den Ebenen von %s und dem Compose-Bestand",
                           layoutName);
    tabelle.headers = ["Modul", "Zeile", "Sequenz", "Ergebnis", "Ebene",
                       "Einstufung", "auch anderswo"];

    uint reihen, muster, einzeln;

    foreach (e; eintraege) {
        final switch (e.art) {
            case SpiegelArt.REIHE:      reihen += 1;  break;
            case SpiegelArt.MUSTER:     muster += 1;  break;
            case SpiegelArt.EINZELFALL: einzeln += 1; break;
        }

        if (!alle && e.art != SpiegelArt.EINZELFALL) continue;

        string einstufung;
        final switch (e.art) {
            case SpiegelArt.REIHE:
                einstufung = format("Reihe (%s, %s Blaetter)", e.kopf, e.kopfBlaetter);
                break;
            case SpiegelArt.MUSTER:
                einstufung = "Muster: " ~ e.muster;
                break;
            case SpiegelArt.EINZELFALL:
                einstufung = "Einzelfall";
                break;
        }

        tabelle.rows ~= [e.modul, e.zeile.to!string, e.sequenz, [e.ergebnis].to!string,
                         e.ebene.to!string, einstufung, e.anderswo ? "ja" : "-"];
    }

    tabelle.note = format("Reihe %s, Muster %s, Einzelfall %s - zusammen %s Doppelungen. %s",
        reihen, muster, einzeln, eintraege.length,
        alle ? "Die Spalte »auch anderswo« heisst: dasselbe Zeichen liefert noch "
             ~ "eine andere Sequenz."
             : "Gezeigt sind nur die Einzelfaelle; --alle zeigt auch Reihen und Muster.");
    return tabelle;
}

version (unittest) {
    import std.algorithm : canFind;
}

unittest {
    // Die Konsolenausgabe richtet Spalten an der breitesten Zelle aus und
    // rechnet dabei in Zeichen, nicht in Bytes.
    ReportTable t;
    t.title = "Probe";
    t.headers = ["a", "b"];
    t.rows = [["kurz", "1"], ["deutlich laenger", "22"]];

    auto text = renderConsole([t]);

    assert(text.canFind("Probe"));
    assert(text.canFind("deutlich laenger"));
    // Der Kopf muss auf die breiteste Zelle aufgefuellt sein: Spaltenbreite 16
    // ("deutlich laenger") minus Kopfbreite 1 ("a") plus 2 Trennzeichen = 17
    // Leerzeichen zwischen "a" und "b".
    assert(text.canFind("a                 b"));
}

unittest {
    // originCasesTable rendert, was auditOrigin schon berechnet und deckelt -
    // beide Richtungen, je eine Zeile je Fall. Ohne diese Tabelle war
    // overwrote/overwrittenBy berechnet, unittestet und in keinem
    // Unterbefehl sichtbar (Important 3 der Codereview).
    ModuleOrigin[] herkunft = [
        ModuleOrigin("base", 10, 0, 0, 0, 0, 0, [], ["<Multi_key> a"]),
        ModuleOrigin("en_US", 5, 1, 0, 0, 0, 0, ["<Multi_key> a"], [])
    ];

    auto tabelle = originCasesTable(herkunft);

    assert(tabelle.rows.length == 2);
    assert(tabelle.rows.canFind(["base", "verlor an spaeter geladene Datei", "<Multi_key> a"]));
    assert(tabelle.rows.canFind(["en_US", "nahm", "<Multi_key> a"]));
    assert(tabelle.note.canFind("ORIGIN_CASE_LIMIT"));
}

unittest {
    // Eine Zeile mit mehr Zellen als die Kopfzeile darf weder einen
    // Indexfehler noch einen size_t-Unterlauf ausloesen (Codereview-Minor):
    // schreibeZeile pruefte den Spaltenindex vorher nicht, obwohl der
    // Breitenlauf oben denselben Index schon schuetzt.
    ReportTable t;
    t.title = "Ueberbreit";
    t.headers = ["a"];
    t.rows = [["eins", "zwei", "drei"]];

    auto text = renderConsole([t]);

    assert(text.canFind("eins"));
    assert(text.canFind("zwei"));
    assert(text.canFind("drei"));
}

unittest {
    // In sich geschlossen: keine externen Verweise. Dieselbe Anforderung wie
    // beim Belegungsblatt - der Bericht muss ohne Netz und ohne JavaScript
    // vollstaendig sein, sonst taugt er nicht als Beweisstueck.
    ReportTable t;
    t.title = "Probe";
    t.headers = ["Spalte"];
    t.rows = [["Wert"]];

    auto html = renderHtml("Compose-Bericht", [t]);

    // @import und url( pruefen dieselbe Anforderung wie die uebrigen Eintraege
    // der Liste - eine Stylesheet-Anweisung ist der klassische Weg, wie eine
    // Seite trotzdem beim Netz vorstellig wird, ohne <link>/<img>/src= zu sein.
    foreach (verboten; ["http://", "https://", "<link", "<img", "src=", "<script",
                        "@import", "url("]) {
        assert(!html.canFind(verboten), "Externer Verweis im Bericht: " ~ verboten);
    }
    assert(html.canFind("<title>Compose-Bericht</title>"));
    assert(html.canFind("Probe"));
    assert(html.canFind("Wert"));
}

unittest {
    // Sequenzen und Unicode-Namen kommen aus Datendateien und muessen maskiert
    // werden - eine .module-Datei darf den Bericht nicht zerlegen koennen. Die
    // gefaehrliche Zeichenkette geht hier durch alle vier Stellen, an denen
    // renderHtml Daten in Markup einbettet: den Dokumenttitel (kommt bei
    // "report" fest vor, bei Einzelbefehlen aber ebenfalls aus Nutzereingabe),
    // den Tabellentitel (bei checkTable/diffTable/namespaceTable ein Dateiname,
    // eine Modulauswahl oder ein Keysym-Praefix von der Kommandozeile), eine
    // Kopfzelle und den Hinweistext - sonst waere ein vergessenes htmlEscape an
    // einer der vier Stellen von diesem Test aus nicht sichtbar.
    enum gefahr = `<b>&"`;
    enum erwartet = "&lt;b&gt;&amp;&quot;";

    ReportTable t;
    t.title = gefahr;
    t.headers = [gefahr];
    t.rows = [[gefahr]];
    t.note = gefahr;

    auto html = renderHtml(gefahr, [t]);

    assert(html.canFind("<title>" ~ erwartet ~ "</title>"), "Dokumenttitel nicht maskiert");
    assert(html.canFind("<h1>" ~ erwartet ~ "</h1>"), "Dokumenttitel (h1) nicht maskiert");
    assert(html.canFind("<h2>" ~ erwartet ~ "</h2>"), "Tabellentitel nicht maskiert");
    assert(html.canFind("<th>" ~ erwartet ~ "</th>"), "Kopfzelle nicht maskiert");
    assert(html.canFind("<td>" ~ erwartet ~ "</td>"), "Zelle nicht maskiert");
    assert(html.canFind(`class="hinweis">` ~ erwartet), "Hinweistext nicht maskiert");
    assert(!html.canFind("<b>"), "Unmaskiertes <b> im Bericht");
}

unittest {
    // namespaceTable mit Layout: Ebenen-Spalte je Zeile, Summenzeile in der
    // Note. Ohne Layout bleibt die Tabelle unveraendert vierspaltig - die
    // Zusage "byteidentisch ohne --layout" haengt an diesem Test.
    import mapping : MapEntry, NeoKey, NeoLayout, Scancode;

    NeoLayout layout;
    layout.layers.length = 2;
    NeoKey k1; k1.keysym = 0x61;
    NeoKey k2; k2.keysym = 0x41;
    layout.map[Scancode(0x10, false)] = MapEntry([k1, k2], false);

    NamespaceEntry[] rows = [
        NamespaceEntry("<x> a", 0, 1, true, 0x61),
        NamespaceEntry("<x> A", 0, 1, true, 0x41),
        NamespaceEntry("<x> q", 0, 1, true, 0x9999),
    ];

    auto ohne = namespaceTable(rows, "x");
    assert(ohne.headers.length == 4, "ohne Layout keine Ebenen-Spalte");

    auto mit = namespaceTable(rows, "x", &layout, "Fixture");
    assert(mit.headers.length == 5);
    assert(mit.headers[4] == "Ebene");
    assert(mit.rows[0][4] == "1");
    assert(mit.rows[1][4] == "2");
    assert(mit.rows[2][4] == "\u2013", "nicht tippbar zeigt einen Halbgeviertstrich");
    assert(mit.note.canFind("2 von 3"), "Summenzeile: tippbar von gesamt");
    assert(mit.note.canFind("1 auf keiner Ebene"));
    assert(mit.note.canFind("Fixture"));
}

unittest {
    // Standardmaessig nur die Einzelfaelle, mit "alle" die ganze Liste. Die
    // Bilanzzeile nennt in beiden Faellen alle drei Zahlen.
    import std.algorithm : filter;
    import std.range : front;

    SpiegelEintrag[] eintraege = [
        SpiegelEintrag("math", 88, "<Multi_key> <h> <a>", 'ℵ', 6,
                       SpiegelArt.EINZELFALL, "", 0, "", false),
        SpiegelEintrag("math", 255, "<Multi_key> <elementof> <dead_stroke> <dead_stroke>",
                       '∉', 6, SpiegelArt.MUSTER, "", 0, "Negation", true),
        SpiegelEintrag("en_US", 12, "<dead_acute> <a>", 'á', 3,
                       SpiegelArt.REIHE, "<dead_acute>", 405, "", false)
    ];

    auto knapp = spiegelTable(eintraege, "AnNoted", false);
    assert(knapp.rows.length == 1, "ohne --alle nur der Einzelfall");
    assert(knapp.rows[0][0] == "math");
    assert(knapp.note.canFind("405") == false, "die Bilanz nennt Zahlen je Stufe, keine Kopfgroessen");
    assert(knapp.note.canFind("1"), "die Bilanz nennt die Zahl der Einzelfaelle");

    auto voll = spiegelTable(eintraege, "AnNoted", true);
    assert(voll.rows.length == 3);
    assert(voll.title.canFind("AnNoted"));

    // Die Einstufungsspalte traegt bei REIHE den Kopf samt Blattzahl, bei
    // MUSTER den Namen.
    auto reihe = voll.rows.filter!(r => r[0] == "en_US").front;
    assert(reihe[5].canFind("Reihe") && reihe[5].canFind("405"));

    auto muster = voll.rows.filter!(r => r[1] == "255").front;
    assert(muster[5] == "Muster: Negation");
    assert(muster[6] == "ja", "auch anderswo im Baum");
}

unittest {
    // In sich geschlossen und maskiert - dieselben zwei Zusagen wie bei den
    // bestehenden HTML-Tests. Die Sequenzspalte traegt Zeichen aus
    // layouts.json und den Moduldateien, also auch spitze Klammern.
    SpiegelEintrag[] eintraege = [
        SpiegelEintrag("test", 1, "<Multi_key> <less> <a&b>", '<', 1,
                       SpiegelArt.EINZELFALL, "", 0, "", false)
    ];

    auto html = renderHtml("Spiegel", [spiegelTable(eintraege, "AnNoted", true)]);

    assert(!html.canFind("http://") && !html.canFind("https://"),
        "kein externer Verweis - der Bericht muss ohne Netz lesbar sein");
    assert(!html.canFind("<a&b>"), "die Sequenzspalte ist maskiert");
    assert(html.canFind("&lt;") && html.canFind("&amp;"));
}
