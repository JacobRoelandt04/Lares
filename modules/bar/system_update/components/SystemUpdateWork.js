.pragma library

// =============================================================================
// SystemUpdateWork.js -- what a system-update run is doing, in the shell's words.
//
// ONE copy of the wording, for the two places that name the work. The popup
// titles its status card with it, and the update's SERVICE names it in the
// authentication toast when sudo asks for the password -- which happens with the
// popup closed, so the popup's own label is not there to ask. Both feed it the
// parser's phase, sub-phase and plain label; neither holds a copy of the switch.
// =============================================================================

// The transaction's title says what pacman is doing NOW. "Installing official
// packages" over a download would read as the download being mislabelled -- to the
// reader an install is files being put in place, and that has not started.
// Anything outside the two transactions is the parser's own label.
//
// `kind` is the run's kind ("update", or "undo": pacman -U of old packages) and `snapshotState` the
// parser's: the pre-transaction hook that takes the snapshot is the whole of "Preparing to install" for
// as long as it runs, so the title says so.
function workLabel(phase, subPhase, rawLabel, kind, snapshotState) {
    if (subPhase === "L4_PREHOOKS" && snapshotState === "running")
        return "Taking a snapshot";
    if (kind === "undo" && (phase === "OFFICIAL_INSTALL" || phase === "AUR_INSTALL")) {
        switch (subPhase) {
            case "L0_RESOLVE": case "L1_TABLE": return "Undoing the update";
            case "L3_INTEGRITY":                return "Verifying the old packages";
            case "L4_PREHOOKS":                 return "Preparing to downgrade";
            case "L5_CHANGES":                  return "Downgrading packages";
            case "L6_POSTHOOKS":                return "Running post-install hooks";
        }
        return rawLabel;
    }
    if (phase === "OFFICIAL_INSTALL" || phase === "AUR_INSTALL") {
        const what = phase === "AUR_INSTALL" ? "AUR packages" : "official packages";
        switch (subPhase) {
            case "L0_RESOLVE": case "L1_TABLE": return "Resolving the upgrade";
            case "N0_LOAD":                     return "Loading built AUR packages";
            // pacman's table for the built packages, and the Proceed
            // question under it. The reader is being asked to approve
            // a list, which is not "loading".
            case "N1_TABLE":                    return "Reviewing AUR changes";
            case "L2_DOWNLOAD":                 return "Downloading " + what;
            case "L3_INTEGRITY": case "N3_INTEGRITY": return "Verifying " + what;
            // A mixed run has TWO transactions and pacman runs hooks for
            // each: the AUR one's own -- evdi-dkms rebuilding DKMS and
            // the initramfs, docker-desktop and cardwire reloading systemd
            // and D-Bus, the desktop apps refreshing the MIME and icon
            // caches -- come after the AUR packages are in, because that
            // is when their files exist. Titled like the official hooks
            // they would read as the official ones arriving late, so each names the
            // install it belongs to.
            case "L4_PREHOOKS":                 return "Preparing to install " + what;
            case "L5_CHANGES": case "N5_CHANGES":     return "Installing " + what;
            case "L6_POSTHOOKS":                return "Running post-install hooks";
            case "N6_POSTHOOKS":                return "Finishing the AUR install";
        }
    }
    return rawLabel;
}

// What the authentication toast says when sudo asks mid-run: the run, and what
// yay is doing at that moment. `{ body, detail }`, the shape AskpassSource's
// `describe` returns.
function askpassDescription(phase, subPhase, rawLabel, kind, snapshotState) {
    const undo = kind === "undo";
    return { body: phase === "INITIAL" ? (undo ? "Starting the undo" : "Starting the update")
                                       : workLabel(phase, subPhase, rawLabel, kind, snapshotState),
             detail: undo ? "asked by pacman" : "asked by yay" };
}

// The title of a run that ended: "Update complete" / "Update failed", and an undo's own.
function endLabel(kind, ok) {
    if (kind === "undo")
        return ok ? "Update undone" : "Undo failed";
    return ok ? "Update complete" : "Update failed";
}

// The failed snapshot hook's `failed <code> <text>` as a plain sentence for the card and the error list.
// `text` is the hook's own words (the three largest new files for `added`, the free figure for `space`).
function snapshotFailure(code, text) {
    var head;
    switch (code) {
        case "space":    head = "Not enough free disk space for a snapshot"; break;
        case "added":    head = "The snapshot would grow far too large"; break;
        case "time":     head = "The snapshot took too long"; break;
        case "lock":     head = "Another snapshot is running"; break;
        default:         head = "The snapshot could not be taken"; break;
    }
    var t = String(text || "").trim();
    return t.length > 0 ? head + ": " + t : head;
}

// "112 packages: linux, mesa, nvidia-open" (the hook's `start` text) as the operation line's names:
// "linux, mesa and 110 more". Never more names than the hook sent; "" when it sent none.
function snapshotNames(text) {
    var m = String(text || "").match(/^(\d+) packages?(?:: (.+))?$/);
    if (!m || !m[2]) return "";
    var names = m[2].split(/,\s*/).filter(function (x) { return x.length > 0; });
    var more = Math.max(0, parseInt(m[1]) - names.length);
    if (more === 0)
        return names.length > 1 ? names.slice(0, -1).join(", ") + " and " + names[names.length - 1] : names[0];
    return names.join(", ") + " and " + more + " more";
}

// What `SnapshotService.wantsFor(names)` answers as a yes: a bool, or the rule's `{ want, ... }` (the
// contract names the call, section 4 the rule's object; the shell reads either).
function wantsYes(answer) {
    return !!(answer && typeof answer === "object" ? answer.want : answer);
}
