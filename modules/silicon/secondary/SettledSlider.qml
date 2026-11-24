pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/scroll"

// =============================================================================
// SettledSlider.qml -- one number of the CPU panel on a groove: its name (a hover tip says what it
// is), its figure at the right in a slot, and the shell's GrooveSlider under them with the mute
// mechanic off. It is the LLM pdf menu's slider row (LlmPdfMenu) lifted into a part;
// the two should become one in common/components when LlmPdfMenu is next touched.
//
// WHEN A VALUE IS WRITTEN. A write is a pkexec round trip and the machine's power limits move with
// it, so `committed(value)` must not follow the ball pixel by pixel. The FIGURE does follow it (the
// person sees what they are choosing); the signal fires on RELEASE, or after `settleMs` of the ball
// standing still while held. Release is watched passively by a PointHandler in front of the slider's
// own MouseArea (a handler on the slider itself sits behind that area and never sees the press once
// it has accepted it). A wheel over the slider is eaten here: a two-finger scroll that happens to
// cross a power limit must not change it.
//
// WHAT IS SHOWN. `hostValue` is the panel's answer -- the pending value while a write settles, else
// the fact -- and the row shows it, EXCEPT while the person is choosing (`_drag`). The moment the
// choice is handed over (`committed` is synchronous: the host aims its target in the same call) the
// drag is dropped and the row shows the host again: the accepted value stays where it was put with
// no flicker back to the old one, and a refused one slides back to what the machine says. The slider
// owns its `value` while dragged (it assigns it, which severs any binding), so the row drives it
// imperatively both ways -- the TabSelector idiom.
//
// THE WALLS. `lowWall` / `highWall` keep a value out of a range the machine would refuse (PL1 never
// above PL2). The ball stops at the wall; the figure says the wall's number.
//
// ONE COLUMN EDGE. The groove's visible ends sit on the content column's edges (the title's first
// letter, the figure's last digit), so the slider is as much wider than the column as the groove
// is inset in it; the ball's overhang falls in the card's padding.
// =============================================================================
Item {
    id: row

    // ---- the host's side -----------------------------------------------------------------------
    property SecondaryStyle look: null
    property Item overlay: null
    property string title: ""
    property string tip: ""
    property string unit: "%"
    property real from: 0
    property real to: 100
    property real step: 1
    property real hostValue: 0
    property real lowWall: -1e9
    property real highWall: 1e9
    property int settleMs: 250

    // The value was chosen and has settled: the host writes it (and aims its target at once).
    signal committed(real value)

    // ---- what the row says ---------------------------------------------------------------------
    property real _drag: -1
    readonly property real shown: row._drag >= 0 ? row._drag : row.hostValue
    readonly property bool dragging: row._drag >= 0
    readonly property string figure: figureText.text

    readonly property string _family: row.look ? row.look.fontFamily : "Inter"
    readonly property real _bodySize: row.look ? row.look.bodySize : 12
    readonly property real _figureSize: row.look ? row.look.figureSize : 11
    // How far the groove's box reaches up into the title's row. The box carries ~15 px of room above
    // the groove for a bent ball, so the title can stand over its own slider (CLAUDE.md "gap text to
    // rail" 6-8 px of ink) and further from the one above it (the card's gap plus the ink under it).
    readonly property real titleOverlap: 7

    // The slider's box carries room above and below the groove for a bent, squished ball; at rest the
    // ink is the bar (half its thickness, its bevel and a shadow) around the groove's centre. The row
    // ends there, so the air under the last slider in a card equals the air over its title, and the
    // gap between two sliders is the card's gap -- the slack still belongs to the slider's own box,
    // which reaches exactly one gap into whatever follows.
    readonly property real inkBelow: 10
    implicitHeight: Math.ceil(slider.y + slider.height / 2 + row.inkBelow)

    // ---- the figure's slot: as wide as the widest value it can hold, never as wide as the one it
    // holds (CLAUDE.md "Figures never jitter"; Audiowide has no tabular digits) -------------------
    FontMetrics {
        id: figureMetrics
        font.family: row._family
        font.pixelSize: row._figureSize
    }
    FontMetrics {
        id: bodyMetrics
        font.family: row._family
        font.pixelSize: row._bodySize
    }
    function _slot(template) {
        // The metrics' own font is read here: advanceWidth() is a method call and captures nothing,
        // so this read is the dependency, and it is what makes a re-measure follow a face change.
        const f = figureMetrics.font;
        void f.family;
        void f.pixelSize;
        let widest = "0";
        let wd = 0;
        for (const d of "0123456789") {
            const a = figureMetrics.advanceWidth(d);
            if (a > wd) {
                wd = a;
                widest = d;
            }
        }
        return Math.ceil(figureMetrics.advanceWidth(template.replace(/[0-9]/g, widest)));
    }
    readonly property int _digits: Math.max(String(Math.round(row.from)).length, String(Math.round(row.to)).length)
    readonly property real figureSlot: row._slot("0".repeat(row._digits) + " " + row.unit)

    // ---- the title row ---------------------------------------------------------------------------
    Item {
        id: titleRow
        width: row.width
        height: Math.ceil(bodyMetrics.height) + 2

        TipLabel {
            id: titleLabel
            look: row.look
            overlay: row.overlay
            tip: row.tip
            text: row.title
            maxWidth: titleRow.width - row.figureSlot - 8
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: figureText
            x: titleRow.width - width
            width: row.figureSlot
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: Math.round(row.shown) + " " + row.unit
            color: Theme.textPrimary
            font.family: row._family
            font.pixelSize: row._figureSize
        }
    }

    // ---- the groove --------------------------------------------------------------------------------
    // How far the slider's own box must extend past the column so the groove's VISIBLE end (its cap's
    // outer edge, at rest) lands on the column's edge: the groove starts `grooveStart` inside the
    // box, and its cap reaches half the bar's thickness plus the bevel beyond that point.
    readonly property real _bleed: slider.grooveStart - slider.scFat / 2 - slider.grooveBevelWidth * slider.sizeScale

    GrooveSlider {
        id: slider
        x: -row._bleed
        y: titleRow.height - row.titleOverlap
        width: row.width + 2 * row._bleed
        height: Math.round(slider.neededCross)
        orientation: "horizontal"
        sizeScale: 0.8
        ballSize: 12
        edgePadding: 8
        // A setting has nothing to mute: no second bar, no snap, no thickness swap.
        muteEnabled: false
        allowBoost: false
        sparksEnabled: false
        maxValue: 1

        surfaceColor: Theme.listBox
        grooveColor: Theme.headerBox
        grooveBevelColor: Theme.bevel
        grooveShadowColor: Theme.border
        ballColor: Theme.accent
        ballShadowColor: Theme.ballShadow

        onUserChangedValue: v => row._moved(v)
    }

    // Release, observed passively IN FRONT of the slider; the wheel, eaten.
    Item {
        anchors.fill: slider
        z: 1
        PointHandler {
            onActiveChanged: {
                if (active)
                    ease.stop();
                else
                    row.flush();
            }
        }
        WheelArea {
            anchors.fill: parent
            turned: wheel => wheel.accepted = true
        }
    }

    // ---- driving the ball -------------------------------------------------------------------------
    readonly property real _norm: row.to > row.from
        ? Math.max(0, Math.min(1, (row.shown - row.from) / (row.to - row.from))) : 0
    property bool _placed: false

    NumberAnimation {
        id: ease
        target: slider
        property: "value"
        duration: 200
        easing.type: Easing.OutCubic
    }
    // The host's value moved (a profile switch, a write landing, a refusal): the ball goes there,
    // unless the person has hold of it.
    function _drive() {
        if (row._drag >= 0)
            return;
        ease.stop();
        if (!row._placed || !row.visible || Math.abs(slider.value - row._norm) < 1e-4) {
            slider.value = row._norm;
            return;
        }
        ease.from = slider.value;
        ease.to = row._norm;
        ease.restart();
    }
    on_NormChanged: row._drive()
    Component.onCompleted: {
        slider.value = row._norm;
        row._placed = true;
    }

    // ---- choosing ----------------------------------------------------------------------------------
    function quantise(v) {
        const q = row.from + Math.round((v - row.from) / row.step) * row.step;
        return Math.max(row.from, Math.min(row.to, q));
    }

    function _moved(v) {
        ease.stop();
        const raw = row.from + Math.max(0, Math.min(1, v)) * (row.to - row.from);
        let q = row.quantise(raw);
        const lo = Math.max(row.from, row.lowWall);
        const hi = Math.min(row.to, row.highWall);
        if (lo <= hi) {
            const c = Math.max(lo, Math.min(hi, q));
            if (c !== q) {
                // the wall: the ball stops there
                q = c;
                slider.value = (q - row.from) / (row.to - row.from);
            }
        }
        if (q !== row._drag)
            row._drag = q;
        settle.restart();
    }

    // Hand the choice over -- once -- and show the host's answer again.
    function flush() {
        settle.stop();
        if (row._drag < 0)
            return;
        const q = row._drag;
        if (q !== row.hostValue)
            row.committed(q);
        row._drag = -1;
        row._drive();
    }

    Timer {
        id: settle
        interval: row.settleMs
        onTriggered: row.flush()
    }
}
