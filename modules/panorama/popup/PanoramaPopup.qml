pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../secondary"
import ".."

// =============================================================================
// PanoramaPopup.qml -- the displays' drop-in (docs/contracts/panorama.md section 5; decisions 7, 14, 15, 16, 32).
//
//   service        PanoramaService (or PanoramaMock): displays, plan, staged, dirty, setups, diagnostics, engineState ...
//   fontFamily     "Inter" by default, the mockup dresses it
//   style          PanoramaStyle
//   selected       the display whose side popup is open ("" none). The owner may set it at build time (Arrange... on the never-seen toast);
//                  the popup assigns it itself afterwards (a click on a tile, on the card's floor, Escape)
//   closeRequested()   Apply went out (service.apply() returned true): the owner closes the popup so the keep toast is in plain view
//
// Top to bottom: the title (the setup in force, "· changed" while an edit is staged), the canvas card, the hints, and the apply bar glued to the
// BOX's foot. SIZE: nothing here animates a height -- `implicitHeight` steps to its final value in one turn (a hint arriving, the apply bar
// coming with an edit, a parked chip) and the engine eases the box; the parts are laid out at the size they asked for, from the top, and the
// box reveals them. A fraction here is a presence (opacity) only. Not set up (`engineState` not "active"): the canvas is read-only, no apply bar, a note says `lares panorama-import`.
// The secondary (DisplaySettings, the aerial pattern) belongs to `selected`.
// =============================================================================
Item {
    id: root

    property var service: null
    property string fontFamily: "Inter"
    property PanoramaStyle style: PanoramaStyle {}
    property string selected: ""
    // A CAST CHANGES ITS DISPLAY'S NAME when it starts or stops mirroring (its own output <-> the stand-in), with a moment of no display
    // at all while its output is made: a detail open on it follows the display to its new name
    property string _castName: root.service ? (root.service.castDisplayName || "") : ""
    on_CastNameChanged: {
        if (root._castName === "")
            return;
        if (root._castWas !== "" && root.selected === root._castWas)
            root.selected = root._castName;
        root._castWas = root._castName;
    }
    property string _castWas: ""
    property bool parked: false
    property bool prewarm: false
    // HOSTED UNDER A TAB ROW (PanoramaTabs): the title row is the host's tab selector, so it is not drawn and the canvas starts at the popup's
    // padding; the setup in force becomes a one-line caption under the canvas.
    property bool headerless: false

    signal closeRequested()

    readonly property bool active: !!root.service && root.service.engineState === "active"
    readonly property bool dirty: root.active && !!root.service.dirty

    // ---- the hints ---------------------------------------------------------------------------------------------------------------------------
    readonly property var hints: {
        const s = root.service, res = [];
        if (!s)
            return res;
        if (s.engineState !== "active") {
            const why = String(s.engineWhy || "Panorama is not set up yet");
            const m = /`([^`]+)`/.exec(why);
            res.push({ id: "engine", severity: "info", title: "Read only", body: m ? why.replace(m[0], "").trim() : why,
                       command: m ? m[1] : "", action: "", output: "" });
        }
        for (const d of (s.diagnostics || []))
            res.push({ id: d.id, severity: d.severity, title: d.title, body: d.body, command: d.command || "", action: d.action || "", output: d.output || "" });
        return res;
    }

    // ---- size --------------------------------------------------------------------------------------------------------------------------------
    readonly property real _p: root.style.padding
    readonly property real _g: root.style.gap
    readonly property real _titleH: 22
    readonly property real _topH: root.headerless ? 0 : root._titleH + root._g
    readonly property string _caption: (root.service && root.service.setupName !== "" ? root.service.setupName : "") + (root.dirty ? (root.service && root.service.setupName !== "" ? " · " : "") + "changed" : "")
    readonly property real _captionGap: 8
    readonly property real _captionH: root.headerless && root._caption !== "" ? 14 : 0
    readonly property real _captionBlock: root._captionH > 0 ? root._captionGap + root._captionH : 0
    readonly property real _hintsH: root.hints.length > 0 ? Math.ceil(hintRows.implicitHeight) : 0
    readonly property real _applyH: root.active && root.dirty ? Math.ceil(applyBar.implicitHeight) : 0

    implicitWidth: root.style.popupWidth
    implicitHeight: Math.ceil(root._p + root._topH + canvas.implicitHeight + root._captionBlock
                              + (root._hintsH > 0 ? root._g + root._hintsH : 0)
                              + (root._applyH > 0 ? root._g + root._applyH : 0)
                              + root._p)

    // ---- the engine's contract -----------------------------------------------------------------------------------------------------------
    readonly property string keyboardFocusRequest: "none"

    // Escape: an open menu of the detail goes first (DisplaySettings' own handleEscape); else false, and the engine's rule closes the
    // popup with its detail, or puts the detail away first (`stepBack`, under shell.jsonc `"escape": "detail"`)
    function handleEscape(): bool {
        // a cast chip in its confirm step is left first (casting); then the shell's one Escape rule for a detail
        if (canvas.cancelCast())
            return true;
        return root.secondaryOpen && !!root._liveSettings && root._liveSettings.handleEscape() === true;
    }
    function stepBack(): bool {
        if (root.selected === "")
            return false;
        root.selected = "";
        return true;
    }
    // the detail's content on show (the engine builds one per open; the newest is the one Escape reaches)
    property DisplaySettings _liveSettings: null

    // ---- the secondary (the aerial pattern: the aim first, the key last) -------------------------------------------------------------
    property var secondaryKey: null
    property bool secondaryOpen: false
    property point secondaryAnchor: Qt.point(0, 0)
    property real secondaryAnchorAt: 0.5
    property real secondaryWidthFrom: 0.5
    // THE SIDE THE SCREEN HAS ROOM FOR (aerial's rule): the left of the popup by default -- the glyph stands in the right island, near the
    // screen's right edge, where "end" had no room and the settings never showed (the mockup's stage had room on both sides) -- the
    // right only when the left is too narrow for the panel and the right is wider. Decided when the panel opens; it does not hop.
    property string _sideNow: "start"
    readonly property string secondarySide: root._sideNow
    function _fitSide(): string {
        const win = root.Window.window;
        if (!win || !(win.width > 0) || !(root.width > 0))
            return "start";
        const a = root.mapToItem(null, 0, 0), b = root.mapToItem(null, root.width, 0);
        const left = a.x, right = win.width - b.x;
        const need = root.style.sideWidth * (b.x - a.x) / root.width;
        return left >= need || left >= right ? "start" : "end";
    }
    readonly property bool secondaryOverhang: false
    readonly property real secondaryInset: 0

    readonly property bool _selectedHere: root.selected !== "" && root.active && !!root.service
                                          && root.service.displays.some(d => d.name === root.selected)
    function _publishSecondary(): void {
        if (!root._selectedHere) {
            root.secondaryOpen = false;
            root.secondaryKey = null;
            return;
        }
        const r = root._selectedRest;
        if (r.height > 0)
            root.secondaryAnchor = Qt.point(root.width, Math.round(canvas.y + r.y + r.height / 2));
        if (!root.secondaryOpen)
            root._sideNow = root._fitSide();
        root.secondaryAnchorAt = 0.5;
        root.secondaryWidthFrom = 0.5;
        root.secondaryKey = root.selected;
        root.secondaryOpen = true;
    }
    // the anchor follows the tile's REST geometry (where the facts put it), so a drop, a rescale and a rotate re-aim the side popup too
    readonly property rect _selectedRest: root._selectedHere ? canvas.restRect(root.selected) : Qt.rect(0, 0, 0, 0)
    on_SelectedRestChanged: root._publishSecondary()
    onSelectedChanged: root._publishSecondary()
    on_SelectedHereChanged: root._publishSecondary()
    Component.onCompleted: root._publishSecondary()

    property Component secondaryComponent: Component {
        DisplaySettings {
            id: settings
            service: root.service
            fontFamily: root.fontFamily
            style: root.style
            onDismissed: root.selected = ""
            Component.onCompleted: root._liveSettings = settings
            Component.onDestruction: {
                if (root._liveSettings === settings)
                    root._liveSettings = null;
            }
        }
    }

    // ---- the parts -----------------------------------------------------------------------------------------------------------------------
    Text {
        x: root._p
        y: root._p
        width: root.width - 2 * root._p
        height: root._titleH
        visible: !root.headerless
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: (root.service && root.service.setupName !== "" ? root.service.setupName : "Displays") + (root.dirty ? " · changed" : "")
        color: Theme.textPrimary
        font.family: root.fontFamily
        font.pixelSize: root.style.titleSize
        font.bold: true
    }

    ArrangeCanvas {
        id: canvas
        objectName: "canvas"
        x: root._p
        y: root._p + root._topH
        width: root.width - 2 * root._p
        service: root.service
        style: root.style
        fontFamily: root.fontFamily
        selected: root.selected
        enabled: root.active
        opacity: root.active ? 1 : 0.6
        floatRunning: !root.parked && !root.prewarm
        onSelectRequested: name => root.selected = name
    }

    Text {
        id: captionText
        x: root._p
        y: canvas.y + canvas.implicitHeight + root._captionGap
        width: root.width - 2 * root._p
        height: root._captionH
        visible: root._captionH > 0
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: root._caption
        color: Theme.textMuted
        font.family: root.fontFamily
        font.pixelSize: root.style.figureSize
    }

    HintRows {
        id: hintRows
        x: root._p
        y: canvas.y + canvas.implicitHeight + root._captionBlock + root._g
        width: root.width - 2 * root._p
        visible: root._hintsH > 0
        hints: root.hints
        style: root.style
        fontFamily: root.fontFamily
        onActionRequested: (action, output) => {
            if (action === "enable" && root.service)
                root.service.enableOutput(output);
        }
    }

    ApplyBar {
        id: applyBar
        objectName: "applyBar"
        x: root._p
        y: root.height - root._p - applyBar.implicitHeight
        width: root.width - 2 * root._p
        dirty: root.active && root.dirty
        style: root.style
        fontFamily: root.fontFamily
        onDiscardClicked: root.service.discard()
        onApplyClicked: {
            if (root.service.apply())
                root.closeRequested();
        }
    }
}
