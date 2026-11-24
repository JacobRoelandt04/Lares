pragma ComponentBehavior: Bound

import QtQuick
import "../../common/system"

import "SourceGlyphs.js" as G
import "ScreenshotPolicy.js" as Shots

// =============================================================================
// ScreenshotNotifier.qml -- a screenshot was taken (source "screenshot"; SOURCES.md, "Later sources").
//
// The capture script tells the OSD (`quickshell ipc call osd capture shot <path> copied|plain`, tools/osd/shot.sh) and the
// OSD's CaptureSource announces it with a `request`; this source listens to that one signal -- no file watching, no
// grim -- and says: the picture itself on the card (its band: a click on it is the card's own, Open), the file's name,
// whether it was copied, and three buttons (and a trash icon after them): Open and Edit (osd.jsonc capture.openCommand / editCommand, by
// default xdg-open and swappy, whose Save writes over the shot: the capture source's argv, the card's own), Copy path (wl-copy). The buttons leave
// the card where it is (it is resident): a click on Copy path is not a dismissal.
//
// IT MUST NOT DOUBLE THE OSD'S CARD. The capture card already shows the shot; so by default (`toast: "auto"`) this
// notification is FILED silently while the OSD routes its capture card to the screen (it waits in the manager with its
// buttons, seen, no second popup over the same picture), stays out when the OSD posts a plain notification of its own,
// and toasts only where the OSD says nothing. ScreenshotPolicy has the table; "always" and "never" are the user's.
// Recordings and "copied" labels are the OSD's alone.
// `osd` is the shell's OsdService (null: this source is off).
// =============================================================================
SourceBase {
    id: src

    sourceId: "screenshot"
    appName: "Screenshot"
    glyph: G.screenshot
    keys: ["shot"]

    // What the trash button runs (a probe's seam): the OSD card's trash icon and swappy's delete button run the same.
    property string trashHelper: RepoRoot.dir + "/tools/notifications/shot_trash.sh"

    // The OsdService: its capture source's `request`, and its config's route for the capture card.
    property var osd: null
    ready: !!src.osd && !!src.osd.sources && !!src.osd.sources.capture

    function _route() {
        return Shots.route(src.osd && src.osd.config ? src.osd.config.config : null);
    }

    // The shot was deleted (the trash icon of the card, of this notification, or of swappy): its notification has nothing left to
    // show, so it goes. Said by shot_trash.sh through the OSD's `capture deleted <path> ""` (CaptureSource.deleted).
    function _gone(path) {
        if (src.active && path)
            src.withdraw(Shots.key(path));
    }

    function _shot(req) {
        if (!src.active)
            return;
        const s = Shots.shot(req);
        if (s === null)
            return;
        const mode = Shots.mode(src.settings.toast, src._route());
        if (mode === "none")
            return;
        const t = Shots.text(s);
        const cap = src.osd.sources.capture;
        // FILED silently: the service files what its source is `attended` for, so the post is made inside that.
        src.attended = mode === "file";
        src.post(Shots.key(s.path), {
            title: t.title, body: t.body, urgency: "low", image: s.path, resident: true,
            actions: [
                { id: "open", label: "Open", run: () => src.host.run(cap.openArgv(s.path)) },
                { id: "edit", label: "Edit", run: () => src.host.run(cap.editArgv(s.path)) },
                { id: "copypath", label: "Copy path", run: () => src.host.run(["wl-copy", s.path]) },
                // an icon-only button: to the Trash (recoverable), no editor; the shot's card then leaves (withdraw above)
                { id: "trash", label: "Move to Trash", icon: G.trash, run: () => src.host.run([src.trashHelper, s.path]) }
            ],
            onDefault: () => src.host.run(cap.openArgv(s.path))
        });
        src.attended = false;
    }

    Connections {
        target: src.osd && src.osd.sources ? src.osd.sources.capture : null
        ignoreUnknownSignals: true
        function onRequest(req) {
            src._shot(req);
        }
        function onDeleted(path) {
            src._gone(path);
        }
    }
}
