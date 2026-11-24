pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../common/components"

// =============================================================================
// AuthOwner.qml -- puts the broker's current request in front of the user.
//
// One request is live at a time (`broker.current`; the rest wait behind it).
// For it the owner posts ONE sticky toast through the notification service:
//
//   { source: "auth", key: <request id>, urgency: "critical", timeoutMs: -1,
//     fixed: true, bodyComponent: AuthCard, bodyProps }
//
// critical makes it sticky and lets it through do-not-disturb and holds
// (NotifyPolicy; `auth` is in dnd.breakthroughSources), `fixed` takes away
// everything a toast lets the user do to it but answer it. The card is the
// toast's rich body: it is handed the broker, the request's id, the service and
// a token for its interaction, and the SECRET'S BUFFER, which lives here, per
// request, so the typed text survives the card being rebuilt.
//
// OVER FULLSCREEN the lane is invisible (the engine's window is on the Top
// layer and the holds keep toasts back there), so while `fullscreen` the toast
// is withdrawn and the same card is shown in an AuthPillWindow on the Overlay
// layer. A flip either way moves the request between the two and keeps the
// buffer (the OSD's _surfaceFlip is the model). While `sharing` the screen is
// being shared: the toast's body is empty and the card hides the user and the
// action (`privacy: owner`), but the request itself is still shown -- a
// password prompt that cannot be seen cannot be answered.
//
// `pillSource` is replaceable (see there).
//
// ONE PER SHELL. The shell builds a single AuthOwner on the shell's one
// NotificationService and one AuthBroker; nothing in it is per screen. The TOAST goes where the
// service's lane is (the focused screen's lane, whichever screen that owner stands on) and the
// card's keyboard rules are the card's own (AuthCard: the pointer must MOVE onto it, the first key
// latches it, Exclusive is HELD for as long as it is armed -- never a pulse). The pill's window is
// the one thing that has a screen: the host hands the owner the shell's FocusedScreen (`focusSource`,
// or binds `screenName` itself) and `pillScreen` follows the focused screen's name (a screen that
// vanishes falls back to the first one). `fullscreen` is the focused screen's too. The pill window is an Overlay-layer surface of its own, not the bar's: it
// carries a ThemeCrossfade host of its own (AuthPillWindow), which Theme waits for like the bar's.
// =============================================================================
Item {
    id: owner

    property var broker: null
    property var service: null
    // The shell's one focus tracker (a FocusedScreen, modules/common/system). With it `fullscreen` and
    // `screenName` are DEFAULTS read from it -- the focused workspace has a fullscreen window; the pill
    // goes to the focused screen -- and a host that assigns either itself (a mockup) overrides them.
    // null = both stay the host's to set.
    property var focusSource: null
    // The focused workspace has a fullscreen window (FullscreenWatch.fullscreen).
    property bool fullscreen: owner.focusSource ? owner.focusSource.fullscreen : false
    // A screencast is running (the service's hold reason is "screencast").
    property bool sharing: false
    // The screen the pill goes to ("" = the first one).
    property string screenName: owner.focusSource ? owner.focusSource.name : ""
    property string toastSource: "auth"
    property string appName: "Authentication"
    // Sizes for the card, read live (a mockup's knobs); null = its own.
    property var look: null

    readonly property var current: owner.broker ? owner.broker.current : null
    // "" nothing | "toast" | "pill"
    readonly property string where: owner._pillId !== "" ? "pill" : owner._toastId !== "" ? "toast" : ""
    // The request the pill shows ("" while none).
    readonly property string pillId: owner._pillId

    property Component bodyComponent: Component {
        AuthCard {}
    }
    // The pill's window. Loaded by URL, only when a request is shown over a
    // fullscreen window: this file never names the type, so a host that cannot
    // open a layer-shell window (a mockup, offscreen) sets it empty and stands
    // in with an AuthPill of its own.
    property url pillSource: Qt.resolvedUrl("AuthPillWindow.qml")
    readonly property var pillScreen: owner._screen()

    property string _toastId: ""
    property string _toastUid: ""
    property string _lastTitle: ""
    property string _lastBody: ""
    property string _pillId: ""
    property var _buffers: ({})
    property int _bufferSerial: 0

    function _screen() {
        const list = Quickshell.screens;
        for (let i = 0; i < list.length; i++)
            if (owner.screenName !== "" && list[i].name === owner.screenName)
                return list[i];
        return list.length > 0 ? list[0] : null;
    }

    // The typed secret of a request: made when the request first shows, dropped
    // when it is gone. Read in a binding, so `_bufferSerial` is the dependency;
    // a host that presents the card itself (a mockup) reads it here too.
    function bufferOf(id) {
        void owner._bufferSerial;
        return id !== "" && owner._buffers[id] ? owner._buffers[id] : null;
    }
    function _ensureBuffer(id) {
        if (owner._buffers[id])
            return;
        owner._buffers[id] = bufferComp.createObject(owner);
        owner._bufferSerial++;
    }
    // Dropped with their request. Asked of the broker's own list, not of its
    // `requests` property: `current` can notify first, and `requests` is then
    // still the generation before.
    function _sweepBuffers() {
        let dropped = false;
        for (const id in owner._buffers) {
            if (owner.broker && owner.broker.record(id) !== null)
                continue;
            owner._buffers[id].destroy();
            delete owner._buffers[id];
            dropped = true;
        }
        if (dropped)
            owner._bufferSerial++;
    }
    Component {
        id: bufferComp
        PasswordBuffer {}
    }

    function _toastBody(rec) {
        return owner.sharing ? "" : rec.body;
    }
    function _postToast(rec) {
        owner._ensureBuffer(rec.id);
        owner._toastUid = owner.service.post({
            source: owner.toastSource,
            key: rec.id,
            appName: owner.appName,
            title: rec.title,
            body: owner._toastBody(rec),
            urgency: "critical",
            timeoutMs: -1,
            fixed: true,
            bodyComponent: owner.bodyComponent,
            bodyProps: {
                broker: owner.broker,
                requestId: rec.id,
                service: owner.service,
                token: "auth-toast:" + rec.id,
                buffer: owner._buffers[rec.id],
                privacy: owner,
                look: owner.look
            }
        });
        owner._toastId = rec.id;
        owner._lastTitle = rec.title;
        owner._lastBody = owner._toastBody(rec);
    }
    function _withdrawToast() {
        if (owner._toastId === "")
            return;
        const id = owner._toastId;
        owner._toastId = "";
        owner._toastUid = "";
        if (owner.service)
            owner.service.withdraw(owner.toastSource, id);
    }

    // Keep what is shown equal to what is asked for.
    function _sync() {
        const rec = owner.current;
        const id = rec ? rec.id : "";
        const toastWanted = id !== "" && !owner.fullscreen && owner.service !== null;
        const pillWanted = id !== "" && owner.fullscreen;
        if (owner._toastId !== "" && (!toastWanted || owner._toastId !== id))
            owner._withdrawToast();
        if (toastWanted) {
            if (owner._toastId !== id)
                owner._postToast(rec);
            else if (rec.title !== owner._lastTitle || owner._toastBody(rec) !== owner._lastBody) {
                owner._lastTitle = rec.title;
                owner._lastBody = owner._toastBody(rec);
                owner.service.update(owner._toastUid, { title: rec.title, body: owner._lastBody });
            }
        }
        if (pillWanted)
            owner._ensureBuffer(id);
        owner._pillId = pillWanted ? id : "";
        owner._sweepBuffers();
    }

    Connections {
        target: owner.broker
        ignoreUnknownSignals: true
        function onOpened() { owner._sync(); }
        function onChanged() { owner._sync(); }
        function onClosed() { owner._sync(); }
    }
    onCurrentChanged: owner._sync()
    onFullscreenChanged: owner._sync()
    onSharingChanged: owner._sync()
    onServiceChanged: owner._sync()
    Component.onCompleted: owner._sync()
    Component.onDestruction: owner._withdrawToast()

    LazyLoader {
        id: pillLoader
        active: owner._pillId !== "" && owner.pillSource.toString() !== ""
        source: owner.pillSource
    }
    Binding {
        target: pillLoader.item
        property: "host"
        value: owner
        when: pillLoader.item !== null
    }
}
