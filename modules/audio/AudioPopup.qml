pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "data/AudioModel.js" as Model
import "../common/scroll"

// =============================================================================
// AudioPopup.qml -- the audio popup's drop-in: pavucontrol's five tabs in the shell's material, every feature of its window (docs/audio.md
// has the analysis of its source, feature by feature), and four things it never had: lines from streams to where they really go, a level glow in the rows,
// a marker that travels when a stream moves or the default changes, a test tone per output.
//
//   service    AudioService (or AudioMock). All it acts through: every verb, every row.
//   parity     VolumeParity: a wheel over a slider is one step of the shell's one volume step.
//   section    "playback" | "recording" | "sinks" | "sources" | "cards"; the host keeps it between opens.
//
// THE ONE WHEEL READER (the network popup's rule). One MouseArea over the whole popup reads every wheel and accepts it, so nothing below (GrooveSlider's own 5 % wheel, a Flickable)
// is a second reader. A gesture picks its axis, and what it is for, on its first event, until the fingers lift: sideways steps the tab; up and down scrolls the list.
//
// A SCROLL NEVER REACHES A VOLUME. Up and down is a slider's only when the hand put it there: the pointer MOVED onto the slider and came to rest on it (`sliderRestMs`), and
// nothing scrolled since. A slider that slid under a still pointer has not been chosen by anybody, and neither has one a moving pointer happens to cross. The percent
// takes the accent when that is so: the one sign that the wheel is the slider's. A list with nothing to scroll has no such doubt, and a slider takes the wheel at once.
//
// THE HYBRID ROOM (Playback, Recording). The devices' box always has the room its names need and the list has what is left, wide, while nothing sounds; when a stream sounds
// the gap between the boxes opens for the waves and the list gives the room (`gap`, one number on one clock), and it closes again a while after the last of the sound has
// landed, so a pause between two songs moves nothing.
//
// ONE LAYOUT, by the feedback: "one on one clone".
//
// THE BEAT. Every meter and every line moves on one 30 Hz timer, which runs only while there is a meter to read or sound on a line, and draws only when something moved
// (Figures change together; a progress that moves on screen is a whole-window frame per step). Silence costs no frame. It holds still under a theme crossfade: a picture over
// something moving is two of it.
// =============================================================================
Item {
    id: root

    property var service: null
    property var parity: null
    property string fontFamily: "Inter"
    property real renderScale: 1
    property string section: "playback"
    property AudioStyle style: AudioStyle {}
    readonly property AudioGlyphs glyphs: AudioGlyphs {}

    // ---- what floats ---------------------------------------------------------------------------------------------------------------
    readonly property alias overlayItem: overlayLayer

    // ---- the engine's contract ------------------------------------------------------------------------------------------------------
    readonly property bool swipeGestureActive: root._gestureActive
    readonly property real gestureHoldWidth: root.width
    readonly property real gestureHoldHeight: root.height
    // The keyboard is asked for only while a name is being typed.
    property bool grabKeyboard: true
    property bool _focusPulse: false
    property string renaming: ""
    readonly property string keyboardFocusRequest: root.renaming === "" ? "none" : root._focusPulse ? "exclusive" : "onDemand"
    function pulseKeyboard(): void {
        if (!root.grabKeyboard)
            return;
        root._focusPulse = true;
        focusPulse.restart();
    }
    Timer {
        id: focusPulse
        interval: 120
        onTriggered: root._focusPulse = false
    }
    function beginRename(key: string): void {
        root.renaming = key;
        root.pulseKeyboard();
    }
    function endRename(): void {
        root.renaming = "";
    }

    // ---- sizes -----------------------------------------------------------------------------------------------------------------------
    // Laid out at the size it ASKED for, and the opening box reveals it: at the box's own size every row, figure and ball would be re-laid out on every frame of an open and a close
    // (a ball carried along its row is a ball in flight, and a flight repaints with its shadow: 16 ms of polish a frame for seconds after the popup has landed).
    readonly property real _inner: root.implicitWidth - 2 * root.style.padding
    readonly property real _listTop: root.style.padding + root.style.tabsHeight + root.style.padding + banner.height + (banner.height > 0 ? root.style.padding : 0)
    readonly property real _footTop: root.implicitHeight - root.style.padding - root.style.footHeight

    implicitWidth: root.style.popupWidth
    implicitHeight: Math.ceil(root.style.padding * 4 + root.style.tabsHeight + root.style.listHeight + root.style.footHeight)

    // ---- the tabs --------------------------------------------------------------------------------------------------------------------
    readonly property var sections: ["playback", "recording", "sinks", "sources", "cards"]
    onSectionChanged: {
        if (tabs.currentTab !== root.section)
            tabs.currentTab = root.section;
        root.closeMenu();
        root.renaming = "";
        root._disarm();
    }
    TabSelector {
        id: tabs
        objectName: "tabs"
        x: root.style.padding
        y: root.style.padding
        width: root._inner
        height: root.style.tabsHeight
        fontFamily: root.fontFamily
        fontPixelSize: 12
        slotPaddingAlong: 8
        tabs: [
            { id: "playback", label: "Playback" }, { id: "recording", label: "Recording" }, { id: "sinks", label: "Outputs" },
            { id: "sources", label: "Inputs" }, { id: "cards", label: "Configuration" }
        ]
        swipeSelfHandled: false
        onTabChanged: id => {
            root.section = id;
        }
    }
    // A click writes the selector's own currentTab, which would cut a plain binding for good: a speaker's click switching the tab would no longer reach the pill.
    Binding {
        target: tabs
        property: "currentTab"
        value: root.section
    }

    // ---- a backend that is not well: a state, in words, with what it is made of ---------------------------------------------------------
    readonly property bool _lostBinding: !!root.service && root.service.health === "ok" && !root.service.bindingUp
    readonly property bool _unwell: !!root.service && (root._lostBinding || root.service.health === "hung" || root.service.health === "dead" || root.service.health === "missing" || root.service.health === "error")
    readonly property string _bannerTitle: {
        if (!root.service)
            return "";
        if (root._lostBinding)
            return "The shell lost its connection to PipeWire";
        switch (root.service.health) {
        case "hung":
            return "The sound server is not answering";
        case "dead":
            return "The sound server is not running";
        case "missing":
            return "pactl is not installed";
        case "error":
            return "pactl failed";
        }
        return "";
    }
    Item {
        id: banner
        objectName: "banner"
        x: root.style.padding
        y: root.style.padding + root.style.tabsHeight + root.style.padding
        width: root._inner
        height: root._unwell ? bannerText.implicitHeight + 2 * 8 : 0
        clip: true
        opacity: root._unwell ? 1 : 0
        Behavior on height {
            NumberAnimation {
                duration: root.style.resizeMs
                easing.type: Easing.OutCubic
            }
        }
        Behavior on opacity {
            NumberAnimation {
                duration: root.style.fadeMs
            }
        }
        ShadowBox {
            anchors.fill: parent
            baseRadius: 10
            surfaceColor: Theme.surface
            backgroundColor: Theme.errorTint
            bevelColor: Theme.bevel
            shadowColor: Theme.error
            bevelWidth: 1
            shadowWidth: 3
        }
        Column {
            id: bannerText
            x: 12
            y: 8
            width: parent.width - 24
            Text {
                width: parent.width
                text: root._bannerTitle
                font.family: root.fontFamily
                font.pixelSize: root.style.titleSize
                font.bold: true
                color: Theme.textPrimary
            }
            Text {
                objectName: "bannerReason"
                width: parent.width
                wrapMode: Text.WordWrap
                text: !root.service ? "" : root._lostBinding ? "PipeWire restarted. Everything here still works through pactl, but the meters are off and the bar's volume is dead until the shell restarts."
                    : root.service.healthDiag !== "" ? root.service.healthDiag : root.service.healthReason
                font.family: root.fontFamily
                font.pixelSize: root.style.noteSize
                color: Theme.textMuted
            }
        }
    }

    // ---- the lists: one per tab, built the first time their tab shows -----------------------------------------------------------------
    readonly property var _filters: root.service ? root.service.settings.filters || ({}) : ({})
    function filterOf(sec: string): int {
        const f = root._filters[sec];
        return f === undefined ? Model.FILTER_DEFAULT[sec] : f;
    }
    function _keysFor(sec: string): var {
        if (!root.service)
            return [];
        const r = root.service.rows;
        if (sec === "cards")
            return r.cards.map(x => x.key);
        const a = Model.applyFilter(sec, r[sec], root.filterOf(sec)).map(x => x.key);
        if (sec === "playback" && root.service.roleRow)
            a.unshift(root.service.roleRow.key);
        return a;
    }
    component Tab: Item {
        id: tab
        required property string sec
        required property string emptyText
        readonly property bool current: root.section === tab.sec
        property bool seen: tab.current
        readonly property alias list: listLoader.item
        readonly property bool hasBay: (tab.sec === "playback" || tab.sec === "recording") && root.style.linesEnabled
        // THE GAP: one number, and everything in the tab reads it in the same frame. A tab that has just come up is not a move: its first level lands inside the entrance.
        readonly property AudioPatchBay bay: bayLoader.item as AudioPatchBay
        readonly property real _gapWant: !tab.bay || tab.bay.lineCount === 0 ? root.style.gapNone : tab.bay.sounding ? root.style.gapSounding : root.style.gapIdle
        property real gap: tab._gapWant
        property bool _eased: false
        Behavior on gap {
            enabled: tab._eased
            NumberAnimation {
                duration: root.style.resizeMs
                easing.type: Easing.OutCubic
            }
        }
        Timer {
            interval: 400
            running: tab.current
            onTriggered: tab._eased = true
        }
        onCurrentChanged: {
            if (tab.current) {
                tab.seen = true;
                const l = listLoader.item as AudioList;
                if (l)
                    l.enter();
            } else {
                tab._eased = false;
            }
        }
        readonly property var keys: {
            void root.service.rowsSerial;
            void root._filters;
            return root._keysFor(tab.sec);
        }
        x: root.style.padding
        y: root._listTop
        width: root._inner
        height: root._footTop - root.style.padding - root._listTop
        visible: tab.current
        Loader {
            id: listLoader
            active: tab.seen
            width: tab.hasBay ? Math.round(tab.width - root.style.socketColumn - tab.gap) : tab.width
            height: tab.height
            sourceComponent: AudioList {
                section: tab.sec
                keys: tab.keys
                service: root.service
                parity: root.parity
                popup: root
                style: root.style
                fontFamily: root.fontFamily
                shown: tab.current
                metersOn: root.service.settings.meters !== false
                renderScale: root.renderScale
                emptyText: tab.emptyText
                armed: tab.current ? root._armed : null
                objectName: "list:" + tab.sec
            }
        }
        Loader {
            id: socketsLoader
            active: tab.seen && tab.hasBay
            x: tab.width - root.style.socketColumn
            width: root.style.socketColumn
            height: tab.height
            sourceComponent: AudioSockets {
                section: tab.sec
                service: root.service
                style: root.style
                fontFamily: root.fontFamily
                glyphs: root.glyphs
                objectName: "sockets:" + tab.sec
            }
        }
        Loader {
            id: bayLoader
            active: tab.seen && tab.hasBay
            anchors.fill: parent
            sourceComponent: AudioPatchBay {
                section: tab.sec
                list: listLoader.item
                sockets: socketsLoader.item
                socketsX: socketsLoader.x
                service: root.service
                style: root.style
                shown: tab.current
                objectName: "bay:" + tab.sec
            }
        }
        function beat(): real {
            const l = listLoader.item as AudioList;
            const top = l ? l.beat() : 0;
            if (tab.bay)
                tab.bay.beat();
            return top;
        }
    }
    Tab {
        id: playbackTab
        sec: "playback"
        emptyText: "Nothing playing"
    }
    Tab {
        id: recordingTab
        sec: "recording"
        emptyText: "Nothing recording"
    }
    Tab {
        id: sinksTab
        sec: "sinks"
        emptyText: "No output devices"
    }
    Tab {
        id: sourcesTab
        sec: "sources"
        emptyText: "No input devices"
    }
    Tab {
        id: cardsTab
        sec: "cards"
        emptyText: "No sound cards"
    }
    readonly property var _tabs: [playbackTab, recordingTab, sinksTab, sourcesTab, cardsTab]
    readonly property var currentList: {
        const t = root._tabs[root.sections.indexOf(root.section)];
        return t ? t.list : null;
    }

    // ---- the beat -----------------------------------------------------------------------------------------------------------------------
    readonly property var _shownTab: root._tabs[root.sections.indexOf(root.section)]
    // Something to read, or something still on its way down: with neither there is no beat at all.
    readonly property bool _beatWanted: {
        const t = root._shownTab, l = t ? t.list : null;
        return !!l && l.meterCount > 0 || !!t && !!t.bay && t.bay.flowing;
    }
    Timer {
        id: beatTimer
        objectName: "beat"
        interval: root.style.levelBeatMs
        repeat: true
        running: root.visible && !!root.service && root.service.settings.meters !== false && root.section !== "cards" && root.style.glowEnabled && !Theme.crossfading && root._beatWanted
        onTriggered: {
            const t = root._tabs[root.sections.indexOf(root.section)];
            if (t)
                t.beat();
        }
    }

    // ---- the foot --------------------------------------------------------------------------------------------------------------------
    readonly property var _notice: root.service ? root.service.notice : null
    // The fact behind "I selected headphones and it plays through my speakers": the device the user chose is not here.
    readonly property string _fallback: {
        if (!root.service)
            return "";
        const sink = root.section === "playback" || root.section === "sinks";
        const src = root.section === "recording" || root.section === "sources";
        const want = sink ? root.service.configuredSink : src ? root.service.configuredSource : "";
        const have = sink ? root.service.defaultSinkName : root.service.defaultSourceName;
        if (want === "" || have === "" || want === have)
            return "";
        void root.service.rowsSerial;
        const d = root.service.rowOf("d:" + (sink ? "sink:" : "source:") + have);
        return "Your chosen device, " + Model.prettyNode(want) + ", is not here. In use: " + (d ? d.shortName : have) + ".";
    }
    readonly property string _footText: root._notice ? root._notice.text : root._fallback

    Item {
        id: foot
        objectName: "foot"
        x: root.style.padding
        y: root._footTop
        width: root._inner
        height: root.style.footHeight

        AudioChoice {
            id: filterChoice
            objectName: "filterChoice"
            anchors.verticalCenter: parent.verticalCenter
            visible: root.section !== "cards"
            label: "Show"
            value: visible ? Model.FILTERS[root.section][root.filterOf(root.section)] : ""
            maxWidth: 220
            ground: Theme.surface
            overlayItem: overlayLayer
            fontFamily: root.fontFamily
            onPicked: from => {
                const sec = root.section;
                const p = from.mapToItem(overlayLayer, 0, -4);
                const names = Model.FILTERS[sec];
                root.openMenu(p.x, p.y - names.length * 26 - 12, names.map((n, i) => ({ id: String(i), label: n, check: "radio", checked: i === root.filterOf(sec) })), id => root.service.setFilter(sec, Number(id)), 210);
            }
        }
        Row {
            id: cardOptions
            objectName: "cardOptions"
            anchors.verticalCenter: parent.verticalCenter
            visible: root.section === "cards"
            spacing: 18
            component Option: Row {
                id: opt
                required property string text
                required property string settingKey
                property bool fallback: false
                spacing: 6
                GrooveToggle {
                    id: optToggle
                    objectName: "toggle:" + opt.settingKey
                    anchors.verticalCenter: parent.verticalCenter
                    trackWidth: 28
                    surfaceColor: Theme.surface
                    checked: root.service ? (root.service.settings[opt.settingKey] === undefined ? opt.fallback : root.service.settings[opt.settingKey] === true) : false
                    onToggled: c => root.service.setSetting(opt.settingKey, c)
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: opt.text
                    font.family: root.fontFamily
                    font.pixelSize: root.style.subtitleSize
                    color: Theme.textMuted
                }
            }
            Option {
                text: "Show volume meters"
                settingKey: "meters"
                fallback: true
            }
            Option {
                text: "Hide unavailable card profiles"
                settingKey: "hideUnavailable"
            }
            Option {
                text: "Feedback sound"
                settingKey: "feedback"
            }
        }
        Text {
            id: footLine
            objectName: "footLine"
            x: filterChoice.visible ? filterChoice.width + 12 : (cardOptions.visible ? cardOptions.width + 12 : 0)
            width: (noticeButton.visible ? noticeButton.x - 8 : parent.width) - x
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignRight
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            text: root._footText
            font.family: root.fontFamily
            font.pixelSize: root.style.noteSize
            lineHeight: 0.9
            color: Theme.textMuted
        }
        RaisedButton {
            id: noticeButton
            objectName: "noticeAction"
            anchors.verticalCenter: parent.verticalCenter
            x: parent.width - width
            visible: !!root._notice && root._notice.action !== undefined
            text: visible ? root._notice.label : ""
            height: 26
            fontFamily: root.fontFamily
            fontPixelSize: 11
            surfaceColor: Theme.surface
            plateauColor: Theme.buttonPlateau
            plateauHoverColor: Theme.buttonPlateauHover
            bevelColor: Theme.bevel
            shadowColor: Theme.buttonShadow
            onClicked: root.service.runNoticeAction()
        }
    }

    // ---- the one menu -------------------------------------------------------------------------------------------------------------------
    property var _onPick: null
    function openMenu(x: real, y: real, rows: var, onPick: var, w: real): void {
        root._onPick = onPick;
        menu.menuWidth = w > 0 ? w : 200;
        menu.rows = rows;
        menu.openAt(x, y);
    }
    function closeMenu(): void {
        menu.open = false;
    }

    // ---- the one wheel reader -------------------------------------------------------------------------------------------------------
    property bool _gestureActive: false
    property string _axis: ""
    property var _gestureSlider: null
    property int gestureIdleEndMs: 260
    readonly property real _pixelToAngle: 2.5

    WheelStepper {
        id: stepper
        notchThreshold: root.parity ? root.parity.notchUnits : 120
        pixelThreshold: root.parity ? root.parity.touchpadUnits : 100
        stepCooldownMs: 0
    }
    function _endGesture(): void {
        idle.stop();
        tabs.applySwipe(0);
        if (root._gestureSlider && root._axis === "y")
            root._gestureSlider.row.gestureEnded();
        stepper.end();
        root._gestureActive = false;
        root._axis = "";
        root._gestureSlider = null;
    }
    Timer {
        id: idle
        interval: root.gestureIdleEndMs
        onTriggered: root._endGesture()
    }
    // ---- the slider the pointer rests on ------------------------------------------------------------------------------------------------
    property var _armed: null
    property point _lastPoint: Qt.point(-1, -1)
    function _sliderUnderPointer(): var {
        const l = root.currentList;
        if (!l)
            return null;
        const p = l.mapFromItem(root, root._lastPoint.x, root._lastPoint.y);
        return l.sliderAt(p.x, p.y);
    }
    // A RESTING POINTER'S POINT IS RE-DELIVERED EVERY FRAME: only a point that changed is the hand. On the slider it is armed on, a hand that shifts keeps it.
    function _pointerAt(p: point): void {
        if (p.x === root._lastPoint.x && p.y === root._lastPoint.y)
            return;
        root._lastPoint = p;
        if (root._armed) {
            const s = root._sliderUnderPointer();
            if (s && s.key === root._armed.key && s.channel === root._armed.channel)
                return;
            root._armed = null;
        }
        rest.restart();
    }
    function _disarm(): void {
        rest.stop();
        root._armed = null;
    }
    Timer {
        id: rest
        interval: root.style.sliderRestMs
        onTriggered: root._armed = root._sliderUnderPointer()
    }
    HoverHandler {
        onPointChanged: root._pointerAt(point.position)
        onHoveredChanged: {
            if (!hovered)
                root._disarm();
        }
    }
    // What moved under the pointer was not chosen by the pointer.
    Connections {
        target: root.currentList
        function onScrolled() {
            root._disarm();
        }
    }

    // One event (WheelHub's) in the frame of `reader`; public so a probe can feed a touchpad (a QtTest wheel carries no pixel delta).
    function readWheel(ev: var): void {
        const x = ev.x, y = ev.y, angle = ev.angleDelta, pixel = ev.pixelDelta, phase = ev.phase, inverted = ev.inverted;
        // a mouse: a sideways notch is a tab, and so is an upright one over the tab row itself (this reader is above it and keeps every wheel)
        if (ev.device === "wheel" && (angle.x !== 0 || tabs.contains(tabs.mapFromItem(reader, x, y)))) {
            tabs.applySteps(ev.steps);
            return;
        }
        const dx = angle.x !== 0 ? angle.x : pixel.x * root._pixelToAngle;
        const dy = angle.y !== 0 ? angle.y : pixel.y * root._pixelToAngle;
        const l = root.currentList;
        if (dx === 0 && dy === 0) {
            if (l && (phase === Qt.ScrollBegin || (root._axis === "y" && !root._gestureSlider)))
                l.feedWheel(0, 0, phase);
            root._endGesture();
            return;
        }
        idle.restart();
        if (!root._gestureActive) {
            root._gestureActive = true;
            root._axis = "";
            // A slider the pointer rests on, or any slider of a list with nothing to scroll: this gesture is that slider's.
            if (l && !l.scrolling) {
                if (root._armed)
                    root._gestureSlider = root._armed;
                else if (!l.canScroll) {
                    const p = l.mapFromItem(root, x, y);
                    root._gestureSlider = l.sliderAt(p.x, p.y);
                }
            }
        }
        if (root._axis === "") {
            if (Math.abs(dx) > Math.abs(dy) * 1.2)
                root._axis = "x";
            else if (Math.abs(dy) > Math.abs(dx) * 1.2)
                root._axis = "y";
        }
        if (root._axis === "x" && dx !== 0)
            tabs.applySwipe(dx);
        if (root._axis !== "y" || dy === 0)
            return;
        const gs = root._gestureSlider;
        if (gs) {
            const nat = root.parity ? root.parity.naturalScroll : null;
            const flipped = inverted || (!!nat && (pixel.y !== 0 ? nat.touchpad : nat.mouse));
            const steps = stepper.feed(dy * (flipped ? -1 : 1), pixel.y !== 0);
            if (steps !== 0)
                gs.row.wheelStep(steps, gs.channel);
            return;
        }
        if (l)
            l.feedWheel(pixel.y, angle.y, phase);
    }
    WheelArea {
        id: reader
        anchors.fill: parent
        z: 200
        turned: wheel => {
            root.readWheel(wheel);
            wheel.accepted = true;
        }
    }

    Item {
        id: overlayLayer
        anchors.fill: parent
        z: 1000
        FloatingMenu {
            id: menu
            objectName: "menu"
            overlayItem: overlayLayer
            fontFamily: root.fontFamily
            onTriggered: id => {
                const f = root._onPick;
                root._onPick = null;
                if (f)
                    f(id);
            }
        }
    }
}
