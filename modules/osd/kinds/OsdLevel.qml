pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// OsdLevel.qml -- volume, mic and brightness: a glyph, a GrooveSlider, the
// figure, and (horizontal bar only) the device's name.
//
//   h     glyph | slider | figure over name        the slider runs along x
//   v     glyph / slider / figure                  the slider runs along y; the glyph's ink
//                                                  and the figure's stand inkPadV from the ends
//   pill  glyph | the SAME slider as h | figure    compact, no input at all (one drawing, the slider's, a touch of it per pill, so the
//         pill looks like the OSD)
//
// The GrooveSlider is the real one -- ball, mute-by-pulling-across, boost --
// with every colour bound to Theme. Brightness takes `muteEnabled: false` (one
// bar), volume takes `allowBoost` when the payload says boost.
//
// THE DISPLAYED VALUE IS ONE CLOCK (OsdEased): 120 ms OutCubic when an app or
// a key moved it, direct while the pointer drags (the service's echo of a
// dragged value must not restart an ease under the finger). `value` is written
// through a Binding: the slider assigns it itself on a drag, which would end a
// plain binding for good.
//
// WHAT THE FIGURE SAYS (`shown`). A drag or a wheel notch is written to the
// source and the source does not echo it back (the content already shows where
// the ball is), so the payload still holds the value from before the pointer
// touched anything. The figure, the glyph and the next wheel notch therefore
// read the pointer's own value (`_userV`) for as long as it is the newer one,
// and the service's again the moment it speaks (the next payload: a key, an
// app, the mute switch).
//
// The wheel is read by OsdContent (one MouseArea above this) and handed to
// `wheelStep(units)` here, which knows the range and the boost limit.
//
// A SLOW DISPLAY (DDC). A brightness card for an external display can carry `pending` (the request went out and the display has not
// confirmed yet), `unavailable` + `note` (the display takes no brightness over DDC, or its last request failed: the note says why under
// the display's name). The figure and the fill stand at the GOAL at once; while pending the figure and the glyph are mixed toward the faint
// ink by ONE eased fraction (`_dim`, never a Behavior on a colour) and a slim accent mark sweeps the foot of the card ("sent"). The pill
// is the compact look: it takes the mixed ink only.
//
// SPARKS. The ball of the slider, and on the pill the head
// of the fill, shed a few calm sparks (OsdSparks) for every change of the DISPLAYED value that the pointer did not make:
// a key, an app, the mute switch. A drag keeps the slider's own (it needs speed a key step never has), so nothing sheds twice.
// =============================================================================
Item {
    id: root

    property string kind: "volume"
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
    readonly property bool isPill: root.orientation === "pill"
    readonly property bool isBrightness: root.kind === "brightness"
    readonly property bool boost: root.kind === "volume" && root.p.boost === true
    readonly property real maxV: Math.max(1, Number(root.p.max) || 1)
    // What the slider can reach right now.
    readonly property real limit: root.boost ? root.maxV : 1
    readonly property real goal: Math.max(0, Math.min(root.maxV, Number(root.p.value) || 0))
    readonly property bool muted: root.p.muted === true
    // The pointer's value while it is the newer one (a drag, a wheel notch); -1 = the payload's.
    property real _userV: -1
    readonly property real shown: root._userV >= 0 ? root._userV : root.goal
    readonly property string devType: root.p.device && root.p.device.type ? root.p.device.type : ""
    readonly property string devName: root.p.device && root.p.device.name ? root.p.device.name : ""
    readonly property int pct: Math.round(root.shown * 100)
    readonly property bool unavailable: root.p.unavailable === true
    readonly property bool pending: root.p.pending === true && !root.unavailable
    readonly property string note: root.p.note ? String(root.p.note) : ""
    // 0 = settled, 1 = waiting for the display / not available: one fraction, eased
    readonly property real _dimGoal: root.pending || root.unavailable ? 1 : 0
    property real _dim: root._dimGoal
    Behavior on _dim {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }

    readonly property string glyph: {
        if (root.kind === "volume")
            return glyphs.outputGlyph(root.devType, root.shown, root.muted);
        if (root.kind === "mic")
            return glyphs.inputGlyph(root.muted);
        // brightness: three suns, dim to bright (Material brightness-5/6/7)
        return root.shown < 0.34 ? "\u{F00DE}" : root.shown < 0.67 ? "\u{F00DF}" : "\u{F00E0}";
    }

    AudioGlyphs {
        id: glyphs
    }

    // ---- the one clock --------------------------------------------------------
    OsdEased {
        id: eased
        goal: root.shown
        ms: root.style.valueEaseMs
    }
    Timer {
        id: directHold
        interval: root.style.directHoldMs
        onTriggered: eased.direct = false
    }
    property bool _born: false
    Timer {
        running: true
        interval: 500
        onTriggered: root._born = true
    }
    // A payload is the service speaking: what it says is the truth again, and the
    // ball follows it (an ease, unless the pointer is still down).
    onPayloadChanged: {
        root._userV = -1;
        // the mute came from outside the card's own drag (the bar icon, a key, an app): the ball changes lanes all the same
        // (read the payload itself: `p` and `muted` still hold the old one while this handler runs)
        const pl = root.payload;
        if (pl && pl.muteFlip === true && slider.lineLength > 0)
            root._burstWhenSeen(pl.muted === true);
    }

    // THE BURST OF A BALL CHANGING LANES, whatever the method.
    // The slider throws it itself, but only when ITS drag snaps the ball over (`_fireMuteSnap`): a mute by the bar icon, the key or an app
    // reaches the slider as a bare change of `muted` and throws nothing. The service says `muteFlip` on a request whose mute differs from
    // the last one it said; the card throws the slider's own burst for it -- unless the drag just did (its request comes back with the flip).
    property double _snapAt: 0
    property double _burstAt: 0
    function _muteBurst(toMuted) {
        const now = Date.now();
        if (root.isBrightness || now - root._snapAt < 2500 || now - root._burstAt < 300)
            return;
        root._burstAt = now;
        slider._emitMuteBurst(toMuted);
    }
    // A card made BY the mute (closed when the key came): it is born in the muted lane, so the ball's arrival is the burst, once its
    // geometry is in place AND the card can be seen: the fullscreen pill makes its content at the spawn and shows it only once the
    // capsule has widened (~0.5 s later), so a burst thrown at birth would play to nobody. Tried every 60 ms until the card's own and every
    // ancestor's opacity is full (for at most ~4 s; the bar's card is there at the first try).
    property int _bornTries: 0
    property bool _burstTo: false
    // A content the pill keeps between presents is told the next payload while it is still hidden: the same wait.
    function _burstWhenSeen(toMuted) {
        root._burstTo = toMuted;
        root._bornTries = 0;
        if (root._seen())
            root._muteBurst(toMuted);
        else
            bornBurst.restart();
    }
    function _seen() {
        for (let it = root; it; it = it.parent) {
            if (!it.visible || it.opacity < 0.99)
                return false;
        }
        return true;
    }
    Timer {
        id: bornBurst
        interval: 60
        repeat: true
        onTriggered: {
            if (!root._seen()) {
                // never shown (a pill dismissed first): no burst for nobody
                if (++root._bornTries >= 70)
                    bornBurst.stop();
                return;
            }
            bornBurst.stop();
            root._muteBurst(root._burstTo);
        }
    }
    Component.onCompleted: {
        if (root.p.muteFlip === true) {
            root._burstTo = root.muted;
            root._bornTries = 0;
            bornBurst.start();
        }
    }

    function _user(v) {
        eased.direct = true;
        eased.snap(v);
        directHold.restart();
        root._userV = v;
        root.userValue(v);
        root.touched();
    }

    // A wheel (or a touchpad scroll) of `units` notches; true when it did
    // something. Notches are 120 angle units, a touchpad's are fractions.
    function wheelStep(units) {
        if (root.isPill || !root.interactive || units === 0)
            return false;
        const v = Math.max(0, Math.min(root.limit, root.shown + units * root.style.wheelStep * root.limit));
        if (v === root.shown)
            return false;
        root._user(v);
        return true;
    }

    // ---- shared look --------------------------------------------------------
    readonly property color glyphColor: root.muted ? Theme.textFaint : Mix.c(Theme.textPrimary, Theme.textFaint, root._dim)
    readonly property color figureColor: root.muted ? Theme.textFaint : Mix.c(Theme.textPrimary, Theme.textFaint, root._dim)
    readonly property real figPx: root.isPill ? root.style.pillFigurePx
                                : root.vert ? root.style.figurePxV : root.style.figurePx

    OsdGlyph {
        id: glyphItem
        osd: root.style
        glyph: root.glyph
        size: root.isPill ? root.style.pillGlyphPx : root.style.glyphPx
        slot: root.isPill ? root.style.pillGlyphPx : root.style.glyphSlot
        color: root.glyphColor
        x: root.vert ? Math.round((root.width - width) / 2)
                     : Math.round(root.isPill ? root.style.pillPad : root.style.pad)
        // Vertical: the glyph's INK stands inkPadV from the top, as the figure's
        // does from the foot (the boxes carry room of their own, so a pad of 12
        // on the boxes would leave the two ends unequal).
        y: root.vert ? Math.round(root.style.inkPadV - glyphItem.inkTop) : Math.round((root.height - height) / 2)
    }

    OsdFigure {
        id: figure
        text: String(root.pct)
        px: root.figPx
        family: root.style.figureFont
        color: root.figureColor
        percentColor: root.glyphColor
        // Horizontal: the figure over the name, both right-aligned to the
        // padding; vertical: centred at the foot; pill: the right end.
        x: root.vert ? Math.round((root.width - width) / 2)
                     : Math.round(root.width - (root.isPill ? root.style.pillPad : root.style.pad) - width)
        y: root.vert ? Math.round(root.height - root.style.inkPadV - height + figure.inkBottom)
                     : root.isPill ? Math.round((root.height - height) / 2)
                       : Math.round((root.height - colH) / 2)
        readonly property real colH: height + (nameText.visible ? 2 + nameText.implicitHeight : 0) + (noteText.visible ? 1 + noteText.implicitHeight : 0)
    }

    Text {
        id: nameText
        visible: !root.vert && !root.isPill && root.devName.length > 0
        width: root.style.nameW
        x: Math.round(root.width - root.style.pad - width)
        y: Math.round(figure.y + figure.height + 2)
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
        text: root.devName
        color: Theme.textMuted
        font.family: root.style.textFont
        font.pixelSize: root.style.namePx
    }

    Text {
        id: noteText
        visible: !root.vert && !root.isPill && root.note.length > 0
        width: root.style.nameW
        x: Math.round(root.width - root.style.pad - width)
        y: Math.round(nameText.y + (nameText.visible ? nameText.implicitHeight + 1 : 0))
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
        text: root.note
        color: Theme.textFaint
        font.family: root.style.textFont
        font.pixelSize: root.style.namePx
    }

    // the "sent" mark: a short accent line sweeping the foot of the card while the display has not answered
    Item {
        id: sentMark
        visible: opacity > 0 && !root.isPill
        opacity: root.pending ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: 160
            }
        }
        x: root.vert ? Math.round(root.width / 2 - 1) : Math.round(root._alongStart)
        y: root.vert ? Math.round(root._alongStart) : Math.round(root.height - 3)
        width: root.vert ? 2 : Math.max(0, Math.round(root._alongEnd - root._alongStart))
        height: root.vert ? Math.max(0, Math.round(root._alongEnd - root._alongStart)) : 2
        clip: true
        Rectangle {
            id: sweepBar
            radius: 1
            color: Theme.accent
            width: root.vert ? 2 : Math.round(sentMark.width * 0.25)
            height: root.vert ? Math.round(sentMark.height * 0.25) : 2
            property real t: 0
            x: root.vert ? 0 : Math.round(-width + (sentMark.width + width) * t)
            y: root.vert ? Math.round(-height + (sentMark.height + height) * t) : 0
            NumberAnimation on t {
                from: 0
                to: 1
                duration: 900
                loops: Animation.Infinite
                running: root.pending
            }
        }
    }

    // ---- sparks -------------------------------------------------------------
    // Where the moving head is, in this item's frame: the slider's ball (its canvas is turned a quarter when
    // vertical -- see the mark inside the slider), or the pill's fill head.
    property real _headX: -1
    property real _headY: -1
    property bool _headKnown: false
    function _head() {
        return ballMark.mapToItem(root, 0, 0);
    }
    function _shedStep() {
        if (!root._born)
            return;
        const h = root._head();
        const known = root._headKnown;
        const px = root._headX;
        const py = root._headY;
        root._headX = h.x;
        root._headY = h.y;
        root._headKnown = true;
        // the first reading only learns where the head is; a drag has sparks of its own; a muted level is quiet
        if (!known || eased.direct || root.muted)
            return;
        sparks.shed(h.x, h.y, h.x - px, h.y - py);
    }
    Connections {
        target: eased
        function onValueChanged() {
            root._shedStep();
        }
    }
    // the pill's head moves with `eased.value` too, but the pill is built fresh: learn it before the first change
    onWidthChanged: root._headKnown = false
    onHeightChanged: root._headKnown = false

    OsdSparks {
        id: sparks
        anchors.fill: parent
        z: 5
        style: root.style
        color: Theme.accent
    }

    // ---- bar slider ---------------------------------------------------------
    // Where the groove's visible end sits against its slot: the slider item
    // starts `_cap` before the first groove pixel so the gap to the glyph is the
    // style's gap, not the gap plus the slider's own end padding.
    readonly property real _cap: slider.grooveStart - slider.scFat / 2
    // The ink's centre across the line: the mute bar stands on one side of the
    // main bar, so centring the ITEM would lean the picture away from it.
    readonly property real _inkShift: slider.muteEnabled
        ? (-slider.scFat / 2 + slider.scTrackSep + slider.scThin / 2) / 2 : 0
    // The along-axis room between the glyph and the figure.
    readonly property real _alongStart: root.vert
        ? glyphItem.y + glyphItem.height + root.style.gap
        : glyphItem.x + glyphItem.width + root.style.gap
    readonly property real _alongEnd: root.vert
        ? figure.y - root.style.gap
        : root.isPill ? figure.x - root.style.gap
        : root.width - root.style.pad - root.style.nameW - root.style.gap

    GrooveSlider {
        id: slider
        enabled: root.interactive && !root.unavailable
        orientation: root.vert ? "vertical" : "horizontal"
        // The vertical slider runs 0 at the top; a level reads upward, so it
        // is turned half a round (its canvas is turned a quarter, which puts
        // "right" on the screen's left; the half round puts it back on the
        // right, where `_inkShift` expects it). Its MouseArea turns with it.
        rotation: root.vert ? 180 : 0
        muteSide: root.vert ? "right" : "below"
        sizeScale: root.style.sliderScale
        muteEnabled: !root.isBrightness
        // The ball's sparks wait for the first half second: a slider still
        // settling into its first geometry throws a few streaks at its origin.
        sparksEnabled: root._born && eased.direct
        // Born at its value (the Binding below keeps it there): left at the
        // slider's own 0.5 the ball would fly to the value on the first frames
        // and shed sparks all the way.
        value: eased.value
        muted: root.muted
        allowBoost: root.boost
        boostMaxValue: root.maxV > 1 ? root.maxV : 1.5

        x: root.vert ? Math.round((root.width - width) / 2 - root._inkShift)
                     : Math.round(root._alongStart - root._cap)
        y: root.vert ? Math.round(root._alongStart - root._cap)
                     : Math.round((root.height - height) / 2 - root._inkShift)
        width: root.vert ? implicitWidth : Math.round(root._alongEnd - root._alongStart + 2 * root._cap)
        height: root.vert ? Math.round(root._alongEnd - root._alongStart + 2 * root._cap) : implicitHeight

        surfaceColor: Theme.surface
        grooveColor: Theme.panelSunk
        grooveBevelColor: Theme.bevel
        grooveShadowColor: Theme.border
        ballColor: Theme.accent
        // A muted ball is the faint ink, as the glyph and the figure beside it are, and as the audio popup's muted rows draw
        // theirs. Theme.shadowDeep was a grey in light mode but #0B0C0E in dark: a black hole in the groove. Its glow stays
        // shadowDeep: a faint-ink glow reaches past the pill's capsule while it opens (osd_pill_open_probe, mic: 1.5 px of 2).
        ballMutedColor: Theme.textFaint
        muteBarColor: Theme.border
        muteBarBevelColor: Theme.bevel
        muteBarShadowColor: Theme.shadowDeep
        ballMutedShadowColor: Theme.shadowDeep
        muteBurstColor: Theme.accentBevel
        unmuteBurstColorStart: Theme.accentBevel
        unmuteBurstColorEnd: Theme.accent

        onUserChangedValue: function (v) {
            root._user(v);
        }
        onUserToggledMute: {
            root._snapAt = Date.now();
            if (!root.isBrightness)
                root.userToggleMute();
            root.touched();
        }
        onUserToggledBoost: {
            if (root.kind === "volume")
                root.userToggleBoost();
            root.touched();
        }

        // The ball's centre, in the slider's own frame: along its line, and on the active bar's centre line (what the
        // slider's own emitter uses). The slider draws in a canvas turned a quarter when vertical -- a turn of 90
        // sends canvas (along, cross) to (width - cross, along) -- so this mark is what `_head` maps to the card.
        Item {
            id: ballMark
            width: 0
            height: 0
            x: root.vert ? slider.width - (slider._activeBarCenterY + slider._ballCrossOffset) : slider.ballAlong
            y: root.vert ? slider.ballAlong : slider._activeBarCenterY + slider._ballCrossOffset
        }
    }
    Binding {
        target: slider
        property: "value"
        value: eased.value
    }
}
