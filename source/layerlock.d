module layerlock;

import std.conv : to;
import std.json : JSONValue;
import std.string : split, strip, toUpper;

import mapping : Modifier, PartialModifierState, VKEY, parseModifier;

/// Alle Neo-eigenen Modifier in generischer Form. Mod3 und Mod4 haben eine
/// linke und eine rechte Variante, Mod5 aufwaerts nicht.
immutable Modifier[] NEO_MODIFIERS = [
    Modifier.MOD3, Modifier.MOD4, Modifier.MOD5,
    Modifier.MOD6, Modifier.MOD7, Modifier.MOD8, Modifier.MOD9
];

/// Linke und rechte Variante eines Modifiers auf denselben Wert abbilden.
/// Die Enumwerte sind so gewaehlt, dass die linke Variante gerade ist und die
/// rechte genau eins darueber liegt.
Modifier genericModifier(Modifier mod) pure nothrow @nogc {
    return cast(Modifier) (mod & 0xFFFE);
}

/// Neo-eigene Modifier (Mod3 aufwaerts) haben Werte ab 0x100 und werden vor
/// Programmen versteckt, native Modifier darunter nicht.
bool isNeoModifier(Modifier mod) pure nothrow @nogc {
    return mod >= 0x100;
}

/// Enthaelt der Satz diesen Modifier (unabhaengig von links/rechts)?
bool containsModifier(const(Modifier)[] satz, Modifier mod) pure nothrow @nogc {
    auto gesucht = genericModifier(mod);
    foreach (m; satz) {
        if (genericModifier(m) == gesucht) return true;
    }
    return false;
}

/// Effektiver Zustand eines Modifiers aus physisch gehalten und gerastet.
/// Ohne Passthrough gilt XOR: ein gerasteter Modifier laesst sich durch
/// Halten der Taste kurzzeitig aufheben. Mit Passthrough - also wenn
/// Programme die Neo-Modifier selbst sehen und der native Treiber die Ebene
/// mitschaltet - gilt ODER, weil das echte Tastenevent sonst dagegenarbeitet.
bool modifierActive(bool held, bool locked, bool passThrough) pure nothrow @nogc {
    return passThrough ? (held || locked) : (held != locked);
}

/// Der gerastete Modifier-Satz samt Anzeigename.
struct LockState {
    const(Modifier)[] set;
    string name;

    bool empty() const pure nothrow @nogc {
        return set.length == 0;
    }

    bool isLocked(Modifier mod) const pure nothrow @nogc {
        return containsModifier(set, mod);
    }

    bool sameSetAs(const(Modifier)[] anderer) const pure nothrow @nogc {
        if (set.length != anderer.length) return false;
        foreach (m; anderer) {
            if (!containsModifier(set, m)) return false;
        }
        return true;
    }
}

/// Aktuelle Ebene bestimmen. Die Eintraege in "layers" werden der Reihe nach
/// getestet, der erste passende gewinnt - die Reihenfolge im Layout ist also
/// signifikant. Rueckgabe ist 1-basiert, Rueckfallwert ist Ebene 1.
///
/// "isHeld" bekommt stets einen generischen Modifier und muss beide Varianten
/// pruefen. "flipShift" dreht den Shift-Zustand um und dient der
/// Capslock-Vertauschung.
///
/// Gerastetes Shift folgt der ODER-Semantik (siehe modifierActive): Das
/// physische Shift bleibt fuer Programme sichtbar, dagegen kann XOR nicht
/// arbeiten - Halten hebt eine Shift-Rastung also nicht auf.
///
/// "rueckfall" meldet, wenn kein Eintrag passte und der Vorgabewert 1
/// zurueckgeht.
uint determineLayer(PartialModifierState[] layers,
                    scope bool delegate(Modifier) nothrow isHeld,
                    const(Modifier)[] lockedSet,
                    bool neoModifiersPassThrough,
                    bool flipShift,
                    const(bool)[] ignoresLocks = [],
                    bool* rueckfall = null) nothrow {
    if (rueckfall !is null) *rueckfall = false;
    foreach (i, layerModState; layers) {
        bool allMatch = true;

        // Locked-not-don't-care, nur fuer Neo-Modifier: Ein Eintrag, der einen
        // gerade gerasteten Neo-Modifier gar nicht erwaehnt, darf nicht
        // gewinnen. Sonst schattet Ebene 1 jede gerastete Zusatzebene ab, weil
        // sie den neuen Modifier schlicht nicht kennt. Gerastetes Shift ist
        // ausgenommen: Die Eintraege 4 und 6 behandeln Shift absichtlich als
        // don't care, und das soll bei Lock["Shift"] genauso bleiben.
        //
        // Eine Ebene kann sich davon ausdruecklich ausnehmen ("ignoreLocks" in
        // layouts.json). Das braucht die Modifikator-Ebene: Sie traegt die
        // Startzeichen der Compose-Grammatik und muss deshalb aus jedem
        // gerasteten Block erreichbar bleiben. Weil sie als letzter Eintrag
        // steht und Mod3+Mod4 zugleich verlangt - eine Kombination, die keine
        // fruehere Ebene trifft -, schattet sie nichts ab.
        const bool steigtAus = i < ignoresLocks.length && ignoresLocks[i];

        if (!steigtAus) foreach (locked; lockedSet) {
            if (!isNeoModifier(locked)) continue;

            bool erwaehnt = false;
            foreach (mod; layerModState.byKey) {
                if (genericModifier(mod) == locked) {
                    erwaehnt = true;
                    break;
                }
            }
            if (!erwaehnt) {
                allMatch = false;
                break;
            }
        }

        if (allMatch) {
            // wir koennen nicht (mod, modState; layerModState) schreiben,
            // weil _aaApply2 nicht nothrow ist
            foreach (mod; layerModState.byKey) {
                auto generisch = genericModifier(mod);
                bool verlangt = layerModState[mod];
                bool held = isHeld(generisch);
                if (flipShift && generisch == Modifier.SHIFT) {
                    held = !held;
                }
                bool locked = containsModifier(lockedSet, generisch);
                // Native Modifier (Shift) sind fuer Programme immer sichtbar,
                // fuer sie gilt stets die ODER-Semantik. Neo-Modifier nur im
                // Passthrough-Fall (Erweiterungsmodus ohne Filterung).
                bool passThrough = isNeoModifier(generisch) ? neoModifiersPassThrough : true;

                if (modifierActive(held, locked, passThrough) != verlangt) {
                    allMatch = false;
                    break;
                }
            }
        }

        if (allMatch) {
            return cast(uint) i + 1;
        }
    }

    // Kein Eintrag passte: der Vorgabewert. Der Melder existiert, weil sich
    // dieser Rueckfall vom echten Treffer der Ebene 1 nicht am Rueckgabewert
    // unterscheiden laesst (Rastungs-Spec 3).
    if (rueckfall !is null) *rueckfall = true;
    return 1;
}

/// Soll Capslock fuer diesen Tastendruck den Shift-Zustand umdrehen?
/// Reproduziert das Bestandsverhalten: Capslock wirkt nur auf capslockable
/// Tasten und nur, solange kein Neo-Modifier gehalten wird - "Caps+Mod3"
/// bleibt also Ebene 3. Zusaetzlich schweigt Capslock, solange ein Lock
/// aktiv ist, weil sonst zwei Umschaltungen gegeneinander arbeiten.
bool capslockSwapApplies(bool capslockOn, bool keyCapslockable, bool anyLockActive,
                         scope bool delegate(Modifier) nothrow isHeld) nothrow {
    if (!capslockOn || !keyCapslockable || anyLockActive) {
        return false;
    }

    foreach (mod; NEO_MODIFIERS) {
        if (isHeld(mod)) return false;
    }

    return true;
}

/// Traegt der Lock gerade etwas bei, das nicht ohnehin physisch gehalten wird?
/// Genau dann muss der Hook die Taste essen und ersetzen, weil ein nativer
/// Treiber von der Rastung nichts weiss.
bool lockContributes(const(Modifier)[] lockedSet,
                     scope bool delegate(Modifier) nothrow isHeld) nothrow {
    foreach (mod; lockedSet) {
        if (!isHeld(mod)) return true;
    }

    return false;
}

/// Was ein ausgeloester Trigger tut.
enum LockAction {
    SET_LOCK,               // rastet den Modifier-Satz aus "lock" (Toggle)
    CAPSLOCK,               // schaltet das Capslock des Betriebssystems um
    CLEAR_LOCKS,            // loest alle Rastungen (Panik-Chord)
    TOGGLE_OSK,             // Bildschirmtastatur ein/aus
    TOGGLE_ONE_HANDED_MODE, // Einhandmodus ein/aus
    START_COMPOSE           // beginnt eine Compose-Sequenz (wirkt in jedem Rastzustand)
}

/// Wie ein Trigger erkannt wird.
enum TriggerKind {
    DOUBLE_MODIFIER,  // linke und rechte Variante desselben Modifiers zusammen
    CHORD             // gehaltene Modifier plus eine Haupttaste
}

/// Ein Auslöser aus der "locks"-Sektion der Konfiguration.
struct LockTrigger {
    TriggerKind kind;
    Modifier modifier;      // nur bei DOUBLE_MODIFIER, generisch
    Modifier[] chordMods;   // nur bei CHORD, generisch
    VKEY chordKey;          // nur bei CHORD
    LockAction action;
    Modifier[] lockSet;     // nur bei SET_LOCK, generisch
    bool toggleMode;        // true: Satz in die laufende Rastung ein-/ausschalten
    string name;            // Anzeigename im Tooltip
}

/// Rastbar sind Shift und die Neo-Modifier. Strg und Alt bleiben aussen vor,
/// weil eine dauerhaft gerastete Strg- oder Alt-Taste jedes Programm-Shortcut
/// kapern wuerde.
bool isLockableModifier(Modifier mod) pure nothrow @nogc {
    auto generisch = genericModifier(mod);
    return generisch == Modifier.SHIFT || isNeoModifier(generisch);
}

/// Die genannten Modifier in einem bestehenden Satz ein- oder ausschalten.
/// Reihenfolge der vorhandenen Eintraege bleibt erhalten, neue kommen hinten an.
Modifier[] toggledLockSet(const(Modifier)[] aktuell, const(Modifier)[] umschalten) nothrow {
    Modifier[] neu;

    foreach (mod; aktuell) {
        if (!containsModifier(umschalten, mod)) neu ~= mod;
    }

    foreach (mod; umschalten) {
        if (!containsModifier(aktuell, mod)) neu ~= genericModifier(mod);
    }

    return neu;
}

/// Anzeigename eines Modifiers, ohne to!string - das ist nicht nothrow.
string modifierDisplayName(Modifier mod) pure nothrow @nogc {
    switch (genericModifier(mod)) {
        case Modifier.SHIFT: return "Shift";
        case Modifier.CTRL:  return "Strg";
        case Modifier.ALT:   return "Alt";
        case Modifier.MOD3:  return "Mod3";
        case Modifier.MOD4:  return "Mod4";
        case Modifier.MOD5:  return "Mod5";
        case Modifier.MOD6:  return "Mod6";
        case Modifier.MOD7:  return "Mod7";
        case Modifier.MOD8:  return "Mod8";
        case Modifier.MOD9:  return "Mod9";
        default: return "?";
    }
}

/// Anzeigename eines ganzen Satzes, etwa "Mod7+Shift".
string lockSetName(const(Modifier)[] satz) nothrow {
    string name;

    foreach (i, mod; satz) {
        if (i > 0) name ~= "+";
        name ~= modifierDisplayName(mod);
    }

    return name;
}

/// Beschriftung des Ebenenstreifens der Bildschirmtastatur: Ebenennummer,
/// Blockname und Modifier-Satz, getrennt durch Mittelpunkte. Das Wort "Ebene"
/// kommt von aussen herein, weil dieses Modul rein bleibt und die
/// Lokalisierung in localization.d haengt (die ihrerseits app.d importiert).
///
/// Name und Satz stehen beide da, weil sie Verschiedenes beantworten: Der
/// Name nennt das Thema ("Griechisch"), der Satz die Mechanik ("Mod7"). Wo
/// beide dasselbe sagen - nach dem Shift-Toggle schreibt fireLockTrigger den
/// Namen auf den Modifier-Satz um -, wird nur einmal ausgegeben.
string lockLayerLabel(string ebeneWort, uint layer, const(Modifier)[] lockedSet,
                      string lockName) nothrow {
    string text;
    try {
        text = ebeneWort ~ " " ~ layer.to!string;
    } catch (Exception e) {
        return ebeneWort;
    }

    if (lockName.length > 0) text ~= " · " ~ lockName;

    auto satz = lockSetName(lockedSet);
    if (satz.length > 0 && satz != lockName) text ~= " · " ~ satz;

    return text;
}

/// Einen Chord-String zerlegen. "Shift+Shift" ist ein Doppeltasten-Trigger,
/// "Mod3+Escape" ein Chord aus gehaltenen Modifiern und einer Haupttaste.
LockTrigger parseChord(string chord) {
    auto teile = chord.split("+");

    if (teile.length < 2) {
        throw new Exception("Ungueltiger Chord '" ~ chord ~
            "': erwartet werden mindestens zwei durch '+' getrennte Teile.");
    }

    LockTrigger trigger;

    if (teile.length == 2 && teile[0].strip.toUpper == teile[1].strip.toUpper) {
        trigger.kind = TriggerKind.DOUBLE_MODIFIER;
        trigger.modifier = genericModifier(chordModifier(chord, teile[0]));
        return trigger;
    }

    trigger.kind = TriggerKind.CHORD;
    foreach (teil; teile[0 .. $ - 1]) {
        trigger.chordMods ~= genericModifier(chordModifier(chord, teil));
    }
    trigger.chordKey = chordKeyName(chord, teile[$ - 1]);

    return trigger;
}

private Modifier chordModifier(string chord, string name) {
    try {
        return parseModifier(name.strip);
    } catch (Exception e) {
        throw new Exception("Ungueltiger Chord '" ~ chord ~ "': '" ~ name.strip ~
            "' ist kein bekannter Modifier.");
    }
}

private VKEY chordKeyName(string chord, string name) {
    try {
        return ("VK_" ~ name.strip.toUpper).to!VKEY;
    } catch (Exception e) {
        throw new Exception("Ungueltiger Chord '" ~ chord ~ "': '" ~ name.strip ~
            "' ist keine bekannte Taste.");
    }
}

/// Die "locks"-Sektion der Konfiguration in Trigger uebersetzen.
/// Die Reihenfolge der Liste bleibt erhalten; beim Dispatch gewinnt der erste
/// passende Eintrag nicht - es werden alle passenden ausgefuehrt, weil sich
/// Doppeltasten- und Chord-Trigger nie ueberschneiden.
LockTrigger[] parseLockTriggers(JSONValue locksJson) {
    LockTrigger[] trigger;

    if ("triggers" !in locksJson) {
        return trigger;
    }

    foreach (JSONValue eintrag; locksJson["triggers"].array) {
        if ("chord" !in eintrag) {
            throw new Exception("Eintrag in \"locks\".\"triggers\" ohne \"chord\".");
        }

        string chord = eintrag["chord"].str;
        auto neu = parseChord(chord);

        if ("lock" in eintrag) {
            neu.action = LockAction.SET_LOCK;

            foreach (JSONValue modJson; eintrag["lock"].array) {
                auto mod = genericModifier(chordModifier(chord, modJson.str));
                if (!isLockableModifier(mod)) {
                    throw new Exception("Chord '" ~ chord ~
                        "': \"lock\" erlaubt nur Shift und Mod3 bis Mod9, '" ~
                        modJson.str ~ "' laesst sich nicht rasten.");
                }
                neu.lockSet ~= mod;
            }

            if (neu.lockSet.length == 0) {
                throw new Exception("Chord '" ~ chord ~ "': \"lock\" ist leer.");
            }

            if ("mode" in eintrag) {
                switch (eintrag["mode"].str) {
                    case "replace": neu.toggleMode = false; break;
                    case "toggle": neu.toggleMode = true; break;
                    default:
                    throw new Exception("Chord '" ~ chord ~ "': unbekannter \"mode\" '" ~
                        eintrag["mode"].str ~ "'. Erlaubt sind replace und toggle.");
                }
            }

            neu.name = "name" in eintrag ? eintrag["name"].str : lockSetName(neu.lockSet);
        } else if ("action" in eintrag) {
            switch (eintrag["action"].str) {
                case "capslock": neu.action = LockAction.CAPSLOCK; break;
                case "clearLocks": neu.action = LockAction.CLEAR_LOCKS; break;
                case "osk": neu.action = LockAction.TOGGLE_OSK; break;
                case "oneHandedMode": neu.action = LockAction.TOGGLE_ONE_HANDED_MODE; break;
                case "compose": neu.action = LockAction.START_COMPOSE; break;
                default:
                throw new Exception("Chord '" ~ chord ~ "': unbekannte \"action\" '" ~
                    eintrag["action"].str ~
                    "'. Erlaubt sind capslock, clearLocks, osk, oneHandedMode, compose.");
            }
        } else {
            throw new Exception("Chord '" ~ chord ~
                "': ein Trigger braucht entweder \"lock\" oder \"action\".");
        }

        trigger ~= neu;
    }

    return trigger;
}

unittest {
    // genericModifier bildet die rechte auf die linke Variante ab; Modifier ohne
    // Seitenunterschied (Mod5 aufwaerts) bleiben, wie sie sind
    assert(genericModifier(Modifier.LSHIFT) == Modifier.SHIFT);
    assert(genericModifier(Modifier.RSHIFT) == Modifier.SHIFT);
    assert(genericModifier(Modifier.RMOD3) == Modifier.MOD3);
    assert(genericModifier(Modifier.RMOD4) == Modifier.MOD4);
    assert(genericModifier(Modifier.MOD5) == Modifier.MOD5);
    assert(genericModifier(Modifier.MOD9) == Modifier.MOD9);
}

unittest {
    // Neo-Modifier sind alle ab 0x100, native darunter
    assert(!isNeoModifier(Modifier.LSHIFT));
    assert(!isNeoModifier(Modifier.RALT));
    assert(isNeoModifier(Modifier.MOD3));
    assert(isNeoModifier(Modifier.MOD4));
    assert(isNeoModifier(Modifier.MOD9));

    // NEO_MODIFIERS enthaelt genau Mod3 bis Mod9 in generischer Form
    assert(NEO_MODIFIERS.length == 7);
    foreach (mod; NEO_MODIFIERS) {
        assert(isNeoModifier(mod));
        assert(genericModifier(mod) == mod);
    }
}

unittest {
    // Das Herzstueck des Rastmodells: XOR im Normalfall, ODER im Passthrough
    // (physisch gehalten, gerastet, passthrough) -> aktiv?
    assert(!modifierActive(false, false, false));
    assert(modifierActive(true, false, false));
    assert(modifierActive(false, true, false));
    // gerastet UND gehalten hebt sich auf - so kommt man kurz zurueck auf Ebene 1
    assert(!modifierActive(true, true, false));

    // Sehen Programme die Neo-Modifier selbst, darf sich nichts aufheben,
    // weil der native Treiber die Ebene ohnehin mitschaltet
    assert(!modifierActive(false, false, true));
    assert(modifierActive(true, false, true));
    assert(modifierActive(false, true, true));
    assert(modifierActive(true, true, true));
}

unittest {
    // LockState: leerer Satz, Zugehoerigkeit, Mengenvergleich
    LockState leer;
    assert(leer.empty);
    assert(!leer.isLocked(Modifier.MOD4));
    assert(leer.sameSetAs([]));
    assert(!leer.sameSetAs([Modifier.MOD4]));

    LockState mod4;
    mod4.set = [Modifier.MOD4];
    mod4.name = "Mod4";
    assert(!mod4.empty);
    assert(mod4.isLocked(Modifier.MOD4));
    // die rechte Variante zaehlt als derselbe Modifier
    assert(mod4.isLocked(Modifier.RMOD4));
    assert(!mod4.isLocked(Modifier.MOD3));
    assert(mod4.sameSetAs([Modifier.MOD4]));
    assert(!mod4.sameSetAs([Modifier.MOD3]));
    assert(!mod4.sameSetAs([Modifier.MOD4, Modifier.MOD3]));

    // Reihenfolge im Satz darf keine Rolle spielen
    LockState zwei;
    zwei.set = [Modifier.MOD5, Modifier.MOD3];
    assert(zwei.sameSetAs([Modifier.MOD3, Modifier.MOD5]));
}

version (unittest) {
    // Die Ebenendefinition, die Neo, NeoQwertz und Noted gemeinsam haben.
    PartialModifierState[] neoEbenen() {
        PartialModifierState[] l;
        l ~= [Modifier.SHIFT: false, Modifier.MOD3: false, Modifier.MOD4: false];
        l ~= [Modifier.SHIFT: true,  Modifier.MOD3: false, Modifier.MOD4: false];
        l ~= [Modifier.SHIFT: false, Modifier.MOD3: true,  Modifier.MOD4: false];
        l ~= [Modifier.MOD3: false, Modifier.MOD4: true];
        l ~= [Modifier.SHIFT: true,  Modifier.MOD3: true,  Modifier.MOD4: false];
        l ~= [Modifier.MOD3: true,  Modifier.MOD4: true];
        return l;
    }

    // Die acht Ebenen des ausgemusterten Layouts 3l - der Regressionsfall.
    // Die reine Mod4-Ebene liegt hier an Index 4, ist also Ebene 5.
    PartialModifierState[] dreiLEbenen() {
        PartialModifierState[] l;
        l ~= [Modifier.SHIFT: false, Modifier.MOD3: false, Modifier.MOD4: false];
        l ~= [Modifier.SHIFT: true,  Modifier.MOD3: false, Modifier.MOD4: false];
        l ~= [Modifier.SHIFT: false, Modifier.MOD3: true,  Modifier.MOD4: false];
        l ~= [Modifier.SHIFT: true,  Modifier.MOD3: true,  Modifier.MOD4: false];
        l ~= [Modifier.SHIFT: false, Modifier.MOD3: false, Modifier.MOD4: true];
        l ~= [Modifier.SHIFT: true,  Modifier.MOD3: false, Modifier.MOD4: true];
        l ~= [Modifier.SHIFT: false, Modifier.MOD3: true,  Modifier.MOD4: true];
        l ~= [Modifier.SHIFT: true,  Modifier.MOD3: true,  Modifier.MOD4: true];
        return l;
    }

    // Die 14 Noted-Ebenen aus Paket 2. Reihenfolge und explizite
    // Modifier-Nennungen muessen exakt der layers-Definition in layouts.json
    // entsprechen: Alle neuen Eintraege nennen Shift und Mod5-Mod8 explizit,
    // weil die Locked-not-don't-care-Regel Shift ausnimmt und ein Eintrag
    // ohne Shift-Nennung die zweite Blockebene abschatten wuerde.
    PartialModifierState[] notedEbenen14() {
        PartialModifierState[] l;
        l ~= [Modifier.SHIFT: false, Modifier.MOD3: false, Modifier.MOD4: false,
              Modifier.MOD5: false, Modifier.MOD6: false, Modifier.MOD7: false, Modifier.MOD8: false];
        l ~= [Modifier.SHIFT: true,  Modifier.MOD3: false, Modifier.MOD4: false,
              Modifier.MOD5: false, Modifier.MOD6: false, Modifier.MOD7: false, Modifier.MOD8: false];
        l ~= [Modifier.SHIFT: false, Modifier.MOD3: true,  Modifier.MOD4: false,
              Modifier.MOD5: false, Modifier.MOD6: false, Modifier.MOD7: false, Modifier.MOD8: false];
        // Eintrag 4 behaelt sein Shift-don't-care (Ebene 4 gewinnt auch mit Shift)
        l ~= [Modifier.MOD3: false, Modifier.MOD4: true,
              Modifier.MOD5: false, Modifier.MOD6: false, Modifier.MOD7: false, Modifier.MOD8: false];
        // 5/6: Mathematik (Mod3+Mod4, physisch erreichbar und rastbar)
        l ~= [Modifier.SHIFT: false, Modifier.MOD3: true,  Modifier.MOD4: true,
              Modifier.MOD5: false, Modifier.MOD6: false, Modifier.MOD7: false, Modifier.MOD8: false];
        l ~= [Modifier.SHIFT: true,  Modifier.MOD3: true,  Modifier.MOD4: true,
              Modifier.MOD5: false, Modifier.MOD6: false, Modifier.MOD7: false, Modifier.MOD8: false];
        // 7/8: Typografie (Mod5), 9/10: Griechisch (Mod6),
        // 11/12: Kyrillisch (Mod7), 13/14: Obskures (Mod8)
        foreach (block; [Modifier.MOD5, Modifier.MOD6, Modifier.MOD7, Modifier.MOD8]) {
            foreach (shift; [false, true]) {
                PartialModifierState eintrag;
                eintrag[Modifier.SHIFT] = shift;
                eintrag[Modifier.MOD3] = false;
                eintrag[Modifier.MOD4] = false;
                foreach (mod; [Modifier.MOD5, Modifier.MOD6, Modifier.MOD7, Modifier.MOD8]) {
                    eintrag[mod] = mod == block;
                }
                l ~= eintrag;
            }
        }
        return l;
    }

    // Ein isHeld-Delegat, das genau die uebergebenen Modifier als gehalten meldet.
    bool delegate(Modifier) nothrow gehalten(Modifier[] modifier) {
        return delegate bool(Modifier mod) nothrow {
            return containsModifier(modifier, mod);
        };
    }
}

unittest {
    // Ohne Lock reproduziert determineLayer die sechs Neo-Ebenen
    auto ebenen = neoEbenen();

    assert(determineLayer(ebenen, gehalten([]), [], false, false) == 1);
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT]), [], false, false) == 2);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3]), [], false, false) == 3);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD4]), [], false, false) == 4);
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT, Modifier.MOD3]), [], false, false) == 5);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3, Modifier.MOD4]), [], false, false) == 6);

    // Die rechte Variante zaehlt genauso
    assert(determineLayer(ebenen, gehalten([Modifier.RMOD3]), [], false, false) == 3);

    // Bestandsverhalten, das leicht ueberrascht: Ebene 4 nennt Shift nicht,
    // gewinnt also auch bei gehaltenem Shift
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT, Modifier.MOD4]), [], false, false) == 4);
}

unittest {
    // Gerasteter Mod4: ohne gehaltene Taste Ebene 4, mit gehaltener Taste
    // zurueck auf Ebene 1 (XOR)
    auto ebenen = neoEbenen();
    const Modifier[] lock = [Modifier.MOD4];

    assert(determineLayer(ebenen, gehalten([]), lock, false, false) == 4);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD4]), lock, false, false) == 1);
    assert(determineLayer(ebenen, gehalten([Modifier.RMOD4]), lock, false, false) == 1);
    // Shift wirkt neben dem Lock normal weiter
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT, Modifier.MOD4]), lock, false, false) == 2);
    // Mod3 zusaetzlich zum gerasteten Mod4 ergibt Ebene 6
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3]), lock, false, false) == 6);
}

unittest {
    // Passthrough: sehen Programme die Neo-Modifier selbst, hebt die gehaltene
    // Taste den Lock nicht auf - das ist die heutige Ausnahme des Mod4-Locks
    // im Erweiterungsmodus mit filterNeoModifiers: false
    auto ebenen = neoEbenen();
    const Modifier[] lock = [Modifier.MOD4];

    assert(determineLayer(ebenen, gehalten([Modifier.MOD4]), lock, true, false) == 4);
    assert(determineLayer(ebenen, gehalten([]), lock, true, false) == 4);
}

unittest {
    // Shift-Rastung: fuer gerastetes Shift gilt ODER statt XOR, weil das
    // physische Shift fuer Programme sichtbar bleibt (Shortcuts, Shift+Klick)
    // und XOR gegen ein sichtbares Shift nicht arbeiten kann
    auto ebenen = neoEbenen();
    const Modifier[] lock = [Modifier.SHIFT];

    assert(determineLayer(ebenen, gehalten([]), lock, false, false) == 2);
    // Halten hebt die Shift-Rastung NICHT auf - ODER, nicht XOR
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT]), lock, false, false) == 2);
    // Eintrag 4 behandelt Shift als don't care - das bleibt auch bei
    // gerastetem Shift so (Locked-not-don't-care gilt nur fuer Neo-Modifier)
    assert(determineLayer(ebenen, gehalten([Modifier.MOD4]), lock, false, false) == 4);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3]), lock, false, false) == 5);
}

unittest {
    // Ebene 5 als Rastung: Shift und Mod3 zusammen gerastet
    auto ebenen = neoEbenen();
    const Modifier[] lock = [Modifier.SHIFT, Modifier.MOD3];

    assert(determineLayer(ebenen, gehalten([]), lock, false, false) == 5);
    // Mod4 dazu: Eintrag 6 nennt Shift nicht (don't care) -> Ebene 6
    assert(determineLayer(ebenen, gehalten([Modifier.MOD4]), lock, false, false) == 6);
    // Mod3 halten hebt den Neo-Anteil der Rastung auf (XOR) -> Ebene 2
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3]), lock, false, false) == 2);
}

unittest {
    // Regression 3l: der gerastete Mod4 trifft dort Ebene 5, nicht Ebene 4.
    // Der alte hartkodierte Lock setzte fest layer = 4 und lag damit daneben.
    auto ebenen = dreiLEbenen();
    const Modifier[] lock = [Modifier.MOD4];

    assert(determineLayer(ebenen, gehalten([]), lock, false, false) == 5);
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT]), lock, false, false) == 6);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD4]), lock, false, false) == 1);
}

unittest {
    // Locked-not-don't-care: ein Eintrag, der den gerasteten Modifier nicht
    // erwaehnt, darf nicht gewinnen
    auto ebenen = neoEbenen();
    ebenen ~= [Modifier.SHIFT: false, Modifier.MOD3: false, Modifier.MOD4: false, Modifier.MOD5: true];
    const Modifier[] lock = [Modifier.MOD5];

    // Ebene 1 wuerde ohne die Regel passen, weil sie Mod5 nicht nennt
    assert(determineLayer(ebenen, gehalten([]), lock, false, false) == 7);

    // Kennt kein Eintrag den gerasteten Modifier, faellt die Ebene auf 1
    // zurueck, statt etwas Beliebiges zu treffen
    assert(determineLayer(neoEbenen(), gehalten([]), lock, false, false) == 1);
}

unittest {
    // Capslock-Wahrheitstabelle. Der Tausch greift nur, wenn Capslock an ist,
    // die Taste capslockable ist, kein Lock aktiv ist und kein Neo-Modifier
    // gehalten wird.
    assert(capslockSwapApplies(true, true, false, gehalten([])));
    assert(capslockSwapApplies(true, true, false, gehalten([Modifier.SHIFT])));

    assert(!capslockSwapApplies(false, true, false, gehalten([])));
    assert(!capslockSwapApplies(true, false, false, gehalten([])));
    assert(!capslockSwapApplies(true, true, true, gehalten([])));
    // Caps+Mod3 bleibt Ebene 3 - der wichtigste Bestandsfall
    assert(!capslockSwapApplies(true, true, false, gehalten([Modifier.MOD3])));
    assert(!capslockSwapApplies(true, true, false, gehalten([Modifier.RMOD4])));
}

unittest {
    // Greift der Tausch, wird die Ebene mit umgedrehtem Shift neu bestimmt -
    // fuer die heutigen Layouts ist das genau der Tausch 1 gegen 2
    auto ebenen = neoEbenen();

    assert(determineLayer(ebenen, gehalten([]), [], false, true) == 2);
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT]), [], false, true) == 1);
}

unittest {
    // lockContributes: traegt der Lock gerade etwas bei, das nicht ohnehin
    // physisch gehalten wird? Danach entscheidet sich, ob die Taste gegessen
    // werden muss, weil der native Treiber sie nicht richtig uebersetzt.
    assert(!lockContributes([], gehalten([])));
    assert(lockContributes([Modifier.MOD4], gehalten([])));
    assert(!lockContributes([Modifier.MOD4], gehalten([Modifier.MOD4])));
    assert(!lockContributes([Modifier.MOD4], gehalten([Modifier.RMOD4])));
    assert(lockContributes([Modifier.MOD4, Modifier.MOD5], gehalten([Modifier.MOD4])));
}

unittest {
    // Doppeltasten-Chords: zweimal derselbe Modifier
    auto shift = parseChord("Shift+Shift");
    assert(shift.kind == TriggerKind.DOUBLE_MODIFIER);
    assert(shift.modifier == Modifier.SHIFT);

    auto mod4 = parseChord("Mod4+Mod4");
    assert(mod4.kind == TriggerKind.DOUBLE_MODIFIER);
    assert(mod4.modifier == Modifier.MOD4);

    // Gross- und Kleinschreibung ist egal, Leerzeichen ebenso
    auto lose = parseChord(" mod4 + MOD4 ");
    assert(lose.kind == TriggerKind.DOUBLE_MODIFIER);
    assert(lose.modifier == Modifier.MOD4);
}

unittest {
    // Echte Chords: Modifier plus Haupttaste
    auto esc = parseChord("Mod3+Escape");
    assert(esc.kind == TriggerKind.CHORD);
    assert(esc.chordMods == [Modifier.MOD3]);
    assert(esc.chordKey == VKEY.VK_ESCAPE);

    auto f1 = parseChord("Mod3+F1");
    assert(f1.kind == TriggerKind.CHORD);
    assert(f1.chordKey == VKEY.VK_F1);

    auto zwei = parseChord("Mod3+Shift+F5");
    assert(zwei.kind == TriggerKind.CHORD);
    assert(zwei.chordMods == [Modifier.MOD3, Modifier.SHIFT]);
    assert(zwei.chordKey == VKEY.VK_F5);
}

unittest {
    // Fehlerhafte Chords werfen eine verstaendliche Exception, keinen ConvError
    import std.exception : assertThrown;

    assertThrown!Exception(parseChord("F1"));
    assertThrown!Exception(parseChord("Quatsch+F1"));
    assertThrown!Exception(parseChord("Mod3+Quatsch"));
    assertThrown!Exception(parseChord(""));
}

unittest {
    // Die Vorgabekonfiguration wird vollstaendig geparst
    import std.json : parseJSON;

    auto json = parseJSON(`{
        "oskAutoShow": false,
        "triggers": [
            { "chord": "Shift+Shift", "action": "capslock" },
            { "chord": "Mod4+Mod4", "lock": ["Mod4"], "name": "Mod4" },
            { "chord": "Mod3+Escape", "action": "clearLocks" },
            { "chord": "Mod3+F1", "action": "osk" },
            { "chord": "Mod3+F10", "action": "oneHandedMode" }
        ]
    }`);

    auto trigger = parseLockTriggers(json);
    assert(trigger.length == 5);

    assert(trigger[0].kind == TriggerKind.DOUBLE_MODIFIER);
    assert(trigger[0].action == LockAction.CAPSLOCK);

    assert(trigger[1].kind == TriggerKind.DOUBLE_MODIFIER);
    assert(trigger[1].action == LockAction.SET_LOCK);
    assert(trigger[1].lockSet == [Modifier.MOD4]);
    assert(trigger[1].name == "Mod4");

    assert(trigger[2].action == LockAction.CLEAR_LOCKS);
    assert(trigger[3].action == LockAction.TOGGLE_OSK);
    assert(trigger[4].action == LockAction.TOGGLE_ONE_HANDED_MODE);
}

unittest {
    // Ohne "name" ergibt sich der Anzeigename aus dem gerasteten Satz
    import std.json : parseJSON;

    auto json = parseJSON(`{
        "triggers": [ { "chord": "Mod3+F2", "lock": ["Mod5"] } ]
    }`);

    auto trigger = parseLockTriggers(json);
    assert(trigger.length == 1);
    assert(trigger[0].lockSet == [Modifier.MOD5]);
    assert(trigger[0].name == "Mod5");
}

unittest {
    // Shift ist rastbar - damit ist jede Ebene ab der zweiten erreichbar
    import std.json : parseJSON;

    auto json = parseJSON(`{
        "triggers": [
            { "chord": "Mod3+F7", "lock": ["Shift"], "mode": "toggle" },
            { "chord": "Mod3+F8", "lock": ["Shift", "Mod3"], "name": "Ebene 5" }
        ]
    }`);

    auto trigger = parseLockTriggers(json);
    assert(trigger[0].lockSet == [Modifier.SHIFT]);
    assert(trigger[0].toggleMode);
    assert(trigger[1].lockSet == [Modifier.SHIFT, Modifier.MOD3]);
    // ohne "mode" gilt Ersetzen
    assert(!trigger[1].toggleMode);
}

unittest {
    // toggledLockSet schaltet die genannten Modifier hinein und wieder heraus
    assert(toggledLockSet([], [Modifier.SHIFT]) == [Modifier.SHIFT]);
    assert(toggledLockSet([Modifier.SHIFT], [Modifier.SHIFT]) == []);
    assert(toggledLockSet([Modifier.MOD7], [Modifier.SHIFT]) == [Modifier.MOD7, Modifier.SHIFT]);
    assert(toggledLockSet([Modifier.MOD7, Modifier.SHIFT], [Modifier.SHIFT]) == [Modifier.MOD7]);

    // lockSetName baut den Anzeigenamen aus dem Satz
    assert(lockSetName([]) == "");
    assert(lockSetName([Modifier.MOD7]) == "Mod7");
    assert(lockSetName([Modifier.MOD7, Modifier.SHIFT]) == "Mod7+Shift");
}

unittest {
    // Fehlerhafte Trigger-Eintraege werden abgelehnt
    import std.exception : assertThrown;
    import std.json : parseJSON;

    // Strg und Alt sind als Rastung nicht erlaubt - eine dauerhaft gerastete
    // Strg-Taste wuerde jedes Programm-Shortcut kapern
    assertThrown!Exception(parseLockTriggers(parseJSON(
        `{"triggers": [ {"chord": "Mod3+F2", "lock": ["Ctrl"]} ]}`)));
    assertThrown!Exception(parseLockTriggers(parseJSON(
        `{"triggers": [ {"chord": "Mod3+F2", "lock": ["LAlt"]} ]}`)));
    // unbekannter Modus
    assertThrown!Exception(parseLockTriggers(parseJSON(
        `{"triggers": [ {"chord": "Mod3+F2", "lock": ["Mod5"], "mode": "huepfen"} ]}`)));
    // leerer Lock-Satz
    assertThrown!Exception(parseLockTriggers(parseJSON(
        `{"triggers": [ {"chord": "Mod3+F2", "lock": []} ]}`)));
    // weder lock noch action
    assertThrown!Exception(parseLockTriggers(parseJSON(
        `{"triggers": [ {"chord": "Mod3+F2"} ]}`)));
    // unbekannte action
    assertThrown!Exception(parseLockTriggers(parseJSON(
        `{"triggers": [ {"chord": "Mod3+F2", "action": "fliegen"} ]}`)));
    // kein chord
    assertThrown!Exception(parseLockTriggers(parseJSON(
        `{"triggers": [ {"action": "capslock"} ]}`)));

    // Fehlt "triggers" ganz, ist die Liste eben leer - kein Fehler
    assert(parseLockTriggers(parseJSON(`{"oskAutoShow": true}`)).length == 0);
}

unittest {
    // Die 14 Noted-Ebenen aus Paket 2: physisch erreichbar bleiben 1-6,
    // Shift+Mod3 hat keine Ebene mehr und faellt auf 1 zurueck
    auto ebenen = notedEbenen14();
    assert(ebenen.length == 14);

    assert(determineLayer(ebenen, gehalten([]), [], false, false) == 1);
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT]), [], false, false) == 2);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3]), [], false, false) == 3);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD4]), [], false, false) == 4);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3, Modifier.MOD4]), [], false, false) == 5);
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT, Modifier.MOD3, Modifier.MOD4]), [], false, false) == 6);
    // Verhaltensaenderung aus Paket 2: das alte kleine Griechisch (Shift+Mod3)
    // gibt es nicht mehr - kein Eintrag passt, Rueckfall auf Ebene 1
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT, Modifier.MOD3]), [], false, false) == 1);
    // Ebene 4 bleibt Shift-don't-care
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT, Modifier.MOD4]), [], false, false) == 4);
}

unittest {
    // Griechisch-Rastung: Lock[Mod6] -> 9, Shift wechselt im Block auf 10
    auto ebenen = notedEbenen14();
    const Modifier[] lock = [Modifier.MOD6];

    assert(determineLayer(ebenen, gehalten([]), lock, false, false) == 9);
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT]), lock, false, false) == 10);
    // Gehaltenes Mod3 passt zu keinem Eintrag (die Blockebenen verlangen
    // Mod3 false, die Ebenen 3/4 nennen Mod6 nicht) -> Fallback Ebene 1
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3]), lock, false, false) == 1);
}

unittest {
    // Mathematik-Rastung: Lock[Mod3, Mod4] -> 5; XOR-Nebeneffekt aus dem
    // Masterplan: Mod3 halten hebt seinen Anteil auf -> Ebene 4 (Navigation),
    // Mod4 halten entsprechend -> Ebene 3
    auto ebenen = notedEbenen14();
    const Modifier[] lock = [Modifier.MOD3, Modifier.MOD4];

    assert(determineLayer(ebenen, gehalten([]), lock, false, false) == 5);
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT]), lock, false, false) == 6);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3]), lock, false, false) == 4);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD4]), lock, false, false) == 3);
}

unittest {
    // Zweite Blockebene dauerhaft: Shift zusaetzlich gerastet (mode: "toggle")
    auto ebenen = notedEbenen14();
    const Modifier[] lock = [Modifier.MOD5, Modifier.SHIFT];

    assert(determineLayer(ebenen, gehalten([]), lock, false, false) == 8);
    // ODER-Semantik: gehaltenes Shift hebt die Shift-Rastung nicht auf
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT]), lock, false, false) == 8);
}

unittest {
    // Die sechs Paket-2-Trigger aus config.default.json werden geparst:
    // fuenf Blockrastungen plus der Shift-Umschalter (mode: "toggle")
    import std.json : parseJSON;

    auto json = parseJSON(`{
        "triggers": [
            { "chord": "Mod3+F2", "lock": ["Mod3", "Mod4"], "name": "Mathematik" },
            { "chord": "Mod3+F3", "lock": ["Mod5"],         "name": "Typografie" },
            { "chord": "Mod3+F4", "lock": ["Mod6"],         "name": "Griechisch" },
            { "chord": "Mod3+F5", "lock": ["Mod7"],         "name": "Kyrillisch" },
            { "chord": "Mod3+F6", "lock": ["Mod8"],         "name": "Extra" },
            { "chord": "Mod3+F7", "lock": ["Shift"],        "mode": "toggle", "name": "Shift" }
        ]
    }`);

    auto trigger = parseLockTriggers(json);
    assert(trigger.length == 6);

    assert(trigger[0].chordKey == VKEY.VK_F2);
    assert(trigger[0].lockSet == [Modifier.MOD3, Modifier.MOD4]);
    assert(trigger[0].name == "Mathematik");
    assert(!trigger[0].toggleMode);

    assert(trigger[1].lockSet == [Modifier.MOD5]);
    assert(trigger[2].lockSet == [Modifier.MOD6]);
    assert(trigger[3].lockSet == [Modifier.MOD7]);
    assert(trigger[4].lockSet == [Modifier.MOD8]);

    assert(trigger[5].chordKey == VKEY.VK_F7);
    assert(trigger[5].lockSet == [Modifier.SHIFT]);
    assert(trigger[5].toggleMode);
}

unittest {
    // Paket 7: Das Blockschema - jeder Themenblock hat einen eigenen
    // Block-Modifier (Mod5-Mod9); bei gerasteter Basis erreichen gehaltenes
    // Shift/Mod3/Mod4 die weiteren Ebenen des Blocks. Die Fixture bildet die
    // 20-Ebenen-Definition von AnNoted nach (alle Eintraege nennen Shift und
    // Mod5-Mod9 explizit, wie es die Locked-not-don't-care-Regel verlangt).
    import mapping : Modifier, PartialModifierState;

    bool delegate(Modifier) nothrow gehalten(Modifier[] modifier) {
        return delegate bool(Modifier mod) nothrow {
            return containsModifier(modifier, mod);
        };
    }

    PartialModifierState eintrag(bool shift, bool m3, bool m4,
                                 Modifier block = cast(Modifier) 0) {
        // cast(Modifier) 0 dient nur als "kein Block"-Markierung; der Wert 0
        // kollidiert mit keinem Blockmodifier (die liegen ab 0x104).
        PartialModifierState s = [
            Modifier.SHIFT: shift, Modifier.MOD3: m3, Modifier.MOD4: m4,
            Modifier.MOD5: false, Modifier.MOD6: false, Modifier.MOD7: false,
            Modifier.MOD8: false, Modifier.MOD9: false
        ];
        if (block != cast(Modifier) 0) s[block] = true;
        return s;
    }

    PartialModifierState[] ebenen;
    ebenen ~= eintrag(false, false, false);                 // 1
    ebenen ~= eintrag(true,  false, false);                 // 2
    ebenen ~= eintrag(false, true,  false);                 // 3
    // Ebene 4 behaelt ihr Shift-don't-care wie im echten Layout
    PartialModifierState vier = [
        Modifier.MOD3: false, Modifier.MOD4: true,
        Modifier.MOD5: false, Modifier.MOD6: false, Modifier.MOD7: false,
        Modifier.MOD8: false, Modifier.MOD9: false
    ];
    ebenen ~= vier;                                          // 4
    foreach (block; [Modifier.MOD5, Modifier.MOD6]) {        // Mathe, Typo
        ebenen ~= eintrag(false, false, false, block);       // Basis
        ebenen ~= eintrag(true,  false, false, block);       // +Shift
        ebenen ~= eintrag(false, true,  false, block);       // +Mod3
        ebenen ~= eintrag(false, false, true,  block);       // +Mod4
    }
    foreach (block; [Modifier.MOD7, Modifier.MOD8]) {
        ebenen ~= eintrag(false, false, false, block);       // Basis
        ebenen ~= eintrag(true,  false, false, block);       // +Shift
    }
    // Extra (Mod9) ist seit der Extra-Runde der dritte Vier-Ebenen-Block:
    // Basis, +Shift, +Mod3 (Emoji), +Mod4 (Obskures)
    ebenen ~= eintrag(false, false, false, Modifier.MOD9);
    ebenen ~= eintrag(true,  false, false, Modifier.MOD9);
    ebenen ~= eintrag(false, true,  false, Modifier.MOD9);
    ebenen ~= eintrag(false, false, true,  Modifier.MOD9);
    assert(ebenen.length == 20);

    // Gerastete Mathe-Basis und ihre drei Erweiterungen
    const(Modifier)[] mathe = [Modifier.MOD5];
    assert(determineLayer(ebenen, gehalten([]), mathe, false, false) == 5);
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT]), mathe, false, false) == 6);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3]), mathe, false, false) == 7);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD4]), mathe, false, false) == 8);
    // Shift+Mod3 zugleich hat keine Ebene -> Rueckfall 1
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT, Modifier.MOD3]), mathe, false, false) == 1);

    // Typografie sitzt direkt dahinter
    const(Modifier)[] typo = [Modifier.MOD6];
    assert(determineLayer(ebenen, gehalten([Modifier.MOD4]), typo, false, false) == 12);

    // Letzter Block, seit der Extra-Runde mit vier Ebenen
    const(Modifier)[] extra = [Modifier.MOD9];
    assert(determineLayer(ebenen, gehalten([]), extra, false, false) == 17);
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT]), extra, false, false) == 18);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3]), extra, false, false) == 19);
    assert(determineLayer(ebenen, gehalten([Modifier.MOD4]), extra, false, false) == 20);
    // Shift+Mod3 zugleich hat auch hier keine Ebene -> Rueckfall 1
    assert(determineLayer(ebenen, gehalten([Modifier.SHIFT, Modifier.MOD3]), extra, false, false) == 1);

    // Mod3+Mod4 gehalten ohne Rastung hat keine Ebene mehr -> Rueckfall 1
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3, Modifier.MOD4]), [], false, false) == 1);
}

unittest {
    // ignoreLocks: Eine Ebene, die einen gerasteten Neo-Modifier nicht nennt,
    // verliert normalerweise (Locked-not-don't-care). Mit der Marke gewinnt sie
    // trotzdem - das ist die Grundlage der Modifikator-Ebene 21, die aus jedem
    // gerasteten Block erreichbar sein muss.
    PartialModifierState[] ebenen;
    PartialModifierState e1;                       // Ebene 1: nichts gehalten
    e1[Modifier.SHIFT] = false; e1[Modifier.MOD3] = false;
    e1[Modifier.MOD4] = false; e1[Modifier.MOD5] = false;
    ebenen ~= e1;
    PartialModifierState e2;                       // Ebene 2: nur Mod5 (Block)
    e2[Modifier.SHIFT] = false; e2[Modifier.MOD3] = false;
    e2[Modifier.MOD4] = false; e2[Modifier.MOD5] = true;
    ebenen ~= e2;
    PartialModifierState e3;                       // Ebene 3: Mod3+Mod4, Mod5 ungenannt
    e3[Modifier.MOD3] = true; e3[Modifier.MOD4] = true;
    ebenen ~= e3;

    auto haltMod34 = gehalten([Modifier.MOD3, Modifier.MOD4]);

    // Ohne Rastung trifft der Griff die dritte Ebene, mit und ohne Marke.
    assert(determineLayer(ebenen, haltMod34, [], false, false) == 3);
    assert(determineLayer(ebenen, haltMod34, [], false, false, [false, false, true]) == 3);

    // Mit gerastetem Mod5 verliert sie ohne Marke (Rueckfall auf Ebene 1) ...
    assert(determineLayer(ebenen, haltMod34, [Modifier.MOD5], false, false) == 1,
        "Gegenprobe: ohne Marke greift Locked-not-don't-care");

    // ... und gewinnt mit Marke.
    assert(determineLayer(ebenen, haltMod34, [Modifier.MOD5], false, false,
        [false, false, true]) == 3);

    // Eine zu kurze Liste gilt als "keine Ebene steigt aus".
    assert(determineLayer(ebenen, haltMod34, [Modifier.MOD5], false, false, [false]) == 1);
}

unittest {
    // Rueckfall-Melder (Rastungs-Spec 3): wahr nur, wenn KEIN Ebenen-Eintrag
    // passte und der Vorgabewert 1 zurueckgeht. Ebene 1 echt getroffen und
    // ein getroffener Blockeintrag melden beide falsch - die Drehung der
    // Kandidatenreihenfolge (Spec 2.2) darf nur den echten Rueckfall treffen.
    auto ebenen = notedEbenen14();

    bool rueckfall = true;
    assert(determineLayer(ebenen, gehalten([]), [], false, false, [], &rueckfall) == 1);
    assert(!rueckfall, "Ebene 1 echt getroffen ist kein Rueckfall");

    // Griechisch-Block der Fixture: Mod6, Ebenen 9/10.
    auto lock = [Modifier.MOD6];
    rueckfall = true;
    assert(determineLayer(ebenen, gehalten([]), lock, false, false, [], &rueckfall) == 9);
    assert(!rueckfall, "getroffener Blockeintrag ist kein Rueckfall");

    // Gehaltenes Mod3 unter der Rastung: 9/10 verlangen Mod3 false, alle
    // anderen Eintraege nennen Mod6 nicht (Locked-not-don't-care) - nichts
    // passt, der Vorgabewert 1 geht mit Meldung zurueck.
    rueckfall = false;
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3]), lock, false, false, [], &rueckfall) == 1);
    assert(rueckfall, "Vorgabewert 1 ohne Treffer muss als Rueckfall gemeldet werden");

    // Aufruf ohne den Parameter bleibt unveraendert moeglich.
    assert(determineLayer(ebenen, gehalten([Modifier.MOD3]), lock, false, false) == 1);
}

unittest {
    // Die Beschriftung des Ebenenstreifens: Ebenennummer, Blockname und
    // Modifier-Satz. Der Name kommt aus dem Ausloeser ("Griechisch"), der
    // Satz aus der laufenden Rastung - beide gehoeren hin, weil der eine das
    // Thema nennt und der andere die Mechanik.
    assert(lockLayerLabel("Ebene", 13, [Modifier.MOD7], "Griechisch")
        == "Ebene 13 · Griechisch · Mod7");

    // Der Shift-Toggle schreibt currentLock.name auf den Modifier-Satz um
    // (fireLockTrigger). Dann steht dieselbe Angabe zweimal da - einmal
    // genuegt.
    assert(lockLayerLabel("Ebene", 14, [Modifier.MOD7, Modifier.SHIFT], "Mod7+Shift")
        == "Ebene 14 · Mod7+Shift");

    // Ohne Rastung nur die Nummer: Der Streifen erscheint dann ohnehin nur,
    // wenn zugleich eine Compose-Sequenz laeuft.
    assert(lockLayerLabel("Ebene", 21, [], "") == "Ebene 21");

    // Ein leerer Name mit gerastetem Satz kann nicht vorkommen (lockSetName
    // springt ein), waere aber kein Grund fuer einen doppelten Trenner.
    assert(lockLayerLabel("Layer", 5, [Modifier.MOD5], "") == "Layer 5 · Mod5");
}

unittest {
    // Compose als Ausloeser: Mod3+Tab wird vor der Ebenenbestimmung
    // ausgewertet und wirkt deshalb auch bei gerastetem Block.
    import std.json : parseJSON;
    import std.algorithm : canFind;
    import std.exception : collectException;

    auto trigger = parseLockTriggers(parseJSON(
        `{"triggers": [ {"chord": "Mod3+Tab", "action": "compose"} ]}`));

    assert(trigger.length == 1);
    assert(trigger[0].kind == TriggerKind.CHORD);
    assert(trigger[0].action == LockAction.START_COMPOSE);
    assert(trigger[0].chordKey == VKEY.VK_TAB);

    // Gegenprobe: Die Fehlermeldung zaehlt die erlaubten Actions auf, und
    // "compose" muss darin vorkommen - sonst sucht der naechste Leser vergeblich.
    auto e = collectException(parseLockTriggers(parseJSON(
        `{"triggers": [ {"chord": "Mod3+F2", "action": "fliegen"} ]}`)));
    assert(e !is null);
    assert(e.msg.canFind("compose"), "die Fehlermeldung muss compose nennen");
}
