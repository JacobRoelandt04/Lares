pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"
import "../../common/components"
import "../data/BridgeModel.js" as Model
import "../../common/components/Mix.js" as Mix

// =============================================================================
// HomeScreen.qml -- the phone's home screen: the device's name (a click opens the device menu), ONE line of what is going on
// with it, and the six tiles of what it can do, in a 3 x 2 grid:
//
//     Mirror   Files   Send        Mirror and Files open a PAGE (they grow out of their tile); the other four act at once.
//     Clipboard  Ring  Shot
//
// WHO DECIDES. Nothing here knows what a device can do: a tile is lit by `can.<x>.ok` of the tool, and when it is not the
// tile says the tool's `why` and `hint` as its tip. A tile that cannot act still opens its page where the page explains
// (Mirror, Files) and does nothing but show its tip otherwise. A tile's `actState` is the service's `acts.<x>.state`; a
// failed call's reason replaces the tip until the state leaves.
//
// UNDER THE TILES, only while a send runs, one line of its figures (DownloadStats: plain totals before anything moved).
// Its room is reserved, so the grid never moves when a send starts.
//
// The group is placed by `style.homeBias` in the room between the status bar and the home indicator. No layer, no colour
// animation: this lives on the face that turns.
// =============================================================================
Item {
    id: home

    property var service: null
    // the current device's record (BridgeModel's <device>)
    property var dev: null
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}
    property Item overlayItem: null
    property color ground: Theme.listBox
    // the room the home screen lives in: below the status bar, above the home indicator (the face's own numbers)
    property real roomTop: 0
    property real roomHeight: height

    // the heading, for the owner that floats a menu under it
    readonly property alias nameItem: heading

    signal pageRequested(string page)
    signal menuRequested(Item anchor)

    // ---- the tiles ------------------------------------------------------------------------------------------------
    // id, the word under it, the glyph (md-cast, md-folder, md-send, md-clipboard, md-bell_ring, md-cellphone_screenshot)
    readonly property var _tiles: [
        { id: "mirror", label: "Mirror", glyph: "\u{F0118}", opens: "mirror" },
        { id: "files", label: "Files", glyph: "\u{F024B}", opens: "files" },
        { id: "send", label: "Send", glyph: "\u{F048A}", opens: "" },
        { id: "clip", label: "Clipboard", glyph: "\u{F0147}", opens: "" },
        { id: "ring", label: "Ring", glyph: "\u{F009E}", opens: "" },
        { id: "shot", label: "Shot", glyph: "\u{F0A35}", opens: "" }
    ]

    readonly property string _key: home.dev ? home.dev.key : ""
    readonly property var _acts: home.service ? home.service.acts : null
    readonly property var _jobs: home.service ? home.service.jobs : []

    function _can(ak: string): var {
        return Model.canOf(home.dev, ak);
    }
    function _actOf(ak: string): var {
        const a = home._acts;
        return a && a[ak] ? a[ak] : { state: "idle", why: "", hint: "", at: 0 };
    }
    function _words(why: string, hint: string): string {
        const w = String(why || "").replace(/[.\s]+$/, "");
        const h = String(hint || "");
        return w !== "" && h !== "" ? w + ". " + h : (w !== "" ? w : h);
    }
    function _mounted(): bool {
        const m = home.dev ? home.dev.mounts : null;
        return !!m && (m.usb.state === "mounted" || m.wifi.state === "mounted");
    }
    // what a tile shows now: { ok, active, act, tip }
    function _info(id: string): var {
        const dev = home.dev;
        if (!dev)
            return { ok: false, active: false, act: "idle", tip: "" };
        let ok = false, active = false, act = home._actOf(id), why = "", hint = "";
        const c = home._can(id);
        switch (id) {
        case "mirror":
            ok = c.ok;
            active = home.service !== null && (home.service.job(dev.key, "mirror") !== null || (home.service.casting && home.service.castKey === dev.key));
            why = c.why;
            hint = c.hint;
            break;
        case "files": {
            const u = home._can("mountUsb"), w = home._can("mountWifi");
            const au = home._actOf("mountUsb"), aw = home._actOf("mountWifi");
            ok = u.ok || w.ok || home._mounted();
            active = home._mounted();
            // the worst of the two calls shows: busy, then failed, then done
            if (au.state === "busy")
                act = au;
            else if (aw.state === "busy")
                act = aw;
            else if (au.state === "failed")
                act = au;
            else if (aw.state === "failed")
                act = aw;
            else
                act = au.state === "done" ? au : aw;
            // when neither can mount, the cable's reason leads (the user mostly wires)
            why = u.why !== "" ? u.why : w.why;
            hint = u.why !== "" ? u.hint : w.hint;
            break;
        }
        default:
            ok = c.ok;
            why = c.why;
            hint = c.hint;
        }
        // a failure is told, never a lock: a tile whose last try failed stays pressable and says why
        let tip = "";
        if (act.state === "failed")
            tip = home._words(act.why, act.hint);
        else if (why !== "")
            tip = home._words(why, hint);
        return { ok: ok, active: active, act: act.state, tip: tip };
    }
    function _press(id: string): void {
        const dev = home.dev;
        const svc = home.service;
        if (!dev || !svc)
            return;
        const info = home._info(id);
        switch (id) {
        case "mirror":
            // a cast running for this phone: straight back to it
            home.pageRequested(svc.casting && svc.castKey === dev.key ? "cast" : "mirror");
            break;
        case "files":
            home.pageRequested("files");
            break;
        case "send":
            if (info.ok)
                svc.pickAndSend(dev.key);
            break;
        case "clip":
            if (info.ok)
                svc.clip(dev.key);
            break;
        case "ring":
            // loud on purpose, so never by accident (the user, 2026-11-19): a click arms the tile ("Hold"), and only a
            // press held for ringHoldMs while armed rings; the click that ends that hold is not a new arming
            if (home._ringFired) {
                home._ringFired = false;
                break;
            }
            if (info.ok && !home._ringArmed) {
                home._ringArmed = true;
                ringDisarm.restart();
            }
            break;
        case "shot":
            if (info.ok)
                svc.shot(dev.key);
            break;
        }
    }

    // where a tile stands, in this item's coordinates (a page grows out of it and shrinks back into it)
    function tileRect(page: string): var {
        for (let i = 0; i < home._tiles.length; i++) {
            if (home._tiles[i].opens === page) {
                const t = grid.tileAt(i);
                if (t)
                    return { x: grid.x + t.x, y: grid.y + t.y, w: t.tileSize, h: t.tileSize };
            }
        }
        return { x: home.width / 2, y: home.roomTop + home.roomHeight / 2, w: 0, h: 0 };
    }

    // ---- the group --------------------------------------------------------------------------------------------------
    readonly property real _innerW: home.width - 2 * home.style.padding
    readonly property real _tileH: home.style.tileSize + home.style.tileLabelGap + labelMetrics.height
    readonly property real _gridH: 2 * home._tileH + home.style.tileRowGap
    readonly property real _nameH: home.style.nameSize + 6
    readonly property real _headH: home._nameH + home.style.nameGap + home.style.stateSize + 5
    readonly property real _statsH: home.style.statsGap + home.style.statsHeight
    readonly property real _groupH: home._headH + home.style.headerToTiles + home._gridH + home._statsH
    readonly property real _groupY: Math.round(home.roomTop + Math.max(0, home.roomHeight - home._groupH) * home.style.homeBias)

    TextMetrics {
        id: labelMetrics
        font.family: home.fontFamily
        font.pixelSize: home.style.tileLabelSize
        text: "Mg"
    }

    DeviceName {
        id: heading
        x: home.style.padding
        y: home._groupY
        width: home._innerW
        name: home.dev ? home.dev.name : ""
        more: home.service !== null && home.service.count > 1
        fontFamily: home.fontFamily
        style: home.style
        onOpened: home.menuRequested(heading)
    }
    Text {
        id: line
        x: home.style.padding
        y: home._groupY + home._nameH + home.style.nameGap
        width: home._innerW
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: Model.stateLine(home.dev, home._jobs)
        color: Theme.textMuted
        font.family: home.fontFamily
        font.pixelSize: home.style.stateSize
    }

    Item {
        id: grid
        x: home.style.padding
        y: home._groupY + home._headH + home.style.headerToTiles
        width: home._innerW
        height: home._gridH
        function tileAt(i: int): var {
            return reps.itemAt(i);
        }
        Repeater {
            id: reps
            model: home._tiles.length
            TileButton {
                id: tile
                required property int index
                readonly property var spec: home._tiles[tile.index]
                readonly property var info: home._info(tile.spec.id)
                readonly property int col: tile.index % 3
                readonly property int row: Math.floor(tile.index / 3)
                x: Math.round(tile.col * (grid.width - tile.tileSize) / 2)
                y: tile.row * (home._tileH + home.style.tileRowGap)
                tileSize: home.style.tileSize
                radius: home.style.tileRadius
                glyphSize: home.style.tileGlyphSize
                labelSize: home.style.tileLabelSize
                labelGap: home.style.tileLabelGap
                fontFamily: home.fontFamily
                surfaceColor: home.ground
                glyph: tile.spec.glyph
                label: tile.spec.id === "ring" && home._ringArmed ? "Hold" : tile.spec.label
                enabledLook: tile.info.ok
                clickable: tile.info.ok || tile.spec.opens !== ""
                active: tile.info.active
                actState: tile.holding ? "busy" : tile.info.act
                tip: tile.spec.id === "ring" && tile.info.ok ? (home._ringArmed ? "Hold to ring" : "Click, then hold to ring") : tile.info.tip
                overlayItem: home.overlayItem
                onClicked: home._press(tile.spec.id)
                // Ring's second layer: held while armed
                readonly property bool holding: tile.spec.id === "ring" && home._ringArmed && tile.pressed
                onHoldingChanged: home._holdRing(tile.holding)
            }
        }
    }

    // ---- Ring's two layers: a click arms (4 s), a held press rings -------------------------------------------------------
    property bool _ringArmed: false
    property bool _ringFired: false
    property int ringHoldMs: 1200
    Timer {
        id: ringDisarm
        interval: 4000
        onTriggered: home._ringArmed = false
    }
    Timer {
        id: ringHold
        interval: home.ringHoldMs
        onTriggered: {
            home._ringFired = true;
            home._ringArmed = false;
            ringDisarm.stop();
            if (home.service && home.dev && home._can("ring").ok)
                home.service.ring(home.dev.key);
        }
    }
    function _holdRing(on: bool): void {
        if (on) {
            ringDisarm.stop();
            ringHold.restart();
        } else if (ringHold.running) {
            ringHold.stop();
            ringDisarm.restart();
        }
    }
    onDevChanged: {
        home._ringArmed = false;
        ringHold.stop();
    }

    // ---- a send's figures ---------------------------------------------------------------------------------------
    // the last send job is held while its line fades out, so the words do not change under the fade
    readonly property var _sendJob: home.service && home.dev ? home.service.job(home.dev.key, "send") : null
    property var _shownJob: null
    on_SendJobChanged: if (home._sendJob !== null)
        home._shownJob = home._sendJob
    Component.onCompleted: if (home._sendJob !== null)
        home._shownJob = home._sendJob
    property real _statsF: home._sendJob !== null ? 1 : 0
    Behavior on _statsF {
        NumberAnimation {
            duration: home.style.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    DownloadStats {
        id: stats
        x: home.style.padding
        y: grid.y + grid.height + home.style.statsGap
        width: home._innerW
        height: home.style.statsHeight
        visible: home._statsF > 0.01 && home._shownJob !== null
        opacity: home._statsF
        alignment: Qt.AlignHCenter
        fontFamily: home.fontFamily
        pixelSize: home.style.statsSize
        color: Theme.textMuted
        unit: "files"
        unitSingular: "file"
        showEta: false
        availableWidth: home._innerW
        // plain totals before anything moved ("3 files · 11.5 MiB"), then done / total
        done: home._shownJob && home._shownJob.done > 0 ? Math.max(1, home._shownJob.file) : -1
        total: home._shownJob ? Math.max(1, home._shownJob.files) : -1
        bytesDone: home._shownJob && home._shownJob.done > 0 ? home._shownJob.done : -1
        bytesTotal: home._shownJob ? home._shownJob.total : 0
        rateText: home._shownJob && home._shownJob.rate > 0 ? Model.bytesWords(home._shownJob.rate) + "/s" : ""
    }
}
