.pragma library

// =============================================================================
// MuxFlow.js -- the words and the arithmetic of the MUX's moments in the shell:
// what the restart card says by state, the keep prompt toast's words and countdown, the notice after a revert or a way back that
// did not go through, the notification of an app Smart kept off the dGPU. Pure, no Qt: the card, the keep prompt, the watcher
// and the notifier read it, and a harness can call it with made-up facts.
//
// THE COUNTDOWN RULE (HELPER_PROTOCOL.md, "reverting in m:ss") is the data layer's, one place:
// SiliconModel.muxRemainingMs (the record's uptime deadline minus the shell's own /proc/uptime, another boot's
// window over, the wall deadline as the display fallback). MuxCountdown reads the uptime and calls it; this file
// only formats the answer and says when it next changes.
//
// WHAT THE FACTS ARE (`vm.gpu.mux`): state, pending, want, why, deadlineMs, deadlineBootId, deadlineUptimeMs,
// bootId, bootWindowS, promptWindowS (the helper's two windows: facts, not config), prechecks {ok, why},
// outcomeSeen.
// =============================================================================

function isNum(v) {
    return typeof v === "number" && isFinite(v);
}

// --- the countdown -------------------------------------------------------------------------------

// "m:ss" of a remaining time, rounded UP: a countdown never says 0:00 while time is left.
function clock(ms) {
    if (!isNum(ms))
        return "";
    var s = Math.max(0, Math.ceil(ms / 1000));
    var r = s % 60;
    return Math.floor(s / 60) + ":" + (r < 10 ? "0" : "") + r;
}

// How long until clock(ms) says something else: the next whole-second boundary, never less than 1 ms.
// -1 when the countdown is over (nothing left to arm).
function untilNext(ms) {
    if (!isNum(ms) || ms <= 0)
        return -1;
    var shown = Math.ceil(ms / 1000);
    return Math.max(1, Math.ceil(ms - (shown - 1) * 1000));
}

// --- the words -----------------------------------------------------------------------------------------

var _MINUTES = ["", "a minute", "two minutes", "three minutes", "four minutes", "five minutes"];

// 120 -> "two minutes", 90 -> "90 seconds"
function spanWords(seconds) {
    var n = Math.round(seconds);
    if (!(n > 0))
        return "a little while";
    if (n % 60 === 0) {
        var m = n / 60;
        return m < _MINUTES.length ? _MINUTES[m] : m + " minutes";
    }
    return n + " seconds";
}

// The restart card, by what is waiting. `keepSeconds` is the window the prompt gives (`gpu.mux.promptWindowS`).
//   kind "dgpu"    a request for dGPU only, the pre-checks pass: restart, later, cancel
//   kind "hybrid"  the way back (no guard after it): restart, later, cancel. The title says where the laptop ends
//                  up -- the mode asked for after the restart (`mux.afterMode`: 0 Integrated, 1 Smart, 2 or none
//                  Hybrid) -- and the body what happens after the screen is back on the Intel card
//   kind "blocked" a request for dGPU only the pre-checks now refuse: only cancel
function muxCardCopy(mux, keepSeconds) {
    var want = mux && typeof mux.want === "string" ? mux.want : "";
    var pre = mux && mux.prechecks && typeof mux.prechecks === "object" ? mux.prechecks : { ok: true, why: "" };
    if (want === "dgpu" && pre.ok === false) {
        var why = String(pre.why || "").trim();
        return {
            kind: "blocked",
            title: "dGPU only cannot go ahead",
            body: why !== "" ? why : "The checks for it did not pass.",
            hint: "Cancel, put that right, and ask again.",
            restart: false, later: false, cancel: true
        };
    }
    if (want === "dgpu") {
        return {
            kind: "dgpu",
            title: "dGPU only needs a restart",
            body: "The screen comes back on the NVIDIA card. After the restart you have " + spanWords(keepSeconds)
                  + " to keep it, or the laptop goes back to Hybrid and restarts once more.",
            hint: "",
            restart: true, later: true, cancel: true
        };
    }
    var after = mux && isNum(mux.afterMode) ? mux.afterMode : 2;
    var title = "Hybrid needs a restart";
    var body = "The screen goes back to the Intel card. Nothing to confirm after the restart.";
    if (after === 0) {
        title = "Integrated needs a restart";
        body = "The screen goes back to the Intel card, and then the dGPU is switched off. Nothing to confirm after the restart.";
    } else if (after === 1) {
        title = "Smart needs a restart";
        body = "The screen goes back to the Intel card, and then Smart mode takes over. Nothing to confirm after the restart.";
    }
    return {
        kind: "hybrid",
        title: title,
        body: body,
        hint: "",
        restart: true, later: true, cancel: true
    };
}

// The keep prompt toast, by phase: "ask" (waiting for the answer) | "back" (the way back is on its way).
function keepCopy(phase) {
    if (phase === "back")
        return { title: "Going back to Hybrid", body: "The laptop restarts in a moment." };
    return {
        title: "Keep dGPU only?",
        body: "The screen is on the NVIDIA card now. If you do nothing, the laptop goes back to Hybrid and restarts once more."
    };
}

// The way back from a keep prompt that did not go through (MuxKeepPrompt.wayBackFailed): the prompt's keep step took, so
// the guard no longer counts, and what is left depends on how far the three steps got -- Hybrid asked and waiting for a
// restart (`queued`), or nothing (dGPU only stays on). `why` is the helper's reason when it refused, else "".
function wayBackFailed(mux, why) {
    var w = String(why || "").trim();
    var queued = !!mux && mux.state === "queued";
    return {
        title: "Going back to Hybrid did not go through",
        body: (w !== "" ? w + " " : "")
              + (queued ? "Hybrid is waiting for the next restart." : "dGPU only stays on. Switch back from the GPU panel when you want it.")
    };
}

// What the guard's last word on a record says to the user, once: { title, body } of a NOTIFICATION (the manager keeps it, to be read at
// leisure -- an OSD card truncated it, and the helper's reasons are long). null for a record with no outcome to tell (kept and
// cancelled are the user's own answers).
//
// A `failed` record whose WIRING IN EFFECT is the one it asked for is not a failure (2026-11-04, kernel 7.2 asus-armoury): the helper
// writes gpu_mux_mode at shutdown and reads it straight back; the firmware attribute answers with the OLD value until the restart
// (`pending_reboot: 1`), so the write is recorded as "the firmware holds hybrid after the write" -- and the machine came up on the NVIDIA
// card all the same. Saying "did not go through" then is false, and because the record was `failed` no keep prompt ran and the boot guard
// had nothing to guard, so the notice says what is true: the switch is in, and nothing will put Hybrid back by itself.
function outcome(mux) {
    if (!mux || !(mux.state === "reverted" || mux.state === "failed"))
        return null;
    var why = String(mux.why || "").trim();
    if (mux.state === "reverted") {
        return {
            title: "dGPU only was not kept",
            body: "So the laptop went back to Hybrid."
        };
    }
    var want = String(mux.want || "");
    if ((want === "dgpu" || want === "hybrid") && String(mux.wiringNow || "") === want) {
        return want === "dgpu" ? {
            title: "dGPU only is on",
            body: "The firmware took the switch at the restart. The check made when it was written read the old value and logged a failure, "
                  + "so no keep prompt ran and nothing will go back to Hybrid by itself. Switch back from the GPU panel when you want it."
        } : {
            title: "Hybrid is on",
            body: "The firmware took the switch at the restart. The check made when it was written read the old value and logged a failure."
        };
    }
    return {
        title: "The GPU change did not go through",
        body: why !== "" ? why : "The firmware was not changed."
    };
}

// The id an app is known by: cardwire's own, else its process name.
function appId(app) {
    if (!app)
        return "";
    if (typeof app.id === "string" && app.id !== "")
        return app.id;
    if (typeof app.appId === "string" && app.appId !== "")
        return app.appId;
    return typeof app.comm === "string" ? app.comm : "";
}

// The name to show for an app: the policy row's, else its process, else its id.
function appName(app, policies) {
    var id = appId(app);
    var rows = Array.isArray(policies) ? policies : [];
    for (var i = 0; i < rows.length; i++) {
        if (rows[i] && rows[i].id === id && typeof rows[i].name === "string" && rows[i].name !== "")
            return rows[i].name;
    }
    if (app && typeof app.comm === "string" && app.comm !== "")
        return app.comm;
    return id;
}

// The notification of an app Smart kept off the dGPU: a title, one line on why, the two answers.
function blockedCopy(name) {
    return {
        title: name + " stayed on the integrated GPU",
        body: "Smart mode only lets the apps you allow use the NVIDIA card.",
        actions: [{ id: "allow", label: "Allow always" }, { id: "ignore", label: "Ignore" }]
    };
}
