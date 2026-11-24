// tools/dev/cast_parse_cases.js -- CastParse.js (the cast tool's JSON lines as one reducer) in node.
//   node tools/dev/cast_parse_cases.js          prints `CPC ok|FAIL <case>` and `CAST_PARSE RESULT PASS|FAIL`
//   node tools/dev/cast_parse_cases.js --arms   each fault in a copy of the source must fail ITS case
//   node tools/dev/cast_parse_cases.js --lines F   the tool's REAL lines (cast_tool_probe.sh writes them): every one is an event the reducers know, and the
//                                                figures come out with every key and text; `CAST_PARSE LINES RESULT PASS|FAIL`
const fs = require("fs");
const SRC = fs.readFileSync(__dirname + "/../../modules/panorama/data/CastParse.js", "utf8");
const load = (src) => new Function(src.replace(".pragma library", "") + "\nreturn {parseLine, initial, begin, reduce, requestStop, parseScan, active, figures, figureText, ageText, FIGURES};")();

function cases(P, only) {
    const out = [];
    const t = (name, ok, d) => { out.push([name, !!ok, d]); };
    const run = (evs, m0) => evs.reduce((m, e) => P.reduce(m, e), m0 || P.begin("wfd:A", "M"));
    t("a line that is not an event is null", P.parseLine("x") === null && P.parseLine("") === null && P.parseLine("{\"a\":1}") === null && P.parseLine("{\"event\":\"state\"}") !== null);
    let m = run([{ event: "state", state: "scanning" }, { event: "state", state: "connecting" }, { event: "state", state: "negotiating" }, { event: "mode", width: 1920, height: 1080, fps: 30 }, { event: "state", state: "streaming" }]);
    t("streaming latches started and keeps the mode", m.state === "streaming" && m.started && m.mode.width === 1920, JSON.stringify(m));
    m = run([{ event: "state", state: "streaming" }, { event: "state", state: "negotiating" }, { event: "state", state: "scanning" }]);
    t("a state never goes back", m.state === "streaming", m.state);
    m = run([{ event: "state", state: "negotiating" }, { event: "mode", width: 1, height: 1, fps: 1 }, { event: "retry", n: 1 }]);
    t("a retry starts again from connecting without a mode", m.state === "connecting" && m.retried && m.mode === null, JSON.stringify(m));
    m = run([{ event: "failed", reason: "activation", detail: "d" }, { event: "state", state: "ended" }, { event: "ended", code: 1 }]);
    t("failed then ended is \"failed\" and state failed", m.ended === "failed" && m.state === "failed" && m.failure.reason === "activation", JSON.stringify(m));
    m = run([{ event: "failed", reason: "peer-gone", detail: "d" }, { event: "ended", code: 1 }]);
    t("peer-gone ends as peer-gone", m.ended === "peer-gone", m.ended);
    m = P.requestStop(run([{ event: "state", state: "streaming" }]));
    m = run([{ event: "failed", reason: "peer-gone", detail: "d" }, { event: "ended", code: 0 }], m);
    t("an end after a requested stop is \"stopped\", idle, with no failure kept", m.ended === "stopped" && m.state === "idle" && m.failure === null, JSON.stringify(m));
    m = run([{ event: "ended", code: 9 }]);
    t("an exit with no word is failed (tool)", m.ended === "failed" && m.failure.reason === "tool", JSON.stringify(m));
    m = run([{ event: "failed", reason: "capture", detail: "d" }, { event: "ended", code: 1 }, { event: "ended", code: 0 }, { event: "state", state: "streaming" }]);
    const m2 = run([{ event: "ended", code: 9 }], P.requestStop(P.begin("wfd:A", "M")));
    const m3 = run([{ event: "ended", code: 9 }], m2);
    t("nothing after the end changes the end", m.ended === "failed" && m.state === "failed" && m2.ended === "stopped" && m3.ended === "stopped" && m3.failure === null, JSON.stringify([m, m3]));
    m = run([{ event: "state", state: "streaming" }, { event: "lost" }]);
    t("a stream that is lost is connecting again at once, with no mode, and is no retry yet", m.state === "connecting" && m.mode === null && m.retried === false && m.started, JSON.stringify(m));
    m = run([{ event: "lost" }], P.requestStop(run([{ event: "state", state: "streaming" }])));
    t("a lost link under a stop stays stopping", m.state === "stopping", m.state);

    // the figures
    const set = { event: "stats", age: 61, reconnects: 0, fps: 29.96, dropped: 3, repeated: 41, behindMs: 340, kbps: 8312, rttMs: 4.1, signalDbm: -52, linkMbps: 866.7 };
    const text = (f) => P.FIGURES.filter(x => f[x.key] !== undefined).map(x => x.label + "=" + P.figureText(x.key, f[x.key])).join("|");
    let f = P.figures(null, set);
    t("a set of figures is read whole", text(f) === "Frames sent=30 fps|Data sent=8.3 Mbit/s|Dropped frames=3|Round trip=4 ms|Repeated frames=41|Signal=-52 dBm|Encoder behind=0.3 s|Link rate=867 Mbit/s", text(f));
    t("the set's time and reconnects are one line", P.ageText(f) === "1:01" && P.ageText(P.figures(null, { event: "stats", age: 3723, reconnects: 1 })) === "1:02:03 \u00b7 reconnected once"
        && P.ageText(P.figures(null, { event: "stats", age: 9, reconnects: 2 })) === "0:09 \u00b7 reconnected twice"
        && P.ageText(P.figures(null, { event: "stats", age: 9, reconnects: 3 })) === "0:09 \u00b7 reconnected 3 times" && P.ageText(null) === "", P.ageText(f));
    const few = P.figures(null, { event: "stats", age: 2, reconnects: 0, fps: null, dropped: 0, repeated: 0 });
    t("a figure with no source has no key, one not known right now is a dash", text(few) === "Frames sent=\u2013|Dropped frames=0|Repeated frames=0", text(few));
    const lost = P.figures(f, { event: "lost" });
    t("a lost link leaves the totals and none of the live figures", lost.dropped === 3 && lost.repeated === 41 && lost.age === 61
        && P.FIGURES.filter(x => x.live).every(x => lost[x.key] === null) && P.FIGURES.filter(x => x.live).length === 6, JSON.stringify(lost));
    t("an end leaves no live figure either", P.figures(f, { event: "ended", code: 0 }).fps === null);
    const again = P.figures(f, { event: "begin", same: true });
    t("a new cast to the same display keeps the rows with nothing in them, another display has none", again !== null && Object.keys(again).length === Object.keys(f).length && again.dropped === null && again.age === null
        && again.reconnects === 0 && P.ageText(again) === "" && P.figures(f, { event: "begin", same: false }) === null, JSON.stringify(again));
    t("an event that is none of the figures' leaves them as they are", P.figures(f, { event: "state", state: "streaming" }) === f && P.figures(f, null) === f);
    t("a round trip under a millisecond is 1 ms, a rate past a gigabit says so", P.figureText("rttMs", 0.2) === "1 ms" && P.figureText("linkMbps", 2401.9) === "2.4 Gbit/s");
    t("a beat touches nothing of the cast's model", JSON.stringify(run([set])) === JSON.stringify(P.begin("wfd:A", "M")));
    const s = P.parseScan('{"devices":[{"id":"wfd:A","name":"TV","capable":true,"note":""}],"fluxcast":"0.3.0","shim":true,"protocols":["wfd"]}');
    t("a scan answer gives facts and info", s.devices.length === 1 && s.devices[0].capable === true && s.info.shim === true, JSON.stringify(s));
    t("a scan error line is an error", P.parseScan('{"event":"error","reason":"scan","detail":"no device"}').error === "scan: no device" && P.parseScan("").error !== undefined);
    return out;
}

const ARMS = {
    backward: ['RANK[s] > RANK[n.state]', 'true', "a state never goes back"],
    stopwins: ['if (n.state === "stopping")\n            n.ended = "stopped";', 'if (false)\n            n.ended = "stopped";', "an end after a requested stop"],
    afterend: ['if (!ev || n.ended !== "")', 'if (!ev)', "nothing after the end changes the end"],
    noretrymode: ['            n.mode = null;', '', "a retry starts again"],
    lostretry: ['n.retried = n.retried || ev.event === "retry";', 'n.retried = true;', "a stream that is lost"],
    stalefigures: ['n[k] = all || FIGURES[i].live ? null : f[k];', 'n[k] = all ? null : f[k];', "a lost link leaves the totals"],
    zeroed: ['n[k] = all || FIGURES[i].live ? null : f[k];', 'n[k] = null;', "a lost link leaves the totals"],
    nokey: ['            if (ev[k] !== undefined)\n                n[k] = _num(ev[k]);', '            n[k] = _num(ev[k]);', "a figure with no source"],
    flapping: ['return ev.same ? _blank(f, true) : null;', 'return null;', "a new cast to the same display"],
};
let fails = 0;
function judge(list, tag) {
    for (const [name, ok, d] of list)
        if (!ok) { fails++; console.log("CPC FAIL " + tag + name + (d ? "  -- " + d : "")); }
        else if (!tag) console.log("CPC ok   " + name);
}
if (process.argv.includes("--arms")) {
    let bad = 0;
    for (const [k, [a, b, needle]] of Object.entries(ARMS)) {
        if (SRC.split(a).length !== 2) { console.log("ARM " + k + ": anchor gone"); bad++; continue; }
        const r = cases(load(SRC.replace(a, b)));
        const hit = r.some(([n, ok]) => !ok && n.indexOf(needle) === 0);
        console.log("ARM " + k + (hit ? ": failed as it must" : ": DID NOT BITE")); if (!hit) bad++;
    }
    console.log("CAST_PARSE ARMS RESULT " + (bad ? "FAIL" : "PASS"));
    process.exit(bad ? 1 : 0);
}
if (process.argv.includes("--lines")) {
    const P = load(SRC), lines = fs.readFileSync(process.argv[process.argv.indexOf("--lines") + 1], "utf8").split("\n").filter(l => l !== "");
    const known = ["state", "mode", "stats", "hold", "lost", "retry", "failed", "error", "ended"];
    let m = P.begin("wfd:A", "M"), f = null, strange = [], sets = 0, full = null;
    for (const l of lines) {
        const ev = P.parseLine(l);
        if (ev === null || known.indexOf(ev.event) < 0) { strange.push(l); continue; }
        m = P.reduce(m, ev);
        f = P.figures(f, ev);
        if (ev.event === "stats") { sets++; full = f; }
    }
    judge([["lines: every line of the tool is an event the reducers know", strange.length === 0 && lines.length > 10, strange.slice(0, 3).join(" ")],
           ["lines: the cast came up and ended", m.started && m.ended === "stopped", JSON.stringify(m)],
           ["lines: every figure comes out of the tool's own sets, with its text", sets >= 10 && P.FIGURES.every(x => full[x.key] !== undefined && /\d/.test(P.figureText(x.key, full[x.key]))) && /^\d+:\d\d$/.test(P.ageText(full)), sets + " " + JSON.stringify(full)]], "");
    console.log("CAST_PARSE LINES RESULT " + (fails ? "FAIL" : "PASS"));
    process.exit(fails ? 1 : 0);
}
judge(cases(load(SRC)), "");
console.log("CAST_PARSE RESULT " + (fails ? "FAIL" : "PASS"));
process.exit(fails ? 1 : 0);
