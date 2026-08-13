module toolargs;

import std.array : split;
import std.conv : to;
import std.file : exists, readText;
import std.json : parseJSON;
import std.path : buildPath, extension;
import std.string : startsWith, toUpper;
import std.utf : toUTF32;

// Reine Argument- und Auswahllogik der Compose-Unterbefehle - keine
// Win32-, keine Cairo-Abhaengigkeit. Vorher in tool_main.d, das laut
// docs/superpowers/specs/2026-08-02-compose-werkzeug-design.md, §2 "nur
// Aufrufverteilung" sein soll und dessen dub-Konfiguration keinen
// unittest-Lauf kennt (source/tool_main.d ist in "unittest" ausgeschlossen).
// Hier ist alles unter Tests.

/// Gemeinsame Schalter aller compose-Unterbefehle.
struct ComposeArgs {
    string sub;
    string[] positional;
    string[] modules;    /// leer = Auswahl aus der Konfiguration
    string modulesRaw;   /// unzerlegte Angabe hinter --modules, fuer leseAuswahl
    string outFile;
    string htmlFile;
    string layout;       /// leer = keine Ebenen-Spalte (compose namespace)
    uint schwelle;       /// 0 = nicht angegeben, der Aufrufer setzt die Vorgabe
    bool alle;           /// compose spiegel: auch Reihen und Muster zeigen
}

ComposeArgs parseComposeArgs(string[] args) {
    ComposeArgs a;
    for (size_t i = 2; i < args.length; i++) {
        if (args[i] == "--modules" && i + 1 < args.length) {
            a.modulesRaw = args[++i];
            a.modules = a.modulesRaw.split(",");
        } else if (args[i] == "--layout" && i + 1 < args.length) {
            a.layout = args[++i];
        } else if (args[i] == "--out" && i + 1 < args.length) {
            a.outFile = args[++i];
        } else if (args[i] == "--html" && i + 1 < args.length) {
            a.htmlFile = args[++i];
        } else if (args[i] == "--schwelle" && i + 1 < args.length) {
            // to!uint wirft bei unlesbarem Wert - besser als stillschweigend
            // 0, was "nicht angegeben" bedeutet und die Vorgabe einsetzte.
            a.schwelle = to!uint(args[++i]);
        } else if (args[i] == "--alle") {
            // Der erste wertlose Schalter: kein "i + 1 < args.length", kein
            // ++i. Ohne diesen Zweig faende er sich als Positionsargument
            // wieder und bliebe wirkungslos.
            a.alle = true;
        } else if (a.sub.length == 0) {
            a.sub = args[i];
        } else {
            a.positional ~= args[i];
        }
    }
    return a;
}

/// Liest composeModules aus einer bereits aufgeloesten config.*.json-Datei.
/// Gemeinsamer Kern von leseComposeModules und leseAuswahl - die beiden hatten
/// zuvor je eine eigene Kopie dieser drei Zeilen (Deckungsfund aus der
/// Codereview zum Compose-Werkzeug).
private string[] composeModulesAusDatei(string pfad) {
    auto config = parseJSON(readText(pfad));
    string[] namen;
    foreach (eintrag; config["composeModules"].array) namen ~= eintrag.str;
    return namen;
}

/// composeModules aus der Nutzer-Konfiguration, ersatzweise aus der Vorgabe -
/// dieselbe Regel wie beim Belegungsblatt.
string[] leseComposeModules(string datenVerzeichnis) {
    auto pfad = buildPath(datenVerzeichnis, "config.json");
    if (!exists(pfad)) pfad = buildPath(datenVerzeichnis, "config.default.json");
    return composeModulesAusDatei(pfad);
}

/// Eine Auswahl ist entweder eine kommagetrennte Modulliste oder der Pfad zu
/// einer config.*.json, aus der composeModules gelesen wird.
///
/// Die Angabe wird zuerst gegen das Arbeitsverzeichnis geprueft, dann gegen
/// datenVerzeichnis - genau wie jede andere Datendatei des Werkzeugs relativ
/// zu executableDir gesucht wird (siehe CLAUDE.md, Abschnitt "Datendateien").
/// Traegt "angabe" die Endung .json, MUSS einer der beiden Orte treffen; sonst
/// wird laut geworfen, statt die Angabe stillschweigend als (dann leere)
/// Modulliste zu behandeln. Genau das war der Befund aus der Codereview: von
/// einem fremden Arbeitsverzeichnis aus lud "compose diff config.default.json
/// config.neo.json" nur die eingebauten Sonderroutinen und meldete "0
/// Unterschiede" - nicht unterscheidbar von einem echten Nullbefund.
string[] leseAuswahl(string datenVerzeichnis, string angabe) {
    if (angabe.extension == ".json") {
        auto pfad = angabe;
        if (!exists(pfad)) pfad = buildPath(datenVerzeichnis, angabe);
        if (!exists(pfad)) {
            throw new Exception("Auswahl '" ~ angabe ~ "' ist keine vorhandene .json-Datei "
                ~ "(weder im Arbeitsverzeichnis noch in '" ~ datenVerzeichnis ~ "').");
        }
        return composeModulesAusDatei(pfad);
    }

    return angabe.split(",");
}

/// "U+2200" oder das Zeichen selbst. Beides muss gehen: Ein Zeichen jenseits
/// der BMP laesst sich auf der Kommandozeile oft nicht eingeben.
dstring parseZeichen(string eingabe) {
    if (eingabe.toUpper.startsWith("U+")) {
        return [cast(dchar) to!uint(eingabe[2 .. $], 16)].idup;
    }
    return eingabe.toUTF32.idup;
}

version (unittest) {
    import std.exception : assertThrown, collectException;
    import std.file : mkdirRecurse, remove, rmdir, tempDir, write;
}

unittest {
    // parseComposeArgs trennt Schalter von Positionsargumenten. Der
    // Normalfall: Unterbefehl, zwei Positionsargumente, --out und --html.
    auto a = parseComposeArgs(["ananeo-tool", "compose", "diff", "a", "b",
                                "--out", "x.txt", "--html", "y.html"]);
    assert(a.sub == "diff");
    assert(a.positional == ["a", "b"]);
    assert(a.outFile == "x.txt");
    assert(a.htmlFile == "y.html");
    assert(a.modules == []);
}

unittest {
    // --modules mit Wert zerlegt an Kommata und merkt sich zusaetzlich die
    // unzerlegte Angabe (fuer leseAuswahl, das denselben String auch als
    // Dateipfad lesen koennen muss).
    auto a = parseComposeArgs(["ananeo-tool", "compose", "check", "datei.module",
                                "--modules", "base,math"]);
    assert(a.sub == "check");
    assert(a.positional == ["datei.module"]);
    assert(a.modules == ["base", "math"]);
    assert(a.modulesRaw == "base,math");
}

unittest {
    // Ein Schalter ohne folgenden Wert (z.B. das letzte Kommandozeilenwort)
    // erfuellt die Bedingung "i + 1 < args.length" nicht und faellt deshalb
    // durch auf den Positionsargument-Zweig - kein Absturz, kein
    // stillschweigendes Verschlucken.
    auto a = parseComposeArgs(["ananeo-tool", "compose", "origin", "--modules"]);
    assert(a.sub == "origin");
    assert(a.positional == ["--modules"]);
    assert(a.modules == []);
}

unittest {
    // --layout gehoert zu compose namespace: benannter Schalter statt
    // zweitem Positionsargument, weil "compose namespace AnNoted" sonst
    // nicht aufloesbar waere (Praefix oder Layout?).
    auto a = parseComposeArgs(["ananeo-tool", "compose", "namespace",
                                "Multi_key", "--layout", "AnNoted"]);
    assert(a.sub == "namespace");
    assert(a.positional == ["Multi_key"]);
    assert(a.layout == "AnNoted");

    // Ohne Wert faellt --layout wie die anderen Schalter auf den
    // Positionsargument-Zweig - kein Absturz, kein Verschlucken.
    auto b = parseComposeArgs(["ananeo-tool", "compose", "namespace", "--layout"]);
    assert(b.layout == "");
    assert(b.positional == ["--layout"]);
}

unittest {
    // Grossbuchstabe, Kleinbuchstabe im Praefix und ein Zeichen jenseits der
    // BMP - dstring statt string, sonst wuerde ein UTF-16-Surrogatpaar
    // hindurchrutschen.
    assert(parseZeichen("U+2200") == "∀"d);
    assert(parseZeichen("u+2200") == "∀"d, "Praefix ist nicht gross-/kleinschreibungsempfindlich");
    assert(parseZeichen("U+1FA00") == "\U0001FA00"d, "jenseits der BMP");
}

unittest {
    // Ein literales Zeichen statt einer U+-Angabe muss ebenso funktionieren -
    // auf der Kommandozeile laesst sich nicht jedes Zeichen als U+-Nummer
    // eingeben, aber das Zeichen selbst schon (Copy&Paste).
    assert(parseZeichen("∀") == "∀"d);
    assert(parseZeichen("æ") == "æ"d);
}

unittest {
    // Kaputte Hexziffern hinter "U+" muessen laut scheitern statt ein
    // falsches Zeichen zu liefern.
    assertThrown(parseZeichen("U+ZZZZ"));
}

unittest {
    // Kommagetrennte Modulliste - der haeufigste Fall, keine Datei beteiligt.
    assert(leseAuswahl(".", "base,math") == ["base", "math"]);
    assert(leseAuswahl(".", "base") == ["base"]);
}

unittest {
    // Eine .json-Datei, die relativ zum Arbeitsverzeichnis nicht existiert,
    // aber im datenVerzeichnis (wie das exe-Verzeichnis im echten Werkzeug)
    // liegt, muss trotzdem gefunden werden - das ist Important 1 der
    // Codereview: vorher wurde nur exists(angabe) relativ zum CWD geprueft.
    auto verzeichnis = buildPath(tempDir(), "ananeo-leseauswahl-test");
    mkdirRecurse(verzeichnis);
    scope(exit) {
        collectException(remove(buildPath(verzeichnis, "ananeo-test-config.json")));
        collectException(rmdir(verzeichnis));
    }

    write(buildPath(verzeichnis, "ananeo-test-config.json"),
        `{"composeModules": ["base", "diacritics"]}`);

    // Der Dateiname ist bewusst ungewoehnlich (Praefix "ananeo-test-"), damit
    // er garantiert nicht zufaellig im tatsaechlichen Arbeitsverzeichnis des
    // Testlaufs (Repo-Wurzel) existiert - sonst wuerde dieser Test den
    // CWD-Zweig treffen statt den datenVerzeichnis-Zweig, den er pruefen soll.
    assert(!exists("ananeo-test-config.json"),
        "Testannahme verletzt: die Datei darf nicht zufaellig im CWD liegen");

    auto auswahl = leseAuswahl(verzeichnis, "ananeo-test-config.json");
    assert(auswahl == ["base", "diacritics"]);
}

unittest {
    // Eine .json-Angabe, die weder im Arbeitsverzeichnis noch im
    // datenVerzeichnis existiert, muss laut scheitern - nicht stillschweigend
    // als (dann leere) Modulliste durchgehen. Das ist der zweite Teil von
    // Important 1: die eigentliche Reproduktion des "0 Unterschiede"-Befunds.
    auto verzeichnis = buildPath(tempDir(), "ananeo-leseauswahl-fehlt-test");
    mkdirRecurse(verzeichnis);
    scope(exit) collectException(rmdir(verzeichnis));

    auto fehler = collectException!Exception(
        leseAuswahl(verzeichnis, "gibt-es-nirgendwo.json"));
    assert(fehler !is null, "eine nirgendwo aufloesbare .json-Angabe muss werfen");
}

unittest {
    // leseComposeModules: config.json vor config.default.json, wie beim
    // Belegungsblatt.
    auto verzeichnis = buildPath(tempDir(), "ananeo-lesecomposemodules-test");
    mkdirRecurse(verzeichnis);
    scope(exit) {
        collectException(remove(buildPath(verzeichnis, "config.default.json")));
        collectException(rmdir(verzeichnis));
    }

    write(buildPath(verzeichnis, "config.default.json"),
        `{"composeModules": ["base", "en_US"]}`);

    assert(leseComposeModules(verzeichnis) == ["base", "en_US"]);
}

unittest {
    // --schwelle nimmt einen Wert, --alle nicht. --alle ist der erste
    // wertlose Schalter des Parsers: ohne eigenen Zweig fiele er in den
    // Positionsargument-Zweig und waere still wirkungslos.
    auto a = parseComposeArgs(["ananeo-tool", "compose", "spiegel",
                                "--layout", "AnNoted", "--schwelle", "12", "--alle"]);
    assert(a.sub == "spiegel");
    assert(a.layout == "AnNoted");
    assert(a.schwelle == 12);
    assert(a.alle);
    assert(a.positional == [], "--alle darf nicht als Positionsargument enden");
}

unittest {
    // Ohne die Schalter bleiben die Vorgaben stehen: schwelle 0 heisst
    // "nicht angegeben", der Aufrufer setzt dann SPIEGEL_SCHWELLE.
    auto a = parseComposeArgs(["ananeo-tool", "compose", "spiegel", "--layout", "AnNoted"]);
    assert(a.schwelle == 0);
    assert(!a.alle);
}

unittest {
    // --schwelle ohne Wert faellt wie die anderen wertnehmenden Schalter auf
    // den Positionsargument-Zweig; --schwelle mit unlesbarem Wert muss laut
    // scheitern statt stillschweigend 0 zu bedeuten.
    auto a = parseComposeArgs(["ananeo-tool", "compose", "spiegel", "--schwelle"]);
    assert(a.schwelle == 0);
    assert(a.positional == ["--schwelle"]);

    assertThrown(parseComposeArgs(["ananeo-tool", "compose", "spiegel",
                                    "--schwelle", "acht"]));
}
