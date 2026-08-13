import core.sys.windows.windows;
import core.stdc.stdio;
import core.stdc.string;
import core.stdc.wchar_;
import core.stdc.stdlib : exit;

import ananeo;
import mapping;
import layerlock : LockTrigger, parseLockTriggers, lockLayerLabel;
import composer;
import debuglog;
import keysyms;
import trayicon;
import osk;
import localization : initLocalization, appString, appStringwz, Language, AppString, hotkeyString;

import std.utf;
import std.string;
import std.conv;
import std.file;
import std.path;
import std.stdio;
import std.json;
import std.regex : matchFirst;

import core.sys.windows.shellapi : ShellExecute;
import sheet : renderSheet;
import keyboardview : BoardLayout;
import composeview : ComposeDisplay, composeOverlay;

HHOOK hHook;
HWINEVENTHOOK foregroundHook;

// The following three flags contain the hook activation state.
// Any time any of them are changed, onHookStateUpdate is called!

// Is the keyboard hook registered and called? Corresponds to
// enable/disable function in tray menu, state shown via tray icon.
// This is *always set by the user*.
bool _keyboardHookActive;
@property bool keyboardHookActive() nothrow {
    return _keyboardHookActive;
}
@property void keyboardHookActive(bool val) nothrow {
    _keyboardHookActive = val;
    onHookStateUpdate();
}
// There are multiple ways the hook can still get bypassed. In that case,
// the tray icon is blue, but the tooltip shows "(inaktiv)". This
// *always happens automatically*.
// 1. Standalone mode is disabled and the native layout is not set
//    to a Neo layout
bool _bypassBecauseNoMatchingLayout;
@property bool bypassBecauseNoMatchingLayout() nothrow {
    return _bypassBecauseNoMatchingLayout;
}
@property void bypassBecauseNoMatchingLayout(bool val) nothrow {
    _bypassBecauseNoMatchingLayout = val;
    onHookStateUpdate();
}
// 2. The current window is on the configured blacklist
bool _bypassBecauseWindowInBlacklist;
@property bool bypassBecauseWindowInBlacklist() nothrow {
    return _bypassBecauseWindowInBlacklist;
}
@property void bypassBecauseWindowInBlacklist(bool val) nothrow {
    _bypassBecauseWindowInBlacklist = val;
    onHookStateUpdate();
}

@property bool resultingHookState() nothrow {
    return keyboardHookActive && !(bypassBecauseNoMatchingLayout || bypassBecauseWindowInBlacklist);
}

// Cache the last resulting hook state to detect changes
bool previousResultingHookState;

bool foregroundWindowChanged;
bool previousNumlockState;

bool oskOpen;
// Wurde die Bildschirmtastatur automatisch durch eine Rastung geoeffnet?
// Nur dann schliessen wir sie beim Loesen wieder.
bool oskOpenedByLock;
// Wurde die Bildschirmtastatur automatisch durch eine Compose-Sequenz
// geoeffnet? Nur dann schliessen wir sie am Sequenzende wieder - dasselbe
// Muster wie oskOpenedByLock.
bool oskOpenedByCompose;

bool configStandaloneMode;
NeoLayout *configStandaloneLayout;
bool configAutoNumlock;
bool configLocksOskAutoShow;
bool configComposeOskAutoShow;
LockTrigger[] configLockTriggers;
bool configFilterNeoModifiers;
HotkeyConfig configHotkeyToggleActivation;
HotkeyConfig configHotkeyToggleOSK;
HotkeyConfig configHotkeyToggleOneHandedMode;
Scancode configOneHandedModeMirrorKey;
Scancode[Scancode] configOneHandedModeMirrorMap;
BlacklistEntry[] configBlacklist;

// Default values, are overwritten if hotkeys are set in user config
string hotkeyToggleActivationStr;
string hotkeyToggleOSKStr = "Mod3+F1";
string hotkeyToggleOneHandedModeStr = "Mod3+F10";

HWND hwnd;

HMENU contextMenu;
HMENU layoutMenu;
HICON iconEnabled;
HICON iconDisabled;
HICON iconLocked;

// set in checkKeyboardLayout (if not null) and used when translating characters to native key combos
HKL lastInputLocale;

const MOD_NOREPEAT = 0x4000;

const UINT ID_MYTRAYICON = 0x1000;
const UINT ID_TRAY_ACTIVATE_CONTEXTMENU = 0x1100;
const UINT ID_TRAY_RELOAD_CONTEXTMENU = 0x1101;
const UINT ID_TRAY_OSK_CONTEXTMENU = 0x1102;
const UINT ID_TRAY_ONE_HANDED_MODE_CONTEXTMENU = 0x1103;
const UINT ID_TRAY_SHEET_CONTEXTMENU = 0x1104;
const UINT ID_TRAY_VERSION = 0x110E;
const UINT ID_TRAY_QUIT_CONTEXTMENU = 0x110F;
const UINT ID_LAYOUTMENU = 0x1200;

const UINT ID_HOTKEY_DEACTIVATE = 0x001;
const UINT ID_HOTKEY_OSK = 0x002;
const UINT ID_HOTKEY_ONE_HANDED_MODE = 0x003;

const UINT LAYOUTMENU_POSITION = 0;

const APPNAME            = "AnaNeo"w;
string executableDir;

TrayIcon trayIcon;

struct HotkeyConfig {
    uint modFlags;
    uint key;  // main key vk
}

struct BlacklistEntry {
    string windowTitleRegex;
}

extern (Windows)
LRESULT LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam) nothrow {
    if (foregroundWindowChanged) {
        checkKeyboardLayout();
        foregroundWindowChanged = false;
    }

    if (!resultingHookState) {
        return CallNextHookEx(hHook, nCode, wParam, lParam);
    }

    auto msgPtr = cast(LPKBDLLHOOKSTRUCT) lParam;
    auto msgStruct = *msgPtr;

    bool eat = keyboardHook(wParam, msgStruct);

    /*
    If nCode is less than zero, the hook procedure must return the value returned by CallNextHookEx.

    If nCode is greater than or equal to zero, and the hook procedure did not process the message,
    it is highly recommended that you call CallNextHookEx and return the value it returns;
    otherwise, other applications that have installed WH_KEYBOARD_LL hooks will not receive hook
    notifications and may behave incorrectly as a result. If the hook procedure processed the message,
    it may return a nonzero value to prevent the system from passing the message to the rest of the
    hook chain or the target window procedure.
    */

    if (nCode < 0) {
        return CallNextHookEx(hHook, nCode, wParam, lParam);
    }

    if (eat) {
        return -1;
    }

    return CallNextHookEx(hHook, nCode, wParam, lParam);
}

wstring inputLocaleToDllName(HKL inputLocale) nothrow {
    // Getting the layout name (which we can then look up in the registry) is a little tricky
    // https://stackoverflow.com/a/19321020/1610421

    // Assume that inputLocale is not null!
    ActivateKeyboardLayout(inputLocale, KLF_SETFORPROCESS);
    wchar[KL_NAMELENGTH] layoutName;
    GetKeyboardLayoutNameW(layoutName.ptr);

    wchar[256] regKey;
    wcscpy(regKey.ptr, r"SYSTEM\ControlSet001\Control\Keyboard Layouts\"w.ptr);
    wcscat(regKey.ptr, layoutName.ptr);

    wstring valueName = "Layout File"w;

    wchar[256] layoutFile;
    uint bufferSize = layoutFile.length;

    if (RegGetValueW(HKEY_LOCAL_MACHINE, regKey.ptr, valueName.ptr, RRF_RT_REG_SZ, NULL, layoutFile.ptr, &bufferSize) == ERROR_SUCCESS) {
        // read layout file name, get characters until null terminator
        wchar[] dllName = layoutFile[0 .. wcslen(layoutFile.ptr)];
        return dllName.to!wstring;
    } else {
        // something went wrong, return null
        return null;
    }
}

void checkKeyboardLayout() nothrow {
    // Function is called when we suspect that the native Windows layout may have changed.
    // This happens
    // - on launch and reload
    // - when enabling the keyboard hook
    // - when manually selecting a standalone layout from the tray menu
    // - on the first key event after a foreground window change

    debugWriteln("Updating keyboard layout");
    // inputLocale may be null, e.g. in console windows!
    HKL inputLocale = GetKeyboardLayout(GetWindowThreadProcessId(GetForegroundWindow(), NULL));
    debugWriteln("Found input locale ", inputLocale);
    wstring dllName;
    if (inputLocale) {  // only look up the inputLocale if it's not null, otherwise dllName is empty
        dllName = inputLocaleToDllName(inputLocale);
    }
    debugWriteln("Input locale corresponds to dll file name '", dllName, "'");

    NeoLayout *layout;

    // try to find a layout in the config that matches the currently active keyboard layout DLL
    for (int i = 0; i < layouts.length; i++) {
        if (dllName && layouts[i].dllName == dllName) {
            layout = &layouts[i];
        }
    }

    if (inputLocale) {  // check if inputLocale is null
        // We got a valid inputLocale, cache it for further use
        lastInputLocale = inputLocale;

        if (layout == null) {
            if (configStandaloneMode) {
                // user enabled standalone mode in config, so we want to overtake and replace it with the selected Neo related layout
                standaloneModeActive = true;
                layout = configStandaloneLayout;
            } else {
                // user just wants to use whatever native layout they selected
                standaloneModeActive = false;
            }
        } else {
            // there is a native Neo related layout active, just operate in extension mode
            standaloneModeActive = false;
        }
    } else {
        // GetKeyboardLayout returns null in Windows terminal, see #11
        // In that case, we want to just keep the current layout settings if there are any, otherwise deactivate
        if (resultingHookState && activeLayout) {
            layout = activeLayout;
        } else {
            layout = null;  // "dllName" and therefore "layout" might be an actual (but wrong) layout if inputLocale == null
            standaloneModeActive = false;
        }
    }

    // Update tray menu: enable layout selection only if standalone mode is currently active
    if (configStandaloneMode) {
        if (standaloneModeActive) {
            EnableMenuItem(contextMenu, LAYOUTMENU_POSITION, MF_BYPOSITION | MF_ENABLED);
        } else {
            EnableMenuItem(contextMenu, LAYOUTMENU_POSITION, MF_BYPOSITION | MF_GRAYED);
        }
    }

    if (layout != null) {
        bypassBecauseNoMatchingLayout = false;

        if (setActiveLayout(layout)) {
            debugWriteln("Changing keyboard layout to ", layout.name);
        }
    } else {
        if (!bypassBecauseNoMatchingLayout) {
            debugWriteln("No matching layout found, bypassing keyboard hook");
            bypassBecauseNoMatchingLayout = true;
        }
    }
}

uint taskBarCreatedMsg = 0;

extern(Windows)
LRESULT WndProc(HWND hwnd, uint msg, WPARAM wParam, LPARAM lParam) nothrow {
    // Huge try block because WndProc is defined as "nothrow"
    try {

    switch (msg) {
        case WM_CREATE:
        taskBarCreatedMsg = RegisterWindowMessage("TaskbarCreated");
        break;
        case WM_DESTROY:
        // Hide the tray icon and cleanup before closing the application
        trayIcon.hide();
        DestroyMenu(contextMenu);
        // Not necessary to unload icons loaded from file
        PostQuitMessage(0);
        return 0;

        case WM_TRAYICON:
        // From https://docs.microsoft.com/en-us/windows/win32/shell/taskbar#adding-modifying-and-deleting-icons-in-the-notification-area:
        // The wParam parameter of the message contains the identifier of the taskbar icon in which the event occurred.
        // The lParam parameter holds the mouse or keyboard message associated with the event.

        // We can omit the check for wParam as we use only a single notification icon
        switch(lParam) {
            case WM_LBUTTONDBLCLK:
            // Execute the same action as the context menu default item
            auto menuItem = GetMenuDefaultItem(contextMenu, 0, 0);
            SendMessage(hwnd, WM_COMMAND, menuItem, 0);
            break;

            case WM_CONTEXTMENU:
            trayIcon.showContextMenu(hwnd, contextMenu);
            break;

            default: break;
        }
        break;

        case WM_COMMAND:
        switch (wParam) {
            case ID_TRAY_ACTIVATE_CONTEXTMENU:
            toggleKeyboardHook();
            break;

            case ID_TRAY_OSK_CONTEXTMENU:
            toggleOSK();
            break;

            case ID_TRAY_ONE_HANDED_MODE_CONTEXTMENU:
            toggleOneHandedMode();
            break;

            case ID_TRAY_SHEET_CONTEXTMENU:
            erzeugeBelegungsblatt();
            break;

            case ID_TRAY_RELOAD_CONTEXTMENU:
            debugWriteln("Re-initialize...");
            initialize();
            // Eine bestehende Rastung zeigt nach dem Neuladen auf Trigger, die
            // es so nicht mehr geben muss - deshalb loesen wir sie.
            clearAllLocks();
            // Ebenso koennen gegessene Chord-Haupttasten auf Trigger zeigen,
            // die nach dem Neuladen nicht mehr existieren.
            chordVkDown.clear();
            updateLockState();
            break;

            case ID_TRAY_QUIT_CONTEXTMENU:
            PostMessage(hwnd, WM_CLOSE, 0, 0);  // cleanup will be done in WM_DESTROY handler
            break;

            default:
            uint newLayoutIdx = cast(uint)wParam - ID_LAYOUTMENU;
            // Did the user select a valid layout index?
            if (newLayoutIdx >= 0 && newLayoutIdx < layouts.length) {
                configStandaloneLayout = &layouts[newLayoutIdx];
                checkKeyboardLayout();
                CheckMenuRadioItem(layoutMenu, 0, GetMenuItemCount(layoutMenu) - 1, newLayoutIdx, MF_BYPOSITION);
                // Persist new selected layout
                auto configJson = parseJSONFile("config.json");
                configJson["standaloneLayout"] = layouts[newLayoutIdx].name;
                std.file.write(buildPath(executableDir, "config.json"), toJSON(configJson, true));
                updateOSK();
            }
            break;
        }
        break;

        case WM_HOTKEY:
        switch (wParam) {
            case ID_HOTKEY_DEACTIVATE:
            // De(activation) hotkey
            toggleKeyboardHook();
            break;
            case ID_HOTKEY_OSK:
            toggleOSK();
            break;
            case ID_HOTKEY_ONE_HANDED_MODE:
            toggleOneHandedMode();
            break;
            default: break;
        }
        break;

        case WM_UPDATELOCKSTATE:
        updateLockState();
        break;

        case WM_COMPOSECHANGED:
        updateComposeState();
        break;

        case WM_SETTINGCHANGE:
        // Windows meldet den Wechsel zwischen hellem und dunklem Apps-Modus als
        // WM_SETTINGCHANGE mit lParam "ImmersiveColorSet". Der Nachrichtentyp
        // selbst ist aber unspezifisch - Richtlinienaenderungen, Gebietsschema,
        // Druckerwarteschlange und mehr kommen ueber denselben Weg. Ohne den
        // Vergleich wuerde jede davon ein Registry-Lesen und ein volles
        // updateOSK() ausloesen, obwohl nur "Sachlich" sich dafuer interessiert.
        if (lParam != 0
            && wcscmp(cast(const(wchar)*) lParam, "ImmersiveColorSet"w.ptr) == 0) {
            refreshOskTheme();
            updateOSK();
        }
        break;

        default:  // Pass everything else to OSK
        if (msg == taskBarCreatedMsg) {
            /** If the explorer process is restarted, tray icons need to be readded,
            otherwise they wont show up. The shell registers TaskbarCreated as a
            message and then broadcasts it to all top-level windows when the taskbar has
            been created. When this message is received, the tray icon needs to be
            readded. **/
            debugWriteln("Show tray icon");
            trayIcon.show();
        }
        return oskWndProc(hwnd, msg, wParam, lParam);
    }

    } catch (Exception e) {
        // Doing nothing here. Might better be done in some methods in TrayIcon
    }

    return DefWindowProc(hwnd, msg, wParam, lParam);
}

// Redraw OSK. WARNING: This function blocks and shouldn't be called from the key event handler
void updateOSK() nothrow {
    try {
        // Die Compose-Anzeige entsteht hier und nicht in osk.d: drawOsk
        // bleibt reiner Verbraucher, wie bei keyboardview.d (Spec 4.3).
        ComposeDisplay anzeige;
        ComposeDisplay* zeiger = null;
        if (composeSpecialActive()) {
            anzeige.sonderModus = true;
            anzeige.sequenz = composeSpecialBuffer();
            zeiger = &anzeige;
        } else if (auto knoten = currentComposeNode()) {
            anzeige.sequenz = composeSequenceString(currentComposeKeysyms()).to!wstring;
            if (activeLayout !is null) {
                uint erstEbene, zweitEbene;
                composeEbenenpaar(erstEbene, zweitEbene);
                anzeige.overlay = composeOverlay(knoten, activeLayout, erstEbene, zweitEbene);
            }
            zeiger = &anzeige;
        }

        // Der Ebenenstreifen erscheint nur bei aktiver Rastung - dort geht
        // der Ueberblick verloren, welche Nummer der Block gerade hat. Beim
        // blossen Halten von Mod3/Mod4 bliebe er sonst staendig am Auf- und
        // Zuklappen.
        wstring ebenenText;
        if (!currentLock.empty) {
            ebenenText = lockLayerLabel(appString(AppString.OSK_LAYER), activeLayer,
                                        currentLock.set, currentLock.name).to!wstring;
        }

        drawOsk(hwnd, activeLayout, activeLayer, capslock,
                heldModifierQuery(), !currentLock.empty, zeiger, ebenenText);
    } catch (Exception e) {}
}

// Schedule an OSK redraw on the message queue. Safe to call from the key event handler
void updateOSKAsync() nothrow {
    PostMessage(hwnd, WM_DRAWOSK, 0, 0);
}

// Erzeugt das Belegungsblatt aus dem, was das LAUFENDE Programm geladen hat -
// nicht aus den Dateien auf der Platte. Genau deshalb gibt es diesen Weg neben
// dem Werkzeug: Er zeigt garantiert den Zustand, den der Nutzer gerade benutzt.
void erzeugeBelegungsblatt() {
    if (activeLayout is null) {
        debugWriteln("Kein Layout geladen - kein Belegungsblatt.");
        // debugWriteln ist im Release-Build ein Nichts (weder Konsole noch
        // Logdatei) - ohne diese Meldung klickt der Nutzer ins Leere, ohne
        // je zu erfahren, warum nichts passiert.
        MessageBox(hwnd, appStringwz(AppString.ERROR_SHEET_NO_LAYOUT),
                   appStringwz(AppString.MENU_SHEET), MB_OK | MB_ICONWARNING);
        return;
    }

    try {
        auto html = renderSheet(activeLayout,
                                configOskLayout == OSKLayout.ISO ? BoardLayout.ISO : BoardLayout.ANSI,
                                configOskNumberRow, configOskNumpad, configLockTriggers);
        auto pfad = buildPath(executableDir, "ananeo-belegung-" ~ activeLayout.name.to!string ~ ".html");
        std.file.write(pfad, html);
        debugWriteln("Belegungsblatt geschrieben: ", pfad);

        auto ergebnis = ShellExecute(null, "open".toUTF16z, pfad.toUTF16z, null, null, SW_SHOWNORMAL);
        // Laut ShellExecute-Doku heisst ein Rueckgabewert <= 32 fehlgeschlagen.
        // Die Datei ist in diesem Fall trotzdem geschrieben - eine andere
        // Meldung als "konnte nicht geschrieben werden".
        if (cast(size_t) ergebnis <= 32) {
            debugWriteln("ShellExecute fuer das Belegungsblatt fehlgeschlagen, Rueckgabewert ",
                         cast(size_t) ergebnis);
            MessageBox(hwnd, appStringwz(AppString.ERROR_SHEET_NOT_OPENED, pfad),
                       appStringwz(AppString.MENU_SHEET), MB_OK | MB_ICONWARNING);
        }
    } catch (Exception e) {
        debugWriteln("Belegungsblatt fehlgeschlagen: ", e.msg);
        MessageBox(hwnd, appStringwz(AppString.ERROR_SHEET_FAILED, e.msg),
                   appStringwz(AppString.MENU_SHEET), MB_OK | MB_ICONERROR);
    }
}

const UINT WM_UPDATELOCKSTATE = WM_APP + 2;

// Rueckmeldung ueber eine geaenderte Rastung auf die Nachrichtenschlange legen.
// Aus dem Hook heraus darf nichts Blockierendes passieren, deshalb PostMessage -
// dasselbe Muster wie updateOSKAsync.
void updateLockStateAsync() nothrow {
    PostMessage(hwnd, WM_UPDATELOCKSTATE, 0, 0);
}

const UINT WM_COMPOSECHANGED = WM_APP + 3;

// Sichtbarer Compose-Zustand hat sich geaendert (Start, Fortschritt,
// Sondermodus-Eingabe oder Ende). Aus dem Hook heraus darf nichts
// Blockierendes passieren, deshalb PostMessage - dasselbe Muster wie
// updateOSKAsync und updateLockStateAsync.
void updateComposeStateAsync() nothrow {
    PostMessage(hwnd, WM_COMPOSECHANGED, 0, 0);
}

// Laeuft in der Fensterprozedur, darf also blockieren.
void updateComposeState() nothrow {
    bool laeuft = composeActive();
    if (configComposeOskAutoShow) {
        if (laeuft && !oskOpen) {
            toggleOSK();
            oskOpenedByCompose = true;
        } else if (!laeuft && oskOpenedByCompose) {
            if (oskOpen) toggleOSK();
            oskOpenedByCompose = false;
        }
    }
    updateOSK();
}

// Laeuft in der Fensterprozedur, darf also blockieren.
void updateLockState() nothrow {
    updateTrayIcon();
    updateTrayTooltip();

    if (configLocksOskAutoShow) {
        if (!currentLock.empty && !oskOpen) {
            toggleOSK();
            oskOpenedByLock = true;
        } else if (currentLock.empty && oskOpenedByLock) {
            if (oskOpen) toggleOSK();
            oskOpenedByLock = false;
        }
    }

    updateOSK();
}

void toggleOSK() nothrow {
    oskOpen = !oskOpen;
    if (oskOpen) {
        ShowWindow(hwnd, SW_SHOWNA);
        updateOSK();
    } else {
        ShowWindow(hwnd, SW_HIDE);
    }
    try {
        updateContextMenu();
    } catch (Exception e) {
    }
}

void toggleOneHandedMode() nothrow {
    oneHandedModeActive = !oneHandedModeActive;
    try {
        updateContextMenu();
    } catch (Exception e) {
    }
}

void modifyMenuItemString(HMENU hMenu, UINT id, string text) {
    // Changing a menu entry is cumbersome by hand (or foot)
    MENUITEMINFO mii;
    mii.cbSize = MENUITEMINFO.sizeof;
    mii.fMask = MIIM_STRING;
    mii.dwTypeData = toUTFz!(wchar*)(text);
    SetMenuItemInfo(hMenu, id, 0, &mii);
}

void updateTrayIcon() nothrow {
    try {
        if (!keyboardHookActive) {
            trayIcon.setIcon(iconDisabled);
        } else if (!currentLock.empty) {
            trayIcon.setIcon(iconLocked);
        } else {
            trayIcon.setIcon(iconEnabled);
        }
    } catch (Exception e) {}
}

void updateContextMenu() {
    updateTrayIcon();

    if (!keyboardHookActive) {
        modifyMenuItemString(contextMenu, ID_TRAY_ACTIVATE_CONTEXTMENU, appString(AppString.MENU_ENABLE, hotkeyToggleActivationStr));
    } else {
        modifyMenuItemString(contextMenu, ID_TRAY_ACTIVATE_CONTEXTMENU, appString(AppString.MENU_DISABLE, hotkeyToggleActivationStr));
    }

    if (oskOpen) {
        CheckMenuItem(contextMenu, ID_TRAY_OSK_CONTEXTMENU, MF_BYCOMMAND | MF_CHECKED);
    } else {
        CheckMenuItem(contextMenu, ID_TRAY_OSK_CONTEXTMENU, MF_BYCOMMAND | MF_UNCHECKED);
    }

    if (oneHandedModeActive) {
        CheckMenuItem(contextMenu, ID_TRAY_ONE_HANDED_MODE_CONTEXTMENU, MF_BYCOMMAND | MF_CHECKED);
    } else {
        CheckMenuItem(contextMenu, ID_TRAY_ONE_HANDED_MODE_CONTEXTMENU, MF_BYCOMMAND | MF_UNCHECKED);
    }
}

void updateTrayTooltip() nothrow {
    wstring layoutName = "inaktiv"w;
    if (resultingHookState && activeLayout) {
        layoutName = (standaloneModeActive ? ""w : "+"w) ~ activeLayout.name;
    }

    wstring lockInfo;
    if (resultingHookState && !currentLock.empty) {
        try {
            lockInfo = ", "w ~ appString(AppString.TOOLTIP_LOCKED, currentLock.name).to!wstring;
        } catch (Exception e) {}
    }

    trayIcon.setTip((APPNAME ~ " (" ~ layoutName ~ lockInfo ~ ")").to!(wchar[]));
}

void onHookStateUpdate() nothrow {
    // Called every time any of the three hook state flags are set

    if (!previousResultingHookState && resultingHookState) {  // on activation
        debugWriteln("Keyboard hook active");
        // store original numlock state so that we can reset it later when deactivating
        previousNumlockState = getNumlockState();

        // We want Numlock to be always on, because some apps (built on WinUI, see #32) misinterpret VK_NUMPADx events if Numlock is disabled
        // However, this means we have to deal with fake shift events on Numpad layer 2 (#15)
        // On some notebooks with a native Numpad layer on the main keyboard we shouldn't do this, because they
        // then always get numbers instead of letters.
        if (configAutoNumlock) {
            setNumlockState(true);
        }

        // Deactivate Kana lock because Kana permanently activates layer 4 in kbdneo
        setKanaState(false);

        resetHookStates();  // Reset potential locks when activating hook
    } else if (previousResultingHookState && !resultingHookState) {  // on deactivation
        debugWriteln("Keyboard hook inactive");
        setNumlockState(previousNumlockState);
    }

    // resetHookStates() kann eine laufende Rastung loeschen, ohne dass
    // updateLockState() (blockierend, nur Fensterprozedur) dazwischen laeuft -
    // Icon sonst weiterhin auf "gerastet" haengen bleibt.
    updateTrayIcon();
    updateTrayTooltip();

    // War das OSK durch die geloeschte Rastung geoeffnet worden, bleibt das
    // Flag sonst faelschlich gesetzt. Das eigentliche Schliessen bleibt
    // updateLockState() vorbehalten - hier wird nur das Flag nachgezogen,
    // damit ein spaeterer Lauf kein fremdes OSK schliesst.
    if (currentLock.empty && oskOpenedByLock) {
        oskOpenedByLock = false;
    }

    previousResultingHookState = resultingHookState;
}

void toggleKeyboardHook() {
    keyboardHookActive = !keyboardHookActive;

    if (keyboardHookActive) {  // on activation
        HINSTANCE hInstance = GetModuleHandle(NULL);
        hHook = SetWindowsHookEx(WH_KEYBOARD_LL, &LowLevelKeyboardProc, hInstance, 0);
        debugWriteln("Keyboard hook registered!");

        checkKeyboardLayout();
    } else {  // on deactivation
        UnhookWindowsHookEx(hHook);
        // Only reset Numlock state if we were active before
        debugWriteln("Keyboard hook unregistered!");
    }

    updateContextMenu();
}


extern (Windows)
void WinEventProc(HWINEVENTHOOK hWinEventHook, DWORD event, HWND hwnd, LONG idObject, LONG idChild, DWORD idEventThread, DWORD dwmsEventTime) nothrow {
    foregroundWindowChanged = true;
    wchar[256] titleBuffer;
    uint titleLen = GetWindowTextW(hwnd, titleBuffer.ptr, 256);
    const auto windowTitle = titleBuffer[0..titleLen].toUTF8;
    debugWriteln("Changed to window with title '", windowTitle, "'");
    try {
        bool windowInBlacklist;

        foreach (blacklistEntry; configBlacklist) {
            if (matchFirst(windowTitle, blacklistEntry.windowTitleRegex)) {
                windowInBlacklist = true;
                break;
            }
        }

        if (windowInBlacklist) {
            debugWriteln("Current window is in blacklist");
        }
        bypassBecauseWindowInBlacklist = windowInBlacklist;
    } catch(Exception e) {}
}

HotkeyConfig parseHotkey(string hotkeyString) {
    HotkeyConfig config;
    config.modFlags = MOD_NOREPEAT;

    auto keyStrings = hotkeyString.split("+");

    foreach (i, keyString; keyStrings) {
        string normalizedKey = keyString.strip.toUpper;

        switch (normalizedKey) {
            case "SHIFT": config.modFlags |= core.sys.windows.winuser.MOD_SHIFT; break;
            case "CTRL": config.modFlags |= core.sys.windows.winuser.MOD_CONTROL; break;
            case "ALT": config.modFlags |= core.sys.windows.winuser.MOD_ALT; break;
            case "WIN": config.modFlags |= core.sys.windows.winuser.MOD_WIN; break;
            default:
            if (i == keyStrings.length - 1) {
                config.key = ("VK_" ~ normalizedKey).to!VKEY;
            } else {
                throw new Exception(appString(AppString.ERROR_INVALID_HOTKEY_MODIFIER, keyString));
            }
            break;
        }
    }

    return config;
}

// Einmalige, idempotente Migrationen alter Konfigurationsdateien. Laeuft bei
// jedem Start vor dem Zusammenfuehren mit config.default.json - jeder Block
// muss deshalb mehrfache Anwendung vertragen.
void migrateConfig(ref JSONValue userConfigJson, ref JSONValue defaultConfigJson) {
    migriereMod4Lock(userConfigJson, defaultConfigJson);
    migriereComposeModulNamen(userConfigJson);
    ergaenzeNeueComposeModule(userConfigJson);
}

/// Stand der Konfigurationsstruktur. Zaehlt eigenstaendig hoch, nicht mit der
/// Programmversion - er beantwortet genau eine Frage: Welche
/// Ergaenzungsschritte hat diese config.json schon gesehen?
///
/// Damit darf eine Migrationsstufe etwas HINZUFUEGEN, was ohne Marker
/// unmoeglich waere: Sie laeuft bei jedem Start und koennte "noch nie
/// ausgeliefert" nicht von "bewusst entfernt" unterscheiden. Genau daran ist
/// die Farbschema-Stufe gescheitert (Kommentar weiter unten). Eine fehlende
/// Angabe zaehlt als 0, also als Konfiguration von vor der Einfuehrung.
enum CONFIG_VERSION = 1;   // 1: Compose-Inhaltsrunde, ananeo-kreis

/// Ein neu ausgeliefertes Compose-Modul und der Ort, an dem es in eine
/// gewachsene Liste gehoert. `nach` ist ein Anker, kein Index: Die
/// Listenreihenfolge ist die Ladereihenfolge, und wer bei einer Kollision
/// gewinnt, haengt daran. Steht der Anker nicht in der Liste, wird angehaengt.
private struct NeuesComposeModul {
    string name;
    string nach;
    long abVersion;   /// erst ergaenzen, wenn die Config aelter ist als dies
}

private static immutable NeuesComposeModul[] NEUE_COMPOSE_MODULE = [
    NeuesComposeModul("ananeo-kreis", "ananeo-hochtief", 1),   // Inhaltsrunde
];

private void ergaenzeNeueComposeModule(ref JSONValue userConfigJson) {
    import std.algorithm : canFind, map;
    import std.array : array;
    import std.json : JSONType;

    // Fehlende oder unbrauchbare Angabe zaehlt als 0: eine Konfiguration von
    // vor der Einfuehrung des Markers, die alle Schritte noch vor sich hat.
    long geseheneVersion = 0;
    if (auto marke = "configVersion" in userConfigJson) {
        if (marke.type == JSONType.INTEGER) geseheneVersion = marke.integer;
    }

    // Den Marker IMMER auf den aktuellen Stand setzen, auch wenn diese Config
    // gar keine composeModules hat - sonst laufen die Schritte spaeter erneut.
    scope(exit) userConfigJson["configVersion"] = JSONValue(CONFIG_VERSION);

    if ("composeModules" !in userConfigJson) return;

    auto namen = userConfigJson["composeModules"].array.map!(e => e.str).array;

    foreach (neu; NEUE_COMPOSE_MODULE) {
        if (geseheneVersion >= neu.abVersion) continue;
        if (namen.canFind(neu.name)) continue;

        JSONValue[] ergaenzt;
        bool gesetzt = false;
        foreach (name; namen) {
            ergaenzt ~= JSONValue(name);
            if (name == neu.nach) { ergaenzt ~= JSONValue(neu.name); gesetzt = true; }
        }
        if (!gesetzt) ergaenzt ~= JSONValue(neu.name);

        namen = ergaenzt.map!(e => e.str).array;
        userConfigJson["composeModules"] = JSONValue(ergaenzt);
        debugWriteln("Migration: Compose-Modul \"", neu.name, "\" ergaenzt.");
    }
}

// Umbenannte Moduldateien in "composeModules" nachziehen. Alter Name -> neuer.
//
// Diese Stufe darf es geben, obwohl migrateConfig bei JEDEM Start laeuft und
// der Kommentar unten vor genau solchen Stufen warnt: Der alte Name zeigt auf
// eine Datei, die nicht mehr existiert. Er kann deshalb keine ausdrueckliche
// Wahl sein, sondern nur ein Rest - anders als "ColorClassic", das ein
// gueltiger Wert blieb. Bewusst NICHT migriert wird das Ergaenzen neuer Module
// (ananeo-kreis): Ein fehlender Name kann gewollt sein, ein toter nicht.
private static immutable string[2][] UMBENANNTE_COMPOSE_MODULE = [
    ["hochtief", "ananeo-hochtief"],   // Compose-Inhaltsrunde, 04.08.2026
];

/// Meldungstext fuer konfigurierte Module ohne Datei - leer, wenn alles
/// gefunden wurde. Eigene Funktion statt einer Bedingung mitten in
/// initialize(): Die laesst sich pruefen, initialize() ruft Win32.
string unbekannteComposeModuleMeldung(const(string)[] unbekannt) {
    import std.array : join;

    if (unbekannt.length == 0) return "";
    return appString(AppString.ERROR_COMPOSE_MODULE_MISSING, unbekannt.join(", "));
}

private void migriereComposeModulNamen(ref JSONValue userConfigJson) {
    if ("composeModules" !in userConfigJson) return;

    // Ganze Eintraege vergleichen, nicht im Text ersetzen: "hochtief" ist ein
    // Teilstring von "ananeo-hochtief", eine Ersetzung liefe beim naechsten
    // Start noch einmal und baute "ananeo-ananeo-hochtief".
    foreach (ref JSONValue eintrag; userConfigJson["composeModules"].array) {
        foreach (paar; UMBENANNTE_COMPOSE_MODULE) {
            if (eintrag.str != paar[0]) continue;
            eintrag = JSONValue(paar[1]);
            debugWriteln("Migration: Compose-Modul \"", paar[0], "\" heisst jetzt \"",
                paar[1], "\".");
        }
    }
}

// "enableMod4Lock" ist durch die "locks"-Sektion ersetzt worden. Stand die
// Option auf false, wollte der Nutzer den Lock ausdruecklich nicht - er
// bekommt dann eine "locks"-Sektion ohne die Trigger, die etwas rasten.
private void migriereMod4Lock(ref JSONValue userConfigJson, ref JSONValue defaultConfigJson) {
    if ("enableMod4Lock" !in userConfigJson) return;

    bool mod4LockErlaubt = userConfigJson["enableMod4Lock"].boolean;
    userConfigJson.object.remove("enableMod4Lock");
    debugWriteln("Migration: \"enableMod4Lock\" entfernt (war ", mod4LockErlaubt, ").");

    if (mod4LockErlaubt || "locks" in userConfigJson) return;

    JSONValue[] ohneLock;
    foreach (JSONValue eintrag; defaultConfigJson["locks"]["triggers"].array) {
        if ("lock" in eintrag) continue;
        ohneLock ~= eintrag;
    }

    // Frisches Objekt bauen, nicht das Vorgabeobjekt veraendern - JSONValue
    // teilt sich beim Zuweisen die inneren Verweise.
    userConfigJson["locks"] = JSONValue([
        "oskAutoShow": defaultConfigJson["locks"]["oskAutoShow"],
        "triggers": JSONValue(ohneLock)
    ]);
    debugWriteln("Migration: \"locks\" ohne rastende Trigger angelegt.");
}

// Hier stand bis zur OSK-Vorschau-Runde migriereFarbschema: Seit Paket 5b ist
// "Sachlich" das Vorgabeschema, und weil der Konfigurations-Merge einen
// bestehenden Wert nicht ersetzt, schrieb eine Migrationsstufe den alten
// Vorgabewert "ColorClassic" auf "Sachlich" um. Sie war als einmaliger Anstoss
// gedacht, lief aber bei JEDEM Start - "ColorClassic" liess sich dadurch gar
// nicht mehr auswaehlen (Befund aus der Abnahme am 03.08.2026). Entfernt statt
// nachgebessert: Gewachsene Konfigurationen sind seit mehreren Runden
// umgestellt, wer den Wert heute in der config.json stehen hat, meint ihn.

void initialize() {
    try {
        // Muss vor initCompose laufen: der Compose-Baum wird ueber Keysyms
        // aufgebaut.
        initKeysyms(executableDir);

        // Load default config (shipped with the program) as a base
        auto configJson = parseJSONFile("config.default.json");
        // Load user config if it exists
        if (exists(buildPath(executableDir, "config.json"))) {
            auto userConfigJson = parseJSONFile("config.json");

            migrateConfig(userConfigJson, configJson);

            // Overwrite values from default config with user config settings
            void copyJsonObjectOverOther(ref JSONValue source, ref JSONValue destination) {
                foreach (string key, JSONValue value; source) {
                    // The "mirrorMap" thing is a hack to not fill the user config.json with mirror map
                    // entries for scancodes that they have removed but that exist in config.default.json
                    if (value.type == JSONType.OBJECT && key in destination && key != "mirrorMap") {
                        copyJsonObjectOverOther(value, destination[key]);
                    } else {
                        destination[key] = value;
                    }
                }
            }

            copyJsonObjectOverOther(userConfigJson, configJson);
        }

        // Write combined config (default values + user settings) to user config file
        std.file.write(buildPath(executableDir, "config.json"), toJSON(configJson, true));

        // First of all, set the langage so that subsequent stuff is localized correctly
        initLocalization(configJson["language"].str.toUpper.to!Language);

        // Braucht die zusammengefuehrte Konfiguration: "composeModules" legt
        // fest, welche Moduldateien in welcher Reihenfolge geladen werden.
        string[] composeModules;
        foreach (JSONValue eintrag; configJson["composeModules"].array) {
            composeModules ~= eintrag.str;
        }
        initCompose(executableDir, composeModules);

        // Ein Name ohne Datei kostet einen ganzen Compose-Zweig, ohne dass
        // irgendetwas auffiele - das Programm laeuft ja. Deshalb sichtbar
        // machen und nicht nur ins Debug-Log schreiben, das ein Release-Build
        // gar nicht fuehrt. Kein Abbruch: Die uebrigen Module sind geladen,
        // ein Tippfehler soll den Start nicht verhindern.
        auto fehlendeModule = unbekannteComposeModuleMeldung(composeUnknownModules);
        if (fehlendeModule.length > 0) {
            debugWriteln(fehlendeModule);
            MessageBox(hwnd, fehlendeModule.toUTF16z,
                appStringwz(AppString.ERROR_WHILE_INITIALIZING), MB_OK | MB_ICONWARNING);
        }


        auto layoutsJson = parseJSONFile("layouts.json");
        initLayouts(layoutsJson["layouts"]);

        initOsk(configJson["osk"]);

        // Initialize layout menu
        layoutMenu = CreatePopupMenu();
        for (int i = 0; i < layouts.length; i++) {
            AppendMenu(layoutMenu, MF_STRING, ID_LAYOUTMENU + i, layouts[i].name.toUTF16z);
        }

        configStandaloneMode = configJson["standaloneMode"].boolean;
        if (configStandaloneMode) {
            wstring standaloneLayoutName = configJson["standaloneLayout"].str.to!wstring;
            for (int i = 0; i < layouts.length; i++) {
                if (layouts[i].name == standaloneLayoutName) {
                    configStandaloneLayout = &layouts[i];
                    // Select the current layout (only visible if standalone mode is active)
                    CheckMenuRadioItem(layoutMenu, 0, GetMenuItemCount(layoutMenu) - 1, i, MF_BYPOSITION);
                    break;
                }
            }

            if (configStandaloneLayout == null) {
                debugWriteln("Standalone layout '", standaloneLayoutName, "' not found!");
            }
        }

        configAutoNumlock = configJson["autoNumlock"].boolean;
        configLocksOskAutoShow = configJson["locks"]["oskAutoShow"].boolean;
        configComposeOskAutoShow = configJson["compose"]["oskAutoShow"].boolean;
        configLockTriggers = parseLockTriggers(configJson["locks"]);
        configFilterNeoModifiers = configJson["filterNeoModifiers"].boolean;

        // Parse hotkeys (might be null -> user doesn't want to use hotkey)
        if (configJson["hotkeys"]["toggleActivation"].type == JSONType.STRING) {
            configHotkeyToggleActivation = parseHotkey(configJson["hotkeys"]["toggleActivation"].str);
            hotkeyToggleActivationStr = hotkeyString(configHotkeyToggleActivation);
        }
        if (configJson["hotkeys"]["toggleOSK"].type == JSONType.STRING) {
            configHotkeyToggleOSK = parseHotkey(configJson["hotkeys"]["toggleOSK"].str);
            hotkeyToggleOSKStr = hotkeyString(configHotkeyToggleOSK);
        }
        if (configJson["hotkeys"]["toggleOneHandedMode"].type == JSONType.STRING) {
            configHotkeyToggleOneHandedMode = parseHotkey(configJson["hotkeys"]["toggleOneHandedMode"].str);
            hotkeyToggleOneHandedModeStr = hotkeyString(configHotkeyToggleOneHandedMode);
        }

        configOneHandedModeMirrorKey = parseScancode(configJson["oneHandedMode"]["mirrorKey"].str);
        foreach (string key, JSONValue value; configJson["oneHandedMode"]["mirrorMap"]) {
            configOneHandedModeMirrorMap[parseScancode(key)] = parseScancode(value.str);
        }

        configBlacklist = [];
        foreach (blacklistEntryJson; configJson["blacklist"].array) {
            BlacklistEntry blacklistEntry;
            if (!("windowTitle" in blacklistEntryJson)) {
                throw new Exception(appString(AppString.ERROR_BLACKLIST_MUST_CONTAIN_WINDOW_TITLE));
            }
            blacklistEntry.windowTitleRegex = blacklistEntryJson["windowTitle"].str;
            configBlacklist ~= blacklistEntry;
        }
    } catch (Exception e) {
        MessageBox(hwnd, appStringwz(AppString.ERROR_ERROR_OCCURRED_WHILE_STARTING, e.msg), appStringwz(AppString.ERROR_WHILE_INITIALIZING), MB_OK | MB_ICONERROR);
        exit(0);
    }

    debugWriteln("Initialization complete!");
}

unittest {
    // Gegenprobe zur entfernten Farbschema-Migration: migrateConfig laeuft bei
    // JEDEM Start, eine Stufe, die einen Schemanamen umschreibt, macht diesen
    // Namen dauerhaft unwaehlbar. Genau das ist mit "ColorClassic" passiert
    // (Abnahme vom 03.08.2026). Der Test haelt fest, dass alle fuenf Schemata
    // die Migration unveraendert ueberstehen.
    import std.json : parseJSON;

    auto vorgabe = parseJSON(`{
        "osk": {"theme": "Sachlich"},
        "locks": {"oskAutoShow": false, "triggers": []}
    }`);

    foreach (schema; ["Grey", "NeoBlue", "ColorClassic", "ColorGreen", "Sachlich"]) {
        auto config = parseJSON(`{"osk": {"theme": "` ~ schema ~ `"}}`);
        migrateConfig(config, vorgabe);
        assert(config["osk"]["theme"].str == schema,
            "migrateConfig hat das Farbschema umgeschrieben: " ~ schema);
        migrateConfig(config, vorgabe);
        assert(config["osk"]["theme"].str == schema, "zweiter Lauf hat etwas veraendert");
    }

    // Konfiguration ganz ohne "osk"-Sektion darf nicht werfen
    auto ohneOsk = parseJSON(`{"standaloneMode": true}`);
    migrateConfig(ohneOsk, vorgabe);
}

unittest {
    // Die Umbenennung hochtief -> ananeo-hochtief ist migrierbar, und zwar aus
    // genau dem Grund, aus dem die Farbschema-Stufe es nicht war (Kommentar
    // oben): Der alte Name zeigt auf eine Datei, die es nicht mehr gibt. Eine
    // "ausdrueckliche Wahl", die zu erhalten waere, kann es dafuer nicht geben.
    // Anlass ist die Abnahme vom 04.08.2026 - eine gewachsene config.json nannte
    // nach der Umbenennung weiter "hochtief", und BEIDE eigenen Module fielen
    // stumm aus.
    import std.json : parseJSON;

    auto vorgabe = parseJSON(`{"composeModules": ["base", "ananeo-hochtief"]}`);
    auto config = parseJSON(`{"composeModules": ["base", "hochtief", "ananeo-schrift"]}`);

    migrateConfig(config, vorgabe);
    assert(config["composeModules"].array[1].str == "ananeo-hochtief");

    // Idempotent, und zwar ohne Textersetzung: "hochtief" ist ein Teilstring des
    // neuen Namens - wer hier ersetzt statt ganze Eintraege vergleicht, baut beim
    // zweiten Start "ananeo-ananeo-hochtief".
    migrateConfig(config, vorgabe);
    assert(config["composeModules"].array[1].str == "ananeo-hochtief");

    // Der Rest bleibt unangetastet. Die Laenge prueft dieser Test bewusst
    // nicht: Das Ergaenzen neuer Module ist eine eigene Stufe mit eigenem Test,
    // und sie laeuft in demselben migrateConfig.
    import std.algorithm : canFind, map;
    import std.array : array;

    auto namen = config["composeModules"].array.map!(e => e.str).array;
    assert(namen[0] == "base");
    assert(namen.canFind("ananeo-schrift"));
    assert(!namen.canFind("hochtief"), "der tote Name ist weg, nicht nur ergaenzt");

    // Konfiguration ohne "composeModules" darf nicht werfen.
    auto ohne = parseJSON(`{"standaloneMode": true}`);
    migrateConfig(ohne, vorgabe);
}

unittest {
    // Neue Compose-Module erreichen eine gewachsene config.json nur ueber eine
    // Migrationsstufe: Der Start-Merge ersetzt Arrays als Ganzes, ergaenzt sie
    // also nicht. Ohne diese Stufe fehlten Bestandsnutzern nach der
    // Inhaltsrunde die 220 Eintraege der Einkreisung - und zwar ohne jede
    // Warnung, weil kein Name ins Leere zeigt.
    //
    // Eingefuegt wird hinter einem Anker, nicht angehaengt: Die Listenreihenfolge
    // ist die Ladereihenfolge, und wer bei einer Kollision gewinnt, haengt daran.
    import std.algorithm : map;
    import std.array : array;
    import std.json : parseJSON;

    auto vorgabe = parseJSON(`{"composeModules": []}`);
    auto config = parseJSON(
        `{"composeModules": ["base", "math", "ananeo-hochtief", "ananeo-schrift"]}`);

    migrateConfig(config, vorgabe);

    auto namen = config["composeModules"].array.map!(e => e.str).array;
    assert(namen == ["base", "math", "ananeo-hochtief", "ananeo-kreis", "ananeo-schrift"],
        "hinter dem Anker eingefuegt, nicht angehaengt");
}

unittest {
    // Der Marker ist der ganze Grund, warum diese Stufe ergaenzen DARF: Sie
    // laeuft wie alle bei jedem Start, und ohne ihn koennte sie "noch nie
    // gesehen" nicht von "bewusst entfernt" unterscheiden - dieselbe Falle, in
    // die die Farbschema-Stufe gelaufen ist (Kommentar oben). Wer ein Modul
    // nach dem Umstieg herausnimmt, hat die Version schon gesehen; es kommt
    // nicht zurueck.
    import std.algorithm : canFind, map;
    import std.array : array;
    import std.json : parseJSON;

    auto vorgabe = parseJSON(`{"composeModules": []}`);

    // Aktuelle Version, Modul fehlt: eine ausdrueckliche Wahl.
    auto entfernt = parseJSON(`{
        "configVersion": ` ~ CONFIG_VERSION.to!string ~ `,
        "composeModules": ["base", "ananeo-hochtief"]
    }`);
    migrateConfig(entfernt, vorgabe);
    assert(!entfernt["composeModules"].array.map!(e => e.str).array.canFind("ananeo-kreis"),
        "ein bewusst entferntes Modul darf nicht zurueckkehren");

    // Gegenprobe: dieselbe Liste ohne Marker ist eine Config von vor dem
    // Umstieg - da wird ergaenzt.
    auto alt = parseJSON(`{"composeModules": ["base", "ananeo-hochtief"]}`);
    migrateConfig(alt, vorgabe);
    assert(alt["composeModules"].array.map!(e => e.str).array.canFind("ananeo-kreis"));

    // Und danach traegt sie den Marker, laeuft also beim naechsten Start nicht
    // noch einmal - sonst waere die Unterscheidung nur einen Start lang wahr.
    assert(alt["configVersion"].integer == CONFIG_VERSION);
}

unittest {
    // Steht der Anker nicht in der Liste - jemand hat ananeo-hochtief
    // abgewaehlt -, wird angehaengt statt verworfen. Das neue Modul soll auch
    // dann ankommen; die Reihenfolge entscheidet nur ueber Kollisionen, und
    // die hat ananeo-kreis mit niemandem.
    import std.algorithm : map;
    import std.array : array;
    import std.json : parseJSON;

    auto vorgabe = parseJSON(`{"composeModules": []}`);
    auto config = parseJSON(`{"composeModules": ["base", "math"]}`);

    migrateConfig(config, vorgabe);

    assert(config["composeModules"].array.map!(e => e.str).array
        == ["base", "math", "ananeo-kreis"]);
}

unittest {
    // Gegenprobe gegen die ausgelieferten Konfigurationen, im Geist des
    // Farbschema-Tests: Sie sind auf dem aktuellen Stand, also darf migrateConfig
    // an ihnen NICHTS aendern - weder Module ergaenzen noch umbenennen. Faengt
    // ab, dass jemand CONFIG_VERSION hochzaehlt, ohne die Vorgaben nachzuziehen.
    import std.algorithm : map;
    import std.array : array;
    import std.file : readText;
    import std.json : parseJSON;

    auto vorgabe = parseJSON(readText("config.default.json"));

    foreach (datei; ["config.default.json", "config.neo.json", "config.neoqwertz.json",
                     "config.noted.json", "config.annoted.json"]) {
        auto config = parseJSON(readText(datei));
        auto vorher = config["composeModules"].array.map!(e => e.str).array;

        // Am Dateiinhalt geprueft, NICHT am Ergebnis der Migration: Die setzt
        // den Marker selbst, die Pruefung danach waere immer wahr.
        assert("configVersion" in config && config["configVersion"].integer == CONFIG_VERSION,
            datei ~ ": traegt nicht CONFIG_VERSION " ~ CONFIG_VERSION.to!string
                  ~ " - Vorgabe nachziehen.");

        migrateConfig(config, vorgabe);

        assert(config["composeModules"].array.map!(e => e.str).array == vorher,
            datei ~ ": migrateConfig hat die Modulliste veraendert.");
    }
}

unittest {
    // Ein Modulname ohne Datei kostet stillschweigend einen ganzen
    // Compose-Zweig. Bis zur Inhaltsrunde sah das laufende Programm
    // composer.composeUnknownModules gar nicht an - nur das Werkzeug meldete
    // es, und im Release-Build schreibt AnaNeo nicht einmal ein Log. Der Text
    // muss die Namen tragen, sonst hilft er beim Suchen nicht, und den Ort,
    // damit klar ist, wo sie stehen.
    import std.algorithm : canFind;

    initLocalization(Language.GERMAN);

    assert(unbekannteComposeModuleMeldung([]) == "", "alles gefunden - keine Meldung");

    auto meldung = unbekannteComposeModuleMeldung(["hochtief", "tippfehler"]);
    assert(meldung.canFind("hochtief"));
    assert(meldung.canFind("tippfehler"));
    assert(meldung.canFind("composeModules"), "der Text nennt den Ort, an dem sie stehen");
}

JSONValue parseJSONFile(string jsonFilename) {
    string jsonFilePath = buildPath(executableDir, jsonFilename);
    if (!exists(jsonFilePath))
        throw new Exception(appString(AppString.ERROR_PATH_DOES_NOT_EXIST, jsonFilePath));
    string jsonString = readText(jsonFilePath);
    try {
        return parseJSON(jsonString);
    } catch (Exception e) {
        throw new Exception(appString(AppString.ERROR_WHILE_PARSING, jsonFilename, e.msg));
    }
}

version (unittest) {
    // Im Testbuild liefert source/test_main.d die main-Funktion.
} else
void main(string[] args) {
    debug {
        const auto codePage = CP_UTF8;
        if (!SetConsoleCP(codePage))
            debugWriteln("WARNING: Could not set input CP to UTF-8. This probably doesn’t matter.");
        if (!SetConsoleOutputCP(codePage))
            debugWriteln("WARNING: Could not set output CP to UTF-8. Some characters may be displayed wrongly.");
    }

    debugWriteln("Starting AnaNeo...");
    version(FileLogging) {
        debugWriteln("WARNING: File logging enabled, make sure you know what you're doing!");
    }
    executableDir = dirName(thisExePath());

    initialize();

    // We want to detect when the selected keyboard layout changes so that we can activate or deactivate AnaNeo as necessary.
    // Listening to input locale events directly is difficult and not very robust. So we listen to the foreground window changes
    // (which also fire when the language bar is activated) and then recheck the keyboard layout on the next keypress.
    // For some reason (probably by mistake) WINEVENTPROCs must be @nogc. That's annoying, so we just cast our function pointer
    // and use the GC anyway.
    foregroundHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, NULL, cast(WINEVENTPROC) &WinEventProc, 0, 0, WINEVENT_OUTOFCONTEXT);
    if (foregroundHook) {
        debugWriteln("Foreground window hook active!");
    } else {
        debugWriteln("Could not install foreground window hook!");
    }

    // Create window for on-screen keyboard
    WNDCLASS wndclass;
    wndclass.lpszClassName = APPNAME.toUTF16z;
    wndclass.lpfnWndProc = &WndProc;
    RegisterClass(&wndclass);
    HINSTANCE hInstance = GetModuleHandle(NULL);
    hwnd = CreateWindowEx(WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TOOLWINDOW, wndclass.lpszClassName, APPNAME.toUTF16z, WS_POPUP, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, NULL, NULL, hInstance, NULL);

    // Move and scale window to center of its current monitor
    centerOskOnScreen(hwnd);

    // Names of icons are defined in icons.rc
    iconEnabled = LoadImage(hInstance, "trayenabled", IMAGE_ICON, 0, 0, LR_SHARED | LR_DEFAULTSIZE);
    iconDisabled = LoadImage(hInstance, "traydisabled", IMAGE_ICON, 0, 0, LR_SHARED | LR_DEFAULTSIZE);
    iconLocked = LoadImage(hInstance, "traylocked", IMAGE_ICON, 0, 0, LR_SHARED | LR_DEFAULTSIZE);
    if (!iconLocked) {
        // Ressource fehlt, etwa weil ananeo.res nicht neu gebaut wurde
        debugWriteln("Icon 'traylocked' nicht gefunden, benutze das normale Icon.");
        iconLocked = iconEnabled;
    }

    SetClassLongPtr(hwnd, GCLP_HICON, cast(LONG_PTR) iconEnabled);

    // Install icon in notification area, based on the hwnd
    trayIcon = new TrayIcon(hwnd, ID_MYTRAYICON, iconEnabled, APPNAME.to!(wchar[]));
    trayIcon.show();

    // Define context menu
    contextMenu = CreatePopupMenu();
    if (configStandaloneMode) {
        AppendMenu(contextMenu, MF_POPUP, cast(UINT_PTR) layoutMenu, appStringwz(AppString.MENU_CHOOSE_LAYOUT));
        AppendMenu(contextMenu, MF_SEPARATOR, 0, NULL);
    }
    AppendMenu(contextMenu, MF_STRING, ID_TRAY_OSK_CONTEXTMENU, appStringwz(AppString.MENU_OSK, hotkeyToggleOSKStr));
    AppendMenu(contextMenu, MF_STRING, ID_TRAY_ONE_HANDED_MODE_CONTEXTMENU, appStringwz(AppString.MENU_ONE_HANDED_MODE, hotkeyToggleOneHandedModeStr));
    AppendMenu(contextMenu, MF_STRING, ID_TRAY_SHEET_CONTEXTMENU, appStringwz(AppString.MENU_SHEET));
    AppendMenu(contextMenu, MF_STRING, ID_TRAY_RELOAD_CONTEXTMENU, appStringwz(AppString.MENU_RELOAD));
    AppendMenu(contextMenu, MF_STRING, ID_TRAY_ACTIVATE_CONTEXTMENU, appStringwz(AppString.MENU_DISABLE, hotkeyToggleActivationStr));
    AppendMenu(contextMenu, MF_SEPARATOR, 0, NULL);
    string versionMsg = "AnaNeo %VERSION%";   // placeholder is replaced with the tag name by .github/workflows/release.yml
    AppendMenu(contextMenu, MF_STRING, ID_TRAY_VERSION, versionMsg.toUTF16z);
    EnableMenuItem(contextMenu, ID_TRAY_VERSION, MF_BYCOMMAND | MF_GRAYED);
    AppendMenu(contextMenu, MF_STRING, ID_TRAY_QUIT_CONTEXTMENU, appStringwz(AppString.MENU_QUIT));
    SetMenuDefaultItem(contextMenu, ID_TRAY_ACTIVATE_CONTEXTMENU, 0);

    keyboardHookActive = false;
    toggleKeyboardHook();

    // Register global (de)activation hotkey
    if (configHotkeyToggleActivation.key)
        RegisterHotKey(hwnd, ID_HOTKEY_DEACTIVATE, configHotkeyToggleActivation.modFlags, configHotkeyToggleActivation.key);
    // Register alternate OSK hotkey (M3+F1 always works)
    if (configHotkeyToggleOSK.key)
        RegisterHotKey(hwnd, ID_HOTKEY_OSK, configHotkeyToggleOSK.modFlags, configHotkeyToggleOSK.key);
    // Register alternate one handed mode hotkey (M3+F10 always works)
    if (configHotkeyToggleOneHandedMode.key)
        RegisterHotKey(hwnd, ID_HOTKEY_ONE_HANDED_MODE, configHotkeyToggleOneHandedMode.modFlags, configHotkeyToggleOneHandedMode.key);

    MSG msg;
    while(GetMessage(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    UnregisterHotKey(hwnd, ID_HOTKEY_ONE_HANDED_MODE);
    UnregisterHotKey(hwnd, ID_HOTKEY_OSK);
    UnregisterHotKey(hwnd, ID_HOTKEY_DEACTIVATE);

    if (keyboardHookActive) { toggleKeyboardHook(); }
}
