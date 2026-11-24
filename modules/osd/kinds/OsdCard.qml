pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import ".."

// =============================================================================
// OsdCard.qml -- the plain event cards: theme, bluetooth, network, vpn, autoTunnel, btLow,
// battery low / full, power (silicon) and the generic glyph + title + detail. One
// layout, one descriptor per kind (`d`): what the picture is, what it says. A
// glyph card's colour is the Theme token its request names (`colorToken`; none,
// or one the theme does not have, is the accent).
//
//   h     picture | title over detail
//   v     picture over title over detail, centred; text never rotates, so a
//         long title wraps one word per line ("eva" / "dark"). A word is never
//         broken: the card grows to its longest word (`wantW`, up to the
//         style's cardMaxW) and a word past that elides on one line.
//   pill  picture title detail on one line, the detail standing back
//
// THE PICTURE is a NetGlyph for bluetooth / Wi-Fi (the shell's own machined
// symbols; its padlock is too dim on a bare surface in dark mode, so the VPN
// is the Nerd Font glyph, accent when up and faint when down), BatteryBody + nub for the battery, a Nerd Font glyph for
// the rest. The stack is centred in the box on both axes: space above equals
// space below, whatever the text does. The battery's percentage is in its
// picture (the figure inside the cell), so it has no detail line to repeat it.
// =============================================================================
Item {
    id: root

    property string kind: "theme"
    property string orientation: "h"
    property var payload: ({})
    property bool interactive: true
    property var style: null
    property real renderScale: 1

    signal userValue(real v)
    signal userToggleMute()
    signal userToggleBoost()
    signal touched()

    readonly property var p: root.payload ? root.payload : ({})
    readonly property bool vert: root.orientation === "v"
    // the charge as a part of the pack the limit leaves: full at 80 with the limit on, as the bar's track
    readonly property real batteryFill: Math.max(0, Math.min(1, (root.d.percent || 0) / (root.d.target || 100)))
    readonly property bool isPill: root.orientation === "pill"

    function _tokenColor(tok, fallback) {
        const c = tok ? Theme[tok] : undefined;
        return c !== undefined ? c : fallback;
    }

    // What the card says, per kind. Facts only; colours are resolved here, in
    // the card, from the facts.
    readonly property var d: {
        const p = root.p;
        switch (root.kind) {
        case "theme": {
            const t = p.theme || ({});
            // a theme's name is shown with its dashes as spaces ("night owl dark"; themectl shown_name), no-break ones here: a side bar's
            // narrow card breaks the title into lines, and the name stays on one ("night owl" / "dark", as "night-owl" / "dark" did)
            return { pic: "glyph", glyph: "\u{F050E}", color: Theme.accent,
                     title: (String(t.name || "").replace(/-/g, "\u00A0") + " " + (t.mode || "")).trim(), detail: "" };
        }
        case "bluetooth": {
            const b = p.bt || ({});
            const on = b.state === "connected";
            const bat = Number(b.battery);
            return { pic: "net", net: "bt", on: on, title: b.name || "",
                     detail: on ? (bat >= 0 ? "Connected · " + Math.round(bat) + " %" : "Connected")
                                : "Disconnected" };
        }
        case "network": {
            const n = p.net || ({});
            const sig = Number(n.signal) || 0;
            const up = n.state === "connected";
            // a cable: the port, lit while it is up (its profile is the title; none reads "Ethernet")
            if (n.via === "wired")
                return { pic: "net", net: "wired", on: up, level: 0, title: n.ssid || "Ethernet", detail: up ? "Connected" : "Disconnected" };
            return { pic: "net", net: "wifi", level: up ? Math.max(1, Math.min(4, Math.ceil(sig / 25))) : 0,
                     title: n.ssid || "", detail: up ? "Connected" : n.state === "failed" ? (n.reason || "Connection failed") : "Connection lost" };
        }
        case "vpn": {
            const v = p.vpn || ({});
            const up = v.state === "up";
            return { pic: "glyph", glyph: "\u{F0582}", color: up ? Theme.accent : Theme.textFaint,
                     title: v.name || "", detail: up ? "Connected" : "Disconnected" };
        }
        case "autoTunnel": {
            // aerial raised the tunnel by itself: joining a Public network (the card says why, and through where)
            const t = p.tunnel || ({});
            return { pic: "glyph", glyph: "\u{F0582}", color: Theme.accent, title: "Public network",
                     detail: t.country ? "Tunnel raised via " + t.country : "Tunnel raised" };
        }
        case "btLow": {
            const b = p.bt || ({});
            return { pic: "net", net: "bt", on: true, title: b.name || "", detail: "Battery low · " + Math.round(Number(b.battery) || 0) + " %" };
        }
        case "battery": {
            const b = p.battery || ({});
            const full = b.event === "full";
            return { pic: "battery", percent: Number(b.percent) || 0, target: Number(b.target) || 100,
                     color: full ? Theme.batteryCharge : Theme.batteryLow,
                     title: full ? "Fully charged" : "Battery low", detail: "" };
        }
        default:
            // power and generic: the request brings its own glyph, title, detail and colour
            return { pic: "glyph", glyph: p.glyph || (root.kind === "power" ? "\u{F0425}" : "\u{F02FC}"), color: root._tokenColor(p.colorToken, Theme.accent),
                     title: p.title || "", detail: p.detail || "" };
        }
    }

    OsdWords {
        id: words
        family: root.style.textFont
        titlePx: root.style.titlePx
        detailPx: root.style.detailPx
    }
    // The width this card asks for when it stands (OsdContent grows to it).
    readonly property real wantW: root.vert
        ? Math.max(root._titleW(root.d.title), words.detail(root.d.detail)) + 2 * root.style.pad : 0
    // The title's longest run the wrap cannot break: a no-break space (inside a theme's name) joins, as Qt's WordWrap does, where
    // OsdWords.title splits at every \s.
    function _titleW(s: string): real {
        const runs = String(s || "").split(/[ \t\n]+/);
        let m = 0;
        for (let i = 0; i < runs.length; i++)
            m = Math.max(m, words.titleLine(runs[i]));
        return m;
    }

    readonly property real picW: root.d.pic === "net" ? root.style.netGlyphPx
                               : root.d.pic === "battery" ? root.style.batteryW + 7
                               : root.isPill ? root.style.pillGlyphPx : root.style.glyphSlot
    readonly property real picH: root.d.pic === "net" ? root.style.netGlyphPx
                               : root.d.pic === "battery" ? root.style.batteryH
                               : root.picW
    readonly property real padX: root.isPill ? root.style.pillPad : root.style.pad
    readonly property real textPx: root.isPill ? root.style.pillTextPx : root.style.titlePx
    readonly property real detailPx: root.isPill ? root.style.pillTextPx : root.style.detailPx

    // ---- the picture ----------------------------------------------------------
    Item {
        id: pic
        width: root.picW
        height: root.picH
        // h/pill: the left end; v: the top of the centred stack.
        x: root.vert ? Math.round((root.width - width) / 2) : Math.round(root.padX)
        y: root.vert ? Math.round(root.stackTop) : Math.round((root.height - height) / 2)

        OsdGlyph {
            visible: root.d.pic === "glyph"
            osd: root.style
            glyph: root.d.glyph || ""
            size: root.isPill ? root.style.pillGlyphPx : root.style.cardGlyphPx
            slot: root.picW
            height: root.picH
            color: root.d.color || Theme.accent
        }
        NetGlyph {
            id: net
            visible: root.d.pic === "net"
            // a cable pulled out: the same port, dimmed (Wi-Fi's lost is its grey arcs, a bluetooth's is its `on`)
            opacity: root.d.net === "wired" && root.d.on !== true ? 0.4 : 1
            kind: root.d.net || "bt"
            level: root.d.level || 0
            on: root.d.on === true
            size: root.picW
            renderScale: root.renderScale
        }
        // Battery: the bar's body and nub at a few pixels, the percentage in
        // the text colour over the groove and in the on-accent colour over the
        // charge (BatteryBarIcon's trick: legible on both sides of the edge).
        Item {
            id: bat
            visible: root.d.pic === "battery"
            anchors.fill: parent
            BatteryBody {
                id: body
                width: root.style.batteryW
                height: root.style.batteryH
                baseRadius: 7
                bevelWidth: 1
                shadowWidth: 2
                fillPadding: 2
                fillRadiusOffset: 0
                fillBevelWidth: 0.5
                fillShadowWidth: 1
                fillAnimationMs: 300
                fillRatio: root.batteryFill
                fillColor: root.d.color || Theme.batteryIdle
                Text {
                    id: label
                    x: Math.round((body.width - label.implicitWidth) / 2)
                    y: Math.round((body.height - label.implicitHeight) / 2)
                    text: String(Math.round(root.d.percent || 0))
                    color: Theme.textPrimary
                    font.family: root.style.textFont
                    font.pixelSize: 10
                    font.bold: true
                }
                Item {
                    width: body.fillEdgeX
                    height: body.height
                    clip: true
                    Text {
                        x: label.x
                        y: label.y
                        text: label.text
                        color: Theme.textOnAccent
                        font: label.font
                    }
                }
            }
            BatteryNub {
                x: root.style.batteryW + 2
                y: Math.round((root.style.batteryH - 11) / 2)
                width: 5
                height: 11
                baseRadius: 2.5
                bevelWidth: 0.5
                shadowWidth: 1
                fillPadding: 1
                fillBevelWidth: 0.3
                fillShadowWidth: 0.5
                fillAnimationMs: 0
                fillRatio: 1.0
                fillColor: root.d.color || Theme.batteryIdle
            }
        }
    }

    // ---- the words ------------------------------------------------------------
    // A vertical card's stack (picture, gap, title, detail) is centred on its
    // own height; the others centre the text block on the picture.
    readonly property real stackH: pic.height + root.style.gap + titleText.height
        + (detailText.visible ? 2 + detailText.height : 0)
    readonly property real stackTop: Math.round((root.height - root.stackH) / 2)

    Text {
        id: titleText
        text: root.d.title
        color: Theme.textPrimary
        font.family: root.style.textFont
        font.pixelSize: root.textPx
        font.bold: true
        horizontalAlignment: root.vert ? Text.AlignHCenter : Text.AlignLeft
        wrapMode: root.vert && root._titleW(text) <= width ? Text.WordWrap : Text.NoWrap
        elide: Text.ElideRight
        maximumLineCount: root.vert ? 3 : 1
        x: root.vert ? Math.round(root.style.pad) : Math.round(pic.x + pic.width + root.style.cardGap)
        width: root.vert ? root.width - 2 * root.style.pad
             : root.isPill ? Math.min(implicitWidth, (root.width - root.padX - x) * 0.72)
             : root.width - root.padX - x
        y: root.vert ? Math.round(root.stackTop + pic.height + root.style.gap)
           : root.isPill ? Math.round((root.height - height) / 2)
           : Math.round((root.height - (height + (detailText.visible ? 2 + detailText.height : 0))) / 2)
    }
    Text {
        id: detailText
        visible: root.d.detail.length > 0
        text: root.d.detail
        color: Theme.textMuted
        font.family: root.style.textFont
        font.pixelSize: root.detailPx
        horizontalAlignment: root.vert ? Text.AlignHCenter : Text.AlignLeft
        wrapMode: root.vert && words.detail(text) <= width ? Text.WordWrap : Text.NoWrap
        elide: Text.ElideRight
        maximumLineCount: root.vert ? 2 : 1
        x: root.isPill ? Math.round(titleText.x + titleText.width + 8) : titleText.x
        width: root.vert ? titleText.width : root.width - root.padX - x
        y: root.vert ? Math.round(titleText.y + titleText.height + 2)
           : root.isPill ? Math.round((root.height - height) / 2)
           : Math.round(titleText.y + titleText.height + 2)
    }
}
