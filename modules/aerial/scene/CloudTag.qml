pragma ComponentBehavior: Bound

import QtQuick

import "../../common/float"
import "../../common/theme"
import "CloudPlace.js" as CP

// =============================================================================
// CloudTag.qml -- one thing in aerial's air (CloudHolo.qml places it, CloudPlace.js decides where): a FloatCard, so it sways on the cloud's one FloatClock and is dealt in
// when the popup opens. Its size is its plate's; the host puts its CENTRE where the placer says.
//
//   a NETWORK, named   a node dot in its band's hue, the name (a saved network in the text ink, a stranger muted; the first arc a little heavier), a small lock when it
//                      is secured, the open lock in the warn colour when it is public. NO outline at rest: a soft plate of the surface, only so the name reads over the board.
//   a network, a DOT   5 px in the band's hue (a hidden access point: hollow); under the resting pointer it opens into the named form
//   the own HOTSPOT / a hotspot's CLIENT   the broadcast / the device glyph in place of the dot
//   a DEVICE (Bluetooth, not connected)    one row as a network is: its kind's glyph in Bluetooth's hue where a network has its node; a stranger smaller and fainter
//
// Under the RESTING POINTER (`hovered`) or in the hand (`carried`): the plate goes opaque with a hairline in the hue and one line of facts under the name. Nothing else
// announces it (the hand cursor is the host's). `glint` 0..1 is the pulse passing: the node brightens and a ring leaves it.
// =============================================================================
FloatCard {
    id: root

    property var entry: null
    property color hue: Theme.accent
    property color btHue: Theme.accent
    property bool hovered: false
    property bool carried: false
    property bool target: false                 // in the hand and over where it may land
    property real presence: 1
    property real dim: 1
    property real glint: 0
    property real renderScale: 1
    property string fontFamily: "Inter"

    readonly property var _e: root.entry || ({ kind: "net", ssid: "", form: "dot", arc: 0, textW: 0, w: 10, h: 10 })
    readonly property bool isBt: root._e.kind === "bt"
    readonly property bool isNet: root._e.kind === "net"
    readonly property bool open_: root.hovered || root.carried
    // a dot under the pointer shows what it is: the named form, sized here (the placer sized the dot)
    readonly property bool named: root._e.form !== "dot" || root.open_
    readonly property bool small: root.isBt && root._e.paired !== true
    readonly property bool heavy: root.isNet && root._e.arc === 0 && root._e.form !== "dot"
    readonly property string nameText: root._e.ssid !== "" ? String(root._e.ssid) : (root._e.hidden === true ? "Hidden network" : "")
    readonly property real nameSize: root.small ? 10 : 11
    readonly property real _tw: {
        // the width the placer measured (TextMetrics, the drawn weight); a dot opened by the pointer was never measured: an advance per letter is near enough for a plate
        const w = root._e.form !== "dot" && root._e.textW > 0 ? root._e.textW : root.nameText.length * root.nameSize * 0.56 + 2;
        return Math.min(CP.TW_MAX, Math.max(8, Math.ceil(w)));
    }
    readonly property var _size: CP.sizeOf(Object.assign({}, root._e, { form: root.named ? "named" : "dot" }), root._tw)
    readonly property string facts: {
        const e = root._e;
        if (root.isBt)
            return e.pairing ? "Pairing…" : e.paired ? (e.battery >= 0 ? "Paired · " + e.battery + " %" : "Paired · away") : "Not paired";
        if (e.kind === "hotspot")
            return "Your hotspot · off";
        if (e.kind === "client")
            return "Joined";
        const sec = e.sec === "open" || e.sec === "" ? "open" : e.sec === "owe" ? "OWE" : e.sec === "eap" ? "802.1X" : String(e.sec).toUpperCase();
        return (e.signal | 0) + " % · " + (e.bands && e.bands.length ? e.bands.join(" / ") + " GHz · " : "") + sec;
    }
    readonly property real _factsW: root.open_ ? Math.ceil(factsMetrics.advanceWidth) + 16 : 0
    TextMetrics {
        id: factsMetrics
        font.family: root.fontFamily
        font.pixelSize: 9
        text: root.open_ ? root.facts : ""
    }

    width: Math.max(root._size[0], root._factsW)
    height: root._size[1] + (root.open_ ? 13 : 0)
    // the plate the pointer hits: this item's own box, a little padded (the resting box: the sway is a few px)
    readonly property rect hitRect: Qt.rect(-3, -3, root.width + 6, root.height + 6)

    opacity: root.presence * root.dim * (root.small && !root.open_ && root._e.pairing !== true ? 0.7 : 1)
    lifted: root.hovered && !root.carried

    // ---- the plate ----
    Rectangle {
        id: plate
        anchors.fill: parent
        visible: root.named
        radius: 7
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, root.open_ ? 1 : 0.82)
        border.width: root.open_ ? 1 : 0
        border.color: Qt.rgba(root._ink.r, root._ink.g, root._ink.b, root.target ? 1 : 0.55)
    }
    readonly property color _ink: root.isBt ? root.btHue : root.hue

    // ---- a dot ----
    Rectangle {
        visible: !root.named
        width: 5
        height: 5
        radius: 2.5
        x: (root.width - 5) / 2
        y: (root.height - 5) / 2
        color: root._e.hidden === true ? "transparent" : root.hue
        border.width: root._e.hidden === true ? 1 : 0
        border.color: root.hue
        opacity: 0.7 + 0.3 * root.glint
        scale: 1 + 0.5 * root.glint
    }

    // ---- a network / the hotspot / a client: node, name, lock ----
    Item {
        visible: root.named
        width: root.width
        height: CP.TAG_H
        // the node: a dot in the band's hue, or the kind's glyph
        Rectangle {
            id: node
            visible: root.isNet
            x: 7
            y: (CP.TAG_H - 6) / 2
            width: 6
            height: 6
            radius: 3
            color: root._e.hidden === true && root._e.ssid === "" ? "transparent" : root.hue
            border.width: root._e.hidden === true && root._e.ssid === "" ? 1 : 0
            border.color: root.hue
            scale: 1 + 0.35 * root.glint
        }
        Rectangle {
            // the pulse passing: a ring leaves the node
            visible: root.isNet && root.glint > 0.01
            readonly property real d: 6 + 9 * (1 - root.glint)
            x: 10 - d / 2
            y: CP.TAG_H / 2 - d / 2
            width: d
            height: d
            radius: d / 2
            color: "transparent"
            border.width: 1
            border.color: root.hue
            opacity: 0.55 * root.glint
        }
        Text {
            visible: !root.isNet
            x: 6
            width: 14
            height: CP.TAG_H
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: root.isBt ? CP.glyphOf(root._e.dev || "generic") : String.fromCodePoint(root._e.kind === "hotspot" ? 0xF0003 : 0xF011C)
            color: root._ink
            font.family: "Symbols Nerd Font"
            font.pixelSize: root.isBt ? (root.small ? 11 : 13) : 12
            opacity: (root._e.pairing === true ? 0.55 : 0.85) + 0.15 * root.glint
        }
        Text {
            id: nameText
            x: root.isNet ? 18 : root.small ? 23 : 25
            width: Math.min(root._tw, root.isBt ? (root.small ? 90 : 110) : CP.TW_MAX)
            height: CP.TAG_H
            verticalAlignment: Text.AlignVCenter
            text: root.nameText
            elide: Text.ElideMiddle
            color: root._e.known === true || root.open_ ? Theme.textPrimary : Theme.textMuted
            font.family: root.fontFamily
            font.pixelSize: root.nameSize
            font.weight: root.heavy ? Font.DemiBold : Font.Normal
            opacity: 0.9 + 0.1 * root.glint
        }
        Text {
            visible: root.isNet && (root._e.secured === true || root._e.publicNet === true)
            x: nameText.x + root._tw + 4
            width: 9
            height: CP.TAG_H
            verticalAlignment: Text.AlignVCenter
            text: String.fromCodePoint(root._e.publicNet === true ? 0xF033F : 0xF033E)
            color: root._e.publicNet === true ? Theme.warn : Theme.textFaint
            font.family: "Symbols Nerd Font"
            font.pixelSize: 9
        }
    }

    // ---- the facts, under the name, while it is open ----
    Text {
        visible: root.open_ && root.named
        x: 8
        y: root._size[1] - 2
        width: root.width - 16
        text: root.facts
        color: Theme.textMuted
        font.family: root.fontFamily
        font.pixelSize: 9
    }
}
