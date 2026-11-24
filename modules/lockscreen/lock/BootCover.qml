pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// =============================================================================
// BootCover.qml -- the tty's black, held over the workspace while a boot lock asks for the session (LockRoot,
// THE COVER).
//
// WHY. Hyprland (0.57, Renderer.cpp) draws a locked session's WORKSPACE -- the wallpaper, every layer -- from the moment a
// locker asks (`ext_session_lock_manager_v1.lock`: a fresh lock, `lockdead_screen_delay` not yet run out, `locked` not
// yet sent) until that locker's surface has drawn on every output, and no black primer under it. A lock surface's first
// commit must carry a buffer, so that span is at least one round of the client's first frame; any frame the compositor
// draws in it is the desktop. At a real boot it draws plenty (hyprpaper maps and fades the wallpaper in, themectl sets it
// again, the cursor theme is set): the user filmed 3-7 frames of the wallpaper between the tty's black and the veil. A
// relaunched or replaced lock has the same span, over the live desktop.
//
// WHAT. One opaque black layer surface per output on the Overlay layer, MAPPED before the lock asks: in that span the
// workspace Hyprland draws is this cover over everything else, so the screen stays black. Before the request the session
// is held by --locked-cmd (or the lockdead screen), and the workspace is not drawn at all; after `locked` it is not drawn
// either (xray is off at boot), so the cover is never seen and goes once the lock is secure.
//
// MAPPED, NOT COMMITTED. A frame the cover has swapped is not yet on the compositor's side: Hyprland holds a dmabuf
// commit until the buffer's GPU fence is readable (Compositor.cpp, LOCK_REASON_FENCE) and acts on the lock's request at
// once, so a request sent on the cover's `frameSwapped` could still win (one boot film in sixteen drew a frame of the
// wallpaper so). Hyprland lists a layer in `hyprctl -j layers` only once it is mapped (Commands.cpp: "Don't add the layer
// prematurely"), so after its first frame the cover asks the compositor until every output's cover is listed: `ready`.
// It must be opaque in its FIRST mapped frame, so the supervisor sets a `no_anim` layer rule for its namespace before
// every launch (tools/lockscreen/lares-lock: a layer fades in over ~0.5 s otherwise; hyprctl reports the fade's goal, not
// where it stands). It takes no input and no keyboard. When hyprctl does not answer, LockRoot's failsafe asks anyway.
// =============================================================================
Scope {
    id: root

    readonly property string namespace: "lares-lock-cover"
    // every screen's cover is mapped (listed by the compositor)
    readonly property bool ready: root._mapped
    // ms from the cover's creation to its first swapped frame and to the compositor listing it (for the log)
    readonly property real swappedMs: root._swappedAt > 0 ? root._swappedAt - root._bornAt : -1
    readonly property real mappedMs: root._mappedAt > 0 ? root._mappedAt - root._bornAt : -1

    readonly property int _want: Math.max(1, Quickshell.screens.length)
    property int _shown: 0
    property bool _mapped: false
    property real _bornAt: Date.now()
    property real _swappedAt: 0
    property real _mappedAt: 0

    on_ShownChanged: {
        if (root._shown >= root._want && root._swappedAt === 0) {
            root._swappedAt = Date.now();
            layers.running = true;
        }
    }

    // The compositor's word: how many covers it has mapped.
    Process {
        id: layers
        command: ["hyprctl", "-j", "layers"]
        stdout: StdioCollector {
            id: layersOut
        }
    }
    Connections {
        target: layers
        function onExited() {
            let n = 0;
            try {
                const mons = JSON.parse(String(layersOut.text));
                for (const m of Object.values(mons))
                    for (const level of Object.values(m.levels || {}))
                        for (const l of level)
                            if (l.namespace === root.namespace)
                                n++;
            } catch (e) {}
            if (n >= root._want) {
                root._mappedAt = Date.now();
                root._mapped = true;
            } else {
                again.start();
            }
        }
    }
    Timer {
        id: again
        interval: 8
        onTriggered: layers.running = true
    }

    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: cover
            required property var modelData
            property bool _counted: false
            screen: cover.modelData
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: root.namespace
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            color: "black"
            mask: Region {}

            Item {
                id: body
                anchors.fill: parent
            }
            Connections {
                target: body.Window.window
                function onFrameSwapped() {
                    if (cover._counted)
                        return;
                    cover._counted = true;
                    root._shown++;
                }
            }
        }
    }
}
