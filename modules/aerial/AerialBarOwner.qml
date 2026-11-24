pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"
import "bar"
import "popup"

// =============================================================================
// AerialBarOwner.qml -- aerial's bar-side object: the pill (AerialBarButton) and the wiring between it, the one service and thePopup.
// (NetBtBarPair's successor; SiliconBarOwner is the model.)
//
// THE ENGINE BUILDS A POPUP'S CONTENT WHEN IT OPENS AND TEARS IT DOWN WHEN IT CLOSES, so what must outlive the popup lives here and
// in the service. ONE POPUP FOR ANY CLICK ON THE PILL: no sections, no halves, no tabs (the user's rule). The popup hangs from the
// pill's MIDDLE, rounded to a whole pixel (an x.5 middle lands a content that follows its own shift on a half pixel). `toggle()`
// opens or closes; there is no travel to another half.
//
// THE SERVICE IS NEVER THE OWNER'S: an AerialService starts a helper process and reads the machine, so the owner builds none, hosted or
// not. The shell hands in its one (`service`), a mockup or a probe its mock; null = the feature is absent (the pill draws the defaults,
// nothing opens).
//
// SHELL-HOSTED (`shellHosted`, docs/contracts/shell.md section 4): the shell mounts one owner per screen over ONE service, so a hosted
// owner writes no property of it, registers no shortcut and connects no unaddressed request. `sharedFlags` is what it would have
// written: `aerialPopupOpen` (the service's `popupOpen`: the scan, the tests, the stations follow the popup) and `aerialRatesWatch` (the
// service's `ratesWatched`: the 1 s beat of /proc/net/dev while a horizontal bar shows the traffic figures); the host ORs the screens'
// and writes the service once. Not hosted (a mockup, a probe), the owner writes them itself.
//
// THE PARTS' ANSWERS. The popup emits `partActivated(intent)` for a click on a part; the screw, the two DIP switches, the search
// button, the beacon and the test pads are answered here by the service's intents (`_answer`); the parts that open a detail popup
// (label, globe, jack, memory, usage, rings, ...) belong to the detail panels (stream P), which are the popup's own.
//
// THE POPUP'S FAMILY (Material / Blueprint) is silicon's one setting for both boards: the host hands it in (`family`).
// =============================================================================
Item {
    id: owner

    property var engine: null                 // GooeyEngine
    property var bar: null                    // GooeyBar this sits in
    property string barId: ""
    property string ownerId: "aerial"

    // ---- the pill ------------------------------------------------------------
    property string orientation: "horizontal"
    property real halfLength: 26
    property real thickness: 26
    // The down / up figures between the glyphs while the link carries a transfer (AerialBarButton). Off, the pill is plain and the
    // service is never asked for the 1 s beat.
    property bool trafficEnabled: true
    property var trafficConfig: ({})
    property string fontFamily: "Inter"
    readonly property alias button: pill

    // ---- the shell (CONTRACT section 4) --------------------------------------
    property bool shellHosted: false
    readonly property var sharedFlags: ({
            aerialPopupOpen: owner.popupMine,
            // the horizontal bars only: the side bars' pill has no room for the figures
            aerialRatesWatch: owner.trafficEnabled && owner.orientation === "horizontal"
        })

    // ---- the service: injected (the shell, a mockup, a probe) -----------------
    property var service: null
    readonly property var svc: owner.service

    // ---- the popup -------------------------------------------------------------
    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen && owner.engine.popupOwnerId === owner.ownerId
    // the popup's clock runs only while this holds: ours, and showing
    readonly property bool popupShown: owner.popupMine && !!owner.engine.thePopup && owner.engine.thePopup.contentOpacity > 0

    // the board's family (0 Material, 1 Blueprint): silicon's setting
    property int family: 0
    // how large the popup is drawn on top of its popup ratio (`scale.popups.aerial`): 0.5 .. 2, a constant of the module
    property real sizeScale: 1
    // DEVICE px per design px (the engine's renderScale; a mockup's stage zoom)
    readonly property real renderScale: owner.engine && owner.engine.renderScale > 0 ? owner.engine.renderScale : 1

    readonly property Component popupComponent: Component {
        AerialPopup {
            service: owner.svc
            family: owner.family
            sizeScale: owner.sizeScale
            renderScale: owner.renderScale
            open: owner.popupShown
            soundsEnabled: !owner.svc || !owner.svc.config || owner.svc.config.sounds !== false
            onPartActivated: intent => owner._answer(intent)
        }
    }

    // ---- the button --------------------------------------------------------------
    implicitWidth: pill.implicitWidth
    implicitHeight: pill.implicitHeight

    AerialBarButton {
        id: pill
        anchors.fill: parent
        service: owner.svc
        popupOpen: owner.popupMine
        trafficEnabled: owner.trafficEnabled
        trafficConfig: owner.trafficConfig
        fontFamily: owner.fontFamily
        orientation: owner.orientation
        halfLength: owner.halfLength
        thickness: owner.thickness
        onClicked: owner.toggle()
    }

    // Hover intent: the pointer has rested on the pill, so the content is built now, parked, for the click that follows.
    HoverIntent {
        target: pill
        enabled: !!owner.svc
        armed: !!owner.engine && !owner.popupMine
        onIntent: owner.engine.prebuild(owner.ownerId, owner.popupComponent, { parked: true })
    }

    // The service's cadence follows the popup and the figures: only an owner that is not hosted writes them.
    Binding {
        target: owner.svc
        property: "popupOpen"
        value: owner.sharedFlags.aerialPopupOpen
        when: !owner.shellHosted && !!owner.svc
    }
    Binding {
        target: owner.svc
        property: "ratesWatched"
        value: owner.sharedFlags.aerialRatesWatch
        when: !owner.shellHosted && !!owner.svc && "ratesWatched" in owner.svc
    }

    // ---- the parts' answers --------------------------------------------------------
    function _answer(intent: string): void {
        const s = owner.svc;
        if (!s)
            return;
        if (intent === "screw")
            s.setAirplane(!s.airplane.on);
        else if (intent === "dip.wifi")
            s.setRadio(!s.wifi.radioOn);
        else if (intent === "dip.bt")
            s.setBtPowered(!s.bt.powered);
        // SCAN and BEACON are toggles (round 6): a second press ends what runs
        else if (intent === "bt.scan")
            s.bt.discovering ? s.btStopSearch() : s.btSearch();
        else if (intent === "beacon")
            s.bt.discoverable ? s.btHide() : s.btVisible();
        else if (intent.indexOf("pad.") === 0)
            s.testPad(intent.slice(4));
    }

    function toggle(): void {
        if (owner.popupMine)
            owner.close();
        else
            owner.open();
    }

    // Nothing opens without a service: the popup is built from it, and a data layer that did not load leaves the pill as it is.
    function open(): void {
        if (!owner.engine || !owner.bar || !owner.svc || owner.popupMine)
            return;
        // Read at the moment of opening, not bound (a mapToItem in a binding does not track the layout that moved it), and ROUNDED: the
        // engine rests a popup about the middle its owner passes, so an x.5 middle lands the content on a half pixel.
        const centre = Math.round(owner.mapToItem(owner.bar, owner.width / 2, owner.height / 2).x);
        owner.engine.open(owner.ownerId, owner.barId, centre, null, null, false, owner.popupComponent, 1);
    }

    function close(): void {
        if (owner.popupMine)
            owner.engine.close();
    }
}
