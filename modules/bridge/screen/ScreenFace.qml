pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"
import "../../common/components"
import "../../common/components/LevelMorph.js" as LM

// =============================================================================
// ScreenFace.qml -- what the phone's DISPLAY shows: the whole control panel, the front face of the PhoneStage
// (`front: [ ScreenFace { anchors.fill: parent } ]`). It fills the display; the stage draws the display's ground under it
// and its round corners over it, so this face keeps its text clear of them (`style.statusInset`, `style.padding`).
//
// WHAT IT SHOWS is decided from the service's facts only, never from a guess:
//
//   no device   (`count` is 0, or there is no service)        PairingScreen
//   asleep      (the current device is not `present`)         AsleepScreen
//   otherwise   HomeScreen: the name, one line, six tiles
//
// THE CAST PAGE ("cast", CastPage) is the one page that fills the WHOLE display: the phone's own picture brings its status bar
// and navigation, so the face's status bar and home indicator step aside while it rests there. It grows out of the Mirror tile.
//
// and, over any of them, ONE PAGE at a time: `service.page` ("mirror" | "files"; it lives in the service because a popup's
// content is destroyed on close) or one of this face's own ("pair", the pairing page, and "device", the device's details:
// neither is a service fact).
// A page GROWS OUT OF ITS TILE (MorphCard, LevelMorph.js, the notes popup's way: the tile becomes the card becomes the page;
// the screen left behind recedes), on one clock (MorphClock), and goes back into it. The phone's own chrome stays put: the
// status bar on top, the home indicator at the foot (a click on it goes home).
//
// SWIPING BACK. The popup reads the two-finger swipe (one SwipeScrub over the whole popup) and calls `beginBackScrub()`,
// `scrubBack(p)` and `liftBack(commit)` here; `backCommitted` says a committed back is still playing out (the popup keeps the
// reader from starting a second one over it).
//
// RULES OF THE FACE THE PHONE TURNS: it holds no `layer` and animates no colour. A change of which screen shows is instant and
// the new one fades in (presence only); a page's chrome belongs to the page.
// =============================================================================
Item {
    id: screen

    property var service: null
    property BridgeStyle style: BridgeStyle {}
    property string fontFamily: "Inter"
    property Item overlayItem: null
    // the display's ground (the stage draws it; the face's controls stand on it)
    property color ground: Theme.listBox
    // the cast page sends the phone nothing while this holds (BridgePopup's free look owns the pointer and the keys then)
    property bool castInputHeld: false
    // the host is on the glass (the face's own `visible` goes with the phone's turn) and the phone in it is turning: what the cast
    // page's player and its size follow
    property bool shown: screen.visible
    property bool turning: false

    // a device menu is wanted at this item (the owner floats it in the overlay)
    signal menuRequested(Item anchor)

    // ---- the facts --------------------------------------------------------------------------------------------------
    // the current device's record; with none current the first one (a device list always has an order)
    readonly property var dev: {
        const svc = screen.service;
        if (!svc)
            return null;
        void svc.serial;
        void svc.rowSerial;
        return svc.current || (svc.count > 0 ? svc.devices.get(0).rec.d : null);
    }
    readonly property string kind: !screen.service || screen.service.count === 0 ? "pairing" : (screen.dev && !screen.dev.present ? "asleep" : "home")

    // the device's name on whichever screen shows one (a menu of devices opens under it)
    readonly property Item nameItem: screen.kind === "asleep" ? asleep.nameItem : home.nameItem

    // ---- the geometry of the display ----------------------------------------------------------------------------------
    // the room between the status bar and the home indicator: the home screen's and every page's
    readonly property real pageTop: screen.style.statusTop + screen.style.statusHeight + screen.style.pageTopGap
    readonly property real pageBottom: screen.height - screen.style.indicatorBottom - screen.style.indicatorHeight - screen.style.indicatorGap
    readonly property real pageHeight: Math.max(0, screen.pageBottom - screen.pageTop)
    readonly property var _full: screen.shownPage === "cast" ? ({ x: 0, y: 0, w: screen.width, h: screen.height })
                                                              : ({ x: 0, y: screen.pageTop, w: screen.width, h: screen.pageHeight })
    // the cast page at rest: the face's own chrome steps aside
    readonly property bool castShown: screen.page === "cast" && screen._m === null
    // a page's text field is open (the Details page's PIN): the popup asks for the keys; Escape closes it before the page
    readonly property DevicePage _devicePage: deviceLoader.item as DevicePage
    readonly property bool keysWanted: screen._devicePage !== null && screen._devicePage.keysWanted
    function cancelEdit(): bool {
        return screen._devicePage !== null && screen._devicePage.cancelEdit();
    }
    // how much of the cast's room the popup takes: 1 resting on the cast page, the morph's progress while it grows out or goes
    // (a swipe back scrubs it with the fingers), 0 elsewhere -- the popup's size follows it, so the way back is one motion
    readonly property real castShare: screen._m ? (screen._m.page === "cast" ? (screen._m.dir === "open" ? clock.me : 1 - clock.me) : 0)
                                                : (screen.page === "cast" ? 1 : 0)

    // ---- the page ---------------------------------------------------------------------------------------------------
    property string _localPage: ""
    readonly property string page: screen.service && screen.service.page !== "" ? screen.service.page : screen._localPage
    readonly property bool pageOpen: screen.page !== ""
    function _setPage(p: string): void {
        if (p === "pair" || p === "device" || !screen.service) {
            screen._localPage = p;
            if (screen.service && p !== "")
                screen.service.page = "";
        } else {
            screen._localPage = "";
            screen.service.page = p;
        }
    }

    // ---- the morph --------------------------------------------------------------------------------------------------
    // _m = { dir: "open" | "back", page, tile: {x, y, w, h}, scrub, cancelled }; null at rest
    property var _m: null
    readonly property bool morphing: screen._m !== null
    readonly property string shownPage: screen._m ? screen._m.page : screen.page
    // a back that was committed (lifted past the third, or asked outright) and is still playing out
    readonly property bool backCommitted: screen._m !== null && screen._m.dir === "back" && !screen._m.scrub && !screen._m.cancelled

    MorphClock {
        id: clock
        morphMs: screen.style.morphMs
        onLanded: screen._landed()
    }
    readonly property var _fr: LM.fractions(screen._m ? screen._m.dir : "", clock.me)
    // the tile as the screen left behind draws it on this frame: its place, scaled about its own centre by the receding zoom
    readonly property var _tileNow: {
        if (!screen._m)
            return { x: 0, y: 0, w: 0, h: 0 };
        const t = screen._m.tile;
        return LM.zoomRect(t, { x: t.x + t.w / 2, y: t.y + t.h / 2 }, screen._fr.zoom);
    }
    // at rest the page stands on its own room (the cast's is the whole display: placed at pageTop it hung out of the phone's foot)
    readonly property var _card: screen._m ? LM.cardRect(screen._tileNow, screen._full, screen._m.dir, clock.me) : { x: screen._full.x, y: screen._full.y, w: screen._full.w, h: screen._full.h, s: 1 }

    // where a page's tile stands (the home screen knows); the details grow out of the device's name; with no tile the
    // centre of the room
    function _tileOf(p: string): var {
        if (p === "device" && screen.nameItem) {
            const c = screen.nameItem.mapToItem(screen, screen.nameItem.width / 2, screen.nameItem.height / 2);
            return { x: c.x, y: c.y, w: 0, h: 0 };
        }
        if (screen.kind === "home")
            return home.tileRect(p === "cast" ? "mirror" : p);
        return { x: screen.width / 2, y: screen.pageTop + screen.pageHeight / 2, w: 0, h: 0 };
    }
    function _finishNow(): void {
        clock.stop();
        const m = screen._m;
        if (m && m.dir === "back" && !m.cancelled && !m.scrub)
            screen._setPage("");
        screen._m = null;
        clock.mt = 0;
    }
    function _landed(): void {
        const m = screen._m;
        if (!m)
            return;
        // the page goes only now: a back that was let go can still be turned round
        if (m.dir === "back" && !m.cancelled)
            screen._setPage("");
        screen._m = null;
        clock.mt = 0;
    }

    function openPage(name: string): void {
        if (screen.page === name && !screen._m)
            return;
        if (screen._m)
            screen._finishNow();
        screen._m = { dir: "open", page: name, tile: screen._tileOf(name), scrub: false, cancelled: false };
        clock.stop();
        clock.mt = 0;
        screen._setPage(name);
        clock.runTo(1);
    }
    // Back, by a click or a key: true when there was a page to leave (a back already running is that page's and is left alone).
    function goBack(): bool {
        if (!screen.pageOpen)
            return false;
        if (screen.backCommitted)
            return true;
        if (screen._m)
            screen._finishNow();
        screen._m = { dir: "back", page: screen.page, tile: screen._tileOf(screen.page), scrub: false, cancelled: false };
        clock.stop();
        clock.mt = 0;
        clock.runTo(1);
        return true;
    }
    // ---- the swipe's three calls ------------------------------------------------------------------------------------
    function beginBackScrub(): void {
        if (!screen.pageOpen)
            return;
        if (screen._m)
            screen._finishNow();
        screen._m = { dir: "back", page: screen.page, tile: screen._tileOf(screen.page), scrub: true, cancelled: false };
        clock.stop();
        clock.mt = 0;
    }
    function scrubBack(p: real): void {
        if (screen._m && screen._m.scrub)
            clock.scrubTo(p);
    }
    // the fingers lifted: past a third (or a fling) on to the home screen, short of it back to the page
    function liftBack(commit: bool): void {
        if (!screen._m || !screen._m.scrub) {
            // no scrub was under the fingers: it was a notch, one whole back
            if (commit)
                screen.goBack();
            return;
        }
        const n = Object.assign({}, screen._m);
        n.scrub = false;
        if (!commit)
            n.cancelled = true;
        screen._m = n;
        clock.runTo(commit ? 1 : 0);
    }

    // ---- which screen: an instant swap, the newcomer fades in --------------------------------------------------------
    property bool _built: false
    property real _kindF: 1
    NumberAnimation {
        id: kindFade
        target: screen
        property: "_kindF"
        from: 0
        to: 1
        duration: screen.style.fadeMs
        easing.type: Easing.OutCubic
    }
    onKindChanged: if (screen._built)
        kindFade.restart()
    Component.onCompleted: screen._built = true

    // ---- the phone's chrome -------------------------------------------------------------------------------------------
    StatusBar {
        id: statusBar
        visible: !screen.castShown
        x: 0
        y: screen.style.statusTop
        width: screen.width
        height: screen.style.statusHeight
        dev: screen.kind === "pairing" ? null : screen.dev
        fontFamily: screen.fontFamily
        style: screen.style
        ground: screen.ground
    }

    // ---- the screen left behind ---------------------------------------------------------------------------------------
    Item {
        id: base
        anchors.fill: parent
        visible: screen._m !== null || screen.page === ""
        opacity: (screen._m !== null ? screen._fr.recede : 1) * screen._kindF
        transform: Scale {
            origin.x: screen._m ? screen._m.tile.x + screen._m.tile.w / 2 : 0
            origin.y: screen._m ? screen._m.tile.y + screen._m.tile.h / 2 : 0
            xScale: screen._m ? screen._fr.zoom : 1
            yScale: screen._m ? screen._fr.zoom : 1
        }

        HomeScreen {
            id: home
            anchors.fill: parent
            visible: screen.kind === "home"
            service: screen.service
            dev: screen.dev
            fontFamily: screen.fontFamily
            style: screen.style
            overlayItem: screen.overlayItem
            ground: screen.ground
            roomTop: screen.pageTop
            roomHeight: screen.pageHeight
            onPageRequested: p => screen.openPage(p)
            onMenuRequested: anchor => screen.menuRequested(anchor)
        }
        AsleepScreen {
            id: asleep
            anchors.fill: parent
            visible: screen.kind === "asleep"
            service: screen.service
            dev: screen.dev
            fontFamily: screen.fontFamily
            style: screen.style
            overlayItem: screen.overlayItem
            ground: screen.ground
            roomTop: screen.pageTop
            roomHeight: screen.pageHeight
            onMenuRequested: anchor => screen.menuRequested(anchor)
            onPairRequested: screen.openPage("pair")
        }
        PairingScreen {
            anchors.fill: parent
            visible: screen.kind === "pairing"
            service: screen.service
            fontFamily: screen.fontFamily
            style: screen.style
            overlayItem: screen.overlayItem
            ground: screen.ground
            roomTop: screen.pageTop
            roomHeight: screen.pageHeight
        }
    }

    // ---- the tile that becomes the page ---------------------------------------------------------------------------------
    MorphCard {
        id: card
        visible: screen._m !== null
        x: screen._card.x
        y: screen._card.y
        width: screen._card.w
        height: screen._card.h
        grow: screen._m ? (screen._m.dir === "open" ? clock.me : 1 - clock.me) : 1
        faceF: screen._fr.faceF
        tileW: screen._m ? screen._m.tile.w : 0
        tileH: screen._m ? screen._m.tile.h : 0
        tileRadius: screen.style.tileRadius
        raised: true
        tileColor: Theme.buttonPlateau
        groundColor: screen.ground
        radii: [screen.style.boxRadius, screen.style.boxRadius, screen.style.boxRadius, screen.style.boxRadius]
        facts: ({ glyph: screen.shownPage === "mirror" || screen.shownPage === "cast" ? "\u{F0118}" : (screen.shownPage === "files" ? "\u{F024B}" : "") })
        face: Component {
            Text {
                text: card.facts.glyph
                width: card.tileW
                height: card.tileH
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                color: Theme.textPrimary
                font.family: "Symbols Nerd Font"
                font.pixelSize: screen.style.tileGlyphSize
            }
        }
    }

    // ---- the page -------------------------------------------------------------------------------------------------------
    // laid out once at its own resting size and carried by the card while it grows: whole from its first frame, never cut
    Item {
        id: pageLayer
        visible: screen.shownPage !== ""
        x: screen._card.x
        y: screen._card.y
        width: screen._full.w
        height: screen._full.h
        scale: screen._card.s
        transformOrigin: Item.TopLeft
        opacity: screen._m ? screen._fr.arrive : 1

        Loader {
            width: pageLayer.width
            height: pageLayer.height
            active: screen.shownPage === "mirror"
            sourceComponent: Component {
                MirrorPage {
                    service: screen.service
                    dev: screen.dev
                    fontFamily: screen.fontFamily
                    style: screen.style
                    overlayItem: screen.overlayItem
                    ground: screen.ground
                    onBack: screen.goBack()
                    // Mirror or Desktop on the phone's own screen: the cast starts and its page grows out of the Mirror tile
                    onCastRequested: (mode, record) => {
                        if (screen.service && screen.dev && screen.service.castStart(screen.dev.key, mode, record))
                            screen.openPage("cast");
                    }
                }
            }
        }
        Loader {
            width: pageLayer.width
            height: pageLayer.height
            active: screen.shownPage === "cast"
            sourceComponent: Component {
                CastPage {
                    service: screen.service
                    dev: screen.dev
                    fontFamily: screen.fontFamily
                    style: screen.style
                    overlayItem: screen.overlayItem
                    ground: screen.ground
                    inputHeld: screen.castInputHeld
                    shown: screen.shown
                    turning: screen.turning
                    onBack: screen.goBack()
                }
            }
        }
        Loader {
            width: pageLayer.width
            height: pageLayer.height
            active: screen.shownPage === "files"
            sourceComponent: Component {
                FilesPage {
                    service: screen.service
                    dev: screen.dev
                    fontFamily: screen.fontFamily
                    style: screen.style
                    overlayItem: screen.overlayItem
                    ground: screen.ground
                    onBack: screen.goBack()
                }
            }
        }
        Loader {
            width: pageLayer.width
            height: pageLayer.height
            id: deviceLoader
            active: screen.shownPage === "device"
            sourceComponent: Component {
                DevicePage {
                    service: screen.service
                    dev: screen.dev
                    fontFamily: screen.fontFamily
                    style: screen.style
                    overlayItem: screen.overlayItem
                    ground: screen.ground
                    onBack: screen.goBack()
                }
            }
        }
        Loader {
            width: pageLayer.width
            height: pageLayer.height
            active: screen.shownPage === "pair"
            sourceComponent: Component {
                PairingScreen {
                    asPage: true
                    service: screen.service
                    fontFamily: screen.fontFamily
                    style: screen.style
                    overlayItem: screen.overlayItem
                    ground: screen.ground
                    roomTop: 0
                    roomHeight: screen._full.h
                    onBack: screen.goBack()
                }
            }
        }
    }

    // ---- the home indicator -------------------------------------------------------------------------------------------
    // purely the phone's: a short carved pill at the foot; on a page a click on it goes home
    Item {
        id: indicator
        visible: screen.shownPage !== "cast"
        width: screen.style.indicatorWidth
        height: screen.style.indicatorHeight
        x: Math.round((screen.width - width) / 2)
        y: screen.height - screen.style.indicatorBottom - height
        ShadowBox {
            anchors.fill: parent
            baseWidth: indicator.width
            baseHeight: indicator.height
            baseRadius: indicator.height / 2
            surfaceColor: screen.ground
            backgroundColor: Theme.panelSunk
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            bevelWidth: 0.75
            shadowWidth: 1.5
        }
        MouseArea {
            x: -(screen.style.indicatorHitWidth - indicator.width) / 2
            y: -screen.style.indicatorHitUp
            width: screen.style.indicatorHitWidth
            height: indicator.height + screen.style.indicatorHitUp + screen.style.indicatorBottom
            enabled: screen.pageOpen
            cursorShape: screen.pageOpen ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: screen.goBack()
        }
    }

    // while a page grows or goes the screens under it are deaf (`enabled: false` would be inherited by every button in them)
    MouseArea {
        anchors.fill: parent
        visible: screen.morphing
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        onWheel: wheel => wheel.accepted = false
    }
}
