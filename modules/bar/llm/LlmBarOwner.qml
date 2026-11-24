pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/components"
import "../../common/system"
import "components"

// =============================================================================
// LlmBarOwner.qml -- the LLM chat's bar-side object.
//
// The engine builds a popup's content on open and DESTROYS it on close, so what must outlive the popup is not here
// but in LlmServices (once per shell: the conversations, the turn in flight, the tool jobs, the "come back"
// notification). This owner holds only what the bar needs of them: the way the popup is opened and handed the
// service, and the two things that are the DESKTOP'S business rather than the module's -- the file chooser and links.
//
//   llm             LlmServices. Injected: none means the feature is absent (a click opens nothing), never a bundle
//                   of its own making.
//   anchorItem      what the popup hangs from: the host's OutletAnchor on the LEFT bar's top (the chat opens out of
//                   the left 6 px bar, under the left island), or a button.
//   sharedFlags     { attended }: the popup is showing. The host ORs it over its screens' owners and writes the
//                   result to `llm.attended`, which is what LlmAttention waits on before it posts a notification and LlmResidency before
//                   it puts the chat away and lets go of the card. (Not the popup's own `onVisibleChanged`: that runs in the engine as
//                   the item is built -- a Loader's item announces visible=false as it is parented, so every OPEN would release the model
//                   about to be used -- and it cannot know about a second screen's popup.)
//   toggle() / open() / close()
//   openConversation(id)   a notification's "Open" / "Open chat" (an answer, a spoken ask's toast): the service opens that
//                   conversation, then the popup opens, with the keyboard as any click-opened popup. A popup that is up already
//                   only follows the conversation. A SPOKEN ask itself opens nothing (LlmService.voiceAsk runs in the background).
//
// THE FILE CHOOSER. The popup's attach button emits `attachRequested`; the owner runs the xdg-desktop-portal
// FileChooser through tools/notes/portal_pick.py (the notes module's "show in file manager", the launcher's picker):
// a separate process, so it works from a layer-shell window, which a QtQuick.Dialogs FileDialog parented to one
// has not been shown to. The files come back as chips on the popup that asked; if it was
// closed in the meantime they wait for the next one. The dialog's title is the popup's `attachTitle`, handed to the script as its
// second argument (without one the script says "Notes", which is the notes module's own).
//
// NOTES -> THE CHAT. `sendFile(path)` is the notes owner's "Send to LLM" (the host connects the two owners of one screen): a NEW
// conversation on the model the chat is on, the file attached to it as a chip, the chat opened -- or, when it is up already, switched to
// it. `noteTemplate` is the prompt the user has not decided on yet: empty (the default) puts no text in the composer; set, the text is the
// new conversation's prompt and is SELECTED, so one Backspace or any typing replaces it. It lives in llm.jsonc as `notePrompt`
// (the host reads it into this property). The prompt goes through the service's draft of "the chat that does not exist yet", which
// `newChat()` hands to the chat it makes -- the same road a prompt typed before the first message takes.
//
// THE KEYBOARD is the popup's (`keyboardFocusRequest`, read by the engine); the owner has no part in it.
//
// THE SIZE. The chat is a little larger than the other popups: shell.jsonc `scale.popups.llm` (1.1 unless the file says otherwise,
// ScaleConfig.js), the per-popup ratio every popup has -- the engine lays the content out in its own units and draws it that much larger.
//
// THE HOVER BUILD. The pointer rests on the chat's button for ~80 ms before a click, and the popup is
// ~3 600 items of history and conversation: built IN the click's frame that is 182 ms of a 241 ms warm open, a 240 ms hole in a
// travel. `hoverTarget` is that button (the outlet `anchorItem` is a 6 px mark on the side bar, not what the pointer rests on):
// a HoverIntent on it asks the engine to build the popup parked -- `prebuild(.., { parked: true })` -- and the click adopts it.
// LlmPopup honours `parked`: it asks nothing of the service, takes no key and runs nothing until it is shown. Not while an answer
// is streaming (`_streaming`): a popup built ahead and left unclaimed (the engine keeps one for two minutes) would render the stream
// into a transcript nobody sees. Files picked while the popup was shut are handed over when it is SHOWN, not when it is built ahead.
// =============================================================================
Item {
    id: owner

    // ---- the bar ----------------------------------------------------------------------------------------------
    property var engine: null                 // GooeyEngine
    property var bar: null                    // GooeyBar
    property string barId: ""
    property string ownerId: "llm"
    property Item anchorItem: null
    // The chat's button in the island: where the pointer rests before the click (the hover build, above). Null: no hover build.
    property Item hoverTarget: null

    // ---- what it holds ----------------------------------------------------------------------------------------
    property var llm: null                    // LlmServices
    // The shell's faces: Audiowide for the chrome, Exo 2 for what is read and written, Consolas for code.
    property string fontFamily: "Audiowide"
    property string bodyFontFamily: "Exo 2"
    property string monoFamily: "Consolas"
    // Where the chooser opens (llm.jsonc "attachFrom", then the last place a file was picked from), and the helper that runs it.
    property string attachDir: Quickshell.env("HOME") || "/"
    property string portalHelper: RepoRoot.dir + "/tools/notes/portal_pick.py"
    // What a link in an answer does. A function so a probe can stand in for the browser.
    property var openUrl: function (url) {
        Qt.openUrlExternally(url);
    }
    // The text put in the composer, selected, when a note is sent to the chat. "" = none (the user is still deciding what it says).
    property string noteTemplate: ""

    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen
                                      && owner.engine.popupOwnerId === owner.ownerId
    readonly property var sharedFlags: ({
            attended: owner.popupMine
        })

    // ---- the popup --------------------------------------------------------------------------------------------
    // The history, as the user left it: written back on every change, so the next open starts there (the player's `browseOpen`, the
    // same pattern -- the popup is built on open and destroyed on close, and the history WIDENS the popup, so a popup that
    // forgot would open narrow and grow). Within the session only; a fresh shell opens it folded. `history` (llm.jsonc): "session" is
    // that, "open" / "closed" what every open starts with.
    property string history: "session"
    property bool sidebarOpen: false
    readonly property bool _sidebarAtOpen: owner.history === "open" || (owner.history === "session" && owner.sidebarOpen)

    // What thePopup loads: the drop-in, handed the service. Beyond the history's state it holds none that matters.
    readonly property Component popupComponent: Component {
        LlmPopup {
            id: content
            service: owner.llm ? owner.llm.service : null
            sidebarOpen: owner._sidebarAtOpen
            onSidebarOpenChanged: owner.sidebarOpen = content.sidebarOpen
            fontFamily: owner.fontFamily
            bodyFontFamily: owner.bodyFontFamily
            monoFamily: owner.monoFamily
            onAttachRequested: owner.pickFiles(content)
            onLinkActivated: url => owner.openUrl(url)
            // The popup stops being up (the close has begun; this content is still on screen, shrinking): the keys go back now, not
            // when the engine parks it a few frames later -- the compositor re-activates the layer surface in between (LlmPopup.giveBackKeys).
            Connections {
                target: owner
                function onPopupMineChanged() {
                    if (!owner.popupMine)
                        content.giveBackKeys();
                }
            }
            Component.onCompleted: {
                owner._live = content;
                if (!content.parked)
                    owner._deliver(content);
            }
            onParkedChanged: {
                if (!content.parked)
                    owner._deliver(content);
            }
        }
    }

    // The pointer has rested on the button: build the popup now, parked, for the click that follows.
    readonly property bool _streaming: !!owner.llm && !!owner.llm.service && !!owner.llm.service.generating
    HoverIntent {
        // (a HoverHandler with no parent is destroyed, and the intent then reads a handler that is gone: a host with no button -- a probe,
        // a mockup -- hands it this item, which has no size and so is never hovered)
        target: owner.hoverTarget ? owner.hoverTarget : owner
        enabled: !!owner.llm && !!owner.llm.service
        armed: !!owner.engine && typeof owner.engine.prebuild === "function" && !owner.popupMine && !owner._streaming
        onIntent: owner.engine.prebuild(owner.ownerId, owner.popupComponent, { parked: true })
    }

    function toggle() {
        if (owner.popupMine)
            owner.close();
        else
            owner.open();
    }

    // A note's file to a NEW conversation, in front of the user. The conversation is made now (so the popup, built or already up, is on
    // it), the file waits in `_held` for a popup that is shown -- the road a file picked while the chat was shut takes.
    property LlmPopup _live: null             // the popup built last, nulled by Qt when it is destroyed
    property bool _selectPrompt: false
    function sendFile(path) {
        const svc = owner.llm ? owner.llm.service : null;
        if (!svc || String(path || "") === "")
            return false;
        if (owner.noteTemplate !== "")
            svc.setDraft("", owner.noteTemplate);
        svc.newChat();
        owner._held = owner._held.concat([String(path)]);
        owner._selectPrompt = owner.noteTemplate !== "";
        const up = owner._live;
        if (owner.popupMine && up && !up.parked)
            owner._deliver(up);
        else
            owner.open();
        return true;
    }

    function open() {
        if (!owner.engine || !owner.bar || !owner.anchorItem || !owner.llm || !owner.llm.service || owner.popupMine)
            return;
        // Read at the moment of opening, not bound: a mapToItem in a binding does not track the layout that moved it.
        const centre = owner.anchorItem.mapToItem(owner.bar, owner.anchorItem.width / 2, owner.anchorItem.height / 2).x;
        owner.engine.open(owner.ownerId, owner.barId, centre, null, null, false, owner.popupComponent, 1);
    }

    function close() {
        if (owner.popupMine)
            owner.engine.close();
    }

    // A new chat (shell.jsonc "clicks": "new"), shown: a popup that is up follows the service.
    function openNew() {
        if (!owner.llm || !owner.llm.service)
            return;
        owner.llm.service.newChat();
        if (!owner.popupMine)
            owner.open();
    }

    // The conversation first, so the popup is built already on it; a popup that is up simply follows the service.
    function openConversation(convId) {
        if (!owner.llm || !owner.llm.service)
            return;
        const svc = owner.llm.service;
        svc.open(convId);
        if (owner.popupMine)
            return;
        owner.open();
    }

    // ---- the file chooser ---------------------------------------------------------------------------------------
    property LlmPopup _asker: null            // the popup that asked, nulled by Qt when it is destroyed
    property var _held: []                    // picked, and nobody to hand them to

    function pickFiles(popup) {
        if (chooser.running)
            return;
        owner._asker = popup;
        chooser.command = ["python3", owner.portalHelper, owner.attachDir, popup && popup.attachTitle ? popup.attachTitle : "Attach files"];
        chooser.running = true;
    }

    function _picked(text) {
        // The popup that asked, if it is still the one on screen. A closed popup is HELD by the engine for a moment (inert, `parked`, until
        // the engine is at rest) before it is destroyed, and a file handed to one in that moment is lost: it waits for the next popup instead.
        const asker = owner._asker;
        const popup = asker && !asker.parked && owner.popupMine ? asker : null;
        owner._asker = null;
        const files = String(text || "").split("\u0000").filter(p => p.length > 0);
        if (files.length === 0)
            return;
        const slash = files[0].lastIndexOf("/");
        if (slash > 0)
            owner.attachDir = files[0].substring(0, slash);
        if (popup) {
            for (const f of files)
                popup.attachFile(f);
        } else {
            owner._held = owner._held.concat(files);
        }
    }

    // A popup built after files were picked for a closed one takes them.
    function _deliver(popup) {
        if (owner._held.length === 0)
            return;
        const files = owner._held;
        owner._held = [];
        for (const f of files)
            popup.attachFile(f);
        if (owner._selectPrompt) {
            owner._selectPrompt = false;
            // After the popup has taken its own draft (its build order is its own).
            Qt.callLater(function () { if (popup) popup.selectPrompt(); });
        }
    }

    Process {
        id: chooser
        stdout: StdioCollector {
            onStreamFinished: owner._picked(text)
        }
    }
}
