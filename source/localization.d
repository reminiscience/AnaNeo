module localization;

import std.conv : to;
import std.format : format;
import std.utf : toUTF16z;
import std.string : capitalize;

import core.sys.windows.windows : LPCWSTR;
import core.sys.windows.winuser : MOD_WIN, MOD_ALT, MOD_SHIFT, MOD_CONTROL;

import app : HotkeyConfig;
import mapping : VKEY;

enum AppString {
    MENU_DISABLE,
    MENU_ENABLE,
    MENU_RELOAD,
    MENU_CHOOSE_LAYOUT,
    MENU_QUIT,
    MENU_OSK,
    MENU_ONE_HANDED_MODE,
    MENU_SHEET,

    TOOLTIP_LOCKED,

    OSK_COMPOSE_HERE,
    OSK_COMPOSE_ELSEWHERE,
    OSK_LAYER,

    ERROR_INVALID_HOTKEY_MODIFIER,
    ERROR_BLACKLIST_MUST_CONTAIN_WINDOW_TITLE,
    ERROR_ERROR_OCCURRED_WHILE_STARTING,
    ERROR_WHILE_INITIALIZING,
    ERROR_PATH_DOES_NOT_EXIST,
    ERROR_WHILE_PARSING,
    ERROR_COMPOSE_MODULE_MISSING,
    ERROR_SHEET_NO_LAYOUT,
    ERROR_SHEET_FAILED,
    ERROR_SHEET_NOT_OPENED
}

enum Language {
    ENGLISH,
    GERMAN
}

private Language selectedLanguage;

private string[Language][AppString] stringMap;

void initLocalization(Language lang) {
    stringMap = [
        AppString.MENU_DISABLE: [Language.ENGLISH: "Deactivate\t%s", Language.GERMAN: "Deaktivieren\t%s"],
        AppString.MENU_ENABLE: [Language.ENGLISH: "Activate\t%s", Language.GERMAN: "Aktivieren\t%s"],
        AppString.MENU_RELOAD: [Language.ENGLISH: "Reload", Language.GERMAN: "Neu laden"],
        AppString.MENU_CHOOSE_LAYOUT: [Language.ENGLISH: "Layout", Language.GERMAN: "Tastaturlayout"],
        AppString.MENU_QUIT: [Language.ENGLISH: "Quit", Language.GERMAN: "Beenden"],
        AppString.MENU_OSK: [Language.ENGLISH: "On-Screen Keyboard\t%s", Language.GERMAN: "Bildschirmtastatur\t%s"],
        AppString.MENU_ONE_HANDED_MODE: [Language.ENGLISH: "One-Handed Mode\t%s", Language.GERMAN: "Einhandmodus\t%s"],
        AppString.MENU_SHEET: [Language.ENGLISH: "Create layout sheet", Language.GERMAN: "Belegungsblatt erzeugen"],
        AppString.TOOLTIP_LOCKED: [Language.ENGLISH: "%s locked", Language.GERMAN: "%s gerastet"],

        AppString.OSK_COMPOSE_HERE: [Language.ENGLISH: "here", Language.GERMAN: "hier"],
        AppString.OSK_COMPOSE_ELSEWHERE: [Language.ENGLISH: "on other layers", Language.GERMAN: "auf anderen Ebenen"],
        AppString.OSK_LAYER: [Language.ENGLISH: "Layer", Language.GERMAN: "Ebene"],
        AppString.ERROR_INVALID_HOTKEY_MODIFIER: [
            Language.ENGLISH: "Non-existent hotkey modifier '%s'. Possible values are Shift, Ctrl, Alt, Win.",
            Language.GERMAN: "Nicht existierender Hotkey-Modifier '%s'. Mögliche Werte sind Shift, Ctrl, Alt, Win."
        ],
        AppString.ERROR_BLACKLIST_MUST_CONTAIN_WINDOW_TITLE: [
            Language.ENGLISH: "Blacklist entries must contain \"windowTitle\".",
            Language.GERMAN: "Blacklist-Einträge müssen \"windowTitle\" enthalten."
        ],
        AppString.ERROR_ERROR_OCCURRED_WHILE_STARTING: [
            Language.ENGLISH: "An error occurred while starting AnaNeo:\n%s",
            Language.GERMAN: "Beim Starten von AnaNeo ist ein Fehler aufgetreten:\n%s"
        ],
        AppString.ERROR_WHILE_INITIALIZING: [
            Language.ENGLISH: "Error during initialization",
            Language.GERMAN: "Fehler beim Initialisieren"
        ],
        AppString.ERROR_PATH_DOES_NOT_EXIST: [
            Language.ENGLISH: "%s does not exist.",
            Language.GERMAN: "%s existiert nicht."
        ],
        AppString.ERROR_WHILE_PARSING: [
            Language.ENGLISH: "Error while parsing %s.\n%s",
            Language.GERMAN: "Fehler beim Parsen von %s.\n%s"
        ],
        AppString.ERROR_COMPOSE_MODULE_MISSING: [
            Language.ENGLISH: "\"composeModules\" in config.json names compose modules that have no file:\n%s\n\nThey were not loaded, so their sequences are missing.",
            Language.GERMAN: "\"composeModules\" in der config.json nennt Compose-Module ohne Datei:\n%s\n\nSie sind nicht geladen worden, ihre Sequenzen fehlen also."
        ],
        AppString.ERROR_SHEET_NO_LAYOUT: [
            Language.ENGLISH: "No layout is loaded yet, the layout sheet cannot be created.",
            Language.GERMAN: "Es ist noch kein Layout geladen, das Belegungsblatt kann nicht erzeugt werden."
        ],
        AppString.ERROR_SHEET_FAILED: [
            Language.ENGLISH: "The layout sheet could not be created:\n%s",
            Language.GERMAN: "Das Belegungsblatt konnte nicht erzeugt werden:\n%s"
        ],
        AppString.ERROR_SHEET_NOT_OPENED: [
            Language.ENGLISH: "The layout sheet was written to %s, but could not be opened automatically.",
            Language.GERMAN: "Das Belegungsblatt wurde nach %s geschrieben, ließ sich aber nicht automatisch öffnen."
        ],
    ];

    selectedLanguage = lang;
}

string appString(T...)(AppString as, T args) nothrow {
    try {
        if (as in stringMap && selectedLanguage in stringMap[as]) {
            return format(stringMap[as][selectedLanguage], args);
        } else {
            return as.to!string;
        }
    } catch (Exception e) {
        return "";
    }
}

LPCWSTR appStringwz(T...)(AppString as, T args) nothrow {
    try {
        return appString(as, args).toUTF16z;
    } catch (Exception e) {
        return null;
    }
}

string hotkeyString(HotkeyConfig hotkey) {
    string hotkeyString = "";

    if (hotkey.modFlags & MOD_WIN) {
        hotkeyString ~= "Win+";
    }
    if (hotkey.modFlags & MOD_CONTROL) {
        hotkeyString ~= controlKeyName() ~ "+";
    }
    if (hotkey.modFlags & MOD_ALT) {
        hotkeyString ~= "Alt+";
    }
    if (hotkey.modFlags & MOD_SHIFT) {
        hotkeyString ~= "Shift+";
    }

    hotkeyString ~= hotkey.key.to!VKEY.to!string[3..$].capitalize;

    return hotkeyString;
}

string controlKeyName() {
    if (selectedLanguage == Language.GERMAN) {
        return "Strg";
    } else {
        return "Ctrl";
    }
}
