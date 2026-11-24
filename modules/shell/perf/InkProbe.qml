pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/flourish"
import "../../common/theme"

// =============================================================================
// InkProbe -- the gate's eye on THE INK (GooeyInk; tools/dev/visible_ink_probe.sh). Built only when the shell is started with
// LARES_INK_PROBE=<dir> (ShellScreen's Loader); nothing of it exists otherwise.
//
// It numbers the window's frames (at every `afterAnimating`) and draws the number into the frame itself: 16 cells of 3 x 3 px,
// opaque white for a 1 and black for a 0, at the window's bottom right corner (the gate leaves that box out). It writes the
// window's visible region to the log whenever it changes, stamped with the frame it goes out with:
//     INKP R <frame> whole | empty | [{"x":..,"y":..,"w":..,"h":..}, ...]
// (every change after a frame's `afterAnimating` goes out with the next frame: its polish is where the region is sent), and it
// grabs the whole window as often as a grab can be had (<dir>/g<n>.png). The gate reads each picture's own frame number off its
// cells and holds every pixel with alpha above 0 to the region that frame was drawn under: ink the compositor would have cut.
// IPC target `inkprobe`: `mark <name>` names the tour's step from this frame on, `reel <key> 1|0` brings a reel's strip out / in,
// `flourish` plays every glyph flourish of the shell at once (FlourishRegistry, as a hover plays them).
// =============================================================================
Item {
    id: probe

    // the window's content item (what is grabbed) and the region's state
    required property Item grabItem
    required property var ink
    // "whole" (no region: the whole surface), "empty" (parked), "rects"
    required property string mode
    required property string dir
    // the screen's ShellFrame (its reels, for `reel`)
    required property var frame

    property int frameNo: 0
    property string _last: ""
    property bool _pending: false
    property int _grabs: 0

    // (placed by its Loader: the window's bottom right corner)
    width: 48
    height: 3

    Repeater {
        model: 16
        delegate: Rectangle {
            required property int index
            x: index * 3
            width: 3
            height: 3
            color: ((probe.frameNo >> index) & 1) ? "white" : "black"
        }
    }

    function _state(): string {
        return probe.mode === "rects" ? JSON.stringify(probe.ink.rects) : probe.mode;
    }
    function _record(stamp: int): void {
        const s = probe._state();
        if (s === probe._last)
            return;
        probe._last = s;
        console.log("INKP R " + stamp + " " + s);
    }
    Connections {
        target: probe.Window.window
        function onAfterAnimating() {
            probe.frameNo = (probe.frameNo + 1) & 0xffff;
            probe._record(probe.frameNo);
        }
    }
    // `afterAnimating` comes AFTER the frame's polish and the animations advance right after its sync: whatever changes from then on
    // (a handler, a timer, the next tick, the next polish) goes out with the next frame.
    function _changed(): void {
        probe._record((probe.frameNo + 1) & 0xffff);
    }
    onModeChanged: probe._changed()
    // the theme's crossfade, for the log (the region is the whole window while it runs)
    Connections {
        target: Theme
        function onCrossfadingChanged() {
            console.log("INKP T " + probe.frameNo + " crossfading " + Theme.crossfading);
        }
    }
    Connections {
        target: probe.ink
        function onRectsChanged() {
            probe._changed();
        }
    }
    Timer {
        interval: 30
        repeat: true
        running: true
        onTriggered: {
            if (probe._pending || !probe.grabItem)
                return;
            probe._pending = true;
            const n = probe._grabs++;
            const ok = probe.grabItem.grabToImage(r => {
                r.saveToFile(probe.dir + "/g" + String(n).padStart(6, "0") + ".png");
                probe._pending = false;
            });
            if (!ok)
                probe._pending = false;
        }
    }
    IpcHandler {
        target: "inkprobe"
        // a named step of the tour from this frame on: `INKP M <frame> <name>`
        function mark(name: string): string {
            console.log("INKP M " + probe.frameNo + " " + name);
            return String(probe.frameNo);
        }
        // a reel's strip out ("1") or in ("0"): `power`, `idle` (ReelBarModule.openPopup / closePopup)
        function reel(key: string, open: string): string {
            const r = probe.frame && probe.frame.owners ? probe.frame.owners[key] : null;
            if (!r || typeof r.openPopup !== "function")
                return "none";
            if (open === "1")
                r.openPopup();
            else
                r.closePopup();
            return r.reelOpen ? "open" : "shut";
        }
        function flourish(): string {
            let n = 0;
            for (const e of FlourishRegistry.entries)
                if (e.demo())
                    n++;
            return String(n);
        }
    }
}
