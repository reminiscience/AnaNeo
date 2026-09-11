# Nomenclature
- **VK**/**VKEY**: A **Virtual-Key Code** (`uint`), documented [here](https://docs.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes). For letters and number keys, there are no names in the Microsoft header, which is why our enum has been supplemented with `VK_KEY_A` - `VK_KEY_Z` and `VK_KEY_0` - `VK_KEY_9`
- **Scancode**: Code that indicates the physical position of the key on the keyboard. [Reference here](https://kbdlayout.info/kbdgr/scancodes). Some keys are additionally distinguished by the **Extended Bit**, which we combine with the number in a `Scancode` struct. In `layouts.json`, the Extended Bit is marked with a `+`.
- **Keysym**: Numeric code (`uint`) from `keysymdef.h` that describes the meaning of a key (character or control key). In some cases, the *name* (`str`) of the code is also referred to as Keysym in the code. Used for Compose, as the Compose definitions in XCompose format use these key designations.
- **Neo-Modifier**: Mod3, Mod4, ...
- **NeoKey**: An entry in the keymap in `layouts.json`. Assigns a desired function to a key on a certain level. This can either be a specific character (**Char-Mapping**) or a control key (**VK-Mapping**).

# Basic Principle
The core of the program is the logic in the `keyboardHook` function. Roughly summarized, the following steps are executed in sequence.

## Filter unwanted events
We ignore Unicode events (`VK_PACKET`) as well as all events where the `injected` flag is set. These are probably coming from us anyway and should not end up in a loop.

In addition, we actively filter out fake events inserted by AltGr or the numeric keypad from the keyboard stack.

## Update modifier states
Sending native key combinations for special characters, arbitrarily mappable modifiers, and VK mappings with modifiers on arbitrary levels has made their handling increasingly complex. The current implementation aims to move away from a complex state machine with many individual flags and special cases and is based on the following conceptual model.

Which **modifiers** exist and where they are located on the keyboard is defined in `"modifiers"` in the layout. This covers both the **native modifiers** Shift, Ctrl, and Alt (in left and right variants) as well as the **Neo-Modifiers** Mod3, Mod4 (left and right), and higher (without left/right).

The **natural modifier state** describes which of these modifiers are currently being pressed by physical keys. This is complicated somewhat by the fact that, in principle, multiple physical keys can press the same modifier. If multiple keys hold the same modifier, we want to "release" the modifier only when the last physical key is released.

For each modifier type, it is stored which scancodes currently press this modifier. In a *Modifier-Down-Event*, the corresponding scancode is added to this data structure and the correct modifier event is passed through or sent. In principle, programs should only see *native modifiers*, *Neo-Modifiers* are filtered and their state is only handled internally. In a *Modifier-Up-Event*, the scancode is removed from the data structure again. Only if this key was the last one holding this modifier, an Up-Event for programs is generated (including forced modifiers, see below).

## Determine current level

The **natural modifier state** and the **locked modifier set** together yield the *effective* state: a modifier counts as active if it is held **or** locked, but not both – which makes it possible to leave a locked layer briefly by holding the key. If programs see the Neo modifiers themselves (extension mode with `filterNeoModifiers: false`), a plain OR applies instead, because the native driver switches the layer on the real key event anyway. On that basis the levels in `"layers"` are tested one after the other, and the first matching one is adopted. An entry that does not mention a currently locked modifier is skipped – otherwise level 1 would shadow every locked additional level.

Capslock comes afterwards and only under narrow conditions: the key must be listed in `"capslockableKeys"`, no lock may be active and no Neo modifier may be held. The level is then determined again with the Shift state inverted. For the shipped layouts this is the swap between levels 1 and 2. On locked layers Capslock stays silent; upper/lower case switching there is handled by a Shift trigger with `"mode": "toggle"`.

The logic lives entirely in `source/layerlock.d`, where it is unit tested without any Win32 state. Which chords lock something is configured under `"locks"` in `config.json`.

With the current level and the pressed scancode, the NeoKey is then derived from the mapping.

## Compose

The entry point to the Compose module is the `compose` function, which is passed the current NeoKey for each key press. The core of the module is the **Compose tree**, whose branches are then followed during a Compose sequence. Depending on the resulting Compose state, the function responds with a Compose state. Thus, the keypress is either passed through unchanged in the Hook function, swallowed (because it is part of a Compose sequence), or replaced by the Compose result at the end of a Compose sequence.

Which module files fill the tree is decided by the positive list `composeModules` in the configuration; the order of the list is the loading order. The `.remove` files are read first – those of the selected modules plus those that have no module at all, since those belong to built-in special routines such as Unicode input. The modules themselves follow. For every sequence, `addComposeEntry` reports back what happened to it: newly added, overwritten as an exact duplicate, or discarded as an extension or a prefix of an existing sequence. From this, `initCompose` writes a report to the debug log once loading finishes – counters per module file plus the individual cases.

## Sending key events

Depending on the mapping type (VK or Char) and mode, different events are generated.

VK mappings are always implemented as VK events. The scancode is obtained from a lookup in the native layout.

Char mappings are realized as Unicode events in extension mode. In standalone mode, however, a key combination that produces the desired character is searched for in the native layout, and this combination is sent. If the character does not exist natively, a Unicode event is used as a fallback.

VK mappings can force some or all of the *native modifiers* on or off with `"mods"`. The **forced modifier state** describes which modifiers are currently being forced to which value. The unspecified modifiers are not changed. The same mechanism also works for native key combinations for special characters in Char mappings.

The forced state is stored in a global variable between key presses. When a Down event of a key that may force new modifier states occurs, it must be determined with which minimal set of modifier events one can transition from one state to the other.

First, the natural state is combined with the previous (old) forced state to obtain the previous **resulting modifier state**. This is the state as seen by other programs.

```
                        LShift         LCtrl          LAlt
  natural               1              0              0
+ old forced                                          1         (LShift and LCtrl were irrelevant)
= old resulting         1              0              1
```

Equivalently, the new resulting state is obtained with the (new) forced state of the currently pressed key.

```
                        LShift         LCtrl          LAlt
  natural               1              0              0
+ new forced            1              1              0
= new resulting         1              1              0
```

Comparing the two resulting states (old and new) makes it clear which modifier events need to be sent to transition from old to new.

```
                        LShift         LCtrl          LAlt
old resulting           1              0              1
new resulting           1              1              0
-> Necessary events                    Down           Up
```

For an Up event, we generally want to reset the forced modifiers to the natural state. However, this only applies if the Up event belongs to the key that is the originator of the current forced state, otherwise the state is maintained.

# Insights and Workarounds
## Numpad
### Numlock State
In principle, Numlock works similarly to Capslock; the status can be queried and toggled with `VK_NUMLOCK`, and the keyboard LED displays the current status. *Actually*, the Numlock state doesn't matter to us, as Numlock as a concept does not exist in Neo. The numpad is also subject to the normal layer principle.

However, applications behave differently in practice. Most programs generate the corresponding number for a `VK_NUMPADx` event, regardless of the current state of Numlock. [WinUI applications require Numlock to be enabled, otherwise they only move the text cursor](https://github.com/microsoft/microsoft-ui-xaml/issues/5008).

**Workaround**: By default, we automatically enable Numlock.

This is annoying for some laptops that have a number pad *in the main field* activated via Numlock. Specifically, this has occurred on a Dell device. In this case, `"autoNumlock": false` can be used to disable the automatic activation of Numlock (with the expected limitations).

### Numlock Key
Strange things happen when you want to remap the Numlock key by filtering out its events. The LED does not change, but the internal state does.

**Workaround**: [Inspired by AHK](https://github.com/Lexikos/AutoHotkey_L/blob/master/source/hook.cpp#L2027), we internally press Numlock a few times to resolve the strange state.

### Shift and Numpad
When Numlock is enabled, special behavior occurs when pressing Shift *together* with a "**dual state**" numpad key. This specifically affects number keys 0-9 and the comma key. In this case, the driver stack inserts a **Fake-Shift** event to release the currently held Shift key and press it again afterward. These fake events do not have the `injected` flag set and are *sometimes* marked with the fake scancode `0x22A` (LShift) or `0x236` (RShift).

**Workaround**: We generally filter events with fake scancodes. For the affected "dual state" numpad keys, we also internally set a flag for key events to expect a Shift event next and filter it out accordingly. If it doesn't come (because Numlock is disabled or the event has already been filtered out based on the fake scancode), the flag is reset.

## AltGr
Internally, there is no "AltGr" key; instead, it is called "RAlt". In European layouts, however, the driver is configured so that pressing the key also sends an "LCtrl" event in addition to "RAlt" if LCtrl is not already pressed. This **Fake-LCtrl** is marked with the *fake scancode* `0x21D`, but not with the `injected` flag.

If you inject an RAlt yourself, the Windows stack automatically adds a Fake-LCtrl. In this case, *under Windows 10, the Fake-LCtrl is marked with the `injected` flag, while under Windows 7, it is not*.

Most applications generate the desired characters with LCtrl+LAlt. However, some only accept LCtrl+RAlt for special characters (e.g., *PuTTY*).

**Workaround**: For Mod4, we generally filter RAlt, but also all Fake-LCtrl events, identified by the fake scancode.

To generate special characters with native key combinations, we send both RAlt and LCtrl events for AltGr characters. We want to prevent the keyboard stack from automatically injecting Fake-LCtrl events, so the order matters here: LCtrl↓ RAlt↓ Key↓ Key↑ RAlt↑ LCtrl↑.

## Neo-Modifiers
GTK and Qt programs do not like modifiers other than Shift, Ctrl, Alt and behave strangely. The Telegram app is suitable for testing. If you use pure *kbdneo* there, [the next key event is completely swallowed after Mod3](https://git.neo-layout.org/neo/neo-layout/issues/510).

**Workaround**: In extension mode, we completely filter out Neo-Modifier events and instead send the desired keys directly on levels 3 and higher. Characters on these higher levels are then always Unicode packets.

If you actually want to let Neo-Modifier events through to programs, this behavior can be adjusted with `"filterNeoModifiers"` in the config.

## Capslock
### Capslock State
Using `VK_CAPITAL`, the current Capslock state can be read (`GetKeyState`) and set with key events. The current state is always displayed with the Capslock LED.

To ensure the Capslock LED is correct, we always toggle the actual Capslock state with Double-Shift. The letter keys are implemented as VK mapping and are then natively converted to uppercase letters.

### Capslockable

Not all keys should be affected by Capslock. On the Neo side, it's only the letter keys. The keys that should switch to the second level with Capslock are referred to as **capslockable** and are defined in `layouts.json`.

Conversely, not all keys are affected by Capslock in the native layout. The native driver determines which keys are affected.

**Workaround**: In `sendUTF16OrKeyCombo`, we use `ToUnicodeEx` to unlock the native driver with active Capslock, checking whether the next key will be affected by it. Depending on this, Shift must be additionally pressed or released.

## Dead Keys
### Dead Keys in the Native Driver
Native keyboard drivers support arbitrarily long dead key sequences. Typically, programs see these keys as `WM_KEYDOWN` and `WM_KEYUP`, and the window procedure turns them into `WM_DEADCHAR`. Most programs, however, do not process these events but wait for a `WM_CHAR` with the fully combined character to arrive at the end of the sequence.

In *kbdneo*, only a small fraction of the Compose sequences are defined. Also, [the Compose key `M3+Tab` still reaches programs](https://git.neo-layout.org/neo/neo-layout/issues/397).

**Workaround**: As soon as AnaNeo recognizes the beginning of a Compose sequence, the corresponding key events are filtered out, and internally the Compose tree is followed until the end of the sequence is reached. Then, only the finished character(s) are sent as (a sequence of) Unicode packets.

### Identifying Dead Keys
In Standalone mode, we try to find the desired characters with `VkKeyScanEx` in the native layout and implement them as native key combinations. However, this is problematic for keys like the backtick "`" or the circumflex "^" on level 3. These keys should immediately generate a character but are often present as dead keys in native layouts. The exception is the DE-CH layout, where the circumflex is not a dead key.

**Workaround**: With `ToUnicodeEx`, it is possible to check whether the found key actually generates a character immediately. If not, the character is realized with a Unicode packet. Calling this function changes the internal state of the Windows driver stack. If we find a dead key, we need to call the function again to reset the state.

## Native Layouts
### Detecting Layout Changes
We want to detect layout changes in Windows in order to automatically switch between Extension mode and Standalone mode, or to (de)activate AnaNeo. Unfortunately, there are no direct global events for this.

**Workaround**: We register a hook to listen for window changes. When the window has changed, we check *on the next key press* the current layout with `GetKeyboardLayout`. If you change the layout with Win+Space, Ctrl+Shift, or Alt+Shift, it happens immediately since the popup with the layout selection is considered a window change. If you use Shift+Ctrl or Shift+Alt instead, the hook is not triggered, and you need to manually switch windows for the hook to activate.

### The Console
In certain terminals, such as the classic console, `GetKeyboardLayout` returns `null` for the console thread. Calls like `VkKeyScan` also return incorrect results in these windows, as internally some strange legacy layout is assumed.

**Workaround**: We cache the last seen "meaningful" layout and ignore layout changes when the new layout is `null`. For calls like `VkKeyScan`, we use the `VkKeyScanEx` variant and explicitly pass the cached, meaningful layout.


## Glyph Output (On-Screen Keyboard and Layout Sheet)
Since package 5b, the on-screen keyboard draws labels via `cairo_show_glyphs` instead of `cairo_show_text`, because characters beyond the Basic Multilingual Plane (BMP) break otherwise. Getting there involved three traps, each of them silently wrong – none of them fails with an error.

### UTF-16 code units instead of code points
`GetGlyphIndices` and Cairo's Win32 text path (used internally by `cairo_show_text`) both operate on UTF-16 **code units**, not code points. A character beyond the BMP consists of a surrogate pair, i.e. two code units; only the first one, the high half, gets looked up – which is not a valid character on its own. The result is the tofu box, indistinguishable from a character the font genuinely doesn't have.

**Workaround**: obtain glyph indices yourself, at the code-point level, and draw with `cairo_show_glyphs` (`source/fontchain.d`, `source/osk.d`).

### GDI is not an option
The obvious way out would have been direct GDI output (`ExtTextOutW`) – GDI understands code points, so the problem above wouldn't apply. It fails for a different reason: the on-screen keyboard is a layered window, drawn via `UpdateLayeredWindow` with `ULW_ALPHA`. GDI does not write the alpha channel; text drawn via GDI would be invisible or corrupted. Cairo rasterizes itself and writes alpha correctly – which is why Cairo stays in the picture despite the code-unit problem above.

### Uniscribe: `S_OK` is not success
The obvious way to get glyph indices at the code-point level is Uniscribe (`usp10.dll`): `ScriptGetCMap` takes a UTF-16 string **with a length** and can therefore handle surrogate pairs correctly. It was built first – then measured against ten installed fonts and ten code points beyond the BMP, with a throwaway console program. Result: `ScriptGetCMap` returns a real glyph for a character beyond the BMP in **none** of the ten fonts – either `S_FALSE`, or `S_OK` with the blank glyph. Even the bundled font answered this way for its own target character (chess, U+1FA00). `S_OK` proves nothing here; a caller that only checks the return value mistakes a failure for a success.

The glyph is genuinely present in the font, though – read directly, the `cmap` table of Segoe UI Symbol carries glyph 7721 for U+1D504, for example. The Uniscribe call simply fails to find it. The second Uniscribe route (`ScriptItemize` + `ScriptShape`) only succeeds with shaping switched off (the documented fallback to `eScript = SCRIPT_UNDEFINED`) and fails for the bundled font even on a BMP character (`USP_E_SCRIPT_NOT_IN_FONT`).

**Decision**: Uniscribe is dropped entirely. `source/cmap.d` reads a font's `cmap` table (format 12, otherwise format 4) directly from the bytes `GetFontData` returns – plain byte arithmetic, no Win32 call with an ambiguous answer. Measured: the same glyph as via Uniscribe in all 100 checked combinations, wherever Uniscribe returned one at all. Side benefit: a cmap reader can be tested against a font file that lives in the repo (`fonts/NotoSansSymbols2-Regular.ttf`), even where no Windows fonts are installed (`tools/verify-linux.sh` under Wine) – Uniscribe would not have been testable there at all.

### Light/dark without `prefers-color-scheme`
A Win32 window has no equivalent of `prefers-color-scheme` – unlike the layout sheet (an HTML page), the on-screen keyboard cannot simply query a media query. The `Sachlich` color scheme therefore reads the registry value `AppsUseLightTheme` under `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` once at startup and again on every `WM_SETTINGCHANGE` (Windows reports the switch between light and dark app mode through that message) – the only practical way to catch a live switch without querying the registry on every draw.

## Base Layers and Character Keys

On layers 1 and 2, letters, digits, and most punctuation deliberately exist as a **VK mapping**, not a char mapping. The reason is not convenience but necessity: a VK mapping lets Windows see a real keypress (`VK_KEY_E` instead of a Unicode packet for "e"). Only that keeps keyboard shortcuts working that rely on *which key was pressed* rather than on the character it produces – Ctrl+C, Alt+Tab, practically every game. A char mapping sends a Unicode packet instead; to a program listening for `VK_KEY_C` held with Ctrl, a key that merely types "c" is invisible. **Switching a base-layer key to `"char"` makes it blind to exactly those shortcuts.** This is not a rendering detail but a property of the layout data, and package 5c does not touch it anywhere.

For the *display* (on-screen keyboard, layout sheet), the VK-versus-char distinction is nonetheless the wrong question. What matters is what actually comes out when the key is typed, not how the layout encodes it internally. Since package 5c, `keyboardview.describeKey` answers that via the **keysym**: if `keysymdef.h` assigns a Unicode code point to a VK mapping's keysym (`keysyms.codepointsByKeysym`), the key produces a character and is drawn as one, regardless of the mapping type. A VK key with forced modifiers (`"mods"`) is exempt – it sends a shortcut like Ctrl+Z no matter what its keysym says.

The numpad is a case of its own here: `keysymdef.h` assigns no code point to the `KP_` keysyms, even though most of these keys do produce characters. `keyboardview.keypadChar` covers that with a small fixed table – and deliberately returns the **produced** character, not the label. The numpad's multiply key is labelled "×" (U+00D7) but types "*" (U+002A); the divide key is labelled "÷" (U+00F7) but types "/" (U+002F). Deriving the code point from the label instead of the table would print a falsehood on the sheet – visually unremarkable, since both characters serve the same purpose, but technically wrong.

## Compose Grammar

Since the grammar round the project's own compose entries follow one rule: **a sequence starts with a modifier, then comes the base.** The modifier says *what* happens to the character, the base says *to which one*. Two conditions follow that every own table must satisfy: (1) a node on the way to the base carries **no** result of its own – otherwise it would be a dead end and the sequence could not be extended; (2) the base is a **single character**, so the branch reads uniformly.

There are six modifiers, each on layer 21 of `AnNoted`, on the initial letter of its category:

| Character | Code point | Key | Category |
|---|---|---|---|
| `𝔵` | U+1D535 | S | font variant (Schriftvariante) |
| `ⓧ` | U+24E7 | E | enclosure (Einkreisung) |
| `↻` | U+21BB | D | rotation (Drehung) |
| `ₓ` | U+2093 | T | subscript (Tiefstellung) |
| `˞` | U+02DE | R | retroflex hook |
| `ˣ` | U+02E3 | H | superscript (Hochstellung) |

Layer 21 hangs off `Mod3+Mod4` and carries the marker `"ignoreLocks": true` in `layouts.json`. Without it the layer would be unreachable inside any locked block: `layerlock.determineLayer` discards a layer that does not mention a currently locked Neo modifier at all ("locked-not-don't-care"), and layer 21 deliberately does not mention the block modifiers. It still shadows nothing, because it is the **last** entry and requires `Mod3` and `Mod4` together – a combination no earlier layer matches. The trigger `{"chord": "Mod3+Tab", "action": "compose"}` exists for the same reason: a trigger runs before layer determination, whereas the `Multi_key` on layer 3 of the Tab key is lost whenever a layer is locked.

**The font table is computed, not maintained.** `compose/ananeo-schrift.module` (1,073 entries under `𝔵`: 1,047 characters and 26 macro lines) is generated from `source/schriftvarianten.d` via `ananeo-tool compose gen-schrift`; a guard test keeps file and computation together. Each line reads `<U1D535> <family letter> [<slash>] <base> : "character" UXXXX` – an upper-case family letter means bold, a `/` before the base means italic (`a` antiqua, `s` script, `r` fraktur, `d` double-struck, `l` sans-serif, `m` monospace). A seventh family letter falls outside that notation: `c` is not a family but the **chancery variant of script** – the same 26 capitals followed by variation selector U+FE00 (`𝔵 c A` → `𝒜︀`, two code points, both named after the string). Unicode has only one script block; whether `𝒜` renders as `\mathcal` or `\mathscr` is up to the font, and the standardized variation sequences (Unicode 14, `data/StandardizedVariants.txt`) exist for the capitals only – hence no lower-case letters. A dedicated watchdog holds the row exactly against the 26 `chancery style` lines of that file. The upper-case `C` – which the notation would read as "bold chancery", a thing that does not exist – instead types the **LaTeX macro as text**: `𝔵 C A` → `\mathcal{A}`. Reason: KaTeX (measured with 0.16.11 and 0.18.5) renders every Unicode script letter as `\mathscr` and ignores the selector; in a KaTeX field only the macro reaches `\mathcal`. Inside the XCompose string the backslash is written `\\`. Characters are written as `<UXXXX>` rather than as named keysyms, so the file does not depend on `keysymdef.h` and Latin, Greek, and the variant forms all take the same shape.

Two peculiarities of the Unicode block are baked into the computation and cannot be derived: **24 slots are missing from the block** because the character lives in "Letterlike Symbols" (`ℬ`, `ℭ`, `ℂ`, …, and U+210E is named PLANCK CONSTANT) – they are listed in `ausnahme()`. And the **58 Greek base slots** follow a fixed order with foreign bodies in it: the theta symbol `ϴ` sits among the capitals, nabla `∇` and the partial differential `∂` sit in the middle of the run. Guessing the order yields code points that are all assigned but all wrong – hence the watchdog against UCD 17.0.0 in the same module.

## Privilege Levels
### Elevated Windows
Windows does not let a low-level keyboard hook from a non-elevated process affect windows belonging to an elevated process (User Interface Privilege Isolation). If AnaNeo runs without administrator rights, it therefore has no effect in a terminal, editor, or installer started as administrator – with no error message, no log entry, and no change to the tray icon.

In extension mode this is easy to notice too late: there the native driver (`kbdnoted.dll` and relatives) does the layer work at driver level, and UIPI does not apply to it. So in an elevated window the usual characters keep appearing, while everything AnaNeo itself contributes – compose, capslock, layer 4 navigation, sending characters beyond the BMP – silently fails. In standalone mode there is no driver to step in; there, nothing happens at all.

**Workaround**: None in code. Anyone who wants to use AnaNeo with elevated windows has to start AnaNeo elevated as well. More important is the consequence for testing: **manual tests belong in a non-elevated window.** A result from an administrator terminal is worthless, and in both directions – a keystroke passed through unchanged looks exactly like a correctly processed one.
