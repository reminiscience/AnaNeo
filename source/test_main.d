module test_main;

// Wird nur in der dub-Konfiguration "unittest" mitgebaut und ersetzt dort die
// Win32-main aus app.d. Die D-Laufzeit führt vor main alle unittest-Blöcke aus
// und beendet den Prozess anschließend, ohne diese main überhaupt aufzurufen.
version (unittest) {
    void main() {
    }
}
