module html;

import std.array : replace;

/// HTML-Maskierung fuer alles, was aus Daten kommt - Beschriftungen aus
/// layouts.json, Sequenzen aus den .module-Dateien, Unicode-Namen. Liegt in
/// einem eigenen Modul, weil sowohl das Belegungsblatt (sheet.d) als auch der
/// Compose-Bericht (composereport.d) sie brauchen und keines von beiden vom
/// anderen abhaengen soll.
string htmlEscape(string s) {
    return s.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;");
}
