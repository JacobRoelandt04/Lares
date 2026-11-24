// qmllint disable import unresolved-type
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

// =============================================================================
// DictationShortcuts.qml -- the dictation's four keys, Hyprland global shortcuts of the appid "lares" (registered once per
// shell: ShellServices builds one, beside OsdShortcuts). Each press toggles a take (DictationService.toggleMode); any of them stops
// whatever take runs. With shell.jsonc dictation.key "hold" the first two take while they are held (DictationService, HOLD):
//
//   dictate          fn+F10 (XF86Launch5, the laptop's microphone key)   into the focused field, English or Dutch detected
//                                                                        (dictation.language forces one)
//   dictate-nl       Shift + fn+F10                                      the same in Dutch, no detection (dictation.altLanguage)
//   dictate-source   Ctrl + fn+F10 (round 5)                             the focused window's sound, transcribed (a caption card,
//                                                                        the transcript on the clipboard at the stop)
//   dictate-ask      Alt + fn+F10 (round 5)                              a spoken question for the local model (LlmService.voiceAsk)
//
// THE BINDS (tools/shell/lares BINDS_TABLE; lines of the user's keybinds.lua, which `lares binds` prints and checks):
//   hl.bind("XF86Launch5", hl.dsp.global("lares:dictate"))
//   hl.bind("SHIFT + XF86Launch5", hl.dsp.global("lares:dictate-nl"))
//   hl.bind("CTRL + XF86Launch5", hl.dsp.global("lares:dictate-source"))
//   hl.bind("ALT + XF86Launch5", hl.dsp.global("lares:dictate-ask"))
// Not `locked`: no dictation over the lock screen. A global bind gives one press and one release and never repeats (CLAUDE.md);
// `hyprctl dispatch` of one gives no release (a held take then lasts until the next press). With the switch off a press does nothing but one toast a session (DictationService).
//
// The linter cannot resolve GlobalShortcut (Quickshell's _GlobalShortcuts qmldir: OsdShortcuts has the note); it resolves at run time.
// =============================================================================
Scope {
    id: root

    property var service: null
    property bool enabled: true

    // For a probe: the presses that arrived, oldest first.
    property var presses: []

    function press(name: string): void {
        root.presses = root.presses.concat([name]);
        const s = root.service;
        if (!s)
            return;
        if (name === "dictate-source" || name === "dictate-ask") {
            s.toggleMode(name === "dictate-source" ? "source" : "ask", "");
            return;
        }
        const lang = name === "dictate-nl" ? s.config.altLanguage : s.config.language === "auto" ? "" : s.config.language;
        if (s.config.key === "hold")
            s.holdPress(lang);
        else
            s.toggleMode("type", lang);
    }
    function release(): void {
        if (root.service)
            root.service.holdRelease();
    }

    LazyLoader {
        active: root.enabled
        Scope {
            GlobalShortcut {
                appid: "lares"
                name: "dictate"
                description: "Dictation: start or stop (English or Dutch, detected)"
                onPressed: root.press("dictate")
                onReleased: root.release()
            }
            GlobalShortcut {
                appid: "lares"
                name: "dictate-nl"
                description: "Dictation in Dutch: start or stop"
                onPressed: root.press("dictate-nl")
                onReleased: root.release()
            }
            GlobalShortcut {
                appid: "lares"
                name: "dictate-source"
                description: "Transcribe the focused window's sound: start or stop"
                onPressed: root.press("dictate-source")
            }
            GlobalShortcut {
                appid: "lares"
                name: "dictate-ask"
                description: "Ask the local model by voice: start or stop"
                onPressed: root.press("dictate-ask")
            }
        }
    }
}
