# Herkunft der Unicode-Stammdaten

- `UnicodeData.txt` und `Blocks.txt` stammen aus dem Unicode Character Database.
- **Version: UCD 17.0.0**
- Quelle: <https://www.unicode.org/Public/17.0.0/ucd/>
- Abgerufen: 02.08.2026

Die Version ist **festgeschrieben**. Es gibt kein automatisches Nachziehen: Ein
Versionssprung verschiebt die Abdeckungszahlen des Compose-Berichts, ohne dass
sich am Compose-Bestand etwas geaendert haette. Wer aktualisiert, tut das
bewusst, taucht beide Dateien zusammen aus und schreibt die neue Version hier
und im Bericht fest.

Die Dateien landen **nicht** im Release-ZIP: `.github/workflows/release.yml`
packt ueber eine Positivliste, in der `data` nicht steht.

Lizenz: Unicode License v3 (siehe <https://www.unicode.org/license.txt>).
