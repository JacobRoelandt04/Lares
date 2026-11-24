//@ pragma IconTheme Papirus
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/mockup"
import "modules/common/theme"
import "modules/common/components"
import "modules/bar/gooey"
import "modules/notifications"
import "modules/notifications/parts"
import "modules/notifications/data"
import "modules/auth"
import "modules/auth/data"

// =============================================================================
// mockups/auth.qml -- the auth toast on the REAL bar engine.
//
// Run it through tools/dev/auth_render.sh (`run`, `smoke`, `grab`): a private
// config / state dir, offscreen for the scripted ones. The notification service
// runs in-process and owns no bus name (`serverEnabled: false`), so nothing here
// touches mako or the user's history.
//
// What is real: GooeyEngine + NotificationsBarOwner (the lane), the
// NotificationService, AuthBroker, PolkitSource, AuthOwner and AuthCard. What is
// faked: polkit -- a stand-in AuthFlow (the real one's properties, signals and
// orders; PolkitSource takes it as `fakeAgent`) that answers a password after
// `answerDelay` and fails or accepts it, so every timeline below runs the code
// the shell runs. The pill (AuthPillWindow, a layer-shell window, which cannot
// open offscreen) is stood in for by an AuthPill item over the stage; the owner
// is told `pillSource: ""` so it opens no window.
//
// KEYBOARD. The stage is an ordinary window, so there is no layer-shell
// keyboard grant to bind: the card takes ACTIVE FOCUS when it arms (the pointer
// MOVED onto it) and the first key latches it, which is the part of the rule a
// plain window can show. The real grant (`keyboardRequest` -> Exclusive, the
// catch rect) is read off the service in the Run tab ("interaction").
//
// Env: AUTH_STATE=scan|typed|checking|failed|ok (jump there 300 ms after load)
//      AUTH_PLAY=<n> (play timeline n, 0-based, 300 ms after load)
//      HOST=lane|pill (pill = a fullscreen window: the card over it)
//      HOWDY=native|off   STAGE_GRAB=<png> GRAB_MS=<ms>  ZOOM
// =============================================================================
MockupWindow {
    id: win

    moduleId: "auth"
    title: "Auth"
    stageLabel: "A section of the screen at 1:1 -- the top bar and the auth toast (" + (win.fullscreenOn ? "over a fullscreen window: the pill" : "in the toast lane") + ")"
    content: scene
    target: cardLook
    stageColor: "#1F2229"
    zoom: Number(Quickshell.env("ZOOM") || 1)
    panelWidth: 460
    fitContent: true

    readonly property string envState: Quickshell.env("AUTH_STATE") || ""
    readonly property string envHost: Quickshell.env("HOST") || "lane"
    property bool fullscreenOn: win.envHost === "pill"
    property bool sharingOn: false
    property string howdyMode: Quickshell.env("HOWDY") || "native"

    lists: ({
            cardParams: win.cardParams,
            pillParams: win.pillParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Card",
            subs: [
                { name: "Field", lists: ["cardParams"], groups: ["Field", "Status"] },
                { name: "Text, buttons", lists: ["cardParams"], groups: ["Text", "Buttons"] }
            ]
        },
        {
            name: "Pill",
            lists: ["pillParams"]
        }
    ]

    // ---- the stage's actors -------------------------------------------------------
    NotificationService {
        id: svc
        serverEnabled: false
        liveSignals: false
    }
    BoundaryClock {
        id: clock
        active: notifOwner.laneMine
    }
    NotificationStyle {
        id: nstyle
    }

    AuthBroker {
        id: broker
        registerOnBus: false
        okHoldMs: win.envState === "ok" ? 600000 : 700
    }
    QtObject {
        id: fakeAgent
        property var flow: null
    }
    PolkitSource {
        id: polkit
        broker: broker
        fakeAgent: fakeAgent
        howdyMode: win.howdyMode
        faceTimeoutMs: 2500
        faceMarginMs: 500
    }

    // The sizes every card reads (AuthCard.look): the panel writes into it.
    QtObject {
        id: cardLook
        property real titleSize: 16
        property real bodySize: 12
        property real detailSize: 10
        property real gap: 8
        property real fieldHeight: 40
        property real fieldRadius: 20
        property real dotSize: 8
        property real dotGap: 5
        property real glyphSize: 24
        property real statusHeight: 20
        property real statusTextSize: 11
        property real buttonHeight: 30
        property real buttonGap: 8
        property real buttonRadius: 7
        property real pillFieldHeight: 44
        property real pillFieldRadius: 22
        property real pillDotSize: 9
        property real pillGlyphSize: 28
    }

    // A stand-in AuthFlow: what Quickshell's has, in the real flow's orders.
    Component {
        id: flowComp
        QtObject {
            id: fl
            property string message: "Authentication is required to run /usr/bin/pacman as root"
            property string iconName: "dialog-password"
            property string actionId: "org.archlinux.pkexec.pacman"
            property var identities: [{ displayName: "user" }]
            property var selectedIdentity: fl.identities[0]
            property bool isResponseRequired: false
            property string inputPrompt: ""
            property bool responseVisible: false
            property string supplementaryMessage: ""
            property bool supplementaryIsError: false
            property bool isCompleted: false
            property bool isSuccessful: false
            property bool isCancelled: false
            property bool failed: false
            // the mockup's: the right password, how long the stack takes, and
            // whether it answers at all (false: "checking" for good)
            property string password: "hunter2"
            property int answerDelay: 800
            property bool answers: true
            property var submits: []
            signal authenticationSucceeded()
            signal authenticationFailed()
            signal authenticationRequestCancelled()
            function submit(v) {
                fl.submits = fl.submits.concat([v]);
                fl.isResponseRequired = false;
                if (!fl.answers)
                    return;
                win.later(fl.answerDelay, () => {
                    if (fl.isCompleted)
                        return;
                    if (v === fl.password) {
                        fl.succeed();
                    } else {
                        fl.failed = true;
                        fl.authenticationFailed();
                        // the next session starts itself (same cookie)
                        win.later(150, () => fl.prompt());
                    }
                });
            }
            function cancelAuthenticationRequest() {
                fl.isCancelled = true;
                fl.isCompleted = true;
                fl.authenticationRequestCancelled();
            }
            function prompt() {
                if (fl.isCompleted)
                    return;
                fl.inputPrompt = "Password: ";
                fl.isResponseRequired = true;
            }
            function say(text, isError) {
                fl.supplementaryIsError = !!isError;
                fl.supplementaryMessage = text;
            }
            function succeed() {
                fl.isCompleted = true;
                fl.isSuccessful = true;
                fl.authenticationSucceeded();
            }
        }
    }

    Component {
        id: timerComp
        Timer {
            repeat: false
        }
    }
    function later(ms, fn) {
        const t = timerComp.createObject(win, { interval: Math.max(1, ms) });
        t.triggered.connect(() => {
            fn();
            t.destroy();
        });
        t.start();
    }

    // =====================================================================
    //  THE STAGE
    // =====================================================================
    Item {
        id: scene
        implicitWidth: 900
        implicitHeight: 520

        Rectangle {
            anchors.fill: parent
            color: win.stageColor
        }

        GooeyEngine {
            id: engine
            anchors.fill: parent
            renderScale: win.stage ? win.stage.zoom : 1
            surfaceColor: Theme.surface
            barsList: [topBar]

            GooeyBar {
                id: topBar
                engine: engine
                barId: "top"
                edge: "top"
                rawPos: 0
                rawLen: engine.w

                NotificationsBarButton {
                    id: bell
                    x: Math.round(780 - width / 2)
                    y: Math.round((topBar.height - height) / 2)
                    owner: notifOwner
                }
            }
        }

        NotificationsBarOwner {
            id: notifOwner
            engine: engine
            bar: topBar
            barId: "top"
            anchorItem: bell
            screenName: svc.laneScreen
            service: svc
            clock: clock
            style: nstyle
        }

        // The pill over a fullscreen window (AuthPillWindow's content, on the stage).
        Loader {
            id: pillHost
            active: authOwner.where === "pill"
            x: Math.round((scene.width - (item ? item.width : 0)) / 2)
            y: 56
            sourceComponent: AuthPill {
                broker: broker
                requestId: authOwner.pillId
                buffer: authOwner.bufferOf(authOwner.pillId)
                privacy: authOwner
                look: cardLook
            }
        }
    }

    AuthOwner {
        id: authOwner
        broker: broker
        service: svc
        fullscreen: win.fullscreenOn
        sharing: win.sharingOn
        look: cardLook
        pillSource: ""
    }

    // =====================================================================
    //  TIMELINES
    // =====================================================================
    function recNow() {
        return broker.current;
    }
    function bufNow() {
        const r = broker.current;
        return r ? authOwner.bufferOf(r.id) : null;
    }
    function typeText(text) {
        const b = win.bufNow();
        if (!b)
            return;
        for (let i = 0; i < text.length; i++)
            b.handleKey({ key: 0, text: text[i], modifiers: 0 });
    }
    // What Enter does in the card, without the card.
    function enter() {
        const r = broker.current;
        const b = win.bufNow();
        if (r && b && b.length > 0)
            broker.submit(r.id, b.take());
    }
    function newFlow(mode, opts) {
        win.howdyMode = mode;
        const f = flowComp.createObject(win, opts || {});
        fakeAgent.flow = f;
        return f;
    }
    // Everything back to rest.
    function reset() {
        steps.stop();
        win.fullscreenOn = win.envHost === "pill";
        const f = fakeAgent.flow;
        fakeAgent.flow = null;
        // a flow of the last run still has timers pending: let them find it done
        if (f)
            f.isCompleted = true;
        const ids = broker.requests.map(r => r.id);
        for (let i = 0; i < ids.length; i++)
            broker.finish(ids[i], "cancelled");
    }
    function openAskpass(title, body, pw) {
        let id = "";
        id = broker.open({
            source: "askpass", title: title, body: body, detail: "/usr/bin/sudo", user: "user",
            prompt: "Password:", face: "none"
        }, {
            respond: secret => win.later(600, () => {
                const r = broker.record(id);
                if (!r)
                    return;
                if (secret === pw)
                    broker.finish(id, "ok");
                else
                    broker.update(id, { state: "failed", failCount: r.failCount + 1, prompt: "Password:" });
            }),
            cancel: () => broker.finish(id, "cancelled")
        });
        return id;
    }

    property var _steps: []
    property int _stepAt: 0
    property real _t0: 0
    Timer {
        id: steps
        repeat: false
        onTriggered: {
            const s = win._steps[win._stepAt];
            win._stepAt++;
            s[1]();
            win._arm();
        }
    }
    function _arm() {
        if (win._stepAt >= win._steps.length)
            return;
        steps.interval = Math.max(1, win._steps[win._stepAt][0] - (Date.now() - win._t0));
        steps.restart();
    }
    function play(list) {
        win.reset();
        win._steps = list;
        win._stepAt = 0;
        win._t0 = Date.now();
        win._arm();
    }

    readonly property var timelines: [
        { name: "native: the face wins", tip: "howdy workaround = native: the prompt is open from the first moment, the face is scanned in parallel and a win closes the toast with no answer given. Watch the glyph sweep, then settle ok, then the card leave.",
          steps: () => [
            [0, () => win.newFlow("native")],
            [10, () => fakeAgent.flow.prompt()],
            [1800, () => fakeAgent.flow.say("Identified face as user", false)],
            [2000, () => fakeAgent.flow.succeed()]
        ] },
        { name: "native: the password", tip: "Native, the face never matches: a password is typed key by key (dots), answered with Enter and accepted. The prompt is open, so nothing is held.",
          steps: () => [
            [0, () => win.newFlow("native")],
            [10, () => fakeAgent.flow.prompt()],
            [900, () => win.typeText("hunt")],
            [1300, () => win.typeText("er2")],
            [2000, () => win.enter()]
        ] },
        { name: "off: held Enter", tip: "howdy workaround = off: the prompt opens only after the scan. Enter during the scan is held (checking, no prompt yet), and answered the moment 'Failure, timeout reached' lets the prompt open.",
          steps: () => [
            [0, () => win.newFlow("off")],
            [500, () => win.typeText("hunter2")],
            [1300, () => win.enter()],
            [2600, () => fakeAgent.flow.say("Failure, timeout reached", true)],
            [2650, () => fakeAgent.flow.prompt()]
        ] },
        { name: "wrong, then right", tip: "A wrong password: the field's inset flushes to the error colour and eases back, 'Wrong password' stands under it until the next key; the session restarts and the right one is accepted.",
          steps: () => [
            [0, () => win.newFlow("native")],
            [10, () => fakeAgent.flow.prompt()],
            [700, () => win.typeText("letmein")],
            [1400, () => win.enter()],
            [3200, () => win.typeText("hunter2")],
            [3900, () => win.enter()]
        ] },
        { name: "cancel", tip: "Cancel ends the request: the broker tells polkit and the toast leaves at once.",
          steps: () => [
            [0, () => win.newFlow("native")],
            [10, () => fakeAgent.flow.prompt()],
            [900, () => win.typeText("abc")],
            [1800, () => {
                const r = win.recNow();
                if (r)
                    broker.cancel(r.id);
            }]
        ] },
        { name: "two queued", tip: "Two sudo requests at once: one live, the other waiting behind it. The second takes the toast when the first has been answered.",
          steps: () => [
            [0, () => {
                win.openAskpass("Update the system", "sudo wants to run: pacman -Syu", "hunter2");
                win.openAskpass("Remove an orphan", "sudo wants to run: pacman -Rns old-lib", "hunter2");
            }],
            [900, () => win.typeText("hunter2")],
            [1600, () => win.enter()],
            [3600, () => win.typeText("hunter2")],
            [4200, () => win.enter()]
        ] },
        { name: "fullscreen flip", tip: "A window goes fullscreen while the request is open: the toast is withdrawn and the same card appears in the Overlay pill with what was typed still there; back out and it returns to the lane.",
          steps: () => [
            [0, () => win.newFlow("native")],
            [10, () => fakeAgent.flow.prompt()],
            [600, () => win.typeText("hunt")],
            [1500, () => { win.fullscreenOn = true; }],
            [3000, () => win.typeText("er2")],
            [4200, () => { win.fullscreenOn = false; }],
            [5400, () => win.enter()]
        ] }
    ]

    // A resting state, for the renders.
    function jump(name) {
        win.reset();
        const f = win.newFlow("native", { answerDelay: name === "failed" ? 120 : 800, answers: name !== "checking" });
        win.later(10, () => f.prompt());
        if (name === "scan")
            return;
        win.later(120, () => win.typeText(name === "failed" ? "letmein" : "hunter2"));
        if (name === "typed")
            return;
        win.later(260, () => win.enter());
        if (name === "ok")
            win.later(500, () => f.succeed());
    }

    Timer {
        running: win.envState !== ""
        interval: 300
        onTriggered: win.jump(win.envState)
    }
    readonly property string envPlay: Quickshell.env("AUTH_PLAY") || ""
    Timer {
        running: win.envPlay !== ""
        interval: 300
        onTriggered: win.play(win.timelines[Number(win.envPlay)].steps())
    }

    readonly property string stageGrab: Quickshell.env("STAGE_GRAB") || ""
    Timer {
        running: win.stageGrab !== ""
        interval: Number(Quickshell.env("GRAB_MS") || 2500)
        onTriggered: scene.grabToImage(r => {
            r.saveToFile(win.stageGrab);
            Qt.quit();
        })
    }

    // =====================================================================
    //  RUN PAGE
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Timelines"
                blurb: "Scripted runs of the real broker, owner and card against a stand-in polkit flow (the right password is hunter2)."
            }
            Repeater {
                model: win.timelines.length
                TipRow {
                    id: tlRow
                    required property int index
                    readonly property var tl: win.timelines[tlRow.index]
                    tip: tlRow.tl.tip
                    Layout.fillWidth: true
                    spacing: 6
                    Button {
                        Layout.preferredWidth: 200
                        text: tlRow.tl.name
                        onClicked: win.play(tlRow.tl.steps())
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                }
            }

            TipGroup {
                title: "States"
                blurb: "Jump to a resting state (the renders): native howdy, the prompt open."
            }
            TipRow {
                tip: "Face scanning with the prompt open; a password typed; answered and waiting for the stack; a wrong one (the flush, then the words); accepted (the toast stays 'ok' for the broker's hold, a minute here)."
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: ["scan", "typed", "checking", "failed", "ok"]
                    Button {
                        required property string modelData
                        text: modelData
                        onClicked: win.jump(modelData)
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Type for the active request without the keyboard: seven characters into its buffer (as the card would), or press its Enter. Real keys need the pointer to MOVE over the card first."
                Layout.fillWidth: true
                spacing: 6
                Button {
                    text: "type"
                    onClicked: win.typeText("hunter2")
                }
                Button {
                    text: "enter"
                    onClicked: win.enter()
                }
                Button {
                    text: "reset"
                    onClicked: win.reset()
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Environment"
                blurb: "What the owner is told about the desktop."
            }
            TipRow {
                tip: "fullscreen: a client is fullscreen, so the lane is invisible and the card moves to the Overlay pill. sharing: a screencast is running, so the toast's body and the card's user line are hidden. howdy off: the prompt only opens after the scan (an Enter is held); native: it is open from the start."
                Layout.fillWidth: true
                spacing: 6
                CheckBox {
                    text: "fullscreen"
                    checked: win.fullscreenOn
                    onToggled: win.fullscreenOn = checked
                }
                CheckBox {
                    text: "sharing"
                    checked: win.sharingOn
                    onToggled: win.sharingOn = checked
                }
                CheckBox {
                    text: "howdy off"
                    checked: win.howdyMode === "off"
                    onToggled: win.howdyMode = checked ? "off" : "native"
                }
            }

            TipGroup {
                title: "Readout"
                blurb: "What the card asks of its host."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#6F6F72"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: {
                    const r = broker.current;
                    return "request: " + (r ? r.id + "  " + r.state + "  face " + r.face + "  fails " + r.failCount + (r.held ? "  HELD" : "") : "none")
                        + "\nqueued: " + broker.count + "   shown in: " + (authOwner.where || "-")
                        + "\nkeyboard: " + svc.interaction.keyboard + "   catch-all: " + svc.interaction.catchAll;
                }
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var cardParams: [
        {
            label: "field height", prop: "fieldHeight", group: "Field",
            blurb: "The carved password field (the lockscreen's LockField) in a toast.",
            tip: "Height of the carved field. 40 sits between a toast's 30 px buttons and the lock's 64 px field: tall enough to read as the thing to type into, short enough not to dwarf the title above it.",
            val: 40, from: 28, to: 64, step: 1
        },
        {
            label: "field radius", prop: "fieldRadius", group: "Field",
            tip: "Corner radius of the field. Half its height (20) makes the pill the lockscreen's field is; a smaller one squares it toward the notification card's 14.",
            val: 20, from: 4, to: 32, step: 1
        },
        {
            label: "dot size", prop: "dotSize", group: "Field",
            tip: "Diameter of one typed-character dot. 8 keeps about twenty dots between the face glyph's side slots in a 340 px toast.",
            val: 8, from: 4, to: 14, step: 1
        },
        {
            label: "dot gap", prop: "dotGap", group: "Field",
            tip: "Space between dots. 5, so the pitch is 13 px against a 10 px dot of the lock's 16.",
            val: 5, from: 2, to: 12, step: 1
        },
        {
            label: "face glyph", prop: "glyphSize", group: "Field",
            tip: "The face plate at the field's end. 24 leaves 8 px of field round it at height 40, the lock's one-padding-all-round rule.",
            val: 24, from: 16, to: 40, step: 1
        },
        {
            label: "status height", prop: "statusHeight", group: "Status",
            blurb: "The line under the field (LockStatusRow): a reserved slot, so a message appearing never moves the field.",
            tip: "Height of the reserved status slot. 20 holds one line of 11 px text with air.",
            val: 20, from: 14, to: 32, step: 1
        },
        {
            label: "status text", prop: "statusTextSize", group: "Status",
            tip: "Size of the status words. 11 is the notification card's figure size.",
            val: 11, from: 9, to: 14, step: 1
        },
        {
            label: "gap", prop: "gap", group: "Text",
            blurb: "The card's own lines.",
            tip: "Space between the card's lines: header, user line, field, status, buttons. 8, a notification card's line gap.",
            val: 8, from: 2, to: 16, step: 1
        },
        {
            label: "title", prop: "titleSize", group: "Text",
            tip: "The pill's title size (a toast uses the notification card's summary). 16 bold, the shell's title.",
            val: 16, from: 12, to: 22, step: 1
        },
        {
            label: "body", prop: "bodySize", group: "Text",
            tip: "The pill's body size (a toast uses the notification card's). 12, the shell's body.",
            val: 12, from: 9, to: 16, step: 1
        },
        {
            label: "user line", prop: "detailSize", group: "Text",
            tip: "The faint 'user . action id' line. 10, a meta size: it is for checking what you are authorising, not for reading first.",
            val: 10, from: 8, to: 13, step: 1
        },
        {
            label: "button height", prop: "buttonHeight", group: "Buttons",
            blurb: "The card's Cancel and Authenticate buttons.",
            tip: "Height of Cancel and Authenticate. 30, a notification card's action button.",
            val: 30, from: 22, to: 40, step: 1
        },
        {
            label: "button gap", prop: "buttonGap", group: "Buttons",
            tip: "Space between the two buttons. 8, the card's line gap, so the row's gap equals the column's.",
            val: 8, from: 2, to: 16, step: 1
        },
        {
            label: "button radius", prop: "buttonRadius", group: "Buttons",
            tip: "Corner radius of the buttons. 7, the notification card's action radius.",
            val: 7, from: 2, to: 15, step: 1
        }
    ]

    readonly property var pillParams: [
        {
            label: "field height", prop: "pillFieldHeight", group: "Pill field",
            blurb: "The card over a fullscreen window is larger: it stands alone on the screen, not inside a toast.",
            tip: "Height of the field in the pill. 44, a little taller than a toast's 40 because there is no card around it.",
            val: 44, from: 28, to: 72, step: 1
        },
        {
            label: "field radius", prop: "pillFieldRadius", group: "Pill field",
            tip: "Corner radius of the pill's field; half its height.",
            val: 22, from: 4, to: 36, step: 1
        },
        {
            label: "dot size", prop: "pillDotSize", group: "Pill field",
            tip: "Typed-character dot in the pill. 9.",
            val: 9, from: 4, to: 16, step: 1
        },
        {
            label: "face glyph", prop: "pillGlyphSize", group: "Pill field",
            tip: "Face plate in the pill's field. 28 leaves 8 px round it at height 44.",
            val: 28, from: 16, to: 44, step: 1
        }
    ]
}
