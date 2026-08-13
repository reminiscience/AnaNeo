# AnaNeo – The Neo keyboard layout family on Windows

[**Diese Seite auf Deutsch**](README_DE.md)

> **AnaNeo is a fork of [ReNeo](https://github.com/Rojetto/ReNeo)** by Rojetto and qwertfisch. Most of the code originates from ReNeo and is licensed under GPL-3.0, as before. AnaNeo is a private project made public – see [About this fork](#about-this-fork) before you rely on it.

📖 **[The wiki](https://github.com/reminiscience/AnaNeo/wiki)** documents all 21 layers – one page per themed block, with a picture of every layer – and the complete configuration space.

AnaNeo implements the [Neo keyboard layout](http://neo-layout.org/) and its relatives on Windows. There are two main modes of operation:
1. *standalone mode*: AnaNeo replaces all key events of the native layout (likely QWERTZ or QWERTY) with the desired Neo layout. You only need to run the AnaNeo executable on system startup.
2. *extension mode*: First, install a native Neo driver like [kbdneo](https://neo-layout.org/Einrichtung/kbdneo/). AnaNeo then supplements all functions that can't be implemented in the native driver (capslock, navigation keys on layer 4, compose, ...).

![AnaNeo on-screen keyboard layer 1](docs/osk_screenshot.png "AnaNeo On-Screen keyboard")

## About this fork

AnaNeo is not a competitor to ReNeo, it is one layout taken further. ReNeo carries the whole Neo family and stays close to the published standards; AnaNeo keeps four of those layouts – *Neo*, *NeoQwertz*, *Noted* and *AnNoted* (Bone, AdNW, Mine, KOY, VOU and 3l were dropped) – and puts the work into **AnNoted**, its own variant of *Noted*.

- **Refreshing Noted.** *AnNoted* keeps Noted's letter arrangement and its native driver (`kbdnoted.dll`), but is free to depart from the published standard where an extension has a reason to. *Noted* itself stays in the package unchanged as a standard-conform standalone layout, so nothing is taken away.
- **More layers.** *AnNoted* has 21 layers instead of 6: layers 1 to 4 as usual, then five themed blocks – maths, typography, Ancient Greek, Cyrillic, extra – and layer 21 for the compose modifiers. No physical key carries the block modifiers; a block is reached by locking it, which is why the lock model had to become a first-class part of the program rather than a switch for layer 4.
- **Systematising the functionality.** Any set of modifiers can be locked, and a lock is described in `config.json` instead of being hard-coded. The compose tree follows a stated grammar – *the layer carries the grip, the tree carries the derivation* – and two of the compose modules (font variants, enclosed characters) are generated from code rather than maintained by hand, with tests holding file and calculation together. A separate command-line build, `ananeo-tool`, reports on the compose stock: origin, coverage, gaps, duplicates, and which layer each continuation sits on.
- **The display was rebuilt, not invented.** The on-screen keyboard comes from ReNeo. What it *shows* is now computed in a separate, testable module; it renders glyphs through the font's own `cmap` table, so characters beyond the Basic Multilingual Plane (chess, alchemy, Mathematical Alphanumeric Symbols) appear instead of empty boxes; it carries a layer strip and a live preview of the running compose sequence. New alongside it is a printable, self-contained HTML **layout sheet**.

Unchanged from ReNeo is the part that is hardest to get right and easiest to break: the low-level keyboard hook, the modifier bookkeeping and the forced modifier state. That work is Rojetto's and qwertfisch's, and it is why this fork could concentrate on layouts and compose.

### How this repository was built

**AnaNeo is vibe-coded.** Almost all of the code, tests and documentation added in this fork were written by Claude (Anthropic's Claude Code agent) under human direction. Decisions, reviews and the manual acceptance testing are the human side of it: anything that touches the keyboard hook, the modifier state or the drawing cannot be proven by a unit test and has to be tried on a real Windows machine. Each development round therefore ends with a written acceptance protocol.

Two consequences worth knowing before you install it:

- The automated test suite is large and covers the pure data and logic modules – layout parsing, layer and lock logic, the compose tree, the key descriptions, the font `cmap` reader, the report generators. It does **not** cover the hook, the sending of key events, or the drawing itself.
- Development happened in a private working copy. The project log, the specifications and plans, and the acceptance protocols are German-language working documents and are **not part of this repository** – this README and `README_DE.md` are the parts written for readers from outside.

## Installation

1. *optional*: Install [kbdneo](https://neo-layout.org/Einrichtung/kbdneo/) normally
2. Download [newest release](https://github.com/reminiscience/AnaNeo/releases/latest) and unpack in a directory with write permissions, e.g. `C:\Users\[USER]\AnaNeo`
3. Start `ananeo.exe` oder [add it to the autostart list](docs/autostart.md). Use the tray icon to deactivate or quit the program.
4. *optional*: [Tweak `config.json`](#configuration) (generated on first start)

*Update*

Download new release and overwrite existing files with package contents. Because `config.json` isn't contained in the release package user settings are preserved.

*Uninstallation*

1. *optional*: Uninstall kbdneo according to Neo wiki tutorial
2. Delete AnaNeo directory and remove executable from autostart

## Features

General:

- Supports the layouts *Neo*, *NeoQwertz*, *Noted* and *AnNoted* – AnNoted is Noted's own variant with special spaces on the space bar; in extension mode against `kbdnoted.dll`, AnNoted is active, while Noted itself is only selectable in standalone mode
- Use tray menu to switch between layouts
- Lockable layers: Capslock (both shift keys), mod 3 lock (both mod 3 keys), mod 4 lock (both mod 4 keys) and further locks configured freely via `"locks"` in `config.json`. `M3+Esc` releases all locks. While a layer is locked, the tray icon changes color and the tooltip names the lock.
- Themed layers: Beyond layers 1 to 4 there are five themed blocks, each with its own block modifier (Mod5 to Mod9). A block is locked (`M3+F2` to `M3+F6`); once the base layer is locked, holding Shift, Mod3, or Mod4 reaches the block's other layers. No physical key carries Mod5 to Mod9 – every block is reachable exclusively through locking.

    | Layers | Trigger | Block |
    |---|---|---|
    | 1–4 | – / Shift / Mod3 / Mod4 | as usual |
    | 5–8 | Mod5 / +Shift / +Mod3 / +Mod4 | maths and logic (7 = superscript, 8 = subscript) |
    | 9–12 | Mod6 / +Shift / +Mod3 / +Mod4 | typography (11/12 carry three compose dead keys, rest still in reserve) |
    | 13–14 | Mod7 / +Shift | Ancient Greek, lower/upper case |
    | 15–16 | Mod8 / +Shift | Cyrillic (Russian) |
    | 17–20 | Mod9 / +Shift / +Mod3 / +Mod4 | extra: symbol zones, emoji (19), dice/alchemy/technology (20) |
    | 21 | Mod3+Mod4 | compose modifiers, reachable from **every** lock state |

    Layer 21 carries the six starting characters of the compose grammar on the home row, each on the initial letter of its category: `𝔵` font variant (S), `ⓧ` enclosure (E), `↻` rotation (D), `ₓ` subscript (T), `˞` retroflex hook (R), `ˣ` superscript (H). It is the only layer that exempts itself from locking – pressing `Mod3+Mod4` inside a locked block lands there instead of on layer 1. Example: `Mod3+Mod4`, `S`, release, then `d K` gives `𝕂`.

    Default triggers: `M3+F2` maths, `M3+F3` typography, `M3+F4` Greek, `M3+F5` Cyrillic, `M3+F6` extra. `M3+F7` adds Shift to the lock or removes it again, keeping you on the block's second layer.

    The space key carries its own hierarchy: layer 3 a non-breaking space, layer 4 a narrow non-breaking space, layer 5 a thin space, layer 6 a hair space, layer 7 a zero-width space; from layer 8 on it types normally. Layer 4's numpad-0 moves to `w` to make room. Until the grammar round the compose prefixes for super- and subscript sat on the `^` key; they now live on layer 21 together with the other modifiers, and `Mod3`+`^` no longer produces anything – the one spot where AnNoted deliberately departs from the Neo standard.

    **Only the *AnNoted* layout has these layers.** *Neo*, *NeoQwertz*, and *Noted* stay at their six published layers; of the themed-block triggers they ship only `M3+F2`, and there the lock is called `Mod3+Mod4` because it hits their existing layer 6.

    Two consequences of this layer split in AnNoted: `Shift+Mod3` has no layer of its own and falls back to layer 1 (`Mod3+Mod4` has hit the modifier layer 21 since the grammar round). And within a locked block, only the defined extensions (+Shift, and for maths, typography, and extra also +Mod3/+Mod4) reach a layer – anything else falls back to layer 1 as well; release the lock briefly with `M3+Esc` if you need special characters or navigation in between.
- **On-screen keyboard**: Toggle using tray menu or with shortcut `M3+F1`. Switches between layers as modifiers are pressed. While a layer is locked, a strip at the top names the current layer, its block, and the modifier set ("Layer 13 · Griechisch · Mod7"); if a compose sequence is running at the same time, it shares the strip. Also draws characters beyond the Basic Multilingual Plane correctly (chess, alchemy, Mathematical Alphanumeric Symbols); to do so, a bundled symbol font (*Noto Sans Symbols 2*, directory `fonts/`, licensed under the SIL Open Font License 1.1, text in `fonts/OFL.txt`) is loaded privately into the process at startup, without installing it. If no font has a matching glyph, the key shows its code point in small text instead of an empty box. Five color schemes are available; the default since package 5b is `Sachlich` (light/dark follows the Windows setting automatically) – anyone who previously had `ColorClassic` (the old default) set gets `Sachlich` automatically on the next start, while an explicitly chosen `ColorGreen` is left untouched.
- *All* dead keys and compose combinations. These can be extended by users; the list `composeModules` in `config.json` decides which `.module` files from the `compose/` directory are loaded, and in which order.
- Special compose sequences
    - Unicode input: `♫uu[codepoint hex]<space>` inserts unicode characters, e.g. `♫uu1f574<space>` → 🕴
    - Roman numerals: `♫rn[zahl]<space>` for lower case, `♫RN[zahl]<space>` for upper case. Numbers must range between 1 and 3999. Example: `♫rn1970<space>` → ⅿⅽⅿⅼⅹⅹ, `♫RN1970<space>` → ⅯⅭⅯⅬⅩⅩ
- Sticky modifiers: Some compose modifiers (e.g. `ˣ` superscript, `ₓ` subscript, `ⓧ` circling, `𝔵` font variant) keep the sequence open after emitting a character instead of ending it – the next keypress continues at the modifier. Example: `ˣ 1 2 3` gives ¹²³. Exit the modifier either with a key that has no compose entry (types normally again), with `Escape` (discards the whole sequence), or with the modifier itself (silent exit, does not type). **Pitfall:** `x ˣ 2 y` gives `x²ʸ`, not `x²y` – `y` is still typed inside superscript mode. The way out is one more press of the modifier: `x ˣ 2 ˣ y` → `x²y`.
- `Shift+Pause` de(activates) the program
- One-handed mode: If mode is enabled and space (default) is held, the whole keyboard is “mirored”. Toggle using tray menu or with shortcut `M3+F10`.
- Additional layouts can be added or modified in `layouts.json`.

## Layout sheet

Two ways to generate the current key layout as a printable HTML document:

- Tray menu → "Create layout sheet": shows exactly what the running program currently has loaded, and opens the file in the default browser.
- Command line: `ananeo-tool sheet [layout name]` generates the same sheet without a running AnaNeo, directly from the files in the executable's directory. Without a layout name, a sheet is generated for each layout. `ananeo-tool.exe` is a separate build that links neither Cairo nor the keyboard hook.

The sheet is a single, self-contained HTML file – no external references, usable without a network connection: one keyboard, one tab per layer, switching by click via a small amount of JavaScript. When printing (print preview is enough) or with JavaScript disabled, it instead shows all layers stacked below each other – the print form.

How to read it: an accent bar marks a key that produces a character, with its code point (`U+…`) below; keys without a bar, shown dimmed, are function keys (with their key name), modifiers get a filled background, and dashed outlines mark unassigned positions – the latter are the work list for remapping. The same reading applies to the on-screen keyboard under the `Sachlich` color scheme.

As an extension to the native driver:

- Navigation keys on layer 4
- If the native layout is recognized as Neo-related (`kbdneo2.dll`, `kbdgr2.dll`, `kbdnoted.dll`), AnaNeo automatically switches to extension mode. Switching between layouts is possible as normal.
- Improved compatibility with Qt and GTK applications. Workaround for [this bug](https://git.neo-layout.org/neo/neo-layout/issues/510).
- Compose key `M3+Tab` does not send tab character to applications. Workaround for [this bug](https://git.neo-layout.org/neo/neo-layout/issues/397).

## Configuration

Two files, both next to the executable: `config.json` holds your settings and is created on first start, `layouts.json` holds the layouts themselves. Neither needs a rebuild – edit and restart AnaNeo.

**The full reference lives in the wiki**, with the reasoning and the pitfalls:

| Wiki page | Covers |
|---|---|
| [Configuration](https://github.com/reminiscience/AnaNeo/wiki/Configuration) | how your settings and the defaults are merged, and the top-level options |
| [Locks and triggers](https://github.com/reminiscience/AnaNeo/wiki/Configuration-Locks) | `locks` – which modifiers lock, by which chord, and the fixed actions |
| [On-screen keyboard](https://github.com/reminiscience/AnaNeo/wiki/Configuration-OSK) | `osk` – theme, ISO/ANSI, numpad, number row, modifier names |
| [Compose modules](https://github.com/reminiscience/AnaNeo/wiki/Configuration-Compose-Modules) | `composeModules`, `compose` – which sequence files load, in what order |
| [Hotkeys and blacklist](https://github.com/reminiscience/AnaNeo/wiki/Configuration-Hotkeys-and-Blacklist) | `hotkeys`, `blacklist` |
| [One-handed mode](https://github.com/reminiscience/AnaNeo/wiki/Configuration-One-Handed-Mode) | `oneHandedMode` – mirror key and mirror map |
| [Editing layouts](https://github.com/reminiscience/AnaNeo/wiki/Editing-Layouts) | `layouts.json` – layers, keys, keysyms, forced modifiers |

### Options at a glance

| Option | Values | Meaning |
|---|---|---|
| `standaloneMode` | `true` (default) / `false` | replace the native layout, or only supplement a Neo driver and deactivate otherwise |
| `standaloneLayout` | `"AnNoted"`, `"Noted"`, `"Neo"`, `"NeoQwertz"` | layout for standalone mode; also in the tray menu |
| `language` | `"german"` / `"english"` | program language |
| `filterNeoModifiers` | `true` (default) / `false` | hide M3/M4 events from other programs in extension mode ([bug](https://git.neo-layout.org/neo/neo-layout/issues/510)); `false` if you want to bind them in an application |
| `autoNumlock` | `true` (default) / `false` | switch Numlock on automatically; `false` for laptops whose numpad sits on the letter keys |
| `blacklist` | list of `{"windowTitle": "…"}` | deactivate AnaNeo for windows whose title matches the regex |
| `composeModules` | list of file names without extension | which files from `compose/` load, **in this order** |
| `compose.oskAutoShow` | `false` (default) / `true` | open the on-screen keyboard while a compose sequence runs |
| `locks.oskAutoShow` | `false` (default) / `true` | open the on-screen keyboard while a layer is locked |
| `locks.triggers` | list of `{"chord": …, "lock"/"action": …}` | which chord locks what, or performs a fixed action |
| `osk.theme` | `"Sachlich"` (default), `"Grey"`, `"NeoBlue"`, `"ColorClassic"`, `"ColorGreen"` | colour scheme; `Sachlich` follows the Windows light/dark setting |
| `osk.layout` | `"iso"` / `"ansi"` | physical keyboard shape |
| `osk.numpad`, `osk.numberRow` | `true` / `false` | show the numeric keypad, show the number row |
| `osk.modifierNames` | `"standard"` / `"three"` | label modifiers `M3`, `M4` or `Sym`, `Cur` |
| `hotkeys.toggleActivation` | e.g. `"Shift+Pause"`, or `null` | global shortcut switching AnaNeo on and off |
| `hotkeys.toggleOSK`, `hotkeys.toggleOneHandedMode` | shortcut or `null` (default) | already reachable as `M3+F1` and `M3+F10` |
| `oneHandedMode.mirrorKey` | scan code, `"39"` (space) by default | key that mirrors the keyboard while held |
| `oneHandedMode.mirrorMap` | `"original": "mirrored"` scan codes | which key becomes which; adjust for ergonomic and matrix keyboards |
| `configVersion` | number, maintained automatically | records which migration steps this config has seen |

Hotkey syntax: modifiers `Shift`, `Ctrl`, `Alt`, `Win` plus a main key from the `VKEY` enumeration in [`source/mapping.d`](https://github.com/reminiscience/AnaNeo/blob/develop/source/mapping.d), based on the [Win32 virtual-key codes](https://docs.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes). `null` registers no global hotkey.

Lock trigger syntax: `"chord"` plus either `"lock"` or `"action"`. The same modifier twice (`"Shift+Shift"`) means left and right key together; otherwise all parts but the last are held modifiers. Lockable are `Shift` and `Mod3` to `Mod9` – not Ctrl or Alt, which would capture every application shortcut. Actions are `"capslock"`, `"clearLocks"`, `"osk"`, `"oneHandedMode"` and `"compose"`. Full grammar in the [wiki](https://github.com/reminiscience/AnaNeo/wiki/Configuration-Locks).

### After an update

**Arrays are replaced whole when your settings are merged with the defaults, not merged field by field.** If your `config.json` already has a `"triggers"` array, newly shipped triggers will not appear in it. Delete that entry – or the whole `"locks"` block – once and restart.

The same used to apply to `"composeModules"`; renamed and newly shipped modules are now carried over automatically. If something is missing anyway, deleting that entry once has the same effect.

### Modifying layouts

`layouts.json` defines every layout: `modifiers` (scan code → modifier), `layers` (the modifier state each layer requires, tested in order), `capslockableKeys`, and `map` (scan code → one entry per layer). An entry carries a `keysym` plus either a `char` or a `vk`, optionally a `label` and forced `mods`.

Put your own changes in *AnNoted* – the other three layouts reproduce published standards. Adding a layer means adding an entry to every line of `map`.

The [wiki page](https://github.com/reminiscience/AnaNeo/wiki/Editing-Layouts) has the field reference, the procedure for creating a new layout, and the traps – empty cells becoming `VK_VOID`, invisible characters needing `\uXXXX` escapes, why a cell needs both `keysym` and `char`, and why you must never re-serialise the file with a JSON library.

# Virtual machines and remote desktop
As soon as several nested operatings systems interoperate things get difficult. Because different VM software and remote desktop clients behave differently there is no universal solution. What follows is some general advice and a few tested configurations.

For optimal compatibility, the *innermost* system should generally implement the alternative layout and all outer systems should be set to QWERTZ/QWERTY.
In the case of virtual machines this means QWERTZ on the host and a Neo driver on the guest system.
For remote desktop machines a local QWERTZ setup and a Neo driver on the remote system are recommended.

If it turns out that programs work better without AnaNeo, the offending programs can be added to the *blacklist* for AnaNeo to automatically deactivate, see [configuration](#configuration).

## WSL using VcXsrv as X server

Set Windows to QWERTZ (without AnaNeo), then set the Neo layout in X11 using `setxkbmap`.

## VirtualBox

Set host to QWERTZ, then install Neo driver (e.g. AnaNeo) in guest system.

## [Remote Desktop Manager](https://remotedesktopmanager.com/)

Use AnaNeo in standalone mode on the local system. Letters and (non-unicode) special characters are transmitted correctely to the remote system.

# For developers
## Compilation
AnaNeo is written in D and uses `dub` for project configuration and compilation.
There are three build settings:

1. Debug with `dub build`: In addition to debugging symbols, the generated executable opens instantiates a console to output debugging imformation.
2. Debug and log with `dub build --build=debug-log`: Similar to debug but console output is additionally written to `ananeo_log.txt`. Caution: this log file may contain sensitive information!
3. Release with `dub build --build=release`: Optimizations are active and no console is instantiated.

The resource file `res/ananeo.res` is built using `rc.exe` from the Windows SDK (x86 version, otherwise the generated res file won't work). The command ist `rc.exe ananeo.rc`.

Cairo DLL originates from https://github.com/preshing/cairo-windows. The D header files were generated from the C headers using [DStep](https://github.com/jacob-carlborg/dstep) and manually tweaked.

## Release
A tag of the form `v*` triggers a GitHub action to generate a release draft. Based on the different `config.[layout].json` files, several pre-configured ZIP archives are created.

# Librarys
Uses [Cairo](https://www.cairographics.org/) licensed under the GNU Lesser General Public License (LGPL) version 2.1.
