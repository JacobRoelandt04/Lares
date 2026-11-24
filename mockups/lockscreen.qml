pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/locale"
import "modules/common/mockup"
import "modules/common/theme"
import "modules/lockscreen"
import "modules/lockscreen/popup"
import "modules/weather/data"
import "modules/wiki/data"
import "modules/screentime/data"
import "modules/common/system"

// =============================================================================
// mockups/lockscreen.qml -- the lock popup: what the user sees while the session
// is locked (modules/lockscreen/popup/, contract section 4).
//
// The content is exactly the drop-in the shell's bar hangs on its popup slot
// (`LockPopup`), on the mockup stage at its own implicit size. The Run tab
// stands in for the lock process: it writes a LockState -- typing, checking,
// failing, caps, every face state, a boot lock or an ordinary one --
// and for the shell's services, which are MOCKS here (a fake battery, the
// weather fixture, fake updates, a fake mpd, the wiki fixture): nothing reads
// the network and nothing starts a process. The other tabs are every tunable
// of every part, each with its tip.
//
// Nothing here locks anything: the mockup never instantiates the session lock.
//
// Env (for renders):
//   STATE=<k=v,...>   dots=N auth=idle|checking|failed|ok fail=N caps=0|1
//                     face=<state> why=<faceReason> boot=0|1 lockedMin=N inkcentre=0|1
//                     awake=0|1 fallback=0|1 media=vinyl|paused|wiki|empty|none
//                     battery=none|82|14|charging|full weather=0|1
//                     updates=0|1|none screentime=0|1 width=N name=<text> time=HH:MM
//   NOW=<epoch ms>    freeze the clock's reading (a render)
//   STAGE_GRAB=<png> [GRAB_MS]   grab the popup on its surface at 1:1 and quit
//   MODE=light|dark   the theme
// =============================================================================
MockupWindow {
    id: win

    moduleId: "lockscreen"
    title: "Lock popup"
    stageLabel: "LockPopup (drop-in for thePopup, and the lock's fallback card)"
    content: demo
    target: demo
    stageColor: Theme.surface
    clipContent: true
    zoom: 1
    panelWidth: 460

    targets: ({
            clockParams: demo.clockBlock,
            fieldParams: demo.field,
            faceParams: demo.field.faceGlyph,
            statusParams: demo.statusRow,
            bandParams: demo.infoBand,
            mediaParams: demo.mediaSlot
        })
    lists: ({
            popupParams: win.popupParams,
            clockParams: win.clockParams,
            fieldParams: win.fieldParams,
            faceParams: win.faceParams,
            statusParams: win.statusParams,
            bandParams: win.bandParams,
            mediaParams: win.mediaParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Popup",
            lists: ["popupParams"]
        },
        {
            name: "Clock",
            lists: ["clockParams"]
        },
        {
            name: "Field",
            subs: [
                {
                    name: "Field",
                    lists: ["fieldParams"]
                },
                {
                    name: "Face",
                    lists: ["faceParams"]
                },
                {
                    name: "Status",
                    lists: ["statusParams"]
                }
            ]
        },
        {
            name: "Band",
            lists: ["bandParams"]
        },
        {
            name: "Media",
            lists: ["mediaParams"]
        }
    ]

    // =====================================================================
    //  THE MOCKS
    // =====================================================================
    LockState {
        id: fake
        phase: "locked"
        lockedAt: Date.now() - 4 * 60000
    }
    LocaleConfig {
        id: locale
    }
    BatteryData {
        id: mockBattery
        polling: false
        status: "Discharging"
        percent: 82
        energyNowWh: 41
        energyFullWh: 50
        energyFullDesignWh: 55
        smoothedWatts: 9.4
    }
    WeatherMock {
        id: mockWeather
    }
    WikiMock {
        id: mockWiki
        scenario: "normal"
    }
    ScreentimeMock {
        id: mockScreentime
        seed: 7
        latencyMs: 0
    }
    QtObject {
        id: mockUpdates
        property int totalCount: 214
        property var categories: [
            { key: "core", count: 9 },
            { key: "extra", count: 180 },
            { key: "multilib", count: 14 },
            { key: "aur", count: 6 },
            { key: "flatpak", count: 5 }
        ]
    }
    QtObject {
        id: mockMpd
        property bool playing: true
        property var current: ({ title: "Sandstorm", artist: "Darude", album: "Before the Storm", file: "Albums/Before the Storm/01.flac" })
        function coverUrlFor(file) {
            return "";
        }
    }

    // What the popup is handed: a source is `null` while its switch is off.
    property bool srcBattery: true
    property bool srcWeather: true
    property bool srcUpdates: true
    property bool srcScreentime: false
    property string mediaMode: "vinyl"      // vinyl | paused | wiki | empty
    property string greeting: "Alex"

    readonly property string envMode: Quickshell.env("MODE") || ""
    readonly property string envState: Quickshell.env("STATE") || ""
    readonly property real envNow: Number(Quickshell.env("NOW") || 0)
    readonly property string stageGrab: Quickshell.env("STAGE_GRAB") || ""

    // =====================================================================
    //  THE DROP-IN CONTENT
    // =====================================================================
    LockPopup {
        id: demo
        lockState: fake
        battery: win.srcBattery ? mockBattery : null
        weather: win.srcWeather ? mockWeather : null
        updates: win.srcUpdates ? mockUpdates : null
        screentime: win.srcScreentime ? mockScreentime : null
        mpd: win.mediaMode === "vinyl" || win.mediaMode === "paused" ? mockMpd : null
        wikiService: win.mediaMode === "wiki" || win.mediaMode === "paused" ? mockWiki : null
        locale: locale
        greetingName: win.greeting
        renderScale: win.zoom
    }

    // =====================================================================
    //  STATE DRIVER
    // =====================================================================
    Timer {
        id: submitTimer
        interval: 2000
        onTriggered: {
            fake.auth = win._submitOk ? "ok" : "failed";
            if (!win._submitOk)
                fake.failCount += 1;
            fake.dots = 0;
        }
    }
    property bool _submitOk: false
    // Type N characters, press Enter: pam_unix takes ~2 s to say no.
    function submit(ok) {
        if (fake.dots === 0)
            fake.dots = 9;
        win._submitOk = ok;
        fake.auth = "checking";
        submitTimer.restart();
    }
    function typeKey() {
        submitTimer.stop();
        if (fake.auth === "failed" || fake.auth === "ok")
            fake.auth = "idle";
        fake.dots = Math.min(512, fake.dots + 1);
    }
    function backspace() {
        fake.dots = Math.max(0, fake.dots - 1);
    }

    function setBattery(kind) {
        win.srcBattery = kind !== "none";
        if (kind === "none")
            return;
        const b = mockBattery;
        b.status = kind === "charging" ? "Charging" : (kind === "full" ? "Full" : "Discharging");
        b.percent = kind === "full" ? 100 : (kind === "charging" ? 45 : (kind === "14" ? 14 : Number(kind) || 82));
        b.energyNowWh = b.energyFullWh * b.percent / 100;
        b.smoothedWatts = kind === "full" ? 0 : 9.4;
    }
    function setMedia(m) {
        win.mediaMode = m === "none" ? "empty" : m;
        if (m === "wiki")
            mockWiki.scenario = "normal";
        if (m === "empty" || m === "none")
            mockWiki.scenario = "empty";
        mockMpd.playing = m === "vinyl";
    }

    // STATE="dots=7,auth=failed,fail=3,caps=1,face=dark,..."
    // The wall the popup reads: the frozen reading when there is one.
    function wall() {
        return demo.clockBlock.fixedNow > 0 ? demo.clockBlock.fixedNow : Date.now();
    }

    function applySpec(spec) {
        for (const part of spec.split(",")) {
            const eq = part.indexOf("=");
            if (eq < 0)
                continue;
            const k = part.substring(0, eq).trim();
            const v = part.substring(eq + 1).trim();
            switch (k) {
            case "dots": fake.dots = Number(v); break;
            case "auth": fake.auth = v; break;
            case "fail": fake.failCount = Number(v); break;
            case "caps": fake.caps = v === "1"; break;
            case "inkcentre": demo.clockBlock.centreByInk = v !== "0"; break;
            case "face": fake.face = v; break;
            case "why": fake.faceReason = v; break;
            case "boot": fake.boot = v === "1"; break;
            case "time": {
                const hm = v.split(":");
                demo.clockBlock.fixedNow = new Date(2026, 8, 30, Number(hm[0]), Number(hm[1]), 0).getTime();
                break;
            }
            case "lockedMin": fake.lockedAt = win.wall() - Number(v) * 60000; break;
            case "awake": demo.active = v === "1"; break;
            case "fallback": demo.fallback = v === "1"; break;
            case "media": win.setMedia(v); break;
            case "battery": win.setBattery(v); break;
            case "weather": win.srcWeather = v === "1"; break;
            case "updates": win.srcUpdates = v !== "none" && v !== "0"; break;
            case "screentime": win.srcScreentime = v === "1"; break;
            case "width": demo.contentWidth = Number(v); break;
            case "name": win.greeting = v; break;
            }
        }
    }

    Component.onCompleted: {
        if (win.envMode === "light" || win.envMode === "dark")
            Theme.setMode(win.envMode);
        if (win.envNow > 0) {
            demo.clockBlock.fixedNow = win.envNow;
            fake.lockedAt = win.envNow - 4 * 60000;
        }
        if (win.envState !== "")
            win.applySpec(win.envState);
    }

    // STAGE_GRAB: the popup on its surface (the stage's rect is opaque), at
    // 1:1, then quit.
    Timer {
        running: win.stageGrab !== ""
        interval: Number(Quickshell.env("GRAB_MS") || 1800)
        onTriggered: demo.parent.grabToImage(function (r) {
            r.saveToFile(win.stageGrab);
            console.log("STAGE_GRAB saved " + win.stageGrab);
            Qt.quit();
        })
    }

    // =====================================================================
    //  THE RUN PAGE
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Typing"
                blurb: "What the lock process reports: the number of characters in its password buffer, never the characters."
            }
            TipRow {
                tip: "Type or delete one character. The dots grow with one eased count and the row stays centred; past the cap (what fits between the side slots, at most 'max dots') the row holds its width, its first dots fade and the last one pulses on each key. A key after a failed attempt clears the message."
                Button {
                    text: "+1"
                    onClicked: win.typeKey()
                }
                Button {
                    text: "-1"
                    onClicked: win.backspace()
                }
                Button {
                    text: "+5"
                    onClicked: {
                        for (let i = 0; i < 5; i++)
                            win.typeKey();
                    }
                }
                Button {
                    text: "clear"
                    onClicked: fake.dots = 0
                }
                Button {
                    text: "40"
                    onClicked: fake.dots = 40
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipGroup {
                title: "Password"
                blurb: "The auth field of the state: idle, checking (PAM working: an accent band crosses the inset), failed (the inset flushes to the error colour and eases back; the words stay until the next key), ok."
            }
            TipRow {
                tip: "Submit the typed characters (9 if empty): checking for 2 s -- pam_unix's failure delay -- then a wrong password (the count grows) or the right one."
                Button {
                    text: "wrong password"
                    onClicked: win.submit(false)
                }
                Button {
                    text: "right password"
                    onClicked: win.submit(true)
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Set the auth field directly, without the typing. 'failed' does not clear the dots, the way the lock does not until the next key."
                Repeater {
                    model: ["idle", "checking", "failed", "ok"]
                    delegate: Button {
                        id: authBtn
                        required property string modelData
                        text: authBtn.modelData
                        onClicked: {
                            submitTimer.stop();
                            fake.auth = authBtn.modelData;
                            if (authBtn.modelData === "failed")
                                fake.failCount = Math.max(1, fake.failCount);
                        }
                    }
                }
                Button {
                    text: "fail count +1"
                    onClicked: fake.failCount += 1
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Caps lock: the field's inset holds the warn colour."
                Switch {
                    text: "caps"
                    checked: fake.caps
                    onToggled: fake.caps = checked
                }
            }
            TipGroup {
                title: "Face"
                blurb: "howdy's state, one glyph at the field's end: absent draws nothing, scanning sweeps the accent round the plate, ok and failed set the inset, dark/busy/unavailable/misconfigured are muted or faint, the four with words where the camera has something to say."
            }
            TipRow {
                tip: "The face state, as the lock's PAM stack reports it."
                ComboBox {
                    Layout.fillWidth: true
                    model: ["absent", "idle", "scanning", "ok", "failed", "dark", "busy", "unavailable", "misconfigured"]
                    currentIndex: Math.max(0, model.indexOf(fake.face))
                    onActivated: fake.face = currentText
                }
            }
            TipRow {
                tip: "Why the face is where it is (LockState.faceReason, round 5): the lock reads it off howdy's words, its result and the lid; the line under the field says it. Pick a state above that it explains (failed: nomatch / stall / error; unavailable: camera / lid / nomodel; misconfigured: workaround / device / config / nomodel / pam / input)."
                ComboBox {
                    Layout.fillWidth: true
                    model: ["", "nomatch", "dark", "camera", "lid", "nomodel", "error", "stall", "input", "workaround", "device", "config", "pam"]
                    currentIndex: Math.max(0, model.indexOf(fake.faceReason))
                    onActivated: fake.faceReason = currentText
                }
            }
            TipGroup {
                title: "The lock"
                blurb: "What the popup says about the lock itself."
            }
            TipRow {
                tip: "A boot lock (the first unlock of the session) greets by the hour and puts the date under it; an ordinary lock shows the date and how long ago it was locked, on RelTime's own boundaries."
                Switch {
                    text: "first unlock of the session"
                    checked: fake.boot
                    onToggled: fake.boot = checked
                }
            }
            TipRow {
                tip: "Set 'locked' this long ago (minutes). The line under the date follows: 'Locked just now', '4 min ago', '3 h ago'."
                Repeater {
                    model: [0, 4, 75, 400]
                    delegate: Button {
                        id: agoBtn
                        required property int modelData
                        text: agoBtn.modelData + " min"
                        onClicked: fake.lockedAt = win.wall() - agoBtn.modelData * 60000
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Freeze the clock's reading at 09:41 (a render's fixed time) or 09:59 (one minute before every digit rolls), step it a minute on to watch the digits roll, or follow the real clock again. The real clock ticks on the minute boundary only."
                Button {
                    text: "freeze 09:41"
                    onClicked: demo.clockBlock.fixedNow = new Date(2026, 8, 30, 9, 41, 0).getTime()
                }
                Button {
                    text: "09:59"
                    onClicked: demo.clockBlock.fixedNow = new Date(2026, 8, 30, 9, 59, 0).getTime()
                }
                Button {
                    text: "+1 min"
                    onClicked: demo.clockBlock.fixedNow = (demo.clockBlock.fixedNow > 0 ? demo.clockBlock.fixedNow : Math.floor(Date.now() / 60000) * 60000) + 60000
                }
                Button {
                    text: "follow"
                    onClicked: demo.clockBlock.fixedNow = 0
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Awake or at rest (the lock's `awake` after its idle seconds): at rest nothing in the popup ticks -- the bands, the face's sweep, the record and the wiki card stop; only the clock's minute boundary runs. Fallback: the lock's own hosting, which drops every service but the battery and the locale."
                Switch {
                    text: "awake"
                    checked: demo.active
                    onToggled: demo.active = checked
                }
                Switch {
                    text: "fallback"
                    checked: demo.fallback
                    onToggled: demo.fallback = checked
                }
            }
            TipGroup {
                title: "Sources"
                blurb: "What the shell hands the popup. A cell whose source is null is not there and the band re-centres; a band with no cell has no height."
            }
            TipRow {
                tip: "The battery: discharging at 82 or 14 percent, charging, full, or no battery at all (a desktop)."
                Repeater {
                    model: ["82", "14", "charging", "full", "none"]
                    delegate: Button {
                        id: batBtn
                        required property string modelData
                        text: batBtn.modelData
                        onClicked: win.setBattery(batBtn.modelData)
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Weather now (the fixture of the weather module's mock, no network) and the updates waiting (fake counts split by repo)."
                Switch {
                    text: "weather"
                    checked: win.srcWeather
                    onToggled: win.srcWeather = checked
                }
                Switch {
                    text: "updates"
                    checked: win.srcUpdates
                    onToggled: win.srcUpdates = checked
                }
            }
            TipRow {
                tip: "The 92 px slot: a spinning record while mpd plays; paused mpd or no mpd shows the wiki card; with neither (or a wiki with nothing to show) the slot has no height and the popup closes over it."
                Repeater {
                    model: ["vinyl", "paused", "wiki", "empty"]
                    delegate: Button {
                        id: mediaBtn
                        required property string modelData
                        text: mediaBtn.modelData
                        onClicked: win.setMedia(mediaBtn.modelData)
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The name after the greeting. Empty leaves the comma out too (the shell derives the real one from the account's full name)."
                Label {
                    text: "name"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                }
                TextField {
                    Layout.fillWidth: true
                    text: win.greeting
                    onTextEdited: win.greeting = text
                }
            }
            Label {
                Layout.fillWidth: true
                text: "size: " + demo.implicitWidth.toFixed(0) + " x " + demo.implicitHeight.toFixed(0)
                    + "   dots cap: " + demo.field.cap + "   locale: " + locale.source
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var popupParams: [
        {
            label: "padding",
            prop: "padding",
            group: "Popup",
            blurb: "The popup's own space. Every number is the shell's.",
            tip: "Space between the popup's edge and its content, on every side: 12 everywhere in the shell, so the space above equals the space below.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "section gap",
            prop: "gap",
            group: "Popup",
            tip: "Space between the sections (clock, field, band, slot). 12 like the padding; a section that is not there takes its gap with it.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "status gap",
            prop: "statusGap",
            group: "Popup",
            tip: "Space between the field and the row of words under it. Smaller than the section gap: the words belong to the field.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "content width",
            prop: "contentWidth",
            group: "Popup",
            tip: "Width of every section; the popup is this plus the padding on both sides, and the content is centred by hand so it does not move while the box opens. 560 fits the info band's four cells (battery, weather, updates, screen time) at their widest texts side by side (~550); narrower, the band shrinks every cell by one factor and its texts elide. Below 260 the wiki card and the band no longer fit.",
            val: 560,
            from: 260,
            to: 640,
            step: 2
        },
        {
            label: "font",
            prop: "fontFamily",
            group: "Type",
            blurb: "One face for the whole popup.",
            tip: "The face of every text (the clock, the date, the messages, the band, the record's title). Audiowide is the user's; the module's own default when this is left empty is the same.",
            val: "Audiowide",
            kind: "text"
        }
    ]

    readonly property var clockParams: [
        {
            label: "hero size",
            prop: "heroSize",
            group: "Time",
            blurb: "The clock: Audiowide in DigitCells, so a minute turning never shifts a digit.",
            tip: "Pixel size of the time. hyprlock used 110 pt; the popup is 464 wide, and 104 px sets \"00:00\" about 360 wide -- the hero, with room either side.",
            val: 104,
            from: 40,
            to: 180,
            step: 1
        },
        {
            label: "anchored digits",
            prop: "anchoredDigits",
            group: "Time",
            tip: "On: the colon stands at the centre and the digits are packed outward from it at their natural widths -- tight, readable groups (\"11:11\"), and on a minute change only digits outside the changed one can shift, once a minute. Off: every digit has a fixed slot, so nothing ever moves, but a narrow digit (Audiowide's 1) leaves gaps (\"1 1:1 1\").",
            val: true
        },
        {
            label: "centre by ink",
            prop: "centreByInk",
            group: "Time",
            tip: "On: the whole time is centred by its INK (the first and last glyph's tight bounds), so \"11:11\" and \"20:48\" both leave equal margins either side; the correction eases 260 ms when a minute turns. Off: the figures are centred by their advances, which puts the colon at the centre and the whole group right of it whenever the hour's digits are narrower than the minute's (the round-1 look, kept for the render gate's armed fault).",
            val: true
        },
        {
            label: "roll digits",
            prop: "rollDigits",
            group: "Roll",
            blurb: "A digit that changes rolls: the old figure rises out, then the new one rises in from below.",
            tip: "On: a changed digit rolls, the changed digits cascading right to left as an odometer carries. Off: digits swap at once (the round-4 clock).",
            val: true
        },
        {
            label: "roll ms",
            prop: "rollMs",
            group: "Roll",
            tip: "One digit's roll: the old figure leaves over the first half, the new one settles over the second -- never both on screen. 420 reads as a deliberate turn without dragging past the ink re-centring (260 ms).",
            val: 420,
            from: 120,
            to: 1200,
            step: 10
        },
        {
            label: "cascade ms",
            prop: "rollStaggerMs",
            group: "Roll",
            tip: "Delay between one changed digit and the next one to its left. 70: 09:59 -> 10:00 carries across the four digits in about 0.63 s; 0 rolls them together.",
            val: 70,
            from: 0,
            to: 300,
            step: 5
        },
        {
            label: "travel",
            prop: "rollTravel",
            group: "Roll",
            tip: "How far a figure rises while it leaves or arrives, as a fraction of the hero size. 0.18 gives the roll a clear direction while the arriving figure, faint as it starts, barely reaches the date line below (0.3 dipped into it).",
            val: 0.18,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "date size",
            prop: "dateSize",
            group: "Lines",
            blurb: "The two lines under the time.",
            tip: "Pixel size of the first line: the date, or the greeting on a boot lock.",
            val: 20,
            from: 10,
            to: 36,
            step: 1
        },
        {
            label: "sub size",
            prop: "subSize",
            group: "Lines",
            tip: "Pixel size of the second line: 'Locked 4 min ago', or the date under a greeting.",
            val: 12,
            from: 8,
            to: 20,
            step: 1
        },
        {
            label: "time to date",
            prop: "dateGap",
            group: "Lines",
            tip: "Space between the digits' ink and the first line.",
            val: 10,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "date to sub",
            prop: "subGap",
            group: "Lines",
            tip: "Space between the first line and the second.",
            val: 2,
            from: 0,
            to: 16,
            step: 1
        }
    ]

    readonly property var fieldParams: [
        {
            label: "height",
            prop: "fieldHeight",
            group: "Field",
            blurb: "The carved password field. hyprlock's was 325 x 78, rounded 32.",
            tip: "Height of the field. The face glyph sits one padding from the end on every side, so the glyph's slot grows with it.",
            val: 64,
            from: 40,
            to: 96,
            step: 1
        },
        {
            label: "radius",
            prop: "radius",
            group: "Field",
            tip: "Corner radius: half the height is a pill, hyprlock's rounding. It meets no container corner, so the shell's 14 does not bind it.",
            val: 32,
            from: 4,
            to: 48,
            step: 1
        },
        {
            label: "placeholder key",
            prop: "placeholderGlyph",
            group: "Field",
            tip: "The faint key in the empty field, as hyprlock had. It fades with the first character. Off leaves the empty field bare.",
            val: true
        },
        {
            label: "dot size",
            prop: "dotSize",
            group: "Dots",
            blurb: "The typed characters.",
            tip: "Diameter of a dot.",
            val: 10,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "dot gap",
            prop: "dotGap",
            group: "Dots",
            tip: "Space between two dots.",
            val: 6,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "max dots",
            prop: "maxDots",
            group: "Dots",
            tip: "The most dots shown: 32, or however many fit between the two side slots, whichever is fewer. Past it the row holds its width.",
            val: 32,
            from: 4,
            to: 64,
            step: 1
        },
        {
            label: "dot grow ms",
            prop: "dotGrowMs",
            group: "Dots",
            tip: "How long the row takes to take a new dot (one eased count moves every dot and the centring).",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "glyph size",
            prop: "glyphSize",
            group: "Face glyph",
            blurb: "The face plate at the field's end.",
            tip: "Diameter of the face plate at the field's end. The dots' area is symmetric about the field whether the glyph is there or not.",
            val: 40,
            from: 20,
            to: 64,
            step: 1
        },
        {
            label: "checking sweep ms",
            prop: "checkSweepMs",
            group: "Checking band",
            blurb: "While PAM works, an accent band crosses the inset shadow, over and over.",
            tip: "One trip of the band. Slow, because it says 'still working' and pam_unix's no takes ~2 s.",
            val: 1600,
            from: 400,
            to: 4000,
            step: 100
        },
        {
            label: "band head",
            prop: "sweepHead",
            group: "Checking band",
            tip: "The share of the trip the band's leading edge spends moving (Sweep.js). Higher = a softer start.",
            val: 0.7,
            from: 0.1,
            to: 1,
            step: 0.05
        },
        {
            label: "band tail",
            prop: "sweepTail",
            group: "Checking band",
            tip: "The share of the trip the trailing edge spends moving. Head + tail over 1 is the overlap where the band travels at full width.",
            val: 0.7,
            from: 0.1,
            to: 1,
            step: 0.05
        },
        {
            label: "state fade ms",
            prop: "stateFadeMs",
            group: "Colours",
            blurb: "Fractions, not colours: a theme switch stays one clock.",
            tip: "How long the inset takes to move to caps, ok or the band's presence.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "fail flush ms",
            prop: "failFlushMs",
            group: "Colours",
            tip: "How fast the inset flushes to the error colour on a wrong password.",
            val: 140,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "fail return ms",
            prop: "failReturnMs",
            group: "Colours",
            tip: "How long it takes to come back. The message stays up regardless -- the colour is the reaction, the words are the fact.",
            val: 800,
            from: 0,
            to: 3000,
            step: 50
        }
    ]

    readonly property var faceParams: [
        {
            label: "sweep ms",
            prop: "sweepMs",
            group: "Scanning",
            blurb: "The face plate's own band while the camera scans.",
            tip: "One trip of the accent band round the plate's inset. One clock, stopped when the popup is at rest.",
            val: 1500,
            from: 400,
            to: 4000,
            step: 100
        },
        {
            label: "band head",
            prop: "sweepHead",
            group: "Scanning",
            tip: "Share of the trip the band's leading edge moves.",
            val: 0.7,
            from: 0.1,
            to: 1,
            step: 0.05
        },
        {
            label: "band tail",
            prop: "sweepTail",
            group: "Scanning",
            tip: "Share of the trip the trailing edge moves.",
            val: 0.7,
            from: 0.1,
            to: 1,
            step: 0.05
        },
        {
            label: "fade ms",
            prop: "fadeMs",
            group: "Scanning",
            tip: "Presence of the glyph, the band, ok and failed: 160 ms, the shell's presence fade.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "faint opacity",
            prop: "faintOpacity",
            group: "Plate",
            blurb: "The plate's carve and its 'not now' look.",
            tip: "How much of the glyph busy, unavailable and misconfigured keep: present, but not to be relied on.",
            val: 0.5,
            from: 0.1,
            to: 1,
            step: 0.05
        },
        {
            label: "plate bevel",
            prop: "plateBevel",
            group: "Plate",
            tip: "Width of the light rim outside the carve. 1, as the field's own.",
            val: 1,
            from: 0,
            to: 3,
            step: 0.25
        },
        {
            label: "plate shadow",
            prop: "plateShadow",
            group: "Plate",
            tip: "Depth of the inset shadow. The band is drawn in it, so a deeper carve is a wider band.",
            val: 3,
            from: 1,
            to: 7,
            step: 0.5
        }
    ]

    readonly property var statusParams: [
        {
            label: "row height",
            prop: "rowHeight",
            group: "Row",
            blurb: "The line under the field, a reserved slot: it keeps its height with nothing to say.",
            tip: "Height of the row.",
            val: 22,
            from: 14,
            to: 36,
            step: 1
        },
        {
            label: "text size",
            prop: "textSize",
            group: "Row",
            tip: "Pixel size of the message.",
            val: 12,
            from: 8,
            to: 20,
            step: 1
        },
        {
            label: "fade ms",
            prop: "fadeMs",
            group: "Row",
            tip: "Presence of the message. A text swap is instant; only presence fades.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        }
    ]

    readonly property var bandParams: [
        {
            label: "height",
            prop: "bandHeight",
            group: "Band",
            blurb: "The carved band of glances: battery, weather, updates.",
            tip: "Height of the band. Two lines of text and a padding above and below.",
            val: 56,
            from: 40,
            to: 96,
            step: 1
        },
        {
            label: "radius",
            prop: "radius",
            group: "Band",
            tip: "Corner radius: the shell's container radius, 14.",
            val: 14,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "figure size",
            prop: "figureSize",
            group: "Type",
            blurb: "The sizes of a band cell's two lines.",
            tip: "Pixel size of a cell's first line (the figure). 13 bold.",
            val: 13,
            from: 9,
            to: 20,
            step: 1
        },
        {
            label: "line size",
            prop: "lineSize",
            group: "Type",
            tip: "Pixel size of a cell's second line.",
            val: 10,
            from: 8,
            to: 16,
            step: 1
        },
        {
            label: "line gap",
            prop: "lineGap",
            group: "Type",
            tip: "Space between a cell's two lines.",
            val: 2,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "battery width",
            prop: "batteryWidth",
            group: "Battery",
            blurb: "The small carved battery in the band.",
            tip: "Width of the small carved battery (its nub is 3 px more).",
            val: 28,
            from: 18,
            to: 48,
            step: 1
        },
        {
            label: "battery height",
            prop: "batteryHeight",
            group: "Battery",
            tip: "Height of the small battery.",
            val: 15,
            from: 10,
            to: 26,
            step: 1
        },
        {
            label: "weather glyph",
            prop: "glyphSize",
            group: "Weather",
            blurb: "The carved weather glyph in the band.",
            tip: "Size of the carved weather glyph.",
            val: 28,
            from: 16,
            to: 44,
            step: 1
        },
        {
            label: "bar width",
            prop: "barWidth",
            group: "Updates",
            blurb: "The updates' bar, split by repo in the update popup's category colours.",
            tip: "Width of the bar under the count; also the cell's least width.",
            val: 88,
            from: 40,
            to: 140,
            step: 2
        },
        {
            label: "bar height",
            prop: "barHeight",
            group: "Updates",
            tip: "Height of the bar's segments.",
            val: 4,
            from: 2,
            to: 10,
            step: 1
        },
        {
            label: "slide ms",
            prop: "slideMs",
            group: "Motion",
            blurb: "When a source arrives or goes.",
            tip: "How long the cells take to re-centre: 260 ms OutCubic, the shell's resize.",
            val: 260,
            from: 0,
            to: 800,
            step: 20
        },
        {
            label: "fade ms",
            prop: "fadeMs",
            group: "Motion",
            tip: "Presence of a cell that comes or goes.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        }
    ]

    readonly property var mediaParams: [
        {
            label: "slot height",
            prop: "slotHeight",
            group: "Slot",
            blurb: "The reclaimable slot at the foot.",
            tip: "Height of the record's row. 92 is the wiki's lock card's height, so the slot does not change size when mpd starts and stops.",
            val: 92,
            from: 60,
            to: 140,
            step: 1
        },
        {
            label: "radius",
            prop: "radius",
            group: "Slot",
            tip: "Corner radius of the record's carved row: 14.",
            val: 14,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "fade ms",
            prop: "fadeMs",
            group: "Slot",
            tip: "The newcomer's fade when the slot changes what it shows. The old view goes at once; two layouts are never crossfaded.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "disc item",
            prop: "discItem",
            group: "Record",
            blurb: "The mini vinyl.",
            tip: "The record's own item: the disc is 78 % of it, and the shader's shadow needs the rest. 96 makes a 75 px record in a 92 px row.",
            val: 96,
            from: 60,
            to: 140,
            step: 1
        },
        {
            label: "spin ms",
            prop: "spinMs",
            group: "Record",
            tip: "One turn. 33 1/3 rpm is 1800 ms. The record turns only while mpd plays and the popup is awake.",
            val: 1800,
            from: 600,
            to: 6000,
            step: 100
        },
        {
            label: "title size",
            prop: "titleSize",
            group: "Type",
            blurb: "The sizes of the track's three lines.",
            tip: "Pixel size of the track's title (bold).",
            val: 14,
            from: 9,
            to: 22,
            step: 1
        },
        {
            label: "artist size",
            prop: "artistSize",
            group: "Type",
            tip: "Pixel size of the artist.",
            val: 12,
            from: 8,
            to: 18,
            step: 1
        },
        {
            label: "album size",
            prop: "albumSize",
            group: "Type",
            tip: "Pixel size of the album, the third line, in the faint ink.",
            val: 10,
            from: 8,
            to: 16,
            step: 1
        },
        {
            label: "line gap",
            prop: "lineGap",
            group: "Type",
            tip: "Space between the title and the artist.",
            val: 4,
            from: 0,
            to: 12,
            step: 1
        }
    ]
}
