module composeview;

// Die Kreuzung aus Compose-Baumzustand und Layout: Was bietet der Baum an
// diesem Knoten an, und wo liegt es auf den Tasten der gezeigten Ebene?
// Reines Modul nach dem Muster von keyboardview.d - kein Win32, kein Cairo,
// kein globaler Zustand. Verbraucher sind osk.d (Overlay und Bilanzzeile)
// und composereport.d (Ebenen-Spalte von compose namespace).
//
// Spec: docs/superpowers/specs/2026-08-02-osk-vorschau-design.md

import composer : ComposeNode;
import keysyms : KEYSYM_VOID;
import mapping : MapEntry, NeoKey, NeoLayout, Scancode;

/// Was eine Taste waehrend einer laufenden Sequenz bedeutet.
enum ComposeKeyKind {
    RESULT,         /// Sequenz endet hier, die Taste liefert das Ergebnis
    BRANCH,         /// Sequenz geht hier weiter
    RESULT_BRANCH,  /// beides: der Knoten haelt ein Ergebnis UND geht weiter
    EXIT,           /// Taste verlaesst den klebrigen Modus stumm (gibt ein
                    /// gehaltenes Ergebnis noch aus, tippt sich nicht selbst)
    NONE            /// Taste bricht die Sequenz ab (nicht in ComposeOverlay.keys
                    /// gespeichert - Fehlen eines Eintrags heisst NONE)
}

struct ComposeKeyView {
    ComposeKeyKind kind;
    wstring result;   /// bei RESULT: das Ergebnis (mehrzeichig moeglich)
    uint leaves;      /// bei BRANCH: Blaetter hinter dieser Fortsetzung;
                      /// 0 bei einem Sondermodus-Einstieg (Unicode, Roemisch)
}

struct ComposeOverlay {
    ComposeKeyView[Scancode] keys;  /// nur belegte Tasten; fehlt = NONE
    uint total;         /// Fortsetzungen des Knotens
    uint here;          /// davon auf der gezeigten Ebene tippbar
    uint elsewhere;     /// davon nur auf anderen Ebenen
    uint unreachable;   /// davon auf keiner Ebene
}

/// Was osk.d im Kopfstreifen und auf den Tasten zeigt. Gebaut von app.d
/// (updateOSK), gezeichnet von osk.d - composeview rechnet nur das Overlay.
struct ComposeDisplay {
    wstring sequenz;    /// Werkzeugnotation bzw. Sondermodus-Puffer
    bool sonderModus;   /// true: kein Overlay, Tastenbild bleibt normal
    ComposeOverlay overlay;
}

/// Blaetter eines Teilbaums. Kein Drift-Risiko wie bei den Laderegeln:
/// Gezaehlt wird derselbe fertige Baum, den das laufende Programm benutzt.
/// Ein Anti-Drift-Test haelt die Zaehlung gegen auditNamespace.
uint zaehleBlaetter(const(ComposeNode)* knoten) nothrow {
    if (knoten is null) return 0;
    if (knoten.next.length == 0) return 1;
    // Ein doppelrolliger Knoten traegt selbst ein Ergebnis und zaehlt deshalb
    // mit - sonst faellt es aus der Bilanz und der Anti-Drift-Test gegen
    // auditNamespace schlaegt an (Spec 8).
    uint summe = knoten.result.length > 0 ? 1 : 0;
    foreach (kind; knoten.next) summe += zaehleBlaetter(kind);
    return summe;
}

/// Niedrigste Ebene, auf der das Layout dieses Keysym erzeugt, 0 wenn keine.
/// Vergleich ueber Keysym-WERTE, nie ueber Namen - dead_psili und
/// dead_abovecomma sind beide 0xfe64 (STATUS.md, Punkt 19: derselbe
/// Namensvergleich hat eine Zwischenmessung um 177 verfaelscht).
uint lowestLayerFor(const(NeoLayout)* layout, uint keysym) nothrow {
    if (layout is null || keysym == KEYSYM_VOID) return 0;
    foreach (ebene; 1 .. cast(uint) layout.layers.length + 1) {
        foreach (eintrag; layout.map.byValue) {
            if (eintrag.layers.length >= ebene
                && eintrag.layers[ebene - 1].keysym == keysym) {
                return ebene;
            }
        }
    }
    return 0;
}

/// Das erste Keysym des Pfades von der Wurzel zu diesem Knoten - das
/// Wurzelzeichen des Zweiges, ueber das der stumme Ausstieg laeuft.
/// KEYSYM_VOID, wenn der Knoten selbst die Wurzel ist: Ohne laufende Sequenz
/// gibt es nichts zu verlassen, und das Keysym der Wurzel taugt nicht.
///
/// Kein Nachbau von composer.currentKeysyms[0], sondern dieselbe Groesse auf
/// einem zweiten Weg: ruecksprung setzt currentKeysyms = pfadZu(n)
/// (composer.d:838), im gewoehnlichen Lauf waechst die Liste Taste fuer Taste
/// mit dem Pfad. Beide liefern per Konstruktion dasselbe erste Keysym.
private uint wurzelKeysymVon(const(ComposeNode)* knoten) nothrow {
    uint erstes = KEYSYM_VOID;
    auto n = knoten;
    while (n !is null && n.prev !is null) {
        erstes = n.keysym;
        n = n.prev;
    }
    return erstes;
}

/// Liegt dieser Knoten in einem klebrigen Zweig - er selbst oder ein Vorfahre?
/// Eigene Kopie, weil das Gegenstueck in composer.d private ist; drei Zeilen
/// Aufstieg ueber prev, kein Nachbau einer Regel.
private bool inKlebrigemZweig(const(ComposeNode)* knoten) nothrow {
    auto n = knoten;
    while (n !is null) {
        if (n.klebrig) return true;
        n = n.prev;
    }
    return false;
}

/// Klassifiziert eine einzelne Fortsetzung nach den drei Faellen RESULT/
/// RESULT_BRANCH/BRANCH samt result/leaves-Belegung. Gemeinsame Stelle fuer
/// den Primaerblock (Fortsetzungen des Knotens selbst) und den
/// Ancestor-Block (Fortsetzungen des klebrigen Vorfahren) - eine zweite,
/// abweichende Kopie hatte dort RESULT_BRANCH unterschlagen (Review-Fund
/// nach Task 5).
private ComposeKeyView klassifiziereFortsetzung(const(ComposeNode)* fortsetzung) nothrow {
    ComposeKeyView view;
    const bool hatErgebnis = fortsetzung.result.length > 0;
    if (fortsetzung.next.length == 0 && fortsetzung.specialMode is null) {
        view.kind = ComposeKeyKind.RESULT;
        view.result = fortsetzung.result;
    } else if (hatErgebnis && fortsetzung.specialMode is null) {
        // Doppelrolle: die Taste liefert ein Ergebnis UND geht weiter.
        view.kind = ComposeKeyKind.RESULT_BRANCH;
        view.result = fortsetzung.result;
        view.leaves = zaehleBlaetter(fortsetzung) - 1;  // ohne das eigene
    } else {
        view.kind = ComposeKeyKind.BRANCH;
        // Ein Sondermodus-Einstieg (Unicode-Eingabe, roemische Zahlen)
        // ist im Baum ein Blatt mit specialMode - dahinter liegt keine
        // zaehlbare Blattmenge, der Marker erscheint ohne Zahl.
        view.leaves = fortsetzung.specialMode !is null
            ? 0 : zaehleBlaetter(fortsetzung);
    }
    return view;
}

/// Das Overlay fuer einen Knoten: je Taste, was sie in der laufenden
/// Sequenz bedeutet, plus die Bilanz. Die Zuordnung folgt exakt der Regel
/// von composer.compose: Je Taste zaehlt das Keysym der ersten Ebene;
/// setzt es am Knoten nicht fort, das der Zweit-Ebene (Rastungs-Spec 2.2 -
/// die Gewinn-Reihenfolge rechnet der Aufrufer, ananeo.composeEbenenpaar).
/// Verglichen werden Keysym-WERTE, nie Namen (dead_psili == dead_abovecomma).
ComposeOverlay composeOverlay(const(ComposeNode)* knoten,
                              const(NeoLayout)* layout, uint ebene,
                              uint zweitEbene = 0) nothrow {
    ComposeOverlay overlay;
    if (knoten is null) return overlay;

    overlay.total = cast(uint) knoten.next.length;
    if (layout is null || ebene < 1) {
        overlay.unreachable = overlay.total;
        return overlay;
    }

    // Je Fortsetzung die Ansicht vorbereiten und sie ueber ihren
    // Keysym-Wert auffindbar machen. Kindknoten sind je Keysym eindeutig
    // (addComposeEntry fuehrt Duplikate zusammen).
    ComposeKeyView[] views;
    uint[] fortsetzungKeysyms;
    views.length = knoten.next.length;
    fortsetzungKeysyms.length = knoten.next.length;
    size_t[uint] indexByKeysym;
    foreach (i, fortsetzung; knoten.next) {
        fortsetzungKeysyms[i] = fortsetzung.keysym;
        views[i] = klassifiziereFortsetzung(fortsetzung);
        if (fortsetzung.keysym != KEYSYM_VOID) {
            indexByKeysym[fortsetzung.keysym] = i;
        }
    }

    // Haelt dieser Knoten ein Ergebnis fest, sind auch die Fortsetzungen
    // seines klebrigen Vorfahren erreichbar: die Taste gibt erst das
    // gehaltene Ergebnis aus und wird dort erneut geprueft (Spec 8).
    // Traegt dieselbe Taste an beiden Knoten etwas, gewinnt der naehere.
    if (knoten.result.length > 0) {
        const(ComposeNode)* ahn = knoten.prev;
        while (ahn !is null && !ahn.klebrig) ahn = ahn.prev;
        if (ahn !is null) {
            foreach (fortsetzung; ahn.next) {
                if (fortsetzung.keysym == KEYSYM_VOID) continue;
                if (fortsetzung.keysym in indexByKeysym) continue;
                auto sicht = klassifiziereFortsetzung(fortsetzung);
                indexByKeysym[fortsetzung.keysym] = views.length;
                views ~= sicht;
                fortsetzungKeysyms ~= fortsetzung.keysym;
            }
        }
    }

    // Tasten-Schleife: erste Ebene, dann Zweit-Ebene.
    bool[] erreicht;
    erreicht.length = views.length;
    foreach (scan, eintrag; layout.map) {
        size_t* treffer = null;
        if (eintrag.layers.length >= ebene) {
            treffer = eintrag.layers[ebene - 1].keysym in indexByKeysym;
        }
        if (treffer is null && zweitEbene >= 1
            && eintrag.layers.length >= zweitEbene) {
            treffer = eintrag.layers[zweitEbene - 1].keysym in indexByKeysym;
        }
        if (treffer !is null) {
            overlay.keys[scan] = views[*treffer];
            erreicht[*treffer] = true;
        }
    }

    overlay.total = cast(uint) views.length;
    foreach (i, keysym; fortsetzungKeysyms) {
        if (erreicht[i]) overlay.here++;
        else if (lowestLayerFor(layout, keysym) > 0) overlay.elsewhere++;
        else overlay.unreachable++;
    }

    // Der stumme Ausstieg (composer.d:1001-1017): In einem klebrigen Zweig
    // beendet das Wurzelzeichen der Sequenz den Modus, ohne sich selbst zu
    // tippen. Ohne diesen Fall waere die Taste NONE - leer, gestrichelt und
    // ununterscheidbar von jeder Taste, die wirklich abbricht.
    //
    // Drei Dinge stehen hier bewusst so:
    //   1. NACH der Bilanz, und nur nach overlay.keys. Der Ausstieg ist keine
    //      Fortsetzung des Knotens; zaehlte er mit, verschoebe er total und
    //      damit here/elsewhere/unreachable - die Invariante und der
    //      Anti-Drift-Test gegen auditNamespace fielen sofort.
    //   2. Nur wo noch kein Eintrag steht. Damit gewinnt eine gueltige
    //      Fortsetzung auf derselben Taste - dieselbe Vorrangregel wie in
    //      composer.d, wo !foundNext den Ausstieg hinter jede Fortsetzung
    //      stellt.
    //   3. Nur die erste Ebene, nicht die Zweit-Ebene. Im Abbruchzweig ist
    //      'gewaehlt' immer der Erstkandidat (composer.d:854 setzt ihn als
    //      Vorgabe und stellt nur bei einem Treffer um).
    const uint wurzelKeysym = wurzelKeysymVon(knoten);
    if (wurzelKeysym != KEYSYM_VOID && inKlebrigemZweig(knoten)) {
        foreach (scan, eintrag; layout.map) {
            if (scan in overlay.keys) continue;
            if (eintrag.layers.length < ebene) continue;
            if (eintrag.layers[ebene - 1].keysym != wurzelKeysym) continue;
            ComposeKeyView sicht;
            sicht.kind = ComposeKeyKind.EXIT;
            overlay.keys[scan] = sicht;
        }
    }

    return overlay;
}

version (unittest) {
    import composer : ComposeFileLine, ComposeResult, addComposeEntry;

    /// Die geladenen Compose-Module einer Konfiguration. Eigene Kopie, weil
    /// das Gegenstueck in composeaudit.d private in dessen unittest-Block
    /// steht - drei Zeilen JSON-Auslese, kein Nachbau von Laderegeln.
    private string[] composeModuleNamen(string configDatei) {
        import std.file : readText;
        import std.json : parseJSON;

        auto config = parseJSON(readText(configDatei));
        string[] namen;
        foreach (eintrag; config["composeModules"].array) namen ~= eintrag.str;
        return namen;
    }

    // Zwei Ebenen, drei Tasten: 0x10 traegt a/A, 0x11 traegt e/E,
    // 0x47 traegt auf beiden Ebenen dasselbe Keysym 0x37 ('7') - die
    // Numpad-Konstellation fuer den Doppeltasten-Test.
    private NeoLayout fixtureLayout() {
        NeoKey taste(uint keysym) {
            NeoKey k;
            k.keysym = keysym;
            return k;
        }

        NeoLayout l;
        l.layers.length = 2;
        l.map[Scancode(0x10, false)] = MapEntry([taste(0x61), taste(0x41)], false);
        l.map[Scancode(0x11, false)] = MapEntry([taste(0x65), taste(0x45)], false);
        l.map[Scancode(0x47, false)] = MapEntry([taste(0x37), taste(0x37)], false);
        // 0x12/0x13 tragen die Ziffern 1/0 - gebraucht von der
        // Doppelrollen-Fixture (RESULT_BRANCH).
        l.map[Scancode(0x12, false)] = MapEntry([taste(0x31), taste(0x31)], false);
        l.map[Scancode(0x13, false)] = MapEntry([taste(0x30), taste(0x30)], false);
        l.map[Scancode(0x14, false)] = MapEntry([taste(0x32), taste(0x32)], false);
        return l;
    }

    /// Sucht die Taste, die dieses Keysym auf der genannten Ebene traegt -
    /// das Gegenstueck zur Zuordnung, die composeOverlay intern macht, hier
    /// aber fuer die Testfixtures gebraucht.
    private Scancode scancodeFuerKeysym(const(NeoLayout)* layout, uint keysym,
                                         uint ebene) {
        foreach (scan, eintrag; layout.map) {
            if (eintrag.layers.length >= ebene
                && eintrag.layers[ebene - 1].keysym == keysym) {
                return scan;
            }
        }
        assert(false, "Keysym nicht im Fixture-Layout");
    }
}

unittest {
    // Die drei Tastenfaelle und die Bilanz-Invariante an einem Knoten mit
    // drei Fortsetzungen: e (Blatt, auf Ebene 1), A (Zweig, nur auf Ebene 2),
    // 0x9999 (auf keiner Ebene).
    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "æ"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x41, 0x65], "x"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x41, 0x45], "y"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x9999], "z"w, null), wurzel);

    auto layout = fixtureLayout();

    // Der Knoten nach getipptem 'a' ist das erste Kind der Wurzel.
    assert(wurzel.next.length == 1 && wurzel.next[0].keysym == 0x61);
    auto knoten = wurzel.next[0];

    auto overlay = composeOverlay(knoten, &layout, 1);
    assert(overlay.total == 3);
    assert(overlay.here == 1, "nur e liegt auf Ebene 1");
    assert(overlay.elsewhere == 1, "A liegt nur auf Ebene 2");
    assert(overlay.unreachable == 1, "0x9999 liegt auf keiner Ebene");
    assert(overlay.here + overlay.elsewhere + overlay.unreachable == overlay.total);

    assert(overlay.keys.length == 1);
    auto e = Scancode(0x11, false) in overlay.keys;
    assert(e !is null && e.kind == ComposeKeyKind.RESULT && e.result == "æ"w);

    // Auf Ebene 2 dreht sich das Bild: A wird als Zweig sichtbar, e nicht.
    auto oben = composeOverlay(knoten, &layout, 2);
    assert(oben.here == 1 && oben.elsewhere == 1 && oben.unreachable == 1);
    auto zweig = Scancode(0x10, false) in oben.keys;
    assert(zweig !is null && zweig.kind == ComposeKeyKind.BRANCH);
    assert(zweig.leaves == 2, "hinter A liegen zwei Blaetter");
}

unittest {
    // Zwei Tasten mit demselben Keysym auf der gezeigten Ebene (Zahlenreihe
    // gegen Nummernblock-Kopie): beide tragen die Fortsetzung, die Bilanz
    // zaehlt die Fortsetzung trotzdem nur einmal.
    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x37], "7!"w, null), wurzel);

    auto layout = fixtureLayout();
    layout.map[Scancode(0x08, false)] =
        MapEntry([NeoKey(0x37), NeoKey(0x37)], false);

    auto overlay = composeOverlay(wurzel.next[0], &layout, 1);
    assert(overlay.total == 1 && overlay.here == 1);
    assert(overlay.keys.length == 2, "beide Tasten tragen die Fortsetzung");
    assert(overlay.keys[Scancode(0x47, false)].result == "7!"w,
        "mehrzeichiges Ergebnis bleibt vollstaendig");
}

unittest {
    // Ein Ergebnis jenseits der BMP bleibt ein Surrogatpaar (zwei
    // UTF-16-Codeeinheiten), wird also nicht verkuerzt.
    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "\U0001D504"w, null), wurzel);

    auto layout = fixtureLayout();
    auto overlay = composeOverlay(wurzel.next[0], &layout, 1);
    auto view = overlay.keys[Scancode(0x11, false)];
    assert(view.result.length == 2, "Surrogatpaar hat zwei Codeeinheiten");
    assert(view.result == "\U0001D504"w);
}

unittest {
    // Randfaelle: kein Knoten, kein Layout, Ebene 0.
    auto layout = fixtureLayout();
    assert(composeOverlay(null, &layout, 1).total == 0);

    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "x"w, null), wurzel);
    auto ohneLayout = composeOverlay(wurzel.next[0], null, 1);
    assert(ohneLayout.total == 1 && ohneLayout.unreachable == 1);
    assert(ohneLayout.keys.length == 0);

    auto ebeneNull = composeOverlay(wurzel.next[0], &layout, 0);
    assert(ebeneNull.unreachable == 1, "Ebene 0 gibt es nicht");
}

unittest {
    // Zweit-Ebene (Rastungs-Spec 3): Eine Taste, deren Keysym auf der ersten
    // Ebene nicht fortsetzt, traegt die Fortsetzung ihrer Zweit-Ebene; die
    // Bilanz zaehlt sie als "hier", weil sie ohne Zustandswechsel tippbar ist.
    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "ae"w, null), wurzel);

    auto layout = fixtureLayout();
    // Erste Ebene 2 ("gerastet"), Zweit-Ebene 1: e liegt nur auf Ebene 1.
    auto overlay = composeOverlay(wurzel.next[0], &layout, 2, 1);
    assert(overlay.total == 1);
    assert(overlay.here == 1 && overlay.elsewhere == 0,
        "die Zweit-Ebenen-Fortsetzung zaehlt als hier");
    auto e = Scancode(0x11, false) in overlay.keys;
    assert(e !is null && e.kind == ComposeKeyKind.RESULT && e.result == "ae"w);
}

unittest {
    // Abschattung (Rastungs-Spec 4.1): Setzt das Keysym der ersten Ebene
    // selbst fort, kommt der Zweitversuch derselben Taste nicht zum Zug.
    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "klein"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x45], "gross"w, null), wurzel);

    auto layout = fixtureLayout();
    auto overlay = composeOverlay(wurzel.next[0], &layout, 2, 1);
    auto taste = Scancode(0x11, false) in overlay.keys;
    assert(taste !is null && taste.result == "gross"w,
        "die erste Ebene gewinnt auf der Taste");
    assert(overlay.here == 1 && overlay.elsewhere == 1,
        "die abgeschattete Fortsetzung bleibt anderswo");
    assert(overlay.here + overlay.elsewhere + overlay.unreachable == overlay.total);
}

unittest {
    // Ohne Rastung aendert sich nichts: Zweit-Ebene 0 und Zweit-Ebene ==
    // erste Ebene liefern das heutige Ergebnis - die Zusage, dass der
    // Bestand unberuehrt bleibt (Rastungs-Spec 6).
    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "x"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x9999], "y"w, null), wurzel);

    auto layout = fixtureLayout();
    auto alt = composeOverlay(wurzel.next[0], &layout, 1);
    foreach (variante; [composeOverlay(wurzel.next[0], &layout, 1, 0),
                        composeOverlay(wurzel.next[0], &layout, 1, 1)]) {
        assert(variante.total == alt.total && variante.here == alt.here
            && variante.elsewhere == alt.elsewhere
            && variante.unreachable == alt.unreachable);
        assert(variante.keys.length == alt.keys.length);
    }
}

unittest {
    // Ein Sondermodus-Einstieg ist BRANCH mit leaves 0 - dahinter liegt
    // keine zaehlbare Blattmenge.
    static ComposeResult dummy(const(NeoKey) nk, bool probe) nothrow {
        return ComposeResult.init;
    }

    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], ""w, &dummy), wurzel);

    auto layout = fixtureLayout();
    auto unter = composeOverlay(wurzel.next[0], &layout, 1);
    auto view = unter.keys[Scancode(0x11, false)];
    assert(view.kind == ComposeKeyKind.BRANCH && view.leaves == 0);
}

unittest {
    // lowestLayerFor: niedrigste Ebene gewinnt, VOID und unbekannt liefern 0.
    auto layout = fixtureLayout();
    assert(lowestLayerFor(&layout, 0x61) == 1);
    assert(lowestLayerFor(&layout, 0x41) == 2);
    assert(lowestLayerFor(&layout, 0x37) == 1);
    assert(lowestLayerFor(&layout, 0x9999) == 0);
    assert(lowestLayerFor(&layout, KEYSYM_VOID) == 0);
    assert(lowestLayerFor(null, 0x61) == 0);
}

version (unittest) {
    import std.conv : to;
    import std.file : readText;
    import std.json : parseJSON;
    import composeaudit : allLeaves, auditNamespace, collectAudit;
    import composer : composeRoot, composeSequenceString;
    import keysyms : initKeysyms, parseKeysym;
    import mapping : initLayouts, layouts, resetLayoutsForTest;
}

unittest {
    // Regression gegen den Namensvergleich: dead_psili und dead_abovecomma
    // sind beide 0xfe64. Eine Fortsetzung unter dem einen Namen muss die
    // Taste treffen, deren Layout-Keysym unter dem anderen Namen geparst
    // wurde - genau der Vergleich, der in der Ausduennungsrunde eine
    // Zwischenmessung um 177 verfaelscht hat (STATUS.md, Punkt 19).
    initKeysyms(".");
    assert(parseKeysym("dead_psili") == parseKeysym("dead_abovecomma"),
        "Testannahme: beide Namen liegen auf demselben Keysym-Wert");

    ComposeNode wurzel;
    cast(void) addComposeEntry(
        ComposeFileLine([0x61, parseKeysym("dead_psili")], "x"w, null), wurzel);

    NeoLayout layout;
    layout.layers.length = 1;
    NeoKey k;
    k.keysym = parseKeysym("dead_abovecomma");
    layout.map[Scancode(0x2B, false)] = MapEntry([k], false);

    auto overlay = composeOverlay(wurzel.next[0], &layout, 1);
    assert(overlay.here == 1, "Wertevergleich muss die Taste treffen");
    assert(Scancode(0x2B, false) in overlay.keys);
}

unittest {
    // Anti-Drift: zaehleBlaetter und auditNamespace zaehlen denselben Baum -
    // laufen die beiden auseinander, zeigen Vorschau und Werkzeug
    // verschiedene Zahlen fuer denselben Zweig.
    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x62, 0x63], "x"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x62, 0x64], "y"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "z"w, null), wurzel);

    auto karte = auditNamespace(&wurzel, [0x61u]);
    // Verglichen wird bewusst die SUMME, nicht je Eintrag: Die Zuordnung
    // einzelner Eintraege zu Kindknoten liefe ueber den Anzeige-Praefix
    // und waere damit ein zweiter Namensvergleich.
    uint auditSumme = 0;
    foreach (eintrag; karte) auditSumme += eintrag.leaves;
    assert(auditSumme == zaehleBlaetter(wurzel.next[0]),
        "Blattzahl von composeview und composeaudit muss uebereinstimmen");
    assert(auditSumme == 3);
}

unittest {
    // Doppelrollige Knoten in der Vorschau: sie zaehlen als Blatt mit, ihre
    // Taste ist RESULT_BRANCH, und am haltenden Knoten sind die
    // Fortsetzungen des klebrigen Vorfahren auch erreichbar (Spec 8).
    import composer : ComposeFileLine, ComposeNode, addComposeEntry, markSticky;

    ComposeNode wurzel;
    // K klebrig; K1 -> "eins" mit Kind 0 -> "zehn"; Ka -> "a-kreis".
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31], "eins"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31, 0x30], "zehn"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x61], "a-kreis"w, null), wurzel);
    assert(markSticky([0x4Bu], wurzel));

    auto kKnoten = wurzel.next[0];
    auto einsKnoten = kKnoten.next[0];

    // Blattzahl: der doppelrollige Knoten traegt selbst ein Ergebnis.
    assert(zaehleBlaetter(einsKnoten) == 2,
        "das gehaltene Ergebnis und das Kind - nicht nur das Kind");
    assert(zaehleBlaetter(kKnoten) == 3);

    // Tastenart am Knoten K: die 1 ist beides.
    auto layout = fixtureLayout();
    auto overlay = composeOverlay(kKnoten, &layout, 1);
    auto blick = overlay.keys[scancodeFuerKeysym(&layout, 0x31, 1)];
    assert(blick.kind == ComposeKeyKind.RESULT_BRANCH);
    assert(blick.result == "eins"w);
    assert(blick.leaves == 1, "ein Kind hinter der 1");

    // Am haltenden Knoten kommen die Fortsetzungen des klebrigen Vorfahren
    // dazu - K1a gibt "einsa-kreis", die Taste ist also nicht tot.
    auto amHalt = composeOverlay(einsKnoten, &layout, 1);
    assert(scancodeFuerKeysym(&layout, 0x61, 1) in amHalt.keys,
        "die Fortsetzung des klebrigen Vorfahren muss erscheinen");
    assert(amHalt.keys[scancodeFuerKeysym(&layout, 0x30, 1)].kind == ComposeKeyKind.RESULT,
        "das eigene Kind bleibt, und es gewinnt bei gleicher Taste");
}

unittest {
    // Review-Fund: der Ancestor-Fortsetzungsblock kannte bisher nur
    // RESULT/BRANCH und unterschlug RESULT_BRANCH bei einer doppelrolligen
    // Vorfahren-Fortsetzung - latent im heutigen Bestand (null doppelrollige
    // Knoten), real erst mit Task 7 (Einkreisung).
    import composer : ComposeFileLine, ComposeNode, addComposeEntry, markSticky;

    ComposeNode wurzel;
    // K klebrig; K1 doppelrollig ("eins" + Kind 0 -> "zehn");
    // K2 ebenfalls doppelrollig ("zwei" + Kind 0 -> "zwanzig").
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31], "eins"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x31, 0x30], "zehn"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x32], "zwei"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x4B, 0x32, 0x30], "zwanzig"w, null), wurzel);
    assert(markSticky([0x4Bu], wurzel));

    auto kKnoten = wurzel.next[0];
    auto einsKnoten = kKnoten.next[0];  // haelt "eins"

    // Am K1-Knoten ist K2 als Fortsetzung des klebrigen Vorfahren erreichbar,
    // und die 2 ist selbst doppelrollig - muss also RESULT_BRANCH bleiben,
    // nicht auf BRANCH ohne result herabfallen.
    auto layout = fixtureLayout();
    auto amHalt = composeOverlay(einsKnoten, &layout, 1);
    auto zweiScan = scancodeFuerKeysym(&layout, 0x32, 1);
    assert(zweiScan in amHalt.keys, "die 2 muss als Fortsetzung des Vorfahren erscheinen");
    auto blick = amHalt.keys[zweiScan];
    assert(blick.kind == ComposeKeyKind.RESULT_BRANCH,
        "eine doppelrollige Vorfahren-Fortsetzung bleibt RESULT_BRANCH");
    assert(blick.result == "zwei"w, "das Ergebnis darf nicht verlorengehen");
    assert(blick.leaves == 1, "ein Kind hinter der 2, wie im Primaerblock gerechnet");
}

unittest {
    // Der Tastenfall EXIT: der stumme Ausstieg wird sichtbar. Fixture nach
    // dem Muster der Doppelrollen-Tests, aber mit einem Wurzel-Keysym, das
    // im Fixture-Layout auch eine Taste hat (a auf 0x10) - 0x4B haette
    // keine, und der Ausstieg waere nicht auffindbar.
    import composer : ComposeFileLine, ComposeNode, addComposeEntry, markSticky;

    ComposeNode wurzel;
    // a klebrig; a1 -> "eins" mit Kind 0 -> "zehn"; ae -> "a-e".
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x31], "eins"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x31, 0x30], "zehn"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "a-e"w, null), wurzel);
    assert(markSticky([0x61u], wurzel));

    auto aKnoten = wurzel.next[0];
    auto einsKnoten = aKnoten.next[0];  // haelt "eins"

    auto layout = fixtureLayout();
    auto amHalt = composeOverlay(einsKnoten, &layout, 1);

    // Die Taste mit dem Wurzel-Keysym steigt aus - sie ist keine
    // Fortsetzung und war deshalb bisher NONE.
    auto ausstiegScan = scancodeFuerKeysym(&layout, 0x61, 1);
    assert(ausstiegScan in amHalt.keys, "die Ausstiegstaste darf nicht NONE bleiben");
    assert(amHalt.keys[ausstiegScan].kind == ComposeKeyKind.EXIT);

    // Und die Bilanz bleibt unberuehrt: EXIT ist keine Fortsetzung. Drei
    // Fortsetzungen (eigenes Kind 0, dazu 1 und e vom klebrigen Vorfahren),
    // alle drei auf Ebene 1 - aber vier belegte Tasten.
    assert(amHalt.total == 3, "der Ausstieg zaehlt nicht als Fortsetzung");
    assert(amHalt.here == 3 && amHalt.elsewhere == 0 && amHalt.unreachable == 0);
    assert(amHalt.here + amHalt.elsewhere + amHalt.unreachable == amHalt.total);
    assert(amHalt.keys.length == 4, "drei Fortsetzungen plus der Ausstieg");
}

unittest {
    // Gegenprobe: ohne Klebrigkeit gibt es keinen Ausstieg. Derselbe Baum,
    // nur ohne markSticky - die Taste mit dem Wurzel-Keysym bleibt NONE.
    import composer : ComposeFileLine, ComposeNode, addComposeEntry;

    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x31], "eins"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x31, 0x30], "zehn"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x65], "a-e"w, null), wurzel);

    auto einsKnoten = wurzel.next[0].next[0];

    auto layout = fixtureLayout();
    auto amHalt = composeOverlay(einsKnoten, &layout, 1);
    assert(scancodeFuerKeysym(&layout, 0x61, 1) !in amHalt.keys,
        "ohne klebrigen Zweig gibt es nichts zu verlassen");
}

unittest {
    // Vorrang: traegt die Taste mit dem Wurzel-Keysym zugleich eine gueltige
    // Fortsetzung, gewinnt die Fortsetzung. Das ist dieselbe Reihenfolge wie
    // in composer.d, wo Bedingung !foundNext den Ausstieg hinter jede
    // Fortsetzung stellt.
    import composer : ComposeFileLine, ComposeNode, addComposeEntry, markSticky;

    ComposeNode wurzel;
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x31], "eins"w, null), wurzel);
    cast(void) addComposeEntry(ComposeFileLine([0x61, 0x61], "aa"w, null), wurzel);
    assert(markSticky([0x61u], wurzel));

    auto aKnoten = wurzel.next[0];

    auto layout = fixtureLayout();
    auto overlay = composeOverlay(aKnoten, &layout, 1);
    auto scan = scancodeFuerKeysym(&layout, 0x61, 1);
    assert(scan in overlay.keys);
    assert(overlay.keys[scan].kind == ComposeKeyKind.RESULT,
        "die Fortsetzung gewinnt gegen den Ausstieg");
    assert(overlay.keys[scan].result == "aa"w);
    assert(overlay.here + overlay.elsewhere + overlay.unreachable == overlay.total);
}

unittest {
    // Waechter 7: das Wurzel-Keysym eines klebrigen Zweigs kommt in diesem
    // Zweig nirgends als Fortsetzung vor.
    //
    // Er friert eine bewusste Vereinfachung ein. Die EXIT-Vergabe ueberspringt
    // jede Taste, die schon einen Eintrag hat - auch einen, der vom klebrigen
    // VORFAHREN stammt. composer.d prueft !foundNext dagegen nur gegen die
    // Kinder des AKTUELLEN Knotens und steigt aus, bevor der Halte-Zweig die
    // Taste am Vorfahren erneut prueft (die Fallreihenfolge in
    // composer.d:988-1030 ist belegt und darf nicht umgestellt werden).
    //
    // Traegt also ein klebriger Knoten sein eigenes Wurzel-Keysym als Kind,
    // zeigt die Vorschau an einem haltenden Nachfahren dessen Ergebnis,
    // waehrend composer stumm aussteigt - und die Bilanz zaehlte diese Taste
    // als "hier", obwohl sie dort nie ankommt. Heute latent, weil kein
    // ausgeliefertes Wurzelzeichen in seinem eigenen Zweig fortsetzt; derselbe
    // Fall wie beim RESULT_BRANCH-Fund im Ancestor-Block. Wird dieser Waechter
    // rot, ist die Vereinfachung real geworden und die Vergabe muss den
    // Ancestor-Block ausnehmen - samt der Frage, was das fuer die Bilanz heisst.
    //
    // Spec: docs/superpowers/specs/2026-08-08-osk-ausstieg-marker-design.md
    initKeysyms(".");
    cast(void) collectAudit(".", composeModuleNamen("config.default.json"));

    uint klebrigeGefunden = 0;

    void pruefeZweig(const(ComposeNode)* knoten, uint wurzelKeysym) {
        foreach (kind; knoten.next) {
            assert(kind.keysym != wurzelKeysym,
                "das Wurzel-Keysym eines klebrigen Zweigs setzt darin fort - "
                ~ "die EXIT-Vereinfachung traegt nicht mehr");
            pruefeZweig(kind, wurzelKeysym);
        }
    }

    void suche(const(ComposeNode)* knoten) {
        foreach (kind; knoten.next) {
            if (kind.klebrig) {
                klebrigeGefunden++;
                pruefeZweig(kind, wurzelKeysymVon(kind));
            }
            suche(kind);
        }
    }

    suche(&composeRoot);
    assert(klebrigeGefunden == 24,
        "24 klebrige Knoten wie in Waechter 9 - sonst prueft dieser Waechter "
        ~ "einen anderen Bestand als gemeint");
}

unittest {
    // Waechter gegen den ausgelieferten Bestand: <Multi_key> a + e liefert
    // auf AnNoted Ebene 1 ein RESULT ae - die Sequenz, die seit der
    // Erstinbetriebnahme als Eingabeprobe dient (STATUS.md).
    initKeysyms(".");
    cast(void) collectAudit(".", composeModuleNamen("config.default.json"));

    initLayouts(parseJSON(readText("layouts.json"))["layouts"]);
    scope(exit) resetLayoutsForTest();

    NeoLayout* annoted;
    foreach (ref l; layouts) {
        if (l.name.to!string == "AnNoted") { annoted = &l; break; }
    }
    assert(annoted !is null);

    const(ComposeNode)* knoten = null;
    foreach (kind; composeRoot.next) {
        if (kind.keysym == parseKeysym("Multi_key")) { knoten = kind; break; }
    }
    assert(knoten !is null, "Multi_key steht an der Wurzel");
    const(ComposeNode)* nachA = null;
    foreach (kind; knoten.next) {
        if (kind.keysym == 0x61) { nachA = kind; break; }
    }
    assert(nachA !is null, "a ist Fortsetzung unter Multi_key");

    auto overlay = composeOverlay(nachA, annoted, 1);
    assert(overlay.here + overlay.elsewhere + overlay.unreachable == overlay.total);

    auto e = Scancode(0x21, false) in overlay.keys;
    assert(e !is null, "Grundstellung e (Taste 21) traegt die Fortsetzung");
    assert(e.kind == ComposeKeyKind.RESULT);
    assert(e.result == "æ"w, "Multi_key a e ist ae");
}

unittest {
    // Waechter 6: genau das, was die Schnittrunde herstellt - und nicht
    // mehr. Zwei Zusicherungen gegen den ausgelieferten Bestand:
    //   1. Jedes Startzeichen des Baums liegt auf einer Ebene von AnNoted.
    //   2. Keines der 17 geschnittenen Keysyms kommt in irgendeiner
    //      geladenen Sequenz noch vor.
    // Die weitergehende Regel "jede Sequenz ist vollstaendig tippbar" gilt
    // ausdruecklich NICHT: Am 05.08.2026 gemessen sind 2 361 der 8 600
    // Blaetter untippbar, aus 295 verschiedenen Gruenden - vorkomponierte
    // Buchstaben als Zwischentaste, Zweitschreibweisen wie <acute> neben
    // <dead_acute>, und anderes (Spec 2026-08-05, Abschnitt 1.2).
    initKeysyms(".");
    cast(void) collectAudit(".", composeModuleNamen("config.default.json"));

    initLayouts(parseJSON(readText("layouts.json"))["layouts"]);
    scope(exit) resetLayoutsForTest();

    NeoLayout* annoted;
    foreach (ref l; layouts) {
        if (l.name.to!string == "AnNoted") { annoted = &l; break; }
    }
    assert(annoted !is null, "Layout AnNoted fehlt in layouts.json");

    // lowestLayerFor laeuft ueber alle 21 Ebenen mal alle Karteneintraege.
    // Je Keysym einmal rechnen genuegt, sonst kostet der Waechter Laufzeit
    // ohne Gegenwert.
    uint[uint] ebeneVon;
    uint ebene(uint keysym) {
        if (auto p = keysym in ebeneVon) return *p;
        auto e = lowestLayerFor(annoted, keysym);
        ebeneVon[keysym] = e;
        return e;
    }

    // Zusicherung 1: kein Startzeichen ohne Ebene. Das ist die Regel, die
    // diese Runde einfuehrt - wer einen Compose-Zweig hinzufuegt, muss ihm
    // eine Taste geben.
    string ohneEbene;
    foreach (kind; composeRoot.next) {
        if (ebene(kind.keysym) == 0) {
            ohneEbene ~= " " ~ composeSequenceString([kind.keysym]);
        }
    }
    assert(ohneEbene.length == 0,
        "Startzeichen des Compose-Baums ohne Ebene in AnNoted:" ~ ohneEbene);

    // Zusicherung 2: die 17 geschnittenen Keysyms kommen nirgends mehr vor,
    // auch nicht mitten in einer Sequenz, die erreichbar beginnt. Ohne
    // diese Zusicherung bliebe der Schnitt der 65 Zeilen ungesichert, die
    // mit einem erreichbaren Startzeichen anfangen. Die Liste haelt eine
    // Entscheidung fest, keinen Messwert - wie das namentliche Verbot von
    // U+00AA und U+00BA in Waechter 5.
    bool[uint] geschnitten;
    foreach (name; ["dead_iota", "dead_hook", "dead_greek", "dead_horn",
                    "dead_currency", "dead_doublegrave", "dead_invertedbreve",
                    "dead_ogonek", "dead_belowmacron", "dead_belowcircumflex",
                    "dead_belowtilde", "dead_belowcomma", "dead_belowring",
                    "dead_belowdiaeresis", "dead_belowbreve",
                    "Greek_accentdieresis"]) {
        auto k = parseKeysym(name);
        // parseKeysym liefert bei unbekanntem Namen KEYSYM_VOID statt zu
        // werfen. Ohne diese Zusicherung landete VOID in der Menge, und der
        // Waechter schluege bei jedem Blatt mit einer leeren Zelle an.
        assert(k != KEYSYM_VOID, "Testannahme: Keysym-Name unbekannt: " ~ name);
        geschnitten[k] = true;
    }
    geschnitten[0x10002F5] = true;   // ˵ U+02F5, in den Modulen als <U02F5>
    geschnitten[0x1000385] = true;   // ΅ U+0385 in der Offset-Form

    size_t treffer;
    string beispiel;
    foreach (blatt; allLeaves(&composeRoot)) {
        foreach (ks; blatt.keysyms) {
            if (ks !in geschnitten) continue;
            treffer++;
            if (beispiel.length == 0) {
                beispiel = composeSequenceString(blatt.keysyms);
            }
            break;
        }
    }
    assert(treffer == 0,
        "In der Schnittrunde entfernte Keysyms sind wieder im Baum: "
        ~ treffer.to!string ~ " Blaetter, zum Beispiel " ~ beispiel);
}
