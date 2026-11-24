// qmllint disable import unresolved-type required
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

// =============================================================================
// OsdShortcuts.qml -- the hardware keys, as Hyprland global shortcuts
// (CONTRACT section 11, appid "lares"). Each one hands its press and its
// release to the OsdService, which changes the value, repeats a held key at the
// compositor's own delay and rate, and asks for the card.
//
//   property var service     the OsdService
//   property bool enabled    register the shortcuts (default true)
//
// A GLOBAL BIND GIVES ONE pressed() AND ONE released(): the compositor does not
// repeat it, so no `repeating = true` in the bind (it would send a press per
// repeat and no way to tell a held key from a tapped one -- the boost gate needs
// exactly that). The shell's repeat is OsdService's; a release that never
// comes is cut there after holdMaxMs. `hyprctl dispatch` of a global gives a
// press and NO release, which is why that cut exists.
//
// THE BINDS (Hyprland's Lua config, ~/.config/hypr/config/keybinds.lua;
// `hl.dsp.global("<appid>:<name>")` takes ONE string, verified against the live
// compositor: a table is "bad argument 1: expected string, got table"):
//
//   local function osd(name) return hl.dsp.global("lares:" .. name) end
//   local K = { locked = true }          -- also while the session is locked
//
//   hl.bind("XF86AudioRaiseVolume",         osd("osd-volume-up"),              K)
//   hl.bind("XF86AudioLowerVolume",         osd("osd-volume-down"),            K)
//   hl.bind("XF86AudioMute",                osd("osd-volume-mute"),            K)
//   hl.bind("XF86AudioMicMute",             osd("osd-mic-mute"),               K)
//   hl.bind("XF86MonBrightnessUp",          osd("osd-brightness-up"),          K)
//   hl.bind("XF86MonBrightnessDown",        osd("osd-brightness-down"),        K)
//   hl.bind("SHIFT + XF86MonBrightnessUp",  osd("osd-brightness-up-fine"),     K)
//   hl.bind("SHIFT + XF86MonBrightnessDown",osd("osd-brightness-down-fine"),   K)
//   hl.bind("XF86KbdBrightnessUp",          osd("osd-kbd-up"),                 K)
//   hl.bind("XF86KbdBrightnessDown",        osd("osd-kbd-down"),               K)
//   hl.bind("XF86AudioNext",                osd("osd-media-next"),             K)
//   hl.bind("XF86AudioPrev",                osd("osd-media-prev"),             K)
//   hl.bind("XF86AudioPlay",                osd("osd-media-toggle"),           K)
//   hl.bind("XF86AudioPause",               osd("osd-media-toggle"),           K)
//   hl.bind("XF86AudioStop",                osd("osd-media-stop"),             K)
//   -- Caps / Num lock: the key must still reach the application, so the bind
//   -- does not consume it (`non_consuming`). A lock key's own modifier is held
//   -- while the key is down, and Hyprland 0.57 matches binds with the key
//   -- applied: the press is CAPS + Caps_Lock / MOD2 + Num_Lock whichever way
//   -- the lock goes, and a bind of the plain key never fires
//   -- (tools/dev/osd_lockkeys_probe.sh presses the real keycodes).
//   hl.bind("CAPS + Caps_Lock", osd("osd-lockkeys"), { non_consuming = true })
//   hl.bind("MOD2 + Num_Lock",  osd("osd-lockkeys"), { non_consuming = true })
//
// The Fn+F-key names above are what this laptop's keys send; XF86Kbd* and the
// media keys are the usual names -- `wev` settles any that is wrong.
//
// The linter cannot resolve GlobalShortcut ("PostReloadHook was not found"):
// Quickshell 0.3.1's _GlobalShortcuts qmldir does not declare `depends
// Quickshell`. It resolves at runtime (LauncherBarOwner has the same note), so
// the three warnings that follow from it are switched off for this file.
// =============================================================================
Scope {
    id: root

    property var service: null
    property bool enabled: true

    // name -> what it does. `hold`: the service repeats it while down.
    readonly property var table: [
        { name: "osd-volume-up",              what: "Volume up",                 call: "volume",     verb: "up",        hold: true },
        { name: "osd-volume-down",            what: "Volume down",               call: "volume",     verb: "down",      hold: true },
        { name: "osd-volume-mute",            what: "Mute the output",           call: "volume",     verb: "mute",      hold: false },
        { name: "osd-mic-mute",               what: "Mute the microphone",       call: "mic",        verb: "mute",      hold: false },
        { name: "osd-brightness-up",          what: "Brightness up",             call: "brightness", verb: "up",        hold: true },
        { name: "osd-brightness-down",        what: "Brightness down",           call: "brightness", verb: "down",      hold: true },
        { name: "osd-brightness-up-fine",     what: "Brightness up, fine",       call: "brightness", verb: "up-fine",   hold: true },
        { name: "osd-brightness-down-fine",   what: "Brightness down, fine",     call: "brightness", verb: "down-fine", hold: true },
        { name: "osd-kbd-up",                 what: "Keyboard light up",         call: "kbd",        verb: "up",        hold: false },
        { name: "osd-kbd-down",               what: "Keyboard light down",       call: "kbd",        verb: "down",      hold: false },
        { name: "osd-lockkeys",               what: "Caps / Num lock changed",   call: "lockkeys",   verb: "",          hold: false },
        { name: "osd-media-next",             what: "Next track",                call: "media",      verb: "next",      hold: false },
        { name: "osd-media-prev",             what: "Previous track",            call: "media",      verb: "prev",      hold: false },
        { name: "osd-media-toggle",           what: "Play / pause",              call: "media",      verb: "toggle",    hold: false },
        { name: "osd-media-stop",             what: "Stop",                      call: "media",      verb: "stop",      hold: false }
    ]

    // One entry's press / release, as the service sees them.
    function press(entry) {
        const s = root.service;
        if (!s)
            return;
        if (entry.call === "lockkeys")
            s.lockkeys();
        else
            s[entry.call](entry.hold ? "press-" + entry.verb : entry.verb);
    }
    function release(entry) {
        const s = root.service;
        if (!s)
            return;
        // a lock turns OFF at its key's release
        if (entry.call === "lockkeys")
            s.lockkeysReleased();
        else if (entry.hold)
            s[entry.call]("release-" + entry.verb);
    }

    LazyLoader {
        active: root.enabled
        component: Scope {
            Instantiator {
                model: root.table
                delegate: GlobalShortcut {
                    required property var modelData
                    appid: "lares"
                    name: modelData.name
                    description: modelData.what
                    onPressed: root.press(modelData)
                    onReleased: root.release(modelData)
                }
            }
        }
    }
}
