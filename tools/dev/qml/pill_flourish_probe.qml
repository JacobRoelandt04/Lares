pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/common/flourish"
import "modules/bar/audio"
import "modules/aerial/bar"
import "modules/aerial/bar/AerialPill.js" as PillFacts
import "modules/common/components/GlyphOutline.js" as O
import "modules/bar/audio/parts/AudioPose.js" as APose
import "modules/bar/audio/parts/AudioParts.js" as AParts
import "modules/aerial/bar/parts/NetPose.js" as NPose
import "modules/aerial/bar/parts/NetParts.js" as NParts

// =============================================================================
// pill_flourish_probe.qml -- the audio pill's and the networking pill's flourishes (AudioPose.js, NetPose.js) on the real
// buttons; the second half of tools/dev/glyph_flourish_probe.sh.
//
//   pill_rest        nothing plays after load, every glyph is its plain Text (not posing, no parts)
//   pill_identity    every glyph of both tables, on and off: the pose at t = 0 and at t = life is the font's outline to the
//                    digit, and nothing is thrown there
//   pill_wifi_level  THE STATE IS NEVER MISSTATED: for every fan (each level, each alert) at every 10 ms of a play, on and off,
//                    the fan's ink as a share of its own box is the SHOWN glyph's (measured from the emitted path, not from
//                    the pose's numbers): the fill never reads as another level
//   pill_arc         the thrown arc is OUTSIDE the fan at every sample (every point further from the tip than the fan's
//                    furthest), thinner than the fan's rim, and never thrown with the radio off
//   pill_speaker     at every sample the speaker shows its own waves and no more (one path per part it has, each wave's ink
//                    its own), the cone's back edge stays on the pen (the bar's pinned edge), and the ONE thing it lets out
//                    says what it does: a speaker that SOUNDS (on, a wave on it) throws a wave -- an arc, thin, beyond its
//                    outermost ink -- and never a puff; one that makes no sound (muted, or no wave on it) lets out a PUFF --
//                    ONE cloud at every sample (one outline: never loose discs, which read as bubbles), as wide as tall give
//                    or take a third (never an arc), clear of its ink, all but gone by its last sample (its ink times its
//                    share of the ink, against that at its most) -- and never a wave
//   pill_near        JUST INSIDE each end of its clock every pose is still the rest's picture (its ink box within 12 font
//                    units -- a tenth of a pixel --, its ink within 1.5 %): nothing pops in at the first frame or out at the last
//   pill_mic         the capsule is thrown and comes back the same capsule (its ink its own at every sample, the stem's foot
//                    where it was); on, it turns right over and rises well clear of the cradle, and the thud's two marks fly
//                    only after it has landed, thin, clear of the capsule; MUTED it only hops and shakes (never over), and
//                    NO mark is ever thrown
//   pill_phones      the cups are drawn in before the burst and thrown out after it (the outline narrower, then wider, the
//                    band's top where it was), the waves fly only from the burst on, outside the cups, thin; muted: no wave,
//                    a smaller spring
//   pill_rune        the five pieces of the rune's line ARE the glyph (sampled against the font's outline); the rune
//                    EMPTIES (most of its ink gone at some sample) and is whole again just inside both ends; every cut is
//                    straight (no curve is ever emitted: the corners stay sharp); a connected rune's dots stay on their
//                    centres; switched OFF it plays the very same (as long, and path for path at every sample: only its
//                    ink says it is off)
//   pill_plane       the plane bunches up before it stretches (its length under, then over, the glyph's), and the wind is
//                    straight streaks that never touch the plane
//   pill_lan         the wire only ever THICKENS (never thinner than the glyph's, its two ends where they were); with a link
//                    the lower box takes every bulge; with none it never moves and the bulge is gone before the corner
//   pill_bounds      no pose leaves its half of the pill (every glyph, every sample, at the bar's size)
//   pill_half_*      the pointer's rule PER HALF from the one shared area: an entry that does not move plays nothing, its
//                    first motion plays THAT half once and not the other, motions after it play nothing, crossing to the
//                    other half is that half's entry, a leave and a new entry play again
//   pill_ends        a play ends by itself: the Text is back, no clock runs
//   pill_registry    each half is in the OLED care's registry under its name (audio.speaker, audio.mic, aerial.wifi,
//                    aerial.bluetooth), decorative, and demo() plays it as a hover would
//
// Prints `FLOURISH_PROBE <check> ok|FAIL ...` and `PILL_PROBE RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 320
        implicitHeight: 120
        visible: true
        color: Theme.surface

        AerialPillStand {
            id: netSvc
        }
        AudioBarButton {
            id: bAudio
            x: 40
            y: 40
            outputVolume: 0.9
        }
        AerialBarButton {
            id: bNet
            x: 160
            y: 40
            service: netSvc
        }

        TestCase {
            id: tc
            name: "pillprobe"
            when: false
        }

        property var plays: ({ speaker: [], mic: [], wifi: [], bluetooth: [] })
        Connections {
            target: bAudio.outputFlourish
            function onPlayed(why) {
                win.plays.speaker.push(why);
            }
        }
        Connections {
            target: bAudio.inputFlourish
            function onPlayed(why) {
                win.plays.mic.push(why);
            }
        }
        Connections {
            target: bNet.netFlourish
            function onPlayed(why) {
                win.plays.wifi.push(why);
            }
        }
        Connections {
            target: bNet.btFlourish
            function onPlayed(why) {
                win.plays.bluetooth.push(why);
            }
        }
        function counts() {
            return [win.plays.speaker.length, win.plays.mic.length, win.plays.wifi.length, win.plays.bluetooth.length].join(",");
        }

        property int fails: 0
        function check(name, ok, detail) {
            console.log("FLOURISH_PROBE " + name + " " + (ok ? "ok" : "FAIL") + " " + (detail || ""));
            if (!ok)
                win.fails++;
        }

        // ---- the pill's facts (AerialPill.js): what each state of the net half is, from the service's facts ----
        function pillFacts() {
            const net = (o, extra) => Object.assign({ wifi: { present: true, radioOn: true, hardBlocked: false, networks: [{ key: "a", connected: true, signalBand: 1, trusted: true }] },
                wired: { jacks: [] }, hotspot: { active: false }, bt: { present: true, powered: true, devices: [] }, proton: { state: "down" }, health: { pads: [] }, airplane: { on: false }, rates: { iface: "" } }, o || {}, extra || {});
            const home = PillFacts.of(net());
            win.check("pillfacts_home", home.netOn && home.bars === 3 && !home.vpnUp && !home.publicOpen && home.fault === "" && !home.hotspotOn && !home.wiredShown, JSON.stringify(home));
            win.check("pillfacts_vpn", PillFacts.of(net({ proton: { state: "up" } })).vpnUp, "tunnel up -> the padlock badge");
            const pub = PillFacts.of(net({ wifi: { present: true, radioOn: true, networks: [{ key: "a", connected: true, signalBand: 0, trusted: false }] } }));
            win.check("pillfacts_public", pub.publicOpen && pub.bars === 4, JSON.stringify(pub));
            const pubTun = PillFacts.of(net({ proton: { state: "up" }, wifi: { present: true, radioOn: true, networks: [{ key: "a", connected: true, signalBand: 0, trusted: false }] } }));
            win.check("pillfacts_public_tunnelled", !pubTun.publicOpen && pubTun.vpnUp, "a Public network with the tunnel up is the padlock, not the open one");
            win.check("pillfacts_hotspot", PillFacts.of(net({ hotspot: { active: true } })).hotspotOn, "the broadcasting glyph");
            win.check("pillfacts_fault", PillFacts.of(net({ health: { pads: [{ id: "net", state: "warn" }] } })).fault === "warn"
                      && PillFacts.of(net({ health: { pads: [{ id: "net", state: "warn" }, { id: "dns", state: "fail" }] } })).fault === "error"
                      && PillFacts.of(net({ health: { pads: [{ id: "net", state: "ok" }, { id: "dns", state: "unknown" }, { id: "link", state: "testing" }] } })).fault === "",
                      "warn, then the worst wins (error); ok / unknown / testing are no fault");
            win.check("pillfacts_airplane", !PillFacts.of(net({ airplane: { on: true } })).netOn && PillFacts.of(net({ airplane: { on: true } })).airplane, "the plane, the net half off");
            const wired = PillFacts.of(net({ wired: { jacks: [{ iface: "e", connected: true }] }, wifi: { present: false, networks: [] } }));
            win.check("pillfacts_wired", wired.wiredShown && wired.netOn, JSON.stringify(wired));
            // both up: the traffic decides (the scene's own rule)
            const both = o => PillFacts.of(net({ wired: { jacks: [{ iface: "e", connected: true }] }, rates: { iface: o } }));
            win.check("pillfacts_both", both("e").wiredShown && !both("wlp").wiredShown, "the cable carries only while the traffic runs over it");
            win.check("pillfacts_off", !PillFacts.of(net({ wifi: { present: true, radioOn: false, networks: [] } })).netOn && PillFacts.of(net({ bt: { present: true, powered: false, devices: [] } })).btOn === false
                      && PillFacts.of(net({ bt: { present: true, powered: true, devices: [{ connected: true }] } })).btConnected, "radio off, bluetooth off, a connected device");
        }

        // ---- reading an emitted path back: its subpaths as point lists (curves flattened), in the units it was emitted in ----
        function points(d) {
            const subs = [];
            let cur = null, last = null;
            const re = /([MLQZ])([^MLQZ]*)/g;
            let m;
            while ((m = re.exec(d)) !== null) {
                const v = m[2].trim().length > 0 ? m[2].trim().split(/\s+/).map(Number) : [];
                if (m[1] === "M") {
                    cur = [[v[0], v[1]]];
                    subs.push(cur);
                    last = [v[0], v[1]];
                } else if (m[1] === "L") {
                    cur.push([v[0], v[1]]);
                    last = [v[0], v[1]];
                } else if (m[1] === "Q") {
                    for (let i = 1; i <= 8; ++i) {
                        const f = i / 8, g = 1 - f;
                        cur.push([g * g * last[0] + 2 * g * f * v[0] + f * f * v[2], g * g * last[1] + 2 * g * f * v[1] + f * f * v[3]]);
                    }
                    last = [v[2], v[3]];
                }
            }
            return subs;
        }
        // the ink of a path under the winding rule for the font's nesting (holes wound against outlines): |sum of signed areas|
        function ink(subs) {
            let a = 0;
            for (const s of subs)
                for (let i = 0; i < s.length; ++i) {
                    const p = s[i], q = s[(i + 1) % s.length];
                    a += p[0] * q[1] - q[0] * p[1];
                }
            return Math.abs(a) / 2;
        }
        function box(subs) {
            let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
            for (const s of subs)
                for (const p of s) {
                    x0 = Math.min(x0, p[0]);
                    x1 = Math.max(x1, p[0]);
                    y0 = Math.min(y0, p[1]);
                    y1 = Math.max(y1, p[1]);
                }
            return [x0, y0, x1, y1];
        }
        // the nearest and the furthest point of a path from (cx, cy)
        function reach(subs, cx, cy) {
            let lo = 1e9, hi = 0;
            for (const s of subs)
                for (const p of s) {
                    const r = Math.hypot(p[0] - cx, p[1] - cy);
                    lo = Math.min(lo, r);
                    hi = Math.max(hi, r);
                }
            return [lo, hi];
        }
        // a pose in FONT UNITS, y up: k = 1 at the origin, and emit's flip undone
        function pose(P, text, t, live) {
            return P.path(text, t, P.life(text, live), live, null, 2048, 0, 0).map(d => win.points(d).map(s => s.map(p => [p[0], -p[1]])));
        }
        function shades(P, text, t, live) {
            return P.pose(text, t, P.life(text, live), live, null, 2048, 0, 0).shades;
        }
        // the rest's picture in the same units
        function rest(T, hex) {
            return T.G[hex].parts.map(p => win.points(O.emit(p, O.same, 1, 0, 0)).map(s => s.map(q => [q[0], -q[1]])));
        }
        // is (x, y) ink of any of `paths` (each a list of subpaths: the winding rule per path)
        function inked(paths, x, y) {
            for (const subs of paths) {
                let w = 0;
                for (const s of subs)
                    for (let i = 0; i < s.length; ++i) {
                        const a = s[i], b = s[(i + 1) % s.length];
                        if ((a[1] <= y) !== (b[1] <= y)) {
                            const xi = a[0] + (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]);
                            if (xi > x)
                                w += b[1] > a[1] ? 1 : -1;
                        }
                    }
                if (w !== 0)
                    return true;
            }
            return false;
        }
        // a picture sampled on a grid over `b`: one bool per sample
        function sampled(paths, b, step) {
            const out = [];
            for (let y = b[1] + step / 2; y < b[3]; y += step)
                for (let x = b[0] + step / 2; x < b[2]; x += step)
                    out.push(win.inked(paths, x, y));
            return out;
        }
        function count(a) {
            let n = 0;
            for (const v of a)
                if (v)
                    n++;
            return n;
        }
        function differ(a, b) {
            let n = 0;
            for (let i = 0; i < a.length; ++i)
                if (a[i] !== b[i])
                    n++;
            return n;
        }
        function allBox(paths) {
            let b = [1e9, 1e9, -1e9, -1e9];
            for (const subs of paths) {
                if (subs.length === 0)
                    continue;
                const c = win.box(subs);
                b = [Math.min(b[0], c[0]), Math.min(b[1], c[1]), Math.max(b[2], c[2]), Math.max(b[3], c[3])];
            }
            return b;
        }
        function glyphOf(hex) {
            return String.fromCodePoint(parseInt(hex, 16));
        }

        function identity(P, T, tag) {
            let bad = [];
            for (const hex in T.G) {
                const text = win.glyphOf(hex);
                for (const live of [true, false])
                    for (const t of [0, P.life(text, live)]) {
                        const got = P.path(text, t, P.life(text, live), live, null, 15, 3, 11);
                        const want = T.G[hex].parts.map(p => O.emit(p, O.same, 15 / T.UNITS, 3, 11));
                        if (got.length !== want.length || got.some((d, i) => d !== want[i]))
                            bad.push(hex + "@" + t + (live ? "" : " off"));
                    }
            }
            return bad;
        }

        function wifiLevel() {
            // the share of its own box a fan's ink takes: what "how full" is, whatever the fan's size
            const share = subs => {
                const b = win.box(subs);
                return win.ink(subs) / ((b[2] - b[0]) * (b[3] - b[1]));
            };
            let worst = 0, where = "", arcBad = [], n = 0;
            for (const hex in NParts.G) {
                if (NParts.G[hex].kind !== "fan")
                    continue;
                const text = win.glyphOf(hex);
                const shown = share(win.points(O.emit(NParts.G[hex].parts[0], O.same, 1, 0, 0)));
                const parts = NParts.G[hex].parts.length;
                for (const live of [true, false])
                    for (let t = 0; t <= NPose.life(text, live); t += 10) {
                        const ps = win.pose(NPose, text, t, live);
                        const d = Math.abs(share(ps[0]) - shown) / shown;
                        if (d > worst) {
                            worst = d;
                            where = hex + "@" + t;
                        }
                        n++;
                        if (ps.length > parts + (live ? 1 : 0))
                            arcBad.push(hex + "@" + t + " thrown with the radio off");
                        if (ps.length > parts) {
                            const b = win.box(ps[0]);
                            const tip = [(b[0] + b[2]) / 2, b[1]];
                            const fan = win.reach(ps[0], tip[0], tip[1]), arc = win.reach(ps[parts], tip[0], tip[1]);
                            if (arc[0] < fan[1])
                                arcBad.push(hex + "@" + t + " inside the fan by " + (fan[1] - arc[0]).toFixed(0));
                            if (arc[1] - arc[0] > 172)
                                arcBad.push(hex + "@" + t + " as thick as the rim");
                        }
                    }
            }
            win.check("pill_wifi_level", n > 500 && worst < 0.01, "samples=" + n + " worst=" + (100 * worst).toFixed(2) + "% " + where);
            win.check("pill_arc", arcBad.length === 0, arcBad.slice(0, 3).join("; "));
        }

        function speaker() {
            const bad = [];
            let n = 0, waves = 0, puffs = 0;
            // a thrown subpath's shape: a wave is an arc (tall and thin), a puff a round cloud
            const round = s => {
                const b = win.box([s]);
                const r = (b[2] - b[0]) / (b[3] - b[1]);
                return r > 0.75 && r < 1.34;
            };
            for (const hex of ["f057f", "f0580", "f057e"]) {
                const g = AParts.G[hex], text = win.glyphOf(hex);
                const own = g.parts.map(p => win.ink(win.points(O.emit(p, O.same, 1, 0, 0))));
                for (const live of [true, false]) {
                    const sounding = live && g.parts.length > 1, life = APose.life(text, live);
                    // the puff's ink times its share of the ink: at its most, and at its last sample
                    let most = 0, last = 0, any = 0;
                    if (APose.sounds(text, live) !== sounding)
                        bad.push(hex + " sounds() says " + !sounding);
                    for (let t = 0; t <= life; t += 10) {
                        const ps = win.pose(APose, text, t, live);
                        n++;
                        if (ps.length < g.parts.length || ps.length > g.parts.length + 1)
                            bad.push(hex + "@" + t + " paths=" + ps.length + (live ? "" : " muted"));
                        // each wave it has is its own ink, only moved
                        for (let i = 1; i < g.parts.length; ++i)
                            if (Math.abs(win.ink(ps[i]) - own[i]) > own[i] * 0.002)
                                bad.push(hex + "@" + t + " wave " + i + " changed");
                        if (Math.abs(win.box(ps[0])[0]) > 0.01)
                            bad.push(hex + "@" + t + " the cone left the pen by " + win.box(ps[0])[0].toFixed(2));
                        if (ps.length <= g.parts.length)
                            continue;
                        let far = 0;
                        for (let i = 0; i < g.parts.length; ++i)
                            far = Math.max(far, win.box(ps[i])[2]);
                        const w = ps[g.parts.length];
                        const isPuff = w.every(round);
                        const who = hex + "@" + t + (live ? "" : " muted");
                        // clear of the speaker's own ink: a wave by its inner edge on the axis (it is an arc about the mouth), a puff whole
                        const r = win.reach(w, APose.MOUTH[0], APose.MOUTH[1]);
                        const left = isPuff ? win.box(w)[0] : APose.MOUTH[0] + r[0];
                        if (left < far - 1)
                            bad.push(who + " thrown into the speaker's ink by " + (far - left).toFixed(0));
                        if (sounding) {
                            waves++;
                            if (isPuff)
                                bad.push(who + " a puff from a speaker that sounds");
                            if (r[1] - r[0] > 172 * 1.6)
                                bad.push(who + " thrown wave too thick");
                        } else {
                            puffs++;
                            any++;
                            if (!isPuff)
                                bad.push(who + " a WAVE from a speaker that makes no sound");
                            if (w.length !== 1)
                                bad.push(who + " the puff is " + w.length + " loose pieces (one cloud)");
                            const shade = win.shades(APose, text, t, live)[g.parts.length];
                            if (!(shade >= 0 && shade <= 1))
                                bad.push(who + " the puff's share of the ink is " + shade);
                            last = win.ink(w) * shade;
                            most = Math.max(most, last);
                        }
                    }
                    if (!sounding && (any < 20 || last > most * 0.03))
                        bad.push(hex + (live ? "" : " muted") + " the puff: " + any + " samples, still " + (100 * last / Math.max(1, most)).toFixed(1)
                                 + "% of its most at its last");
                }
            }
            win.check("pill_speaker", n > 300 && waves > 40 && puffs > 100 && bad.length === 0,
                      "samples=" + n + " waves=" + waves + " puffs=" + puffs + " " + bad.slice(0, 3).join("; "));
        }

        // just inside each end of its clock a pose is still the rest's picture
        function near() {
            const bad = [];
            let n = 0;
            const one = (P, T) => {
                for (const hex in T.G) {
                    const text = win.glyphOf(hex), g = T.G[hex];
                    const rest = win.rest(T, hex);
                    const rb = win.allBox(rest);
                    let rink = 0;
                    for (const subs of rest)
                        rink += win.ink(subs);
                    for (const live of [true, false]) {
                        const life = P.life(text, live);
                        for (const t of [1, life - 1]) {
                            const ps = win.pose(P, text, t, live);
                            const sh = win.shades(P, text, t, live);
                            n++;
                            const pb = win.allBox(ps);
                            const off = Math.max(Math.abs(pb[0] - rb[0]), Math.abs(pb[1] - rb[1]), Math.abs(pb[2] - rb[2]), Math.abs(pb[3] - rb[3]));
                            // a kick starts at speed: a millisecond in, the fan is 9 units larger
                            if (off > 12)
                                bad.push(hex + "@" + t + (live ? "" : " off") + " ink box off by " + off.toFixed(1));
                            if (g.kind === "rune")
                                continue;      // its pieces overlap: sampled in pill_rune
                            let pink = 0;
                            ps.forEach((subs, i) => pink += win.ink(subs) * (i < sh.length ? sh[i] : 1));
                            if (Math.abs(pink - rink) > rink * 0.015)
                                bad.push(hex + "@" + t + (live ? "" : " off") + " ink " + (100 * (pink / rink - 1)).toFixed(2) + "%");
                        }
                    }
                }
            };
            one(APose, AParts);
            one(NPose, NParts);
            win.check("pill_near", n > 90 && bad.length === 0, "samples=" + n + " " + bad.slice(0, 4).join("; "));
        }

        function mic() {
            const bad = [];
            const hex = "f036c", text = win.glyphOf(hex), g = AParts.G[hex];
            const own = win.ink(win.points(O.emit(g.parts[0], O.same, 1, 0, 0)));
            const cx = APose.CAPSULE[0], cy = APose.CAPSULE[1];
            let n = 0;
            const seen = {};
            for (const live of [true, false]) {
                const life = APose.life(text, live), land = APose.landMs(live, null);
                let top = 0, over = false, marks = 0, lean = 0;
                for (let t = 0; t <= life; t += 10) {
                    const ps = win.pose(APose, text, t, live);
                    const who = "@" + t + (live ? "" : " muted");
                    n++;
                    if (Math.abs(win.ink(ps[0]) - own) > own * 0.004)
                        bad.push(who + " the capsule's ink changed");
                    if (Math.abs(win.box(ps[1])[1] - APose.FOOT_Y) > 0.01)
                        bad.push(who + " the stem's foot moved");
                    // where the capsule's head (its first point) is about its own middle
                    const b = win.box(ps[0]);
                    const mx = (b[0] + b[2]) / 2, my = (b[1] + b[3]) / 2, head = ps[0][0][0];
                    top = Math.max(top, my - cy);
                    if (head[1] < my - 100)
                        over = true;
                    lean = Math.max(lean, Math.abs(Math.atan2(head[0] - mx, head[1] - my)) * 180 / Math.PI);
                    if (ps.length > 2) {
                        marks++;
                        if (!live)
                            bad.push(who + " a mark from a MUTED microphone");
                        if (t < land)
                            bad.push(who + " a mark before the capsule landed (" + land.toFixed(0) + ")");
                        const r = win.reach(ps[2], cx, cy);
                        if (r[0] < 340 || ps[2].length !== 2)
                            bad.push(who + " marks=" + ps[2].length + " nearest " + r[0].toFixed(0) + " from the capsule's middle");
                        for (const s of ps[2]) {
                            const q = win.reach([s], cx, cy);
                            if (q[1] - q[0] > 172)
                                bad.push(who + " a mark as thick as the cradle");
                        }
                    }
                }
                seen[live] = { top: top, over: over, marks: marks, lean: lean };
            }
            const on = seen[true], off = seen[false];
            if (!on.over || on.top < 350 || on.marks < 15)
                bad.push("on: over=" + on.over + " rose " + on.top.toFixed(0) + " marks=" + on.marks);
            if (off.over || off.lean > 25 || off.top > 200 || off.top < 60 || off.marks !== 0)
                bad.push("muted: over=" + off.over + " lean " + off.lean.toFixed(0) + " rose " + off.top.toFixed(0) + " marks=" + off.marks);
            win.check("pill_mic", n > 120 && bad.length === 0, "samples=" + n + " on rose " + on.top.toFixed(0) + ", muted " + off.top.toFixed(0)
                      + " (lean " + off.lean.toFixed(0) + " deg) " + bad.slice(0, 3).join("; "));
        }

        function phones() {
            const bad = [];
            let n = 0;
            for (const hex of ["f02cb", "f02ce"]) {
                const text = win.glyphOf(hex), g = AParts.G[hex];
                const rb = win.box(win.rest(AParts, hex)[0]);
                const out = {};
                for (const live of [true, false]) {
                    const life = APose.life(text, live), build = APose.DEFAULTS.buildMs;
                    let narrow = 0, wide = 0, waves = 0;
                    for (let t = 0; t <= life; t += 10) {
                        const ps = win.pose(APose, text, t, live);
                        const who = hex + "@" + t + (live ? "" : " muted");
                        n++;
                        const b = win.box(ps[0]);
                        if (Math.abs(b[3] - rb[3]) > 0.01)
                            bad.push(who + " the band's top moved");
                        if (Math.abs((b[0] + b[2]) / 2 - (rb[0] + rb[2]) / 2) > 0.5)
                            bad.push(who + " the cups are not thrown alike");
                        const d = (b[2] - b[0]) - (rb[2] - rb[0]);
                        if (t <= build) {
                            narrow = Math.min(narrow, d);
                            if (d > 0.01)
                                bad.push(who + " wider before the burst");
                        } else {
                            wide = Math.max(wide, d);
                        }
                        for (let i = 1; i < ps.length; ++i) {
                            waves++;
                            if (!live)
                                bad.push(who + " a wave from MUTED headphones");
                            if (t < build)
                                bad.push(who + " a wave before the burst");
                            if (ps[i].length !== 2)
                                bad.push(who + " a burst of " + ps[i].length + " waves (one a side)");
                            for (const s of ps[i]) {
                                const c = win.box([s]);
                                // outside the cups as they stand at rest: left of the left one, right of the right one
                                if (!(c[2] < rb[0] + 1 || c[0] > rb[2] - 1))
                                    bad.push(who + " a wave over the glyph [" + c[0].toFixed(0) + ".." + c[2].toFixed(0) + "]");
                                if (c[2] - c[0] > 172 * 1.5)
                                    bad.push(who + " a wave too thick");
                            }
                        }
                    }
                    out[live] = { narrow: narrow, wide: wide, waves: waves };
                }
                const on = out[true], off = out[false];
                if (on.narrow > -80 || on.wide < 160 || on.waves < 25)
                    bad.push(hex + " on: drawn in " + on.narrow.toFixed(0) + ", thrown out " + on.wide.toFixed(0) + ", waves " + on.waves);
                if (off.waves !== 0 || off.wide >= on.wide * 0.8 || off.wide < 40)
                    bad.push(hex + " muted: thrown out " + off.wide.toFixed(0) + " (on " + on.wide.toFixed(0) + "), waves " + off.waves);
            }
            win.check("pill_phones", n > 300 && bad.length === 0, "samples=" + n + " " + bad.slice(0, 3).join("; "));
        }

        function rune() {
            const bad = [];
            let n = 0;
            // off the font's own grid (its edges run through whole units at 45 degrees: a step of 32 samples ON them)
            const step = 29.7;
            for (const hex of ["f00af", "f00b1"]) {
                const text = win.glyphOf(hex), g = NParts.G[hex];
                const rest = win.rest(NParts, hex);
                const b = g.box;
                const want = win.sampled(rest, b, step);
                const full = win.count(want);
                // the rune's own samples (not the dots')
                const runeOnly = win.count(win.sampled([rest[0]], b, step));
                const life = NPose.life(text, true);
                let least = full, curves = 0, unlike = 0;
                if (NPose.life(text, false) !== life)
                    bad.push(hex + " off is not the on rune's play: " + NPose.life(text, false) + " ms for " + life);
                const times = [1];
                for (let t = 20; t < life - 1; t += 20)
                    times.push(t);
                times.push(life - 1);
                for (const t of times) {
                    const d = NPose.path(text, t, life, true, null, 2048, 0, 0);
                    if (d.some(p => p.indexOf("Q") >= 0 && g.parts.length === 1))
                        curves++;
                    if (NPose.path(text, t, life, false, null, 2048, 0, 0).join("|") !== d.join("|"))
                        unlike++;
                    const ps = d.map(p => win.points(p).map(s => s.map(q => [q[0], -q[1]])));
                    const got = win.sampled(ps, b, step);
                    const c = win.count(got);
                    n++;
                    least = Math.min(least, c);
                    const who = hex + "@" + t;
                    // just inside each end: the whole glyph (the font's own 4 units of slack are a few samples)
                    if ((t === 1 || t === life - 1) && win.differ(got, want) > full * 0.012)
                        bad.push(who + " not the whole rune: " + win.differ(got, want) + " of " + full + " samples differ");
                    // never ink the glyph has not
                    let extra = 0;
                    for (let i = 0; i < got.length; ++i)
                        if (got[i] && !want[i])
                            extra++;
                    if (extra > full * (g.parts.length > 1 ? 0.09 : 0.012))
                        bad.push(who + " " + extra + " samples of ink outside the glyph");
                    if (g.parts.length > 1) {
                        // the dots: on their centres at every sample (the last two subpaths of the last path)
                        const dots = ps[3].slice(-2), at = rest[1];
                        for (let k = 0; k < 2; ++k) {
                            const p = win.box([dots[k]]), q = win.box([at[k]]);
                            if (Math.abs(p[0] + p[2] - q[0] - q[2]) > 0.5 || Math.abs(p[1] + p[3] - q[1] - q[3]) > 0.5 || p[2] - p[0] < q[2] - q[0] - 0.5)
                                bad.push(who + " dot " + k + " moved or shrank");
                        }
                    }
                }
                if (curves > 0)
                    bad.push(hex + ": " + curves + " samples with a curve in them (a corner rounded)");
                if (unlike > 0)
                    bad.push(hex + " off is not the on rune's play: " + unlike + " samples with another path");
                const share = (least - (full - runeOnly)) / runeOnly;
                if (share > 0.3)
                    bad.push(hex + ": at its emptiest " + (100 * share).toFixed(0) + "% of the rune is there");
            }
            win.check("pill_rune", n > 70 && bad.length === 0, "samples=" + n + " " + bad.slice(0, 3).join("; "));
        }

        function plane() {
            const bad = [];
            const hex = "f072", text = win.glyphOf(hex), life = NPose.life(text, true);
            const rb = win.box(win.rest(NParts, hex)[0]), len = rb[2] - rb[0];
            let n = 0, short = len, long = len, shortAt = 0, longAt = 0, wind = 0;
            for (let t = 0; t <= life; t += 10) {
                const ps = win.pose(NPose, text, t, true);
                n++;
                const b = win.box(ps[0]);
                if (b[2] - b[0] < short) {
                    short = b[2] - b[0];
                    shortAt = t;
                }
                if (b[2] - b[0] > long) {
                    long = b[2] - b[0];
                    longAt = t;
                }
                if (ps.length > 1) {
                    wind++;
                    for (const s of ps[1]) {
                        const c = win.box([s]);
                        if (c[3] - c[1] > 172 || s.length !== 4)
                            bad.push("@" + t + " a streak " + (c[3] - c[1]).toFixed(0) + " thick, " + s.length + " corners");
                        for (const q of s)
                            if (win.inked([ps[0]], q[0], q[1]))
                                bad.push("@" + t + " the wind touches the plane at " + q[0].toFixed(0) + "," + q[1].toFixed(0));
                    }
                }
            }
            if (short > len * 0.93 || long < len * 1.1 || shortAt >= longAt || wind < 15)
                bad.push("shortest " + (short / len).toFixed(2) + " @" + shortAt + ", longest " + (long / len).toFixed(2) + " @" + longAt + ", wind in " + wind + " samples");
            win.check("pill_plane", n > 60 && bad.length === 0, "samples=" + n + " shortest " + (short / len).toFixed(2) + " @" + shortAt
                      + " longest " + (long / len).toFixed(2) + " @" + longAt + " " + bad.slice(0, 3).join("; "));
        }

        function lan() {
            const bad = [];
            const hex = "f0318", text = win.glyphOf(hex);
            const rest = win.rest(NParts, hex);
            const wb = win.box(rest[1]), wink = win.ink(rest[1]), lower = win.box(rest[2]);
            let n = 0;
            const seen = {};
            for (const live of [true, false]) {
                const life = NPose.life(text, live);
                let fat = 0, taken = 0, was = false;
                for (let t = 0; t <= life; t += 10) {
                    const ps = win.pose(NPose, text, t, live);
                    const who = "@" + t + (live ? "" : " no link");
                    n++;
                    const b = win.box(ps[1]), a = win.ink(ps[1]);
                    if (Math.abs(b[3] - wb[3]) > 0.01 || Math.abs(b[2] - wb[2]) > 0.01)
                        bad.push(who + " the wire's ends moved");
                    if (a < wink * 0.999)
                        bad.push(who + " the wire is thinner than the glyph's");
                    fat = Math.max(fat, a / wink);
                    // the lower box taking a bulge: a pop (its box grows), counted per rise
                    const lb = win.box(ps[2]);
                    const up = lb[2] - lb[0] > lower[2] - lower[0] + 1;
                    if (up && !was)
                        taken++;
                    was = up && lb[2] - lb[0] > lower[2] - lower[0] + 20;
                    if (!live && (b[1] < wb[1] - 2 || up))
                        bad.push(who + (up ? " the lower box moved" : " the bulge is past the corner"));
                }
                seen[live] = { fat: fat, taken: taken };
            }
            if (seen[true].fat < 1.1 || seen[true].taken < 1 || seen[false].fat < 1.05 || seen[false].taken !== 0)
                bad.push("link: fattest " + seen[true].fat.toFixed(2) + " taken " + seen[true].taken + "; none: fattest " + seen[false].fat.toFixed(2)
                         + " taken " + seen[false].taken);
            win.check("pill_lan", n > 100 && bad.length === 0, "samples=" + n + " fattest " + seen[true].fat.toFixed(2) + " " + bad.slice(0, 3).join("; "));
        }

        // every pose inside its half of the pill, at the bar's size (the halves are 26 x 26; the glyph item's origin)
        function bounds() {
            const bad = [];
            const one = (P, T, btn, item, half, lives) => {
                for (const hex in T.G) {
                    const text = win.glyphOf(hex);
                    const adv = T.G[hex].adv * 15 / T.UNITS;
                    // where the half puts this glyph: centred by its advance (the speaker by its widest), on the Text's baseline
                    const pin = T.G[hex].kind === "speaker" ? T.G["f057e"].adv * 15 / T.UNITS : adv;
                    const ox = Math.round((26 - pin) / 2), oy = item.y + item.origin.y;
                    for (const live of lives)
                        for (let t = 0; t <= P.life(text, live); t += 20) {
                            const ds = P.path(text, t, P.life(text, live), live, null, 15, ox, oy);
                            for (const d of ds) {
                                if (d === "")
                                    continue;
                                const b = win.box(win.points(d));
                                if (b[0] < 0 || b[2] > 26 || b[1] < 0 || b[3] > 26)
                                    bad.push(half + " " + hex + "@" + t + " [" + b.map(v => v.toFixed(1)).join(",") + "]");
                            }
                        }
                }
            };
            one(APose, AParts, bAudio, bAudio.outputGlyphItem, "audio", [true, false]);
            one(NPose, NParts, bNet, bNet.netGlyphItem, "aerial", [true, false]);
            win.check("pill_bounds", bad.length === 0, bad.slice(0, 4).join("; "));
        }

        function at(btn, fx, dx) {
            const p = btn.mapToItem(win.contentItem, btn.width * fx + (dx || 0), btn.height / 2);
            return Qt.point(Math.round(p.x), Math.round(p.y));
        }
        function move(p) {
            tc.mouseMove(win.contentItem, p.x, p.y);
        }
        function park() {
            win.move(Qt.point(win.width - 3, 3));
        }
        function allFlourishes() {
            return [bAudio.outputFlourish, bAudio.inputFlourish, bNet.netFlourish, bNet.btFlourish];
        }
        function anyPlaying() {
            return win.allFlourishes().some(f => f.playing || f._run.running);
        }

        property var steps: []
        property int _i: -1
        function nextStep() {
            win._i++;
            if (win._i >= win.steps.length) {
                console.log("PILL_PROBE RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " fails=" + win.fails);
                quitTimer.start();
                return;
            }
            // a throwing step is a failed check, not a probe that did not load
            let wait = 0;
            try {
                wait = win.steps[win._i]() || 0;
            } catch (e) {
                win.check("pill_step_" + win._i, false, String(e));
            }
            stepTimer.interval = Math.max(1, wait);
            stepTimer.restart();
        }
        Timer {
            id: stepTimer
            onTriggered: win.nextStep()
        }
        // a wait for every clock to stop (live time, capped)
        property int _spins: 0
        function untilStill() {
            if (win.anyPlaying() && win._spins < 60) {
                win._spins++;
                win._i--;
                return 50;
            }
            win._spins = 0;
            return 30;
        }

        // the pointer's rule on one pill: `a` its first half's play list, `b` its second's
        function halfScript(tag, btn, a, b) {
            return [
                () => {
                    win.park();
                    return 100;
                },
                () => {
                    win.move(win.at(btn, 0.25));
                    return 250;
                },
                () => {
                    win.check("pill_half_still_" + tag, win.plays[a].length === 0 && win.plays[b].length === 0, "plays=" + win.counts());
                    win.move(win.at(btn, 0.25, 2));
                    return 120;
                },
                () => {
                    win.check("pill_half_motion_" + tag, win.plays[a].length === 1 && win.plays[a][0] === "hover" && win.plays[b].length === 0,
                              "plays=" + win.counts());
                    win.move(win.at(btn, 0.25, -2));
                    win.move(win.at(btn, 0.25, 3));
                    return 60;
                },
                () => win.untilStill(),
                () => {
                    win.move(win.at(btn, 0.25, -3));
                    win.move(win.at(btn, 0.25, 1));
                    return 150;
                },
                () => {
                    win.check("pill_half_once_" + tag, win.plays[a].length === 1 && win.plays[b].length === 0, "plays=" + win.counts());
                    // across to the other half: its entry, then its motion
                    win.move(win.at(btn, 0.75));
                    return 80;
                },
                () => {
                    win.move(win.at(btn, 0.75, 2));
                    return 120;
                },
                () => {
                    win.check("pill_half_cross_" + tag, win.plays[a].length === 1 && win.plays[b].length === 1, "plays=" + win.counts());
                    return 30;
                },
                () => win.untilStill(),
                () => {
                    win.park();
                    return 80;
                },
                () => {
                    win.move(win.at(btn, 0.25));
                    win.move(win.at(btn, 0.25, 2));
                    return 120;
                },
                () => {
                    win.check("pill_half_reentry_" + tag, win.plays[a].length === 2 && win.plays[b].length === 1, "plays=" + win.counts());
                    return 30;
                },
                () => win.untilStill()
            ];
        }

        readonly property var script: [
            () => {
                win.park();
                return 600;
            },
            () => {
                const items = [bAudio.outputGlyphItem, bAudio.inputGlyphItem, bNet.netGlyphItem, bNet.btGlyphItem];
                win.check("pill_rest", !win.anyPlaying() && items.every(i => !i.posing && i.parts.length === 0), "playing=" + win.anyPlaying());
                const bad = win.identity(APose, AParts, "audio").concat(win.identity(NPose, NParts, "network"));
                win.check("pill_identity", bad.length === 0, "glyphs=" + (Object.keys(AParts.G).length + Object.keys(NParts.G).length) + " " + bad.slice(0, 4).join(" "));
                win.pillFacts();
                win.wifiLevel();
                win.speaker();
                win.near();
                win.mic();
                win.phones();
                win.rune();
                win.plane();
                win.lan();
                win.bounds();
                return 30;
            }
        ].concat(win.halfScript("audio", bAudio, "speaker", "mic")).concat(win.halfScript("network", bNet, "wifi", "bluetooth")).concat([
            () => {
                const items = [bAudio.outputGlyphItem, bAudio.inputGlyphItem, bNet.netGlyphItem, bNet.btGlyphItem];
                win.check("pill_ends", !win.anyPlaying() && items.every(i => !i.posing && i.parts.length === 0), "playing=" + win.anyPlaying());
                win.park();
                const keys = win.allFlourishes().map(f => FlourishRegistry.keyOf(f));
                const inReg = win.allFlourishes().every(f => FlourishRegistry.entries.indexOf(f) >= 0 && f.decorative && FlourishRegistry.under(f, win.contentItem));
                const before = win.counts();
                const played = win.allFlourishes().map(f => f.demo());
                win.check("pill_registry", inReg && keys.join(",") === "audio.speaker,audio.mic,aerial.wifi,aerial.bluetooth"
                          && played.every(p => p === true) && win.allFlourishes().every(f => f.playing && f.why === "random"),
                          "keys=" + keys.join(",") + " demo=" + played.join(",") + " plays " + before + " -> " + win.counts());
                return 30;
            },
            () => win.untilStill()
        ])

        Timer {
            id: quitTimer
            interval: 50
            onTriggered: Qt.quit()
        }
        Timer {
            running: true
            interval: 800
            onTriggered: {
                win.steps = win.script;
                win.nextStep();
            }
        }
    }
}
