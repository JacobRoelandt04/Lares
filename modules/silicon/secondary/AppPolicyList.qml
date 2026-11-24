pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// AppPolicyList.qml -- the Smart mode's app list: a carved box of the apps cardwire has been asked
// about (`gpu.policies`: the ones the person allowed and the ones it blocked at least once), each
// with its state and one switch -- allowed (on) or blocked (off). A BLOCKED app also carries "Never
// ask again", the same words as the blocked-app notice's button: it stops that notice for that app
// (`vm.ignoreApp`), and the row says "Ignored" once it has.
//
// THE ROWS ARE A MODEL OF IDS, NOT THE FACTS' ARRAY. `vm.gpu` is a new object on every tick, and so
// is its `policies` array: a Repeater over it would regenerate every delegate every second and the
// box would jump back to its top. The ListModel holds the app ids and is edited only when the id
// sequence really changes; each row reads its own record through one lookup built from the current
// array, so a name or a state that changes is a binding that re-evaluates and nothing is rebuilt.
//
// A ROW STAYS WHILE THE PANEL IS OPEN. The facts list the apps the person allowed and the ones
// cardwire blocked at least once; an app that was allowed and is switched off here is neither any
// more, and the data layer stops listing it. Its row stays (reading Blocked, with the name it had), so
// the choice can be undone from where it was made; the next time the panel opens it is gone. A new
// app is inserted where the facts put it.
//
// The box shows at least `minRows` and at most `maxRows` rows of its own height (it never resizes
// as apps come and go within that); beyond `maxRows` it scrolls, with the shell's ScrollDressing
// (one notch = 120 px, the fades at its ends).
// =============================================================================
Item {
    id: list

    property var vm: null
    property SecondaryStyle look: null
    property Item overlay: null
    property int minRows: 3
    property int maxRows: 6
    readonly property real rowHeight: 32
    // the room between the box's edge and its rows: the shell's list-row inset
    readonly property real inset: 6

    readonly property var policies: list.vm && list.vm.gpu && list.vm.gpu.policies ? list.vm.gpu.policies : []
    readonly property int count: ids.count
    readonly property alias flick: flick
    readonly property alias rows: rowsRepeater
    readonly property var _byId: {
        const m = {};
        for (const p of list.policies)
            m[p.id] = p;
        return m;
    }

    readonly property string _family: list.look ? list.look.fontFamily : "Inter"
    readonly property real _figureSize: list.look ? list.look.figureSize : 11

    implicitHeight: Math.round(Math.max(list.minRows, Math.min(list.maxRows, ids.count)) * list.rowHeight + 2 * list.inset)

    // ---- the ids, edited only on a real change -------------------------------------------------------
    ListModel {
        id: ids
    }
    property string _idKey: ""
    property bool _keyed: false
    // the name each app had when the facts last listed it (mutated in place: nothing reads it until
    // the app drops out of the facts, and that is a change of `_byId`)
    readonly property var _names: ({})
    function _sync() {
        const ps = list.policies;
        const want = ps.map(p => p.id);
        for (const p of ps)
            list._names[p.id] = p.name;
        const key = want.join("\n");
        if (list._keyed && key === list._idKey)
            return;
        list._keyed = true;
        list._idKey = key;
        let after = -1;
        for (let j = 0; j < want.length; j++) {
            let at = -1;
            for (let k = 0; k < ids.count; k++) {
                if (ids.get(k).appId === want[j]) {
                    at = k;
                    break;
                }
            }
            if (at < 0) {
                at = after + 1;
                ids.insert(at, { appId: want[j] });
            }
            after = at;
        }
    }
    onPoliciesChanged: list._sync()
    Component.onCompleted: list._sync()

    function setAllowed(id, allowed) {
        if (list.vm)
            list.vm.setAppPolicy(id, allowed);
    }
    function ignore(id) {
        if (!list.vm)
            return;
        list.vm.ignoreApp(id);
    }

    // ---- measuring the slots ----------------------------------------------------------------------------
    FontMetrics {
        id: fm
        font.family: list._family
        font.pixelSize: list._figureSize
    }
    function _adv(s) {
        const f = fm.font;
        void f.family;
        void f.pixelSize;
        return Math.ceil(fm.advanceWidth(s));
    }
    readonly property real stateSlot: Math.max(list._adv("Allowed"), list._adv("Blocked"))
    readonly property real ignoreSlot: Math.max(list._adv("Never ask again"), list._adv("Ignored"))

    // ---- the box -------------------------------------------------------------------------------------------
    ShadowBox {
        anchors.fill: parent
        baseRadius: list.look ? list.look.radius : 14
        surfaceColor: Theme.surface
        backgroundColor: Theme.listBox
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: list.look ? list.look.cardBevelWidth : 1
        shadowWidth: list.look ? list.look.cardShadowWidth : 3
        shadowFalloff: list.look ? list.look.cardShadowFalloff : 1
    }

    Flickable {
        id: flick
        objectName: "appList"
        x: list.inset
        y: list.inset
        width: list.width - 2 * list.inset
        height: list.height - 2 * list.inset
        clip: true
        interactive: false
        contentWidth: width
        contentHeight: rowsColumn.implicitHeight

        Column {
            id: rowsColumn
            width: flick.width

            Repeater {
                id: rowsRepeater
                model: ids

                delegate: Item {
                    id: row

                    required property int index
                    required property string appId

                    readonly property var rec: list._byId[row.appId] || null
                    readonly property bool allowed: row.rec !== null && row.rec.policy === 1
                    readonly property string appName: row.rec !== null && row.rec.name ? row.rec.name : (list._names[row.appId] || row.appId)
                    readonly property bool ignored: row.rec !== null && row.rec.ignored === true     // the data layer's fact
                    readonly property bool canIgnore: !row.allowed

                    width: rowsColumn.width
                    height: list.rowHeight

                    // a wash under the row the pointer is on
                    HoverHandler {
                        id: hover
                    }
                    property real hoverF: hover.hovered ? 1 : 0
                    Behavior on hoverF {
                        NumberAnimation {
                            duration: 120
                        }
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: 8
                        color: Theme.panelSunk
                        opacity: row.hoverF
                        visible: opacity > 0.001
                    }

                    GrooveToggle {
                        id: toggle
                        objectName: "appToggle"
                        // the ball, not the groove, lies on the row's margin (see SwitchRow)
                        x: row.width - width - 6 - (ballSize - grooveThickness) / 2
                        anchors.verticalCenter: parent.verticalCenter
                        checked: row.allowed
                        onToggled: c => list.setAllowed(row.appId, c)
                    }
                    Text {
                        id: stateText
                        x: toggle.x - 10 - list.stateSlot
                        width: list.stateSlot
                        anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignRight
                        text: row.allowed ? "Allowed" : "Blocked"
                        color: Theme.textMuted
                        font.family: list._family
                        font.pixelSize: list._figureSize
                    }
                    // "Never ask again": on a blocked row, and only while the pointer is on the row (an
                    // app's second action is not a thing to repeat down a whole list). It is the one
                    // text here that is a link: the hand cursor and a short colour fade say so.
                    // "Ignored" is a state, and stays.
                    Text {
                        id: ignoreText
                        objectName: "appIgnore"
                        x: stateText.x - 10 - list.ignoreSlot
                        width: list.ignoreSlot
                        anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignRight
                        // opacity, not `visible`, is what hides it: the area under it stays live, so the
                        // click that follows the hover lands even in the first frames of the fade in
                        visible: row.canIgnore
                        opacity: row.ignored ? 1 : row.hoverF
                        text: row.ignored ? "Ignored" : "Never ask again"
                        color: row.ignored ? Theme.textFaint : Mix.c(Theme.textMuted, Theme.accent, ignoreArea.hoverF)
                        font.family: list._family
                        font.pixelSize: list._figureSize
                        MouseArea {
                            id: ignoreArea
                            property real hoverF: containsMouse && !row.ignored ? 1 : 0
                            Behavior on hoverF {
                                NumberAnimation {
                                    duration: 120
                                }
                            }
                            anchors.fill: parent
                            anchors.margins: -4
                            // not tied to the fade: the click that follows a hover must land
                            enabled: !row.ignored && row.canIgnore
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: list.ignore(row.appId)
                        }
                    }
                    TipLabel {
                        objectName: "appName"
                        // the card's content column: the box's inset (6) and 6 more = 12 from its edge
                        x: 6
                        anchors.verticalCenter: parent.verticalCenter
                        look: list.look
                        overlay: list.overlay
                        text: row.appName
                        tip: row.appId !== row.appName ? row.appId : ""
                        maxWidth: (row.canIgnore ? ignoreText.x : stateText.x) - 10 - x
                    }
                }
            }
        }
    }
    ScrollDressing {
        anchors.fill: flick
        flick: flick
        ground: Theme.listBox
        fadeHeight: 18
    }

    // Nothing yet: a blank box keeps its height and says why.
    Text {
        objectName: "appEmpty"
        anchors.centerIn: parent
        visible: ids.count === 0
        width: parent.width - 2 * list.inset - 16
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: "No apps yet. They appear here once Smart mode has blocked one."
        textFormat: Text.PlainText
        color: Theme.textFaint
        font.family: list._family
        font.pixelSize: list._figureSize
    }
}
