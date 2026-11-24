pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/scroll"
import "../../common/theme"
import "../../presets"
import ".."

// =============================================================================
// PanoramaTabs.qml -- the machine popup: ONE popup, TWO TABS behind the one bar button (the user, 2026-11-21): "Displays" (PanoramaPopup,
// the arrangement) and "Presets" (PresetsPopup, the saved desktops). Both are the drop-ins as they are; this file is the clock popup's
// pattern (modules/clock/ClockPopupContent.qml) over them.
//
//   service        PanoramaService (or PanoramaMock)                 presets      PresetsService (null: the Presets tab is empty)
//   appLookup      AppLookup (the presets' icons)                   style / presetsStyle   the two drop-ins' numbers
//   currentTab     "displays" | "presets": the OWNER holds it (PanoramaBarOwner decides it at the open, by situation) and binds it here
//   restTab        the tab the NEXT open will show (the owner's rule): `restImplicitWidth/Height` aim the open at its size
//   selected       the display whose detail (the Displays tab's secondary) is open; "" none
//   eager          build both tabs at once (a mockup that tunes both)
//   closeRequested()   Apply went out, or a preset load began: the owner closes the popup
//   presetLoadStarted() a load was asked on the Presets tab (before closeRequested): the owner deals the glyph's flourish
//
// SIZE: each tab keeps ITS OWN size (Displays 460 wide; Presets 596, and 304 while no preset is saved) and the popup is the header (the tab row) plus the current tab's own, so a
// switch is ONE step of `implicitWidth` / `implicitHeight` and the engine eases the box. Nothing here animates a size; the tab on show is
// laid out at the size it asked for, centred by hand on whole pixels in whatever box it gets, and the box reveals it -- a tab swap is
// instant (visible), never two layouts crossfaded through each other. A tab is BUILT WHEN FIRST SHOWN and kept (a latched Loader).
//
// THE HEADER: the tab selector stands in the title's row of the Displays popup (PanoramaPopup `headerless`: no title; the setup in force
// is its caption under the canvas). The content below starts with its own padding, which is the gap under the tab row, so the two tabs'
// tops coincide.
//
// THE CONTRACT, PER ACTIVE TAB: keyboardFocusRequest, handleEscape(), the secondary (Displays only: closed on the Presets tab and when the
// tab changes), parked / prewarm / recycle(), and the swipe hold (docs/contracts/gestures.md section 4): a two-finger sideways swipe over the
// whole popup switches the tab; a vertical one is left to whatever scrolls underneath (the presets' grid).
// =============================================================================
Item {
    id: root

    property var service: null
    property var presets: null
    property var appLookup: null
    property string fontFamily: "Inter"
    property PanoramaStyle style: PanoramaStyle {}
    property PresetsStyle presetsStyle: PresetsStyle {}
    property real renderScale: 1
    // the owner's word that this popup is on screen (the presets' clock stops without it)
    property bool motionRunning: true

    property string currentTab: "displays"
    property string restTab: "displays"
    property string selected: ""
    property bool eager: false
    // the engine's: built ahead of a click and held (GooeyEngine.prebuild); a prewarm draws it once
    property bool parked: false
    property bool prewarm: false

    signal closeRequested()
    signal presetLoadStarted()

    readonly property alias tabSelector: tabSel
    readonly property var displaysTab: panoLoader.item
    readonly property var presetsTab: presLoader.item

    // ---- size ---------------------------------------------------------------------------------------------------------------------------------
    property real padding: 12
    property real tabWidth: 240
    property real tabHeight: 34
    readonly property real _headH: root.padding + root.tabHeight
    readonly property real _wD: root.displaysTab ? Math.ceil(root.displaysTab.implicitWidth) : root.style.popupWidth
    readonly property real _wP: root.presetsTab ? Math.ceil(root.presetsTab.implicitWidth)
        : root.presetsStyle.widthFor((root.presets ? root.presets.presets.length : 0) + 1)
    // 0 until the tab is built (a tab not built yet is not known)
    readonly property real _hD: root.displaysTab ? Math.ceil(root.displaysTab.implicitHeight) : 0
    readonly property real _hP: root.presetsTab ? Math.ceil(root.presetsTab.implicitHeight) : 0

    implicitWidth: root.currentTab === "presets" ? root._wP : root._wD
    // A tab not built yet has no height: the height of the one before stands for the instant until its Loader has built it, so a first show is
    // ONE step, not a step to the header and a second to the tab. (`_memo` is mutated in place: it is no property, so no binding reads it.)
    readonly property var _memo: ({ h: 0 })
    implicitHeight: {
        const h = root.currentTab === "presets" ? root._hP : root._hD;
        if (h > 0)
            root._memo.h = root._headH + h;
        return root._memo.h > 0 ? root._memo.h : root._headH;
    }
    // THE SIZE THE NEXT OPEN ASKS FOR (GooeyEngine reads these when a content has them): the owner reopens on the tab its situation gives,
    // not on the one this content was closed on. 0 while that tab is not built: the engine then takes `implicit*`.
    readonly property real restImplicitWidth: root.restTab === "presets" ? root._wP : root._wD
    readonly property real restImplicitHeight: {
        const h = root.restTab === "presets" ? root._hP : root._hD;
        return h > 0 ? root._headH + h : 0;
    }

    // ---- the header -----------------------------------------------------------------------------------------------------------------------------
    TabSelector {
        id: tabSel
        x: Math.round((root.width - width) / 2)
        y: root.padding
        width: root.tabWidth
        height: root.tabHeight
        tabs: [{ id: "displays", label: "Displays" }, { id: "presets", label: "Presets" }]
        onTabChanged: id => {
            root.currentTab = id;
        }
        // the popup-wide area below feeds it: a swipe is aimed at the popup, not at this small target
        swipeSelfHandled: false
    }
    // the selector assigns its own currentTab when a click or a swipe steps it, which kills a plain binding: a Binding re-applies
    Binding {
        target: tabSel
        property: "currentTab"
        value: root.currentTab
    }

    // ---- the tabs ---------------------------------------------------------------------------------------------------------------------------------
    property bool _panoShown: false
    property bool _presShown: false
    Loader {
        id: panoLoader
        active: root.eager || root.currentTab === "displays" || root._panoShown
        visible: root.currentTab === "displays"
        x: Math.round((root.width - root._wD) / 2)
        y: root._headH
        onVisibleChanged: if (visible) root._panoShown = true
        sourceComponent: Component {
            PanoramaPopup {
                id: pp
                service: root.service
                fontFamily: root.fontFamily
                style: root.style
                headerless: true
                parked: root.parked
                prewarm: root.prewarm
                selected: root.selected
                // the popup assigns `selected` itself (a click on a tile, Escape): the plain binding above dies there, this one does not
                Binding {
                    target: pp
                    property: "selected"
                    value: root.selected
                    restoreMode: Binding.RestoreNone
                }
                onSelectedChanged: {
                    if (pp.selected !== root.selected)
                        root.selected = pp.selected;
                }
                onCloseRequested: root.closeRequested()
            }
        }
    }
    Loader {
        id: presLoader
        active: root.eager || root.currentTab === "presets" || root._presShown
        visible: root.currentTab === "presets"
        x: Math.round((root.width - root._wP) / 2)
        y: root._headH
        onVisibleChanged: if (visible) root._presShown = true
        sourceComponent: Component {
            PresetsPopup {
                service: root.presets
                appLookup: root.appLookup
                style: root.presetsStyle
                fontFamily: root.fontFamily
                renderScale: root.renderScale
                motionRunning: root.motionRunning && root.currentTab === "presets"
                parked: root.parked
                // the tab is laid out at its own size; its first and last columns follow the box while their number changes
                boxWidth: root.width
                // the only thing that closes it is a load: the owner deals the glyph, then closes
                onCloseRequested: {
                    root.presetLoadStarted();
                    root.closeRequested();
                }
            }
        }
    }

    // a tab left is left whole: the detail is not for the next tab. (Not at the build: a first value is no change.)
    property bool _born: false
    Component.onCompleted: root._born = true
    onCurrentTabChanged: {
        if (root._born && root.currentTab !== "displays") {
            root.selected = "";
            root._endGesture();
        }
    }

    // ---- the engine's contract: the keyboard and Escape, the tab on show's ---------------------------------------------------------------
    readonly property string keyboardFocusRequest: root.currentTab === "presets" && root.presetsTab ? String(root.presetsTab.keyboardFocusRequest) : "none"

    function handleEscape(): bool {
        const t = root.currentTab === "presets" ? root.presetsTab : root.displaysTab;
        return !!t && t.handleEscape() === true;
    }
    // the Displays tab's detail (the Presets tab has none)
    function stepBack(): bool {
        return root._detailOn && root.displaysTab.stepBack() === true;
    }

    // Called by the engine when it keeps this content parked after it was shown and closed (and only then: a content without it is thrown
    // away). What a fresh open expects: no detail, no menu / rename / confirm left on the cards. The TAB is the owner's (it binds it).
    function recycle(): void {
        root.selected = "";
        root._endGesture();
        let guard = 8;
        while (guard-- > 0 && root.presetsTab && root.presetsTab.handleEscape() === true) {
        }
    }

    // ---- the Displays tab's secondary (the detail), mapped into THIS content's frame -----------------------------------------------------
    readonly property bool _detailOn: root.currentTab === "displays" && !!root.displaysTab
    readonly property bool secondaryOpen: root._detailOn && root.displaysTab.secondaryOpen === true
    readonly property var secondaryKey: root._detailOn ? root.displaysTab.secondaryKey : null
    readonly property string secondarySide: root._detailOn ? String(root.displaysTab.secondarySide) : "start"
    readonly property real secondaryAnchorAt: root._detailOn ? root.displaysTab.secondaryAnchorAt : 0.5
    readonly property real secondaryWidthFrom: root._detailOn ? root.displaysTab.secondaryWidthFrom : 0.5
    readonly property bool secondaryOverhang: false
    readonly property real secondaryInset: 0
    // the popup's own right edge, at the row of the tile (the Displays tab's y is the header's below)
    readonly property point secondaryAnchor: root._detailOn ? Qt.point(root.width, root.displaysTab.secondaryAnchor.y + panoLoader.y) : Qt.point(0, 0)
    readonly property var secondaryComponent: root.displaysTab ? root.displaysTab.secondaryComponent : null

    // ---- the swipe-hold contract (docs/contracts/gestures.md section 4) --------------------------------------------------------------------
    // A sideways swipe switches tabs, and the tabs are different sizes: the popup changes size under the fingers. While a gesture lives the
    // host keeps its input at least the size of the larger tab and hands this content the wheels that land outside it (gestureWheel).
    property int gestureIdleEndMs: 260
    // wheel units that count as a sideways step, and a touchpad that reports only pixels is scaled into wheel units
    property real swipePixelToAngle: 2.5
    property bool _gestureActive: false
    property string _gestureAxis: ""
    readonly property bool swipeGestureActive: root._gestureActive
    readonly property real gestureHoldWidth: Math.max(root._wD, root._wP)
    readonly property real gestureHoldHeight: root._headH + Math.max(root._hD, root._hP)

    function _endGesture(): void {
        gestureIdleTimer.stop();
        if (root._gestureActive)
            tabSel.applySwipe(0);
        root._gestureActive = false;
        root._gestureAxis = "";
    }
    Timer {
        id: gestureIdleTimer
        interval: root.gestureIdleEndMs
        onTriggered: root._endGesture()
    }
    // One wheel event (WheelHub's). The area below and gestureWheel() both land here.
    function _wheel(ev: var): void {
        const ad = ev.angleDelta, pd = ev.pixelDelta;
        // a mouse: a sideways notch is a tab (an upright one is the list's, or the tab row's own)
        if (ev.device === "wheel") {
            if (ad.x !== 0)
                tabSel.applySteps(ev.steps);
            return;
        }
        const dx = ad.x !== 0 ? ad.x : pd.x * root.swipePixelToAngle;
        const dy = ad.y !== 0 ? ad.y : pd.y * root.swipePixelToAngle;
        // zero on both axes is the touchpad's scroll end: the fingers left. That, not the timer, ends a gesture.
        if (dx === 0 && dy === 0) {
            root._endGesture();
            return;
        }
        gestureIdleTimer.restart();
        if (!root._gestureActive) {
            root._gestureActive = true;
            root._gestureAxis = "";
        }
        if (root._gestureAxis === "") {
            if (Math.abs(dx) > Math.abs(dy) * 1.2)
                root._gestureAxis = "x";
            else if (Math.abs(dy) > Math.abs(dx) * 1.2)
                root._gestureAxis = "y";
        }
        if (root._gestureAxis === "x" && dx !== 0)
            tabSel.applySwipe(dx);
    }
    // A wheel the HOST forwards while a gesture lives (it landed outside this content: a tab switch made the popup narrower under the
    // fingers). A forwarded wheel never starts a gesture. Returns whether it was used.
    function gestureWheel(ev: var): bool {
        if (!root._gestureActive || !ev)
            return false;
        root._wheel(ev);
        return true;
    }

    // One area over the whole popup hears every wheel and never accepts it, so the grid underneath still scrolls.
    WheelArea {
        id: swipeArea
        // grown about the popup's centre while a gesture lives, so a narrower tab keeps hearing the rest of the swipe
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        width: root._gestureActive ? Math.max(root.width, root.gestureHoldWidth) : root.width
        height: root._gestureActive ? Math.max(root.height, root.gestureHoldHeight) : root.height
        z: 200
        turned: wheel => {
            root._wheel(wheel);
            wheel.accepted = false;
        }
    }
}
