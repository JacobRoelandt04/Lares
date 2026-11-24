pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "body"
import "screen"
import "data/BridgeModel.js" as Model

// =============================================================================
// BridgePopup.qml -- the bridge's popup, the drop-in content of the bar's popup (thePopup): a PHONE, drawn front-on, whose
// screen is the control panel (docs/contracts/bridge.md). One fixed size (the PhoneStage's: 320 x 664), no views.
//
//     BridgePopup { service: <BridgeService>; fontFamily: "Inter" }
//
// WHAT IS IN IT. ONE PhoneStage (modules/bridge/body): the body and the display. On the FRONT, in the display, the
// ScreenFace: the status bar, the home screen (name, one line, six tiles), its pages (Mirror, Files, Pair, and Details: the
// device's sheet and the rare controls, behind the device menu). The BACK is the phone's own back and carries nothing: the
// turn is a thing to play with, not a place to read (the user's review of round 2). The body's own keys act: the power key
// and the volume rocker press those keys on the phone (`service.pressKey`), the cable opens the Files page.
//
// WHO DECIDES. Nothing here knows what a phone can do: every tile, key and switch is enabled by `can.<x>.ok` of the tool
// (through the service) and says its `why` and `hint` when it is not. With no `service` it shows the "no phone" screen.
//
// THE SWIPE. Two fingers sideways are one gesture with ONE reader (SwipeScrub over the whole popup, gestures.md), and its
// ROLE is latched at the gesture's first scrub: with a page open it is the page's back (scrubbed under the fingers); otherwise
// it turns the phone over (the stage's own half turn: a lift past a third commits, short of it springs back). The reader is
// deaf while a committed back or a turn is still playing out, and the stage cannot turn while a page is open.
//
// THE CAST. While the cast page rests on the display the popup takes the keyboard (`onDemand`: the keys are the phone's) and is
// RESIZED by its free edges like the notes popup (PopupEdgeResize, the engine's live-resize contract); the phone keeps its
// shape, one `zoom` (service.castScale) for both sides, and is drawn again at its new size. Off the cast page it is the phone
// at zoom 1 (the engine eases there).
//
// FREE LOOK. With the pointer over the popup, Alt HELD turns the phone with the pointer's own motion (nothing pressed): the
// stage's look (PhoneStage `lookBegin` / `lookEnd`), every way round, and back to the face it showed when Alt is let go. The
// pointer is hidden meanwhile and kept where the look began: the popup only ASKS (`lookPointer("hold")` at the start,
// `lookPointer("home")` whenever it has strayed and at the end); the owner moves the real pointer, a host that cannot leaves
// it. Alt is read from the key itself and, as a net, from each pointer motion's modifiers (Alt already down as the pointer
// comes in; a release the popup never heard). Wayland tells the modifiers only to the surface that holds the keyboard, so
// the popup asks for the keyboard once a pointer has MOVED onto it (HoverArm: never because it opened under a resting one).
//
// THE ENGINE'S CONTRACT (GooeyEngine's content contract): `keyboardFocusRequest` none until a pointer has moved onto the popup,
// then onDemand (and always on the cast page and while the Details page's PIN field is open); `handleEscape()` closes the device menu, else that field, else goes back from a page, else lets
// the popup close (never two of them at once); `parked` / `prewarm` (a parked content runs nothing; with `prewarm` it only draws the body's pipelines once); `swipeGestureActive`, `gestureHoldWidth` /
// `Height` and `gestureWheel(ev)`.
//
// ONE FULL TURN plays at every open (`settings.flip.onOpen`), once the content is shown.
//
// WHAT THE OWNER SETS: `service` (the shell's one BridgeService), `fontFamily`. The overlay (tips, the device menu, the drop
// mark) is this popup's own and sits above everything.
// =============================================================================
Item {
    id: popup

    // ---- what the owner gives ---------------------------------------------------------------------------------------
    property var service: null
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}
    // the engine's: held hidden (nothing runs), or built ahead to draw the body's pipelines once
    property bool parked: false
    property bool prewarm: false
    // one full turn at every open (the config's `flip.onOpen`); a harness may say no
    property bool flipOnOpen: popup.service ? popup.service.settings.flip.onOpen : true

    readonly property Item overlay: overlayLayer
    readonly property alias stage: stage
    readonly property alias screenFace: screenFace
    readonly property alias deviceMenu: deviceMenu
    readonly property var device: screenFace.dev

    implicitWidth: stage.implicitWidth
    implicitHeight: stage.implicitHeight

    // ---- the cast's size ------------------------------------------------------------------------------------------------
    // from the service's fact, never from the face: the face is laid out from the stage's geometry, which the zoom feeds (reading
    // the face here was a binding loop on the stage's layout)
    readonly property bool _castShown: popup.service !== null && popup.service.page === "cast"
    // the cast's size, carried in and out WITH the page (the face's castShare: the morph's progress, the fingers' on a swipe back)
    readonly property real _castShare: screenFace.castShare
    readonly property real _zoom: popup.service ? 1 + (popup.service.castScale - 1) * popup._castShare : 1
    // the largest zoom the window can hold (the popup's own scale in the frame read off its mapping)
    readonly property real _maxZoom: {
        const w = popup.Window.window;
        if (!w || popup.height <= 0)
            return 1.8;
        const k = Math.abs(popup.mapToItem(null, 0, popup.height).y - popup.mapToItem(null, 0, 0).y) / popup.height;
        return Math.max(1, (w.height * 0.92) / (664 * (k > 0 ? k : 1)));
    }
    // The resizer reports the dragged side's new length and keeps the other at its length from the drag's START: the side that
    // moves is the one that differs from the start, and it alone decides the zoom (deciding by the CURRENT size picked the
    // unchanged side as soon as the zoom had grown: the box fell back every other frame, the user's flicker). A resize grows
    // about the popup's centre and never moves it (the resizer's `symmetric`); the place is the move grip's alone, the middle
    // of the foot (the user's review 2026-11-19: a corner drag had walked the popup to the centre island).
    property real _dragZ0: 1
    property real _dragShift0: 0
    Connections {
        target: resizer
        function onActiveChanged(): void {
            if (resizer.active && popup.service) {
                popup._dragZ0 = popup.service.castScale;
                popup._dragShift0 = popup.service.castShift;
            }
        }
    }
    function _resizeTo(w: real, h: real, shift: real): void {
        if (!popup.service)
            return;
        if (resizer.moving) {
            popup.service.castShift = shift;
            return;
        }
        const z0 = popup._dragZ0;
        const dw = Math.abs(w - 320 * z0), dh = Math.abs(h - 664 * z0);
        popup.service.castScale = Math.max(1, Math.min(popup._maxZoom, dw >= dh ? w / 320 : h / 664));
        popup.service.castShift = popup._dragShift0;
    }
    // Back to the resting size and place, on the resize clock (260 ms OutCubic), the host following frame by frame.
    readonly property bool _resized: popup.service !== null && (popup.service.castScale !== 1 || popup.service.castShift !== 0)
    property real _resetZ0: 1
    property real _resetS0: 0
    function resetSize(): void {
        if (!popup.service || !popup._resized)
            return;
        popup._resetZ0 = popup.service.castScale;
        popup._resetS0 = popup.service.castShift;
        resetClock.f = 0;
        resetAnim.restart();
    }
    QtObject {
        id: resetClock
        property real f: 0
        onFChanged: {
            if (!resetAnim.running || !popup.service)
                return;
            popup.service.castScale = resetClock.f >= 1 ? 1 : popup._resetZ0 + (1 - popup._resetZ0) * resetClock.f;
            popup.service.castShift = resetClock.f >= 1 ? 0 : popup._resetS0 * (1 - resetClock.f);
        }
    }
    NumberAnimation {
        id: resetAnim
        target: resetClock
        property: "f"
        from: 0
        to: 1
        duration: 260
        easing.type: Easing.OutCubic
    }
    // live while dragged, and while the page carries a resized popup in or out (the host follows the size exactly, frame by frame)
    readonly property bool liveResizeActive: resizer.active || resetAnim.running
        || (popup._castShare > 0 && popup._castShare < 1 && popup.service !== null && (popup.service.castScale !== 1 || popup.service.castShift !== 0))
    readonly property real alongShift: popup.service ? popup.service.castShift * popup._castShare : 0
    property var hostRoom: null

    // ---- the engine's content contract ----------------------------------------------------------------------------------
    readonly property string keyboardFocusRequest: popup._castShown || screenFace.keysWanted || popup._keysAsked ? "onDemand" : "none"

    // ---- free look ---------------------------------------------------------------------------------------------------------
    // held: the pointer turns the phone and nothing else (the cast page sends the phone nothing meanwhile)
    readonly property bool freeLooking: stage.lookHeld
    // the engine's content contract: the window's cursor cover hides the pointer too (shell.jsonc `hoverCursor` off)
    readonly property bool pointerHidden: popup.freeLooking
    // "hold": the look begins, remember where the pointer is. "home": put it back there.
    signal lookPointer(string what)
    // Alt is also read off each pointer motion's modifiers (a harness whose synthetic pointer carries none says no)
    property bool lookFromMotion: true
    // a mockup's switch or a harness holds the look without the key
    property bool freeLookHold: false
    onFreeLookHoldChanged: popup.freeLookHold ? stage.lookBegin() : stage.lookEnd()
    // LATCHED until the popup is put away: the compositor answers a changed keyboard ask by re-entering the pointer, and
    // an ask that followed the hover would take itself back (the keyboard came and went within one motion, measured nested)
    property bool _keysAsked: false
    HoverArm {
        id: keysArm
        target: popup
        active: !popup.parked && !popup.prewarm
    }
    // bridge.jsonc lookKey: the key held for the look ("off": none; a mockup's switch still holds it)
    readonly property string lookKey: popup.service && popup.service.settings.lookKey ? popup.service.settings.lookKey : "alt"
    readonly property int _lookKeyCode: popup.lookKey === "ctrl" ? Qt.Key_Control : popup.lookKey === "shift" ? Qt.Key_Shift : popup.lookKey === "alt" ? Qt.Key_Alt : -1
    readonly property int _lookMod: popup.lookKey === "ctrl" ? Qt.ControlModifier : popup.lookKey === "shift" ? Qt.ShiftModifier : popup.lookKey === "alt" ? Qt.AltModifier : 0
    function _look(down: bool): void {
        if (popup.freeLookHold)
            return;
        if (down && keysArm.hovered && !popup.parked)
            stage.lookBegin();
        else
            stage.lookEnd();
    }
    // the keys come to whatever holds the focus in the popup and rise from there; with nothing focused the popup takes it
    function _takeFocus(): void {
        const w = popup.Window.window;
        if (w && (!w.activeFocusItem || w.activeFocusItem === w.contentItem))
            popup.forceActiveFocus();
    }
    Keys.onPressed: event => {
        if (event.key === popup._lookKeyCode && !event.isAutoRepeat)
            popup._look(true);
    }
    Keys.onReleased: event => {
        if (event.key === popup._lookKeyCode && !event.isAutoRepeat)
            popup._look(false);
    }
    Connections {
        target: keysArm
        function onArmedChanged(): void {
            if (keysArm.armed) {
                popup._keysAsked = true;
                popup._takeFocus();
            }
        }
        function onHoveredChanged(): void {
            if (!keysArm.hovered && !popup.freeLookHold)
                stage.lookEnd();
        }
    }
    Connections {
        target: popup.Window.window
        function onActiveChanged(): void {
            if (popup.Window.window.active)
                popup._takeFocus();
            else
                stage.lookEnd();
        }
    }
    onParkedChanged: {
        if (popup.parked) {
            stage.lookEnd();
            popup._keysAsked = false;
        }
    }
    readonly property bool swipeGestureActive: swipe.active
    readonly property real gestureHoldWidth: popup.implicitWidth
    readonly property real gestureHoldHeight: popup.implicitHeight
    function gestureWheel(ev: var): bool {
        return swipe.gestureWheel(ev);
    }
    // Opens the device menu under the screen's name, as a click on the name does.
    function openMenu(): void {
        screenFace.menuRequested(screenFace.nameItem);
    }
    // Escape: the device menu first, then a page; one thing per press. false closes the popup.
    function handleEscape(): bool {
        if (deviceMenu.handleEscape())
            return true;
        if (screenFace.cancelEdit())
            return true;
        if (screenFace.pageOpen || screenFace.morphing) {
            screenFace.goBack();
            return true;
        }
        return false;
    }

    // ---- the facts the stage wants ---------------------------------------------------------------------------------------
    readonly property var _dev: screenFace.dev
    readonly property var _canKey: Model.canOf(popup._dev, "key")
    readonly property bool _working: popup.service !== null && popup._dev !== null
        && (popup.service.job(popup._dev.key, "mirror") !== null || popup.service.job(popup._dev.key, "send") !== null)

    // The display of an asleep device is dimmed: the stage draws the ground, so a fraction eased here gives it (never a colour
    // animation: the two ends are themed).
    property real _dimF: screenFace.kind === "asleep" ? 1 : 0
    Behavior on _dimF {
        NumberAnimation {
            duration: popup.style.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    readonly property color _ground: Mix.c(Theme.listBox, Mix.c(Theme.listBox, Theme.shadowDeep, popup.style.asleepDim), popup._dimF)

    PhoneStage {
        id: stage
        anchors.fill: parent
        zoom: popup._zoom
        skin: popup._dev ? popup._dev.skin : "generic"
        wired: popup._dev !== null && popup._dev.usb !== null
        busy: popup._working
        relight: popup.service ? popup.service.settings.relight : true
        overlayItem: overlayLayer
        screenGround: popup._ground
        canFlip: !screenFace.pageOpen && !screenFace.morphing
        partEnabled: ({ power: popup._canKey.ok, volup: popup._canKey.ok, voldown: popup._canKey.ok, cable: true })
        partTips: ({
                power: popup._canKey.ok ? "Wake or sleep the screen" : popup._keyWhy,
                volup: popup._canKey.ok ? "Volume up" : popup._keyWhy,
                voldown: popup._canKey.ok ? "Volume down" : popup._keyWhy,
                cable: "Files"
            })
        onPartClicked: part => {
            if (part === "cable") {
                if (screenFace.page !== "files")
                    screenFace.openPage("files");
            } else if (popup.service && popup._dev && popup._canKey.ok) {
                popup.service.pressKey(popup._dev.key, part);
            }
        }

        front: [
            ScreenFace {
                id: screenFace
                anchors.fill: parent
                service: popup.service
                style: popup.style
                fontFamily: popup.fontFamily
                overlayItem: overlayLayer
                ground: popup._ground
                // held for a look, the pointer and the keys are the look's: the cast sends the phone nothing
                castInputHeld: popup.freeLooking
                // a turned phone is no closed popup: the cast plays on, and no new size is asked of the phone until it has landed
                shown: popup.visible
                turning: stage.flipping
                onMenuRequested: anchor => {
                    const p = anchor.mapToItem(overlayLayer, (anchor.width - popup.style.menuWidth) / 2, anchor.height + 6);
                    deviceMenu.openAt(Math.round(p.x), Math.round(p.y));
                }
            }
        ]
    }
    readonly property string _keyWhy: popup._canKey.why !== "" ? popup._canKey.why + (popup._canKey.hint !== "" ? ". " + popup._canKey.hint : "") : "No phone to press keys on"

    // a menu does not turn with the phone
    Connections {
        target: stage
        function onFlippingChanged(): void {
            if (stage.flipping)
                deviceMenu.close();
        }
        function onPointerMoved(modifiers: int): void {
            if (popup.lookFromMotion && popup._lookMod !== 0)
                popup._look((modifiers & popup._lookMod) !== 0);
        }
        function onLookHeldChanged(): void {
            if (stage.lookHeld)
                popup.lookPointer("hold");
        }
        function onLookStrayed(): void {
            popup.lookPointer("home");
        }
    }

    // ---- files dropped on the display --------------------------------------------------------------------------------
    DropArea {
        id: drop
        x: stage.screenRect.x
        y: stage.screenRect.y
        width: stage.screenRect.width
        height: stage.screenRect.height
        keys: []
        onEntered: event => {
            event.accepted = event.hasUrls;
        }
        onDropped: event => {
            if (!event.hasUrls)
                return;
            const paths = [];
            for (let i = 0; i < event.urls.length; i++) {
                const u = event.urls[i].toString();
                if (u.indexOf("file://") === 0)
                    paths.push(decodeURIComponent(u.substring(7)));
            }
            event.accept();
            popup.dropped(paths);
        }
    }
    // what a drop asks for: a send to the current device when the tool says it can, else the mark shakes. (The probe's drop
    // simulation and the DropArea come through here.)
    function dropped(paths: var): void {
        if (paths.length === 0 || !popup.service || !popup._dev || !Model.canOf(popup._dev, "send").ok) {
            dropMark.refuse();
            return;
        }
        popup.service.send(popup._dev.key, paths);
    }
    property real _dropF: drop.containsDrag ? 1 : 0
    Behavior on _dropF {
        NumberAnimation {
            duration: popup.style.fadeMs
            easing.type: Easing.OutCubic
        }
    }

    // ---- the swipe -------------------------------------------------------------------------------------------------
    // ONE reader over the whole popup. A page open: its back. Otherwise the phone's turn. The role is latched at the first scrub.
    property string _role: ""
    function _roleNow(): string {
        return screenFace.pageOpen ? "page" : "phone";
    }
    SwipeScrub {
        id: swipe
        anchors.fill: parent
        z: 880
        // from the front a swipe one way turns to the back, from the back the reverse turns to the front
        sign: stage.face === "front" ? 1 : -1
        canBegin: screenFace.pageOpen ? true : stage.canFlip
        // a committed back, or a turn, is still playing out: the fingers that carry on must not start a second one over it
        blocked: !swipe.active && (stage.flipping || screenFace.backCommitted)
        onScrub: p => {
            if (!swipe.active) {
                popup._role = popup._roleNow();
                if (popup._role === "page")
                    screenFace.beginBackScrub();
            }
            if (popup._role === "page")
                screenFace.scrubBack(p);
            else
                stage.scrubTo(p);
        }
        // `active` is still true on a lift after a scrub; with no scrub under the fingers it was a notch: one whole step
        onCommit: {
            const role = swipe.active ? popup._role : popup._roleNow();
            popup._role = "";
            if (role === "page")
                screenFace.liftBack(true);
            else
                stage.commit();
        }
        onCancel: {
            const role = swipe.active ? popup._role : popup._roleNow();
            popup._role = "";
            if (role === "page")
                screenFace.liftBack(false);
            else
                stage.cancel();
        }
    }

    // ---- the cast's controls: above the phone, in the stage's own margin (never over the picture: over it they hid the phone's
    // status bar, the user's review 2026-11-19), three icons that come and go WITH the cast page ------------------------------
    readonly property bool _castAudio: popup._dev !== null && popup._dev.prefs.castAudio === true
    Row {
        id: castControls
        visible: popup._castShare > 0.01
        opacity: popup._castShare
        spacing: Math.round(14 * popup._zoom)
        x: Math.round((popup.width - width) / 2)
        y: Math.round((stage.topMargin * popup._zoom - height) / 2)
        z: 950
        QuietButton {
            text: popup._castAudio ? "\u{F057E}" : "\u{F0581}"
            fontFamily: "Symbols Nerd Font"
            fontPixelSize: 15
            overlayItem: overlayLayer
            tip: popup._castAudio ? "Sound on this computer: on" : "Sound on this computer: off"
            onClicked: {
                if (popup.service)
                    popup.service.castSetAudio(!popup._castAudio);
            }
        }
        QuietButton {
            text: "\u{F03CC}"
            fontFamily: "Symbols Nerd Font"
            fontPixelSize: 15
            overlayItem: overlayLayer
            tip: "In a window of its own"
            onClicked: {
                if (popup.service)
                    popup.service.castDetach();
            }
        }
        QuietButton {
            text: "\u{F04DB}"
            fontFamily: "Symbols Nerd Font"
            fontPixelSize: 15
            overlayItem: overlayLayer
            tip: "Stop"
            onClicked: {
                if (popup.service)
                    popup.service.castStop();
                screenFace.goBack();
            }
        }
    }

    // the resting size back (the notes popup's reset): at the right of the controls' margin, there while the cast is resized
    QuietButton {
        id: castReset
        property real presence: popup._resized && !resetAnim.running ? 1 : 0
        Behavior on presence {
            NumberAnimation {
                duration: popup.style.fadeMs
                easing.type: Easing.OutCubic
            }
        }
        visible: castControls.visible && castReset.presence > 0.01
        opacity: popup._castShare * castReset.presence
        x: Math.round(popup.width - width - 12 * popup._zoom)
        y: castControls.y
        z: 950
        text: "\uF066"
        fontFamily: "Symbols Nerd Font"
        fontPixelSize: 13
        overlayItem: overlayLayer
        tip: "Back to the resting size"
        onClicked: popup.resetSize()
    }

    // ---- the cast's edges: a drag resizes the phone (the notes popup's grips; nothing drawn, the pointer says it) ----------
    PopupEdgeResize {
        id: resizer
        anchors.fill: parent
        z: 900
        enabled: screenFace.castShown
        hostRoom: popup.hostRoom
        curW: popup.width
        curH: popup.height
        curShift: popup.alongShift
        minW: 320
        minH: 664
        // a resize keeps the place; the middle of the foot, under the phone, moves it
        symmetric: true
        moveWidth: Math.round(120 * popup._zoom)
        moveDepth: Math.round(stage.topMargin * popup._zoom)
        onResized: (w, h, shift) => popup._resizeTo(w, h, shift)
        onCommitted: (w, h, shift) => popup._resizeTo(w, h, shift)
    }

    // ---- what floats over everything ---------------------------------------------------------------------------------------
    Item {
        id: overlayLayer
        anchors.fill: parent
        z: 1000

        FileDropOverlay {
            id: dropMark
            x: stage.screenRect.x
            y: stage.screenRect.y
            width: stage.screenRect.width
            height: stage.screenRect.height
            radius: stage.screenRadius
            surfaceColor: popup._ground
            presence: popup._dropF
        }
    }
    DeviceMenu {
        id: deviceMenu
        service: popup.service
        overlayItem: overlayLayer
        fontFamily: popup.fontFamily
        style: popup.style
        onPairRequested: screenFace.openPage("pair")
        onDetailsRequested: screenFace.openPage("device")
    }

    // ---- the open --------------------------------------------------------------------------------------------------------
    // One full turn at every open, from a 0 ms turn after the build; a prewarm draws the body's pipelines instead; a content
    // built parked does it when it is shown. The device's facts (model, storage) are asked once, never from a getter.
    property bool _shown: false
    function _opened(): void {
        if (popup.parked || popup._shown)
            return;
        popup._shown = true;
        if (popup.prewarm)
            stage.warm();
        else if (popup.flipOnOpen)
            stage.flourish();
        askFacts.restart();
    }
    Timer {
        id: openTurn
        interval: 0
        onTriggered: popup._opened()
    }
    Connections {
        target: popup
        function onParkedChanged(): void {
            if (!popup.parked)
                openTurn.restart();
        }
    }
    Component.onCompleted: openTurn.restart()

    readonly property bool _wantFacts: popup._dev !== null && popup._dev.facts === null && Model.canOf(popup._dev, "facts").ok
    on_WantFactsChanged: if (popup._wantFacts && popup._shown && !popup.parked)
        askFacts.restart()
    Timer {
        id: askFacts
        interval: 0
        onTriggered: {
            if (popup._wantFacts && popup.service && popup._dev)
                popup.service.loadFacts(popup._dev.key);
        }
    }
}
