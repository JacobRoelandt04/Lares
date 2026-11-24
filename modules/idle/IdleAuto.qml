pragma ComponentBehavior: Bound

import QtQuick

import "IdleAutoRules.js" as Rules

// =============================================================================
// IdleAuto.qml -- the idle auto layer: what needs the machine awake asks IdleService for a mode, with a reason
// (IdleAutoRules.js has the table and the rules).
//
//   in    one fact per holder, bound by the host (ShellServices; `content` by IdleService itself, from ContentHold): the LLM, a timer, a system
//         update, music, the screen share (ScreenShareWatch), a wiki batch, a download (DownloadWatch), a package job of someone else's
//         (PackageJobWatch: yay / pacman in a terminal; the shell's own update is `update`, with its own words)
//   out   mode ("" when nothing asks), key (the holder that names the cause), reason (the OSD card's words)
//
// THE DEBOUNCE. A holder counts once it has held for `onMs` (3 s: a notification's blip, a title the LLM writes in a second, a
// video started by mistake ask nothing) and stops counting once it has let go for `offMs` (15 s: a video paused for a look away,
// a timer reset and restarted, the LLM between two tool rounds keep the hold, so the reel does not dance on every flap).
//
// THE OVERRIDE (suppress(), from a Ctrl+click or Ctrl+scroll on the idle reel): the holders counting at that moment are set aside
// until one that was not counts, or none does.
// =============================================================================
Item {
    id: root

    // ---- the facts ----------------------------------------------------------------------------------------------------------
    property bool content: false
    property string contentWho: ""
    property bool update: false
    property bool llm: false
    property bool timer: false
    property string timerWhat: "timer"
    property bool music: false
    // the screen is shared or recorded (ScreenShareWatch), a wiki batch runs (WikiService.batch.running), a file is being downloaded
    // into the download folder (DownloadWatch)
    property bool share: false
    property bool wiki: false
    property bool download: false
    property string downloadWhat: ""
    property bool pkg: false
    property string pkgWhat: ""
    // files are being sent to a phone (the bridge's send job): a suspend would cut the transfer
    property bool bridge: false
    property string bridgeWhat: ""

    property int onMs: 3000
    property int offMs: 15000
    // idle.jsonc `auto`: the mode each cause asks for ({ music: "off", llm: "normal" ... }); a key it does not name keeps the table's
    property var modes: ({})

    // ---- the answer ----------------------------------------------------------------------------------------------------------
    readonly property var counted: ({ content: hContent.counted, update: hUpdate.counted, llm: hLlm.counted, timer: hTimer.counted, music: hMusic.counted,
        share: hShare.counted, wiki: hWiki.counted, download: hDownload.counted, pkg: hPkg.counted, bridge: hBridge.counted })
    readonly property var decision: Rules.decide(root.counted, root._suppressed, root.modes)
    readonly property string mode: root.decision.mode
    readonly property string key: root.decision.key
    readonly property string reason: Rules.reason(root.decision.key, { contentWho: root._who, timerWhat: root.timerWhat, downloadWhat: root._file, pkgWhat: root._pkgText, bridgeWhat: root._phone })
    // An override stands (the probe and the reel read it).
    readonly property bool overridden: root.decision.mode === "" && root.decision.keys.length > 0

    // Set aside the holders counting now.
    function suppress(): void {
        root._suppressed = Rules.countedKeys(root.counted, root.modes);
    }

    property var _suppressed: []
    // The download's last named file, kept the way `_who` is (the words stay while the hold lingers).
    property string _file: ""
    onDownloadWhatChanged: {
        if (root.downloadWhat !== "")
            root._file = root.downloadWhat;
    }
    // ... and the package job's words, kept the same way.
    property string _pkgText: ""
    onPkgWhatChanged: {
        if (root.pkgWhat !== "")
            root._pkgText = root.pkgWhat;
    }
    // ... and the phone's name.
    property string _phone: ""
    onBridgeWhatChanged: {
        if (root.bridgeWhat !== "")
            root._phone = root.bridgeWhat;
    }
    // The content's last named holder: the words stay with the hold while it lingers after the holder has gone (a card would
    // otherwise say "A video is playing" the moment Firefox's own request ends).
    property string _who: ""
    onContentWhoChanged: {
        if (root.contentWho !== "")
            root._who = root.contentWho;
    }
    Component.onCompleted: {
        if (root.contentWho !== "")
            root._who = root.contentWho;
        if (root.downloadWhat !== "")
            root._file = root.downloadWhat;
        if (root.pkgWhat !== "")
            root._pkgText = root.pkgWhat;
        if (root.bridgeWhat !== "")
            root._phone = root.bridgeWhat;
    }
    // An override ends when nothing counts or a holder it did not set aside does (the binding above only stops honouring it; this
    // forgets it, so the same holder coming back later asks again).
    onCountedChanged: {
        if (root._suppressed.length === 0)
            return;
        const keys = Rules.countedKeys(root.counted, root.modes);
        if (!Rules.overrideStands(keys, root._suppressed))
            root._suppressed = [];
    }

    component Hold: QtObject {
        id: h
        property bool on: false
        property bool counted: false
        property int onMs: 3000
        property int offMs: 15000
        function _arm(): void {
            if (h.on === h.counted) {
                h._timer.stop();
                return;
            }
            h._timer.interval = h.on ? h.onMs : h.offMs;
            h._timer.restart();
        }
        onOnChanged: h._arm()
        Component.onCompleted: h._arm()
        property Timer _timer: Timer {
            onTriggered: h.counted = h.on
        }
    }
    Hold {
        id: hContent
        on: root.content
        onMs: root.onMs
        offMs: root.offMs
    }
    Hold {
        id: hUpdate
        on: root.update
        onMs: root.onMs
        offMs: root.offMs
    }
    Hold {
        id: hLlm
        on: root.llm
        onMs: root.onMs
        offMs: root.offMs
    }
    Hold {
        id: hTimer
        on: root.timer
        onMs: root.onMs
        offMs: root.offMs
    }
    Hold {
        id: hMusic
        on: root.music
        onMs: root.onMs
        offMs: root.offMs
    }
    Hold {
        id: hShare
        on: root.share
        onMs: root.onMs
        offMs: root.offMs
    }
    Hold {
        id: hWiki
        on: root.wiki
        onMs: root.onMs
        offMs: root.offMs
    }
    Hold {
        id: hBridge
        on: root.bridge
        onMs: root.onMs
        offMs: root.offMs
    }
    Hold {
        id: hDownload
        on: root.download
        onMs: root.onMs
        offMs: root.offMs
    }
    Hold {
        id: hPkg
        on: root.pkg
        onMs: root.onMs
        offMs: root.offMs
    }
}
