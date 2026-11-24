pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "../../../common/system"

// =============================================================================
// CaptureSource.qml -- screenshot and recording confirmations. IPC only:
// nothing here can see a capture, so whoever made it says so
// (`quickshell ipc call osd capture ...`, tools/osd/shot.sh, a recording script).
//
//   capture(what, a, b)        ("shot", path, "copied"|"plain")
//                              ("rec", "start"|"stop", path)
//                              ("copied", label)
//   signal request(var req)    one partial CONTRACT section 1 request
//
// `copied` is true only for a shell or screenshot copy, which is what the card
// says "copied" for; the thumbnail of a shot is its own file. Nothing here touches
// the file or the clipboard.
//
//   open(path)                 what osd.jsonc's capture.openCommand says (a click on the card with capture.click "open", the
//                              notification's Open), started as `edit` is
//   edit(path)                 a click on the capture card, the notification's Edit: capture.editCommand, and with none swappy on that
//                              shot, through the ONE helper (tools/notifications/shot_edit.sh), so that its Save writes OVER the shot,
//                              not a new file on the desktop. Started detached (its own session, no pipes of the shell's): an edit
//                              in progress survives the shell's restart, as the lock does (CommandRunner).
//                              `live: false` records the call (`edits`) and starts nothing.
//   trash(path)                the trash icon on a screenshot's card (and the notification's): the ONE helper
//                              (tools/notifications/shot_trash.sh: `gio trash`, then `quickshell ipc call osd capture
//                              deleted <path>`) -- the editor's delete button runs the same, so the card, the manager
//                              and the editor all end in the same "deleted". Started detached like `edit`; `live:
//                              false` records the call and starts nothing.
//   capture("deleted", path)   the shot is gone (said by that helper): NOT a card (pressing the trash
//                              closes the OSD as the confirmation, and a "Screenshot deleted" card behind it would be a
//                              second 3.5 s one). It is the signal `deleted(path)`: the owner takes down the shot's card if
//                              it is still up, the shot's notification leaves the manager (ScreenshotNotifier).
// =============================================================================
Item {
    id: root

    signal request(var req)
    // A shot is gone (the trash helper told the shell): no card, only this.
    signal deleted(string path)

    property bool live: true
    // osd.jsonc capture.openCommand / editCommand (argv; {path} is the picture); an empty editCommand is the helper.
    property var openCommand: ["xdg-open", "{path}"]
    property var editCommand: []
    // The program that opens a shot for editing (a probe's seam), and every path asked for, oldest first.
    property string editHelper: RepoRoot.dir + "/tools/notifications/shot_edit.sh"
    function _argv(template, path) {
        return Array.from(template, a => a.split("{path}").join(path));
    }
    function openArgv(path) {
        return root._argv(root.openCommand, path);
    }
    function editArgv(path) {
        return root.editCommand.length > 0 ? root._argv(root.editCommand, path) : [root.editHelper, path];
    }
    readonly property var edits: root._edits
    property var _edits: []
    // The program that moves a shot to the Trash (a probe's seam), and every path asked for.
    property string trashHelper: RepoRoot.dir + "/tools/notifications/shot_trash.sh"
    property var _trashes: []

    function trash(path) {
        const p = path === undefined || path === null ? "" : String(path);
        if (p.length === 0)
            return false;
        root._trashes = root._trashes.concat([p]);
        if (root.live)
            trashProc.run(p);
        return true;
    }
    Process {
        id: trashProc
        function run(p) {
            trashProc.command = ["setsid", "-f", "sh", "-c", "exec \"$@\" </dev/null >/dev/null 2>&1", "sh", root.trashHelper, p];
            trashProc.running = true;
        }
    }

    function edit(path) {
        const p = path === undefined || path === null ? "" : String(path);
        if (p.length === 0)
            return false;
        root._edits = root._edits.concat([p]);
        if (root.live)
            editProc.run(root.editArgv(p));
        return true;
    }
    function open(path) {
        const p = path === undefined || path === null ? "" : String(path);
        if (p.length === 0)
            return false;
        if (root.live)
            editProc.run(root.openArgv(p));
        return true;
    }
    Process {
        id: editProc
        function run(argv) {
            // `setsid -f` returns at once and the child lives on with nothing of the shell's attached (CommandRunner._detach)
            editProc.command = ["setsid", "-f", "sh", "-c", "exec \"$@\" </dev/null >/dev/null 2>&1", "sh"].concat(argv);
            editProc.running = true;
        }
    }

    function capture(what, a, b) {
        const A = a === undefined || a === null ? "" : String(a);
        const B = b === undefined || b === null ? "" : String(b);
        let c = null;
        if (what === "shot")
            c = { what: "shot", path: A, thumb: A.length > 0 ? "file://" + root._encode(A) : "", copied: B === "copied", label: "" };
        else if (what === "rec" && (A === "start" || A === "stop"))
            c = { what: A === "start" ? "rec-start" : "rec-stop", path: B, thumb: "", copied: false, label: "" };
        else if (what === "deleted") {
            if (A.length === 0)
                return false;
            root.deleted(A);
            return true;
        } else if (what === "copied")
            c = { what: "copied", path: "", thumb: "", copied: true, label: A };
        if (c === null)
            return false;
        root.request({ kind: "capture", key: c.what, source: "ipc", capture: c });
        return true;
    }

    // A file URL: every byte that is not a path character is escaped.
    function _encode(path) {
        return path.split("/").map(s => encodeURIComponent(s)).join("/");
    }
}
