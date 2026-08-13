module sheet;

import std.array : appender;
import std.algorithm : sort;
import std.conv : to;
import std.format : format;

import mapping;
import keyboardview;
import layerlock : LockTrigger, LockAction, TriggerKind, determineLayer, genericModifier;
import html : htmlEscape;

// Das HTML-Belegungsblatt. Bewusst ohne Cairo, ohne Win32 und ohne app.d:
// Dieses Modul wird sowohl vom laufenden Programm (Tray-Eintrag) als auch von
// der dub-Konfiguration "tool" benutzt, und Letztere soll weder den Hook noch
// die Zeichenbibliothek linken.
//
// Gestaltung nach dem Design-Standard "Schweizer Sachlichkeit": Papier/Tinte,
// Hairlines, border-radius 0, keine Schatten, EIN Akzent-Slot (Ultramarin),
// Druck immer hell. Der Akzent traegt Bedeutung (Tastenart), nicht Dekoration -
// Fingerfarben gibt es hier bewusst nicht, sie wuerden die Flaeche fluten.

/// Kopfzeile einer Ebene.
struct LayerInfo {
    uint number;
    /// Modifier-Definition der Ebene, z.B. "Mod3 + Mod4, ohne Shift"
    string modifiers;
    /// Ausloeser aus der Konfiguration, z.B. "Mod3+F2 (Mathematik)"; leer, wenn
    /// die Ebene ueber keine Rastung erreichbar ist
    string trigger;
}

/// Anzeigename eines Modifiers fuer die Kopfzeile. Bewusst nicht
/// keyboardview.modifierLabel: Das liefert Tastenbeschriftungen ("M3", "⇧"),
/// hier steht die Definition der Ebene ("Mod3", "Shift").
///
/// Ueber genericModifier geschaltet, nicht direkt ueber mod: Modifier.SHIFT und
/// Modifier.LSHIFT sind derselbe Wert (0xA0), zwei case-Zweige dafuer waeren ein
/// Uebersetzungsfehler. Dieselbe Loesung wie in keyboardview.modifierLabel.
private string modifierName(Modifier mod) {
    switch (genericModifier(mod)) {
        case Modifier.LSHIFT: return "Shift";
        case Modifier.LCTRL:  return "Strg";
        case Modifier.LALT:   return "Alt";
        case Modifier.MOD3: return "Mod3";
        case Modifier.MOD4: return "Mod4";
        case Modifier.MOD5: return "Mod5";
        case Modifier.MOD6: return "Mod6";
        case Modifier.MOD7: return "Mod7";
        case Modifier.MOD8: return "Mod8";
        case Modifier.MOD9: return "Mod9";
        default: return mod.to!string;
    }
}

/// Tastenname eines VK-Codes ohne das Praefix, z.B. VK_DELETE -> "VK_DELETE".
/// Bewusst MIT Praefix: So ist im Blatt sofort erkennbar, dass hier eine
/// virtuelle Taste steht und kein Zeichen.
private string vkName(VKEY vk) {
    return vk.to!string;
}

/// Chord-Beschreibung eines Ausloesers, so wie er in der config.json steht.
private string triggerChord(const LockTrigger t) {
    final switch (t.kind) {
        case TriggerKind.DOUBLE_MODIFIER:
            auto name = modifierName(t.modifier);
            return name ~ "+" ~ name;
        case TriggerKind.CHORD:
            string s;
            foreach (mod; t.chordMods) {
                s ~= modifierName(mod) ~ "+";
            }
            // VK_F2 -> F2: In der Konfiguration steht der Chord ohne Praefix.
            auto taste = t.chordKey.to!string;
            return s ~ (taste.length > 3 && taste[0 .. 3] == "VK_" ? taste[3 .. $] : taste);
    }
}

LayerInfo[] layerInfos(NeoLayout* layout, const(LockTrigger)[] triggers) {
    LayerInfo[] infos;

    foreach (i, ebene; layout.layers) {
        LayerInfo info;
        info.number = cast(uint) i + 1;

        // Die Reihenfolge in einem assoziativen Array ist unspezifiziert -
        // sortieren, sonst sieht das Blatt bei jedem Lauf anders aus.
        Modifier[] verlangt;
        Modifier[] ausgeschlossen;
        foreach (mod; ebene.byKey) {
            if (ebene[mod]) verlangt ~= mod;
            else ausgeschlossen ~= mod;
        }
        verlangt.sort();
        ausgeschlossen.sort();

        string text;
        foreach (j, mod; verlangt) {
            text ~= (j == 0 ? "" : " + ") ~ modifierName(mod);
        }
        // "ohne Modifier" nur, wenn die Ebene ueberhaupt nichts nennt. Sonst
        // traegt die Aufzaehlung der ausgeschlossenen Modifier die Aussage
        // schon allein - "ohne Modifier, ohne Shift, Mod3" sagt zweimal
        // dasselbe.
        if (verlangt.length == 0 && ausgeschlossen.length == 0) text = "ohne Modifier";
        if (ausgeschlossen.length > 0) {
            text ~= (text.length == 0 ? "ohne " : ", ohne ");
            foreach (j, mod; ausgeschlossen) {
                text ~= (j == 0 ? "" : ", ") ~ modifierName(mod);
            }
        }
        info.modifiers = text;

        // Welcher Ausloeser fuehrt auf diese Ebene? Ueber determineLayer, also
        // ueber dieselbe Funktion, die auch das Verhalten bestimmt - nicht
        // ueber die Reihenfolge der Trigger geraten.
        foreach (t; triggers) {
            if (t.action != LockAction.SET_LOCK) continue;

            uint getroffen = determineLayer(layout.layers,
                                            (Modifier m) nothrow => false,
                                            t.lockSet,
                                            false,
                                            false);
            if (getroffen != info.number) continue;

            info.trigger = triggerChord(t);
            if (t.name.length > 0) info.trigger ~= " (" ~ t.name ~ ")";
            break;
        }

        infos ~= info;
    }

    return infos;
}

private string codepointText(const dchar[] codepoints) {
    string s;
    foreach (i, c; codepoints) {
        s ~= (i == 0 ? "" : " ") ~ format("U+%04X", cast(uint) c);
    }
    return s;
}

/// Vorbedingung: layout darf nicht null sein. Beide heutigen Aufrufer pruefen
/// das vorher (app.d: activeLayout-Guard vor erzeugeBelegungsblatt,
/// tool_main.d: layout kommt aus einer Iteration ueber layouts) - die Pruefung
/// hier ist die verstaendliche Fehlermeldung fuer den Fall, dass ein
/// zukuenftiger Aufrufer das vergisst, nicht ein neuer Regelfall.
string renderSheet(NeoLayout* layout, BoardLayout board, bool numberRow, bool numpad,
                   const(LockTrigger)[] triggers) {
    if (layout is null) {
        throw new Exception("renderSheet: layout ist null - Aufrufer muss vorher pruefen.");
    }

    auto geometrie = boardGeometry(board, numberRow, numpad);
    auto infos = layerInfos(layout, triggers);
    auto name = layout.name.to!string;

    // Brettmass in Tasteneinheiten, aus der Geometrie selbst abgeleitet statt
    // noch einmal hingeschrieben.
    float breite = 0, hoehe = 0;
    foreach (g; geometrie) {
        if (g.x + g.width > breite) breite = g.x + g.width;
        if (g.y + g.height > hoehe) hoehe = g.y + g.height;
    }

    // Das Blatt zeigt die Ebene, wie sie ohne gehaltene Tasten aussieht -
    // einmal deklariert, nicht je Taste neu.
    bool nichtsGehalten(Modifier m) nothrow { return false; }

    auto html = appender!string();
    html ~= sheetKopf(name, breite, hoehe);

    // Reiter. Ohne JavaScript unsichtbar, dann zeigt die Seite alle Ebenen
    // untereinander - also die Druckform.
    html ~= "<nav class=\"reiter\">";
    foreach (info; infos) {
        html ~= format("<button type=\"button\" data-ebene=\"%d\">%d</button>",
                       info.number, info.number);
    }
    html ~= "</nav>\n";

    foreach (info; infos) {
        html ~= format("<section class=\"ebene\" data-ebene=\"%d\">\n", info.number);
        html ~= format("<header><h2>Ebene %d</h2><p class=\"meta\">%s</p>%s</header>\n",
                       info.number,
                       htmlEscape(info.modifiers),
                       info.trigger.length > 0
                           ? format("<p class=\"meta\">Auslöser: %s</p>", htmlEscape(info.trigger))
                           : "");
        html ~= "<div class=\"brett\">\n";

        foreach (geo; geometrie) {
            auto view = describeKey(layout, geo.scancode, info.number, false,
                                    &nichtsGehalten, false);

            // Ob und wie eine Taste beschriftet ist, entscheidet
            // keyboardview.keyLabel - dieselbe Funktion, die auch osk.d
            // fragt. Vor Paket 5b stand die Regel hier noch einmal eigens.
            auto beschriftung = keyLabel(layout, view);
            if (!beschriftung.draw) continue;
            string label = beschriftung.text;

            // Die Gestaltung fragt, ob die Taste ein ZEICHEN erzeugt, nicht ob
            // das Layout sie als Zeichen abbildet. Die Grundebenen bilden
            // Buchstaben auf VK-Codes ab (siehe keyboardview.describeKey);
            // ohne diese Unterscheidung stuende die halbe Tastatur gedaempft da.
            string art;
            if (view.codepoints.length > 0) {
                art = "char";
            } else final switch (view.kind) {
                case KeyKind.CHAR:     art = "char";     break;
                case KeyKind.VKEY:     art = "vkey";     break;
                case KeyKind.MODIFIER: art = "modifier"; break;
                case KeyKind.EMPTY:    art = "leer";     break;
            }

            string zweiteZeile;
            if (view.codepoints.length > 0) {
                zweiteZeile = codepointText(view.codepoints);
            } else if (view.kind == KeyKind.VKEY) {
                zweiteZeile = vkName(view.vkCode);
            }

            html ~= format("<div class=\"taste art-%s%s\" data-scan=\"%02X%s\" "
                           ~ "style=\"--x:%g;--y:%g;--b:%g;--h:%g\">"
                           ~ "<span class=\"glyph\">%s</span>"
                           ~ "<span class=\"cp\">%s</span></div>\n",
                           art,
                           geo.shape == KeyShape.ISO_RETURN ? " iso-return" : "",
                           geo.scancode.scan,
                           geo.scancode.extended ? "e" : "",
                           geo.x, geo.y, geo.width, geo.height,
                           htmlEscape(label),
                           htmlEscape(zweiteZeile));
        }

        html ~= "</div>\n</section>\n";
    }

    html ~= sheetFuss();
    return html.data;
}

private string sheetKopf(string layoutName, float breite, float hoehe) {
    return format(`<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AnaNeo – Belegung %s</title>
<style>
:root {
  --paper: #F4F4F4;
  --ink: #0A0A0A;
  --muted: #575757;
  --line-soft: #C6C6C6;
  --accent: #2323D6;
  --display: "Archivo", system-ui, sans-serif;
  --body: system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  --mono: ui-monospace, "Cascadia Mono", Consolas, monospace;
  --u: 3.2rem;
}
@media screen and (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --paper: #1C1A1D; --ink: #E0DCDF; --muted: #9A9298;
    --line-soft: #383337; --accent: #A9C9E8;
  }
}
@media screen {
  :root[data-theme="dark"] {
    --paper: #1C1A1D; --ink: #E0DCDF; --muted: #9A9298;
    --line-soft: #383337; --accent: #A9C9E8;
  }
}
* { box-sizing: border-box; border-radius: 0; }
body {
  margin: 0; padding: 2rem 1.5rem 4rem;
  background: var(--paper); color: var(--ink);
  font-family: var(--body); font-size: 15px;
}
h1 { font-family: var(--display); font-weight: 700; font-size: 2rem;
     letter-spacing: -0.02em; line-height: 1.05; margin: 0 0 0.25rem; }
h2 { font-family: var(--display); font-weight: 640; font-size: 1.15rem;
     margin: 0; letter-spacing: -0.01em; }
.meta { font-family: var(--mono); font-size: 0.72rem; letter-spacing: 0.06em;
        color: var(--muted); margin: 0.15rem 0 0; }
.kopf { border-bottom: 2px solid var(--ink); padding-bottom: 0.75rem;
        margin-bottom: 1.5rem; }
.reiter { display: none; gap: 0; margin: 0 0 1.5rem;
          border-bottom: 1px solid var(--line-soft); }
html.js .reiter { display: flex; flex-wrap: wrap; }
.reiter button {
  font-family: var(--mono); font-size: 0.75rem; letter-spacing: 0.06em;
  background: none; border: 1px solid var(--line-soft); border-bottom: none;
  color: var(--muted); padding: 0.4rem 0.8rem; margin-right: -1px; cursor: pointer;
}
.reiter button[aria-current="true"] { color: var(--ink); border-color: var(--ink);
  border-bottom: 2px solid var(--accent); }
.reiter button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.ebene { margin: 0 0 2.5rem; }
.ebene header { border-bottom: 1px solid var(--line-soft);
                padding-bottom: 0.4rem; margin-bottom: 0.9rem; }
html.js .ebene { display: none; }
html.js .ebene.aktiv { display: block; }
.brett { position: relative; width: calc(%g * var(--u)); height: calc(%g * var(--u)); }
.taste {
  position: absolute;
  left: calc(var(--x) * var(--u)); top: calc(var(--y) * var(--u));
  width: calc(var(--b) * var(--u)); height: calc(var(--h) * var(--u));
  border: 1px solid var(--line-soft);
  display: flex; flex-direction: column; align-items: center; justify-content: center;
  overflow: hidden; padding: 0.1rem;
}
.glyph { font-size: calc(var(--u) * 0.39); line-height: 1.1; }
.cp { font-family: var(--mono); font-size: calc(var(--u) * 0.17); letter-spacing: 0.04em;
      color: var(--muted); margin-top: 0.15rem;
      max-width: 100%%; overflow-wrap: anywhere; line-height: 1.05; text-align: center; }
.art-char { border-left: 3px solid var(--accent); }
.art-vkey .glyph, .art-modifier .glyph { color: var(--muted); font-size: calc(var(--u) * 0.27); }
.art-modifier { background: var(--line-soft); }
.art-leer { border-style: dashed; }
.iso-return { border: none; }
.iso-return::before, .iso-return::after {
  content: ""; position: absolute;
  clip-path: polygon(0 0, 100%% 0, 100%% 100%%, 16.67%% 100%%, 16.67%% 50%%, 0 50%%);
}
.iso-return::before { inset: 0; background: var(--line-soft); }
.iso-return::after { inset: 1px; background: var(--paper); }
.iso-return .glyph, .iso-return .cp { position: relative; z-index: 1; }
@media print {
  :root { --paper: #F4F4F4; --ink: #0A0A0A; --muted: #575757;
          --line-soft: #C6C6C6; --accent: #2323D6;
          /* Aus der tatsaechlichen Brettbreite in Tasteneinheiten gerechnet,
             statt fest hingeschrieben - so passt das Blatt hochkant auf A4,
             mit UND ohne Nummernblock. 17 cm lassen Rand fuer die
             body-Polsterung, die im Druck ebenfalls kleiner wird. */
          --u: calc(17cm / %g); }
  body { padding: 0.6cm; }
  html.js .reiter { display: none; }
  html.js .ebene { display: block; }
  .ebene { break-inside: avoid; }
}
</style>
</head>
<body>
<div class="kopf">
<h1>AnaNeo – Belegung</h1>
<p class="meta">Layout %s</p>
</div>
`, htmlEscape(layoutName), breite, hoehe, breite, htmlEscape(layoutName));
}

private string sheetFuss() {
    // Das JavaScript schaltet ausschliesslich die Reiter. Ohne es zeigt die
    // Seite alle Ebenen untereinander - also genau die Druckform.
    return `<script>
document.documentElement.classList.add('js');
var reiter = document.querySelectorAll('.reiter button');
var ebenen = document.querySelectorAll('.ebene');
function zeige(nr) {
  ebenen.forEach(function (e) { e.classList.toggle('aktiv', e.dataset.ebene === nr); });
  reiter.forEach(function (b) {
    b.setAttribute('aria-current', b.dataset.ebene === nr ? 'true' : 'false');
  });
}
reiter.forEach(function (b) { b.addEventListener('click', function () { zeige(b.dataset.ebene); }); });
zeige('1');
</script>
</body>
</html>
`;
}

version (unittest) {
    import std.json : parseJSON;
    import std.algorithm : canFind, count;
    import layerlock : parseLockTriggers;
    import keysyms : initKeysyms;
}

unittest {
    // Vollstaendigkeit: Jede Taste, die im Layout steht und einen Platz in der
    // Geometrie hat, kommt im erzeugten HTML vor. Das ist die Eigenschaft, die
    // das Blatt ueberhaupt brauchbar macht - eine fehlende Taste faellt beim
    // Lesen nicht auf.
    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestBlatt",
        "modifiers": {"2A": "LShift", "3A": "Mod3"},
        "layers": [{"Shift": false}, {"Shift": true}],
        "capslockableKeys": ["10"],
        "map": {
            "10": [{"char": "a", "label": "a"}, {"char": "A", "label": "A"}],
            "11": [{"vk": "VK_DELETE", "label": "⌦"}, {}],
            "12": [{"char": "𝔄"}, {}]
        }
    }]`);
    initLayouts(json);

    auto html = renderSheet(&layouts[0], BoardLayout.ISO, true, false, []);

    foreach (scan; ["10", "11", "12", "2A", "3A"]) {
        assert(html.canFind(`data-scan="` ~ scan ~ `"`),
               "Taste " ~ scan ~ " fehlt im Blatt");
    }

    // Eine Ebene, ein Abschnitt
    assert(html.count(`class="ebene`) == 2);

    // Zeichen jenseits der BMP: Glyph UND Codepunkt
    assert(html.canFind("𝔄"));
    assert(html.canFind("U+1D504"));

    // VK-Taste: Tastenname statt Codepunkt
    assert(html.canFind("VK_DELETE"));
    assert(!html.canFind("U+0000"));
}

unittest {
    // In sich geschlossen: keine externen Verweise, sonst zeigt das Blatt auf
    // einem Rechner ohne Netz etwas anderes als auf dem, wo es entstand.
    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestGeschlossen",
        "modifiers": {},
        "layers": [{"Shift": false}],
        "capslockableKeys": [],
        "map": {"10": [{"char": "a"}]}
    }]`);
    initLayouts(json);

    auto html = renderSheet(&layouts[0], BoardLayout.ISO, true, false, []);

    foreach (verboten; ["http://", "https://", "<link", "<img", "src="]) {
        assert(!html.canFind(verboten), "Externer Verweis im Blatt: " ~ verboten);
    }
}

unittest {
    // Beschriftungen aus layouts.json landen im HTML und muessen maskiert
    // werden - ein Layout darf die Seite nicht zerlegen koennen.
    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestMaskierung",
        "modifiers": {},
        "layers": [{"Shift": false}],
        "capslockableKeys": [],
        "map": {"10": [{"char": "<", "label": "<b>&"}]}
    }]`);
    initLayouts(json);

    auto html = renderSheet(&layouts[0], BoardLayout.ISO, true, false, []);

    assert(html.canFind("&lt;b&gt;&amp;"));
    assert(!html.canFind("<b>&"));
}

unittest {
    // Kopfzeile: Ebenennummer, Modifier-Definition und der Ausloeser aus der
    // Konfiguration. Der Ausloeser wird ueber determineLayer zugeordnet, nicht
    // ueber die Reihenfolge der Trigger - dieselbe Funktion, die auch das
    // Verhalten bestimmt.
    scope(exit) resetLayoutsForTest();

    auto json = parseJSON(`[{
        "name": "TestKopf",
        "modifiers": {"3A": "Mod3"},
        "layers": [
            {"Shift": false, "Mod3": false, "Mod4": false},
            {"Shift": false, "Mod3": true, "Mod4": true}
        ],
        "capslockableKeys": [],
        "map": {"10": [{"char": "a"}, {"char": "b"}]}
    }]`);
    initLayouts(json);

    auto trigger = parseLockTriggers(parseJSON(`{
        "oskAutoShow": false,
        "triggers": [
            { "chord": "Mod3+F2", "lock": ["Mod3", "Mod4"], "name": "Mathematik" }
        ]
    }`));

    auto infos = layerInfos(&layouts[0], trigger);
    assert(infos.length == 2);
    assert(infos[0].number == 1);
    assert(infos[0].trigger.length == 0, "Ebene 1 hat keinen Ausloeser");
    // Ebene 1 verlangt nichts, schliesst aber Shift, Mod3 und Mod4 aus - die
    // Aufzaehlung traegt die Aussage schon allein, "ohne Modifier, ohne ..."
    // sagte doppelt.
    assert(infos[0].modifiers == "ohne Shift, Mod3, Mod4",
           "Kopfzeile Ebene 1: " ~ infos[0].modifiers);
    assert(infos[1].trigger.canFind("Mod3+F2"));
    assert(infos[1].trigger.canFind("Mathematik"));
    assert(infos[1].modifiers.canFind("Mod3"));
    assert(infos[1].modifiers.canFind("Mod4"));

    auto html = renderSheet(&layouts[0], BoardLayout.ISO, true, false, trigger);
    assert(html.canFind("Mod3+F2"));
}

unittest {
    // Eine VK-Taste, die ein Zeichen erzeugt, gehoert auf dem Blatt zu den
    // Zeichentasten: Akzentbalken und Codepunkt, nicht der VK-Name. Vor
    // Paket 5c stand unter jedem Buchstaben der Grundebene "VK_KEY_E".
    scope(exit) resetLayoutsForTest();
    initKeysyms(".");

    auto json = parseJSON(`[{
        "name": "TestVKZeichen",
        "modifiers": {},
        "layers": [{"Shift": false}],
        "capslockableKeys": [],
        "map": {
            "21": [{"keysym": "e", "vk": "VK_KEY_E", "label": "e"}],
            "0F": [{"keysym": "Tab", "vk": "VK_TAB", "label": "↹"}]
        }
    }]`);
    initLayouts(json);

    auto html = renderSheet(&layouts[0], BoardLayout.ISO, true, false, []);

    // Der Buchstabe traegt seinen Codepunkt und die Zeichentasten-Klasse
    assert(html.canFind("U+0065"));
    assert(!html.canFind("VK_KEY_E"));

    // Die Funktionstaste behaelt ihren Tastennamen
    assert(html.canFind("VK_TAB"));
}
