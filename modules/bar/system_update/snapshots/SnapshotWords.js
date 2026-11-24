.pragma library
.import "../../../common/components/RelTime.js" as RelTime

// =============================================================================
// SnapshotWords.js -- the snapshots page's and service's pure words and rules, with no Qt in it.
//
//   sizeText(bytes)                   "812 MB" / "1.1 GB" / "18 GB" (decimal, as the user writes it)
//   whenText(ms, nowMs)               { text, nextMs }  "12 min ago" / "today 14:05" / "yesterday 17:21" / "Tue 14:05" / "17 Nov"
//   rowFromRecord(rec, opts)          one `records/<short>.json` -> the page's row (docs/contracts/snapshots.md section 11)
//   rowsFromList(list, opts)          newest first
//   planLine(entry)                   the one line under Undo, from the service's undoPlans[short]
//   undoable(entry)                   the plan says something can be put back
//   summaryLine(rows, repoBytes)      "6 snapshots, 18 GB"
//   offsiteLine(off, enabled, nowMs, onBattery)
//                                     { text, figure, fraction, nextMs, tone }  tone: "ok" | "busy" | "bad" | ""; `figure` "1.2 / 12.7 GB" and
//                                     `fraction` 0..1 (else "" and -1) while it copies. What it waits for is said from the facts NOW.
//   offsiteDue(o)                     "" | "afterRun" | "daily" | "retry": when the service starts a copy off site
// =============================================================================

var UNDO_SENTENCE = "Puts the old versions back. The next update brings the new ones again."
var NOT_SET_UP = "Snapshots are not set up. Run lares setup for the steps."

function sizeText(bytes) {
    var b = Number(bytes)
    if (!isFinite(b) || b < 0) return ""
    var u = ["B", "kB", "MB", "GB", "TB"], i = 0
    while (b >= 1000 && i < u.length - 1) { b /= 1000; i++ }
    var s = i === 0 ? String(Math.round(b)) : (b >= 10 || i < 2 ? String(Math.round(b)) : b.toFixed(1))
    // 1 decimal under 10 GB / TB, none below a GB's worth of rounding noise
    if (i >= 3 && b < 10) s = b.toFixed(1)
    return s + " " + u[i]
}

function _p2(n) { return n < 10 ? "0" + n : String(n) }
var _DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var _MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function whenText(ms, nowMs) {
    var age = nowMs - ms
    if (age < 3600000) {
        var r = RelTime.format(ms, nowMs, { justNow: "just now", suffix: " ago" })
        return { text: r.text, nextMs: r.nextMs }
    }
    var d = new Date(ms), n = new Date(nowMs)
    var midnight = new Date(n.getFullYear(), n.getMonth(), n.getDate() + 1).getTime()
    var hm = _p2(d.getHours()) + ":" + _p2(d.getMinutes())
    var dayStart = new Date(n.getFullYear(), n.getMonth(), n.getDate()).getTime()
    if (ms >= dayStart) return { text: "today " + hm, nextMs: midnight }
    var yStart = new Date(n.getFullYear(), n.getMonth(), n.getDate() - 1).getTime()
    if (ms >= yStart) return { text: "yesterday " + hm, nextMs: midnight }
    var sixStart = new Date(n.getFullYear(), n.getMonth(), n.getDate() - 5).getTime()
    if (ms >= sixStart) return { text: _DAYS[d.getDay()] + " " + hm, nextMs: midnight }
    var text = d.getDate() + " " + _MONTHS[d.getMonth()] + (d.getFullYear() !== n.getFullYear() ? " " + d.getFullYear() : "")
    return { text: text, nextMs: d.getFullYear() !== n.getFullYear() ? -1 : midnight }
}

function _dayText(ms) {
    var d = new Date(ms)
    return d.getDate() + " " + _MONTHS[d.getMonth()]
}

function _titleOf(rec) {
    var note = rec.note ? String(rec.note) : ""
    var count = rec.count | 0
    if (rec.reason === "update")
        return count === 1 ? "Before 1 package" : "Before " + count + " packages"
    if (rec.reason === "manual") return "Manual"
    // an undo's note is the short of the snapshot it undid; the list says when that one was taken (undoneTime)
    if (rec.reason === "undo") return rec.undoneTime > 0 ? "Before undoing the update of " + _dayText(rec.undoneTime * 1000) : "Before undoing an update"
    if (rec.reason === "rescue") return "Before the restore of " + _dayText((rec.time || 0) * 1000)
    return note ? note : "Snapshot"
}

function _notable(rec) {
    var crit = rec.critical || [], changed = rec.changed || [], out = []
    for (var i = 0; i < crit.length && out.length < 4; i++) {
        var hit = null
        for (var j = 0; j < changed.length; j++)
            if (changed[j].name === crit[i]) { hit = changed[j]; break }
        out.push({ name: crit[i], from: hit && hit.from ? String(hit.from) : "", to: hit && hit.to ? String(hit.to) : "",
                   installed: !!hit && !hit.from, removed: !!hit && !hit.to })
    }
    return out
}

// opts: { offsite: [short...], runActive: bool, nowMs: number }
function rowFromRecord(rec, opts) {
    var o = opts || {}
    var off = o.offsite || []
    var t = (rec.time || 0) * 1000
    var open = rec.state === "open"
    return {
        short: String(rec.short), timeMs: t, title: _titleOf(rec), reason: String(rec.reason || ""),
        changed: rec.changed || [], notable: _notable(rec), count: rec.count | 0,
        state: String(rec.state || "done"), keep: rec.keep === true, addedBytes: Number(rec.addedPacked) || Number(rec.added) || 0,
        offsite: off.indexOf(rec.short) >= 0,
        // open with nothing running = the update did not finish; a run that is on, or a hook a moment ago, is not
        unfinished: open && o.runActive !== true && (o.nowMs || Date.now()) - t > 600000,
        note: rec.note ? String(rec.note) : ""
    }
}

function rowsFromList(list, opts) {
    var rows = []
    for (var i = 0; i < list.length; i++) rows.push(rowFromRecord(list[i], opts))
    rows.sort(function (a, b) { return b.timeMs - a.timeMs })
    return rows
}

function undoable(entry) {
    return !!entry && entry.state === "ok" && !!entry.plan && entry.plan.ok !== false && (entry.plan.files || []).length > 0
}

function planLine(entry) {
    if (!entry || entry.state === "loading") return "Looking at what can be put back..."
    if (entry.state !== "ok" || !entry.plan) return entry.text ? String(entry.text) : "This cannot be worked out now."
    var have = (entry.plan.files || []).length, gone = (entry.plan.missing || []).length, all = have + gone
    if (all === 0) return "Nothing to undo: no package has changed since."
    var blocked = entry.plan.blockedBy || []
    if (blocked.length > 0)
        return "This cannot be undone: the old " + blocked.slice(0, 3).join(", ") + (blocked.length > 3 ? " and more are gone." : blocked.length > 1 ? " are gone." : " is gone.")
    var taken = entry.plan.takenOver || []
    if (taken.length > 0)
        return "This cannot be undone here: " + taken[0].owner + ", new since then, took over files of " + taken[0].name + ". The rescue entry in the boot menu can."
    if (have === 0) return "Nothing can be put back: the old versions are gone."
    if (gone === 0) return all === 1 ? "The 1 package can be put back." : "All " + all + " packages can be put back."
    return have + " of " + all + " packages can be put back; " + gone + (gone === 1 ? " old version is gone." : " old versions are gone.")
}

function summaryLine(rows, repoBytes) {
    var n = rows.length, kept = 0
    for (var i = 0; i < n; i++) if (rows[i].keep) kept++
    var s = n + (n === 1 ? " snapshot" : " snapshots") + (kept > 0 ? " (" + kept + " kept)" : "")
    var z = sizeText(repoBytes)
    return z ? s + ", " + z : s
}

// What a copy waits for, by offsite.json's `cause`. The battery is not in it: it is said from the battery itself, and the file holds
// what was true when the copy last looked.
var _WAITS = {
    metered: "Proton Drive waits for an unmetered connection",
    update: "Proton Drive waits for the update to end",
    keyring: "Proton Drive waits for the keyring (it opens with your password)",
    busy: "Proton Drive waits for the snapshot tool",
    throttled: "Proton Drive asked for a pause; the copy goes on later",
    stopped: "The copy to Proton Drive was stopped; it goes on later"
}

function offsiteLine(off, enabled, nowMs, onBattery) {
    function line(text, tone, figure, fraction, nextMs) {
        return { text: text, figure: figure || "", fraction: fraction === undefined ? -1 : fraction, nextMs: nextMs || -1, tone: tone }
    }
    if (!enabled) return line("", "")
    var o = off || {}
    if (o.state === "running") {
        var done = (o.done && o.done.bytes) || 0, left = (o.pending && o.pending.bytes) || 0
        var total = done + left
        return total > 0 ? line("Copying to Proton Drive", "busy", _pair(done, total), done / total) : line("Looking at Proton Drive", "busy")
    }
    if (o.state === "waiting") {
        if (o.cause === "battery")
            return line(onBattery ? "Proton Drive waits for the charger" : "Proton Drive: the copy starts in a moment", "busy")
        return line(_WAITS[o.cause] || "Proton Drive: " + (o.reason ? String(o.reason) : "waiting"), "busy")
    }
    if (o.state === "error")
        return line(o.cause === "signin" ? "Proton Drive is signed out. Run proton-drive auth login" : "Proton Drive: " + (o.reason ? String(o.reason) : "the copy failed"), "bad")
    if (o.state === "idle" && o.lastOk > 0) {
        var w = whenText(o.lastOk * 1000, nowMs)
        return line("Proton Drive: up to date, " + w.text, "ok", "", -1, w.nextMs)
    }
    return line("Proton Drive: not copied yet", "")
}
// "1.2 / 12.7 GB": both in the total's unit, the same decimals, so the first figure alone moves
function _pair(a, b) {
    var u = ["B", "kB", "MB", "GB", "TB"], i = 0, k = 1
    while (b / k >= 1000 && i < u.length - 1) { k *= 1000; i++ }
    var d = i >= 3 ? 1 : 0
    return (a / k).toFixed(d) + " / " + (b / k).toFixed(d) + " " + u[i]
}

// o: { enabled, live, runActive, busy, offsiteState, cause, onBattery, looked, lastOkMs, lastTriggerMs, nowMs, runEndedMs, newSinceRun, afterMs,
//      everyMs (snapshots.jsonc offsite.everyHours; a day when absent), afterUpdate (offsite.afterUpdate; true when absent) }
var _SOON = { metered: true, update: true, keyring: true, busy: true }
// afterRun: a run ended with a new snapshot and `afterMs` has passed (unless `afterUpdate` is false); daily: nothing copied or tried within
// `everyMs` (a day).
function offsiteDue(o) {
    if (!o.enabled || !o.live || o.runActive || o.busy) return ""
    var since = o.nowMs - (o.lastTriggerMs || 0)
    // "running" is what the copy wrote last: a machine that went down in the middle leaves it standing for ever. After three hours (or a new
    // shell) it is asked again: a copy that really runs keeps its unit's name and its own lock, so a second one does nothing.
    if (o.offsiteState === "running") return since >= 10800000 ? "retry" : ""
    var afterUpdate = o.afterUpdate !== false
    if (afterUpdate && o.newSinceRun && o.runEndedMs > 0 && o.nowMs - o.runEndedMs >= o.afterMs) return "afterRun"
    if (!o.newSinceRun || !afterUpdate) {
        var last = Math.max(o.lastOkMs || 0, o.lastTriggerMs || 0)
        if (o.nowMs - last >= (o.everyMs > 0 ? o.everyMs : 86400000)) return "daily"
        // A copy that could not run or broke off is asked again, not the next day: the tool looks at its conditions first and calls nothing
        // when one does not hold. The battery is heard (the charger in: at once), so on battery it is asked only every half hour, in case
        // the file or the reading is wrong; the rest has no signal and is looked at every five minutes. `looked`: the user opened the page.
        if (o.offsiteState === "waiting") {
            if (o.cause === "battery" ? !o.onBattery && since >= 10000 : _SOON[o.cause] === true && since >= 300000) return "retry"
            if (o.looked && since >= 60000 && !(o.cause === "battery" && o.onBattery)) return "retry"
            if (since >= 1800000) return "retry"
        }
        if (o.offsiteState === "error" && since >= (o.looked ? 60000 : 10800000)) return "retry"
    }
    return ""
}
