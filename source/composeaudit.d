module composeaudit;

import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.path : baseName, buildPath, extension;
import std.utf : toUTF32;

import composer;
import keyboardview : describeKey;
import mapping : Modifier, NeoLayout;
import unicodedata : UnicodeData, assignedIn, nameOf;

/// Alles, was ein Ladevorgang ueber sich preisgibt. Der fertige Baum steht
/// weiterhin in composer.composeRoot - er wird hier nicht kopiert, weil
/// ComposeNode Zeiger auf seine Nachbarn haelt.
struct AuditData {
    ComposeRecord[] records;
    string[] moduleOrder;
}

/// Eine Auswahl laden und dabei jede gelesene Zeile aufzeichnen.
///
/// Bewusst ueber composer.initCompose statt ueber eine eigene Ladelogik: Es
/// darf nur EINE Umsetzung der Laderegeln geben, sonst driften Auskunft und
/// laufendes Programm auseinander.
AuditData collectAudit(string exeDir, const(string)[] modules) {
    AuditData daten;
    auto sammler = appender!(ComposeRecord[]);

    // Der bisherige Beobachter gehoert einem Aufrufer weiter oben (z.B.
    // compose diff, das collectAudit zweimal hintereinander ruft und
    // zwischendurch keinen eigenen Beobachter erwartet) - er wird deshalb
    // wiederhergestellt, nicht auf null gesetzt. composer.d selbst setzt ihn
    // nie zurueck (siehe Kommentar bei composeObserver), das ist Sache jedes
    // Aufrufers.
    auto vorher = composeObserver;
    scope(exit) composeObserver = vorher;

    composeObserver = (ComposeRecord r) nothrow {
        try { sammler.put(r); } catch (Exception e) {}
    };

    initCompose(exeDir, modules);

    daten.records = sammler.data;

    // Ladereihenfolge aus der Buchfuehrung, nicht aus der Konfiguration: So
    // steht hier auch "(built-in)" und eine Datei ohne Eintraege faellt auf.
    foreach (datei; composeStatsOrder) {
        daten.moduleOrder ~= modulName(datei);
    }

    return daten;
}

/// Dateiname ohne Pfad und ohne Endung; der eingebaute Name bleibt, wie er ist.
string modulName(string datei) {
    if (datei == COMPOSE_BUILTIN_NAME) return datei;
    return datei.baseName(datei.extension);
}

struct Leaf {
    uint[] keysyms;
    wstring result;
}

/// Verlustfreier Schluessel einer Sequenz. composeSequenceString ist eine
/// ANZEIGE-Funktion: sie rendert zwei verschiedene Keysyms mit demselben
/// Codepunkt gleich (XK_underscore 0x005F und das APL-XK_underbar 0x0BC6
/// werden beide zu "_"), und taugt deshalb nicht als Kartenschluessel. Diese
/// Funktion bildet stattdessen jedes Keysym auf seinen rohen Zahlenwert ab -
/// verschiedene Keysyms ergeben immer verschiedene Schluessel, unabhaengig
/// davon, wie sie angezeigt werden.
string keysymKey(const uint[] keysyms) {
    import std.array : join;
    import std.format : format;

    string[] teile;
    foreach (k; keysyms) teile ~= format("%x", k);
    return teile.join(",");
}

/// Alle Ergebnisse des Baums, also jede tatsaechlich eingebbare Sequenz.
/// Sonderroutinen-Knoten (specialMode) sind Blaetter ohne Ergebnis. Ein
/// doppelrolliger Knoten traegt ein Ergebnis UND Kinder - er erscheint mit
/// seinem eigenen Pfad und seine Kinder zusaetzlich.
Leaf[] allLeaves(ComposeNode* root) {
    auto sammler = appender!(Leaf[]);
    uint[] pfad;

    void gehe(ComposeNode* knoten) {
        if (knoten.next.length == 0) {
            sammler.put(Leaf(pfad.dup, knoten.result));
            return;
        }
        if (knoten.result.length > 0) {
            sammler.put(Leaf(pfad.dup, knoten.result));
        }
        foreach (kind; knoten.next) {
            pfad ~= kind.keysym;
            gehe(kind);
            pfad = pfad[0 .. $ - 1];
        }
    }

    gehe(root);
    return sammler.data;
}

/// Jeder Codepunkt, der ueber irgendeine Sequenz herauskommt. Mehrzeichige
/// Ergebnisse steuern jeden ihrer Codepunkte bei.
bool[dchar] reachableCodepoints(ComposeNode* root) {
    bool[dchar] menge;
    foreach (blatt; allLeaves(root)) {
        foreach (cp; blatt.result.toUTF32) menge[cp] = true;
    }
    return menge;
}

/// Was eine Datei beigetragen hat, und wer wem im Weg stand.
struct ModuleOrigin {
    string name;
    uint added, overwritten, dual, rejected, removed, unparsed;
    string[] overwrote;
    string[] overwrittenBy;
}

/// Wie viele Einzelfaelle je Richtung aufgefuehrt werden. Ohne Deckel wuerde
/// die Tabelle bei en_US unlesbar.
enum ORIGIN_CASE_LIMIT = 40;

ModuleOrigin[] auditOrigin(ref AuditData data) {
    ModuleOrigin[] ergebnis;
    size_t[string] index;

    ModuleOrigin* hole(string datei) {
        auto name = modulName(datei);
        if (name !in index) {
            index[name] = ergebnis.length;
            ergebnis ~= ModuleOrigin(name);
        }
        return &ergebnis[index[name]];
    }

    // Wer eine Sequenz zuletzt eingetragen hat - fuer die Gegenrichtung.
    // Geschluesselt ueber keysymKey, nicht ueber die Anzeige-Sequenz (siehe
    // keysymKey) - sonst wuerden zwei verschiedene Keysyms mit demselben
    // Codepunkt (z.B. XK_underscore/XK_underbar) hier denselben Eintrag
    // treffen.
    string[string] letzterEintrag;

    foreach (r; data.records) {
        auto eintrag = hole(r.file);
        const schluessel = keysymKey(r.keysyms);
        const sequenz = composeSequenceString(r.keysyms); // nur zur Anzeige

        final switch (r.outcome) {
            case ComposeOutcome.ADDED:
                eintrag.added += 1;
                letzterEintrag[schluessel] = modulName(r.file);
                break;
            case ComposeOutcome.OVERWRITTEN:
                eintrag.overwritten += 1;
                if (eintrag.overwrote.length < ORIGIN_CASE_LIMIT) {
                    eintrag.overwrote ~= sequenz;
                }
                if (auto voriges = schluessel in letzterEintrag) {
                    auto opfer = hole(*voriges);
                    if (opfer.overwrittenBy.length < ORIGIN_CASE_LIMIT) {
                        opfer.overwrittenBy ~= sequenz;
                    }
                }
                letzterEintrag[schluessel] = modulName(r.file);
                break;
            case ComposeOutcome.DUAL:
                // DUAL traegt wie ADDED ein Ergebnis in den Baum ein (nur mit
                // Doppelrolle) - fuer die Gegenrichtung zaehlt es deshalb
                // genauso als "zuletzt eingetragen".
                eintrag.dual += 1;
                letzterEintrag[schluessel] = modulName(r.file);
                break;
            case ComposeOutcome.REJECTED:  eintrag.rejected += 1; break;
            case ComposeOutcome.REMOVED:    eintrag.removed += 1;    break;
            case ComposeOutcome.UNPARSED:   eintrag.unparsed += 1;   break;
        }
    }

    return ergebnis;
}

/// Eine .remove-Zeile, die im ganzen Ladevorgang nie gegriffen hat.
struct RemoveGap {
    string file;
    uint line;
    string sequence;
}

/// Welche .remove-Zeilen tatsaechlich etwas abgefangen haben, ergibt sich aus
/// den REMOVED-Aufzeichnungen. Alles, was in einer geladenen .remove-Datei
/// steht und dort nicht vorkommt, ist tot.
///
/// Die .remove-Dateien werden hier ein zweites Mal gelesen - das ist kein
/// Driftrisiko, weil nur Zeilen gezaehlt und geparst werden, nicht die
/// Laderegeln nachgebaut.
RemoveGap[] auditDeadRemoves(string exeDir, const(string)[] modules, ref AuditData data) {
    import std.file : exists, read;
    import std.string : split;

    // Geschluesselt ueber keysymKey statt der Anzeige-Sequenz - siehe dort.
    bool[string] gegriffen;
    foreach (r; data.records) {
        if (r.outcome == ComposeOutcome.REMOVED) {
            gegriffen[keysymKey(r.keysyms)] = true;
        }
    }

    auto composeDir = buildPath(exeDir, "compose");
    if (!exists(composeDir)) return [];

    // Denselben Verzeichnisscan wie initCompose benutzen - nicht selbst
    // nachbauen, sonst driften beide bei einer Aenderung der Aufzaehlungsregel
    // (neue Endung, Gross-/Kleinschreibung, Rekursion) still auseinander.
    auto scan = scanComposeDir(composeDir);
    auto auswahl = selectComposeFiles(modules, scan.modules, scan.removes);

    RemoveGap[] tote;

    foreach (name; auswahl.removes) {
        auto pfad = buildPath(composeDir, name ~ ".remove");
        auto zeilen = (cast(string) read(pfad)).split("\n");

        foreach (index, zeile; zeilen) {
            if (classifyComposeLine(zeile) != ComposeLineKind.ENTRY) continue;
            try {
                auto eintrag = parseLine(zeile);
                auto schluessel = keysymKey(eintrag.keysyms);
                auto sequenz = composeSequenceString(eintrag.keysyms); // nur zur Anzeige
                if (schluessel !in gegriffen) {
                    tote ~= RemoveGap(name ~ ".remove", cast(uint)(index + 1), sequenz);
                }
            } catch (Exception e) {
                // Eine kaputte .remove-Zeile greift zwangslaeufig ins Leere.
                tote ~= RemoveGap(name ~ ".remove", cast(uint)(index + 1),
                    "(nicht lesbar) " ~ zeile);
            }
        }
    }

    return tote;
}

/// Eine eingetragene Sequenz, die ein unbekanntes Keysym enthaelt.
struct VoidSequence {
    string file;
    uint line;
    string raw;
}

/// parseKeysym wirft bei unbekanntem Namen nicht, sondern liefert
/// KEYSYM_VOID - eine solche Sequenz wird trotzdem eingetragen und landet auf
/// demselben Knoten wie jeder andere Tippfehler. Hier wird sie sichtbar.
VoidSequence[] auditVoidKeysyms(ref AuditData data) {
    import keysyms : KEYSYM_VOID;

    VoidSequence[] treffer;

    foreach (r; data.records) {
        if (r.outcome == ComposeOutcome.UNPARSED) continue;
        if (!r.keysyms.canFind(KEYSYM_VOID)) continue;
        treffer ~= VoidSequence(modulName(r.file), r.line, composeSequenceString(r.keysyms));
    }

    return treffer;
}

/// Ein Zweig des Namensraums unterhalb eines Praefixes.
struct NamespaceEntry {
    string prefix;
    uint children;
    uint leaves;
    bool terminal;
    uint keysym;   /// rohes Keysym der Fortsetzung, fuer die Ebenen-Spalte
}

/// Die Fortsetzungen unterhalb eines Praefixes. Ein leeres Praefix liefert die
/// Startzeichen des Baums.
///
/// terminal heisst: Dieser Knoten traegt selbst ein Ergebnis. Seit den
/// mehrzeichigen Basen blockiert das keine Verlaengerung mehr - ein solcher
/// Knoten darf zugleich Kinder tragen und haelt sein Ergebnis fest, bis die
/// naechste Taste entscheidet.
NamespaceEntry[] auditNamespace(ComposeNode* root, const(uint)[] prefix) {
    auto knoten = root;

    foreach (keysym; prefix) {
        ComposeNode* naechster;
        foreach (kind; knoten.next) {
            if (kind.keysym == keysym) { naechster = kind; break; }
        }
        if (naechster is null) return [];
        knoten = naechster;
    }

    uint zaehleBlaetter(ComposeNode* n) {
        if (n.next.length == 0) return 1;
        uint summe = n.result.length > 0 ? 1 : 0;
        foreach (kind; n.next) summe += zaehleBlaetter(kind);
        return summe;
    }

    NamespaceEntry[] ergebnis;

    foreach (kind; knoten.next) {
        auto pfad = prefix.dup ~ kind.keysym;
        ergebnis ~= NamespaceEntry(
            composeSequenceString(pfad),
            cast(uint) kind.next.length,
            zaehleBlaetter(kind),
            kind.result.length > 0 || kind.specialMode !is null,
            kind.keysym);
    }

    return ergebnis;
}

/// Abdeckung eines Unicode-Blocks durch den Compose-Bestand.
struct BlockCoverage {
    string block;
    dchar first, last;
    uint assigned;
    uint covered;
}

/// Abdeckung je Block. Bloecke ohne ein einziges zugewiesenes Zeichen fallen
/// heraus - eine Zeile "0 von 0" traegt nichts bei.
BlockCoverage[] auditCoverage(bool[dchar] reachable, ref UnicodeData ucd) {
    BlockCoverage[] ergebnis;

    foreach (block; ucd.blocks) {
        const zugewiesen = assignedIn(ucd, block.first, block.last);
        if (zugewiesen == 0) continue;

        uint abgedeckt;
        foreach (cp, _; reachable) {
            if (cp >= block.first && cp <= block.last) abgedeckt += 1;
        }

        ergebnis ~= BlockCoverage(block.name, block.first, block.last, zugewiesen, abgedeckt);
    }

    return ergebnis;
}

/// Eine gefundene Sequenz samt Herkunft.
struct FoundSequence {
    string sequence;
    string result;
    string file;
    uint line;
}

/// Rueckwaertssuche: alle Sequenzen, deren Ergebnis das gesuchte Zeichen
/// enthaelt. Gesucht wird im fertigen Baum (dort steht, was tatsaechlich
/// herauskommt); die Herkunft kommt aus der Aufzeichnung, weil der Baum sie
/// nicht kennt.
FoundSequence[] auditFind(ref AuditData data, ComposeNode* root, dstring needle) {
    // Letzter Eintrag je Sequenz gewinnt - genau wie beim Laden. Geschluesselt
    // ueber keysymKey, nicht ueber die Anzeige-Sequenz - siehe dort.
    string[string] datei;
    uint[string] zeile;
    foreach (r; data.records) {
        // DUAL zaehlt mit wie ADDED/OVERWRITTEN: addComposeEntry schreibt bei
        // DUAL ebenfalls ein Ergebnis in den Baum, nur mit Doppelrolle - eine
        // gefundene Sequenz soll ihre Herkunft bekommen statt leer zu bleiben.
        if (r.outcome != ComposeOutcome.ADDED && r.outcome != ComposeOutcome.OVERWRITTEN
            && r.outcome != ComposeOutcome.DUAL) continue;
        const s = keysymKey(r.keysyms);
        datei[s] = modulName(r.file);
        zeile[s] = r.line;
    }

    FoundSequence[] treffer;

    foreach (blatt; allLeaves(root)) {
        if (blatt.result.length == 0) continue;
        if (!blatt.result.toUTF32.canFind(needle)) continue;

        const s = keysymKey(blatt.keysyms);
        const angezeigt = composeSequenceString(blatt.keysyms);
        treffer ~= FoundSequence(angezeigt, blatt.result.to!string,
            datei.get(s, ""), zeile.get(s, 0));
    }

    return treffer;
}

/// Ein zugewiesenes Zeichen eines Blocks, das der Compose-Bestand nicht liefert.
struct GapEntry {
    dchar codepoint;
    string name;
}

/// Was in einem Block namentlich fehlt. Bereichszeichen (CJK, Hangul) werden
/// bewusst nicht aufgezaehlt: Eine Liste mit 20 000 Ideogrammen hilft niemandem
/// bei der Kuratierung.
GapEntry[] auditGaps(bool[dchar] reachable, ref UnicodeData ucd, string blockName) {
    import std.algorithm : sort;

    GapEntry[] luecken;

    foreach (block; ucd.blocks) {
        if (block.name != blockName) continue;

        dchar[] kandidaten;
        foreach (cp, name; ucd.names) {
            if (cp >= block.first && cp <= block.last) kandidaten ~= cp;
        }
        kandidaten.sort();

        foreach (cp; kandidaten) {
            if (cp !in reachable) luecken ~= GapEntry(cp, nameOf(ucd, cp));
        }
    }

    return luecken;
}

/// Was mit einer Kandidatenzeile geschehen wuerde.
enum CheckKind {
    UNPARSED,     /// sieht wie ein Eintrag aus, laesst sich aber nicht lesen
    VOID_KEYSYM,  /// enthaelt einen Keysym-Namen, den keysymdef.h nicht kennt
    DUPLICATE,    /// Sequenz und Ergebnis stehen schon so im Bestand
    OVERWRITE,    /// Sequenz steht schon da, mit anderem Ergebnis
    DUAL,         /// macht einen Knoten doppelrollig - wird eingetragen
    REJECTED,     /// Kombination mit einem Sondermodus - wuerde verworfen
    FREE          /// kollisionsfrei
}

struct CheckFinding {
    uint line;
    string sequence;
    string result;
    CheckKind kind;
    string collidesWith;
}

/// Eine Kandidatendatei gegen den geladenen Bestand pruefen.
///
/// ACHTUNG: Traegt die Zeilen tatsaechlich in den uebergebenen Baum ein - nur
/// so gilt exakt dieselbe Kollisionslogik wie beim Laden, ohne sie ein zweites
/// Mal zu schreiben. Der Baum ist danach nicht mehr der geladene Bestand.
CheckFinding[] auditCheck(ref AuditData data, ComposeNode* root, string candidateFile) {
    import keysyms : KEYSYM_VOID;
    import std.file : read;
    import std.string : split;

    // Wer eine Sequenz zuletzt beigesteuert hat - fuer die Spalte "betrifft".
    // Geschluesselt ueber keysymKey, nicht ueber die Anzeige-Sequenz - siehe
    // dort.
    string[string] herkunft;
    foreach (r; data.records) {
        // DUAL zaehlt mit wie ADDED/OVERWRITTEN: addComposeEntry schreibt bei
        // DUAL ebenfalls ein Ergebnis in den Baum, nur mit Doppelrolle - eine
        // Kandidatenzeile, die genau diese Sequenz trifft, soll die Spalte
        // "betrifft" bekommen statt leer zu bleiben.
        if (r.outcome != ComposeOutcome.ADDED && r.outcome != ComposeOutcome.OVERWRITTEN
            && r.outcome != ComposeOutcome.DUAL) continue;
        herkunft[keysymKey(r.keysyms)] = modulName(r.file);
    }

    CheckFinding[] befunde;
    auto zeilen = (cast(string) read(candidateFile)).split("\n");

    foreach (index, zeile; zeilen) {
        const nummer = cast(uint)(index + 1);
        const art = classifyComposeLine(zeile);
        // Wie die uebrigen Aufrufer von classifyComposeLine in dieser Datei:
        // alles ausser ENTRY wird uebersprungen. Vorher stand hier nur
        // EMPTY/COMMENT - eine #klebrig-Zeile (DIRECTIVE) waere in einer
        // gepruften Kandidatendatei faelschlich als UNPARSED gemeldet worden.
        if (art != ComposeLineKind.ENTRY) continue;

        ComposeFileLine eintrag;
        try {
            eintrag = parseLine(zeile);
        } catch (Exception e) {
            befunde ~= CheckFinding(nummer, zeile, "", CheckKind.UNPARSED, "");
            continue;
        }

        const sequenz = composeSequenceString(eintrag.keysyms); // nur zur Anzeige
        const betrifft = herkunft.get(keysymKey(eintrag.keysyms), "");

        if (eintrag.keysyms.canFind(KEYSYM_VOID)) {
            befunde ~= CheckFinding(nummer, sequenz, eintrag.result.to!string,
                CheckKind.VOID_KEYSYM, betrifft);
            continue;
        }

        // Vor dem Eintragen fragen, ob Sequenz UND Ergebnis schon so dastehen -
        // addComposeEntry unterscheidet Duplikat und echte Ueberschreibung nicht.
        const istDuplikat = isEntryInComposeTree(eintrag, *root);

        const ausgang = addComposeEntry(eintrag, *root);

        CheckKind art2;
        final switch (ausgang) {
            case ComposeAddResult.ADDED:       art2 = CheckKind.FREE;      break;
            case ComposeAddResult.OVERWRITTEN: art2 = istDuplikat ? CheckKind.DUPLICATE
                                                                 : CheckKind.OVERWRITE; break;
            case ComposeAddResult.DUAL:      art2 = CheckKind.DUAL;     break;
            case ComposeAddResult.REJECTED:  art2 = CheckKind.REJECTED; break;
        }

        befunde ~= CheckFinding(nummer, sequenz, eintrag.result.to!string, art2,
            art2 == CheckKind.FREE ? "" : betrifft);
    }

    return befunde;
}

/// Ein Blatt des Baums fuer den Vergleich zweier Bestaende. sequence ist die
/// gerenderte Sequenz, NUR zur Anzeige (siehe keysymKey) - der Kartenschluessel
/// von leafMap ist etwas anderes.
struct LeafEntry {
    string sequence;
    string result;
}

/// Der fertige Baum als schlichte Abbildung Schluessel -> Blatt. Loest den
/// Baum vom globalen Zustand ab, damit zwei Ladevorgaenge vergleichbar werden -
/// collectAudit baut composeRoot jedes Mal neu auf.
///
/// Geschluesselt wird ueber keysymKey, NICHT ueber composeSequenceString: Zwei
/// verschiedene Keysyms mit demselben Codepunkt (XK_underscore/XK_underbar,
/// beide "_") wuerden sonst denselben Kartenschluessel treffen und eines der
/// beiden Blaetter stillschweigend verschlucken.
LeafEntry[string] leafMap(ComposeNode* root) {
    LeafEntry[string] karte;
    foreach (blatt; allLeaves(root)) {
        if (blatt.keysyms.length == 0) continue;
        karte[keysymKey(blatt.keysyms)] =
            LeafEntry(composeSequenceString(blatt.keysyms), blatt.result.to!string);
    }
    return karte;
}

enum DiffSide { ONLY_A, ONLY_B, DIFFERENT }

struct DiffEntry {
    string sequence;
    string resultA;
    string resultB;
    DiffSide side;
}

/// Zwei Bestaende gegeneinander. Sortiert nach dem verlustfreien Schluessel,
/// nicht nach der gerenderten Sequenz: Seitdem der Kartenschluessel von der
/// Anzeige entkoppelt ist, koennen zwei verschiedene Schluessel dieselbe
/// Anzeige haben (siehe keysymKey) - die Anzeige allein waere also keine
/// totale Ordnung mehr, und zwei Laeufe koennten bei Gleichstand in
/// unterschiedlicher Reihenfolge herauskommen.
DiffEntry[] auditDiff(const LeafEntry[string] a, const LeafEntry[string] b) {
    import std.algorithm : sort;
    import std.typecons : Tuple, tuple;

    Tuple!(string, DiffEntry)[] ergebnis;

    foreach (schluessel, eintragA; a) {
        if (auto eintragB = schluessel in b) {
            if (eintragB.result != eintragA.result) {
                ergebnis ~= tuple(schluessel,
                    DiffEntry(eintragA.sequence, eintragA.result, eintragB.result, DiffSide.DIFFERENT));
            }
        } else {
            ergebnis ~= tuple(schluessel,
                DiffEntry(eintragA.sequence, eintragA.result, "", DiffSide.ONLY_A));
        }
    }

    foreach (schluessel, eintragB; b) {
        if (schluessel !in a) {
            ergebnis ~= tuple(schluessel,
                DiffEntry(eintragB.sequence, "", eintragB.result, DiffSide.ONLY_B));
        }
    }

    ergebnis.sort!((x, y) => x[0] < y[0]);

    DiffEntry[] sortiert;
    foreach (e; ergebnis) sortiert ~= e[1];
    return sortiert;
}

/// Was eine Ebene traegt und wie viel davon auch per Compose erreichbar ist.
struct LayerReach {
    uint layer;
    uint codepoints;
    uint alsoCompose;
    dchar[] layerOnly;
}

/// Alle Codepunkte einer Ebene. Ueber describeKey, damit dieselbe Regel gilt
/// wie fuer Bildschirmtastatur und Belegungsblatt - insbesondere die
/// Zeichen-Keysym-Regel aus Paket 5c fuer VK-Tasten.
private bool[dchar] codepointsOfLayer(const NeoLayout* layout, uint ebene) {
    // Kein Modifier gehalten - fuer eine statische Betrachtung wie beim
    // Belegungsblatt. Dieselbe Annahme wie sheet.d. Als verschachtelte
    // Funktion, nicht auf Modulebene: &nichtsGehalten muss ein delegate
    // sein, describeKey verlangt keinen Funktionszeiger.
    bool nichtsGehalten(Modifier m) nothrow { return false; }

    bool[dchar] menge;

    foreach (scan, _; layout.map) {
        auto view = describeKey(layout, scan, ebene, false, &nichtsGehalten, false);
        foreach (cp; view.codepoints) menge[cp] = true;
    }

    return menge;
}

LayerReach[] auditLayers(bool[dchar] reachable, const NeoLayout* layout) {
    import std.algorithm : sort;

    LayerReach[] ergebnis;

    foreach (index; 0 .. layout.layers.length) {
        const ebene = cast(uint)(index + 1);
        auto aufEbene = codepointsOfLayer(layout, ebene);

        LayerReach zeile;
        zeile.layer = ebene;
        zeile.codepoints = cast(uint) aufEbene.length;

        foreach (cp, _; aufEbene) {
            if (cp in reachable) zeile.alsoCompose += 1;
            else zeile.layerOnly ~= cp;
        }

        zeile.layerOnly.sort();
        ergebnis ~= zeile;
    }

    return ergebnis;
}

/// Codepunkte, die nur ueber Compose erreichbar sind und auf keiner Ebene
/// liegen. Bewusst nur als Zahl: Es sind ueber dreitausend.
uint composeOnlyCount(bool[dchar] reachable, const NeoLayout* layout) {
    bool[dchar] aufEbenen;

    foreach (index; 0 .. layout.layers.length) {
        foreach (cp, _; codepointsOfLayer(layout, cast(uint)(index + 1))) {
            aufEbenen[cp] = true;
        }
    }

    uint nurCompose;
    foreach (cp, _; reachable) {
        if (cp !in aufEbenen) nurCompose += 1;
    }

    return nurCompose;
}

/// Wie eine Doppelung eingestuft ist (Spec 4). Die drei Werte sind
/// erschoepfend und schliessen einander aus - darauf steht die
/// Bilanz-Invariante im Test gegen den ausgelieferten Bestand.
enum SpiegelArt {
    REIHE,       /// Stufe 1: der Kopf der Sequenz traegt viele Blaetter
    MUSTER,      /// Stufe 2: eine benannte Endungs-Systematik
    EINZELFALL   /// Stufe 3: keins von beidem, Kandidat fuer den Schnitt
}

/// Eine Sequenz, deren Ergebnis auch auf einer Ebene des Layouts liegt.
struct SpiegelEintrag {
    string modul;
    uint zeile;
    string sequenz;      /// Anzeigeform ueber composeSequenceString
    dchar ergebnis;
    uint ebene;          /// niedrigste Ebene, die das Zeichen traegt
    SpiegelArt art;
    string kopf;         /// Anzeigeform des Kopfes, nur bei REIHE gefuellt
    uint kopfBlaetter;   /// Blattzahl unter dem Kopf, nur bei REIHE
    string muster;       /// Name der Endungs-Systematik, nur bei MUSTER
    bool anderswo;       /// dasselbe Zeichen liefert noch eine andere Sequenz
}

/// Vorgabe des Siebs (Spec 4.4). Ausdruecklich eine Einstellung, kein
/// Wahrheitswert: Der Rest waechst mit der Schwelle gleichmaessig, es gibt
/// keinen natuerlichen Knick. Deshalb steht der Wert hier und nicht in der
/// Regel, und deshalb haengt an ihm auch kein Waechtertest.
enum uint SPIEGEL_SCHWELLE = 8;

/// Der Kopf einer Sequenz: das erste Keysym, bei Multi_key die ersten zwei
/// (Spec 4.1). Ein leerer Pfad hat keinen Kopf.
private const(uint)[] spiegelKopf(const uint[] pfad, uint multiKey) {
    if (pfad.length == 0) return null;
    if (pfad[0] == multiKey && pfad.length >= 2) return pfad[0 .. 2];
    return pfad[0 .. 1];
}

/// Das eine Zeichen eines Ergebnisses. Falsch bei leerem oder mehrzeichigem
/// Ergebnis: Ein mehrzeichiges kann kein Spiegel einer Ebenenzelle sein
/// (Spec 3). Gerechnet wird in UTF-32, damit ein Surrogatpaar ein Zeichen
/// bleibt und nicht als zwei zaehlt.
private bool spiegelZeichen(wstring ergebnis, out dchar zeichen) {
    if (ergebnis.length == 0) return false;

    auto voll = ergebnis.toUTF32;
    if (voll.length != 1) return false;

    zeichen = voll[0];
    return true;
}

/// Zu jedem Codepunkt die niedrigste Ebene, die ihn traegt (Spec 5).
/// Rueckwaerts durch die Ebenen, damit die niedrigste zuletzt schreibt und
/// damit gewinnt.
private uint[dchar] niedrigsteEbeneJeCodepunkt(const NeoLayout* layout) {
    uint[dchar] ergebnis;

    foreach_reverse (index; 0 .. layout.layers.length) {
        const ebene = cast(uint)(index + 1);
        foreach (cp, _; codepointsOfLayer(layout, ebene)) ergebnis[cp] = ebene;
    }

    return ergebnis;
}

/// Die benannten Endungs-Systematiken aus Spec 4.2 - das einzige von Hand
/// gepflegte Stueck der ganzen Regel. Keysym-NAMEN statt Zahlen, weil
/// keysymdef.h zur Laufzeit geparst wird. Laengere Endungen stehen zuerst,
/// damit <dead_stroke> <dead_stroke> nicht von einer einteiligen Regel
/// abgefangen wird.
private struct Endungsmuster {
    string[] endung;   /// Keysym-Namen in Sequenzreihenfolge
    string name;
}

private Endungsmuster[] endungsmuster() {
    return [
        Endungsmuster(["dead_stroke", "dead_stroke"], "Negation"),
        Endungsmuster(["U0338"], "Negation"),
        Endungsmuster(["underscore"], "oder-gleich"),
        Endungsmuster(["underbar"], "oder-gleich")
    ];
}

/// Traegt der Pfad eine benannte Endungs-Systematik? Leerer Rueckgabewert
/// heisst nein.
private string spiegelMuster(const uint[] pfad, const(uint)[][] endungen,
                             const string[] namen) {
    foreach (i, endung; endungen) {
        // Der Kopf muss uebrig bleiben: Eine Sequenz, die NUR aus der Endung
        // besteht, ist keine Ableitung von etwas.
        if (pfad.length <= endung.length) continue;
        if (pfad[$ - endung.length .. $] == endung) return namen[i];
    }

    // Die generische Verdopplung zuletzt. Sie traegt keine Bedeutung - <E><E>
    // gibt Ə, <f><f> gibt ﬀ, <7><7> gibt ⁊, und das hat nichts miteinander zu
    // tun (Spec 7). Sie steht hier nur als SCHUTZmuster: im Zweifel behalten.
    // Mindestlaenge 3, damit ein Kopf aus zwei gleichen Keysyms nicht sich
    // selbst als Verdopplung meldet.
    if (pfad.length >= 3 && pfad[$ - 1] == pfad[$ - 2]) return "Verdopplung";

    return "";
}

/// Jede Sequenz, deren Ergebnis auch auf einer Ebene des Layouts liegt,
/// samt Einstufung nach Spec 4. Rein: kein Win32, kein Cairo, keine Ausgabe.
///
/// "schwelle" ist die Blattzahl, ab der ein Kopf als Systematik gilt.
SpiegelEintrag[] auditSpiegel(ref AuditData daten, ComposeNode* root,
                              const NeoLayout* layout, uint schwelle) {
    import keysyms : KEYSYM_VOID, parseKeysym;

    // Herkunft je Sequenz - letzter Eintrag gewinnt, genau wie beim Laden.
    // Dasselbe Muster wie in auditFind, geschluesselt ueber keysymKey und
    // nicht ueber die Anzeige-Sequenz (siehe dort: underscore und underbar
    // sehen gleich aus und sind es nicht).
    string[string] datei;
    uint[string] zeile;
    foreach (r; daten.records) {
        // DUAL zaehlt mit wie ADDED/OVERWRITTEN: siehe Begruendung in
        // auditFind oben, dasselbe Muster.
        if (r.outcome != ComposeOutcome.ADDED && r.outcome != ComposeOutcome.OVERWRITTEN
            && r.outcome != ComposeOutcome.DUAL) continue;
        const s = keysymKey(r.keysyms);
        datei[s] = modulName(r.file);
        zeile[s] = r.line;
    }

    const multiKey = parseKeysym("Multi_key");
    auto blaetter = allLeaves(root);

    // Blattzahl je Kopf. Ueber die Blaetter gruppiert statt je Kopf durch den
    // Baum navigiert - dasselbe Mass (Spec 5 verlangt die BLATTZAHL, nicht
    // next.length), aber ein Durchlauf statt einer Baumsuche je Zeile.
    uint[string] blaetterJeKopf;
    foreach (blatt; blaetter) {
        auto kopf = spiegelKopf(blatt.keysyms, multiKey);
        if (kopf.length == 0) continue;
        blaetterJeKopf[keysymKey(kopf)] += 1;
    }

    // Wie oft liefert ein Zeichen ueberhaupt eine Sequenz? Fuer die Spalte
    // "auch anderswo" - ausweisen, nicht bewerten (Spec 3).
    uint[dchar] vorkommen;
    foreach (blatt; blaetter) {
        dchar cp;
        if (spiegelZeichen(blatt.result, cp)) vorkommen[cp] += 1;
    }

    auto ebeneVon = niedrigsteEbeneJeCodepunkt(layout);

    // Die Endungsmuster einmal aufloesen. Ein unbekannter Name wird von
    // parseKeysym zu KEYSYM_VOID; ein solches Muster faellt raus, statt auf
    // jedes VOID im Bestand zu passen.
    const(uint)[][] endungen;
    string[] musterNamen;
    foreach (m; endungsmuster()) {
        uint[] werte;
        bool bekannt = true;
        foreach (name; m.endung) {
            const k = parseKeysym(name);
            if (k == KEYSYM_VOID) { bekannt = false; break; }
            werte ~= k;
        }
        if (!bekannt) continue;
        endungen ~= werte;
        musterNamen ~= m.name;
    }

    SpiegelEintrag[] ergebnis;

    foreach (blatt; blaetter) {
        dchar cp;
        if (!spiegelZeichen(blatt.result, cp)) continue;

        const ebene = ebeneVon.get(cp, 0);
        if (ebene == 0) continue;   // liegt auf keiner Ebene, also keine Doppelung

        SpiegelEintrag e;
        const s = keysymKey(blatt.keysyms);
        e.modul = datei.get(s, "");
        e.zeile = zeile.get(s, 0);
        e.sequenz = composeSequenceString(blatt.keysyms);
        e.ergebnis = cp;
        e.ebene = ebene;
        e.anderswo = vorkommen.get(cp, 0) > 1;

        auto kopf = spiegelKopf(blatt.keysyms, multiKey);
        const kopfZahl = kopf.length > 0 ? blaetterJeKopf.get(keysymKey(kopf), 0) : 0;

        if (kopfZahl >= schwelle) {
            e.art = SpiegelArt.REIHE;
            e.kopf = composeSequenceString(kopf);
            e.kopfBlaetter = kopfZahl;
        } else {
            const name = spiegelMuster(blatt.keysyms, endungen, musterNamen);
            if (name.length > 0) {
                e.art = SpiegelArt.MUSTER;
                e.muster = name;
            } else {
                e.art = SpiegelArt.EINZELFALL;
            }
        }

        ergebnis ~= e;
    }

    return ergebnis;
}

version (unittest) {
    import composer;
    import keysyms : initKeysyms;
    import std.algorithm : canFind, count, filter, map;
    import std.array : array;
}

unittest {
    // collectAudit laedt eine Auswahl und zeichnet dabei jede Zeile auf. Die
    // Aufzeichnung muss zur Buchfuehrung von composer.d passen - dieselbe
    // Eigenschaft wie im Anti-Drift-Test, hier aber ueber die Schnittstelle,
    // die das Werkzeug tatsaechlich benutzt.
    initKeysyms(".");

    auto daten = collectAudit(".", ["base", "diacritics"]);

    assert(daten.records.length > 0);
    // moduleOrder kommt aus composeStatsOrder, nicht aus der Konfiguration -
    // deshalb steht hier auch "(built-in)": initCompose traegt die drei
    // eingebauten Sonderroutinen (Unicode-Eingabe, roemische Zahlen) am Ende
    // jeder Ladung ein, unabhaengig von der Auswahl (siehe composer.d,
    // addBuiltinComposeEntry). Eine Datei ohne Eintraege wuerde hier ebenso
    // auffallen.
    assert(daten.moduleOrder == ["base", "diacritics", COMPOSE_BUILTIN_NAME]);
    assert(daten.records.canFind!(r => r.outcome == ComposeOutcome.ADDED));

    // Nach dem Sammeln steht der Baum. Jedes Blatt ist ueber mindestens einen
    // Keysym-Schritt erreicht - eine leere Sequenz gaebe es nur, wenn schon
    // die Wurzel selbst keine Kinder haette (leerer Baum), was hier nicht
    // zutrifft.
    auto blaetter = allLeaves(&composeRoot);
    assert(blaetter.length > 0);
    foreach (blatt; blaetter) assert(blatt.keysyms.length > 0);

    // Die meisten Blaetter tragen ein Ergebnis; genau drei nicht - das sind
    // die eingebauten Sonderroutinen (Unicode-Eingabe, kleine und grosse
    // roemische Zahlen), deren Endknoten ueber specialMode statt ueber result
    // gehen. Gemessen am 02.08.2026 fuer diese Modulauswahl (base+diacritics).
    assert(blaetter.count!(b => b.result.length == 0) == 3);

    auto erreichbar = reachableCodepoints(&composeRoot);
    // "æ" (aus <a><e>) traegt ausschliesslich en_US.module, das hier nicht
    // geladen ist - gemessen am 02.08.2026 (grep ueber compose/*.module).
    // "ø" (<dead_stroke><o>) steht dagegen in base.module und ist damit die
    // richtige Stichprobe fuer diese Modulauswahl.
    assert(dchar('ø') in erreichbar, "base.module traegt ø");
}

unittest {
    // auditOrigin fasst je Datei zusammen, was sie beigetragen hat, und haelt
    // fest, wer wen ueberschrieben hat. Das beantwortet die Kernfrage der
    // Ausduennung: was verliere ich, wenn ein Modul fliegt.
    initKeysyms(".");

    auto daten = collectAudit(".", ["base", "en_US"]);
    auto herkunft = auditOrigin(daten);

    assert(herkunft.length >= 2);
    assert(herkunft[0].name == "base");
    assert(herkunft[0].added > 0);

    // en_US ueberschreibt bekanntermassen Eintraege; wer ueberschrieben wurde,
    // muss auf der Gegenseite auftauchen - das ist der hole(*voriges)-Pfad,
    // den das "Achtung"-Merkblatt zum Task als fragil markiert.
    auto enUS = herkunft.filter!(h => h.name == "en_US").array;
    assert(enUS.length == 1);
    foreach (sequenz; enUS[0].overwrote) {
        assert(sequenz.length > 0);
    }

    // Opferseite: base ist vor en_US geladen, kann also nur von en_US
    // ueberschrieben werden, nie umgekehrt. Gemessen am 02.08.2026 fuer
    // diese Modulauswahl (base+en_US) traegt en_US 57 OVERWRITTEN-Zeilen,
    // von denen 46 base als Opfer haben (die restlichen 11 sind Duplikate
    // innerhalb von en_US.module selbst). 46 liegt ueber dem Deckel
    // ORIGIN_CASE_LIMIT (40), die Liste ist also randvoll - der staerkste
    // Test hier ist deshalb die exakte Deckelhoehe, nicht nur "nicht leer".
    assert(herkunft[0].overwrittenBy.length == ORIGIN_CASE_LIMIT);
    foreach (sequenz; herkunft[0].overwrittenBy) {
        assert(sequenz.length > 0);
    }

    // Kreuzprobe: dieselbe Sequenz taucht auf beiden Seiten auf - bei en_US
    // als "habe weggenommen", bei base als "wurde mir weggenommen".
    assert(enUS[0].overwrote.canFind("<Multi_key> f f"));
    assert(herkunft[0].overwrittenBy.canFind("<Multi_key> f f"));
}

unittest {
    // Fixrunde 1 zu Task 2: DUAL traegt wie ADDED ein Ergebnis in den Baum
    // ein (addComposeEntry schreibt es), zaehlt fuer die Gegenrichtung also
    // ebenso als "zuletzt eingetragen". Zwei Module: das erste stellt per
    // DUAL eine Doppelrolle her, das zweite ueberschreibt genau diese
    // Sequenz - das Opfer muss die Sequenz in seiner overwrittenBy-Liste
    // tragen, auch wenn sie per DUAL und nicht per ADDED hineinkam.
    import std.exception : collectException;
    import std.file : mkdirRecurse, remove, rmdir, tempDir, write;
    import std.path : buildPath;

    initKeysyms(".");

    auto verzeichnis = buildPath(tempDir(), "ananeo-origin-dual-test");
    auto composeDir = buildPath(verzeichnis, "compose");
    mkdirRecurse(composeDir);

    scope(exit) {
        collectException(remove(buildPath(composeDir, "basis.module")));
        collectException(remove(buildPath(composeDir, "spaeter.module")));
        collectException(rmdir(composeDir));
        collectException(rmdir(verzeichnis));
    }

    write(buildPath(composeDir, "basis.module"),
        `<Multi_key> <a> : "A"` ~ "\n" ~              // ADDED
        `<Multi_key> <a> <b> : "AB"` ~ "\n");         // DUAL - erstes Kind unter <a>

    write(buildPath(composeDir, "spaeter.module"),
        `<Multi_key> <a> <b> : "XY"` ~ "\n");         // OVERWRITE der per DUAL geladenen Sequenz

    auto daten = collectAudit(verzeichnis, ["basis", "spaeter"]);
    auto herkunft = auditOrigin(daten);

    auto basis = herkunft.filter!(h => h.name == "basis").array;
    auto spaeter = herkunft.filter!(h => h.name == "spaeter").array;
    assert(basis.length == 1 && spaeter.length == 1);

    assert(basis[0].dual == 1, "die Multi_key-a-b-Zeile in basis ist DUAL");
    assert(spaeter[0].overwritten == 1);

    // Der eigentliche Fund: ohne den Fix bleibt overwrittenBy leer, weil
    // letzterEintrag fuer DUAL nie gesetzt wurde.
    assert(basis[0].overwrittenBy.canFind("<Multi_key> a b"),
        "das Opfer eines DUAL-Eintrags muss in overwrittenBy auftauchen");
}

unittest {
    // Eine .remove-Zeile, die nie greift, ist toter Ballast - oder ein Hinweis
    // darauf, dass sich das zugehoerige Modul geaendert hat. Beides will man
    // sehen, bevor man ausduennt.
    //
    // Gegen einen Kunstfall statt gegen den ausgelieferten Bestand: Dort weiss
    // heute niemand, ob es tote Zeilen gibt - ein Test, der nur ueber das
    // Ergebnis iteriert, bestuende bei null Treffern, ohne etwas geprueft zu
    // haben. Hier ist die Zahl bekannt.
    import std.exception : collectException;
    import std.file : mkdirRecurse, remove, rmdir, tempDir, write;
    import std.path : buildPath;

    initKeysyms(".");

    auto verzeichnis = buildPath(tempDir(), "ananeo-deadremove-test");
    auto composeDir = buildPath(verzeichnis, "compose");
    mkdirRecurse(composeDir);
    // DMD erlaubt kein try/catch direkt im Rumpf von scope(exit) - deshalb
    // collectException je Aufraeumschritt statt eines gemeinsamen catch-Blocks.
    scope(exit) {
        collectException(remove(buildPath(composeDir, "probe.module")));
        collectException(remove(buildPath(composeDir, "probe.remove")));
        collectException(rmdir(composeDir));
        collectException(rmdir(verzeichnis));
    }

    write(buildPath(composeDir, "probe.module"),
        `<Multi_key> <a> : "A"` ~ "\n" ~
        `<Multi_key> <b> : "B"` ~ "\n");

    write(buildPath(composeDir, "probe.remove"),
        `<Multi_key> <a> : "A"` ~ "\n" ~      // Zeile 1: greift
        `<Multi_key> <z> : "Z"` ~ "\n" ~      // Zeile 2: laeuft ins Leere
        `<Multi_key> <b> "y"` ~ "\n");        // Zeile 3: sieht wie ein Eintrag
                                              // aus (faengt mit '<' an), hat
                                              // aber kein ':' - parseLine
                                              // wirft, derselbe Zeilentyp wie
                                              // Task 2s UNPARSED-Fixture.

    auto daten = collectAudit(verzeichnis, ["probe"]);
    auto tote = auditDeadRemoves(verzeichnis, ["probe"], daten);

    assert(tote.length == 2, "eine tote und eine unlesbare .remove-Zeile erwartet");
    assert(tote[0].file == "probe.remove");
    assert(tote[0].line == 2);
    assert(tote[0].sequence.length > 0);

    assert(tote[1].file == "probe.remove");
    assert(tote[1].line == 3);
    assert(tote[1].sequence.canFind("(nicht lesbar)"),
        "eine kaputte .remove-Zeile muss als unlesbar markiert sein");
}

unittest {
    // Ein unbekannter Keysym-Name wird von parseKeysym zu KEYSYM_VOID, ohne zu
    // werfen. Die Sequenz landet dann im Baum - auf demselben Knoten wie jeder
    // andere Tippfehler. auditVoidKeysyms macht das sichtbar.
    import keysyms : KEYSYM_VOID;
    import std.exception : collectException;
    import std.file : mkdirRecurse, remove, rmdir, write;
    import std.path : buildPath;
    import std.file : tempDir;

    initKeysyms(".");

    auto verzeichnis = buildPath(tempDir(), "ananeo-void-test");
    auto composeDir = buildPath(verzeichnis, "compose");
    mkdirRecurse(composeDir);
    // DMD erlaubt kein try/catch direkt im Rumpf von scope(exit) - deshalb
    // collectException je Aufraeumschritt statt eines gemeinsamen catch-Blocks.
    scope(exit) {
        collectException(remove(buildPath(composeDir, "probe.module")));
        collectException(rmdir(composeDir));
        collectException(rmdir(verzeichnis));
    }

    write(buildPath(composeDir, "probe.module"),
        `<Multi_key> <a> : "x"` ~ "\n" ~
        `<Multi_key> <GibtesNicht> : "y"` ~ "\n");

    auto daten = collectAudit(verzeichnis, ["probe"]);
    auto kaputt = auditVoidKeysyms(daten);

    assert(kaputt.length == 1, "genau eine Sequenz mit unbekanntem Keysym erwartet");
    assert(kaputt[0].line == 2);
}

unittest {
    // Namensraum-Karte: Welche Fortsetzungen gibt es unter einem Praefix, wie
    // viele Blaetter haengen daran, und welche Knoten blockieren jede
    // Verlaengerung, weil sie selbst ein Ergebnis tragen. Das ist die
    // Grundlage fuer den Entwurf der systematischen Grammatik.
    ComposeNode wurzel;

    cast(void) addComposeEntry(ComposeFileLine([1u, 2u], "ab"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([1u, 3u], "ac"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([1u, 4u, 5u], "ade"w, null), wurzel);

    auto karte = auditNamespace(&wurzel, [1u]);

    assert(karte.length == 3, "drei Fortsetzungen unter Keysym 1");

    auto vier = karte.filter!(e => e.children == 1).array;
    assert(vier.length == 1, "genau ein Zweig geht weiter");
    assert(vier[0].leaves == 1);
    assert(!vier[0].terminal);

    auto blaetter = karte.filter!(e => e.children == 0).array;
    assert(blaetter.length == 2);
    foreach (b; blaetter) {
        assert(b.terminal, "ein Blatt mit Ergebnis blockiert jede Verlaengerung");
        assert(b.leaves == 1);
    }

    // Praefix, der von der Wurzel aus schon am ersten Schritt ins Leere laeuft
    // - kein Kind traegt das Keysym 999.
    assert(auditNamespace(&wurzel, [999u]).length == 0,
        "unbekanntes Keysym direkt an der Wurzel liefert eine leere Karte");

    // Praefix, der teilweise einen gueltigen Weg nimmt (1 existiert), dann aber
    // an einem zweiten, nicht vorhandenen Keysym scheitert. Das ist der Fall,
    // den die fruehe Rueckkehr in der Schleife tatsaechlich absichert - anders
    // als beim Scheitern gleich am ersten Schritt oben.
    assert(auditNamespace(&wurzel, [1u, 999u]).length == 0,
        "gueltiger erster Schritt, dann unbekanntes zweites Keysym liefert eine leere Karte");
}

unittest {
    // Ohne Praefix liefert die Karte die Startzeichen des Baums - bei uns im
    // Wesentlichen Multi_key und die Tottasten.
    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([1u, 2u], "x"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([9u, 2u], "y"w, null), wurzel);

    auto karte = auditNamespace(&wurzel, []);
    assert(karte.length == 2);

    // Beide Startzeichen sind selbst Praefixe (je ein Kind, keine Sackgasse) -
    // die Felder, die der Unterbefehl tatsaechlich ausgibt, muessen stimmen.
    foreach (eintrag; karte) {
        assert(eintrag.children == 1, "je ein Kind unter jedem Startzeichen");
        assert(eintrag.leaves == 1, "genau ein Blatt im jeweiligen Teilbaum");
        assert(!eintrag.terminal, "keines der Startzeichen traegt selbst ein Ergebnis");
        assert(eintrag.prefix.length > 0, "die lesbare Sequenz darf nicht leer sein");
    }

    auto eins = karte.filter!(e => e.prefix == composeSequenceString([1u])).array;
    assert(eins.length == 1, "das Startzeichen fuer Keysym 1 muss in der Karte stehen");

    auto neun = karte.filter!(e => e.prefix == composeSequenceString([9u])).array;
    assert(neun.length == 1, "das Startzeichen fuer Keysym 9 muss in der Karte stehen");
}

unittest {
    // Abdeckung je Block, gegen einen synthetischen UCD-Auszug. Der Nenner
    // sind zugewiesene Zeichen, nicht die Blockgroesse - das ist die
    // Korrektur an der Messmethode der 3b-Vorarbeit.
    import unicodedata : parseUnicodeData;

    auto ucd = parseUnicodeData(
        "0041;LATIN CAPITAL LETTER A;Lu;0;L;;;;;N;;;;0061;\n" ~
        "0042;LATIN CAPITAL LETTER B;Lu;0;L;;;;;N;;;;0062;\n" ~
        "0043;LATIN CAPITAL LETTER C;Lu;0;L;;;;;N;;;;0063;\n",
        "0040..004F; Testblock\n");

    bool[dchar] erreichbar;
    erreichbar['A'] = true;

    auto abdeckung = auditCoverage(erreichbar, ucd);

    assert(abdeckung.length == 1);
    assert(abdeckung[0].block == "Testblock");
    assert(abdeckung[0].assigned == 3, "drei zugewiesene Zeichen, nicht 16 Blockplaetze");
    assert(abdeckung[0].covered == 1);

    auto luecken = auditGaps(erreichbar, ucd, "Testblock");
    assert(luecken.length == 2);
    assert(luecken[0].codepoint == 'B');
    assert(luecken[0].name == "LATIN CAPITAL LETTER B");
    assert(luecken[1].codepoint == 'C');
}

unittest {
    // Ein unbekannter Blockname liefert eine leere Liste, keinen Absturz.
    import unicodedata : parseUnicodeData;

    auto ucd = parseUnicodeData("", "0000..000F; Nur dieser\n");
    bool[dchar] leer;
    assert(auditGaps(leer, ucd, "Gibt es nicht").length == 0);
}

unittest {
    // Rueckwaertssuche: Welche Sequenz liefert ein bestimmtes Zeichen? Die
    // Herkunft kommt aus der Aufzeichnung, nicht aus dem Baum - der Baum weiss
    // nicht, wer ihn gefuellt hat.
    //
    // Modul en_US statt base: "æ" (<a><e>) traegt ausschliesslich
    // en_US.module (siehe Kommentar bei reachableCodepoints oben, gemessen am
    // 02.08.2026) - base.module allein wuerde die Assertion unten vakuos
    // durchfallen lassen.
    initKeysyms(".");

    auto daten = collectAudit(".", ["en_US"]);
    auto treffer = auditFind(daten, &composeRoot, "æ"d);

    assert(treffer.length >= 1, "en_US.module liefert æ");
    foreach (t; treffer) {
        assert(t.result == "æ");
        assert(t.sequence.length > 0);
        assert(t.file == "en_US");
        assert(t.line >= 1);
    }
}

unittest {
    // Ein Zeichen, das niemand liefert, ergibt eine leere Liste.
    initKeysyms(".");
    auto daten = collectAudit(".", ["base"]);
    assert(auditFind(daten, &composeRoot, "\U0001FA00"d).length == 0);
}

unittest {
    // check prueft eine Kandidatendatei gegen den geladenen Bestand, ohne sie
    // in composeModules einzutragen. Jede der sieben Befundarten muss sich
    // ausloesen lassen.
    import std.exception : collectException;
    import std.file : mkdirRecurse, remove, rmdir, tempDir, write;
    import std.path : buildPath;

    initKeysyms(".");

    auto verzeichnis = buildPath(tempDir(), "ananeo-check-test");
    auto composeDir = buildPath(verzeichnis, "compose");
    mkdirRecurse(composeDir);

    auto kandidat = buildPath(verzeichnis, "kandidat.module");
    // DMD erlaubt kein try/catch direkt im Rumpf von scope(exit) - deshalb
    // collectException je Aufraeumschritt statt eines gemeinsamen catch-Blocks.
    scope(exit) {
        collectException(remove(buildPath(composeDir, "bestand.module")));
        collectException(remove(kandidat));
        collectException(rmdir(composeDir));
        collectException(rmdir(verzeichnis));
    }

    write(buildPath(composeDir, "bestand.module"),
        `<Multi_key> <a> : "A"` ~ "\n" ~
        `<Multi_key> <b> <c> : "BC"` ~ "\n");

    write(kandidat,
        "# Kommentar, wird uebergangen\n" ~          // ignoriert
        `<Multi_key> <a> : "A"` ~ "\n" ~             // Zeile 2: DUPLICATE
        `<Multi_key> <b> : "B"` ~ "\n" ~             // Zeile 3: DUAL (frueher PREFIX)
        `<Multi_key> <a> <x> : "AX"` ~ "\n" ~        // Zeile 4: DUAL (frueher EXTENSION)
        `<Multi_key> <z> : "Z"` ~ "\n" ~             // Zeile 5: FREE
        `<Multi_key> <GibtesNicht> : "V"` ~ "\n" ~   // Zeile 6: VOID_KEYSYM
        `<Multi_key> <q> "Q"` ~ "\n" ~               // Zeile 7: UNPARSED
        `<Multi_key> <b> <c> : "XY"` ~ "\n" ~        // Zeile 8: OVERWRITE (anderes
                                                      // Ergebnis als das bestehende "BC")
        `<Multi_key> <u> <u> <x> : "UX"` ~ "\n" ~    // Zeile 9: REJECTED (Fortsetzung
                                                      // hinter dem eingebauten Unicode-
                                                      // Sondermodus Multi_key u u)
        "#klebrig <Multi_key> <a>\n");                // Zeile 10: Direktive, kein Befund

    auto daten = collectAudit(verzeichnis, ["bestand"]);
    auto befunde = auditCheck(daten, &composeRoot, kandidat);

    CheckKind artVon(uint zeile) {
        foreach (b; befunde) if (b.line == zeile) return b.kind;
        assert(false, "kein Befund fuer Zeile");
    }

    assert(befunde.length == 8, "acht Eintragszeilen - Kommentar und Direktive zaehlen nicht");
    assert(artVon(2) == CheckKind.DUPLICATE);
    assert(artVon(3) == CheckKind.DUAL);
    assert(artVon(4) == CheckKind.DUAL);
    assert(artVon(5) == CheckKind.FREE);
    assert(artVon(6) == CheckKind.VOID_KEYSYM);
    assert(artVon(7) == CheckKind.UNPARSED);
    assert(artVon(9) == CheckKind.REJECTED);
    assert(artVon(8) == CheckKind.OVERWRITE);
    // Die Zusatzanforderung dieses Tasks: eine #klebrig-Zeile (DIRECTIVE) darf
    // in auditCheck keinen Befund erzeugen - insbesondere keinen UNPARSED. Vor
    // der Korrektur (art == EMPTY || art == COMMENT statt art != ENTRY) waere
    // sie faelschlich als UNPARSED gemeldet worden.
    foreach (b; befunde) assert(b.line != 10, "die Direktive darf keinen Befund erzeugen");

    // Die Herkunft des betroffenen Eintrags muss benannt sein - fuer DUPLICATE
    // wie fuer OVERWRITE.
    foreach (b; befunde) {
        if (b.kind == CheckKind.DUPLICATE || b.kind == CheckKind.OVERWRITE) {
            assert(b.collidesWith == "bestand");
        }
    }
}

unittest {
    // Fixrunde 1 zu Task 2: der Herkunftsfilter in auditCheck schloss DUAL
    // aus - eine Kandidatenzeile, die eine per DUAL geladene Sequenz trifft,
    // bekam deshalb eine leere "betrifft"-Spalte statt des Modulnamens.
    import std.exception : collectException;
    import std.file : mkdirRecurse, remove, rmdir, tempDir, write;
    import std.path : buildPath;

    initKeysyms(".");

    auto verzeichnis = buildPath(tempDir(), "ananeo-check-dual-test");
    auto composeDir = buildPath(verzeichnis, "compose");
    mkdirRecurse(composeDir);

    auto kandidat = buildPath(verzeichnis, "kandidat.module");
    scope(exit) {
        collectException(remove(buildPath(composeDir, "bestand.module")));
        collectException(remove(kandidat));
        collectException(rmdir(composeDir));
        collectException(rmdir(verzeichnis));
    }

    write(buildPath(composeDir, "bestand.module"),
        `<Multi_key> <a> : "A"` ~ "\n" ~              // ADDED
        `<Multi_key> <a> <b> : "AB"` ~ "\n");         // DUAL - erstes Kind unter <a>

    // Exaktes Duplikat der per DUAL geladenen Sequenz.
    write(kandidat, `<Multi_key> <a> <b> : "AB"` ~ "\n");

    auto daten = collectAudit(verzeichnis, ["bestand"]);
    auto befunde = auditCheck(daten, &composeRoot, kandidat);

    assert(befunde.length == 1);
    assert(befunde[0].kind == CheckKind.DUPLICATE);
    // Der eigentliche Fund: ohne den Fix bleibt collidesWith leer, weil der
    // Herkunftsfilter DUAL-Records ausschloss.
    assert(befunde[0].collidesWith == "bestand",
        "eine per DUAL geladene Sequenz muss als Herkunft erkannt werden");
}

unittest {
    // Differenz zweier Auswahlen. Der Test bildet die Aliasfalle ausdruecklich
    // ab: Erst A laden und retten, dann B laden.
    initKeysyms(".");

    // Der Rueckgabewert von collectAudit wird hier nicht gebraucht - nur der
    // Nebeneffekt zaehlt (composeRoot wird neu aufgebaut), und leafMap rettet
    // das Ergebnis, bevor der naechste Ladevorgang composeRoot ueberschreibt.
    cast(void) collectAudit(".", ["base"]);
    auto a = leafMap(&composeRoot);

    cast(void) collectAudit(".", ["base", "diacritics"]);
    auto b = leafMap(&composeRoot);

    assert(a.length > 0 && b.length > a.length,
        "diacritics muss Sequenzen hinzufuegen");

    auto unterschiede = auditDiff(a, b);

    assert(unterschiede.length > 0);
    // Alles, was nur in B steht, kommt aus diacritics.
    assert(unterschiede.canFind!(d => d.side == DiffSide.ONLY_B));
    // Nichts darf allein in A stehen: B enthaelt A vollstaendig.
    assert(!unterschiede.canFind!(d => d.side == DiffSide.ONLY_A),
        "B ist eine Obermenge von A");
}

unittest {
    // Gleiche Sequenz, anderes Ergebnis ist ein eigener Fall - genau das
    // passiert, wenn ein Modul ein anderes ueberschreibt.
    LeafEntry[string] a = ["x": LeafEntry("x", "eins")];
    LeafEntry[string] b = ["x": LeafEntry("x", "zwei")];

    auto unterschiede = auditDiff(a, b);
    assert(unterschiede.length == 1);
    assert(unterschiede[0].side == DiffSide.DIFFERENT);
    assert(unterschiede[0].resultA == "eins");
    assert(unterschiede[0].resultB == "zwei");
}

unittest {
    // Regressionstest fuer den Kartenschluessel-Fund aus der Codereview:
    // XK_underscore (0x005F) und der APL-Keysym XK_underbar (0x0BC6) tragen
    // beide den Codepunkt U+005F und rendern deshalb bei
    // composeSequenceString identisch zu "_". Wird die gerenderte Sequenz als
    // Kartenschluessel benutzt (der Fehler, den dieser Task behebt), kollabieren
    // beide auf einen Eintrag - genau das hat compose diff verfaelscht (96 von
    // 8854 Blaettern kollabierten auf 8758 Schluessel, gemessen von der
    // Codereview).
    enum XK_UNDERSCORE = 0x005Fu;
    enum XK_UNDERBAR = 0x0BC6u;

    initKeysyms(".");

    // Beide rendern identisch - sonst waere die folgende Assertion die
    // eigentliche Aussage des Tests, nicht bloss eine Randbedingung, die
    // belegt, dass der Testfall die reale Kollision trifft.
    assert(composeSequenceString([XK_UNDERSCORE]) == "_",
        "XK_underscore muss als \"_\" gerendert werden");
    assert(composeSequenceString([XK_UNDERBAR]) == "_",
        "XK_underbar muss ebenfalls als \"_\" gerendert werden - sonst ist das "
      ~ "nicht der Kollisionsfall");

    ComposeNode beideBlaetter;
    cast(void) addComposeEntry(ComposeFileLine([XK_UNDERSCORE], "eins"w, null), beideBlaetter);
    cast(void) addComposeEntry(ComposeFileLine([XK_UNDERBAR], "zwei"w, null), beideBlaetter);

    auto karte = leafMap(&beideBlaetter);
    assert(karte.length == 2,
        "zwei verschiedene Keysyms mit gleichem Codepunkt muessen zwei Kartenschluessel bleiben");

    ComposeNode nurUnderscore;
    cast(void) addComposeEntry(ComposeFileLine([XK_UNDERSCORE], "eins"w, null), nurUnderscore);
    auto karteNurEins = leafMap(&nurUnderscore);

    auto unterschiede = auditDiff(karteNurEins, karte);
    assert(unterschiede.length == 1,
        "genau ein Unterschied: das zusaetzliche Blatt XK_underbar");
    assert(unterschiede[0].side == DiffSide.ONLY_B);
}

unittest {
    // Billigere Gegenprobe am ausgelieferten Bestand, ohne eine feste
    // Kollisionszahl zu behaupten (die wuerde bei jeder Aenderung an einem
    // Compose-Modul brechen): leafMap ist bijektiv zu den Blaettern mit
    // nichtleeren Keysym-Pfaden, weil jeder Pfad im Baum eindeutig ist. Nach
    // dem Fix darf also KEIN Blatt beim Aufbau der Karte verschwinden - vor
    // dem Fix waeren es bei diesem Bestand 96 weniger gewesen.
    import std.algorithm : filter;

    initKeysyms(".");

    auto module_ = composeModulesAus("config.default.json");
    cast(void) collectAudit(".", module_);

    auto blaetterMitPfad = allLeaves(&composeRoot).filter!(b => b.keysyms.length > 0).array;
    auto karte = leafMap(&composeRoot);

    assert(karte.length == blaetterMitPfad.length,
        "leafMap darf gegenueber den Baumblaettern keinen einzigen Eintrag verlieren");
}

unittest {
    // Ebenenabgleich: Was liegt auf einer Ebene, und ist es zusaetzlich per
    // Compose erreichbar? Gegen ein kleines, selbst gebautes Layout, damit der
    // Test nicht an der ausgelieferten layouts.json haengt.
    import mapping : initLayouts, layouts, resetLayoutsForTest;
    import std.json : parseJSON;

    scope(exit) resetLayoutsForTest();
    initKeysyms(".");

    auto json = parseJSON(`[{
        "name": "TestEbenen",
        "modifiers": {},
        "layers": [{"Shift": false}, {"Shift": true}],
        "capslockableKeys": [],
        "map": {
            "10": [{"char": "a"}, {"char": "A"}],
            "11": [{"char": "æ"}, {"char": "Æ"}]
        }
    }]`);
    initLayouts(json);

    bool[dchar] erreichbar;
    erreichbar['æ'] = true;
    erreichbar['∀'] = true;   // liegt auf keiner Ebene

    auto abgleich = auditLayers(erreichbar, &layouts[0]);

    assert(abgleich.length == 2, "zwei Ebenen");
    assert(abgleich[0].layer == 1);
    assert(abgleich[0].codepoints == 2, "a und æ");
    assert(abgleich[0].alsoCompose == 1, "nur æ ist auch per Compose erreichbar");
    assert(abgleich[0].layerOnly == [dchar('a')]);

    assert(abgleich[1].codepoints == 2);
    assert(abgleich[1].alsoCompose == 0, "A und Æ liefert der Bestand hier nicht");

    // Nur per Compose: ∀ - a, A, æ und Æ liegen alle auf einer Ebene.
    assert(composeOnlyCount(erreichbar, &layouts[0]) == 1);
}

version (unittest) {
    /// Die fuenf ausgelieferten Konfigurationen. config.default.json ist die
    /// Vorgabe fuer Builds aus dem Repo, die vier anderen werden im
    /// Release-Workflow je Layout eingesetzt.
    private static immutable string[] AUSGELIEFERTE_CONFIGS = [
        "config.default.json", "config.neo.json", "config.neoqwertz.json",
        "config.noted.json", "config.annoted.json"
    ];

    private string[] composeModulesAus(string configDatei) {
        import std.file : readText;
        import std.json : parseJSON;

        auto config = parseJSON(readText(configDatei));
        string[] namen;
        foreach (eintrag; config["composeModules"].array) namen ~= eintrag.str;
        return namen;
    }
}

unittest {
    // Waechter 1: Jedes konfigurierte Modul existiert und traegt mehr als null
    // Eintraege bei. Genau das war bei greek-oxia drei Pakete lang nicht so -
    // das Modul stand in der Liste, entfernte per .remove seine eigenen 19
    // Zeilen und trug nichts bei, waehrend es 20 fremde Eintraege zerstoerte.
    import std.file : exists;

    initKeysyms(".");

    foreach (configDatei; AUSGELIEFERTE_CONFIGS) {
        assert(exists(configDatei), "Ausgelieferte Konfiguration fehlt: " ~ configDatei);

        auto module_ = composeModulesAus(configDatei);
        auto daten = collectAudit(".", module_);
        auto herkunft = auditOrigin(daten);

        foreach (name; module_) {
            assert(exists("compose/" ~ name ~ ".module"),
                configDatei ~ " nennt Modul '" ~ name ~ "', die Datei fehlt aber.");

            uint beitrag;
            foreach (h; herkunft) {
                if (h.name == name) beitrag = h.added + h.overwritten;
            }
            assert(beitrag > 0,
                configDatei ~ ": Modul '" ~ name ~ "' traegt null Eintraege bei.");
        }
    }
}

unittest {
    // Waechter 2: Jede geladene .remove-Datei greift mindestens einmal. Eine,
    // die gar nichts mehr abfaengt, gehoert entweder weg oder ihr Modul hat
    // sich unter ihr weggedreht.
    initKeysyms(".");

    auto module_ = composeModulesAus("config.default.json");
    auto daten = collectAudit(".", module_);

    // Welche .remove-Datei zugeschlagen hat, weiss der Ladepfad nicht - eine
    // REMOVED-Aufzeichnung nennt das MODUL, dessen Zeile abgefangen wurde.
    // Deshalb ueber auditDeadRemoves gegengerechnet.
    auto tote = auditDeadRemoves(".", module_, daten);

    // Zeilen je .remove-Datei zaehlen und mit den toten vergleichen.
    uint[string] toteJeDatei;
    foreach (t; tote) toteJeDatei[t.file] = toteJeDatei.get(t.file, 0) + 1;

    import std.file : read;
    import std.string : split;

    // Denselben Verzeichnisscan wie initCompose benutzen, nicht selbst
    // nachbauen - genau die Regel, die auditDeadRemoves oben schon befolgt
    // (Kommentar dort), hier bisher aber nicht galt (Codereview-Befund).
    auto scan = scanComposeDir("compose");
    auto auswahl = selectComposeFiles(module_, scan.modules, scan.removes);

    foreach (name; auswahl.removes) {
        const datei = name ~ ".remove";
        uint eintragszeilen;
        foreach (zeile; (cast(string) read("compose/" ~ datei)).split("\n")) {
            if (classifyComposeLine(zeile) == ComposeLineKind.ENTRY) eintragszeilen += 1;
        }

        assert(eintragszeilen == 0 || toteJeDatei.get(datei, 0) < eintragszeilen,
            datei ~ " greift ueberhaupt nicht mehr - alle "
                  ~ eintragszeilen.to!string ~ " Zeilen laufen ins Leere.");
    }
}

unittest {
    // Waechter 3: Welche Moduldateien liegen im Verzeichnis, ohne in einer
    // Konfiguration zu stehen? Genau zwei, beide mit Absicht. Der Test
    // faengt ein versehentlich herausgefallenes Modul und haelt zugleich fest,
    // dass diese zwei bewusst draussen sind. greek-oxia wurde in der
    // Ausduennungsrunde entfernt, weil seine Ergebniszeichen Tonos- statt
    // Oxia-Codepunkte trugen und es dadurch null Eintraege beitrug.
    //
    // Fuer .remove-Dateien gilt die Regel NICHT: Sie werden geladen, wenn ihr
    // Modul ausgewaehlt ist oder wenn es zu ihnen gar kein Modul gibt
    // (unicode.remove gehoert zur eingebauten Unicode-Eingabe).
    import std.algorithm : sort;
    import std.file : dirEntries, SpanMode;
    import std.path : baseName, extension;

    bool[string] konfiguriert;
    foreach (configDatei; AUSGELIEFERTE_CONFIGS) {
        foreach (name; composeModulesAus(configDatei)) konfiguriert[name] = true;
    }

    string[] ungenannt;
    foreach (eintrag; dirEntries("compose", SpanMode.shallow)) {
        if (!eintrag.isFile) continue;
        if (eintrag.name.extension != ".module") continue;
        const name = eintrag.name.baseName(".module");
        if (name !in konfiguriert) ungenannt ~= name;
    }

    ungenannt.sort();
    assert(ungenannt == ["klingon", "klingon-kp"],
        "Unerwartete Menge ungenannter Module: " ~ ungenannt.to!string);
}

unittest {
    // Waechter 4: KEIN geladenes Modul enthaelt eine unparsbare Zeile oder
    // ein unbekanntes Keysym. Geprueft wird composeModulesAus gegen
    // "config.default.json", also nur die zehn dort geladenen Module.
    // klingon.module und klingon-kp.module liegen im Repo und werden mit dem
    // compose-Verzeichnis ausgeliefert, bleiben von diesem Waechter aber
    // ungeprueft.
    //
    // Bis zur Ausduennungsrunde galt die Schranke nur fuer eigene Module
    // (hochtief, ananeo-*), weil bei der Planung niemand wusste, ob der
    // geerbte X11-Bestand sauber durchparst. Die Messung vom 02.08.2026 hat
    // es beantwortet: null Verstoesse in allen neun geladenen Modulen,
    // en_US.module mit seinen 5 981 Eintragszeilen eingeschlossen. Seitdem
    // faengt derselbe Test zusaetzlich ab, dass ein Schnitt eine Zeile
    // zerreisst.
    initKeysyms(".");

    auto module_ = composeModulesAus("config.default.json");
    auto daten = collectAudit(".", module_);

    foreach (r; daten.records) {
        assert(r.outcome != ComposeOutcome.UNPARSED,
            modulName(r.file) ~ ".module, Zeile " ~ r.line.to!string
                              ~ ": nicht lesbar.");
    }

    foreach (v; auditVoidKeysyms(daten)) {
        assert(false,
            v.file ~ ".module, Zeile " ~ v.line.to!string
                   ~ ": unbekanntes Keysym (" ~ v.raw ~ ").");
    }
}

unittest {
    // Waechter 5: compose/ananeo-hochtief.module ist von Hand gepflegt - die
    // UCD ist die Kontrolle, nicht die Quelle (Spec 5.3 der Inhaltsrunde,
    // Entscheidung 3). Je Eintrag muss das Zielzeichen in UCD 17.0.0 die
    // Zerlegung <super> bzw. <sub> auf GENAU die Basis der Sequenz tragen;
    // U+00AA und U+00BA (die spanischen Ordnungszahl-Indikatoren, Spec 2.4)
    // sind ausdruecklich verboten; die Gesamtzahl ist 107 (70 hoch, 37 tief).
    import std.file : readText;
    import std.string : lineSplitter;
    import std.utf : toUTF32;
    import keysyms : codepointsByKeysym, initKeysyms, parseKeysym;
    import unicodedata : loadUnicodeData;

    initKeysyms(".");
    auto ucd = loadUnicodeData("data");

    const hoch = parseKeysym("U02E3");
    const tief = parseKeysym("U2093");

    uint hochGezaehlt, tiefGezaehlt;
    uint zeilenNr;
    foreach (zeile; readText("compose/ananeo-hochtief.module").lineSplitter) {
        zeilenNr++;
        if (classifyComposeLine(zeile.idup) != ComposeLineKind.ENTRY) continue;
        auto eintrag = parseLine(zeile.idup);
        auto ort = "ananeo-hochtief.module, Zeile " ~ zeilenNr.to!string ~ ": ";

        assert(eintrag.keysyms.length == 2, ort ~ "genau Praefix und Basis");
        assert(eintrag.keysyms[0] == hoch || eintrag.keysyms[0] == tief,
            ort ~ "unbekannter Praefix");

        // Basis-Keysym -> Basis-Codepunkt. Die eine Ausnahme ist das
        // Minuszeichen: Das Keysym minus ist ASCII 0x2D, die UCD-Basis der
        // Hoch-/Tiefstellung aber U+2212 (Spec 2.3).
        const basisKeysym = eintrag.keysyms[1];
        dchar basis;
        if (basisKeysym == parseKeysym("minus")) {
            basis = 0x2212;
        } else if (auto cp = basisKeysym in codepointsByKeysym) {
            basis = cast(dchar) *cp;
        } else {
            assert(false, ort ~ "Basis-Keysym ohne Unicode-Codepunkt");
        }

        auto ziel = eintrag.result.toUTF32;
        assert(ziel.length == 1, ort ~ "Ergebnis ist genau ein Codepunkt");
        assert(ziel[0] != 0x00AA && ziel[0] != 0x00BA,
            ort ~ "Ordnungszahl-Indikator statt Modifikatorbuchstabe (Spec 2.4)");

        auto tabelle = eintrag.keysyms[0] == hoch ? ucd.superscripts : ucd.subscripts;
        auto kandidaten = basis in tabelle;
        assert(kandidaten !is null, ort ~ "die UCD kennt zu dieser Basis keine Zerlegung");
        assert((*kandidaten).canFind(ziel[0]),
            ort ~ "das Zielzeichen zerlegt sich nicht auf diese Basis");

        if (eintrag.keysyms[0] == hoch) hochGezaehlt++; else tiefGezaehlt++;
    }

    assert(hochGezaehlt == 70, "70 Hochstellungen, gezaehlt: " ~ hochGezaehlt.to!string);
    assert(tiefGezaehlt == 37, "37 Tiefstellungen, gezaehlt: " ~ tiefGezaehlt.to!string);
}

unittest {
    // Waechter 8: Die doppelrolligen Knoten des ausgelieferten Bestands sind
    // genau die acht der Einkreisung. Er ist der Ersatz fuer die gestrichene
    // Ablehnung: ohne ihn koennte ein Tippfehler in einer geerbten Datei
    // still einen Knoten doppelrollig machen und ihm eine Tastenverzoegerung
    // verpassen (Spec 9).
    import std.algorithm.sorting : sort;
    import keysyms : initKeysyms, parseKeysym;

    initKeysyms(".");
    auto module_ = composeModulesAus("config.default.json");
    cast(void) collectAudit(".", module_);

    string[] gefunden;
    void gehe(ComposeNode* knoten, uint[] pfad) {
        if (knoten.next.length > 0 && knoten.result.length > 0) {
            gefunden ~= composeSequenceString(pfad);
        }
        foreach (kind; knoten.next) gehe(kind, pfad ~ kind.keysym);
    }
    gehe(&composeRoot, []);
    sort(gefunden);

    string[] erwartet = [
        composeSequenceString([parseKeysym("U24E7"), parseKeysym("U0031")]),
        composeSequenceString([parseKeysym("U24E7"), parseKeysym("U0032")]),
        composeSequenceString([parseKeysym("U24E7"), parseKeysym("parenleft"), parseKeysym("U0031")]),
        composeSequenceString([parseKeysym("U24E7"), parseKeysym("parenleft"), parseKeysym("U0032")]),
        composeSequenceString([parseKeysym("U24E7"), parseKeysym("period"), parseKeysym("U0031")]),
        composeSequenceString([parseKeysym("U24E7"), parseKeysym("period"), parseKeysym("U0032")]),
        composeSequenceString([parseKeysym("U24E7"), parseKeysym("exclam"), parseKeysym("U0031")]),
        composeSequenceString([parseKeysym("U24E7"), parseKeysym("exclam"), parseKeysym("U0032")]),
    ];
    sort(erwartet);

    assert(gefunden == erwartet,
        "die doppelrolligen Knoten sind genau die acht der Einkreisung, gefunden: "
        ~ gefunden.to!string);
}

unittest {
    // Waechter 9: Die klebrigen Knoten sind genau die von der Regel
    // geforderten, und alle liegen in den drei eigenen Modulen. Die Soll-Seite
    // kommt aus der REGEL, nicht aus den gefundenen Deklarationen - sonst
    // waere der Waechter gruen, wenn der Lader die Direktiven stumm als
    // Kommentar verschluckt und beide Mengen leer sind (Spec 9).
    import std.algorithm.sorting : sort;
    import std.format : format;
    import keysyms : initKeysyms, parseKeysym;
    import schriftvarianten : reihen;

    initKeysyms(".");
    auto module_ = composeModulesAus("config.default.json");
    cast(void) collectAudit(".", module_);

    string[] gefunden;
    void gehe(ComposeNode* knoten, uint[] pfad) {
        if (knoten.klebrig) gefunden ~= composeSequenceString(pfad);
        foreach (kind; knoten.next) gehe(kind, pfad ~ kind.keysym);
    }
    gehe(&composeRoot, []);
    sort(gefunden);

    // Soll-Seite aus der Regel (Spec 5).
    const kreis = parseKeysym("U24E7");
    string[] erwartet = [
        composeSequenceString([parseKeysym("U02E3")]),
        composeSequenceString([parseKeysym("U2093")]),
        composeSequenceString([kreis]),
        composeSequenceString([kreis, parseKeysym("parenleft")]),
        composeSequenceString([kreis, parseKeysym("bracketleft")]),
        composeSequenceString([kreis, parseKeysym("period")]),
        composeSequenceString([kreis, parseKeysym("exclam")]),
        composeSequenceString([kreis, parseKeysym("bracketleft"), parseKeysym("exclam")]),
    ];
    foreach (r; reihen) {
        dchar fam = r.fett ? cast(dchar)(r.familienZeichen - 32) : r.familienZeichen;
        uint[] pfad = [parseKeysym("U1D535"), parseKeysym(format("U%04X", cast(uint) fam))];
        if (r.kursiv) pfad ~= parseKeysym("slash");
        erwartet ~= composeSequenceString(pfad);
    }
    sort(erwartet);

    assert(gefunden == erwartet,
        "klebrig sind genau die von der Regel geforderten Knoten, gefunden: "
        ~ gefunden.to!string);
    assert(gefunden.length == 24, "zwei Hoch/Tief, sechs Kreis, sechzehn Schrift");
}

unittest {
    // Jeder Namensraum-Eintrag traegt das rohe Keysym seiner Fortsetzung -
    // die Ebenen-Spalte des Werkzeugs schlaegt darueber nach, nicht ueber
    // den Anzeige-Praefix (Wertevergleich statt Namensvergleich).
    import std.algorithm : sort;

    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([1u, 2u], "x"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([1u, 3u], "y"w, null), wurzel);

    auto karte = auditNamespace(&wurzel, [1u]);
    assert(karte.length == 2);
    uint[] keysyms;
    foreach (eintrag; karte) keysyms ~= eintrag.keysym;
    keysyms.sort();
    assert(keysyms == [2u, 3u]);
}

version (unittest) {
    /// Ein Layout mit zwei Ebenen fuer die Spiegel-Tests. Ueber initLayouts
    /// mit JSON, NICHT als handgebaute NeoLayout: codepointsOfLayer geht ueber
    /// describeKey, und das stuft eine Zelle ohne "char" als EMPTY ein - eine
    /// reine keysym-Fixture lieferte null Codepunkte und der Test liefe
    /// stillschweigend durch.
    ///
    /// Sechs Tasten, nicht drei: Eine Doppelung entsteht nur, wenn das
    /// Ergebnis der Sequenz auch auf einer Ebene liegt. Die fuenfgliedrige
    /// Reihe des ersten Tests braucht deshalb fuenf Ergebniszeichen im
    /// Layout, sonst faellt der halbe Test still unter die Schranke.
    private void spiegelFixtureLayout() {
        import mapping : initLayouts;
        import std.json : parseJSON;

        initLayouts(parseJSON(`[{
            "name": "SpiegelTest",
            "modifiers": {},
            "layers": [{"Shift": false}, {"Shift": true}],
            "capslockableKeys": [],
            "map": {
                "10": [{"char": "x"}, {"char": "X"}],
                "11": [{"char": "y"}, {"char": "Y"}],
                "12": [{"char": "z"}, {"char": "Z"}],
                "13": [{"char": "q"}, {"char": "Q"}],
                "14": [{"char": "r"}, {"char": "R"}],
                "15": [{"char": "s"}, {"char": "S"}]
            }
        }]`));
    }
}

unittest {
    // Die drei Einstufungen an einer handgebauten Fixture. Keysyms: 0x61 'a',
    // 0x62 'b', 0x68 'h', Multi_key kommt aus keysymdef.h.
    import keysyms : parseKeysym;
    import mapping : layouts, resetLayoutsForTest;
    import std.range : front;

    scope(exit) resetLayoutsForTest();
    initKeysyms(".");
    spiegelFixtureLayout();

    const multi = parseKeysym("Multi_key");
    const unterstrich = parseKeysym("underscore");

    ComposeNode wurzel;
    // Eine Reihe: fuenf Blaetter unter dem Kopf <Multi_key> <a>.
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x61, 0x61], "x"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x61, 0x62], "y"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x61, 0x63], "q"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x61, 0x64], "r"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x61, 0x65], "s"w, null), wurzel);
    // Eine Endungs-Systematik unter einem kleinen Kopf.
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x68, unterstrich], "z"w, null), wurzel);
    // Ein Einzelfall: kleiner Kopf, keine benannte Endung.
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x62, 0x68], "X"w, null), wurzel);
    // Mehrzeichiges Ergebnis - muss uebersprungen werden (Spec 3).
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x62, 0x69], "xy"w, null), wurzel);
    // Ergebnis auf keiner Ebene - keine Doppelung.
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x62, 0x6A], "∀"w, null), wurzel);

    AuditData daten;
    daten.records = [
        ComposeRecord("base.module", 7, [multi, 0x61, 0x61], "x"w, "", ComposeOutcome.ADDED)
    ];

    auto eintraege = auditSpiegel(daten, &wurzel, &layouts[0], 5);

    // Sieben Blaetter liefern ein einzelnes Zeichen auf einer Ebene:
    // x y q r s (die Reihe) plus z (Muster) plus X (Einzelfall).
    assert(eintraege.length == 7, "sieben Doppelungen, mehrzeichig und ∀ fallen raus");

    auto reihe = eintraege.filter!(e => e.ergebnis == 'x').front;
    assert(reihe.art == SpiegelArt.REIHE);
    assert(reihe.kopfBlaetter == 5, "fuenf Blaetter unter <Multi_key> <a>");
    assert(reihe.ebene == 1);
    assert(reihe.modul == "base", "Herkunft kommt aus den Records");
    assert(reihe.zeile == 7);

    auto muster = eintraege.filter!(e => e.ergebnis == 'z').front;
    assert(muster.art == SpiegelArt.MUSTER);
    assert(muster.muster == "oder-gleich");

    auto einzeln = eintraege.filter!(e => e.ergebnis == 'X').front;
    assert(einzeln.art == SpiegelArt.EINZELFALL);
    assert(einzeln.ebene == 2, "X liegt auf Ebene 2");
    assert(einzeln.muster == "" && einzeln.kopf == "");
}

unittest {
    // Der Schwellwert ist ein Sieb, kein Kriterium (Spec 4.4): Derselbe Baum,
    // zwei Schwellen, verschobene Einstufung.
    //
    // Die drei Sequenzen enden bewusst auf DREI VERSCHIEDENEN Keysyms. Endete
    // eine auf demselben wie ihr Vorgaenger (<Multi_key> <a> <a>), griffe das
    // Verdopplungs-Schutzmuster und machte sie zu MUSTER statt EINZELFALL -
    // richtig so, aber hier nicht gemeint.
    import keysyms : parseKeysym;
    import mapping : layouts, resetLayoutsForTest;

    scope(exit) resetLayoutsForTest();
    initKeysyms(".");
    spiegelFixtureLayout();

    const multi = parseKeysym("Multi_key");

    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x61, 0x62], "x"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x61, 0x63], "y"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x61, 0x64], "z"w, null), wurzel);

    AuditData daten;

    auto locker = auditSpiegel(daten, &wurzel, &layouts[0], 3);
    assert(locker.length == 3);
    foreach (e; locker) assert(e.art == SpiegelArt.REIHE, "Schwelle 3 erreicht der Kopf");

    auto streng = auditSpiegel(daten, &wurzel, &layouts[0], 4);
    assert(streng.length == 3);
    foreach (e; streng) assert(e.art == SpiegelArt.EINZELFALL, "Schwelle 4 erreicht er nicht");
}

unittest {
    // Die Endungsmuster einzeln: Beide Negations-Schreibweisen liefern
    // denselben Namen, und ein Pfad, der NUR aus der Endung besteht, gilt
    // nicht als Ableitung.
    import keysyms : parseKeysym;
    import mapping : layouts, resetLayoutsForTest;
    import std.range : front;

    scope(exit) resetLayoutsForTest();
    initKeysyms(".");
    spiegelFixtureLayout();

    const multi = parseKeysym("Multi_key");
    const strich = parseKeysym("dead_stroke");
    const schraeg = parseKeysym("U0338");

    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x68, strich, strich], "x"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x69, schraeg], "y"w, null), wurzel);
    // Verdopplung ohne benannte Endung: das Schutzmuster.
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x6A, 0x6A], "z"w, null), wurzel);
    // Nur ein Keysym - darf keinen Fehlgriff ausloesen.
    cast(void) addComposeEntry(ComposeFileLine([0x58], "X"w, null), wurzel);

    AuditData daten;
    auto e = auditSpiegel(daten, &wurzel, &layouts[0], 99);

    assert(e.filter!(x => x.ergebnis == 'x').front.muster == "Negation");
    assert(e.filter!(x => x.ergebnis == 'y').front.muster == "Negation",
        "U0338 und die dead_stroke-Verdopplung sind dieselbe Systematik");
    assert(e.filter!(x => x.ergebnis == 'z').front.muster == "Verdopplung");

    auto kurz = e.filter!(x => x.ergebnis == 'X').front;
    assert(kurz.art == SpiegelArt.EINZELFALL, "ein einzelnes Keysym ist keine Endung");
}

unittest {
    // Gegen den ausgelieferten Bestand. Keine Gesamtzahl wird festgenagelt -
    // der Compose-Bestand darf sich aendern, und ein Test, der bei jeder
    // Aenderung rot wird, erzieht nur zum Nachziehen (Spec 8).
    import mapping : initLayouts, layouts, resetLayoutsForTest;
    import std.file : readText;
    import std.json : parseJSON;

    scope(exit) resetLayoutsForTest();
    initKeysyms(".");
    initLayouts(parseJSON(readText("layouts.json"))["layouts"]);

    NeoLayout* annoted;
    foreach (ref l; layouts) {
        if (l.name.to!string == "AnNoted") { annoted = &l; break; }
    }
    assert(annoted !is null, "AnNoted steht in der ausgelieferten layouts.json");

    auto module_ = composeModulesAus("config.default.json");
    auto daten = collectAudit(".", module_);

    auto eintraege = auditSpiegel(daten, &composeRoot, annoted, SPIEGEL_SCHWELLE);
    assert(eintraege.length > 0, "der Bestand doppelt sich mit den Ebenen");

    // Bilanz-Invariante: Die drei Stufen sind erschoepfend und schliessen
    // einander aus.
    const reihen = eintraege.count!(e => e.art == SpiegelArt.REIHE);
    const muster = eintraege.count!(e => e.art == SpiegelArt.MUSTER);
    const einzeln = eintraege.count!(e => e.art == SpiegelArt.EINZELFALL);
    assert(reihen + muster + einzeln == eintraege.length);

    // Und die Nebenfelder passen zur Einstufung.
    foreach (e; eintraege) {
        final switch (e.art) {
            case SpiegelArt.REIHE:
                assert(e.kopfBlaetter >= SPIEGEL_SCHWELLE);
                assert(e.kopf.length > 0);
                assert(e.muster.length == 0);
                break;
            case SpiegelArt.MUSTER:
                assert(e.muster.length > 0);
                assert(e.kopf.length == 0);
                break;
            case SpiegelArt.EINZELFALL:
                assert(e.muster.length == 0);
                assert(e.kopf.length == 0);
                break;
        }
        assert(e.ebene >= 1, "eine Doppelung liegt auf einer Ebene");
    }
}

unittest {
    // Drei Leitfaelle gegen den ausgelieferten Bestand - das unabhaengige
    // Gegenstueck zur Bilanz-Invariante, die allein beinahe tautologisch
    // waere. Adressiert ueber die SEQUENZ, nie ueber Zeilennummern: die
    // verschieben sich bei jedem Schnitt.
    import keysyms : parseKeysym;
    import mapping : initLayouts, layouts, resetLayoutsForTest;
    import std.file : readText;
    import std.json : parseJSON;

    scope(exit) resetLayoutsForTest();
    initKeysyms(".");
    initLayouts(parseJSON(readText("layouts.json"))["layouts"]);

    NeoLayout* annoted;
    foreach (ref l; layouts) {
        if (l.name.to!string == "AnNoted") { annoted = &l; break; }
    }

    auto daten = collectAudit(".", composeModulesAus("config.default.json"));
    auto eintraege = auditSpiegel(daten, &composeRoot, annoted, SPIEGEL_SCHWELLE);

    const multi = parseKeysym("Multi_key");
    const strich = parseKeysym("dead_stroke");
    const akut = parseKeysym("dead_acute");

    /// Die Einstufung einer Sequenz, ueber ihren Keysym-Pfad gesucht.
    SpiegelEintrag* suche(const uint[] pfad) {
        const gesucht = composeSequenceString(pfad);
        foreach (ref e; eintraege) if (e.sequenz == gesucht) return &e;
        return null;
    }

    // 1. Muster: <Multi_key> <elementof> <dead_stroke> <dead_stroke> -> ∉
    auto negation = suche([multi, parseKeysym("elementof"), strich, strich]);
    assert(negation !is null, "die Negations-Zeile steht im Bestand");
    assert(negation.art == SpiegelArt.MUSTER);
    assert(negation.muster == "Negation");

    // 2. Einzelfall: <Multi_key> <h> <a> -> ℵ
    auto aleph = suche([multi, 0x68, 0x61]);
    assert(aleph !is null, "die Aleph-Zeile steht im Bestand");
    assert(aleph.art == SpiegelArt.EINZELFALL);
    assert(aleph.ergebnis == 'ℵ');

    // 3. Reihe: eine Tottasten-Zeile. dead_acute traegt im Bestand mehrere
    // hundert Blaetter, liegt also weit ueber jeder sinnvollen Schwelle.
    auto tot = eintraege.filter!(e => e.art == SpiegelArt.REIHE
                                   && e.sequenz.length > 0).array;
    assert(tot.length > 0, "der Bestand traegt Reihen");
    auto akutZeile = suche([akut, 0x61]);
    if (akutZeile !is null) {
        assert(akutZeile.art == SpiegelArt.REIHE,
            "<dead_acute> <a> haengt an einem der groessten Koepfe ueberhaupt");
    }
}

version (unittest) {
    /// Die Sequenzen, die die Spiegelschnitt-Runde geschnitten hat
    /// (Spec 2026-08-06-compose-spiegelschnitt-design.md, Abschnitt 3).
    ///
    /// Keysym-NAMEN statt Zahlen, weil keysymdef.h zur Laufzeit geparst
    /// wird - dieselbe Entscheidung wie bei den Endungsmustern in
    /// auditSpiegel. Ein Tippfehler faellt auf, weil der Waechter jeden
    /// Namen gegen KEYSYM_VOID prueft, statt stillschweigend auf einem
    /// nicht existierenden Pfad gruen zu werden.
    /// Die zwei Umkehrungen (equal zuerst) stehen mit dabei, obwohl die
    /// Einstufung sie als Reihe fuehrt: Ihr Kopf <Multi_key> <equal> traegt
    /// 43 Blaetter, ist aber ein Sammelkopf ohne thematischen Zusammenhalt
    /// (Doppelakut, Waehrungen, Pfeile). Der Schwellwert misst Groesse,
    /// nicht Zusammenhalt - er irrt hier zugunsten des Bestands, so wie er
    /// beim siebengliedrigen Notenzweig zu seinen Ungunsten irrt.
    private static immutable string[][] GESCHNITTENE_SPIEGEL = [
        ["Multi_key", "Cyrillic_ES", "equal"],           // war: €
        ["Multi_key", "equal", "Cyrillic_ES"],           // war: €
        ["Multi_key", "Cyrillic_IE", "equal"],           // war: €
        ["Multi_key", "equal", "Cyrillic_IE"],           // war: €
        ["Multi_key", "Cyrillic_pe", "Cyrillic_a"],      // war: §
        ["Multi_key", "Cyrillic_EN", "Cyrillic_o"],      // war: №
        ["Multi_key", "Cyrillic_EN", "Cyrillic_O"],      // war: №
        // Keine Spiegel, sondern Fehlbedienung: Beide lieferten U+266B.
        // Die zweite ist der Compose-Doppeldruck - der Ausloeser Mod3+Tab
        // ruft compose(multi) (source/ananeo.d:598) und gibt Multi_key
        // damit als Fortsetzung in den Baum, in jedem Rastzustand.
        ["Multi_key", "Tab"],
        ["Multi_key", "Multi_key"]
    ];
}

unittest {
    // Waechter 7: Die geschnittenen Spiegel duerfen nicht zurueckkommen.
    //
    // Er haelt eine ENTSCHEIDUNG fest, keinen Messwert - wie die Liste der
    // 17 Keysyms in Waechter 6 und wie das namentliche Verbot von U+00AA
    // und U+00BA in Waechter 5. Deshalb nagelt er wie jene keine
    // Gesamtzahl fest: Der Compose-Bestand darf sich aendern.
    //
    // Zwei Grenzen gehoeren dazu. Er sagt NICHTS ueber die nicht
    // geschnittenen Einzelfaelle - die stehen unter Regeln (Reihenglied,
    // bildhaft), die sich mit dem Bestand aendern duerfen, und waeren als
    // Testschranke falsch. Und er prueft nur die Sequenz als Ganzes: Ein
    // Praefix davon darf weiterhin im Baum stehen, und tut es auch
    // (<Multi_key> <Cyrillic_EN> traegt nach dem Schnitt noch zwei
    // Blaetter).
    import keysyms : KEYSYM_VOID, parseKeysym;
    import std.array : join;

    initKeysyms(".");
    cast(void) collectAudit(".", composeModulesAus("config.default.json"));

    // Alle Blaetter ueber keysymKey schluesseln, nicht ueber die
    // Anzeigeform: Zwei Keysyms mit demselben Codepunkt sehen gleich aus
    // und sind es nicht (siehe keysymKey).
    bool[string] vorhanden;
    foreach (blatt; allLeaves(&composeRoot)) vorhanden[keysymKey(blatt.keysyms)] = true;

    // Alle Verstoesse sammeln statt beim ersten abzubrechen: Die
    // Negativkontrolle vor dem Schnitt muss ALLE Eintraege der Tabelle
    // nennen. Meldet sie weniger, ist ein Pfad falsch notiert und der
    // Waechter waere nach dem Schnitt still gruen, ohne etwas zu pruefen.
    string[] nochDa;

    foreach (pfad; GESCHNITTENE_SPIEGEL) {
        uint[] folge;
        foreach (name; pfad) {
            const k = parseKeysym(name);
            assert(k != KEYSYM_VOID,
                "Waechter 7 nennt das unbekannte Keysym '" ~ name
                ~ "' - der Waechter ist falsch notiert, nicht der Bestand.");
            folge ~= k;
        }

        if (keysymKey(folge) in vorhanden) nochDa ~= composeSequenceString(folge);
    }

    assert(nochDa.length == 0,
        "Geschnittene Sequenzen sind wieder im Baum ("
        ~ nochDa.length.to!string ~ "): " ~ nochDa.join(" | "));
}

unittest {
    // Doppelrollige Knoten sind Ergebnistraeger: allLeaves muss sie
    // auffuehren, sonst fehlen sie in coverage, find, spiegel und diff.
    import composer : ComposeFileLine, ComposeNode, addComposeEntry;

    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31], "eins"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31, 0x30], "zehn"w, null), wurzel);

    auto blaetter = allLeaves(&wurzel);
    assert(blaetter.length == 2, "das gehaltene Ergebnis und das Kind");

    bool eins, zehn;
    foreach (b; blaetter) {
        if (b.result == "eins"w) { eins = true; assert(b.keysyms == [0x4Bu, 0x31u]); }
        if (b.result == "zehn"w) { zehn = true; assert(b.keysyms == [0x4Bu, 0x31u, 0x30u]); }
    }
    assert(eins && zehn);

    // auditNamespace zaehlt dieselbe Menge.
    auto eintraege = auditNamespace(&wurzel, []);
    assert(eintraege.length == 1);
    assert(eintraege[0].leaves == 2);
}

unittest {
    // Uebertragene Zusatzanforderung aus dem Task-2-Review: DUAL traegt wie
    // ADDED ein Ergebnis in den Baum ein (addComposeEntry schreibt es), der
    // Herkunftsfilter in auditFind schloss DUAL-Records bisher aus - eine
    // per DUAL geladene Sequenz bekam deshalb eine leere Herkunft statt des
    // Modulnamens.
    import composer : ComposeFileLine, ComposeNode, addComposeEntry;

    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31], "eins"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31, 0x30], "zehn"w, null), wurzel);

    AuditData daten;
    daten.records = [
        ComposeRecord("basis.module", 3, [0x4B, 0x31], "eins"w, "", ComposeOutcome.DUAL)
    ];

    auto treffer = auditFind(daten, &wurzel, "eins"d);
    assert(treffer.length == 1);
    // Der eigentliche Fund: ohne den Fix bleibt file leer, weil der
    // Herkunftsfilter DUAL-Records ausschloss.
    assert(treffer[0].file == "basis",
        "eine per DUAL geladene Sequenz muss als Herkunft erkannt werden");
    assert(treffer[0].line == 3);
}

unittest {
    // Dieselbe Zusatzanforderung fuer auditSpiegel: DUAL-Records duerfen
    // nicht aus dem Herkunftsfilter fallen, sonst bleibt die Spalte "modul"
    // fuer eine per DUAL geladene Sequenz leer.
    import keysyms : parseKeysym;
    import mapping : layouts, resetLayoutsForTest;
    import std.algorithm : filter;
    import std.range : front;

    scope(exit) resetLayoutsForTest();
    initKeysyms(".");
    spiegelFixtureLayout();

    const multi = parseKeysym("Multi_key");

    ComposeNode wurzel;
    // <Multi_key> <a> traegt selbst ein Ergebnis (DUAL) UND die Fortsetzung
    // <Multi_key> <a> <h>, die per Spiegelfixture auf einer Ebene liegt.
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x61], "x"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([multi, 0x61, 0x68], "y"w, null), wurzel);

    AuditData daten;
    daten.records = [
        ComposeRecord("basis.module", 5, [multi, 0x61], "x"w, "", ComposeOutcome.DUAL)
    ];

    auto eintraege = auditSpiegel(daten, &wurzel, &layouts[0], 5);
    auto treffer = eintraege.filter!(e => e.ergebnis == 'x').front;
    // Der eigentliche Fund: ohne den Fix bleibt modul leer, weil der
    // Herkunftsfilter DUAL-Records ausschloss.
    assert(treffer.modul == "basis",
        "eine per DUAL geladene Sequenz muss als Herkunft erkannt werden");
    assert(treffer.zeile == 5);
}
