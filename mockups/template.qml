pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import "modules/common/components"
import "modules/common/mockup"

// =============================================================================
// mockups/template.qml -- copy this to start a module mockup.
//
//   cp mockups/template.qml mockups/<module>.qml
//   then: rename moduleId, drop your content in, list your values.
//
// The framework (modules/common/mockup/, contract in
// docs/contracts/mockup_framework.md) owns the window: the stage on the left
// that follows the content's implicit size and magnifies it, and the tabbed
// control panel on the right with the * marks, Reset, "Save to mockup" and
// the profiles. This file provides four things and nothing else:
//
//   content   the drop-in item, sized by its own implicitWidth/Height
//   lists     one array per component, each entry a control on the panel
//   tabDefs   which lists (and which of your own pages) go on which tab
//   pages     your module's own controls -- what drives the content
//
// Run it:  quickshell -p mockups/<module>.qml
// Grab it: tools/dev/mockup_grab.sh mockups/<module>.qml --list   (then a tab)
// Test it: tools/dev/mockup_panel_test.sh mockups/<module>.qml
// =============================================================================
MockupWindow {
    id: win

    // Names the profile directory (~/.config/quickshell/mockup_profiles/<id>/)
    // and, by default, the file "Save to mockup" writes back into.
    moduleId: "template"
    // Say where this file is (mockupFile: RepoRoot.dir + "/mockups/<name>.qml") whenever it is not mockups/<moduleId>.qml,
    // or Save to mockup has nothing to write into.
    title: "Template mockup"
    content: demo

    // Where a list's values are written. One target for all of them here;
    // a module with an inner component tunes that component directly:
    //   targets: ({ railParams: demo.rail })
    target: demo

    // Every key is the name of a `readonly property var <key>` below --
    // tools/dev/mockup_save_defaults.py finds the array in this file by that name.
    lists: ({
            boxParams: win.boxParams,
            boxColors: win.boxColors
        })

    // The tabs follow mockup_framework.md, "The panel standard": Run first; then one tab per component, the popup's
    // frame first and its parts in reading order; Colours (a palette several components share); the bar side
    // (Button, Bar); Config / Data; Host; the framework appends Profiles.
    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Box",
            lists: ["boxParams", "boxColors"]
        }
        // A tab past about 20 rows splits by what its groups do, its colours last:
        //   { name: "Rail", subs: [
        //       { name: "Swirl", lists: ["railParams"], groups: ["Glow", "Chase"] },
        //       { name: "Colours", lists: ["railColors"] } ] }
    ]

    // =====================================================================
    //  THE DROP-IN CONTENT
    //
    // Exactly what will go into thePopup: self-contained, sized through
    // implicitWidth / implicitHeight (never width/height), assuming nothing
    // about its host. The stage gives it a surface and its own size, the
    // way thePopup will.
    // =====================================================================
    Item {
        id: demo

        // The host reads these; the stage animates to them, as thePopup does.
        implicitWidth: 420
        implicitHeight: 160 + (demo.expanded ? 90 : 0)
        Behavior on implicitHeight {
            NumberAnimation {
                duration: 260
                easing.type: Easing.OutCubic
            }
        }

        // Tunables the panel writes to. Every one of them is a property on
        // the content, never a property of the mockup: the panel is only
        // ever a second way to set what the module already exposes.
        property real boxRadius: 14
        property real boxPadding: 16
        property color boxColor: "#E6E9F0"
        property bool expanded: false

        ShadowBox {
            anchors.fill: parent
            anchors.margins: demo.boxPadding
            baseRadius: demo.boxRadius
            backgroundColor: demo.boxColor
            bevelWidth: 1
            shadowWidth: 3

            Text {
                anchors.centerIn: parent
                text: demo.expanded ? "expanded" : "click me"
                color: "#5D5D5F"
                font.family: "Audiowide"
                font.pixelSize: 16
                font.bold: true
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: demo.expanded = !demo.expanded
            }
        }
    }

    // =====================================================================
    //  THE MODULE'S OWN PANEL PAGES
    //
    // Whatever drives the content: replay, a synthetic run, per-state jumps,
    // readouts. Everything that is not a plain number or colour lives here.
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            // The Run page's groups, in this order (mockup_framework.md, "The panel standard"): the data, one-click
            // states, the calls that drive it, what may reach the desktop (opt-in), Stage, and the State readout last.
            TipGroup {
                title: "Scenarios"
                blurb: "One click puts the content in a state."
            }
            TipRow {
                tip: "What the content is showing. A module with states drives them from here -- a replay of a captured log, a synthetic run, a jump straight to one state."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Collapse"
                    onClicked: demo.expanded = false
                }
                Button {
                    text: "Expand"
                    onClicked: demo.expanded = true
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the content believes right now."
            }

            Label {
                Layout.fillWidth: true
                text: "expanded: " + demo.expanded + "   size: " + demo.implicitWidth.toFixed(0) + " x " + demo.implicitHeight.toFixed(0)
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 14
            }
        }
    ]

    // =====================================================================
    //  VALUES
    //
    // One array per component. `val` is this file's default for that
    // property: pushed into the target on load, restored by Reset, compared
    // against for the * marks, and rewritten in place by "Save to mockup".
    //
    // EVERY entry carries a `tip` -- what it does and why the default is
    // what it is -- and a `group`; the first entry of a group may carry a
    // `blurb` describing the group. A six-word label cannot say what a value
    // means, and an unexplained slider is one nobody dares move.
    //
    // The KIND of a row is its own `val`, so an entry is always
    // { label, prop, group, tip, val }: a number with from/to/step is a
    // slider, `val: true` or `val: false` is a switch, and a list whose
    // FIRST entry's val is a "#RRGGBB" string is a colour list. A component's
    // switches go in its param list beside its numbers -- the panel is split
    // by component, never by kind.
    // =====================================================================
    readonly property var boxParams: [
        {
            label: "radius",
            prop: "boxRadius",
            group: "Box",
            blurb: "The carved box the content is built from.",
            tip: "Corner radius of the box. 14 is the shell's container radius, so a box that meets a container's corner shares its curve; compact views use 10.",
            val: 14,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "padding",
            prop: "boxPadding",
            group: "Box",
            tip: "Space between the content's edge and the box, px. A real popup takes the shell's 12 (the same on every side, so the space above equals the space below); the template's 16 only shows the box off its edge.",
            val: 16,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "expanded",
            prop: "expanded",
            group: "Box",
            tip: "Whether the content is showing its second half, the state the box's click toggles. A bool entry is a switch: no from/to/step, and `val` is the state the module ships in — collapsed, because a popup opens at its smallest and grows.",
            val: false
        }
    ]

    readonly property var boxColors: [
        {
            label: "box fill",
            prop: "boxColor",
            group: "Box colours",
            blurb: "Hex, as the palette in CLAUDE.md writes them.",
            tip: "Fill of the carved box. #E6E9F0 is the list-box fill: a shade under the surface, so the box reads as cut into it.",
            val: "#E6E9F0"
        }
    ]
}
