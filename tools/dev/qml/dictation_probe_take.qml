// qmllint disable unqualified
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/dictation"

// =============================================================================
// dictation_probe_take.qml -- DictationService's side of a take against a helper that misbehaves on cue (round 6), offscreen, for
// tools/dev/dictation_probe_take.sh: the REAL service, a stand-in helper (tools/dev/dictation_probe_helper.py: the protocol, no
// model), a stand-in lares-ime (the runner's script: `ready`, `activate`, every line logged, a `quit` answered 0.8 s late), a stand-in
// shell field (the contract: dictationActive / dictationPreedit / dictationCommit / dictationBefore), a stub wl-copy.
//
//   T1  THE SHELL ROUTE at the press: a field with the caret takes the take -- live words as its preedit, the finals committed with
//       the spacing after the text before the caret -- and no input method is started
//   T2  the field loses the caret mid-take: one blink (false and back in one turn) changes nothing; a real loss hands the rest to the
//       input method (started then), the field's preedit cleared
//   T3  a field gains the caret mid-take: the input method's preedit is cleared and the rest goes to the field
//   T8  a press right after a take: the new take waits for the last take's lares-ime to go and gets its own (route ime, its words there)
//   T6  a press in `stopping` within the grace is the same stop; after it the take ends at once (`forced`, the aura let go); the helper
//       answers the ping (no restart), and its late `running` for the ended take plays no aura
//   T4  a helper that goes silent after `running` (take 9 of 2026-11-09): the stop's wait ends the take (`timeout`), the helper is
//       asked for its threads and started again, and the next press is a normal take
//   T5  a helper that does not answer a start: `startAnswerMs` later the take ends (`stalled`) and the helper is started again
//   T7  a keep-warm restart with a press in the same turn: the start reaches the NEW helper, never the one that is going
//   T9  the aura: held for the take (`holdsAura`), let go at its end
//   T11 the helper's main loop raised (`crash`): the take ends with the helper's stated reason ("error": the words shown are written, a toast
//       says the helper crashed and why), the helper is started again
//   T12 a GPU decode failed (`gpufail`): the helper's `fallback` is a toast in words ("The iGPU stopped responding; switched to the CPU"), the
//       take goes on and nothing is lost
//   T13 THE LISTENING WATCHDOG: a helper that goes silent mid-take (`silent`: no word, no beat) ends the take within `beatMs`, not at the
//       stop's 6 s, with the reason in a toast; T14 a main loop stuck inside a native call (`loopstuck`: the beat thread says how long ago it
//       last turned) ends it at `loopStuckMs`, and a decode that hung on a GPU puts the next take on the CPU until a rest restart
//   T16 the helper PROCESS ends mid-take (`die`, exit 139 with a stderr line): the toast and the take log say how it went
//   T17 HOLD (dictation.key): the release ends the take, one still starting too; a press while the last take finishes waits for it, and
//       starts one only if the key is still down. T18 endAfterMin ends a take nobody speaks into. T19 copy "always" (the clipboard has what
//       the field took), unmute off (a take on a muted mic does not start, and writes nothing), logKeep, a word that is none
//   T10 the take log: a file that does not end in a newline gets one before the next record, and two records finished while one
//       write runs both land (every line one JSON record)
// Prints `DT ok|FAIL <check>: <detail>` and `DT RESULT PASS|FAIL`. Env: DT_HELPER (the stand-in's script), DT_IME (the stand-in
// lares-ime), DT_IMELOG / DT_HELPERLOG (their logs), DT_CTL (the stand-in helper's scenario file), DT_STATE (the state dir), DT_COPY
// (the stub wl-copy).
// =============================================================================
ShellRoot {
    id: root

    readonly property string stateDir: Quickshell.env("DT_STATE") || ""
    property int bad: 0
    property var auras: []
    property var toasts: []

    function say(ok: bool, what: string, detail: string): void {
        if (!ok)
            root.bad += 1;
        console.log("DT " + (ok ? "ok" : "FAIL") + " " + what + ": " + detail);
    }

    // ---- the stand-in shell field (THE SHELL ROUTE's contract) --------------------------------------------------------------------
    QtObject {
        id: field
        objectName: "fakeField"
        property bool dictationActive: false
        property string text: ""
        property string preedit: ""
        property var preedits: []
        property var commits: []
        function dictationPreedit(t: string): void {
            field.preedit = t;
            field.preedits = field.preedits.concat([t]);
        }
        function dictationCommit(t: string): void {
            field.preedit = "";
            field.text += t;
            field.commits = field.commits.concat([t]);
        }
        function dictationBefore(): string {
            return field.text;
        }
        function reset(active: bool, text: string): void {
            field.dictationActive = active;
            field.text = text;
            field.preedit = "";
            field.preedits = [];
            field.commits = [];
        }
    }

    DictationService {
        id: svc
        live: !!Quickshell.env("DT_HELPER")
        rawConfig: ({ enabled: true, logTakes: true })
        pipewire: null
        stateDir: root.stateDir
        pythonPath: "/usr/bin/python3"
        helperScript: Quickshell.env("DT_HELPER") || ""
        imePath: Quickshell.env("DT_IME") || ""
        copyCommand: [Quickshell.env("DT_COPY") || "true", root.stateDir + "/clipboard.txt"]
        activeWindowCommand: ["printf", "{\"class\":\"probe\",\"title\":\"probe\",\"pid\":1}"]
        // the ShellServices binding's shape: the content while its field has the caret
        shellTarget: field.dictationActive ? field : null
        startAnswerMs: 1500
        pingMs: 2000
        beatMs: 1500
        loopStuckMs: 8000
        playAura: (palette, group, lifeMs) => {
            root.auras = root.auras.concat([group]);
            return "playing on 1 screen(s)";
        }
        releaseAura: () => {
            root.auras = root.auras.concat(["release"]);
        }
        onToast: (title, body) => root.toasts = root.toasts.concat([title + ": " + body])
    }

    // ---- the files ---------------------------------------------------------------------------------------------------------------
    FileView {
        id: ctl
        path: Quickshell.env("DT_CTL") || ""
        blockWrites: true
        atomicWrites: true
        printErrors: false
    }
    function scenario(kind: string): void {
        ctl.setText(JSON.stringify({ default: kind }) + "\n");
    }
    FileView {
        id: imeLog
        path: Quickshell.env("DT_IMELOG") || ""
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    FileView {
        id: helperLog
        path: Quickshell.env("DT_HELPERLOG") || ""
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    FileView {
        id: takeLog
        path: root.stateDir + "/dictation/takes.jsonl"
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    function lines(fv: var): var {
        fv.reload();
        return String(fv.text() || "").split("\n").filter(l => l !== "");
    }
    // the stand-in lares-ime processes that started, in order (each logs "<pid> up")
    function imeUps(): var {
        return root.lines(imeLog).filter(l => / up$/.test(l)).map(l => l.split(" ")[0]);
    }
    function helperUps(): var {
        return root.lines(helperLog).filter(l => / up$/.test(l)).map(l => l.split(" ")[0]);
    }
    // EVERY ENTRY THE SERVICE LOGGED, kept here: svc.log is capped at its last 200, and a probe that slices a capped log by index reads
    // nothing once it is full (CLAUDE.md). The new entries are the ones after the last known object (by identity).
    property var all: []
    Connections {
        target: svc
        function onLogChanged() {
            const cur = svc.log;
            const last = root.all.length > 0 ? root.all[root.all.length - 1] : null;
            let from = last ? cur.lastIndexOf(last) + 1 : 0;
            if (last && from === 0)
                from = Math.max(0, cur.length - 1);
            root.all = root.all.concat(cur.slice(from));
        }
    }
    function since(i: int): var {
        return root.all.slice(i);
    }
    function finished(from: int): var {
        return root.since(from).filter(e => e.ev === "finished");
    }

    // ---- the steps ---------------------------------------------------------------------------------------------------------------
    // each: start() once, then done() polled every 50 ms until true (check() then) or `ms` pass (a FAIL naming the step)
    property int at: 0
    property double stepAt: 0
    property bool started: false
    property var ctx: ({})
    property var mem: ({})
    readonly property var steps: [
        { name: "boot", ms: 5000, start: () => {}, done: () => svc.log.some(e => e.ev === "checked") && svc.helperRunning, check: () => {} },
        // T1 -- the shell route at the press
        { name: "T1", ms: 8000,
          start: () => {
              root.scenario("normal");
              field.reset(true, "Hello");
              root.ctx = { log: root.all.length, imes: root.imeUps().length, auras: root.auras.length };
              svc.toggle("");
          },
          done: () => field.commits.length >= 2 && svc.state === "listening",
          check: () => {
              root.ctx.held = svc.holdsAura;
              svc.toggle("");
          } },
        { name: "T1 end", ms: 8000, start: () => {}, done: () => svc.state === "idle",
          check: () => {
              const ev = root.since(root.ctx.log);
              const routes = ev.filter(e => e.ev === "route").map(e => e.route);
              root.say(svc.route === "shell" && routes.join(",") === "shell" && field.text === "Hello W0 w1. W2."
                       && root.imeUps().length === root.ctx.imes, "T1 shell route",
                       "routes " + routes.join(",") + "; the field reads \"" + field.text + "\"; input methods started "
                       + (root.imeUps().length - root.ctx.imes));
              root.say(field.preedits.indexOf(" w0 w1") >= 0 && field.preedit === "", "T1 preedit",
                       "preedits " + JSON.stringify(field.preedits) + ", left \"" + field.preedit + "\"");
              const au = root.auras.slice(root.ctx.auras);
              root.say(root.ctx.held === true && !svc.holdsAura && au[au.length - 1] === "release", "T9 aura held for the take",
                       "holdsAura " + root.ctx.held + " during, " + svc.holdsAura + " after; asks " + au.join(" "));
          } },
        // T2 -- the field loses the caret mid-take (a blink first)
        { name: "T2", ms: 8000,
          start: () => {
              root.scenario("slow");
              field.reset(true, "");
              root.ctx = { log: root.all.length, imes: root.imeUps().length, lost: false };
              svc.toggle("");
          },
          done: () => {
              if (!root.ctx.lost && field.commits.length >= 1) {
                  root.ctx.lost = true;
                  // one blink: false and back in one turn is no change (the routes counted before it, compared 300 ms after)
                  root.ctx.blinkRoutes = root.since(root.ctx.log).filter(e => e.ev === "route").length;
                  field.dictationActive = false;
                  field.dictationActive = true;
                  blinkThenLose.start();
              }
              if (svc.state === "listening" && root.since(root.ctx.log).filter(e => e.ev === "seg").length >= 2)
                  svc.toggle("");
              return svc.state === "idle";
          },
          check: () => {
              const ev = root.since(root.ctx.log);
              const routes = ev.filter(e => e.ev === "route").map(e => e.route);
              const imeLines = root.lines(imeLog);
              const ups = root.imeUps();
              const mine = ups.length > root.ctx.imes ? ups[ups.length - 1] : "";
              const got = imeLines.filter(l => mine !== "" && l.indexOf(mine + " commit") === 0);
              root.say(routes[0] === "shell" && routes.indexOf("ime") > 0 && field.commits.length === 1 && got.length >= 1
                       && root.ctx.routesAfterBlink === root.ctx.blinkRoutes, "T2 field lost",
                       "routes " + routes.join(",") + " (" + root.ctx.blinkRoutes + " before the blink, " + root.ctx.routesAfterBlink
                       + " after it); the field got " + JSON.stringify(field.commits) + ", the input method " + JSON.stringify(got));
              root.say(field.preedit === "", "T2 preedit cleared", "the field's preedit left \"" + field.preedit + "\"");
          } },
        // T3 -- a field gains the caret mid-take
        { name: "T3", ms: 8000,
          start: () => {
              root.scenario("slow");
              field.reset(false, "Note:");
              root.ctx = { log: root.all.length, imes: root.imeUps().length, gained: false };
              svc.toggle("");
          },
          done: () => {
              const ups = root.imeUps();
              const mine = ups.length > root.ctx.imes ? ups[ups.length - 1] : "";
              if (!root.ctx.gained && mine !== "" && root.lines(imeLog).some(l => l.indexOf(mine + " commit") === 0)) {
                  root.ctx.gained = true;
                  root.ctx.mine = mine;
                  field.dictationActive = true;
              }
              if (svc.state === "listening" && root.since(root.ctx.log).filter(e => e.ev === "seg").length >= 2)
                  svc.toggle("");
              return svc.state === "idle";
          },
          check: () => {
              const ev = root.since(root.ctx.log);
              const routes = ev.filter(e => e.ev === "route").map(e => e.route);
              const mine = root.ctx.mine || "?";
              const imeLines = root.lines(imeLog).filter(l => l.indexOf(mine + " ") === 0).map(l => l.substring(mine.length + 1));
              const cleared = imeLines.lastIndexOf("preedit\t") > imeLines.findIndex(l => l.indexOf("commit") === 0);
              root.say(routes.slice(-2).join(",") === "ime,shell" && field.text === "Note: W2." && cleared, "T3 field gained",
                       "routes " + routes.join(",") + "; the field reads \"" + field.text + "\"; the input method's preedit cleared " + cleared);
          } },
        // T8 -- the next take's input method waits for the last one's
        // (the last take's lares-ime gone first: this step's first take must have its own from the press)
        { name: "T8 settle", ms: 3000, start: () => {}, done: () => !svc._imeQuitting, check: () => {} },
        { name: "T8", ms: 10000,
          start: () => {
              root.scenario("slow");
              field.reset(false, "");
              root.ctx = { log: root.all.length, imes: root.imeUps().length, second: false };
              svc.toggle("");
          },
          done: () => {
              if (!root.ctx.second && root.since(root.ctx.log).some(e => e.ev === "commit")) {
                  if (svc.state === "listening") {
                      svc.toggle("");
                      return false;
                  }
              }
              if (!root.ctx.second && svc.state === "idle" && root.finished(root.ctx.log).length === 1) {
                  // at once: the last take's lares-ime is still answering its `quit` (0.8 s)
                  root.ctx.second = true;
                  root.ctx.log2 = root.all.length;
                  svc.toggle("");
                  return false;
              }
              if (root.ctx.second && svc.state === "listening" && root.since(root.ctx.log2).filter(e => e.ev === "seg").length >= 2)
                  svc.toggle("");
              return root.ctx.second && svc.state === "idle" && root.finished(root.ctx.log2).length === 1;
          },
          check: () => {
              const ev = root.since(root.ctx.log2);
              const ups = root.imeUps();
              const fin = root.finished(root.ctx.log2)[0] || {};
              const waited = ev.some(e => e.ev === "imewait");
              const mine = ups.length >= root.ctx.imes + 2 ? ups[ups.length - 1] : "";
              const got = root.lines(imeLog).filter(l => mine !== "" && l.indexOf(mine + " commit") === 0);
              root.say(fin.route === "ime" && waited && got.length >= 1, "T8 the next take's input method",
                       "route " + fin.route + ", waited " + waited + ", input methods started " + (ups.length - root.ctx.imes)
                       + ", the second's commits " + JSON.stringify(got));
          } },
        // T6 -- forced while the models load; the ping answered; the late `running`
        { name: "T6", ms: 12000,
          start: () => {
              root.scenario("latewake");
              root.ctx = { log: root.all.length, helpers: root.helperUps().length, auras: root.auras.length, phase: 0, t: Date.now() };
              svc.toggle("");
          },
          done: () => {
              const dt = Date.now() - root.ctx.t;
              if (root.ctx.phase === 0 && dt > 300) {
                  svc.toggle("");                        // the stop, while the model loads
                  root.ctx.phase = 1;
              } else if (root.ctx.phase === 1 && dt > 800) {
                  svc.toggle("");                        // inside the grace: the same stop
                  root.ctx.phase = 2;
                  root.ctx.stateInGrace = svc.state;
              } else if (root.ctx.phase === 2 && dt > 2600) {
                  svc.toggle("");                        // after it: the end, now
                  root.ctx.phase = 3;
                  root.ctx.stateForced = svc.state;
                  root.ctx.aurasForced = root.auras.length;
              }
              // past the late `running` (3.1 s) and the ping's answer
              return root.ctx.phase === 3 && dt > 5500;
          },
          check: () => {
              const ev = root.since(root.ctx.log);
              const fin = root.finished(root.ctx.log)[0] || {};
              root.say(root.ctx.stateInGrace === "stopping" && root.ctx.stateForced === "idle" && fin.reason === "forced"
                       && root.auras[root.ctx.aurasForced - 1] === "release", "T6 forced",
                       "in the grace " + root.ctx.stateInGrace + ", after it " + root.ctx.stateForced + ", reason " + fin.reason
                       + ", aura asks " + root.auras.slice(root.ctx.auras).join(" "));
              root.say(root.auras.length === root.ctx.aurasForced && !ev.some(e => e.ev === "running"), "T6 late running",
                       "aura asks after the end: " + JSON.stringify(root.auras.slice(root.ctx.aurasForced)) + "; running read after it "
                       + ev.some(e => e.ev === "running"));
              root.say(!ev.some(e => e.ev === "stall") && root.helperUps().length === root.ctx.helpers, "T6 alive",
                       "the helper answered the ping: no stall, no restart (" + (root.helperUps().length - root.ctx.helpers) + " started)");
          } },
        // T4 -- silent after `running`: the stop's wait restarts it; the next take is normal
        { name: "T4", ms: 15000,
          start: () => {
              root.scenario("stall");
              root.ctx = { log: root.all.length, helpers: root.helperUps().length, auras: root.auras.length, stopped: false };
              svc.toggle("");
          },
          done: () => {
              const run = root.since(root.ctx.log).find(e => e.ev === "running");
              if (run && !root.ctx.runAt)
                  root.ctx.runAt = Date.now();
              // the stop a moment after `running` (the user's take 9: listening, running, then nothing)
              if (!root.ctx.stopped && root.ctx.runAt && Date.now() - root.ctx.runAt > 300) {
                  root.ctx.stopped = true;
                  root.ctx.stopAt = Date.now();
                  svc.toggle("");
              }
              return root.ctx.stopped && svc.state === "idle" && root.helperUps().length > root.ctx.helpers;
          },
          check: () => {
              const fin = root.finished(root.ctx.log)[0] || {};
              const au = root.auras.slice(root.ctx.auras);
              root.say(fin.reason === "timeout" && au[au.length - 1] === "release" && root.since(root.ctx.log).some(e => e.ev === "restart"),
                       "T4 restarted", "reason " + fin.reason + " " + Math.round((Date.now() - root.ctx.stopAt) / 100) / 10
                       + " s after the stop; aura asks " + au.join(" ") + "; helpers started " + (root.helperUps().length - root.ctx.helpers));
              root.scenario("normal");
              root.ctx.log2 = root.all.length;
              svc.toggle("");
          } },
        { name: "T4 next", ms: 8000, start: () => {},
          done: () => {
              if (svc.state === "listening" && root.since(root.ctx.log2).some(e => e.ev === "seg"))
                  svc.toggle("");
              return svc.state === "idle" && root.finished(root.ctx.log2).length === 1;
          },
          check: () => {
              const fin = root.finished(root.ctx.log2)[0] || {};
              root.say(fin.reason === "ended" && root.since(root.ctx.log2).some(e => e.ev === "capture"), "T4 next take",
                       "the press after the restart: reason " + fin.reason);
          } },
        // T5 -- no answer to a start
        { name: "T5", ms: 10000,
          start: () => {
              root.scenario("hang");
              root.ctx = { log: root.all.length, helpers: root.helperUps().length, t: Date.now() };
              svc.toggle("");
          },
          done: () => svc.state === "idle" && root.helperUps().length > root.ctx.helpers,
          check: () => {
              const fin = root.finished(root.ctx.log)[0] || {};
              root.say(fin.reason === "stalled" && root.since(root.ctx.log).some(e => e.ev === "stall" && e.why === "start"), "T5 start answer",
                       "reason " + fin.reason + " " + Math.round((Date.now() - root.ctx.t) / 100) / 10 + " s after the press; toasts "
                       + JSON.stringify(root.toasts.slice(-1)));
          } },
        // T7 -- a keep-warm restart and a press in one turn
        { name: "T7", ms: 10000,
          start: () => {
              root.scenario("normal");
              root.ctx = { log: root.all.length, old: root.helperUps().slice(-1)[0] };
              svc._restartHelper("rest");
              svc.toggle("");
          },
          done: () => {
              if (svc.state === "listening" && root.since(root.ctx.log).some(e => e.ev === "seg"))
                  svc.toggle("");
              return svc.state === "idle" && root.finished(root.ctx.log).length === 1;
          },
          check: () => {
              const starts = root.lines(helperLog).filter(l => / op \{"op":"start"/.test(l)).slice(-1);
              const by = starts.length ? starts[0].split(" ")[0] : "";
              const fin = root.finished(root.ctx.log)[0] || {};
              root.say(by !== "" && by !== root.ctx.old && fin.reason === "ended", "T7 start reached the new helper",
                       "the start went to " + by + " (the old helper " + root.ctx.old + "); reason " + fin.reason);
          } },
        // T11 -- the helper's main loop raised: the take is ended with a reason, the helper is started again
        { name: "T11", ms: 9000,
          start: () => {
              root.scenario("crash");
              field.reset(true, "");
              root.ctx = { log: root.all.length, helpers: root.helperUps().length, toasts: root.toasts.length, take: svc._take + 1 };
              root.mem.crash = svc._take + 1;
              svc.toggle("");
          },
          done: () => svc.state === "idle" && root.finished(root.ctx.log).length === 1 && root.helperUps().length > root.ctx.helpers,
          check: () => {
              const fin = root.finished(root.ctx.log)[0] || {};
              const t = root.toasts.slice(root.ctx.toasts);
              root.say(fin.reason === "error" && t.some(x => x.indexOf("The speech helper crashed (RuntimeError: the decoder did not return)") >= 0),
                       "T11 crash", "reason " + fin.reason + "; toasts " + JSON.stringify(t));
              root.say(field.text === "w0" && field.preedit === "", "T11 nothing lost",
                       "the words shown when the helper ended the take are written: the field reads \"" + field.text + "\"");
              root.say(root.helperUps().length > root.ctx.helpers, "T11 restarted", "helpers started " + (root.helperUps().length - root.ctx.helpers));
          } },
        // T12 -- a GPU decode failed: the CPU took over, the take went on
        { name: "T12", ms: 9000,
          start: () => {
              root.scenario("gpufail");
              field.reset(true, "");
              root.ctx = { log: root.all.length, toasts: root.toasts.length };
              root.mem.gpufail = svc._take + 1;
              svc.toggle("");
          },
          done: () => {
              if (svc.state === "listening" && root.since(root.ctx.log).filter(e => e.ev === "seg").length >= 2)
                  svc.toggle("");
              return svc.state === "idle" && root.finished(root.ctx.log).length === 1;
          },
          check: () => {
              const fin = root.finished(root.ctx.log)[0] || {};
              const t = root.toasts.slice(root.ctx.toasts);
              root.say(fin.reason === "ended" && field.text === "W0 w1. W2." && t.some(x => x === "Dictation: The iGPU stopped responding; switched to the CPU, the take goes on"),
                       "T12 gpu fallback", "reason " + fin.reason + "; the field reads \"" + field.text + "\"; toasts " + JSON.stringify(t));
          } },
        // T13 -- a helper gone silent mid-take: the watchdog, not the stop's 6 s
        { name: "T13", ms: 9000,
          start: () => {
              root.scenario("silent");
              field.reset(true, "");
              root.ctx = { log: root.all.length, toasts: root.toasts.length, helpers: root.helperUps().length, t: Date.now() };
              root.mem.silent = svc._take + 1;
              svc.toggle("");
          },
          done: () => svc.state === "idle" && root.finished(root.ctx.log).length === 1 && root.helperUps().length > root.ctx.helpers,
          check: () => {
              const fin = root.finished(root.ctx.log)[0] || {};
              const dt = Date.now() - root.ctx.t;
              const t = root.toasts.slice(root.ctx.toasts);
              root.say(fin.reason === "stalled" && dt < 5000 && root.since(root.ctx.log).some(e => e.ev === "stall" && e.why === "silent")
                       && t.some(x => x.indexOf("went silent") >= 0 && x.indexOf("the take was ended") >= 0),
                       "T13 listening watchdog", "reason " + fin.reason + " " + Math.round(dt / 100) / 10 + " s after the press (the stop's wait is 6 s); toasts "
                       + JSON.stringify(t));
          } },
        // T14 -- the main loop stuck inside a native call: the beat says so; a GPU decode that hung puts the next take on the CPU
        { name: "T14", ms: 12000,
          start: () => {
              root.scenario("loopstuck");
              svc.loopStuckMs = 2500;
              root.ctx = { log: root.all.length, toasts: root.toasts.length, helpers: root.helperUps().length, t: Date.now() };
              root.mem.loop = svc._take + 1;
              svc.toggle("");
          },
          done: () => svc.state === "idle" && root.finished(root.ctx.log).length === 1 && root.helperUps().length > root.ctx.helpers,
          check: () => {
              const fin = root.finished(root.ctx.log)[0] || {};
              const dt = Date.now() - root.ctx.t;
              const t = root.toasts.slice(root.ctx.toasts);
              root.say(fin.reason === "stalled" && dt < 5500 && root.since(root.ctx.log).some(e => e.ev === "stall" && e.why === "loop")
                       && t.some(x => x.indexOf("decoder did not return for") >= 0 && x.indexOf("on the CPU for the next take") >= 0),
                       "T14 loop stuck", "reason " + fin.reason + " " + Math.round(dt / 100) / 10 + " s after the press; toasts " + JSON.stringify(t));
              svc.loopStuckMs = 8000;
              root.say(svc._avoidGpu === true, "T14 gpu rests", "the GPU is avoided for the next take: " + svc._avoidGpu);
              root.scenario("normal");
              root.ctx.log2 = root.all.length;
              svc.toggle("");
          } },
        { name: "T14 next", ms: 9000, start: () => {},
          done: () => {
              if (svc.state === "listening" && root.since(root.ctx.log2).some(e => e.ev === "seg"))
                  svc.toggle("");
              return svc.state === "idle" && root.finished(root.ctx.log2).length === 1;
          },
          check: () => {
              const starts = root.lines(helperLog).filter(l => / op \{"op":"start"/.test(l)).slice(-1);
              root.say(starts.length === 1 && starts[0].indexOf('"device":"cpu"') >= 0, "T14 next take on the CPU", starts.length ? starts[0].slice(0, 150) : "no start");
              svc._restartHelper("rest");
              root.say(svc._avoidGpu === false, "T14 rest restart", "the GPU is tried again after the rest restart: avoid " + svc._avoidGpu);
          } },
        // T16 -- the helper process itself ends mid-take
        { name: "T16", ms: 9000,
          start: () => {
              root.scenario("die");
              root.ctx = { log: root.all.length, toasts: root.toasts.length };
              root.mem.die = svc._take + 1;
              svc.toggle("");
          },
          done: () => svc.state === "idle" && root.finished(root.ctx.log).length === 1,
          check: () => {
              const fin = root.finished(root.ctx.log)[0] || {};
              const t = root.toasts.slice(root.ctx.toasts);
              root.say(fin.reason === "helper" && t.some(x => x.indexOf("it crashed with a segmentation fault: fake helper: CUDA error: out of memory") >= 0
                                                          && x.indexOf("the take was ended") >= 0),
                       "T16 helper died", "reason " + fin.reason + "; toasts " + JSON.stringify(t));
          } },
        // T10 -- the take log
        { name: "T10", ms: 5000,
          start: () => {
              root.ctx = { before: root.lines(takeLog).length };
              svc._logTake("probe-a");
              svc._logTake("probe-b");
          },
          done: () => root.lines(takeLog).length >= root.ctx.before + 2,
          check: () => {
              const ls = root.lines(takeLog);
              let parsed = 0;
              for (const l of ls) {
                  try {
                      JSON.parse(l);
                      parsed++;
                  } catch (e) {
                      // a glued line does not parse
                  }
              }
              const reasons = ls.map(l => { try { return JSON.parse(l).reason; } catch (e) { return "?"; } });
              root.say(parsed === ls.length && reasons.slice(-2).join(",") === "probe-a,probe-b" && reasons[0] === "seeded",
                       "T10 every record", parsed + " of " + ls.length + " lines parse; reasons " + reasons.join(","));
          } },
        // T15 -- the take log keeps what the helper said: its own reason, the exit, the stall, the fallback, the mode, each sentence's cut
        { name: "T15", ms: 3000, start: () => {}, done: () => true,
          check: () => {
              const recs = root.lines(takeLog).map(l => { try { return JSON.parse(l); } catch (e) { return {}; } });
              const by = n => recs.find(r => r.take === n) || {};
              const c = by(root.mem.crash), g = by(root.mem.gpufail), s = by(root.mem.silent), lp = by(root.mem.loop), d = by(root.mem.die);
              root.say(c.reason === "error" && c.helperReason === "error" && c.mode === "type", "T15 crash record",
                       JSON.stringify({ reason: c.reason, helperReason: c.helperReason, mode: c.mode }));
              root.say(Array.isArray(g.fallbacks) && g.fallbacks.length === 1 && g.fallbacks[0].why === "the iGPU stopped responding"
                       && g.fallbacks[0].to === "CPU" && String(g.fallbacks[0].detail).indexOf("clWaitForEvents") >= 0
                       && Array.isArray(g.segs) && g.segs.length >= 1 && g.segs[0].cut !== undefined, "T15 fallback record",
                       JSON.stringify({ fallbacks: g.fallbacks, device: g.device }));
              root.say(s.stall && s.stall.why === "silent" && lp.stall && lp.stall.why === "loop" && lp.stall.loopMs > 2000, "T15 stall record",
                       JSON.stringify({ silent: s.stall, loop: lp.stall }));
              root.say(d.reason === "helper" && d.exit && d.exit.code === 139 && d.exit.stderr === "fake helper: CUDA error: out of memory"
                       && d.exit.words.indexOf("segmentation") >= 0, "T15 exit record", JSON.stringify(d.exit));
          } },
        // T17 -- HOLD: the release ends the take (one still starting too), a press while the last take finishes waits for it, and only with the key down
        { name: "T17 settle", ms: 6000, start: () => {}, done: () => svc._helperReady && svc.state === "idle", check: () => {} },
        { name: "T17", ms: 8000,
          start: () => {
              svc.rawConfig = { enabled: true, key: "hold", copy: "always", logKeep: 3, language: "en" };
              root.scenario("normal");
              field.reset(true, "");
              root.ctx = { log: root.all.length };
              svc.holdPress("en");
              root.ctx.state = svc.state;
              svc.holdRelease();                         // before the helper has said anything
              root.ctx.after = svc.state;
          },
          done: () => svc.state === "idle" && root.finished(root.ctx.log).length === 1,
          check: () => {
              const fin = root.finished(root.ctx.log)[0] || {};
              root.say(root.ctx.state === "starting" && root.ctx.after === "stopping" && fin.reason === "ended", "T17 release while starting",
                       root.ctx.state + " -> " + root.ctx.after + ", reason " + fin.reason);
              root.ctx = { log: root.all.length, stopped: false };
              svc.holdPress("en");
          } },
        { name: "T17 held", ms: 12000, start: () => {},
          done: () => {
              if (!root.ctx.stopped && svc.state === "listening" && root.since(root.ctx.log).filter(e => e.ev === "seg").length >= 2) {
                  root.ctx.stopped = true;
                  svc.holdRelease();
                  svc.holdPress("en");                   // still finishing: kept ...
                  root.ctx.kept = svc.state;
                  svc.holdRelease();                     // ... and let go before it has: no take
              }
              if (root.ctx.stopped && svc.state === "idle" && !root.ctx.idleAt)
                  root.ctx.idleAt = Date.now();
              return (root.ctx.idleAt && Date.now() - root.ctx.idleAt > 300) || root.finished(root.ctx.log).length > 1;
          },
          check: () => {
              const ev = root.since(root.ctx.log);
              root.say(root.ctx.kept === "stopping" && ev.filter(e => e.ev === "press").length === 1 && svc.state === "idle",
                       "T17 held", "pressed again in " + root.ctx.kept + ", takes " + ev.filter(e => e.ev === "press").length + ", state " + svc.state);
              if (svc.state !== "idle")
                  svc._finish("probe");
              root.ctx = { log: root.all.length, stopped: false };
              svc.holdPress("en");
          } },
        { name: "T17 kept", ms: 12000, start: () => {},
          done: () => {
              if (!root.ctx.stopped && svc.state === "listening" && root.since(root.ctx.log).some(e => e.ev === "seg")) {
                  root.ctx.stopped = true;
                  svc.holdRelease();
                  svc.holdPress("en");                   // still finishing, and the key stays down: the next take
              }
              if (root.ctx.stopped && root.finished(root.ctx.log).length === 1 && svc.state === "listening" && !root.ctx.second) {
                  root.ctx.second = true;
                  svc.holdRelease();
              }
              return root.ctx.second === true && svc.state === "idle" && root.finished(root.ctx.log).length === 2;
          },
          check: () => {
              const ev = root.since(root.ctx.log);
              root.say(root.finished(root.ctx.log).every(f => f.reason === "ended"), "T17 kept", root.finished(root.ctx.log).map(f => f.reason).join(","));
              const copies = ev.filter(e => e.ev === "copied").map(e => e.text);
              root.say(field.text.indexOf("W0 w1. W2.") === 0 && copies[0].indexOf("W0 w1.") === 0 && !root.toasts.slice(-1).some(t => t.indexOf("Dictation copied") === 0),
                       "T19 copy always", "the field reads " + field.text + "; copied " + JSON.stringify(copies));
          } },
        // T18 -- endAfterMin: nothing said
        { name: "T18", ms: 9000,
          start: () => {
              svc.rawConfig = { enabled: true, endAfterMin: 0.01, logKeep: 3 };
              root.scenario("slowload");
              field.reset(true, "");
              root.ctx = { log: root.all.length, toasts: root.toasts.length, t: Date.now() };
              svc.toggle("");
          },
          done: () => svc.state === "idle" && root.finished(root.ctx.log).length === 1,
          check: () => {
              const t = root.toasts.slice(root.ctx.toasts);
              root.say(root.since(root.ctx.log).some(e => e.ev === "quietend") && t.some(x => x.indexOf("Dictation ended: Nothing was said") === 0),
                       "T18 nothing said", "toasts " + JSON.stringify(t));
          } },
        // T19 -- unmute off on a muted mic; the log keeps logKeep
        { name: "T19", ms: 4000,
          start: () => {
              svc.rawConfig = { enabled: true, unmute: false, key: "x", copy: 5, logKeep: 3 };
              svc.pipewire = mutedPw;
              root.ctx = { log: root.all.length, toasts: root.toasts.length };
              svc.toggle("");
          },
          done: () => root.lines(takeLog).length <= 3,
          check: () => {
              const t = root.toasts.slice(root.ctx.toasts);
              root.say(svc.state === "idle" && t.join() === "The microphone is muted: Unmute it to dictate" && mutedPw.calls === 0, "T19 muted mic",
                       "state " + svc.state + ", toasts " + JSON.stringify(t) + ", mute writes " + mutedPw.calls);
              root.say(svc.config.key === "toggle" && svc.config.copy === "fallback" && root.lines(takeLog).length === 3, "T19 words and the log",
                       JSON.stringify([svc.config.key, svc.config.copy, root.lines(takeLog).length]));
              svc.pipewire = null;
          } }
    ]
    QtObject {
        id: mutedPw
        property int calls: 0
        readonly property QtObject defaultSource: QtObject {
            property string name: "mic"
            readonly property QtObject audio: QtObject {
                property bool muted: true
                property real volume: 0.5
            }
        }
        function setMuted(n: var, m: bool): void {
            mutedPw.calls++;
        }
    }
    Timer {
        id: blinkThenLose
        interval: 300
        onTriggered: {
            root.ctx.routesAfterBlink = root.since(root.ctx.log).filter(e => e.ev === "route").length;
            field.dictationActive = false;
        }
    }
    Timer {
        interval: 50
        repeat: true
        running: !!Quickshell.env("DT_HELPER")
        onTriggered: {
            if (root.at >= root.steps.length)
                return;
            const s = root.steps[root.at];
            if (!root.started) {
                root.started = true;
                root.stepAt = Date.now();
                try {
                    s.start();
                } catch (e) {
                    root.say(false, s.name, "its start threw: " + e);
                }
                return;
            }
            let ok = false;
            try {
                ok = s.done();
            } catch (e) {
                root.say(false, s.name, "it threw: " + e);
                ok = true;
            }
            if (ok) {
                try {
                    s.check();
                } catch (e) {
                    root.say(false, s.name, "its check threw: " + e);
                }
            } else if (Date.now() - root.stepAt > s.ms) {
                root.say(false, s.name, "not done in " + s.ms + " ms (state " + svc.state + ", route " + svc.route + "; last events "
                         + JSON.stringify(svc.log.slice(-6)) + ")");
                if (svc.state !== "idle")
                    svc._finish("probe");
            } else {
                return;
            }
            root.at += 1;
            root.started = false;
            if (root.at >= root.steps.length) {
                console.log("DT RESULT " + (root.bad === 0 ? "PASS" : "FAIL"));
                quitSoon.start();
            }
        }
    }
    Timer {
        id: quitSoon
        interval: 200
        onTriggered: Qt.quit()
    }
    Timer {
        // a harness smoked bare (no runner) drives nothing
        interval: 0
        running: !Quickshell.env("DT_HELPER")
        onTriggered: {
            console.log("DT RESULT FAIL (no runner: tools/dev/dictation_probe_take.sh)");
            Qt.quit();
        }
    }
}
