module composer;

import std.stdio;
import std.utf;
import std.regex;
import std.algorithm;
import std.conv;
import std.file;
import std.path;
import std.array;
import std.format;

import std.datetime.stopwatch;

import debuglog;
import keysyms;
import mapping : NeoKey, NeoKeyType;


class ComposeParser {
    string line;
    uint pos;
    int chunkStart = -1;

    this(string line) {
        this.line = line;
    }

    char peek() {
        return line[pos];
    }

    void advance() {
        pos++;
    }

    bool match(char[] cs ...) {
        foreach (char c; cs) {
            if (check(c)) {
                advance();
                return true;
            }
        }

        return false;
    }

    bool check(char c) {
        if(atEnd()) {
            return false;
        }
        return peek() == c;
    }

    bool atEnd() {
        return pos >= line.length;
    }

    void consumeWhitespace() {
        while (match(' ', '\t')) {}
    }

    void startChunk() {
        assert(chunkStart == -1);
        chunkStart = pos;
    }

    string endChunk() {
        assert(chunkStart != -1);
        string chunk = line[chunkStart .. pos];
        chunkStart = -1;
        return chunk;
    }

    uint composeSequenceKey() {
        /// parse "<Multi_Key>" into a matching keysym
        if (!match('<')) throw new Exception("Keysym beginnt nicht mit '<'");
        startChunk();
        while (!check('>')) {
            // atEnd() erreicht: Zeile ist zu Ende, bevor '>' kam. check('<')
            // erreicht: ein zweites '<' vor dem ersten '>' - ohne diese Pruefung
            // wuerde z.B. "<a <b>" klaglos als Keysymname "a <b" durchgehen
            // (parseKeysym wirft nie, nur KEYSYM_VOID). Beide Faelle sind eine
            // unbeendete Klammer.
            if (atEnd() || check('<')) throw new Exception("Keysym ohne schliessendes '>'");
            advance();
        }
        string keysymStr = endChunk();
        match('>');
        return parseKeysym(keysymStr);
    }

    string quotedString() {
        if (!match('"')) throw new Exception("Ergebnis steht nicht in Anfuehrungszeichen");

        string stringContent;

        while (!check('"')) {
            if (atEnd()) throw new Exception("Ergebnis ohne schliessendes Anfuehrungszeichen");
            char next = peek();

            if (next == '\\') {
                // For backslash escaped characters, skip the backslash and decide based on the next char
                advance();
                if (atEnd()) throw new Exception("Ergebnis endet auf unvollstaendiges Escape");

                if (check('n')) {
                    stringContent ~= '\n';
                } else if (check('t')) {
                    stringContent ~= '\t';
                } else {
                    stringContent ~= peek();
                }
            } else {
                stringContent ~= next;
            }

            advance();
        }

        match('"');
        return stringContent;
    }

    ComposeFileLine composeEntry() {
        ComposeFileLine entry; // remains empty if line is empty

        consumeWhitespace();
        if (!check('<')) {
            // early return on empty/comment lines
            return entry;
        }

        while (check('<')) {
            entry.keysyms ~= composeSequenceKey();
            consumeWhitespace();
        }

        if (!match(':')) throw new Exception("Doppelpunkt fehlt");
        consumeWhitespace();
        string resultString = quotedString();
        entry.result = resultString.to!wstring;

        return entry;
    }
}

struct ComposeNode {
    uint keysym;
    ComposeNode *prev;
    ComposeNode *[] next;
    wstring result;
    // Everything after this node is processed by the special mode function
    SpecialComposeFunction specialMode;
    /// Klebrig: Nach einer Ausgabe im Teilbaum springt die Sequenz hierher
    /// zurueck, statt zu enden (Spec 3.1). Wird per #klebrig-Direktive in der
    /// Moduldatei gesetzt, nie aus einer Eintragszeile.
    bool klebrig;
}

/// Ein Sondermodus (z.B. Unicode-Eingabe, roemische Zahlen). "probe" heisst: nur pruefen, ob die Taste angenommen
/// wuerde - nichts aendern, nichts ausgeben (Sondermodi-Spec 2). Die
/// Antwort ist dann EAT ("nehme ich") oder ABORT ("nehme ich nicht"), das
/// Ergebnisfeld bleibt leer. Geurteilt wird ueber die Taste, nicht ueber
/// den Ausgang: Ein angenommenes Abschlusszeichen kann im echten Aufruf
/// trotzdem an ungueltigem Inhalt scheitern.
alias SpecialComposeFunction = ComposeResult function(const(NeoKey), bool probe) nothrow;

/// Was beim Eintragen einer Sequenz in den Compose-Baum passiert ist.
enum ComposeAddResult {
    ADDED,        /// neu eingetragen
    OVERWRITTEN,  /// exaktes Duplikat - das Ergebnis der neuen Sequenz gewinnt
    DUAL,         /// eingetragen und dabei einen Knoten doppelrollig gemacht
    REJECTED      /// Kombination mit einem Sondermodus - nicht eingetragen
}

/// Buchhaltung je Moduldatei fuer den Kollisionsbericht.
struct ComposeStats {
    uint added;
    uint overwritten;
    uint dual;      /// Doppelrolle hergestellt
    uint rejected;  /// wegen eines Sondermodus abgelehnt
    uint removed;   /// per .remove-Datei uebersprungen
}

/// Kollisionsarten, die der Bericht einzeln auffuehrt. Die ersten drei
/// entsprechen den gleichnamigen ComposeAddResult-Werten, REMOVED steht fuer
/// eine Sequenz, die eine .remove-Datei vor dem Eintragen abgefangen hat.
enum ComposeNote {
    OVERWRITTEN,
    DUAL,
    REJECTED,
    REMOVED
}

/// Ein einzelner Konflikt, fuer die Liste im Log.
struct ComposeConflict {
    string file;
    uint[] keysyms;
    ComposeNote note;
}

/// Was mit einer gelesenen Zeile geschehen ist. Fasst die bisher getrennten
/// Wege ComposeAddResult und noteComposeRemoved zu einer Aufzaehlung zusammen,
/// damit ein Beobachter alle Faelle gleich behandeln kann.
enum ComposeOutcome { ADDED, OVERWRITTEN, DUAL, REJECTED, REMOVED, UNPARSED }

/// Eine gelesene Zeile mit Herkunft und Ausgang. Nur fuer die Auskunft; das
/// laufende Programm zaehlt weiterhin ueber ComposeStats.
struct ComposeRecord {
    string file;
    uint line;
    uint[] keysyms;
    wstring result;
    string raw;
    ComposeOutcome outcome;
}

/// Optionaler Empfaenger jeder gelesenen Zeile. Standardmaessig null: Das
/// laufende Programm zahlt einen Nullzeiger-Test je Zeile. Das Werkzeug haengt
/// hier einen vollstaendigen Sammler ein. Wird von initCompose bewusst NICHT
/// zurueckgesetzt - der Aufrufer besitzt ihn.
void delegate(ComposeRecord) nothrow composeObserver;

ComposeNode composeRoot;
ComposeNode removeComposeRoot;

ComposeStats[string] composeStatsByFile;
string[] composeStatsOrder;   // Ladereihenfolge, damit der Bericht ihr folgt
ComposeConflict[] composeConflicts;

// Konfigurierte Namen aus composeModules, zu denen keine .module-Datei
// gefunden wurde - von selectComposeFiles ohnehin schon berechnet
// (ComposeSelection.unknown), hier nur abgelegt, damit ein Aufrufer (das
// Werkzeug) sie nach initCompose ohne erneute Verzeichnisabfrage abfragen
// kann. Wie composeStatsOrder wird auch dieses Feld bei jedem initCompose
// neu gesetzt, nicht nur ergaenzt.
string[] composeUnknownModules;

bool active;
ComposeNode *currentNode;
dstring currentSequence;
// Function pointer if currently switched to special compose mode
SpecialComposeFunction currentSpecialMode;
uint addedEntries;

// Die getippte Sequenz als Keysym-Folge, fuer die Anzeige der Vorschau.
// currentSequence taugt dafuer nicht: Es sammelt nur Zeichen mit
// Unicode-Darstellung, eine Tottaste fehlt darin.
uint[] currentKeysyms;

// Keysym constants for Unicode input
uint KEYSYM_0;
uint KEYSYM_KP_0;
uint KEYSYM_a;
uint KEYSYM_A;
uint KEYSYM_SPACE;

// Unicode input special mode
string unicodeInput;

// Roman numeral special mode
const ROMAN_DIGITS = [
    [["ⅰ"w, "Ⅰ"w], ["ⅰⅰ"w, "ⅠⅠ"w], ["ⅰⅰⅰ"w, "ⅠⅠⅠ"w], ["ⅰⅴ"w, "ⅠⅤ"w], ["ⅴ"w, "Ⅴ"w], ["ⅴⅰ"w, "ⅤⅠ"w], ["ⅴⅰⅰ"w, "ⅤⅠⅠ"w], ["ⅴⅰⅰⅰ"w, "ⅤⅠⅠⅠ"w], ["ⅰⅹ"w, "ⅠⅩ"w]],
    [["ⅹ"w, "Ⅹ"w], ["ⅹⅹ"w, "ⅩⅩ"w], ["ⅹⅹⅹ"w, "ⅩⅩⅩ"w], ["ⅹⅼ"w, "ⅩⅬ"w], ["ⅼ"w, "Ⅼ"w], ["ⅼⅹ"w, "ⅬⅩ"w], ["ⅼⅹⅹ"w, "ⅬⅩⅩ"w], ["ⅼⅹⅹⅹ"w, "ⅬⅩⅩⅩ"w], ["ⅹⅽ"w, "ⅩⅭ"w]],
    [["ⅽ"w, "Ⅽ"w], ["ⅽⅽ"w, "ⅭⅭ"w], ["ⅽⅽⅽ"w, "ⅭⅭⅭ"w], ["ⅽⅾ"w, "ⅭⅮ"w], ["ⅾ"w, "Ⅾ"w], ["ⅾⅽ"w, "ⅮⅭ"w], ["ⅾⅽⅽ"w, "ⅮⅭⅭ"w], ["ⅾⅽⅽⅽ"w, "ⅮⅭⅭⅭ"w], ["ⅽⅿ"w, "ⅭⅯ"w]],
    [["ⅿ"w, "Ⅿ"w], ["ⅿⅿ"w, "ⅯⅯ"w], ["ⅿⅿⅿ"w, "ⅯⅯⅯ"w]]
];
string romanNumeralInput;

enum ComposeResultType {
    PASS,
    EAT,
    FINISH,
    /// Ausgeben, aber die Sequenz laeuft weiter: der Baum ist an einem
    /// klebrigen Vorfahren zurueckgesprungen (Spec 3.1). Der Aufrufer
    /// behandelt EMIT genau wie FINISH; nur composeActive() bleibt wahr.
    EMIT,
    ABORT
}

struct ComposeResult {
    ComposeResultType type;
    wstring result;
}

struct ComposeFileLine {
    /** 
    * One line in a compose file, consisting of the required keysyms and the resulting string
    * This is only used while parsing, the actual compose data structure is a tree (see ComposeNode)
    **/
    uint [] keysyms;
    wstring result;
    // Minor abuse of this type, as actual .module files can't specify special modes
    SpecialComposeFunction specialMode;
}


/// Welche .module- und .remove-Dateien liegen im compose-Verzeichnis?
/// Oeffentlich, weil composeaudit.d dieselbe Frage stellt - eine zweite Kopie
/// dieser Schleife wuerde bei einer Aenderung der Aufzaehlungsregel (neue
/// Endung, Gross-/Kleinschreibung, Rekursion) still auseinanderlaufen.
struct ComposeDirScan {
    string[] modules;   /// .module-Dateien, ohne Pfad und ohne Endung
    string[] removes;   /// .remove-Dateien, ohne Pfad und ohne Endung
}

ComposeDirScan scanComposeDir(string composeDir) {
    ComposeDirScan scan;
    foreach (dirEntry; dirEntries(composeDir, SpanMode.shallow)) {
        if (!dirEntry.isFile) continue;
        if (dirEntry.name.extension == ".module") {
            scan.modules ~= dirEntry.name.baseName(".module");
        } else if (dirEntry.name.extension == ".remove") {
            scan.removes ~= dirEntry.name.baseName(".remove");
        }
    }
    return scan;
}

/// Ergebnis der Modulauswahl, jeweils Dateinamen ohne Endung.
struct ComposeSelection {
    string[] modules;   /// zu ladende .module in Ladereihenfolge
    string[] removes;   /// zu ladende .remove in Ladereihenfolge
    string[] unknown;   /// konfigurierte Namen ohne passende .module-Datei
}

/// Aus der Positivliste "composeModules" und dem Bestand des compose-Ordners
/// die tatsaechlich zu ladenden Dateien bestimmen. Rein, damit testbar.
///
/// Zu jedem ausgewaehlten Modul gehoert seine gleichnamige .remove-Datei.
/// Zusaetzlich werden .remove-Dateien geladen, zu denen es ueberhaupt kein
/// Modul gibt: Die koennen sich nur auf eine eingebaute Sonderroutine
/// beziehen (compose/unicode.remove raeumt der Unicode-Eingabe den Weg frei)
/// und werden deshalb immer gebraucht.
ComposeSelection selectComposeFiles(const(string)[] configured,
                                    const(string)[] availableModules,
                                    const(string)[] availableRemoves) {
    ComposeSelection selection;

    foreach (name; configured) {
        if (availableModules.canFind(name)) {
            selection.modules ~= name;
            if (availableRemoves.canFind(name)) {
                selection.removes ~= name;
            }
        } else {
            selection.unknown ~= name;
        }
    }

    foreach (name; availableRemoves.dup.sort) {
        if (!availableModules.canFind(name)) {
            selection.removes ~= name;
        }
    }

    return selection;
}

void initCompose(string exeDir, const(string)[] configuredModules) {
    debugWriteln("Initializing compose");

    debug {
        auto sw = StopWatch();
        sw.start();
    }
    // reset existing compose tree
    composeRoot = ComposeNode();
    removeComposeRoot = ComposeNode();
    addedEntries = 0;
    composeStatsByFile.clear();
    composeStatsOrder = [];
    composeConflicts = [];
    composeKeysymNames.clear();
    composeUnknownModules = [];
    string composeDir = buildPath(exeDir, "compose");

    if (!exists(composeDir)) {
        return;
    }

    auto scan = scanComposeDir(composeDir);

    auto selection = selectComposeFiles(configuredModules, scan.modules, scan.removes);

    composeUnknownModules = selection.unknown;

    foreach (name; selection.unknown) {
        debugWriteln("Compose module '", name, "' from composeModules has no file ",
            buildPath(composeDir, name ~ ".module"), ", skipping.");
    }

    // Gather all entries that appear in .remove files. This has to happen
    // before the first .module is read: the remove tree must be complete when
    // the first entry is checked against it.
    foreach (name; selection.removes) {
        string fname = buildPath(composeDir, name ~ ".remove");
        debugWriteln("Removing compose module ", fname);
        loadRemoveModule(fname);
    }

    // Gather compose entries from the selected .module files, in list order
    foreach (name; selection.modules) {
        string fname = buildPath(composeDir, name ~ ".module");
        debugWriteln("Loading compose module ", fname);
        loadModule(fname);
    }

    debug {
        debugWriteln("Time spent reading and parsing module files: ", sw.peek().total!"msecs", " ms");
        sw.reset();
    }

    const uint KEYSYM_MULTIKEY = parseKeysym("Multi_key");
    // Register unicode input special mode with prefix "♫uu"
    addBuiltinComposeEntry(ComposeFileLine([KEYSYM_MULTIKEY, parseKeysym("u"), parseKeysym("u")], ""w, &composeUnicode));

    // Register lower case roman numeral special mode with prefix "♫rn"
    addBuiltinComposeEntry(ComposeFileLine([KEYSYM_MULTIKEY, parseKeysym("r"), parseKeysym("n")], ""w, &composeLowerRoman));

    // Register upper case roman numeral special mode with prefix "♫RN"
    addBuiltinComposeEntry(ComposeFileLine([KEYSYM_MULTIKEY, parseKeysym("R"), parseKeysym("N")], ""w, &composeUpperRoman));

    debugWriteln("Loaded ", addedEntries, " compose sequences.");
    composeReport();

    // For unicode input
    KEYSYM_SPACE = parseKeysym("space");
    KEYSYM_0 = parseKeysym("0");
    KEYSYM_KP_0 = parseKeysym("KP_0");
    KEYSYM_a = parseKeysym("a");
    KEYSYM_A = parseKeysym("A");
}

/// Die eine Anweisungszeile, die eine Moduldatei kennt. Alles andere hinter
/// '#' bleibt Kommentar.
enum COMPOSE_STICKY_DIRECTIVE = "#klebrig";

/// Was fuer eine Zeile das ist - bevor der Parser sie anfasst. Trennt
/// Kommentare und Leerzeilen (folgenlos) von Eintragszeilen (ein Parse-Fehler
/// ist dort ein echter Fehler und keine Kommentarzeile) und von der einen
/// Anweisungszeile.
enum ComposeLineKind { EMPTY, COMMENT, ENTRY, DIRECTIVE, OTHER }

ComposeLineKind classifyComposeLine(string line) {
    import std.algorithm.searching : startsWith;

    foreach (i, c; line) {
        if (c == ' ' || c == '\t' || c == '\r') continue;
        if (c == '#') {
            return line[i .. $].startsWith(COMPOSE_STICKY_DIRECTIVE)
                ? ComposeLineKind.DIRECTIVE : ComposeLineKind.COMMENT;
        }
        if (c == '<') return ComposeLineKind.ENTRY;
        return ComposeLineKind.OTHER;
    }
    return ComposeLineKind.EMPTY;
}

/// Die Keysym-Folge einer #klebrig-Zeile. Wirft wie parseLine, wenn die
/// Notation kaputt oder der Pfad leer ist.
uint[] parseStickyDirective(string line) {
    import std.algorithm.searching : countUntil;

    const start = line.countUntil(COMPOSE_STICKY_DIRECTIVE);
    if (start < 0) throw new Exception("keine #klebrig-Zeile");

    auto parser = new ComposeParser(line[start + COMPOSE_STICKY_DIRECTIVE.length .. $]);
    uint[] pfad;
    parser.consumeWhitespace();
    while (parser.check('<')) {
        pfad ~= parser.composeSequenceKey();
        parser.consumeWhitespace();
    }
    if (pfad.length == 0) throw new Exception("#klebrig ohne Keysym-Pfad");
    return pfad;
}

/// Den Knoten am Ende des Pfades klebrig machen. false, wenn der Pfad ins
/// Leere zeigt - der Aufrufer meldet das dann als unparsbare Zeile.
bool markSticky(const uint[] pfad, ref ComposeNode nodeRoot) {
    auto knoten = &nodeRoot;
    foreach (keysym; pfad) {
        ComposeNode* naechster;
        foreach (kind; knoten.next) {
            if (kind.keysym == keysym) { naechster = kind; break; }
        }
        if (naechster is null) return false;
        knoten = naechster;
    }
    knoten.klebrig = true;
    return true;
}

ComposeFileLine parseLine(string line) {
    /// Parse compose module line into an entry struct
    /// Throws if the line can't be parsed (e.g. it's empty or a comment)
    auto parser = new ComposeParser(line);
    auto entry = parser.composeEntry();
    if (entry.result == ""w) {
        throw new Exception("Line does not contain compose entry");
    }

    return entry;
}

bool isEntryInComposeTree(ComposeFileLine entry, ref ComposeNode nodeRoot) {
    auto currentNode = &nodeRoot;

    foreach (keysym; entry.keysyms) {
        ComposeNode *next;
        bool foundNext;

        foreach (nextIter; currentNode.next) {
            if (nextIter.keysym == keysym) {
                foundNext = true;
                next = nextIter;
                break;
            }
        }
        if (!foundNext) break;
        currentNode = next;
    }

    return (currentNode.result == entry.result);
}

ComposeAddResult addComposeEntry(ComposeFileLine entry, ref ComposeNode nodeRoot) {
    auto currentNode = &nodeRoot;
    bool doppelrolleHergestellt;

    foreach (keysym; entry.keysyms) {
        ComposeNode *next;
        bool foundNext;

        foreach (nextIter; currentNode.next) {
            if (nextIter.keysym == keysym) {
                foundNext = true;
                next = nextIter;
                break;
            }
        }

        if (!foundNext) {
            // Ein Sondermodus verschluckt alles nach sich - unter ihm kann
            // keine Fortsetzung liegen. Das bleibt abgelehnt, auch wenn die
            // Ergebnis-Haelfte dieser Bedingung gefallen ist (Spec 7).
            if (currentNode.specialMode !is null) {
                return ComposeAddResult.REJECTED;
            }
            // Ein Knoten mit Ergebnis darf jetzt Kinder bekommen: er wird
            // doppelrollig und haelt sein Ergebnis fest, bis die naechste
            // Taste entscheidet. Nur das ERSTE Kind stellt das her (next.length
            // noch 0) - ohne diese Wache wuerde jedes weitere Geschwister die
            // Doppelrolle erneut melden, obwohl der Knoten sie schon hat
            // (Spec 3.2: "Geschwister danach sind gewoehnliche ADDED").
            if (currentNode.result != ""w && currentNode.next.length == 0) {
                doppelrolleHergestellt = true;
            }

            next = new ComposeNode(keysym, currentNode, [], ""w, null);
            currentNode.next ~= next;
        }

        currentNode = next;
    }

    // Ein Sondermodus auf einem Knoten mit Kindern waere derselbe
    // Widerspruch von der anderen Seite - er betrifft die eingebauten
    // Eintraege, die zuletzt laden (composer.d, initCompose).
    if (entry.specialMode !is null && currentNode.next.length > 0) {
        return ComposeAddResult.REJECTED;
    }
    if (currentNode.next.length > 0 && currentNode.result == ""w
        && currentNode.specialMode is null) {
        // Erst dieses Ergebnis macht den Knoten doppelrollig.
        doppelrolleHergestellt = true;
    }

    // Ein bereits belegter Endknoten bedeutet, dass genau diese Sequenz schon
    // einmal eingetragen wurde. Sie wird ueberschrieben, die zuletzt geladene
    // Datei gewinnt also - das ist gewolltes Verhalten, aber berichtenswert.
    const bool alreadyOccupied = currentNode.result != ""w || currentNode.specialMode !is null;
    currentNode.result = entry.result;
    currentNode.specialMode = entry.specialMode;

    if (doppelrolleHergestellt) return ComposeAddResult.DUAL;
    return alreadyOccupied ? ComposeAddResult.OVERWRITTEN : ComposeAddResult.ADDED;
}

// Rueckwaertssuche Keysym -> Name, nur fuer den Bericht. Wird beim ersten
// Zugriff aus keysymsByName aufgebaut und in initCompose verworfen.
string[uint] composeKeysymNames;

// Eine Sequenz fuer den Bericht lesbar machen: Keysyms mit bekanntem
// Codepunkt als Zeichen, benannte Keysyms ohne Codepunkt (Multi_key, die
// dead_-Tasten) unter ihrem Namen, alle uebrigen als Hexwert.
string composeSequenceString(const uint[] keysyms) {
    if (composeKeysymNames.length == 0) {
        foreach (name, keysym; keysymsByName) {
            // Der erste Name gewinnt; keysymdef.h fuehrt einige Keysyms
            // mehrfach auf, die Auswahl ist fuer den Bericht gleichgueltig.
            if (keysym !in composeKeysymNames) {
                composeKeysymNames[keysym] = name;
            }
        }
    }

    string[] parts;

    foreach (keysym; keysyms) {
        if (auto codepoint = keysym in codepointsByKeysym) {
            parts ~= [dchar(*codepoint)].toUTF8;
        } else if (keysym > KEYSYM_CODEPOINT_OFFSET) {
            parts ~= [dchar(keysym - KEYSYM_CODEPOINT_OFFSET)].toUTF8;
        } else if (auto name = keysym in composeKeysymNames) {
            parts ~= "<" ~ *name ~ ">";
        } else {
            parts ~= format("0x%X", keysym);
        }
    }

    return parts.join(" ");
}

void beginComposeFile(string file) {
    if (file !in composeStatsByFile) {
        composeStatsByFile[file] = ComposeStats();
        composeStatsOrder ~= file;
    }
}

void noteComposeResult(string file, uint line, ComposeFileLine entry, ComposeAddResult result) {
    beginComposeFile(file);

    ComposeOutcome ausgang;

    final switch (result) {
        case ComposeAddResult.ADDED:
            composeStatsByFile[file].added += 1;
            addedEntries += 1;
            ausgang = ComposeOutcome.ADDED;
            break;
        case ComposeAddResult.OVERWRITTEN:
            composeStatsByFile[file].overwritten += 1;
            addedEntries += 1;
            composeConflicts ~= ComposeConflict(file, entry.keysyms, ComposeNote.OVERWRITTEN);
            ausgang = ComposeOutcome.OVERWRITTEN;
            break;
        case ComposeAddResult.DUAL:
            composeStatsByFile[file].dual += 1;
            // Anders als bei EXTENSION/PREFIX vorher: DUAL traegt tatsaechlich
            // ein (addComposeEntry schreibt das Ergebnis), zaehlt also mit.
            addedEntries += 1;
            composeConflicts ~= ComposeConflict(file, entry.keysyms, ComposeNote.DUAL);
            ausgang = ComposeOutcome.DUAL;
            break;
        case ComposeAddResult.REJECTED:
            composeStatsByFile[file].rejected += 1;
            composeConflicts ~= ComposeConflict(file, entry.keysyms, ComposeNote.REJECTED);
            ausgang = ComposeOutcome.REJECTED;
            break;
    }

    meldeComposeZeile(ComposeRecord(file, line, entry.keysyms, entry.result, "", ausgang));
}

void noteComposeRemoved(string file, uint line, ComposeFileLine entry) {
    beginComposeFile(file);
    composeStatsByFile[file].removed += 1;
    composeConflicts ~= ComposeConflict(file, entry.keysyms, ComposeNote.REMOVED);
    meldeComposeZeile(ComposeRecord(file, line, entry.keysyms, entry.result, "",
        ComposeOutcome.REMOVED));
}

/// Eine Aufzeichnung an den Beobachter geben, falls einer eingehaengt ist.
private void meldeComposeZeile(ComposeRecord aufzeichnung) {
    if (composeObserver !is null) composeObserver(aufzeichnung);
}

// Name, unter dem die eingebauten Sonderroutinen (Unicode-Eingabe, roemische
// Zahlen) im Bericht erscheinen. Sie werden zuletzt eingetragen und koennen
// deshalb mit geladenen Modulen kollidieren - dafuer gibt es .remove-Dateien
// ohne zugehoeriges Modul, etwa compose/unicode.remove.
enum COMPOSE_BUILTIN_NAME = "(built-in)";

void addBuiltinComposeEntry(ComposeFileLine entry) {
    noteComposeResult(COMPOSE_BUILTIN_NAME, 0, entry, addComposeEntry(entry, composeRoot));
}

// Wie viele Einzelfaelle je Kollisionsart das Log hoechstens auffuehrt.
enum COMPOSE_CONFLICT_LOG_LIMIT = 50;

void composeReport() {
    debugWriteln("Compose modules loaded (entries / overwritten / dual conflicts / rejected conflicts / removed):");

    foreach (file; composeStatsOrder) {
        const stats = composeStatsByFile[file];
        debugWriteln("  ", baseName(file), ": ", stats.added + stats.overwritten,
            " / ", stats.overwritten, " / ", stats.dual,
            " / ", stats.rejected, " / ", stats.removed);
    }

    foreach (art; [ComposeNote.OVERWRITTEN, ComposeNote.DUAL, ComposeNote.REJECTED, ComposeNote.REMOVED]) {
        auto faelle = composeConflicts.filter!(c => c.note == art).array;
        if (faelle.length == 0) continue;

        debugWriteln("Compose conflicts of type ", art, " (", faelle.length, "):");
        foreach (fall; faelle[0 .. min($, COMPOSE_CONFLICT_LOG_LIMIT)]) {
            debugWriteln("  ", baseName(fall.file), ": ", composeSequenceString(fall.keysyms));
        }
        if (faelle.length > COMPOSE_CONFLICT_LOG_LIMIT) {
            debugWriteln("  ... and ", faelle.length - COMPOSE_CONFLICT_LOG_LIMIT, " more");
        }
    }
}

void loadModule(string fname) {
    /// Load a module file and add all entries, if they are not in the remove-tree
    string content = cast(string) std.file.read(fname);
    string[] lines = split(content, "\n");

    beginComposeFile(fname);

    // Direktiven wirken erst nach der letzten Zeile: #klebrig steht im Kopf
    // der Datei, der genannte Knoten entsteht aber erst mit den Eintraegen.
    uint[][] klebrigePfade;
    uint[] klebrigeZeilen;

    foreach (index, l; lines) {
        // 1-basiert, damit die Zeilennummer zu der im Editor passt.
        const uint nummer = cast(uint)(index + 1);
        const art = classifyComposeLine(l);
        if (art == ComposeLineKind.EMPTY || art == ComposeLineKind.COMMENT) continue;

        if (art == ComposeLineKind.DIRECTIVE) {
            try {
                klebrigePfade ~= parseStickyDirective(l);
                klebrigeZeilen ~= nummer;
            } catch (Exception e) {
                meldeComposeZeile(ComposeRecord(fname, nummer, [], ""w, l.idup,
                    ComposeOutcome.UNPARSED));
                debugWriteln("Unparsable directive ", fname, ":", nummer, ": ", l);
            }
            continue;
        }

        try {
            auto entry = parseLine(l);
            if (isEntryInComposeTree(entry, removeComposeRoot)) {
                noteComposeRemoved(fname, nummer, entry);
            } else {
                noteComposeResult(fname, nummer, entry, addComposeEntry(entry, composeRoot));
            }
        } catch (Exception e) {
            // Eine Zeile, die wie ein Eintrag aussieht, sich aber nicht lesen
            // laesst. Vor Paket 8 verschwand sie spurlos im selben catch-Zweig
            // wie die Kommentare.
            beginComposeFile(fname);
            meldeComposeZeile(ComposeRecord(fname, nummer, [], ""w, l.idup,
                ComposeOutcome.UNPARSED));
            debugWriteln("Unparsable line ", fname, ":", nummer, ": ", l);
        }
    }

    // Ein Pfad ins Leere ist derselbe Fehler wie eine unlesbare Eintragszeile
    // und wird auch so gemeldet - sonst faenge ihn kein Waechter ab.
    foreach (i, pfad; klebrigePfade) {
        if (!markSticky(pfad, composeRoot)) {
            meldeComposeZeile(ComposeRecord(fname, klebrigeZeilen[i], pfad.dup, ""w,
                COMPOSE_STICKY_DIRECTIVE, ComposeOutcome.UNPARSED));
            debugWriteln("Sticky directive points nowhere ", fname, ":",
                klebrigeZeilen[i]);
        }
    }
}

void loadRemoveModule(string fname) {
    /// Load a module file and add all entries to the remove-tree
    string content = cast(string) std.file.read(fname);
    string[] lines = split(content, "\n");
    foreach(l; lines) {
        const art = classifyComposeLine(l);
        if (art == ComposeLineKind.EMPTY || art == ComposeLineKind.COMMENT) continue;

        try {
            auto entry = parseLine(l);
            // Kollisionen im Entfernungsbaum sind uninteressant: Er wird nur
            // abgefragt, nicht abgespielt, und doppelt genannte Sequenzen sind
            // in .remove-Dateien folgenlos.
            cast(void) addComposeEntry(entry, removeComposeRoot);
        } catch (Exception e) {
            // Eine kaputte Zeile im Entfernungsbaum - der hat keine
            // Buchfuehrung, deshalb bleibt das hier ungemeldet.
        }
    }
}

/// Der Keysym-Pfad von der Wurzel zu diesem Knoten. Fuer die Anzeige und die
/// Abbruchkette nach einem Ruecksprung.
private uint[] pfadZu(const(ComposeNode)* knoten) nothrow {
    uint[] rueckwaerts;
    auto n = knoten;
    while (n !is null && n.prev !is null) {
        rueckwaerts ~= n.keysym;
        n = n.prev;
    }
    uint[] pfad;
    pfad.length = rueckwaerts.length;
    foreach (i, k; rueckwaerts) pfad[$ - 1 - i] = k;
    return pfad;
}

/// Liegt dieser Knoten in einem klebrigen Zweig - er selbst oder ein Vorfahre?
/// Entscheidet, ob der stumme Ausstieg gilt.
private bool inKlebrigemZweig(const(ComposeNode)* knoten) nothrow {
    auto n = knoten;
    while (n !is null) {
        if (n.klebrig) return true;
        n = n.prev;
    }
    return false;
}

/// Nach einer Ausgabe: zum naechsten klebrigen VORFAHREN zurueckspringen,
/// sonst die Sequenz beenden. true heisst, sie laeuft weiter.
/// Der Knoten selbst zaehlt nicht mit - sonst entstuende eine Schleife auf
/// sich selbst.
private bool ruecksprung(ComposeNode* von) nothrow {
    auto n = von is null ? null : von.prev;
    while (n !is null) {
        if (n.klebrig) {
            currentNode = n;
            // Die Abbruchkette faengt neu an: der Modifikator hat seine
            // Arbeit getan (Spec 7).
            currentSequence = "";
            currentKeysyms = pfadZu(n);
            return true;
        }
        n = n.prev;
    }
    active = false;
    return false;
}

/// Die passende Fortsetzung an einem Knoten: erst der erste Kandidat, dann
/// der zweite (Rastungs-Spec 2.2 - der erste gewinnt, der zweite rettet nur
/// eine Taste, deren erstes Keysym hier tot ist). null, wenn keiner passt;
/// gewaehlt zeigt dann auf den ersten Kandidaten.
private ComposeNode* sucheFortsetzung(ComposeNode* knoten, ref NeoKey nk,
                                      const(NeoKey)* zweit,
                                      out const(NeoKey)* gewaehlt) nothrow {
    gewaehlt = &nk;
    if (knoten is null) return null;

    foreach (kind; knoten.next) {
        if (kind.keysym == nk.keysym) return kind;
    }
    if (zweit !is null) {
        foreach (kind; knoten.next) {
            if (kind.keysym == zweit.keysym) {
                gewaehlt = zweit;
                return kind;
            }
        }
    }
    return null;
}

/// Das Zeichen, mit dem eine Taste in der Abbruchkette erscheint. 0, wenn sie
/// keines hat (Eingabe, Tabulator, Pfeile) - eine solche Taste geht beim
/// Abbruch verloren, das ist geerbtes Verhalten (Spec 12, Punkt 2).
private dchar zeichenVon(const(NeoKey)* taste) nothrow {
    if (taste is null) return 0;
    if (taste.keysym in codepointsByKeysym) {
        return dchar(codepointsByKeysym[taste.keysym]);
    }
    if (taste.keysym > KEYSYM_CODEPOINT_OFFSET) {
        return dchar(taste.keysym - KEYSYM_CODEPOINT_OFFSET);
    }
    if (taste.keytype == NeoKeyType.CHAR && taste.chars.length > 0) {
        try {
            wstring rest = taste.chars;
            return decodeFront(rest);  // Surrogatpaar -> ein Codepunkt
        } catch (Exception e) {
            // kaputte Surrogatfolge: kein Abbruchzeichen
        }
    }
    return 0;
}

ComposeResult compose(NeoKey nk, const(NeoKey)* zweit = null) nothrow {
    if (!active) {
        // Der Zweitkandidat gilt nur fuer Fortsetzungen einer laufenden
        // Sequenz. Beim Start wuerde er das Blocktippen kapern: Die Taste
        // wuerde geschluckt, statt ihr Zeichen zu liefern (Rastungs-Spec 2.1).
        zweit = null;
        foreach (startNode; composeRoot.next) {
            if (startNode.keysym == nk.keysym) {
                active = true;
                // Clear compose sequence at the beginning
                currentSequence = "";
                currentKeysyms = [];
                currentNode = &composeRoot;
                break;
            }
        }

        if (!active) {
            return ComposeResult(ComposeResultType.PASS, ""w);
        } else {
            debugWriteln("Starting compose sequence");
        }
    }

    if (active) {
        if (currentSpecialMode) {
            // Kandidatenwahl im Sondermodus (Sondermodi-Spec 2): Der
            // Probelauf fragt, ohne etwas zu aendern - erst den ersten
            // Kandidaten, dann den zweiten. Lehnen beide ab, laeuft der
            // erste echt durch und bricht ab wie bisher. Welcher Kandidat
            // der erste ist, entscheidet der Aufrufer (ananeo.d).
            const(NeoKey)* gewaehlt = &nk;
            if (zweit !is null
                && currentSpecialMode(nk, true).type == ComposeResultType.ABORT
                && currentSpecialMode(*zweit, true).type != ComposeResultType.ABORT) {
                gewaehlt = zweit;
            }

            auto specialResult = currentSpecialMode(*gewaehlt, false);
            if (specialResult.type == ComposeResultType.ABORT || specialResult.type == ComposeResultType.FINISH) {
                // Special mode has finished, reset compose to normal state
                active = false;
                currentSpecialMode = null;
                debugWriteln("Special compose sequence finished");
            }
            return specialResult;
        } else {
            // Kandidatenwahl (Rastungs-Spec 2.2): der erste gewinnt, der
            // zweite rettet nur eine Taste, deren erstes Keysym hier tot ist.
            // Welcher Kandidat der erste ist - gerastet zuerst, beim
            // Rueckfall gedreht - entscheidet der Aufrufer (ananeo.d).
            const(NeoKey)* gewaehlt;
            ComposeNode* next = sucheFortsetzung(currentNode, nk, zweit, gewaehlt);
            const bool foundNext = next !is null;

            // Abbruchkette: das Zeichen des Kandidaten, der zaehlt - bei
            // Scheitern beider das des ersten (Rastungs-Spec 4.3).
            dchar sequenceChar = zeichenVon(gewaehlt);
            if (sequenceChar) {
                debugWriteln("Added char to compose abort sequence: ", [sequenceChar].toUTF8);
                currentSequence ~= sequenceChar;
            }

            if (foundNext) {
                currentKeysyms ~= gewaehlt.keysym;

                if (next.next.length == 0) {
                    // this was the final key
                    if (next.specialMode) {
                        // user entered the leader sequence for a special mode
                        // the following key presses will be handled by the associated special mode function
                        debugWriteln("Starting special compose sequence");
                        currentSpecialMode = next.specialMode;
                        return ComposeResult(ComposeResultType.EAT, ""w);
                    } else {
                        // Ausgeben - und weiterlaufen, wenn ein klebriger
                        // Vorfahre da ist (Spec 3.1).
                        auto ergebnis = next.result;
                        if (ruecksprung(next)) {
                            debugWriteln("Compose emitted, sticky ancestor resumed");
                            return ComposeResult(ComposeResultType.EMIT, ergebnis);
                        }
                        debugWriteln("Compose finished");
                        return ComposeResult(ComposeResultType.FINISH, ergebnis);
                    }
                } else {
                    currentNode = next;
                    try {
                        debugWriteln("Next: ", currentNode.next.map!(n => format("0x%X", n.keysym)).join(", "));
                    } catch (Exception e) {
                        // Doesn't matter
                    }
                    return ComposeResult(ComposeResultType.EAT, ""w);
                }
            } else {
                // Vier Faelle liegen hier uebereinander, und die Reihenfolge
                // ist Absicht: Escape verwirft alles, der stumme Ausstieg gibt
                // ein gehaltenes Ergebnis noch aus, der Halte-Zweig gibt aus
                // und prueft erneut, der gewoehnliche Abbruch bleibt zuletzt.

                // 1. Escape verwirft auch ein gehaltenes Ergebnis - das ist
                // seine Rolle, keine des Ausstiegs (Spec 4, Weg 2).
                if (nk.keysym == keysymsByName["Escape"]) {
                    active = false;
                    debugWriteln("Compose aborted by Escape");
                    return ComposeResult(ComposeResultType.ABORT, ""w);
                }

                // 2. Stummer Ausstieg (Spec 4, Weg 3): In einem klebrigen
                // Zweig beendet das Wurzelzeichen der Sequenz den Modus, ohne
                // sich selbst zu tippen. Das Keysym des klebrigen Knotens
                // taugt dafuer nicht - der Schrift-Familienknoten traegt "l",
                // und "l" ist dort eine gueltige Fortsetzung. Ein gehaltenes
                // Ergebnis wird dabei aber noch faellig - der Ausstieg
                // verwirft nichts, das ist Escapes Rolle.
                if (!foundNext && currentKeysyms.length > 0
                    && gewaehlt.keysym == currentKeysyms[0]
                    && inKlebrigemZweig(currentNode)) {
                    active = false;
                    auto beimAusstieg = currentNode.result;
                    debugWriteln("Sticky compose mode left");
                    return ComposeResult(
                        beimAusstieg.length > 0 ? ComposeResultType.FINISH : ComposeResultType.ABORT,
                        beimAusstieg);
                }

                // 3. Kein Kind passt. Haelt der Knoten ein Ergebnis fest
                // (Doppelrolle), wird es jetzt faellig - und die Taste am
                // klebrigen Vorfahren noch einmal geprueft (Spec 7).
                auto gehalten = currentNode.result;

                if (gehalten.length > 0) {
                    if (ruecksprung(currentNode)) {
                        const(NeoKey)* zweitGewaehlt;
                        ComposeNode* wieder =
                            sucheFortsetzung(currentNode, nk, zweit, zweitGewaehlt);
                        if (wieder !is null) {
                            currentKeysyms ~= zweitGewaehlt.keysym;
                            if (wieder.next.length == 0) {
                                if (wieder.specialMode !is null) {
                                    // Sondermodus-Blatt: scharf machen wie im
                                    // gewoehnlichen Pfad, der dafuer EAT
                                    // liefert. Hier ist zusaetzlich das
                                    // gehaltene Ergebnis faellig, deshalb EMIT
                                    // - die Sequenz laeuft im Sondermodus
                                    // weiter.
                                    currentSpecialMode = wieder.specialMode;
                                    debugWriteln("Compose emitted held result, special compose sequence started");
                                    return ComposeResult(ComposeResultType.EMIT, gehalten);
                                }
                                auto zusammen = gehalten ~ wieder.result;
                                if (ruecksprung(wieder)) {
                                    return ComposeResult(ComposeResultType.EMIT, zusammen);
                                }
                                return ComposeResult(ComposeResultType.FINISH, zusammen);
                            }
                            currentNode = wieder;
                            // Die erneut gepruefte Taste schreibt sich selbst
                            // in die Abbruchkette - im gewoehnlichen Pfad tut
                            // das der Block oben, hier hat der Ruecksprung sie
                            // danach geleert. Es zaehlt der Kandidat, der
                            // gewonnen hat, nicht der erste.
                            const dchar wiederChar = zeichenVon(zweitGewaehlt);
                            if (wiederChar) {
                                currentSequence ~= wiederChar;
                            }
                            return ComposeResult(ComposeResultType.EMIT, gehalten);
                        }
                    }
                    // Auch am Vorfahren nichts - Ende, das Zeichen der Taste
                    // haengt hinten dran wie beim gewoehnlichen Abbruch.
                    // FINISH, nicht EMIT: die Sequenz laeuft hier nicht weiter.
                    active = false;
                    auto letztes = zeichenVon(gewaehlt);
                    auto ausgabe = gehalten;
                    if (letztes) ausgabe ~= toUTF16([letztes]);
                    debugWriteln("Compose emitted held result, sequence ended");
                    return ComposeResult(ComposeResultType.FINISH, ausgabe);
                }

                // 4. Gewoehnlicher Abbruch, wie bisher.
                active = false;
                debugWriteln("Compose aborted");
                // Return and output typed compose sequence
                return ComposeResult(ComposeResultType.ABORT, toUTF16(currentSequence));
            }
        }
    }
    
    return ComposeResult(ComposeResultType.PASS, ""w);
}

// --- Lesende Zugriffe fuer die OSK-Vorschau -------------------------------
// app.d (updateOSK) und ananeo.d (Zustandsvergleich nach compose) lesen den
// Compose-Zustand ueber diese Funktionen statt ueber die Globals - die
// Bedingung "kein Knoten im Sondermodus" steht damit an einer Stelle.

bool composeActive() nothrow {
    return active;
}

bool composeSpecialActive() nothrow {
    return active && currentSpecialMode !is null;
}

/// Der aktuelle Knoten der laufenden Sequenz - null, wenn keine Sequenz
/// laeuft oder ein Sondermodus uebernommen hat (dort gibt es keinen
/// Baumknoten und nichts auf den Tasten zu zeigen).
const(ComposeNode)* currentComposeNode() nothrow {
    if (!active || currentSpecialMode !is null) return null;
    return currentNode;
}

const(uint)[] currentComposeKeysyms() nothrow {
    return active ? currentKeysyms : [];
}

/// Anzeigetext des Sondermodus: "uu " plus Hexziffern bei der
/// Unicode-Eingabe, der rohe Puffer bei den roemischen Zahlen. Leer, wenn
/// kein Sondermodus laeuft. Handgebaute wstring-Anfuegung statt to!wstring,
/// damit die Funktion nothrow bleibt - beide Puffer sind reines ASCII.
wstring composeSpecialBuffer() nothrow {
    if (!active || currentSpecialMode is null) return ""w;

    string puffer;
    wstring text;
    if (currentSpecialMode is &composeUnicode) {
        text = "uu "w;
        puffer = unicodeInput;
    } else if (currentSpecialMode is &composeLowerRoman
               || currentSpecialMode is &composeUpperRoman) {
        puffer = romanNumeralInput;
    }

    foreach (char c; puffer) text ~= cast(wchar) c;
    return text;
}

ComposeResult composeUnicode(const(NeoKey) nk, bool probe) nothrow {
    // Starts processing keys after "uu", then accepts up to six hex digits, terminated by "space"
    // If complete, return matching Unicode char, otherwise abort
    if (unicodeInput.length < 6 && nk.keysym >= KEYSYM_0 && nk.keysym <= KEYSYM_0 + 9) {
        if (!probe) unicodeInput ~= '0' + (nk.keysym - KEYSYM_0);
        return ComposeResult(ComposeResultType.EAT, ""w);
    } else if (unicodeInput.length < 6 && nk.keysym >= KEYSYM_KP_0 && nk.keysym <= KEYSYM_KP_0 + 9) {
        if (!probe) unicodeInput ~= '0' + (nk.keysym - KEYSYM_KP_0);
        return ComposeResult(ComposeResultType.EAT, ""w);
    } else if (unicodeInput.length < 6 && nk.keysym >= KEYSYM_a && nk.keysym <= KEYSYM_a + 5) {
        if (!probe) unicodeInput ~= 'a' + (nk.keysym - KEYSYM_a);
        return ComposeResult(ComposeResultType.EAT, ""w);
    } else if (unicodeInput.length < 6 && nk.keysym >= KEYSYM_A && nk.keysym <= KEYSYM_A + 5) {
        if (!probe) unicodeInput ~= 'a' + (nk.keysym - KEYSYM_A);
        return ComposeResult(ComposeResultType.EAT, ""w);
    } else if (unicodeInput.length >= 2 && nk.keysym == KEYSYM_SPACE) {
        // Angenommen ist das Abschlusszeichen schon hier; ob der Inhalt
        // taugt, entscheidet erst der echte Aufruf (Vertragssatz 3).
        if (probe) return ComposeResult(ComposeResultType.EAT, ""w);

        ComposeResult result;

        try {
            uint codepoint = to!uint(unicodeInput, 16);
            if (codepoint >= 0x20 && codepoint <= 0x10FFFF) { // 0x20 ≙ space
                result.type = ComposeResultType.FINISH;
                // There might be a simpler way to do this...
                // uint codepoint (32 bit) -> UTF-16 string
                result.result = codepoint.to!dchar.to!dstring.to!wstring;
            } else {
                result.type = ComposeResultType.ABORT;
            }
        } catch (Exception e) {
            result.type = ComposeResultType.ABORT;
        }
        unicodeInput = "";  // Important: reset stored codepoint string on finish
        return result;
    } else {
        if (!probe) unicodeInput = "";
        return ComposeResult(ComposeResultType.ABORT, ""w);
    }
}

ComposeResult composeRoman(const(NeoKey) nk, bool upper, bool probe) nothrow {
    // Accepts 1 to 4 decimal digits (1 to 3999), terminated by "space"
    if (romanNumeralInput.length < 4 && nk.keysym >= KEYSYM_0 && nk.keysym <= KEYSYM_0 + 9) {
        if (!probe) romanNumeralInput ~= '0' + (nk.keysym - KEYSYM_0);
        return ComposeResult(ComposeResultType.EAT, ""w);
    } else if (romanNumeralInput.length < 4 && nk.keysym >= KEYSYM_KP_0 && nk.keysym <= KEYSYM_KP_0 + 9) {
        if (!probe) romanNumeralInput ~= '0' + (nk.keysym - KEYSYM_KP_0);
        return ComposeResult(ComposeResultType.EAT, ""w);
    } else if (romanNumeralInput.length >= 1 && nk.keysym == KEYSYM_SPACE) {
        // Wie oben: die Taste ist angenommen, ueber den Inhalt entscheidet
        // erst der echte Aufruf (Vertragssatz 3).
        if (probe) return ComposeResult(ComposeResultType.EAT, ""w);

        ComposeResult result;

        try {
            uint number = to!uint(romanNumeralInput);
            if (1 <= number && number <= 3999) {
                uint caseIndex = upper ? 1 : 0;

                if (uint thousands = number / 1000) {
                    result.result ~= ROMAN_DIGITS[3][thousands - 1][caseIndex];
                }
                if (uint hundreds = (number / 100) % 10) {
                    result.result ~= ROMAN_DIGITS[2][hundreds - 1][caseIndex];
                }
                if (uint tens = (number / 10) % 10) {
                    result.result ~= ROMAN_DIGITS[1][tens - 1][caseIndex];
                }
                if (uint units = number % 10) {
                    result.result ~= ROMAN_DIGITS[0][units - 1][caseIndex];
                }

                result.type = ComposeResultType.FINISH;
            } else {
                result.type = ComposeResultType.ABORT;
            }
        } catch (Exception e) {
            result.type = ComposeResultType.ABORT;
        }

        romanNumeralInput = "";  // Important: reset stored number string on finish
        return result;
    } else {
        if (!probe) romanNumeralInput = "";
        return ComposeResult(ComposeResultType.ABORT, ""w);
    }
}

ComposeResult composeLowerRoman(const(NeoKey) nk, bool probe) nothrow {
    return composeRoman(nk, false, probe);
}

ComposeResult composeUpperRoman(const(NeoKey) nk, bool probe) nothrow {
    return composeRoman(nk, true, probe);
}

unittest {
    // Die Positivliste bestimmt Auswahl und Reihenfolge; zu jedem gewaehlten
    // Modul kommt seine .remove-Datei, sofern es eine gibt.
    auto auswahl = selectComposeFiles(
        ["math", "base", "greek"],
        ["base", "greek", "klingon", "math"],
        ["base", "math"]);

    assert(auswahl.modules == ["math", "base", "greek"]);
    assert(auswahl.removes == ["math", "base"]);
    assert(auswahl.unknown == []);
}

unittest {
    // Ein .remove ohne gleichnamiges Modul gehoert zu einer eingebauten
    // Sonderroutine und wird immer geladen - unabhaengig von der Auswahl.
    // Solche Waisen kommen alphabetisch ans Ende.
    auto auswahl = selectComposeFiles(
        ["base"],
        ["base", "greek"],
        ["unicode", "base", "greek"]);

    assert(auswahl.modules == ["base"]);
    assert(auswahl.removes == ["base", "unicode"]);
    // greek ist nicht ausgewaehlt, also wird auch greek.remove nicht geladen
    assert(!auswahl.removes.canFind("greek"));
}

unittest {
    // Namen ohne passende Datei werden gemeldet, nicht stillschweigend
    // uebergangen; die uebrigen laden trotzdem.
    auto auswahl = selectComposeFiles(
        ["base", "gibtsnicht", "greek"],
        ["base", "greek"],
        []);

    assert(auswahl.modules == ["base", "greek"]);
    assert(auswahl.unknown == ["gibtsnicht"]);
    assert(auswahl.removes == []);
}

unittest {
    // Leere Liste laedt kein Modul, die verwaisten .remove aber schon -
    // sonst wuerde die eingebaute Unicode-Eingabe an en_US scheitern.
    auto auswahl = selectComposeFiles([], ["base"], ["base", "unicode"]);

    assert(auswahl.modules == []);
    assert(auswahl.removes == ["unicode"]);
}

unittest {
    // Verlaengerung (frueher abgelehnt): eine Sequenz, die eine bestehende
    // fortsetzt, wird seit der Doppelrolle-Runde eingetragen und macht den
    // getroffenen Knoten doppelrollig (Spec 3.2, ausfuehrlicher Test am
    // Dateiende).
    ComposeNode wurzel;

    assert(addComposeEntry(ComposeFileLine([1u, 2u], "kurz"w, null), wurzel) == ComposeAddResult.ADDED);
    assert(addComposeEntry(ComposeFileLine([1u, 2u, 3u], "lang"w, null), wurzel) == ComposeAddResult.DUAL);

    assert(wurzel.next.length == 1);
    auto knoten1 = wurzel.next[0];
    assert(knoten1.keysym == 1u);
    assert(knoten1.next.length == 1);
    auto knoten2 = knoten1.next[0];
    assert(knoten2.keysym == 2u);
    // Der Knoten behaelt sein Ergebnis und bekommt zusaetzlich ein Kind
    assert(knoten2.result == "kurz"w);
    assert(knoten2.next.length == 1);
    auto knoten3 = knoten2.next[0];
    assert(knoten3.keysym == 3u);
    assert(knoten3.result == "lang"w);
}

unittest {
    // Praefix (frueher abgelehnt): eine Sequenz, die vorzeitig auf einem
    // Verzweigungsknoten endet, wird seit der Doppelrolle-Runde eingetragen -
    // der bestehende Baum bleibt daneben erhalten (Spec 3.2).
    ComposeNode wurzel;

    assert(addComposeEntry(ComposeFileLine([1u, 2u, 3u], "lang"w, null), wurzel) == ComposeAddResult.ADDED);
    assert(addComposeEntry(ComposeFileLine([1u, 2u], "kurz"w, null), wurzel) == ComposeAddResult.DUAL);

    auto knoten2 = wurzel.next[0].next[0];
    assert(knoten2.keysym == 2u);
    // Das Ergebnis der kuerzeren Sequenz wurde jetzt eingetragen
    assert(knoten2.result == "kurz"w);
    assert(knoten2.next.length == 1);
    assert(knoten2.next[0].result == "lang"w);
}

unittest {
    // Exaktes Duplikat: ueberschreibt still, die zuletzt geladene Datei gewinnt
    ComposeNode wurzel;

    assert(addComposeEntry(ComposeFileLine([1u, 2u], "erst"w, null), wurzel) == ComposeAddResult.ADDED);
    assert(addComposeEntry(ComposeFileLine([1u, 2u], "zweit"w, null), wurzel) == ComposeAddResult.OVERWRITTEN);

    auto knoten2 = wurzel.next[0].next[0];
    assert(knoten2.result == "zweit"w);
    assert(wurzel.next.length == 1);
    assert(wurzel.next[0].next.length == 1);
}

unittest {
    // Ein Zwischenknoten ohne eigenes Ergebnis gilt nicht als belegt: die
    // laengere Sequenz kommt zuerst, die kuerzere Praefixsequenz scheitert
    // (Praefix), aber ein Geschwistereintrag ist ein normales ADDED.
    ComposeNode wurzel;

    assert(addComposeEntry(ComposeFileLine([1u, 2u], "eins-zwei"w, null), wurzel) == ComposeAddResult.ADDED);
    assert(addComposeEntry(ComposeFileLine([1u, 3u], "eins-drei"w, null), wurzel) == ComposeAddResult.ADDED);
    assert(wurzel.next[0].next.length == 2);

    // Sonderroutinen belegen einen Knoten ohne Ergebnistext. Anders als ein
    // gewoehnlicher Knoten bleiben sie von der Doppelrolle ausgenommen - eine
    // nachfolgende Verlaengerung bleibt abgelehnt (Spec 7).
    ComposeNode zweiteWurzel;
    assert(addComposeEntry(ComposeFileLine([1u, 2u], ""w, &composeUnicode), zweiteWurzel) == ComposeAddResult.ADDED);
    assert(addComposeEntry(ComposeFileLine([1u, 2u, 3u], "lang"w, null), zweiteWurzel) == ComposeAddResult.REJECTED);
    // Und ein exaktes Duplikat ueberschreibt die Sonderroutine
    assert(addComposeEntry(ComposeFileLine([1u, 2u], "statt dessen"w, null), zweiteWurzel) == ComposeAddResult.OVERWRITTEN);
    assert(zweiteWurzel.next[0].next[0].specialMode is null);
}

unittest {
    // Die lesbare Darstellung fuer den Bericht: Keysyms mit bekanntem
    // Codepunkt werden zu Zeichen, benannte ohne Codepunkt zum Namen,
    // alles uebrige bleibt hexadezimal.
    scope(exit) {
        codepointsByKeysym.clear();
        keysymsByName.clear();
        composeKeysymNames.clear();
    }
    codepointsByKeysym.clear();
    keysymsByName.clear();
    composeKeysymNames.clear();
    codepointsByKeysym[0x41] = 0x41;   // 'A'
    keysymsByName["Multi_key"] = 0xFF20;

    assert(composeSequenceString([0x41]) == "A");
    // Keysym oberhalb des Codepunkt-Offsets wird direkt umgerechnet
    assert(composeSequenceString([KEYSYM_CODEPOINT_OFFSET + 0x2200]) == "∀");
    // Benanntes Keysym ohne Codepunkt erscheint unter seinem Namen
    assert(composeSequenceString([0xFF20, 0x41]) == "<Multi_key> A");
    // Voellig unbekanntes Keysym bleibt hexadezimal
    assert(composeSequenceString([0x41, 0xFF21]) == "A 0xFF21");
}

unittest {
    // isEntryInComposeTree vergleicht nur das Ergebnis des zuletzt erreichten
    // Knotens mit dem gesuchten Ergebnis. Die Schleife bricht beim ersten
    // nicht gefundenen Keysym einfach ab, ohne das zu vermerken - sie prueft
    // also nicht, ob die komplette Sequenz im Baum existiert.
    ComposeNode wurzel;

    cast(void) addComposeEntry(ComposeFileLine([1u, 2u], "treffer"w, null), wurzel);

    assert(isEntryInComposeTree(ComposeFileLine([1u, 2u], "treffer"w, null), wurzel));
    assert(!isEntryInComposeTree(ComposeFileLine([1u, 2u], "anderes"w, null), wurzel));
    assert(!isEntryInComposeTree(ComposeFileLine([1u], "treffer"w, null), wurzel));

    // Bekannter Fehler, den Paket 3 aufgreift (hier nur dokumentiert, die
    // Funktion wird bewusst nicht geaendert): eine laengere Sequenz als der
    // eingetragene Pfad liefert faelschlich ebenfalls true, weil ab dem
    // fehlenden dritten Keysym (9) einfach am zuletzt erreichten Knoten
    // (Knoten 2, Ergebnis "treffer") weiterverglichen wird. Praktische Folge:
    // ein .remove-Eintrag kann damit auch laengere Sequenzen mit demselben
    // Praefix und Ergebnis versehentlich mit entfernen.
    assert(isEntryInComposeTree(ComposeFileLine([1u, 2u, 9u], "treffer"w, null), wurzel));
}

unittest {
    // Paket 7 / Inhaltsrunde: Das Modul der Hoch-/Tiefstell-Praefixe
    // (^-Taste im Mathe-Block) muss laden und die Kernsequenzen tragen.
    // Die vollstaendige Tabelle prueft Waechter 5 in composeaudit.d.
    import std.file : readText;
    import std.string : lineSplitter;
    import keysyms : initKeysyms;

    initKeysyms(".");
    ComposeNode wurzel;
    foreach (zeile; readText("compose/ananeo-hochtief.module").lineSplitter) {
        try {
            cast(void) addComposeEntry(parseLine(zeile.idup), wurzel);
        } catch (Exception e) {
            // Kommentare und Leerzeilen
        }
    }

    assert(isEntryInComposeTree(parseLine(`<U02E3> <2> : "²"`), wurzel));
    assert(isEntryInComposeTree(parseLine(`<U02E3> <n> : "ⁿ"`), wurzel));
    assert(isEntryInComposeTree(parseLine(`<U02E3> <a> : "ᵃ"`), wurzel));
    assert(isEntryInComposeTree(parseLine(`<U2093> <2> : "₂"`), wurzel));
    assert(isEntryInComposeTree(parseLine(`<U2093> <parenleft> : "₍"`), wurzel));
}

unittest {
    // Anti-Drift: Der Beobachter muss jede Zeile melden, die auch die
    // bestehende Buchfuehrung zaehlt. Laufen beide auseinander, liefert das
    // Werkzeug spaeter Zahlen, die das laufende Programm nicht kennt - genau
    // der Fehler, den die Python-Replik der 3b-Vorarbeit nur durch Handarbeit
    // vermieden hat.
    import keysyms : initKeysyms;

    initKeysyms(".");

    ComposeRecord[] gesammelt;
    composeObserver = (ComposeRecord r) nothrow {
        try { gesammelt ~= r; } catch (Exception e) {}
    };
    scope(exit) composeObserver = null;

    initCompose(".", ["base", "diacritics"]);

    uint[ComposeOutcome] gezaehlt;
    foreach (r; gesammelt) gezaehlt[r.outcome] = gezaehlt.get(r.outcome, 0) + 1;

    uint added, overwritten, dual, rejected, removed;
    foreach (datei, stats; composeStatsByFile) {
        added += stats.added;
        overwritten += stats.overwritten;
        dual += stats.dual;
        rejected += stats.rejected;
        removed += stats.removed;
    }

    assert(gezaehlt.get(ComposeOutcome.ADDED, 0) == added);
    assert(gezaehlt.get(ComposeOutcome.OVERWRITTEN, 0) == overwritten);
    assert(gezaehlt.get(ComposeOutcome.DUAL, 0) == dual);
    assert(gezaehlt.get(ComposeOutcome.REJECTED, 0) == rejected);
    assert(gezaehlt.get(ComposeOutcome.REMOVED, 0) == removed);

    // Zeilennummern sind 1-basiert und innerhalb einer Datei aufsteigend.
    // Ausnahme: die eingebauten Sonderroutinen (COMPOSE_BUILTIN_NAME) haben
    // keine Quelldatei und melden bewusst Zeile 0 (siehe addBuiltinComposeEntry).
    string letzteDatei;
    uint letzteZeile;
    foreach (r; gesammelt) {
        if (r.file == COMPOSE_BUILTIN_NAME) continue;
        assert(r.line >= 1, "Zeilennummer 0 - Zaehlung ist nicht 1-basiert");
        if (r.file == letzteDatei) assert(r.line > letzteZeile);
        letzteDatei = r.file;
        letzteZeile = r.line;
    }
}

unittest {
    // Ein konfigurierter Name ohne passende .module-Datei muss nach
    // initCompose im modulweiten composeUnknownModules stehen - das Werkzeug
    // fragt das nach jedem Ladevorgang ab, um laut zu scheitern, statt eine
    // leere Auswahl stillschweigend als "0 Treffer" zu melden (Codereview,
    // Important 2). Bekannte Namen duerfen dort nicht auftauchen.
    import keysyms : initKeysyms;

    initKeysyms(".");

    initCompose(".", ["base", "gibtsnicht"]);
    assert(composeUnknownModules == ["gibtsnicht"]);

    // Ein zweiter Ladevorgang mit ausschliesslich bekannten Namen muss die
    // Liste wieder leeren - initCompose setzt composeUnknownModules bei
    // jedem Aufruf neu, wie composeStatsOrder auch.
    initCompose(".", ["base"]);
    assert(composeUnknownModules == []);
}

unittest {
    // Zeilenklassifizierung: Gemessen am 02.08.2026 ist in allen zwoelf
    // Moduldateien jede Zeile entweder leer, ein #-Kommentar oder eine mit <
    // beginnende Eintragszeile. OTHER gibt es heute nicht - die Kategorie
    // existiert, damit eine solche Zeile kuenftig auffaellt statt zu
    // verschwinden.
    assert(classifyComposeLine("") == ComposeLineKind.EMPTY);
    assert(classifyComposeLine("   \t ") == ComposeLineKind.EMPTY);
    assert(classifyComposeLine("# Kommentar") == ComposeLineKind.COMMENT);
    assert(classifyComposeLine("   # eingerueckt") == ComposeLineKind.COMMENT);
    assert(classifyComposeLine(`<a> <b> : "c"`) == ComposeLineKind.ENTRY);
    assert(classifyComposeLine(`  <a> : "b"`) == ComposeLineKind.ENTRY);
    assert(classifyComposeLine("include \"foo\"") == ComposeLineKind.OTHER);
}

unittest {
    // Der Parser wirft bei kaputten Eintragszeilen eine Exception, statt sich
    // auf assert zu verlassen: In --build=release sind Asserts entfernt, und
    // dieselbe Zeile lief dann in quotedString in eine Endlosschleife.
    import std.exception : assertThrown;

    assertThrown!Exception(parseLine(`<a> <b> "c"`));      // Doppelpunkt fehlt
    assertThrown!Exception(parseLine(`<a> <b> : c`));      // Ergebnis nicht in Anfuehrungszeichen
    assertThrown!Exception(parseLine(`<a> <b> : "c`));     // Anfuehrungszeichen nicht geschlossen
    assertThrown!Exception(parseLine(`<a <b> : "c"`));     // spitze Klammer nicht geschlossen
    assertThrown!Exception(parseLine("<a> <b> : \"c\\"));  // Escape am Zeilenende ohne Folgezeichen
}

unittest {
    // Eine kaputte Eintragszeile wird als UNPARSED gemeldet, ein Kommentar
    // nicht. Vor dieser Aenderung verschwanden beide gleichermassen im
    // catch-Zweig von loadModule.
    import keysyms : initKeysyms;
    import std.exception : collectException;
    import std.file : mkdirRecurse, remove, rmdir, write;
    import std.path : buildPath;

    initKeysyms(".");

    auto verzeichnis = buildPath(tempDir(), "ananeo-unparsed-test");
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
        "# nur ein Kommentar\n" ~
        `<Multi_key> <a> : "x"` ~ "\n" ~
        `<Multi_key> <b> "y"` ~ "\n");

    ComposeRecord[] gesammelt;
    composeObserver = (ComposeRecord r) nothrow {
        try { gesammelt ~= r; } catch (Exception e) {}
    };
    scope(exit) composeObserver = null;

    initCompose(verzeichnis, ["probe"]);

    auto kaputt = gesammelt.filter!(r => r.outcome == ComposeOutcome.UNPARSED).array;
    assert(kaputt.length == 1, "genau eine kaputte Zeile erwartet");
    assert(kaputt[0].line == 3);
    assert(kaputt[0].raw.canFind(`<Multi_key> <b>`));
}

unittest {
    // Pfad und Knoten waehrend einer laufenden Sequenz: Start, Fortschritt,
    // FINISH. Der Compose-Zustand ist global - aufraeumen per scope(exit).
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSpecialMode = null;
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "\u00E6"w, null), composeRoot);

    NeoKey a; a.keysym = 0x61;
    NeoKey e; e.keysym = 0x65;

    assert(!composeActive());
    assert(currentComposeNode() is null);
    assert(currentComposeKeysyms().length == 0);

    auto r1 = compose(a);
    assert(r1.type == ComposeResultType.EAT);
    assert(composeActive());
    assert(currentComposeKeysyms() == [0x61u]);
    auto knoten = currentComposeNode();
    assert(knoten !is null && knoten.keysym == 0x61);

    auto r2 = compose(e);
    assert(r2.type == ComposeResultType.FINISH && r2.result == "\u00E6"w);
    assert(!composeActive(), "FINISH beendet die Sequenz");
    assert(currentComposeNode() is null);
    assert(currentComposeKeysyms().length == 0);
}

unittest {
    // ABORT raeumt genauso auf wie FINISH - der Uebergang, den eine
    // Vorschau am leichtesten uebersieht (Spec, Abschnitt 4.3).
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSpecialMode = null;
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "x"w, null), composeRoot);

    NeoKey a; a.keysym = 0x61;
    NeoKey q; q.keysym = 0x71;

    cast(void) compose(a);
    assert(composeActive());
    auto r = compose(q);
    assert(r.type == ComposeResultType.ABORT);
    assert(!composeActive());
    assert(currentComposeNode() is null);
}

unittest {
    // Sondermodus-Puffer: Im Unicode-Modus liefert composeSpecialBuffer den
    // Praefix "uu " plus die getippten Ziffern, currentComposeNode dagegen
    // null - im Sondermodus gibt es keinen Baumknoten und kein Overlay.
    scope(exit) {
        active = false;
        currentSpecialMode = null;
        unicodeInput = "";
    }
    active = true;
    currentSpecialMode = &composeUnicode;
    unicodeInput = "2200";

    assert(composeSpecialActive());
    assert(composeSpecialBuffer() == "uu 2200"w);
    assert(currentComposeNode() is null);
}

unittest {
    // Zweitkandidat (Rastungs-Spec 2.2): Der erste gewinnt bei Doppeltreffer,
    // der zweite rettet nur die tote Taste.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSpecialMode = null;
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "klein"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x45], "gross"w, null), composeRoot);

    NeoKey a; a.keysym = 0x61;
    NeoKey e; e.keysym = 0x65;
    NeoKey gross; gross.keysym = 0x45;

    // Doppeltreffer: beide Kandidaten setzen fort, der erste zaehlt.
    cast(void) compose(a);
    auto r1 = compose(gross, &e);
    assert(r1.type == ComposeResultType.FINISH && r1.result == "gross"w,
        "der erste Kandidat muss bei Doppeltreffer gewinnen");

    // Rettung: der erste ist tot, der zweite setzt fort.
    NeoKey tot; tot.keysym = 0x9999;
    cast(void) compose(a);
    auto r2 = compose(tot, &e);
    assert(r2.type == ComposeResultType.FINISH && r2.result == "klein"w,
        "der zweite Kandidat muss die tote Taste retten");
}

unittest {
    // Abbruchkette (Rastungs-Spec 4.3): Der Kandidat, der zaehlt, liefert das
    // Zeichen; scheitern beide, das des ersten.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSpecialMode = null;
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65, 0x78], "!"w, null), composeRoot);

    NeoKey zeichen(uint keysym, wstring chars) {
        NeoKey k;
        k.keysym = keysym;
        k.keytype = NeoKeyType.CHAR;
        k.chars = chars;
        return k;
    }
    auto a = zeichen(0x61, "a"w);
    auto e = zeichen(0x65, "e"w);
    auto q = zeichen(0x71, "q"w);
    auto z = zeichen(0x7A, "z"w);
    NeoKey stumm; stumm.keysym = 0x9999;  // kein Zeichen, setzt nie fort

    // Der gerettete zweite Kandidat traegt SEIN Zeichen ein und SEIN Keysym.
    cast(void) compose(a);
    cast(void) compose(q, &e);
    assert(currentComposeKeysyms() == [0x61u, 0x65u],
        "der Kandidat, der zaehlt, steht in der Sequenz");
    auto r1 = compose(stumm);
    assert(r1.type == ComposeResultType.ABORT && r1.result == "ae"w,
        "Abbruchkette traegt das Zeichen des geretteten Kandidaten");

    // Scheitern beide, zaehlt das Zeichen des ersten.
    cast(void) compose(a);
    auto r2 = compose(q, &z);
    assert(r2.type == ComposeResultType.ABORT && r2.result == "aq"w,
        "bei Scheitern beider zaehlt das Zeichen des ersten Kandidaten");
}

unittest {
    // Der Start ignoriert den Zweitkandidaten (Rastungs-Spec 2.1) - sonst
    // kaperte ein Zweitkandidat, der eine Sequenz beginnt, das Blocktippen.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSpecialMode = null;
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "x"w, null), composeRoot);

    NeoKey q; q.keysym = 0x71;
    NeoKey a; a.keysym = 0x61;
    auto r = compose(q, &a);
    assert(r.type == ComposeResultType.PASS, "kein gekaperter Start");
    assert(!composeActive());
}

unittest {
    // Die Leitfaelle der Rastungs-Spec (Abschnitte 2 und 6) gegen den
    // ausgelieferten Bestand: Compose-Module der Vorgabe-Konfiguration,
    // layouts.json, Ebenen ueber determineLayer mit echtem Lock-Satz.
    import std.file : readText;
    import std.json : parseJSON;
    import keysyms : initKeysyms;
    import layerlock : determineLayer;
    import mapping : Modifier, NeoLayout, Scancode, initLayouts, layouts, resetLayoutsForTest;

    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSpecialMode = null;
        currentKeysyms = [];
        resetLayoutsForTest();
    }

    initKeysyms(".");
    auto config = parseJSON(readText("config.default.json"));
    string[] modulNamen;
    foreach (eintrag; config["composeModules"].array) modulNamen ~= eintrag.str;
    initCompose(".", modulNamen);

    initLayouts(parseJSON(readText("layouts.json"))["layouts"]);
    NeoLayout* annoted;
    foreach (ref l; layouts) {
        if (l.name == "AnNoted"w) { annoted = &l; break; }
    }
    assert(annoted !is null);

    // Ebene im gegebenen Zustand, wie handleKeyEvent sie bestimmt (ohne
    // Passthrough, ohne Capslock), samt Rueckfall-Meldung.
    uint ebene(Modifier[] gehaltene, Modifier[] lock, bool* rueckfall = null) {
        return determineLayer(annoted.layers,
            delegate bool(Modifier m) nothrow {
                foreach (g; gehaltene) { if (g == m) return true; }
                return false;
            },
            lock, false, false, annoted.layerIgnoresLocks, rueckfall);
    }

    // Taste, deren Zelle auf der Ebene das Keysym traegt.
    Scancode tasteMitKeysym(uint keysym, uint e) {
        foreach (scan, eintrag; annoted.map) {
            if (eintrag.layers.length >= e && eintrag.layers[e - 1].keysym == keysym) {
                return scan;
            }
        }
        assert(false, "Keysym nicht im Layout");
    }
    NeoKey zelle(Scancode scan, uint e) { return annoted.map[scan].layers[e - 1]; }

    // ---- Leitfall 1: x-Kreis ( a unter Mathematik-Rastung (Mod5) ----
    Modifier[] mathe = [Modifier.MOD5];

    // Start ueber Ebene 21 (ignoreLocks), in jedem Rastzustand erreichbar.
    assert(ebene([Modifier.MOD3, Modifier.MOD4], mathe) == 21);
    auto kreis = zelle(tasteMitKeysym(parseKeysym("U24E7"), 21), 21);
    assert(compose(kreis).type == ComposeResultType.EAT);

    // ( liegt nur auf Ebene 3 (t-Taste); unter der Rastung trifft
    // gehaltenes Mod3 die Ebene 7, dort ist die Zelle leer.
    auto scanParen = tasteMitKeysym(parseKeysym("parenleft"), 3);
    assert(ebene([Modifier.MOD3], mathe) == 7);
    assert(ebene([Modifier.MOD3], []) == 3);
    auto parenErst = zelle(scanParen, 7);
    auto parenZweit = zelle(scanParen, 3);
    assert(compose(parenErst, &parenZweit).type == ComposeResultType.EAT,
        "der Zweitkandidat muss ( retten");

    // a: unter der Rastung Ebene 5 (Blockbasis, dort liegt ein
    // Mathematik-Zeichen), Zweitkandidat Ebene 1.
    auto scanA = tasteMitKeysym(parseKeysym("a"), 1);
    assert(ebene([], mathe) == 5);
    auto aErst = zelle(scanA, 5);
    auto aZweit = zelle(scanA, 1);
    auto klammerA = compose(aErst, &aZweit);
    assert(klammerA.type == ComposeResultType.EMIT && klammerA.result == "⒜"w,
        "x-Kreis ( a ist die Klammer-Form von a - und der Zweig ist klebrig");
    assert(composeActive(), "nach EMIT laeuft die Sequenz am klebrigen ⓧ ( weiter");

    // Der Zweitkandidat ueberlebt den Ruecksprung: b kommt unter der Rastung
    // wieder als Paar, und der erste Kandidat ist an der Ebene 5 nicht die
    // lateinische b. Ohne durchgereichten Zweitkandidaten liefert das nichts.
    auto scanB = tasteMitKeysym(parseKeysym("b"), 1);
    auto bErst = zelle(scanB, 5);
    auto bZweit = zelle(scanB, 1);
    auto klammerB = compose(bErst, &bZweit);
    assert(klammerB.type == ComposeResultType.EMIT && klammerB.result == "⒝"w,
        "der Zweitkandidat muss den Ruecksprung ueberleben");

    // Ausstieg ueber das Wurzelzeichen, damit der naechste Leitfall bei null
    // anfaengt.
    assert(compose(kreis).type == ComposeResultType.ABORT);
    assert(!composeActive());

    // ---- Leitfall 2: Hochstellung mit griechischer Basis, primaer ----
    Modifier[] griechisch = [Modifier.MOD7];

    auto hochstell = zelle(tasteMitKeysym(parseKeysym("U02E3"), 21), 21);
    assert(compose(hochstell).type == ComposeResultType.EAT);

    bool rueckfall;
    assert(ebene([], griechisch, &rueckfall) == 13 && !rueckfall,
        "die Griechisch-Basis ist echt gewaehlt, kein Rueckfall");
    auto scanBeta = tasteMitKeysym(parseKeysym("Greek_beta"), 13);
    auto betaErst = zelle(scanBeta, 13);
    auto betaZweit = zelle(scanBeta, 1);  // der lateinische Buchstabe darunter
    auto hochBeta = compose(betaErst, &betaZweit);
    assert(hochBeta.type == ComposeResultType.EMIT && hochBeta.result == "ᵝ"w,
        "der erste Kandidat muss gewinnen: griechisches beta, nicht die "
        ~ "Hochstellung des lateinischen Buchstabens");
    assert(compose(hochstell).type == ComposeResultType.ABORT,
        "das Wurzelzeichen beendet den klebrigen Modus stumm");
    assert(!composeActive());

    // ---- Leitfall 3: Multi_key ( alpha unter Griechisch-Rastung ----
    NeoKey multi;
    multi.keysym = parseKeysym("Multi_key");
    assert(compose(multi).type == ComposeResultType.EAT);

    // Gehaltenes Mod3 faellt unter der Rastung auf Ebene 1 zurueck (der
    // gemessene Befund aus Risiko 7) - dort liegt t, das nach Multi_key
    // selbst fortsetzt. Die Rueckfall-Drehung macht ( zum ersten Kandidaten.
    assert(ebene([Modifier.MOD3], griechisch, &rueckfall) == 1 && rueckfall);
    auto tRueckfall = zelle(scanParen, 1);
    assert(compose(parenZweit, &tRueckfall).type == ComposeResultType.EAT,
        "( muss die Drehung gewinnen, obwohl t fortsetzen wuerde");
    assert(currentComposeKeysyms()[$ - 1] == parseKeysym("parenleft"),
        "in der Sequenz steht (, nicht t");

    auto scanAlpha = tasteMitKeysym(parseKeysym("Greek_alpha"), 13);
    auto alphaErst = zelle(scanAlpha, 13);
    auto alphaZweit = zelle(scanAlpha, 1);
    auto dasia = compose(alphaErst, &alphaZweit);
    assert(dasia.type == ComposeResultType.FINISH && dasia.result == "ἁ"w,
        "Multi_key ( alpha ist alpha mit Dasia");

    // ---- Gegenprobe: Multi_key t m -> Trade-Mark unter Griechisch ----
    // Ohne gehaltenes Mod3 ist die Blockbasis echt gewaehlt (kein Rueckfall):
    // gerastet zuerst, und wo das griechische Zeichen nicht fortsetzt,
    // liefert der Zweitkandidat den lateinischen Buchstaben.
    assert(compose(multi).type == ComposeResultType.EAT);
    assert(ebene([], griechisch, &rueckfall) == 13 && !rueckfall);

    auto scanT = tasteMitKeysym(parseKeysym("t"), 1);
    auto tErst = zelle(scanT, 13);   // tau
    auto tZweit = zelle(scanT, 1);   // t
    assert(compose(tErst, &tZweit).type == ComposeResultType.EAT,
        "t bleibt unter der Rastung erreichbar");

    auto scanM = tasteMitKeysym(parseKeysym("m"), 1);
    auto mErst = zelle(scanM, 13);
    auto mZweit = zelle(scanM, 1);
    auto marke = compose(mErst, &mZweit);
    assert(marke.type == ComposeResultType.FINISH && marke.result == "™"w,
        "Multi_key t m ist das Trade-Mark-Zeichen");

    // ---- Leitfall 4: mehrstellige Hochstellung ----
    assert(compose(hochstell).type == ComposeResultType.EAT);
    auto s1 = zelle(tasteMitKeysym(parseKeysym("1"), 1), 1);
    auto s2 = zelle(tasteMitKeysym(parseKeysym("2"), 1), 1);
    auto s3 = zelle(tasteMitKeysym(parseKeysym("3"), 1), 1);
    auto e1 = compose(s1);
    auto e2 = compose(s2);
    auto e3 = compose(s3);
    assert(e1.type == ComposeResultType.EMIT && e1.result == "¹"w);
    assert(e2.type == ComposeResultType.EMIT && e2.result == "²"w);
    assert(e3.type == ComposeResultType.EMIT && e3.result == "³"w,
        "drei Anschlaege nach dem Modifikator geben ¹²³");
    assert(compose(hochstell).type == ComposeResultType.ABORT);

    // ---- Leitfall 5: die zweistellige Einkreisung ----
    assert(compose(kreis).type == ComposeResultType.EAT);
    auto k1 = zelle(tasteMitKeysym(parseKeysym("1"), 1), 1);
    auto k0 = zelle(tasteMitKeysym(parseKeysym("0"), 1), 1);
    assert(compose(k1).type == ComposeResultType.EAT,
        "x-Kreis 1 haelt ① fest, statt sie auszugeben");
    auto zehn = compose(k0);
    assert(zehn.type == ComposeResultType.EMIT && zehn.result == "⑩"w,
        "⑩ ist ein Zeichen, nicht ①⓪");
    assert(compose(kreis).type == ComposeResultType.ABORT);

    // ---- Leitfall 6: das gehaltene Ergebnis wird faellig ----
    assert(compose(kreis).type == ComposeResultType.EAT);
    assert(compose(k1).type == ComposeResultType.EAT);
    auto scanX = tasteMitKeysym(parseKeysym("x"), 1);
    auto beides = compose(zelle(scanX, 1));
    assert(beides.type == ComposeResultType.EMIT && beides.result == "①ⓧ"w,
        "① wird faellig, die x am klebrigen ⓧ erneut geprueft");
    assert(compose(kreis).type == ComposeResultType.ABORT);

    // ---- Leitfall 7: √ und ∨ als Compose-Zwischentaste ----
    // Die Module benennen diese beiden Zwischentasten mit dem X11-Namen
    // (<radical>, <logicalor>). Solange layouts.json dort U221A/U2228
    // schrieb, lag das Zeichen auf der Taste und der Zweig war trotzdem tot:
    // Der Vergleich geht ueber den Keysym-Wert, nicht ueber das Zeichen.
    // Gemessen am 08.08.2026, 13 ersatzlose Blaetter.
    assert(ebene([Modifier.MOD3], []) == 3);
    auto multiTaste = zelle(tasteMitKeysym(parseKeysym("Multi_key"), 3), 3);
    assert(ebene([Modifier.MOD5], []) == 5, "Mathematik-Ebene ohne Rastung");
    auto wurzel = zelle(tasteMitKeysym(parseKeysym("radical"), 5), 5);
    auto oder = zelle(tasteMitKeysym(parseKeysym("logicalor"), 5), 5);

    assert(compose(multiTaste).type == ComposeResultType.EAT);
    assert(compose(zelle(tasteMitKeysym(parseKeysym("3"), 1), 1)).type == ComposeResultType.EAT);
    auto kubik = compose(wurzel);
    assert(kubik.type == ComposeResultType.FINISH && kubik.result == "∛"w,
        "Multi_key 3 √ ergibt die Kubikwurzel");

    assert(compose(multiTaste).type == ComposeResultType.EAT);
    assert(compose(oder).type == ComposeResultType.EAT);
    auto grossesOder = compose(oder);
    assert(grossesOder.type == ComposeResultType.FINISH && grossesOder.result == "⋁"w,
        "Multi_key ∨ ∨ ergibt das n-stellige Oder");

    // ---- Leitfall 8: ∧ und ∥ haben seit dem 09.08.2026 eine Taste ----
    // Beide standen in keiner Zelle von AnNoted, obwohl math.module sie als
    // Zwischentaste benutzt - 11 ersatzlose Blaetter. ∧ traegt den X11-Namen
    // <logicaland>, ∥ dagegen die Offset-Form <U2225>: Die Module benennen es
    // so, einen Keysym-Namen "parallel" gibt es in keysymdef.h nicht.
    auto und = zelle(tasteMitKeysym(parseKeysym("logicaland"), 5), 5);
    auto par = zelle(tasteMitKeysym(parseKeysym("U2225"), 5), 5);
    assert(ebene([Modifier.MOD3], []) == 3, "underscore liegt auf Ebene 3");
    auto unterstrich = zelle(tasteMitKeysym(parseKeysym("underscore"), 3), 3);

    assert(compose(multiTaste).type == ComposeResultType.EAT);
    assert(compose(und).type == ComposeResultType.EAT);
    auto undUnterbalken = compose(unterstrich);
    assert(undUnterbalken.type == ComposeResultType.FINISH
        && undUnterbalken.result == "⩟"w,
        "Multi_key ∧ _ ergibt LOGICAL AND WITH UNDERBAR - eines der Blaetter, "
        ~ "die die Messung vom 08.08.2026 als ersatzlos ausgewiesen hat");

    assert(compose(multiTaste).type == ComposeResultType.EAT);
    assert(compose(zelle(tasteMitKeysym(parseKeysym("o"), 1), 1)).type
        == ComposeResultType.EAT);
    auto kreisParallel = compose(par);
    assert(kreisParallel.type == ComposeResultType.FINISH
        && kreisParallel.result == "⦷"w,
        "Multi_key o ∥ ergibt CIRCLED PARALLEL");

    // ---- Leitfall 9: die Chancery-Reihe der Schrifttabelle (11.09.2026) ----
    // x-Fraktur c A tippt den Script-Buchstaben MIT Variantenselektor, die
    // Reihe bleibt klebrig; x-Fraktur C A tippt das LaTeX-Makro als Text,
    // weil KaTeX Variantenfolgen ignoriert. Kleinbuchstaben fuehrt keine der
    // beiden Reihen - a bricht ab und tippt die rohe Sequenz.
    auto fraktur = zelle(tasteMitKeysym(parseKeysym("U1D535"), 21), 21);
    auto kleinC = zelle(tasteMitKeysym(parseKeysym("c"), 1), 1);
    auto grossC = zelle(tasteMitKeysym(parseKeysym("C"), 2), 2);
    auto grossA = zelle(tasteMitKeysym(parseKeysym("A"), 2), 2);
    auto grossB = zelle(tasteMitKeysym(parseKeysym("B"), 2), 2);
    auto kleinA = zelle(tasteMitKeysym(parseKeysym("a"), 1), 1);

    assert(compose(fraktur).type == ComposeResultType.EAT);
    assert(compose(kleinC).type == ComposeResultType.EAT);
    auto chanceryA = compose(grossA);
    assert(chanceryA.type == ComposeResultType.EMIT && chanceryA.result == "\U0001D49C\uFE00"w,
        "x-Fraktur c A ergibt U+1D49C plus U+FE00 und haelt die Reihe offen");
    auto chanceryB = compose(grossB);
    assert(chanceryB.type == ComposeResultType.EMIT && chanceryB.result == "ℬ\uFE00"w,
        "die Letterlike-Ausnahme ℬ traegt den Selektor ebenso");
    auto abbruch = compose(kleinA);
    assert(abbruch.type == ComposeResultType.ABORT && abbruch.result == "a"w,
        "nach einer Ausgabe faengt die Abbruchkette neu an: nur das a");

    assert(compose(fraktur).type == ComposeResultType.EAT);
    assert(compose(grossC).type == ComposeResultType.EAT);
    auto makroA = compose(grossA);
    assert(makroA.type == ComposeResultType.EMIT && makroA.result == "\\mathcal{A}"w,
        "x-Fraktur C A tippt das Makro als Text");
    auto makroB = compose(grossB);
    assert(makroB.type == ComposeResultType.EMIT && makroB.result == "\\mathcal{B}"w,
        "die Makro-Reihe ist klebrig");
    assert(compose(fraktur).type == ComposeResultType.ABORT, "stummer Ausstieg");

    assert(compose(fraktur).type == ComposeResultType.EAT);
    assert(compose(kleinC).type == ComposeResultType.EAT);
    auto roh = compose(kleinA);
    assert(roh.type == ComposeResultType.ABORT && roh.result == "\U0001D535ca"w,
        "ohne vorherige Ausgabe tippt der Abbruch die rohe Sequenz");
}

// Diese und die naechsten Tests brauchen KEYSYM_0/KEYSYM_A/... bereits befuellt -
// initKeysyms/initCompose laufen nicht hier, sondern im Leitfall-Test weiter oben
// (um Zeile 1469). Wandert dieser weg oder vor die hiesigen Tests, gilt KEYSYM_0
// als 0 und ein Test besteht dann nur noch zufaellig.
unittest {
    // Vertragssatz 1 (Sondermodi-Spec 2): Der Probelauf aendert nichts -
    // weder bei einer angenommenen noch bei einer abgelehnten Taste. Das
    // ist der Test, der den ganzen Ansatz traegt: Eine vergessene Klammer
    // um eine Zuweisung faellt sonst erst im Betrieb auf.
    scope(exit) {
        active = false;
        currentSpecialMode = null;
        unicodeInput = "";
        romanNumeralInput = "";
    }

    NeoKey ziffer; ziffer.keysym = KEYSYM_0 + 7;
    NeoKey fremd; fremd.keysym = 0x9999;

    unicodeInput = "2200";
    assert(composeUnicode(ziffer, true).type == ComposeResultType.EAT);
    assert(unicodeInput == "2200", "angenommene Taste haengt im Probelauf nichts an");
    assert(composeUnicode(fremd, true).type == ComposeResultType.ABORT);
    assert(unicodeInput == "2200", "abgelehnte Taste raeumt im Probelauf nicht ab");

    romanNumeralInput = "42";
    assert(composeLowerRoman(ziffer, true).type == ComposeResultType.EAT);
    assert(romanNumeralInput == "42");
    assert(composeUpperRoman(fremd, true).type == ComposeResultType.ABORT);
    assert(romanNumeralInput == "42", "auch die roemische Seite bleibt unberuehrt");
}

unittest {
    // Anti-Drift (Sondermodi-Spec 6): Der Probelauf sagt genau dann "nehme
    // ich", wenn der echte Aufruf auf demselben Puffer nicht abbricht.
    // Der Puffer wird je Fall auf einen INHALTLICH gueltigen Stand gesetzt -
    // bei ungueltigem Inhalt gilt die eine erlaubte Abweichung (naechster
    // Test), und die wuerde hier fatal aussehen.
    scope(exit) {
        active = false;
        currentSpecialMode = null;
        unicodeInput = "";
        romanNumeralInput = "";
    }

    uint[] stichprobe = [
        KEYSYM_0, KEYSYM_0 + 9,            // Zahlenreihe
        KEYSYM_KP_0, KEYSYM_KP_0 + 9,      // Nummernblock
        KEYSYM_a, KEYSYM_a + 5,            // Hexbuchstaben klein
        KEYSYM_A, KEYSYM_A + 5,            // Hexbuchstaben gross
        KEYSYM_SPACE,                      // Abschlusszeichen
        parseKeysym("z"),                  // Buchstabe ausserhalb
        parseKeysym("U2264"),              // Blockzeichen der Mathematik-Ebene
        keysymsByName["Escape"]
    ];

    foreach (ks; stichprobe) {
        NeoKey k; k.keysym = ks;

        unicodeInput = "2200";
        auto probeU = composeUnicode(k, true);
        assert(probeU.type != ComposeResultType.FINISH,
            "Vertragssatz 2: der Probelauf antwortet nie mit FINISH");
        assert(probeU.result == ""w, "Vertragssatz 2: das Ergebnisfeld bleibt leer");
        assert(unicodeInput == "2200", "Vertragssatz 1 gilt fuer jede Taste der Stichprobe");
        unicodeInput = "2200";
        const bool echtU = composeUnicode(k, false).type != ComposeResultType.ABORT;
        assert((probeU.type != ComposeResultType.ABORT) == echtU,
            "Unicode: Probelauf und echter Aufruf sind sich uneins");

        romanNumeralInput = "42";
        auto probeR = composeLowerRoman(k, true);
        assert(probeR.type != ComposeResultType.FINISH);
        assert(probeR.result == ""w);
        assert(romanNumeralInput == "42", "Vertragssatz 1 gilt fuer jede Taste der Stichprobe");
        romanNumeralInput = "42";
        const bool echtR = composeLowerRoman(k, false).type != ComposeResultType.ABORT;
        assert((probeR.type != ComposeResultType.ABORT) == echtR,
            "Roemisch: Probelauf und echter Aufruf sind sich uneins");
    }
}

unittest {
    // Vertragssatz 3 (Sondermodi-Spec 2): Der Probelauf urteilt ueber die
    // TASTE, nicht ueber den Ausgang. Bei ungueltigem Inhalt nimmt er das
    // Abschlusszeichen an, waehrend der echte Aufruf abbricht - in beiden
    // Modi. Ohne diesen Test liest die naechste Sitzung den Anti-Drift-Test
    // als Allaussage und "repariert" den Vertrag kaputt.
    scope(exit) {
        active = false;
        currentSpecialMode = null;
        unicodeInput = "";
        romanNumeralInput = "";
    }

    NeoKey leer; leer.keysym = KEYSYM_SPACE;

    unicodeInput = "0019";  // kleiner als 0x20, kein erlaubter Codepunkt
    assert(composeUnicode(leer, true).type == ComposeResultType.EAT);
    assert(unicodeInput == "0019", "der Probelauf raeumt auch hier nicht ab");
    assert(composeUnicode(leer, false).type == ComposeResultType.ABORT);

    romanNumeralInput = "0";  // nicht in 1..3999
    assert(composeLowerRoman(leer, true).type == ComposeResultType.EAT);
    assert(romanNumeralInput == "0");
    assert(composeLowerRoman(leer, false).type == ComposeResultType.ABORT);
}

unittest {
    // Kandidatenwahl im Sondermodus (Sondermodi-Spec 2): erster gewinnt,
    // zweiter rettet, lehnen beide ab, bricht es ab wie bisher. Der Fall
    // "Doppeltreffer" ist zugleich die Nachfolge des Rastungs-Runden-Tests
    // "Der Sondermodus ignoriert den Zweitkandidaten" - dieselbe Eingabe,
    // andere Begruendung.
    scope(exit) {
        active = false;
        currentSpecialMode = null;
        unicodeInput = "";
    }
    active = true;
    currentSpecialMode = &composeUnicode;
    unicodeInput = "";

    NeoKey eins; eins.keysym = KEYSYM_0 + 1;
    NeoKey zwei; zwei.keysym = KEYSYM_0 + 2;
    NeoKey block; block.keysym = parseKeysym("U2264");  // Mathematik-Ebene

    // Doppeltreffer: beide Kandidaten sind Ziffern, der erste zaehlt.
    cast(void) compose(eins, &zwei);
    assert(composeSpecialBuffer() == "uu 1"w, "der erste Kandidat gewinnt");

    // Rettung: der gerastete Kandidat wird abgelehnt, die Ziffer springt ein.
    cast(void) compose(block, &zwei);
    assert(composeSpecialBuffer() == "uu 12"w, "der zweite Kandidat rettet die Taste");

    // Beide abgelehnt: Abbruch wie heute, Puffer geraeumt. Das deckt
    // zugleich Randfall 2 der Spec ab - eine leere Zelle auf der
    // Rueckgriffs-Ebene traegt VOID und wird genauso abgelehnt wie ein
    // beliebiges fremdes Keysym.
    NeoKey fremd; fremd.keysym = KEYSYM_VOID;
    auto r = compose(block, &fremd);
    assert(r.type == ComposeResultType.ABORT && r.result == ""w);
    assert(!composeActive() && unicodeInput == "",
        "der Abbruch raeumt weiter auf (Sondermodi-Spec 4.3)");
}

unittest {
    // Die Laengengrenze ist keine Frage der Ebene (Sondermodi-Spec 6): Eine
    // siebte Hexziffer und eine fuenfte Dezimalstelle werden auch dann
    // abgelehnt, wenn der zweite Kandidat eine gueltige Ziffer traegt.
    scope(exit) {
        active = false;
        currentSpecialMode = null;
        unicodeInput = "";
        romanNumeralInput = "";
    }

    NeoKey ziffer; ziffer.keysym = KEYSYM_0 + 1;
    NeoKey block; block.keysym = parseKeysym("U2264");

    active = true;
    currentSpecialMode = &composeUnicode;
    unicodeInput = "220000";  // sechs Stellen, voll
    assert(compose(block, &ziffer).type == ComposeResultType.ABORT,
        "die siebte Hexziffer wird auch als Rueckgriff abgelehnt");

    active = true;
    currentSpecialMode = &composeLowerRoman;
    romanNumeralInput = "1234";  // vier Stellen, voll
    assert(compose(block, &ziffer).type == ComposeResultType.ABORT,
        "die fuenfte Dezimalstelle ebenso");
}

unittest {
    // Die Leitfaelle der Sondermodi-Spec (Abschnitte 6 und 7) gegen den
    // ausgelieferten Bestand. Ebenen ueber determineLayer mit echtem
    // Lock-Satz, nie hartkodiert.
    import std.file : readText;
    import std.json : parseJSON;
    import keysyms : initKeysyms;
    import layerlock : determineLayer;
    import mapping : Modifier, NeoLayout, Scancode, initLayouts, layouts, resetLayoutsForTest;

    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSpecialMode = null;
        currentKeysyms = [];
        unicodeInput = "";
        romanNumeralInput = "";
        resetLayoutsForTest();
    }

    initKeysyms(".");
    auto config = parseJSON(readText("config.default.json"));
    string[] modulNamen;
    foreach (eintrag; config["composeModules"].array) modulNamen ~= eintrag.str;
    initCompose(".", modulNamen);

    initLayouts(parseJSON(readText("layouts.json"))["layouts"]);
    NeoLayout* annoted;
    foreach (ref l; layouts) {
        if (l.name == "AnNoted"w) { annoted = &l; break; }
    }
    assert(annoted !is null);

    uint ebene(Modifier[] lock) {
        return determineLayer(annoted.layers,
            delegate bool(Modifier m) nothrow { return false; },
            lock, false, false, annoted.layerIgnoresLocks);
    }

    Scancode tasteMitKeysym(uint keysym, uint e) {
        foreach (scan, eintrag; annoted.map) {
            if (eintrag.layers.length >= e && eintrag.layers[e - 1].keysym == keysym) {
                return scan;
            }
        }
        assert(false, "Keysym nicht im Layout");
    }
    NeoKey zelle(Scancode scan, uint e) { return annoted.map[scan].layers[e - 1]; }

    // Eine Taste im gerasteten Zustand tippen: gerastet zuerst, der
    // ungerasteste Zustand als Zweitkandidat - genau wie handleKeyEvent es
    // baut. "grund" ist die Ebene ohne Rastung (hier stets 1, es wird
    // nichts gehalten).
    ComposeResult tippe(uint keysym, uint blockEbene) {
        auto scan = tasteMitKeysym(keysym, 1);
        auto erst = zelle(scan, blockEbene);
        auto zweit = zelle(scan, 1);
        return compose(erst, &zweit);
    }

    // ---- Leitfall 1: uu 2200 unter Mathematik-Rastung (Mod5) ----
    const uint mathe = ebene([Modifier.MOD5]);
    assert(mathe == 5);

    NeoKey multi;
    multi.keysym = parseKeysym("Multi_key");
    assert(compose(multi).type == ComposeResultType.EAT);
    assert(tippe(parseKeysym("u"), mathe).type == ComposeResultType.EAT);
    assert(tippe(parseKeysym("u"), mathe).type == ComposeResultType.EAT);
    assert(composeSpecialActive(), "der Sondermodus laeuft");

    foreach (ziffer; ["2", "2", "0", "0"]) {
        assert(tippe(parseKeysym(ziffer), mathe).type == ComposeResultType.EAT,
            "die Ziffern kommen unter Mathematik-Rastung per Rueckgriff");
    }
    auto fuerAlle = tippe(parseKeysym("space"), mathe);
    assert(fuerAlle.type == ComposeResultType.FINISH && fuerAlle.result == "∀"w,
        "auch das Abschlusszeichen kommt per Rueckgriff - Ebene 5 traegt U+2009");

    // ---- Leitfall 2: rn 42 unter Extra-Rastung (Mod9) ----
    const uint extra = ebene([Modifier.MOD9]);
    assert(extra == 17);

    assert(compose(multi).type == ComposeResultType.EAT);
    assert(tippe(parseKeysym("r"), extra).type == ComposeResultType.EAT);
    assert(tippe(parseKeysym("n"), extra).type == ComposeResultType.EAT);
    assert(tippe(parseKeysym("4"), extra).type == ComposeResultType.EAT);
    assert(tippe(parseKeysym("2"), extra).type == ComposeResultType.EAT);
    auto roemisch = tippe(parseKeysym("space"), extra);
    // ROMAN_DIGITS liefert die Unicode-Zahlzeichen (U+2170-Block), nicht
    // ASCII-Buchstaben - geerbter Bestand aus ReNeo.
    assert(roemisch.type == ComposeResultType.FINISH
        && roemisch.result == "ⅹⅼⅰⅰ"w);

    // ---- Leitfall 3: uu 1f01 unter Griechisch-Rastung (Mod7) ----
    // Die Ziffern liegen dort normal, der Hexbuchstabe ist der Pruefpunkt.
    const uint griechisch = ebene([Modifier.MOD7]);
    assert(griechisch == 13);

    assert(compose(multi).type == ComposeResultType.EAT);
    assert(tippe(parseKeysym("u"), griechisch).type == ComposeResultType.EAT);
    assert(tippe(parseKeysym("u"), griechisch).type == ComposeResultType.EAT);
    foreach (zeichen; ["1", "f", "0", "1"]) {
        assert(tippe(parseKeysym(zeichen), griechisch).type == ComposeResultType.EAT);
    }
    auto dasia = tippe(parseKeysym("space"), griechisch);
    assert(dasia.type == ComposeResultType.FINISH && dasia.result == "ἁ"w,
        "der Hexbuchstabe f kommt unter Griechisch per Rueckgriff");

    // ---- Regression: Mod4-Rastung behaelt ihren Nummernblock ----
    // Das ist der Fall, den die verworfene Pauschalregel zerbrochen haette
    // (Sondermodi-Spec 5): Auf Ebene 4 liegen KP_0 bis KP_9 auf dem
    // Buchstabenfeld, und der GERASTETE Kandidat muss gewinnen. Die
    // Leertaste traegt dort U+202F, ihr Abschluss kommt per Rueckgriff.
    const uint mod4 = ebene([Modifier.MOD4]);
    assert(mod4 == 4);

    assert(compose(multi).type == ComposeResultType.EAT);
    assert(tippe(parseKeysym("u"), mod4).type == ComposeResultType.EAT);
    assert(tippe(parseKeysym("u"), mod4).type == ComposeResultType.EAT);

    foreach (kp; ["KP_2", "KP_2", "KP_0", "KP_0"]) {
        auto scan = tasteMitKeysym(parseKeysym(kp), mod4);
        auto erst = zelle(scan, mod4);
        auto zweit = zelle(scan, 1);
        assert(compose(erst, &zweit).type == ComposeResultType.EAT,
            "der gerastete Nummernblock gewinnt den Probelauf");
    }
    auto ueberNumpad = tippe(parseKeysym("space"), mod4);
    assert(ueberNumpad.type == ComposeResultType.FINISH && ueberNumpad.result == "∀"w,
        "Codepunkteingabe ueber den Mod4-Nummernblock bleibt moeglich");
}

unittest {
    // Die #klebrig-Direktive: Zeilenart, Pfad, Wirkung auf den Knoten.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSpecialMode = null;
        currentKeysyms = [];
    }

    // Zeilenart: die Direktive ist kein Kommentar mehr, jede andere
    // #-Zeile bleibt einer.
    assert(classifyComposeLine("#klebrig <U02E3>") == ComposeLineKind.DIRECTIVE);
    assert(classifyComposeLine("   #klebrig <U02E3>") == ComposeLineKind.DIRECTIVE,
        "fuehrende Leerzeichen aendern die Art nicht");
    assert(classifyComposeLine("#configinfo Schriftvarianten") == ComposeLineKind.COMMENT);
    assert(classifyComposeLine("# klebrig <U02E3>") == ComposeLineKind.COMMENT,
        "das Leerzeichen macht daraus einen gewoehnlichen Kommentar");
    assert(classifyComposeLine(`<Multi_key> <a> : "A"`) == ComposeLineKind.ENTRY);

    // Pfad lesen - als Gegenprobe gegen den anderen Parser, nicht gegen einen
    // hartkodierten Zahlenwert: parseKeysym bildet die UXXXX-Form je nach
    // Codepunkt auf ein Legacy-Keysym oder auf den Offset ab, und beides von
    // Hand nachzurechnen ist eine Fehlerquelle ohne Gegenwert.
    assert(parseStickyDirective("#klebrig <U02E3>")
        == parseLine(`<U02E3> : "x"`).keysyms);
    assert(parseStickyDirective("#klebrig <U24E7> <parenleft>")
        == parseLine(`<U24E7> <parenleft> : "x"`).keysyms);

    // Kaputte Notation wirft, genau wie parseLine.
    bool geworfen;
    try { cast(void) parseStickyDirective("#klebrig"); }
    catch (Exception e) { geworfen = true; }
    assert(geworfen, "#klebrig ohne Pfad ist ein Fehler");

    // Wirkung: der Knoten am Ende des Pfades wird klebrig, ein Pfad ins
    // Leere meldet sich.
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "ae"w, null), composeRoot);
    assert(markSticky([0x61u], composeRoot), "der Knoten a existiert");
    assert(composeRoot.next[0].klebrig);
    assert(!markSticky([0x62u], composeRoot), "der Knoten b existiert nicht");
}

unittest {
    // Die Direktive wirkt auch, wenn sie VOR den Eintraegen steht - sie wird
    // gesammelt und erst nach der letzten Zeile angewendet.
    import std.exception : collectException;
    import std.file : mkdirRecurse, remove, write;
    import std.path : buildPath;

    scope(exit) {
        composeRoot = ComposeNode();
        removeComposeRoot = ComposeNode();
        active = false;
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    removeComposeRoot = ComposeNode();

    auto pfad = buildPath(".", "klebrig-test.module");
    // DMD erlaubt kein try/catch direkt im Rumpf von scope(exit) - deshalb
    // collectException statt eines eigenen catch-Blocks (wie beim
    // UNPARSED-Test weiter oben in dieser Datei).
    scope(exit) { collectException(remove(pfad)); }
    write(pfad,
        "#klebrig <U0061>\n" ~
        `<U0061> <U0065> : "ae"` ~ "\n");

    loadModule(pfad);
    assert(composeRoot.next.length == 1);
    assert(composeRoot.next[0].klebrig,
        "die Direktive im Kopf muss den spaeter entstandenen Knoten treffen");
}

unittest {
    // Doppelrolle (Spec 3.2): Verlaengerung und Praefix werden angenommen und
    // melden DUAL - in BEIDEN Reihenfolgen derselbe Baum. Dieser Test ersetzt
    // die weggefallene Ablehnung.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentKeysyms = [];
    }

    // Reihenfolge A: erst kurz, dann lang (frueher EXTENSION).
    composeRoot = ComposeNode();
    assert(addComposeEntry(ComposeFileLine([0x61, 0x31], "eins"w, null), composeRoot)
        == ComposeAddResult.ADDED);
    assert(addComposeEntry(ComposeFileLine([0x61, 0x31, 0x32], "zwoelf"w, null), composeRoot)
        == ComposeAddResult.DUAL, "das erste Kind unter einem Ergebnis stellt die Doppelrolle her");
    assert(addComposeEntry(ComposeFileLine([0x61, 0x31, 0x33], "dreizehn"w, null), composeRoot)
        == ComposeAddResult.ADDED, "das Geschwister danach ist gewoehnlich");

    auto knotenA = composeRoot.next[0].next[0];
    assert(knotenA.result == "eins"w && knotenA.next.length == 2);

    // Reihenfolge B: erst lang, dann kurz (frueher PREFIX). Derselbe Baum.
    composeRoot = ComposeNode();
    assert(addComposeEntry(ComposeFileLine([0x61, 0x31, 0x32], "zwoelf"w, null), composeRoot)
        == ComposeAddResult.ADDED);
    assert(addComposeEntry(ComposeFileLine([0x61, 0x31, 0x33], "dreizehn"w, null), composeRoot)
        == ComposeAddResult.ADDED);
    assert(addComposeEntry(ComposeFileLine([0x61, 0x31], "eins"w, null), composeRoot)
        == ComposeAddResult.DUAL, "ein Ergebnis auf einem Knoten mit Kindern stellt sie ebenso her");

    auto knotenB = composeRoot.next[0].next[0];
    assert(knotenB.result == "eins"w && knotenB.next.length == 2);
}

unittest {
    // Die Rest-Ablehnung: jede Kombination mit einem Sondermodus bleibt
    // abgelehnt, in beiden Richtungen (Spec 7). Ein Sondermodus haelt kein
    // Ergebnis fest, ueber das die naechste Taste entscheiden koennte.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentKeysyms = [];
    }

    // Kind unter einem Sondermodus-Knoten.
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x75], ""w, &composeUnicode), composeRoot);
    assert(addComposeEntry(ComposeFileLine([0x61, 0x75, 0x31], "x"w, null), composeRoot)
        == ComposeAddResult.REJECTED, "kein Kind unter einem Sondermodus");
    assert(composeRoot.next[0].next[0].next.length == 0);

    // Sondermodus auf einem Knoten, der schon Kinder hat.
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x75, 0x31], "x"w, null), composeRoot);
    assert(addComposeEntry(ComposeFileLine([0x61, 0x75], ""w, &composeUnicode), composeRoot)
        == ComposeAddResult.REJECTED, "kein Sondermodus ueber Kindern");
    assert(composeRoot.next[0].next[0].specialMode is null);
}

unittest {
    // Klebrigkeit (Spec 3.1): Nach einer Ausgabe springt die Sequenz zum
    // naechsten klebrigen Vorfahren zurueck, statt zu enden.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSpecialMode = null;
        currentSequence = "";
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    // ^ (0x5E) als Wurzel, darunter 1 -> "hoch1" und 2 -> "hoch2".
    cast(void) addComposeEntry(ComposeFileLine([0x5E, 0x31], "hoch1"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x5E, 0x32], "hoch2"w, null), composeRoot);
    assert(markSticky([0x5Eu], composeRoot));

    NeoKey wurzel; wurzel.keysym = 0x5E;
    NeoKey eins;   eins.keysym = 0x31;
    NeoKey zwei;   zwei.keysym = 0x32;
    NeoKey punkt;  punkt.keysym = 0x2E; punkt.keytype = NeoKeyType.CHAR; punkt.chars = "."w;

    assert(compose(wurzel).type == ComposeResultType.EAT);

    auto r1 = compose(eins);
    assert(r1.type == ComposeResultType.EMIT && r1.result == "hoch1"w,
        "ein Blatt in einem klebrigen Zweig gibt aus und laeuft weiter");
    assert(composeActive(), "die Sequenz laeuft nach dem Ruecksprung weiter");

    auto r2 = compose(zwei);
    assert(r2.type == ComposeResultType.EMIT && r2.result == "hoch2"w,
        "die naechste Taste wird am klebrigen Vorfahren gesucht");

    // Abbruchkette geleert: Der Modifikator darf sich nicht ein zweites Mal
    // in den Abbruch schreiben (Spec 7).
    auto r3 = compose(punkt);
    assert(r3.type == ComposeResultType.ABORT && r3.result == "."w,
        "nach dem Ruecksprung nur das Zeichen der abbrechenden Taste, kein ^");
    assert(!composeActive());
}

unittest {
    // Gegenprobe (Spec 9, Test 2): OHNE klebrigen Vorfahren bleibt alles wie
    // heute - das ist die Zusicherung an den geerbten Bestand.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSequence = "";
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x5E, 0x31], "hoch1"w, null), composeRoot);

    NeoKey wurzel; wurzel.keysym = 0x5E;
    NeoKey eins;   eins.keysym = 0x31;

    assert(compose(wurzel).type == ComposeResultType.EAT);
    auto r = compose(eins);
    assert(r.type == ComposeResultType.FINISH && r.result == "hoch1"w);
    assert(!composeActive(), "ohne Klebrigkeit endet die Sequenz wie bisher");
}

unittest {
    // Stummer Ausstieg (Spec 4, Weg 3): das Wurzelzeichen des Zweiges beendet
    // den klebrigen Modus ohne Ausgabe.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSequence = "";
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x5E, 0x31], "hoch1"w, null), composeRoot);
    assert(markSticky([0x5Eu], composeRoot));

    NeoKey wurzel; wurzel.keysym = 0x5E;
    wurzel.keytype = NeoKeyType.CHAR;
    wurzel.chars = "^"w;
    NeoKey eins; eins.keysym = 0x31;

    cast(void) compose(wurzel);
    cast(void) compose(eins);
    auto aus = compose(wurzel);
    assert(aus.type == ComposeResultType.ABORT && aus.result == ""w,
        "das Wurzelzeichen beendet stumm, es tippt sich nicht selbst");
    assert(!composeActive());
}

unittest {
    // Gegenprobe zum stummen Ausstieg: OHNE vorangegangene Ausgabe und ohne
    // Klebrigkeit verhaelt sich dasselbe Zeichen wie bisher - die getippte
    // Sequenz wird ausgegeben.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSequence = "";
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x5E, 0x31], "hoch1"w, null), composeRoot);

    NeoKey wurzel; wurzel.keysym = 0x5E;
    wurzel.keytype = NeoKeyType.CHAR;
    wurzel.chars = "^"w;

    cast(void) compose(wurzel);
    auto aus = compose(wurzel);
    assert(aus.type == ComposeResultType.ABORT && aus.result == "^^"w,
        "ohne Klebrigkeit bleibt der Abbruch, wie er war");
}

unittest {
    // Doppelrolle zur Laufzeit (Spec 3.2): Der Knoten haelt sein Ergebnis
    // fest, bis die naechste Taste entscheidet - beide Ausgaenge.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSequence = "";
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    // K (0x4B) Wurzel und klebrig; K1 -> "eins", K10 -> "zehn", Ka -> "a-kreis".
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31], "eins"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31, 0x30], "zehn"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x61], "a-kreis"w, null), composeRoot);
    assert(markSticky([0x4Bu], composeRoot));

    NeoKey k;    k.keysym = 0x4B;
    NeoKey eins; eins.keysym = 0x31;
    NeoKey null_; null_.keysym = 0x30;
    NeoKey a;    a.keysym = 0x61;
    NeoKey punkt; punkt.keysym = 0x2E; punkt.keytype = NeoKeyType.CHAR; punkt.chars = "."w;

    // Ausgang 1: das Kind passt.
    cast(void) compose(k);
    auto halt = compose(eins);
    assert(halt.type == ComposeResultType.EAT && halt.result == ""w,
        "ein doppelrolliger Knoten gibt nicht sofort aus");
    auto zehn = compose(null_);
    assert(zehn.type == ComposeResultType.EMIT && zehn.result == "zehn"w);

    // Ausgang 2: das Kind passt nicht, die Taste wird am klebrigen Vorfahren
    // erneut geprueft und trifft dort ein Blatt - beide Ergebnisse in einem
    // Schub.
    // Vorher ausdruecklich auf Anfang: Nach Ausgang 1 laeuft der klebrige
    // Modus noch (der Ruecksprung haelt ihn am Leben), und ein erneutes k
    // waere dort der stumme Ausstieg aus Task 3, kein Neustart.
    active = false;
    currentSequence = "";
    currentKeysyms = [];
    cast(void) compose(k);
    cast(void) compose(eins);
    auto beides = compose(a);
    assert(beides.type == ComposeResultType.EMIT && beides.result == "einsa-kreis"w,
        "gehaltenes Ergebnis, dann das der erneut geprueften Taste");

    // Ausgang 3: die Taste passt auch am Vorfahren nicht - Ende, ihr Zeichen
    // wird angehaengt.
    active = false;
    currentSequence = "";
    currentKeysyms = [];
    cast(void) compose(k);
    cast(void) compose(eins);
    auto ende = compose(punkt);
    assert(ende.type == ComposeResultType.FINISH && ende.result == "eins."w,
        "FINISH, nicht EMIT - die Sequenz laeuft hier gerade NICHT weiter");
    assert(!composeActive());
}

unittest {
    // Der stumme Ausstieg gibt ein gehaltenes Ergebnis noch aus (Spec 4):
    // ⓧ 1 ⓧ liefert ① und beendet den Modus.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSequence = "";
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31], "eins"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31, 0x30], "zehn"w, null), composeRoot);
    assert(markSticky([0x4Bu], composeRoot));

    NeoKey k; k.keysym = 0x4B; k.keytype = NeoKeyType.CHAR; k.chars = "K"w;
    NeoKey eins; eins.keysym = 0x31;

    cast(void) compose(k);
    cast(void) compose(eins);
    auto aus = compose(k);
    assert(aus.type == ComposeResultType.FINISH && aus.result == "eins"w,
        "der Ausstieg verschluckt das gehaltene Ergebnis nicht");
    assert(!composeActive());
}

unittest {
    // Escape am haltenden Knoten verwirft das gehaltene Ergebnis - wie jeder
    // Escape-Abbruch, ohne Ausgabe (Spec 4, Weg 2).
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSequence = "";
        currentKeysyms = [];
    }
    import keysyms : initKeysyms;
    initKeysyms(".");

    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31], "eins"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31, 0x30], "zehn"w, null), composeRoot);
    assert(markSticky([0x4Bu], composeRoot));

    NeoKey k;    k.keysym = 0x4B;
    NeoKey eins; eins.keysym = 0x31;
    NeoKey esc;  esc.keysym = keysymsByName["Escape"];

    cast(void) compose(k);
    cast(void) compose(eins);
    auto r = compose(esc);
    assert(r.type == ComposeResultType.ABORT && r.result == ""w,
        "Escape verwirft auch ein gehaltenes Ergebnis");
    assert(!composeActive());
}

unittest {
    // Der Zweitkandidat gilt bei der erneuten Pruefung weiter (Spec 7).
    // Ohne ihn stuerbe der klebrige Modus unter jeder Rastung.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSequence = "";
        currentKeysyms = [];
    }
    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x61], "a-kreis"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x62], "b-kreis"w, null), composeRoot);
    assert(markSticky([0x4Bu], composeRoot));

    NeoKey k; k.keysym = 0x4B;
    NeoKey a; a.keysym = 0x61;
    NeoKey b; b.keysym = 0x62;
    NeoKey tot; tot.keysym = 0x9999;   // die gerastete Ebene traegt hier nichts

    cast(void) compose(k);
    auto erst = compose(a);
    assert(erst.type == ComposeResultType.EMIT && erst.result == "a-kreis"w);

    // Nach dem Ruecksprung: erster Kandidat tot, zweiter rettet.
    auto zweitTreffer = compose(tot, &b);
    assert(zweitTreffer.type == ComposeResultType.EMIT && zweitTreffer.result == "b-kreis"w,
        "der Zweitkandidat muss den Ruecksprung ueberleben");
}

unittest {
    // Fixrunde 1, Fix 1: Trifft die erneute Pruefung am klebrigen Vorfahren
    // ein Sondermodus-Blatt, muss der Sondermodus scharf werden - das
    // gehaltene Ergebnis wird trotzdem faellig. Beides zusammen gibt es nur
    // hier; der gewoehnliche Pfad hat nichts auszugeben und liefert EAT.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSpecialMode = null;
        currentSequence = "";
        currentKeysyms = [];
        unicodeInput = "";
    }
    import keysyms : initKeysyms;
    initKeysyms(".");
    KEYSYM_SPACE = parseKeysym("space");
    KEYSYM_0 = parseKeysym("0");
    KEYSYM_a = parseKeysym("a");
    KEYSYM_A = parseKeysym("A");

    composeRoot = ComposeNode();
    // K (0x4B) Wurzel und klebrig; K1 doppelrollig ("eins" plus Kind 0);
    // Ku startet die Unicode-Eingabe.
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31], "eins"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31, 0x30], "zehn"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x75], ""w, &composeUnicode), composeRoot);
    assert(markSticky([0x4Bu], composeRoot));

    NeoKey k;    k.keysym = 0x4B;
    NeoKey eins; eins.keysym = 0x31;
    NeoKey u;    u.keysym = 0x75;

    cast(void) compose(k);
    cast(void) compose(eins);
    auto faellig = compose(u);
    assert(faellig.type == ComposeResultType.EMIT && faellig.result == "eins"w,
        "das gehaltene Ergebnis kommt heraus");
    assert(composeSpecialActive(),
        "der Sondermodus wird nach der erneuten Pruefung scharf");

    // Und die naechsten Tasten gehen wirklich durch ihn: uu 41 ␣ -> "A".
    NeoKey vier; vier.keysym = KEYSYM_0 + 4;
    NeoKey ziff1; ziff1.keysym = KEYSYM_0 + 1;
    NeoKey leer;  leer.keysym = KEYSYM_SPACE;
    assert(compose(vier).type == ComposeResultType.EAT);
    assert(compose(ziff1).type == ComposeResultType.EAT);
    auto grossA = compose(leer);
    assert(grossA.type == ComposeResultType.FINISH && grossA.result == "A"w,
        "die folgenden Tasten laufen durch den Sondermodus");
    assert(!composeActive());
}

unittest {
    // Fixrunde 1, Fix 2: Landet die erneute Pruefung auf einem Zweigknoten,
    // muss sich die Taste in die vom Ruecksprung geleerte Abbruchkette
    // schreiben - sonst fehlt ihr Zeichen, wenn die Sequenz spaeter abbricht.
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSpecialMode = null;
        currentSequence = "";
        currentKeysyms = [];
    }
    import keysyms : initKeysyms;
    initKeysyms(".");

    composeRoot = ComposeNode();
    // K klebrig; K1 doppelrollig; K a b -> Ka ist ein Zweigknoten ohne
    // eigenes Ergebnis.
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31], "eins"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31, 0x30], "zehn"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x61, 0x62], "ab"w, null), composeRoot);
    assert(markSticky([0x4Bu], composeRoot));

    NeoKey k;    k.keysym = 0x4B;
    NeoKey eins; eins.keysym = 0x31;
    NeoKey a;    a.keysym = 0x61; a.keytype = NeoKeyType.CHAR; a.chars = "a"w;
    NeoKey q;    q.keysym = 0x71; q.keytype = NeoKeyType.CHAR; q.chars = "q"w;

    cast(void) compose(k);
    cast(void) compose(eins);
    auto faellig = compose(a);
    assert(faellig.type == ComposeResultType.EMIT && faellig.result == "eins"w,
        "das gehaltene Ergebnis kommt heraus, die Sequenz steht auf dem Zweigknoten");

    auto abbruch = compose(q);
    assert(abbruch.type == ComposeResultType.ABORT && abbruch.result == "aq"w,
        "die erneut gepruefte Taste steht mit in der Abbruchkette");
    assert(!composeActive());
}

unittest {
    // Fixrunde 2: Der Zweitkandidat ueberlebt die ERNEUTE PRUEFUNG (Spec 7,
    // composer.d um Zeile 1028) - nicht nur den Ruecksprung nach einem Blatt.
    // Dafuer braucht die Fixture einen doppelrolligen Knoten: K klebrig,
    // K1 doppelrollig ("eins" plus Kind 0), Kb -> "b-kreis". Nach `K 1`
    // haelt K1 sein Ergebnis; die tote Taste faellt am klebrigen K nur ueber
    // den Zweitkandidaten auf Kb. Ohne die Weitergabe von `zweit` an
    // sucheFortsetzung endete die Sequenz hier mit FINISH "eins".
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSequence = "";
        currentKeysyms = [];
    }
    import keysyms : initKeysyms;
    initKeysyms(".");

    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31], "eins"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31, 0x30], "zehn"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x62], "b-kreis"w, null), composeRoot);
    assert(markSticky([0x4Bu], composeRoot));

    NeoKey k;    k.keysym = 0x4B;
    NeoKey eins; eins.keysym = 0x31;
    NeoKey b;    b.keysym = 0x62;
    NeoKey tot;  tot.keysym = 0x9999;   // die gerastete Ebene traegt hier nichts

    cast(void) compose(k);
    auto halt = compose(eins);
    assert(halt.type == ComposeResultType.EAT && halt.result == ""w,
        "K1 haelt sein Ergebnis, bis die naechste Taste entscheidet");

    auto beides = compose(tot, &b);
    assert(beides.type == ComposeResultType.EMIT && beides.result == "einsb-kreis"w,
        "der Zweitkandidat muss die erneute Pruefung ueberleben");
    assert(composeActive(), "der klebrige Modus laeuft nach dem Blatt weiter");
}

unittest {
    // Fixrunde 2, zweite Haelfte: Landet die erneute Pruefung ueber den
    // Zweitkandidaten auf einem Zweigknoten, traegt die Abbruchkette das
    // Zeichen des ZWEITEN Kandidaten (zeichenVon(zweitGewaehlt),
    // composer.d um Zeile 1055) - nicht das des ersten. Erster und zweiter
    // Kandidat tragen hier verschiedene Zeichen, damit die Wahl unterscheidbar
    // ist; mit zeichenVon(gewaehlt) hiesse die Kette "tq" statt "aq".
    scope(exit) {
        composeRoot = ComposeNode();
        active = false;
        currentSequence = "";
        currentKeysyms = [];
    }
    import keysyms : initKeysyms;
    initKeysyms(".");

    composeRoot = ComposeNode();
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31], "eins"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31, 0x30], "zehn"w, null), composeRoot);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x61, 0x62], "ab"w, null), composeRoot);
    assert(markSticky([0x4Bu], composeRoot));

    NeoKey k;    k.keysym = 0x4B;
    NeoKey eins; eins.keysym = 0x31;
    NeoKey a;    a.keysym = 0x61; a.keytype = NeoKeyType.CHAR; a.chars = "a"w;
    NeoKey tot;  tot.keysym = 0x9999; tot.keytype = NeoKeyType.CHAR; tot.chars = "t"w;
    NeoKey q;    q.keysym = 0x71; q.keytype = NeoKeyType.CHAR; q.chars = "q"w;

    cast(void) compose(k);
    cast(void) compose(eins);
    auto faellig = compose(tot, &a);
    assert(faellig.type == ComposeResultType.EMIT && faellig.result == "eins"w,
        "das gehaltene Ergebnis kommt heraus, die Sequenz steht auf dem Zweigknoten");

    auto abbruch = compose(q);
    assert(abbruch.type == ComposeResultType.ABORT && abbruch.result == "aq"w,
        "die Abbruchkette traegt das Zeichen des Zweitkandidaten, der gewonnen hat");
    assert(!composeActive());
}
