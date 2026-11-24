pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/components"
import "modules/common/flourish"
import "modules/shell"

// =============================================================================
// flourish_pool_probe.qml -- the OLED care's random flourishes on the MOCK shell: the registry every glyph flourish joins
// (FlourishRegistry), one screen's scheduler (FlourishScheduler in ShellFrame) and the config that drives it (shell.jsonc
// `oled.flourishes`, ShellConfig.oledFlourishes). ONE ShellFrame over mock services in an offscreen window; tools/dev/flourish_pool_probe.sh
// runs it. The idleness is PINNED (`forceIdle`) and a turn is taken by hand (`turn()`), so nothing waits on the real clock.
//
//   registry   every flourish of the frame is registered under its name (power.*, idleReel.*, update, bell, player, weather); one made outside
//              the frame is not the frame's; at rest nothing plays and the frame's `oledHeld` is false; the archive's flourish (which
//              the shift never waited for before) holds it while it plays
//   demo       a turn plays a glyph that is on show through its DEMO: no reel clock of kind fire / engage, no ReelActions.flourished,
//              no reel `activated` -- ever, over the whole run
//   bag        every glyph of the pool plays once before any plays twice, and a new round does not start with the last one
//   gates      a popup out on this screen, the reel's strip out, the bars away, a fullscreen window, the OLED care off: the turn is
//              skipped and says why (the lock and the theme's crossfade are one-line conditions a mock cannot drive)
//   config     idle false (while idle) arms nothing; glyph switches (a group off, a glyph key that wins over its group, an event glyph
//              switched on); the wait is drawn in the mode's range; a bad value takes its default and is named
//   staleheld  a delegate replaced in one update (its successor registers before it dies) leaves the live entry in the registry
// Prints `FLPOOL ok|FAIL <check>` and `FLPOOL RESULT PASS|FAIL (<n>/<n> checks)`.
//
// THE WAIT: the script starts on the shell's `settled` (the prewarm's builds are GUI-thread stalls) and every wait counts live time
// (oled_shift_probe.qml's sequencer).
// =============================================================================
ShellRoot {
    id: root

    property int checks: 0
    property int fails: 0

    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("FLPOOL " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    FloatingWindow {
        id: win
        implicitWidth: 1400
        implicitHeight: 700
        visible: true
        color: "#808080"

        ShellServices {
            id: mockServices
            mode: "mock"
            windowless: true
        }
        Loader {
            id: frameLoader
            anchors.fill: parent
            active: mockServices.ready
            sourceComponent: Component {
                ShellFrame {
                    services: mockServices
                    screenName: "eDP-1"
                }
            }
        }

        // a flourish that is NOT under the frame (a mockup's, another screen's): never the frame's
        Item {
            id: outside
            GlyphFlourish {
                id: outsideFl
                group: "update"
                decorative: true
                host: outside
            }
        }
    }
    // a delegate replaced in one update (staleheld): a Variants makes the new instance before it destroys the old one, as the shell's
    // screens do on a re-plug
    Variants {
        id: stale
        model: [1]
        delegate: Component {
            QtObject {
                required property var modelData
                property GlyphFlourish fl: GlyphFlourish {
                    group: "probestale"
                    host: outside
                }
            }
        }
    }

    readonly property var frame: frameLoader.item
    readonly property var sched: root.frame ? root.frame.flourishScheduler : null

    // ---- the fire path, watched over the whole run ----
    // the plain decorative glyph buttons (a GlyphFlourish with a group and `decorative: true`, always on show): each is in the
    // registry and in the default pool. A new one is ONE name here; the bag's rounds follow the pool's size.
    readonly property var plainDecorative: ["notes", "llm", "theme", "bridge", "panorama", "stocks"]
    readonly property int poolN: 8 + root.plainDecorative.length
    // the pool under the second config ("glyphs judged"): its five and the plain ones
    readonly property int poolN2: 5 + root.plainDecorative.length
    property int fired: 0
    property int activated: 0
    property var badKinds: []
    Connections {
        target: mockServices.reelActions
        function onFlourished(id: string): void {
            root.fired++;
        }
    }
    Connections {
        target: root.frame ? root.frame.buttons.power : null
        function onActivated(index: int, item: var): void {
            root.activated++;
        }
    }
    Connections {
        target: root.frame ? root.frame.buttons.idle : null
        function onActivated(index: int, item: var): void {
            root.activated++;
        }
    }
    // every reel clock's kind, every tick: a random play is never a fire
    function watchKinds(): void {
        for (const e of FlourishRegistry.entries)
            if (e.kind !== undefined && (e.kind === "fire" || e.kind === "engage") && root.badKinds.indexOf(FlourishRegistry.keyOf(e) + " " + e.kind) < 0)
                root.badKinds = root.badKinds.concat([FlourishRegistry.keyOf(e) + " " + e.kind]);
    }

    function mineKeys(): var {
        return FlourishRegistry.entriesUnder(root.frame).map(e => FlourishRegistry.keyOf(e)).filter(k => k !== "");
    }
    function playingKeys(): var {
        return FlourishRegistry.entriesUnder(root.frame).filter(e => e.playing).map(e => FlourishRegistry.keyOf(e));
    }
    function allQuiet(): bool {
        return root.playingKeys().length === 0;
    }
    function allClosed(): bool {
        const e = root.frame.engine;
        return e.thePopup.phase === "closed" && e.theReel.phase === "closed" && e.theReelChild.phase === "closed";
    }
    function setFlourishes(obj: var): void {
        mockServices.shellConfig.apply({ oled: { flourishes: obj } });
    }

    // ---- the sequencer: wait for a condition (polled), with a deadline counted in live time ----
    property var _q: []
    property var _cur: null
    property real _since: 0
    property real _spent: 0
    property real _lastTick: 0
    function step(label: string, run: var, until: var, ms: int): void {
        root._q = root._q.concat([{ label: label, run: run, until: until, ms: ms || 6000 }]);
    }
    Timer {
        interval: 25
        repeat: true
        running: true
        onTriggered: {
            root.watchKinds();
            const now = Date.now();
            const dt = root._lastTick > 0 ? Math.min(now - root._lastTick, 100) : 0;
            root._lastTick = now;
            if (!root._cur) {
                if (root._q.length === 0)
                    return;
                root._cur = root._q[0];
                root._q = root._q.slice(1);
                root._since = now;
                root._spent = 0;
                try {
                    root._cur.run();
                } catch (e) {
                    root.check(root._cur.label + " (threw)", false, String(e));
                    root._cur = null;
                }
                return;
            }
            root._spent += dt;
            let done = false;
            try {
                done = !root._cur.until || root._cur.until();
            } catch (e) {
                done = false;
            }
            if (done) {
                root._cur = null;
            } else if (root._spent > root._cur.ms || now - root._since > 4 * root._cur.ms) {
                root.check(root._cur.label + " (waited)", false, "timed out; playing " + JSON.stringify(root.playingKeys()) + ", lastTurn " + (root.sched ? root.sched.lastTurn : "-"));
                root._cur = null;
            }
        }
    }

    // ---- the script ----
    property var drawn: []
    property string turned: ""
    function turnAndWait(label: string): void {
        root.step(label + ": quiet", () => {}, () => root.allQuiet(), 6000);
        root.step(label, () => {
            root.turned = root.sched.turn();
            if (root.turned !== "")
                root.drawn = root.drawn.concat([root.turned]);
        }, () => true);
    }

    Component.onCompleted: {
        root.step("frame up", () => {}, () => !!root.frame && root.frame.ready && root.frame.buttons.theme.width > 0, 20000);
        root.step("settled", () => {}, () => mockServices.settled && root.allClosed(), 60000);

        // ---- the registry ----
        root.step("registry", () => {
            const keys = root.mineKeys();
            const want = ["power.sleep", "power.poweroff", "power.reboot", "power.hibernate", "power.logout", "power.lock",
                          "idleReel.zzz", "idleReel.sunset", "idleReel.mug", "idleReel.infinity", "update", "bell", "player", "weather",
                          "audio.speaker", "audio.mic", "aerial.wifi", "aerial.bluetooth"].concat(root.plainDecorative);
            const missing = want.filter(k => keys.indexOf(k) < 0);
            console.log("FLPOOL registered under the frame: " + keys.join(" "));
            root.check("registry: every flourish of the frame is registered under its name", missing.length === 0, "missing " + missing.join(" "));
            root.check("registry: a flourish outside the frame is not the frame's", FlourishRegistry.entries.indexOf(outsideFl) >= 0
                       && FlourishRegistry.entriesUnder(root.frame).indexOf(outsideFl) < 0, "");
            root.check("registry: at rest nothing plays on the frame and the shift is not held", !FlourishRegistry.playingUnder(root.frame) && !root.frame.oledHeld,
                       JSON.stringify(root.playingKeys()) + " held=" + root.frame.oledHeld);
        });
        // the archive's flourish holds the pixel shift (the shift never waited for it before the registry)
        root.step("archive plays", () => {
            const u = FlourishRegistry.entriesUnder(root.frame).find(e => FlourishRegistry.keyOf(e) === "update");
            root._ok = !!u && u.demo();
        }, () => true);
        root.step("archive holds", () => {
            root.check("oledHeld: the archive's flourish holds the shift while it plays", root._ok && root.frame.oledHeld && FlourishRegistry.playingUnder(root.frame),
                       "played=" + root._ok + " held=" + root.frame.oledHeld);
        }, () => true);
        root.step("archive ends", () => {}, () => root.allQuiet() && !root.frame.oledHeld, 6000);

        // ---- the bag and the demo path, with the default pool, idle ----
        root.step("idle pinned", () => {
            root.sched.forceIdle = true;
            root.setFlourishes({});
        }, () => root.sched.idle && root.sched.armed);
        root.step("the wait while idle", () => {
            const n = root.sched.nextMs;
            root.check("config: the wait while idle is drawn in [120, 240] s (" + n + " ms)", n >= 120000 && n <= 240000, String(n));
            root.drawn = [];
        });
        for (let i = 0; i < 2 * root.poolN; i++)
            root.turnAndWait("bag turn " + i);
        root.step("bag judged", () => {
            const pool = ["power.lock", "idleReel." + ({ off: "zzz", soft: "sunset", normal: "mug", hard: "infinity" })[mockServices.idle.mode], "update", "weather",
                          "audio.speaker", "audio.mic", "aerial.wifi", "aerial.bluetooth"].concat(root.plainDecorative);
            const n = root.poolN;
            const d = root.drawn;
            console.log("FLPOOL drawn: " + d.join(" ") + " (pool " + pool.join(" ") + ")");
            const r1 = d.slice(0, n).slice().sort().join(" "), r2 = d.slice(n, 2 * n).slice().sort().join(" ");
            const p = pool.slice().sort().join(" ");
            root.check("bag: the default pool is the decorative glyphs on show (the reels' selected items, the archive, the weather icon, the audio and networking pills' halves, the plain decorative glyphs)", d.every(k => pool.indexOf(k) >= 0), d.join(" "));
            root.check("bag: every glyph plays once before any plays twice (two rounds)", d.length === 2 * n && r1 === p && r2 === p, d.join(" "));
            root.check("bag: a new round does not start with the last one drawn", d.length === 2 * n && d[n] !== d[n - 1], d.join(" "));
            root.check("demo: no turn took the fire path (no fire / engage kind, no ReelActions.flourished, no activation)",
                       root.badKinds.length === 0 && root.fired === 0 && root.activated === 0, "kinds " + JSON.stringify(root.badKinds) + " fired " + root.fired + " activated " + root.activated);
        }, () => root.allQuiet(), 6000);

        // ---- the gates ----
        root.step("popup open", () => { root.frame.owners.theme.toggle(); }, () => root.frame.engine.thePopup.phase === "open", 10000);
        root.turnAndWait("under the popup");
        root.step("popup judged", () => {
            root.check("gate: a popup open on this screen skips the turn", root.turned === "" && root.sched.lastTurn === "skip popup" && root.allQuiet(),
                       "turned '" + root.turned + "' lastTurn " + root.sched.lastTurn);
        });
        root.step("popup close", () => { root.frame.owners.theme.toggle(); }, () => root.allClosed(), 10000);
        root.step("strip open", () => { root.frame.owners.power.pinnedOpen = true; }, () => root.frame.engine.theReel.phase === "open", 8000);
        root.turnAndWait("under the strip");
        root.step("strip judged", () => {
            root.check("gate: the reel's strip out skips the turn", root.turned === "" && root.sched.lastTurn === "skip popup", root.sched.lastTurn);
        });
        root.step("strip close", () => { root.frame.owners.power.pinnedOpen = false; }, () => root.allClosed(), 8000);
        root.step("bars away", () => { mockServices.barsShown = false; }, () => root.frame.hideT > 0.5, 8000);
        root.turnAndWait("bars away");
        root.step("bars judged", () => {
            root.check("gate: the bars away skip the turn", root.turned === "" && root.sched.lastTurn === "skip bars away", root.sched.lastTurn);
        });
        root.step("bars back", () => { mockServices.barsShown = true; }, () => root.frame.hideT === 0, 8000);
        root.step("fullscreen", () => {
            const f = mockServices.focus;
            f.setFocused("eDP-1");
            f.setActiveWorkspace("eDP-1", 1);
            f.setFullscreen(true);
        }, () => root.frame.fullscreenHere, 6000);
        root.turnAndWait("over a fullscreen window");
        root.step("fullscreen judged", () => {
            root.check("gate: a fullscreen window on this screen skips the turn", root.turned === "" && root.sched.lastTurn === "skip fullscreen", root.sched.lastTurn);
            mockServices.focus.setFullscreen(false);
        }, () => true);
        root.step("fullscreen gone", () => {}, () => !root.frame.fullscreenHere && root.frame.hideT === 0 && root.allClosed(), 8000);
        root.step("oled off", () => {
            mockServices.shellConfig.apply({ oled: { enabled: false } });
        }, () => !root.sched.armed);
        root.turnAndWait("oled off");
        root.step("oled judged", () => {
            root.check("gate: the OLED care off (shell.jsonc oled.enabled) arms nothing and skips the turn", root.turned === "" && root.sched.lastTurn === "skip off" && root.sched.nextMs === 0,
                       root.sched.lastTurn + " next " + root.sched.nextMs);
            root.setFlourishes({});
        });
        root.turnAndWait("after the gates");
        root.step("after the gates judged", () => {
            root.check("gate: with every reason gone a turn plays again", root.turned !== "", root.sched.lastTurn);
        });

        // ---- the config ----
        root.step("idle off", () => { root.setFlourishes({ idle: false }); }, () => !root.sched.armed);
        root.turnAndWait("idle off");
        root.step("idle off judged", () => {
            root.check("config: idle false while idle arms nothing and plays nothing", root.turned === "" && root.sched.lastTurn === "skip off" && root.sched.nextMs === 0,
                       root.sched.lastTurn + " next " + root.sched.nextMs);
        });
        root.step("active", () => {
            root.sched.forceIdle = false;
        }, () => root.sched.armed);
        root.step("active judged", () => {
            const n = root.sched.nextMs;
            root.check("config: idle false still plays while active, the wait in [600, 1200] s (" + n + " ms)", n >= 600000 && n <= 1200000, String(n));
            root.setFlourishes({ active: false, idleEveryS: [30, 30] });
        }, () => true);
        root.step("active off", () => {}, () => !root.sched.armed);
        root.step("active off judged", () => {
            root.check("config: active false while active arms nothing", !root.sched.armed && root.sched.nextMs === 0, "next " + root.sched.nextMs);
            root.sched.forceIdle = true;
        });
        root.step("idle range", () => {}, () => root.sched.armed);
        root.step("idle range judged", () => {
            root.check("config: idleEveryS [30, 30] waits 30 s", root.sched.nextMs === 30000, String(root.sched.nextMs));
            root.setFlourishes({ idleEveryS: "soon", glyphs: { power: "yes" } });
        });
        root.step("bad values judged", () => {
            const c = mockServices.shellConfig.oledFlourishes;
            root.check("config: a bad value takes its default and is named", c.idleEveryS[0] === 120 && c.idleEveryS[1] === 240 && c.problems.length === 2
                       && root.sched.nextMs >= 120000, JSON.stringify(c));
            // a group off, a glyph key that wins over its group, an event glyph switched on
            const sel = ({ off: "zzz", soft: "sunset", normal: "mug", hard: "infinity" })[mockServices.idle.mode];
            const g = { power: false, idleReel: false, bell: true, audio: false, aerial: false };
            g["aerial.bluetooth"] = true;
            g["idleReel." + sel] = true;
            root.setFlourishes({ glyphs: g });
            root.drawn = [];
            root._sel = sel;
        }, () => true);
        for (let i = 0; i < 2 * root.poolN2; i++)
            root.turnAndWait("glyph turn " + i);
        root.step("glyphs judged", () => {
            const d = root.drawn;
            const n = root.poolN2;
            const want = ["bell", "idleReel." + root._sel, "update", "weather", "aerial.bluetooth"].concat(root.plainDecorative).sort().join(" ");
            console.log("FLPOOL drawn with the switches: " + d.join(" "));
            root.check("config: a group off is out, a glyph key wins over its group, an event glyph switched on is in", d.length === 2 * n
                       && d.slice(0, n).slice().sort().join(" ") === want && d.slice(n).slice().sort().join(" ") === want, d.join(" "));
            root.check("demo: still no fire path after every turn", root.badKinds.length === 0 && root.fired === 0 && root.activated === 0,
                       "kinds " + JSON.stringify(root.badKinds) + " fired " + root.fired + " activated " + root.activated);
        }, () => root.allQuiet(), 6000);

        // ---- a delegate replaced in one update ----
        root.step("replace", () => { stale.model = [2]; }, () => true);
        root.step("replace settles", () => {}, () => FlourishRegistry.entries.filter(e => e.group === "probestale").length <= 1 && root._ticks++ > 8, 4000);
        root.step("staleheld judged", () => {
            const live = stale.instances.length === 1 ? stale.instances[0] : null;
            const mine = FlourishRegistry.entries.filter(e => e.group === "probestale");
            root.check("staleheld: a replaced delegate leaves the live entry in the registry", !!live && mine.length === 1 && mine[0] === live.fl,
                       mine.length + " entries");
        });
        root.step("end", () => {
            console.log("FLPOOL RESULT " + (root.fails === 0 && root.checks >= 20 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
            Qt.quit();
        });
    }
    property bool _ok: false
    property string _sel: ""
    property int _ticks: 0
}
