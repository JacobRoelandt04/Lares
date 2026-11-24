pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "TuningModel.js" as TM

// =============================================================================
// TuningPanel.qml -- the CPU's tuning card, the content of the secondary a click on the package
// opens (SiliconSecondary kind "tuning").
//
//   Behaviour   the energy preference (four steps, locked with its reason while the governor is
//               performance), turbo, the governor with one honest line of what it does here -- the
//               selected one's, or the one under the pointer while it is on a tab, so each can be
//               read before it is chosen
//   Limits      the highest speed as a share, and PL1 / PL2 -- the whole caps block hidden while the
//               firmware's limits are not writable; lower than the firmware's own, never PL1 over PL2
//   header      "Reset to profile" at the right, only while the live values differ from the profile's
//
// IT PERFORMS NOTHING ITSELF. Every control asks `vm.setTuning(patch)` / `vm.resetTuning()`; the
// service validates (and refuses with words, which the popup's caption shows), aims `tuningTarget`
// and writes after its own settle.
//
// WHAT IS SHOWN IS THE TARGET FIRST. While a write settles the controls read `vm.tuningTarget`
// (the pending patch, which a profile step fills with the profile's linked values too), so a value
// the person just chose never flickers back to the old one; the fact answers once nothing is
// pending, and a refused write plays back to it. A cap the patch says is "firmware" is the
// ceiling's number.
//
// EACH SHOWN VALUE IS ONE SCALAR READ OF ITS TWO SOURCES (the facts rebuild every tick, and a
// binding that read another derived binding could see the pair from two generations). The tab lists
// are built from a KEY STRING of the kernel's lists: a TabSelector regenerates every tab when its
// `tabs` array is reassigned, and `vm.cpu` is a new object every second.
//
// Every number is on whole pixels; every figure sits in a slot; presence fades (160 ms) and nothing
// else animates but the ball and the pill.
// =============================================================================
Item {
    id: panel

    property var vm: null
    property SecondaryStyle look: SecondaryStyle {}
    property Item overlay: null
    property real panelWidth: 380

    // ---- the facts: one read of each source -----------------------------------------------------
    readonly property var _noCpu: ({
        present: false, eppChoices: [], governors: [], eppLocked: false, tweaked: false,
        features: { epp: false, turbo: false, governor: false, maxPerfPct: false, caps: false },
        maxPerfRange: { min: null, max: null }, capsWritable: false, capFloorW: null,
        capCeilW: { pl1: null, pl2: null }, epp: "", turbo: false, governor: "", maxPerfPct: null,
        pl1W: null, pl2W: null
    })
    readonly property var cpu: panel.vm && panel.vm.cpu ? panel.vm.cpu : panel._noCpu
    readonly property var tgt: panel.vm && panel.vm.tuningTarget ? panel.vm.tuningTarget : ({})

    function _has(k) {
        return panel.tgt[k] !== undefined && panel.tgt[k] !== null;
    }
    // A number, or `d`: a limit the machine does not have is null in the facts, and a slider that is
    // not shown is still bound.
    function _num(v, d) {
        return typeof v === "number" && isFinite(v) ? v : d;
    }
    // A cap in watts: the pending one ("firmware" is the ceiling), else the fact, else the ceiling.
    function _cap(key, ceil, fact) {
        if (panel._has(key))
            return panel._num(panel.tgt[key] === "firmware" ? ceil : panel.tgt[key], 0);
        return panel._num(fact, panel._num(ceil, 0));
    }

    readonly property string governorShown: panel._has("governor") ? panel.tgt.governor : panel.cpu.governor
    // The kernel fixes the energy preference while the governor is performance: the pending
    // governor decides before the fact does, so the lock follows the click, not the write.
    readonly property bool locked: panel._has("governor") ? panel.tgt.governor === "performance" : panel.cpu.eppLocked
    readonly property string eppShown: panel.locked ? "performance"
        : (panel._has("epp") ? panel.tgt.epp : panel.cpu.epp)
    readonly property bool turboShown: panel._has("turbo") ? panel.tgt.turbo === true : panel.cpu.turbo === true
    readonly property real maxPerfShown: panel._has("maxPerfPct") ? panel._num(panel.tgt.maxPerfPct, 0)
        : panel._num(panel.cpu.maxPerfPct, panel._num(panel.cpu.maxPerfRange.max, 0))
    readonly property real pl1Shown: panel._cap("pl1W", panel.cpu.capCeilW.pl1, panel.cpu.pl1W)
    readonly property real pl2Shown: panel._cap("pl2W", panel.cpu.capCeilW.pl2, panel.cpu.pl2W)

    // The governor the hint talks about: the one under the pointer while it is on a tab, else the
    // selected one.
    readonly property int _govHovered: {
        if (!govHover.hovered || panel._govTabs.length === 0)
            return -1;
        const p = govHover.point.position;
        const n = panel._govTabs.length;
        const i = panel.govColumn ? Math.floor(p.y / (gov.height / n)) : Math.floor(p.x / (gov.width / n));
        return Math.max(0, Math.min(n - 1, i));
    }
    readonly property string governorRead: panel._govHovered >= 0 ? panel._govTabs[panel._govHovered].id : panel.governorShown

    // ---- what is offered (a kernel that lacks a knob hides its row) --------------------------------
    readonly property string _eppKey: panel.cpu.eppChoices.join("|")
    readonly property var _eppTabs: TM.eppTabs(panel._eppKey === "" ? [] : panel._eppKey.split("|"))
    readonly property bool eppOffered: panel.cpu.features.epp && panel._eppTabs.length > 0
    readonly property bool turboOffered: panel.cpu.features.turbo
    readonly property string _govKey: panel.cpu.governors.join("|")
    readonly property var _govNames: panel._govKey === "" ? [] : panel._govKey.split("|")
    readonly property var _govTabs: TM.govTabs(panel._govNames)
    readonly property bool govOffered: panel.cpu.features.governor && panel._govTabs.length > 0
    readonly property bool maxPerfOffered: panel.cpu.features.maxPerfPct
        && typeof panel.cpu.maxPerfRange.min === "number" && typeof panel.cpu.maxPerfRange.max === "number"
        && panel.cpu.maxPerfRange.max > panel.cpu.maxPerfRange.min
    readonly property bool capsOffered: panel.cpu.capsWritable
        && typeof panel.cpu.capFloorW === "number" && typeof panel.cpu.capCeilW.pl1 === "number"
        && typeof panel.cpu.capCeilW.pl2 === "number"
    readonly property bool behaviourOffered: panel.eppOffered || panel.turboOffered || panel.govOffered
    readonly property bool limitsOffered: panel.maxPerfOffered || panel.capsOffered
    // A long list does not fit one row of tabs: it becomes a column of them.
    readonly property bool govColumn: panel._govTabs.length > 3

    // ---- writing -------------------------------------------------------------------------------------
    // Returns whether the service took it; a refusal has already put its words in the caption.
    function write(patch) {
        return panel.vm ? panel.vm.setTuning(patch) === true : false;
    }

    // ---- fractions: presence and locking are the only things that fade --------------------------------
    property real _resetF: panel.cpu.tweaked ? 1 : 0
    Behavior on _resetF {
        NumberAnimation {
            duration: panel.look.fadeMs
            easing.type: Easing.OutCubic
        }
    }

    // ---- measuring -------------------------------------------------------------------------------------
    FontMetrics {
        id: bodyMetrics
        font.family: panel.look.fontFamily
        font.pixelSize: panel.look.bodySize
    }
    FontMetrics {
        id: figureMetrics
        font.family: panel.look.fontFamily
        font.pixelSize: panel.look.figureSize
    }
    readonly property real _lineH: Math.ceil(bodyMetrics.height) + 2
    // the air between a line of text and the control it names (CLAUDE.md "gap text to rail")
    readonly property real gapText: 6
    readonly property real _hintH: Math.ceil(figureMetrics.height)

    implicitWidth: panel.panelWidth
    implicitHeight: Math.ceil(column.implicitHeight + 2 * panel.look.padding)

    Column {
        id: column
        x: panel.look.padding
        y: panel.look.padding
        width: panel.panelWidth - 2 * panel.look.padding
        spacing: panel.look.gap

        // ---- the title and the way back to the profile ---------------------------------------------
        Item {
            id: header
            width: column.width
            height: 30

            Text {
                id: title
                anchors.verticalCenter: parent.verticalCenter
                text: "CPU tuning"
                color: Theme.textPrimary
                font.family: panel.look.fontFamily
                font.pixelSize: panel.look.titleSize
                font.bold: true
            }
            RaisedButton {
                id: reset
                objectName: "resetButton"
                x: header.width - width
                anchors.verticalCenter: parent.verticalCenter
                text: "Reset to profile"
                opacity: panel._resetF
                visible: opacity > 0.001
                enabled: panel.cpu.tweaked
                width: Math.ceil(implicitWidth)
                implicitHeight: 28
                fontFamily: panel.look.fontFamily
                fontPixelSize: panel.look.bodySize
                bold: false
                horizontalPadding: 12
                minWidth: 56
                radius: 8
                shadowWidth: 4
                surfaceColor: Theme.surface
                plateauColor: Theme.buttonPlateau
                plateauHoverColor: Theme.buttonPlateauHover
                bevelColor: Theme.buttonBevel
                shadowColor: Theme.buttonShadow
                accentColor: Theme.accent
                accentHoverColor: Theme.accentHover
                accentBevelColor: Theme.accentBevel
                shadowToAlpha: true
                onClicked: {
                    if (panel.vm)
                        panel.vm.resetTuning();
                }
            }
        }

        // ---- no helper: the one sentence that says why -----------------------------------------------
        PanelCard {
            id: absent
            objectName: "tuningAbsent"
            look: panel.look
            width: column.width
            visible: !panel.cpu.present
            height: visible ? implicitHeight : 0
            Text {
                width: parent.width
                visible: absent.visible
                text: panel.vm && panel.vm.caption && panel.vm.caption.cpu ? panel.vm.caption.cpu : "Power control is unavailable"
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Theme.textMuted
                font.family: panel.look.fontFamily
                font.pixelSize: panel.look.bodySize
            }
        }

        // ---- behaviour -----------------------------------------------------------------------------------
        PanelCard {
            id: behaviour
            objectName: "behaviourCard"
            look: panel.look
            width: column.width
            visible: panel.cpu.present && panel.behaviourOffered
            height: visible ? implicitHeight : 0

            // the energy preference
            Item {
                id: eppBlock
                objectName: "eppBlock"
                width: parent.width
                visible: panel.eppOffered
                height: visible ? panel._lineH + panel.gapText + epp.height : 0

                TipLabel {
                    id: eppLabel
                    look: panel.look
                    overlay: panel.overlay
                    text: "Energy preference"
                    tip: "Leans the CPU's own speed logic toward\n"
                        + "saving power or toward speed (EPP).\n"
                        + "Fixed while the governor is performance."
                    maxWidth: eppBlock.width
                    anchors.verticalCenter: eppHead.verticalCenter
                }
                Item {
                    id: eppHead
                    width: eppBlock.width
                    height: panel._lineH
                }
                // The reason the steps are dimmed, in the label's own row: it costs no height, and
                // it is there only while it is true. The name has the room first; the reason takes
                // what is left of the row (and elides in a wide face).
                Text {
                    id: eppReason
                    objectName: "eppReason"
                    x: eppBlock.width - width
                    width: Math.min(implicitWidth, Math.max(0, eppBlock.width - eppLabel.width - 8))
                    anchors.verticalCenter: eppHead.verticalCenter
                    text: "Fixed by the " + panel.governorShown + " governor"
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    opacity: epp.offF
                    visible: opacity > 0.001
                    color: Theme.textMuted
                    font.family: panel.look.fontFamily
                    font.pixelSize: panel.look.figureSize
                }
                PanelTabs {
                    id: epp
                    objectName: "eppTabs"
                    look: panel.look
                    y: panel._lineH + panel.gapText
                    width: eppBlock.width
                    height: 42
                    tabs: panel._eppTabs
                    trackRadiusOverride: 12
                    locked: panel.locked
                    onTabChanged: id => {
                        if (id !== panel.eppShown && !panel.write({ epp: id }))
                            epp.currentTab = panel.eppShown;
                    }
                }
                // TabSelector assigns its own `currentTab` on a click, which would sever a plain
                // binding: the shown value is bound with a Binding, which survives that.
                Binding {
                    target: epp
                    property: "currentTab"
                    value: panel.eppShown
                }
            }

            // turbo
            SwitchRow {
                id: turboRow
                objectName: "turboRow"
                look: panel.look
                overlay: panel.overlay
                width: parent.width
                visible: panel.turboOffered
                height: visible ? implicitHeight : 0
                title: "Turbo boost"
                tip: "Lets cores run above their base speed\nwhile power and temperature allow it."
                checked: panel.turboShown
                onToggled: c => panel.write({ turbo: c })
            }

            // the governor
            Item {
                id: govBlock
                objectName: "govBlock"
                width: parent.width
                visible: panel.govOffered
                height: visible ? panel._lineH + panel.gapText + gov.height + panel.gapText + panel._hintH : 0

                TipLabel {
                    look: panel.look
                    overlay: panel.overlay
                    text: "Governor"
                    tip: TM.governorTip(panel._govNames, panel.cpu.features.epp)
                    maxWidth: govBlock.width
                    anchors.verticalCenter: govHead.verticalCenter
                }
                Item {
                    id: govHead
                    width: govBlock.width
                    height: panel._lineH
                }
                PanelTabs {
                    id: gov
                    objectName: "govTabs"
                    look: panel.look
                    y: panel._lineH + panel.gapText
                    width: govBlock.width
                    height: panel.govColumn ? panel._govTabs.length * 28 + 6 : 30
                    orientation: panel.govColumn ? "vertical" : "horizontal"
                    tabs: panel._govTabs
                    fontPixelSize: panel.look.bodySize
                    trackRadiusOverride: panel.govColumn ? 12 : 10
                    onTabChanged: id => {
                        if (id !== panel.governorShown && !panel.write({ governor: id }))
                            gov.currentTab = panel.governorShown;
                    }
                    // Which tab the pointer is on, by arithmetic from the track's own geometry (a
                    // handler on the selector itself is an ancestor of its tabs' areas: it takes
                    // nobody's hover or cursor).
                    HoverHandler {
                        id: govHover
                    }
                }
                Binding {
                    target: gov
                    property: "currentTab"
                    value: panel.governorShown
                }
                // ONE line of what the selected governor does here: instant text, a reserved slot.
                Text {
                    id: govHint
                    objectName: "govHint"
                    y: gov.y + gov.height + panel.gapText
                    width: govBlock.width
                    height: panel._hintH
                    text: TM.governorHint(panel.governorRead, panel._govNames, panel.cpu.features.epp)
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: Theme.textMuted
                    font.family: panel.look.fontFamily
                    font.pixelSize: panel.look.figureSize
                }
            }
        }

        // ---- limits ----------------------------------------------------------------------------------------
        PanelCard {
            id: limits
            objectName: "limitsCard"
            look: panel.look
            width: column.width
            visible: panel.cpu.present && panel.limitsOffered
            height: visible ? implicitHeight : 0

            SettledSlider {
                id: maxPerf
                objectName: "sliderMaxPerf"
                look: panel.look
                overlay: panel.overlay
                width: parent.width
                visible: panel.maxPerfOffered
                height: visible ? implicitHeight : 0
                title: "Maximum performance"
                tip: "The highest speed the CPU may reach, as a\n"
                    + "share of its maximum (intel_pstate's\n"
                    + "max_perf_pct). A profile change or Reset\n"
                    + "puts it back to the profile's value (the\n"
                    + "kernel's maximum unless the profile sets one)."
                unit: "%"
                from: panel.maxPerfOffered ? panel.cpu.maxPerfRange.min : 0
                to: panel.maxPerfOffered ? panel.cpu.maxPerfRange.max : 100
                hostValue: panel.maxPerfShown
                onCommitted: v => panel.write({ maxPerfPct: v })
            }
            SettledSlider {
                id: pl1
                objectName: "sliderPl1"
                look: panel.look
                overlay: panel.overlay
                width: parent.width
                visible: panel.capsOffered
                height: visible ? implicitHeight : 0
                title: "Sustained power (PL1)"
                tip: "The power the package may draw for as long\n"
                    + "as it likes. Lower than the firmware's own\n"
                    + "value only, and never above PL2."
                unit: "W"
                from: panel.capsOffered ? panel.cpu.capFloorW : 0
                to: panel.capsOffered ? panel.cpu.capCeilW.pl1 : 100
                hostValue: panel.pl1Shown
                highWall: panel.pl2Shown
                onCommitted: v => panel.write({ pl1W: v })
            }
            SettledSlider {
                id: pl2
                objectName: "sliderPl2"
                look: panel.look
                overlay: panel.overlay
                width: parent.width
                visible: panel.capsOffered
                height: visible ? implicitHeight : 0
                title: "Burst power (PL2)"
                tip: "The power it may draw in short bursts.\n"
                    + "Lower than the firmware's own value only,\n"
                    + "and never below PL1."
                unit: "W"
                from: panel.capsOffered ? panel.cpu.capFloorW : 0
                to: panel.capsOffered ? panel.cpu.capCeilW.pl2 : 100
                hostValue: panel.pl2Shown
                lowWall: panel.pl1Shown
                onCommitted: v => panel.write({ pl2W: v })
            }
        }
    }
}
