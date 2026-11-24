pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/components"
import "../../common/system"
import "../../common/components/JsonComments.js" as JsonComments
import "VeilBag.js" as VeilBag

// =============================================================================
// LockConfig.qml -- the lock's settings (contract section 5).
//
// Read once, at creation, from <repo>/config/lockscreen.jsonc (the user's; ConfigFile's older places after it), else
// <repo>/.examples/lockscreen.jsonc (RepoRoot: the lock starts from <repo>/lock). Every key has a default here, so a missing file, a
// half-written one or a key of the wrong type gives the default rather than an
// undefined that a shader or a timer would choke on -- the lock must come up
// whatever is in that file.
//
// EACH FILE HAS ITS OWN FileView (CLAUDE.md: a FileView loads synchronously only
// on its FIRST path; repointing one hands back the previous file's bytes).
// `printErrors: false`: the user's file legitimately may not exist.
// =============================================================================
Scope {
    id: root

    readonly property var defaults: ({
            veil: "random",
            veils: ["relief", "gooey", "dimples", "paper", "louvres", "keycaps", "dials"],
            idleSeconds: 30,
            fps: 60,
            batteryFpsRatio: 0.5,
            blurInMs: 250,
            veilRiseMs: 1200,
            unlockHoldMs: 600,
            unlockMs: 400,
            face: "auto",
            keyringPassword: true,
            faceRearmCooldownMs: 5000,
            fallbackDelayMs: 2000,
            bootFallbackDelayMs: 30000,
            handoverGraceMs: 3000,
            greetingName: "",
            popupBand: ["battery", "weather", "updates", "screen"],
            popupFoot: ["music", "wiki"],
            greeting: "boot",
            faceWhen: ["boot", "resume", "return", "ask"],
            lockedControls: ["idle", "volume", "player"],
            obscure: []
        })

    property var values: root.defaults
    // Which file the values came from ("" = defaults only), for the log.
    property string source: ""

    // A veil's name, or "random": the next of `veils` per lock, in a shuffle bag (see pickVeil).
    readonly property string veil: root.values.veil
    readonly property var veils: root.values.veils
    readonly property real idleSeconds: root.values.idleSeconds
    readonly property real fps: root.values.fps
    readonly property real batteryFpsRatio: root.values.batteryFpsRatio
    readonly property int blurInMs: root.values.blurInMs
    // How long the veil takes to rise (it starts with the blur-in of the still).
    readonly property int veilRiseMs: root.values.veilRiseMs
    // The unlock: the veil holds at full presence (its `ok` plays), then the lock
    // fades to the live desktop over unlockMs, then the session is released.
    readonly property int unlockHoldMs: root.values.unlockHoldMs
    readonly property int unlockMs: root.values.unlockMs
    readonly property string face: root.values.face
    // No face while the login keyring is locked: the password opens it (FaceAvailability, "THE KEYRING")
    readonly property bool keyringPassword: root.values.keyringPassword !== false
    readonly property int faceRearmCooldownMs: root.values.faceRearmCooldownMs
    readonly property int fallbackDelayMs: root.values.fallbackDelayMs
    // At boot the shell starts seconds after the lock: its card waits this long (the shell's own start budget, lares's
    // READY_TIMEOUT 30 s), and a failed attempt brings it at once (LockSurface, THE FALLBACK).
    readonly property int bootFallbackDelayMs: root.values.bootFallbackDelayMs
    // The card goes when the shell names its bar; it comes back when the shell's popup has not followed within this.
    readonly property int handoverGraceMs: root.values.handoverGraceMs
    readonly property string greetingName: root.values.greetingName
    // What the popup shows is the shell's popup's to follow (it reads the same file); here it is the lock's own card's.
    readonly property var popupBand: root.values.popupBand
    readonly property string greeting: root.values.greeting
    // When a face scan starts by itself (AuthController); asking for one by a key always may.
    readonly property var faceWhen: root.values.faceWhen
    readonly property var obscure: root.values.obscure

    // ConfigFile: config/lockscreen.jsonc first, then its older places. Read once, at creation (no watch).
    ConfigFile {
        id: userFile
        path: RepoRoot.dir + "/config/lockscreen.jsonc"
        watchChanges: false
    }
    ConfigFile {
        id: exampleFile
        path: RepoRoot.dir + "/.examples/lockscreen.jsonc"
        watchChanges: false
    }

    // The parsed object with every default filled in; a key of the wrong type
    // (or a non-finite number) keeps its default.
    function merge(parsed) {
        const out = {};
        for (const k in root.defaults) {
            const d = root.defaults[k];
            const v = (parsed !== null && typeof parsed === "object") ? parsed[k] : undefined;
            const ok = v !== undefined && v !== null
                && (Array.isArray(d) ? Array.isArray(v) : typeof v === typeof d)
                && (typeof d !== "number" || isFinite(v));
            out[k] = ok ? v : d;
        }
        return out;
    }

    // The veils there are (LockVeil.proposals). A name that is not one -- a veil that is gone ("zen") in
    // an older lockscreen.jsonc -- is not an error and not a lock with no
    // veil: it falls back to the default (random over the default list), with one log line.
    readonly property var known: ["relief", "gooey", "dimples", "paper", "louvres", "keycaps", "dials"]

    // The veils a random lock draws from: `veils` without the names that are no veil (see `known`; one log line each).
    function randomNames() {
        const all = root.veils.filter(n => typeof n === "string" && n !== "");
        for (const n of all)
            if (root.known.indexOf(n) < 0)
                console.log("lock: veil '" + n + "' in veils is no veil (any more); skipped");
        return all.filter(n => root.known.indexOf(n) >= 0);
    }

    // The veil of THIS lock: { name, state }. A fixed name is that name (the bag is left as it was). "random" draws the next veil of the
    // SHUFFLE BAG (VeilBag.js): each round is a fresh permutation of `veils`, so every veil shows within a window and two locks in a row
    // never look the same; `state` is the bag as it was kept (VeilBag.parse of the state file) and the answer's `state` is what to keep.
    // `rnd` is a function returning a number in [0, 1), a parameter so a probe can walk every outcome.
    // A name that is no veil (see `known`) is skipped, one log line each.
    function pickVeil(state, rnd) {
        let names;
        if (root.veil !== "random") {
            if (root.known.indexOf(root.veil) >= 0)
                return { name: root.veil, state: state };
            console.log("lock: veil '" + root.veil + "' is no veil (any more); using the default");
            names = root.defaults.veils;
        } else {
            names = root.randomNames();
        }
        const d = VeilBag.draw(state, names, rnd);
        return { name: d.name === "" ? "relief" : d.name, state: d.state };
    }

    function _read(view) {
        try {
            const t = view.text();
            if (t === undefined || t === null || String(t).trim() === "")
                return null;
            const o = JSON.parse(JsonComments.strip(String(t)));
            return (o !== null && typeof o === "object" && !Array.isArray(o)) ? o : null;
        } catch (e) {
            return null;
        }
    }

    // Idempotent: whoever needs the values first (LockRoot, before it starts
    // anything that reads them) calls it; completion order between sibling
    // objects is not something to lean on.
    property bool loaded: false
    function load() {
        if (root.loaded)
            return;
        root.loaded = true;
        let o = root._read(userFile);
        root.source = o ? userFile.activePath : "";
        if (!o) {
            o = root._read(exampleFile);
            root.source = o ? exampleFile.activePath : "";
        }
        root.values = root.merge(o);
    }
    Component.onCompleted: root.load()
}
