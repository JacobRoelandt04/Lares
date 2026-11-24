pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/glyphs"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "parts"
import "parts/NotifyGlyphs.js" as G
import "parts/BellPose.js" as Pose

// =============================================================================
// NotificationsBarButton.qml -- the bell in the bar.
//
//   bell           nothing held back
//   bell-sleep     toasts held back: do not disturb, or held (fullscreen, a
//                  screen share, the lock) -- the z's, one glyph for "muted"
//   its colour     something arrived since the manager was last opened: the
//                  glyph takes the colour of the most urgent such group
//                  (GroupPalette: critical, system, normal, low; no count, no
//                  dot); the muted ink when nothing did
//
// Left click opens the manager; RIGHT click toggles do-not-disturb. The
// glyph is a plain glyph button's (BarGlyphButton, notes, the LLM star): its
// own hover hue (BarHues `bellHover`, which is none of the unread colours)
// under the pointer and while the manager is up, with NO ground behind it (a
// sunk square on hover looks worse). Hover is one eased fraction on the bar's
// one hover clock; the unread colour comes and goes on a 160 ms fraction;
// nothing animates a colour.
//
// THE FLOURISH (feedback/notification.md "The flourish"): the bell RINGS -- a
// quick, bouncy swing about its crown with the clapper hanging late behind it
// (BellPose.js) -- on EVERY new notification, whatever happens to its toast
// (do not disturb, a share, fullscreen, the lock: the bell rings all the
// same), and when the pointer comes onto it (GlyphFlourish: once per entry).
// A notification while it rings re-strikes it ("extend": the swing lifts back
// to full where it stands, so a burst rings longer, never harder). A record an
// undo brings back is not news: only one that arrived just now rings. At rest
// the glyph is the plain Text (PosedGlyph) and nothing ticks.
// =============================================================================
Item {
    id: btn

    property var owner: null
    readonly property var service: btn.owner ? btn.owner.service : null
    readonly property bool active: btn.owner ? btn.owner.popupMine : false

    property string orientation: "horizontal"
    property real barRotation: 0
    // The look is the owner's NotificationStyle (the bell's block); each
    // default is the value drawn when no style is given.
    readonly property NotificationStyle style: btn.owner ? btn.owner.style : null
    property real glyphSize: btn.style ? btn.style.bellGlyphSize : 16
    property real padAlong: btn.style ? btn.style.bellPadX : 8
    property real padAcross: btn.style ? btn.style.bellPadY : 4

    readonly property bool vertical: btn.orientation === "vertical"
    readonly property bool dnd: !!btn.service && !!btn.service.dnd
    readonly property bool held: !!btn.service && (btn.service.holdReason || "") !== ""
        || (!!btn.owner && !!btn.owner.laneHeld)
    readonly property string dotGroup: btn.service ? (btn.service.dotGroup || "") : ""

    implicitWidth: Math.ceil(btn.glyphSize + 2 * btn.padAlong)
    implicitHeight: Math.ceil(btn.glyphSize + 2 * btn.padAcross)

    // The groups' colours are the style's (the panel's Colours rows write
    // them, and the cards and the manager read the same palette); a bell with
    // no style has its own.
    readonly property GroupPalette _groups: btn.style && btn.style.groups ? btn.style.groups : ownGroups
    GroupPalette {
        id: ownGroups
    }

    // The pointer, and the manager being ours: one fraction on the bar's hover clock.
    property real hoverF: area.containsMouse || btn.active ? 1 : 0
    Behavior on hoverF {
        GlyphHoverEase {}
    }
    // Something unseen: the glyph takes its group's colour (160 ms, the shell's presence fade).
    property real unreadF: btn.dotGroup !== "" && !btn.active ? 1 : 0
    Behavior on unreadF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    // The glyph keeps the last group's colour while it fades back to the muted ink. The colour reads `dotGroup` itself while one is
    // unread and the latch only once it has cleared: a bell BUILT with a group already unread (a toast that lands while a new screen's
    // frame is built: Panorama's "connected") first evaluates `dotGroup` inside this binding, and its change handler -- which runs
    // for a binding's first value -- wrote the latch the binding had read: a binding loop on the glyph's colour.
    property string _unreadShown: ""
    onDotGroupChanged: if (btn.dotGroup !== "") btn._unreadShown = btn.dotGroup
    readonly property string _unreadGroup: btn.dotGroup !== "" ? btn.dotGroup : btn._unreadShown
    readonly property color unreadColour: btn._unreadGroup !== "" ? btn._groups.color(btn._unreadGroup) : Theme.textMuted

    // ---- the flourish ----
    property bool flourishEnabled: true
    // one strike's life, ms (a re-strike ends this long after it)
    property int flourishMs: 900
    readonly property alias flourish: ring
    GlyphFlourish {
        id: ring
        // the OLED care's name for it (FlourishRegistry): it says a notification came, so it plays at random only when switched on
        group: "bell"
        armed: btn.flourishEnabled
        ms: btn.flourishMs
        overlap: "extend"
        hoverArea: area
    }
    // A record restored by an undo comes back through the same signal as a new one: only a record that ARRIVED just now is
    // news. Its arrival stamp is taken in the same call that emits (NotificationService._place), so "now" is milliseconds; a
    // clear and its undo inside a quarter second of an arrival are no human's.
    Connections {
        target: btn.service
        ignoreUnknownSignals: true
        function onRecordAdded(uid) {
            const store = btn.service ? btn.service.store : null;
            const rec = store ? store.get(uid) : null;
            // notifications.jsonc bell.ring: "always" | "notDnd" | "never"
            const when = btn.service && btn.service.config ? btn.service.config.bell.ring : "always";
            if (when === "never" || (when === "notDnd" && btn.dnd))
                return;
            if (rec && Date.now() - Number(rec.arrivedMs || 0) < 250)
                ring.play("notification");
        }
    }

    PosedGlyph {
        id: glyph
        anchors.centerIn: parent
        rotation: btn.vertical ? -btn.barRotation : 0
        readonly property bool sleeping: btn.dnd || btn.held
        text: glyph.sleeping ? G.bellSleep : G.bell
        family: G.family
        pixelSize: btn.glyphSize
        color: Mix.c(Mix.c(Theme.textMuted, btn.unreadColour, btn.unreadF), BarHues.bellHover, btn.hoverF)
        posing: ring.playing
        parts: ring.playing ? Pose.path(glyph.sleeping, ring.t, ring.kicks, ring.ms, null, glyph.pixelSize, glyph.origin.x,
                                        glyph.origin.y) : []
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) {
                if (btn.service)
                    btn.service.dnd = !btn.service.dnd;
            } else if (btn.owner) {
                btn.owner.toggle();
            }
        }
    }
}
