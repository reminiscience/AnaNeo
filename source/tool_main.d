module tool_main;

import core.sys.windows.wincon : SetConsoleOutputCP;
import core.sys.windows.windef : UINT;

import std.algorithm : canFind;
import std.array : join;
import std.conv : to;
// Normaler statt selektiver Import: schreibeAus ruft std.file.write qualifiziert
// auf, um eine Verwechslung mit std.stdio.writeln auszuschliessen.
import std.file;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.stdio : stderr, writeln;
import std.string : toUpper;

import composeaudit;
import composer : composeRoot, composeUnknownModules;
import composereport;
import keyboardview : BoardLayout;
import keysyms : initKeysyms, parseKeysym;
import layerlock : LockTrigger, parseLockTriggers;
import mapping;
import sheet : renderSheet;
import toolargs;
import unicodedata : loadUnicodeData;

// main der dub-Konfiguration "tool". Bewusst ein eigenes Kompilat und nicht ein
// Schalter an ananeo.exe: Diese Binary linkt weder Cairo noch den Hook, laeuft
// als Konsolenprogramm und laesst sich in einem Skript benutzen.
//
// Die Konfiguration heisst "tool" und nicht "sheettool": Seit dem
// Compose-Werkzeug haengen mehrere Unterbefehle an diesem einen Kompilat.

enum CP_UTF8 = 65001;

int main(string[] args) {
    // Ohne CP_UTF8 zeigt die Konsole Sequenzen und Ergebniszeichen als Muell.
    // Beweiskraeftig ist trotzdem der HTML-Bericht (spaeteres Paket):
    // Konsolenfenster zeigen manche Zeichen grundsaetzlich nicht an.
    cast(void) SetConsoleOutputCP(cast(UINT) CP_UTF8);

    if (args.length >= 2 && args[1] == "sheet") return sheetBefehl(args);
    if (args.length >= 2 && args[1] == "compose") return composeBefehl(args);

    stderr.writeln("Aufruf: ananeo-tool <befehl> [...]");
    stderr.writeln("  sheet [Layoutname]        Belegungsblatt als HTML");
    stderr.writeln("  compose <unterbefehl>     Auskunft ueber den Compose-Bestand");
    stderr.writeln("    origin [modul]          Herkunft je Datei");
    stderr.writeln("    namespace [praefix...] [--layout <Name>]  Fortsetzungen unter einem Keysym-Praefix");
    stderr.writeln("    coverage                Abdeckung je Unicode-Block");
    stderr.writeln("    gaps <Blockname...>     Fehlende Zeichen eines Blocks");
    stderr.writeln("    find <Zeichen|U+XXXX>   Sequenzen, die ein Zeichen liefern");
    stderr.writeln("    check <datei.module>    Kandidatendatei gegen den Bestand pruefen");
    stderr.writeln("    diff <auswahl-a> <b>    Zwei Modulauswahlen gegeneinander");
    stderr.writeln("    layers [Layoutname]     Ebenen gegen den Compose-Bestand abgleichen");
    stderr.writeln("    spiegel --layout <Name> [--schwelle N] [--alle]");
    stderr.writeln("                            Doppelungen zwischen Ebenen und Compose-Bestand");
    stderr.writeln("    report                  Mehrere Abschnitte in einem Bericht");
    stderr.writeln("    gen-schrift             compose/ananeo-schrift.module aus der Rechnung erzeugen");
    stderr.writeln("    gen-kreis               compose/ananeo-kreis.module aus der Rechnung erzeugen");
    stderr.writeln("  Gemeinsame Schalter: --modules a,b,c   --out <datei>   --html <datei>");
    return 2;
}

int sheetBefehl(string[] args) {
    if (args.length < 2 || args[1] != "sheet") {
        stderr.writeln("Aufruf: ananeo-tool sheet [Layoutname]");
        stderr.writeln("  Erzeugt das Belegungsblatt als HTML im aktuellen Verzeichnis.");
        stderr.writeln("  Ohne Layoutnamen wird fuer jedes Layout eines erzeugt.");
        return 2;
    }

    // Datendateien liegen neben der EXE, nicht im Arbeitsverzeichnis -
    // dieselbe Regel wie in app.d.
    auto datenVerzeichnis = dirName(thisExePath());

    try {
        initKeysyms(datenVerzeichnis);
        auto layoutsJson = parseJSON(readText(buildPath(datenVerzeichnis, "layouts.json")));
        initLayouts(layoutsJson["layouts"]);

        // config.json ist die gewachsene Nutzerdatei, config.default.json die
        // Vorgabe. Fuer Ausloeser und Tastaturform zaehlt, was der Nutzer hat.
        auto configPfad = buildPath(datenVerzeichnis, "config.json");
        if (!exists(configPfad)) {
            configPfad = buildPath(datenVerzeichnis, "config.default.json");
        }
        auto config = parseJSON(readText(configPfad));

        LockTrigger[] trigger = parseLockTriggers(config["locks"]);
        auto oskJson = config["osk"];
        // "iso"/"ansi" stehen kleingeschrieben in der Vorgabe, die Schreibweise
        // ist aber nicht erzwungen - app.d liest sie ebenfalls ueber toUpper.
        auto brett = oskJson["layout"].str.toUpper == "ANSI" ? BoardLayout.ANSI : BoardLayout.ISO;
        bool zahlenreihe = oskJson["numberRow"].boolean;
        bool nummernblock = oskJson["numpad"].boolean;

        string gewuenscht = args.length > 2 ? args[2] : "";
        bool getroffen = false;

        foreach (ref layout; layouts) {
            auto name = layout.name.to!string;
            if (gewuenscht.length > 0 && name != gewuenscht) continue;
            getroffen = true;

            auto html = renderSheet(&layout, brett, zahlenreihe, nummernblock, trigger);
            auto ziel = "ananeo-belegung-" ~ name ~ ".html";
            write(ziel, html);
            writeln(ziel);
        }

        if (!getroffen) {
            stderr.writeln("Layout '", gewuenscht, "' steht nicht in layouts.json.");
            return 1;
        }
    } catch (Exception e) {
        stderr.writeln("Fehler: ", e.msg);
        return 1;
    }

    return 0;
}

/// Alle Unterbefehle, die compose kennt - vor jeder teuren Arbeit (Laden des
/// gesamten Bestands ueber collectAudit) geprueft, damit ein Tippfehler nicht
/// erst nach einer vollen Ladung mit einer leeren Namensangabe scheitert
/// (Codereview-Minor: "compose" ohne Unterbefehl lud frueher den ganzen
/// Bestand, bevor "Unbekannter Unterbefehl: " mit leerem Namen erschien).
static immutable string[] COMPOSE_UNTERBEFEHLE = [
    "origin", "namespace", "coverage", "gaps", "find", "check", "diff", "report", "layers",
    "spiegel", "gen-schrift", "gen-kreis"
];

/// Nach jedem Ladevorgang (collectAudit ruft intern initCompose) pruefen, ob
/// composeModules Namen ohne passende .module-Datei enthielt. Vorher landete
/// das nur im Debug-Log, das ein Release-Build des Werkzeugs gar nicht
/// schreibt - eine falsch geschriebene Modulauswahl blieb also unbemerkt bei
/// einer leeren Tabelle (Codereview, Important 2).
private int pruefeUnbekannteModule() {
    if (composeUnknownModules.length == 0) return 0;
    stderr.writeln("Unbekannte Module in der Auswahl: ", composeUnknownModules.join(", "));
    return 1;
}

int composeBefehl(string[] args) {
    auto a = parseComposeArgs(args);
    auto datenVerzeichnis = dirName(thisExePath());

    if (!COMPOSE_UNTERBEFEHLE.canFind(a.sub)) {
        if (a.sub.length > 0) {
            stderr.writeln("Unbekannter Unterbefehl: ", a.sub);
        } else {
            stderr.writeln("Kein Unterbefehl angegeben.");
        }
        stderr.writeln("Bekannte Unterbefehle: ", COMPOSE_UNTERBEFEHLE.join(", "));
        return 2;
    }

    try {
        // gen-schrift rechnet nur und schreibt - kein Compose-Baum, keine
        // Keysym-Tabellen. Deshalb vor jedem Ladeaufruf, sonst haengt der
        // Erzeuger an Daten, die er nicht braucht.
        if (a.sub == "gen-schrift") {
            import schriftvarianten : erzeugeSchriftModul;
            import std.file : write;

            auto ziel = a.outFile.length ? a.outFile
                : buildPath(datenVerzeichnis, "compose", "ananeo-schrift.module");
            write(ziel, erzeugeSchriftModul());
            stderr.writeln("geschrieben: ", ziel);
            return 0;
        }

        // gen-kreis: wie gen-schrift reine Rechnung plus Schreiben - kein
        // Compose-Baum, keine Keysym-Tabellen.
        if (a.sub == "gen-kreis") {
            import einkreisung : erzeugeKreisModul;
            import std.file : write;

            auto ziel = a.outFile.length ? a.outFile
                : buildPath(datenVerzeichnis, "compose", "ananeo-kreis.module");
            write(ziel, erzeugeKreisModul());
            stderr.writeln("geschrieben: ", ziel);
            return 0;
        }

        initKeysyms(datenVerzeichnis);

        // diff ist der einzige Unterbefehl, der zwei Auswahlen braucht - und
        // deshalb --modules nicht benutzt. Er muss vor dem gemeinsamen
        // collectAudit abgefangen werden: collectAudit baut composeRoot jedes
        // Mal neu auf, zwei Auswahlen liessen sich sonst nicht gleichzeitig
        // im Speicher halten (siehe leafMap in composeaudit.d).
        if (a.sub == "diff") {
            if (a.modules.length > 0) {
                stderr.writeln("compose diff erlaubt --modules nicht - beide Auswahlen kommen "
                    ~ "aus den Positionsargumenten <auswahl-a> und <auswahl-b>.");
                return 2;
            }
            if (a.positional.length != 2) {
                stderr.writeln("Aufruf: ananeo-tool compose diff <auswahl-a> <auswahl-b>");
                stderr.writeln("  Auswahl: Modulliste (base,math) oder Pfad zu einer config.*.json");
                return 2;
            }

            auto auswahlA = leseAuswahl(datenVerzeichnis, a.positional[0]);
            cast(void) collectAudit(datenVerzeichnis, auswahlA);
            if (auto fehler = pruefeUnbekannteModule()) return fehler;
            auto karteA = leafMap(&composeRoot);

            auto auswahlB = leseAuswahl(datenVerzeichnis, a.positional[1]);
            cast(void) collectAudit(datenVerzeichnis, auswahlB);
            if (auto fehler = pruefeUnbekannteModule()) return fehler;
            auto karteB = leafMap(&composeRoot);

            auto tabellenDiff = [diffTable(auditDiff(karteA, karteB),
                                           a.positional[0], a.positional[1])];
            schreibeAus(tabellenDiff, "Compose-Bericht", a.outFile, a.htmlFile);
            return 0;
        }

        auto auswahl = a.modules.length > 0
            ? leseAuswahl(datenVerzeichnis, a.modulesRaw)
            : leseComposeModules(datenVerzeichnis);

        auto daten = collectAudit(datenVerzeichnis, auswahl);
        if (auto fehler = pruefeUnbekannteModule()) return fehler;

        ReportTable[] tabellen;

        switch (a.sub) {
            case "origin":
                auto herkunft = auditOrigin(daten);
                tabellen = [
                    originTable(herkunft),
                    originCasesTable(herkunft),
                    deadRemovesTable(auditDeadRemoves(datenVerzeichnis, auswahl, daten)),
                    voidKeysymsTable(auditVoidKeysyms(daten))
                ];
                break;
            case "namespace":
                uint[] praefix;
                foreach (teil; a.positional) praefix ~= parseKeysym(teil);

                const(NeoLayout)* nsLayout = null;
                if (a.layout.length > 0) {
                    auto layoutsJsonNs = parseJSON(readText(buildPath(datenVerzeichnis, "layouts.json")));
                    initLayouts(layoutsJsonNs["layouts"]);
                    foreach (ref l; layouts) {
                        if (l.name.to!string == a.layout) { nsLayout = &l; break; }
                    }
                    if (nsLayout is null) {
                        stderr.writeln("Layout '", a.layout, "' steht nicht in layouts.json.");
                        return 1;
                    }
                }

                tabellen = [namespaceTable(auditNamespace(&composeRoot, praefix),
                                           a.positional.join(" "), nsLayout, a.layout)];
                break;
            case "coverage":
                auto ucd = loadUnicodeData(buildPath(datenVerzeichnis, "data"));
                auto erreichbar = reachableCodepoints(&composeRoot);
                tabellen = [coverageTable(auditCoverage(erreichbar, ucd))];
                break;
            case "gaps":
                if (a.positional.length == 0) {
                    stderr.writeln("Aufruf: ananeo-tool compose gaps <Blockname>");
                    return 2;
                }
                auto ucdG = loadUnicodeData(buildPath(datenVerzeichnis, "data"));
                auto erreichbarG = reachableCodepoints(&composeRoot);
                tabellen = [gapsTable(
                    auditGaps(erreichbarG, ucdG, a.positional.join(" ")), a.positional.join(" "))];
                break;
            case "find":
                if (a.positional.length == 0) {
                    stderr.writeln("Aufruf: ananeo-tool compose find <Zeichen|U+XXXX>");
                    return 2;
                }
                auto gesucht = parseZeichen(a.positional[0]);
                tabellen = [findTable(auditFind(daten, &composeRoot, gesucht),
                                      a.positional[0])];
                break;
            case "check":
                if (a.positional.length == 0) {
                    stderr.writeln("Aufruf: ananeo-tool compose check <datei.module>");
                    return 2;
                }
                tabellen = [checkTable(auditCheck(daten, &composeRoot, a.positional[0]),
                                       a.positional[0])];
                break;
            case "report":
                auto ucdR = loadUnicodeData(buildPath(datenVerzeichnis, "data"));
                auto erreichbarR = reachableCodepoints(&composeRoot);

                tabellen = [
                    originTable(auditOrigin(daten)),
                    deadRemovesTable(auditDeadRemoves(datenVerzeichnis, auswahl, daten)),
                    voidKeysymsTable(auditVoidKeysyms(daten)),
                    namespaceTable(auditNamespace(&composeRoot, [parseKeysym("Multi_key")]),
                                   "Multi_key"),
                    coverageTable(auditCoverage(erreichbarR, ucdR))
                ];
                break;
            case "layers":
                auto layoutsJson = parseJSON(readText(buildPath(datenVerzeichnis, "layouts.json")));
                initLayouts(layoutsJson["layouts"]);

                const gewuenscht = a.positional.length > 0 ? a.positional[0] : "AnNoted";
                NeoLayout* gefunden;
                foreach (ref l; layouts) {
                    if (l.name.to!string == gewuenscht) { gefunden = &l; break; }
                }
                if (gefunden is null) {
                    stderr.writeln("Layout '", gewuenscht, "' steht nicht in layouts.json.");
                    return 1;
                }

                auto erreichbarL = reachableCodepoints(&composeRoot);
                tabellen = [layersTable(auditLayers(erreichbarL, gefunden), gewuenscht,
                                        composeOnlyCount(erreichbarL, gefunden))];
                break;
            case "spiegel":
                auto layoutsJsonSp = parseJSON(readText(buildPath(datenVerzeichnis, "layouts.json")));
                initLayouts(layoutsJsonSp["layouts"]);

                // --layout ist hier Pflicht, anders als bei layers, wo es ein
                // Positionsargument mit Vorgabe AnNoted ist. spiegel erzeugt
                // eine Schnitt-Kandidatenliste, und die soll niemand
                // versehentlich fuer ein stillschweigend angenommenes Layout
                // erzeugen (Spec 5).
                if (a.layout.length == 0) {
                    stderr.writeln("compose spiegel braucht --layout <Name> - ",
                                   "eine Kandidatenliste fuer ein stillschweigend ",
                                   "angenommenes Layout waere gefaehrlich.");
                    return 2;
                }

                NeoLayout* fuerSpiegel;
                foreach (ref l; layouts) {
                    if (l.name.to!string == a.layout) { fuerSpiegel = &l; break; }
                }
                if (fuerSpiegel is null) {
                    stderr.writeln("Layout '", a.layout, "' steht nicht in layouts.json.");
                    return 1;
                }

                const schwelle = a.schwelle > 0 ? a.schwelle : SPIEGEL_SCHWELLE;
                tabellen = [spiegelTable(auditSpiegel(daten, &composeRoot, fuerSpiegel, schwelle),
                                         a.layout, a.alle)];
                break;
            default:
                // Unerreichbar: a.sub ist gegen COMPOSE_UNTERBEFEHLE geprueft,
                // bevor dieser Switch ueberhaupt erreicht wird. Ein
                // string-Switch verlangt trotzdem einen default-Zweig.
                assert(false, "unbekannter Unterbefehl haette schon oben abgefangen sein muessen");
        }

        schreibeAus(tabellen, "Compose-Bericht", a.outFile, a.htmlFile);
    } catch (Exception e) {
        stderr.writeln("Fehler: ", e.msg);
        return 1;
    }

    return 0;
}

void schreibeAus(const ReportTable[] tabellen, string titel, string outFile, string htmlFile) {
    if (htmlFile.length > 0) {
        std.file.write(htmlFile, renderHtml(titel, tabellen));
        writeln(htmlFile);
    }

    auto text = renderConsole(tabellen);
    if (outFile.length > 0) {
        std.file.write(outFile, text);
        writeln(outFile);
    } else if (htmlFile.length == 0) {
        writeln(text);
    }
}
