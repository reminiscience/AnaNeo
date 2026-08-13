#!/usr/bin/env bash
#
# Bauen, Testen und Linten von AnaNeo auf einem Linux-Rechner ohne dub.
#
# Warum es das gibt: AnaNeo ist eine Win32-Anwendung, gebaut mit dub und DMD
# auf Windows. Eine Claude-Code-Web-Sitzung laeuft aber in einem Linux-
# Container; ohne dieses Skript kann sie ihre Aenderungen nur behaupten, nicht
# pruefen. Das Skript stellt die drei Abnahmekriterien aus CLAUDE.md nach:
#
#   dub build --build=release  ->  Cross-Build mit LDC + lld-link
#   dub test                   ->  derselbe Build mit -unittest, unter Wine
#   dub lint                   ->  selbst gebautes D-Scanner
#
# Der Weg dorthin: LDC uebersetzt mit --mtriple=x86_64-pc-windows-msvc, lld-link
# linkt gegen druntime/phobos aus dem LDC-Windows-Paket, die Win32-Importbibs
# aus demselben Paket und die CRT aus mingw-w64. Wine fuehrt das Ergebnis aus.
#
# Das ist ausdruecklich ein Ersatz, kein Ersatz fuer die Abnahme: andere
# Toolchain (LDC statt DMD), andere CRT (MinGW-UCRT statt MSVC) und Wine statt
# Windows. Was hier gruen ist, kann auf dem Windows-Rechner trotzdem
# scheitern - und die Hook-, Modifier- und Sendelogik bleibt ohnehin manuell
# zu verifizieren (siehe CLAUDE.md).
#
# Aufruf:
#   tools/verify-linux.sh setup    # einmalig: Pakete, LDC-Windows-Paket, D-Scanner
#   tools/verify-linux.sh build    # Anwendung linken
#   tools/verify-linux.sh test     # Unittests unter Wine
#   tools/verify-linux.sh lint     # D-Scanner
#   tools/verify-linux.sh all      # build + test + lint
#
# Braucht Netzzugang zu github.com (LDC-Release, D-Scanner) und zu den
# Ubuntu-Paketquellen. Alles Heruntergeladene landet unter $WORKDIR, per
# Vorgabe ausserhalb des Repos.

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKDIR=${WORKDIR:-${TMPDIR:-/tmp}/ananeo-verify}
LDC_VERSION=${LDC_VERSION:-1.36.0}
LDC_DIR=$WORKDIR/ldc2-$LDC_VERSION-windows-multilib
DSCANNER=$WORKDIR/dscanner/bin/dscanner

mkdir -p "$WORKDIR"

step() { printf '\n== %s ==\n' "$1"; }
die()  { printf 'FEHLER: %s\n' "$1" >&2; exit 1; }

# --------------------------------------------------------------------------
# setup
# --------------------------------------------------------------------------

do_setup() {
    step "Systempakete"
    # ldc      - der native D-Compiler, cross-uebersetzt nach Windows
    # lld      - liefert lld-link, den COFF-Linker
    # mingw-w64 - liefert die C-Laufzeit (ucrt, mingwex) und das Startobjekt
    # wine64   - fuehrt das Ergebnis aus
    # p7zip-full - entpackt das LDC-Windows-Paket (.7z)
    apt-get update -q || die "apt-get update fehlgeschlagen"
    apt-get install -y -q ldc lld mingw-w64 wine64 p7zip-full git \
        || die "apt-get install fehlgeschlagen"

    step "LDC-Windows-Paket $LDC_VERSION"
    # Enthaelt druntime und phobos fuer x86_64-windows-msvc sowie die
    # Win32-Importbibliotheken unter lib64/mingw. Das Ubuntu-ldc-Paket bringt
    # nur die Linux-Bibliotheken mit, deshalb dieser Download.
    if [ ! -d "$LDC_DIR" ]; then
        local archive=$WORKDIR/ldc-win.7z
        [ -f "$archive" ] || curl -fsSL -o "$archive" \
            "https://github.com/ldc-developers/ldc/releases/download/v$LDC_VERSION/ldc2-$LDC_VERSION-windows-multilib.7z" \
            || die "LDC-Windows-Paket nicht ladbar"
        (cd "$WORKDIR" && 7z x -y "$archive" > /dev/null) || die "Entpacken fehlgeschlagen"
    fi

    step "libmingw32 ohne crtexewin"
    # libmingw32.a enthaelt crtexewin.o, das ein main definiert, welches
    # WinMain aufruft. Es gewinnt gegen das wmain aus druntime, wodurch das
    # Programm ohne Ausgabe und mit Rueckgabewert 0 endet - der Testlauf
    # saehe erfolgreich aus, ohne einen einzigen Test ausgefuehrt zu haben.
    # Deshalb ein Archiv ohne diese beiden Objekte.
    if [ ! -f "$WORKDIR/mingwfix/libmingw32fix.a" ]; then
        rm -rf "$WORKDIR/mingwfix"; mkdir -p "$WORKDIR/mingwfix"
        (cd "$WORKDIR/mingwfix" \
            && ar x /usr/x86_64-w64-mingw32/lib/libmingw32.a \
            && rm -f ./*crtexewin*.o \
            && ar rcs libmingw32fix.a ./*.o) || die "libmingw32 umbauen fehlgeschlagen"
    fi

    step "Shim-Objekt"
    # _fltused erwartet die MSVC-Welt von jedem Modul mit Gleitkomma; die
    # MinGW-CRT liefert es nicht.
    cat > "$WORKDIR/shim.d" <<'EOF'
module shim;
extern(C) __gshared int _fltused = 0;
EOF
    ldc2 -c --mtriple=x86_64-pc-windows-msvc -conf= -I="$LDC_DIR/import" \
        "$WORKDIR/shim.d" -of="$WORKDIR/shim.obj" || die "Shim nicht uebersetzbar"

    step "D-Scanner"
    if [ ! -x "$DSCANNER" ]; then
        [ -d "$WORKDIR/dscanner" ] || git clone --recurse-submodules \
            https://github.com/dlang-community/D-Scanner.git "$WORKDIR/dscanner" \
            || die "D-Scanner nicht klonbar"
        (cd "$WORKDIR/dscanner" && make DC=ldc2 -j"$(nproc)" > "$WORKDIR/dscanner-build.log" 2>&1) \
            || die "D-Scanner-Build fehlgeschlagen, siehe $WORKDIR/dscanner-build.log"
    fi

    printf '\nSetup fertig. Arbeitsverzeichnis: %s\n' "$WORKDIR"
}

# --------------------------------------------------------------------------
# gemeinsamer Cross-Build
# --------------------------------------------------------------------------

check_setup() {
    [ -d "$LDC_DIR/lib64" ] || die "LDC-Windows-Paket fehlt - erst 'setup' aufrufen"
    [ -f "$WORKDIR/shim.obj" ] || die "Shim fehlt - erst 'setup' aufrufen"
    command -v lld-link > /dev/null || die "lld-link fehlt - erst 'setup' aufrufen"
}

# compile <objdir> <extra-ldc-flags...> -- <quelldateien...>
compile() {
    local objdir=$1; shift
    rm -rf "$objdir"; mkdir -p "$objdir"
    local flags=()
    while [ "$1" != "--" ]; do flags+=("$1"); shift; done
    shift
    ldc2 -c --mtriple=x86_64-pc-windows-msvc -conf= \
        -I="$LDC_DIR/import" -I="$REPO/source" -d-version=Windows10 \
        "${flags[@]}" --od="$objdir" "$@"
}

# link <ausgabe> <objdir> <weitere linkerargumente...>
link() {
    local out=$1 objdir=$2; shift 2
    local gcclib
    gcclib=$(ls -d /usr/lib/gcc/x86_64-w64-mingw32/*/ | head -1)
    lld-link /out:"$out" "$objdir"/*.obj "$WORKDIR/shim.obj" "$@" \
        /usr/x86_64-w64-mingw32/lib/crt2u.o \
        /alternatename:__image_base__=__ImageBase /entry:mainCRTStartup \
        /libpath:"$LDC_DIR/lib64" /libpath:"$LDC_DIR/lib64/mingw" \
        /libpath:/usr/x86_64-w64-mingw32/lib /libpath:"$gcclib" \
        /libpath:"$WORKDIR/mingwfix" /libpath:"$REPO/lib/x86_64" \
        phobos2-ldc.lib druntime-ldc.lib \
        libucrt.a libucrtbase.a libmingwex.a libmingw32fix.a libgcc.a \
        oldnames.lib kernel32.lib user32.lib gdi32.lib cairo.lib \
        /subsystem:console
}

# crt2u.o statt crt2.o: Die Unicode-Variante ruft wmain auf, und genau das
# erzeugt LDC fuer ein D-main unter Windows.

do_build() {
    check_setup
    step "build (Anwendung)"
    local quellen=()
    for f in "$REPO"/source/*.d; do
        [ "$(basename "$f")" = "test_main.d" ] || quellen+=("$f")
    done
    compile "$WORKDIR/obj-app" -- "${quellen[@]}" "$REPO"/source/cairo/*.d \
        || die "Uebersetzen fehlgeschlagen"
    link "$WORKDIR/ananeo.exe" "$WORKDIR/obj-app" "$REPO/res/ananeo.res" \
        || die "Linken fehlgeschlagen"
    printf 'ok: %s\n' "$WORKDIR/ananeo.exe"
}

do_test() {
    check_setup
    step "test (Unittests unter Wine)"
    compile "$WORKDIR/obj-test" -unittest -- "$REPO"/source/*.d "$REPO"/source/cairo/*.d \
        || die "Uebersetzen fehlgeschlagen"
    link "$WORKDIR/ananeo-test.exe" "$WORKDIR/obj-test" \
        || die "Linken fehlgeschlagen"

    # Die Tests lesen layouts.json und keysymdef.h aus dem Arbeitsverzeichnis.
    cd "$REPO" || die "Repo nicht betretbar"
    export WINEPREFIX=${WINEPREFIX:-$WORKDIR/wineprefix} WINEDEBUG=-all
    wine "$WORKDIR/ananeo-test.exe" > "$WORKDIR/test-out.txt" 2> "$WORKDIR/test-err.txt"
    local rc=$?
    cat "$WORKDIR/test-out.txt"
    head -60 "$WORKDIR/test-err.txt"
    [ $rc -eq 0 ] || die "Unittests fehlgeschlagen (Rueckgabewert $rc)"
}

do_lint() {
    [ -x "$DSCANNER" ] || die "D-Scanner fehlt - erst 'setup' aufrufen"
    step "lint"
    cd "$REPO" || die "Repo nicht betretbar"
    "$DSCANNER" --styleCheck --config dscanner.ini source/ || die "Lint meldet Warnungen"
    printf 'ok: keine Warnungen\n'
}

case "${1:-all}" in
    setup) do_setup ;;
    build) do_build ;;
    test)  do_test ;;
    lint)  do_lint ;;
    all)   do_build && do_test && do_lint && printf '\nAlles gruen.\n' ;;
    *)     die "unbekannter Aufruf '$1' (setup|build|test|lint|all)" ;;
esac
