module cmap;

/// Die Zeichenzuordnung einer Schrift: Codepunkt -> Glyph-Index. Reine
/// Byte-Arithmetik ueber die cmap-Tabelle, kein Win32 und kein Cairo, damit sie
/// sich gegen die mitgelieferte Schriftdatei testen laesst - auch dort, wo es
/// keine Windows-Schriften gibt (tools/verify-linux.sh unter Wine).
///
/// Warum ueberhaupt selbst gelesen: ScriptGetCMap liefert fuer Zeichen jenseits
/// der BMP in keiner Schrift einen echten Glyphen, sondern nur den Leerglyphen
/// (gemessen am 31.07.2026 ueber zehn Schriften), obwohl die cmap-Tabelle den
/// Glyphen fuehrt - fuer U+1D504 etwa den Index 7721 in Segoe UI Symbol.
struct CmapTable {
    private CmapFormat kind = CmapFormat.none;

    // Format 12: eine Liste aufsteigend sortierter Gruppen zusammenhaengender
    // Codepunkte.
    private immutable(Format12Gruppe)[] gruppen;

    // Format 4: die vier parallelen Segment-Tabellen, dazu eine Kopie der
    // Untertabelle selbst - idRangeOffset zeigt als Byte-Offset relativ auf
    // sich selbst in Richtung glyphIdArray, siehe glyphFor4.
    private immutable(ushort)[] endCode;
    private immutable(ushort)[] startCode;
    private immutable(short)[] idDelta;
    private immutable(ushort)[] idRangeOffset;
    private immutable(ubyte)[] untertabelle;
    private size_t idRangeOffsetPos;  // Position von idRangeOffset[0] in untertabelle

    /// Konnte eine brauchbare Untertabelle (Format 12 oder 4) gefunden werden?
    bool valid() const pure nothrow {
        return kind != CmapFormat.none;
    }

    /// Glyph-Index oder 0, wenn die Schrift diesen Codepunkt nicht fuehrt.
    ushort glyphFor(dchar codepunkt) const pure nothrow {
        final switch (kind) {
            case CmapFormat.none:     return 0;
            case CmapFormat.format12: return glyphFor12(codepunkt);
            case CmapFormat.format4:  return glyphFor4(codepunkt);
        }
    }

    private ushort glyphFor12(dchar codepunkt) const pure nothrow {
        uint cp = cast(uint) codepunkt;
        // Die Gruppen sind aufsteigend sortiert - lineare Suche genuegt (siehe
        // Task-Brief), Schriften fuehren keine tausenden Gruppen.
        foreach (g; gruppen) {
            if (cp < g.startCharCode || cp > g.endCharCode) continue;
            return cast(ushort) (g.startGlyphID + (cp - g.startCharCode));
        }
        return 0;
    }

    private ushort glyphFor4(dchar codepunkt) const pure nothrow {
        if (codepunkt > 0xFFFF) return 0;  // Format 4 kennt nur die BMP
        ushort cp = cast(ushort) codepunkt;

        foreach (i; 0 .. endCode.length) {
            if (cp > endCode[i]) continue;
            if (cp < startCode[i]) return 0;  // Luecke zwischen Segmenten

            if (idRangeOffset[i] == 0) {
                return cast(ushort) ((cp + idDelta[i]) & 0xFFFF);
            }

            size_t adresse = idRangeOffsetPos + i * 2 + idRangeOffset[i]
                            + 2 * (cp - startCode[i]);
            if (adresse + 2 > untertabelle.length) return 0;  // kaputte Tabelle
            ushort roh = readU16(untertabelle, adresse);
            if (roh == 0) return 0;  // Loch im glyphIdArray
            return cast(ushort) ((roh + idDelta[i]) & 0xFFFF);
        }
        return 0;
    }
}

private enum CmapFormat { none, format4, format12 }

private struct Format12Gruppe {
    uint startCharCode;
    uint endCharCode;
    uint startGlyphID;
}

/// Prueft, ob sich laenge Byte ab offset lesen lassen, ohne den Puffer zu
/// verlassen. JEDER Zugriff unten geht durch diese Pruefung, bevor er liest -
/// eine abgeschnittene oder unsinnige Tabelle darf nie einen RangeError werfen.
private bool canRead(const(ubyte)[] puffer, size_t offset, size_t laenge) pure nothrow {
    return offset <= puffer.length && laenge <= puffer.length - offset;
}

/// Nur nach canRead(puffer, offset, 2) aufrufen.
private ushort readU16(const(ubyte)[] puffer, size_t offset) pure nothrow {
    return cast(ushort) ((puffer[offset] << 8) | puffer[offset + 1]);
}

/// Nur nach canRead(puffer, offset, 4) aufrufen.
private uint readU32(const(ubyte)[] puffer, size_t offset) pure nothrow {
    return (cast(uint) puffer[offset]     << 24)
         | (cast(uint) puffer[offset + 1] << 16)
         | (cast(uint) puffer[offset + 2] << 8)
         |  cast(uint) puffer[offset + 3];
}

/// Parst die cmap-Tabelle einer Schrift. Erwartet den INHALT der Tabelle, nicht
/// die ganze Schriftdatei - GetFontData liefert genau das.
CmapTable parseCmap(const(ubyte)[] tabelle) nothrow {
    CmapTable leer;

    // cmap-Kopf: version(2) numTables(2) = 4 Byte
    if (!canRead(tabelle, 0, 4)) return leer;
    ushort numTables = readU16(tabelle, 2);

    size_t bestOffset;
    CmapFormat bestFormat = CmapFormat.none;
    bool bestBevorzugt;  // hat die aktuell beste Untertabelle eine bevorzugte Kodierung?

    foreach (i; 0 .. numTables) {
        // Verzeichniseintrag: platformID(2) encodingID(2) offset(4) = 8 Byte
        size_t eintrag = 4 + i * 8;
        if (!canRead(tabelle, eintrag, 8)) break;  // Verzeichnis endet vorzeitig

        ushort platformID = readU16(tabelle, eintrag);
        ushort encodingID = readU16(tabelle, eintrag + 2);
        uint subOffset = readU32(tabelle, eintrag + 4);
        if (!canRead(tabelle, subOffset, 2)) continue;  // Untertabelle nicht erreichbar

        ushort format = readU16(tabelle, subOffset);
        if (format != 12 && format != 4) continue;

        // Bevorzugte Kodierungen je Format: Windows-Unicode (3,10 bzw. 3,1)
        // oder der volle bzw. BMP-Unicode-Zweig (0,4 bzw. 0,3). Eine
        // Symbolkodierung (3,0) verschiebt Codepunkte nach U+F000-F0FF und
        // liefert sonst nichts - ohne diese Bevorzugung koennte sie eine
        // spaeter im Verzeichnis stehende, richtige Untertabelle verdecken.
        bool bevorzugt = format == 12
            ? (platformID == 3 && encodingID == 10) || (platformID == 0 && encodingID == 4)
            : (platformID == 3 && encodingID == 1)  || (platformID == 0 && encodingID == 3);

        CmapFormat kandidatFormat = format == 12 ? CmapFormat.format12 : CmapFormat.format4;

        // Format 12 schlaegt Format 4 immer; innerhalb eines Formats gewinnt
        // die bevorzugte Kodierung, sonst bleibt die zuerst gefundene.
        bool besser = bestFormat == CmapFormat.none
            || (kandidatFormat == CmapFormat.format12 && bestFormat == CmapFormat.format4)
            || (kandidatFormat == bestFormat && bevorzugt && !bestBevorzugt);

        if (besser) {
            bestOffset = subOffset;
            bestFormat = kandidatFormat;
            bestBevorzugt = bevorzugt;
        }

        if (bestFormat == CmapFormat.format12 && bestBevorzugt) break;  // besser geht es nicht mehr
    }

    final switch (bestFormat) {
        case CmapFormat.none:     return leer;
        case CmapFormat.format12: return parseFormat12(tabelle, bestOffset);
        case CmapFormat.format4:  return parseFormat4(tabelle, bestOffset);
    }
}

private CmapTable parseFormat12(const(ubyte)[] tabelle, size_t offset) nothrow {
    CmapTable leer;
    // Kopf: format(2) reserved(2) length(4) language(4) nGroups(4) = 16 Byte
    if (!canRead(tabelle, offset, 16)) return leer;

    uint nGroups = readU32(tabelle, offset + 12);
    size_t gruppenStart = offset + 16;
    size_t gruppenBytes = cast(size_t) nGroups * 12;
    if (!canRead(tabelle, gruppenStart, gruppenBytes)) return leer;

    Format12Gruppe[] gruppen;
    foreach (i; 0 .. nGroups) {
        size_t g = gruppenStart + i * 12;
        gruppen ~= Format12Gruppe(
            readU32(tabelle, g),
            readU32(tabelle, g + 4),
            readU32(tabelle, g + 8)
        );
    }

    CmapTable ergebnis;
    ergebnis.kind = CmapFormat.format12;
    ergebnis.gruppen = gruppen.idup;
    return ergebnis;
}

private CmapTable parseFormat4(const(ubyte)[] tabelle, size_t offset) nothrow {
    CmapTable leer;
    // Kopf: format,length,language,segCountX2,searchRange,entrySelector,
    // rangeShift, je ushort = 14 Byte
    if (!canRead(tabelle, offset, 14)) return leer;

    ushort segCountX2 = readU16(tabelle, offset + 6);
    size_t segCount = segCountX2 / 2;

    size_t endCodeStart = offset + 14;
    if (!canRead(tabelle, endCodeStart, segCount * 2)) return leer;

    size_t startCodeStart = endCodeStart + segCount * 2 + 2;  // + reservedPad
    if (!canRead(tabelle, startCodeStart, segCount * 2)) return leer;

    size_t idDeltaStart = startCodeStart + segCount * 2;
    if (!canRead(tabelle, idDeltaStart, segCount * 2)) return leer;

    size_t idRangeOffsetStart = idDeltaStart + segCount * 2;
    if (!canRead(tabelle, idRangeOffsetStart, segCount * 2)) return leer;

    ushort[] endCode, startCode, idRangeOffset;
    short[] idDelta;
    foreach (i; 0 .. segCount) {
        endCode ~= readU16(tabelle, endCodeStart + i * 2);
        startCode ~= readU16(tabelle, startCodeStart + i * 2);
        idDelta ~= cast(short) readU16(tabelle, idDeltaStart + i * 2);
        idRangeOffset ~= readU16(tabelle, idRangeOffsetStart + i * 2);
    }

    CmapTable ergebnis;
    ergebnis.kind = CmapFormat.format4;
    ergebnis.endCode = endCode.idup;
    ergebnis.startCode = startCode.idup;
    ergebnis.idDelta = idDelta.idup;
    ergebnis.idRangeOffset = idRangeOffset.idup;
    // Kopie ab dem Beginn DIESER Untertabelle: idRangeOffset-Werte sind relativ
    // dazu zu verstehen, glyphFor4 braucht den Rohpuffer dafuer weiterhin.
    ergebnis.untertabelle = tabelle[offset .. $].idup;
    ergebnis.idRangeOffsetPos = idRangeOffsetStart - offset;
    return ergebnis;
}

/// Sucht eine Tabelle im sfnt-Verzeichnis einer vollstaendigen Schriftdatei.
/// Nur fuer Tests und Werkzeuge - im Betrieb liefert GetFontData die Tabelle
/// direkt. Leeres Ergebnis, wenn die Datei die Tabelle nicht fuehrt.
const(ubyte)[] sfntTable(const(ubyte)[] schriftdatei, string tag) nothrow {
    if (tag.length != 4) return [];

    // sfnt-Kopf: sfntVersion(4) numTables(2) searchRange(2) entrySelector(2)
    // rangeShift(2) = 12 Byte, danach numTables Eintraege zu je 16 Byte.
    if (!canRead(schriftdatei, 0, 12)) return [];
    ushort numTables = readU16(schriftdatei, 4);

    foreach (i; 0 .. numTables) {
        size_t eintrag = 12 + i * 16;
        if (!canRead(schriftdatei, eintrag, 16)) break;  // Verzeichnis endet vorzeitig

        if (schriftdatei[eintrag]     == cast(ubyte) tag[0]
         && schriftdatei[eintrag + 1] == cast(ubyte) tag[1]
         && schriftdatei[eintrag + 2] == cast(ubyte) tag[2]
         && schriftdatei[eintrag + 3] == cast(ubyte) tag[3]) {

            uint tabOffset = readU32(schriftdatei, eintrag + 8);
            uint tabLaenge = readU32(schriftdatei, eintrag + 12);
            if (!canRead(schriftdatei, tabOffset, tabLaenge)) return [];
            return schriftdatei[tabOffset .. tabOffset + tabLaenge];
        }
    }

    return [];
}

version (unittest) {
    // Kleine Bausteine, um die synthetischen Testtabellen big-endian und
    // lesbar zu bauen - ein Feld, ein Ausdruck, ein Kommentar.
    private ubyte[] be16(ushort wert) pure nothrow {
        return [cast(ubyte) (wert >> 8), cast(ubyte) (wert & 0xFF)];
    }

    private ubyte[] be32(uint wert) pure nothrow {
        return [cast(ubyte) (wert >> 24), cast(ubyte) (wert >> 16),
                cast(ubyte) (wert >> 8),  cast(ubyte) (wert & 0xFF)];
    }
}

unittest {
    // 1. Format 12 synthetisch: zwei Gruppen mit Luecke dazwischen.
    ubyte[] tabelle;
    tabelle ~= be16(0);   // cmap version
    tabelle ~= be16(1);   // numTables

    tabelle ~= be16(3);   // platformID (Windows)
    tabelle ~= be16(10);  // encodingID (UCS-4)
    tabelle ~= be32(12);  // offset zur Untertabelle (Kopf+Verzeichnis = 12 Byte)

    tabelle ~= be16(12);  // format
    tabelle ~= be16(0);   // reserved
    tabelle ~= be32(0);   // length (wird von parseCmap nicht ausgewertet)
    tabelle ~= be32(0);   // language
    tabelle ~= be32(2);   // nGroups

    tabelle ~= be32(0x1000); tabelle ~= be32(0x1005); tabelle ~= be32(100);
    // Gruppe 1: Codepunkte 0x1000..0x1005 -> Glyphen 100..105

    tabelle ~= be32(0x2000); tabelle ~= be32(0x2002); tabelle ~= be32(500);
    // Gruppe 2: Codepunkte 0x2000..0x2002 -> Glyphen 500..502

    auto cmap = parseCmap(tabelle);
    assert(cmap.valid);
    assert(cmap.glyphFor(0x1000) == 100);  // Anfang der ersten Gruppe
    assert(cmap.glyphFor(0x1002) == 102);  // Mitte der ersten Gruppe
    assert(cmap.glyphFor(0x1005) == 105);  // Ende der ersten Gruppe
    assert(cmap.glyphFor(0x1500) == 0);    // Luecke zwischen den Gruppen
}

unittest {
    // 2. Format 4 synthetisch: ein direktes Segment (idRangeOffset == 0), ein
    // Segment ueber glyphIdArray (mit einem Loch), dazu das Abschlusssegment
    // 0xFFFF, das jede Format-4-Tabelle traegt.
    ubyte[] sub;

    // -- Kopf (14 Byte) --
    sub ~= be16(4);   // format
    sub ~= be16(0);   // length (wird nicht ausgewertet)
    sub ~= be16(0);   // language
    sub ~= be16(6);   // segCountX2 (3 Segmente)
    sub ~= be16(0);   // searchRange (ungenutzt)
    sub ~= be16(0);   // entrySelector (ungenutzt)
    sub ~= be16(0);   // rangeShift (ungenutzt)

    // -- endCode[3] --
    sub ~= be16(0x0045);  // Segment A endet bei 'E'
    sub ~= be16(0x0102);  // Segment B endet bei 0x102
    sub ~= be16(0xFFFF);  // Abschlusssegment

    sub ~= be16(0);        // reservedPad

    // -- startCode[3] --
    sub ~= be16(0x0041);  // Segment A beginnt bei 'A'
    sub ~= be16(0x0100);  // Segment B beginnt bei 0x100
    sub ~= be16(0xFFFF);  // Abschlusssegment

    // -- idDelta[3] (signed) --
    sub ~= be16(10);  // Segment A: Glyph = Codepunkt + 10, direkter Weg
    sub ~= be16(0);   // Segment B: Delta wirkt erst nach dem glyphIdArray-Wert
    sub ~= be16(1);   // Abschlusssegment (Konvention)

    // -- idRangeOffset[3] --
    sub ~= be16(0);   // Segment A: direkter Weg, kein Array
    sub ~= be16(4);   // Segment B: 4 Byte hinter sich selbst beginnt glyphIdArray
    sub ~= be16(0);   // Abschlusssegment

    // -- glyphIdArray: drei Eintraege fuer Segment B (0x100, 0x101, 0x102) --
    sub ~= be16(200);  // 0x100 -> 200
    sub ~= be16(0);    // 0x101 -> Loch, bleibt 0
    sub ~= be16(300);  // 0x102 -> 300

    ubyte[] tabelle;
    tabelle ~= be16(0);   // cmap version
    tabelle ~= be16(1);   // numTables
    tabelle ~= be16(3);   // platformID (Windows)
    tabelle ~= be16(1);   // encodingID (BMP)
    tabelle ~= be32(12);  // offset zur Untertabelle
    tabelle ~= sub;

    auto cmap = parseCmap(tabelle);
    assert(cmap.valid);
    assert(cmap.glyphFor(0x41) == 75);    // direkter Weg: 0x41 + idDelta 10
    assert(cmap.glyphFor(0x100) == 200);  // ueber glyphIdArray
    assert(cmap.glyphFor(0x101) == 0);    // Loch im glyphIdArray
    assert(cmap.glyphFor(0x1F063) == 0);  // jenseits der BMP kennt Format 4 nicht
}

unittest {
    // 3. Kaputte Eingaben duerfen niemals werfen, nur ungueltig sein.
    assert(!parseCmap([]).valid);                    // leere Tabelle
    assert(parseCmap([]).glyphFor('A') == 0);

    ubyte[] abgeschnitten = [0, 0, 0];                // kuerzer als der cmap-Kopf (4 Byte)
    assert(!parseCmap(abgeschnitten).valid);
    assert(parseCmap(abgeschnitten).glyphFor('A') == 0);

    ubyte[] falscheAnzahl = be16(0) ~ be16(5);        // numTables=5, kein Eintrag folgt
    assert(!parseCmap(falscheAnzahl).valid);
    assert(parseCmap(falscheAnzahl).glyphFor('A') == 0);
}

unittest {
    // 4. Gegen die im Repo liegende Schrift: acht Sollwerte, gemessen am
    // 31.07.2026 (siehe Nachtrag zu Task 2).
    import std.file : read;
    import std.path : buildPath;

    auto daten = cast(ubyte[]) read(buildPath("fonts", "NotoSansSymbols2-Regular.ttf"));
    auto tabelle = sfntTable(daten, "cmap");
    assert(tabelle.length > 0, "keine cmap-Tabelle in der mitgelieferten Schrift gefunden");

    auto cmap = parseCmap(tabelle);
    assert(cmap.valid);

    assert(cmap.glyphFor('\U0001FA00') == 2196);  // Schach
    assert(cmap.glyphFor('\U0001F774') == 2652);  // Alchemie
    assert(cmap.glyphFor('♞') == 1645);       // BMP-Springer
    assert(cmap.glyphFor('\U0001F063') == 2035);   // Domino
    assert(cmap.glyphFor('\U0001F0A1') == 2085);   // Spielkarte
    assert(cmap.glyphFor('\U0001F004') == 1714);   // Mahjong
    assert(cmap.glyphFor('A') == 0);                // "A" - diese Schrift fuehrt kein Latein
    assert(cmap.glyphFor('\U0001D504') == 0);       // Fraktur-A - deckt Segoe UI Symbol ab
}

unittest {
    // 5. Bevorzugung nach Kodierung, nicht nur nach Format (Fund "Klein 7" der
    // Abschlusspruefung von Paket 5b): Eine Symbolkodierung (3,0), die zuerst
    // im Verzeichnis steht, darf eine spaeter stehende Windows-Unicode-
    // Kodierung (3,1) nicht verdecken - beides Format 4, minimal und direkt
    // (idRangeOffset 0), je ein Segment plus Abschlusssegment 0xFFFF.
    ubyte[] minimalesFormat4(dchar cp, ushort glyph) {
        ubyte[] sub;
        sub ~= be16(4);   // format
        sub ~= be16(0);   // length (wird nicht ausgewertet)
        sub ~= be16(0);   // language
        sub ~= be16(4);   // segCountX2 (2 Segmente: eins echt, eins Abschluss)
        sub ~= be16(0); sub ~= be16(0); sub ~= be16(0);  // ungenutzt

        sub ~= be16(cast(ushort) cp); sub ~= be16(0xFFFF);              // endCode
        sub ~= be16(0);                                                  // reservedPad
        sub ~= be16(cast(ushort) cp); sub ~= be16(0xFFFF);              // startCode
        sub ~= be16(cast(ushort) (glyph - cast(ushort) cp)); sub ~= be16(1);  // idDelta
        sub ~= be16(0); sub ~= be16(0);                                  // idRangeOffset (direkter Weg)
        return sub;
    }

    auto symbolSub = minimalesFormat4('A', 111);
    auto bevorzugtSub = minimalesFormat4('A', 222);

    size_t offsetSymbol = 4 + 2 * 8;
    size_t offsetBevorzugt = offsetSymbol + symbolSub.length;

    ubyte[] tabelle;
    tabelle ~= be16(0);   // cmap version
    tabelle ~= be16(2);   // numTables

    tabelle ~= be16(3); tabelle ~= be16(0); tabelle ~= be32(cast(uint) offsetSymbol);
    // (3,0) Symbolkodierung, steht zuerst im Verzeichnis
    tabelle ~= be16(3); tabelle ~= be16(1); tabelle ~= be32(cast(uint) offsetBevorzugt);
    // (3,1) Windows-Unicode, bevorzugt - obwohl sie spaeter im Verzeichnis steht

    tabelle ~= symbolSub;
    tabelle ~= bevorzugtSub;

    auto cmap = parseCmap(tabelle);
    assert(cmap.valid);
    assert(cmap.glyphFor('A') == 222,
           "die bevorzugte (3,1)-Kodierung haette gewinnen muessen, nicht (3,0)");
}
