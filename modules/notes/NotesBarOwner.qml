pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

import "../common/float"
import "browse"

// =============================================================================
// NotesBarOwner.qml -- the notes popup's bar-side owner.
//
// The bar engine builds a popup's content on open and destroys it on close,
// so what must outlive the popup lives here: the NotesStore (the view, the
// open documents and their undo, the sizes, the session) and the tunables
// the popup is built with. The ClockBarOwner pattern.
//
//   toggle() / open() / close()   from the bar button (a click: the pointer
//                                 rests on the bar, so the popup may take the
//                                 keyboard with the short pulse NotesPopup does)
//   shortcutPressed()             the shell's Alt+N: opens a KEY-opened popup,
//                                 closes it when it is already out (below)
//   springLoad()                  a file dragged onto the bar button opens the
//                                 popup so it can be dropped on it (never on a new note)
//
// Everything is written the moment the popup stops being ours.
//
//   shown / floatStyle            the tiles' float (modules/common/float): it runs while the
//                                 popup is on screen (present, `shown`, its window visible),
//                                 with the notes' numbers (NotesFloatStyle; the mockup hands its own)
//
// THE STORE. `store` hands an injected NotesStore in (the shell holds ONE for every
// screen; its files are the user's notes, and a second store would watch the same
// folder twice); null builds the owner's own from `notesRoot` / `statePath`.
// `activeStore` is the one in use. Hosted (`shellHosted`, CONTRACT section
// 4) the owner builds none, whatever `store` is: a null one is a feature that is absent.
// There is nothing to aggregate (`sharedFlags` is empty: the store's state is the
// store's, once) and nothing to route but the shortcut.
//
// OPENED BY A KEY. A popup opened by Alt+N has no pointer on it, and the pulse would
// hand the keyboard straight back to whatever window lies under the pointer.
// So `shortcutPressed()` opens it with the keyboard held by a
// HyprlandFocusGrab over the host's `grabWindows` (the bar window of this screen):
// the keys come to the popup whatever the surface's keyboard mode, and a click outside
// clears the grab, which closes the popup (as the clipboard shelf does). That is
// `keyOpened`. The pulse is off for such a popup. With no `grabWindows` (a mockup is an
// ordinary window) there is no grab. The grab itself can only be proved in a compositor;
// offscreen the owner's half is: `keyOpened`, and `cleared` -> close.
// =============================================================================
Item {
    id: owner

    property var engine: null
    property var bar: null
    property string barId: ""
    property string ownerId: "notes"
    property Item anchorItem: null

    // ---- the shell (CONTRACT section 4) ----------------------------------------------------
    property bool shellHosted: false
    readonly property var sharedFlags: ({})
    // "Send to LLM" in a note's menu: offered when the host says the chat is there (`llmEnabled`), and
    // answered by `sendToLlm(path)` -- the host (ShellFrame) hands the path to the LLM owner of its own
    // screen. The owner builds nothing of the chat: it only asks.
    property bool llmEnabled: false
    signal sendToLlm(string path)
    // The windows a key-opened popup holds the keyboard for (this screen's bar window).
    property var grabWindows: []

    property string notesRoot: (Quickshell.env("HOME") || "") + "/Documents/Notes"
    property string statePath: (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/lares/notes/session.json"

    // ---- What notes.jsonc says -------------------------------------------------------------------
    // What the popup opens on: "last" | "root" | "new" (NotesStore.arriveAt).
    property string openAt: "last"
    // Escape in an open note goes back to the tiles; closes the popup otherwise.
    property bool escapeBack: false
    // Deleting a note or a group asks first.
    property bool confirmDelete: true
    // What opens a link: "ctrl" | "click".
    property string linkClick: "ctrl"

    // ---- What the popup is built with (the mockup's panel writes these) --------
    property string fontFamily: "Inter"
    property string editorFontFamily: "Inter"
    property real editorBodySize: 12
    property real editorTitleSize: 22
    // Landscape tiles (longer than they are high), three across
    // the default browse size, which is wider than it is tall for that.
    property real minTile: 150
    property real maxTile: 210
    property real tileAspect: 0.7
    property real tileGap: 12
    property real browseWidth: 560
    property real browseHeight: 440
    property real noteWidth: 420
    property real noteHeight: 480
    property real minWidth: 300
    property real minHeight: 280
    // Opening a tile and going back (NotesPopup's morph), and the two-finger
    // swipe that scrubs going back.
    property int morphMs: 320
    property real swipeBackUnits: 900
    property real swipeBackSign: 1

    // ---- the tiles' float -----------------------------------------------------------------------
    property bool shown: true
    property FloatStyle floatStyle: NotesFloatStyle {}
    // The content lives until the close ends, and it is on screen all that time.
    readonly property bool popupPresent: !!owner.engine && owner.engine.thePopup.ownerId === owner.ownerId && owner.engine.thePopup.phase !== "closed"
    readonly property bool _windowShown: owner.Window.window ? owner.Window.window.visible : true

    // ---- the store: injected, else our own ---------------------------------------------------
    property var store: null
    readonly property var activeStore: owner.store ?? ownStore.item
    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen && owner.engine.popupOwnerId === owner.ownerId

    Loader {
        id: ownStore
        active: owner.store === null && !owner.shellHosted
        sourceComponent: Component {
            NotesStore {
                root: owner.notesRoot
                statePath: owner.statePath
                defaultBrowseSize: ({
                        w: owner.browseWidth,
                        h: owner.browseHeight,
                        shift: 0
                    })
                defaultNoteSize: ({
                        w: owner.noteWidth,
                        h: owner.noteHeight,
                        shift: 0
                    })
            }
        }
    }

    // ---- opened by a key ------------------------------------------------------------------------
    property bool _keyOpened: false
    readonly property bool keyOpened: owner._keyOpened && owner.popupMine
    readonly property alias keyGrab: keyGrab
    HyprlandFocusGrab {
        id: keyGrab
        active: owner.keyOpened && owner.grabWindows.length > 0
        windows: owner.grabWindows
        onCleared: owner.close()
    }

    onPopupMineChanged: {
        if (!owner.popupMine) {
            owner._keyOpened = false;
            if (owner.activeStore)
                owner.activeStore.saveAll();
        }
    }
    Component.onDestruction: {
        if (owner.activeStore)
            owner.activeStore.saveAll();
    }

    readonly property Component popupComponent: Component {
        NotesPopup {
            store: owner.activeStore
            fontFamily: owner.fontFamily
            editorFontFamily: owner.editorFontFamily
            editorBodySize: owner.editorBodySize
            editorTitleSize: owner.editorTitleSize
            minWidth: owner.minWidth
            minHeight: owner.minHeight
            cornerRadii: owner.engine ? owner.engine.popupCornerRadii : [0, 0, 0, 0]
            morphMs: owner.morphMs
            swipeBackUnits: owner.swipeBackUnits
            swipeBackSign: owner.swipeBackSign
            // The grab holds a key-opened popup's keyboard: no pulse (it would hand the keys to
            // the window under the pointer at the switch).
            grabKeyboard: !owner._keyOpened
            gridOptions: ({
                    pad: 12,
                    gap: owner.tileGap,
                    minTile: owner.minTile,
                    maxTile: owner.maxTile,
                    aspect: owner.tileAspect,
                    hysteresis: 6
                })
            escapeBack: owner.escapeBack
            confirmDelete: owner.confirmDelete
            linkClick: owner.linkClick
            llmEnabled: owner.llmEnabled
            motionRunning: owner.popupPresent && owner.shown && owner._windowShown
            floatStyle: owner.floatStyle
            onSendToLlm: path => owner.sendToLlm(path)
            onCloseRequested: owner.close()
        }
    }

    // The click path: the pointer rests on the bar, so the popup's pulse may take the keyboard.
    function toggle() {
        if (owner.popupMine)
            owner.close();
        else {
            owner._keyOpened = false;
            owner.open();
        }
    }

    // The shell's Alt+N: a key-opened popup, its keyboard held by the grab; pressed again it closes.
    function shortcutPressed() {
        if (owner.popupMine) {
            owner.close();
            return;
        }
        owner._keyOpened = true;
        owner.open();
        if (!owner.popupMine)
            owner._keyOpened = false;
    }

    function open() {
        owner._openOn(owner.openAt);
    }

    function _openOn(where: string) {
        // Hosted with no store, the feature is absent: there is nothing to build a popup from.
        if (!owner.engine || !owner.bar || !owner.anchorItem || owner.popupMine || (owner.shellHosted && !owner.activeStore))
            return;
        // A whole pixel: the engine rests the box about this point, and an outlet (or a button of odd width) whose
        // middle falls on a half pixel put the box's edges there too -- everything in it then shimmers (CLAUDE.md:
        // a box's edges must be whole pixels). The popup's sizes are whole numbers (the store rounds them).
        const centre = Math.round(owner.anchorItem.mapToItem(owner.bar, owner.anchorItem.width / 2, owner.anchorItem.height / 2).x);
        owner.activeStore.arriveAt(where);
        owner.engine.open(owner.ownerId, owner.barId, centre, null, null, false, owner.popupComponent, 1);
    }

    function close() {
        if (owner.popupMine)
            owner.engine.close();
    }

    // A new note (shell.jsonc "clicks": "new"): the popup opens on one; one that is out already is left as it is.
    function openNew() {
        owner._openOn("new");
    }

    function springLoad() {
        owner._openOn(owner.openAt === "new" ? "root" : owner.openAt);
    }
}
